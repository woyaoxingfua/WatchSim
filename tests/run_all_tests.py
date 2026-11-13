#!/usr/bin/env python3
"""Full regression suite for the WatchSim project.

Runs every layer of the stack and asserts on real outputs, not just exit codes:
  1. test_anim  - LVGL animation timer advances under a driven tick
  2. diag_pos   - rotated image renders non-empty pixels (the decoder fix)
  3. run_face   - unmodified face.lua renders normal + injected + AOD frames
  4. smoke      - the long-running sim_server stdio core
  5. websocket  - the aiohttp panel end-to-end (server started on a free port)

Usage:
    python3 tests/run_all_tests.py
    # optional: export WATCHSIM_FACE=/path/to/other_face_dir
"""
from __future__ import annotations

import io
import os
import socket
import subprocess
import sys
import time

import numpy as np
from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BUILD = os.path.join(ROOT, "build", "cmake")
FACE = os.environ.get("WATCHSIM_FACE") or os.path.join(ROOT, "examples", "AstroFace")
ASSETS = os.path.join(FACE, "res")
FRAME = 336 * 480 * 4

os.makedirs(os.path.join(ROOT, "build"), exist_ok=True)

results: list[tuple[str, bool, str]] = []


def check(name: str, ok: bool, detail: str = "") -> None:
    results.append((name, bool(ok), detail))
    print(f"[{'PASS' if ok else 'FAIL'}] {name} {detail}")


def binpath(name: str) -> str:
    """Resolve a built binary name, tolerating CMake's .exe suffix on Windows."""
    for cand in (name, name + ".exe"):
        p = os.path.join(BUILD, cand)
        if os.path.exists(p):
            return p
    return os.path.join(BUILD, name)


def run(cmd: str, **kw) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, shell=True, capture_output=True, text=True,
                         cwd=ROOT, timeout=kw.get("timeout", 30))


def free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


# 1. animation -------------------------------------------------------------
r = run(f'"{binpath("test_anim")}"')
out = r.stdout
check("动画推进", "angle=863" in out and "angle=1800" in out,
      "-> 500ms≈900, 1100ms 保持 1800")

# 2. rotation decoder fix --------------------------------------------------
r = run(f'"{binpath("diag_pos")}" "{ASSETS}/w_sunny.png" 1918')
diag_raw = os.path.join(ROOT, "build", "diag.raw")
if os.path.exists(diag_raw):
    a = np.fromfile(diag_raw, dtype=np.uint8)
    # raw frame is RGBA; count non-transparent / non-black pixels
    px = a.reshape(-1, 4)
    lit = int(((px[:, 0] > 20) | (px[:, 3] > 20)).sum())
    check("旋转渲染非空", lit > 1000, f"-> {lit} 个有效像素")
else:
    check("旋转渲染非空", False, "diag.raw 缺失")

# 3. full face: normal / injected / AOD ------------------------------------
for tag, aod, inject, expect in [
    ("亮屏默认", 0, "", "normal"),
    ("亮屏注入", 0, os.path.join(ROOT, "tests", "inject_basic.lua"), "inj"),
    ("AOD 静态", 1, "", "aod"),
]:
    outp = os.path.join(ROOT, "build", f"reg_{expect}.raw")
    extra = f' "{inject}"' if inject else ""
    r = run(f'"{binpath("run_face")}" "{FACE}" "{FACE}/" {aod} "{outp}"{extra}')
    ok = os.path.exists(outp) and os.path.getsize(outp) == FRAME
    check(f"表盘渲染-{tag}", ok, f"-> {os.path.getsize(outp) if ok else '失败'} 字节")

# injected frame must visibly differ from the default frame (any face)
normal = np.fromfile(os.path.join(ROOT, "build", "reg_normal.raw"),
                     dtype=np.uint8).reshape(480, 336, 4)
inj = np.fromfile(os.path.join(ROOT, "build", "reg_inj.raw"),
                  dtype=np.uint8).reshape(480, 336, 4)
changed = int((normal != inj).any(axis=-1).sum())
check("注入帧有变化", changed > 200, f"-> {changed} 像素与默认帧不同")

# 4. sim_server stdio core -------------------------------------------------
r = run("python3 tests/smoke_server.py", timeout=40)
check("stdio 核心冒烟", "exit code: 0" in r.stdout and "STDERR" not in r.stdout,
      "-> 注入/帧/AOD 全 OK")

# 5. websocket end-to-end --------------------------------------------------
port = free_port()
srv = subprocess.Popen(
    [sys.executable, os.path.join(ROOT, "web", "server.py"),
     "--host", "127.0.0.1", "--port", str(port)],
    cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
try:
    import asyncio
    import aiohttp

    async def ws_test() -> tuple[bool, int]:
        url = f"http://127.0.0.1:{port}/ws"
        # wait for the listener
        for _ in range(50):
            try:
                with socket.create_connection(("127.0.0.1", port), .2):
                    break
            except OSError:
                time.sleep(.15)
        frames = 0
        async with aiohttp.ClientSession() as s:
            async with s.ws_connect(url, max_msg_size=8 * 1024 * 1024) as ws:
                await ws.send_json({"type": "inject",
                                    "key": "healthStepCount", "value": 7401})
                async for msg in ws:
                    if msg.type == aiohttp.WSMsgType.BINARY:
                        Image.open(io.BytesIO(msg.data)).verify()
                        frames += 1
                    elif msg.type == aiohttp.WSMsgType.TEXT:
                        d = msg.json()
                        if d.get("type") == "ack":
                            return True, frames
        return frames > 0, frames

    ok, n = asyncio.run(asyncio.wait_for(ws_test(), timeout=25))
    check("WebSocket 端到端", ok, f"-> 收到 {n} 个可解码 PNG")
finally:
    srv.terminate()
    try:
        srv.wait(timeout=5)
    except subprocess.TimeoutExpired:
        srv.kill()

# summary ------------------------------------------------------------------
passed = sum(1 for _, ok, _ in results if ok)
total = len(results)
print("\n" + "=" * 48)
print(f"回归汇总: {passed}/{total} 通过")
if passed != total:
    print("失败项:")
    for name, ok, _ in results:
        if not ok:
            print("  -", name)
sys.exit(0 if passed == total else 1)
