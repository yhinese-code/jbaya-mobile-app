"""Password hashing, JWT tokens and role checks."""
import base64
import hashlib
import hmac
import ipaddress
import os
from datetime import datetime, timedelta, timezone

import jwt
from fastapi import Depends, HTTPException, Request
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer

from .config import settings
from .db import dict_cursor, get_conn

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
    return role in settings.TWO_FACTOR_ROLES


def create_token(employee: dict, mfa: bool = False) -> str:
    now = datetime.now(timezone.utc)
    hours = settings.COMMAND_SESSION_HOURS if needs_two_factor(employee["role"]) else settings.JWT_TTL_HOURS
    payload = {
        "sub": str(employee["id"]),
        "role": employee["role"],
        "mfa": mfa,
        "iat": now,
        "exp": now + timedelta(hours=hours),
    }
    return jwt.encode(payload, settings.JWT_SECRET, algorithm="HS256")


_bearer = HTTPBearer(auto_error=False)


def client_ip(request: Request) -> str:
    return request.client.host if request.client else ""


def ip_allowed(ip: str) -> bool:
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


def current_user(request: Request, creds: HTTPAuthorizationCredentials | None = Depends(_bearer)) -> dict:
    if creds is None:
        raise HTTPException(401, "يجب تسجيل الدخول")
    try:
        payload = jwt.decode(creds.credentials, settings.JWT_SECRET, algorithms=["HS256"])
    except jwt.ExpiredSignatureError:
        raise HTTPException(401, "انتهت الجلسة، يرجى تسجيل الدخول مجدداً")
    except jwt.PyJWTError:
        raise HTTPException(401, "رمز الدخول غير صالح")

    with get_conn() as conn, dict_cursor(conn) as cur:
        cur.execute(
            """SELECT e.id, e.employee_code, e.full_name, e.role, e.phone, e.sector_id, e.supervisor_id, e.active,
                      s.name AS sector_name, s.code AS sector_code
               FROM employees e LEFT JOIN sectors s ON s.id = e.sector_id
               WHERE e.id = %s""",
            (int(payload["sub"]),),
        )
        user = cur.fetchone()
    if not user or not user["active"]:
        raise HTTPException(401, "الحساب غير مفعل")
    if needs_two_factor(user["role"]):
        if not payload.get("mfa"):
            raise HTTPException(401, "يجب إكمال التحقق بخطوتين")
        if not ip_allowed(client_ip(request)):
            raise HTTPException(403, "الدخول لغرفة القيادة غير مسموح من هذا الجهاز/الشبكة")
    return dict(user)


def require_roles(*roles: str):
    def checker(user: dict = Depends(current_user)) -> dict:
        if user["role"] not in roles and user["role"] != "admin":
            raise HTTPException(403, "ليس لديك صلاحية لهذا الإجراء")
        return user
    return checker
