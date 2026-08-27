import json
from pathlib import Path
from tempfile import TemporaryDirectory
import unittest

from hugin_seed_pto import seed


class HuginPoseSeedTest(unittest.TestCase):
    def test_pose_seed_preserves_exif_roll(self) -> None:
        with TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "source.pto"
            source.write_text(
                'i w4032 h3024 f0 v53.5 r90 p0 y0 n"/input/sphere-000.jpg"\n',
                encoding="utf-8",
            )
            mapping = root / "mapping.json"
            mapping.write_text(
                json.dumps({
                    "frames": [{
                        "prepared": "sphere-000.jpg",
                        "expectedPose": {"yaw": 32.0, "pitch": 4.0},
                    }]
                }),
                encoding="utf-8",
            )
            destination = root / "seeded.pto"

            seed(source, mapping, destination)

            result = destination.read_text(encoding="utf-8")
            self.assertIn("r90", result)
            self.assertIn("y32.00000000", result)
            self.assertIn("p4.00000000", result)


if __name__ == "__main__":
    unittest.main()
