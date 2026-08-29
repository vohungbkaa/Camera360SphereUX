from pathlib import Path
from tempfile import TemporaryDirectory
import unittest

from fastapi import BackgroundTasks, HTTPException

import app as backend_app


class StitchApiTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = TemporaryDirectory()
        self.previous_sessions = backend_app.SESSIONS
        backend_app.SESSIONS = Path(self.temporary.name) / "sessions"

    def tearDown(self) -> None:
        backend_app.SESSIONS = self.previous_sessions
        self.temporary.cleanup()

    def test_stitch_requires_two_uploaded_manifest_frames(self) -> None:
        backend_app.create_session(backend_app.SessionCreate(id="one-frame"))
        directory = backend_app.SESSIONS / "one-frame"
        (directory / "frames" / "frame-0.jpg").write_bytes(b"jpeg")
        backend_app.complete_session(
            "one-frame",
            backend_app.CompleteRequest(
                frames=[{"id": "frame-0"}],
            ),
        )

        with self.assertRaises(HTTPException) as context:
            backend_app.start_stitch("one-frame", BackgroundTasks())
        self.assertEqual(context.exception.status_code, 422)

if __name__ == "__main__":
    unittest.main()
