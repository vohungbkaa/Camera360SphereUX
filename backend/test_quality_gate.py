from pathlib import Path
from tempfile import TemporaryDirectory
import unittest

from quality_gate import (
    evaluate_horizontal_chain,
    evaluate_quality,
    parse_control_point_graph,
    parse_match_graph,
)


class QualityGateTest(unittest.TestCase):
    def test_disconnected_graph_and_dropped_frame_require_recapture(self) -> None:
        with TemporaryDirectory() as directory:
            graph_path = Path(directory) / "graph.dot"
            graph_path.write_text(
                'graph g {\n"sphere-000.jpg" -- "sphere-001.jpg"'
                '[label="Nm=20, Ni=15, C=1.2"];\n}', encoding="utf-8"
            )
            names = ["sphere-000.jpg", "sphere-001.jpg", "sphere-002.jpg"]
            graph = parse_match_graph(graph_path, names)
            mapping = {"frames": [
                {"prepared": name, "source": name, "targetId": f"target-{index}"}
                for index, name in enumerate(names)
            ]}
            result = {"usedFrames": 2, "usedFrameNames": names[:2]}
            decision = evaluate_quality(result, mapping, graph)
            self.assertEqual(decision["status"], "RECAPTURE")
            self.assertEqual(graph["componentCount"], 2)
            self.assertEqual(decision["droppedFrames"][0]["targetId"], "target-2")

    def test_complete_connected_result_passes(self) -> None:
        mapping = {"horizontalFovDegrees": 55, "frames": [
            {"prepared": "a.jpg", "expectedPose": {"yaw": 0}},
            {"prepared": "b.jpg", "expectedPose": {"yaw": 30}},
        ]}
        graph = {"componentCount": 1, "components": [["a.jpg", "b.jpg"]], "edges": [
            {"a": "a.jpg", "b": "b.jpg", "controlPoints": 12}
        ]}
        result = {"usedFrames": 2, "usedFrameNames": ["a.jpg", "b.jpg"]}
        decision = evaluate_quality(result, mapping, graph)
        self.assertEqual(decision["status"], "PASS")
        self.assertEqual(decision["captureChainStatus"], "connected")
        self.assertEqual(decision["wrapBoundaryStatus"], "open")

    def test_visual_match_that_conflicts_with_pose_is_rejected(self) -> None:
        mapping = {"horizontalFovDegrees": 50, "frames": [
            {"prepared": "a.jpg", "expectedPose": {"yaw": 0, "pitch": 0}},
            {"prepared": "b.jpg", "expectedPose": {"yaw": 180, "pitch": 0}},
        ]}
        graph = {"componentCount": 1, "components": [["a.jpg", "b.jpg"]], "edges": [
            {"a": "a.jpg", "b": "b.jpg", "confidence": 1.5, "controlPoints": 12}
        ]}
        result = {"usedFrames": 2, "usedFrameNames": ["a.jpg", "b.jpg"]}
        decision = evaluate_quality(result, mapping, graph)
        self.assertEqual(decision["status"], "RECAPTURE")
        self.assertEqual(decision["blockers"], ["matchGraphConflictsWithCapturePose"])

    def test_closed_horizontal_loop_requires_all_neighbor_edges(self) -> None:
        names = [f"sphere-{index:03d}.jpg" for index in range(4)]
        mapping = {"horizontalFovDegrees": 120, "frames": [
            {
                "prepared": name,
                "targetId": f"target-{index}",
                "expectedPose": {"yaw": index * 90},
            }
            for index, name in enumerate(names)
        ]}
        edges = [
            {"a": names[index], "b": names[(index + 1) % 4], "controlPoints": 10}
            for index in range(4)
        ]
        chain = evaluate_horizontal_chain(mapping, {"edges": edges})
        self.assertEqual(chain["captureChainStatus"], "connected")
        self.assertEqual(chain["wrapBoundaryStatus"], "closed")
        self.assertTrue(chain["loopCoverageComplete"])

    def test_clean_pto_control_points_build_visual_graph(self) -> None:
        with TemporaryDirectory() as directory:
            pto = Path(directory) / "clean.pto"
            pto.write_text(
                "\n".join([
                    "c n0 N1 x1 y1 X2 Y2 t0",
                    "c n0 N1 x3 y3 X4 Y4 t0",
                    "c n1 N2 x5 y5 X6 Y6 t0",
                ]),
                encoding="utf-8",
            )
            graph = parse_control_point_graph(pto, ["a.jpg", "b.jpg", "c.jpg"])
            self.assertEqual(graph["componentCount"], 1)
            self.assertEqual(graph["edges"][0]["controlPoints"], 2)


if __name__ == "__main__":
    unittest.main()
