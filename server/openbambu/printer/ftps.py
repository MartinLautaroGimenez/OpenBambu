"""Acceso a la tarjeta SD de la impresora por FTPS implícito (puerto 990).

Particularidades de Bambu:
  * TLS implícito (el socket se envuelve en TLS antes del saludo FTP)
  * El canal de datos exige reutilizar la sesión TLS del canal de control
  * Usuario ``bblp`` y contraseña = código de acceso
"""

from __future__ import annotations

import asyncio
import ftplib
import posixpath
import ssl
from collections.abc import Callable
from datetime import datetime
from pathlib import Path

FTPS_PORT = 990
USERNAME = "bblp"
PRINTABLE_EXT = (".3mf", ".gcode")


class ImplicitFTPS(ftplib.FTP_TLS):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self._sock = None

    @property
    def sock(self):  # type: ignore[override]
        return self._sock

    @sock.setter
    def sock(self, value):
        if value is not None and not isinstance(value, ssl.SSLSocket):
            value = self.context.wrap_socket(value, server_hostname=self.host)
        self._sock = value

    def ntransfercmd(self, cmd, rest=None):
        conn, size = ftplib.FTP.ntransfercmd(self, cmd, rest)
        if self._prot_p:
            # Reutilizar la sesión TLS: la impresora rechaza el canal de datos si no
            conn = self.context.wrap_socket(conn, server_hostname=self.host, session=self.sock.session)
        return conn, size


def _context() -> ssl.SSLContext:
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    return ctx


class PrinterFiles:
    """Operaciones sincrónicas sobre la SD; usar los métodos ``a*`` desde asyncio."""

    def __init__(self, host: str, access_code: str, port: int = FTPS_PORT, timeout: float = 20):
        self.host, self.code, self.port, self.timeout = host, access_code, port, timeout
        self._lock = asyncio.Lock()

    def _connect(self) -> ImplicitFTPS:
        ftp = ImplicitFTPS(context=_context(), timeout=self.timeout)
        ftp.connect(self.host, self.port)
        ftp.login(USERNAME, self.code)
        ftp.prot_p()
        return ftp

    def _run(self, fn: Callable[[ImplicitFTPS], object]):
        ftp = self._connect()
        try:
            return fn(ftp)
        finally:
            try:
                ftp.quit()
            except (ftplib.all_errors, OSError):
                ftp.close()

    # ---- operaciones -------------------------------------------------------
    def list(self, path: str = "/") -> list[dict]:
        def op(ftp: ImplicitFTPS):
            items = []
            try:
                for name, facts in ftp.mlsd(path, facts=["type", "size", "modify"]):
                    if name in (".", ".."):
                        continue
                    items.append(_entry(path, name, facts.get("type") == "dir",
                                        int(facts.get("size", 0) or 0), facts.get("modify")))
                return items
            except ftplib.error_perm:
                pass  # el servidor no soporta MLSD: usar LIST
            lines: list[str] = []
            ftp.retrlines(f"LIST {path}", lines.append)
            for line in lines:
                parsed = _parse_list_line(line)
                if parsed:
                    name, is_dir, size = parsed
                    items.append(_entry(path, name, is_dir, size, None))
            return items

        items = self._run(op)
        return sorted(items, key=lambda x: (not x["is_dir"], x["name"].lower()))

    def upload(self, local: Path, remote: str, progress: Callable[[int], None] | None = None) -> None:
        def op(ftp: ImplicitFTPS):
            sent = 0

            def cb(block: bytes):
                nonlocal sent
                sent += len(block)
                if progress:
                    progress(sent)

            with open(local, "rb") as f:
                ftp.storbinary(f"STOR {remote}", f, blocksize=64 * 1024, callback=cb)

        self._run(op)

    def download(self, remote: str, local: Path) -> None:
        def op(ftp: ImplicitFTPS):
            with open(local, "wb") as f:
                ftp.retrbinary(f"RETR {remote}", f.write, blocksize=64 * 1024)

        self._run(op)

    def delete(self, remote: str) -> None:
        self._run(lambda ftp: ftp.delete(remote))

    # ---- versiones async ---------------------------------------------------
    async def alist(self, path: str = "/") -> list[dict]:
        async with self._lock:
            return await asyncio.to_thread(self.list, path)

    async def aupload(self, local: Path, remote: str, progress: Callable[[int], None] | None = None) -> None:
        async with self._lock:
            await asyncio.to_thread(self.upload, local, remote, progress)

    async def adownload(self, remote: str, local: Path) -> None:
        async with self._lock:
            await asyncio.to_thread(self.download, remote, local)

    async def adelete(self, remote: str) -> None:
        async with self._lock:
            await asyncio.to_thread(self.delete, remote)


def _entry(path: str, name: str, is_dir: bool, size: int, modify: str | None) -> dict:
    mtime = None
    if modify:
        try:
            mtime = datetime.strptime(modify[:14], "%Y%m%d%H%M%S").timestamp()
        except ValueError:
            pass
    return {
        "name": name,
        "path": posixpath.join(path, name),
        "is_dir": is_dir,
        "size": size,
        "modified": mtime,
        "printable": not is_dir and name.lower().endswith(PRINTABLE_EXT),
    }


def _parse_list_line(line: str) -> tuple[str, bool, int] | None:
    """Parsea una línea estilo ``ls -l``: ``drwxr-xr-x 1 0 0 0 Jan 1 00:00 nombre``."""
    parts = line.split(maxsplit=8)
    if len(parts) < 9:
        return None
    try:
        size = int(parts[4])
    except ValueError:
        size = 0
    return parts[8], parts[0].startswith("d"), size

