"""Phase 4: derived general ledger (always balanced), statements, manual journal, government remittances,
closing escalated differences, overview, forecasting, Benford, anomalies, risk score, arrears aging."""
import base64
import random

import pytest

from app import fin_math
from test_flows import _active_property, _pay, client, db, login, outbox  # noqa: F401

JPEG = base64.b64encode(b"\xff\xd8\xff\xe0" + b"\x00" * 200).decode()
LOCS = [(33.3152 + i * 0.0004, 44.3661) for i in range(6)]


def _tb(client, h):
    tb = client.get("/finance/trial-balance", headers=h).json()
    assert tb["balanced"], tb
    return {a["code"]: a["balance"] for a in tb["accounts"]}, tb


def _receipts_total(col="total_amount"):
    with db() as conn, conn.cursor() as cur:
        cur.execute(f"SELECT COALESCE(SUM({col}),0)::float FROM receipts")
        return cur.fetchone()[0]


@pytest.fixture(scope="module")
def collected(client):
    """Six first-visit collections by JB-0492."""
    # outbox is function-scoped; capture codes through a local box
    from app import whatsapp
    box = []
    orig = (whatsapp.send_otp, whatsapp.send_bill_notice, whatsapp.send_receipt)
    whatsapp.send_otp = lambda phone, code: box.append(code)
    whatsapp.send_bill_notice = lambda phone, **kw: None
    whatsapp.send_receipt = lambda phone, **kw: None
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
        whatsapp.send_otp, whatsapp.send_bill_notice, whatsapp.send_receipt = orig
    return True


def test_math_benford_and_chi2():
    assert abs(fin_math.chi2_sf(15.507, 8) - 0.05) < 0.001
    good = fin_math.benford_first_digit([2 ** i for i in range(1, 300)])
    assert good["level"] == "close" and good["mad"] < 0.006
    random.seed(1)
    bad = fin_math.benford_first_digit([random.uniform(100, 999) for _ in range(600)])
    assert bad["level"] == "nonconformity"
    assert fin_math.benford_first_digit([1, 2, 3])["level"] == "insufficient"
    fake = fin_math.last_digit_test([random.randint(10, 999) * 10 for _ in range(60)])
    assert fake["suspicious"] and fake["share_0_5"] == 1.0
    real = fin_math.last_digit_test([random.randint(100, 99999) for _ in range(500)])
    assert not real["suspicious"]


def test_math_forecast_learns_weekly_pattern():
    random.seed(2)
    y = [0.0 if d % 7 == 4 else 1_000_000 + random.gauss(0, 30_000) for d in range(84)]
    r = fin_math.holt_winters(y, horizon=14)
    assert r["method"] == "holt_winters" and len(r["forecast"]) == 14
    fridays = [r["forecast"][h - 1] for h in range(1, 15) if (84 + h - 1) % 7 == 4]
    others = [r["forecast"][h - 1] for h in range(1, 15) if (84 + h - 1) % 7 != 4]
    assert max(fridays) < 0.2 * min(others)
    assert all(lo <= f <= hi for f, lo, hi in zip(r["forecast"], r["lower"], r["upper"]))
    assert fin_math.holt_winters([5, 5, 5], 3)["method"] == "average"


def test_roles(client):
    assert client.get("/finance/overview", headers=login(client, "JB-0492")).status_code == 403
    cmd = login(client, "CMD-01")
    assert client.get("/finance/risk", headers=cmd).status_code == 200
    assert client.get("/finance/trial-balance", headers=cmd).status_code == 200
    assert client.post("/finance/journal", headers=cmd, json={}).status_code in (403, 422)
    assert client.post("/finance/journal", headers=cmd, json={
        "entry_date": "2026-01-01", "memo": "test", "lines": [{"account": "1100", "debit": 1}, {"account": "3000", "credit": 1}]}
    ).status_code == 403


def test_collection_posts_to_ledger(client, collected):
    fn = login(client, "FN-01")
    bal, tb = _tb(client, fn)
    assert bal["1010"] == pytest.approx(_receipts_total())
    assert bal["2100"] == pytest.approx(_receipts_total("gov_amount"))
    assert bal["4100"] == pytest.approx(_receipts_total("company_fee"))
    assert tb["cash"]["with_collectors"] == bal["1010"]


def test_full_cash_cycle_shortage_escalation_deposit_payroll(client, collected):
    fn, sp, hr = login(client, "FN-01"), login(client, "SP-01"), login(client, "HR-01")
    expected = _receipts_total()
    rec = client.post("/supervisor/reconciliations", headers=sp,
                      json={"collector_code": "JB-0492", "counted_cash": expected - 1000}).json()
    bal, _ = _tb(client, fn)
    assert bal["1010"] == 0 and bal["1020"] == expected - 1000 and bal["1290"] == 1000

    client.post(f"/supervisor/reconciliations/{rec['reconciliation_id']}/resolve", headers=sp,
                json={"action": "escalate", "note": "الجابي ينكر العجز"})
    esc = client.get("/finance/escalations", headers=fn).json()
    assert [e["id"] for e in esc] == [rec["reconciliation_id"]]
    assert client.post(f"/finance/reconciliations/{rec['reconciliation_id']}/close", headers=fn,
                       json={"action": "salary_deduction", "note": "قرار المالية"}).status_code == 200
    assert client.post(f"/finance/reconciliations/{rec['reconciliation_id']}/close", headers=fn,
                       json={"action": "write_off", "note": "مرة ثانية"}).status_code == 409
    bal, _ = _tb(client, fn)
    assert bal["1290"] == 0 and bal["1200"] == 1000

    dep = client.post("/supervisor/deposits", headers=sp, json={
        "amount": expected - 1000, "bank_name": "الرافدين", "slip_number": "RF-1", "slip_photo_base64": JPEG}).json()
    bal, _ = _tb(client, fn)
    assert bal["1020"] == 0 and bal["1030"] == expected - 1000
    client.post(f"/finance/deposits/{dep['deposit_id']}/decision", headers=fn, json={"action": "verify", "note": "مطابق للكشف"})
    bal, tb = _tb(client, fn)
    assert bal["1030"] == 0 and bal["1100"] == expected - 1000
    assert tb["cash"]["total_cash"] == expected - 1000

    # payroll for the current month recovers the shortage from the collector's salary
    with db() as conn, conn.cursor() as cur:
        cur.execute("SELECT to_char(NOW() AT TIME ZONE 'Asia/Baghdad', 'YYYY-MM')")
        period = cur.fetchone()[0]
    assert client.post("/hr/payroll/runs", headers=hr, json={"period": period}).status_code == 200
    run = client.get(f"/hr/payroll/runs/{period}", headers=fn).json()
    slip = next(p for p in run["payslips"] if p["employee_code"] == "JB-0492")
    assert any(l["code"] == "cash_shortage" and l["amount"] == 1000 for l in slip["lines"])
    client.post(f"/hr/payroll/runs/{period}/action", headers=fn, json={"action": "approve"})
    client.post(f"/hr/payroll/runs/{period}/action", headers=fn, json={"action": "mark_paid"})
    bal2, _ = _tb(client, fn)
    assert bal2["1200"] == 0
    assert bal2["1100"] == pytest.approx(bal["1100"] - run["totals"]["net"])
    assert bal2["5100"] > 0

    stmt = client.get(f"/finance/income-statement?period={period}", headers=fn).json()
    assert stmt["total_revenue"] == pytest.approx(_receipts_total("company_fee"))
    assert stmt["net_income"] == pytest.approx(stmt["total_revenue"] - stmt["total_expenses"])
    assert stmt["pass_through"]["government_collected"] == pytest.approx(_receipts_total("gov_amount"))


def test_journal_rules_and_reversal(client, collected):
    fn = login(client, "FN-01")
    def post(lines, date_="2026-01-05"):
        return client.post("/finance/journal", headers=fn, json={"entry_date": date_, "memo": "رصيد افتتاحي", "lines": lines})
    assert post([{"account": "1100", "debit": 100}, {"account": "3000", "credit": 90}]).status_code == 422       # unbalanced
    assert post([{"account": "1010", "debit": 100}, {"account": "3000", "credit": 100}]).status_code == 422      # system account
    assert post([{"account": "1100", "debit": 100, "credit": 100}, {"account": "3000", "credit": 0}]).status_code == 422
    assert post([{"account": "1100", "debit": 1}, {"account": "3000", "credit": 1}], "2099-01-01").status_code == 422
    before, _ = _tb(client, fn)
    eid = post([{"account": "1100", "debit": 5_000_000}, {"account": "3000", "credit": 5_000_000}]).json()["id"]
    after, _ = _tb(client, fn)
    assert after["1100"] == before["1100"] + 5_000_000 and after["3000"] == 5_000_000
    assert client.post(f"/finance/journal/{eid}/reverse", headers=fn).status_code == 200
    assert client.post(f"/finance/journal/{eid}/reverse", headers=fn).status_code == 409
    back, _ = _tb(client, fn)
    assert back["1100"] == before["1100"] and back["3000"] == 0
    assert len(client.get("/finance/journal", headers=fn).json()) == 2


def test_remittance_limits(client, collected):
    fn = login(client, "FN-01")
    r = client.get("/finance/remittances", headers=fn).json()
    due, bank = r["due"], r["bank"]
    assert due > 0
    assert client.post("/finance/remittances", headers=fn, json={"amount": due + 1, "bank_ref": "TR-1"}).status_code == 409
    if bank < due:      # can't send money the bank doesn't hold
        assert client.post("/finance/remittances", headers=fn, json={"amount": due, "bank_ref": "TR-1"}).status_code == 409
    client.post("/finance/journal", headers=fn, json={"entry_date": "2026-01-05", "memo": "تمويل", "lines": [
        {"account": "1100", "debit": 50_000_000}, {"account": "3000", "credit": 50_000_000}]})
    ok = client.post("/finance/remittances", headers=fn, json={"amount": due, "bank_ref": "TR-2", "note": "توريد"})
    assert ok.status_code == 200 and ok.json()["due_after"] == 0
    bal, _ = _tb(client, fn)
    assert bal["2100"] == 0
    led = client.get("/finance/ledger?account=1100&start=2026-01-01", headers=fn).json()
    assert led["postings"][-1]["balance"] == pytest.approx(bal["1100"])


def test_overview_risk_anomalies_aging(client, collected):
    fn = login(client, "FN-01")
    ov = client.get("/finance/overview", headers=fn).json()
    assert ov["kpis"]["mtd"]["total"] == pytest.approx(_receipts_total())
    assert ov["kpis"]["active_properties"] >= 6 and len(ov["series"]) == 30
    assert any(s["code"] == "S-01" for s in ov["sectors"])

    risk = client.get("/finance/risk", headers=fn).json()
    row = next(c for c in risk["collectors"] if c["employee_code"] == "JB-0492")
    assert 0 <= row["score"] <= 100 and row["score"] == round(sum(f["points"] for f in row["factors"]))
    assert next(f for f in row["factors"] if f["key"] == "shortage")["points"] > 0

    with db() as conn, conn.cursor() as cur:       # a receipt at 03:00 Baghdad time
        cur.execute("""UPDATE receipts SET issued_at = date_trunc('day', NOW() AT TIME ZONE 'Asia/Baghdad') AT TIME ZONE 'Asia/Baghdad'
                       + INTERVAL '3 hours' WHERE id = (SELECT MIN(id) FROM receipts)""")
    an = client.get("/finance/anomalies", headers=fn).json()
    types = {a["type"] for a in an["items"]}
    assert "off_hours" in types and "shortage" in types

    ag = client.get("/finance/aging", headers=fn).json()
    assert sum(b["properties"] for b in ag["buckets"]) == ov["kpis"]["active_properties"]
    assert ag["buckets"][0]["key"] == "0-30" and ag["buckets"][0]["properties"] >= 6

    bf = client.get("/finance/benford?dataset=gov_amount&collector=JB-0492", headers=fn).json()
    assert bf["law"]["level"] == "insufficient" and bf["collectors"][0]["collector"] == "JB-0492"


def test_forecast(client, collected):
    fn = login(client, "FN-01")
    with db() as conn, conn.cursor() as cur:     # spread history over the past weeks
        cur.execute("SELECT id FROM receipts ORDER BY id")
        ids = [r[0] for r in cur.fetchall()]
        for i, rid in enumerate(ids):
            cur.execute("UPDATE receipts SET issued_at = issued_at - (%s || ' days')::interval WHERE id = %s", (i * 3 + 1, rid))
    fc = client.get("/finance/forecast?horizon=14", headers=fn).json()
    assert fc["available"] and len(fc["forecast"]) >= 14
    assert fc["month"]["projected_low"] <= fc["month"]["projected_total"] <= fc["month"]["projected_high"]
    assert all(f["lower"] <= f["value"] <= f["upper"] for f in fc["forecast"])
    _tb(client, fn)        # still balanced after everything
