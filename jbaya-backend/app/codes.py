"""OTP challenges (sent to the citizen's WhatsApp) and the rotating master code (Command only)."""
import hashlib
import hmac
import secrets
import struct
import time
from datetime import datetime, timedelta, timezone

from fastapi import HTTPException

from .config import settings


# ---------------------------------------------------------------- OTP

def generate_otp() -> str:
    return str(secrets.randbelow(10 ** settings.OTP_DIGITS)).zfill(settings.OTP_DIGITS)


def _otp_hash(challenge_salt: str, code: str) -> str:
    return hmac.new(settings.OTP_SECRET.encode(), f"{challenge_salt}:{code}".encode(), hashlib.sha256).hexdigest()


def create_challenge(cur, *, purpose: str, property_id: int, bill_id: int | None, phone: str, created_by: int) -> tuple[dict, str]:
    """Supersedes any open challenge for the same property/purpose, stores only the hash.
    Returns (challenge_row, plain_code). The plain code must ONLY be sent to WhatsApp."""
    # resend cooldown
    cur.execute(
        """SELECT created_at FROM otp_challenges
           WHERE property_id = %s AND purpose = %s AND status = 'pending'
           ORDER BY created_at DESC LIMIT 1""",
        (property_id, purpose),
    )
    last = cur.fetchone()
    if last:
        elapsed = (datetime.now(timezone.utc) - last["created_at"]).total_seconds()
        if elapsed < settings.OTP_RESEND_COOLDOWN_SECONDS:
            wait = int(settings.OTP_RESEND_COOLDOWN_SECONDS - elapsed) + 1
            raise HTTPException(429, f"يرجى الانتظار {wait} ثانية قبل إعادة إرسال الرمز")

    cur.execute(
        "UPDATE otp_challenges SET status = 'superseded' WHERE property_id = %s AND purpose = %s AND status = 'pending'",
        (property_id, purpose),
    )
    code = generate_otp()
    salt = secrets.token_hex(8)
    expires = datetime.now(timezone.utc) + timedelta(seconds=settings.OTP_TTL_SECONDS)
    cur.execute(
        """INSERT INTO otp_challenges (purpose, property_id, bill_id, phone, code_hash, expires_at, max_attempts, created_by)
           VALUES (%s, %s, %s, %s, %s, %s, %s, %s) RETURNING *""",
        (purpose, property_id, bill_id, phone, f"{salt}${_otp_hash(salt, code)}", expires,
         settings.OTP_MAX_ATTEMPTS, created_by),
    )
    return cur.fetchone(), code


def check_challenge(cur, *, purpose: str, property_id: int, bill_id: int | None, code: str) -> dict:
    """Validates the latest pending challenge. Never raises: returns {"ok": bool, ...} so the caller can
    COMMIT the attempt counter first and only then raise an HTTP error (otherwise a rollback would
    erase failed attempts and allow unlimited guessing)."""
    cur.execute(
        """SELECT * FROM otp_challenges
           WHERE property_id = %s AND purpose = %s AND status = 'pending'
             AND (%s::int IS NULL OR bill_id = %s::int)
           ORDER BY created_at DESC LIMIT 1 FOR UPDATE""",
        (property_id, purpose, bill_id, bill_id),
    )
    ch = cur.fetchone()
    if not ch:
        return {"ok": False, "status": 400, "message": "لا يوجد رمز تحقق فعال، يرجى إرسال رمز جديد"}

    if datetime.now(timezone.utc) > ch["expires_at"]:
        cur.execute("UPDATE otp_challenges SET status = 'expired' WHERE id = %s", (ch["id"],))
        return {"ok": False, "status": 400, "message": "انتهت صلاحية الرمز، يرجى إرسال رمز جديد"}

    salt, stored = ch["code_hash"].split("$", 1)
    if hmac.compare_digest(_otp_hash(salt, (code or "").strip()), stored):
        cur.execute("UPDATE otp_challenges SET status = 'verified', verified_at = NOW(), attempts = attempts + 1 WHERE id = %s", (ch["id"],))
        return {"ok": True, "challenge": ch}

    attempts = ch["attempts"] + 1
    if attempts >= ch["max_attempts"]:
        cur.execute("UPDATE otp_challenges SET attempts = %s, status = 'locked' WHERE id = %s", (attempts, ch["id"]))
        return {"ok": False, "status": 400, "message": "تم تجاوز عدد المحاولات. تم إلغاء الرمز، يرجى إرسال رمز جديد"}
    cur.execute("UPDATE otp_challenges SET attempts = %s WHERE id = %s", (attempts, ch["id"]))
    left = ch["max_attempts"] - attempts
    return {"ok": False, "status": 400, "message": f"الرمز غير صحيح. المحاولات المتبقية: {left}"}


# ---------------------------------------------------------------- Rotating master code

def _window_index(ts: float | None = None) -> int:
    return int((ts if ts is not None else time.time()) // settings.MASTER_CODE_WINDOW_SECONDS)


def master_code_for_window(window: int) -> str:
    """HOTP-style: HMAC(secret, window) -> dynamic truncation -> N digits. Not stored anywhere."""
    mac = hmac.new(settings.MASTER_CODE_SECRET.encode(), struct.pack(">Q", window), hashlib.sha256).digest()
    offset = mac[-1] & 0x0F
    value = struct.unpack(">I", mac[offset:offset + 4])[0] & 0x7FFFFFFF
    return str(value % (10 ** settings.OTP_DIGITS)).zfill(settings.OTP_DIGITS)


def current_master_code(ts: float | None = None) -> dict:
    now = ts if ts is not None else time.time()
    w = _window_index(now)
    valid_until = (w + 1) * settings.MASTER_CODE_WINDOW_SECONDS
    return {
        "code": master_code_for_window(w),
        "window_index": w,
        "valid_until": datetime.fromtimestamp(valid_until, timezone.utc).isoformat(),
        "seconds_remaining": int(valid_until - now),
        "window_seconds": settings.MASTER_CODE_WINDOW_SECONDS,
    }


def match_master_code(code: str, ts: float | None = None) -> int | None:
    """Returns the matching window index, or None. The previous window's code is accepted for a short grace period
    after rotation, so a code read out at 9:59 still works at 10:00."""
    now = ts if ts is not None else time.time()
    w = _window_index(now)
    code = (code or "").strip()
    if hmac.compare_digest(code, master_code_for_window(w)):
        return w
    into_window = now - w * settings.MASTER_CODE_WINDOW_SECONDS
    if into_window < settings.MASTER_CODE_GRACE_SECONDS and hmac.compare_digest(code, master_code_for_window(w - 1)):
        return w - 1
    return None
