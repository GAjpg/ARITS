"""Replay the frozen dataset with the Swift solver and check it against external labels.

The solver never sees labels.json. Checks only use facts recorded there:
  - an out_of_map query must not come back as a single candidate;
  - a candidate labelled wrong must not be returned as a single candidate again;
  - single candidates should be stable between the 12-frame (App default) and full prefixes.
Results without raw depth are summarised from their stored candidates and marked as such.

usage: python3 Tools/frozen_eval.py --frozen work/frozen-v1 --replay work/bin/replay --tag v2b
"""
import argparse
import glob
import json
import math
import os
import subprocess
from pathlib import Path


def yaw(t):
    return math.degrees(math.atan2(t[0][2], t[0][0]))


def yaw_gap(a, b):
    return abs((a - b + 180) % 360 - 180)


def apply(t, p):
    return [t[r][3] + sum(t[r][c] * p[c] for c in range(3)) for r in range(3)]


def camera_gap(a, b, camera):
    """Yaw difference and how far the same camera lands in the map under two transforms."""
    pa = apply(a, [camera[0][3], camera[1][3], camera[2][3]])
    pb = apply(b, [camera[0][3], camera[1][3], camera[2][3]])
    return yaw_gap(yaw(a), yaw(b)), math.dist(pa, pb)


def scan_dir(frozen, scan_id, role):
    hits = glob.glob(f"{frozen}/extracted/lidar-{role}-{scan_id}/{role}-{scan_id}")
    return hits[0] if hits else None


FREE_SPACE = False


def replay(binary, map_dir, query_dir, frames, out):
    args = [binary, "--map", map_dir, "--query", query_dir, "--frames", frames, "--out", out]
    run = subprocess.run(args + (["--free-space"] if FREE_SPACE else []), capture_output=True, text=True)
    if run.returncode:
        raise RuntimeError(run.stderr.strip())
    return json.load(open(out))


def summary(r):
    best = r["candidates"][0] if r["candidates"] else None
    modes = r.get("modes") or []
    best_mode = next((m for m in modes if best and m["id"] == best.get("mode_id")), None)
    return {
        "status": r["status"], "reasons": r.get("decision_reasons") or [],
        "modes": len(modes), "gated_modes": sum(m["quality_gate"] for m in modes),
        "best_spread_m": best_mode.get("spread_along_axis_m") if best_mode else None,
        "seconds": round(r["registration_seconds"], 2),
        "search_complete": r.get("search_complete"),
        # Report-only: conflict rate / coverage of the best and of the gated rivals.
        "free_space": [
            {"mode": c.get("mode_id"), "gate": c["quality_gate"], "score": round(c["geometry_score"], 3),
             "yaw": round(yaw(c["transform_query_to_map"])),
             "conflict_rate": None if c["free_space"].get("conflict_rate") is None else round(c["free_space"]["conflict_rate"], 3),
             "coverage": round(c["free_space"]["coverage"], 2), "comparable": c["free_space"]["comparable"]}
            for c in r["candidates"] if c.get("free_space")] or None,
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--frozen", default="work/frozen-v1")
    ap.add_argument("--replay", default="work/bin/replay")
    ap.add_argument("--tag", default="current")
    ap.add_argument("--free-space", action="store_true", help="attach report-only free-space evidence")
    a = ap.parse_args()
    global FREE_SPACE
    FREE_SPACE = a.free_space
    frozen = a.frozen
    labels = json.load(open(f"{frozen}/labels.json"))
    out = Path(frozen) / "runs" / a.tag
    out.mkdir(parents=True, exist_ok=True)
    maps = {k: v for k, v in labels["maps"].items() if v.get("recomputable")}
    wrong = {c["query_scan_id"]: c for c in labels["candidate_labels"] if c["label"] == "wrong"}
    rows, failures = [], []

    for q in labels["queries"]:
        qdir = scan_dir(frozen, q["scan_id"], "query")
        first_camera = json.load(open(f"{qdir}/scan.json"))["frames"][0]["camera_to_session"]
        results = {}
        for frames in ("12", "all"):
            mdir = scan_dir(frozen, q["map_id"], "map")
            r = replay(a.replay, mdir, qdir, frames, str(out / f"{q['scan_id'][:8]}-own-f{frames}.json"))
            results[frames] = r
            s = summary(r)
            row = {"query": q["label"], "map": labels["maps"][q["map_id"]]["name"], "in_map": q["in_map"],
                   "frames": frames, **s, "checks": []}
            if q["in_map"] == "out_of_map" and r["status"] == "candidate_requires_review":
                row["checks"].append("FAIL out_of_map_returned_single")
            if q["scan_id"] in wrong and r["candidates"]:
                gy, gd = camera_gap(r["candidates"][0]["transform_query_to_map"], wrong[q["scan_id"]]["transform_query_to_map"], first_camera)
                row["vs_known_wrong"] = f"yaw {gy:.0f}°, camera {gd:.2f} m"
                if r["status"] == "candidate_requires_review" and gy < 15 and gd < 1:
                    row["checks"].append("FAIL known_wrong_returned_single")
            rows.append(row)
        singles = [f for f, r in results.items() if r["status"] == "candidate_requires_review"]
        if len(singles) == 2:
            gy, gd = camera_gap(results["12"]["candidates"][0]["transform_query_to_map"],
                                results["all"]["candidates"][0]["transform_query_to_map"], first_camera)
            rows[-1]["prefix_stability"] = f"12 vs all: yaw {gy:.1f}°, camera {gd:.2f} m"

        for other_id in maps:
            if other_id == q["map_id"]:
                continue
            r = replay(a.replay, scan_dir(frozen, other_id, "map"), qdir, "12", str(out / f"{q['scan_id'][:8]}-cross-{other_id[:8]}-f12.json"))
            rows.append({"query": q["label"], "map": labels["maps"][other_id]["name"], "in_map": labels["cross_map_pairs"]["in_map"],
                         "frames": "12", **summary(r), "checks": []})

    for row in rows:
        failures += [f"{row['query']} / {row['map']} / f{row['frames']}: {c}" for c in row["checks"]]

    # Stored on-device results without raw depth: structural diagnostics only.
    stored = []
    for run_id, info in labels["run_results"].items():
        if info.get("mode") != "navigation":
            continue
        files = sorted(glob.glob(f"{frozen}/extracted/{run_id}/{run_id}/localization-*.json"))
        bests = []
        for f in files:
            r = json.load(open(f))
            gated = [c for c in r["candidates"] if c["quality_gate"]]
            if not gated:
                stored.append({"run": run_id, "file": os.path.basename(f), "status": r["status"], "note": "no gated candidate"})
                continue
            b = gated[0]
            rivals = [c for c in gated[1:] if c["geometry_score"] >= b["geometry_score"] - 0.10 and
                      math.hypot(c["transform_query_to_map"][0][3] - b["transform_query_to_map"][0][3],
                                 c["transform_query_to_map"][2][3] - b["transform_query_to_map"][2][3]) > 0.45]
            stored.append({"run": run_id, "file": os.path.basename(f), "status": r["status"],
                           "best_yaw": round(yaw(b["transform_query_to_map"]), 1),
                           "best_origin_xz": [round(b["transform_query_to_map"][0][3], 2), round(b["transform_query_to_map"][2][3], 2)],
                           "competing_same_yaw": sum(yaw_gap(yaw(c["transform_query_to_map"]), yaw(b["transform_query_to_map"])) <= 20 for c in rivals),
                           "competing_opposite_yaw": sum(yaw_gap(yaw(c["transform_query_to_map"]), yaw(b["transform_query_to_map"])) >= 150 for c in rivals)})
            bests.append((os.path.basename(f), r["session_id"], b["transform_query_to_map"]))
        # Same-session structure: group best transforms by origin-mapping agreement (no camera poses were exported).
        sessions = {}
        for name, sid, t in bests:
            sessions.setdefault(sid, []).append((name, t))
        for sid, items in sessions.items():
            if len(items) < 2:
                continue
            clusters = []
            for name, t in items:
                for c in clusters:
                    ref = c[0][1]
                    if yaw_gap(yaw(t), yaw(ref)) <= 15 and math.hypot(t[0][3] - ref[0][3], t[2][3] - ref[2][3]) <= 1:
                        c.append((name, t))
                        break
                else:
                    clusters.append([(name, t)])
            stored.append({"run": run_id, "session": sid, "same_session_clusters": [[n for n, _ in c] for c in clusters],
                           "note": "按会话原点映射差聚类（无相机轨迹），只是结构性诊断，不是对错标签"})

    report = {"tag": a.tag, "rows": rows, "failures": failures, "stored_results": stored}
    json.dump(report, open(out / "report.json", "w"), ensure_ascii=False, indent=1)
    lines = [f"# 冻结集评估 {a.tag}", "", f"硬性检查失败：{len(failures)}", ""]
    lines += [f"- {f}" for f in failures]
    lines += ["", "| 查询 | 地图 | 地图内外 | 帧 | 状态 | 原因 | 模式数 | 最佳模式扩散 m | 耗时 s | 备注 |", "|---|---|---|---|---|---|---|---|---|---|"]
    for r in rows:
        note = "；".join(x for x in [r.get("vs_known_wrong", ""), r.get("prefix_stability", "")] + r["checks"] if x)
        spread = "" if r["best_spread_m"] is None else f"{r['best_spread_m']:.2f}"
        lines.append(f"| {r['query']} | {r['map']} | {r['in_map']} | {r['frames']} | {r['status']} | {','.join(r['reasons'])} | {r['modes']} | {spread} | {r['seconds']} | {note} |")
    if FREE_SPACE:
        lines += ["", "## 自由空间证据（只报告，不参与判定）", "",
                  "| 查询 | 地图 | 地图内外 | 帧 | 状态 | 候选（模式, 门槛, 分数, 朝向, 冲突率, 覆盖率） |", "|---|---|---|---|---|---|"]
        for r in rows:
            cells = "；".join(f"m{c['mode']} {'✓' if c['gate'] else '·'} {c['score']} {c['yaw']}° {c['conflict_rate']} {c['coverage']}" for c in (r["free_space"] or []))
            lines.append(f"| {r['query']} | {r['map']} | {r['in_map']} | {r['frames']} | {r['status']} | {cells} |")
    if FREE_SPACE:
        # Offline threshold trial only. Approximates the decision with the stored candidates:
        # a candidate stays gated if conflict_rate <= 0.10 and coverage >= 0.30.
        lines += ["", "## 离线门槛试验：冲突率 ≤ 0.10 且覆盖率 ≥ 0.30（近似，不改求解器）", "",
                  "| 查询 | 地图 | 地图内外 | 帧 | 原状态 | 试验状态 |", "|---|---|---|---|---|---|"]
        for r in rows:
            kept = [c for c in (r["free_space"] or []) if c["gate"] and c["conflict_rate"] is not None
                    and c["conflict_rate"] <= 0.10 and c["coverage"] >= 0.30]
            if not kept:
                trial = "rejected"
            else:
                top = max(kept, key=lambda c: c["score"])
                rivals = [c for c in kept if c is not top and c["mode"] != top["mode"] and c["score"] >= top["score"] - 0.10]
                trial = "ambiguous" if rivals or r["status"] == "ambiguous" and "along_axis_spread" in r["reasons"] else "candidate_requires_review"
            r["free_space_trial_status"] = trial
            mark = "" if trial == r["status"] else " ←"
            lines.append(f"| {r['query']} | {r['map']} | {r['in_map']} | {r['frames']} | {r['status']} | {trial}{mark} |")
        # Trial 2, veto only: free space may reject the best candidate but never removes rivals,
        # so it can only make a decision more conservative.
        lines += ["", "## 离线门槛试验 2（只否决）：最佳候选冲突率 ≥ 0.30 且可比较点 ≥ 20 时拒绝", "",
                  "| 查询 | 地图 | 地图内外 | 帧 | 原状态 | 试验状态 |", "|---|---|---|---|---|---|"]
        for r in rows:
            best = next((c for c in (r["free_space"] or []) if c["gate"]), None)
            veto = best is not None and best["conflict_rate"] is not None and best["conflict_rate"] >= 0.30 and best["comparable"] >= 20
            trial = "rejected" if veto else r["status"]
            r["free_space_veto_status"] = trial
            lines.append(f"| {r['query']} | {r['map']} | {r['in_map']} | {r['frames']} | {r['status']} | {trial}{'' if trial == r['status'] else ' ←'} |")
        json.dump(report, open(out / "report.json", "w"), ensure_ascii=False, indent=1)
    lines += ["", "## 无原始深度的手机结果（只做结构性诊断）", ""]
    lines += [f"- {json.dumps(s, ensure_ascii=False)}" for s in stored]
    (out / "report.md").write_text("\n".join(lines) + "\n")
    print("\n".join(lines))


if __name__ == "__main__":
    main()
