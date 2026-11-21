"""Etiquetas con código QR para los carretes de filamento."""

from __future__ import annotations

import io
from pathlib import Path

import qrcode
from PIL import Image, ImageDraw, ImageFont

PREFIX = "openbambu:spool:"
FONT_DIRS = ("/usr/share/fonts/truetype/dejavu",)


def spool_code(spool_id: int) -> str:
    return f"{PREFIX}{spool_id}"


def parse_code(code: str) -> int | None:
    code = code.strip()
    if code.startswith(PREFIX) and code[len(PREFIX):].isdigit():
        return int(code[len(PREFIX):])
    return None


def _font(size: int, bold: bool = False):
    name = "DejaVuSans-Bold.ttf" if bold else "DejaVuSans.ttf"
    for d in FONT_DIRS:
        p = Path(d) / name
        if p.exists():
            return ImageFont.truetype(str(p), size)
    return ImageFont.load_default(size)


def _fit(draw: ImageDraw.ImageDraw, text: str, width: int, size: int, bold: bool = False):
    while size > 12:
        f = _font(size, bold)
        if draw.textlength(text, font=f) <= width:
            return f
        size -= 2
    return _font(size, bold)


def render_label(spool: dict, width: int = 696, height: int = 300) -> bytes:
    """PNG en blanco y negro (sirve para impresoras de etiquetas de 62 mm)."""
    img = Image.new("RGB", (width, height), "white")
    d = ImageDraw.Draw(img)
    qr = qrcode.QRCode(border=1, box_size=10, error_correction=qrcode.constants.ERROR_CORRECT_M)
    qr.add_data(spool_code(spool["id"]))
    qr.make(fit=True)
    side = height - 24
    q = qr.make_image(fill_color="black", back_color="white").convert("RGB").resize((side, side), Image.NEAREST)
    img.paste(q, (12, 12))

    x, w = side + 36, width - side - 52
    material = spool.get("material") or "?"
    d.text((x, 14), material, font=_fit(d, material, w, 72, True), fill="black")
    brand = spool.get("brand") or ""
    color_name = spool.get("color_name") or ""
    y = 104
    if brand:
        d.text((x, y), brand, font=_fit(d, brand, w, 36), fill="black")
        y += 46
    # Muestra de color (también como recuadro para impresoras monocromo)
    sw = 40
    color = spool.get("color") or "#FFFFFF"
    d.rectangle((x, y + 2, x + sw, y + 2 + sw), fill=color, outline="black", width=3)
    if color_name:
        d.text((x + sw + 12, y + 4), color_name, font=_fit(d, color_name, w - sw - 12, 32), fill="black")
    y += sw + 18
    weight = f"{round(spool.get('weight_g') or 0)} g"
    d.text((x, y), f"{weight}  ·  #{spool['id']}", font=_font(26), fill="black")
    buf = io.BytesIO()
    img.save(buf, "PNG", optimize=True)
    return buf.getvalue()
