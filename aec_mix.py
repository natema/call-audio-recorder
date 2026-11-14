#!/usr/bin/env python3
"""Build a mixed track: echo-cancelled mic + speaker playback.

The mic hears the same remote audio that we already capture from the
speakers, so a naive sum sounds like echo. Speex AEC subtracts the
speaker signal from the mic first; the mix is then your voice plus the
clean digital far-end.
"""

from __future__ import annotations

import argparse
import array
import ctypes
import ctypes.util
import subprocess
import sys

SR = 48000
FRAME = 480  # 10 ms
TAIL = 9600  # 200 ms, covers laptop path delay and some Bluetooth slack

# speex/speex_echo.h and speex_preprocess.h (speexdsp 1.2)
SPEEX_ECHO_SET_SAMPLING_RATE = 24
SPEEX_PREPROCESS_SET_DENOISE = 0
SPEEX_PREPROCESS_SET_ECHO_SUPPRESS = 20
SPEEX_PREPROCESS_SET_ECHO_SUPPRESS_ACTIVE = 22
SPEEX_PREPROCESS_SET_ECHO_STATE = 24


class SpeexAEC:
    def __init__(self, sr: int = SR, frame: int = FRAME, tail: int = TAIL) -> None:
        libname = ctypes.util.find_library("speexdsp") or "libspeexdsp.so.1"
        self.lib = ctypes.CDLL(libname)
        lib = self.lib
        lib.speex_echo_state_init.restype = ctypes.c_void_p
        lib.speex_echo_state_init.argtypes = [ctypes.c_int, ctypes.c_int]
        lib.speex_echo_cancellation.argtypes = [
            ctypes.c_void_p,
            ctypes.c_void_p,
            ctypes.c_void_p,
            ctypes.c_void_p,
        ]
        lib.speex_echo_ctl.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_void_p]
        lib.speex_echo_state_destroy.argtypes = [ctypes.c_void_p]
        lib.speex_preprocess_state_init.restype = ctypes.c_void_p
        lib.speex_preprocess_state_init.argtypes = [ctypes.c_int, ctypes.c_int]
        lib.speex_preprocess_ctl.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_void_p]
        lib.speex_preprocess_run.argtypes = [ctypes.c_void_p, ctypes.c_void_p]
        lib.speex_preprocess_state_destroy.argtypes = [ctypes.c_void_p]

        self.frame = frame
        self.st = lib.speex_echo_state_init(frame, tail)
        if not self.st:
            raise RuntimeError("speex_echo_state_init failed")
        rate = ctypes.c_int(sr)
        lib.speex_echo_ctl(self.st, SPEEX_ECHO_SET_SAMPLING_RATE, ctypes.byref(rate))
        self.pp = lib.speex_preprocess_state_init(frame, sr)
        if not self.pp:
            lib.speex_echo_state_destroy(self.st)
            raise RuntimeError("speex_preprocess_state_init failed")
        lib.speex_preprocess_ctl(self.pp, SPEEX_PREPROCESS_SET_ECHO_STATE, self.st)
        denoise = ctypes.c_int(0)
        lib.speex_preprocess_ctl(self.pp, SPEEX_PREPROCESS_SET_DENOISE, ctypes.byref(denoise))
        suppress = ctypes.c_int(-40)
        lib.speex_preprocess_ctl(self.pp, SPEEX_PREPROCESS_SET_ECHO_SUPPRESS, ctypes.byref(suppress))
        suppress_dt = ctypes.c_int(-15)
        lib.speex_preprocess_ctl(
            self.pp, SPEEX_PREPROCESS_SET_ECHO_SUPPRESS_ACTIVE, ctypes.byref(suppress_dt)
        )

    def process(self, rec: bytes, play: bytes) -> bytes:
        n = self.frame
        rec_a = (ctypes.c_short * n).from_buffer_copy(rec)
        play_a = (ctypes.c_short * n).from_buffer_copy(play)
        out_a = (ctypes.c_short * n)()
        self.lib.speex_echo_cancellation(self.st, rec_a, play_a, out_a)
        self.lib.speex_preprocess_run(self.pp, out_a)
        mixed = array.array("h")
        for i in range(n):
            s = int(out_a[i]) + int(play_a[i])
            if s > 32767:
                s = 32767
            elif s < -32767:
                s = -32767
            mixed.append(s)
        return mixed.tobytes()

    def close(self) -> None:
        if getattr(self, "pp", None):
            self.lib.speex_preprocess_state_destroy(self.pp)
            self.pp = None
        if getattr(self, "st", None):
            self.lib.speex_echo_state_destroy(self.st)
            self.st = None

    def __del__(self) -> None:
        try:
            self.close()
        except Exception:
            pass


def decoder(path: str, highpass: bool = False) -> subprocess.Popen:
    cmd = [
        "ffmpeg",
        "-hide_banner",
        "-nostdin",
        "-v",
        "error",
        "-i",
        path,
        "-ac",
        "1",
        "-ar",
        str(SR),
        "-sample_fmt",
        "s16",
    ]
    if highpass:
        cmd.extend(["-af", "highpass=f=80"])
    cmd.extend(["-f", "s16le", "-"])
    return subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)


def read_frame(proc: subprocess.Popen, nbytes: int) -> bytes:
    assert proc.stdout is not None
    buf = bytearray()
    while len(buf) < nbytes:
        chunk = proc.stdout.read(nbytes - len(buf))
        if not chunk:
            break
        buf.extend(chunk)
    if not buf:
        return b""
    if len(buf) < nbytes:
        buf.extend(b"\x00" * (nbytes - len(buf)))
    return bytes(buf)


def mix(mic_path: str, speakers_path: str, mixed_path: str) -> None:
    aec = SpeexAEC()
    mic = decoder(mic_path, highpass=True)
    spk = decoder(speakers_path, highpass=False)
    out = subprocess.Popen(
        [
            "ffmpeg",
            "-hide_banner",
            "-nostdin",
            "-v",
            "error",
            "-y",
            "-f",
            "s16le",
            "-ar",
            str(SR),
            "-ac",
            "1",
            "-i",
            "-",
            "-af",
            "alimiter=limit=0.95",
            "-c:a",
            "flac",
            "-sample_fmt",
            "s16",
            mixed_path,
        ],
        stdin=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    nbytes = FRAME * 2
    out_code = 1
    try:
        assert mic.stdout and spk.stdout and out.stdin
        while True:
            rec = read_frame(mic, nbytes)
            play = read_frame(spk, nbytes)
            if not rec and not play:
                break
            if not rec:
                rec = b"\x00" * nbytes
            if not play:
                play = b"\x00" * nbytes
            out.stdin.write(aec.process(rec, play))
        out.stdin.close()
        out_code = out.wait()
    finally:
        aec.close()
        for proc in (mic, spk):
            if proc.stdout:
                proc.stdout.close()
            if proc.poll() is None:
                proc.kill()
            proc.wait()
        if out.poll() is None:
            out.kill()
            out.wait()
            out_code = out.returncode
    if out_code != 0:
        err = b""
        if out.stderr:
            err = out.stderr.read()
        raise RuntimeError(f"flac encoder failed ({out_code}): {err.decode('utf-8', 'replace')}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mic")
    parser.add_argument("speakers")
    parser.add_argument("mixed")
    args = parser.parse_args()
    mix(args.mic, args.speakers, args.mixed)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        print(f"aec_mix: {exc}", file=sys.stderr)
        raise SystemExit(1)
