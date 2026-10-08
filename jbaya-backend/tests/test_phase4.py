"""Phase 4 (reworked): the account book always balances; government money is a trust; supervisors hand cash to finance
at headquarters (blind count); cash box <-> bank; owner-only profit; owner approvals; breakeven & performance per role;
plus the analytics (forecast, Benford, anomalies, risk, arrears)."""
import random

import pytest

from app import fin_math
from app.config import settings
from test_flows import client, db, login, outbox  # noqa: F401

LOCS = [(33.3152 + i * 0.0004, 44.3661) for i in range(6)]
SHARE = 10.0


def _book(client, h):
    """{code: balance} from the plain account book (whatever this role may see)."""
    b = client.get("/finance/book", headers=h).json()
    return {a["code"]: a["balance"] for g in b["groups"] for a in g["accounts"]}, b


def _tb(client):
    tb = client.get("/finance/trial-balance", headers=login(client, "OWNER-01")).json()
    assert tb["balanced"], tb
    return {a["code"]: a["balance"] for a in tb["accounts"]}, tb


def _sum(col):
    with db() as conn, conn.cursor() as cur:
        cur.execute(f"SELECT COALESCE(SUM({col}),0)::float FROM receipts")
        return cur.fetchone()[0]


@pytest.fixture(scope="module")
def collected(client):
    """Six first-visit collections by JB-0492 with a 10% company share of the water amount."""
    from app import whatsapp
    box = []
    orig = (whatsapp.send_otp, whatsapp.send_bill_notice, whatsapp.send_receipt, settings.COMPANY_SHARE_PCT)
    whatsapp.send_otp = lambda phone, code: box.append(code)
    whatsapp.send_bill_notice = lambda phone, **kw: None
    whatsapp.send_receipt = lambda phone, **kw: None
    settings.COMPANY_SHARE_PCT = SHARE
    try:
        h = login(client, "JB-0492")
        for i, loc in enumerate(LOCS):
            r = client.post("/registrations", headers=h, json={
                "full_name": f"مواطن {i}", "address": f"دار {i}", "property_class": "Household",
                "whatsapp_phone": f"0781555000{i}", "lat": loc[0], "lng": loc[1], "gps_accuracy_m": 8, "meter_status": "working"})
            pid = r.json()["property_id"]
            client.post(f"/registrations/{pid}/verify", headers=h, json={"code": box[-1]})
            b = client.post("/bills", headers=h, json={"property_id": pid, "method": "reading", "current_reading": 100 + i,
                                                       "lat": loc[0], "lng": loc[1]}).json()
            assert client.post(f"/bills/{b['id']}/verify", headers=h, json={"code": box[-1]}).status_code == 200
    finally:
        whatsapp.send_otp, whatsapp.send_bill_notice, whatsapp.send_receipt, settings.COMPANY_SHARE_PCT = orig
    return True


# ---------------------------------------------------------------- statistics

def test_math_benford_and_chi2():
    assert abs(fin_math.chi2_sf(15.507, 8) - 0.05) < 0.001
    good = fin_math.benford_first_digit([2 ** i for i in range(1, 300)])
    assert good["level"] == "close" and good["mad"] < 0.006
    random.seed(1)
    assert fin_math.benford_first_digit([random.uniform(100, 999) for _ in range(600)])["level"] == "nonconformity"
    assert fin_math.benford_first_digit([1, 2, 3])["level"] == "insufficient"
    fake = fin_math.last_digit_test([random.randint(10, 999) * 10 for _ in range(60)])
    assert fake["suspicious"] and fake["share_0_5"] == 1.0
    assert not fin_math.last_digit_test([random.randint(100, 99999) for _ in range(500)])["suspicious"]


def test_math_forecast_learns_weekly_pattern():
    random.seed(2)
    y = [0.0 if d % 7 == 4 else 1_000_000 + random.gauss(0, 30_000) for d in range(84)]
    r = fin_math.holt_winters(y, horizon=14)
    fridays = [r["forecast"][h - 1] for h in range(1, 15) if (84 + h - 1) % 7 == 4]
    others = [r["forecast"][h - 1] for h in range(1, 15) if (84 + h - 1) % 7 != 4]
    assert r["method"] == "holt_winters" and max(fridays) < 0.2 * min(others)
    assert all(lo <= f <= hi for f, lo, hi in zip(r["forecast"], r["lower"], r["upper"]))
    assert fin_math.holt_winters([5, 5, 5], 3)["method"] == "average"


# ---------------------------------------------------------------- who sees what

def test_visibility(client, collected):
    fn, own, cmd, col, sp = (login(client, c) for c in ("FN-01", "OWNER-01", "CMD-01", "JB-0492", "SP-01"))
    assert client.get("/finance/overview", headers=col).status_code == 403
    assert client.get("/finance/risk", headers=cmd).status_code == 200
    # profit is the owner's alone
    for path in ("/finance/trial-balance", "/finance/income-statement", "/owner/summary", "/owner/approvals", "/owner/finance-log"):
        assert client.get(path, headers=fn).status_code == 403, path
        assert client.get(path, headers=own).status_code == 200, path
    assert client.get("/finance/overview", headers=fn).json()["profit_mtd"] is None
    assert client.get("/finance/overview", headers=own).json()["profit_mtd"]["income"] > 0
    # Phase 5: finance sees the company's INCOME accounts (it handles that money) but never costs, capital or profit
    book = client.get("/finance/book", headers=fn).json()["groups"]
    fin_codes = {a["code"] for g in book for a in g["accounts"]}
    assert {"4100", "4110"} <= fin_codes and not ({"3000", "5100", "5200", "5300", "5400"} & fin_codes)
    assert client.get("/finance/book/4100", headers=fn).status_code == 200
    assert client.get("/finance/book/5100", headers=fn).status_code == 403
    assert "5100" in {a["code"] for g in client.get("/finance/book", headers=own).json()["groups"] for a in g["accounts"]}
    assert client.get("/finance/book/4100", headers=own).status_code == 200
    # performance: money for finance/command/owner, houses only for supervisor and collector
    assert client.get("/performance/collectors", headers=fn).status_code == 200
    assert client.get("/performance/collectors", headers=cmd).status_code == 200
    assert client.get("/performance/collectors", headers=sp).status_code == 403
    assert client.get("/performance/collectors", headers=col).status_code == 403


def test_trust_and_company_share(client, collected):
    bal, tb = _tb(client)
    assert _sum("company_share") == pytest.approx(round(_sum("gov_amount") * SHARE / 100), abs=6)
    assert bal["1010"] == pytest.approx(_sum("total_amount"))
    assert bal["2100"] == pytest.approx(_sum("gov_amount") - _sum("company_share"))     # trust: not income, not debt
    assert bal["4110"] == pytest.approx(_sum("company_share"))
    assert bal["4100"] == pytest.approx(_sum("company_fee"))
    assert tb["cash"]["government_trust"] == bal["2100"]
    fn = login(client, "FN-01")
    t = client.get("/finance/trust", headers=fn).json()
    assert t["held"] == bal["2100"] and t["collected_this_month"] == bal["2100"]


# ---------------------------------------------------------------- the cash chain

def test_cash_chain_field_to_hq_to_bank_and_payroll(client, collected):
    fn, sp, hr, own = login(client, "FN-01"), login(client, "SP-01"), login(client, "HR-01"), login(client, "OWNER-01")
    expected = _sum("total_amount")
    rec = client.post("/supervisor/reconciliations", headers=sp,
                      json={"collector_code": "JB-0492", "counted_cash": expected - 1000}).json()
    client.post(f"/supervisor/reconciliations/{rec['reconciliation_id']}/resolve", headers=sp,
                json={"action": "escalate", "note": "الجابي ينكر"})
    diffs = client.get("/finance/differences", headers=fn).json()
    assert any(d["kind"] == "field" and d["id"] == rec["reconciliation_id"] for d in diffs)
    assert client.post(f"/finance/reconciliations/{rec['reconciliation_id']}/close", headers=fn,
                       json={"action": "salary_deduction", "note": "قرار المالية"}).json()["resolution_status"] == "resolved"

    # supervisor brings the cash; finance counts 500 short (blind)
    held = client.get("/supervisor/cash", headers=sp).json()["cash_to_hand_over"]
    assert held == expected - 1000
    h = client.post("/finance/handovers", headers=fn, json={"supervisor_code": "SP-01", "counted_cash": held - 500}).json()
    assert h["difference"] == -500 and h["resolution_status"] == "pending"
    bal, _ = _book(client, fn)
    assert bal["1020"] == 0 and bal["1050"] == held - 500 and bal["1290"] == 500
    assert client.post(f"/finance/handovers/{h['handover_id']}/resolve", headers=fn,
                       json={"action": "surplus_income", "note": "x x x"}).status_code == 422
    client.post(f"/finance/handovers/{h['handover_id']}/resolve", headers=fn,
                json={"action": "salary_deduction", "note": "يُخصم من المشرف"})
    bal, book = _book(client, fn)
    assert bal["1290"] == 0 and bal["1200"] == 1500
    assert book["cash"]["outside_hq"] == 0 and book["cash"]["cash_box"] == held - 500

    # cash box -> bank
    assert client.post("/finance/transfers", headers=fn, json={"direction": "to_bank", "amount": held}).status_code == 409
    assert client.post("/finance/transfers", headers=fn, json={"direction": "to_bank", "amount": held - 500, "reference": "R1"}).status_code == 200
    bal, _ = _book(client, fn)
    assert bal["1050"] == 0 and bal["1100"] == held - 500
    acct = client.get("/finance/book/1100?start=2026-01-01", headers=fn).json()
    assert acct["closing"] == bal["1100"] and acct["lines"][-1]["in"] == held - 500

    # payroll recovers both shortages (collector 1000 + supervisor 500)
    with db() as conn, conn.cursor() as cur:
        cur.execute("SELECT to_char(NOW() AT TIME ZONE 'Asia/Baghdad', 'YYYY-MM')")
        period = cur.fetchone()[0]
    client.post("/hr/payroll/runs", headers=hr, json={"period": period})
    run = client.get(f"/hr/payroll/runs/{period}", headers=fn).json()
    lines = {p["employee_code"]: {l["code"]: l["amount"] for l in p["lines"]} for p in run["payslips"]}
    assert lines["JB-0492"]["cash_shortage"] == 1000 and lines["SP-01"]["cash_shortage"] == 500
    client.post(f"/hr/payroll/runs/{period}/action", headers=fn, json={"action": "approve"})
    paid = client.post(f"/hr/payroll/runs/{period}/action", headers=fn, json={"action": "mark_paid", "paid_from": "bank"}).json()
    assert paid["paid_from"] == "bank"
    bal2, _ = _tb(client)
    assert bal2["1200"] == 0 and bal2["1100"] == pytest.approx(bal["1100"] - run["totals"]["net"])

    stmt = client.get(f"/finance/income-statement?period={period}", headers=own).json()
    assert stmt["total_income"] == pytest.approx(_sum("company_fee") + _sum("company_share"))
    assert stmt["profit"] == pytest.approx(stmt["total_income"] - stmt["total_costs"])
    assert stmt["trust"]["collected"] == pytest.approx(_sum("gov_amount") - _sum("company_share"))
    log = client.get("/owner/finance-log", headers=own).json()
    assert {"cash_handover", "transfer_to_bank", "payroll_mark_paid"} <= {x["action"] for x in log}


def test_owner_approves_large_write_offs_and_corrections(client, collected, monkeypatch):
    monkeypatch.setattr(settings, "OWNER_APPROVAL_IQD", 100)
    fn, sp, own, h = login(client, "FN-01"), login(client, "SP-01"), login(client, "OWNER-01"), login(client, "JB-0492")
    # a fresh collection so the supervisor has something to count
    from app import whatsapp
    box = []
    monkeypatch.setattr(whatsapp, "send_otp", lambda phone, code: box.append(code))
    monkeypatch.setattr(whatsapp, "send_bill_notice", lambda phone, **kw: None)
    monkeypatch.setattr(whatsapp, "send_receipt", lambda phone, **kw: None)
    loc = (33.3190, 44.3700)
    pid = client.post("/registrations", headers=h, json={"full_name": "مواطن موافقة", "address": "دار 9", "property_class": "Household",
                                                         "whatsapp_phone": "07815550099", "lat": loc[0], "lng": loc[1],
                                                         "gps_accuracy_m": 8, "meter_status": "working"}).json()["property_id"]
    client.post(f"/registrations/{pid}/verify", headers=h, json={"code": box[-1]})
    b = client.post("/bills", headers=h, json={"property_id": pid, "method": "reading", "current_reading": 50, "lat": loc[0], "lng": loc[1]}).json()
    client.post(f"/bills/{b['id']}/verify", headers=h, json={"code": box[-1]})
    rec = client.post("/supervisor/reconciliations", headers=sp, json={"collector_code": "JB-0492", "counted_cash": b["total_amount"] - 2000}).json()
    client.post(f"/supervisor/reconciliations/{rec['reconciliation_id']}/resolve", headers=sp, json={"action": "escalate", "note": "x x x"})
    r = client.post(f"/finance/reconciliations/{rec['reconciliation_id']}/close", headers=fn, json={"action": "write_off", "note": "مبلغ صغير"}).json()
    assert r["resolution_status"] == "pending_owner"
    before, _ = _tb(client)
    assert before["1290"] == 2000
    waiting = client.get("/owner/approvals", headers=own).json()
    assert any(a["kind"] == "reconciliation" and a["id"] == rec["reconciliation_id"] and a["amount"] == 2000 for a in waiting)
    assert client.post(f"/owner/approvals/reconciliation/{rec['reconciliation_id']}", headers=fn, json={"action": "approve"}).status_code == 403
    client.post(f"/owner/approvals/reconciliation/{rec['reconciliation_id']}", headers=own, json={"action": "approve", "note": "موافق"})
    after, _ = _tb(client)
    assert after["1290"] == 0 and after["5300"] == before["5300"] + 2000

    # a large manual correction waits; rejected it never touches the book
    j = client.post("/finance/journal/simple", headers=fn, json={"kind": "bank_charge", "amount": 5000, "entry_date": "2026-01-05",
                                                                "memo": "عمولة"}).json()
    assert j["status"] == "pending_owner"
    assert _tb(client)[0]["1100"] == after["1100"]
    client.post(f"/owner/approvals/journal/{j['id']}", headers=own, json={"action": "reject", "note": "بلا وصل"})
    assert client.post(f"/owner/approvals/journal/{j['id']}", headers=own, json={"action": "approve"}).status_code == 409
    assert _tb(client)[0]["1100"] == after["1100"]
    small = client.post("/finance/journal/simple", headers=fn, json={"kind": "bank_charge", "amount": 50, "entry_date": "2026-01-05",
                                                                    "memo": "عمولة صغيرة"}).json()
    assert small["status"] == "posted" and _tb(client)[0]["1100"] == after["1100"] - 50
    assert client.post(f"/finance/journal/{small['id']}/reverse", headers=fn).status_code == 200
    assert client.post(f"/finance/journal/{small['id']}/reverse", headers=fn).status_code == 409


def test_journal_rules(client, collected):
    fn = login(client, "FN-01")
    def post(lines):
        return client.post("/finance/journal", headers=fn, json={"entry_date": "2026-01-05", "memo": "تصحيح", "lines": lines})
    assert post([{"account": "1100", "debit": 100}, {"account": "3000", "credit": 90}]).status_code == 422
    assert post([{"account": "1010", "debit": 100}, {"account": "3000", "credit": 100}]).status_code == 422
    assert post([{"account": "2100", "debit": 100}, {"account": "1100", "credit": 100}]).status_code == 422    # trust is automatic
    assert client.post("/finance/journal/simple", headers=fn, json={"kind": "opening_bank", "amount": 1, "entry_date": "2099-01-01",
                                                                   "memo": "x x x"}).status_code == 422


def test_trust_handover_limits(client, collected):
    fn = login(client, "FN-01")
    t = client.get("/finance/trust", headers=fn).json()
    held = t["held"]
    assert held > 0
    assert client.post("/finance/remittances", headers=fn, json={"amount": held + 1, "bank_ref": "T1"}).status_code == 409
    pending = client.post("/finance/journal/simple", headers=fn, json={"kind": "opening_cash_box", "amount": 50_000_000,
                                                                      "entry_date": "2026-01-05", "memo": "رصيد"}).json()
    assert pending["status"] == "pending_owner"                       # above the approval limit
    assert client.post("/finance/remittances", headers=fn, json={"amount": held, "bank_ref": "T1", "source": "cash"}).status_code == 409
    client.post(f"/owner/approvals/journal/{pending['id']}", headers=login(client, "OWNER-01"), json={"action": "approve"})
    ok = client.post("/finance/remittances", headers=fn, json={"amount": held, "bank_ref": "T2", "source": "cash"})
    assert ok.status_code == 200 and ok.json()["held_after"] == 0
    assert client.get("/finance/trust", headers=fn).json()["held"] == 0


# ---------------------------------------------------------------- performance

def test_performance_per_role(client, collected):
    fn, sp, col = login(client, "FN-01"), login(client, "SP-01"), login(client, "JB-0492")
    money = client.get("/performance/collectors", headers=fn).json()
    me = next(c for c in money["collectors"] if c["employee_code"] == "JB-0492")
    assert me["earnings"] > 0 and me["daily_fixed_cost"] > 0 and me["breakeven_receipts_per_day"] >= 1
    assert me["net"] == me["earnings"] - me["cost"]
    assert all(d["status"] in ("profitable", "losing", "leave", "today", "extra") for d in me["days"])

    team = client.get("/supervisor/performance", headers=sp).json()
    row = next(c for c in team["collectors"] if c["employee_code"] == "JB-0492")
    money_words = ("earn", "cost", "net", "amount", "iqd")
    assert not any(w in k for k in row for w in money_words) and row["daily_target"] == me["breakeven_receipts_per_day"]
    assert row["label"]

    coach = client.get("/collector/coach", headers=col).json()
    assert not any(w in k for k in coach for w in money_words)
    # Phase 5: no numbers at all for the collector, only a status and plain messages
    assert coach["status"] in ("on_track", "behind", "underperforming") and coach["messages"]
    assert not any(isinstance(v, (int, float)) and not isinstance(v, bool) for v in coach.values())
    assert not any(ch.isdigit() for m in coach["messages"] for ch in m["text"])
    assert team["banner"]["title"]
    assert client.get("/collector/coach", headers=sp).status_code == 200      # supervisors collect too

    own = client.get("/owner/performance", headers=login(client, "OWNER-01")).json()
    assert own["company"]["monthly_staff_cost"] > 0 and own["company"]["receipts_needed_month"] >= 1


def test_losing_streak_flag(client, collected, monkeypatch):
    """A collector with no receipts on past working days builds a losing streak and is flagged everywhere."""
    from datetime import timedelta
    from app import hr_logic
    with db() as conn, conn.cursor() as cur:
        cur.execute("SELECT (NOW() AT TIME ZONE 'Asia/Baghdad')::date")
        today = cur.fetchone()[0]
    past = [d for d in hr_logic.working_days(today.replace(day=1), today - timedelta(days=1))]
    if len(past) < 2:
        pytest.skip("too early in the month for a streak")
    monkeypatch.setattr(settings, "LOSING_STREAK_ALERT_DAYS", 2)
    fn, sp = login(client, "FN-01"), login(client, "SP-01")
    with db() as conn, conn.cursor() as cur:       # JB-0492 started at the beginning of the month and sold nothing since
        cur.execute("UPDATE employees SET hire_date = %s WHERE employee_code = 'JB-0492'", (today.replace(day=1),))
        cur.execute("""UPDATE receipts SET issued_at = date_trunc('day', NOW() AT TIME ZONE 'Asia/Baghdad') AT TIME ZONE 'Asia/Baghdad'
                       + INTERVAL '10 hours' WHERE collector_id = (SELECT id FROM employees WHERE employee_code = 'JB-0492')""")
    me = next(c for c in client.get("/performance/collectors", headers=fn).json()["collectors"] if c["employee_code"] == "JB-0492")
    assert me["losing_streak"] == len(past) and me["lazy_flag"]
    row = next(c for c in client.get("/supervisor/performance", headers=sp).json()["collectors"] if c["employee_code"] == "JB-0492")
    assert row["flag"] and "متأخر" in row["label"]
    coach = client.get("/collector/coach", headers=login(client, "JB-0492")).json()
    assert any(m["level"] == "bad" for m in coach["messages"]) and coach["status"] == "underperforming"
    banner = client.get("/supervisor/performance", headers=sp).json()["banner"]
    assert banner["level"] == "bad"


# ---------------------------------------------------------------- analytics

def test_overview_risk_anomalies_aging(client, collected):
    fn = login(client, "FN-01")
    ov = client.get("/finance/overview", headers=fn).json()
    assert ov["kpis"]["mtd"]["total"] == pytest.approx(_sum("total_amount"))
    assert ov["kpis"]["company_income_mtd"] == pytest.approx(_sum("company_fee") + _sum("company_share"))
    assert ov["kpis"]["trust_mtd"] == pytest.approx(_sum("gov_amount") - _sum("company_share"))
    assert len(ov["series"]) == 30 and "government_trust" in ov["cash"]
    risk = client.get("/finance/risk", headers=fn).json()
    row = next(c for c in risk["collectors"] if c["employee_code"] == "JB-0492")
    assert 0 <= row["score"] <= 100
    with db() as conn, conn.cursor() as cur:
        cur.execute("""UPDATE receipts SET issued_at = date_trunc('day', NOW() AT TIME ZONE 'Asia/Baghdad') AT TIME ZONE 'Asia/Baghdad'
                       + INTERVAL '3 hours' WHERE id = (SELECT MIN(id) FROM receipts)""")
    types = {a["type"] for a in client.get("/finance/anomalies", headers=fn).json()["items"]}
    assert "off_hours" in types and "handover_difference" in types
    ag = client.get("/finance/aging", headers=fn).json()
    assert sum(b["properties"] for b in ag["buckets"]) == ov["kpis"]["active_properties"]


def test_forecast_and_book_still_balanced(client, collected):
    fn = login(client, "FN-01")
    with db() as conn, conn.cursor() as cur:
        cur.execute("SELECT id FROM receipts ORDER BY id")
        for i, (rid,) in enumerate(cur.fetchall()):
            cur.execute("UPDATE receipts SET issued_at = issued_at - (%s || ' days')::interval WHERE id = %s", (i * 3 + 1, rid))
    fc = client.get("/finance/forecast?horizon=14", headers=fn).json()
    assert fc["available"] and fc["month"]["projected_low"] <= fc["month"]["projected_total"] <= fc["month"]["projected_high"]
    _tb(client)
