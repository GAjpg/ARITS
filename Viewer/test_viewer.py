import io
import json
from pathlib import Path
import sys
import tempfile
import time
import unittest
from unittest.mock import patch
import numpy as np

sys.path.insert(0,str(Path(__file__).resolve().parents[1]/"Tools"))
from make_lidar_fixture import make
from engine import Scan, decode_frame, decode_cloud, match, validate_result
from server import Store, create_app

class ViewerTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp=tempfile.TemporaryDirectory()
        cls.root=Path(cls.temp.name)
        cls.map_meta,cls.query_meta,_,cls.truth=make(cls.root/"fixtures")
        cls.store=Store(cls.root/"viewer-data")
        cls.app=create_app(cls.store)
        cls.client=cls.app.test_client()
        cls.headers={"X-Viewer-Token":cls.app.config["TOKEN"]}
    @classmethod
    def tearDownClass(cls):
        cls.store.compute.shutdown(wait=True)
        cls.temp.cleanup()
    def test_frame_coordinates_and_rgb_are_consistent(self):
        with Scan(self.root/"fixtures/query.zip") as q:
            f=q.meta["frames"][2]
            actual=decode_frame(q,f)
            np.testing.assert_allclose(actual[:,:3],q.points([f]),atol=1e-5)
            self.assertTrue(np.isfinite(actual).all())
            self.assertTrue(((actual[:,3:]>=0)&(actual[:,3:]<=1)).all())
            cloud=decode_cloud(q,limit=50)
            self.assertLessEqual(len(cloud),50)
    def test_import_and_http_cloud_image(self):
        with (self.root/"fixtures/map.zip").open("rb") as f:
            r=self.client.post("/api/import",data={"file":(io.BytesIO(f.read()),"map.zip")},headers=self.headers)
        self.assertEqual(r.status_code,200,r.json)
        mid=r.json["scan"]["id"]
        r.close();r.request.environ["wsgi.input"].close()
        binary=self.client.get(f"/api/scans/{mid}/cloud")
        self.assertEqual(binary.status_code,200)
        self.assertEqual(len(binary.data)%24,0)
        frame=self.client.get(f"/api/scans/{mid}/frames/0/cloud")
        self.assertEqual(frame.status_code,200)
        image=self.client.get(f"/api/scans/{mid}/frames/0/image")
        self.assertEqual(image.mimetype,"image/jpeg")
        binary.close();frame.close();image.close()
        self.assertEqual(self.client.get(f"/api/scans/{mid}/frames/999/cloud").status_code,400)
    def test_schema2_map_above_legacy_frame_cap_and_v1_rejection(self):
        import copy,zipfile
        from make_lidar_fixture import checksum
        folder=self.root/'map-v2';folder.mkdir(exist_ok=True)
        with Scan(self.root/'fixtures/map.zip') as source:
            meta=copy.deepcopy(source.meta);meta['schema_version']=2
            import uuid
            meta['scan_id']=str(uuid.uuid4());meta['frames']=[]
            for i in range(101):
                frame=copy.deepcopy(source.meta['frames'][0]);frame['index']=i;frame['timestamp']=100+i*.5
                meta['frames'].append(frame)
                target=folder/f'frames/{i:04d}';target.mkdir(parents=True,exist_ok=True)
                for name in ('depth.f32','confidence.u8','rgb.jpg'):
                    (target/name).write_bytes(source.read('frames/0000/'+name))
        (folder/'scan.json').write_text(json.dumps(meta));checksum(folder)
        archive=self.root/'map-v2.zip'
        with zipfile.ZipFile(archive,'w',zipfile.ZIP_DEFLATED) as z:
            for file in folder.rglob('*'):
                if file.is_file():z.write(file,'map-v2/'+file.relative_to(folder).as_posix())
        info=self.store.import_path(archive)
        self.assertEqual(len(info['frames']),101)
        with Scan(folder) as scan:self.assertEqual(scan.meta['schema_version'],2)
        meta['schema_version']=1;(folder/'scan.json').write_text(json.dumps(meta));checksum(folder)
        with self.assertRaises(ValueError):Scan(folder)
    def test_query_schema2_64_frames_and_schema1_24_boundary(self):
        import copy,uuid,zipfile
        from make_lidar_fixture import checksum
        folder=self.root/'query-v2-64';folder.mkdir()
        with Scan(self.root/'fixtures/query.zip') as source:
            meta=copy.deepcopy(source.meta);meta['schema_version']=2
            meta['scan_id']=str(uuid.uuid4());meta['frames']=[]
            for i in range(64):
                frame=copy.deepcopy(source.meta['frames'][0]);frame['index']=i;frame['timestamp']=100+i*.5
                meta['frames'].append(frame)
                target=folder/f'frames/{i:04d}';target.mkdir(parents=True)
                for name in ('depth.f32','confidence.u8','rgb.jpg'):
                    (target/name).write_bytes(source.read('frames/0000/'+name))
        (folder/'scan.json').write_text(json.dumps(meta));checksum(folder)
        archive=self.root/'query-v2-64.zip'
        with zipfile.ZipFile(archive,'w',zipfile.ZIP_DEFLATED) as z:
            for file in folder.rglob('*'):
                if file.is_file():z.write(file,'query/'+file.relative_to(folder).as_posix())
        info=self.store.import_path(archive)
        self.assertEqual(len(info['frames']),64)
        frame=self.client.get(f"/api/scans/{info['id']}/frames/63/cloud")
        self.assertEqual(frame.status_code,200);self.assertGreater(len(frame.data),0);frame.close()
        self.assertEqual(self.client.get(f"/api/scans/{info['id']}/frames/64/cloud").status_code,400)
        # The result store must also keep the final schema-2 frame, not truncate it at 24.
        payload=dict(map_id=self.map_meta['scan_id'],query_id=info['id'],mode='single_frame',frame_index=63,status='rejected',candidates=[])
        self.store.save_result(payload)
        with self.assertRaisesRegex(ValueError,'帧编号'):
            self.store.save_result(dict(payload,frame_index=64))
        invalid=copy.deepcopy(meta);extra=copy.deepcopy(invalid['frames'][-1]);extra['index']=64;extra['timestamp']+=.5;invalid['frames'].append(extra)
        (folder/'scan.json').write_text(json.dumps(invalid));checksum(folder)
        with self.assertRaisesRegex(ValueError,'帧数'):Scan(folder)
        for count,accepted in [(24,True),(25,False)]:
            legacy=copy.deepcopy(meta);legacy['schema_version']=1;legacy['frames']=legacy['frames'][:count]
            (folder/'scan.json').write_text(json.dumps(legacy));checksum(folder)
            if accepted:
                with Scan(folder) as q:self.assertEqual(len(q.meta['frames']),24)
            else:
                with self.assertRaisesRegex(ValueError,'帧数'):Scan(folder)

    def test_origin_and_token_checks(self):
        self.assertEqual(self.client.post("/api/jobs",json={}).status_code,403)
        self.assertEqual(self.client.get("/api/catalog",headers={"Host":"evil.invalid"}).status_code,403)
    def test_corrupt_zip_is_reported_not_registered(self):
        r=self.client.post("/api/import",data={"file":(io.BytesIO(b"not a zip"),"broken.zip")},headers=self.headers)
        self.assertEqual(r.status_code,400)
        r.close();r.request.environ["wsgi.input"].close()
    def test_result_collection_export_import(self):
        result=dict(map_id=self.map_meta["scan_id"],query_id=self.query_meta["scan_id"],status="rejected",reason="test",candidates=[])
        self.store.save_result(result)
        exported=self.client.get("/api/export-results")
        r=self.client.post("/api/import",data={"file":(io.BytesIO(exported.data),"results.json")},headers=self.headers)
        self.assertEqual(r.status_code,200,r.json)
        self.assertTrue(r.json["results"])
        exported.close();r.close()
    def test_single_frame_does_not_use_other_frames(self):
        observed={}
        def fake(mp,qp,held):
            observed["source"]=qp.copy()
            np.testing.assert_equal(qp,held)
            return dict(status="rejected",reason="test",candidates=[]),None
        with patch("lidar_validate.solve",side_effect=fake):
            result=match(self.root/"fixtures/map.zip",self.root/"fixtures/query.zip",3)
        with Scan(self.root/"fixtures/query.zip") as q:
            np.testing.assert_equal(observed["source"],q.points([q.meta["frames"][3]]))
        self.assertEqual(result["mode"],"single_frame")
        self.assertIn("没有独立留出帧",result["evaluation_warning"])
    def test_result_invalid_transform_rejected(self):
        result=dict(map_id=self.map_meta["scan_id"],query_id=self.query_meta["scan_id"],status="candidate_requires_review",candidates=[dict(transform_query_to_map=np.diag([1,1,-1,1]).tolist(),heldout_overlap=.9,heldout_rmse_m=.03,gravity_error_deg=0)])
        with self.assertRaises(ValueError):validate_result(result)
    def test_whole_scan_end_to_end(self):
        result=match(self.root/"fixtures/map.zip",self.root/"fixtures/query.zip")
        self.assertEqual(result["status"],"candidate_requires_review",result)
        np.testing.assert_allclose(np.array(result["best"]["transform_query_to_map"]),self.truth,atol=.03)


class RecordedPhoneTests(unittest.TestCase):
    def setUp(self):
        import uuid
        self.temp=tempfile.TemporaryDirectory();self.root=Path(self.temp.name)
        self.mid=str(uuid.uuid4()).upper();self.qid=str(uuid.uuid4()).upper();self.sid=str(uuid.uuid4()).upper()
        self.store=Store(self.root/'cache')
    def tearDown(self):
        self.store.compute.shutdown(wait=True);self.temp.cleanup()
    def bundle(self,name,files):
        import hashlib,zipfile
        files={k:v if isinstance(v,bytes) else json.dumps(v).encode() for k,v in files.items()}
        files['files.json']=json.dumps(dict(files=[dict(path=k,bytes=len(v),sha256=hashlib.sha256(v).hexdigest()) for k,v in files.items()])).encode()
        path=self.root/name
        with zipfile.ZipFile(path,'w') as z:
            for k,v in files.items():z.writestr('bundle/'+k,v)
        return path
    def result(self):
        return dict(algorithm='gravity_correlative_search_3d_icp_v1',session_id=self.sid,status='ambiguous',reason='test',
            candidates=[dict(transform_query_to_map=np.eye(4).tolist(),overlap=.8,structural_overlap=.75,rmse_m=.08,geometry_score=.7,quality_gate=True)])
    def test_run_import_preserves_candidates_without_calling_match(self):
        payload=self.result()
        source=self.bundle('run.zip',{'run.json':dict(configuration=dict(map_id=self.mid)),
            f'localization-{self.qid}.json':payload,'camera-poses.jsonl':b''})
        with patch('server.match',side_effect=AssertionError('must not recompute')):
            info=self.store.import_path(source)
        self.assertEqual(info['kind'],'run')
        actual=next(iter(self.store.results.values()))
        self.assertEqual(actual['recorded_result'],payload)
        self.assertEqual(actual['candidates'],payload['candidates'])
        self.assertEqual(actual['mode'],'recorded')
        self.assertFalse(actual['recomputable'])
        self.assertFalse(self.store.scans[self.qid]['raw_available'])
        restarted=Store(self.root/'cache');self.assertEqual(len(restarted.results),1);restarted.compute.shutdown()
    def test_runtime_map_and_phone_json_import_and_export(self):
        xyz=np.arange(300,dtype='<f4').reshape(100,3)/100
        nav=dict(map_id=self.mid,session_id=self.sid,name='测试地图',kind='lidar_navigation_map',schema_version=1,
            coordinate_system='ARKit_Y_up_camera_minus_Z_row_major_meters',points_file='geometry.f32',point_count=100)
        nav['schema_version']=2
        self.store.import_path(self.bundle('map.zip',{'navigation.json':nav,'geometry.f32':xyz.tobytes()}))
        info=self.store.scans[self.mid]
        self.assertEqual(info['frames'],[]);self.assertEqual(info['points'],100)
        payload=self.result();payload['provenance']=dict(map_id=self.mid,query_scan_id=self.qid,session_id=self.sid)
        actual=self.store.save_result(payload)
        self.assertEqual(actual['recorded_result'],payload)
        with self.assertRaisesRegex(ValueError,'不可重算'):
            self.store.job(self.mid,self.qid,'whole_scan')
        app=create_app(self.store);client=app.test_client();headers={'X-Viewer-Token':app.config['TOKEN']}
        exported=client.get('/api/export-results')
        response=client.post('/api/import',data={'file':(io.BytesIO(exported.data),'results.json')},headers=headers)
        self.assertEqual(response.status_code,200,response.json)
        self.assertEqual(response.json['results'][0]['recorded_result'],payload)
        exported.close();response.close()
    def test_landmark_archive_displays_unknown_without_invented_position(self):
        import hashlib,uuid
        from PIL import Image
        ident=str(uuid.uuid4());xyz=np.zeros((100,3),dtype='<f4');raw=xyz.tobytes()
        nav=dict(map_id=self.mid,session_id=self.sid,name='含门牌的界面样本',kind='lidar_navigation_map',schema_version=2,
            coordinate_system='ARKit_Y_up_camera_minus_Z_row_major_meters',points_file='geometry.f32',point_count=100)
        output=io.BytesIO();Image.new('RGB',(60,30),'white').save(output,format='JPEG')
        crop=f'landmarks/{ident}/crop.jpg'
        landmark=dict(id=ident,category='room_plate',trigger='manual',text=dict(raw='1309',normalized='1309',confirmed_by_user=True),
            destination=dict(enabled=False,node_id=None),geometry=dict(status='unknown',center=None,normal=None,reason='too_few_measured_frames'),evidence=[],best_crop=crop)
        data=dict(kind='lidar_landmarks',schema_version=1,map_id=self.mid,coordinate_system=nav['coordinate_system'],geometry_sha256=hashlib.sha256(raw).hexdigest(),landmarks=[landmark])
        source=self.bundle('landmarks.zip',{'navigation.json':nav,'geometry.f32':raw,'landmarks.json':data,crop:output.getvalue()})
        info=self.store.import_path(source)
        self.assertTrue(info['landmarks'][0]['has_image'])
        self.assertIsNone(info['landmarks'][0]['geometry']['center'])
        client=create_app(self.store).test_client();response=client.get(f'/api/scans/{self.mid}/landmarks/{ident}/image')
        self.assertEqual(response.mimetype,'image/jpeg');self.assertEqual(response.data,output.getvalue());response.close()
        landmark['geometry']=dict(status='measured',center=dict(x=1,y=2,z=3),normal=dict(x=1,y=0,z=0),observations=3,reason='synthetic_test_only')
        updated=self.store.import_path(self.bundle('landmarks-revised.zip',{'navigation.json':nav,'geometry.f32':raw,'landmarks.json':data,crop:output.getvalue()}))
        self.assertEqual(updated['landmarks'][0]['geometry']['center'],[1,2,3])
        landmark['display_name']='研讨室 132'
        named=self.store.import_path(self.bundle('landmarks-named.zip',{'navigation.json':nav,'geometry.f32':raw,'landmarks.json':data,crop:output.getvalue()}))
        self.assertEqual(named['landmarks'][0]['display_name'],'研讨室 132')
        self.assertEqual(named['landmarks'][0]['text']['raw'],'1309')
        landmark['display_name']='   '
        with self.assertRaisesRegex(ValueError,'名称无效'):
            self.store.import_path(self.bundle('landmarks-empty-name.zip',{'navigation.json':nav,'geometry.f32':raw,'landmarks.json':data,crop:output.getvalue()}))
        landmark['display_name']='研讨室 132'

        data['geometry_sha256']='0'*64
        with self.assertRaisesRegex(ValueError,'另一份几何'):
            self.store.import_path(self.bundle('bad-landmark-hash.zip',{'navigation.json':nav,'geometry.f32':raw,'landmarks.json':data,crop:output.getvalue()}))
        data['geometry_sha256']=hashlib.sha256(raw).hexdigest();landmark['best_crop']='../crop.jpg'
        with self.assertRaises(ValueError):
            self.store.import_path(self.bundle('bad-landmark-path.zip',{'navigation.json':nav,'geometry.f32':raw,'landmarks.json':data,'crop.jpg':output.getvalue()}))
    def test_scoped_phone_result_preserves_all_tiers(self):
        import copy
        from engine import recorded_result
        payload=self.result()
        payload['search_scope']=dict(candidate_radius_m=15,center_node_id='start',tiers_tried=2)
        first=copy.deepcopy(payload);first['search_scope']['candidate_radius_m']=10
        payload['search_tiers']=[first,copy.deepcopy(payload)]
        actual=recorded_result(payload,self.mid,self.qid)
        self.assertEqual(actual['search_tiers'],payload['search_tiers'])
        self.assertEqual(actual['recorded_result'],payload)
        self.assertEqual(actual['search_scope']['candidate_radius_m'],15)
    def test_tampered_run_is_rejected(self):
        import zipfile
        source=self.bundle('bad.zip',{'run.json':dict(configuration=dict(map_id=self.mid)),f'localization-{self.qid}.json':self.result()})
        with zipfile.ZipFile(source,'a') as z:z.writestr('bundle/extra.txt','unlisted')
        with self.assertRaises(ValueError):self.store.import_path(source)
    def test_recorded_result_requires_context_and_rejects_invalid_pose(self):
        from engine import recorded_result
        with self.assertRaises(ValueError):recorded_result(self.result())
        bad=self.result();bad['candidates'][0]['transform_query_to_map']=np.diag([1,1,-1,1]).tolist()
        with self.assertRaises(ValueError):recorded_result(bad,self.mid,self.qid)

if __name__=="__main__":unittest.main()
