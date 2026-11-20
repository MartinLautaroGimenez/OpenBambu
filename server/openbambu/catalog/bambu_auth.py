"""Inicio de sesión en la cuenta Bambu Lab (la misma de MakerWorld).

El token obtenido sirve para descargar perfiles de MakerWorld. Se guarda en
``data/secrets.json`` (fuera de config.yaml) y nunca se devuelve a la app.
Si la cuenta tiene verificación por email, Bambu manda un código que se
ingresa en un segundo paso.
"""

from __future__ import annotations

import json
import os
from pathlib import Path

import httpx

from .base import CatalogError

API = "https://api.bambulab.com/v1/user-service"


class LoginNeedsCode(CatalogError):
    pass


async def login(client: httpx.AsyncClient, email: str, password: str = "", code: str = "") -> str:
    body = {"account": email, "code": code} if code else {"account": email, "password": password, "apiError": ""}
    r = await client.post(f"{API}/user/login", json=body, timeout=20)
    try:
        data = r.json()
    except ValueError as e:
        raise CatalogError(f"Bambu Lab respondió {r.status_code}; probá pegando el token a mano") from e
    if r.status_code >= 400:
        raise CatalogError(data.get("message") or data.get("error") or f"Error {r.status_code}")
    if data.get("accessToken"):
        return data["accessToken"]
    if data.get("loginType") == "verifyCode":
        await client.post(f"{API}/user/sendemail/code", json={"email": email, "type": "codeLogin"}, timeout=20)
        raise LoginNeedsCode("Te enviamos un código por email; ingresalo para terminar")
    if data.get("loginType") == "tfa":
        raise CatalogError("La cuenta usa verificación en dos pasos; pegá el token a mano")
    raise CatalogError("No se pudo iniciar sesión")


def secrets_path(data_dir: str) -> Path:
    return Path(data_dir) / "secrets.json"


def load_secrets(data_dir: str) -> dict:
    p = secrets_path(data_dir)
    try:
        return json.loads(p.read_text())
    except (OSError, ValueError):
        return {}


def save_secret(data_dir: str, key: str, value: str | None) -> None:
    data = load_secrets(data_dir)
    if value:
        data[key] = value
    else:
        data.pop(key, None)
    p = secrets_path(data_dir)
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(json.dumps(data))
    os.chmod(p, 0o600)
