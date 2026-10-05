"""Finance: verify supervisors' bank deposits against the bank statement.
(Ledger, charts and analytics come in Phase 4.)"""
from typing import Literal

from fastapi import APIRouter, Depends, HTTPException, Query
from pydantic import BaseModel, Field

from .. import audit, files
from ..db import dict_cursor, get_conn
from ..security import require_roles

router = APIRouter(prefix="/finance", tags=["finance"])
finance_only = require_roles("finance")


@router.get("/deposits")
def deposits(status: Literal["pending", "verified", "rejected", "all"] = Query("pending"),
             user: dict = Depends(finance_only)):
    with get_conn() as conn, dict_cursor(conn) as cur:
        cur.execute(
            """SELECT d.id, d.amount, d.expected_amount, d.difference, d.bank_name, d.slip_number, d.status,
                      d.finance_note, d.created_at, d.verified_at, e.employee_code AS supervisor_code,
                      e.full_name AS supervisor_name,
                      (SELECT COUNT(*) FROM reconciliations r WHERE r.deposit_id = d.id) AS reconciliations,
                      (SELECT COALESCE(SUM(r.difference), 0) FROM reconciliations r WHERE r.deposit_id = d.id) AS collector_differences
               FROM bank_deposits d JOIN employees e ON e.id = d.supervisor_id
               WHERE (%s = 'all' OR d.status = %s)
               ORDER BY d.created_at DESC LIMIT 200""",
            (status, status),
        )
        rows = cur.fetchall()
        cur.execute(
            """SELECT COALESCE(SUM(amount) FILTER (WHERE status = 'pending'), 0) AS pending_amount,
                      COUNT(*) FILTER (WHERE status = 'pending') AS pending_count,
                      COALESCE(SUM(amount) FILTER (WHERE status = 'verified'), 0) AS verified_amount
               FROM bank_deposits"""
        )
        totals = cur.fetchone()
    for r in rows:
        for k in ("amount", "expected_amount", "difference", "collector_differences"):
            r[k] = float(r[k])
        r["created_at"] = r["created_at"].isoformat()
        r["verified_at"] = r["verified_at"].isoformat() if r["verified_at"] else None
    return {
        "deposits": rows,
        "totals": {"pending_amount": float(totals["pending_amount"]), "pending_count": totals["pending_count"],
                   "verified_amount": float(totals["verified_amount"])},
    }


@router.get("/deposits/{deposit_id}/slip")
def deposit_slip(deposit_id: int, user: dict = Depends(require_roles("finance", "command"))):
    with get_conn() as conn, dict_cursor(conn) as cur:
        cur.execute("SELECT slip_photo_path FROM bank_deposits WHERE id = %s", (deposit_id,))
        d = cur.fetchone()
    photo = files.load_photo(d["slip_photo_path"]) if d else None
    if not photo:
        raise HTTPException(404, "صورة الوصل غير موجودة")
    return photo


class DepositDecisionIn(BaseModel):
    action: Literal["verify", "reject"]
    note: str = Field(..., min_length=3, max_length=500)


@router.post("/deposits/{deposit_id}/decision")
def decide(deposit_id: int, body: DepositDecisionIn, user: dict = Depends(finance_only)):
    with get_conn() as conn, dict_cursor(conn) as cur:
        cur.execute("SELECT * FROM bank_deposits WHERE id = %s FOR UPDATE", (deposit_id,))
        d = cur.fetchone()
        if not d:
            raise HTTPException(404, "الإيداع غير موجود")
        if d["status"] != "pending":
            raise HTTPException(409, "تمت معالجة هذا الإيداع مسبقاً")
        new_status = "verified" if body.action == "verify" else "rejected"
        cur.execute(
            "UPDATE bank_deposits SET status = %s, finance_note = %s, verified_by = %s, verified_at = NOW() WHERE id = %s",
            (new_status, body.note, user["id"], deposit_id),
        )
        if new_status == "rejected":
            # the cash goes back on the supervisor's books until a valid deposit is made
            cur.execute("UPDATE reconciliations SET deposit_id = NULL WHERE deposit_id = %s", (deposit_id,))
        audit.log(cur, user["id"], f"deposit_{new_status}", "deposit", deposit_id, {"note": body.note})
    return {"deposit_id": deposit_id, "status": new_status}
