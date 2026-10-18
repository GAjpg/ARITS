#!/usr/bin/env python3
"""CPU-only stage-one geometry localization. Never uses ground truth as a seed."""
import argparse
import csv
import html
import json
import math
import os
import time
import tempfile
from pathlib import Path

os.environ.setdefault("OMP_NUM_THREADS", "4")
os.environ.setdefault("OPENBLAS_NUM_THREADS", "4")
os.environ.setdefault("MPLCONFIGDIR", str(Path(tempfile.gettempdir())/"lidarprobe-matplotlib"))
import numpy as np
from lidar_data import Scan, require_independent, validate_transform


def cloud(points, voxel):
    import open3d as o3d
    c = o3d.geometry.PointCloud(o3d.utility.Vector3dVector(points))
    c = c.voxel_down_sample(voxel)
    if len(c.points) < 150:
        raise ValueError("有效几何太少（降采样后不足 150 点）")
    c.estimate_normals(o3d.geometry.KDTreeSearchParamHybrid(radius=voxel*2.5, max_nn=40))
    return c


def features(c, voxel):
    import open3d as o3d
    return o3d.pipelines.registration.compute_fpfh_feature(
        c, o3d.geometry.KDTreeSearchParamHybrid(radius=voxel*5, max_nn=100))


def angle(t):
    return math.degrees(math.atan2(t[0, 2], t[2, 2]))


def delta(a, b):
    distance = float(np.linalg.norm(a[:3, 3]-b[:3, 3]))
    rotation = abs((angle(a)-angle(b)+180) % 360-180)
    return distance, rotation


def solve(map_points, query_points, heldout_points, voxel=0.10, attempts=3, iterations=50000):
    import open3d as o3d
    from scipy.spatial import cKDTree
    reg = o3d.pipelines.registration
    started = time.perf_counter()
    target = cloud(map_points, voxel)
    source = cloud(query_points, voxel)
    tf, sf = features(target, voxel), features(source, voxel)
    fine_target = cloud(map_points, voxel/2)
    fine_source = cloud(query_points, voxel/2)
    heldout = cloud(heldout_points, voxel/2)
    threshold = voxel*1.2
    tree = cKDTree(np.asarray(fine_target.points))
    candidates = []
    for i in range(attempts):
        o3d.utility.random.seed(57+i*101)
        coarse = reg.registration_ransac_based_on_feature_matching(
            source, target, sf, tf, True, voxel*1.5,
            reg.TransformationEstimationPointToPoint(False), 3,
            [reg.CorrespondenceCheckerBasedOnEdgeLength(0.9),
             reg.CorrespondenceCheckerBasedOnDistance(voxel*1.5)],
            reg.RANSACConvergenceCriteria(iterations, 0.999))
        if len(coarse.correspondence_set) < 10:
            continue
        fine = reg.registration_icp(
            fine_source, fine_target, threshold, coarse.transformation,
            reg.TransformationEstimationPointToPlane(reg.TukeyLoss(k=threshold)),
            reg.ICPConvergenceCriteria(max_iteration=60))
        t = validate_transform(fine.transformation)
        evaluation = reg.evaluate_registration(heldout, fine_target, threshold, t)
        up_angle = math.degrees(math.acos(float(np.clip(t[1, 1], -1, 1))))
        p = np.asarray(heldout.points) @ t[:3, :3].T + t[:3, 3]
        distances, nearest = tree.query(p, workers=2)
        mask = distances < threshold
        normals = np.asarray(fine_target.normals)[nearest[mask]]
        eigen = np.linalg.eigvalsh(normals.T@normals/max(1, len(normals)))
        ratio = float(eigen[0]/max(eigen[-1], 1e-12))
        coverage = float(evaluation.fitness)
        rmse = float(evaluation.inlier_rmse)
        candidates.append({"attempt": i, "transform_query_to_map": t.tolist(),
                           "fit_overlap": float(fine.fitness), "heldout_overlap": coverage,
                           "heldout_rmse_m": rmse, "gravity_error_deg": up_angle,
                           "normal_eigenvalues": eigen.tolist(), "normal_min_max_ratio": ratio,
                           "quality_gate": coverage >= 0.45 and rmse <= threshold and up_angle <= 8 and ratio >= 0.015})
    candidates.sort(key=lambda c: (c["quality_gate"], c["heldout_overlap"] - c["heldout_rmse_m"]), reverse=True)
    if not candidates:
        return {"status": "rejected", "reason": "没有找到足够的几何对应", "candidates": [],
                "registration_seconds": time.perf_counter()-started}, None
    best = candidates[0]
    ambiguity = False
    for c in candidates[1:]:
        if c["quality_gate"] and c["heldout_overlap"] >= best["heldout_overlap"]-0.08:
            distance, yaw = delta(np.array(c["transform_query_to_map"]), np.array(best["transform_query_to_map"]))
            if distance > 0.5 or yaw > 8:
                ambiguity = True
    status = "candidate_requires_review" if best["quality_gate"] else "rejected"
    reason = "几何质量门槛通过，仍需独立真值或现场核对；不是已证实定位成功"
    if not best["quality_gate"]:
        reason = "重叠率、残差、重力方向或几何约束不足；不输出可信位置"
    elif ambiguity:
        status, reason = "ambiguous", "找到分数接近但位置不同的结果，不能确定唯一位置"
    return {"status": status, "reason": reason, "best": best, "candidates": candidates,
            "registration_seconds": time.perf_counter()-started,
            "thresholds": {"min_heldout_overlap": 0.45, "max_rmse_m": threshold,
                           "max_gravity_deg": 8, "min_normal_eigen_ratio": 0.015},
            "points": {"map": len(fine_target.points), "query_fit": len(fine_source.points), "query_heldout": len(heldout.points)}}, np.array(best["transform_query_to_map"])


def write_visuals(output, map_points, query_points, t, report):
    import open3d as o3d
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    output.mkdir(parents=True, exist_ok=True)
    transformed = query_points @ t[:3, :3].T + t[:3, 3] if t is not None else query_points
    m = o3d.geometry.PointCloud(o3d.utility.Vector3dVector(map_points)).voxel_down_sample(0.05)
    q = o3d.geometry.PointCloud(o3d.utility.Vector3dVector(transformed)).voxel_down_sample(0.05)
    m.paint_uniform_color([0.18, 0.55, 0.85]);q.paint_uniform_color([0.98, 0.47, 0.12])
    o3d.io.write_point_cloud(str(output/"overlay.ply"), m+q)
    fig, axes = plt.subplots(1, 2, figsize=(12, 5.5), constrained_layout=True)
    for ax, (x, y, title, xlabel, ylabel) in zip(axes, [(0, 2, "Top view", "X (m)", "Z (m)"), (0, 1, "Front view", "X (m)", "Y (m)")]):
        mp = np.asarray(m.points)[::max(1, len(m.points)//18000)]
        qp = np.asarray(q.points)[::max(1, len(q.points)//10000)]
        ax.scatter(mp[:, x], mp[:, y], s=1, c="#328bd1", label="Map", alpha=0.35)
        ax.scatter(qp[:, x], qp[:, y], s=2, c="#fa781f", label="Query after registration" if t is not None else "Query: no match", alpha=0.6)
        if t is not None:
            ax.scatter([t[x, 3]], [t[y, 3]], marker="x", c="black", s=70, label="Query session origin")
        ax.set(title=title, xlabel=xlabel, ylabel=ylabel);ax.set_aspect("equal");ax.grid(alpha=0.2);ax.legend(fontsize=8)
    fig.suptitle(report["status"]+" | geometry candidate, verify independently", fontsize=12)
    fig.savefig(output/"overlay.png", dpi=150);plt.close(fig)


def write_report(output, report):
    output.mkdir(parents=True, exist_ok=True)
    (output/"result.json").write_text(json.dumps(report, ensure_ascii=False, indent=2, allow_nan=False))
    text = html.escape(json.dumps(report, ensure_ascii=False, indent=2, allow_nan=False))
    title = html.escape(report.get("query_label", "LiDAR 验证"))
    (output/"index.html").write_text(f'''<!doctype html><html lang="zh"><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><title>{title}</title>
<style>body{{font:16px system-ui;max-width:1100px;margin:32px auto;padding:0 20px;background:#f5f7fa;color:#132639}}img{{width:100%;background:white;border-radius:16px}}pre{{white-space:pre-wrap;background:white;padding:20px;border-radius:16px}}.tag{{padding:8px 14px;border-radius:20px;background:#ffe3bc;display:inline-block}}</style>
<h1>{title}</h1><p class="tag">{html.escape(report['status'])}</p><p>{html.escape(report['reason'])}</p>
<p>蓝色：建图；橙色：配准后的查询；黑叉：查询会话原点。重叠图和低残差不能替代独立真值，重复走廊仍可能产生错误匹配。</p>
<img src="overlay.png" alt="地图与查询点云的俯视、正视叠加"><p><a href="overlay.ply">下载三维叠加点云</a> · <a href="result.json">完整 JSON 结果</a></p>
<details><summary>展开指标和候选位置</summary><pre>{text}</pre></details></html>''')


def run_registration(args):
    with Scan(args.map) as m:
        map_started = time.perf_counter()
        map_points = m.points(stride=args.stride, min_confidence=args.confidence)
        map_seconds = time.perf_counter()-map_started
        summaries = []
        truth = json.loads(Path(args.truth).read_text()) if args.truth else {}
        for path in args.query:
            started = time.perf_counter()
            query_id = Path(path).stem
            output = Path(args.out)/query_id
            try:
                with Scan(path) as q:
                    require_independent(m, q)
                    query_id = q.meta["scan_id"]
                    output = Path(args.out)/("query-"+query_id)
                    frames = q.meta["frames"]
                    fit_frames = [f for i, f in enumerate(frames) if i % 3 != 2]
                    held_frames = [f for i, f in enumerate(frames) if i % 3 == 2]
                    fit = q.points(fit_frames, args.stride, args.confidence)
                    held = q.points(held_frames, args.stride, args.confidence)
                    qp = np.concatenate([fit, held])
                    report, t = solve(map_points, fit, held, args.voxel, args.attempts, args.iterations)
                    report.update({"schema_version": 1, "map_id": m.meta["scan_id"], "query_id": query_id,
                        "query_label": q.meta["label"], "map_hardware": m.meta["hardware"], "query_hardware": q.meta["hardware"],
                        "initial_world_map_used": False, "independent_sessions": True,
                        "geometry_input": "raw depth, no saved preview, no RGB matching, no ground-truth seed",
                        "same_region_hint": m.meta["region_id"] == q.meta["region_id"],
                        "map_reconstruction_seconds": map_seconds,
                        "query_capture_seconds": frames[-1]["timestamp"]-frames[0]["timestamp"],
                        "processing_seconds": time.perf_counter()-started,
                        "truth_evaluation": "not_available_requires_manual_review",
                        "config": {k: getattr(args, k) for k in ("voxel", "attempts", "iterations", "stride", "confidence")}})
                    if query_id in truth and t is not None:
                        expected = validate_transform(truth[query_id]["query_to_map"])
                        translation, yaw = delta(t, expected)
                        report["truth_evaluation"] = {"translation_error_m": translation, "yaw_error_deg": yaw,
                            "independent_truth_required": True, "note": "仅在求解结束后评估，未参与初始化或候选选择"}
                    write_visuals(output, map_points, qp, t, report)
                    report["processing_and_visualization_seconds"] = time.perf_counter()-started
                    write_report(output, report)
                    print(f"{q.meta['label']}: {report['status']} → {output/'index.html'}", flush=True)
                    summaries.append({"query": q.meta["label"], "id": query_id, "status": report["status"],
                        "seconds": report["processing_seconds"], "truth": str(report["truth_evaluation"])})
            except Exception as e:
                report = {"status": "invalid_trial", "reason": str(e), "query_label": query_id}
                output.mkdir(parents=True, exist_ok=True)
                (output/"error.json").write_text(json.dumps(report, ensure_ascii=False, indent=2))
                summaries.append({"query": query_id, "id": query_id, "status": "invalid_trial", "seconds": time.perf_counter()-started, "truth": str(e)})
                print(f"{query_id}: invalid_trial: {e}", flush=True)
        Path(args.out).mkdir(parents=True, exist_ok=True)
        with (Path(args.out)/"summary.csv").open("w", newline="", encoding="utf-8-sig") as f:
            writer = csv.DictWriter(f, fieldnames=["query", "id", "status", "seconds", "truth"])
            writer.writeheader();writer.writerows(summaries)
        return 2 if any(s["status"] == "invalid_trial" for s in summaries) else 0


def main():
    p = argparse.ArgumentParser(description=__doc__)
    sub = p.add_subparsers(dest="command", required=True)
    check = sub.add_parser("check", help="校验文件、坐标、JPEG 尺寸和深度；允许检查中断包")
    check.add_argument("scan")
    register = sub.add_parser("register", help="无初始位置猜测的 FPFH/RANSAC + ICP 配准")
    register.add_argument("--map", required=True)
    register.add_argument("--query", nargs="+", required=True)
    register.add_argument("--out", default="work/lidar-report")
    register.add_argument("--voxel", type=float, default=0.10)
    register.add_argument("--attempts", type=int, default=3)
    register.add_argument("--iterations", type=int, default=50000)
    register.add_argument("--stride", type=int, default=4)
    register.add_argument("--confidence", type=int, choices=[1, 2], default=1)
    register.add_argument("--truth", help="按 scan_id 索引的独立真值 JSON，只用于事后误差统计")
    args = p.parse_args()
    try:
        if args.command == "check":
            with Scan(args.scan, allow_incomplete=True) as scan:
                points = scan.points()
                print(json.dumps({"state": scan.meta["state"], "role": scan.meta["role"],
                    "label": scan.meta["label"], "scan_id": scan.meta["scan_id"],
                    "frames": len(scan.meta["frames"]), "sampled_points": len(points),
                    "bounds": [points.min(axis=0).tolist(), points.max(axis=0).tolist()] if len(points) else None,
                    "hardware": scan.meta["hardware"], "checksums": "verified"}, ensure_ascii=False, indent=2))
                return 0
        if not (0.04 <= args.voxel <= 0.3 and 3 <= args.attempts <= 8 and 1000 <= args.iterations <= 200000 and 1 <= args.stride <= 16):
            p.error("参数范围：voxel 0.04–0.3，attempts 3–8，iterations 1000–200000，stride 1–16")
        return run_registration(args)
    except ImportError as e:
        p.exit(1, f"缺少依赖：{e}。请先运行 Tools/setup_lidar.sh\n")
    except Exception as e:
        p.exit(1, str(e)+"\n")


if __name__ == "__main__":
    raise SystemExit(main())
