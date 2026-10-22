import os
import re
import subprocess
import sys
import threading
from datetime import datetime
from pathlib import Path
from queue import Empty, Queue
import tkinter as tk
from tkinter import filedialog, messagebox

from PIL import Image

# Constants are values the program uses in several places and does not expect
# to change while the app is running.
SUPPORTED_EXTENSIONS = {".jpg", ".jpeg", ".png", ".webp", ".heic", ".heif"}
EXIF_TIME_TAGS = (36867, 36868, 306)  # DateTimeOriginal, DateTimeDigitized, DateTime


class RenameResult:
    """Small container object for the counters shown in the app."""

    def __init__(self) -> None:
        # These attributes are updated as files are scanned and renamed.
        self.total = 0
        self.renamed = 0
        self.skipped = 0
        self.failed = 0


def extract_capture_time(file_path: Path) -> datetime:
    """Prefer EXIF capture time; fallback to filesystem modified time."""
    try:
        # "with" is a context manager: Pillow opens the image here and closes it
        # automatically when this block finishes.
        with Image.open(file_path) as image:
            exif = image.getexif()
            if exif:
                # Try each known EXIF date tag until one gives a valid date.
                for tag in EXIF_TIME_TAGS:
                    value = exif.get(tag)
                    if isinstance(value, str):
                        try:
                            # Camera EXIF dates commonly use this exact format.
                            return datetime.strptime(value, "%Y:%m:%d %H:%M:%S")
                        except ValueError:
                            # If this tag is not in the expected format, try the
                            # next possible EXIF date tag.
                            continue
    except Exception:
        # Some images have missing/broken metadata, or the local machine may not
        # know how to decode a format. The app still works by using modified time.
        pass

    return datetime.fromtimestamp(file_path.stat().st_mtime)


def build_target_path(file_path: Path, timestamp: str) -> Path:
    # fullmatch checks the entire name without its extension. Keep names that
    # already match this timestamp, including collision numbers such as _001.
    if re.fullmatch(rf"{timestamp}(?:_[0-9]{{3,}})?", file_path.stem):
        return file_path

    candidate = file_path.with_name(f"{timestamp}{file_path.suffix}")
    index = 1
    # Never choose an occupied name. :03d pads small numbers with zeros but
    # also supports larger numbers, such as _1000.
    while candidate.exists():
        candidate = file_path.with_name(f"{timestamp}_{index:03d}{file_path.suffix}")
        index += 1
    return candidate


def scan_images(folders: list[Path]) -> list[Path]:
    # The type hint list[Path] means "a list whose items are Path objects".
    files: list[Path] = []
    for folder in folders:
        # os.walk visits the folder and all of its subfolders.
        for root, _, filenames in os.walk(folder):
            for name in filenames:
                path = Path(root) / name
                if path.suffix.lower() in SUPPORTED_EXTENSIONS:
                    files.append(path)
    return files


class App:
    """Tkinter desktop application.

    The App object owns both the visible widgets and the renaming workflow.
    """

    def __init__(self, root: tk.Tk) -> None:
        # __init__ runs once when App(root) is created.
        self.root = root
        self.root.title("Photo Time Renamer")
        self.root.geometry("860x560")

        # Instance attributes live on self, so other methods can use them later.
        self.selected_folders: list[Path] = []
        self.is_running = False

        # Tkinter should only be updated from the main UI thread. The worker
        # thread sends messages through this Queue, and the UI reads them later.
        self.log_queue: Queue[tuple[str, str | None]] = Queue()

        # StringVar connects Python values to text displayed by Tkinter labels.
        self.total_var = tk.StringVar(value="Total: 0")
        self.renamed_var = tk.StringVar(value="Renamed: 0")
        self.skipped_var = tk.StringVar(value="Skipped: 0")
        self.failed_var = tk.StringVar(value="Failed: 0")

        self._build_ui()
        # after schedules a function to run later. Here it starts a repeating
        # loop that checks for worker-thread messages every 100 milliseconds.
        self.root.after(100, self._process_log_queue)

    def _build_ui(self) -> None:
        # Tkinter layouts are built by creating widgets, then calling pack/grid
        # to place them in the window.
        top_frame = tk.Frame(self.root)
        top_frame.pack(fill=tk.X, padx=12, pady=10)

        self.add_button = tk.Button(top_frame, text="Add Folder", command=self.add_folder)
        self.add_button.pack(side=tk.LEFT)

        self.remove_button = tk.Button(top_frame, text="Remove Selected", command=self.remove_selected)
        self.remove_button.pack(side=tk.LEFT, padx=8)

        self.start_button = tk.Button(top_frame, text="Start Rename", command=self.start_rename)
        self.start_button.pack(side=tk.LEFT)

        folders_label = tk.Label(self.root, text="Selected folders (recursive):")
        folders_label.pack(anchor="w", padx=12)

        self.folder_listbox = tk.Listbox(self.root, height=8, selectmode=tk.EXTENDED)
        self.folder_listbox.pack(fill=tk.X, padx=12, pady=6)

        stats_frame = tk.Frame(self.root)
        stats_frame.pack(fill=tk.X, padx=12, pady=6)

        tk.Label(stats_frame, textvariable=self.total_var, width=18, anchor="w").pack(side=tk.LEFT)
        tk.Label(stats_frame, textvariable=self.renamed_var, width=18, anchor="w").pack(side=tk.LEFT)
        tk.Label(stats_frame, textvariable=self.skipped_var, width=18, anchor="w").pack(side=tk.LEFT)
        tk.Label(stats_frame, textvariable=self.failed_var, width=18, anchor="w").pack(side=tk.LEFT)

        log_label = tk.Label(self.root, text="Log:")
        log_label.pack(anchor="w", padx=12)

        self.log_text = tk.Text(self.root, height=18, wrap=tk.WORD)
        self.log_text.pack(fill=tk.BOTH, expand=True, padx=12, pady=(6, 12))
        self.log_text.configure(state=tk.DISABLED)

    def add_folder(self) -> None:
        # One click can return one folder or many folders, depending on what
        # the user selected in the folder picker.
        for path in self._choose_folders():
            self._add_folder_path(path)

    def _choose_folders(self) -> list[Path]:
        # Tkinter's built-in askdirectory can only choose one folder. On macOS,
        # AppleScript gives us the Finder-style dialog with multi-select.
        if sys.platform == "darwin":
            script = """
            set chosenFolders to choose folder with prompt "Select one or more folders" with multiple selections allowed
            set folderPaths to ""
            repeat with selectedFolder in chosenFolders
                set folderPaths to folderPaths & POSIX path of selectedFolder & linefeed
            end repeat
            return folderPaths
            """
            try:
                completed = subprocess.run(
                    ["osascript", "-e", script],
                    check=True,
                    capture_output=True,
                    text=True,
                )
            except subprocess.CalledProcessError:
                # Canceling the dialog also raises CalledProcessError, so we
                # simply return an empty list and leave the app unchanged.
                return []
            return [Path(line) for line in completed.stdout.splitlines() if line]

        # Fallback for non-macOS systems: still works, but only one folder at a
        # time because their Tkinter picker may not support multi-select.
        folder = filedialog.askdirectory(title="Select folder")
        if not folder:
            return []
        return [Path(folder)]

    def _add_folder_path(self, path: Path) -> bool:
        # This helper contains the shared "add this path to the app" rules.
        # Returning True or False lets callers know whether the folder was added.
        if path in self.selected_folders:
            self._log(f"[skip] already added: {path}")
            return False
        self.selected_folders.append(path)
        self.folder_listbox.insert(tk.END, str(path))
        self._log(f"[ok] added: {path}")
        return True

    def remove_selected(self) -> None:
        selected_indices = list(self.folder_listbox.curselection())
        if not selected_indices:
            return
        # Delete from the end first so earlier indexes do not shift while we
        # are removing items from the listbox.
        for index in reversed(selected_indices):
            folder_text = self.folder_listbox.get(index)
            self.folder_listbox.delete(index)
            folder_path = Path(folder_text)
            if folder_path in self.selected_folders:
                self.selected_folders.remove(folder_path)
                self._log(f"[ok] removed: {folder_path}")

    def start_rename(self) -> None:
        if self.is_running:
            return
        if not self.selected_folders:
            messagebox.showwarning("No folders", "Please add at least one folder.")
            return

        self._set_running_state(True)
        self._set_stats(RenameResult())
        self._log("[info] scanning image files...")

        # A background thread keeps the window responsive while files are being
        # scanned and renamed.
        worker = threading.Thread(target=self._rename_worker, daemon=True)
        worker.start()

    def _rename_worker(self) -> None:
        # This method runs in the background thread, not directly in Tkinter's
        # main event loop.
        result = RenameResult()
        try:
            files = scan_images(self.selected_folders)
            result.total = len(files)
            self.log_queue.put(("stats", self._serialize_stats(result)))

            for index, file_path in enumerate(files, start=1):
                try:
                    # strftime formats the date as YYMMDDHHmm, without seconds.
                    timestamp = extract_capture_time(file_path).strftime("%y%m%d%H%M")
                    target = build_target_path(file_path, timestamp)

                    if target == file_path:
                        result.skipped += 1
                        self.log_queue.put(("log", f"[skip] already renamed: {file_path.name}"))
                    else:
                        file_path.rename(target)
                        result.renamed += 1
                        self.log_queue.put(("log", f"[ok] {file_path.name} -> {target.name}"))
                except Exception as exc:
                    # Catching per-file errors lets the app continue with the
                    # rest of the images even if one file fails.
                    result.failed += 1
                    self.log_queue.put(("log", f"[fail] {file_path}: {exc}"))

                if index % 10 == 0 or index == result.total:
                    # Updating stats every 10 files avoids excessive UI work.
                    self.log_queue.put(("stats", self._serialize_stats(result)))

            summary = (
                f"[done] total={result.total}, renamed={result.renamed}, "
                f"skipped={result.skipped}, failed={result.failed}"
            )
            self.log_queue.put(("log", summary))
        finally:
            self.log_queue.put(("stats", self._serialize_stats(result)))
            self.log_queue.put(("done", None))

    def _serialize_stats(self, result: RenameResult) -> str:
        # Queue messages are simple strings. This joins four numbers with "|".
        return f"{result.total}|{result.renamed}|{result.skipped}|{result.failed}"

    def _apply_serialized_stats(self, value: str) -> None:
        # split reverses _serialize_stats and gives the four counter strings.
        total_str, renamed_str, skipped_str, failed_str = value.split("|")
        self.total_var.set(f"Total: {total_str}")
        self.renamed_var.set(f"Renamed: {renamed_str}")
        self.skipped_var.set(f"Skipped: {skipped_str}")
        self.failed_var.set(f"Failed: {failed_str}")

    def _set_stats(self, result: RenameResult) -> None:
        self.total_var.set(f"Total: {result.total}")
        self.renamed_var.set(f"Renamed: {result.renamed}")
        self.skipped_var.set(f"Skipped: {result.skipped}")
        self.failed_var.set(f"Failed: {result.failed}")

    def _set_running_state(self, is_running: bool) -> None:
        self.is_running = is_running
        state = tk.DISABLED if is_running else tk.NORMAL
        self.add_button.config(state=state)
        self.remove_button.config(state=state)
        self.start_button.config(state=state)

    def _log(self, message: str) -> None:
        # The Text widget is normally disabled so the user cannot edit the log.
        # Temporarily enable it, insert a line, then disable it again.
        self.log_text.configure(state=tk.NORMAL)
        self.log_text.insert(tk.END, message + "\n")
        self.log_text.see(tk.END)
        self.log_text.configure(state=tk.DISABLED)

    def _process_log_queue(self) -> None:
        try:
            while True:
                # get_nowait reads one queued message without freezing the UI.
                event_type, payload = self.log_queue.get_nowait()
                if event_type == "log" and payload is not None:
                    self._log(payload)
                elif event_type == "stats" and payload is not None:
                    self._apply_serialized_stats(payload)
                elif event_type == "done":
                    self._set_running_state(False)
        except Empty:
            pass

        self.root.after(100, self._process_log_queue)


def main() -> None:
    # Create the main Tkinter window, attach our App to it, then start Tkinter's
    # event loop. The event loop waits for clicks, timers, and window events.
    root = tk.Tk()
    app = App(root)
    root.minsize(700, 420)
    root.mainloop()


if __name__ == "__main__":
    # This block runs only when the file is executed directly with:
    # python photo_time_renamer.py
    # It does not run when another Python file imports this module.
    main()
