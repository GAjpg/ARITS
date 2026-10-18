"""Point-cloud decoding and pose review. No browser or UI dependencies."""
import io
import json
import hashlib
import stat
import zipfile
import uuid
from pathlib import Path
import sys
import numpy as np
from PIL import Image

sys.path.insert(0, str(Path(__file__).resolve().parents[1]/"Tools"))
from lidar_data import Scan, validate_transform, require_independent, safe_name, MAX_BYTES, MAX_BYTES_V2, FRAME_LIMITS


def decode_frame(scan, frame, pixel_stride=4):
    c = frame["calibration"]
    folder = f"frames/{frame['index']:04d}"
    depth = np.frombuffer(scan.read(folder+"/depth.f32"), dtype="<f4").reshape(c["height"], c["width"])
    confidence = np.frombuffer(scan.read(folder+"/confidence.u8"), dtype="u1").reshape(depth.shape)
    v, u = np.mgrid[0:c["height"]:pixel_stride, 0:c["width"]:pixel_stride]
    z = depth[::pixel_stride, ::pixel_stride]
    valid = np.isfinite(z) & (z >= 0.2) & (z <= 4.5) & (confidence[::pixel_stride, ::pixel_stride] >= 1) & (confidence[::pixel_stride, ::pixel_stride] <= 2)
    sx, sy = c["width"]/c["image_width"], c["height"]/c["image_height"]
    p = np.stack([(u[valid]-c["cx"]*sx)/(c["fx"]*sx)*z[valid], -(v[valid]-c["cy"]*sy)/(c["fy"]*sy)*z[valid], -z[valid]], axis=1)
    t = validate_transform(frame["camera_to_session"])
    p = p@t[:3, :3].T+t[:3, 3]
    with Image.open(io.BytesIO(scan.read(folder+"/rgb.jpg"))) as image:
        image.draft("RGB", (c["width"], c["height"]))
        image = image.convert("RGB").resize((c["width"], c["height"]), Image.Resampling.BILINEAR)
        rgb = np.asarray(image)[v[valid], u[valid]].astype(np.float32)/255
    # Three.js vertex colors are linear RGB, while JPEG is sRGB.
    rgb = np.where(rgb <= 0.04045, rgb/12.92, ((rgb+0.055)/1.055)**2.4)
    return np.ascontiguousarray(np.concatenate([p, rgb], axis=1), dtype="<f4")


def decode_cloud(scan, limit=220000):
    clouds = [decode_frame(scan, f) for f in scan.meta["frames"]]
    if not clouds:
        return np.empty((0, 6), dtype="<f4")
    cloud = np.concatenate(clouds)
    if len(cloud):
        # This cap affects display only. The registration engine reads raw depth.
        _, indices = np.unique(np.floor(cloud[:, :3]/0.04).astype(np.int32), axis=0, return_index=True)
        indices.sort()
        if len(indices) > limit:
            indices = indices[np.linspace(0, len(indices)-1, limit, dtype=int)]
        cloud = cloud[indices]
    return np.ascontiguousarray(cloud, dtype="<f4")


def recorded_result(payload, map_id=None, query_id=None, source_sha256=None):
    """Presentation envelope; original candidate data is never recomputed."""
    original = payload.get("recorded_result", payload)
    provenance = original.get("provenance") or {}
    mid = provenance.get("map_id") or map_id or payload.get("map_id")
    qid = provenance.get("query_scan_id") or query_id or payload.get("query_id")
    if not mid or not qid:
        raise ValueError("手机旧结果缺少地图或查询编号，请导入包含它的导航run ZIP")
    result = dict(original)
    result.update(map_id=mid, query_id=qid, mode="recorded", recorded_result=original,
                  recorded_json_sha256=source_sha256 or payload.get("recorded_json_sha256"),
                  pose_meaning="query_session_to_map; origin is NOT the camera without camera_to_session",
                  recomputable=False)
    return validate_result(result)


def validate_result(result):
    for k in ("map_id", "query_id"):
        uuid.UUID(result[k])
    native = result.get("mode") == "recorded"
    allowed = ("candidate_requires_review", "ambiguous", "rejected", "timeout", "cancelled") if native else ("candidate_requires_review", "ambiguous", "rejected")
    if result.get("status") not in allowed:
        raise ValueError("不支持的配准结果状态")
    candidates = result.get("candidates", [])
    if not isinstance(candidates,list) or len(candidates) > 64:
        raise ValueError("候选数量过多或格式错误")
    for candidate in candidates:
        validate_transform(candidate["transform_query_to_map"])
        names = ("overlap", "rmse_m") if native else ("heldout_overlap", "heldout_rmse_m", "gravity_error_deg")
        for name in names:
            value = candidate.get(name)
            if not isinstance(value, (int, float)) or not np.isfinite(value):
                raise ValueError("候选指标无效")
        overlap = candidate["overlap" if native else "heldout_overlap"]
        rmse = candidate["rmse_m" if native else "heldout_rmse_m"]
        if not 0 <= overlap <= 1 or rmse < 0:
            raise ValueError("候选指标超出范围")
    json.dumps(result, allow_nan=False)
    return result


def bundle_kind(path):
    with zipfile.ZipFile(path) as z:
        basenames = {Path(n).name for n in z.namelist()}
    if "scan.json" in basenames:
        return "raw"
    if "navigation.json" in basenames:
        return "navigation"
    if "run.json" in basenames:
        return "run"
    raise ValueError("不是原始扫描、导航地图或导航run ZIP")


def read_landmarks(read, names, map_id, geometry_hash=None):
    """Presentation-only metadata from an already checksum-verified container."""
    if 'landmarks.json' not in names:
        return [], {}
    data=json.loads(read('landmarks.json'))
    if data.get('kind')!='lidar_landmarks' or data.get('schema_version')!=1 or data.get('map_id')!=map_id or data.get('coordinate_system')!='ARKit_Y_up_camera_minus_Z_row_major_meters':
        raise ValueError('门牌数据与地图不匹配')
    if geometry_hash and data.get('geometry_sha256') and geometry_hash!=data['geometry_sha256']:
        raise ValueError('门牌测量引用了另一份几何')
    items=data.get('landmarks',[])
    if not isinstance(items,list) or len(items)>500:
        raise ValueError('门牌数量无效')
    seen=set(); assets={}
    for item in items:
        ident=item['id'];uuid.UUID(ident)
        if ident in seen:raise ValueError('门牌编号重复')
        seen.add(ident)
        if item.get('category') not in ('room_plate','reference_feature') or item.get('trigger') not in ('manual','auto'):
            raise ValueError('门牌类别无效')
        text=item.get('text',{})
        if not isinstance(text.get('raw'),str) or len(text['raw'])>200:raise ValueError('门牌文字无效')
        if item['category']=='room_plate' and (item['trigger']!='manual' or text.get('confirmed_by_user') is not True):
            raise ValueError('门牌必须人工确认')
        display=item.get('display_name')
        if display is not None and (not isinstance(display,str) or not display.strip() or display!=display.strip() or len(display)>120):raise ValueError('门牌名称无效')
        geometry=item.get('geometry',{})
        if geometry.get('status') not in ('measured','unknown'):raise ValueError('门牌三维状态无效')
        if geometry['status']=='measured':
            for name in ('center','normal'):
                vector=geometry.get(name)
                # ProbePoint encodes as an XYZ object in navigation files.
                if isinstance(vector,dict):vector=[vector.get(k) for k in ('x','y','z')]
                if not isinstance(vector,list) or len(vector)!=3 or any(not isinstance(v,(int,float)) or not np.isfinite(v) or abs(v)>=1000 for v in vector):
                    raise ValueError('门牌三维数据无效')
                geometry[name]=vector
        for evidence in item.get('evidence',[]):
            for key in ('image_file','depth_file','confidence_file'):
                path=evidence.get(key)
                if path is not None and (not safe_name(path).startswith('landmarks/') or path not in names):raise ValueError('门牌证据路径无效')
        crop=item.get('best_crop')
        if crop:
            if not safe_name(crop).startswith('landmarks/') or crop not in names:raise ValueError('门牌图片路径无效')
            raw=read(crop)
            if len(raw)>8_388_608:raise ValueError('门牌图片过大')
            with Image.open(io.BytesIO(raw)) as image:
                if image.format!='JPEG' or image.width*image.height>24_000_000:raise ValueError('门牌图片无效')
                image.verify()
            assets[ident]=raw
        item['has_image']=ident in assets
    json.dumps(items,allow_nan=False)
    return items,assets

def read_auxiliary_bundle(path):
    """Verify without extraction, including empty log files in run manifests."""
    with zipfile.ZipFile(path) as z:
        entries = [e for e in z.infolist() if not e.is_dir()]
        names = [safe_name(e.filename) for e in entries]
        if len(names) != len(set(names)) or len(names) > 10_000 or sum(e.file_size for e in entries) > MAX_BYTES_V2:
            raise ValueError("数据包过大或包含重复文件")
        if any(stat.S_ISLNK(e.external_attr >> 16) for e in entries):
            raise ValueError("不允许符号链接")
        if "files.json" in names:
            prefix = ""
        else:
            roots = {n.split('/')[0] for n in names}
            if len(roots) != 1:
                raise ValueError("ZIP必须只有一个根目录")
            prefix = next(iter(roots))+"/"
        relative = {n[len(prefix):]:n for n in names}
        def read(name, limit=8_388_608):
            actual = relative.get(safe_name(name))
            if not actual or z.getinfo(actual).file_size > limit:
                raise ValueError("文件缺失或过大："+name)
            return z.read(actual)
        manifest = json.loads(read("files.json"))
        declared = manifest["files"]
        if len(declared) != len({e['path'] for e in declared}) or {e['path'] for e in declared} != set(relative)-{"files.json"}:
            raise ValueError("文件清单不完整")
        for entry in declared:
            actual = relative[safe_name(entry['path'])]
            h = hashlib.sha256();size = 0
            with z.open(actual) as stream:
                while data := stream.read(131072):
                    size += len(data);h.update(data)
            if size != entry['bytes'] or h.hexdigest() != entry['sha256']:
                raise ValueError("文件损坏："+entry['path'])
        if "navigation.json" in relative:
            nav = json.loads(read("navigation.json"))
            uuid.UUID(nav["map_id"]);uuid.UUID(nav["session_id"])
            if nav.get("kind") != "lidar_navigation_map" or nav.get("schema_version") not in (1,2) or nav.get("coordinate_system") != "ARKit_Y_up_camera_minus_Z_row_major_meters" or nav.get("points_file") != "geometry.f32":
                raise ValueError("导航地图格式或坐标系不支持")
            count = nav["point_count"]
            if not isinstance(count,int) or not 100 <= count <= 400_000:
                raise ValueError("运行点数无效")
            points = np.frombuffer(read("geometry.f32"),dtype="<f4")
            if points.size != count*3 or not np.isfinite(points).all() or (np.abs(points)>=1000).any():
                raise ValueError("运行点云无效")
            xyz = points.reshape(-1,3)
            cloud = np.concatenate([xyz,np.full_like(xyz,.5)],axis=1).astype('<f4')
            landmarks,images=read_landmarks(read,relative,nav['map_id'],hashlib.sha256(read('geometry.f32')).hexdigest())
            return dict(kind="navigation", navigation=nav, cloud=cloud,landmarks=landmarks,landmark_images=images)
        run = json.loads(read("run.json"))
        map_id = run.get("configuration",{}).get("map_id")
        results = []
        for n in sorted(relative):
            if n.startswith("localization-") and n.endswith(".json"):
                raw = read(n)
                results.append(recorded_result(json.loads(raw),map_id,n[len('localization-'):-5],hashlib.sha256(raw).hexdigest()))
        if not results:
            raise ValueError("此run没有保存定位结果；请导入导航run")
        return dict(kind="run", run=run, results=results)


def match(map_path, query_path, frame_index=None):
    from lidar_validate import solve
    with Scan(map_path) as m, Scan(query_path) as q:
        require_independent(m, q)
        mp = m.points()
        frames = q.meta["frames"]
        if frame_index is None:
            fit = q.points([f for i, f in enumerate(frames) if i % 3 != 2])
            held = q.points([f for i, f in enumerate(frames) if i % 3 == 2])
            mode = "whole_scan"
            report, _ = solve(mp, fit, held)
        else:
            if not isinstance(frame_index, int) or not 0 <= frame_index < len(frames):
                raise ValueError("帧编号无效")
            # Exactly one frame. No preceding/following frame, known map pose,
            # previous candidate or whole-scan transform is used as a seed.
            points = q.points([frames[frame_index]])
            mode = "single_frame"
            report, _ = solve(mp, points, points)
            report["evaluation_warning"] = "单帧用同一批点评估残差，没有独立留出帧，不能与整段留出检查等同。"
        report.update(schema_version=1, map_id=m.meta["scan_id"], query_id=q.meta["scan_id"],
                      query_label=q.meta["label"], mode=mode, frame_index=frame_index,
                      independent_sessions=True, initial_world_map_used=False,
                      pose_meaning="query_session_to_map; camera pose = T_map_query @ T_query_camera",
                      truth_evaluation="not_available_requires_manual_review")
        return validate_result(report)
