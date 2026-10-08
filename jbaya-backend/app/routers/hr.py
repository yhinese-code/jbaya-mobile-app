"""HR portal (role hr; admin too): employees & documents, attendance, leave approvals, payroll, expenses,
appraisals, custody, discipline, recruitment, training and the HR dashboard.
Supervisors approve their team's leave (first step) and rate their team's appraisals."""
import json
from datetime import date
from typing import Literal

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field

from .. import audit, files, hr_logic
from ..config import settings
from ..db import dict_cursor, get_conn
from ..security import hash_password, require_roles
from ..utils import normalize_iraqi_phone
from .me import expense_out, leave_out

router = APIRouter(tags=["hr"])
hr_only = require_roles("hr")
hr_or_finance = require_roles("hr", "finance")
supervisor_or_hr = require_roles("supervisor", "hr")

MONEY_FIELDS = ("base_salary", "allowance_transport", "allowance_phone", "allowance_risk", "daily_target_iqd")
DATE_FIELDS = ("hire_date", "contract_end", "birth_date")


def _iso(v):
    return v.isoformat() if v else None


def _emp_out(e: dict) -> dict:
    out = dict(e)
    out.pop("password_hash", None)
    for k in MONEY_FIELDS:
        if k in out and out[k] is not None:
            out[k] = float(out[k])
    for k in DATE_FIELDS + ("created_at",):
        if k in out:
            out[k] = _iso(out[k])
    return out


def _get_emp(cur, code: str) -> dict:
    cur.execute(
        """SELECT e.*, s.code AS sector_code, s.name AS sector_name, sup.employee_code AS supervisor_code,
                  sup.full_name AS supervisor_name
           FROM employees e LEFT JOIN sectors s ON s.id = e.sector_id LEFT JOIN employees sup ON sup.id = e.supervisor_id
           WHERE UPPER(e.employee_code) = UPPER(%s)""",
        (code,),
    )
    e = cur.fetchone()
    if not e:
        raise HTTPException(404, "الموظف غير موجود")
    return e


# ================================================================ dashboard

@router.get("/hr/dashboard")
def dashboard(user: dict = Depends(hr_only)):
    with get_conn() as conn, dict_cursor(conn) as cur:
        today = hr_logic.local_today(cur)
        cur.execute("SELECT role, COUNT(*) FILTER (WHERE active) AS active, COUNT(*) FILTER (WHERE NOT active) AS inactive "
                    "FROM employees GROUP BY role ORDER BY role")
        by_role = cur.fetchall()
        cur.execute("SELECT COUNT(*) AS n FROM attendance WHERE work_date = %s", (today,))
        present = cur.fetchone()["n"]
        cur.execute("SELECT COUNT(*) AS n FROM attendance WHERE work_date = %s AND late_minutes > 0", (today,))
        late = cur.fetchone()["n"]
        cur.execute("SELECT COUNT(DISTINCT employee_id) AS n FROM leave_requests WHERE status = 'approved' AND %s BETWEEN start_date AND end_date",
                    (today,))
        on_leave = cur.fetchone()["n"]
        cur.execute("SELECT COUNT(*) AS n FROM employees WHERE active AND role IN ('collector','supervisor')")
        field = cur.fetchone()["n"]
        cur.execute("SELECT COUNT(*) FILTER (WHERE status = 'pending_hr') AS hr, COUNT(*) FILTER (WHERE status = 'pending_supervisor') AS sup FROM leave_requests")
        leave_pending = cur.fetchone()
        cur.execute("SELECT COUNT(*) AS n, COALESCE(SUM(amount),0) AS s FROM expense_claims WHERE status = 'pending'")
        exp = cur.fetchone()
        cur.execute(
            """SELECT 'contract' AS kind, employee_code AS ref, full_name AS title, contract_end AS expires_on FROM employees
               WHERE active AND contract_end IS NOT NULL AND contract_end <= %s + 30
               UNION ALL
               SELECT 'document', e.employee_code, d.title, d.expires_on FROM employee_documents d JOIN employees e ON e.id = d.employee_id
               WHERE e.active AND d.expires_on IS NOT NULL AND d.expires_on <= %s + 30
               ORDER BY expires_on""",
            (today, today),
        )
        expiring = cur.fetchall()
        cur.execute("SELECT period, status, totals FROM payroll_runs ORDER BY period DESC LIMIT 1")
        last_run = cur.fetchone()
        cur.execute("SELECT COALESCE(SUM(total_amount),0) AS s FROM receipts WHERE issued_at >= date_trunc('month', NOW())")
        collected_month = float(cur.fetchone()["s"])
        cur.execute("SELECT COUNT(*) AS n, COALESCE(SUM(value_iqd),0) AS s FROM custody_items WHERE status = 'assigned'")
        custody = cur.fetchone()
    for x in expiring:
        x["expires_on"] = _iso(x["expires_on"])
    return {
        "today": today.isoformat(), "working_day": hr_logic.is_working_day(today),
        "headcount": by_role, "present_today": present, "late_today": late, "on_leave_today": on_leave,
        "field_staff": field, "absent_field_today": max(0, field - present - on_leave) if hr_logic.is_working_day(today) else 0,
        "leave_pending_hr": leave_pending["hr"], "leave_pending_supervisor": leave_pending["sup"],
        "expenses_pending": exp["n"], "expenses_pending_amount": float(exp["s"]),
        "expiring": expiring, "last_payroll": last_run, "collected_this_month": collected_month,
        "custody_items_out": custody["n"], "custody_value_out": float(custody["s"]),
    }


# ================================================================ employees

@router.get("/hr/employees")
def employees(q: str | None = None, role: str | None = None, active: bool | None = None, user: dict = Depends(hr_only)):
    with get_conn() as conn, dict_cursor(conn) as cur:
        today = hr_logic.local_today(cur)
        cur.execute(
            """SELECT e.id, e.employee_code, e.full_name, e.role, e.job_title, e.phone, e.active, e.hire_date, e.contract_end,
                      e.base_salary, s.name AS sector_name, sup.employee_code AS supervisor_code,
                      (SELECT check_in_at FROM attendance a WHERE a.employee_id = e.id AND a.work_date = %(today)s) AS checked_in_at,
                      EXISTS (SELECT 1 FROM leave_requests l WHERE l.employee_id = e.id AND l.status = 'approved'
                              AND %(today)s BETWEEN l.start_date AND l.end_date) AS on_leave
               FROM employees e LEFT JOIN sectors s ON s.id = e.sector_id LEFT JOIN employees sup ON sup.id = e.supervisor_id
               WHERE (%(q)s::text IS NULL OR e.employee_code ILIKE '%%' || %(q)s || '%%' OR e.full_name ILIKE '%%' || %(q)s || '%%')
                 AND (%(role)s::text IS NULL OR e.role = %(role)s)
                 AND (%(active)s::boolean IS NULL OR e.active = %(active)s)
               ORDER BY e.active DESC, e.role, e.employee_code""",
            {"today": today, "q": q, "role": role, "active": active},
        )
        rows = cur.fetchall()
    out = []
    for r in rows:
        r = _emp_out(r)
        r["checked_in_at"] = _iso(r["checked_in_at"])
        out.append(r)
    return out


class HrEmployeeIn(BaseModel):
    employee_code: str = Field(..., min_length=3, max_length=30)
    full_name: str = Field(..., min_length=3, max_length=120)
    role: Literal["collector", "supervisor", "finance", "command", "hr"]
    password: str = Field(..., min_length=8)
    phone: str | None = None
    sector_code: str | None = None
    supervisor_code: str | None = None
    job_title: str | None = None
    department: str | None = None
    hire_date: date | None = None
    contract_end: date | None = None
    national_id_no: str | None = Field(None, max_length=40)
    birth_date: date | None = None
    home_address: str | None = None
    emergency_contact: str | None = None
    base_salary: float = Field(0, ge=0)
    allowance_transport: float = Field(0, ge=0)
    allowance_phone: float = Field(0, ge=0)
    allowance_risk: float = Field(0, ge=0)
    daily_target_iqd: float | None = Field(None, ge=0)
    payment_method: str | None = None


def _resolve_refs(cur, sector_code, supervisor_code) -> tuple:
    sector_id = supervisor_id = None
    if sector_code:
        cur.execute("SELECT id FROM sectors WHERE code = %s", (sector_code,))
        s = cur.fetchone()
        if not s:
            raise HTTPException(404, "القاطع غير موجود")
        sector_id = s["id"]
    if supervisor_code:
        cur.execute("SELECT id FROM employees WHERE UPPER(employee_code) = UPPER(%s) AND role = 'supervisor'", (supervisor_code,))
        s = cur.fetchone()
        if not s:
            raise HTTPException(404, "المشرف غير موجود")
        supervisor_id = s["id"]
    return sector_id, supervisor_id


def create_employee_row(cur, body: HrEmployeeIn, actor_id: int) -> int:
    phone = None
    if body.phone:
        phone = normalize_iraqi_phone(body.phone)
        if not phone:
            raise HTTPException(422, "رقم الهاتف غير صالح")
    cur.execute("SELECT 1 FROM employees WHERE UPPER(employee_code) = UPPER(%s)", (body.employee_code,))
    if cur.fetchone():
        raise HTTPException(409, "رقم الموظف مستخدم مسبقاً")
    sector_id, supervisor_id = _resolve_refs(cur, body.sector_code, body.supervisor_code)
    cur.execute(
        """INSERT INTO employees (employee_code, full_name, role, password_hash, phone, sector_id, supervisor_id, job_title,
                                  department, hire_date, contract_end, national_id_no, birth_date, home_address,
                                  emergency_contact, base_salary, allowance_transport, allowance_phone, allowance_risk,
                                  daily_target_iqd, payment_method)
           VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s) RETURNING id""",
        (body.employee_code.upper(), body.full_name, body.role, hash_password(body.password), phone, sector_id, supervisor_id,
         body.job_title, body.department, body.hire_date, body.contract_end, body.national_id_no, body.birth_date,
         body.home_address, body.emergency_contact, body.base_salary, body.allowance_transport, body.allowance_phone,
         body.allowance_risk, body.daily_target_iqd, body.payment_method),
    )
    new_id = cur.fetchone()["id"]
    # assign the mandatory courses for this role
    cur.execute(
        """INSERT INTO training_records (course_id, employee_id) SELECT id, %s FROM training_courses WHERE mandatory_for = %s
           ON CONFLICT DO NOTHING""",
        (new_id, body.role),
    )
    audit.log(cur, actor_id, "employee_created", "employee", body.employee_code.upper(), {"role": body.role})
    return new_id


@router.post("/hr/employees")
def create_employee(body: HrEmployeeIn, user: dict = Depends(hr_only)):
    if body.role in ("command",) and user["role"] != "admin":
        raise HTTPException(403, "إنشاء حسابات القيادة متاح لمدير النظام فقط")
    with get_conn() as conn, dict_cursor(conn) as cur:
        new_id = create_employee_row(cur, body, user["id"])
    return {"id": new_id, "employee_code": body.employee_code.upper()}


@router.get("/hr/employees/{code}")
def employee_profile(code: str, user: dict = Depends(hr_only)):
    with get_conn() as conn, dict_cursor(conn) as cur:
        e = _get_emp(cur, code)
        today = hr_logic.local_today(cur)
        balances = hr_logic.leave_balances(cur, e["id"], today.year)
        month_start, _ = hr_logic.parse_period(today.strftime("%Y-%m"))
        cur.execute(
            """SELECT COUNT(*) AS present, COUNT(*) FILTER (WHERE late_minutes > 0) AS late,
                      COALESCE(SUM(worked_minutes),0) AS minutes
               FROM attendance WHERE employee_id = %s AND work_date BETWEEN %s AND %s""",
            (e["id"], month_start, today),
        )
        att = cur.fetchone()
        cur.execute("SELECT id, doc_type, title, expires_on, file_path IS NOT NULL AS has_file, created_at FROM employee_documents "
                    "WHERE employee_id = %s ORDER BY created_at DESC", (e["id"],))
        docs = cur.fetchall()
        cur.execute("SELECT * FROM custody_items WHERE employee_id = %s ORDER BY status, assigned_at DESC", (e["id"],))
        custody = cur.fetchall()
        cur.execute("SELECT d.*, i.employee_code AS issued_by_code FROM disciplinary_actions d LEFT JOIN employees i ON i.id = d.issued_by "
                    "WHERE d.employee_id = %s ORDER BY d.effective_date DESC", (e["id"],))
        discipline = cur.fetchall()
        cur.execute("SELECT * FROM leave_requests WHERE employee_id = %s ORDER BY created_at DESC LIMIT 20", (e["id"],))
        leaves = cur.fetchall()
        cur.execute("SELECT period, auto_score, final_score, supervisor_rating, recommendation FROM appraisals "
                    "WHERE employee_id = %s ORDER BY period DESC LIMIT 6", (e["id"],))
        appraisals = cur.fetchall()
        cur.execute("""SELECT c.title, t.status, t.score, t.completed_at, c.mandatory_for FROM training_records t
                       JOIN training_courses c ON c.id = t.course_id WHERE t.employee_id = %s ORDER BY t.status, c.title""", (e["id"],))
        training = cur.fetchall()
        cur.execute("""SELECT p.id, r.period, r.status, p.net FROM payslips p JOIN payroll_runs r ON r.id = p.run_id
                       WHERE p.employee_id = %s ORDER BY r.period DESC LIMIT 6""", (e["id"],))
        payslips = cur.fetchall()
        cur.execute("SELECT COALESCE(SUM(total_amount),0) AS s FROM receipts WHERE collector_id = %s AND reconciliation_id IS NULL",
                    (e["id"],))
        cash_in_hand = float(cur.fetchone()["s"])
    profile = _emp_out(e)
    return {
        "profile": profile,
        "leave_balances": balances,
        "attendance_month": {"present": att["present"], "late": att["late"], "hours": round(att["minutes"] / 60, 1)},
        "documents": [{**d, "expires_on": _iso(d["expires_on"]), "created_at": _iso(d["created_at"])} for d in docs],
        "custody": [{"id": c["id"], "item_type": c["item_type"], "description": c["description"], "serial_no": c["serial_no"],
                     "value_iqd": float(c["value_iqd"]), "status": c["status"], "assigned_at": _iso(c["assigned_at"]),
                     "returned_at": _iso(c["returned_at"]), "return_note": c["return_note"]} for c in custody],
        "discipline": [{"id": d["id"], "action_type": d["action_type"], "reason": d["reason"], "penalty_iqd": float(d["penalty_iqd"]),
                        "effective_date": _iso(d["effective_date"]), "issued_by": d["issued_by_code"]} for d in discipline],
        "leave_requests": [leave_out(r) for r in leaves],
        "appraisals": [{**a, "auto_score": float(a["auto_score"]), "final_score": float(a["final_score"])} for a in appraisals],
        "training": [{**t, "completed_at": _iso(t["completed_at"])} for t in training],
        "payslips": [{"id": p["id"], "period": p["period"], "status": p["status"], "net": float(p["net"])} for p in payslips],
        "cash_in_hand": cash_in_hand,
    }


class HrEmployeeUpdate(BaseModel):
    full_name: str | None = Field(None, min_length=3, max_length=120)
    phone: str | None = None
    sector_code: str | None = None
    supervisor_code: str | None = None
    job_title: str | None = None
    department: str | None = None
    hire_date: date | None = None
    contract_end: date | None = None
    national_id_no: str | None = None
    birth_date: date | None = None
    home_address: str | None = None
    emergency_contact: str | None = None
    base_salary: float | None = Field(None, ge=0)
    allowance_transport: float | None = Field(None, ge=0)
    allowance_phone: float | None = Field(None, ge=0)
    allowance_risk: float | None = Field(None, ge=0)
    daily_target_iqd: float | None = Field(None, ge=0)
    payment_method: str | None = None
    hr_notes: str | None = None
    password: str | None = Field(None, min_length=8)


@router.patch("/hr/employees/{code}")
def update_employee(code: str, body: HrEmployeeUpdate, user: dict = Depends(hr_only)):
    data = body.model_dump(exclude_unset=True)
    if not data:
        raise HTTPException(422, "لا توجد تعديلات")
    with get_conn() as conn, dict_cursor(conn) as cur:
        e = _get_emp(cur, code)
        if e["role"] in ("admin", "command") and user["role"] != "admin":
            raise HTTPException(403, "تعديل حسابات القيادة والإدارة متاح لمدير النظام فقط")
        sets, args = [], []
        if "phone" in data and data["phone"]:
            phone = normalize_iraqi_phone(data["phone"])
            if not phone:
                raise HTTPException(422, "رقم الهاتف غير صالح")
            data["phone"] = phone
        if "sector_code" in data or "supervisor_code" in data:
            sector_id, supervisor_id = _resolve_refs(cur, data.pop("sector_code", None), data.pop("supervisor_code", None))
            if sector_id is not None:
                sets.append("sector_id = %s"); args.append(sector_id)
            if supervisor_id is not None:
                sets.append("supervisor_id = %s"); args.append(supervisor_id)
        if "password" in data:
            sets.append("password_hash = %s"); args.append(hash_password(data.pop("password")))
        for k, v in data.items():
            sets.append(f"{k} = %s"); args.append(v)
        cur.execute(f"UPDATE employees SET {', '.join(sets)} WHERE id = %s", (*args, e["id"]))
        audit.log(cur, user["id"], "employee_updated", "employee", e["employee_code"],
                  {"fields": [k for k in body.model_dump(exclude_unset=True)]})
    return {"employee_code": e["employee_code"], "updated": True}


class TerminateIn(BaseModel):
    reason: str = Field(..., min_length=3, max_length=500)


@router.post("/hr/employees/{code}/terminate")
def terminate(code: str, body: TerminateIn, user: dict = Depends(hr_only)):
    """End of service: blocked while the employee still holds company items or unreconciled cash."""
    with get_conn() as conn, dict_cursor(conn) as cur:
        e = _get_emp(cur, code)
        if not e["active"]:
            raise HTTPException(409, "الموظف غير فعال مسبقاً")
        cur.execute("SELECT COUNT(*) AS n, COALESCE(SUM(value_iqd),0) AS v FROM custody_items WHERE employee_id = %s AND status = 'assigned'",
                    (e["id"],))
        c = cur.fetchone()
        if c["n"]:
            raise HTTPException(409, f"لا يمكن إنهاء الخدمة: بحوزته {c['n']} عهدة بقيمة {float(c['v']):,.0f} د.ع")
        cur.execute("SELECT COUNT(*) AS n FROM receipts WHERE collector_id = %s AND reconciliation_id IS NULL", (e["id"],))
        if cur.fetchone()["n"]:
            raise HTTPException(409, "لا يمكن إنهاء الخدمة: لديه وصولات لم تُسلَّم نقودها للمشرف")
        cur.execute("UPDATE employees SET active = FALSE WHERE id = %s", (e["id"],))
        audit.log(cur, user["id"], "employee_terminated", "employee", e["employee_code"], {"reason": body.reason})
    return {"employee_code": e["employee_code"], "active": False}


@router.post("/hr/employees/{code}/reactivate")
def reactivate(code: str, user: dict = Depends(hr_only)):
    with get_conn() as conn, dict_cursor(conn) as cur:
        e = _get_emp(cur, code)
        cur.execute("UPDATE employees SET active = TRUE WHERE id = %s", (e["id"],))
        audit.log(cur, user["id"], "employee_reactivated", "employee", e["employee_code"], {})
    return {"employee_code": e["employee_code"], "active": True}


# ---------------------------------------------------------------- documents

class DocumentIn(BaseModel):
    doc_type: Literal["national_id", "contract", "guarantee", "certificate", "medical", "other"]
    title: str = Field(..., min_length=2, max_length=200)
    file_base64: str | None = Field(None, max_length=6_000_000)
    expires_on: date | None = None


@router.post("/hr/employees/{code}/documents")
def add_document(code: str, body: DocumentIn, user: dict = Depends(hr_only)):
    with get_conn() as conn, dict_cursor(conn) as cur:
        e = _get_emp(cur, code)
        path = files.save_photo(body.file_base64, "hr_documents") if body.file_base64 else None
        cur.execute(
            "INSERT INTO employee_documents (employee_id, doc_type, title, file_path, expires_on, uploaded_by) "
            "VALUES (%s,%s,%s,%s,%s,%s) RETURNING id",
            (e["id"], body.doc_type, body.title, path, body.expires_on, user["id"]),
        )
        did = cur.fetchone()["id"]
        audit.log(cur, user["id"], "document_added", "employee", e["employee_code"], {"doc_type": body.doc_type})
    return {"id": did}


@router.get("/hr/documents/{doc_id}/file")
def document_file(doc_id: int, user: dict = Depends(hr_only)):
    with get_conn() as conn, dict_cursor(conn) as cur:
        cur.execute("SELECT file_path FROM employee_documents WHERE id = %s", (doc_id,))
        d = cur.fetchone()
    photo = files.load_photo(d["file_path"]) if d else None
    if not photo:
        raise HTTPException(404, "الملف غير موجود")
    return photo


# ================================================================ attendance

@router.get("/hr/attendance")
def attendance_day(day: date | None = None, user: dict = Depends(require_roles("hr", "supervisor"))):
    with get_conn() as conn, dict_cursor(conn) as cur:
        day = day or hr_logic.local_today(cur)
        team = "AND e.supervisor_id = %(me)s" if user["role"] == "supervisor" else ""
        cur.execute(
            f"""SELECT e.employee_code, e.full_name, e.role, s.name AS sector_name, a.id AS attendance_id,
                       a.check_in_at, a.check_out_at, a.late_minutes, a.worked_minutes, a.flags,
                       a.check_in_photo IS NOT NULL AS has_selfie,
                       EXISTS (SELECT 1 FROM leave_requests l WHERE l.employee_id = e.id AND l.status = 'approved'
                               AND %(day)s BETWEEN l.start_date AND l.end_date) AS on_leave
                FROM employees e LEFT JOIN sectors s ON s.id = e.sector_id
                LEFT JOIN attendance a ON a.employee_id = e.id AND a.work_date = %(day)s
                WHERE e.active AND e.role NOT IN ('admin') {team}
                ORDER BY (a.id IS NULL) DESC, e.role, e.employee_code""",
            {"day": day, "me": user["id"]},
        )
        rows = cur.fetchall()
    working = hr_logic.is_working_day(day)
    out = []
    for r in rows:
        status = "present" if r["attendance_id"] else ("leave" if r["on_leave"] else ("absent" if working else "weekend"))
        if status == "present" and r["late_minutes"]:
            status = "late"
        out.append({**r, "check_in_at": _iso(r["check_in_at"]), "check_out_at": _iso(r["check_out_at"]), "status": status})
    return {"day": day.isoformat(), "working_day": working, "rows": out}


@router.get("/hr/attendance/{attendance_id}/selfie")
def attendance_selfie(attendance_id: int, which: Literal["in", "out"] = "in", user: dict = Depends(require_roles("hr", "supervisor"))):
    with get_conn() as conn, dict_cursor(conn) as cur:
        cur.execute("SELECT a.check_in_photo, a.check_out_photo, e.supervisor_id FROM attendance a JOIN employees e ON e.id = a.employee_id "
                    "WHERE a.id = %s", (attendance_id,))
        a = cur.fetchone()
    if not a or (user["role"] == "supervisor" and a["supervisor_id"] != user["id"]):
        raise HTTPException(404, "السجل غير موجود")
    photo = files.load_photo(a["check_in_photo"] if which == "in" else a["check_out_photo"])
    if not photo:
        raise HTTPException(404, "لا توجد صورة")
    return photo


# ================================================================ leave approvals

@router.get("/hr/leave")
def leave_queue(status: str = "pending", user: dict = Depends(supervisor_or_hr)):
    """Supervisors see their team's requests waiting for them; HR sees everything."""
    with get_conn() as conn, dict_cursor(conn) as cur:
        if user["role"] == "supervisor":
            # Phase 5: the supervisor only SEES his team's requests (to plan the field work); HR decides
            cond, args = "e.supervisor_id = %s AND l.status IN ('pending_hr','pending_supervisor')", [user["id"]]
            if status != "pending":
                cond, args = "e.supervisor_id = %s", [user["id"]]
        else:
            cond, args = ("l.status IN ('pending_hr','pending_supervisor')", []) if status == "pending" else ("TRUE", [])
        cur.execute(
            f"""SELECT l.*, e.employee_code, e.full_name FROM leave_requests l JOIN employees e ON e.id = l.employee_id
                WHERE {cond} ORDER BY l.created_at DESC LIMIT 200""",
            args,
        )
        return [leave_out(r) for r in cur.fetchall()]


class DecisionIn(BaseModel):
    action: Literal["approve", "reject"]
    note: str | None = Field(None, max_length=500)


@router.post("/hr/leave/{leave_id}/decision")
def decide_leave(leave_id: int, body: DecisionIn, user: dict = Depends(supervisor_or_hr)):
    with get_conn() as conn, dict_cursor(conn) as cur:
        cur.execute("SELECT l.*, e.supervisor_id AS emp_supervisor FROM leave_requests l JOIN employees e ON e.id = l.employee_id "
                    "WHERE l.id = %s FOR UPDATE OF l", (leave_id,))
        r = cur.fetchone()
        if not r:
            raise HTTPException(404, "الطلب غير موجود")
        if user["role"] == "supervisor":
            raise HTTPException(403, "الموافقة على الإجازات من صلاحية الموارد البشرية فقط")
        if r["employee_id"] == user["id"]:
            raise HTTPException(403, "لا يمكنك البت في طلب إجازتك. يبت فيه موظف آخر في الموارد البشرية")
        else:
            if r["status"] not in ("pending_supervisor", "pending_hr"):
                raise HTTPException(409, "تمت معالجة الطلب مسبقاً")
            new = "approved" if body.action == "approve" else "rejected"
            cur.execute("UPDATE leave_requests SET status = %s, hr_id = %s, hr_at = NOW(), decision_note = %s WHERE id = %s",
                        (new, user["id"], body.note, leave_id))
        audit.log(cur, user["id"], f"leave_{new}", "leave", leave_id, {"note": body.note})
    return {"id": leave_id, "status": new}


@router.get("/hr/leave/{leave_id}/attachment")
def leave_attachment(leave_id: int, user: dict = Depends(supervisor_or_hr)):
    with get_conn() as conn, dict_cursor(conn) as cur:
        cur.execute("SELECT l.attachment_path, e.supervisor_id FROM leave_requests l JOIN employees e ON e.id = l.employee_id WHERE l.id = %s",
                    (leave_id,))
        r = cur.fetchone()
    if not r or (user["role"] == "supervisor" and r["supervisor_id"] != user["id"]):
        raise HTTPException(404, "الطلب غير موجود")
    photo = files.load_photo(r["attachment_path"])
    if not photo:
        raise HTTPException(404, "لا يوجد مرفق")
    return photo


# ================================================================ expenses

@router.get("/hr/expenses")
def expense_queue(status: Literal["pending", "approved", "rejected", "paid", "all"] = "pending", user: dict = Depends(hr_or_finance)):
    with get_conn() as conn, dict_cursor(conn) as cur:
        cur.execute(
            """SELECT x.*, e.employee_code, e.full_name FROM expense_claims x JOIN employees e ON e.id = x.employee_id
               WHERE (%s = 'all' OR x.status = %s) ORDER BY x.created_at DESC LIMIT 300""",
            (status, status),
        )
        return [expense_out(r) for r in cur.fetchall()]


@router.post("/hr/expenses/{expense_id}/decision")
def decide_expense(expense_id: int, body: DecisionIn, user: dict = Depends(hr_or_finance)):
    with get_conn() as conn, dict_cursor(conn) as cur:
        cur.execute("SELECT * FROM expense_claims WHERE id = %s FOR UPDATE", (expense_id,))
        x = cur.fetchone()
        if not x:
            raise HTTPException(404, "المطالبة غير موجودة")
        if x["status"] != "pending":
            raise HTTPException(409, "تمت معالجة المطالبة مسبقاً")
        new = "approved" if body.action == "approve" else "rejected"
        cur.execute("UPDATE expense_claims SET status = %s, decided_by = %s, decided_at = NOW(), decision_note = %s WHERE id = %s",
                    (new, user["id"], body.note, expense_id))
        audit.log(cur, user["id"], f"expense_{new}", "expense", expense_id, {"amount": str(x["amount"])})
    return {"id": expense_id, "status": new}


@router.get("/hr/expenses/{expense_id}/receipt")
def expense_receipt(expense_id: int, user: dict = Depends(hr_or_finance)):
    with get_conn() as conn, dict_cursor(conn) as cur:
        cur.execute("SELECT receipt_path FROM expense_claims WHERE id = %s", (expense_id,))
        r = cur.fetchone()
    photo = files.load_photo(r["receipt_path"]) if r else None
    if not photo:
        raise HTTPException(404, "لا يوجد وصل")
    return photo


# ================================================================ payroll

class RunIn(BaseModel):
    period: str = Field(..., pattern=r"^\d{4}-\d{2}$")


def _run_out(r: dict) -> dict:
    return {"id": r["id"], "period": r["period"], "status": r["status"], "totals": r["totals"], "paid_from": r.get("paid_from"),
            "created_at": _iso(r["created_at"]), "approved_at": _iso(r["approved_at"]), "paid_at": _iso(r["paid_at"])}


@router.post("/hr/payroll/runs")
def compute_run(body: RunIn, user: dict = Depends(hr_only)):
    """Creates (or recomputes, while still a draft) the payroll for a month."""
    hr_logic.parse_period(body.period)
    with get_conn() as conn, dict_cursor(conn) as cur:
        cur.execute("SELECT * FROM payroll_runs WHERE period = %s FOR UPDATE", (body.period,))
        run = cur.fetchone()
        if run and run["status"] != "draft":
            raise HTTPException(409, "تم اعتماد رواتب هذا الشهر، لا يمكن إعادة الاحتساب")
        if not run:
            cur.execute("INSERT INTO payroll_runs (period, created_by) VALUES (%s, %s) RETURNING *", (body.period, user["id"]))
            run = cur.fetchone()
        cur.execute("UPDATE expense_claims SET payslip_id = NULL WHERE payslip_id IN (SELECT id FROM payslips WHERE run_id = %s)", (run["id"],))
        cur.execute("DELETE FROM payslips WHERE run_id = %s", (run["id"],))
        cur.execute("SELECT * FROM employees WHERE active AND role <> 'admin' ORDER BY employee_code")
        totals = {"employees": 0, "gross": 0.0, "deductions": 0.0, "net": 0.0, "commission": 0.0, "negative_net": 0}
        for emp in cur.fetchall():
            slip = hr_logic.compute_payslip(cur, emp, body.period)
            cur.execute(
                "INSERT INTO payslips (run_id, employee_id, gross, deductions, net, lines, stats) VALUES (%s,%s,%s,%s,%s,%s,%s) RETURNING id",
                (run["id"], emp["id"], slip["gross"], slip["deductions"], slip["net"], json.dumps(slip["lines"], ensure_ascii=False),
                 json.dumps(slip["stats"])),
            )
            sid = cur.fetchone()["id"]
            if slip["stats"]["expense_ids"]:
                cur.execute("UPDATE expense_claims SET payslip_id = %s WHERE id = ANY(%s)", (sid, slip["stats"]["expense_ids"]))
            totals["employees"] += 1
            totals["gross"] += slip["gross"]
            totals["deductions"] += slip["deductions"]
            totals["net"] += slip["net"]
            totals["commission"] += sum(l["amount"] for l in slip["lines"] if l["code"] == "commission")
            totals["negative_net"] += 1 if slip["stats"]["negative_net"] else 0
        cur.execute("UPDATE payroll_runs SET totals = %s WHERE id = %s RETURNING *", (json.dumps(totals), run["id"]))
        run = cur.fetchone()
        audit.log(cur, user["id"], "payroll_computed", "payroll", body.period, totals)
    return _run_out(run)


@router.get("/hr/payroll/runs")
def list_runs(user: dict = Depends(hr_or_finance)):
    with get_conn() as conn, dict_cursor(conn) as cur:
        cur.execute("SELECT * FROM payroll_runs ORDER BY period DESC LIMIT 24")
        return [_run_out(r) for r in cur.fetchall()]


@router.get("/hr/payroll/runs/{period}")
def run_detail(period: str, user: dict = Depends(hr_or_finance)):
    with get_conn() as conn, dict_cursor(conn) as cur:
        cur.execute("SELECT * FROM payroll_runs WHERE period = %s", (period,))
        run = cur.fetchone()
        if not run:
            raise HTTPException(404, "لا توجد رواتب لهذا الشهر")
        cur.execute(
            """SELECT p.*, e.employee_code, e.full_name, e.role FROM payslips p JOIN employees e ON e.id = p.employee_id
               WHERE p.run_id = %s ORDER BY e.role, e.employee_code""",
            (run["id"],),
        )
        slips = cur.fetchall()
    return {**_run_out(run), "payslips": [{
        "id": p["id"], "employee_code": p["employee_code"], "full_name": p["full_name"], "role": p["role"],
        "gross": float(p["gross"]), "deductions": float(p["deductions"]), "net": float(p["net"]),
        "lines": p["lines"], "stats": p["stats"]} for p in slips]}


class RunActionIn(BaseModel):
    action: Literal["approve", "mark_paid"]
    paid_from: Literal["cash", "bank"] = "bank"        # salaries handed out from the HQ cash box, or transferred


@router.post("/hr/payroll/runs/{period}/action")
def run_action(period: str, body: RunActionIn, user: dict = Depends(hr_or_finance)):
    """Approve (finance) then mark as paid (finance). HR prepares, finance releases the money."""
    if user["role"] == "hr":
        raise HTTPException(403, "اعتماد وصرف الرواتب من صلاحية المالية")
    with get_conn() as conn, dict_cursor(conn) as cur:
        cur.execute("SELECT * FROM payroll_runs WHERE period = %s FOR UPDATE", (period,))
        run = cur.fetchone()
        if not run:
            raise HTTPException(404, "لا توجد رواتب لهذا الشهر")
        if body.action == "approve":
            if run["status"] != "draft":
                raise HTTPException(409, "الرواتب معتمدة مسبقاً")
            cur.execute("UPDATE payroll_runs SET status = 'approved', approved_by = %s, approved_at = NOW() WHERE id = %s RETURNING *",
                        (user["id"], run["id"]))
            run = cur.fetchone()
        else:
            if run["status"] != "approved":
                raise HTTPException(409, "يجب اعتماد الرواتب قبل الصرف")
            cur.execute("UPDATE payroll_runs SET status = 'paid', paid_by = %s, paid_at = NOW(), paid_from = %s WHERE id = %s RETURNING *",
                        (user["id"], body.paid_from, run["id"]))
            run = cur.fetchone()
            cur.execute("UPDATE expense_claims SET status = 'paid' WHERE payslip_id IN (SELECT id FROM payslips WHERE run_id = %s)",
                        (run["id"],))
        audit.log(cur, user["id"], f"payroll_{body.action}", "payroll", period, {})
    return _run_out(run)


# ================================================================ appraisals

@router.post("/hr/appraisals/run")
def run_appraisals(body: RunIn, user: dict = Depends(hr_only)):
    """Computes the automatic scorecard for every collector and supervisor (keeps existing supervisor ratings)."""
    with get_conn() as conn, dict_cursor(conn) as cur:
        cur.execute("SELECT * FROM employees WHERE active AND role IN ('collector','supervisor')")
        n = 0
        for emp in cur.fetchall():
            a = hr_logic.compute_appraisal(cur, emp, body.period)
            cur.execute("SELECT supervisor_rating FROM appraisals WHERE employee_id = %s AND period = %s", (emp["id"], body.period))
            prev = cur.fetchone()
            rating = prev["supervisor_rating"] if prev else None
            final = hr_logic.final_score(a["auto_score"], rating)
            cur.execute(
                """INSERT INTO appraisals (employee_id, period, metrics, auto_score, final_score, recommendation)
                   VALUES (%s,%s,%s,%s,%s,%s)
                   ON CONFLICT (employee_id, period) DO UPDATE SET metrics = EXCLUDED.metrics, auto_score = EXCLUDED.auto_score,
                       final_score = EXCLUDED.final_score, recommendation = EXCLUDED.recommendation""",
                (emp["id"], body.period, json.dumps(a["metrics"]), a["auto_score"], final, hr_logic.recommendation(final)),
            )
            n += 1
        audit.log(cur, user["id"], "appraisals_computed", "appraisal", body.period, {"employees": n})
    return {"period": body.period, "employees": n}


@router.get("/hr/appraisals")
def list_appraisals(period: str, user: dict = Depends(supervisor_or_hr)):
    team = "AND e.supervisor_id = %(me)s" if user["role"] == "supervisor" else ""
    with get_conn() as conn, dict_cursor(conn) as cur:
        cur.execute(
            f"""SELECT a.*, e.employee_code, e.full_name, e.role FROM appraisals a JOIN employees e ON e.id = a.employee_id
                WHERE a.period = %(p)s {team} ORDER BY a.final_score DESC""",
            {"p": period, "me": user["id"]},
        )
        rows = cur.fetchall()
    return [{"id": r["id"], "employee_code": r["employee_code"], "full_name": r["full_name"], "role": r["role"],
             "period": r["period"], "metrics": r["metrics"], "auto_score": float(r["auto_score"]),
             "supervisor_rating": r["supervisor_rating"], "supervisor_note": r["supervisor_note"],
             "final_score": float(r["final_score"]), "recommendation": r["recommendation"]} for r in rows]


class RateIn(BaseModel):
    rating: int = Field(..., ge=1, le=5)
    note: str | None = Field(None, max_length=500)


@router.post("/hr/appraisals/{appraisal_id}/rate")
def rate(appraisal_id: int, body: RateIn, user: dict = Depends(supervisor_or_hr)):
    with get_conn() as conn, dict_cursor(conn) as cur:
        cur.execute("SELECT a.*, e.supervisor_id FROM appraisals a JOIN employees e ON e.id = a.employee_id WHERE a.id = %s FOR UPDATE OF a",
                    (appraisal_id,))
        a = cur.fetchone()
        if not a or (user["role"] == "supervisor" and a["supervisor_id"] != user["id"]):
            raise HTTPException(404, "التقييم غير موجود")
        final = hr_logic.final_score(float(a["auto_score"]), body.rating)
        cur.execute(
            """UPDATE appraisals SET supervisor_rating = %s, supervisor_note = %s, final_score = %s, recommendation = %s, rated_by = %s
               WHERE id = %s""",
            (body.rating, body.note, final, hr_logic.recommendation(final), user["id"], appraisal_id),
        )
        audit.log(cur, user["id"], "appraisal_rated", "appraisal", appraisal_id, {"rating": body.rating})
    return {"id": appraisal_id, "final_score": final, "recommendation": hr_logic.recommendation(final)}


# ================================================================ custody

class CustodyIn(BaseModel):
    employee_code: str
    item_type: Literal["phone", "meter_reader", "printer", "vehicle", "uniform", "cash_bag", "other"]
    description: str = Field(..., min_length=2, max_length=200)
    serial_no: str | None = Field(None, max_length=80)
    value_iqd: float = Field(0, ge=0)


@router.post("/hr/custody")
def assign_custody(body: CustodyIn, user: dict = Depends(hr_only)):
    with get_conn() as conn, dict_cursor(conn) as cur:
        e = _get_emp(cur, body.employee_code)
        cur.execute(
            """INSERT INTO custody_items (employee_id, item_type, description, serial_no, value_iqd, assigned_by)
               VALUES (%s,%s,%s,%s,%s,%s) RETURNING id""",
            (e["id"], body.item_type, body.description, body.serial_no, body.value_iqd, user["id"]),
        )
        cid = cur.fetchone()["id"]
        audit.log(cur, user["id"], "custody_assigned", "employee", e["employee_code"], {"item": body.description, "serial": body.serial_no})
    return {"id": cid}


class CustodyReturnIn(BaseModel):
    outcome: Literal["returned", "lost"]
    note: str | None = Field(None, max_length=300)
    charge_employee: bool = False      # for 'lost': deduct the item's value from the next salary


@router.post("/hr/custody/{item_id}/return")
def return_custody(item_id: int, body: CustodyReturnIn, user: dict = Depends(hr_only)):
    with get_conn() as conn, dict_cursor(conn) as cur:
        cur.execute("SELECT c.*, e.employee_code FROM custody_items c JOIN employees e ON e.id = c.employee_id WHERE c.id = %s FOR UPDATE OF c",
                    (item_id,))
        c = cur.fetchone()
        if not c or c["status"] != "assigned":
            raise HTTPException(409, "العهدة غير موجودة أو تمت تسويتها")
        cur.execute("UPDATE custody_items SET status = %s, returned_at = NOW(), return_note = %s WHERE id = %s",
                    (body.outcome, body.note, item_id))
        if body.outcome == "lost" and body.charge_employee and float(c["value_iqd"]) > 0:
            today = hr_logic.local_today(cur)
            cur.execute(
                """INSERT INTO disciplinary_actions (employee_id, action_type, reason, penalty_iqd, effective_date, issued_by)
                   VALUES (%s,'penalty',%s,%s,%s,%s)""",
                (c["employee_id"], f"فقدان عهدة: {c['description']}", c["value_iqd"], today, user["id"]),
            )
        audit.log(cur, user["id"], f"custody_{body.outcome}", "employee", c["employee_code"], {"item": c["description"]})
    return {"id": item_id, "status": body.outcome}


@router.get("/hr/custody")
def custody_list(status: Literal["assigned", "returned", "lost", "all"] = "assigned", user: dict = Depends(hr_only)):
    with get_conn() as conn, dict_cursor(conn) as cur:
        cur.execute(
            """SELECT c.*, e.employee_code, e.full_name FROM custody_items c JOIN employees e ON e.id = c.employee_id
               WHERE (%s = 'all' OR c.status = %s) ORDER BY c.assigned_at DESC LIMIT 500""",
            (status, status),
        )
        rows = cur.fetchall()
    return [{"id": r["id"], "employee_code": r["employee_code"], "full_name": r["full_name"], "item_type": r["item_type"],
             "description": r["description"], "serial_no": r["serial_no"], "value_iqd": float(r["value_iqd"]),
             "status": r["status"], "assigned_at": _iso(r["assigned_at"]), "returned_at": _iso(r["returned_at"])} for r in rows]


# ================================================================ discipline

class DisciplineIn(BaseModel):
    employee_code: str
    action_type: Literal["verbal_warning", "written_warning", "final_warning", "penalty", "suspension"]
    reason: str = Field(..., min_length=3, max_length=500)
    penalty_iqd: float = Field(0, ge=0)
    effective_date: date | None = None


@router.post("/hr/discipline")
def add_discipline(body: DisciplineIn, user: dict = Depends(hr_only)):
    with get_conn() as conn, dict_cursor(conn) as cur:
        e = _get_emp(cur, body.employee_code)
        day = body.effective_date or hr_logic.local_today(cur)
        cur.execute(
            """INSERT INTO disciplinary_actions (employee_id, action_type, reason, penalty_iqd, effective_date, issued_by)
               VALUES (%s,%s,%s,%s,%s,%s) RETURNING id""",
            (e["id"], body.action_type, body.reason, body.penalty_iqd, day, user["id"]),
        )
        did = cur.fetchone()["id"]
        if body.action_type == "suspension":
            cur.execute("UPDATE employees SET active = FALSE WHERE id = %s", (e["id"],))
        cur.execute(
            """SELECT COUNT(*) AS n FROM disciplinary_actions WHERE employee_id = %s
               AND action_type IN ('written_warning','final_warning') AND effective_date >= %s - 365""",
            (e["id"], day),
        )
        warnings = cur.fetchone()["n"]
        audit.log(cur, user["id"], f"discipline_{body.action_type}", "employee", e["employee_code"],
                  {"reason": body.reason, "penalty": body.penalty_iqd})
    return {"id": did, "written_warnings_12m": warnings,
            "suspension_recommended": body.action_type != "suspension" and warnings >= settings.WARNINGS_BEFORE_SUSPENSION,
            "employee_active": body.action_type != "suspension" and e["active"]}


# ================================================================ recruitment

class OpeningIn(BaseModel):
    title: str = Field(..., min_length=3, max_length=200)
    role: Literal["collector", "supervisor", "finance", "hr"] = "collector"
    sector_code: str | None = None
    positions: int = Field(1, ge=1, le=500)
    description: str | None = None


@router.post("/hr/openings")
def create_opening(body: OpeningIn, user: dict = Depends(hr_only)):
    with get_conn() as conn, dict_cursor(conn) as cur:
        cur.execute("INSERT INTO job_openings (title, role, sector_code, positions, description) VALUES (%s,%s,%s,%s,%s) RETURNING id",
                    (body.title, body.role, body.sector_code, body.positions, body.description))
        oid = cur.fetchone()["id"]
        audit.log(cur, user["id"], "opening_created", "opening", oid, {"title": body.title})
    return {"id": oid}


@router.get("/hr/openings")
def list_openings(user: dict = Depends(hr_only)):
    with get_conn() as conn, dict_cursor(conn) as cur:
        cur.execute(
            """SELECT o.*, (SELECT COUNT(*) FROM applicants a WHERE a.opening_id = o.id) AS applicants,
                      (SELECT COUNT(*) FROM applicants a WHERE a.opening_id = o.id AND a.stage = 'hired') AS hired
               FROM job_openings o ORDER BY o.status, o.created_at DESC"""
        )
        rows = cur.fetchall()
        cur.execute("SELECT * FROM applicants ORDER BY created_at DESC")
        apps = cur.fetchall()
    for r in rows:
        r["created_at"] = _iso(r["created_at"])
        r["pipeline"] = [{**a, "created_at": _iso(a["created_at"])} for a in apps if a["opening_id"] == r["id"]]
    return rows


class OpeningStatusIn(BaseModel):
    status: Literal["open", "closed"]


@router.post("/hr/openings/{opening_id}/status")
def opening_status(opening_id: int, body: OpeningStatusIn, user: dict = Depends(hr_only)):
    with get_conn() as conn, dict_cursor(conn) as cur:
        cur.execute("UPDATE job_openings SET status = %s WHERE id = %s RETURNING id", (body.status, opening_id))
        if not cur.fetchone():
            raise HTTPException(404, "الوظيفة غير موجودة")
    return {"id": opening_id, "status": body.status}


class ApplicantIn(BaseModel):
    opening_id: int
    full_name: str = Field(..., min_length=3, max_length=120)
    phone: str | None = None
    notes: str | None = None


@router.post("/hr/applicants")
def add_applicant(body: ApplicantIn, user: dict = Depends(hr_only)):
    with get_conn() as conn, dict_cursor(conn) as cur:
        cur.execute("SELECT status FROM job_openings WHERE id = %s", (body.opening_id,))
        o = cur.fetchone()
        if not o or o["status"] != "open":
            raise HTTPException(409, "الوظيفة غير متاحة")
        phone = normalize_iraqi_phone(body.phone) if body.phone else None
        cur.execute("INSERT INTO applicants (opening_id, full_name, phone, notes) VALUES (%s,%s,%s,%s) RETURNING id",
                    (body.opening_id, body.full_name, phone or body.phone, body.notes))
        return {"id": cur.fetchone()["id"]}


class StageIn(BaseModel):
    stage: Literal["applied", "interview", "test", "offer", "rejected"]
    score: int | None = Field(None, ge=0, le=100)
    notes: str | None = None


@router.post("/hr/applicants/{applicant_id}/stage")
def move_applicant(applicant_id: int, body: StageIn, user: dict = Depends(hr_only)):
    with get_conn() as conn, dict_cursor(conn) as cur:
        cur.execute(
            "UPDATE applicants SET stage = %s, score = COALESCE(%s, score), notes = COALESCE(%s, notes) WHERE id = %s AND stage <> 'hired' RETURNING id",
            (body.stage, body.score, body.notes, applicant_id),
        )
        if not cur.fetchone():
            raise HTTPException(409, "المتقدم غير موجود أو تم تعيينه")
    return {"id": applicant_id, "stage": body.stage}


class HireIn(BaseModel):
    employee_code: str = Field(..., min_length=3, max_length=30)
    password: str = Field(..., min_length=8)
    sector_code: str | None = None
    supervisor_code: str | None = None
    base_salary: float = Field(0, ge=0)
    hire_date: date | None = None


@router.post("/hr/applicants/{applicant_id}/hire")
def hire(applicant_id: int, body: HireIn, user: dict = Depends(hr_only)):
    """One click: creates the employee account, assigns mandatory training, closes the applicant (and the opening when full)."""
    with get_conn() as conn, dict_cursor(conn) as cur:
        cur.execute("SELECT a.*, o.role, o.title, o.positions FROM applicants a JOIN job_openings o ON o.id = a.opening_id "
                    "WHERE a.id = %s FOR UPDATE OF a", (applicant_id,))
        a = cur.fetchone()
        if not a or a["stage"] == "hired":
            raise HTTPException(409, "المتقدم غير موجود أو تم تعيينه")
        emp_body = HrEmployeeIn(
            employee_code=body.employee_code, full_name=a["full_name"], role=a["role"], password=body.password,
            phone=a["phone"] if a["phone"] and normalize_iraqi_phone(a["phone"]) else None,
            sector_code=body.sector_code, supervisor_code=body.supervisor_code, job_title=a["title"],
            hire_date=body.hire_date or hr_logic.local_today(cur), base_salary=body.base_salary,
        )
        new_id = create_employee_row(cur, emp_body, user["id"])
        cur.execute("UPDATE applicants SET stage = 'hired', hired_employee_id = %s WHERE id = %s", (new_id, applicant_id))
        cur.execute("SELECT COUNT(*) AS n FROM applicants WHERE opening_id = %s AND stage = 'hired'", (a["opening_id"],))
        if cur.fetchone()["n"] >= a["positions"]:
            cur.execute("UPDATE job_openings SET status = 'closed' WHERE id = %s", (a["opening_id"],))
    return {"employee_id": new_id, "employee_code": body.employee_code.upper()}


# ================================================================ training

class CourseIn(BaseModel):
    title: str = Field(..., min_length=3, max_length=200)
    description: str | None = None
    mandatory_for: Literal["collector", "supervisor", "finance", "hr", "command"] | None = None


@router.post("/hr/training/courses")
def create_course(body: CourseIn, user: dict = Depends(hr_only)):
    with get_conn() as conn, dict_cursor(conn) as cur:
        cur.execute("INSERT INTO training_courses (title, description, mandatory_for) VALUES (%s,%s,%s) RETURNING id",
                    (body.title, body.description, body.mandatory_for))
        cid = cur.fetchone()["id"]
        if body.mandatory_for:
            cur.execute("""INSERT INTO training_records (course_id, employee_id) SELECT %s, id FROM employees
                           WHERE active AND role = %s ON CONFLICT DO NOTHING""", (cid, body.mandatory_for))
    return {"id": cid}


@router.get("/hr/training/courses")
def list_courses(user: dict = Depends(hr_only)):
    with get_conn() as conn, dict_cursor(conn) as cur:
        cur.execute(
            """SELECT c.*, COUNT(t.id) AS assigned, COUNT(t.id) FILTER (WHERE t.status = 'completed') AS completed
               FROM training_courses c LEFT JOIN training_records t ON t.course_id = c.id GROUP BY c.id ORDER BY c.created_at DESC"""
        )
        courses = cur.fetchall()
        cur.execute("""SELECT t.id, t.course_id, t.status, t.score, t.completed_at, e.employee_code, e.full_name
                       FROM training_records t JOIN employees e ON e.id = t.employee_id ORDER BY t.status, e.employee_code""")
        records = cur.fetchall()
    for c in courses:
        c["created_at"] = _iso(c["created_at"])
        c["records"] = [{**r, "completed_at": _iso(r["completed_at"])} for r in records if r["course_id"] == c["id"]]
    return courses


class AssignIn(BaseModel):
    employee_codes: list[str] = Field(..., min_length=1)


@router.post("/hr/training/courses/{course_id}/assign")
def assign_course(course_id: int, body: AssignIn, user: dict = Depends(hr_only)):
    with get_conn() as conn, dict_cursor(conn) as cur:
        n = 0
        for code in body.employee_codes:
            e = _get_emp(cur, code)
            cur.execute("INSERT INTO training_records (course_id, employee_id) VALUES (%s,%s) ON CONFLICT DO NOTHING RETURNING id",
                        (course_id, e["id"]))
            n += 1 if cur.fetchone() else 0
    return {"assigned": n}


class CompleteIn(BaseModel):
    score: int | None = Field(None, ge=0, le=100)


@router.post("/hr/training/records/{record_id}/complete")
def complete_training(record_id: int, body: CompleteIn, user: dict = Depends(hr_only)):
    with get_conn() as conn, dict_cursor(conn) as cur:
        cur.execute("UPDATE training_records SET status = 'completed', score = %s, completed_at = NOW() WHERE id = %s RETURNING id",
                    (body.score, record_id))
        if not cur.fetchone():
            raise HTTPException(404, "السجل غير موجود")
    return {"id": record_id, "status": "completed"}
