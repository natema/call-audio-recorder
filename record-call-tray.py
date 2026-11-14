#!/usr/bin/env python3
"""Top-bar indicator shown while call audio is being recorded."""

from __future__ import annotations

import argparse
import os
import signal
import subprocess
import sys
import time
from pathlib import Path

import gi

gi.require_version("Gtk", "3.0")
gi.require_version("AyatanaAppIndicator3", "0.1")
from gi.repository import AyatanaAppIndicator3 as AppIndicator
from gi.repository import GLib, Gtk

HERE = Path(__file__).resolve().parent
RECORDER = HERE / "record-call.sh"
ICON_DIR = HERE / "icons"
LOCK_DIR = Path(os.environ.get("XDG_RUNTIME_DIR", "/tmp")) / "call-recorder"
TRAY_LOCK = LOCK_DIR / "tray.lock"
STATUS_FILE = LOCK_DIR / "status"
LABEL_GUIDE = "REC 00:00:00"


def pid_alive(pid: int) -> bool:
    if pid <= 0:
        return False
    try:
        os.kill(pid, 0)
    except OSError:
        return False
    return True


def read_pid(path: Path) -> int | None:
    try:
        text = path.read_text(encoding="utf-8").strip()
        pid = int(text.split()[0])
    except (OSError, ValueError, IndexError):
        return None
    return pid if pid_alive(pid) else None


def read_status() -> dict[str, str]:
    data: dict[str, str] = {}
    try:
        raw = STATUS_FILE.read_text(encoding="utf-8")
    except OSError:
        return data
    for line in raw.splitlines():
        if "=" not in line:
            continue
        key, value = line.split("=", 1)
        data[key] = value
    return data


def hms(seconds: int) -> str:
    seconds = max(0, int(seconds))
    return f"{seconds // 3600:02d}:{(seconds % 3600) // 60:02d}:{seconds % 60:02d}"


class TrayRecorder:
    def __init__(self, output_dir: str | None, local_dir: str | None, duration: int | None) -> None:
        self.output_dir = output_dir
        self.local_dir = local_dir
        self.duration = duration
        self.proc: subprocess.Popen[bytes] | None = None
        self.started = time.time()
        self.stopping = False
        self._tick = 0

        LOCK_DIR.mkdir(parents=True, exist_ok=True)
        TRAY_LOCK.write_text(str(os.getpid()), encoding="utf-8")

        self.status_item = Gtk.MenuItem(label="Starting…")
        self.status_item.set_sensitive(False)
        self.mic_item = Gtk.MenuItem(label="Microphone: …")
        self.mic_item.set_sensitive(False)
        self.spk_item = Gtk.MenuItem(label="Speakers: …")
        self.spk_item.set_sensitive(False)
        self.stop_item = Gtk.MenuItem(label="Stop recording")
        self.stop_item.connect("activate", self.on_stop)

        menu = Gtk.Menu()
        for item in (
            self.status_item,
            self.mic_item,
            self.spk_item,
            Gtk.SeparatorMenuItem(),
            self.stop_item,
        ):
            item.show()
            menu.append(item)

        self.indicator = AppIndicator.Indicator.new(
            "call-recorder",
            "call-recorder-on",
            AppIndicator.IndicatorCategory.APPLICATION_STATUS,
        )
        if ICON_DIR.is_dir():
            self.indicator.set_icon_theme_path(str(ICON_DIR))
        self.indicator.set_icon_full("call-recorder-on", "Recording call audio")
        self.indicator.set_attention_icon_full("call-recorder-on", "Recording call audio")
        self.indicator.set_title("Call recorder")
        self.indicator.set_status(AppIndicator.IndicatorStatus.ATTENTION)
        self.indicator.set_menu(menu)
        self.indicator.set_secondary_activate_target(self.stop_item)
        self.indicator.set_label("REC 00:00:00", LABEL_GUIDE)

        GLib.unix_signal_add(GLib.PRIORITY_DEFAULT, signal.SIGINT, self.on_unix_stop)
        GLib.unix_signal_add(GLib.PRIORITY_DEFAULT, signal.SIGTERM, self.on_unix_stop)
        GLib.timeout_add_seconds(1, self.on_tick)

        self.start_recorder()

    def start_recorder(self) -> None:
        cmd = [str(RECORDER), "--headless"]
        if self.output_dir is not None:
            # May be empty: "no share folder", overriding the environment.
            cmd.extend(["--share-dir", self.output_dir])
        if self.local_dir:
            cmd.extend(["--local-dir", self.local_dir])
        if self.duration is not None:
            cmd.extend(["--duration", str(self.duration)])
        log = LOCK_DIR / "tray-recorder.log"
        log_f = log.open("ab")
        self.proc = subprocess.Popen(
            cmd,
            stdin=subprocess.DEVNULL,
            stdout=log_f,
            stderr=subprocess.STDOUT,
            cwd=str(HERE),
        )

    def on_unix_stop(self, *_args) -> bool:
        self.request_stop()
        return True

    def on_stop(self, *_args) -> None:
        self.request_stop()

    def request_stop(self) -> None:
        if self.stopping:
            return
        self.stopping = True
        self.stop_item.set_sensitive(False)
        self.status_item.set_label("Saving…")
        self.indicator.set_label("Saving…", LABEL_GUIDE)
        if self.proc is not None and self.proc.poll() is None:
            self.proc.send_signal(signal.SIGINT)

    def on_tick(self) -> bool:
        self._tick += 1
        status = read_status()
        if status.get("state") in {"encoding", "saved"}:
            self.stopping = True
        self.refresh_menu()
        if self.proc is not None and self.proc.poll() is not None:
            self.finish()
            return False
        if not self.stopping:
            elapsed = int(time.time() - self.started)
            self.indicator.set_label(f"REC {hms(elapsed)}", LABEL_GUIDE)
        return True

    def refresh_menu(self) -> None:
        status = read_status()
        elapsed = int(time.time() - self.started)
        state = status.get("state", "")
        if self.stopping or state in {"encoding", "saved"}:
            self.status_item.set_label("Saving…")
            self.indicator.set_label("Saving…", LABEL_GUIDE)
        else:
            self.status_item.set_label(f"Recording  {hms(elapsed)}")
        mic = status.get("mic_description")
        spk = status.get("sink_description")
        if mic:
            self.mic_item.set_label(f"Microphone: {mic}")
        if spk:
            self.spk_item.set_label(f"Speakers: {spk}")

    def finish(self) -> None:
        Gtk.main_quit()

    def cleanup(self) -> None:
        if self.proc is not None and self.proc.poll() is None:
            self.proc.send_signal(signal.SIGINT)
            try:
                self.proc.wait(timeout=8)
            except subprocess.TimeoutExpired:
                self.proc.send_signal(signal.SIGTERM)
        try:
            if TRAY_LOCK.is_file() and TRAY_LOCK.read_text(encoding="utf-8").strip() == str(
                os.getpid()
            ):
                TRAY_LOCK.unlink()
        except OSError:
            pass


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Call recorder tray icon")
    parser.add_argument("--share-dir", help="optional folder for the mixed Opus file")
    parser.add_argument("--output-dir", help="alias of --share-dir")
    parser.add_argument("--local-dir", help="folder for the recordings")
    parser.add_argument("--duration", type=int, help="stop after N seconds")
    return parser.parse_args()


def main() -> int:
    if not RECORDER.is_file():
        print(f"Missing recorder script: {RECORDER}", file=sys.stderr)
        return 1
    args = parse_args()
    share_dir = args.share_dir if args.share_dir is not None else args.output_dir
    app = TrayRecorder(share_dir, args.local_dir, args.duration)
    try:
        Gtk.main()
    finally:
        app.cleanup()
    code = 0
    if app.proc is not None and app.proc.returncode not in (0, None, 255):
        code = app.proc.returncode
    return 0 if code == 255 else code


if __name__ == "__main__":
    sys.exit(main())
