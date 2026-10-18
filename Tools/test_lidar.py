import json
import tempfile
import unittest
from pathlib import Path

import numpy as np
from lidar_data import Scan, safe_name, require_independent, validate_transform
from lidar_validate import solve, delta
from make_lidar_fixture import make, checksum


class LiDARTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory()
        cls.root = Path(cls.temp.name)
        cls.m, cls.q, _, cls.truth = make(cls.root)

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def test_nested_zip_and_packing(self):
        with Scan(self.root/"query.zip") as q, Scan(self.root/"query") as folder:
            np.testing.assert_equal(q.points(), folder.points())
            self.assertGreater(len(q.points()), 500)

    def test_path_traversal_and_bad_pose(self):
        for name in ["../a", "/a", "a/../b", "a\\b", "a//b", "a:foo"]:
            with self.assertRaises(ValueError):
                safe_name(name)
        with self.assertRaises(ValueError):
            validate_transform(np.diag([1, 1, -1, 1]))

    def test_checksum_rejects_changes(self):
        file = self.root/"query/frames/0000/depth.f32"
        original = file.read_bytes()
        try:
            file.write_bytes(original+b"bad")
            with self.assertRaisesRegex(ValueError, "文件损坏"):
                Scan(self.root/"query")
        finally:
            file.write_bytes(original)

    def test_same_session_rejected(self):
        with Scan(self.root/"map") as m, Scan(self.root/"query") as q:
            require_independent(m, q)
            q.meta["session_id"] = m.meta["session_id"]
            with self.assertRaises(ValueError):
                require_independent(m, q)

    def test_incomplete_trial_rejected(self):
        file = self.root/"query/scan.json"
        original = file.read_bytes()
        try:
            m = json.loads(original);m["state"] = "interrupted"
            file.write_text(json.dumps(m));checksum(file.parent)
            with self.assertRaisesRegex(ValueError, "未正常完成"):
                Scan(file.parent)
            with Scan(file.parent, allow_incomplete=True):
                pass
        finally:
            file.write_bytes(original);checksum(file.parent)

    def test_global_registration_recovers_unseeded_known_pose(self):
        with Scan(self.root/"map.zip") as m, Scan(self.root/"query.zip") as q:
            fit = q.points([f for i,f in enumerate(q.meta["frames"]) if i % 3 != 2])
            held = q.points([f for i,f in enumerate(q.meta["frames"]) if i % 3 == 2])
            result, t = solve(m.points(), fit, held)
            self.assertIsNotNone(t)
            distance, yaw = delta(t, self.truth)
            self.assertLess(distance, 0.08, result)
            self.assertLess(yaw, 1.5, result)
            self.assertEqual(result["status"], "candidate_requires_review", result)

    def test_single_floor_plane_is_not_a_reliable_location(self):
        with Scan(self.root/"map") as m, Scan(self.root/"outside") as q:
            result, _ = solve(m.points(), q.points(q.meta["frames"][:6]), q.points(q.meta["frames"][6:]), attempts=3, iterations=10000)
            self.assertEqual(result["status"], "rejected", result)


if __name__ == "__main__":
    unittest.main()
