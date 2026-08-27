import json
from pathlib import Path
from tempfile import TemporaryDirectory
import unittest

import cv2 as cv
import numpy as np

from stitch_benchmark import derive_canvas_width, panorama_viewer_config, prepare_inputs


class StitchInputQualityTest(unittest.TestCase):
    def test_full_resolution_mode_preserves_original_jpeg_bytes(self) -> None:
        with TemporaryDirectory() as temporary:
            session = Path(temporary) / "session"
            frames = session / "frames"
            frames.mkdir(parents=True)
            source = frames / "frame-0.jpg"
            image = np.full((48, 64, 3), 127, dtype=np.uint8)
            self.assertTrue(cv.imwrite(str(source), image, [cv.IMWRITE_JPEG_QUALITY, 91]))
            original = source.read_bytes()
            (frames / "frame-0.json").write_text(
                json.dumps({
                    "capture": {
                        "intrinsics": {
                            "exifOrientation": 1,
                            "horizontalFovDegrees": 55,
                            "verticalFovDegrees": 72,
                        }
                    }
                }),
                encoding="utf-8",
            )
            (session / "manifest.json").write_text(
                json.dumps({"productType": "360-horizontal", "isClosedLoop": True}),
                encoding="utf-8",
            )

            destination = Path(temporary) / "prepared"
            prepared = prepare_inputs(session, destination, maximum_edge=0)

            self.assertEqual((destination / "sphere-000.jpg").read_bytes(), original)
            self.assertEqual(prepared["maximumInputEdge"], 0)
            self.assertEqual(prepared["frames"][0]["preparedHeight"], 48)
            self.assertEqual(prepared["huginInputFovDegrees"], 55)
            self.assertTrue(prepared["isFullSphere"])

    def test_untouched_portrait_exif_uses_encoded_axis_fov(self) -> None:
        with TemporaryDirectory() as temporary:
            session = Path(temporary) / "session"
            frames = session / "frames"
            frames.mkdir(parents=True)
            source = frames / "frame-0.jpg"
            self.assertTrue(cv.imwrite(str(source), np.zeros((48, 64, 3), dtype=np.uint8)))
            (frames / "frame-0.json").write_text(
                json.dumps({"capture": {"intrinsics": {
                    "exifOrientation": 6,
                    "horizontalFovDegrees": 55,
                    "verticalFovDegrees": 72,
                }}}),
                encoding="utf-8",
            )

            prepared = prepare_inputs(session, Path(temporary) / "prepared", 0)

            self.assertEqual(prepared["huginInputFovDegrees"], 72)
            self.assertEqual(prepared["frames"][0]["preparedHeight"], 64)

    def test_canvas_uses_source_vertical_pixels_per_degree(self) -> None:
        mapping = {
            "verticalFovDegrees": 72.0,
            "frames": [{"preparedHeight": 4032}, {"preparedHeight": 3024}],
        }
        self.assertEqual(derive_canvas_width(mapping), 20160)

    def test_viewer_config_preserves_hugin_crop_position(self) -> None:
        with TemporaryDirectory() as temporary:
            pto = Path(temporary) / "final.pto"
            pto.write_text(
                'p f2 w20000 h10000 v360 S"5000,15000,2500,7500"\n',
                encoding="utf-8",
            )

            config = panorama_viewer_config(pto, is_closed_loop=False)

            self.assertEqual(config["panoData"], {
                "fullWidth": 20000,
                "fullHeight": 10000,
                "croppedWidth": 10000,
                "croppedHeight": 5000,
                "croppedX": 5000,
                "croppedY": 2500,
            })
            self.assertEqual(config["minimumYawDegrees"], -90.0)
            self.assertEqual(config["maximumYawDegrees"], 90.0)
            self.assertEqual(config["minimumPitchDegrees"], -45.0)
            self.assertEqual(config["maximumPitchDegrees"], 45.0)


if __name__ == "__main__":
    unittest.main()
