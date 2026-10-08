"""End-to-end tests of the Phase 0 flows against a real PostgreSQL database.

Run:  set TEST_DB_CONN, then  python -m pytest -q tests
WARNING: the test database is wiped on every run. Never point TEST_DB_CONN at real data.
"""
import os
import tempfile
import time

import psycopg2
import pytest

TEST_DB = os.environ.get("TEST_DB_CONN", "postgresql://postgres@localhost:5432/jbaya_test")
os.environ["DB_CONN"] = TEST_DB
os.environ["WHATSAPP_MODE"] = "console"
os.environ["OTP_RESEND_COOLDOWN_SECONDS"] = "0"
os.environ["REQUIRE_METER_PHOTO"] = "false"   # phase 1 tests switch it on
os.environ["DEVICE_APPROVAL_REQUIRED"] = "false"
os.environ["FAST_OTP_SECONDS"] = "0"
os.environ["STORAGE_DIR"] = os.path.join(tempfile.gettempdir(), "jbaya-test-storage")

from fastapi.testclient import TestClient  # noqa: E402

from app import codes, whatsapp  # noqa: E402
from app.main import app  # noqa: E402
from app import seed  # noqa: E402

INSIDE = (33.3152, 44.3661)       # inside demo sector S-01
OUTSIDE = (33.3500, 44.4200)      # outside it
PWD = "Jbaya@2026"


@pytest.fixture(scope="module")
def client():
    conn = psycopg2.connect(TEST_DB)
    conn.autocommit = True
    with conn.cursor() as cur:
        cur.execute("DROP SCHEMA public CASCADE; CREATE SCHEMA public;")
    conn.close()
    with TestClient(app) as c:
        seed.run()
        yield c


@pytest.fixture(autouse=True)
def outbox(monkeypatch):
    """Captures WhatsApp messages instead of printing them."""
    box = {"otp": [], "notice": [], "receipt": []}
    monkeypatch.setattr(whatsapp, "send_otp", lambda phone, code: box["otp"].append((phone, code)))
    monkeypatch.setattr(whatsapp, "send_bill_notice", lambda phone, **kw: box["notice"].append((phone, kw)))
    monkeypatch.setattr(whatsapp, "send_receipt", lambda phone, **kw: box["receipt"].append((phone, kw)))
    return box


def db():
    conn = psycopg2.connect(TEST_DB)
    conn.autocommit = True
    return conn


def login(client, code):
    """Logs in; for Command/admin it completes the WhatsApp two-factor step with the captured code."""
    captured = []
    original = whatsapp.send_otp
    whatsapp.send_otp = lambda phone, c: captured.append(c)
    try:
        r = client.post("/auth/login", json={"employee_code": code, "password": PWD})
    finally:
        whatsapp.send_otp = original
    assert r.status_code == 200, r.text
    if r.json().get("two_factor_required"):
        r = client.post("/auth/verify-2fa", json={"challenge_id": r.json()["challenge_id"], "code": captured[-1]})
        assert r.status_code == 200, r.text
    return {"Authorization": f"Bearer {r.json()['token']}"}


def register(client, h, outbox, phone="07801234567", lat_lng=INSIDE, meter="working", name="علي كريم"):
    r = client.post("/registrations", headers=h, json={
        "full_name": name, "address": "زقاق 12 دار 4", "property_class": "Household",
        "whatsapp_phone": phone, "lat": lat_lng[0], "lng": lat_lng[1], "gps_accuracy_m": 8, "meter_status": meter,
    })
    return r


def age_last_payment(property_id, days):
    with db() as conn, conn.cursor() as cur:
        cur.execute("UPDATE bills SET paid_at = paid_at - (%s || ' days')::interval, created_at = created_at - (%s || ' days')::interval "
                    "WHERE property_id = %s AND status = 'paid'", (days, days, property_id))


# ---------------------------------------------------------------------------

def test_login_and_roles(client):
    assert client.post("/auth/login", json={"employee_code": "JB-0492", "password": "wrong"}).status_code == 401
    h = login(client, "jb-0492")  # case-insensitive
    me = client.get("/auth/me", headers=h).json()
    assert me["role"] == "collector" and me["sector_code"] == "S-01"
    assert client.get("/collector/route").status_code == 401


def test_registration_rules(client, outbox):
    h = login(client, "JB-0492")
    assert register(client, h, outbox, phone="12345").status_code == 422
    assert register(client, h, outbox, lat_lng=OUTSIDE).status_code == 403          # geofence (server side)
    with db() as conn, conn.cursor() as cur:
        cur.execute("UPDATE employees SET phone = '9647709998887' WHERE employee_code = 'SP-01'")
    r = register(client, h, outbox, phone="07709998887")
    assert r.status_code == 403 and "موظف" in r.json()["detail"]                     # employee number blocked
    assert outbox["otp"] == []


def test_registration_otp_goes_to_citizen_only(client, outbox):
    h = login(client, "JB-0492")
    r = register(client, h, outbox)
    assert r.status_code == 200, r.text
    body = r.json()
    phone, code = outbox["otp"][-1]
    assert phone == "9647801234567"
    assert code not in r.text                     # the collector's app never receives the code
    assert body["phone_masked"].endswith("4567")

    pid = body["property_id"]
    wrong = client.post(f"/registrations/{pid}/verify", headers=h, json={"code": "000000" if code != "000000" else "111111"})
    assert wrong.status_code == 400 and "المتبقية: 2" in wrong.json()["detail"]
    ok = client.post(f"/registrations/{pid}/verify", headers=h, json={"code": code})
    assert ok.status_code == 200 and ok.json()["verification_method"] == "otp"
    # the plain code is not stored anywhere
    with db() as conn, conn.cursor() as cur:
        cur.execute("SELECT code_hash FROM otp_challenges WHERE property_id = %s", (pid,))
        assert all(code not in row[0].split("$") for row in cur.fetchall())
        cur.execute("SELECT COUNT(*) FROM whatsapp_messages WHERE preview LIKE %s", (f"%{code}%",))
        assert cur.fetchone()[0] == 0


def test_otp_locks_after_max_attempts(client, outbox):
    h = login(client, "JB-0492")
    pid = register(client, h, outbox, phone="07811112222", lat_lng=(33.3200, 44.3700)).json()["property_id"]
    code = outbox["otp"][-1][1]
    bad = "123456" if code != "123456" else "654321"
    for _ in range(3):
        last = client.post(f"/registrations/{pid}/verify", headers=h, json={"code": bad})
    assert "تجاوز" in last.json()["detail"]
    # even the right code no longer works: a new one must be requested
    assert client.post(f"/registrations/{pid}/verify", headers=h, json={"code": code}).status_code == 400
    client.post(f"/registrations/{pid}/resend-otp", headers=h)
    assert client.post(f"/registrations/{pid}/verify", headers=h, json={"code": outbox["otp"][-1][1]}).status_code == 200


def _active_property(client, h, outbox, phone, lat_lng, meter="working"):
    pid = register(client, h, outbox, phone=phone, lat_lng=lat_lng, meter=meter).json()["property_id"]
    client.post(f"/registrations/{pid}/verify", headers=h, json={"code": outbox["otp"][-1][1]})
    return pid


def _pay(client, h, outbox, bill):
    r = client.post(f"/bills/{bill['id']}/verify", headers=h, json={"code": outbox["otp"][-1][1]})
    assert r.status_code == 200, r.text
    return r.json()


def test_first_visit_estimate_then_consumption_billing(client, outbox):
    h = login(client, "JB-0492")
    loc = (33.3160, 44.3650)
    pid = _active_property(client, h, outbox, "07722223333", loc)

    # first visit: reading becomes the baseline, citizen pays the period estimate (22,500 + 3,000 fee)
    r = client.post("/bills", headers=h, json={"property_id": pid, "method": "reading", "current_reading": 1400.5,
                                                "lat": loc[0], "lng": loc[1]})
    assert r.status_code == 200, r.text
    b = r.json()
    assert b["visit_type"] == "first_visit" and b["previous_reading"] is None
    assert b["gov_amount"] == 22500 and b["company_fee"] == 3000 and b["total_amount"] == 25500
    assert outbox["notice"][-1][1]["total"] == 25500                 # citizen gets the exact amount
    assert outbox["otp"][-1][1] not in r.text
    rc = _pay(client, h, outbox, b)
    assert rc["receipt_no"].startswith("RCP-") and rc["total_amount"] == 25500
    assert outbox["receipt"][-1][1]["receipt_no"] == rc["receipt_no"]
    with db() as conn, conn.cursor() as cur:
        cur.execute("SELECT reading::float, reading_type FROM meter_readings WHERE property_id = %s", (pid,))
        assert cur.fetchall() == [(1400.5, "baseline")]

    # same day again -> refused (no double charging)
    again = client.post("/bills", headers=h, json={"property_id": pid, "method": "reading", "current_reading": 1401, "lat": loc[0], "lng": loc[1]})
    assert again.status_code == 409

    # 30 days later: (1450.5 - 1400.5) = 50 m3 x 100 = 5,000 + 3,000
    age_last_payment(pid, 30)
    b2 = client.post("/bills", headers=h, json={"property_id": pid, "method": "reading", "current_reading": 1450.5,
                                                 "lat": loc[0], "lng": loc[1]}).json()
    assert b2["visit_type"] == "periodic" and b2["consumption"] == 50 and b2["period_days"] == 30
    assert b2["gov_amount"] == 5000 and b2["total_amount"] == 8000
    _pay(client, h, outbox, b2)

    # 30 days later, 400 m3 in a month vs 50 average -> flagged, still collectable
    age_last_payment(pid, 30)
    b3 = client.post("/bills", headers=h, json={"property_id": pid, "method": "reading", "current_reading": 1850.5,
                                                 "lat": loc[0], "lng": loc[1]}).json()
    assert "high_consumption" in b3["flags"] and b3["status"] == "awaiting_otp" and b3["gov_amount"] == 40000
    _pay(client, h, outbox, b3)


def test_must_be_at_the_property(client, outbox):
    h = login(client, "JB-0492")
    loc = (33.3170, 44.3640)
    pid = _active_property(client, h, outbox, "07733334444", loc)
    far = client.post("/bills", headers=h, json={"property_id": pid, "method": "reading", "current_reading": 10,
                                                  "lat": 33.3250, "lng": 44.3750})
    assert far.status_code == 403 and "بعد" in far.json()["detail"]


def test_lower_reading_blocked_then_rebaseline(client, outbox):
    h, sp = login(client, "JB-0492"), login(client, "SP-01")
    loc = (33.3180, 44.3630)
    pid = _active_property(client, h, outbox, "07744445555", loc)
    _pay(client, h, outbox, client.post("/bills", headers=h, json={"property_id": pid, "method": "reading", "current_reading": 900, "lat": loc[0], "lng": loc[1]}).json())
    age_last_payment(pid, 45)
    sent_before = len(outbox["otp"])
    b = client.post("/bills", headers=h, json={"property_id": pid, "method": "reading", "current_reading": 15,
                                                "lat": loc[0], "lng": loc[1]}).json()
    assert b["status"] == "blocked_review" and "reading_lower_than_previous" in b["flags"]
    assert len(outbox["otp"]) == sent_before                       # nothing sent to the citizen
    assert client.post(f"/bills/{b['id']}/verify", headers=h, json={"code": "123456"}).status_code == 409

    queue = client.get("/supervisor/reviews", headers=sp).json()
    assert any(q["id"] == b["id"] and "القراءة الحالية أقل من السابقة" in q["flag_labels"] for q in queue)
    d = client.post(f"/supervisor/bills/{b['id']}/decision", headers=sp, json={"action": "rebaseline", "note": "تم تبديل العداد"})
    assert d.status_code == 200 and d.json()["status"] == "awaiting_otp"
    client.post(f"/bills/{b['id']}/send-otp", headers=h)
    _pay(client, h, outbox, b)
    with db() as conn, conn.cursor() as cur:
        cur.execute("SELECT reading::float, reading_type FROM meter_readings WHERE property_id = %s ORDER BY id DESC LIMIT 1", (pid,))
        assert cur.fetchone() == (15.0, "rebaseline")


def test_estimate_on_working_meter_needs_approval(client, outbox):
    h, sp = login(client, "JB-0492"), login(client, "SP-01")
    loc = (33.3190, 44.3620)
    pid = _active_property(client, h, outbox, "07755556666", loc)
    _pay(client, h, outbox, client.post("/bills", headers=h, json={"property_id": pid, "method": "reading", "current_reading": 500, "lat": loc[0], "lng": loc[1]}).json())
    age_last_payment(pid, 30)
    b = client.post("/bills", headers=h, json={"property_id": pid, "method": "estimate", "lat": loc[0], "lng": loc[1]}).json()
    assert b["status"] == "pending_approval"
    assert client.post("/bills", headers=h, json={"property_id": pid, "method": "estimate", "lat": loc[0], "lng": loc[1]}).status_code == 409
    client.post(f"/supervisor/bills/{b['id']}/decision", headers=sp, json={"action": "approve", "note": "العداد مكسور"})
    client.post(f"/bills/{b['id']}/send-otp", headers=h)
    assert _pay(client, h, outbox, b)["total_amount"] == 25500


def test_master_code_command_only_and_logged(client, outbox):
    h, cmd = login(client, "JB-0492"), login(client, "CMD-01")
    for role in ("SP-01", "ADMIN-01", "FN-01", "JB-0492"):
        assert client.get("/command/master-code", headers=login(client, role)).status_code == 403
    mc = client.get("/command/master-code", headers=cmd).json()
    assert len(mc["code"]) == 6 and 0 < mc["seconds_remaining"] <= 600

    loc = (33.3200, 44.3610)
    pid = register(client, h, outbox, phone="07766667777", lat_lng=loc).json()["property_id"]
    no_reason = client.post(f"/registrations/{pid}/verify", headers=h, json={"code": mc["code"], "use_master_code": True})
    assert no_reason.status_code == 422
    wrong = client.post(f"/registrations/{pid}/verify", headers=h, json={"code": "999999" if mc["code"] != "999999" else "888888",
                                                                       "use_master_code": True, "reason": "المواطن بدون واتساب"})
    assert wrong.status_code == 400
    ok = client.post(f"/registrations/{pid}/verify", headers=h, json={"code": mc["code"], "use_master_code": True,
                                                                    "reason": "المواطن بدون واتساب"})
    assert ok.status_code == 200 and ok.json()["verification_method"] == "master_code"

    uses = client.get("/command/master-code/uses", headers=cmd).json()
    assert uses["uses"][0]["reason"] == "المواطن بدون واتساب" and uses["per_collector"][0]["employee_code"] == "JB-0492"


def test_master_code_rotation_and_grace():
    t = 1_800_000_000 - (1_800_000_000 % 600)        # start of a window
    c_now = codes.master_code_for_window(t // 600)
    c_prev = codes.master_code_for_window(t // 600 - 1)
    assert c_now != c_prev
    assert codes.match_master_code(c_now, t + 5) == t // 600
    assert codes.match_master_code(c_prev, t + 30) == t // 600 - 1     # grace period
    assert codes.match_master_code(c_prev, t + 120) is None            # expired
    assert codes.match_master_code(c_now, t + 1200) is None


def test_master_code_daily_limit(client, outbox):
    h, cmd = login(client, "JB-0492"), login(client, "CMD-01")
    # earlier test already used 1; limit is 3/day
    results = []
    for i in range(3):
        loc = (33.3210 + i * 0.0005, 44.3600)
        pid = register(client, h, outbox, phone=f"0779000000{i}", lat_lng=loc).json()["property_id"]
        code = client.get("/command/master-code", headers=cmd).json()["code"]
        results.append(client.post(f"/registrations/{pid}/verify", headers=h,
                                   json={"code": code, "use_master_code": True, "reason": "لا توجد تغطية"}).status_code)
    assert results == [200, 200, 429]


def test_blind_reconciliation(client, outbox):
    sp = login(client, "SP-01")
    cols = client.get("/supervisor/collectors", headers=sp).json()
    assert cols and "expected" not in str(cols)
    with db() as conn, conn.cursor() as cur:
        cur.execute("SELECT SUM(total_amount)::float FROM receipts r JOIN employees e ON e.id = r.collector_id "
                    "WHERE e.employee_code = 'JB-0492' AND reconciliation_id IS NULL")
        expected = cur.fetchone()[0]
    r = client.post("/supervisor/reconciliations", headers=sp, json={"collector_code": "JB-0492", "counted_cash": expected - 3000})
    assert r.status_code == 200 and r.json()["status"] == "shortage" and r.json()["difference"] == -3000
    assert client.post("/supervisor/reconciliations", headers=sp, json={"collector_code": "JB-0492", "counted_cash": 0}).status_code == 409


def test_command_overview_and_receipts(client):
    cmd = login(client, "CMD-01")
    ov = client.get("/command/overview", headers=cmd).json()
    assert ov["receipts_today"] >= 5 and ov["collected_today"] > 0 and ov["master_code_uses_today"] >= 1
    rows = client.get("/command/receipts", headers=cmd).json()
    assert {"otp", "master_code"} >= {r["verification_method"] for r in rows}


def test_audit_chain_detects_tampering(client):
    cmd = login(client, "CMD-01")
    assert client.get("/command/audit/verify", headers=cmd).json()["valid"] is True
    with db() as conn, conn.cursor() as cur:
        cur.execute("UPDATE audit_log SET details = '{\"total\": \"1\"}' WHERE action = 'payment_verified' AND id = (SELECT MIN(id) FROM audit_log WHERE action = 'payment_verified')")
    assert client.get("/command/audit/verify", headers=cmd).json()["valid"] is False


def test_cors_for_flutter_web(client):
    r = client.options("/auth/login", headers={"Origin": "http://localhost:56057", "Access-Control-Request-Method": "POST"})
    assert r.headers.get("access-control-allow-origin") == "http://localhost:56057"
