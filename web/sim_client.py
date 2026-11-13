"""Python wrapper around the long-running `sim_server` C process.

The simulator core speaks a line-based protocol over stdio:
  * text commands  -> one-line "OK ..." / "ERR ..." acknowledgements
  * FRAME          -> a "FRAME <n>" header followed by exactly n raw bytes

This wrapper is synchronous on purpose: the aiohttp server runs it inside a
single-worker event loop and serialises calls through a lock, so the child
process never sees interleaved commands. Keeping the wrapper plain (no async)
also makes it usable from ordinary scripts and the test-suite.
"""
from __future__ import annotations

import subprocess
import threading

import numpy as np

FRAME_W = 336
FRAME_H = 480
FRAME_BYTES = FRAME_W * FRAME_H * 4


class SimClient:
    def __init__(self, sim_server: str, face_dir: str, script_path: str):
        self._proc = subprocess.Popen(
            [sim_server, face_dir, script_path, "0"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        self._lock = threading.RLock()
        ready = self._readline()
        if ready != "READY":
            raise RuntimeError(f"sim_server did not become ready: {ready!r}")
        # Last values pushed to each key, so a mode reload can replay them.
        self.state: dict[str, int] = {}
        self.aod = 0

    # ------------------------------------------------------------------
    # low-level line protocol
    # ------------------------------------------------------------------
    def _writeline(self, text: str) -> None:
        self._proc.stdin.write((text + "\n").encode())
        self._proc.stdin.flush()

    def _readline(self) -> str:
        return self._proc.stdout.readline().decode().strip()

    # ------------------------------------------------------------------
    # public API
    # ------------------------------------------------------------------
    def inject_int(self, key: str, value: int) -> None:
        with self._lock:
            self._writeline(f"INJECT_INT {key} {int(value)}")
            ack = self._readline()
            if not ack.startswith("OK"):
                raise RuntimeError(ack)
            self.state[key] = int(value)

    def inject_sentinel(self, key: str) -> None:
        with self._lock:
            self._writeline(f"SENTINEL {key}")
            ack = self._readline()
            if not ack.startswith("OK"):
                raise RuntimeError(ack)

    def inject_nan(self, key: str) -> None:
        with self._lock:
            self._writeline(f"NAN {key}")
            ack = self._readline()
            if not ack.startswith("OK"):
                raise RuntimeError(ack)

    def tick(self, ms: int) -> None:
        with self._lock:
            self._writeline(f"TICK {int(ms)}")
            ack = self._readline()
            if not ack.startswith("OK"):
                raise RuntimeError(ack)

    def set_mode(self, aod: int) -> None:
        """Reload the face in the requested mode and replay the snapshot."""
        with self._lock:
            self._writeline(f"MODE {1 if aod else 0}")
            ack = self._readline()
            if not ack.startswith("OK"):
                raise RuntimeError(ack)
            self.aod = 1 if aod else 0
            # MODE rebuilds the Lua state, so re-publish the current snapshot.
            snapshot = dict(self.state)
            for key, value in snapshot.items():
                self._writeline(f"INJECT_INT {key} {value}")
                sub = self._readline()
                if not sub.startswith("OK"):
                    raise RuntimeError(sub)

    def frame_rgba(self) -> np.ndarray:
        """Return the current frame as an (H, W, 4) uint8 RGBA array."""
        with self._lock:
            self._writeline("FRAME")
            header = self._readline()
            parts = header.split()
            if len(parts) != 2 or parts[0] != "FRAME":
                raise RuntimeError(f"unexpected frame header: {header!r}")
            raw = self._proc.stdout.read(int(parts[1]))
            if len(raw) != FRAME_BYTES:
                raise RuntimeError(f"short frame: {len(raw)} != {FRAME_BYTES}")
            return np.frombuffer(raw, dtype=np.uint8).reshape(
                FRAME_H, FRAME_W, 4
            ).copy()

    def close(self) -> None:
        with self._lock:
            try:
                self._writeline("QUIT")
                self._readline()
            except (BrokenPipeError, ValueError):
                pass
            try:
                self._proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self._proc.kill()
                self._proc.wait()
