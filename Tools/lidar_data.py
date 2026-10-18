"""Read the iOS scan contract without trusting archive paths or saved previews."""
import hashlib
import json
import stat
import uuid
import zipfile
from pathlib import Path, PurePosixPath

import numpy as np

MAX_BYTES = 512 * 1024 * 1024
# Schema 2 lifts the map frame cap for keyframe-gated capture (see LiDARScanLimits in Swift).
MAX_BYTES_V2 = 2 * 1024 * 1024 * 1024
MAX_FILES_V2 = 4000
FRAME_LIMITS = {1: {"map": 100, "query": 24}, 2: {"map": 600, "query": 64}}


def safe_name(name):
    p = PurePosixPath(name)
    if not name or p.is_absolute() or ".." in p.parts or "\\" in name or ":" in name:
        raise ValueError(f"不安全的文件名: {name}")
    if str(p) != name:
        raise ValueError(f"非标准文件名: {name}")
    return name


class Scan:
    def __init__(self, path, allow_incomplete=False):
        self.path = Path(path).resolve()
        self.archive = None
        self.prefix = ""
        if self.path.is_dir():
            self.names = set()
            total = 0
            for item in self.path.rglob("*"):
                if item.is_symlink():
                    raise ValueError("数据包不允许符号链接")
                if item.is_file():
                    self.names.add(safe_name(item.relative_to(self.path).as_posix()))
                    total += item.stat().st_size
        else:
            self.archive = zipfile.ZipFile(self.path)
            entries = [e for e in self.archive.infolist() if not e.is_dir()]
            self.names = {safe_name(e.filename) for e in entries}
            total = sum(e.file_size for e in entries)
            if len(self.names) != len(entries) or any(stat.S_ISLNK(e.external_attr >> 16) for e in entries):
                self.close()
                raise ValueError("ZIP 包含重复文件或符号链接")
            # ProbeZip stores a single top-level directory. Also support a flat
            # dataset ZIP, but never guess across multiple possible roots.
            if "scan.json" not in self.names:
                roots = {name.split("/")[0] for name in self.names}
                if len(roots) != 1:
                    self.close()
                    raise ValueError("ZIP 必须只含一份扫描")
                self.prefix = next(iter(roots))+"/"
                self.names = {name[len(self.prefix):] for name in self.names}
        if total > MAX_BYTES_V2 or len(self.names) > MAX_FILES_V2:
            self.close()
            raise ValueError("验证包过大（上限 2 GiB / 4000 文件）")
        try:
            if "files.json" not in self.names:
                raise ValueError("缺少完整性清单，请从 App 的记录列表重新导出")
            entries = self.json("files.json")["files"]
            expected = {safe_name(e["path"]) for e in entries}
            if len(entries) != len(expected) or expected != self.names - {"files.json"}:
                raise ValueError("文件清单不完整或存在未登记的文件")
            for e in entries:
                with self.open(e["path"]) as handle:
                    h = hashlib.sha256()
                    size = 0
                    while chunk := handle.read(131072):
                        size += len(chunk)
                        h.update(chunk)
                if size != e["bytes"] or h.hexdigest() != e["sha256"]:
                    raise ValueError(f"文件损坏: {e['path']}")
            self.meta = self.json("scan.json")
            if self.meta.get("schema_version") == 1 and (total > MAX_BYTES or len(self.names) > 1000):
                raise ValueError("schema 1 验证包过大（上限 512 MiB / 1000 文件）")
            self.validate(allow_incomplete)
        except Exception:
            self.close()
            raise

    def open(self, name):
        safe_name(name)
        if name not in self.names:
            raise ValueError(f"缺少文件: {name}")
        if self.archive:
            return self.archive.open(self.prefix+name)
        return (self.path / name).open("rb")

    def read(self, name):
        with self.open(name) as f:
            return f.read()

    def json(self, name):
        with self.open(name) as f:
            data = f.read(5_000_001)
        if len(data) > 5_000_000:
            raise ValueError("JSON 超出大小上限")
        return json.loads(data)

    def close(self):
        if self.archive:
            self.archive.close()

    def __enter__(self):
        return self

    def __exit__(self, *_):
        self.close()

    def validate(self, allow_incomplete):
        m = self.meta
        for key in ("scan_id", "session_id"):
            uuid.UUID(m[key])
        if m.get("schema_version") not in FRAME_LIMITS:
            raise ValueError("不支持的扫描格式版本")
        expected = {
            "kind": "lidar_geometry_scan",
            "initial_world_map_used": False,
            "coordinate_system": "ARKit_Y_up_camera_minus_Z_row_major_meters",
            "depth_encoding": "float32_little_endian_optical_z_meters",
            "confidence_encoding": "uint8_0_low_1_medium_2_high",
            "image_orientation": "native_capturedImage_no_rotation",
            "depth_source": "ARFrame.sceneDepth_unsmoothed",
            "route_alignment": "unbound_independent_session",
        }
        if any(m.get(k) != v for k, v in expected.items()):
            raise ValueError("不支持的坐标 / 深度格式或混入了旧地图姿态")
        if not allow_incomplete and m["state"] != "complete":
            raise ValueError("本次记录未正常完成，不能作为有效配准试验（check 可检查中断包）")
        limits = FRAME_LIMITS[m["schema_version"]]
        if m["role"] not in limits or not 3 <= len(m["frames"]) <= limits[m["role"]]:
            if not (allow_incomplete and m["role"] in limits and len(m["frames"]) <= limits[m["role"]]):
                raise ValueError("扫描角色或帧数不符")
        old_time = -float("inf")
        for i, frame in enumerate(m["frames"]):
            if frame["index"] != i or frame["tracking"] != "normal" or not np.isfinite(frame["timestamp"]) or frame["timestamp"] <= old_time:
                raise ValueError("帧编号、跟踪状态或时间顺序不符")
            old_time = frame["timestamp"]
            validate_transform(frame["camera_to_session"])
            c = frame["calibration"]
            for k in ("width", "height", "image_width", "image_height"):
                if not isinstance(c[k], int) or not 1 <= c[k] <= (2048 if k in ("width", "height") else 8192):
                    raise ValueError("图像尺寸不符")
            if not np.isfinite([c[k] for k in ("fx", "fy", "cx", "cy")]).all() or min(c["fx"], c["fy"]) <= 0:
                raise ValueError("相机内参无效")
            if not (0 <= c["cx"] < c["image_width"] and 0 <= c["cy"] < c["image_height"]):
                raise ValueError("相机主点超出图像")
            folder = f"frames/{i:04d}"
            n = c["width"] * c["height"]
            if len(self.read(folder + "/depth.f32")) != n * 4 or len(self.read(folder + "/confidence.u8")) != n:
                raise ValueError("深度数据长度不符")
            from PIL import Image
            with self.open(folder + "/rgb.jpg") as stream, Image.open(stream) as image:
                if image.size != (c["image_width"], c["image_height"]):
                    raise ValueError("JPEG 尺寸与相机内参参考尺寸不符")
                image.verify()

    def points(self, frames=None, stride=4, min_confidence=1):
        if not 1 <= stride <= 32 or min_confidence not in (1, 2):
            raise ValueError("采样步长或置信度阈值无效")
        all_points = []
        for f in self.meta["frames"] if frames is None else frames:
            c = f["calibration"]
            folder = f"frames/{f['index']:04d}"
            depth = np.frombuffer(self.read(folder + "/depth.f32"), dtype="<f4").reshape(c["height"], c["width"])
            conf = np.frombuffer(self.read(folder + "/confidence.u8"), dtype="u1").reshape(depth.shape)
            if (conf > 2).any():
                raise ValueError("深度置信度编码错误")
            v, u = np.mgrid[0:c["height"]:stride, 0:c["width"]:stride]
            z = depth[::stride, ::stride]
            mask = np.isfinite(z) & (z >= 0.2) & (z <= 4.5) & (conf[::stride, ::stride] >= min_confidence)
            sx, sy = c["width"] / c["image_width"], c["height"] / c["image_height"]
            p = np.stack([(u[mask]-c["cx"]*sx)/(c["fx"]*sx)*z[mask],
                          -(v[mask]-c["cy"]*sy)/(c["fy"]*sy)*z[mask], -z[mask]], axis=1)
            t = np.array(f["camera_to_session"])
            all_points.append(p @ t[:3, :3].T + t[:3, 3])
        return np.concatenate(all_points) if all_points else np.empty((0, 3))


def validate_transform(t):
    t = np.asarray(t, dtype=float)
    if (t.shape != (4, 4) or not np.isfinite(t).all() or
        not np.allclose(t[3], [0, 0, 0, 1], atol=1e-4) or
        not np.allclose(t[:3, :3].T @ t[:3, :3], np.eye(3), atol=0.02) or
        not np.isclose(np.linalg.det(t[:3, :3]), 1, atol=0.02)):
        raise ValueError("无效刚体变换")
    return t


def require_independent(map_scan, query_scan):
    m, q = map_scan.meta, query_scan.meta
    if m["role"] != "map" or q["role"] != "query":
        raise ValueError("必须选择建图包作为 map、独立查询包作为 query")
    if m["scan_id"] == q["scan_id"] or m["session_id"] == q["session_id"]:
        raise ValueError("建图和查询来自相同会话，不能用于独立定位验证")
