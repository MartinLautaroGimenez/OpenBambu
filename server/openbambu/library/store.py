"""Persistencia (SQLite) de la biblioteca de archivos y la cola de impresión."""

from __future__ import annotations

import json
import secrets
import sqlite3
import threading
import time
from pathlib import Path

SCHEMA = """
CREATE TABLE IF NOT EXISTS library (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    filename TEXT NOT NULL,
    size INTEGER NOT NULL,
    added REAL NOT NULL,
    source TEXT NOT NULL,
    meta TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS jobs (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    printer_id TEXT NOT NULL,
    library_id TEXT NOT NULL,
    name TEXT NOT NULL,
    plate INTEGER NOT NULL,
    ams_mapping TEXT NOT NULL,
    options TEXT NOT NULL,
    status TEXT NOT NULL,
    position REAL NOT NULL,
    error TEXT,
    created REAL NOT NULL,
    started REAL,
    finished REAL
);
CREATE TABLE IF NOT EXISTS prints (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    printer_id TEXT NOT NULL,
    name TEXT NOT NULL,
    file TEXT,
    library_id TEXT,
    plate INTEGER,
    job_id INTEGER,
    status TEXT NOT NULL,
    started REAL NOT NULL,
    finished REAL,
    progress INTEGER NOT NULL DEFAULT 0,
    weight_g REAL,
    cost REAL,
    filaments TEXT NOT NULL DEFAULT '[]',
    error TEXT,
    snapshot INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS spools (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    brand TEXT NOT NULL DEFAULT '',
    material TEXT NOT NULL,
    color TEXT,
    color_name TEXT NOT NULL DEFAULT '',
    weight_g REAL NOT NULL DEFAULT 1000,
    remaining_g REAL NOT NULL DEFAULT 1000,
    price REAL NOT NULL DEFAULT 0,
    printer_id TEXT,
    tray INTEGER,
    archived INTEGER NOT NULL DEFAULT 0,
    created REAL NOT NULL,
    notes TEXT NOT NULL DEFAULT ''
);
CREATE TABLE IF NOT EXISTS queue_state (
    printer_id TEXT PRIMARY KEY,
    paused INTEGER NOT NULL DEFAULT 0,
    bed_clear INTEGER NOT NULL DEFAULT 0
);
"""

ACTIVE = ("uploading", "starting", "printing")
OPEN = ("queued", *ACTIVE)


class Store:
    def __init__(self, data_dir: Path):
        self.dir = Path(data_dir)
        self.files_dir = self.dir / "library"
        self.files_dir.mkdir(parents=True, exist_ok=True)
        self._db = sqlite3.connect(self.dir / "openbambu.db", check_same_thread=False)
        self._db.row_factory = sqlite3.Row
        self._lock = threading.Lock()
        with self._lock:
            self._db.executescript(SCHEMA)
            # Trabajos que quedaron a medio arrancar si el servidor se reinició
            self._db.execute(
                "UPDATE jobs SET status='queued' WHERE status IN ('uploading','starting')"
            )
            self._db.commit()

    def _q(self, sql: str, args: tuple = ()) -> list[sqlite3.Row]:
        with self._lock:
            cur = self._db.execute(sql, args)
            self._db.commit()
            return cur.fetchall()

    # ---- biblioteca --------------------------------------------------------
    def file_path(self, item: dict) -> Path:
        return self.files_dir / item["id"] / item["filename"]

    def add_file(self, name: str, filename: str, size: int, source: str, meta: dict) -> dict:
        lid = secrets.token_hex(8)
        self._q(
            "INSERT INTO library VALUES (?,?,?,?,?,?,?)",
            (lid, name, filename, size, time.time(), source, json.dumps(meta)),
        )
        return self.get_file(lid)  # type: ignore[return-value]

    def new_file_dir(self) -> tuple[str, Path]:
        lid = secrets.token_hex(8)
        d = self.files_dir / lid
        d.mkdir(parents=True, exist_ok=True)
        return lid, d

    def insert_file(self, lid: str, name: str, filename: str, size: int, source: str, meta: dict) -> dict:
        self._q(
            "INSERT INTO library VALUES (?,?,?,?,?,?,?)",
            (lid, name, filename, size, time.time(), source, json.dumps(meta)),
        )
        return self.get_file(lid)  # type: ignore[return-value]

    @staticmethod
    def _file(row: sqlite3.Row) -> dict:
        d = dict(row)
        d["meta"] = json.loads(d["meta"])
        return d

    def get_file(self, lid: str) -> dict | None:
        rows = self._q("SELECT * FROM library WHERE id=?", (lid,))
        return self._file(rows[0]) if rows else None

    def list_files(self) -> list[dict]:
        return [self._file(r) for r in self._q("SELECT * FROM library ORDER BY added DESC")]

    def delete_file(self, lid: str) -> None:
        self._q("DELETE FROM library WHERE id=?", (lid,))

    # ---- cola --------------------------------------------------------------
    @staticmethod
    def _job(row: sqlite3.Row) -> dict:
        d = dict(row)
        d["ams_mapping"] = json.loads(d["ams_mapping"])
        d["options"] = json.loads(d["options"])
        return d

    def add_job(self, printer_id: str, library_id: str, name: str, plate: int,
                ams_mapping: list[int], options: dict, front: bool = False) -> dict:
        rows = self._q(
            f"SELECT {'MIN' if front else 'MAX'}(position) AS p FROM jobs WHERE printer_id=? AND status='queued'",
            (printer_id,),
        )
        p = rows[0]["p"]
        pos = (p - 1 if front else p + 1) if p is not None else 0.0
        with self._lock:
            cur = self._db.execute(
                "INSERT INTO jobs (printer_id, library_id, name, plate, ams_mapping, options, status, position, created)"
                " VALUES (?,?,?,?,?,?,'queued',?,?)",
                (printer_id, library_id, name, plate, json.dumps(ams_mapping), json.dumps(options), pos, time.time()),
            )
            self._db.commit()
            jid = cur.lastrowid
        return self.get_job(jid)  # type: ignore[arg-type,return-value]

    def get_job(self, jid: int) -> dict | None:
        rows = self._q("SELECT * FROM jobs WHERE id=?", (jid,))
        return self._job(rows[0]) if rows else None

    def jobs(self, printer_id: str, history: int = 20) -> list[dict]:
        open_ = self._q(
            f"SELECT * FROM jobs WHERE printer_id=? AND status IN ({','.join('?' * len(OPEN))}) ORDER BY position",
            (printer_id, *OPEN),
        )
        done = self._q(
            f"SELECT * FROM jobs WHERE printer_id=? AND status NOT IN ({','.join('?' * len(OPEN))})"
            " ORDER BY finished DESC LIMIT ?",
            (printer_id, *OPEN, history),
        )
        # Los activos primero, luego la cola por posición
        open_jobs = sorted((self._job(r) for r in open_), key=lambda j: (j["status"] == "queued", j["position"]))
        return open_jobs + [self._job(r) for r in done]

    def next_queued(self, printer_id: str) -> dict | None:
        rows = self._q(
            "SELECT * FROM jobs WHERE printer_id=? AND status='queued' ORDER BY position LIMIT 1", (printer_id,)
        )
        return self._job(rows[0]) if rows else None

    def active_job(self, printer_id: str) -> dict | None:
        rows = self._q(
            f"SELECT * FROM jobs WHERE printer_id=? AND status IN ({','.join('?' * len(ACTIVE))}) LIMIT 1",
            (printer_id, *ACTIVE),
        )
        return self._job(rows[0]) if rows else None

    def update_job(self, jid: int, **fields) -> None:
        if "status" in fields and fields["status"] in ("done", "failed", "cancelled"):
            fields.setdefault("finished", time.time())
        if fields.get("status") == "starting":
            fields.setdefault("started", time.time())
        cols = ", ".join(f"{k}=?" for k in fields)
        self._q(f"UPDATE jobs SET {cols} WHERE id=?", (*fields.values(), jid))

    def delete_job(self, jid: int) -> None:
        self._q("DELETE FROM jobs WHERE id=?", (jid,))

    def reorder(self, printer_id: str, ids: list[int]) -> None:
        for i, jid in enumerate(ids):
            self._q("UPDATE jobs SET position=? WHERE id=? AND printer_id=? AND status='queued'",
                    (float(i), jid, printer_id))

    def clear_history(self, printer_id: str) -> None:
        self._q(
            f"DELETE FROM jobs WHERE printer_id=? AND status NOT IN ({','.join('?' * len(OPEN))})",
            (printer_id, *OPEN),
        )

    def queue_state(self, printer_id: str) -> dict:
        rows = self._q("SELECT * FROM queue_state WHERE printer_id=?", (printer_id,))
        if not rows:
            return {"paused": False, "bed_clear": False}
        return {"paused": bool(rows[0]["paused"]), "bed_clear": bool(rows[0]["bed_clear"])}

    def set_queue_state(self, printer_id: str, **fields) -> None:
        st = {**self.queue_state(printer_id), **fields}
        self._q(
            "INSERT INTO queue_state (printer_id, paused, bed_clear) VALUES (?,?,?)"
            " ON CONFLICT(printer_id) DO UPDATE SET paused=excluded.paused, bed_clear=excluded.bed_clear",
            (printer_id, int(st["paused"]), int(st["bed_clear"])),
        )

    # ---- historial de impresiones -----------------------------------------
    @staticmethod
    def _print(row: sqlite3.Row) -> dict:
        d = dict(row)
        d["filaments"] = json.loads(d["filaments"] or "[]")
        d["snapshot"] = bool(d["snapshot"])
        return d

    def add_print(self, **fields) -> int:
        fields.setdefault("started", time.time())
        if "filaments" in fields:
            fields["filaments"] = json.dumps(fields["filaments"])
        cols = ", ".join(fields)
        with self._lock:
            cur = self._db.execute(f"INSERT INTO prints ({cols}) VALUES ({','.join('?' * len(fields))})",
                                   tuple(fields.values()))
            self._db.commit()
            return cur.lastrowid  # type: ignore[return-value]

    def update_print(self, pid: int, **fields) -> None:
        if "filaments" in fields:
            fields["filaments"] = json.dumps(fields["filaments"])
        if "snapshot" in fields:
            fields["snapshot"] = int(fields["snapshot"])
        cols = ", ".join(f"{k}=?" for k in fields)
        self._q(f"UPDATE prints SET {cols} WHERE id=?", (*fields.values(), pid))

    def get_print(self, pid: int) -> dict | None:
        rows = self._q("SELECT * FROM prints WHERE id=?", (pid,))
        return self._print(rows[0]) if rows else None

    def open_print(self, printer_id: str) -> dict | None:
        rows = self._q("SELECT * FROM prints WHERE printer_id=? AND status='printing' ORDER BY id DESC LIMIT 1",
                       (printer_id,))
        return self._print(rows[0]) if rows else None

    def prints(self, printer_id: str | None = None, limit: int = 50, offset: int = 0) -> list[dict]:
        if printer_id:
            rows = self._q("SELECT * FROM prints WHERE printer_id=? ORDER BY started DESC LIMIT ? OFFSET ?",
                           (printer_id, limit, offset))
        else:
            rows = self._q("SELECT * FROM prints ORDER BY started DESC LIMIT ? OFFSET ?", (limit, offset))
        return [self._print(r) for r in rows]

    def delete_print(self, pid: int) -> None:
        self._q("DELETE FROM prints WHERE id=?", (pid,))

    # ---- inventario de filamento ------------------------------------------
    SPOOL_FIELDS = ("brand", "material", "color", "color_name", "weight_g", "remaining_g", "price",
                    "printer_id", "tray", "archived", "notes")

    def add_spool(self, **fields) -> dict:
        data = {k: v for k, v in fields.items() if k in self.SPOOL_FIELDS}
        data["created"] = time.time()
        with self._lock:
            cur = self._db.execute(
                f"INSERT INTO spools ({', '.join(data)}) VALUES ({','.join('?' * len(data))})", tuple(data.values()))
            self._db.commit()
            sid = cur.lastrowid
        if data.get("tray") is not None:
            self.assign_tray(sid, data.get("printer_id"), data["tray"])  # type: ignore[arg-type]
        return self.get_spool(sid)  # type: ignore[arg-type,return-value]

    def get_spool(self, sid: int) -> dict | None:
        rows = self._q("SELECT * FROM spools WHERE id=?", (sid,))
        return dict(rows[0]) if rows else None

    def spools(self, include_archived: bool = False) -> list[dict]:
        sql = "SELECT * FROM spools" + ("" if include_archived else " WHERE archived=0") + " ORDER BY material, brand"
        return [dict(r) for r in self._q(sql)]

    def update_spool(self, sid: int, **fields) -> dict | None:
        data = {k: v for k, v in fields.items() if k in self.SPOOL_FIELDS}
        if "tray" in data:
            tray = data.pop("tray")
            self.assign_tray(sid, data.get("printer_id") or (self.get_spool(sid) or {}).get("printer_id"), tray)
        if data:
            cols = ", ".join(f"{k}=?" for k in data)
            self._q(f"UPDATE spools SET {cols} WHERE id=?", (*data.values(), sid))
        return self.get_spool(sid)

    def assign_tray(self, sid: int, printer_id: str | None, tray: int | None) -> None:
        """Un carrete por bandeja: libera la bandeja si otro carrete la tenía."""
        if tray is not None:
            self._q("UPDATE spools SET tray=NULL WHERE printer_id=? AND tray=? AND id<>?", (printer_id, tray, sid))
        self._q("UPDATE spools SET tray=?, printer_id=? WHERE id=?", (tray, printer_id, sid))

    def spool_in_tray(self, printer_id: str, tray: int) -> dict | None:
        rows = self._q("SELECT * FROM spools WHERE printer_id=? AND tray=? AND archived=0", (printer_id, tray))
        return dict(rows[0]) if rows else None

    def delete_spool(self, sid: int) -> None:
        self._q("DELETE FROM spools WHERE id=?", (sid,))

    def consume(self, sid: int, grams: float) -> dict | None:
        self._q("UPDATE spools SET remaining_g=MAX(0, remaining_g-?) WHERE id=?", (grams, sid))
        return self.get_spool(sid)
