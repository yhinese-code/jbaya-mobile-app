"""Finance: deposit verification, general ledger, statements, manual journal, government remittances,
and closing cash differences escalated by supervisors. Analytics live in routers/analytics.py."""
from datetime import date
from typing import Literal

from fastapi import APIRouter, Depends, HTTPException, Query
from pydantic import BaseModel, Field

from .. import audit, files, hr_logic, ledger
from ..config import settings
from ..db import dict_cursor, get_conn
from ..security import require_roles

router = APIRouter(prefix="/finance", tags=["finance"])
finance_only = require_roles("finance")
finance_read = require_roles("finance", "command")


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


# ================================================================ ledger

def _iso(v):
    return v.isoformat() if v else None


@router.get("/accounts")
def accounts(user: dict = Depends(finance_read)):
    return [ledger.account_out(c) for c in ledger.CHART]


@router.get("/trial-balance")
def trial_balance(as_of: date | None = None, user: dict = Depends(finance_read)):
    with get_conn() as conn, dict_cursor(conn) as cur:
        as_of = as_of or hr_logic.local_today(cur)
        b = ledger.balances(cur, as_of)
    rows = list(b.values())
    td, tc = round(sum(r["debit"] for r in rows), 2), round(sum(r["credit"] for r in rows), 2)
    groups = {}
    for r in rows:
        groups.setdefault(r["type"], 0.0)
        groups[r["type"]] += r["balance"]
    return {"as_of": as_of.isoformat(), "accounts": rows, "total_debit": td, "total_credit": tc,
            "balanced": abs(td - tc) < 0.01, "by_type": {k: round(v, 2) for k, v in groups.items()},
            "cash": ledger.cash_position(b)}


@router.get("/ledger")
def postings(account: str | None = None, start: date | None = None, end: date | None = None,
             source: str | None = None, limit: int = Query(500, ge=1, le=5000), user: dict = Depends(finance_read)):
    if account and account not in ledger.CHART:
        raise HTTPException(404, "الحساب غير موجود")
    with get_conn() as conn, dict_cursor(conn) as cur:
        today = hr_logic.local_today(cur)
        end = end or today
        start = start or end.replace(day=1)
        if start > end:
            raise HTTPException(422, "تاريخ البداية بعد تاريخ النهاية")
        args = {**ledger.local_bounds(start, end), "a": account, "src": source, "lim": limit}
        opening = 0.0
        if account:
            cur.execute(f"""SELECT COALESCE(SUM(debit),0) AS d, COALESCE(SUM(credit),0) AS c FROM ledger_postings
                            WHERE account = %(a)s AND posted_at < {ledger.LO}""", args)
            o = cur.fetchone()
            opening = ledger.signed(account, float(o["d"]), float(o["c"]))
        cur.execute(
            f"""SELECT l.posted_at, l.account, l.debit, l.credit, l.source, l.ref, l.memo, e.employee_code
                FROM ledger_postings l LEFT JOIN employees e ON e.id = l.employee_id
                WHERE l.posted_at >= {ledger.LO} AND l.posted_at < {ledger.HI}
                  AND (%(a)s::text IS NULL OR l.account = %(a)s) AND (%(src)s::text IS NULL OR l.source = %(src)s)
                ORDER BY l.posted_at, l.source, l.ref, l.account LIMIT %(lim)s""",
            args,
        )
        rows = cur.fetchall()
    bal = opening
    out = []
    for r in rows:
        d, c = float(r["debit"]), float(r["credit"])
        item = {"posted_at": _iso(r["posted_at"]), "account": r["account"],
                "account_name": ledger.CHART.get(r["account"], ("?",))[0], "debit": d, "credit": c,
                "source": r["source"], "ref": r["ref"], "memo": r["memo"], "employee_code": r["employee_code"]}
        if account:
            bal += ledger.signed(account, d, c)
            item["balance"] = round(bal, 2)
        out.append(item)
    return {"start": start.isoformat(), "end": end.isoformat(), "account": ledger.account_out(account) if account else None,
            "opening": round(opening, 2), "closing": round(bal, 2) if account else None, "postings": out,
            "truncated": len(rows) >= limit}


@router.get("/income-statement")
def income_statement(period: str | None = None, user: dict = Depends(finance_read)):
    with get_conn() as conn, dict_cursor(conn) as cur:
        if not period:
            t = hr_logic.local_today(cur)
            period = f"{t.year}-{t.month:02d}"
        start, end = hr_logic.parse_period(period)
        mov = ledger.period_movements(cur, start, end)
    def lines(kind):
        return [{**ledger.account_out(c), "amount": m["net"]} for c, m in mov.items() if ledger.CHART[c][1] == kind and m["net"]]
    rev, exp = lines("revenue"), lines("expense")
    tr, te = round(sum(x["amount"] for x in rev), 2), round(sum(x["amount"] for x in exp), 2)
    gov = mov["2100"]
    return {"period": period, "revenue": rev, "expenses": exp, "total_revenue": tr, "total_expenses": te,
            "net_income": round(tr - te, 2),
            "pass_through": {"government_collected": round(gov["credit"], 2), "government_remitted": round(gov["debit"], 2),
                             "note": "حصة دائرة الماء ليست إيراداً للشركة؛ تُحصّل نيابةً عنها وتُورَّد."}}


# ================================================================ manual journal

class JournalLineIn(BaseModel):
    account: str
    debit: float = Field(0, ge=0)
    credit: float = Field(0, ge=0)


class JournalIn(BaseModel):
    entry_date: date
    memo: str = Field(..., min_length=3, max_length=300)
    lines: list[JournalLineIn] = Field(..., min_length=2, max_length=20)


def _post_journal(cur, user_id: int, entry_date: date, memo: str, lines: list[dict]) -> int:
    cur.execute("INSERT INTO journal_entries (posted_at, memo, created_by) "
                "VALUES (((%s::date)::timestamp + interval '12 hours') AT TIME ZONE %s, %s, %s) RETURNING id",
                (entry_date, settings.APP_TIMEZONE, memo, user_id))
    eid = cur.fetchone()["id"]
    for l in lines:
        cur.execute("INSERT INTO journal_lines (entry_id, account, debit, credit) VALUES (%s,%s,%s,%s)",
                    (eid, l["account"], l["debit"], l["credit"]))
    audit.log(cur, user_id, "journal_entry", "journal", eid, {"memo": memo, "lines": lines})
    return eid


@router.post("/journal")
def create_journal(body: JournalIn, user: dict = Depends(finance_only)):
    lines = []
    for l in body.lines:
        if l.account not in ledger.CHART:
            raise HTTPException(422, f"الحساب {l.account} غير موجود")
        if not ledger.CHART[l.account][2]:
            raise HTTPException(422, f"الحساب {l.account} يُرحَّل تلقائياً من النظام ولا يقبل قيوداً يدوية")
        if (l.debit > 0) == (l.credit > 0):
            raise HTTPException(422, "كل سطر يجب أن يكون مديناً أو دائناً فقط")
        lines.append({"account": l.account, "debit": round(l.debit, 2), "credit": round(l.credit, 2)})
    if abs(sum(x["debit"] for x in lines) - sum(x["credit"] for x in lines)) >= 0.01:
        raise HTTPException(422, "القيد غير متوازن: مجموع المدين يجب أن يساوي مجموع الدائن")
    with get_conn() as conn, dict_cursor(conn) as cur:
        if body.entry_date > hr_logic.local_today(cur):
            raise HTTPException(422, "لا يمكن ترحيل قيد بتاريخ مستقبلي")
        eid = _post_journal(cur, user["id"], body.entry_date, body.memo.strip(), lines)
    return {"id": eid}


@router.get("/journal")
def list_journal(user: dict = Depends(finance_read)):
    with get_conn() as conn, dict_cursor(conn) as cur:
        cur.execute("""SELECT j.*, e.employee_code AS created_by_code FROM journal_entries j JOIN employees e ON e.id = j.created_by
                       ORDER BY j.posted_at DESC, j.id DESC LIMIT 200""")
        entries = cur.fetchall()
        cur.execute("SELECT * FROM journal_lines WHERE entry_id = ANY(%s) ORDER BY id", ([e["id"] for e in entries],))
        lines = cur.fetchall()
    return [{"id": e["id"], "posted_at": _iso(e["posted_at"]), "memo": e["memo"], "created_by": e["created_by_code"],
             "lines": [{"account": l["account"], "account_name": ledger.CHART.get(l["account"], ("?",))[0],
                        "debit": float(l["debit"]), "credit": float(l["credit"])} for l in lines if l["entry_id"] == e["id"]]}
            for e in entries]


@router.post("/journal/{entry_id}/reverse")
def reverse_journal(entry_id: int, user: dict = Depends(finance_only)):
    with get_conn() as conn, dict_cursor(conn) as cur:
        cur.execute("SELECT * FROM journal_entries WHERE id = %s", (entry_id,))
        e = cur.fetchone()
        if not e:
            raise HTTPException(404, "القيد غير موجود")
        cur.execute("SELECT 1 FROM journal_entries WHERE memo = %s", (f"عكس القيد #{entry_id}",))
        if cur.fetchone():
            raise HTTPException(409, "تم عكس هذا القيد مسبقاً")
        cur.execute("SELECT account, debit, credit FROM journal_lines WHERE entry_id = %s", (entry_id,))
        lines = [{"account": l["account"], "debit": float(l["credit"]), "credit": float(l["debit"])} for l in cur.fetchall()]
        eid = _post_journal(cur, user["id"], hr_logic.local_today(cur), f"عكس القيد #{entry_id}", lines)
    return {"id": eid}


# ================================================================ government remittances

class RemittanceIn(BaseModel):
    amount: float = Field(..., gt=0)
    bank_ref: str = Field(..., min_length=2, max_length=80)
    remitted_on: date | None = None
    period_from: date | None = None
    period_to: date | None = None
    note: str | None = Field(None, max_length=300)


@router.get("/remittances")
def remittances(user: dict = Depends(finance_read)):
    with get_conn() as conn, dict_cursor(conn) as cur:
        cur.execute("""SELECT g.*, e.employee_code AS created_by_code FROM gov_remittances g JOIN employees e ON e.id = g.created_by
                       ORDER BY g.remitted_at DESC LIMIT 200""")
        rows = cur.fetchall()
        b = ledger.balances(cur)
        cur.execute("SELECT COALESCE(SUM(gov_amount),0) AS s FROM receipts")
        collected = float(cur.fetchone()["s"])
    return {"due": b["2100"]["balance"], "bank": b["1100"]["balance"], "government_collected_total": collected,
            "remitted_total": round(sum(float(r["amount"]) for r in rows), 2),
            "items": [{"id": r["id"], "amount": float(r["amount"]), "bank_ref": r["bank_ref"], "note": r["note"],
                       "period_from": _iso(r["period_from"]), "period_to": _iso(r["period_to"]),
                       "remitted_at": _iso(r["remitted_at"]), "created_by": r["created_by_code"]} for r in rows]}


@router.post("/remittances")
def create_remittance(body: RemittanceIn, user: dict = Depends(finance_only)):
    with get_conn() as conn, dict_cursor(conn) as cur:
        cur.execute("SELECT pg_advisory_xact_lock(4242)")        # one remittance at a time
        today = hr_logic.local_today(cur)
        day = body.remitted_on or today
        if day > today:
            raise HTTPException(422, "لا يمكن تسجيل توريد بتاريخ مستقبلي")
        b = ledger.balances(cur)
        due, bank = b["2100"]["balance"], b["1100"]["balance"]
        if body.amount > due + 0.01:
            raise HTTPException(409, f"المبلغ أكبر من المستحق لدائرة الماء ({due:,.0f} د.ع)")
        if body.amount > bank + 0.01:
            raise HTTPException(409, f"رصيد المصرف المؤكد لا يكفي ({bank:,.0f} د.ع). دقق الإيداعات المعلقة أولاً")
        cur.execute(
            """INSERT INTO gov_remittances (amount, period_from, period_to, bank_ref, note, remitted_at, created_by)
               VALUES (%s,%s,%s,%s,%s, CASE WHEN %s THEN NOW() ELSE ((%s::date)::timestamp + interval '12 hours') AT TIME ZONE %s END, %s)
               RETURNING id""",
            (body.amount, body.period_from, body.period_to, body.bank_ref.strip(), body.note, day == today,
             day, settings.APP_TIMEZONE, user["id"]),
        )
        rid = cur.fetchone()["id"]
        audit.log(cur, user["id"], "gov_remittance", "remittance", rid, {"amount": body.amount, "ref": body.bank_ref})
    return {"id": rid, "due_after": round(due - body.amount, 2)}


# ================================================================ escalated cash differences

@router.get("/escalations")
def escalations(user: dict = Depends(finance_read)):
    with get_conn() as conn, dict_cursor(conn) as cur:
        cur.execute(
            """SELECT r.id, r.created_at, r.counted_cash, r.expected_cash, r.difference, r.status, r.resolution_status,
                      r.resolution_note, c.employee_code AS collector_code, c.full_name AS collector_name,
                      s.employee_code AS supervisor_code
               FROM reconciliations r JOIN employees c ON c.id = r.collector_id JOIN employees s ON s.id = r.supervisor_id
               WHERE r.resolution_status = 'escalated' ORDER BY r.created_at"""
        )
        rows = cur.fetchall()
    return [{**r, "counted_cash": float(r["counted_cash"]), "expected_cash": float(r["expected_cash"]),
             "difference": float(r["difference"]), "created_at": _iso(r["created_at"])} for r in rows]


class CloseIn(BaseModel):
    action: Literal["salary_deduction", "write_off"]
    note: str = Field(..., min_length=3, max_length=500)


@router.post("/reconciliations/{rec_id}/close")
def close_escalation(rec_id: int, body: CloseIn, user: dict = Depends(finance_only)):
    """Finance decides an escalated difference: recover it from the collector's next salary, or write it off."""
    with get_conn() as conn, dict_cursor(conn) as cur:
        cur.execute("SELECT * FROM reconciliations WHERE id = %s FOR UPDATE", (rec_id,))
        r = cur.fetchone()
        if not r or r["resolution_status"] != "escalated":
            raise HTTPException(409, "هذا الفرق غير محال أو تمت تسويته")
        if body.action == "salary_deduction" and float(r["difference"]) >= 0:
            raise HTTPException(422, "الاستقطاع من الراتب للعجز فقط")
        note = ((r["resolution_note"] or "") + " | المالية: " + body.note).strip(" |")
        cur.execute("""UPDATE reconciliations SET resolution_status = 'resolved', resolution_action = %s, resolution_note = %s,
                          resolved_by = %s, resolved_at = NOW() WHERE id = %s""",
                    (body.action, note, user["id"], rec_id))
        audit.log(cur, user["id"], f"reconciliation_{body.action}", "reconciliation", rec_id,
                  {"difference": str(r["difference"]), "note": body.note})
    return {"reconciliation_id": rec_id, "resolution_status": "resolved", "action": body.action}
