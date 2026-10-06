"""HR calculations: working days, leave balances, payroll and the automatic monthly appraisal.
All money is computed here (server side); the app only displays it."""
import calendar
from datetime import date, timedelta

from fastapi import HTTPException

from .config import settings

LEAVE_TYPES = {
    # type: (label, yearly entitlement or None = unlimited, paid)
    "annual": ("إجازة سنوية", lambda: settings.LEAVE_ANNUAL_DAYS, True),
    "sick": ("إجازة مرضية", lambda: settings.LEAVE_SICK_DAYS, True),
    "emergency": ("إجازة اضطرارية", lambda: settings.LEAVE_EMERGENCY_DAYS, True),
    "unpaid": ("إجازة بدون راتب", lambda: None, False),
}


# ---------------------------------------------------------------- dates

def local_today(cur) -> date:
    cur.execute("SELECT (NOW() AT TIME ZONE %s)::date AS d", (settings.APP_TIMEZONE,))
    row = cur.fetchone()
    return row["d"] if isinstance(row, dict) else row[0]


def parse_period(period: str) -> tuple[date, date]:
    try:
        y, m = (int(x) for x in period.split("-"))
        start = date(y, m, 1)
    except (ValueError, TypeError):
        raise HTTPException(422, "الفترة يجب أن تكون بصيغة YYYY-MM")
    return start, date(y, m, calendar.monthrange(y, m)[1])


def is_working_day(d: date) -> bool:
    return d.weekday() not in settings.WEEKEND_DAYS


def working_days(start: date, end: date) -> list[date]:
    out, d = [], start
    while d <= end:
        if is_working_day(d):
            out.append(d)
        d += timedelta(days=1)
    return out


# SQL for "start of local day %(s)s" and "end of local day %(e)s" (exclusive), using PostgreSQL's time-zone data
LO = "(%(s)s::date)::timestamp AT TIME ZONE %(tz)s"
HI = "(%(e)s::date + 1)::timestamp AT TIME ZONE %(tz)s"


# ---------------------------------------------------------------- leave

def leave_balances(cur, employee_id: int, year: int) -> dict:
    cur.execute(
        """SELECT leave_type, status, start_date, end_date FROM leave_requests
           WHERE employee_id = %s AND status IN ('approved','pending_supervisor','pending_hr')
             AND end_date >= %s AND start_date <= %s""",
        (employee_id, date(year, 1, 1), date(year, 12, 31)),
    )
    used = {k: 0 for k in LEAVE_TYPES}
    pending = {k: 0 for k in LEAVE_TYPES}
    for r in cur.fetchall():
        s, e = max(r["start_date"], date(year, 1, 1)), min(r["end_date"], date(year, 12, 31))
        n = len(working_days(s, e))
        (used if r["status"] == "approved" else pending)[r["leave_type"]] += n
    out = {}
    for k, (label, ent, paid) in LEAVE_TYPES.items():
        entitlement = ent()
        out[k] = {
            "label": label, "paid": paid, "entitlement": entitlement, "used": used[k], "pending": pending[k],
            "remaining": None if entitlement is None else entitlement - used[k] - pending[k],
        }
    return out


def approved_leave_days(cur, employee_id: int, start: date, end: date) -> dict[date, str]:
    """{working day: leave_type} for approved leave inside [start, end]."""
    cur.execute(
        """SELECT leave_type, start_date, end_date FROM leave_requests
           WHERE employee_id = %s AND status = 'approved' AND end_date >= %s AND start_date <= %s""",
        (employee_id, start, end),
    )
    days = {}
    for r in cur.fetchall():
        for d in working_days(max(r["start_date"], start), min(r["end_date"], end)):
            days[d] = r["leave_type"]
    return days


# ---------------------------------------------------------------- payroll

def _r(x: float) -> float:
    return float(round(x))


def compute_payslip(cur, emp: dict, period: str) -> dict:
    """Earnings and deductions for one employee for one month. Returns {gross, deductions, net, lines, stats}."""
    p_start, p_end = parse_period(period)
    today = local_today(cur)
    start = max(p_start, emp["hire_date"]) if emp.get("hire_date") else p_start
    counted_until = min(p_end, today)            # absences are only counted up to today in the current month
    month_days = working_days(p_start, p_end)
    daily_rate = float(emp["base_salary"]) / len(month_days) if month_days else 0.0
    expected_days = working_days(start, counted_until) if start <= counted_until else []

    cur.execute("SELECT work_date, late_minutes FROM attendance WHERE employee_id = %s AND work_date BETWEEN %s AND %s",
                (emp["id"], start, counted_until))
    attended = {r["work_date"]: r["late_minutes"] for r in cur.fetchall()}
    present = [d for d in expected_days if d in attended]
    leave = approved_leave_days(cur, emp["id"], start, p_end)
    leave_in_window = {d: t for d, t in leave.items() if d <= counted_until}
    paid_leave = [d for d, t in leave_in_window.items() if t != "unpaid"]
    unpaid_leave = [d for d, t in leave.items() if t == "unpaid"]           # unpaid leave counts for the whole month
    absent = [d for d in expected_days if d not in attended and d not in leave_in_window]
    # days before the hire date are not paid
    unhired = [d for d in month_days if emp.get("hire_date") and d < emp["hire_date"]]

    bounds = {"s": p_start, "e": p_end, "tz": settings.APP_TIMEZONE}
    lines = []

    def earn(code, label, amount, detail=""):
        if amount:
            lines.append({"kind": "earning", "code": code, "label": label, "amount": _r(amount), "detail": detail})

    def deduct(code, label, amount, detail=""):
        if amount:
            lines.append({"kind": "deduction", "code": code, "label": label, "amount": _r(amount), "detail": detail})

    earn("base", "الراتب الأساسي", float(emp["base_salary"]))
    earn("allow_transport", "بدل نقل", float(emp["allowance_transport"]))
    earn("allow_phone", "بدل هاتف", float(emp["allowance_phone"]))
    earn("allow_risk", "بدل خطورة (حمل نقد)", float(emp["allowance_risk"]))

    commission_receipts = 0
    if emp["role"] == "collector":
        cur.execute(
            f"""SELECT COUNT(*) AS n FROM receipts WHERE collector_id = %(id)s AND verification_method = 'otp'
                AND issued_at >= {LO} AND issued_at < {HI}""",
            {**bounds, "id": emp["id"]},
        )
        commission_receipts = cur.fetchone()["n"]
        earn("commission", "عمولة التحصيل", commission_receipts * settings.COMMISSION_PER_RECEIPT_IQD,
             f"{commission_receipts} وصل موثق برمز المواطن × {settings.COMMISSION_PER_RECEIPT_IQD:,.0f}")

    cur.execute(
        """SELECT id, amount, category FROM expense_claims
           WHERE employee_id = %s AND status = 'approved' AND expense_date <= %s""",
        (emp["id"], p_end),
    )
    expenses = cur.fetchall()
    reimb = sum(float(x["amount"]) for x in expenses)
    earn("reimbursement", "تعويض مصروفات", reimb, f"{len(expenses)} مطالبة")

    if unhired:
        deduct("not_hired", "أيام قبل المباشرة", len(unhired) * daily_rate, f"{len(unhired)} يوم")
    deduct("absence", "غياب بدون إذن", len(absent) * daily_rate, f"{len(absent)} يوم × {daily_rate:,.0f}")
    deduct("unpaid_leave", "إجازة بدون راتب", len(unpaid_leave) * daily_rate, f"{len(unpaid_leave)} يوم")

    cur.execute(
        f"""SELECT COALESCE(SUM(ABS(difference)), 0) AS s, COUNT(*) AS n FROM reconciliations
            WHERE collector_id = %(id)s AND resolution_action = 'salary_deduction'
              AND resolved_at >= {LO} AND resolved_at < {HI}""",
        {**bounds, "id": emp["id"]},
    )
    short = cur.fetchone()
    cur.execute(
        f"""SELECT COALESCE(SUM(ABS(difference)), 0) AS s, COUNT(*) AS n FROM cash_handovers
            WHERE supervisor_id = %(id)s AND resolution_action = 'salary_deduction' AND resolution_status = 'resolved'
              AND resolved_at >= {LO} AND resolved_at < {HI}""",
        {**bounds, "id": emp["id"]},
    )
    hq = cur.fetchone()
    deduct("cash_shortage", "نقص نقدي يُخصم من الراتب", float(short["s"]) + float(hq["s"]),
           f"{short['n'] + hq['n']} تسليم فيه نقص")

    cur.execute(
        """SELECT COALESCE(SUM(penalty_iqd), 0) AS s, COUNT(*) AS n FROM disciplinary_actions
           WHERE employee_id = %s AND penalty_iqd > 0 AND effective_date BETWEEN %s AND %s""",
        (emp["id"], p_start, p_end),
    )
    pen = cur.fetchone()
    deduct("penalty", "عقوبات انضباطية", float(pen["s"]), f"{pen['n']} إجراء")

    taxable = sum(l["amount"] for l in lines if l["kind"] == "earning" and l["code"] != "reimbursement")
    deduct("income_tax", "ضريبة الدخل", taxable * settings.INCOME_TAX_PCT / 100, f"{settings.INCOME_TAX_PCT}%")
    deduct("social_security", "الضمان الاجتماعي (حصة الموظف)", float(emp["base_salary"]) * settings.SOCIAL_SECURITY_PCT / 100,
           f"{settings.SOCIAL_SECURITY_PCT}%")

    gross = sum(l["amount"] for l in lines if l["kind"] == "earning")
    deductions = sum(l["amount"] for l in lines if l["kind"] == "deduction")
    net = gross - deductions
    stats = {
        "working_days_month": len(month_days), "expected_days": len(expected_days), "present_days": len(present),
        "absent_days": len(absent), "paid_leave_days": len(paid_leave), "unpaid_leave_days": len(unpaid_leave),
        "late_days": sum(1 for d in present if attended[d] > 0), "daily_rate": _r(daily_rate),
        "commission_receipts": commission_receipts, "expense_ids": [x["id"] for x in expenses],
        "counted_until": counted_until.isoformat(), "negative_net": net < 0,
    }
    return {"gross": gross, "deductions": deductions, "net": max(net, 0.0), "lines": lines, "stats": stats}


# ---------------------------------------------------------------- appraisal

def compute_appraisal(cur, emp: dict, period: str) -> dict:
    p_start, p_end = parse_period(period)
    today = local_today(cur)
    until = min(p_end, today)
    start = max(p_start, emp["hire_date"]) if emp.get("hire_date") else p_start
    expected = working_days(start, until) if start <= until else []
    leave = approved_leave_days(cur, emp["id"], start, until)
    expected = [d for d in expected if d not in leave]
    cur.execute("SELECT work_date, late_minutes FROM attendance WHERE employee_id = %s AND work_date BETWEEN %s AND %s",
                (emp["id"], start, until))
    att = {r["work_date"]: r["late_minutes"] for r in cur.fetchall()}
    present = [d for d in expected if d in att]
    attendance_rate = len(present) / len(expected) if expected else 1.0
    punctuality = 1 - (sum(1 for d in present if att[d] > 0) / len(present)) if present else 1.0

    bounds = {"s": p_start, "e": p_end, "tz": settings.APP_TIMEZONE, "id": emp["id"]}
    lo, hi = LO, HI
    cur.execute(f"""SELECT COALESCE(SUM(total_amount),0) AS s, COUNT(*) AS n,
                           COUNT(*) FILTER (WHERE verification_method = 'master_code') AS master
                    FROM receipts WHERE collector_id = %(id)s AND issued_at >= {lo} AND issued_at < {hi}""", bounds)
    rec = cur.fetchone()
    collected = float(rec["s"])
    target_daily = float(emp["daily_target_iqd"]) if emp.get("daily_target_iqd") is not None else settings.COLLECTOR_DAILY_TARGET_IQD
    target = target_daily * len(present)
    collection_ratio = min(collected / target, 1.5) if target > 0 else (1.0 if emp["role"] != "collector" else 0.0)
    cur.execute(f"""SELECT COALESCE(SUM(ABS(difference)),0) AS s FROM reconciliations
                    WHERE collector_id = %(id)s AND created_at >= {lo} AND created_at < {hi}""", bounds)
    diff = float(cur.fetchone()["s"])
    cash_accuracy = 1 - min(1.0, diff / collected) if collected > 0 else 1.0
    cur.execute(f"""SELECT COUNT(*) AS n FROM audit_log WHERE actor_id = %(id)s AND created_at >= {lo} AND created_at < {hi}
                    AND action IN ('geofence_exit','mock_location','impossible_speed','master_code_failed','employee_phone_blocked')""",
                bounds)
    security = cur.fetchone()["n"]
    cur.execute("""SELECT COUNT(*) AS n FROM disciplinary_actions WHERE employee_id = %s AND effective_date BETWEEN %s AND %s
                   AND action_type IN ('written_warning','final_warning','penalty','suspension')""", (emp["id"], p_start, p_end))
    warnings = cur.fetchone()["n"]
    compliance = max(0.0, 1 - 0.2 * security - 0.1 * max(0, rec["master"] - 3) - 0.34 * warnings)

    if emp["role"] == "collector":
        score = (min(collection_ratio, 1.0) * 35 + attendance_rate * 25 + punctuality * 10 + cash_accuracy * 20 + compliance * 10)
    else:
        score = attendance_rate * 50 + punctuality * 25 + compliance * 25
    metrics = {
        "collected": collected, "target": target, "collection_ratio": round(collection_ratio, 3),
        "expected_days": len(expected), "present_days": len(present), "attendance_rate": round(attendance_rate, 3),
        "punctuality": round(punctuality, 3), "cash_difference": diff, "cash_accuracy": round(cash_accuracy, 3),
        "security_events": security, "master_code_receipts": rec["master"], "warnings": warnings,
        "compliance": round(compliance, 3), "receipts": rec["n"],
    }
    return {"metrics": metrics, "auto_score": round(score, 1)}


def final_score(auto: float, rating: int | None) -> float:
    return round(auto if rating is None else auto * 0.7 + rating * 20 * 0.3, 1)


def recommendation(score: float) -> str:
    if score >= 85:
        return "أداء ممتاز: يُرشَّح لمكافأة أو ترقية"
    if score >= 70:
        return "أداء جيد"
    if score >= 50:
        return "يحتاج تحسين: تدريب ومتابعة من المشرف"
    return "أداء ضعيف: إنذار وخطة تحسين"
