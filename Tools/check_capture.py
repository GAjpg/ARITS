#!/usr/bin/env python3
"""Inspect a real ARProbe run/ZIP. No localization server or GPU required."""
import argparse
import hashlib
import html
import json
import math
from pathlib import Path, PurePosixPath
import shutil
import tempfile
import zipfile

try:
    from PIL import Image, ImageDraw
except ImportError:
    raise SystemExit("需要 Pillow：python3 -m pip install -r Tools/requirements.txt")


def read_json(path):
    return json.loads(path.read_text(encoding="utf-8"))


def safe_file(root, relative):
    if not isinstance(relative, str):
        raise ValueError("文件路径必须是字符串")
    item = PurePosixPath(relative)
    if item.is_absolute() or ".." in item.parts or "\\" in relative:
        raise ValueError("包内出现不安全的文件路径")
    result = root.joinpath(*item.parts)
    if not result.resolve().is_relative_to(root.resolve()):
        raise ValueError("文件路径越出测试包")
    return result


def extract_checked(source, destination):
    with zipfile.ZipFile(source) as archive:
        entries = archive.infolist()
        if len(entries) > 10_000 or sum(x.file_size for x in entries) > 2 * 1024**3:
            raise ValueError("ZIP 超过检查器首版限制：最多 10000 文件、解压后 2 GB")
        paths = set()
        for entry in entries:
            output = safe_file(destination, entry.filename)
            if output in paths:
                raise ValueError("ZIP 中存在重复路径")
            paths.add(output)
            if (entry.external_attr >> 16) & 0o170000 == 0o120000:
                raise ValueError("ZIP 中不允许符号链接")
            if entry.is_dir():
                output.mkdir(parents=True, exist_ok=True)
            else:
                output.parent.mkdir(parents=True, exist_ok=True)
                with archive.open(entry) as reader, output.open("wb") as writer:
                    shutil.copyfileobj(reader, writer, 131_072)
    roots = list(destination.glob("*/run.json"))
    if (destination / "run.json").is_file():
        return destination
    if len(roots) != 1:
        raise ValueError("ZIP 应包含且只包含一个测试记录目录")
    return roots[0].parent


def matrix_valid(matrix):
    if not isinstance(matrix, list) or len(matrix) != 4 or any(not isinstance(row, list) or len(row) != 4 for row in matrix):
        return False
    if any(not isinstance(v, (int, float)) or not math.isfinite(v) for row in matrix for v in row):
        return False
    if any(abs(matrix[3][i] - [0, 0, 0, 1][i]) > 1e-4 for i in range(4)):
        return False
    for a in range(3):
        for b in range(3):
            dot = sum(matrix[r][a] * matrix[r][b] for r in range(3))
            if abs(dot - (1 if a == b else 0)) > 0.02:
                return False
    m = matrix
    determinant = m[0][0] * (m[1][1]*m[2][2] - m[1][2]*m[2][1]) - m[0][1] * (m[1][0]*m[2][2] - m[1][2]*m[2][0]) + m[0][2] * (m[1][0]*m[2][1] - m[1][1]*m[2][0])
    return abs(determinant - 1) < 0.02


def project(point, matrix, intrinsics):
    delta = [point[i] - matrix[i][3] for i in range(3)]
    camera = [sum(matrix[r][c] * delta[r] for r in range(3)) for c in range(3)]
    depth = -camera[2]
    if depth <= 0.001:
        return None
    return (intrinsics["fx"]*camera[0]/depth + intrinsics["cx"],
            -intrinsics["fy"]*camera[1]/depth + intrinsics["cy"])


def sha256(path):
    result = hashlib.sha256()
    with path.open("rb") as reader:
        for block in iter(lambda: reader.read(131_072), b""):
            result.update(block)
    return result.hexdigest()


def inspect_world_map(root, run, events):
    """Verify portable inputs and SDK evidence; never infer physical alignment."""
    config = run.get("configuration", {})
    if not config.get("world_map_test"):
        return None
    if run.get("data_kind") == "simulation":
        raise ValueError("环境地图恢复实验不能使用模拟数据")
    folder = root / "input-world-map"
    required = {"map.json", "route.json", "environment.arworldmap", "reference.jpg", "reference.json"}
    manifest = read_json(folder / "files.json")
    entries = manifest["files"]
    if len(entries) != len(required) or {e["path"] for e in entries} != required:
        raise ValueError("环境地图输入清单不完整")
    for entry in entries:
        path = safe_file(folder, entry["path"])
        if not path.is_file() or path.stat().st_size != entry["bytes"] or sha256(path) != entry["sha256"]:
            raise ValueError("环境地图输入哈希不符")
    meta, route = read_json(folder / "map.json"), read_json(folder / "route.json")
    map_id = config["world_map_id"]
    if (meta["map_id"] != map_id or route["route_id"] != map_id or meta["name"] != route["name"] or
        meta["source_session_id"] != config["world_map_source_session"] or
        meta["source_session_id"] == run["session_id"] or
        meta.get("localization_provider") != "arkit_world_map" or
        meta.get("map_format") != "ARWorldMap_secure_archive_ios_only" or
        meta.get("saved_mapping_status") != "mapped" or meta.get("physical_alignment_verified") is not False or
        not matrix_valid(meta.get("anchor_to_map")) or not matrix_valid(meta.get("route_to_anchor"))):
        raise ValueError("环境地图标识、来源会话或坐标信息无效")
    if route.get("schema_version") != 1 or route.get("coordinate_system") != "route_local_m_y_up_forward_minus_z":
        raise ValueError("独立路线格式无效")
    nodes, edges = route["nodes"], route["edges"]
    if not 2 <= len(nodes) <= 3 or len(edges) != len(nodes)-1 or len({n["id"] for n in nodes}) != len(nodes):
        raise ValueError("独立路线节点或连接不完整")
    for i, edge in enumerate(edges):
        a, b = nodes[i]["position"], nodes[i+1]["position"]
        coordinates = [a[k] for k in ("x","y","z")] + [b[k] for k in ("x","y","z")]
        if any(not isinstance(v,(int,float)) or not math.isfinite(v) for v in coordinates):
            raise ValueError("独立路线坐标无效")
        distance = math.hypot(b["x"]-a["x"], b["z"]-a["z"])
        if edge["from"] != nodes[i]["id"] or edge["to"] != nodes[i+1]["id"] or abs(edge["length_m"]-distance) > 1e-6:
            raise ValueError("独立路线连接或长度无效")
    reference = read_json(folder / "reference.json")
    with Image.open(folder / "reference.jpg") as image:
        image.load()
        if image.size != (reference["image"]["width"], reference["image"]["height"]):
            raise ValueError("环境地图参考图尺寸不符")
    if not matrix_valid(reference.get("camera_to_session")):
        raise ValueError("环境地图参考相机坐标无效")
    requested = [e for e in events if e.get("event") == "world_map_restore_requested"]
    restored = [e for e in events if e.get("event") == "world_map_sdk_restored"]
    observed = [e for e in events if e.get("event") == "world_map_target_anchor_observed"]
    if len(requested) != 1 or requested[0].get("map_id") != map_id:
        raise ValueError("缺少环境地图恢复请求或地图标识错误")
    if len(restored) > 1:
        raise ValueError("同一实验记录重复报告地图恢复")
    for event in restored:
        if (event.get("map_id") != map_id or event.get("anchor_id") != meta["origin_anchor_id"] or
            event.get("physical_alignment_verified") is not False or
            event.get("visual_model_inference_performed") is not False or
            not matrix_valid(event.get("anchor_to_session")) or
            not 0.5 <= event.get("restore_seconds", -1) < 60 or
            not any(e.get("anchor_id") == meta["origin_anchor_id"] for e in observed)):
            raise ValueError("地图恢复证据不完整或错误宣称精度")
    if any(e.get("event") == "photo_calibration_applied" for e in events):
        raise ValueError("环境地图恢复实验混入了人工照片校准")
    summary = read_json(root / "summary.json")
    if bool(summary.get("world_map_sdk_restored")) != bool(restored):
        raise ValueError("环境地图恢复汇总与事件不符")
    assessments = [e for e in events if e.get("event") == "world_map_alignment_assessed"]
    if assessments and not restored:
        raise ValueError("尚未恢复地图却记录了对齐确认")
    for e in assessments:
        if e.get("source") != "human_observation" or e.get("numeric_accuracy_measured") is not False or not isinstance(e.get("aligned"), bool):
            raise ValueError("地图对齐反馈来源不明确")
    return {"map_id": map_id, "name": meta["name"], "sdk_restored": bool(restored),
            "restore_seconds": restored[0]["restore_seconds"] if restored else None,
            "human_alignment": ("aligned" if assessments[-1]["aligned"] else "misaligned") if assessments else "not_checked"}


def inspect(root, output):
    failures, warnings, cards = [], [], []
    photo_selections = {}
    photo_applied = 0
    photo_rejected = 0
    all_events = []
    world_map_result = None
    output.mkdir(parents=True, exist_ok=True)
    assets = output / "assets"
    assets.mkdir(exist_ok=True)
    required = ["run.json", "summary.json", "files.json", "poses.jsonl", "camera-events.jsonl", "anchors.jsonl", "events.jsonl", "measurements.csv"]
    for name in required:
        if not (root / name).is_file():
            failures.append("缺少文件：" + name)
    try:
        run = read_json(root / "run.json")
    except (ValueError, OSError) as error:
        raise ValueError("run.json 无法读取：" + str(error)) from error
    if run.get("state") != "finished":
        warnings.append("此记录没有正常结束，先检查中断和未提交样本。")
    run_id, session_id = run.get("run_id"), run.get("session_id")
    simulation = run.get("data_kind") == "simulation"
    if simulation and run.get("is_real_ar_capture") is not False:
        failures.append("模拟记录缺少明确的非实拍标记。")
    try:
        manifest = read_json(root / "files.json")
        seen_paths = set()
        for entry in manifest["files"]:
            relative = entry["path"]
            if relative in seen_paths:
                failures.append("清单重复路径：" + relative)
            seen_paths.add(relative)
            file = safe_file(root, relative)
            if not file.is_file():
                failures.append("清单文件缺失：" + relative)
            elif file.stat().st_size != entry["bytes"] or sha256(file) != entry["sha256"]:
                failures.append("文件大小或哈希不符：" + relative)
    except (ValueError, OSError, KeyError, TypeError) as error:
        failures.append("文件清单无法完整验证：" + str(error))
        seen_paths = set()

    for name in ["poses.jsonl", "camera-events.jsonl", "anchors.jsonl", "events.jsonl"]:
        file = root / name
        if not file.exists():
            continue
        previous = None
        previous_by_event = {}
        event_interleaving_reported = False
        count = 0
        try:
            with file.open(encoding="utf-8") as stream:
                for line_number, line in enumerate(stream, 1):
                    if not line.strip():
                        continue
                    record = json.loads(line)
                    if name == "events.jsonl":
                        all_events.append(record)
                        if record.get("event") == "photo_calibration_points_submitted":
                            photo_selections[record.get("query_frame_id")] = record.get("raw_pixels")
                        if record.get("event") == "photo_calibration_applied":
                            photo_applied += 1
                            if record.get("source") != "manual_photo_points" or record.get("visual_model_inference_performed") is not False:
                                raise ValueError("手动照片绑定缺少明确的非模型推理标记")
                        if record.get("event") == "photo_calibration_rejected":
                            photo_rejected += 1
                    count += 1
                    if record.get("session_id") != session_id or record.get("run_id") != run_id:
                        raise ValueError(f"第 {line_number} 行会话/测试 ID 不符")
                    stamp = record.get("timestamp")
                    if stamp is not None:
                        if not isinstance(stamp, (int, float)) or not math.isfinite(stamp):
                            raise ValueError(f"第 {line_number} 行时间戳无效")
                        if name == "events.jsonl":
                            # User actions read currentFrame, while queued camera callbacks
                            # refer to their own ARFrame. Their shared log is append order,
                            # not a single chronological stream of frame timestamps.
                            event_kind = record.get("event")
                            same_event_previous = previous_by_event.get(event_kind)
                            if same_event_previous is not None and stamp < same_event_previous:
                                raise ValueError(f"第 {line_number} 行同类事件时间倒退")
                            previous_by_event[event_kind] = stamp
                            if previous is not None and stamp < previous and not event_interleaving_reported:
                                warnings.append("events.jsonl：用户操作与相机回调的不同事件时间交错；已分别检查各类事件的时间顺序。")
                                event_interleaving_reported = True
                        elif previous is not None and stamp < previous:
                            raise ValueError(f"第 {line_number} 行时间倒退")
                        previous = stamp
                    if name == "poses.jsonl" and not matrix_valid(record.get("matrix")):
                        raise ValueError(f"第 {line_number} 行姿态矩阵无效")
        except (ValueError, OSError, TypeError) as error:
            failures.append(name + "：" + str(error))
        if count == 0:
            warnings.append(name + " 没有样本。")

    try:
        world_map_result = inspect_world_map(root, run, all_events)
    except (ValueError, OSError, KeyError, TypeError, IndexError) as error:
        failures.append("环境地图实验：" + str(error))

    metadata_files = sorted((root / "frames").glob("*.json"))
    jpg_files = sorted((root / "frames").glob("*.jpg"))
    if {x.stem for x in metadata_files} != {x.stem for x in jpg_files}:
        failures.append("图片和 JSON 没有完整一一配对。")
    timestamps = set()
    valid_frames = 0
    for metadata in metadata_files:
        try:
            frame = read_json(metadata)
            if frame["frame_id"] != metadata.stem or frame["run_id"] != run_id or frame["session_id"] != session_id:
                raise ValueError("帧 ID 或会话 ID 不符")
            relative = frame["image"]["path"]
            image_file = safe_file(root, relative)
            if image_file != metadata.with_suffix(".jpg"):
                raise ValueError("图片路径和帧 ID 不符")
            if relative not in seen_paths or str(metadata.relative_to(root)) not in seen_paths:
                raise ValueError("图片或元数据未列入导出清单")
            with Image.open(image_file) as raw:
                raw.load()
                image = raw.convert("RGB")
            width, height = image.size
            if (width, height) != (frame["image"]["saved_width"], frame["image"]["saved_height"]):
                raise ValueError("解码图片尺寸与元数据不同")
            if frame["image"].get("rotation_deg") != 0 or frame["image"].get("mirrored") is not False:
                raise ValueError("首版检查器仅支持未旋转、未镜像的传感器方向图片")
            intrinsics = frame["intrinsics"]
            if (intrinsics["reference_width"], intrinsics["reference_height"]) != (width, height):
                raise ValueError("内参参考尺寸与图片不同，需要明确像素适配")
            for key in ["fx", "fy", "cx", "cy"]:
                if not isinstance(intrinsics[key], (int, float)) or not math.isfinite(intrinsics[key]):
                    raise ValueError("内参包含无效值")
            if intrinsics["fx"] <= 0 or intrinsics["fy"] <= 0:
                raise ValueError("焦距无效")
            pose = frame["pose"]
            if pose.get("direction") != "camera_to_session" or pose.get("coordinate_system") != "arkit_right_handed_y_up_camera_forward_minus_z" or not matrix_valid(pose.get("matrix")):
                raise ValueError("相机姿态或坐标约定无效")
            frame_is_simulation = frame.get("data_kind") == "simulation"
            if frame_is_simulation != simulation:
                raise ValueError("模拟与真实记录的数据模式不匹配")
            stamp = frame["timing"]["simulation_timestamp_seconds" if simulation else "ar_frame_timestamp_seconds"]
            if not isinstance(stamp, (int, float)) or not math.isfinite(stamp):
                raise ValueError("图像时间戳无效")
            if stamp in timestamps:
                raise ValueError("重复相机帧时间戳")
            timestamps.add(stamp)
            if not simulation and frame["timing"].get("pose_association") != "same_ARFrame":
                warnings.append(metadata.stem + "：姿态不是来自同一 ARFrame。")
            validity = frame.get("validity", {})
            ground = frame.get("calibration_geometry")
            if ground is not None:
                if not isinstance(ground, dict):
                    raise ValueError("照片校准地面快照格式无效")
                boundary = ground.get("boundary_xz_m", [])
                if (ground.get("source") != "same_ARFrame_horizontal_plane_snapshot" or
                    not matrix_valid(ground.get("plane_to_session")) or len(boundary) < 3 or
                    any(not isinstance(p, list) or len(p) != 2 or
                        any(not isinstance(v, (int, float)) or not math.isfinite(v) for v in p) for p in boundary)):
                    raise ValueError("照片校准的地面快照不完整或无效")
            selection = photo_selections.get(frame["frame_id"])
            if selection is not None:
                if ground is None or not isinstance(selection, list) or len(selection) != 2:
                    raise ValueError("照片选点缺少对应的地面快照")
                for p in selection:
                    if (not isinstance(p, list) or len(p) != 2 or
                        any(not isinstance(v, (int, float)) or not math.isfinite(v) for v in p) or
                        not 0 <= p[0] < width or not 0 <= p[1] < height):
                        raise ValueError("照片选点超出原图或坐标无效")
            if simulation and (frame.get("is_real_ar_capture") is not False or
                               validity.get("image_geometry_verified") or
                               validity.get("ready_for_visual_localization_query") or validity.get("ready_for_ar_alignment")):
                raise ValueError("模拟图片不能标记为真实定位或 AR 对齐输入")
            if validity.get("ready_for_ar_alignment") and not validity.get("image_geometry_verified"):
                raise ValueError("几何未验证却声称可用于 AR 对齐")
            valid_frames += 1
            if len(cards) < 60:
                image.thumbnail((960, 720))
                scale_x, scale_y = image.width/width, image.height/height
                draw = ImageDraw.Draw(image)
                for point in frame.get("route", {}).get("test_points_session", []):
                    pixel = project(point["session"], pose["matrix"], intrinsics)
                    if pixel and 0 <= pixel[0] < width and 0 <= pixel[1] < height:
                        x,y = pixel[0]*scale_x, pixel[1]*scale_y
                        draw.line((x-8,y,x+8,y), fill="#ffcc00", width=3)
                        draw.line((x,y-8,x,y+8), fill="#ffcc00", width=3)
                if selection is not None:
                    for label, p, color in zip(["A", "B"], selection, ["#00ffff", "#ff9933"]):
                        x, y = p[0] * scale_x, p[1] * scale_y
                        draw.ellipse((x-10,y-10,x+10,y+10), outline=color, width=3)
                        draw.text((x+12,y-8), label, fill=color)
                preview = assets / (metadata.stem + ".jpg")
                image.save(preview, quality=85)
                cards.append((metadata.stem, "assets/" + preview.name, stamp))
        except (ValueError, OSError, KeyError, TypeError, IndexError) as error:
            failures.append(metadata.stem + "：" + str(error))
    if valid_frames < 10 and not simulation:
        warnings.append(f"只有 {valid_frames} 个结构合格样本，现场取帧用例至少需要 10 个不同视角。")
    if simulation:
        warnings.append("SIMULATION：全部图片、内参与姿态来自虚拟场景，仅验证保存与导出流程，不用于训练或定位精度验收。")
        warnings.append("黄色十字是合成测试点的投影，图片本身包含虚拟路线和模拟水印。")
    else:
        warnings.append("同一 ARFrame 提供 SDK 关联，仍需验证图像光学方向、真实地面漂移和动态投影。")
        warnings.append("黄色十字是 AR 估计测试点的预测投影；需对照真实地标，不能据此自动给出定位精度。")
    if photo_selections or photo_applied or photo_rejected:
        warnings.append(f"手动照片校准：选点 {len(photo_selections)} 次，应用 {photo_applied} 次，拒绝 {photo_rejected} 次；当前没有图像识别模型。彩色 A、B 圆圈是人工选点。")
    if world_map_result:
        warnings.append(f"环境地图实验：SDK 恢复 {world_map_result['sdk_restored']}，用时 {world_map_result['restore_seconds']} 秒；人工反馈 {world_map_result['human_alignment']}。恢复与人工确认均不等于独立数值精度测量。")
    frame_ids = {p.stem for p in metadata_files}
    if any(frame_id not in frame_ids for frame_id in photo_selections):
        failures.append("照片校准事件引用了不存在的相机帧。")
    result = "FAIL" if failures else ("SIMULATION" if simulation else "UNVERIFIED")
    summary = {"status": result, "file_structure": "FAIL" if failures else "PASS",
               "field_validation": "NOT_APPLICABLE_SIMULATION" if simulation else "UNVERIFIED", "run_id": run_id,
               "data_kind": "simulation" if simulation else "real_ar_capture",
               "manual_photo_selections": len(photo_selections), "manual_photo_calibrations_applied": photo_applied,
               "manual_photo_calibrations_rejected": photo_rejected,
               "valid_frames": valid_frames, "failures": failures, "warnings": warnings}
    if world_map_result: summary["world_map_test"] = world_map_result
    (output / "result.json").write_text(json.dumps(summary, ensure_ascii=False, indent=2), encoding="utf-8")
    escape = html.escape
    lists = "".join(f"<li>{escape(item)}</li>" for item in failures + warnings)
    photos = "".join(f'<article><img src="{escape(path, quote=True)}"><p>{escape(name)} · t={stamp:.3f}s</p></article>' for name,path,stamp in cards)
    body = f'''<!doctype html><html lang="zh-CN"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>AR 测试数据检查</title><style>body{{margin:0;background:#0c1723;color:#e7eff5;font:16px system-ui}}main{{max-width:1100px;margin:40px auto;padding:24px}}h1{{font-size:30px}}.status{{padding:16px;background:#183b35;border-radius:16px}}li{{margin:12px 0}}.grid{{display:grid;grid-template-columns:repeat(auto-fit,minmax(280px,1fr));gap:18px}}article{{background:#172534;border-radius:14px;overflow:hidden}}img{{width:100%;display:block}}article p{{padding:0 14px;font-size:13px}}</style>
<main><h1>{'模拟预览数据检查 · SIMULATION' if simulation else '走廊 AR 测试检查'}</h1><p>{escape(str(run_id))}</p><div class="status">文件结构：{summary['file_structure']} · 合格图像：{valid_frames} · 现场与几何验收：{summary['field_validation']}</div>
<ul>{lists}</ul><h2>{'模拟图片与合成预测点' if simulation else '真实图片与预测点'}</h2><p>下列缩略图为独立报告预览，原始图片未被修改。</p><div class="grid">{photos}</div></main></html>'''
    (output / "index.html").write_text(body, encoding="utf-8")
    return summary


def main():
    parser = argparse.ArgumentParser(description="检查 ARProbe 的真实导出目录或 ZIP，生成本地 HTML 报告")
    parser.add_argument("input", type=Path)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    source = args.input.resolve()
    output = (args.output or source.parent / (source.stem + "_report")).resolve()
    try:
        if source.is_dir():
            summary = inspect(source, output)
        else:
            with tempfile.TemporaryDirectory(prefix="arprobe-inspect-") as temporary:
                summary = inspect(extract_checked(source, Path(temporary)), output)
        print(f"文件结构：{summary['file_structure']}；现场验收：{summary['field_validation']}")
        print("报告：" + str(output / "index.html"))
        return 1 if summary["failures"] else 0
    except (ValueError, OSError, zipfile.BadZipFile) as error:
        print("检查失败：" + str(error))
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
