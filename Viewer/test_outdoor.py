import copy
import io
import json
from pathlib import Path
import tempfile
import unittest
from outdoor import Frame, OutdoorStore, add_path, edit, encoded, parse, validate
from server import Store, create_app

ASSET=Path(__file__).resolve().parents[1]/'Assets/Outdoor/campus.json'

def fixture():
    f=Frame([31,121]);p=lambda x,y:f.geo((x,y))
    return dict(v=2,meta=dict(name='test',source='synthetic',origin=[31,121]),campusRing=[p(-20,-20),p(100,-20),p(100,80),p(-20,80)],buildings=[dict(osm='a',name='A',short='A',centroid=p(5,15),ring=[p(0,10),p(10,10),p(10,20),p(0,20)],doors=[dict(pos=p(5,10),node=0,dist=5)]),dict(osm='b',name='B',short='B',centroid=p(35,15),ring=[p(30,10),p(40,10),p(40,20),p(30,20)],doors=[dict(pos=p(35,10),node=1,dist=5)])],graph=dict(nodes=[p(0,0),p(40,0)],edges=[[0,1,50,1.2,'footway','old']]),future_field={'untouched':True})

class OutdoorTests(unittest.TestCase):
    def test_nonfinite_values_rejected_even_in_unknown_metadata(self):
        for raw in [b'{"future": 1e999}', b'{"future": NaN}']:
            with self.assertRaises(ValueError):parse(raw)
    def test_real_asset_and_invalid_rank(self):
        self.assertEqual(validate(json.loads(ASSET.read_bytes()))['buildings'],88)
        for bad in [0,6,True,3.5]:
            d=fixture();d['buildings'][0]['rank']=bad
            with self.assertRaises(ValueError):validate(d)
    def test_merge_split_stable_ids_and_doors(self):
        d=fixture();merged,r=edit(d,dict(kind='merge',primary='a',secondary='b'))
        self.assertEqual(r['multipart'],1);self.assertEqual(merged['buildings'][0]['osm'],'a');self.assertEqual(len(merged['buildings'][0]['doors']),2)
        result,r=edit(merged,dict(kind='split',id='a',part=1));a,b=result['buildings']
        self.assertEqual(a['osm'],'a');self.assertTrue(b['osm'].startswith('local:'));self.assertEqual(b['doors'][0]['node'],1);self.assertEqual(a['doors'][0]['node'],0)
        self.assertEqual(result['future_field'],d['future_field']);self.assertEqual(len(d['buildings']),2)
    def test_path_weld_split_preserve_indices_costs_parallel_edges(self):
        d=fixture();f=Frame(d['meta']['origin']);old=copy.deepcopy(d['graph']['nodes'])
        d['graph']['edges'].append([0,1,60,2,'service','parallel'])
        add_path(d,[f.geo((20,1)),f.geo((20,30))],'new')
        self.assertEqual(d['graph']['nodes'][:2],old);self.assertEqual(validate(d)['components'],1)
        self.assertAlmostEqual(sum(e[2] for e in d['graph']['edges'] if e[5]=='old'),50)
        self.assertAlmostEqual(sum(e[2] for e in d['graph']['edges'] if e[5]=='parallel'),60)
        for b in d['buildings']:self.assertIn(b['doors'][0]['node'],[0,1])
    def test_crossing_creates_shared_junction_and_rejects_island(self):
        d=fixture();f=Frame(d['meta']['origin']);add_path(d,[f.geo((20,-20)),f.geo((20,30))],'cross')
        self.assertEqual(validate(d)['components'],1)
        with self.assertRaises(ValueError):edit(d,dict(kind='path',points=[f.geo((200,200)),f.geo((240,200))]))
        self.assertEqual(validate(d)['components'],1)
    def test_invalid_geometry_does_not_mutate_source(self):
        d=fixture();before=encoded(d);f=Frame(d['meta']['origin'])
        with self.assertRaises(ValueError):edit(d,dict(kind='add_building',ring=[f.geo((0,0)),f.geo((10,10)),f.geo((10,0)),f.geo((0,10))]))
        self.assertEqual(encoded(d),before)
    def test_http_whole_file_export_save_cas_and_draft_import(self):
        with tempfile.TemporaryDirectory() as tmp:
            store=Store(Path(tmp)/'viewer');app=create_app(store);c=app.test_client();h={'X-Viewer-Token':app.config['TOKEN']}
            try:
                state=c.get('/api/outdoor/state').get_json();rev=state['revision'];d=fixture()
                self.assertEqual(c.post('/api/outdoor/save',json={'campus':d}).status_code,403)
                loaded=c.post('/api/outdoor/import',headers=h,data={'file':(io.BytesIO(encoded(d)),'campus.json')}).get_json()
                self.assertEqual(loaded['report']['buildings'],2)
                self.assertEqual(c.get('/api/outdoor/state').get_json()['revision'],rev) # import is a draft
                saved=c.post('/api/outdoor/save',headers=h,json={'campus':d,'revision':rev});self.assertEqual(saved.status_code,200)
                self.assertEqual(c.post('/api/outdoor/save',headers=h,json={'campus':d,'revision':rev}).status_code,409)
                exported=c.post('/api/outdoor/export',headers=h,json={'campus':d});self.assertEqual(exported.status_code,200)
                self.assertEqual(exported.get_json()['future_field'],d['future_field'])
                broken=copy.deepcopy(d);broken['graph']['nodes'].append([31.1,121.1]);before=c.get('/api/outdoor/state').get_json()['revision']
                self.assertEqual(c.post('/api/outdoor/save',headers=h,json={'campus':broken}).status_code,400)
                self.assertEqual(c.get('/api/outdoor/state').get_json()['revision'],before)
                self.assertEqual(c.post('/api/outdoor/export',headers=h,json={'campus':broken}).status_code,400)
                self.assertEqual(c.get('/outdoor').status_code,200)
            finally:store.compute.shutdown(wait=True)

if __name__=='__main__':unittest.main()
