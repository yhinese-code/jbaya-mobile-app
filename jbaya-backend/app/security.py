"""Password hashing, JWT tokens and role checks."""
import base64
import hashlib
import hmac
import ipaddress
import os
from datetime import datetime, timedelta, timezone
from zoneinfo import ZoneInfo

import jwt
from fastapi import Depends, HTTPException, Request
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer

from .config import settings
from .db import dict_cursor, get_conn
from . import runtime

_PBKDF2_ROUNDS = 260_000


def hash_password(password: str) -> str:
    salt = os.urandom(16)
    dk = hashlib.pbkdf2_hmac("sha256", password.encode(), salt, _PBKDF2_ROUNDS)
    return f"pbkdf2_sha256${_PBKDF2_ROUNDS}${base64.b64encode(salt).decode()}${base64.b64encode(dk).decode()}"


def verify_password(password: str, stored: str) -> bool:
    try:
        _algo, rounds, salt_b64, dk_b64 = stored.split("$")
        dk = hashlib.pbkdf2_hmac("sha256", password.encode(), base64.b64decode(salt_b64), int(rounds))
        return hmac.compare_digest(dk, base64.b64decode(dk_b64))
    except Exception:
        return False


def needs_two_factor(role: str) -> bool:
    """Kept for old callers: employees no longer get WhatsApp login codes (Phase 5 approves devices instead)."""
    return role in (settings.TWO_FACTOR_ROLES or [])


def session_end(now_utc: datetime | None = None) -> datetime:
    """Everyone is logged out daily at DAILY_LOGOUT_AT local time (default midnight Baghdad)."""
    now_utc = now_utc or datetime.now(timezone.utc)
    tz = ZoneInfo(settings.APP_TIMEZONE)
    local = now_utc.astimezone(tz)
    hh, mm = (int(x) for x in settings.DAILY_LOGOUT_AT.split(":"))
    cut = local.replace(hour=hh, minute=mm, second=0, microsecond=0)
    if cut <= local:
        cut += timedelta(days=1)
    return cut.astimezone(timezone.utc)


def create_token(employee: dict, mfa: bool = False, jti: str | None = None, expires: datetime | None = None) -> str:
    now = datetime.now(timezone.utc)
    payload = {
        "sub": str(employee["id"]),
        "role": employee["role"],
        "mfa": mfa,
        "iat": now,
        "exp": expires or session_end(now),
    }
    if jti:
        payload["jti"] = jti
    return jwt.encode(payload, settings.JWT_SECRET, algorithm="HS256")


_bearer = HTTPBearer(auto_error=False)


def client_ip(request: Request) -> str:
    return request.client.host if request.client else ""


def ip_allowed(ip: str, role: str | None = None) -> bool:
    if role is not None and role not in settings.IP_RESTRICTED_ROLES:
        return True
    if not settings.COMMAND_IP_ALLOWLIST:
        return True
    try:
        addr = ipaddress.ip_address(ip)
    except ValueError:
        return False
    for entry in settings.COMMAND_IP_ALLOWLIST:
        try:
            if addr in ipaddress.ip_network(entry, strict=False):
                return True
        except ValueError:
            continue
    return False


_WRITE_METHODS = {"POST", "PUT", "PATCH", "DELETE"}


def current_user(request: Request, creds: HTTPAuthorizationCredentials | None = Depends(_bearer)) -> dict:
    if creds is None:
        raise HTTPException(401, "يجب تسجيل الدخول")
    try:
        payload = jwt.decode(creds.credentials, settings.JWT_SECRET, algorithms=["HS256"])
    except jwt.ExpiredSignatureError:
        raise HTTPException(401, "انتهت الجلسة، يرجى تسجيل الدخول مجدداً")
    except jwt.PyJWTError:
        raise HTTPException(401, "رمز الدخول غير صالح")

    ip = client_ip(request)
    with get_conn() as conn, dict_cursor(conn) as cur:
        runtime.refresh(cur)
        cur.execute(
            """SELECT e.id, e.employee_code, e.full_name, e.role, e.phone, e.sector_id, e.supervisor_id, e.active,
                      e.permissions, s.name AS sector_name, s.code AS sector_code
               FROM employees e LEFT JOIN sectors s ON s.id = e.sector_id
               WHERE e.id = %s""",
            (int(payload["sub"]),),
        )
        user = cur.fetchone()
        sess = None
        if user and payload.get("jti"):
            cur.execute(
                """SELECT s.id, s.revoked_at, s.revoke_reason, d.status AS device_status FROM sessions s
                   LEFT JOIN devices d ON d.id = s.device_row_id WHERE s.jti = %s""",
                (payload["jti"],),
            )
            sess = cur.fetchone()
            if sess and sess["revoked_at"] is None:
                cur.execute("UPDATE sessions SET last_seen_at = NOW() WHERE id = %s AND last_seen_at < NOW() - INTERVAL '60 seconds'",
                            (sess["id"],))
    if not user or not user["active"]:
        raise HTTPException(401, "الحساب غير مفعل")
    if payload.get("jti"):
        if not sess:
            raise HTTPException(401, "الجلسة غير معروفة، يرجى تسجيل الدخول مجدداً")
        if sess["revoked_at"] is not None:
            raise HTTPException(401, "تم إنهاء جلستك من الإدارة التقنية" + (f": {sess['revoke_reason']}" if sess["revoke_reason"] else ""))
        if sess["device_status"] is not None and sess["device_status"] != "approved":
            raise HTTPException(401, "تم إلغاء اعتماد هذا الجهاز، راجع الإدارة التقنية")
    else:
        raise HTTPException(401, "يرجى تسجيل الدخول مجدداً")
    if not ip_allowed(ip, user["role"]):
        raise HTTPException(403, "الدخول لهذا الحساب غير مسموح من هذه الشبكة")
    feature = runtime.feature_for_path(user["role"], request.url.path)
    if feature and not runtime.allowed(user["role"], feature):
        raise HTTPException(403, "هذا القسم غير مفعل لحسابك")
    if settings.MAINTENANCE_MODE and request.method in _WRITE_METHODS and user["role"] != "tech":
        raise HTTPException(503, "المنظومة في وضع الصيانة حالياً (قراءة فقط)")
    out = dict(user)
    out["session_jti"] = payload.get("jti")
    return out


def require_tech(user: dict = Depends(current_user)) -> dict:
    """The tech panel: the `tech` role only (admin does NOT pass here)."""
    if user["role"] != "tech":
        raise HTTPException(403, "هذه الصلاحية للإدارة التقنية فقط")
    return user


def require_roles(*roles: str):
    def checker(user: dict = Depends(current_user)) -> dict:
        if user["role"] not in roles and user["role"] not in ("admin", "tech"):
            raise HTTPException(403, "ليس لديك صلاحية لهذا الإجراء")
        return user
    return checker
