"""Supervisor: review queue (estimates, readings lower than previous) and blind cash reconciliation."""
import json
from typing import Literal

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field

from .. import audit
from ..db import dict_cursor, get_conn
from ..security import require_roles

router = APIRouter(prefix="/supervisor", tags=["supervisor"])
supervisor_only = require_roles("supervisor")

FLAG_LABELS = {
    "reading_lower_than_previous": "القراءة الحالية أقل من السابقة",
    "estimate_on_working_meter": "تقدير على عداد مسجل كعامل",
    "high_consumption": "استهلاك مرتفع بشكل غير طبيعي",
    "zero_consumption": "استهلاك صفري",
    "no_gps": "بدون موقع GPS",
    "new_baseline": "قراءة أساس جديدة",
    "rebaseline": "إعادة تعيين قراءة الأساس",
}


def _team_filter(user: dict) -> tuple[str, tuple]:
    """Supervisors see the collectors who report to them; admin sees everyone."""
    if user["role"] == "admin":
        return "TRUE", ()
    return "e.supervisor_id = %s", (user["id"],)


@router.get("/collectors")
def my_collectors(user: dict = Depends(supervisor_only)):
    cond, args = _team_filter(user)
    with get_conn() as conn, dict_cursor(conn) as cur:
        cur.execute(
            f"""SELECT e.id, e.employee_code, e.full_name, s.name AS sector_name,
                       (SELECT COUNT(*) FROM receipts r WHERE r.collector_id = e.id AND r.reconciliation_id IS NULL) AS open_receipts
                FROM employees e LEFT JOIN sectors s ON s.id = e.sector_id
                WHERE e.role = 'collector' AND e.active AND {cond}
                ORDER BY e.employee_code""",
            args,
        )
        # open_receipts is a count only: the expected cash stays hidden until the supervisor enters the counted amount
        return cur.fetchall()


@router.get("/reviews")
def review_queue(user: dict = Depends(supervisor_only)):
    cond, args = _team_filter(user)
    with get_conn() as conn, dict_cursor(conn) as cur:
        cur.execute(
            f"""SELECT b.id, b.status, b.billing_method, b.visit_type, b.previous_reading, b.current_reading,
                       b.period_days, b.gov_amount, b.company_fee, b.total_amount, b.flags, b.created_at,
                       p.property_code, p.address, p.meter_status, c.full_name AS citizen_name,
                       e.employee_code AS collector_code, e.full_name AS collector_name
                FROM bills b
                JOIN properties p ON p.id = b.property_id
                JOIN citizens c ON c.id = p.citizen_id
                JOIN employees e ON e.id = b.collector_id
                WHERE b.status IN ('pending_approval','blocked_review') AND {cond}
                ORDER BY b.created_at""",
            args,
        )
        rows = cur.fetchall()
    out = []
    for r in rows:
        r = dict(r)
        for k in ("previous_reading", "current_reading", "gov_amount", "company_fee", "total_amount"):
            r[k] = float(r[k]) if r[k] is not None else None
        r["created_at"] = r["created_at"].isoformat()
        r["flag_labels"] = [FLAG_LABELS.get(f, f) for f in r["flags"]]
        out.append(r)
    return out


class DecisionIn(BaseModel):
    action: Literal["approve", "reject", "rebaseline"]
    note: str = Field(..., min_length=3, max_length=500)


@router.post("/bills/{bill_id}/decision")
def decide(bill_id: int, body: DecisionIn, user: dict = Depends(supervisor_only)):
    cond, args = _team_filter(user)
    with get_conn() as conn, dict_cursor(conn) as cur:
        cur.execute(
            f"""SELECT b.* FROM bills b JOIN employees e ON e.id = b.collector_id
                WHERE b.id = %s AND {cond} FOR UPDATE OF b""",
            (bill_id, *args),
        )
        b = cur.fetchone()
        if not b:
            raise HTTPException(404, "الفاتورة غير موجودة ضمن فريقك")

        if body.action == "reject":
            if b["status"] not in ("pending_approval", "blocked_review"):
                raise HTTPException(409, "الفاتورة ليست قيد المراجعة")
            new_status, flags = "cancelled", b["flags"]
        elif body.action == "approve":
            if b["status"] != "pending_approval":
                raise HTTPException(409, "الموافقة متاحة فقط لفواتير التقدير")
            new_status, flags = "awaiting_otp", b["flags"]
        else:  # rebaseline: meter replaced/reset -> bill the period by estimate, store the new reading as the baseline
            if b["status"] != "blocked_review":
                raise HTTPException(409, "إعادة تعيين الأساس متاحة فقط عندما تكون القراءة أقل من السابقة")
            new_status, flags = "awaiting_otp", list(b["flags"]) + ["rebaseline"]
            cur.execute("UPDATE bills SET billing_method = 'estimate', consumption = NULL, unit_rate = NULL WHERE id = %s", (b["id"],))

        cur.execute(
            """UPDATE bills SET status = %s, flags = %s, review_note = %s, reviewed_by = %s, reviewed_at = NOW()
               WHERE id = %s""",
            (new_status, json.dumps(flags), body.note, user["id"], b["id"]),
        )
        audit.log(cur, user["id"], f"bill_{body.action}", "bill", b["id"], {"note": body.note})
    return {"bill_id": bill_id, "status": new_status}


class ReconciliationIn(BaseModel):
    collector_code: str
    counted_cash: float = Field(..., ge=0)
    note: str | None = Field(None, max_length=500)


@router.post("/reconciliations")
def reconcile(body: ReconciliationIn, user: dict = Depends(supervisor_only)):
    """Blind reconciliation: the expected amount is computed and revealed only AFTER the counted cash is submitted."""
    cond, args = _team_filter(user)
    with get_conn() as conn, dict_cursor(conn) as cur:
        cur.execute(
            f"SELECT e.* FROM employees e WHERE UPPER(e.employee_code) = %s AND e.role = 'collector' AND {cond}",
            (body.collector_code.strip().upper(), *args),
        )
        col = cur.fetchone()
        if not col:
            raise HTTPException(404, "الجابي غير موجود ضمن فريقك")
        cur.execute(
            "SELECT id, total_amount FROM receipts WHERE collector_id = %s AND reconciliation_id IS NULL FOR UPDATE",
            (col["id"],),
        )
        receipts = cur.fetchall()
        if not receipts:
            raise HTTPException(409, "لا توجد وصولات غير مسواة لهذا الجابي")
        expected = sum(float(r["total_amount"]) for r in receipts)
        diff = round(body.counted_cash - expected, 2)
        status = "matched" if diff == 0 else ("shortage" if diff < 0 else "surplus")
        cur.execute(
            """INSERT INTO reconciliations (collector_id, supervisor_id, counted_cash, expected_cash, difference,
                                            receipts_count, status, note)
               VALUES (%s,%s,%s,%s,%s,%s,%s,%s) RETURNING id, created_at""",
            (col["id"], user["id"], body.counted_cash, expected, diff, len(receipts), status, body.note),
        )
        rec = cur.fetchone()
        cur.execute("UPDATE receipts SET reconciliation_id = %s WHERE id = ANY(%s)", (rec["id"], [r["id"] for r in receipts]))
        audit.log(cur, user["id"], "reconciliation", "employee", col["employee_code"],
                  {"counted": body.counted_cash, "expected": expected, "difference": diff, "status": status})
    return {
        "reconciliation_id": rec["id"],
        "collector_code": col["employee_code"],
        "collector_name": col["full_name"],
        "receipts_count": len(receipts),
        "counted_cash": body.counted_cash,
        "expected_cash": expected,
        "difference": diff,
        "status": status,
    }
