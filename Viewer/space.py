"""Experimental 2-D passage workbench. Swift owns inference and calibration validation."""
import hashlib
import io
import json
from pathlib import Path
import re
import math
import subprocess
import tempfile
import threading
import shutil
import uuid
import zipfile
from datetime import datetime, timezone

from flask import Response, jsonify, request, send_file
from werkzeug.exceptions import Conflict
from engine import MAX_BYTES_V2, read_auxiliary_bundle, safe_name

ROOT = Path(__file__).resolve().parent
CALIBRATION = 'passage-calibration.json'
MAX_CALIBRATION = 32_000_000
KEY = re.compile(r'^[0-9a-fA-F-]{36}-[0-9a-f]{64}$')


def json_bytes(value):
    return json.dumps(value, ensure_ascii=False, allow_nan=False, indent=2).encode('utf-8')


def read_json(data):
    def invalid(value):
        raise ValueError('JSON 含有非有限数值：'+value)
    return json.loads(data, parse_constant=invalid)


class SpaceStore:
    def __init__(self, root, tool=None):
        self.root = Path(root)/'space-projects'
        self.root.mkdir(exist_ok=True)
        self.lock = threading.RLock()
        self.pinned_tool = tool is None
        self.tool = Path(tool) if tool else Path(root)/'space-runtime/space-route'
        if self.pinned_tool:
            # A workbench session owns its executable. Phone edits/builds must not invalidate
            # a live editor or replace the program midway through calibration validation.
            self.tool.parent.mkdir(exist_ok=True)
            receipt = self.tool.parent/'runtime.json'
            if not self.tool.exists():
                source = ROOT.parent/'.build/tools/space-route'
                if source.is_file():
                    pending = self.tool.parent/(uuid.uuid4().hex+'.partial')
                    shutil.copy2(source,pending);pending.replace(self.tool)
            if self.tool.is_file():
                digest = hashlib.sha256(self.tool.read_bytes()).hexdigest()
                if receipt.exists():
                    if read_json(receipt.read_bytes()).get('binary_sha256') != digest:
                        raise ValueError('工作台独立核心校验失败，请重新安装工作台核心')
                else:
                    receipt.write_bytes(json_bytes(dict(binary_sha256=digest,installed_utc=datetime.now(timezone.utc).isoformat(),policy='pinned_workbench_runtime')))


    def folder(self, key):
        if not isinstance(key, str) or not KEY.fullmatch(key):
            raise ValueError('空间项目编号无效')
        folder = self.root/key
        if not (folder/'project.json').is_file():
            raise ValueError('请先导入地图 ZIP')
        return folder

    def catalog(self):
        with self.lock:
            projects = []
            for file in sorted(self.root.glob('*/project.json')):
                if KEY.fullmatch(file.parent.name):
                    projects.append(read_json(file.read_bytes()))
            return projects

    def run_tool(self, args):
        if not self.tool.is_file():
            raise ValueError('尚未编译空间路网工具，请在 LiDARProbe 目录运行 bash Tools/build_space_route.sh，再重试')
        sources = list((ROOT.parent/'Sources/ProbeCore').glob('*.swift')) + list((ROOT.parent/'Tools/SpaceRoute').glob('*.swift'))
        if not self.pinned_tool and any(p.stat().st_mtime > self.tool.stat().st_mtime for p in sources):
            raise ValueError('空间核心已更新，请运行 bash Tools/build_space_route.sh 重新编译后再试')
        try:
            result = subprocess.run([str(self.tool), *map(str, args)], capture_output=True, timeout=90, check=False)
        except subprocess.TimeoutExpired:
            raise ValueError('空间栅格准备超时，原校准保持不变') from None
        try:
            payload = read_json(result.stdout)
        except (ValueError, UnicodeDecodeError):
            raise ValueError('空间路网工具未返回有效结果，请重新编译工具') from None
        if result.returncode or payload.get('status') == 'error':
            raise ValueError(payload.get('reason', '空间路网工具执行失败'))
        return payload

    def prepare(self, folder, calibration=None):
        args = ['prepare', '--map', folder/'map']
        if calibration is not None:
            args += ['--calibration', calibration]
        target = folder/('grid-'+uuid.uuid4().hex+'.json')
        try:
            self.run_tool([*args, '--out', target])
            grid = read_json(target.read_bytes())
            grid["workbench_tool_sha256"] = hashlib.sha256(self.tool.read_bytes()).hexdigest()
            grid["workbench_calibration_sha256"] = hashlib.sha256(Path(calibration).read_bytes()).hexdigest() if calibration else None
            return grid, json_bytes(grid)
        finally:
            target.unlink(missing_ok=True)

    def import_map(self, source):
        # Existing shared reader checks the entire manifest, hashes, unsafe paths and symlinks.
        bundle = read_auxiliary_bundle(source)
        if bundle['kind'] != 'navigation':
            raise ValueError('空间工作台需要含 navigation.json 和 geometry.f32 的地图 ZIP')
        nav = bundle['navigation']
        with zipfile.ZipFile(source) as archive:
            files = {safe_name(e.filename): e for e in archive.infolist() if not e.is_dir()}
            prefixes = [name[:-len('navigation.json')] for name in files if name.endswith('navigation.json')]
            if len(prefixes) != 1:
                raise ValueError('地图包里必须只有一份 navigation.json')
            prefix = prefixes[0]
            if prefix+'.map-transaction.json' in files:
                raise ValueError('地图更新尚未完成，请先在手机恢复后重新导出')
            def read(name, limit):
                item = files.get(prefix+name)
                if item is None:
                    return None
                if item.file_size > limit:
                    raise ValueError('地图文件过大：'+name)
                return archive.read(item)
            geometry = read('geometry.f32', 400_000*12)
            digest = hashlib.sha256(geometry).hexdigest()
            key = nav['map_id']+'-'+digest
            with self.lock:
                if (self.root/key/'project.json').exists():
                    previous = self.state(key)
                    previous['notice'] = '此几何版本已导入，保留工作台当前的校准副本。'
                    return previous
                with tempfile.TemporaryDirectory(prefix='incoming-', dir=self.root) as temp:
                    staging = Path(temp)
                    (staging/'map').mkdir()
                    (staging/'map/navigation.json').write_bytes(read('navigation.json', 1_048_576))
                    (staging/'map/geometry.f32').write_bytes(geometry)
                    trajectory = read('walked-trajectory.json', MAX_CALIBRATION)
                    if trajectory is not None:
                        (staging/'map/walked-trajectory.json').write_bytes(trajectory)
                    raw = read(CALIBRATION, MAX_CALIBRATION)
                    if raw is not None:
                        read_json(raw)  # Reject non-standard JSON before Swift decoding.
                        (staging/CALIBRATION).write_bytes(raw)
                    grid, encoded = self.prepare(staging, staging/CALIBRATION if raw is not None else None)
                    info = dict(key=key, map_id=nav['map_id'], name=nav['name'], geometry_sha256=digest,
                                point_count=nav['point_count'], imported_utc=datetime.now(timezone.utc).isoformat(),
                                has_trajectory=trajectory is not None)
                    (staging/'project.json').write_bytes(json_bytes(info))
                    (staging/'grid.json').write_bytes(encoded)
                    # Copy just the validated geometry/metadata, never extract user-controlled ZIP paths.
                    staging.rename(self.root/key)
        return self.state(key)

    def state(self, key):
        with self.lock:
            folder = self.folder(key)
            info = read_json((folder/'project.json').read_bytes())
            nav = read_json((folder/'map/navigation.json').read_bytes())
            grid = read_json((folder/'grid.json').read_bytes())
            raw_calibration = (folder/CALIBRATION).read_bytes() if (folder/CALIBRATION).exists() else None
            expected_hash = hashlib.sha256(raw_calibration).hexdigest() if raw_calibration is not None else None
            current_tool = hashlib.sha256(self.tool.read_bytes()).hexdigest() if self.tool.is_file() else None
            if grid.get('workbench_calibration_sha256') != expected_hash or grid.get('workbench_tool_sha256') != current_tool:
                grid, encoded = self.prepare(folder, folder/CALIBRATION if raw_calibration is not None else None)
                pending = folder/('grid-'+uuid.uuid4().hex+'.partial')
                pending.write_bytes(encoded)
                pending.replace(folder/'grid.json')
            calibration = read_json(raw_calibration) if raw_calibration is not None else None
            warnings = []
            if calibration and calibration.get('base_geometry_sha256') not in (None, info['geometry_sha256']):
                warnings.append('校准引用了其他几何版本，已按原地图坐标使用；请核对补采后的区域。')
            if not info['has_trajectory']:
                warnings.append('这份地图没有行走轨迹；自动判断可能留下地面空洞，可在后续涂改中确认通行。')
            return dict(project=info, grid=grid, calibration=calibration, calibration_revision=expected_hash or "none",
                        nodes=nav.get('nodes', []), edges=nav.get('edges', []), warnings=warnings)

    def apply_calibration(self, key, raw, expected_revision=None):
        if len(raw) > MAX_CALIBRATION:
            raise ValueError('校准文件超过 32 MB')
        value = read_json(raw)
        with self.lock:
            folder = self.folder(key)
            info = read_json((folder/'project.json').read_bytes())
            current_revision = hashlib.sha256((folder/CALIBRATION).read_bytes()).hexdigest() if (folder/CALIBRATION).exists() else 'none'
            if expected_revision is not None and expected_revision != current_revision:
                raise Conflict('校准已被另一个页面修改。请先导出当前草稿，再重新加载工作副本，避免覆盖其他修改。')
            if not isinstance(value, dict) or value.get('map_id') != info['map_id']:
                raise ValueError('校准文件不属于这张地图')
            # Stage and validate with the same Swift codec/core as the phone. Failure changes nothing.
            with tempfile.TemporaryDirectory(prefix='calibration-', dir=folder) as temp:
                candidate = Path(temp)/CALIBRATION
                candidate.write_bytes(raw)
                _, grid = self.prepare(folder, candidate)
                pending = Path(temp)/'grid.json'
                pending.write_bytes(grid)
                # Keep the calibration bytes unmodified, including provenance and future fields.
                # Grid is derived cache: startup/state can always re-prepare from the authoritative file.
                candidate.replace(folder/CALIBRATION)
                pending.replace(folder/'grid.json')
            return self.state(key)

    def preview(self, key, payload):
        def point(name):
            p = payload.get(name)
            if not isinstance(p, list) or len(p) != 2 or any(isinstance(x, bool) or not isinstance(x, (int, float)) or not math.isfinite(x) or abs(x) >= 1000 for x in p):
                raise ValueError('预览起终点坐标无效')
            return p
        validation_only = payload.get('from') is None and payload.get('to') is None
        start, end = (None, None) if validation_only else (point('from'), point('to'))
        with self.lock:
            folder = self.folder(key)
            self.state(key)  # Verify/update the persisted cache before reusing it.
            grid_file = folder/'grid.json'
            if payload.get('calibration') is not None:
                raw = json_bytes(payload['calibration'])
                if len(raw) > MAX_CALIBRATION:
                    raise ValueError('校准文件超过 32 MB')
                tool_hash = hashlib.sha256(self.tool.read_bytes()).digest()
                digest = hashlib.sha256(tool_hash+raw).hexdigest()
                cache = folder/'previews';cache.mkdir(exist_ok=True)
                grid_file = cache/(digest+'.json')
                if not grid_file.exists():
                    with tempfile.TemporaryDirectory(prefix='preview-', dir=folder) as temp:
                        candidate = Path(temp)/CALIBRATION;candidate.write_bytes(raw)
                        _, encoded = self.prepare(folder, candidate)
                        pending = Path(temp)/'grid.json';pending.write_bytes(encoded);pending.replace(grid_file)
                    for old in sorted(cache.glob('*.json'),key=lambda p:p.stat().st_mtime,reverse=True)[8:]:
                        old.unlink(missing_ok=True)
            route = None if validation_only else self.run_tool(['route', '--grid', grid_file, '--from', f'{start[0]},{start[1]}', '--to', f'{end[0]},{end[1]}'])
            return dict(route=route, request_id=payload.get('request_id'), calibration_revision=self.state(key)['calibration_revision'])

    def export_draft(self, key, calibration):
        if not isinstance(calibration, dict):
            raise ValueError('导出请求缺少校准草稿')
        raw = json_bytes(calibration)
        if len(raw) > MAX_CALIBRATION:
            raise ValueError('校准文件超过 32 MB')
        with self.lock:
            self.preview(key, {'calibration': calibration})  # Validate without overwriting the saved copy.
            folder = self.folder(key)/'exports';folder.mkdir(exist_ok=True)
            digest = hashlib.sha256(raw).hexdigest();target=folder/(digest+'.json')
            if not target.exists():
                pending=folder/(uuid.uuid4().hex+'.partial');pending.write_bytes(raw);pending.replace(target)
            for old in sorted(folder.glob('*.json'),key=lambda p:p.stat().st_mtime,reverse=True)[3:]:
                if old != target:old.unlink(missing_ok=True)
            return dict(download_url=f'/api/space/projects/{key}/download/{digest}')

    def export(self, key):
        with self.lock:
            folder = self.folder(key)
            if (folder/CALIBRATION).exists():
                return (folder/CALIBRATION).read_bytes()
            info = read_json((folder/'project.json').read_bytes())
            grid = read_json((folder/'grid.json').read_bytes())
            return json_bytes(dict(schema_version=1, kind='lidar_passage_calibration', map_id=info['map_id'],
                base_geometry_sha256=info['geometry_sha256'], updated_utc=datetime.now(timezone.utc).isoformat(),
                editor='workbench', walkable=None, suggested_paths=grid.get('suggested_paths', []), auto_params=grid['params']))


def register_space_routes(app, store):
    spaces = SpaceStore(store.root)
    app.extensions['space_store'] = spaces

    @app.get('/space')
    def space_page():
        page = (ROOT/'web/space.html').read_text().replace('__VIEWER_TOKEN__', app.config['TOKEN'])
        return Response(page, mimetype='text/html')

    @app.get('/api/space/projects')
    def space_catalog():
        return jsonify(projects=spaces.catalog())

    @app.post('/api/space/import')
    def space_import():
        upload = request.files.get('file')
        if not upload or not upload.filename.lower().endswith('.zip'):
            raise ValueError('请选择手机导出的地图 ZIP')
        with tempfile.NamedTemporaryFile(suffix='.zip', dir=spaces.root) as temporary:
            size = 0
            while chunk := upload.stream.read(1024*1024):
                size += len(chunk)
                if size > MAX_BYTES_V2:
                    raise ValueError('地图 ZIP 超过 2 GiB')
                temporary.write(chunk)
            temporary.flush()
            return jsonify(spaces.import_map(temporary.name))

    @app.get('/api/space/projects/<key>')
    def space_state(key):
        return jsonify(spaces.state(key))

    @app.get('/api/space/projects/<key>/geometry')
    def space_geometry(key):
        # Exact imported XYZ, independently of the editable green/white layer.
        folder = spaces.folder(key)
        return send_file(folder/'map/geometry.f32', mimetype='application/octet-stream')

    @app.post('/api/space/projects/<key>/calibration')
    def space_calibration(key):
        upload = request.files.get('file')
        if upload is None:
            raise ValueError('请选择 passage-calibration.json')
        return jsonify(spaces.apply_calibration(key, upload.stream.read(MAX_CALIBRATION+1)))

    def edit_payload():
        if request.content_length is not None and request.content_length > MAX_CALIBRATION+1_000_000:
            raise ValueError('校准请求过大')
        value = read_json(request.get_data(cache=False, as_text=False))
        if not isinstance(value, dict):
            raise ValueError('编辑请求无效')
        return value

    @app.post('/api/space/projects/<key>/edit')
    def space_edit(key):
        value = edit_payload()
        if not isinstance(value.get('base_revision'), str):
            raise ValueError('保存请求缺少工作副本版本，请刷新页面')
        return jsonify(spaces.apply_calibration(key, json_bytes(value.get('calibration')), value['base_revision']))

    @app.post('/api/space/projects/<key>/preview')
    def space_preview(key):
        return jsonify(spaces.preview(key, edit_payload()))

    @app.post('/api/space/projects/<key>/export-draft')
    def space_export_draft(key):
        return jsonify(spaces.export_draft(key, edit_payload().get('calibration')))

    @app.get('/api/space/projects/<key>/download/<digest>')
    def space_download_draft(key, digest):
        if not re.fullmatch(r'[0-9a-f]{64}', digest):
            raise ValueError('校准导出编号无效')
        target = spaces.folder(key)/'exports'/(digest+'.json')
        if not target.is_file():
            raise ValueError('此导出已过期，请重新点击导出')
        return send_file(target, mimetype='application/json', as_attachment=True, download_name=CALIBRATION)

    @app.get('/api/space/projects/<key>/export')
    def space_export(key):
        return send_file(io.BytesIO(spaces.export(key)), mimetype='application/json',
                         as_attachment=True, download_name=CALIBRATION)
