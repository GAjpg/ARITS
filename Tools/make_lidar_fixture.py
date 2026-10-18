#!/usr/bin/env python3
"""Deterministic SYNTHETIC fixtures, not phone measurements or accuracy evidence."""
import argparse
import hashlib
import json
import uuid
import zipfile
from pathlib import Path

import numpy as np
from PIL import Image


def pose(x=0, y=1.4, z=0, yaw=0):
    a = np.deg2rad(yaw)
    t = np.array([[np.cos(a), 0, np.sin(a), x], [0, 1, 0, y], [-np.sin(a), 0, np.cos(a), z], [0, 0, 0, 1]])
    return t


def checksum(root):
    files = [{"path": p.relative_to(root).as_posix(), "bytes": p.stat().st_size,
              "sha256": hashlib.sha256(p.read_bytes()).hexdigest()}
             for p in sorted(root.rglob("*")) if p.is_file() and p.name != "files.json"]
    (root/"files.json").write_text(json.dumps({"schema_version": 1, "files": files}, indent=2))


def render(t, negative=False):
    # Optical rays use z=-1, so the intersection parameter is exactly ARKit's
    # optical depth, not the length of the slanted ray.
    v, u = np.mgrid[0:96, 0:128]
    local = np.stack([(u-64)/100, -(v-48)/100, -np.ones_like(u)], axis=-1)
    rays = local @ t[:3, :3].T
    origin = t[:3, 3]
    depth = np.full((96, 128), np.inf)
    # Room planes, plus two asymmetric boxes.
    for axis, values in enumerate(([-3, 3], [0, 3.2], [-4, 4])):
        for value in values:
            if negative and not (axis == 1 and value == 0):
                continue
            with np.errstate(divide="ignore", invalid="ignore"):
                d = (value-origin[axis])/rays[..., axis]
            depth = np.minimum(depth, np.where(d > 0.2, d, np.inf))
    if not negative:
        for low, high in [(np.array([-2.2, 0, -1.5]), np.array([-1.2, 1.7, -0.8])),
                          (np.array([1.2, 0, -3.5]), np.array([2.4, 1.0, -2.6]))]:
            with np.errstate(divide="ignore", invalid="ignore"):
                a, b = (low-origin)/rays, (high-origin)/rays
            near, far = np.minimum(a, b).max(axis=-1), np.maximum(a, b).min(axis=-1)
            depth = np.minimum(depth, np.where((near > 0.2) & (far >= near), near, np.inf))
    good = np.isfinite(depth) & (depth <= 4.5)
    return np.where(good, depth, 0).astype("<f4"), np.where(good, 2, 0).astype("u1")


def write_scan(root, role, transforms, world_poses, negative=False):
    root.mkdir(parents=True, exist_ok=False)
    meta = dict(schema_version=1, kind="lidar_geometry_scan", scan_id=str(uuid.uuid4()), session_id=str(uuid.uuid4()),
                label="SYNTHETIC_"+root.name, role=role, building_id="synthetic", region_id="synthetic",
                region_name="SYNTHETIC_NOT_PHONE", lighting="other", created_utc="2026-10-16T00:00:00Z",
                initial_world_map_used=False, coordinate_system="ARKit_Y_up_camera_minus_Z_row_major_meters",
                depth_encoding="float32_little_endian_optical_z_meters", confidence_encoding="uint8_0_low_1_medium_2_high",
                image_orientation="native_capturedImage_no_rotation", depth_source="ARFrame.sceneDepth_unsmoothed",
                route_alignment="unbound_independent_session", state="complete", end_reason="synthetic_fixture",
                hardware="SYNTHETIC_NOT_PHONE", app_version="test", frames=[])
    c = dict(width=128, height=96, image_width=128, image_height=96, fx=100, fy=100, cx=64, cy=48)
    for i, (t, world_pose) in enumerate(zip(transforms, world_poses)):
        frame = root/f"frames/{i:04d}"
        frame.mkdir(parents=True)
        depth, confidence = render(world_pose, negative)
        depth.tofile(frame/"depth.f32");confidence.tofile(frame/"confidence.u8")
        Image.new("RGB", (128, 96), (50+i*10, 100, 120)).save(frame/"rgb.jpg")
        meta["frames"].append(dict(index=i, timestamp=100+i*0.5, camera_to_session=t.tolist(), calibration=c,
                                  valid_fraction=float((confidence > 0).mean()), exposure_duration=0.01,
                                  exposure_offset=0, tracking="normal"))
    (root/"scan.json").write_text(json.dumps(meta, indent=2))
    checksum(root)
    with zipfile.ZipFile(root.with_suffix(".zip"), "w", compression=zipfile.ZIP_STORED) as archive:
        for file in root.rglob("*"):
            if file.is_file():
                archive.write(file, root.name+"/"+file.relative_to(root).as_posix())
    return meta


def make(out):
    out = Path(out)
    out.mkdir(parents=True, exist_ok=True)
    map_poses = [pose(yaw=a) for a in range(-180, 180, 30)]
    # Map session origin is deliberately different from the query session.
    truth = pose(0.7, 0, 1.0, 37)
    world_poses = [pose(0.6+i*0.05, 1.4, 0.3, a) for i, a in enumerate([-30, -15, 0, 15, 30, 45, 60, 75, 90])]
    query_poses = [np.linalg.inv(truth)@t for t in world_poses]
    m = write_scan(out/"map", "map", map_poses, map_poses)
    q = write_scan(out/"query", "query", query_poses, world_poses)
    n = write_scan(out/"outside", "query", query_poses, world_poses, negative=True)
    (out/"truth.json").write_text(json.dumps({q["scan_id"]: {"query_to_map": truth.tolist(), "kind": "SYNTHETIC_EXACT"}}, indent=2))
    return m, q, n, truth


if __name__ == "__main__":
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--out", default="work/synthetic")
    args = p.parse_args()
    make(args.out)
    print("生成了明确标记 SYNTHETIC 的建图、查询和负例，不代表真机效果。")
