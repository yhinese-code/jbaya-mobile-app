"""Owner panel: company profit, breakeven, approvals for large write-offs and corrections, and what finance did."""
from typing import Literal

from fastapi import APIRouter, Depends, HTTPException, Query
from pydantic import BaseModel, Field

from .. import audit, fin_data, hr_logic, ledger, performance
from ..config import settings
from ..db import dict_cursor, get_conn
from ..security import require_roles

router = APIRouter(prefix="/owner", tags=["owner"])
owner_only = require_roles("owner")


def _iso(v):
    return v.isoformat() if v else None


def _f(v) -> float:
    return float(v) if v is not None else 0.0


@router.get("/summary")
def summary(user: dict = Depends(owner_only)):
    with get_conn() as conn, dict_cursor(conn) as cur:
        today = hr_logic.local_today(cur)
        months = []
        y, m = today.year, today.month
        for _ in range(6):
            start, end = hr_logic.parse_period(f"{y}-{m:02d}")
            mov = ledger.period_movements(cur, start, min(end, today))
            income = {c: mov[c]["net"] for c in ledger.INCOME}
            costs = {c: mov[c]["net"] for c in ledger.COSTS}
            months.append({"period": f"{y}-{m:02d}", "fees": income["4100"], "share": income["4110"], "other": income["4200"],
                           "income": round(sum(income.values()), 2), "salaries": costs["5100"] + costs["5200"],
                           "losses": costs["5300"], "operating": costs["5400"], "costs": round(sum(costs.values()), 2),
                           "profit": round(sum(income.values()) - sum(costs.values()), 2),
                           "trust_collected": mov["2100"]["in"]})
            m -= 1
            if m == 0:
                y, m = y - 1, 12
        b = ledger.balances(cur)
        cash = ledger.cash_position(b)
        be = performance.company_breakeven(cur)
        cur.execute(
            """SELECT s.code, s.name, COUNT(DISTINCT p.id) FILTER (WHERE p.status = 'active') AS properties,
                      COALESCE(SUM(r.company_fee + r.company_share) FILTER (WHERE r.issued_at >= date_trunc('month', NOW())), 0) AS income_mtd
               FROM sectors s LEFT JOIN properties p ON p.sector_id = s.id LEFT JOIN receipts r ON r.property_id = p.id
               GROUP BY s.id ORDER BY income_mtd DESC"""
        )
        sectors = [{"code": r["code"], "name": r["name"], "properties": r["properties"], "income_mtd": _f(r["income_mtd"]),
                    "income_per_property": round(_f(r["income_mtd"]) / r["properties"]) if r["properties"] else 0}
                   for r in cur.fetchall()]
        approvals = len(_approvals(cur))
    alerts = []
    if cash["outside_hq"] > settings.CASH_OUTSIDE_HQ_ALERT_IQD:
        alerts.append(f"نقد خارج المقر (لدى الجباة والمشرفين): {cash['outside_hq']:,.0f} د.ع")
    if cash["differences"]:
        alerts.append(f"فروقات نقدية قيد التحقيق: {cash['differences']:,.0f} د.ع")
    if approvals:
        alerts.append(f"{approvals} طلبات بانتظار موافقتك")
    if be["on_track"] is False:
        alerts.append("التحصيل هذا الشهر دون نقطة التعادل حتى الآن")
    return {"today": today.isoformat(), "months": months, "cash": cash, "breakeven": be, "sectors": sectors,
            "approvals_waiting": approvals, "alerts": alerts, "company_share_pct": settings.COMPANY_SHARE_PCT,
            "approval_threshold": settings.OWNER_APPROVAL_IQD}


def _approvals(cur) -> list[dict]:
    out = []
    cur.execute("""SELECT j.*, e.employee_code FROM journal_entries j JOIN employees e ON e.id = j.created_by
                   WHERE j.status = 'pending_owner' ORDER BY j.created_at""")
    for j in cur.fetchall():
        cur.execute("SELECT account, debit, credit FROM journal_lines WHERE entry_id = %s", (j["id"],))
        lines = cur.fetchall()
        amount = sum(_f(l["debit"]) for l in lines)
        out.append({"kind": "journal", "id": j["id"], "amount": amount, "title": f"تصحيح يدوي: {j['memo']}",
                    "requested_by": j["employee_code"], "at": _iso(j["created_at"]),
                    "detail": " | ".join(f"{ledger.CHART.get(l['account'], ('?',))[0]} "
                                         f"{'+' if _f(l['debit']) else '-'}{max(_f(l['debit']), _f(l['credit'])):,.0f}" for l in lines)})
    cur.execute("""SELECT r.*, c.employee_code AS person FROM reconciliations r JOIN employees c ON c.id = r.collector_id
                   WHERE r.resolution_status = 'pending_owner' ORDER BY r.created_at""")
    for r in cur.fetchall():
        out.append({"kind": "reconciliation", "id": r["id"], "amount": abs(_f(r["difference"])),
                    "title": f"شطب {'نقص' if _f(r['difference']) < 0 else 'زيادة'} لدى الجابي {r['person']}",
                    "requested_by": None, "at": _iso(r["created_at"]), "detail": r["resolution_note"]})
    cur.execute("""SELECT h.*, s.employee_code AS person FROM cash_handovers h JOIN employees s ON s.id = h.supervisor_id
                   WHERE h.resolution_status = 'pending_owner' ORDER BY h.created_at""")
    for h in cur.fetchall():
        out.append({"kind": "handover", "id": h["id"], "amount": abs(_f(h["difference"])),
                    "title": f"شطب {'نقص' if _f(h['difference']) < 0 else 'زيادة'} عند تسليم المشرف {h['person']}",
                    "requested_by": None, "at": _iso(h["created_at"]), "detail": h["resolution_note"]})
    return out


@router.get("/approvals")
def approvals(user: dict = Depends(owner_only)):
    with get_conn() as conn, dict_cursor(conn) as cur:
        return _approvals(cur)


class DecisionIn(BaseModel):
    action: Literal["approve", "reject"]
    note: str | None = Field(None, max_length=500)


@router.post("/approvals/{kind}/{item_id}")
def decide(kind: Literal["journal", "reconciliation", "handover"], item_id: int, body: DecisionIn,
           user: dict = Depends(owner_only)):
    approve = body.action == "approve"
    with get_conn() as conn, dict_cursor(conn) as cur:
        if kind == "journal":
            cur.execute("UPDATE journal_entries SET status = %s, decided_by = %s, decided_at = NOW(), decision_note = %s "
                        "WHERE id = %s AND status = 'pending_owner' RETURNING id",
                        ("posted" if approve else "rejected", user["id"], body.note, item_id))
        elif kind == "reconciliation":
            # approved: the write-off is booked now; rejected: back to finance to decide again
            cur.execute("""UPDATE reconciliations SET resolution_status = %s, resolved_at = CASE WHEN %s THEN NOW() ELSE resolved_at END,
                              resolution_action = CASE WHEN %s THEN resolution_action ELSE 'escalate' END,
                              resolution_note = COALESCE(resolution_note, '') || %s
                           WHERE id = %s AND resolution_status = 'pending_owner' RETURNING id""",
                        ("resolved" if approve else "escalated", approve, approve,
                         f" | المالك: {'موافقة' if approve else 'رفض'} {body.note or ''}", item_id))
        else:
            cur.execute("""UPDATE cash_handovers SET resolution_status = %s, resolved_at = CASE WHEN %s THEN NOW() ELSE NULL END,
                              resolution_action = CASE WHEN %s THEN resolution_action ELSE NULL END,
                              resolution_note = COALESCE(resolution_note, '') || %s
                           WHERE id = %s AND resolution_status = 'pending_owner' RETURNING id""",
                        ("resolved" if approve else "pending", approve, approve,
                         f" | المالك: {'موافقة' if approve else 'رفض'} {body.note or ''}", item_id))
        if not cur.fetchone():
            raise HTTPException(409, "الطلب غير موجود أو تم البت فيه")
        audit.log(cur, user["id"], f"owner_{body.action}", kind, item_id, {"note": body.note})
    return {"kind": kind, "id": item_id, "result": "approved" if approve else "rejected"}


FINANCE_ACTIONS = {
    "cash_handover": "استلام نقد من مشرف", "transfer_to_bank": "إيداع في المصرف", "transfer_from_bank": "سحب من المصرف",
    "gov_remittance": "تسليم أمانة دائرة الماء", "journal_entry": "تصحيح يدوي", "payroll_approve": "اعتماد الرواتب",
    "payroll_mark_paid": "صرف الرواتب", "deposit_verified": "تأكيد إيداع قديم", "deposit_rejected": "رفض إيداع قديم",
    "reconciliation_salary_deduction": "خصم فرق جابٍ من الراتب", "reconciliation_write_off": "شطب فرق جابٍ",
    "handover_supervisor_paid": "دفع المشرف النقص", "handover_salary_deduction": "خصم نقص مشرف من الراتب",
    "handover_write_off": "شطب فرق مشرف", "handover_surplus_income": "تسجيل زيادة إيراداً",
    "expense_approve": "موافقة على مصروف", "expense_reject": "رفض مصروف",
}


@router.get("/finance-log")
def finance_log(days: int = Query(30, ge=1, le=365), user: dict = Depends(owner_only)):
    """Everything the finance department did, from the tamper-evident audit log."""
    with get_conn() as conn, dict_cursor(conn) as cur:
        cur.execute(
            """SELECT l.id, l.action, l.entity, l.entity_id, l.details, l.created_at, e.employee_code, e.full_name
               FROM audit_log l JOIN employees e ON e.id = l.actor_id
               WHERE e.role = 'finance' AND l.created_at >= NOW() - (%s || ' days')::interval
               ORDER BY l.id DESC LIMIT 500""",
            (days,),
        )
        rows = cur.fetchall()
    return [{"id": r["id"], "action": r["action"], "label": FINANCE_ACTIONS.get(r["action"], r["action"]), "ref": r["entity_id"],
             "details": r["details"], "at": _iso(r["created_at"]), "by": f"{r['employee_code']} - {r['full_name']}"} for r in rows]


@router.get("/performance")
def owner_performance(period: str | None = Query(None, pattern=r"^\d{4}-\d{2}$"), user: dict = Depends(owner_only)):
    with get_conn() as conn, dict_cursor(conn) as cur:
        return {**performance.per_collector_money(cur, period), "company": performance.company_breakeven(cur)}


@router.get("/overview")
def owner_overview(days: int = Query(30, ge=7, le=180), user: dict = Depends(owner_only)):
    with get_conn() as conn, dict_cursor(conn) as cur:
        return fin_data.overview(cur, days, "owner")
