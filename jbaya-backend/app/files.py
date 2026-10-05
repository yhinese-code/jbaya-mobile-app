"""Evidence photos (meter readings, bank slips). Stored on disk, never served publicly:
only returned through authenticated endpoints as base64."""
import base64
import binascii
import secrets
from datetime import datetime, timezone
from pathlib import Path

from fastapi import HTTPException

from .config import settings

_BACKEND_DIR = Path(__file__).resolve().parent.parent


def _root() -> Path:
    root = Path(settings.STORAGE_DIR)
    if not root.is_absolute():
        root = _BACKEND_DIR / root
    return root


def _detect(data: bytes) -> str | None:
    if data[:3] == b"\xff\xd8\xff":
        return "jpg"
    if data[:8] == b"\x89PNG\r\n\x1a\n":
        return "png"
    if data[:4] == b"RIFF" and data[8:12] == b"WEBP":
        return "webp"
    return None


def save_photo(b64: str, folder: str) -> str:
    """Validates a base64 JPEG/PNG/WEBP and stores it. Returns the relative path saved in the database."""
    if "," in b64[:100] and b64.lstrip().startswith("data:"):
        b64 = b64.split(",", 1)[1]
    try:
        data = base64.b64decode(b64, validate=True)
    except (binascii.Error, ValueError):
        raise HTTPException(422, "ملف الصورة غير صالح")
    if len(data) > settings.MAX_PHOTO_BYTES:
        raise HTTPException(413, "حجم الصورة كبير جداً، أعد التصوير")
    ext = _detect(data)
    if not ext:
        raise HTTPException(422, "يجب أن تكون الصورة بصيغة JPG أو PNG")
    day = datetime.now(timezone.utc).strftime("%Y/%m/%d")
    rel = Path(folder) / day / f"{secrets.token_hex(12)}.{ext}"
    full = _root() / rel
    full.parent.mkdir(parents=True, exist_ok=True)
    full.write_bytes(data)
    return rel.as_posix()


def load_photo(rel: str | None) -> dict | None:
    if not rel:
        return None
    full = (_root() / rel).resolve()
    if _root().resolve() not in full.parents or not full.exists():
        return None
    data = full.read_bytes()
    mime = {"jpg": "image/jpeg", "png": "image/png", "webp": "image/webp"}[full.suffix.lstrip(".")]
    return {"mime": mime, "base64": base64.b64encode(data).decode()}
