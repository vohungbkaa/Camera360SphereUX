from pathlib import Path
from tempfile import TemporaryDirectory
import unittest

from quality_gate import evaluate_quality, parse_match_graph


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
        mapping = {"frames": [{"prepared": "a.jpg"}, {"prepared": "b.jpg"}]}
        graph = {"componentCount": 1, "components": [["a.jpg", "b.jpg"]], "edges": []}
        result = {"usedFrames": 2, "usedFrameNames": ["a.jpg", "b.jpg"]}
        self.assertEqual(evaluate_quality(result, mapping, graph)["status"], "PASS")

    def test_visual_match_that_conflicts_with_pose_is_rejected(self) -> None:
        mapping = {"horizontalFovDegrees": 50, "frames": [
            {"prepared": "a.jpg", "expectedPose": {"yaw": 0, "pitch": 0}},
            {"prepared": "b.jpg", "expectedPose": {"yaw": 180, "pitch": 0}},
        ]}
        graph = {"componentCount": 1, "components": [["a.jpg", "b.jpg"]], "edges": [
            {"a": "a.jpg", "b": "b.jpg", "confidence": 1.5}
        ]}
        result = {"usedFrames": 2, "usedFrameNames": ["a.jpg", "b.jpg"]}
        decision = evaluate_quality(result, mapping, graph)
        self.assertEqual(decision["status"], "RECAPTURE")
        self.assertEqual(decision["blockers"], ["matchGraphConflictsWithCapturePose"])


if __name__ == "__main__":
    unittest.main()
