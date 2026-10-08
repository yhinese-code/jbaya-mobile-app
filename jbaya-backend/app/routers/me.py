"""Employee self-service ("خدماتي"): attendance check-in/out with selfie + GPS, leave requests and balances,
payslips, expense claims, custody, appraisals and training. Available to every logged-in employee."""
import json
from datetime import date, datetime
from typing import Literal

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field

from .. import audit, files, hr_logic
from ..config import settings
from ..db import dict_cursor, get_conn
from ..security import current_user
from ..utils import point_in_polygon

router = APIRouter(prefix="/me", tags=["self-service"])


def _iso(v):
    return v.isoformat() if v else None


def _num(v):
    return float(v) if v is not None else None


# ---------------------------------------------------------------- profile

@router.get("/profile")
def my_profile(user: dict = Depends(current_user)):
    with get_conn() as conn, dict_cursor(conn) as cur:
        cur.execute(
            """SELECT e.employee_code, e.full_name, e.role, e.job_title, e.department, e.hire_date, e.contract_end,
                      e.base_salary, e.allowance_transport, e.allowance_phone, e.allowance_risk, e.payment_method,
                      s.name AS sector_name, sup.full_name AS supervisor_name
               FROM employees e LEFT JOIN sectors s ON s.id = e.sector_id LEFT JOIN employees sup ON sup.id = e.supervisor_id
               WHERE e.id = %s""",
            (user["id"],),
        )
        e = cur.fetchone()
    for k in ("base_salary", "allowance_transport", "allowance_phone", "allowance_risk"):
        e[k] = float(e[k])
    for k in ("hire_date", "contract_end"):
        e[k] = _iso(e[k])
    return e


# ---------------------------------------------------------------- attendance

class AttendanceIn(BaseModel):
    lat: float | None = None
    lng: float | None = None
    gps_accuracy_m: float | None = None
    is_mocked: bool = False
    selfie_base64: str | None = Field(None, max_length=6_000_000)


def _local_now(cur) -> tuple[date, int]:
    """(local date, minutes since local midnight)."""
    cur.execute(
        """SELECT (NOW() AT TIME ZONE %s)::date AS d,
                  EXTRACT(HOUR FROM NOW() AT TIME ZONE %s)::int * 60 + EXTRACT(MINUTE FROM NOW() AT TIME ZONE %s)::int AS m""",
        (settings.APP_TIMEZONE,) * 3,
    )
    r = cur.fetchone()
    return r["d"], r["m"]


def _shift_start_minutes() -> int:
    h, m = settings.SHIFT_START.split(":")
    return int(h) * 60 + int(m)


@router.post("/attendance/check-in")
def check_in(body: AttendanceIn, user: dict = Depends(current_user)):
    if settings.REQUIRE_SELFIE and not body.selfie_base64:
        raise HTTPException(422, "يجب التقاط صورة شخصية (سيلفي) لتسجيل الحضور")
    if body.is_mocked:
        raise HTTPException(403, "تم اكتشاف تطبيق لتزييف الموقع. أغلقه ثم حاول مجدداً")
    with get_conn() as conn, dict_cursor(conn) as cur:
        today, minutes = _local_now(cur)
        cur.execute("SELECT id FROM attendance WHERE employee_id = %s AND work_date = %s", (user["id"], today))
        if cur.fetchone():
            raise HTTPException(409, "تم تسجيل حضورك اليوم مسبقاً")
        if hr_logic.approved_leave_days(cur, user["id"], today, today):
            raise HTTPException(409, "لديك إجازة معتمدة اليوم")
        flags = []
        inside = None
        if body.lat is None or body.lng is None:
            flags.append("no_gps")
        elif user["role"] == "collector" and user["sector_id"]:
            cur.execute("SELECT polygon FROM sectors WHERE id = %s", (user["sector_id"],))
            row = cur.fetchone()
            if row:
                inside = point_in_polygon(body.lat, body.lng, row["polygon"])
                if not inside:
                    flags.append("outside_sector")
        if not hr_logic.is_working_day(today):
            flags.append("weekend")
        late = max(0, minutes - _shift_start_minutes())
        late = late if late > settings.LATE_GRACE_MINUTES else 0
        if late:
            flags.append("late")
        photo = files.save_photo(body.selfie_base64, "attendance") if body.selfie_base64 else None
        cur.execute(
            """INSERT INTO attendance (employee_id, work_date, check_in_at, check_in_lat, check_in_lng, check_in_photo,
                                       check_in_inside, late_minutes, flags)
               VALUES (%s,%s,NOW(),%s,%s,%s,%s,%s,%s::jsonb) RETURNING id, check_in_at""",
            (user["id"], today, body.lat, body.lng, photo, inside, late, json.dumps(flags)),
        )
        a = cur.fetchone()
        audit.log(cur, user["id"], "check_in", "attendance", a["id"], {"late_minutes": late, "flags": flags,
                                                                        "lat": body.lat, "lng": body.lng})
    return {"attendance_id": a["id"], "check_in_at": _iso(a["check_in_at"]), "late_minutes": late, "flags": flags}


@router.post("/attendance/check-out")
def check_out(body: AttendanceIn, user: dict = Depends(current_user)):
    with get_conn() as conn, dict_cursor(conn) as cur:
        today, _ = _local_now(cur)
        cur.execute("SELECT * FROM attendance WHERE employee_id = %s AND work_date = %s FOR UPDATE", (user["id"], today))
        a = cur.fetchone()
        if not a:
            raise HTTPException(409, "لم تسجّل حضورك اليوم")
        if a["check_out_at"]:
            raise HTTPException(409, "تم تسجيل انصرافك مسبقاً")
        photo = files.save_photo(body.selfie_base64, "attendance") if body.selfie_base64 else None
        cur.execute(
            """UPDATE attendance SET check_out_at = NOW(), check_out_lat = %s, check_out_lng = %s, check_out_photo = %s,
                      worked_minutes = GREATEST(0, EXTRACT(EPOCH FROM (NOW() - check_in_at))::int / 60)
               WHERE id = %s RETURNING check_out_at, worked_minutes""",
            (body.lat, body.lng, photo, a["id"]),
        )
        r = cur.fetchone()
        audit.log(cur, user["id"], "check_out", "attendance", a["id"], {"worked_minutes": r["worked_minutes"]})
    return {"check_out_at": _iso(r["check_out_at"]), "worked_minutes": r["worked_minutes"]}


@router.get("/attendance")
def my_attendance(month: str | None = None, user: dict = Depends(current_user)):
    with get_conn() as conn, dict_cursor(conn) as cur:
        today, _ = _local_now(cur)
        start, end = hr_logic.parse_period(month or today.strftime("%Y-%m"))
        cur.execute(
            """SELECT work_date, check_in_at, check_out_at, late_minutes, worked_minutes, flags FROM attendance
               WHERE employee_id = %s AND work_date BETWEEN %s AND %s ORDER BY work_date DESC""",
            (user["id"], start, end),
        )
        rows = cur.fetchall()
        cur.execute("SELECT check_in_at, check_out_at FROM attendance WHERE employee_id = %s AND work_date = %s",
                    (user["id"], today))
        t = cur.fetchone()
        on_leave = bool(hr_logic.approved_leave_days(cur, user["id"], today, today))
    return {
        "today": {"date": today.isoformat(), "checked_in_at": _iso(t["check_in_at"]) if t else None,
                  "checked_out_at": _iso(t["check_out_at"]) if t else None, "on_leave": on_leave,
                  "working_day": hr_logic.is_working_day(today)},
        "records": [{"work_date": r["work_date"].isoformat(), "check_in_at": _iso(r["check_in_at"]),
                     "check_out_at": _iso(r["check_out_at"]), "late_minutes": r["late_minutes"],
                     "worked_minutes": r["worked_minutes"], "flags": r["flags"]} for r in rows],
        "shift_start": settings.SHIFT_START,
    }


# ---------------------------------------------------------------- leave

class LeaveIn(BaseModel):
    leave_type: Literal["annual", "sick", "emergency", "unpaid"]
    start_date: date
    end_date: date
    reason: str | None = Field(None, max_length=500)
    attachment_base64: str | None = Field(None, max_length=6_000_000)


def leave_out(r: dict) -> dict:
    return {
        "id": r["id"], "leave_type": r["leave_type"], "label": hr_logic.LEAVE_TYPES[r["leave_type"]][0],
        "start_date": r["start_date"].isoformat(), "end_date": r["end_date"].isoformat(), "days": r["days"],
        "reason": r["reason"], "status": r["status"], "decision_note": r["decision_note"],
        "has_attachment": bool(r["attachment_path"]), "created_at": _iso(r["created_at"]),
        **({"employee_code": r["employee_code"], "full_name": r["full_name"]} if "employee_code" in r else {}),
    }


@router.get("/leave")
def my_leave(user: dict = Depends(current_user)):
    with get_conn() as conn, dict_cursor(conn) as cur:
        today = hr_logic.local_today(cur)
        balances = hr_logic.leave_balances(cur, user["id"], today.year)
        cur.execute("SELECT * FROM leave_requests WHERE employee_id = %s ORDER BY created_at DESC LIMIT 50", (user["id"],))
        rows = cur.fetchall()
    return {"balances": balances, "requests": [leave_out(r) for r in rows]}


@router.post("/leave")
def request_leave(body: LeaveIn, user: dict = Depends(current_user)):
    if body.end_date < body.start_date:
        raise HTTPException(422, "تاريخ النهاية قبل تاريخ البداية")
    if (body.end_date - body.start_date).days > 90:
        raise HTTPException(422, "مدة الإجازة طويلة جداً")
    days = len(hr_logic.working_days(body.start_date, body.end_date))
    if days == 0:
        raise HTTPException(422, "الفترة المختارة لا تحتوي أيام عمل")
    with get_conn() as conn, dict_cursor(conn) as cur:
        today = hr_logic.local_today(cur)
        earliest = today.toordinal() - (30 if body.leave_type == "sick" else 3)
        if body.start_date.toordinal() < earliest:
            raise HTTPException(422, "لا يمكن طلب إجازة بأثر رجعي لهذه المدة")
        cur.execute(
            """SELECT 1 FROM leave_requests WHERE employee_id = %s AND status IN ('pending_supervisor','pending_hr','approved')
               AND start_date <= %s AND end_date >= %s""",
            (user["id"], body.end_date, body.start_date),
        )
        if cur.fetchone():
            raise HTTPException(409, "يوجد طلب إجازة آخر يتداخل مع هذه الفترة")
        bal = hr_logic.leave_balances(cur, user["id"], body.start_date.year)[body.leave_type]
        if bal["remaining"] is not None and days > bal["remaining"]:
            raise HTTPException(422, f"الرصيد المتبقي {bal['remaining']} يوم فقط")
        attachment = files.save_photo(body.attachment_base64, "leave") if body.attachment_base64 else None
        status = "pending_hr"          # Phase 5: only HR approves; the supervisor is just informed
        cur.execute(
            """INSERT INTO leave_requests (employee_id, leave_type, start_date, end_date, days, reason, attachment_path, status)
               VALUES (%s,%s,%s,%s,%s,%s,%s,%s) RETURNING *""",
            (user["id"], body.leave_type, body.start_date, body.end_date, days, body.reason, attachment, status),
        )
        r = cur.fetchone()
        audit.log(cur, user["id"], "leave_requested", "leave", r["id"], {"type": body.leave_type, "days": days})
    return leave_out(r)


@router.post("/leave/{leave_id}/cancel")
def cancel_leave(leave_id: int, user: dict = Depends(current_user)):
    with get_conn() as conn, dict_cursor(conn) as cur:
        cur.execute("SELECT * FROM leave_requests WHERE id = %s AND employee_id = %s FOR UPDATE", (leave_id, user["id"]))
        r = cur.fetchone()
        if not r:
            raise HTTPException(404, "الطلب غير موجود")
        if r["status"] not in ("pending_supervisor", "pending_hr"):
            raise HTTPException(409, "لا يمكن إلغاء طلب تمت معالجته، راجع الموارد البشرية")
        cur.execute("UPDATE leave_requests SET status = 'cancelled' WHERE id = %s", (leave_id,))
        audit.log(cur, user["id"], "leave_cancelled", "leave", leave_id, {})
    return {"id": leave_id, "status": "cancelled"}


# ---------------------------------------------------------------- payslips

@router.get("/payslips")
def my_payslips(user: dict = Depends(current_user)):
    with get_conn() as conn, dict_cursor(conn) as cur:
        cur.execute(
            """SELECT p.id, r.period, r.status, p.gross, p.deductions, p.net FROM payslips p
               JOIN payroll_runs r ON r.id = p.run_id
               WHERE p.employee_id = %s AND r.status IN ('approved','paid') ORDER BY r.period DESC""",
            (user["id"],),
        )
        rows = cur.fetchall()
    return [{"id": r["id"], "period": r["period"], "status": r["status"], "gross": float(r["gross"]),
             "deductions": float(r["deductions"]), "net": float(r["net"])} for r in rows]


@router.get("/payslips/{payslip_id}")
def my_payslip(payslip_id: int, user: dict = Depends(current_user)):
    with get_conn() as conn, dict_cursor(conn) as cur:
        cur.execute(
            """SELECT p.*, r.period, r.status FROM payslips p JOIN payroll_runs r ON r.id = p.run_id
               WHERE p.id = %s AND p.employee_id = %s AND r.status IN ('approved','paid')""",
            (payslip_id, user["id"]),
        )
        p = cur.fetchone()
    if not p:
        raise HTTPException(404, "قسيمة الراتب غير موجودة")
    return {"id": p["id"], "period": p["period"], "status": p["status"], "gross": float(p["gross"]),
            "deductions": float(p["deductions"]), "net": float(p["net"]), "lines": p["lines"], "stats": p["stats"]}


# ---------------------------------------------------------------- expenses

class ExpenseIn(BaseModel):
    category: Literal["fuel", "phone", "transport", "repair", "other"]
    amount: float = Field(..., gt=0, le=10_000_000)
    expense_date: date
    description: str | None = Field(None, max_length=500)
    receipt_base64: str | None = Field(None, max_length=6_000_000)


def expense_out(r: dict) -> dict:
    return {"id": r["id"], "category": r["category"], "amount": float(r["amount"]), "expense_date": r["expense_date"].isoformat(),
            "description": r["description"], "status": r["status"], "decision_note": r["decision_note"],
            "has_receipt": bool(r["receipt_path"]), "created_at": _iso(r["created_at"]),
            **({"employee_code": r["employee_code"], "full_name": r["full_name"]} if "employee_code" in r else {})}


@router.get("/expenses")
def my_expenses(user: dict = Depends(current_user)):
    with get_conn() as conn, dict_cursor(conn) as cur:
        cur.execute("SELECT * FROM expense_claims WHERE employee_id = %s ORDER BY created_at DESC LIMIT 50", (user["id"],))
        return [expense_out(r) for r in cur.fetchall()]


@router.post("/expenses")
def submit_expense(body: ExpenseIn, user: dict = Depends(current_user)):
    if not body.receipt_base64:
        raise HTTPException(422, "يجب إرفاق صورة الوصل")
    with get_conn() as conn, dict_cursor(conn) as cur:
        today = hr_logic.local_today(cur)
        if body.expense_date > today or (today - body.expense_date).days > 60:
            raise HTTPException(422, "تاريخ المصروف غير مقبول (خلال آخر 60 يوماً)")
        path = files.save_photo(body.receipt_base64, "expenses")
        cur.execute(
            """INSERT INTO expense_claims (employee_id, category, amount, expense_date, description, receipt_path)
               VALUES (%s,%s,%s,%s,%s,%s) RETURNING *""",
            (user["id"], body.category, body.amount, body.expense_date, body.description, path),
        )
        r = cur.fetchone()
        audit.log(cur, user["id"], "expense_submitted", "expense", r["id"], {"amount": body.amount, "category": body.category})
    return expense_out(r)


# ---------------------------------------------------------------- custody, appraisals, training

@router.get("/custody")
def my_custody(user: dict = Depends(current_user)):
    with get_conn() as conn, dict_cursor(conn) as cur:
        cur.execute("SELECT * FROM custody_items WHERE employee_id = %s ORDER BY status, assigned_at DESC", (user["id"],))
        rows = cur.fetchall()
    return [{"id": r["id"], "item_type": r["item_type"], "description": r["description"], "serial_no": r["serial_no"],
             "value_iqd": float(r["value_iqd"]), "status": r["status"], "assigned_at": _iso(r["assigned_at"]),
             "returned_at": _iso(r["returned_at"])} for r in rows]


@router.get("/appraisals")
def my_appraisals(user: dict = Depends(current_user)):
    with get_conn() as conn, dict_cursor(conn) as cur:
        cur.execute("SELECT * FROM appraisals WHERE employee_id = %s ORDER BY period DESC LIMIT 12", (user["id"],))
        rows = cur.fetchall()
    return [{"period": r["period"], "auto_score": float(r["auto_score"]), "final_score": float(r["final_score"]),
             "supervisor_rating": r["supervisor_rating"], "supervisor_note": r["supervisor_note"],
             "recommendation": r["recommendation"], "metrics": r["metrics"]} for r in rows]


@router.get("/training")
def my_training(user: dict = Depends(current_user)):
    with get_conn() as conn, dict_cursor(conn) as cur:
        cur.execute(
            """SELECT c.title, c.description, c.mandatory_for, t.status, t.score, t.completed_at
               FROM training_records t JOIN training_courses c ON c.id = t.course_id
               WHERE t.employee_id = %s ORDER BY t.status, c.title""",
            (user["id"],),
        )
        rows = cur.fetchall()
    for r in rows:
        r["completed_at"] = _iso(r["completed_at"])
    return rows


@router.get("/summary")
def my_hr_summary(user: dict = Depends(current_user)):
    """Small badge data for the self-service button: today's attendance + pending items."""
    with get_conn() as conn, dict_cursor(conn) as cur:
        today, _ = _local_now(cur)
        cur.execute("SELECT check_in_at, check_out_at FROM attendance WHERE employee_id = %s AND work_date = %s",
                    (user["id"], today))
        t = cur.fetchone()
        cur.execute("SELECT COUNT(*) AS n FROM leave_requests WHERE employee_id = %s AND status IN ('pending_supervisor','pending_hr')",
                    (user["id"],))
        pending_leave = cur.fetchone()["n"]
    return {"checked_in": bool(t), "checked_out": bool(t and t["check_out_at"]),
            "working_day": hr_logic.is_working_day(today), "pending_leave": pending_leave,
            "server_time": datetime.now().isoformat()}
