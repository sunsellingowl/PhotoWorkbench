"""Check real renames in a temporary folder; no GUI or personal photos needed."""

import os
from datetime import datetime
from pathlib import Path
from queue import Queue
from tempfile import TemporaryDirectory

from PIL import Image

from photo_time_renamer import App, build_target_path


def check_renaming() -> None:
    with TemporaryDirectory() as temporary:
        folder = Path(temporary)
        timestamp = "2610211435"
        exif = Image.Exif()
        exif[36867] = "2026:10:21 14:35:59"
        for name in (f"{timestamp}.jpg", "IMG_1234.jpg", "photo_2610211435.jpg"):
            Image.new("RGB", (2, 2)).save(folder / name, exif=exif)

        # No EXIF: use the file's modified time, preserving its extension.
        fallback = folder / "screenshot.PNG"
        Image.new("RGB", (2, 2)).save(fallback)
        modified = datetime(2026, 10, 20, 8, 7).timestamp()
        os.utime(fallback, (modified, modified))
        original_contents = sorted(path.read_bytes() for path in folder.iterdir())

        # Create only the worker's state, avoiding a Tkinter window in this check.
        app = App.__new__(App)
        app.selected_folders = [folder]
        app.log_queue = Queue()
        app._rename_worker()
        events = list(app.log_queue.queue)
        assert ("stats", "4|3|1|0") in events, events
        assert {path.name for path in folder.iterdir()} == {
            f"{timestamp}.jpg",
            f"{timestamp}_001.jpg",
            f"{timestamp}_002.jpg",
            "2610200807.PNG",
        }
        assert sorted(path.read_bytes() for path in folder.iterdir()) == original_contents

        # A second run must keep all filenames, contents, and modified times.
        before = {path.name: (path.read_bytes(), path.stat().st_mtime_ns)
                  for path in folder.iterdir()}
        app.log_queue = Queue()
        app._rename_worker()
        events = list(app.log_queue.queue)
        assert ("stats", "4|0|4|0") in events, events
        assert before == {path.name: (path.read_bytes(), path.stat().st_mtime_ns)
                          for path in folder.iterdir()}

        # Keep numbered names even when an earlier number is free, including 1000+.
        for number in ("003", "1000"):
            path = folder / f"{timestamp}_{number}.jpg"
            assert build_target_path(path, timestamp) == path

        # An old timestamp must not prevent renaming to the actual capture time.
        assert build_target_path(folder / "2501010000.webp", timestamp).name == f"{timestamp}.webp"


if __name__ == "__main__":
    check_renaming()
    print("Renaming checks passed.")
