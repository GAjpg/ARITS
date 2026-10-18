#!/usr/bin/env python3
"""Local-only ZIP point cloud viewer. Run with ../.venv/bin/python server.py."""
import os
os.environ.setdefault("OMP_NUM_THREADS", "4")
os.environ.setdefault("OPENBLAS_NUM_THREADS", "4")
import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import io
import json
from pathlib import Path
import secrets
import shutil
import sys
import threading
import time
import uuid
import webbrowser
import urllib.request

import numpy as np
from flask import Flask, request, jsonify, send_file, send_from_directory, Response
from werkzeug.exceptions import HTTPException
from werkzeug.serving import make_server
from engine import Scan, decode_cloud, decode_frame, match, validate_result, bundle_kind, read_auxiliary_bundle, recorded_result, MAX_BYTES_V2, FRAME_LIMITS, read_landmarks

ROOT = Path(__file__).resolve().parent
DEFAULT_DATA = ROOT.parent/"work/pointcloud-viewer"


class Store:
    def __init__(self, root):
        self.root = Path(root).resolve()
        self.root.mkdir(parents=True, exist_ok=True)
        self.lock = threading.RLock()
        self.compute = ThreadPoolExecutor(max_workers=1, thread_name_prefix="lidar-match")
        self.scans = {}
        self.results = {}
        self.jobs = {}
        for p in self.root.glob("*/scan-info.json"):
            try:
                info = json.loads(p.read_text())
                uuid.UUID(info["id"])
                if p.parent.name == info["id"] and (p.parent/"source.zip").exists() and (p.parent/"cloud.bin").exists():
                    self.scans[info["id"]] = info
            except (ValueError, KeyError):
                pass
        for p in (self.root/"results").glob("*.json"):
            try:
                self.save_result(json.loads(p.read_text()), persist=False)
            except (ValueError, KeyError):
                pass

    def path(self, scan_id):
        if scan_id not in self.scans:
            raise ValueError("未找到这份扫描，请先导入 ZIP")
        return self.root/scan_id

    def import_path(self, source):
        if bundle_kind(source) != "raw":
            return self.import_auxiliary(source)
        # Copy input first; never modify the original ZIP or use its filename as a path.
        staging = self.root/("incoming-"+uuid.uuid4().hex)
        staging.mkdir()
        try:
            upload = staging/"source.zip"
            with open(source, "rb") as src, upload.open("wb") as dst:
                total = 0
                while chunk := src.read(1024*1024):
                    total += len(chunk)
                    if total > MAX_BYTES_V2:
                        raise ValueError("单个 ZIP 上限为 2 GiB")
                    dst.write(chunk)
            with Scan(upload, allow_incomplete=True) as scan:
                scan_id = scan.meta["scan_id"]
                with self.lock:
                    if scan_id in self.scans and self.scans[scan_id].get("source_kind") not in ("recorded_query","navigation"):
                        # Same ID must also mean the exact same declared content.
                        old = self.path(scan_id)/"source.zip"
                        with Scan(old, allow_incomplete=True) as previous:
                            if previous.read("files.json") != scan.read("files.json"):
                                raise ValueError("同一扫描编号对应不同内容，未覆盖已有数据")
                        return self.scans[scan_id]
                cloud = decode_cloud(scan)
                cloud.tofile(staging/"cloud.bin")
                frames = scan.meta["frames"]
                info = dict(id=scan_id, label=scan.meta["label"], role=scan.meta["role"],
                            state=scan.meta["state"], lighting=scan.meta["lighting"],
                            region_name=scan.meta["region_name"], session_id=scan.meta["session_id"],
                            hardware=scan.meta["hardware"], frames=frames,
                            points=len(cloud), display_stride=4, display_voxel_m=0.04,
                            bounds=[cloud[:, :3].min(0).tolist(), cloud[:, :3].max(0).tolist()] if len(cloud) else [[0,0,0],[0,0,0]],
                            duration=frames[-1]["timestamp"]-frames[0]["timestamp"] if frames else 0,
                            zip_bytes=upload.stat().st_size,source_kind="raw",raw_available=True,
                            geometry_sha256=hashlib.sha256(scan.read("geometry.f32")).hexdigest() if "geometry.f32" in scan.names else None)
                info['landmarks'],images=read_landmarks(scan.read,scan.names,scan_id,info['geometry_sha256'])
                for ident,raw in images.items():(staging/('plate-'+ident+'.jpg')).write_bytes(raw)
                (staging/"scan-info.json").write_text(json.dumps(info, ensure_ascii=False, allow_nan=False))
            target = self.root/scan_id
            with self.lock:
                if target.exists():
                    old = self.scans.get(scan_id,{})
                    if old.get('source_kind') not in ('recorded_query','navigation'):
                        raise ValueError("扫描目录已经存在，请先检查查看器缓存")
                    if old.get('geometry_sha256') and old['geometry_sha256'] != info.get('geometry_sha256'):
                        raise ValueError("相同地图编号的几何已变化，未覆盖")
                    for name in ('source.zip','cloud.bin','scan-info.json'):
                        (staging/name).replace(target/name)
                else:
                    staging.rename(target)
                self.scans[scan_id] = info
            with Scan(target/"source.zip", allow_incomplete=True) as saved:
                if "on-device-result.json" in saved.names:
                    raw = saved.read("on-device-result.json")
                    self.save_result(recorded_result(json.loads(raw),query_id=scan_id,source_sha256=hashlib.sha256(raw).hexdigest()))
            return info
        finally:
            if staging.exists():
                shutil.rmtree(staging)

    def import_auxiliary(self, source):
        bundle = read_auxiliary_bundle(source)
        if bundle['kind'] == 'navigation':
            nav, cloud = bundle['navigation'],bundle['cloud']
            info = dict(id=nav['map_id'],label=nav['name'],role='map',state='runtime_only',lighting='unknown',
                        region_name=nav['name'],session_id=nav['session_id'],hardware='unknown',frames=[],points=len(cloud),
                        bounds=[cloud[:,:3].min(0).tolist(),cloud[:,:3].max(0).tolist()],duration=0,
                        source_kind='navigation',raw_available=False,geometry_sha256=hashlib.sha256(cloud[:,:3].astype('<f4').tobytes()).hexdigest())
            registered=self.register_auxiliary_scan(info, cloud, source)
            folder=self.path(info['id'])
            for ident,raw in bundle.get('landmark_images',{}).items():(folder/('plate-'+ident+'.jpg')).write_bytes(raw)
            registered['landmarks']=bundle.get('landmarks',[])
            if registered.get('source_kind')=='navigation':
                temp=folder/'source.zip.partial';shutil.copyfile(source,temp);temp.replace(folder/'source.zip')
            (folder/'scan-info.json').write_text(json.dumps(registered,ensure_ascii=False,allow_nan=False))
            return registered
        for result in bundle['results']:
            self.save_result(result)
        return dict(kind='run',results=len(bundle['results']),label=bundle['run'].get('run_id','导航记录'))

    def register_auxiliary_scan(self, info, cloud, source=None):
        with self.lock:
            if info['id'] in self.scans:
                old = self.scans[info['id']]
                if old.get('source_kind') == 'navigation' and info.get('source_kind') == 'navigation' and old.get('geometry_sha256') != info.get('geometry_sha256'):
                    raise ValueError('相同地图编号的几何已变化，未覆盖已有地图')
                return old
            folder = self.root/info['id'];folder.mkdir(exist_ok=False)
            if source:
                shutil.copyfile(source,folder/'source.zip')
            else:
                # A virtual query only has recorded transforms, no raw depth.
                (folder/'source.zip').write_bytes(b'')
            cloud.astype('<f4').tofile(folder/'cloud.bin')
            (folder/'scan-info.json').write_text(json.dumps(info,ensure_ascii=False,allow_nan=False))
            self.scans[info['id']] = info
            return info

    def ensure_recorded_query(self, result):
        qid = result['query_id']
        if qid not in self.scans:
            provenance = (result.get('recorded_result') or result).get('provenance') or {}
            self.register_auxiliary_scan(dict(id=qid,label='手机结果 '+qid[:8],role='query',state='result_only',lighting='unknown',
                region_name='',session_id=provenance.get('session_id') or result.get('session_id'),hardware=provenance.get('device','unknown'),
                frames=[],points=0,bounds=[[0,0,0],[0,0,0]],duration=0,source_kind='recorded_query',raw_available=False),np.empty((0,6),dtype='<f4'))

    def save_result(self, result, persist=True):
        if result.get("algorithm") or result.get("recorded_result"):
            result = recorded_result(result)
            self.ensure_recorded_query(result)
        result = validate_result(result)
        mode = result.get("mode", "whole_scan")
        index = result.get("frame_index") if mode == "single_frame" else None
        if mode not in ("whole_scan", "single_frame", "recorded") or (mode == "single_frame" and (not isinstance(index, int) or index < 0 or index >= FRAME_LIMITS[2]["query"])):
            raise ValueError("结果帧编号或计算模式无效")
        key = f"{result['map_id']}__{result['query_id']}__{index if index is not None else mode}"
        with self.lock:
            self.results[key] = result
            if persist:
                folder = self.root/"results"
                folder.mkdir(exist_ok=True)
                temp = folder/(key+".partial")
                temp.write_text(json.dumps(result, ensure_ascii=False, allow_nan=False))
                temp.replace(folder/(key+".json"))
        return result

    def job(self, map_id, query_id, mode, frame_index=None):
        if map_id not in self.scans or query_id not in self.scans:
            raise ValueError("请先导入并选择地图和查询")
        if self.scans[map_id]["role"] != "map" or self.scans[query_id]["role"] != "query":
            raise ValueError("必须选建图记录作为地图、查询记录作为查询")
        if any(self.scans[s].get('raw_available') is False for s in (map_id,query_id)):
            raise ValueError("此记录缺少原始深度，不可重算；可直接查看手机候选")
        if mode not in ("whole_scan", "single_frame", "all_frames"):
            raise ValueError("未知计算模式")
        n = len(self.scans[query_id]["frames"])
        if mode == "single_frame" and (not isinstance(frame_index, int) or not 0 <= frame_index < n):
            raise ValueError("帧编号无效")
        with self.lock:
            if any(j["state"] in ("queued", "running") for j in self.jobs.values()):
                raise ValueError("已有配准任务在运行，请等待或取消")
            job_id = uuid.uuid4().hex
            job = dict(id=job_id, state="queued", completed=0, total=n if mode == "all_frames" else 1,
                       map_id=map_id, query_id=query_id, mode=mode, cancel=False, errors=[])
            self.jobs[job_id] = job
        def work():
            job["state"] = "running"
            indices = range(n) if mode == "all_frames" else [frame_index if mode == "single_frame" else None]
            for index in indices:
                if job["cancel"]:
                    break
                try:
                    result = match(self.path(map_id)/"source.zip", self.path(query_id)/"source.zip", index)
                    self.save_result(result)
                except Exception as e:
                    job["errors"].append({"frame": index, "message": str(e)})
                    if mode != "all_frames":
                        job["state"] = "failed"
                        return
                job["completed"] += 1
            job["state"] = "cancelled" if job["cancel"] else "finished"
        self.compute.submit(work)
        return job


def local_page_token(root):
    # Keep existing open editors usable across a local service restart. The token stays
    # local to this data directory and is never sent in URLs, logs or exports.
    path = Path(root)/'.viewer-token'
    if path.is_symlink():
        raise ValueError('工作台页面凭证路径无效')
    if path.exists():
        value = path.read_text().strip()
        if len(value) < 24 or len(value) > 128 or any(c not in 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_' for c in value):
            raise ValueError('工作台页面凭证无效')
        return value
    value = secrets.token_urlsafe(24)
    try:
        fd = os.open(path,os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)
    except FileExistsError:
        return local_page_token(root)
    with os.fdopen(fd,'w') as f:
        f.write(value)
    return value


def create_app(store):
    app = Flask(__name__, static_folder=None)
    app.config["MAX_CONTENT_LENGTH"] = MAX_BYTES_V2+2*1024*1024
    app.config["TOKEN"] = local_page_token(store.root)

    @app.before_request
    def local_only():
        if request.host.split(":")[0] not in ("127.0.0.1", "localhost"):
            return jsonify(error="只允许本机访问"), 403
        if request.method == "POST" and request.headers.get("X-Viewer-Token") != app.config["TOKEN"]:
            return jsonify(error="请从查看器页面执行操作"), 403

    @app.after_request
    def headers(response):
        response.headers["X-Content-Type-Options"] = "nosniff"
        response.headers["Cache-Control"] = "no-store" if request.path.startswith("/api/") else "no-cache"
        response.headers["Referrer-Policy"] = "no-referrer"
        return response

    @app.errorhandler(Exception)
    def error(e):
        if isinstance(e, HTTPException):
            return jsonify(error="上传文件过大" if e.code == 413 else str(e.description)), e.code
        return jsonify(error=str(e)), 400

    @app.get("/")
    def index():
        page = (ROOT/"web/index.html").read_text().replace("__VIEWER_TOKEN__", app.config["TOKEN"])
        return Response(page, mimetype="text/html")

    @app.get("/assets/<path:name>")
    def assets(name):
        return send_from_directory(ROOT/"web", name)

    @app.get("/api/catalog")
    def catalog():
        with store.lock:
            return jsonify(scans=list(store.scans.values()), results=list(store.results.values()),
                           jobs=list(store.jobs.values()), local_only=True, viewer_protocol=2, space_protocol=1, outdoor_protocol=1)

    @app.post("/api/import")
    def import_scan():
        upload = request.files.get("file")
        if upload is None:
            raise ValueError("请选择 ZIP 或配准结果 JSON")
        if upload.filename.lower().endswith(".json"):
            data = upload.stream.read(5_000_001)
            if len(data) > 5_000_000:
                raise ValueError("结果 JSON 过大")
            payload = json.loads(data)
            if payload.get("kind") == "lidar_viewer_results":
                results = payload.get("results", [])
                if not isinstance(results, list) or len(results) > 2000:
                    raise ValueError("结果集合无效或过大")
                checked = [recorded_result(r) if r.get('algorithm') or r.get('recorded_result') else validate_result(r) for r in results]
                return jsonify(results=[store.save_result(result) for result in checked])
            return jsonify(result=store.save_result(payload))
        if not upload.filename.lower().endswith(".zip"):
            raise ValueError("请导入扫描 ZIP 或已有配准结果 JSON")
        temporary = store.root/("upload-"+uuid.uuid4().hex+".zip")
        try:
            with temporary.open("wb") as output:
                size = 0
                while chunk := upload.stream.read(1024*1024):
                    size += len(chunk)
                    if size > MAX_BYTES_V2:
                        raise ValueError("ZIP 超过 2 GiB")
                    output.write(chunk)
            return jsonify(scan=store.import_path(temporary))
        finally:
            temporary.unlink(missing_ok=True)

    @app.get("/api/scans/<scan_id>/cloud")
    def cloud(scan_id):
        return send_file(store.path(scan_id)/"cloud.bin", mimetype="application/octet-stream")

    @app.get("/api/scans/<scan_id>/landmarks/<landmark_id>/image")
    def plate_image(scan_id,landmark_id):
        folder=store.path(scan_id)
        uuid.UUID(landmark_id)
        if not any(p['id']==landmark_id and p.get('has_image') for p in store.scans[scan_id].get('landmarks',[])):
            raise ValueError('门牌没有可用截图')
        return send_file(folder/('plate-'+landmark_id+'.jpg'),mimetype='image/jpeg')

    @app.get("/api/scans/<scan_id>/frames/<int:index>/<kind>")
    def frame(scan_id, index, kind):
        folder = store.path(scan_id)
        if not 0 <= index < len(store.scans[scan_id]["frames"]):
            raise ValueError("帧编号无效")
        if kind not in ("cloud", "image"):
            raise ValueError("未知帧数据")
        with Scan(folder/"source.zip", allow_incomplete=True) as scan:
            if kind == "image":
                return send_file(io.BytesIO(scan.read(f"frames/{index:04d}/rgb.jpg")), mimetype="image/jpeg")
            cache = folder/f"frame-{index:04d}.bin"
            if not cache.exists():
                data = decode_frame(scan, scan.meta["frames"][index])
                temp = folder/(cache.name+"."+uuid.uuid4().hex+".partial")
                data.tofile(temp)
                temp.replace(cache)
        return send_file(cache, mimetype="application/octet-stream")

    @app.post("/api/jobs")
    def start_job():
        args = request.get_json()
        return jsonify(store.job(args.get("map_id"), args.get("query_id"), args.get("mode", "whole_scan"), args.get("frame_index")))

    @app.get("/api/jobs/<job_id>")
    def get_job(job_id):
        if job_id not in store.jobs:
            raise ValueError("任务不存在")
        return jsonify(store.jobs[job_id])

    @app.post("/api/jobs/<job_id>/cancel")
    def cancel_job(job_id):
        if job_id not in store.jobs:
            raise ValueError("任务不存在")
        store.jobs[job_id]["cancel"] = True
        return jsonify(ok=True)

    @app.get("/api/export-results")
    def export_results():
        payload = dict(kind="lidar_viewer_results", schema_version=1, results=list(store.results.values()))
        return send_file(io.BytesIO(json.dumps(payload, ensure_ascii=False, indent=2).encode()), mimetype="application/json", as_attachment=True, download_name="定位回放结果.json")
    from space import register_space_routes
    register_space_routes(app, store)
    from outdoor import register_outdoor_routes
    register_outdoor_routes(app, store)
    return app


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--port", type=int, default=18766)
    p.add_argument("--data", type=Path, default=DEFAULT_DATA)
    p.add_argument("--import-scans", nargs="*", default=[])
    p.add_argument("--import-results", nargs="*", default=[])
    p.add_argument("--no-browser", action="store_true")
    p.add_argument("--space", action="store_true", help="打开实验通行空间工作台")
    p.add_argument("--outdoor", action="store_true", help="打开校园地图编辑器")
    args = p.parse_args()
    landing = "/outdoor" if args.outdoor else "/space" if args.space else ""
    # Reuse an already running viewer on this Mac when double-clicked again.
    if not args.import_scans and not args.import_results and args.data.resolve() == DEFAULT_DATA.resolve():
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        for port in range(args.port, args.port+10):
            url = f"http://127.0.0.1:{port}"
            try:
                existing = json.load(opener.open(url+"/api/catalog", timeout=0.3))
                page = opener.open(url, timeout=0.3).read(2000).decode()
                if existing.get("viewer_protocol",0) >= 2 and existing.get("local_only") is True and 'viewer-token' in page and 'LiDAR 点云工作台' in page and (not args.space or existing.get('space_protocol', 0) >= 1) and (not args.outdoor or existing.get('outdoor_protocol', 0) >= 1):
                    print("查看器已经运行："+url, flush=True)
                    if not args.no_browser:
                        webbrowser.open(url+landing)
                    return
            except Exception:
                pass
    store = Store(args.data)
    for path in args.import_scans:
        print("导入：", path, flush=True)
        store.import_path(path)
    for path in args.import_results:
        store.save_result(json.loads(Path(path).read_text()))
    app = create_app(store)
    server = None
    for port in range(args.port, args.port+10):
        try:
            server = make_server("127.0.0.1", port, app, threaded=True)
            break
        except (OSError, SystemExit):
            pass
    if server is None:
        raise SystemExit("没有可用端口，请通过 --port 指定其他端口")
    url = f"http://127.0.0.1:{server.server_port}"
    print("点云查看器已启动："+url+"\n数据只在本机处理。关闭终端或按 Ctrl+C 停止。", flush=True)
    if not args.no_browser:
        threading.Timer(0.6, lambda: webbrowser.open(url+landing)).start()
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        for job in store.jobs.values():
            job["cancel"] = True
        server.server_close()
        store.compute.shutdown(wait=True, cancel_futures=True)


if __name__ == "__main__":
    main()
