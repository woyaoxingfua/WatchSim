"""aiohttp control panel for the headless Lua watchface simulator.

Architecture
------------
Browser  <--WebSocket-->  this server  --stdio line protocol-->  sim_server (C)
                                                                   |
                                                      real LVGL offscreen render

The browser only sends small JSON control messages; after every mutation the
server asks the core for a fresh frame, encodes it as PNG and pushes the binary
back over the same socket. PNG keeps the on-wire payload small (a raw frame is
645 KB, a PNG is typically a few tens of KB) and lets the browser show it with
a plain <img> via a Blob URL.

Run:
    export WATCHSIM_FACE=/path/to/face_dir   # directory holding face.lua
    python3 web/server.py --host 0.0.0.0 --port 8080
"""
from __future__ import annotations

import argparse
import asyncio
import io
import os
import sys

from aiohttp import web
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)

from sim_client import SimClient  # noqa: E402

# Watch face directory: $WATCHSIM_FACE, overridable with --face-dir.
DEFAULT_FACE = os.environ.get("WATCHSIM_FACE", "")
SIM_SERVER = os.path.join(ROOT, "build", "cmake", "sim_server")

# Metadata used to build the panel declaratively on the client.
CONTROLS = [
    {
        "group": "时间",
        "fields": [
            {"key": "timeHour", "label": "时", "min": 0, "max": 23},
            {"key": "timeMinute", "label": "分", "min": 0, "max": 59},
            {"key": "timeSecond", "label": "秒", "min": 0, "max": 59},
        ],
    },
    {
        "group": "日期",
        "fields": [
            {"key": "dateMonth", "label": "月", "min": 1, "max": 12},
            {"key": "dateDay", "label": "日", "min": 1, "max": 31},
            {"key": "dateWeek", "label": "星期(0=日)", "min": 0, "max": 6},
        ],
    },
    {
        "group": "设备",
        "fields": [
            {"key": "systemStatusBattery", "label": "电量", "min": 0, "max": 100},
            {"key": "healthStepCount", "label": "步数", "min": 0, "max": 99999},
        ],
    },
]

WEEK_NAMES = ["日", "一", "二", "三", "四", "五", "六"]


async def encode_png(rgba) -> bytes:
    def _png() -> bytes:
        buf = io.BytesIO()
        Image.fromarray(rgba, "RGBA").save(buf, format="PNG", optimize=True)
        return buf.getvalue()

    return await asyncio.to_thread(_png)


async def index(_request: web.Request) -> web.Response:
    with open(os.path.join(HERE, "index.html"), "rb") as fh:
        return web.Response(body=fh.read(), content_type="text/html")


async def ws_handler(request: web.Request) -> web.WebSocketResponse:
    ws = web.WebSocketResponse(max_msg_size=8 * 1024 * 1024)
    await ws.prepare(request)
    client: SimClient = request.app["sim"]

    async def push_frame() -> None:
        rgba = await asyncio.to_thread(client.frame_rgba)
        png = await encode_png(rgba)
        await ws.send_bytes(png)

    # Initial frame + control schema (with current values so the controls are
    # built in sync with whatever state the core already holds).
    await ws.send_json({"type": "schema", "controls": CONTROLS,
                        "week": WEEK_NAMES, "aod": client.aod,
                        "state": client.state})
    await push_frame()

    async for msg in ws:
        if msg.type == 1:  # text
            try:
                data = msg.json()
            except Exception:
                await ws.send_json({"type": "error", "error": "bad json"})
                continue
            kind = data.get("type")
            try:
                if kind == "inject":
                    await asyncio.to_thread(
                        client.inject_int, data["key"], int(data["value"])
                    )
                elif kind == "mode":
                    await asyncio.to_thread(client.set_mode, int(data["aod"]))
                elif kind == "sentinel":
                    await asyncio.to_thread(client.inject_sentinel, data["key"])
                elif kind == "nan":
                    await asyncio.to_thread(client.inject_nan, data["key"])
                elif kind == "tick":
                    await asyncio.to_thread(client.tick, int(data["ms"]))
                elif kind == "refresh":
                    pass
                else:
                    await ws.send_json({"type": "error", "error": "unknown type"})
                    continue
                await ws.send_json({"type": "ack", "kind": kind,
                                    "aod": client.aod, "state": client.state})
                await push_frame()
            except Exception as exc:  # surface core errors instead of hanging
                await ws.send_json({"type": "error", "error": str(exc)})
        # binary from client is not expected
    return ws


async def on_startup(app: web.Application) -> None:
    face_dir = app["face_dir"]
    app["sim"] = SimClient(SIM_SERVER, face_dir, face_dir.rstrip("/") + "/")


async def on_cleanup(app: web.Application) -> None:
    sim = app.get("sim")
    if sim is not None:
        await asyncio.to_thread(sim.close)


def build_app(face_dir: str) -> web.Application:
    app = web.Application()
    app["face_dir"] = face_dir
    app.on_startup.append(on_startup)
    app.on_cleanup.append(on_cleanup)
    app.router.add_get("/", index)
    app.router.add_get("/ws", ws_handler)
    return app


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", default="0.0.0.0")
    ap.add_argument("--port", type=int, default=8080)
    ap.add_argument("--face-dir", default=DEFAULT_FACE,
                    help="watch face directory (holds face.lua); "
                         "defaults to $WATCHSIM_FACE")
    args = ap.parse_args()
    if not args.face_dir:
        ap.error("no watch face directory: pass --face-dir or set $WATCHSIM_FACE")
    web.run_app(build_app(args.face_dir), host=args.host, port=args.port,
                print=lambda *_: None)


if __name__ == "__main__":
    main()
