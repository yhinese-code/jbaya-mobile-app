"""Login. Field roles get a token straight away; Command and admin (TWO_FACTOR_ROLES) must also confirm
a code sent to their own WhatsApp number."""
from fastapi import APIRouter, Depends, HTTPException, Request
from pydantic import BaseModel, Field

from .. import audit, codes, whatsapp
from ..config import settings
from ..db import dict_cursor, get_conn
from ..security import client_ip, create_token, current_user, ip_allowed, needs_two_factor, verify_password
from ..utils import mask_phone

router = APIRouter(prefix="/auth", tags=["auth"])


class LoginIn(BaseModel):
    employee_code: str
    password: str


def _user_out(emp: dict) -> dict:
    return {
        "id": emp["id"],
        "employee_code": emp["employee_code"],
        "full_name": emp["full_name"],
        "role": emp["role"],
        "sector_id": emp["sector_id"],
        "sector_name": emp["sector_name"],
        "sector_code": emp["sector_code"],
    }


def _load(cur, where: str, arg) -> dict | None:
    cur.execute(
        f"""SELECT e.*, s.name AS sector_name, s.code AS sector_code
            FROM employees e LEFT JOIN sectors s ON s.id = e.sector_id WHERE {where}""",
        (arg,),
    )
    return cur.fetchone()


@router.post("/login")
def login(body: LoginIn, request: Request):
    code = body.employee_code.strip().upper()
    ip = client_ip(request)
    error = None
    result = None
    with get_conn() as conn, dict_cursor(conn) as cur:
        emp = _load(cur, "UPPER(e.employee_code) = %s", code)
        if not emp or not verify_password(body.password, emp["password_hash"]):
            audit.log(cur, emp["id"] if emp else None, "login_failed", "employee", code, {"ip": ip})
            error = (401, "رقم الموظف أو كلمة المرور غير صحيحة")
        elif not emp["active"]:
            error = (403, "الحساب موقوف، راجع الإدارة")
        elif needs_two_factor(emp["role"]):
            if not ip_allowed(ip):
                audit.log(cur, emp["id"], "login_blocked_ip", "employee", emp["employee_code"], {"ip": ip})
                error = (403, "الدخول لغرفة القيادة غير مسموح من هذا الجهاز/الشبكة")
            elif not emp["phone"]:
                error = (403, "لا يوجد رقم واتساب مسجل لهذا الحساب، راجع مدير النظام")
            else:
                ch, otp = codes.create_login_challenge(cur, employee_id=emp["id"], ip=ip)
                whatsapp.send_otp(emp["phone"], otp)
                audit.log(cur, emp["id"], "login_2fa_sent", "employee", emp["employee_code"], {"ip": ip})
                result = {
                    "two_factor_required": True,
                    "challenge_id": ch["id"],
                    "phone_masked": mask_phone(emp["phone"]),
                    "resend_after_seconds": settings.OTP_RESEND_COOLDOWN_SECONDS,
                }
        else:
            audit.log(cur, emp["id"], "login", "employee", emp["employee_code"], {"role": emp["role"], "ip": ip})
            result = {"token": create_token(emp), "user": _user_out(emp)}
    if error:
        raise HTTPException(*error)
    return result


class TwoFactorIn(BaseModel):
    challenge_id: int
    code: str = Field(..., min_length=4, max_length=10)


@router.post("/verify-2fa")
def verify_two_factor(body: TwoFactorIn, request: Request):
    ip = client_ip(request)
    with get_conn() as conn, dict_cursor(conn) as cur:
        res = codes.check_login_challenge(cur, challenge_id=body.challenge_id, code=body.code)
        if not res["ok"]:
            if res.get("employee_id"):
                audit.log(cur, res["employee_id"], "login_2fa_failed", "employee", res["employee_id"], {"ip": ip})
        else:
            emp = _load(cur, "e.id = %s", res["employee_id"])
            audit.log(cur, emp["id"], "login", "employee", emp["employee_code"], {"role": emp["role"], "ip": ip, "mfa": True})
    if not res["ok"]:
        raise HTTPException(res["status"], res["message"])
    if not emp["active"]:
        raise HTTPException(403, "الحساب موقوف، راجع الإدارة")
    return {"token": create_token(emp, mfa=True), "user": _user_out(emp)}


@router.get("/me")
def me(user: dict = Depends(current_user)):
    return {k: user[k] for k in ("id", "employee_code", "full_name", "role", "sector_id", "sector_name", "sector_code")}
