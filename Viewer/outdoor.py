"""Whole-campus work copies. No source assets or phone libraries are modified."""
import copy
from datetime import datetime, timezone
import hashlib
import json
import math
from pathlib import Path
import threading
import uuid

from flask import Response, jsonify, request
from werkzeug.exceptions import Conflict

ROOT = Path(__file__).resolve().parent
MAX_BYTES = 32 * 1024 * 1024


def encoded(value):
    return json.dumps(value, ensure_ascii=False, allow_nan=False, indent=2).encode('utf-8')


def parse(raw):
    if len(raw) > MAX_BYTES:
        raise ValueError('校园地图超过32MB')
    def invalid(v): raise ValueError('JSON含有非有限数值：'+v)
    def finite_float(v):
        value=float(v)
        if not math.isfinite(value):raise ValueError('JSON含有超出范围的数值')
        return value
    return json.loads(raw, parse_constant=invalid, parse_float=finite_float)


def number(x): return isinstance(x, (int, float)) and not isinstance(x, bool) and math.isfinite(x)
def integer(x): return isinstance(x, int) and not isinstance(x, bool)
def coordinate(p): return isinstance(p, list) and len(p) == 2 and all(number(x) for x in p) and abs(p[0]) <= 90 and abs(p[1]) <= 180


class Frame:
    def __init__(self, origin):
        self.origin = origin
        p = math.radians(origin[0])
        self.lat = 111132.92-559.82*math.cos(2*p)+1.175*math.cos(4*p)
        self.lon = 111412.84*math.cos(p)-93.5*math.cos(3*p)
    def local(self, p): return ((p[1]-self.origin[1])*self.lon, (p[0]-self.origin[0])*self.lat)
    def geo(self, p): return [self.origin[0]+p[1]/self.lat, self.origin[1]+p[0]/self.lon]
    def distance(self, a, b): return math.dist(self.local(a), self.local(b))


def project(p, a, b):
    dx, dy = b[0]-a[0], b[1]-a[1]
    d = dx*dx+dy*dy
    t = max(0, min(1, ((p[0]-a[0])*dx+(p[1]-a[1])*dy)/d)) if d else 0
    q = (a[0]+t*dx, a[1]+t*dy)
    return q, t, math.dist(p, q)


def intersection(a, b, c, d):
    dx, dy, ex, ey = b[0]-a[0], b[1]-a[1], d[0]-c[0], d[1]-c[1]
    cross = dx*ey-dy*ex
    if abs(cross) < 1e-9: return None
    px, py = c[0]-a[0], c[1]-a[1]
    t, u = (px*ey-py*ex)/cross, (px*dy-py*dx)/cross
    if -1e-8 <= t <= 1+1e-8 and -1e-8 <= u <= 1+1e-8:
        return max(0,min(1,t)), max(0,min(1,u)), (a[0]+t*dx, a[1]+t*dy)
    return None


def parts(b): return b.get('parts') if b.get('parts') is not None else [b['ring']]
def open_ring(r): return r[:-1] if len(r) > 1 and r[0] == r[-1] else r


def check_ring(r, frame):
    if not isinstance(r, list) or not 3 <= len(r) <= 2000 or not all(coordinate(p) for p in r):
        raise ValueError('楼栋轮廓需要3–2000个有效经纬度点')
    p = [frame.local(x) for x in open_ring(r)]
    if len(p) < 3 or len(set(p)) != len(p): raise ValueError('轮廓含重复顶点')
    area = abs(sum(a[0]*b[1]-b[0]*a[1] for a,b in zip(p,p[1:]+p[:1])))/2
    if area <= .01: raise ValueError('轮廓没有有效面积')
    for i in range(len(p)):
        for j in range(i+1,len(p)):
            if j == i+1 or (i == 0 and j == len(p)-1): continue
            if intersection(p[i],p[(i+1)%len(p)],p[j],p[(j+1)%len(p)]): raise ValueError('楼栋轮廓自交，请重新绘制')
    return area


def components(graph):
    parent = list(range(len(graph['nodes'])))
    def find(i):
        while parent[i] != i: parent[i] = parent[parent[i]];i = parent[i]
        return i
    for e in graph['edges']: parent[find(e[0])] = find(e[1])
    return len({find(i) for i in range(len(parent))})


def validate(d, require_connected=False):
    if not isinstance(d, dict) or not integer(d.get('v')) or d['v'] <= 0: raise ValueError('不是受支持的campus.json')
    meta = d.get('meta', {})
    if not isinstance(meta,dict) or not all(isinstance(meta.get(k),str) for k in ('name','source')) or not coordinate(meta.get('origin')) or abs(meta['origin'][0]) >= 85:
        raise ValueError('地图名称、来源或坐标原点无效')
    if not isinstance(d.get('campusRing'),list) or len(d['campusRing']) < 3 or not all(coordinate(p) for p in d['campusRing']): raise ValueError('校园边界无效')
    f = Frame(meta['origin']);g = d.get('graph', {});nodes = g.get('nodes', []);edges = g.get('edges', [])
    if not isinstance(nodes,list) or not 1 <= len(nodes) <= 200000 or not all(coordinate(p) for p in nodes) or not isinstance(edges,list) or len(edges) > 500000: raise ValueError('路网点数据无效')
    for e in edges:
        if not isinstance(e,list) or len(e) != 6 or not all(integer(x) and 0 <= x < len(nodes) for x in e[:2]) or e[0] == e[1] or not all(number(x) for x in e[2:4]) or e[2] <= 0 or e[3] < 1 or not all(isinstance(x,str) for x in e[4:]): raise ValueError('路网边索引、长度或权重无效')
    buildings = d.get('buildings')
    if not isinstance(buildings,list) or len(buildings) > 20000: raise ValueError('楼栋列表无效')
    ids = set();vertices = 0
    for b in buildings:
        if not isinstance(b,dict) or not isinstance(b.get('osm'),str) or not b['osm'] or b['osm'] in ids: raise ValueError('楼栋编号为空或重复')
        ids.add(b['osm'])
        if not all(isinstance(b.get(k,''),str) for k in ('name','short')) or not coordinate(b.get('centroid')): raise ValueError('楼栋名称或中心无效')
        if b.get('rank') is not None and (not integer(b['rank']) or not 1 <= b['rank'] <= 5): raise ValueError('楼栋等级必须为1–5')
        rings = parts(b)
        if not isinstance(rings,list) or not 1 <= len(rings) <= 64 or rings[0] != b.get('ring'): raise ValueError('多部件楼的主轮廓与ring不一致')
        for r in rings: check_ring(r,f);vertices += len(r)
        if vertices > 100000: raise ValueError('楼栋轮廓点总量超过上限')
        for door in b.get('doors',[]):
            if not coordinate(door.get('pos')) or not integer(door.get('node')) or not 0 <= door['node'] < len(nodes) or not number(door.get('dist',0)) or door.get('dist',0) < 0: raise ValueError('楼门的路网接入点无效')
        if not b.get('doors') and b.get('door') is not None:
            if not coordinate(b['door']) or not integer(b.get('doorNode')) or not 0 <= b['doorNode'] < len(nodes): raise ValueError('旧版楼门索引无效')
    for road in d.get('roads',[]):
        if not all(coordinate(p) for p in road.get('p',[])): raise ValueError('步道坐标无效')
    for area in d.get('areas',[]):
        if not all(coordinate(p) for p in area.get('ring',[])): raise ValueError('底图区域坐标无效')
    count = components(g)
    if require_connected and count != 1: raise ValueError(f'步行路网分成{count}块，请补齐连接后再导出')
    return dict(buildings=len(buildings),nodes=len(nodes),edges=len(edges),components=count,multipart=sum(len(parts(b))>1 for b in buildings))


def stamp(d):
    meta = d['meta'];old = meta.get('version',0)
    meta['version'] = (old if integer(old) and old >= 0 else 0)+1
    meta['edited_utc'] = datetime.now(timezone.utc).isoformat()


def refresh_geometry(b, f):
    rings = parts(b);areas = [check_ring(r,f) for r in rings]
    centers = []
    for r in rings:
        p = [f.local(x) for x in open_ring(r)];a = sum(u[0]*v[1]-v[0]*u[1] for u,v in zip(p,p[1:]+p[:1]))
        centers.append((sum((u[0]+v[0])*(u[0]*v[1]-v[0]*u[1]) for u,v in zip(p,p[1:]+p[:1]))/(3*a),sum((u[1]+v[1])*(u[0]*v[1]-v[0]*u[1]) for u,v in zip(p,p[1:]+p[:1]))/(3*a)))
    b['ring'] = rings[0];b['area'] = sum(areas)
    b['centroid'] = f.geo(tuple(sum(p[k]*a for p,a in zip(centers,areas))/sum(areas) for k in (0,1)))


def update_doors(b, doors):
    unique = {};[unique.setdefault((tuple(x['pos']),x['node']),x) for x in doors]
    b['doors'] = list(unique.values())
    for k in ('door','doorNode','doorDist','doorSource'): b.pop(k,None)
    if b['doors']:
        p = b['doors'][0];b.update(door=p['pos'],doorNode=p['node'],doorDist=p.get('dist',0),doorSource=p.get('source','editor'))


def all_doors(b):
    return b.get('doors') or ([dict(pos=b['door'],node=b['doorNode'],dist=b.get('doorDist',0),source='legacy')] if b.get('door') is not None else [])


def suggest_door(b,d,f):
    best = None
    for i,node in enumerate(d['graph']['nodes']):
        p = f.local(node)
        for r in parts(b):
            ring = [f.local(x) for x in open_ring(r)]
            for a,c in zip(ring,ring[1:]+ring[:1]):
                q,_,distance = project(p,a,c)
                if best is None or distance < best[0]: best = (distance,i,q)
    if best: update_doors(b,[dict(pos=f.geo(best[2]),node=best[1],dist=best[0],source='editor_suggested')])


def add_path(d, line, name, snap=3.0):
    if not isinstance(line,list) or not 2 <= len(line) <= 500 or not all(coordinate(p) for p in line): raise ValueError('步道需要2–500个点')
    f = Frame(d['meta']['origin']);g = d['graph'];old_count = len(g['nodes']);xy = [f.local(p) for p in g['nodes']];points = [f.local(p) for p in line]
    cuts = {i:[(0,e[0]),(1,e[1])] for i,e in enumerate(g['edges'])};attached = False
    def node(p):
        best = min(range(len(xy)),key=lambda i: math.dist(p,xy[i]))
        if math.dist(p,xy[best]) <= .20: return best
        xy.append(p);g['nodes'].append(f.geo(p));return len(xy)-1
    endpoints = {}
    for at in (0,len(points)-1):
        choices = [(project(points[at],xy[e[0]],xy[e[1]]),i) for i,e in enumerate(g['edges'])]
        if choices:
            (q,t,dist),edge = min(choices,key=lambda x:x[0][2])
            if dist <= snap: points[at] = q;endpoints[at] = (edge,t);attached = True
    indices = [node(p) for p in points]
    for at,(edge,t) in endpoints.items(): cuts[edge].append((t,indices[at]))
    path_cuts = [[(0,indices[i]),(1,indices[i+1])] for i in range(len(points)-1)]
    for i,(a,b) in enumerate(zip(points,points[1:])):
        for j,e in enumerate(g['edges']):
            hit = intersection(a,b,xy[e[0]],xy[e[1]])
            if hit:
                t,u,p = hit;k = node(p);path_cuts[i].append((t,k));cuts[j].append((u,k));attached = True
        for j in range(i):
            hit = intersection(a,b,points[j],points[j+1])
            if hit:
                t,u,p = hit;k = node(p);path_cuts[i].append((t,k));path_cuts[j].append((u,k))
    if not attached: raise ValueError('新步道没有接到路网。请把至少一个端点画到现有步道3米以内，或穿过现有路网。')
    edges=[];pairs=set()
    def add(a,b,kind,label,factor=1,length=None,extra=None):
        if a == b or math.dist(xy[a],xy[b]) < .001: return
        pairs.add(tuple(sorted((a,b))))
        edges.append([a,b,math.dist(xy[a],xy[b]) if length is None else length,factor,kind,label])
    for i,e in enumerate(g['edges']):
        ordered=sorted(set(cuts[i]))
        for a,b in zip(ordered,ordered[1:]):
            # Preserve original weighted distance, including unsplit/parallel edges.
            if b[0]-a[0]>1e-9:add(a[1],b[1],e[4],e[5],e[3],e[2]*(b[0]-a[0]))
    for cut in path_cuts:
        ordered=sorted(set(cut))
        for a,b in zip(ordered,ordered[1:]):
            if tuple(sorted((a[1],b[1]))) not in pairs:add(a[1],b[1],'footway',name)
    g['edges']=edges
    adj=[[] for _ in xy]
    for e in edges:adj[e[0]].append(e[1]);adj[e[1]].append(e[0])
    reached=set(range(old_count));pending=list(reached)
    while pending:
        for v in adj[pending.pop()]:
            if v not in reached:reached.add(v);pending.append(v)
    if len(reached)!=len(xy): raise ValueError('新步道存在未接入的部分，未采用本次绘制')
    d.setdefault('roads',[]).append(dict(k='footway',n=name,p=[f.geo(p) for p in points],source='workbench'))


def edit(source, op):
    validate(source);d=copy.deepcopy(source);f=Frame(d['meta']['origin']);kind=op.get('kind')
    def building(ident):
        found=next((b for b in d['buildings'] if b['osm']==ident),None)
        if found is None:raise ValueError('楼栋已不存在，请重新选择')
        return found
    changes=d['meta'].setdefault('editor_changes',{})
    if kind=='properties':
        b=building(op.get('id'));name=op.get('name','').strip();short=op.get('short','').strip();rank=op.get('rank')
        if len(name)>120 or len(short)>60 or not integer(rank) or not 1<=rank<=5:raise ValueError('名称过长或等级不在1–5之间')
        b.update(name=name,short=short,rank=rank)
    elif kind=='add_building':
        r=op.get('ring');check_ring(r,f);b=dict(osm='local:'+str(uuid.uuid4()),name=op.get('name','新楼栋'),short='',rank=3,ring=r,centroid=r[0],campus=True,walkThrough=False,doors=[],source='workbench')
        refresh_geometry(b,f);suggest_door(b,d,f);d['buildings'].append(b)
    elif kind=='delete':
        b=building(op.get('id'));d['buildings'].remove(b);changes.setdefault('removed_ids',[]).append(b['osm'])
    elif kind=='merge':
        a=building(op.get('primary'));b=building(op.get('secondary'))
        if a is b:raise ValueError('请选择两栋不同的楼')
        combined=parts(a)+parts(b)
        if len(combined)>64:raise ValueError('合并后的部件超过64个')
        a['parts']=combined;refresh_geometry(a,f);update_doors(a,all_doors(a)+all_doors(b));d['buildings'].remove(b)
        changes.setdefault('merged_into',{})[b['osm']]=a['osm']
    elif kind=='split':
        a=building(op.get('id'));rings=parts(a);index=op.get('part')
        if not integer(index) or len(rings)<2 or not 0<=index<len(rings):raise ValueError('只能从多部件楼拆出一个现有部件')
        selected=rings[index];remaining=rings[:index]+rings[index+1:];b=copy.deepcopy(a);b.update(osm='local:'+str(uuid.uuid4()),name=a.get('name','')+'（拆分）',short='',parts=[selected],ring=selected)
        a['parts']=remaining;a['ring']=remaining[0];refresh_geometry(a,f);refresh_geometry(b,f)
        def distance(door,rings):
            p=f.local(door['pos']);return min(project(p,f.local(u),f.local(v))[2] for r in rings for u,v in zip(open_ring(r),open_ring(r)[1:]+open_ring(r)[:1]))
        old=all_doors(a);moved=[door for door in old if distance(door,[selected])<distance(door,remaining)]
        update_doors(b,moved);update_doors(a,[door for door in old if door not in moved]);d['buildings'].append(b)
        if not all_doors(b):suggest_door(b,d,f)
        changes.setdefault('split',[]).append(dict(source=a['osm'],created=b['osm']))
    elif kind=='path':add_path(d,op.get('points'),str(op.get('name','补充步道'))[:120])
    else:raise ValueError('编辑操作无效')
    stamp(d);report=validate(d)
    return d,report


class OutdoorStore:
    def __init__(self, root):
        self.root=Path(root)/'outdoor';self.root.mkdir(exist_ok=True);self.lock=threading.RLock();self.file=self.root/'campus.json'
    def data(self):return self.file.read_bytes() if self.file.exists() else (ROOT.parent/'Assets/Outdoor/campus.json').read_bytes()
    def state(self):
        raw=self.data();d=parse(raw);return dict(campus=d,report=validate(d),revision=hashlib.sha256(raw).hexdigest())
    def save(self,d,revision=None,connected=True):
        with self.lock:
            current=self.data()
            if revision is not None and hashlib.sha256(current).hexdigest()!=revision:raise Conflict('工作副本已被另一页面修改，请导出当前草稿后重新加载')
            validate(d,connected);stamp(d);raw=encoded(d)
            if len(raw)>MAX_BYTES:raise ValueError('校园地图超过32MB')
            if self.file.exists():(self.root/'previous.json').write_bytes(current)
            pending=self.root/(uuid.uuid4().hex+'.partial');pending.write_bytes(raw);pending.replace(self.file)
            return self.state()


def register_outdoor_routes(app,store):
    outdoor=OutdoorStore(store.root);app.extensions['outdoor_store']=outdoor
    @app.get('/outdoor')
    def page():return Response((ROOT/'web/outdoor.html').read_text().replace('__VIEWER_TOKEN__',app.config['TOKEN']),mimetype='text/html')
    @app.get('/api/outdoor/state')
    def state():return jsonify(outdoor.state())
    @app.get('/api/outdoor/bundled')
    def bundled():
        d=parse((ROOT.parent/'Assets/Outdoor/campus.json').read_bytes());return jsonify(campus=d,report=validate(d))
    @app.post('/api/outdoor/import')
    def load():
        upload=request.files.get('file')
        if upload is None:raise ValueError('请选择campus.json')
        d=parse(upload.stream.read(MAX_BYTES+1));return jsonify(campus=d,report=validate(d))
    @app.post('/api/outdoor/edit')
    def modify():
        if request.content_length and request.content_length>MAX_BYTES:raise ValueError('请求超过32MB')
        body=request.get_json();d,report=edit(body.get('campus'),body.get('operation',{}));return jsonify(campus=d,report=report)
    @app.post('/api/outdoor/save')
    def save():
        if request.content_length and request.content_length>MAX_BYTES:raise ValueError('请求超过32MB')
        body=request.get_json();return jsonify(outdoor.save(body.get('campus'),body.get('revision')))
    @app.post('/api/outdoor/export')
    def export():
        if request.content_length and request.content_length>MAX_BYTES:raise ValueError('请求超过32MB')
        d=request.get_json().get('campus');validate(d,True);stamp(d);raw=encoded(d)
        if len(raw)>MAX_BYTES:raise ValueError('校园地图超过32MB')
        return Response(raw,mimetype='application/json',headers={'Content-Disposition':'attachment; filename="campus.json"'})
