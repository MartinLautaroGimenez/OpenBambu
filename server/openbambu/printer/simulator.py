"""Impresora simulada: permite probar el servidor y la app sin una A1 real.

Imita los reportes MQTT de una A1 con AMS lite, responde a los comandos y
genera una "cámara" sintética.
"""

from __future__ import annotations

import asyncio
import io
import re
import shutil
import tempfile
import time
from collections.abc import AsyncIterator
from pathlib import Path

from .base import BasePrinter

DEMO_JOBS = ["Benchy", "Soporte de auriculares", "Maceta low-poly", "Engranaje planetario"]


def _initial_report() -> dict:
    colors = ["FFFFFFFF", "161616FF", "E4002BFF", "0086D6FF"]
    names = [("PLA", "PLA Basic"), ("PLA", "PLA Matte"), ("PETG", "PETG HF"), ("PLA", "PLA Basic")]
    return {
        "print": {
            "gcode_state": "IDLE",
            "stg_cur": 255,
            "mc_percent": 0,
            "mc_remaining_time": 0,
            "layer_num": 0,
            "total_layer_num": 0,
            "subtask_name": "",
            "gcode_file": "",
            "nozzle_temper": 26.0,
            "nozzle_target_temper": 0,
            "bed_temper": 25.0,
            "bed_target_temper": 0,
            "cooling_fan_speed": "0",
            "heatbreak_fan_speed": "0",
            "spd_lvl": 2,
            "spd_mag": 100,
            "print_error": 0,
            "wifi_signal": "-48dBm",
            "nozzle_diameter": "0.4",
            "sdcard": True,
            "hms": [],
            "lights_report": [{"node": "chamber_light", "mode": "on"}],
            "ams": {
                "ams": [
                    {
                        "id": "0",
                        "humidity": "4",
                        "temp": "0.0",
                        "tray": [
                            {
                                "id": str(i),
                                "tray_type": t,
                                "tray_sub_brands": n,
                                "tray_color": colors[i],
                                "remain": [92, 40, 75, 8][i],
                                "nozzle_temp_min": "190" if t == "PLA" else "220",
                                "nozzle_temp_max": "230" if t == "PLA" else "260",
                                "tray_info_idx": "GFA00",
                            }
                            for i, (t, n) in enumerate(names)
                        ],
                    }
                ],
                "tray_now": "255",
            },
            "vt_tray": {"id": "254", "tray_type": "", "tray_color": "00000000"},
        }
    }


class SimFiles:
    """Tarjeta SD simulada sobre un directorio local."""

    def __init__(self, root: Path):
        self.root = root
        self.root.mkdir(parents=True, exist_ok=True)
        (self.root / "timelapse").mkdir(exist_ok=True)

    def _p(self, remote: str) -> Path:
        p = (self.root / remote.lstrip("/")).resolve()
        if self.root.resolve() not in (p, *p.parents):
            raise PermissionError("Ruta inválida")
        return p

    async def alist(self, path: str = "/") -> list[dict]:
        d = self._p(path)
        items = []
        for f in d.iterdir():
            st = f.stat()
            items.append({
                "name": f.name,
                "path": f"{path.rstrip('/')}/{f.name}",
                "is_dir": f.is_dir(),
                "size": 0 if f.is_dir() else st.st_size,
                "modified": st.st_mtime,
                "printable": f.is_file() and f.name.lower().endswith((".3mf", ".gcode")),
            })
        return sorted(items, key=lambda x: (not x["is_dir"], x["name"].lower()))

    async def aupload(self, local: Path, remote: str, progress=None) -> None:
        await asyncio.to_thread(shutil.copyfile, local, self._p(remote))
        if progress:
            progress(local.stat().st_size)

    async def adownload(self, remote: str, local: Path) -> None:
        await asyncio.to_thread(shutil.copyfile, self._p(remote), local)

    async def adelete(self, remote: str) -> None:
        self._p(remote).unlink()


class SimulatedPrinter(BasePrinter):
    SPEED_FACTOR = {1: 0.5, 2: 1.0, 3: 1.5, 4: 2.0}

    def __init__(self, cfg):
        super().__init__(cfg)
        self.state.apply(_initial_report())
        self._job_index = 0
        self._progress = 0.0
        self._idle_since = time.time() - 20
        # Inicia trabajos de demo solo hasta que se use la cola / impresión real
        self.auto_demo = True
        self._files = SimFiles(Path(tempfile.gettempdir()) / f"openbambu-sim-{cfg.id}")

    @property
    def files(self) -> SimFiles:
        return self._files

    @property
    def p(self) -> dict:
        return self.state.raw["print"]

    async def _run(self) -> None:
        await asyncio.sleep(0.5)
        self.state.connected = True
        self._emit()
        while True:
            self._tick()
            self._emit()
            await asyncio.sleep(1)

    # ---- simulación ----------------------------------------------------
    def _approach(self, cur_key: str, target_key: str, rate: float, ambient: float) -> None:
        cur, tgt = float(self.p[cur_key]), float(self.p[target_key]) or ambient
        step = rate if tgt > cur else rate * 0.6
        cur = min(tgt, cur + step) if tgt > cur else max(tgt, cur - step)
        self.p[cur_key] = round(cur, 1)

    def _start_job(self, name: str | None = None, file: str | None = None) -> None:
        if name is None:
            name = DEMO_JOBS[self._job_index % len(DEMO_JOBS)]
            self._job_index += 1
        self._progress = 0.0
        self.p.update(
            gcode_state="PREPARE",
            stg_cur=2,
            subtask_name=name,
            gcode_file=file or f"/sdcard/{name}.gcode.3mf",
            mc_percent=0,
            total_layer_num=120,
            layer_num=0,
            mc_remaining_time=42,
            nozzle_target_temper=220,
            bed_target_temper=65,
            print_error=0,
            s_obj=[],
        )
        self.p["ams"]["tray_now"] = "0"
        self.p["ams"]["ams"][0]["tray"][0]["remain"] = 92

    def _tick(self) -> None:
        p = self.p
        self._approach("nozzle_temper", "nozzle_target_temper", 9, 26)
        self._approach("bed_temper", "bed_target_temper", 2.5, 25)
        state = p["gcode_state"]

        if state in ("IDLE", "FINISH", "FAILED"):
            if self.auto_demo and time.time() - self._idle_since > 25:
                self._start_job()
            return

        if state == "PREPARE":
            if p["bed_temper"] >= p["bed_target_temper"] - 1:
                p["stg_cur"] = 7
            if p["nozzle_temper"] >= p["nozzle_target_temper"] - 2 and p["stg_cur"] == 7:
                p.update(gcode_state="RUNNING", stg_cur=0, cooling_fan_speed="15", heatbreak_fan_speed="15")
            return

        if state == "RUNNING":
            self._progress += 0.35 * self.SPEED_FACTOR.get(int(p["spd_lvl"]), 1)
            pct = min(100, int(self._progress))
            p["mc_percent"] = pct
            p["layer_num"] = max(1, round(pct / 100 * p["total_layer_num"]))
            p["mc_remaining_time"] = max(0, round(42 * (100 - self._progress) / 100))
            tray = p["ams"]["ams"][0]["tray"][0]
            tray["remain"] = max(0, 92 - pct // 10)
            if pct >= 100:
                self._finish("FINISH")

    def _finish(self, state: str) -> None:
        self.p.update(
            gcode_state=state,
            stg_cur=255,
            mc_remaining_time=0,
            nozzle_target_temper=0,
            bed_target_temper=0,
            cooling_fan_speed="0",
            heatbreak_fan_speed="0",
        )
        self.p["ams"]["tray_now"] = "255"
        self._idle_since = time.time()

    # ---- comandos ------------------------------------------------------
    async def send(self, payload: dict, wait: bool = True) -> dict:
        await asyncio.sleep(0.05)
        p = self.p
        if "system" in payload and payload["system"].get("command") == "ledctrl":
            p["lights_report"] = [{"node": "chamber_light", "mode": payload["system"]["led_mode"]}]
        cmd = payload.get("print", {})
        name = cmd.get("command")
        if name == "pause" and p["gcode_state"] == "RUNNING":
            p.update(gcode_state="PAUSE", stg_cur=16)
        elif name == "resume" and p["gcode_state"] == "PAUSE":
            p.update(gcode_state="RUNNING", stg_cur=0)
        elif name == "stop" and p["gcode_state"] in ("RUNNING", "PAUSE", "PREPARE"):
            p["print_error"] = 50348044  # código real de "impresión cancelada"
            self._finish("FAILED")
        elif name == "project_file" and p["gcode_state"] in ("IDLE", "FINISH", "FAILED"):
            self.auto_demo = False
            if not self._files._p(cmd["file"]).exists():
                return {"result": "failed"}
            self._start_job(cmd.get("subtask_name") or cmd["file"], f"/sdcard/{cmd['file']}")
        elif name == "skip_objects":
            p["s_obj"] = sorted(set(p.get("s_obj", [])) | {int(i) for i in cmd["obj_list"]})
        elif name == "print_speed":
            p["spd_lvl"] = int(cmd["param"])
            p["spd_mag"] = {1: 50, 2: 100, 3: 124, 4: 166}[p["spd_lvl"]]
        elif name == "ams_change_filament":
            p["ams"]["tray_now"] = str(cmd["target"])
        elif name == "ams_filament_setting" and cmd["ams_id"] == 0:
            tray = p["ams"]["ams"][0]["tray"][cmd["tray_id"]]
            tray.update(
                tray_type=cmd["tray_type"],
                tray_sub_brands=f"Genérico {cmd['tray_type']}",
                tray_color=cmd["tray_color"],
                nozzle_temp_min=str(cmd["nozzle_temp_min"]),
                nozzle_temp_max=str(cmd["nozzle_temp_max"]),
                remain=-1,
            )
        elif name == "gcode_line":
            self._gcode(cmd["param"])
        self.state.updated_at = time.time()
        self._emit()
        return {"result": "success"}

    def _gcode(self, text: str) -> None:
        for line in text.splitlines():
            if m := re.match(r"M104 S(\d+)", line):
                self.p["nozzle_target_temper"] = int(m[1])
            elif m := re.match(r"M140 S(\d+)", line):
                self.p["bed_target_temper"] = int(m[1])
            elif m := re.match(r"M106 P1 S(\d+)", line):
                self.p["cooling_fan_speed"] = str(round(int(m[1]) / 255 * 15))

    # ---- cámara --------------------------------------------------------
    async def camera_frames(self) -> AsyncIterator[bytes]:
        from PIL import Image, ImageDraw, ImageFont

        font = ImageFont.load_default(size=30)
        small = ImageFont.load_default(size=24)

        while True:
            p = self.p
            img = Image.new("RGB", (1280, 720), (18, 20, 24))
            d = ImageDraw.Draw(img)
            light = any(x.get("mode") == "on" for x in p.get("lights_report", []))
            bed_color = (70, 74, 82) if light else (35, 37, 41)
            d.polygon([(240, 640), (1040, 640), (900, 430), (380, 430)], fill=bed_color)
            for i in range(9):
                x0 = 240 + i * 100
                x1 = 380 + i * 65
                d.line([(x0, 640), (x1, 430)], fill=(90, 95, 104) if light else (45, 47, 52))
            h = int(180 * p.get("mc_percent", 0) / 100)
            if p.get("gcode_state") in ("RUNNING", "PAUSE", "FINISH"):
                d.rectangle([560, 560 - h, 720, 560], fill=(228, 228, 228) if light else (110, 110, 110))
            head_y = 560 - h - 40
            d.rectangle([590, head_y - 60, 690, head_y], fill=(60, 180, 110))
            d.text((28, 640), f"OpenBambu · simulador  {time.strftime('%H:%M:%S')}", fill=(220, 220, 220), font=font)
            d.text((28, 680), f"{p.get('gcode_state')}  {p.get('mc_percent')}%  "
                   f"boquilla {p.get('nozzle_temper')}°C  cama {p.get('bed_temper')}°C", fill=(160, 200, 170), font=small)
            buf = io.BytesIO()
            img.save(buf, "JPEG", quality=70)
            yield buf.getvalue()
            await asyncio.sleep(1)
