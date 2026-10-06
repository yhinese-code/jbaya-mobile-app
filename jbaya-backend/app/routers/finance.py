"""Finance (قسم المالية): receives cash at headquarters (blind count), keeps the cash box and the bank,
hands the water directorate its trust money, pays salaries, and keeps the account book (دفتر الحساب).
Finance never sees company profit: income/cost accounts and the profit statement are for the owner.
Analytics live in routers/analytics.py; performance in routers/performance.py; the owner in routers/owner.py."""
import json
from datetime import date
from typing import Literal

from fastapi import APIRouter, Depends, HTTPException, Query
from pydantic import BaseModel, Field

from .. import audit, files, hr_logic, ledger
from ..config import settings
from ..db import dict_cursor, get_conn
from ..security import require_roles
from .supervisor import _count_notes

router = APIRouter(prefix="/finance", tags=["finance"])
finance_only = require_roles("finance")
finance_read = require_roles("finance", "command", "owner")
owner_only = require_roles("owner")


def _iso(v):
    return v.isoformat() if v else None


def _f(v) -> float:
    return float(v) if v is not None else 0.0


# ================================================================ legacy bank deposits (made before the HQ handover)

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



# ================================================================ cash handed over at headquarters (blind count)

@router.get("/handovers/waiting")
def handovers_waiting(user: dict = Depends(finance_read)):
    """Supervisors who hold cash for headquarters. Deliberately WITHOUT the amount: finance counts first."""
    with get_conn() as conn, dict_cursor(conn) as cur:
        cur.execute(
            """SELECT s.employee_code, s.full_name, COUNT(c.id) AS reconciliations,
                      COUNT(c.id) FILTER (WHERE c.resolution_status = 'pending') AS unresolved,
                      MIN(c.created_at) AS oldest, string_agg(DISTINCT col.employee_code, '، ') AS collectors
               FROM reconciliations c JOIN employees s ON s.id = c.supervisor_id JOIN employees col ON col.id = c.collector_id
               WHERE c.deposit_id IS NULL AND c.handover_id IS NULL
               GROUP BY s.id ORDER BY MIN(c.created_at)"""
        )
        rows = cur.fetchall()
    return [{**r, "oldest": _iso(r["oldest"])} for r in rows]


class HandoverIn(BaseModel):
    supervisor_code: str
    counted_cash: float | None = Field(None, ge=0)
    denominations: dict[str, int] | None = None
    note: str | None = Field(None, max_length=500)


@router.post("/handovers")
def receive_handover(body: HandoverIn, user: dict = Depends(finance_only)):
    """Finance counts the supervisor's cash. The expected amount is revealed only after the count is saved."""
    if body.denominations is None and body.counted_cash is None:
        raise HTTPException(422, "أدخل عدد الأوراق النقدية أو المبلغ المعدود")
    counted, denoms = body.counted_cash, None
    if body.denominations is not None:
        total, denoms = _count_notes(body.denominations)
        if counted is not None and abs(counted - total) > 0.001:
            raise HTTPException(422, "مجموع الأوراق النقدية لا يساوي المبلغ المدخل")
        counted = total
    with get_conn() as conn, dict_cursor(conn) as cur:
        cur.execute("SELECT * FROM employees WHERE UPPER(employee_code) = UPPER(%s) AND role = 'supervisor'", (body.supervisor_code.strip(),))
        sup = cur.fetchone()
        if not sup:
            raise HTTPException(404, "المشرف غير موجود")
        cur.execute(
            """SELECT id, settled_cash, resolution_status FROM reconciliations
               WHERE supervisor_id = %s AND deposit_id IS NULL AND handover_id IS NULL FOR UPDATE""",
            (sup["id"],),
        )
        rows = cur.fetchall()
        ready = [r for r in rows if r["resolution_status"] != "pending"]
        if not ready:
            raise HTTPException(409, "لا يوجد نقد مستلم من الجباة بانتظار التسليم لدى هذا المشرف"
                                if not rows else "على المشرف معالجة فروقات الجباة المعلقة أولاً")
        expected = round(sum(_f(r["settled_cash"]) for r in ready), 2)
        diff = round(counted - expected, 2)
        status = "matched" if diff == 0 else ("shortage" if diff < 0 else "surplus")
        resolution = "none_needed" if abs(diff) <= settings.HANDOVER_TOLERANCE_IQD else "pending"
        cur.execute(
            """INSERT INTO cash_handovers (supervisor_id, received_by, counted_cash, expected_cash, difference, status, denominations,
                                           note, resolution_status) VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s) RETURNING id, created_at""",
            (sup["id"], user["id"], counted, expected, diff, status, json.dumps(denoms) if denoms else None,
             body.note, resolution),
        )
        h = cur.fetchone()
        cur.execute("UPDATE reconciliations SET handover_id = %s WHERE id = ANY(%s)", (h["id"], [r["id"] for r in ready]))
        audit.log(cur, user["id"], "cash_handover", "employee", sup["employee_code"],
                  {"counted": counted, "expected": expected, "difference": diff, "denominations": denoms})
    return {"handover_id": h["id"], "supervisor_code": sup["employee_code"], "supervisor_name": sup["full_name"],
            "counted_cash": counted, "expected_cash": expected, "difference": diff, "status": status,
            "resolution_status": resolution, "reconciliations": len(ready),
            "left_with_supervisor": len(rows) - len(ready)}


HANDOVER_ACTIONS = {
    "supervisor_paid": ("shortage", "دفع المشرف النقص نقداً"),
    "salary_deduction": ("shortage", "يُخصم من راتب المشرف"),
    "write_off": ("any", "شطب الفرق"),
    "surplus_income": ("surplus", "تُسجّل الزيادة إيراداً"),
}


class HandoverResolveIn(BaseModel):
    action: Literal["supervisor_paid", "salary_deduction", "write_off", "surplus_income"]
    note: str = Field(..., min_length=3, max_length=500)


@router.post("/handovers/{handover_id}/resolve")
def resolve_handover(handover_id: int, body: HandoverResolveIn, user: dict = Depends(finance_only)):
    with get_conn() as conn, dict_cursor(conn) as cur:
        cur.execute("SELECT * FROM cash_handovers WHERE id = %s FOR UPDATE", (handover_id,))
        h = cur.fetchone()
        if not h or h["resolution_status"] != "pending":
            raise HTTPException(409, "لا يوجد فرق معلق في هذا التسليم")
        allowed = HANDOVER_ACTIONS[body.action][0]
        if allowed != "any" and allowed != h["status"]:
            raise HTTPException(422, "هذا الإجراء لا يناسب نوع الفرق")
        needs_owner = body.action == "write_off" and abs(_f(h["difference"])) > settings.OWNER_APPROVAL_IQD
        new_status = "pending_owner" if needs_owner else "resolved"
        cur.execute("""UPDATE cash_handovers SET resolution_status = %s, resolution_action = %s, resolution_note = %s,
                          resolved_by = %s, resolved_at = CASE WHEN %s THEN NULL ELSE NOW() END WHERE id = %s""",
                    (new_status, body.action, body.note, user["id"], needs_owner, handover_id))
        audit.log(cur, user["id"], f"handover_{body.action}", "handover", handover_id,
                  {"difference": str(h["difference"]), "note": body.note, "owner_approval": needs_owner})
    return {"handover_id": handover_id, "resolution_status": new_status}


@router.get("/handovers")
def handovers(user: dict = Depends(finance_read)):
    with get_conn() as conn, dict_cursor(conn) as cur:
        cur.execute(
            """SELECT h.*, s.employee_code AS supervisor_code, s.full_name AS supervisor_name, f.employee_code AS received_by_code,
                      (SELECT COUNT(*) FROM reconciliations c WHERE c.handover_id = h.id) AS reconciliations
               FROM cash_handovers h JOIN employees s ON s.id = h.supervisor_id JOIN employees f ON f.id = h.received_by
               ORDER BY h.created_at DESC LIMIT 200"""
        )
        rows = cur.fetchall()
    out = []
    for r in rows:
        out.append({"id": r["id"], "supervisor_code": r["supervisor_code"], "supervisor_name": r["supervisor_name"],
                    "received_by": r["received_by_code"], "counted_cash": _f(r["counted_cash"]),
                    "expected_cash": _f(r["expected_cash"]), "difference": _f(r["difference"]), "status": r["status"],
                    "resolution_status": r["resolution_status"], "resolution_action": r["resolution_action"],
                    "resolution_label": HANDOVER_ACTIONS.get(r["resolution_action"], (None, None))[1],
                    "resolution_note": r["resolution_note"], "reconciliations": r["reconciliations"],
                    "created_at": _iso(r["created_at"])})
    return out


# ================================================================ cash box <-> bank

class TransferIn(BaseModel):
    direction: Literal["to_bank", "from_bank"]
    amount: float = Field(..., gt=0)
    reference: str | None = Field(None, max_length=80)
    note: str | None = Field(None, max_length=300)


@router.post("/transfers")
def transfer(body: TransferIn, user: dict = Depends(finance_only)):
    with get_conn() as conn, dict_cursor(conn) as cur:
        cur.execute("SELECT pg_advisory_xact_lock(4243)")
        b = ledger.balances(cur)
        source = "1050" if body.direction == "to_bank" else "1100"
        if body.amount > b[source]["balance"] + 0.01:
            raise HTTPException(409, f"الرصيد لا يكفي: {ledger.CHART[source][0]} فيه {b[source]['balance']:,.0f} د.ع")
        cur.execute("INSERT INTO cash_transfers (direction, amount, reference, note, created_by) VALUES (%s,%s,%s,%s,%s) RETURNING id",
                    (body.direction, body.amount, body.reference, body.note, user["id"]))
        tid = cur.fetchone()["id"]
        audit.log(cur, user["id"], f"transfer_{body.direction}", "transfer", tid, {"amount": body.amount, "ref": body.reference})
    return {"id": tid}


@router.get("/transfers")
def transfers(user: dict = Depends(finance_read)):
    with get_conn() as conn, dict_cursor(conn) as cur:
        cur.execute("""SELECT t.*, e.employee_code AS by_code FROM cash_transfers t JOIN employees e ON e.id = t.created_by
                       ORDER BY t.created_at DESC LIMIT 200""")
        rows = cur.fetchall()
        b = ledger.balances(cur)
    return {"cash_box": b["1050"]["balance"], "bank": b["1100"]["balance"],
            "items": [{"id": r["id"], "direction": r["direction"], "amount": _f(r["amount"]), "reference": r["reference"],
                       "note": r["note"], "by": r["by_code"], "created_at": _iso(r["created_at"])} for r in rows]}


# ================================================================ the account book (دفتر الحساب)

@router.get("/book")
def book(user: dict = Depends(finance_read)):
    """Every account the user may see with what came in, went out and what it holds now (plain words)."""
    with get_conn() as conn, dict_cursor(conn) as cur:
        b = ledger.balances(cur)
    groups: dict[str, dict] = {}
    for code, a in b.items():
        if code in ledger.CHART and not ledger.visible(code, user["role"]):
            continue
        if code == "1030" and a["in"] == 0:
            continue                       # legacy account, only shown while it was ever used
        g = groups.setdefault(a["group"], {"group": a["group"], "label": a["group_label"], "accounts": []})
        g["accounts"].append({k: a[k] for k in ("code", "name", "in", "out", "balance", "manual")})
    return {"groups": list(groups.values()), "cash": ledger.cash_position(b)}


@router.get("/book/{account}")
def book_account(account: str, start: date | None = None, end: date | None = None, limit: int = Query(500, ge=1, le=5000),
                 user: dict = Depends(finance_read)):
    if account not in ledger.CHART:
        raise HTTPException(404, "الحساب غير موجود")
    if not ledger.visible(account, user["role"]):
        raise HTTPException(403, "هذا الحساب للمالك فقط")
    with get_conn() as conn, dict_cursor(conn) as cur:
        today = hr_logic.local_today(cur)
        end = end or today
        start = start or end.replace(day=1)
        if start > end:
            raise HTTPException(422, "تاريخ البداية بعد تاريخ النهاية")
        args = {**ledger.local_bounds(start, end), "a": account, "lim": limit}
        cur.execute(f"""SELECT COALESCE(SUM(debit),0) AS d, COALESCE(SUM(credit),0) AS c FROM ledger_postings
                        WHERE account = %(a)s AND posted_at < {ledger.LO}""", args)
        o = cur.fetchone()
        opening = ledger.signed(account, _f(o["d"]), _f(o["c"]))
        cur.execute(
            f"""SELECT l.posted_at, l.debit, l.credit, l.source, l.ref, l.memo, e.employee_code, e.full_name
                FROM ledger_postings l LEFT JOIN employees e ON e.id = l.employee_id
                WHERE l.account = %(a)s AND l.posted_at >= {ledger.LO} AND l.posted_at < {ledger.HI}
                ORDER BY l.posted_at, l.source, l.ref LIMIT %(lim)s""",
            args,
        )
        rows = cur.fetchall()
    bal, out, tin, tout = opening, [], 0.0, 0.0
    for r in rows:
        i, o_ = ledger.in_out(account, _f(r["debit"]), _f(r["credit"]))
        bal += i - o_
        tin += i
        tout += o_
        out.append({"at": _iso(r["posted_at"]), "in": i, "out": o_, "balance": round(bal, 2), "source": r["source"],
                    "ref": r["ref"], "memo": r["memo"], "employee_code": r["employee_code"], "employee_name": r["full_name"]})
    return {"account": ledger.account_out(account), "start": start.isoformat(), "end": end.isoformat(),
            "opening": round(opening, 2), "total_in": round(tin, 2), "total_out": round(tout, 2), "closing": round(bal, 2),
            "lines": out, "truncated": len(rows) >= limit}


@router.get("/accounts")
def accounts(user: dict = Depends(finance_read)):
    return [ledger.account_out(c) for c in ledger.CHART if ledger.visible(c, user["role"])]


@router.get("/trial-balance")
def trial_balance(as_of: date | None = None, user: dict = Depends(owner_only)):
    """The full technical balance (owner / admin): proves every amount in = every amount out."""
    with get_conn() as conn, dict_cursor(conn) as cur:
        as_of = as_of or hr_logic.local_today(cur)
        b = ledger.balances(cur, as_of)
    rows = list(b.values())
    td, tc = round(sum(r["debit"] for r in rows), 2), round(sum(r["credit"] for r in rows), 2)
    return {"as_of": as_of.isoformat(), "accounts": rows, "total_debit": td, "total_credit": tc,
            "balanced": abs(td - tc) < 0.01, "cash": ledger.cash_position(b)}


@router.get("/income-statement")
def income_statement(period: str | None = None, user: dict = Depends(owner_only)):
    """Company profit for a month — owner only."""
    with get_conn() as conn, dict_cursor(conn) as cur:
        if not period:
            t = hr_logic.local_today(cur)
            period = f"{t.year}-{t.month:02d}"
        start, end = hr_logic.parse_period(period)
        mov = ledger.period_movements(cur, start, end)
    def lines(codes):
        return [{**ledger.account_out(c), "amount": mov[c]["net"]} for c in codes if mov[c]["net"]]
    income, costs = lines(ledger.INCOME), lines(ledger.COSTS)
    ti, tc = round(sum(x["amount"] for x in income), 2), round(sum(x["amount"] for x in costs), 2)
    trust = mov["2100"]
    return {"period": period, "income": income, "costs": costs, "total_income": ti, "total_costs": tc,
            "profit": round(ti - tc, 2),
            "trust": {"collected": round(trust["in"], 2), "handed_over": round(trust["out"], 2),
                      "note": "أمانة دائرة الماء ليست دخلاً ولا ديناً على الشركة: تُحصّل نيابةً عنها وتُسلَّم لها."}}


# ================================================================ manual corrections (owner approves large ones)

class JournalLineIn(BaseModel):
    account: str
    debit: float = Field(0, ge=0)
    credit: float = Field(0, ge=0)


class JournalIn(BaseModel):
    entry_date: date
    memo: str = Field(..., min_length=3, max_length=300)
    lines: list[JournalLineIn] = Field(..., min_length=2, max_length=20)


def post_journal(cur, user: dict, entry_date: date, memo: str, lines: list[dict], status: str = "posted") -> int:
    cur.execute("INSERT INTO journal_entries (posted_at, memo, created_by, status) "
                "VALUES (((%s::date)::timestamp + interval '12 hours') AT TIME ZONE %s, %s, %s, %s) RETURNING id",
                (entry_date, settings.APP_TIMEZONE, memo, user["id"], status))
    eid = cur.fetchone()["id"]
    for l in lines:
        cur.execute("INSERT INTO journal_lines (entry_id, account, debit, credit) VALUES (%s,%s,%s,%s)",
                    (eid, l["account"], l["debit"], l["credit"]))
    audit.log(cur, user["id"], "journal_entry", "journal", eid, {"memo": memo, "lines": lines, "status": status})
    return eid


@router.post("/journal")
def create_journal(body: JournalIn, user: dict = Depends(require_roles("finance", "owner"))):
    lines = []
    for l in body.lines:
        if l.account not in ledger.CHART:
            raise HTTPException(422, f"الحساب {l.account} غير موجود")
        if not ledger.CHART[l.account][3]:
            raise HTTPException(422, f"الحساب «{ledger.CHART[l.account][0]}» يُحسب تلقائياً من العمل الميداني ولا يقبل تصحيحاً يدوياً")
        if (l.debit > 0) == (l.credit > 0):
            raise HTTPException(422, "كل سطر إما وارد أو صادر")
        lines.append({"account": l.account, "debit": round(l.debit, 2), "credit": round(l.credit, 2)})
    total = sum(x["debit"] for x in lines)
    if abs(total - sum(x["credit"] for x in lines)) >= 0.01:
        raise HTTPException(422, "القيد غير متوازن")
    status = "pending_owner" if total > settings.OWNER_APPROVAL_IQD and user["role"] not in ("owner", "admin") else "posted"
    with get_conn() as conn, dict_cursor(conn) as cur:
        if body.entry_date > hr_logic.local_today(cur):
            raise HTTPException(422, "لا يمكن تسجيل تصحيح بتاريخ مستقبلي")
        eid = post_journal(cur, user, body.entry_date, body.memo.strip(), lines, status)
    return {"id": eid, "status": status}


class SimpleCorrectionIn(BaseModel):
    """Plain-language corrections finance actually needs, turned into a balanced entry by the server."""
    kind: Literal["bank_charge", "cash_expense", "opening_cash_box", "opening_bank", "tax_paid"]
    amount: float = Field(..., gt=0)
    entry_date: date
    memo: str = Field(..., min_length=3, max_length=300)


SIMPLE_KINDS = {
    "bank_charge": ("5400", "1100", "عمولة مصرفية"),
    "cash_expense": ("5400", "1050", "مصروف نقدي من الصندوق"),
    "opening_cash_box": ("1050", "3000", "رصيد افتتاحي للصندوق"),
    "opening_bank": ("1100", "3000", "رصيد افتتاحي للمصرف"),
    "tax_paid": ("2200", "1100", "تسديد ضرائب وضمان مستقطعة"),
}


@router.post("/journal/simple")
def simple_correction(body: SimpleCorrectionIn, user: dict = Depends(require_roles("finance", "owner"))):
    debit, credit, label = SIMPLE_KINDS[body.kind]
    return create_journal(JournalIn(entry_date=body.entry_date, memo=f"{label}: {body.memo}", lines=[
        JournalLineIn(account=debit, debit=body.amount), JournalLineIn(account=credit, credit=body.amount)]), user)


@router.get("/journal")
def list_journal(user: dict = Depends(finance_read)):
    with get_conn() as conn, dict_cursor(conn) as cur:
        cur.execute("""SELECT j.*, e.employee_code AS created_by_code FROM journal_entries j JOIN employees e ON e.id = j.created_by
                       ORDER BY j.posted_at DESC, j.id DESC LIMIT 200""")
        entries = cur.fetchall()
        cur.execute("SELECT * FROM journal_lines WHERE entry_id = ANY(%s) ORDER BY id", ([e["id"] for e in entries],))
        lines = cur.fetchall()
    out = []
    for e in entries:
        ls = []
        for l in lines:
            if l["entry_id"] != e["id"]:
                continue
            i, o = ledger.in_out(l["account"], _f(l["debit"]), _f(l["credit"])) if l["account"] in ledger.CHART else (0, 0)
            ls.append({"account": l["account"], "account_name": ledger.CHART.get(l["account"], ("?",))[0], "in": i, "out": o})
        out.append({"id": e["id"], "posted_at": _iso(e["posted_at"]), "memo": e["memo"], "created_by": e["created_by_code"],
                    "status": e["status"], "decision_note": e["decision_note"], "lines": ls})
    return out


@router.post("/journal/{entry_id}/reverse")
def reverse_journal(entry_id: int, user: dict = Depends(require_roles("finance", "owner"))):
    with get_conn() as conn, dict_cursor(conn) as cur:
        cur.execute("SELECT * FROM journal_entries WHERE id = %s", (entry_id,))
        e = cur.fetchone()
        if not e:
            raise HTTPException(404, "القيد غير موجود")
        if e["status"] != "posted":
            raise HTTPException(409, "لا يُعكس إلا قيد مُعتمد")
        cur.execute("SELECT 1 FROM journal_entries WHERE memo = %s", (f"عكس القيد #{entry_id}",))
        if cur.fetchone():
            raise HTTPException(409, "تم عكس هذا القيد مسبقاً")
        cur.execute("SELECT account, debit, credit FROM journal_lines WHERE entry_id = %s", (entry_id,))
        lines = [{"account": l["account"], "debit": _f(l["credit"]), "credit": _f(l["debit"])} for l in cur.fetchall()]
        eid = post_journal(cur, user, hr_logic.local_today(cur), f"عكس القيد #{entry_id}", lines)
    return {"id": eid}


# ================================================================ the water directorate's trust money (أمانة)

class RemittanceIn(BaseModel):
    amount: float = Field(..., gt=0)
    bank_ref: str = Field(..., min_length=2, max_length=80)
    source: Literal["cash", "bank"] = "bank"
    remitted_on: date | None = None
    period_from: date | None = None
    period_to: date | None = None
    note: str | None = Field(None, max_length=300)


@router.get("/trust")
def trust(user: dict = Depends(finance_read)):
    with get_conn() as conn, dict_cursor(conn) as cur:
        cur.execute("""SELECT g.*, e.employee_code AS created_by_code FROM gov_remittances g JOIN employees e ON e.id = g.created_by
                       ORDER BY g.remitted_at DESC LIMIT 200""")
        rows = cur.fetchall()
        b = ledger.balances(cur)
        today = hr_logic.local_today(cur)
        mov = ledger.period_movements(cur, today.replace(day=1), today)
    return {"held": b["2100"]["balance"], "collected_total": b["2100"]["in"], "handed_over_total": b["2100"]["out"],
            "collected_this_month": mov["2100"]["in"], "handed_over_this_month": mov["2100"]["out"],
            "cash_box": b["1050"]["balance"], "bank": b["1100"]["balance"],
            "items": [{"id": r["id"], "amount": _f(r["amount"]), "bank_ref": r["bank_ref"], "source": r["source"], "note": r["note"],
                       "period_from": _iso(r["period_from"]), "period_to": _iso(r["period_to"]),
                       "remitted_at": _iso(r["remitted_at"]), "created_by": r["created_by_code"]} for r in rows]}


@router.get("/remittances")
def remittances_compat(user: dict = Depends(finance_read)):
    t = trust(user)
    return {"due": t["held"], "bank": t["bank"], "cash_box": t["cash_box"], "government_collected_total": t["collected_total"],
            "remitted_total": t["handed_over_total"], "items": t["items"]}


@router.post("/remittances")
def create_remittance(body: RemittanceIn, user: dict = Depends(finance_only)):
    with get_conn() as conn, dict_cursor(conn) as cur:
        cur.execute("SELECT pg_advisory_xact_lock(4242)")        # one at a time
        today = hr_logic.local_today(cur)
        day = body.remitted_on or today
        if day > today:
            raise HTTPException(422, "لا يمكن تسجيل تسليم بتاريخ مستقبلي")
        b = ledger.balances(cur)
        held = b["2100"]["balance"]
        src = "1050" if body.source == "cash" else "1100"
        if body.amount > held + 0.01:
            raise HTTPException(409, f"المبلغ أكبر من أمانة دائرة الماء المحفوظة ({held:,.0f} د.ع)")
        if body.amount > b[src]["balance"] + 0.01:
            raise HTTPException(409, f"لا يكفي الرصيد في {ledger.CHART[src][0]} ({b[src]['balance']:,.0f} د.ع)")
        cur.execute(
            """INSERT INTO gov_remittances (amount, period_from, period_to, bank_ref, note, source, remitted_at, created_by)
               VALUES (%s,%s,%s,%s,%s,%s, CASE WHEN %s THEN NOW() ELSE ((%s::date)::timestamp + interval '12 hours') AT TIME ZONE %s END, %s)
               RETURNING id""",
            (body.amount, body.period_from, body.period_to, body.bank_ref.strip(), body.note, body.source, day == today,
             day, settings.APP_TIMEZONE, user["id"]),
        )
        rid = cur.fetchone()["id"]
        audit.log(cur, user["id"], "gov_remittance", "remittance", rid, {"amount": body.amount, "ref": body.bank_ref, "source": body.source})
    return {"id": rid, "held_after": round(held - body.amount, 2), "due_after": round(held - body.amount, 2)}


# ================================================================ cash differences waiting for a decision

@router.get("/differences")
def differences(user: dict = Depends(finance_read)):
    """Collector differences the supervisor escalated + supervisor differences found at headquarters."""
    with get_conn() as conn, dict_cursor(conn) as cur:
        cur.execute(
            """SELECT r.id, r.created_at, r.counted_cash, r.expected_cash, r.difference, r.status, r.resolution_status,
                      r.resolution_action, r.resolution_note, c.employee_code AS person_code, c.full_name AS person_name,
                      s.employee_code AS supervisor_code
               FROM reconciliations r JOIN employees c ON c.id = r.collector_id JOIN employees s ON s.id = r.supervisor_id
               WHERE r.resolution_status IN ('escalated','pending_owner') ORDER BY r.created_at"""
        )
        field = cur.fetchall()
        cur.execute(
            """SELECT h.id, h.created_at, h.counted_cash, h.expected_cash, h.difference, h.status, h.resolution_status,
                      h.resolution_action, h.resolution_note, s.employee_code AS person_code, s.full_name AS person_name
               FROM cash_handovers h JOIN employees s ON s.id = h.supervisor_id
               WHERE h.resolution_status IN ('pending','pending_owner') ORDER BY h.created_at"""
        )
        hq = cur.fetchall()
    def out(r, kind):
        return {"kind": kind, "id": r["id"], "person_code": r["person_code"], "person_name": r["person_name"],
                "supervisor_code": r.get("supervisor_code"), "counted_cash": _f(r["counted_cash"]),
                "expected_cash": _f(r["expected_cash"]), "difference": _f(r["difference"]), "status": r["status"],
                "resolution_status": r["resolution_status"], "resolution_action": r["resolution_action"],
                "note": r["resolution_note"], "created_at": _iso(r["created_at"]),
                "waiting_for_owner": r["resolution_status"] == "pending_owner"}
    return [out(r, "field") for r in field] + [out(r, "hq") for r in hq]


@router.get("/escalations")
def escalations(user: dict = Depends(finance_read)):
    return [{"id": d["id"], "collector_code": d["person_code"], "collector_name": d["person_name"],
             "supervisor_code": d["supervisor_code"], "counted_cash": d["counted_cash"], "expected_cash": d["expected_cash"],
             "difference": d["difference"], "resolution_status": d["resolution_status"], "resolution_note": d["note"],
             "created_at": d["created_at"]} for d in differences(user) if d["kind"] == "field"]


class CloseIn(BaseModel):
    action: Literal["salary_deduction", "write_off"]
    note: str = Field(..., min_length=3, max_length=500)


@router.post("/reconciliations/{rec_id}/close")
def close_escalation(rec_id: int, body: CloseIn, user: dict = Depends(finance_only)):
    """Finance decides an escalated collector difference: deduct from salary, or write off (owner approves large write-offs)."""
    with get_conn() as conn, dict_cursor(conn) as cur:
        cur.execute("SELECT * FROM reconciliations WHERE id = %s FOR UPDATE", (rec_id,))
        r = cur.fetchone()
        if not r or r["resolution_status"] != "escalated":
            raise HTTPException(409, "هذا الفرق غير محال أو تمت تسويته")
        if body.action == "salary_deduction" and _f(r["difference"]) >= 0:
            raise HTTPException(422, "الخصم من الراتب للنقص فقط")
        needs_owner = body.action == "write_off" and abs(_f(r["difference"])) > settings.OWNER_APPROVAL_IQD
        new_status = "pending_owner" if needs_owner else "resolved"
        note = ((r["resolution_note"] or "") + " | المالية: " + body.note).strip(" |")
        cur.execute("""UPDATE reconciliations SET resolution_status = %s, resolution_action = %s, resolution_note = %s,
                          resolved_by = %s, resolved_at = CASE WHEN %s THEN resolved_at ELSE NOW() END WHERE id = %s""",
                    (new_status, body.action, note, user["id"], needs_owner, rec_id))
        audit.log(cur, user["id"], f"reconciliation_{body.action}", "reconciliation", rec_id,
                  {"difference": str(r["difference"]), "note": body.note, "owner_approval": needs_owner})
    return {"reconciliation_id": rec_id, "resolution_status": new_status, "action": body.action}
