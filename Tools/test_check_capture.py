"""Synthetic fixtures only. These checks never count as real AR test evidence."""
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
import zipfile
from PIL import Image

spec = importlib.util.spec_from_file_location("check_capture", Path(__file__).with_name("check_capture.py"))
checker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(checker)

IDENTITY = [[1.0,0,0,0],[0,1,0,0],[0,0,1,0],[0,0,0,1]]


class CaptureChecks(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="arprobe-test-")
        self.base = Path(self.temporary.name)
        self.root = self.base / "run-fixture"
        (self.root / "frames").mkdir(parents=True)
        self.write_json("run.json", {"run_id": "run-fixture", "session_id": "session-fixture", "state": "finished", "synthetic_test_fixture": True})
        self.write_json("summary.json", {"synthetic_test_fixture": True})
        for name in ["poses.jsonl", "camera-events.jsonl", "anchors.jsonl", "events.jsonl"]:
            record = {"run_id": "run-fixture", "session_id": "session-fixture", "timestamp": 1, "matrix": IDENTITY}
            (self.root / name).write_text(json.dumps(record) + "\n")
        (self.root / "measurements.csv").write_text("test_id,result\n")
        for i in range(10):
            name = f"frame-{i:05d}"
            Image.new("RGB", (64,48), (20+i,80,120)).save(self.root / "frames" / (name + ".jpg"))
            frame = {"frame_id": name, "run_id": "run-fixture", "session_id": "session-fixture",
                     "image": {"path": "frames/"+name+".jpg", "saved_width": 64, "saved_height": 48, "rotation_deg": 0, "mirrored": False},
                     "intrinsics": {"reference_width": 64, "reference_height": 48, "fx": 50, "fy": 50, "cx": 32, "cy": 24},
                     "pose": {"direction": "camera_to_session", "coordinate_system": "arkit_right_handed_y_up_camera_forward_minus_z", "matrix": IDENTITY},
                     "timing": {"ar_frame_timestamp_seconds": i+1.0, "pose_association": "same_ARFrame"},
                     "route": {"test_points_session": [{"session": [0,0,-2]}]}, "validity": {"image_geometry_verified": False, "ready_for_ar_alignment": False}}
            self.write_json("frames/"+name+".json", frame)
        self.make_manifest()

    def tearDown(self):
        self.temporary.cleanup()

    def write_json(self, relative, data):
        (self.root / relative).write_text(json.dumps(data), encoding="utf-8")

    def make_manifest(self):
        entries = [{"path": str(p.relative_to(self.root)), "bytes": p.stat().st_size, "sha256": checker.sha256(p)}
                   for p in self.root.rglob("*") if p.is_file() and p.name != "files.json"]
        self.write_json("files.json", {"files": entries})

    def inspect(self):
        return checker.inspect(self.root, self.base / "report")

    def test_valid_structure_does_not_claim_field_accuracy(self):
        result = self.inspect()
        self.assertEqual(result["file_structure"], "PASS")
        self.assertEqual(result["valid_frames"], 10)
        self.assertEqual(result["status"], "UNVERIFIED")
        self.assertTrue((self.base / "report/index.html").is_file())

    def test_changed_intrinsics_and_missing_pair_fail(self):
        path = self.root / "frames/frame-00000.json"
        data = json.loads(path.read_text()); data["intrinsics"]["reference_width"] = 128
        path.write_text(json.dumps(data)); (self.root / "frames/frame-00001.jpg").unlink()
        self.make_manifest()
        result = self.inspect()
        self.assertEqual(result["file_structure"], "FAIL")
        self.assertTrue(any("内参参考尺寸" in message for message in result["failures"]))

    def test_hash_detects_tampering(self):
        (self.root / "measurements.csv").write_text("modified")
        self.assertTrue(any("哈希" in item for item in self.inspect()["failures"]))

    def test_duplicate_timestamps_fail(self):
        path = self.root / "frames/frame-00001.json"
        data = json.loads(path.read_text()); data["timing"]["ar_frame_timestamp_seconds"] = 1.0
        path.write_text(json.dumps(data)); self.make_manifest()
        self.assertTrue(any("重复相机帧" in item for item in self.inspect()["failures"]))

    def test_zip_traversal_is_rejected(self):
        source = self.base / "malicious.zip"
        with zipfile.ZipFile(source, "w") as archive:
            archive.writestr("../escape", "bad")
        with self.assertRaises(ValueError):
            checker.extract_checked(source, self.base / "extracted")
        self.assertFalse((self.base / "escape").exists())

    def test_projection_uses_negative_z_forward(self):
        k = {"fx": 100, "fy": 100, "cx": 50, "cy": 50}
        self.assertEqual(checker.project([1,1,-2], IDENTITY, k), (100,0))
        self.assertIsNone(checker.project([0,0,2], IDENTITY, k))

    def test_reflection_is_not_a_camera_rotation(self):
        matrix = [row[:] for row in IDENTITY]; matrix[0][0] = -1
        self.assertFalse(checker.matrix_valid(matrix))

    def add_photo_calibration(self):
        path = self.root / "frames/frame-00000.json"
        frame = json.loads(path.read_text())
        frame["calibration_geometry"] = {
            "source": "same_ARFrame_horizontal_plane_snapshot", "plane_to_session": IDENTITY,
            "boundary_xz_m": [[-1,-3],[1,-3],[1,0],[-1,0]]}
        path.write_text(json.dumps(frame))
        events = [
            {"event": "photo_calibration_points_submitted", "query_frame_id": "frame-00000", "raw_pixels": [[32,35],[40,35]], "timestamp": 2},
            {"event": "photo_calibration_applied", "source": "manual_photo_points", "visual_model_inference_performed": False, "timestamp": 3}]
        with (self.root / "events.jsonl").open("a") as stream:
            for event in events:
                event.update(run_id="run-fixture", session_id="session-fixture")
                stream.write(json.dumps(event) + "\n")
        self.make_manifest()

    def test_manual_photo_binding_is_reported_separately_from_model_inference(self):
        self.add_photo_calibration(); result = self.inspect()
        self.assertEqual(result["file_structure"], "PASS")
        self.assertEqual(result["manual_photo_selections"], 1)
        self.assertEqual(result["manual_photo_calibrations_applied"], 1)
        self.assertTrue(any("没有图像识别模型" in w for w in result["warnings"]))
        self.assertEqual(result["field_validation"], "UNVERIFIED")

    def test_interleaved_camera_and_user_events_keep_later_calibration_evidence(self):
        self.add_photo_calibration()
        path = self.root / "events.jsonl"
        events = [json.loads(line) for line in path.read_text().splitlines()]
        events[0].update(event="photo_calibration_requested", timestamp=1 + 1/60)
        events.insert(1, {"event": "world_mapping_status_changed", "timestamp": 1,
                          "run_id": "run-fixture", "session_id": "session-fixture", "status": "extending"})
        path.write_text("".join(json.dumps(e) + "\n" for e in events)); self.make_manifest()
        result = self.inspect()
        self.assertEqual(result["file_structure"], "PASS")
        self.assertEqual(result["manual_photo_selections"], 1)
        self.assertEqual(result["manual_photo_calibrations_applied"], 1)
        self.assertTrue(any("不同事件时间交错" in w for w in result["warnings"]))

    def test_same_event_timestamp_regression_still_fails(self):
        events = [{"event": "world_mapping_status_changed", "timestamp": stamp,
                   "run_id": "run-fixture", "session_id": "session-fixture"} for stamp in [2, 1]]
        (self.root / "events.jsonl").write_text("".join(json.dumps(e) + "\n" for e in events)); self.make_manifest()
        self.assertTrue(any("同类事件时间倒退" in f for f in self.inspect()["failures"]))

    def test_camera_and_pose_timestamp_regressions_still_fail(self):
        for name in ["camera-events.jsonl", "poses.jsonl"]:
            with self.subTest(stream=name):
                records = [{"timestamp": stamp, "matrix": IDENTITY,
                            "run_id": "run-fixture", "session_id": "session-fixture"} for stamp in [2, 1]]
                path = self.root / name
                original = path.read_text()
                path.write_text("".join(json.dumps(e) + "\n" for e in records)); self.make_manifest()
                self.assertTrue(any(name + "：" in f and "时间倒退" in f for f in self.inspect()["failures"]))
                path.write_text(original); self.make_manifest()

    def test_photo_selection_requires_capture_time_floor_snapshot(self):
        self.add_photo_calibration()
        path = self.root / "frames/frame-00000.json"
        frame = json.loads(path.read_text()); frame.pop("calibration_geometry")
        path.write_text(json.dumps(frame)); self.make_manifest()
        self.assertTrue(any("地面快照" in w for w in self.inspect()["failures"]))

    def test_photo_selection_outside_original_image_is_rejected(self):
        self.add_photo_calibration()
        path = self.root / "events.jsonl"
        text = path.read_text().replace('"raw_pixels": [[32, 35], [40, 35]]', '"raw_pixels": [[32, 35], [64, 35]]')
        path.write_text(text); self.make_manifest()
        self.assertTrue(any("照片选点" in w for w in self.inspect()["failures"]))

    def test_unknown_photo_frame_reference_is_rejected(self):
        self.add_photo_calibration()
        path = self.root / "events.jsonl"; path.write_text(path.read_text().replace('"query_frame_id": "frame-00000"', '"query_frame_id": "missing"'))
        self.make_manifest()
        self.assertTrue(any("不存在" in w for w in self.inspect()["failures"]))

    def test_manual_binding_cannot_claim_model_inference(self):
        self.add_photo_calibration()
        path = self.root / "events.jsonl"; path.write_text(path.read_text().replace('"visual_model_inference_performed": false', '"visual_model_inference_performed": true'))
        self.make_manifest()
        self.assertTrue(any("非模型" in w for w in self.inspect()["failures"]))

    def make_simulation(self):
        run = json.loads((self.root / "run.json").read_text())
        run.update(data_kind="simulation", is_real_ar_capture=False)
        self.write_json("run.json", run)
        for path in (self.root / "frames").glob("*.json"):
            frame = json.loads(path.read_text())
            frame.update(data_kind="simulation", is_real_ar_capture=False)
            frame["timing"]["simulation_timestamp_seconds"] = frame["timing"].pop("ar_frame_timestamp_seconds")
            frame["timing"]["pose_association"] = "synthetic_scene_snapshot"
            path.write_text(json.dumps(frame))
        self.make_manifest()

    def add_world_map_test(self, restored=True, assessed=False):
        folder = self.root / "input-world-map"; folder.mkdir()
        meta = {"schema_version": 1, "map_id": "map-fixture", "name": "fixture corridor",
                "source_session_id": "old-session", "origin_anchor_id": "saved-anchor",
                "anchor_to_map": IDENTITY, "route_to_anchor": IDENTITY,
                "localization_provider": "arkit_world_map", "map_format": "ARWorldMap_secure_archive_ios_only",
                "saved_mapping_status": "mapped", "physical_alignment_verified": False}
        route = {"schema_version": 1, "coordinate_system": "route_local_m_y_up_forward_minus_z", "route_id": "map-fixture",
                 "name": "fixture corridor", "nodes": [{"id": "N0", "position": {"x": 0,"y": 0,"z": 0}},
                 {"id": "N1", "position": {"x": 0,"y": 0,"z": -2}}],
                 "edges": [{"from": "N0", "to": "N1", "length_m": 2}]}
        self.write_json("input-world-map/map.json", meta); self.write_json("input-world-map/route.json", route)
        # Opaque synthetic bytes exercise integrity checks, never ARKit restoration.
        (folder / "environment.arworldmap").write_bytes(b"synthetic-test-fixture-not-ARWorldMap")
        Image.new("RGB", (64,48)).save(folder / "reference.jpg")
        self.write_json("input-world-map/reference.json", {"image": {"width": 64,"height": 48}, "camera_to_session": IDENTITY})
        entries = [{"path": p.name, "bytes": p.stat().st_size, "sha256": checker.sha256(p)} for p in folder.iterdir()]
        self.write_json("input-world-map/files.json", {"files": entries})
        run = json.loads((self.root / "run.json").read_text())
        run["configuration"] = {"world_map_test": True, "world_map_id": "map-fixture", "world_map_source_session": "old-session"}
        self.write_json("run.json", run)
        events = [{"event": "world_map_restore_requested", "map_id": "map-fixture", "timestamp": 11},
                  {"event": "world_map_target_anchor_observed", "anchor_id": "saved-anchor", "timestamp": 11.1}]
        if restored:
            events.append({"event": "world_map_sdk_restored", "map_id": "map-fixture", "anchor_id": "saved-anchor",
                "anchor_to_session": IDENTITY, "restore_seconds": 1.1, "physical_alignment_verified": False,
                "visual_model_inference_performed": False, "timestamp": 12.1})
        else:
            events.append({"event": "world_map_restore_timeout", "timestamp": 71})
        if assessed:
            events.append({"event": "world_map_alignment_assessed", "aligned": True, "source": "human_observation",
                "numeric_accuracy_measured": False, "timestamp": 13})
        with (self.root / "events.jsonl").open("a") as f:
            for e in events:
                e.update(run_id="run-fixture", session_id="session-fixture"); f.write(json.dumps(e)+"\n")
        self.write_json("summary.json", {"world_map_sdk_restored": restored})
        self.make_manifest()

    def test_world_map_restore_is_not_automatic_physical_accuracy(self):
        self.add_world_map_test(); result = self.inspect()
        self.assertEqual(result["file_structure"], "PASS")
        self.assertEqual(result["world_map_test"]["human_alignment"], "not_checked")
        self.assertEqual(result["field_validation"], "UNVERIFIED")

    def test_world_map_human_feedback_is_separate_from_numeric_measurement(self):
        self.add_world_map_test(assessed=True); result = self.inspect()
        self.assertEqual(result["file_structure"], "PASS")
        self.assertEqual(result["world_map_test"]["human_alignment"], "aligned")
        self.assertEqual(result["field_validation"], "UNVERIFIED")

    def test_world_map_timeout_can_be_a_valid_test_record(self):
        self.add_world_map_test(restored=False); result = self.inspect()
        self.assertEqual(result["file_structure"], "PASS")
        self.assertFalse(result["world_map_test"]["sdk_restored"])

    def test_world_map_wrong_anchor_cannot_be_restoration_success(self):
        self.add_world_map_test()
        path = self.root / "events.jsonl"
        events = [json.loads(l) for l in path.read_text().splitlines()]
        for e in events:
            if e.get("event") == "world_map_sdk_restored": e["anchor_id"] = "different-anchor"
        path.write_text(''.join(json.dumps(e)+"\n" for e in events)); self.make_manifest()
        self.assertTrue(any("恢复证据" in e for e in self.inspect()["failures"]))

    def test_world_map_embedded_source_hash_is_checked(self):
        self.add_world_map_test()
        (self.root / "input-world-map/environment.arworldmap").write_bytes(b"different")
        self.make_manifest()
        self.assertTrue(any("输入哈希" in e for e in self.inspect()["failures"]))

    def test_world_map_manual_recalibration_cannot_masquerade_as_restore(self):
        self.add_world_map_test()
        with (self.root / "events.jsonl").open("a") as f:
            f.write(json.dumps({"event": "photo_calibration_applied", "timestamp": 13,
                "source": "manual_photo_points", "visual_model_inference_performed": False,
                "run_id": "run-fixture", "session_id": "session-fixture"})+"\n")
        self.make_manifest()
        self.assertTrue(any("混入" in e for e in self.inspect()["failures"]))

    def test_simulation_report_is_explicit(self):
        self.make_simulation()
        result = self.inspect()
        self.assertEqual(result["file_structure"], "PASS")
        self.assertEqual(result["status"], "SIMULATION")
        self.assertEqual(result["field_validation"], "NOT_APPLICABLE_SIMULATION")
        self.assertIn("模拟图片", (self.base / "report/index.html").read_text())

    def test_simulation_cannot_be_used_as_localization_input(self):
        self.make_simulation()
        path = self.root / "frames/frame-00000.json"
        frame = json.loads(path.read_text()); frame["validity"]["ready_for_visual_localization_query"] = True
        path.write_text(json.dumps(frame)); self.make_manifest()
        self.assertTrue(any("模拟图片不能" in item for item in self.inspect()["failures"]))

    def test_mixed_simulation_and_real_frames_are_rejected(self):
        self.make_simulation()
        path = self.root / "frames/frame-00000.json"
        frame = json.loads(path.read_text()); frame["data_kind"] = "real_ar_capture"
        path.write_text(json.dumps(frame)); self.make_manifest()
        self.assertTrue(any("数据模式不匹配" in item for item in self.inspect()["failures"]))


if __name__ == "__main__":
    unittest.main()
