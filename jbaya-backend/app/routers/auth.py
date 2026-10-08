"""Login (Phase 5). No WhatsApp codes for employees: each phone / PC is approved ONCE in the tech panel and is then
bound to that one account. A device approved for one account can never log into another.
Every login is a session that ends daily (DAILY_LOGOUT_AT, Baghdad time) or when the tech panel ends it."""
import uuid

from fastapi import APIRouter, Depends, HTTPException, Request
from pydantic import BaseModel, Field

from .. import audit, runtime
from ..config import settings
from ..db import dict_cursor, get_conn
from ..security import client_ip, create_token, current_user, ip_allowed, session_end, verify_password

router = APIRouter(prefix="/auth", tags=["auth"])


class LoginIn(BaseModel):
    employee_code: str
    password: str
    device_id: str | None = Field(None, min_length=8, max_length=100)
    device_label: str | None = Field(None, max_length=120)
    platform: str | None = Field(None, max_length=40)


def _user_out(emp: dict) -> dict:
    return {
        "id": emp["id"],
        "employee_code": emp["employee_code"],
        "full_name": emp["full_name"],
        "role": emp["role"],
        "sector_id": emp["sector_id"],
        "sector_name": emp["sector_name"],
        "sector_code": emp["sector_code"],
        "permissions": runtime.permissions_for(emp["role"]),
    }


def _load(cur, where: str, arg) -> dict | None:
    cur.execute(
        f"""SELECT e.*, s.name AS sector_name, s.code AS sector_code
            FROM employees e LEFT JOIN sectors s ON s.id = e.sector_id WHERE {where}""",
        (arg,),
    )
    return cur.fetchone()


def _device(cur, emp: dict, body: LoginIn, ip: str, user_agent: str) -> tuple[dict | None, dict | None]:
    """Returns (approved device row or None when devices are not required, pending/blocked response or None)."""
    if not body.device_id:
        if settings.DEVICE_APPROVAL_REQUIRED:
            raise HTTPException(422, "يرجى تحديث التطبيق: معرف الجهاز مفقود")
        return None, None
    cur.execute("SELECT * FROM devices WHERE device_id = %s FOR UPDATE", (body.device_id,))
    d = cur.fetchone()
    if d and d["employee_id"] != emp["id"]:
        cur.execute("SELECT employee_code FROM employees WHERE id = %s", (d["employee_id"],))
        owner = cur.fetchone()["employee_code"]
        audit.log(cur, emp["id"], "device_shared_attempt", "device", d["id"], {"bound_to": owner, "ip": ip})
        raise HTTPException(403, f"هذا الجهاز مرتبط بحساب آخر ({owner}). لا يُسمح باستخدام جهاز واحد لأكثر من حساب")
    if d is None:
        status, note = "pending", None
        if not settings.DEVICE_APPROVAL_REQUIRED:
            status, note = "approved", "اعتماد تلقائي (الموافقة غير مطلوبة)"
        elif emp["role"] == "tech":
            # only for the very first tech device ever (not "whenever none is approved right now")
            cur.execute("SELECT 1 FROM devices d JOIN employees e ON e.id = d.employee_id WHERE e.role = 'tech' LIMIT 1")
            if not cur.fetchone():
                status, note = "approved", "أول جهاز للإدارة التقنية"
        cur.execute(
            """INSERT INTO devices (device_id, employee_id, label, platform, user_agent, first_ip, last_ip, status,
                                   decided_at, decision_note)
               VALUES (%s,%s,%s,%s,%s,%s,%s,%s, CASE WHEN %s = 'approved' THEN NOW() END, %s)
               ON CONFLICT (device_id) DO NOTHING RETURNING *""",
            (body.device_id, emp["id"], body.device_label, body.platform, user_agent[:300], ip, ip, status, status, note),
        )
        d = cur.fetchone()
        if d is None:               # the same new device logged in twice at the same moment
            cur.execute("SELECT * FROM devices WHERE device_id = %s", (body.device_id,))
            d = cur.fetchone()
            if d["employee_id"] != emp["id"]:
                raise HTTPException(403, "هذا الجهاز مرتبط بحساب آخر")
        audit.log(cur, emp["id"], "device_registered", "device", d["id"], {"status": status, "ip": ip, "label": body.device_label})
    if d["status"] == "pending":
        return None, {"device_pending": True, "device_request_id": d["id"],
                      "message": "هذا جهاز جديد. تم إرسال طلب اعتماده إلى الإدارة التقنية، أعد المحاولة بعد الموافقة."}
    if d["status"] in ("rejected", "revoked"):
        raise HTTPException(403, "هذا الجهاز غير معتمد لحسابك. راجع الإدارة التقنية")
    return d, None


@router.post("/login")
def login(body: LoginIn, request: Request):
    code = body.employee_code.strip().upper()
    ip = client_ip(request)
    ua = request.headers.get("user-agent", "")
    error = None
    result = None
    with get_conn() as conn, dict_cursor(conn) as cur:
        runtime.refresh(cur)
        emp = _load(cur, "UPPER(e.employee_code) = %s", code)
        if not emp or not verify_password(body.password, emp["password_hash"]):
            audit.log(cur, emp["id"] if emp else None, "login_failed", "employee", code, {"ip": ip})
            error = (401, "رقم الموظف أو كلمة المرور غير صحيحة")
        elif not emp["active"]:
            error = (403, "الحساب موقوف، راجع الإدارة" + (f": {emp['suspended_reason']}" if emp.get("suspended_reason") else ""))
        elif not ip_allowed(ip, emp["role"]):
            audit.log(cur, emp["id"], "login_blocked_ip", "employee", emp["employee_code"], {"ip": ip})
            error = (403, "الدخول لهذا الحساب غير مسموح من هذه الشبكة")
        else:
            try:
                device, pending = _device(cur, emp, body, ip, ua)
            except HTTPException as e:
                conn.commit()
                raise e
            if pending:
                result = pending
            else:
                if device:
                    # one live session per device; logging in again replaces the old one
                    cur.execute("""UPDATE sessions SET revoked_at = NOW(), revoke_reason = 'دخول جديد من نفس الجهاز'
                                   WHERE device_row_id = %s AND revoked_at IS NULL AND expires_at > NOW()""", (device["id"],))
                    cur.execute("UPDATE devices SET last_seen_at = NOW(), last_ip = %s WHERE id = %s", (ip, device["id"]))
                jti = uuid.uuid4().hex
                expires = session_end()
                cur.execute("INSERT INTO sessions (jti, employee_id, device_row_id, ip, expires_at) VALUES (%s,%s,%s,%s,%s)",
                            (jti, emp["id"], device["id"] if device else None, ip, expires))
                audit.log(cur, emp["id"], "login", "employee", emp["employee_code"],
                          {"role": emp["role"], "ip": ip, "device": device["id"] if device else None})
                result = {"token": create_token(emp, jti=jti, expires=expires), "expires_at": expires.isoformat(),
                          "user": _user_out(emp)}
    if error:
        raise HTTPException(*error)
    return result


@router.post("/verify-2fa")
def verify_two_factor():
    raise HTTPException(410, "لم يعد التحقق عبر واتساب مستخدماً للموظفين. حدّث التطبيق")


@router.post("/logout")
def logout(user: dict = Depends(current_user)):
    with get_conn() as conn, dict_cursor(conn) as cur:
        cur.execute("UPDATE sessions SET revoked_at = NOW(), revoke_reason = 'تسجيل خروج' WHERE jti = %s AND revoked_at IS NULL",
                    (user["session_jti"],))
        audit.log(cur, user["id"], "logout", "employee", user["employee_code"], {})
    return {"ok": True}


@router.get("/me")
def me(user: dict = Depends(current_user)):
    out = {k: user[k] for k in ("id", "employee_code", "full_name", "role", "sector_id", "sector_name", "sector_code")}
    out["permissions"] = runtime.permissions_for(user["role"])
    return out
