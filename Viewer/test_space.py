"""W1 integration tests run the actual Swift preparation tool, never a Python replacement."""
import base64
import hashlib
import io
import os
import time
import json
from pathlib import Path
import tempfile
import unittest
import uuid
import zipfile
from unittest.mock import patch
import numpy as np
from server import Store, create_app
from space import SpaceStore, CALIBRATION

TOOL = Path(__file__).resolve().parents[1]/'.build/tools/space-route'


@unittest.skipUnless(TOOL.exists(), 'Run bash Tools/build_space_route.sh first')
class SpaceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.store = Store(self.root/'cache')
        self.app = create_app(self.store)
        self.client = self.app.test_client()
        self.headers = {'X-Viewer-Token':self.app.config['TOKEN']}
        self.spaces = self.app.extensions['space_store']
        self.mid, self.sid = str(uuid.uuid4()), str(uuid.uuid4())
        nodes = [dict(id=str(uuid.uuid4()),name='西口',kind='junction',position=dict(x=-.7,y=-1.5,z=-.7)),
                 dict(id=str(uuid.uuid4()),name='1309',kind='room',position=dict(x=.6,y=-1.5,z=.6))]
        self.nav = dict(schema_version=2,kind='lidar_navigation_map',map_id=self.mid,session_id=self.sid,name='W1 测试地图',
            coordinate_system='ARKit_Y_up_camera_minus_Z_row_major_meters',created_utc='2026-10-17T00:00:00Z',
            initial_world_map_used=False,points_file='geometry.f32',point_count=400,voxel_m=.1,
            nodes=nodes,edges=[dict(id='test-edge',**{'from':nodes[0]['id'],'to':nodes[1]['id']})])
        self.xyz = np.array([[x,-1.5,z] for x in np.arange(-1,1,.1) for z in np.arange(-1,1,.1)],dtype='<f4')

    def tearDown(self):
        self.store.compute.shutdown(wait=True)
        self.temp.cleanup()

    def bundle(self, geometry=None, calibration=None, extra=None):
        files={'navigation.json':json.dumps(self.nav).encode(),'geometry.f32':self.xyz.tobytes() if geometry is None else geometry}
        if calibration: files[CALIBRATION]=json.dumps(calibration).encode()
        files.update(extra or {})
        files['files.json']=json.dumps(dict(files=[dict(path=k,bytes=len(v),sha256=hashlib.sha256(v).hexdigest()) for k,v in files.items()])).encode()
        path=self.root/(uuid.uuid4().hex+'.zip')
        with zipfile.ZipFile(path,'w') as archive:
            for name,raw in files.items():archive.writestr('map/'+name,raw)
        return path

    def calibration(self):
        # Exactly one white cell; it still counts as calibrated. Deliberately old geometry hash.
        return dict(schema_version=1,kind='lidar_passage_calibration',map_id=self.mid,editor='phone',
                    base_geometry_sha256='older-geometry',updated_utc='2026-10-17T00:00:00Z',
                    walkable=dict(origin_x=-.5,origin_z=-.5,cell_m=.1,width=1,height=1,rle=base64.b64encode(b'\x01').decode()),
                    suggested_paths=[],future_field={'preserved':True})

    def test_versions_and_restart_keep_full_original_geometry(self):
        first=self.spaces.import_map(self.bundle())
        changed=self.xyz.copy();changed[:,0]+=.01
        second=self.spaces.import_map(self.bundle(changed.tobytes()))
        self.assertNotEqual(first['project']['key'],second['project']['key'])
        self.assertEqual(len(self.spaces.catalog()),2)
        folder=self.spaces.folder(first['project']['key'])
        self.assertEqual((folder/'map/geometry.f32').read_bytes(),self.xyz.tobytes())
        self.assertEqual(first['nodes'],self.nav['nodes'])
        self.assertEqual(first['grid']['suggested_paths'],[])  # Legacy edges never become forced paths.
        self.assertIsNone(first['grid'].get('calibrated_rect'))
        self.assertEqual(len(SpaceStore(self.root/'cache').catalog()),2)

    def test_calibration_roundtrip_reject_wrong_map_and_preserve_on_failure(self):
        data=self.spaces.import_map(self.bundle());key=data['project']['key']
        value=self.calibration();raw=json.dumps(value).encode()
        loaded=self.spaces.apply_calibration(key,raw)
        self.assertIsNotNone(loaded['grid']['calibrated_rect'])
        self.assertTrue(any('其他几何版本' in w for w in loaded['warnings']))
        self.assertEqual(self.spaces.export(key),raw)
        value['map_id']=str(uuid.uuid4())
        with self.assertRaisesRegex(ValueError,'不属于'):self.spaces.apply_calibration(key,json.dumps(value).encode())
        value=self.calibration();value['walkable']['rle']='@@@@'
        with self.assertRaises(ValueError):self.spaces.apply_calibration(key,json.dumps(value).encode())
        self.assertEqual(self.spaces.export(key),raw)
        duplicate=self.spaces.import_map(self.bundle())
        self.assertEqual(duplicate['calibration']['future_field'],{'preserved':True})

    def test_interrupted_cache_commit_is_rebuilt_from_authoritative_calibration(self):
        data=self.spaces.import_map(self.bundle());key=data['project']['key']
        folder=self.spaces.folder(key)
        # Simulate interruption after replacing calibration but before updating its derived grid.
        (folder/CALIBRATION).write_text(json.dumps(self.calibration()))
        repaired=self.spaces.state(key)
        self.assertIsNotNone(repaired['grid']['calibrated_rect'])
        self.assertEqual(repaired['grid']['workbench_calibration_sha256'],hashlib.sha256((folder/CALIBRATION).read_bytes()).hexdigest())

    def test_http_import_export_and_token_guards(self):
        self.assertEqual(self.client.get('/space').status_code,200)
        self.assertEqual(self.client.get('/api/catalog').json['space_protocol'],1)
        raw=self.bundle().read_bytes()
        self.assertEqual(self.client.post('/api/space/import',data={'file':(io.BytesIO(raw),'map.zip')}).status_code,403)
        response=self.client.post('/api/space/import',data={'file':(io.BytesIO(raw),'map.zip')},headers=self.headers)
        self.assertEqual(response.status_code,200,response.json)
        key=response.json['project']['key'];response.close();response.request.environ['wsgi.input'].close()
        exported=self.client.get(f'/api/space/projects/{key}/export')
        self.assertIsNone(json.loads(exported.data)['walkable'])
        exported.close()
        response=self.client.post(f'/api/space/projects/{key}/calibration',data={'file':(io.BytesIO(json.dumps(self.calibration()).encode()),'cal.json')},headers=self.headers)
        self.assertEqual(response.status_code,200,response.json)
        response.close();response.request.environ['wsgi.input'].close()
        self.assertEqual(self.client.get('/api/space/projects/not-a-project').status_code,400)

    def test_phone_source_edits_do_not_invalidate_pinned_workbench(self):
        data=self.spaces.import_map(self.bundle());key=data['project']['key']
        pinned=self.spaces.tool;digest=hashlib.sha256(pinned.read_bytes()).hexdigest()
        fake=self.root/'phone-worktree';(fake/'Viewer').mkdir(parents=True)
        core=fake/'Sources/ProbeCore';core.mkdir(parents=True)
        changed=core/'LiDARLocalization.swift';changed.write_text('// phone work in progress')
        future=time.time()+3600;os.utime(changed,(future,future))
        with patch('space.ROOT',fake/'Viewer'):
            result=self.spaces.preview(key,{'calibration':self.calibration()})
            self.assertIsNone(result['route'])
            explicit=SpaceStore(self.root/'cache',tool=TOOL)
            with self.assertRaisesRegex(ValueError,'核心已更新'):
                explicit.run_tool([])
        reopened=SpaceStore(self.root/'cache')
        self.assertEqual(reopened.tool.resolve(),pinned.resolve())
        self.assertEqual(hashlib.sha256(reopened.tool.read_bytes()).hexdigest(),digest)

    def test_service_restart_keeps_open_page_token(self):
        token=self.app.config['TOKEN'];restarted=create_app(self.store)
        self.assertEqual(restarted.config['TOKEN'],token)
        response=restarted.test_client().post('/api/space/projects/not-a-project/preview',json={},headers=self.headers)
        self.assertEqual(response.status_code,400) # Request reached validation, not rejected as expired.
        self.assertEqual((self.store.root/'.viewer-token').stat().st_mode & 0o777,0o600)
        self.assertEqual(restarted.test_client().post('/api/space/projects/not-a-project/preview',json={}).status_code,403)

    def test_raw_geometry_reference_is_independent_of_calibration(self):
        data=self.spaces.import_map(self.bundle());key=data['project']['key']
        self.spaces.apply_calibration(key,json.dumps(self.calibration()).encode())
        before=self.spaces.export(key)
        response=self.client.get(f'/api/space/projects/{key}/geometry')
        self.assertEqual(response.status_code,200)
        self.assertEqual(response.data,self.xyz.tobytes())
        response.close()
        self.assertEqual(self.spaces.export(key),before)
        self.assertEqual(self.client.get('/api/space/projects/not-a-project/geometry').status_code,400)

    def test_pending_transaction_and_corruption_rejected(self):
        with self.assertRaisesRegex(ValueError,'更新尚未完成'):
            self.spaces.import_map(self.bundle(extra={'.map-transaction.json':b'{}'}))
        source=self.bundle()
        with zipfile.ZipFile(source,'a') as archive: archive.writestr('map/unlisted.json','{}')
        with self.assertRaises(ValueError): self.spaces.import_map(source)
        self.assertEqual(self.spaces.catalog(),[])

    def test_space_mode_without_edges_keeps_phone_paths_and_walked_trajectory(self):
        self.nav['routing_mode']='space';self.nav['edges']=[]
        cal=self.calibration();cal['walkable']=None
        cal['suggested_paths']=[dict(id='phone-path',points=[[-.7,-.7],[.6,.6]],width_m=.6,source='phone',created_utc='2026-10-17T00:00:00Z')]
        trajectory=dict(schema_version=1,map_id=self.mid,polylines=[[[-.7,-.7],[.6,.6]]])
        data=self.spaces.import_map(self.bundle(calibration=cal,extra={'walked-trajectory.json':json.dumps(trajectory).encode()}))
        self.assertTrue(data['project']['has_trajectory'])
        self.assertEqual(data['grid']['suggested_paths'],cal['suggested_paths'])
        self.assertIsNone(data['grid'].get('calibrated_rect'))
        self.assertEqual(data['edges'],[])
        self.assertEqual(data['calibration']['editor'],'phone')

    def test_tool_change_invalidates_derived_grid(self):
        data=self.spaces.import_map(self.bundle());key=data['project']['key']
        target=self.spaces.folder(key)/'grid.json'
        cached=json.loads(target.read_text());cached['workbench_tool_sha256']='old-tool';target.write_text(json.dumps(cached))
        with patch.object(self.spaces,'prepare',wraps=self.spaces.prepare) as prepare:
            fresh=self.spaces.state(key)
        self.assertEqual(prepare.call_count,1)
        self.assertEqual(fresh['grid']['workbench_tool_sha256'],hashlib.sha256(TOOL.read_bytes()).hexdigest())

    def test_editor_save_revision_and_readonly_draft_preview(self):
        data=self.spaces.import_map(self.bundle());key=data['project']['key']
        cal=self.calibration()
        payload=dict(calibration=cal,base_revision=data['calibration_revision'])
        response=self.client.post(f'/api/space/projects/{key}/edit',json=payload,headers=self.headers)
        self.assertEqual(response.status_code,200,response.json)
        current=response.json['calibration_revision'];self.assertNotEqual(current,'none')
        conflict=self.client.post(f'/api/space/projects/{key}/edit',json=payload,headers=self.headers)
        self.assertEqual(conflict.status_code,409,conflict.json)
        draft=self.calibration();draft['suggested_paths']=[dict(id='draft',points=[[-.6,0],[.6,0]],width_m=.6,source='workbench',created_utc='2026-10-17T00:00:00Z')]
        preview=self.client.post(f'/api/space/projects/{key}/preview',json={'calibration':draft,'from':[-.5,0],'to':[.5,0],'request_id':12},headers=self.headers)
        self.assertEqual(preview.status_code,200,preview.json);self.assertEqual(preview.json['request_id'],12)
        self.assertEqual(preview.json['route']['status'],'ok',preview.json)
        self.assertEqual(self.spaces.state(key)['calibration']['suggested_paths'],[])
        self.assertEqual(self.spaces.state(key)['calibration_revision'],current)
        validated=self.client.post(f'/api/space/projects/{key}/preview',json={'calibration':draft},headers=self.headers)
        self.assertEqual(validated.status_code,200,validated.json);self.assertIsNone(validated.json['route'])
        exported=self.client.post(f'/api/space/projects/{key}/export-draft',json={'calibration':draft},headers=self.headers)
        self.assertEqual(exported.status_code,200,exported.json)
        downloaded=self.client.get(exported.json['download_url'])
        self.assertEqual(json.loads(downloaded.data),draft);self.assertIn('attachment',downloaded.headers['Content-Disposition']);downloaded.close()
        self.assertEqual(self.spaces.state(key)['calibration_revision'],current)
        invalid=self.client.post(f'/api/space/projects/{key}/preview',json={'from':['NaN',0],'to':[0,0]},headers=self.headers)
        self.assertEqual(invalid.status_code,400)
        self.assertEqual(self.client.post(f'/api/space/projects/{key}/edit',json=payload).status_code,403)

    def test_embedded_calibration_and_missing_tool_actionable(self):
        data=self.spaces.import_map(self.bundle(calibration=self.calibration()))
        self.assertIsNotNone(data['grid']['calibrated_rect'])
        with patch.object(self.spaces,'tool',self.root/'missing-tool'):
            with self.assertRaisesRegex(ValueError,'build_space_route'):self.spaces.run_tool([])

if __name__ == '__main__':unittest.main()
