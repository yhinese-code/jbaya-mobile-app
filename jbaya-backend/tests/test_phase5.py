"""Phase 5: tech panel (god mode), device approval instead of WhatsApp login codes, runtime settings and switches,
citizen-number protocol, supervisors in the field, leave by HR only, the 35% rule, previous bills, call-back audits."""
import base64
from datetime import date

import pytest

from app import runtime
from app.config import settings
from test_flows import INSIDE, PWD, client, db, login, outbox  # noqa: F401

LOCS = [(33.3110 + i * 0.0006, 44.3520) for i in range(20)]


@pytest.fixture(autouse=True)
def restore_settings():
    """Settings changed through the tech panel live on the shared `settings` object: put them back after each test."""
    saved = {k: getattr(settings, k) for k in runtime.REGISTRY}
    yield
    for k, v in saved.items():
        setattr(settings, k, v)
    with db() as conn, conn.cursor() as cur:
        cur.execute("DELETE FROM system_settings")
    runtime.mark_stale()


def _dev_login(client, code, device, label="هاتف"):
    return client.post("/auth/login", json={"employee_code": code, "password": PWD, "device_id": device, "device_label": label})


def _h(r):
    return {"Authorization": f"Bearer {r.json()['token']}"}


def _house(client, h, outbox, i, phone=None, account=None):
    """Registers and activates a house at LOCS[i]; returns its id."""
    loc = LOCS[i]
    body = {"full_name": f"مواطن {i}", "address": f"دار {i}", "property_class": "Household",
            "whatsapp_phone": phone or f"0782000{i:04d}", "lat": loc[0], "lng": loc[1], "gps_accuracy_m": 8,
            "meter_status": "working"}
    if account:
        body["account_no"] = account
    r = client.post("/registrations", headers=h, json=body)
    assert r.status_code == 200, r.text
    pid = r.json()["property_id"]
    assert client.post(f"/registrations/{pid}/verify", headers=h, json={"code": outbox["otp"][-1][1]}).status_code == 200
    return pid


def _collect(client, h, outbox, pid, i, reading=100):
    loc = LOCS[i]
    b = client.post("/bills", headers=h, json={"property_id": pid, "method": "reading", "current_reading": reading,
                                               "lat": loc[0], "lng": loc[1]})
    assert b.status_code == 200, b.text
    r = client.post(f"/bills/{b.json()['id']}/verify", headers=h, json={"code": outbox["otp"][-1][1]})
    assert r.status_code == 200, r.text
    return r.json()


# ---------------------------------------------------------------- devices, sessions, logins

def test_device_approval_and_binding(client, monkeypatch):
    monkeypatch.setattr(settings, "DEVICE_APPROVAL_REQUIRED", True)
    # the very first tech device is approved by itself (bootstrap)
    t = _dev_login(client, "TECH-01", "tech-laptop-0001")
    assert t.status_code == 200 and "token" in t.json(), t.text
    tech = _h(t)
    # no device id at all is refused once approval is required
    assert client.post("/auth/login", json={"employee_code": "JB-0492", "password": PWD}).status_code == 422
    # a collector's new phone waits for the tech panel
    r = _dev_login(client, "JB-0492", "phone-jb0492-aaaa")
    assert r.status_code == 200 and r.json()["device_pending"] and "token" not in r.json()
    pending = client.get("/tech/devices", headers=tech).json()
    dev = next(d for d in pending if d["employee_code"] == "JB-0492")
    assert client.post(f"/tech/devices/{dev['id']}/decision", headers=tech, json={"action": "approve"}).json()["status"] == "approved"
    col = _dev_login(client, "JB-0492", "phone-jb0492-aaaa")
    assert col.status_code == 200 and col.json()["user"]["permissions"]["collector.collect"] is True
    h = _h(col)
    assert client.get("/collector/summary", headers=h).status_code == 200
    # the same phone can never log into another account
    other = _dev_login(client, "SP-01", "phone-jb0492-aaaa")
    assert other.status_code == 403 and "مرتبط بحساب آخر" in other.json()["detail"]
    # limit: a collector may have one phone; a second one needs "replace oldest"
    _dev_login(client, "JB-0492", "phone-jb0492-bbbb")
    second = next(d for d in client.get("/tech/devices", headers=tech).json() if d["employee_code"] == "JB-0492")
    assert client.post(f"/tech/devices/{second['id']}/decision", headers=tech, json={"action": "approve"}).status_code == 409
    ok = client.post(f"/tech/devices/{second['id']}/decision", headers=tech, json={"action": "approve", "replace_oldest": True}).json()
    assert ok["replaced"] == [dev["id"]]
    assert client.get("/collector/summary", headers=h).status_code == 401          # old phone's session ended
    h2 = _h(_dev_login(client, "JB-0492", "phone-jb0492-bbbb"))
    # logging in again on the same device replaces the session; tech can end sessions; logout works
    h3 = _h(_dev_login(client, "JB-0492", "phone-jb0492-bbbb"))
    assert client.get("/collector/summary", headers=h2).status_code == 401
    assert client.post("/tech/employees/JB-0492/logout", headers=tech, json={"reason": "اختبار"}).json()["ended"] == 1
    assert client.get("/collector/summary", headers=h3).status_code == 401
    h4 = _h(_dev_login(client, "JB-0492", "phone-jb0492-bbbb"))
    assert client.post("/auth/logout", headers=h4).status_code == 200
    assert client.get("/collector/summary", headers=h4).status_code == 401
    # every session ends at the daily logout time
    exp = _dev_login(client, "JB-0492", "phone-jb0492-bbbb").json()["expires_at"]
    with db() as conn, conn.cursor() as cur:
        cur.execute("SELECT (%s::timestamptz AT TIME ZONE 'Asia/Baghdad')::time", (exp,))
        assert str(cur.fetchone()[0]) == "00:00:00"
    # only tech reaches the tech panel
    monkeypatch.setattr(settings, "DEVICE_APPROVAL_REQUIRED", False)
    assert client.get("/tech/overview", headers=login(client, "OWNER-01")).status_code == 403


def test_command_two_devices_and_ip(client, monkeypatch):
    monkeypatch.setattr(settings, "DEVICE_APPROVAL_REQUIRED", True)
    tech = _h(_dev_login(client, "TECH-01", "tech-laptop-0001"))
    for dev in ("cmd-screen-1", "cmd-screen-2", "cmd-screen-3"):
        _dev_login(client, "CMD-01", dev)
    reqs = [d for d in client.get("/tech/devices", headers=tech).json() if d["employee_code"] == "CMD-01"]
    assert len(reqs) == 3 and all(d["limit"] == 2 for d in reqs)
    ids = sorted(d["id"] for d in reqs)
    assert client.post(f"/tech/devices/{ids[0]}/decision", headers=tech, json={"action": "approve"}).status_code == 200
    assert client.post(f"/tech/devices/{ids[1]}/decision", headers=tech, json={"action": "approve"}).status_code == 200
    assert client.post(f"/tech/devices/{ids[2]}/decision", headers=tech, json={"action": "approve"}).status_code == 409
    assert client.post(f"/tech/devices/{ids[2]}/decision", headers=tech, json={"action": "reject"}).json()["status"] == "rejected"
    assert _dev_login(client, "CMD-01", "cmd-screen-3").status_code == 403
    a, b = _h(_dev_login(client, "CMD-01", "cmd-screen-1")), _h(_dev_login(client, "CMD-01", "cmd-screen-2"))
    assert client.get("/command/overview", headers=a).status_code == 200 and client.get("/command/overview", headers=b).status_code == 200
    # the tech panel sets the IP list; Command is refused from elsewhere, other roles are not affected
    assert client.post("/tech/settings/COMMAND_IP_ALLOWLIST", headers=tech, json={"value": ["10.20.0.0/16"]}).status_code == 200
    assert client.get("/command/overview", headers=a).status_code == 403
    assert _dev_login(client, "CMD-01", "cmd-screen-1").status_code == 403
    assert client.post("/tech/settings/COMMAND_IP_ALLOWLIST", headers=tech, json={"value": []}).status_code == 200


# ---------------------------------------------------------------- settings, switches, permissions

def test_settings_switches_and_permissions(client, outbox):
    tech, col, own = login(client, "TECH-01"), login(client, "JB-0492"), login(client, "OWNER-01")
    groups = client.get("/tech/settings", headers=tech).json()
    keys = {i["key"] for g in groups for i in g["items"]}
    assert {"COMPANY_FEE_IQD", "GAIN_SHARE_PCT", "INCOME_TAX_PCT", "CASH_IN_HAND_CAP_IQD", "COLLECTION_ENABLED"} <= keys
    assert client.post("/tech/settings/COMPANY_FEE_IQD", headers=tech, json={"value": -5}).status_code == 422
    assert client.post("/tech/settings/COMPANY_FEE_IQD", headers=tech, json={"value": 3500, "note": "عقد جديد"}).json()["value"] == 3500
    pid = _house(client, col, outbox, 0)
    bill = client.post("/bills", headers=col, json={"property_id": pid, "method": "reading", "current_reading": 10,
                                                    "lat": LOCS[0][0], "lng": LOCS[0][1]}).json()
    assert bill["company_fee"] == 3500
    hist = client.get("/tech/settings-history?key=COMPANY_FEE_IQD", headers=tech).json()
    assert hist[0]["new"] == 3500 and hist[0]["note"] == "عقد جديد"
    assert client.delete("/tech/settings/COMPANY_FEE_IQD", headers=tech).json()["value"] == 3000
    # only tech changes settings; the owner only those marked for him
    assert client.post("/tech/settings/COMPANY_FEE_IQD", headers=own, json={"value": 1}).status_code == 403
    mine = {s["key"] for s in client.get("/owner/settings", headers=own).json()}
    assert "OWNER_APPROVAL_IQD" in mine and "COMPANY_FEE_IQD" not in mine
    assert client.post("/owner/settings/OWNER_APPROVAL_IQD", headers=own, json={"value": 400000}).status_code == 200
    assert client.post("/owner/settings/COMPANY_FEE_IQD", headers=own, json={"value": 1}).status_code == 403
    client.post("/tech/settings/OWNER_APPROVAL_IQD/owner-editable", headers=tech, json={"allowed": False})
    assert client.post("/owner/settings/OWNER_APPROVAL_IQD", headers=own, json={"value": 300000}).status_code == 403

    # switches: global, per sector, per person
    client.post("/tech/settings/COLLECTION_ENABLED", headers=tech, json={"value": False})
    r = client.post("/bills", headers=col, json={"property_id": pid, "method": "reading", "current_reading": 10,
                                                 "lat": LOCS[0][0], "lng": LOCS[0][1]})
    assert r.status_code == 423
    client.post("/tech/settings/COLLECTION_ENABLED", headers=tech, json={"value": True})
    sector = next(s for s in client.get("/tech/sectors", headers=tech).json() if s["code"] == "S-01")
    client.patch(f"/tech/sectors/{sector['id']}", headers=tech, json={"switches": {"registration": False}})
    r = client.post("/registrations", headers=col, json={"full_name": "مواطن س", "address": "دار", "property_class": "Household",
                                                         "whatsapp_phone": "07829990001", "lat": LOCS[5][0], "lng": LOCS[5][1],
                                                         "gps_accuracy_m": 8})
    assert r.status_code == 423 and "قاطع" in r.json()["detail"]
    client.patch(f"/tech/sectors/{sector['id']}", headers=tech, json={"switches": {"registration": True}})
    client.patch("/tech/employees/JB-0492", headers=tech, json={"permissions": {"estimates": False}})
    r = client.post("/bills", headers=col, json={"property_id": pid, "method": "estimate", "lat": LOCS[0][0], "lng": LOCS[0][1]})
    assert r.status_code == 423 and "لحسابك" in r.json()["detail"]
    client.patch("/tech/employees/JB-0492", headers=tech, json={"permissions": {"estimates": None}})

    # maintenance mode: everything read-only except for tech
    client.post("/tech/settings/MAINTENANCE_MODE", headers=tech, json={"value": True})
    assert client.post("/sos", headers=col, json={}).status_code == 503
    assert client.get("/collector/summary", headers=col).status_code == 200
    client.post("/tech/settings/MAINTENANCE_MODE", headers=tech, json={"value": False})

    # the permission matrix hides a section and the API refuses it
    fn = login(client, "FN-01")
    assert client.get("/finance/gain-share", headers=fn).status_code == 200
    client.post("/tech/permissions", headers=tech, json={"role": "finance", "feature": "finance.gain_share", "allowed": False})
    assert client.get("/finance/gain-share", headers=fn).status_code == 403
    assert client.get("/auth/me", headers=fn).json()["permissions"]["finance.gain_share"] is False
    client.post("/tech/permissions", headers=tech, json={"role": "finance", "feature": "finance.gain_share", "allowed": True})

    # suspend / reactivate / password reset end sessions
    assert client.post("/tech/employees/JB-0492/suspend", headers=tech, json={"reason": "تحقيق"}).status_code == 200
    assert client.get("/collector/summary", headers=col).status_code == 401
    r = client.post("/auth/login", json={"employee_code": "JB-0492", "password": PWD})
    assert r.status_code == 403 and "تحقيق" in r.json()["detail"]
    client.post("/tech/employees/JB-0492/reactivate", headers=tech)
    client.post("/tech/employees/JB-0492/password", headers=tech, json={"new_password": "NewPass@2026"})
    assert client.post("/auth/login", json={"employee_code": "JB-0492", "password": "NewPass@2026"}).status_code == 200
    client.post("/tech/employees/JB-0492/password", headers=tech, json={"new_password": PWD})

    # tariffs, WhatsApp, fraud, audit, overview
    assert client.post("/tech/tariffs/Household", headers=tech, json={"unit_rate": 120, "monthly_estimate": 25000}).status_code == 200
    client.post("/tech/tariffs/Household", headers=tech, json={"unit_rate": 100, "monthly_estimate": 22500})
    wa = client.get("/tech/whatsapp", headers=tech).json()
    notice = next(t for t in wa["templates"] if t["key"] == "bill_notice")
    assert "لموظف الجباية الذي أمامك" in notice["text"]
    assert "لا تدفع أكثر" in next(t for t in wa["templates"] if t["key"] == "receipt")["text"]
    assert client.get("/tech/audit/verify", headers=tech).json()["valid"]
    assert client.get("/tech/overview", headers=tech).json()["switches"]["collection"] is True


# ---------------------------------------------------------------- citizen-number protocol

def test_citizen_number_protocol(client, outbox, monkeypatch):
    monkeypatch.setattr(settings, "MAX_PROPERTIES_PER_PHONE", 2)
    monkeypatch.setattr(settings, "PHONE_HARD_LIMIT_PROPERTIES", 3)
    col = login(client, "JB-0492")
    shared = "07831112233"
    for i in range(3):
        _house(client, col, outbox, i, phone=shared)
    with db() as conn, conn.cursor() as cur:
        cur.execute("""SELECT p.flags FROM properties p JOIN citizens c ON c.id = p.citizen_id
                       WHERE c.whatsapp_phone = '9647831112233' ORDER BY p.id""")
        flags = [r[0] for r in cur.fetchall()]
    assert "phone_reused_by_collector" in flags[2] and "phone_many_properties" in flags[2]
    r = client.post("/registrations", headers=col, json={"full_name": "رابع", "address": "دار", "property_class": "Household",
                                                         "whatsapp_phone": shared, "lat": LOCS[4][0], "lng": LOCS[4][1],
                                                         "gps_accuracy_m": 8})
    assert r.status_code == 403
    # a code typed instantly after sending is flagged on the bill
    monkeypatch.setattr(settings, "FAST_OTP_SECONDS", 60)
    pid = _house(client, col, outbox, 5)
    _collect(client, col, outbox, pid, 5)
    with db() as conn, conn.cursor() as cur:
        cur.execute("SELECT flags FROM bills WHERE property_id = %s AND status = 'paid'", (pid,))
        assert "fast_otp" in cur.fetchone()[0]
    fraud = client.get("/tech/fraud", headers=login(client, "TECH-01")).json()
    row = next(p for p in fraud["people"] if p["employee_code"] == "JB-0492")
    assert row["fast_otp"] >= 1 and row["phone_blocked"] == 1
    assert any(n["houses"] >= 3 for n in fraud["numbers"])


# ---------------------------------------------------------------- supervisors in the field, leave

def test_supervisor_collects_and_hands_over_with_team(client, outbox):
    sp, col, fn = login(client, "SP-01"), login(client, "JB-0492"), login(client, "FN-01")
    a = _house(client, sp, outbox, 6)
    paid_sp = _collect(client, sp, outbox, a, 6)["total_amount"]
    b = _house(client, col, outbox, 7)
    _collect(client, col, outbox, b, 7)
    with db() as conn, conn.cursor() as cur:      # everything JB-0492 still carries (earlier tests too)
        cur.execute("""SELECT SUM(total_amount)::float FROM receipts r JOIN employees e ON e.id = r.collector_id
                       WHERE e.employee_code = 'JB-0492' AND r.reconciliation_id IS NULL""")
        paid_col = cur.fetchone()[0]
    rec = client.post("/supervisor/reconciliations", headers=sp, json={"collector_code": "JB-0492", "counted_cash": paid_col}).json()
    assert rec["status"] == "matched"
    cash = client.get("/supervisor/cash", headers=sp).json()
    assert cash["own_collection"] == paid_sp and cash["cash_to_hand_over"] == paid_sp + paid_col
    waiting = client.get("/finance/handovers/waiting", headers=fn).json()
    assert any(w["employee_code"] == "SP-01" and w.get("own_collection") for w in waiting)
    h = client.post("/finance/handovers", headers=fn, json={"supervisor_code": "SP-01", "counted_cash": paid_sp + paid_col}).json()
    assert h["status"] == "matched" and h["expected_cash"] == paid_sp + paid_col
    tb = client.get("/finance/trial-balance", headers=login(client, "OWNER-01")).json()
    assert tb["balanced"]
    bal = {x["code"]: x["balance"] for x in tb["accounts"]}
    assert bal.get("1010", 0) == 0 and bal.get("1020", 0) == 0
    # supervisors appear in the performance list with the same quota and get their own card
    money = client.get("/performance/collectors", headers=fn).json()
    assert any(c["employee_code"] == "SP-01" and c["role"] == "supervisor" for c in money["collectors"])
    assert client.get("/collector/coach", headers=sp).json()["status"]


def test_leave_supervisor_only_sees(client):
    me = login(client, "JB-0492")
    from datetime import timedelta
    start = date.today() + timedelta(days=40)
    while start.weekday() == 4:
        start += timedelta(days=1)
    r = client.post("/me/leave", headers=me, json={"leave_type": "emergency", "start_date": start.isoformat(),
                                                   "end_date": start.isoformat()}).json()
    assert r["status"] == "pending_hr"
    sp = login(client, "SP-01")
    assert any(q["id"] == r["id"] for q in client.get("/hr/leave", headers=sp).json())
    assert client.post(f"/hr/leave/{r['id']}/decision", headers=sp, json={"action": "approve"}).status_code == 403
    assert client.post(f"/hr/leave/{r['id']}/decision", headers=login(client, "HR-01"),
                       json={"action": "approve"}).json()["status"] == "approved"


# ---------------------------------------------------------------- previous bills and the 35% rule

def _csv(rows: list[str]) -> str:
    return base64.b64encode(("\n".join(rows)).encode("utf-8")).decode()


def test_previous_bills_import_and_per_house_rule(client, outbox, monkeypatch):
    col, fn, sp, tech = login(client, "JB-0492"), login(client, "FN-01"), login(client, "SP-01"), login(client, "TECH-01")
    p1 = _house(client, col, outbox, 8, phone="07841110008", account="ACC-1008")
    p2 = _house(client, col, outbox, 9, phone="07841110009")
    p3 = _house(client, col, outbox, 10, phone="07841110010")
    content = _csv([
        "رقم الحساب,الهاتف,المبلغ,المدة,التاريخ",
        "ACC-1008,,15000,30,2025-11-01",        # by account no
        ",07841110009,12000,30,01/11/2025",      # by phone
        ",07849999999,9000,30,2025-11-01",       # nobody
        ",07841110009,13000,30,2025-12-01",      # same house twice
        ",07841110010,900000,30,2025-11-01",     # odd amount
        "ACC-X,,abc,30,2025-11-01",              # invalid amount
    ])
    st = client.post("/prev-bills/import", headers=fn, json={"filename": "old.csv", "content_base64": content})
    assert st.status_code == 200, st.text
    s = st.json()["summary"]
    assert s["matched"] == 4 and s["unmatched"] == 1 and s["duplicates"] == 2 and s["odd_amount"] == 1 and s["invalid"] == 1
    imp = st.json()["import_id"]
    assert client.post(f"/prev-bills/imports/{imp}/commit", headers=fn).status_code == 409        # duplicates first
    rows = client.get(f"/prev-bills/imports/{imp}?show=all", headers=fn).json()["rows"]
    dup = [r for r in rows if r["issue"] == "duplicate"]
    client.post(f"/prev-bills/imports/{imp}/rows/{dup[1]['index']}", headers=fn, json={"skip": True})
    unmatched = next(r for r in rows if r["property_id"] is None and r["issue"] != "invalid")
    client.post(f"/prev-bills/imports/{imp}/rows/{unmatched['index']}", headers=fn, json={"skip": True})
    done = client.post(f"/prev-bills/imports/{imp}/commit", headers=fn).json()
    assert done["saved"] == 3 and done["to_review"] == 1
    cov = client.get("/prev-bills/summary", headers=fn).json()
    assert cov["confirmed"] == 2 and cov["waiting"] == 1

    # the odd one is checked by the supervisor
    queue = client.get("/supervisor/prev-bills", headers=sp).json()
    odd = next(q for q in queue if q["property_code"] and q["amount"] == 900000)
    assert client.post(f"/supervisor/prev-bills/{odd['id']}/decision", headers=sp, json={"action": "reject"}).json()["status"] == "rejected"
    # at the house: no bill for p3 now -> photograph the paper bill; the collector cannot confirm his own entry... the supervisor does
    photo = base64.b64encode(b"\x89PNG\r\n\x1a\n" + b"0" * 100).decode()
    assert client.get(f"/collector/properties/{p3}/prev-bill", headers=col).json()["previous_bill"] is None
    new = client.post(f"/collector/properties/{p3}/prev-bill", headers=col,
                      json={"action": "new", "amount": 11000, "period_days": 30, "photo_base64": photo}).json()
    assert new["status"] == "pending_review"
    assert client.post(f"/supervisor/prev-bills/{new['id']}/decision", headers=sp, json={"action": "confirm"}).json()["status"] == "confirmed"
    # the imported bill for p2 differs from the paper bill -> mismatch -> supervisor keeps the field amount
    mm = client.post(f"/collector/properties/{p2}/prev-bill", headers=col,
                     json={"action": "mismatch", "amount": 12500, "photo_base64": photo}).json()
    assert mm["status"] == "mismatch"
    assert client.post(f"/supervisor/prev-bills/{mm['id']}/decision", headers=sp,
                       json={"action": "use_field_amount"}).json()["amount"] == 12500

    # per-house mode: 35% of how much the new bill is above the old one, booked on the receipt
    client.post("/tech/settings/GAIN_SHARE_MODE", headers=tech, json={"value": "per_house"})
    with db() as conn, conn.cursor() as cur:   # make the first-visit estimate period exactly 30 days and the tariff higher
        cur.execute("UPDATE tariffs SET monthly_estimate = 30000 WHERE property_class = 'Household'")
    try:
        rc = _collect(client, col, outbox, p1, 8)
    finally:
        with db() as conn, conn.cursor() as cur:
            cur.execute("UPDATE tariffs SET monthly_estimate = 22500 WHERE property_class = 'Household'")
    with db() as conn, conn.cursor() as cur:
        cur.execute("SELECT gov_amount, gain_basis, gain_share FROM receipts WHERE receipt_no = %s", (rc["receipt_no"],))
        gov, basis, share = (float(x) for x in cur.fetchone())
    assert basis == 15000 and share == round((gov - basis) * 0.35)
    tb = client.get("/finance/trial-balance", headers=login(client, "OWNER-01")).json()
    assert tb["balanced"] and next(a for a in tb["accounts"] if a["code"] == "4120")["balance"] == share
    gs = client.get("/finance/gain-share", headers=fn).json()
    assert gs["mode"] == "per_house" and gs["months"][0]["booked_per_house"] == share


def test_baseline_2025_settlement(client, outbox, monkeypatch):
    col, fn, own, tech = login(client, "JB-0492"), login(client, "FN-01"), login(client, "OWNER-01"), login(client, "TECH-01")
    pid = _house(client, col, outbox, 11)
    _collect(client, col, outbox, pid, 11)
    with db() as conn, conn.cursor() as cur:     # pretend the receipt was last month
        cur.execute("UPDATE receipts SET issued_at = date_trunc('month', NOW()) - INTERVAL '3 days'")
        # 1,000 of that month was already booked on a receipt (per-house mode earlier): it must not be counted twice
        cur.execute("UPDATE receipts SET gain_share = 0")
        cur.execute("UPDATE receipts SET gain_share = 1000 WHERE id = (SELECT MAX(id) FROM receipts)")
        cur.execute("SELECT to_char(date_trunc('month', NOW()) - INTERVAL '3 days', 'YYYY-MM'), SUM(gov_amount)::float FROM receipts")
        month, gov = cur.fetchone()
    gs = client.get("/finance/gain-share", headers=fn).json()
    assert gs["mode"] == "not_set" and not gs["confirmed"]
    assert client.post("/finance/gain-share/settle", headers=fn, json={"month": month}).status_code == 409   # mode not chosen
    client.post("/tech/settings/GAIN_SHARE_MODE", headers=tech, json={"value": "baseline_2025"})
    assert client.post("/finance/gain-share/settle", headers=fn, json={"month": month}).status_code == 409   # no baseline yet
    base = gov - 10000
    client.post("/finance/gain-share/baselines", headers=fn, json={"month": "2025-" + month[5:], "amount": base})
    def gain_balance():
        tb = client.get("/finance/trial-balance", headers=own).json()
        assert tb["balanced"]
        return next(a for a in tb["accounts"] if a["code"] == "4120")["balance"]
    before = gain_balance()
    st = client.post("/finance/gain-share/settle", headers=fn, json={"month": month}).json()
    assert st["status"] == "pending_owner" and st["amount"] == round(10000 * 0.35) - 1000
    appr = [a for a in client.get("/owner/approvals", headers=own).json() if a["kind"] == "gain_share"]
    assert appr and appr[0]["amount"] == st["amount"]
    assert client.post(f"/owner/approvals/gain_share/{st['id']}", headers=own, json={"action": "approve"}).status_code == 200
    assert gain_balance() == before + st["amount"]
    assert client.post("/finance/gain-share/settle", headers=fn, json={"month": month}).status_code == 409   # once


# ---------------------------------------------------------------- call-backs, owner's day

def test_callbacks_and_owner_today(client, outbox, monkeypatch):
    monkeypatch.setattr(settings, "CALLBACK_DAILY_SAMPLE", 50)
    col = login(client, "JB-0492")
    _collect(client, col, outbox, _house(client, col, outbox, 12), 12)
    cmd = login(client, "CMD-01")
    items = client.get("/command/callbacks", headers=cmd).json()["items"]
    assert items and all(i["status"] == "pending" for i in items)
    again = client.get("/command/callbacks", headers=cmd).json()["items"]
    assert [i["id"] for i in again] == [i["id"] for i in items]         # the sample is fixed for the day
    first = items[0]
    assert client.post(f"/command/callbacks/{first['id']}", headers=cmd, json={"status": "denied"}).status_code == 422
    assert client.post(f"/command/callbacks/{first['id']}", headers=cmd,
                       json={"status": "denied", "note": "لم يدفع شيئاً"}).status_code == 200
    with db() as conn, conn.cursor() as cur:
        cur.execute("SELECT b.flags FROM bills b JOIN receipts r ON r.bill_id = b.id WHERE r.receipt_no = %s", (first["receipt_no"],))
        assert "callback_denied" in cur.fetchone()[0]
    day = client.get("/owner/today", headers=login(client, "OWNER-01")).json()
    assert "collected" in day and day["callbacks_30_days"].get("denied") == 1 and "cost_usd" in day["whatsapp_month"]
    fraud = client.get("/tech/fraud", headers=login(client, "TECH-01")).json()
    assert fraud["callbacks"] and fraud["callbacks"][0]["status"] == "denied"


# ---------------------------------------------------------------- regressions from the Phase 5 review

def test_review_regressions(client, outbox):
    tech, fn, own = login(client, "TECH-01"), login(client, "FN-01"), login(client, "OWNER-01")
    # admin does not get the tech panel
    assert client.get("/tech/overview", headers=login(client, "ADMIN-01")).status_code == 403
    # HR cannot approve its own leave
    hr = login(client, "HR-01")
    from datetime import timedelta
    start = date.today() + timedelta(days=60)
    while start.weekday() == 4:
        start += timedelta(days=1)
    lv = client.post("/me/leave", headers=hr, json={"leave_type": "emergency", "start_date": start.isoformat(),
                                                    "end_date": start.isoformat()}).json()
    assert client.post(f"/hr/leave/{lv['id']}/decision", headers=hr, json={"action": "approve"}).status_code == 403
    # a setting reset in another worker is picked up (the row disappears -> back to the default)
    client.post("/tech/settings/CASH_IN_HAND_CAP_IQD", headers=tech, json={"value": 123})
    with db() as conn, conn.cursor() as cur:
        cur.execute("DELETE FROM system_settings WHERE key = 'CASH_IN_HAND_CAP_IQD'")
    runtime.mark_stale()
    client.get("/auth/me", headers=fn)
    assert settings.CASH_IN_HAND_CAP_IQD == runtime.default("CASH_IN_HAND_CAP_IQD")
    # the matrix is enforced on the API, not only by hiding the tab
    client.post("/tech/permissions", headers=tech, json={"role": "finance", "feature": "finance.receive", "allowed": False})
    assert client.get("/finance/handovers/waiting", headers=fn).status_code == 403
    client.post("/tech/permissions", headers=tech, json={"role": "finance", "feature": "finance.receive", "allowed": True})
    assert client.get("/finance/handovers/waiting", headers=fn).status_code == 200


def test_prev_bill_self_review_and_scope(client, outbox):
    sp, col = login(client, "SP-01"), login(client, "JB-0492")
    photo = base64.b64encode(b"\x89PNG\r\n\x1a\n" + b"0" * 100).decode()
    pid = _house(client, sp, outbox, 13)
    new = client.post(f"/collector/properties/{pid}/prev-bill", headers=sp,
                      json={"action": "new", "amount": 9000, "photo_base64": photo}).json()
    # he entered it -> he cannot confirm it
    assert client.post(f"/supervisor/prev-bills/{new['id']}/decision", headers=sp, json={"action": "confirm"}).status_code == 403
    # another supervisor outside this team cannot touch it either
    tech = login(client, "TECH-01")
    client.post("/tech/employees", headers=tech, json={"employee_code": "SP-09", "full_name": "مشرف آخر", "role": "supervisor",
                                                       "password": PWD})
    other = login(client, "SP-09")
    assert client.post(f"/supervisor/prev-bills/{new['id']}/decision", headers=other, json={"action": "confirm"}).status_code == 404
    # finance can decide it
    assert client.post(f"/supervisor/prev-bills/{new['id']}/decision", headers=login(client, "FN-01"),
                       json={"action": "confirm"}).json()["status"] == "confirmed"
    # a mismatch report leaves the confirmed amount as the basis until someone ELSE reviews it
    mm = client.post(f"/collector/properties/{pid}/prev-bill", headers=sp,
                     json={"action": "mismatch", "amount": 1000, "photo_base64": photo}).json()
    assert mm["status"] == "mismatch"
    from app import gain
    from app.db import dict_cursor, get_conn
    with get_conn() as conn, dict_cursor(conn) as cur:
        assert gain.basis_for(cur, pid, 30) == 9000
    assert client.post(f"/supervisor/prev-bills/{mm['id']}/decision", headers=sp,
                       json={"action": "use_field_amount"}).status_code == 403
    # a supervisor's own blocked/estimate bill is reviewed by a peer supervisor, never by himself
    pid2 = _house(client, sp, outbox, 14)
    b = client.post("/bills", headers=sp, json={"property_id": pid2, "method": "estimate", "lat": LOCS[14][0], "lng": LOCS[14][1]}).json()
    assert b["status"] == "pending_approval"
    assert all(r["id"] != b["id"] for r in client.get("/supervisor/reviews", headers=sp).json())
    assert any(r["id"] == b["id"] for r in client.get("/supervisor/reviews", headers=other).json())
    assert client.post(f"/supervisor/bills/{b['id']}/decision", headers=other,
                       json={"action": "approve", "note": "عداد عاطل"}).json()["status"] == "awaiting_otp"
    # a supervisor cannot confirm payment on his team member's bill
    pid3 = _house(client, col, outbox, 15)
    b3 = client.post("/bills", headers=col, json={"property_id": pid3, "method": "reading", "current_reading": 5,
                                                  "lat": LOCS[15][0], "lng": LOCS[15][1]}).json()
    assert client.post(f"/bills/{b3['id']}/verify", headers=sp, json={"code": outbox["otp"][-1][1]}).status_code == 403
