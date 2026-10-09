"""Tech panel (لوحة التقنية) — "god mode" (Phase 5).

Full control over every portal and account: device approvals and sessions, accounts and roles, every rate and formula,
switches (global / per sector / per person), the tab-permission matrix, tariffs, sectors, WhatsApp, fraud watch and
the audit log. Every action here is written to the tamper-evident audit log.
"""
import json
from typing import Literal

from fastapi import APIRouter, Depends, HTTPException, Query
from pydantic import BaseModel, Field

from .. import audit, runtime, whatsapp
from ..config import settings
from ..db import dict_cursor, get_conn
from ..security import hash_password, require_tech
from ..utils import normalize_iraqi_phone

router = APIRouter(prefix="/tech", tags=["tech"])
tech_only = require_tech
ROLES = ("collector", "supervisor", "finance", "command", "hr", "owner", "tech", "admin")
ROLE_LABELS = {"collector": "جابي", "supervisor": "مشرف", "finance": "مالية", "command": "قيادة", "hr": "موارد بشرية",
               "owner": "المالك", "tech": "التقنية", "admin": "مدير النظام"}


def _iso(v):
    return v.isoformat() if v else None


def _emp(cur, code: str) -> dict:
    cur.execute("SELECT * FROM employees WHERE UPPER(employee_code) = UPPER(%s)", (code.strip(),))
    e = cur.fetchone()
    if not e:
        raise HTTPException(404, "الموظف غير موجود")
    return e


def _end_sessions(cur, where: str, args: tuple, actor: dict, reason: str) -> int:
    cur.execute(f"""UPDATE sessions SET revoked_at = NOW(), revoked_by = %s, revoke_reason = %s
                    WHERE revoked_at IS NULL AND expires_at > NOW() AND {where} RETURNING id""", (actor["id"], reason, *args))
    return len(cur.fetchall())


# ================================================================ overview

@router.get("/overview")
def overview(user: dict = Depends(tech_only)):
    with get_conn() as conn, dict_cursor(conn) as cur:
        runtime.refresh(cur, force=True)
        cur.execute("SELECT COUNT(*) AS n FROM devices WHERE status = 'pending'")
        pending = cur.fetchone()["n"]
        cur.execute("SELECT COUNT(*) AS n FROM sessions WHERE revoked_at IS NULL AND expires_at > NOW()")
        sessions = cur.fetchone()["n"]
        cur.execute("""SELECT COUNT(DISTINCT employee_id) AS n FROM sessions
                       WHERE revoked_at IS NULL AND expires_at > NOW() AND last_seen_at > NOW() - INTERVAL '10 minutes'""")
        online = cur.fetchone()["n"]
        cur.execute("SELECT role, COUNT(*) FILTER (WHERE active) AS active, COUNT(*) FILTER (WHERE NOT active) AS suspended "
                    "FROM employees GROUP BY role ORDER BY role")
        roles = cur.fetchall()
        cur.execute("SELECT COUNT(*) AS n FROM sectors WHERE switches <> '{}'::jsonb")
        sector_overrides = cur.fetchone()["n"]
        cur.execute("SELECT COUNT(*) AS n FROM employees WHERE permissions <> '{}'::jsonb")
        person_overrides = cur.fetchone()["n"]
        cur.execute("SELECT COUNT(*) AS n FROM audit_log WHERE action = 'device_shared_attempt' AND created_at > NOW() - INTERVAL '7 days'")
        shared = cur.fetchone()["n"]
        cur.execute("SELECT COUNT(*) AS n FROM system_settings")
        overridden = cur.fetchone()["n"]
    return {
        "pending_devices": pending, "active_sessions": sessions, "online_now": online,
        "roles": [{**r, "label": ROLE_LABELS.get(r["role"], r["role"])} for r in roles],
        "switches": {k: getattr(settings, v) for k, v in runtime.SWITCHES.items()},
        "maintenance_mode": settings.MAINTENANCE_MODE, "whatsapp_mode": settings.WHATSAPP_MODE,
        "gain_share_mode": settings.GAIN_SHARE_MODE, "device_approval_required": settings.DEVICE_APPROVAL_REQUIRED,
        "sector_overrides": sector_overrides, "person_overrides": person_overrides,
        "device_sharing_attempts_7d": shared, "settings_overridden": overridden,
    }


# ================================================================ devices and sessions

@router.get("/devices")
def devices(status: Literal["pending", "approved", "rejected", "revoked", "all"] = "pending", user: dict = Depends(tech_only)):
    with get_conn() as conn, dict_cursor(conn) as cur:
        cur.execute(
            """SELECT d.*, e.employee_code, e.full_name, e.role,
                      (SELECT COUNT(*) FROM devices x WHERE x.employee_id = d.employee_id AND x.status = 'approved') AS approved_count,
                      dec.employee_code AS decided_by_code
               FROM devices d JOIN employees e ON e.id = d.employee_id LEFT JOIN employees dec ON dec.id = d.decided_by
               WHERE %(s)s = 'all' OR d.status = %(s)s ORDER BY d.requested_at DESC LIMIT 300""",
            {"s": status},
        )
        rows = cur.fetchall()
    out = []
    for r in rows:
        limit = settings.DEVICE_LIMITS.get(r["role"], 1)
        out.append({"id": r["id"], "device_id": r["device_id"][:12] + "…", "label": r["label"], "platform": r["platform"],
                    "user_agent": r["user_agent"], "first_ip": r["first_ip"], "last_ip": r["last_ip"], "status": r["status"],
                    "employee_code": r["employee_code"], "full_name": r["full_name"], "role": r["role"],
                    "role_label": ROLE_LABELS.get(r["role"], r["role"]), "requested_at": _iso(r["requested_at"]),
                    "decided_at": _iso(r["decided_at"]), "decided_by": r["decided_by_code"], "note": r["decision_note"],
                    "last_seen_at": _iso(r["last_seen_at"]), "approved_count": r["approved_count"], "limit": limit})
    return out


class DeviceDecisionIn(BaseModel):
    action: Literal["approve", "reject", "revoke"]
    note: str | None = Field(None, max_length=300)
    replace_oldest: bool = False          # approving above the role's limit revokes that person's oldest device


@router.post("/devices/{device_row_id}/decision")
def decide_device(device_row_id: int, body: DeviceDecisionIn, user: dict = Depends(tech_only)):
    with get_conn() as conn, dict_cursor(conn) as cur:
        cur.execute("SELECT d.*, e.role, e.employee_code FROM devices d JOIN employees e ON e.id = d.employee_id "
                    "WHERE d.id = %s FOR UPDATE OF d", (device_row_id,))
        d = cur.fetchone()
        if not d:
            raise HTTPException(404, "الجهاز غير موجود")
        cur.execute("SELECT id FROM employees WHERE id = %s FOR UPDATE", (d["employee_id"],))   # one decision at a time per person
        replaced = []
        if body.action == "approve":
            if d["status"] == "approved":
                raise HTTPException(409, "الجهاز معتمد مسبقاً")
            limit = settings.DEVICE_LIMITS.get(d["role"], 1)
            cur.execute("SELECT id FROM devices WHERE employee_id = %s AND status = 'approved' ORDER BY COALESCE(last_seen_at, decided_at)",
                        (d["employee_id"],))
            approved = [r["id"] for r in cur.fetchall()]
            extra = len(approved) + 1 - limit
            if extra > 0:
                if not body.replace_oldest:
                    raise HTTPException(409, f"وصل {d['employee_code']} للحد المسموح ({limit} جهاز). "
                                             "ألغِ جهازاً قديماً أو وافق مع «استبدال الأقدم»")
                replaced = approved[:extra]
                cur.execute("UPDATE devices SET status = 'revoked', decided_by = %s, decided_at = NOW(), "
                            "decision_note = 'استُبدل بجهاز جديد' WHERE id = ANY(%s)", (user["id"], replaced))
                _end_sessions(cur, "device_row_id = ANY(%s)", (replaced,), user, "استُبدل الجهاز")
            new = "approved"
        elif body.action == "reject":
            if d["status"] != "pending":
                raise HTTPException(409, "يمكن رفض الطلبات المعلقة فقط، استخدم «إلغاء الاعتماد»")
            new = "rejected"
        else:
            new = "revoked"
            _end_sessions(cur, "device_row_id = %s", (d["id"],), user, body.note or "أُلغي اعتماد الجهاز")
        cur.execute("UPDATE devices SET status = %s, decided_by = %s, decided_at = NOW(), decision_note = %s WHERE id = %s",
                    (new, user["id"], body.note, d["id"]))
        audit.log(cur, user["id"], f"device_{body.action}", "device", d["id"],
                  {"employee": d["employee_code"], "note": body.note, "replaced": replaced})
    return {"id": d["id"], "status": new, "replaced": replaced}


@router.get("/sessions")
def sessions(user: dict = Depends(tech_only)):
    with get_conn() as conn, dict_cursor(conn) as cur:
        cur.execute(
            """SELECT s.id, s.ip, s.created_at, s.expires_at, s.last_seen_at, e.employee_code, e.full_name, e.role,
                      d.label AS device_label, d.platform
               FROM sessions s JOIN employees e ON e.id = s.employee_id LEFT JOIN devices d ON d.id = s.device_row_id
               WHERE s.revoked_at IS NULL AND s.expires_at > NOW() ORDER BY s.last_seen_at DESC"""
        )
        rows = cur.fetchall()
    return [{**r, "role_label": ROLE_LABELS.get(r["role"], r["role"]), "created_at": _iso(r["created_at"]),
             "expires_at": _iso(r["expires_at"]), "last_seen_at": _iso(r["last_seen_at"])} for r in rows]


class ReasonIn(BaseModel):
    reason: str | None = Field(None, max_length=300)


@router.post("/sessions/{session_id}/end")
def end_session(session_id: int, body: ReasonIn, user: dict = Depends(tech_only)):
    with get_conn() as conn, dict_cursor(conn) as cur:
        n = _end_sessions(cur, "id = %s", (session_id,), user, body.reason or "أنهتها الإدارة التقنية")
        if not n:
            raise HTTPException(404, "الجلسة غير موجودة أو منتهية")
        audit.log(cur, user["id"], "session_ended", "session", session_id, {"reason": body.reason})
    return {"ended": n}


@router.post("/employees/{code}/logout")
def logout_everywhere(code: str, body: ReasonIn, user: dict = Depends(tech_only)):
    with get_conn() as conn, dict_cursor(conn) as cur:
        e = _emp(cur, code)
        n = _end_sessions(cur, "employee_id = %s", (e["id"],), user, body.reason or "أنهتها الإدارة التقنية")
        audit.log(cur, user["id"], "sessions_ended_all", "employee", e["employee_code"], {"count": n, "reason": body.reason})
    return {"ended": n}


# ================================================================ accounts

@router.get("/employees")
def employees(user: dict = Depends(tech_only)):
    with get_conn() as conn, dict_cursor(conn) as cur:
        cur.execute(
            """SELECT e.id, e.employee_code, e.full_name, e.role, e.phone, e.active, e.suspended_reason, e.permissions,
                      s.code AS sector_code, s.name AS sector_name, sup.employee_code AS supervisor_code,
                      (SELECT COUNT(*) FROM devices d WHERE d.employee_id = e.id AND d.status = 'approved') AS devices,
                      (SELECT COUNT(*) FROM sessions x WHERE x.employee_id = e.id AND x.revoked_at IS NULL AND x.expires_at > NOW()) AS sessions,
                      (SELECT MAX(created_at) FROM sessions x WHERE x.employee_id = e.id) AS last_login
               FROM employees e LEFT JOIN sectors s ON s.id = e.sector_id LEFT JOIN employees sup ON sup.id = e.supervisor_id
               ORDER BY e.role, e.employee_code"""
        )
        rows = cur.fetchall()
    return [{**r, "role_label": ROLE_LABELS.get(r["role"], r["role"]), "last_login": _iso(r["last_login"])} for r in rows]


class NewEmployeeIn(BaseModel):
    employee_code: str = Field(..., min_length=3, max_length=30)
    full_name: str = Field(..., min_length=3, max_length=120)
    role: Literal["collector", "supervisor", "finance", "command", "hr", "owner", "tech", "admin"]
    password: str = Field(..., min_length=8)
    phone: str | None = None
    sector_code: str | None = None
    supervisor_code: str | None = None


def _sector_id(cur, code: str | None) -> int | None:
    if not code:
        return None
    cur.execute("SELECT id FROM sectors WHERE code = %s", (code,))
    s = cur.fetchone()
    if not s:
        raise HTTPException(404, "القاطع غير موجود")
    return s["id"]


def _supervisor_id(cur, code: str | None) -> int | None:
    if not code:
        return None
    cur.execute("SELECT id FROM employees WHERE UPPER(employee_code) = UPPER(%s) AND role = 'supervisor'", (code,))
    s = cur.fetchone()
    if not s:
        raise HTTPException(404, "المشرف غير موجود")
    return s["id"]


@router.post("/employees")
def create_employee(body: NewEmployeeIn, user: dict = Depends(tech_only)):
    phone = normalize_iraqi_phone(body.phone) if body.phone else None
    if body.phone and not phone:
        raise HTTPException(422, "رقم الهاتف غير صالح")
    with get_conn() as conn, dict_cursor(conn) as cur:
        cur.execute("SELECT 1 FROM employees WHERE UPPER(employee_code) = UPPER(%s)", (body.employee_code,))
        if cur.fetchone():
            raise HTTPException(409, "رقم الموظف مستخدم مسبقاً")
        cur.execute(
            """INSERT INTO employees (employee_code, full_name, role, password_hash, phone, sector_id, supervisor_id)
               VALUES (%s,%s,%s,%s,%s,%s,%s) RETURNING id""",
            (body.employee_code.upper(), body.full_name, body.role, hash_password(body.password), phone,
             _sector_id(cur, body.sector_code), _supervisor_id(cur, body.supervisor_code)),
        )
        new_id = cur.fetchone()["id"]
        audit.log(cur, user["id"], "employee_created", "employee", body.employee_code.upper(), {"role": body.role, "by": "tech"})
    return {"id": new_id}


class EmployeePatchIn(BaseModel):
    full_name: str | None = Field(None, min_length=3, max_length=120)
    role: Literal["collector", "supervisor", "finance", "command", "hr", "owner", "tech", "admin"] | None = None
    phone: str | None = None
    sector_code: str | None = None           # "" clears it
    supervisor_code: str | None = None       # "" clears it
    permissions: dict[str, bool | None] | None = None   # per-person switches: collection, registration, master_code, estimates


@router.patch("/employees/{code}")
def patch_employee(code: str, body: EmployeePatchIn, user: dict = Depends(tech_only)):
    with get_conn() as conn, dict_cursor(conn) as cur:
        e = _emp(cur, code)
        sets, args, changed = [], [], {}
        if body.full_name is not None:
            sets.append("full_name = %s"); args.append(body.full_name); changed["full_name"] = body.full_name
        if body.role is not None and body.role != e["role"]:
            if e["id"] == user["id"]:
                raise HTTPException(409, "لا يمكنك تغيير دورك بنفسك")
            cur.execute("SELECT COUNT(*) AS n FROM receipts WHERE collector_id = %s AND reconciliation_id IS NULL", (e["id"],))
            if cur.fetchone()["n"]:
                raise HTTPException(409, "لدى الموظف نقد لم يُسلَّم بعد. تتم مطابقته أولاً ثم يُغيَّر دوره")
            sets.append("role = %s"); args.append(body.role); changed["role"] = [e["role"], body.role]
        if body.phone is not None:
            phone = normalize_iraqi_phone(body.phone) if body.phone else None
            if body.phone and not phone:
                raise HTTPException(422, "رقم الهاتف غير صالح")
            sets.append("phone = %s"); args.append(phone); changed["phone"] = True
        if body.sector_code is not None:
            sets.append("sector_id = %s"); args.append(_sector_id(cur, body.sector_code or None)); changed["sector"] = body.sector_code
        if body.supervisor_code is not None:
            sup_id = _supervisor_id(cur, body.supervisor_code or None)
            if sup_id == e["id"]:
                raise HTTPException(422, "لا يمكن أن يكون الموظف مشرفاً على نفسه")
            sets.append("supervisor_id = %s"); args.append(sup_id)
            changed["supervisor"] = body.supervisor_code
        if body.permissions is not None:
            allowed = set(runtime.SWITCHES)
            bad = set(body.permissions) - allowed
            if bad:
                raise HTTPException(422, "صلاحية غير معروفة: " + "، ".join(bad))
            perms = dict(e["permissions"] or {})
            for k, v in body.permissions.items():
                if v is None:
                    perms.pop(k, None)
                else:
                    perms[k] = v
            sets.append("permissions = %s"); args.append(json.dumps(perms)); changed["permissions"] = perms
        if not sets:
            raise HTTPException(422, "لا توجد تعديلات")
        cur.execute(f"UPDATE employees SET {', '.join(sets)} WHERE id = %s", (*args, e["id"]))
        if "role" in changed:
            _end_sessions(cur, "employee_id = %s", (e["id"],), user, "تغيّر الدور")
        audit.log(cur, user["id"], "employee_updated", "employee", e["employee_code"], {"by": "tech", **changed})
    return {"employee_code": e["employee_code"], "changed": changed}


@router.post("/employees/{code}/suspend")
def suspend(code: str, body: ReasonIn, user: dict = Depends(tech_only)):
    with get_conn() as conn, dict_cursor(conn) as cur:
        e = _emp(cur, code)
        if e["id"] == user["id"]:
            raise HTTPException(409, "لا يمكنك إيقاف حسابك")
        cur.execute("UPDATE employees SET active = FALSE, suspended_reason = %s WHERE id = %s", (body.reason, e["id"]))
        n = _end_sessions(cur, "employee_id = %s", (e["id"],), user, body.reason or "أُوقف الحساب")
        audit.log(cur, user["id"], "employee_suspended", "employee", e["employee_code"], {"reason": body.reason, "sessions": n})
    return {"employee_code": e["employee_code"], "active": False}


@router.post("/employees/{code}/reactivate")
def reactivate(code: str, user: dict = Depends(tech_only)):
    with get_conn() as conn, dict_cursor(conn) as cur:
        e = _emp(cur, code)
        cur.execute("UPDATE employees SET active = TRUE, suspended_reason = NULL WHERE id = %s", (e["id"],))
        audit.log(cur, user["id"], "employee_reactivated", "employee", e["employee_code"], {})
    return {"employee_code": e["employee_code"], "active": True}


class PasswordIn(BaseModel):
    new_password: str = Field(..., min_length=8, max_length=100)


@router.post("/employees/{code}/password")
def reset_password(code: str, body: PasswordIn, user: dict = Depends(tech_only)):
    with get_conn() as conn, dict_cursor(conn) as cur:
        e = _emp(cur, code)
        cur.execute("UPDATE employees SET password_hash = %s WHERE id = %s", (hash_password(body.new_password), e["id"]))
        n = _end_sessions(cur, "employee_id = %s", (e["id"],), user, "تغيّرت كلمة المرور")
        audit.log(cur, user["id"], "password_reset", "employee", e["employee_code"], {"sessions_ended": n})
    return {"employee_code": e["employee_code"], "sessions_ended": n}


# ================================================================ settings, formulas, switches

@router.get("/settings")
def get_settings(user: dict = Depends(tech_only)):
    with get_conn() as conn, dict_cursor(conn) as cur:
        runtime.refresh(cur, force=True)
        items = runtime.describe(cur)
    groups: dict[str, dict] = {}
    for it in items:
        g = groups.setdefault(it["group"], {"group": it["group"], "label": it["group_label"], "items": []})
        g["items"].append(it)
    return list(groups.values())


class SettingIn(BaseModel):
    value: object
    note: str | None = Field(None, max_length=300)


@router.post("/settings/{key}")
def set_setting(key: str, body: SettingIn, user: dict = Depends(tech_only)):
    if key == "UI_PERMISSIONS":
        raise HTTPException(422, "استخدم مصفوفة الصلاحيات")
    if key == "WHATSAPP_MODE" and body.value == "live" and not (settings.WHATSAPP_APP_SECRET and settings.WHATSAPP_TOKEN
                                                                 and settings.WHATSAPP_PHONE_NUMBER_ID):
        raise HTTPException(422, "لا يمكن تفعيل الإرسال الفعلي قبل إدخال WHATSAPP_TOKEN و WHATSAPP_PHONE_NUMBER_ID "
                                 "و WHATSAPP_APP_SECRET في ملف .env على الخادم")
    with get_conn() as conn, dict_cursor(conn) as cur:
        return runtime.set_value(cur, key, body.value, user, body.note)


@router.delete("/settings/{key}")
def reset_setting(key: str, user: dict = Depends(tech_only)):
    with get_conn() as conn, dict_cursor(conn) as cur:
        return runtime.reset_value(cur, key, user)


@router.get("/settings-history")
def settings_history(key: str | None = None, user: dict = Depends(tech_only)):
    with get_conn() as conn, dict_cursor(conn) as cur:
        cur.execute(
            """SELECT c.*, e.employee_code FROM setting_changes c LEFT JOIN employees e ON e.id = c.changed_by
               WHERE %(k)s::text IS NULL OR c.key = %(k)s ORDER BY c.id DESC LIMIT 300""",
            {"k": key},
        )
        rows = cur.fetchall()
    return [{"id": r["id"], "key": r["key"], "label": runtime.REGISTRY.get(r["key"], (None, None, r["key"]))[2],
             "old": r["old_value"], "new": r["new_value"], "by": r["employee_code"], "note": r["note"],
             "at": _iso(r["changed_at"])} for r in rows]


class OwnerEditableIn(BaseModel):
    allowed: bool


@router.post("/settings/{key}/owner-editable")
def owner_editable(key: str, body: OwnerEditableIn, user: dict = Depends(tech_only)):
    if key not in runtime.REGISTRY:
        raise HTTPException(404, "إعداد غير معروف")
    with get_conn() as conn, dict_cursor(conn) as cur:
        cur.execute("SELECT COUNT(*) AS n FROM owner_editable_settings")
        if cur.fetchone()["n"] == 0:          # first change: start from the built-in defaults
            for k, spec in runtime.REGISTRY.items():
                if spec[4]:
                    cur.execute("INSERT INTO owner_editable_settings (key) VALUES (%s) ON CONFLICT DO NOTHING", (k,))
        if body.allowed:
            cur.execute("INSERT INTO owner_editable_settings (key) VALUES (%s) ON CONFLICT DO NOTHING", (key,))
        else:
            cur.execute("DELETE FROM owner_editable_settings WHERE key = %s", (key,))
            cur.execute("SELECT COUNT(*) AS n FROM owner_editable_settings")
            if cur.fetchone()["n"] == 0:      # keep a marker so "none" is not read as "use the defaults"
                cur.execute("INSERT INTO owner_editable_settings (key) VALUES ('__none__')")
        audit.log(cur, user["id"], "owner_editable_changed", "setting", key, {"allowed": body.allowed})
    return {"key": key, "owner_editable": body.allowed}


@router.get("/permissions")
def permissions(user: dict = Depends(tech_only)):
    with get_conn() as conn, dict_cursor(conn) as cur:
        runtime.refresh(cur, force=True)
    return [{"role": role, "role_label": ROLE_LABELS.get(role, role),
             "features": [{"key": f, "label": label, "allowed": runtime.permissions_for(role)[f]} for f, label in feats.items()]}
            for role, feats in runtime.FEATURES.items()]


class PermissionIn(BaseModel):
    role: str
    feature: str
    allowed: bool


@router.post("/permissions")
def set_permission(body: PermissionIn, user: dict = Depends(tech_only)):
    if body.feature not in runtime.FEATURES.get(body.role, {}):
        raise HTTPException(404, "صلاحية غير معروفة لهذا الدور")
    with get_conn() as conn, dict_cursor(conn) as cur:
        runtime.refresh(cur, force=True)
        matrix = json.loads(json.dumps(settings.UI_PERMISSIONS or {}))
        matrix.setdefault(body.role, {})[body.feature] = body.allowed
        runtime.set_value(cur, "UI_PERMISSIONS", matrix, user, f"{body.role}.{body.feature} = {body.allowed}")
    return {"role": body.role, "feature": body.feature, "allowed": body.allowed}


# ================================================================ tariffs and sectors

@router.get("/tariffs")
def tariffs(user: dict = Depends(tech_only)):
    with get_conn() as conn, dict_cursor(conn) as cur:
        cur.execute("SELECT property_class, unit_rate, monthly_estimate, updated_at FROM tariffs ORDER BY property_class")
        rows = cur.fetchall()
    labels = {"Household": "سكني", "Business": "تجاري", "Industrial": "صناعي", "Agricultural": "زراعي"}
    return [{"property_class": r["property_class"], "label": labels.get(r["property_class"], r["property_class"]),
             "unit_rate": float(r["unit_rate"]), "monthly_estimate": float(r["monthly_estimate"]),
             "updated_at": _iso(r["updated_at"])} for r in rows]


class TariffIn(BaseModel):
    unit_rate: float = Field(..., ge=0)
    monthly_estimate: float = Field(..., ge=0)


@router.post("/tariffs/{property_class}")
def set_tariff(property_class: Literal["Household", "Business", "Industrial", "Agricultural"], body: TariffIn,
               user: dict = Depends(tech_only)):
    with get_conn() as conn, dict_cursor(conn) as cur:
        cur.execute("SELECT unit_rate, monthly_estimate FROM tariffs WHERE property_class = %s FOR UPDATE", (property_class,))
        old = cur.fetchone()
        if not old:
            raise HTTPException(404, "الفئة غير موجودة")
        cur.execute("UPDATE tariffs SET unit_rate = %s, monthly_estimate = %s, updated_at = NOW() WHERE property_class = %s",
                    (body.unit_rate, body.monthly_estimate, property_class))
        audit.log(cur, user["id"], "tariff_updated", "tariff", property_class,
                  {"old": {k: float(v) for k, v in old.items()}, "new": body.model_dump()})
    return {"property_class": property_class, **body.model_dump()}


@router.get("/sectors")
def sectors(user: dict = Depends(tech_only)):
    with get_conn() as conn, dict_cursor(conn) as cur:
        cur.execute(
            """SELECT s.*, (SELECT COUNT(*) FROM properties p WHERE p.sector_id = s.id AND p.status = 'active') AS houses,
                      (SELECT COUNT(*) FROM employees e WHERE e.sector_id = s.id AND e.active) AS staff,
                      (SELECT string_agg(e.employee_code, '، ') FROM employees e WHERE e.sector_id = s.id AND e.active) AS staff_codes
               FROM sectors s ORDER BY s.code"""
        )
        rows = cur.fetchall()
    return [{**r, "created_at": _iso(r["created_at"])} for r in rows]


class SectorIn(BaseModel):
    code: str = Field(..., min_length=2, max_length=30)
    name: str = Field(..., min_length=2, max_length=120)
    mahalla: str | None = Field(None, max_length=20)
    polygon: list[list[float]] = Field(..., min_length=3)


@router.post("/sectors")
def create_sector(body: SectorIn, user: dict = Depends(tech_only)):
    if any(len(p) != 2 or not (-90 <= p[0] <= 90 and -180 <= p[1] <= 180) for p in body.polygon):
        raise HTTPException(422, "إحداثيات حدود القاطع غير صالحة")
    with get_conn() as conn, dict_cursor(conn) as cur:
        cur.execute("SELECT 1 FROM sectors WHERE code = %s", (body.code,))
        if cur.fetchone():
            raise HTTPException(409, "رمز القاطع مستخدم مسبقاً")
        cur.execute("INSERT INTO sectors (code, name, mahalla, polygon) VALUES (%s,%s,%s,%s) RETURNING id",
                    (body.code, body.name, body.mahalla, json.dumps(body.polygon)))
        sid = cur.fetchone()["id"]
        audit.log(cur, user["id"], "sector_created", "sector", body.code, {"points": len(body.polygon)})
    return {"id": sid}


class SectorPatchIn(BaseModel):
    name: str | None = Field(None, min_length=2, max_length=120)
    mahalla: str | None = None
    polygon: list[list[float]] | None = None
    active: bool | None = None
    switches: dict[str, bool | None] | None = None


@router.patch("/sectors/{sector_id}")
def patch_sector(sector_id: int, body: SectorPatchIn, user: dict = Depends(tech_only)):
    with get_conn() as conn, dict_cursor(conn) as cur:
        cur.execute("SELECT * FROM sectors WHERE id = %s FOR UPDATE", (sector_id,))
        s = cur.fetchone()
        if not s:
            raise HTTPException(404, "القاطع غير موجود")
        sets, args, changed = [], [], {}
        if body.name is not None:
            sets.append("name = %s"); args.append(body.name); changed["name"] = body.name
        if body.mahalla is not None:
            sets.append("mahalla = %s"); args.append(body.mahalla or None); changed["mahalla"] = body.mahalla
        if body.polygon is not None:
            if len(body.polygon) < 3:
                raise HTTPException(422, "الحدود تحتاج 3 نقاط على الأقل")
            sets.append("polygon = %s"); args.append(json.dumps(body.polygon)); changed["polygon"] = len(body.polygon)
        if body.active is not None:
            sets.append("active = %s"); args.append(body.active); changed["active"] = body.active
        if body.switches is not None:
            bad = set(body.switches) - set(runtime.SWITCHES)
            if bad:
                raise HTTPException(422, "مفتاح غير معروف: " + "، ".join(bad))
            sw = dict(s["switches"] or {})
            for k, v in body.switches.items():
                if v is None or v is True:
                    sw.pop(k, None)          # on = follow the global switch
                else:
                    sw[k] = False
            sets.append("switches = %s"); args.append(json.dumps(sw)); changed["switches"] = sw
        if not sets:
            raise HTTPException(422, "لا توجد تعديلات")
        cur.execute(f"UPDATE sectors SET {', '.join(sets)} WHERE id = %s", (*args, sector_id))
        audit.log(cur, user["id"], "sector_updated", "sector", s["code"], changed)
    return {"id": sector_id, "changed": changed}


# ================================================================ WhatsApp

@router.get("/whatsapp")
def whatsapp_panel(days: int = Query(30, ge=1, le=365), user: dict = Depends(tech_only)):
    with get_conn() as conn, dict_cursor(conn) as cur:
        cur.execute(
            """SELECT template, status, COUNT(*) AS n FROM whatsapp_messages
               WHERE created_at >= NOW() - (%s || ' days')::interval GROUP BY template, status ORDER BY template""",
            (days,),
        )
        stats = cur.fetchall()
        cur.execute("""SELECT date_trunc('month', created_at) AS m, COUNT(*) FILTER (WHERE status = 'sent') AS sent,
                              COUNT(*) FILTER (WHERE status = 'failed') AS failed, COUNT(*) FILTER (WHERE status = 'console') AS console,
                              COUNT(*) FILTER (WHERE status = 'free') AS free
                       FROM whatsapp_messages GROUP BY 1 ORDER BY 1 DESC LIMIT 12""")
        months = cur.fetchall()
        cur.execute("""SELECT id, phone, template, status, preview, error, created_at FROM whatsapp_messages
                       ORDER BY id DESC LIMIT 100""")
        log = cur.fetchall()
    names = {"otp": settings.WA_TEMPLATE_OTP, "bill_notice": settings.WA_TEMPLATE_BILL_NOTICE, "receipt": settings.WA_TEMPLATE_RECEIPT}
    cost = settings.WHATSAPP_COST_USD
    return {
        "mode": settings.WHATSAPP_MODE, "cost_per_message_usd": cost,
        "configured": bool(settings.WHATSAPP_TOKEN and settings.WHATSAPP_PHONE_NUMBER_ID),
        "templates": [{"key": k, "name": names[k], "category": whatsapp.TEMPLATE_KIND[k], "text": whatsapp.TEMPLATE_TEXT[k]}
                      for k in names],
        "stats": stats,
        "months": [{"month": r["m"].date().isoformat()[:7], "sent": r["sent"], "failed": r["failed"], "console": r["console"], "free": r["free"],
                    "cost_usd": round(r["sent"] * cost, 2)} for r in months],
        "log": [{**r, "phone": r["phone"][:5] + "****" + r["phone"][-3:], "created_at": _iso(r["created_at"])} for r in log],
    }


# ================================================================ fraud watch

@router.get("/fraud")
def fraud_watch(days: int = Query(30, ge=1, le=365), user: dict = Depends(tech_only)):
    """Citizen numbers and devices that look like a collector confirming payments himself."""
    with get_conn() as conn, dict_cursor(conn) as cur:
        cur.execute(
            """SELECT c.whatsapp_phone AS phone, COUNT(*) AS houses, COUNT(DISTINCT p.registered_by) AS collectors,
                      COUNT(DISTINCT p.sector_id) AS sectors, string_agg(DISTINCT e.employee_code, '، ') AS registered_by
               FROM properties p JOIN citizens c ON c.id = p.citizen_id JOIN employees e ON e.id = p.registered_by
               WHERE p.status = 'active'
               GROUP BY c.whatsapp_phone HAVING COUNT(*) >= %s OR COUNT(DISTINCT p.sector_id) > 1
               ORDER BY COUNT(*) DESC LIMIT 100""",
            (max(2, settings.MAX_PROPERTIES_PER_PHONE),),
        )
        numbers = cur.fetchall()
        cur.execute(
            """SELECT e.employee_code, e.full_name, COUNT(*) FILTER (WHERE l.action = 'fast_otp') AS fast_otp,
                      COUNT(*) FILTER (WHERE l.action = 'phone_flagged') AS phone_flags,
                      COUNT(*) FILTER (WHERE l.action = 'phone_limit_blocked') AS phone_blocked,
                      COUNT(*) FILTER (WHERE l.action = 'employee_phone_blocked') AS employee_phone,
                      COUNT(*) FILTER (WHERE l.action = 'device_shared_attempt') AS device_sharing,
                      COUNT(*) FILTER (WHERE l.action = 'master_code_used') AS master_code
               FROM audit_log l JOIN employees e ON e.id = l.actor_id
               WHERE l.created_at >= NOW() - (%s || ' days')::interval
                 AND l.action IN ('fast_otp','phone_flagged','phone_limit_blocked','employee_phone_blocked',
                                  'device_shared_attempt','master_code_used')
               GROUP BY e.id ORDER BY COUNT(*) DESC""",
            (days,),
        )
        people = cur.fetchall()
        cur.execute(
            """SELECT a.status, e.employee_code, COUNT(*) AS n FROM callback_audits a JOIN receipts r ON r.id = a.receipt_id
               JOIN employees e ON e.id = r.collector_id
               WHERE a.assigned_date >= CURRENT_DATE - %s AND a.status IN ('denied','wrong_amount')
               GROUP BY a.status, e.employee_code ORDER BY n DESC""",
            (days,),
        )
        callbacks = cur.fetchall()
    for n in numbers:
        n["phone"] = n["phone"][:5] + "****" + n["phone"][-3:]
    return {"numbers": numbers, "people": people, "callbacks": callbacks}


# ================================================================ audit log

@router.get("/audit")
def audit_log(actor: str | None = None, action: str | None = None, limit: int = Query(200, ge=1, le=1000),
              user: dict = Depends(tech_only)):
    with get_conn() as conn, dict_cursor(conn) as cur:
        cur.execute(
            """SELECT l.id, l.action, l.entity, l.entity_id, l.details, l.created_at, e.employee_code, e.role
               FROM audit_log l LEFT JOIN employees e ON e.id = l.actor_id
               WHERE (%(a)s::text IS NULL OR UPPER(e.employee_code) = UPPER(%(a)s))
                 AND (%(x)s::text IS NULL OR l.action ILIKE '%%' || %(x)s || '%%')
               ORDER BY l.id DESC LIMIT %(n)s""",
            {"a": actor, "x": action, "n": limit},
        )
        rows = cur.fetchall()
    return [{**r, "created_at": _iso(r["created_at"])} for r in rows]


@router.get("/audit/verify")
def audit_verify(user: dict = Depends(tech_only)):
    with get_conn() as conn, dict_cursor(conn) as cur:
        return audit.verify_chain(cur)
