"""Supervisor: team view, review queue, blind cash reconciliation (with denominations), discrepancy resolution,
and bank deposits."""
import json
from typing import Literal

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field

from .. import audit, files
from ..db import dict_cursor, get_conn
from ..config import settings
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
    "ocr_mismatch": "القراءة المدخلة تختلف عن قراءة الكاميرا (OCR)",
    "no_photo": "بدون صورة للعداد",
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
                       b.photo_path IS NOT NULL AS has_photo, b.ocr_reading,
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
        for k in ("previous_reading", "current_reading", "gov_amount", "company_fee", "total_amount", "ocr_reading"):
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


# Iraqi dinar notes in circulation
DENOMINATIONS = (50000, 25000, 10000, 5000, 1000, 500, 250)


class ReconciliationIn(BaseModel):
    collector_code: str
    denominations: dict[str, int] | None = None   # {"25000": 12, "10000": 3, ...}
    counted_cash: float | None = Field(None, ge=0)
    note: str | None = Field(None, max_length=500)


def _count_notes(denoms: dict[str, int]) -> tuple[float, dict]:
    clean = {}
    total = 0
    for k, n in denoms.items():
        try:
            value = int(k)
        except ValueError:
            raise HTTPException(422, f"فئة نقدية غير معروفة: {k}")
        if value not in DENOMINATIONS:
            raise HTTPException(422, f"فئة نقدية غير معروفة: {k}")
        if n < 0:
            raise HTTPException(422, "عدد الأوراق لا يمكن أن يكون سالباً")
        if n:
            clean[str(value)] = n
            total += value * n
    return float(total), clean


@router.post("/reconciliations")
def reconcile(body: ReconciliationIn, user: dict = Depends(supervisor_only)):
    """Blind reconciliation: the expected amount is computed and revealed only AFTER the counted cash is submitted.
    Each receipt can be reconciled once, so a supervisor cannot "try again" after seeing the expected amount."""
    if body.denominations is None and body.counted_cash is None:
        raise HTTPException(422, "يجب إدخال عدد الأوراق النقدية أو المبلغ المعدود")
    denoms = None
    counted = body.counted_cash
    if body.denominations is not None:
        counted_notes, denoms = _count_notes(body.denominations)
        if counted is not None and abs(counted - counted_notes) > 0.001:
            raise HTTPException(422, "مجموع الأوراق النقدية لا يساوي المبلغ المدخل")
        counted = counted_notes

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
        diff = round(counted - expected, 2)
        status = "matched" if diff == 0 else ("shortage" if diff < 0 else "surplus")
        within_tolerance = abs(diff) <= settings.RECON_TOLERANCE_IQD
        resolution = "none_needed" if within_tolerance else "pending"
        cur.execute(
            """INSERT INTO reconciliations (collector_id, supervisor_id, counted_cash, expected_cash, difference,
                                            receipts_count, status, note, denominations, resolution_status, settled_cash)
               VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s) RETURNING id, created_at""",
            (col["id"], user["id"], counted, expected, diff, len(receipts), status, body.note,
             json.dumps(denoms) if denoms else None, resolution, counted if within_tolerance else None),
        )
        rec = cur.fetchone()
        cur.execute("UPDATE receipts SET reconciliation_id = %s WHERE id = ANY(%s)", (rec["id"], [r["id"] for r in receipts]))
        audit.log(cur, user["id"], "reconciliation", "employee", col["employee_code"],
                  {"counted": counted, "expected": expected, "difference": diff, "status": status, "denominations": denoms})
    return {
        "reconciliation_id": rec["id"],
        "collector_code": col["employee_code"],
        "collector_name": col["full_name"],
        "receipts_count": len(receipts),
        "counted_cash": counted,
        "expected_cash": expected,
        "difference": diff,
        "status": status,
        "resolution_status": resolution,
        "denominations": denoms,
    }


RESOLUTIONS = {
    # action: (allowed for, label)
    "collector_paid": ("shortage", "دفع الجابي الفرق نقداً"),
    "salary_deduction": ("shortage", "يُستقطع من راتب الجابي"),
    "deposit_surplus": ("surplus", "يُودَع الفائض ويُحقَّق في مصدره"),
    "escalate": ("any", "إحالة إلى القيادة"),
}


class ResolveIn(BaseModel):
    action: Literal["collector_paid", "salary_deduction", "deposit_surplus", "escalate"]
    note: str = Field(..., min_length=3, max_length=500)


@router.post("/reconciliations/{rec_id}/resolve")
def resolve(rec_id: int, body: ResolveIn, user: dict = Depends(supervisor_only)):
    with get_conn() as conn, dict_cursor(conn) as cur:
        cur.execute("SELECT * FROM reconciliations WHERE id = %s AND supervisor_id = %s FOR UPDATE", (rec_id, user["id"]))
        r = cur.fetchone()
        if not r:
            raise HTTPException(404, "المطابقة غير موجودة")
        if r["resolution_status"] != "pending":
            raise HTTPException(409, "تمت معالجة هذه المطابقة مسبقاً")
        allowed_for = RESOLUTIONS[body.action][0]
        if allowed_for != "any" and allowed_for != r["status"]:
            raise HTTPException(422, "هذا الإجراء لا يناسب نوع الفرق")
        # cash the supervisor now holds for the bank
        settled = float(r["expected_cash"]) if body.action == "collector_paid" else float(r["counted_cash"])
        new_status = "escalated" if body.action == "escalate" else "resolved"
        cur.execute(
            """UPDATE reconciliations SET resolution_status = %s, resolution_action = %s, resolution_note = %s,
                      resolved_by = %s, resolved_at = NOW(), settled_cash = %s WHERE id = %s""",
            (new_status, body.action, body.note, user["id"], settled, rec_id),
        )
        audit.log(cur, user["id"], f"reconciliation_{body.action}", "reconciliation", rec_id,
                  {"difference": str(r["difference"]), "settled_cash": settled, "note": body.note})
    return {"reconciliation_id": rec_id, "resolution_status": new_status, "settled_cash": settled}


@router.get("/reconciliations")
def my_reconciliations(user: dict = Depends(supervisor_only)):
    with get_conn() as conn, dict_cursor(conn) as cur:
        cur.execute(
            """SELECT r.id, r.created_at, r.counted_cash, r.expected_cash, r.difference, r.receipts_count, r.status,
                      r.resolution_status, r.resolution_action, r.settled_cash, r.deposit_id,
                      e.employee_code AS collector_code, e.full_name AS collector_name
               FROM reconciliations r JOIN employees e ON e.id = r.collector_id
               WHERE r.supervisor_id = %s AND (r.deposit_id IS NULL OR r.created_at >= NOW() - INTERVAL '7 days')
               ORDER BY r.created_at DESC""",
            (user["id"],),
        )
        rows = cur.fetchall()
    return [_rec_out(r) for r in rows]


def _rec_out(r: dict) -> dict:
    out = dict(r)
    for k in ("counted_cash", "expected_cash", "difference", "settled_cash"):
        out[k] = float(out[k]) if out.get(k) is not None else None
    out["created_at"] = out["created_at"].isoformat()
    if out.get("resolution_action"):
        out["resolution_label"] = RESOLUTIONS[out["resolution_action"]][1]
    return out


# ---------------------------------------------------------------- team view (no amounts: keeps reconciliation blind)

@router.get("/team")
def team(user: dict = Depends(supervisor_only)):
    cond, args = _team_filter(user)
    with get_conn() as conn, dict_cursor(conn) as cur:
        cur.execute(
            f"""SELECT e.id, e.employee_code, e.full_name, s.name AS sector_name,
                       (SELECT COUNT(*) FROM receipts r WHERE r.collector_id = e.id AND r.issued_at >= date_trunc('day', NOW())) AS receipts_today,
                       (SELECT COUNT(*) FROM receipts r WHERE r.collector_id = e.id AND r.reconciliation_id IS NULL) AS open_receipts,
                       (SELECT COUNT(*) FROM properties p WHERE p.registered_by = e.id AND p.activated_at >= date_trunc('day', NOW())) AS registrations_today,
                       (SELECT COUNT(*) FROM master_code_uses m WHERE m.collector_id = e.id AND m.used_at >= date_trunc('day', NOW())) AS master_uses_today,
                       (SELECT COUNT(*) FROM bills b WHERE b.collector_id = e.id AND b.status IN ('pending_approval','blocked_review')) AS bills_in_review,
                       (SELECT COUNT(*) FROM sos_alerts a WHERE a.employee_id = e.id AND a.status = 'open') AS open_sos,
                       (SELECT MAX(created_at) FROM audit_log l WHERE l.actor_id = e.id) AS last_activity
                FROM employees e LEFT JOIN sectors s ON s.id = e.sector_id
                WHERE e.role = 'collector' AND e.active AND {cond}
                ORDER BY e.employee_code""",
            args,
        )
        rows = cur.fetchall()
    for r in rows:
        r["last_activity"] = r["last_activity"].isoformat() if r["last_activity"] else None
    return rows


# ---------------------------------------------------------------- bank deposits

def _undeposited(cur, supervisor_id: int) -> list[dict]:
    cur.execute(
        """SELECT id, settled_cash, resolution_status FROM reconciliations
           WHERE supervisor_id = %s AND deposit_id IS NULL FOR UPDATE""",
        (supervisor_id,),
    )
    return cur.fetchall()


@router.get("/cash")
def cash_on_hand(user: dict = Depends(supervisor_only)):
    with get_conn() as conn, dict_cursor(conn) as cur:
        rows = _undeposited(cur, user["id"])
    ready = [r for r in rows if r["resolution_status"] != "pending"]
    return {
        "cash_to_deposit": sum(float(r["settled_cash"] or 0) for r in ready),
        "reconciliations_ready": len(ready),
        "reconciliations_pending_resolution": len(rows) - len(ready),
    }


class DepositIn(BaseModel):
    amount: float = Field(..., gt=0)
    bank_name: str = Field(..., min_length=2, max_length=120)
    slip_number: str = Field(..., min_length=2, max_length=60)
    slip_photo_base64: str = Field(..., max_length=6_000_000)


@router.post("/deposits")
def create_deposit(body: DepositIn, user: dict = Depends(supervisor_only)):
    with get_conn() as conn, dict_cursor(conn) as cur:
        rows = _undeposited(cur, user["id"])
        if not rows:
            raise HTTPException(409, "لا يوجد نقد مستلم بانتظار الإيداع")
        if any(r["resolution_status"] == "pending" for r in rows):
            raise HTTPException(409, "يجب معالجة فروقات المطابقة المعلقة قبل الإيداع")
        expected = round(sum(float(r["settled_cash"] or 0) for r in rows), 2)
        diff = round(body.amount - expected, 2)
        path = files.save_photo(body.slip_photo_base64, "deposits")
        cur.execute(
            """INSERT INTO bank_deposits (supervisor_id, amount, expected_amount, difference, bank_name, slip_number, slip_photo_path)
               VALUES (%s,%s,%s,%s,%s,%s,%s) RETURNING id, created_at""",
            (user["id"], body.amount, expected, diff, body.bank_name.strip(), body.slip_number.strip(), path),
        )
        d = cur.fetchone()
        cur.execute("UPDATE reconciliations SET deposit_id = %s WHERE id = ANY(%s)", (d["id"], [r["id"] for r in rows]))
        audit.log(cur, user["id"], "bank_deposit", "deposit", d["id"],
                  {"amount": body.amount, "expected": expected, "difference": diff, "slip": body.slip_number})
    return {"deposit_id": d["id"], "amount": body.amount, "expected_amount": expected, "difference": diff,
            "reconciliations": len(rows), "status": "pending"}


@router.get("/deposits")
def my_deposits(user: dict = Depends(supervisor_only)):
    with get_conn() as conn, dict_cursor(conn) as cur:
        cur.execute(
            """SELECT id, amount, expected_amount, difference, bank_name, slip_number, status, finance_note, created_at
               FROM bank_deposits WHERE supervisor_id = %s ORDER BY created_at DESC LIMIT 50""",
            (user["id"],),
        )
        rows = cur.fetchall()
    for r in rows:
        for k in ("amount", "expected_amount", "difference"):
            r[k] = float(r[k])
        r["created_at"] = r["created_at"].isoformat()
    return rows
