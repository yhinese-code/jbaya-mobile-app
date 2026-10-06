"""Phase 2: Command two-factor login, live tracking + security events, live feed, trail, sectors,
leaderboard, health, messages."""
from datetime import datetime, timedelta, timezone

import pytest

from app import whatsapp
from app.config import settings
from test_flows import INSIDE, PWD, _active_property, _pay, client, db, login, outbox  # noqa: F401


@pytest.fixture(autouse=True)
def geofence_on(monkeypatch):
    monkeypatch.setattr(settings, "ENFORCE_GEOFENCE", True)
    monkeypatch.setattr(settings, "REQUIRE_METER_PHOTO", False)


def _t(minutes_ago: float) -> str:
    return (datetime.now(timezone.utc) - timedelta(minutes=minutes_ago)).isoformat()


def test_command_two_factor(client, outbox):
    r = client.post("/auth/login", json={"employee_code": "CMD-01", "password": PWD}).json()
    assert r["two_factor_required"] and "token" not in r and r["phone_masked"].endswith("0001")
    code = outbox["otp"][-1][1]
    assert outbox["otp"][-1][0] == "9647700000001"
    wrong = client.post("/auth/verify-2fa", json={"challenge_id": r["challenge_id"], "code": "000000" if code != "000000" else "111111"})
    assert wrong.status_code == 400 and "المتبقية" in wrong.json()["detail"]
    ok = client.post("/auth/verify-2fa", json={"challenge_id": r["challenge_id"], "code": code})
    assert ok.status_code == 200 and ok.json()["user"]["role"] == "command"
    # a challenge can be used once
    assert client.post("/auth/verify-2fa", json={"challenge_id": r["challenge_id"], "code": code}).status_code == 400

    # a token issued without the second step is rejected for Command
    from app.security import create_token
    with db() as conn, conn.cursor() as cur:
        cur.execute("SELECT id, role FROM employees WHERE employee_code = 'CMD-01'")
        emp_id, role = cur.fetchone()
    no_mfa = create_token({"id": emp_id, "role": role}, mfa=False)
    assert client.get("/command/overview", headers={"Authorization": f"Bearer {no_mfa}"}).status_code == 401

    # collectors are not affected
    r = client.post("/auth/login", json={"employee_code": "JB-0492", "password": PWD}).json()
    assert "token" in r


def test_command_ip_allowlist(client, monkeypatch):
    monkeypatch.setattr(settings, "COMMAND_IP_ALLOWLIST", ["10.0.0.0/8"])
    r = client.post("/auth/login", json={"employee_code": "CMD-01", "password": PWD})
    assert r.status_code == 403


def test_tracking_events(client, outbox):
    h = login(client, "JB-0492")
    ok = client.post("/tracking/ping", headers=h, json={"points": [
        {"lat": INSIDE[0], "lng": INSIDE[1], "accuracy_m": 8, "recorded_at": _t(10)},
        {"lat": INSIDE[0] + 0.0005, "lng": INSIDE[1], "accuracy_m": 8, "recorded_at": _t(9)},
    ]}).json()
    assert ok["accepted"] == 2 and ok["events"] == []

    # leaves the sector (33.35 is north of the S-01 polygon), then 'teleports' 20 km in one minute
    r = client.post("/tracking/ping", headers=h, json={"points": [
        {"lat": 33.3400, "lng": 44.3661, "accuracy_m": 10, "recorded_at": _t(7)},
        {"lat": 33.3410, "lng": 44.3661, "accuracy_m": 10, "recorded_at": _t(6)},       # still outside: no 2nd event
        {"lat": 33.5200, "lng": 44.3661, "accuracy_m": 10, "recorded_at": _t(5)},
        {"lat": INSIDE[0], "lng": INSIDE[1], "accuracy_m": 10, "is_mocked": True, "recorded_at": _t(1)},
    ]}).json()
    assert r["events"].count("geofence_exit") == 1
    assert "impossible_speed" in r["events"] and "mock_location" in r["events"]

    # stale and duplicate fixes are ignored
    stale = client.post("/tracking/ping", headers=h, json={"points": [
        {"lat": INSIDE[0], "lng": INSIDE[1], "recorded_at": _t(60 * 30)},   # older than 24 h
        {"lat": INSIDE[0], "lng": INSIDE[1], "recorded_at": _t(3)},         # older than the last fix
        {"lat": INSIDE[0], "lng": INSIDE[1], "recorded_at": _t(-30)},       # 30 min in the future
    ]}).json()
    assert stale["accepted"] == 0

    assert client.post("/tracking/ping", headers=login(client, "FN-01"),
                       json={"points": [{"lat": 1, "lng": 1}]}).status_code == 403


def test_live_feed_trail(client, outbox):
    h, cmd = login(client, "JB-0492"), login(client, "CMD-01")
    loc = INSIDE
    pid = _active_property(client, h, outbox, "07899990001", loc)
    receipt = _pay(client, h, outbox, client.post("/bills", headers=h, json={
        "property_id": pid, "method": "reading", "current_reading": 100, "lat": loc[0], "lng": loc[1]}).json())
    client.post("/sos", headers=h, json={"lat": loc[0], "lng": loc[1], "note": "test"})

    live = client.get("/command/live", headers=cmd).json()
    me = next(x for x in live if x["employee_code"] == "JB-0492")
    assert me["status"] == "sos" and me["lat"] is not None and me["collected_today"] == receipt["total_amount"]
    assert me["cash_in_hand"] >= receipt["total_amount"] and me["is_mocked"] is True

    feed = client.get("/command/feed", headers=cmd).json()
    actions = [f["action"] for f in feed]
    for a in ("sos", "impossible_speed", "geofence_exit", "mock_location", "payment_verified"):
        assert a in actions, a
    assert feed[0]["id"] > feed[-1]["id"]                                        # newest first
    sos = next(f for f in feed if f["action"] == "sos")
    assert sos["severity"] == "critical" and sos["lat"] == loc[0]
    newer = client.get(f"/command/feed?after_id={feed[0]['id']}", headers=cmd).json()
    assert newer == []
    high = client.get("/command/feed?min_severity=high", headers=cmd).json()
    assert all(f["severity"] in ("high", "critical") for f in high)
    assert client.get("/command/feed", headers=h).status_code == 403

    trail = client.get("/command/trail/JB-0492", headers=cmd).json()
    assert len(trail["points"]) >= 6 and trail["distance_km"] > 20
    assert trail["stops"][0]["receipt_no"] == receipt["receipt_no"] and trail["sector"]["code"] == "S-01"

    props = client.get("/command/properties", headers=cmd).json()
    assert any(p["status_color"] == "green" for p in props)


def test_sectors_leaderboard_health(client):
    cmd = login(client, "CMD-01")
    sectors = client.get("/command/sectors", headers=cmd).json()
    s1 = next(s for s in sectors if s["code"] == "S-01")
    assert s1["properties"] >= 1 and s1["paid_in_cycle"] >= 1 and 0 < s1["coverage"] <= 1 and s1["collectors"] == 1
    board = client.get("/command/leaderboard", headers=cmd).json()
    assert board[0]["employee_code"] == "JB-0492" and board[0]["collected"] > 0 and board[0]["security_events"] >= 3
    health = client.get("/command/health", headers=cmd).json()
    assert health["database"]["ok"] and health["tracking"]["last_ping"] and health["whatsapp"]["mode"] == "console"
    ov = client.get("/command/overview", headers=cmd).json()
    assert ov["online_staff"] >= 1 and ov["target_today"] == settings.COLLECTOR_DAILY_TARGET_IQD


def test_messages(client):
    cmd, h, sp = login(client, "CMD-01"), login(client, "JB-0492"), login(client, "SP-01")
    client.post("/command/messages", headers=cmd, json={"audience": "one", "employee_code": "JB-0492", "body": "توجه إلى الزقاق 14", "priority": "urgent"})
    client.post("/command/messages", headers=cmd, json={"audience": "supervisors", "body": "اجتماع الساعة 4"})
    client.post("/command/messages", headers=cmd, json={"audience": "all", "body": "تعميم عام"})
    assert client.post("/command/messages", headers=h, json={"audience": "all", "body": "x"}).status_code == 403

    inbox = client.get("/messages/inbox", headers=h).json()
    bodies = [m["body"] for m in inbox["messages"]]
    assert "توجه إلى الزقاق 14" in bodies and "تعميم عام" in bodies and "اجتماع الساعة 4" not in bodies
    assert inbox["unread"] == 2
    urgent = next(m for m in inbox["messages"] if m["priority"] == "urgent")
    client.post(f"/messages/{urgent['id']}/read", headers=h)
    assert client.get("/messages/inbox", headers=h).json()["unread"] == 1
    sp_bodies = [m["body"] for m in client.get("/messages/inbox", headers=sp).json()["messages"]]
    assert "اجتماع الساعة 4" in sp_bodies and "توجه إلى الزقاق 14" not in sp_bodies
    assert client.post(f"/messages/{urgent['id']}/read", headers=sp).status_code == 404
    sent = client.get("/command/messages", headers=cmd).json()
    assert next(m for m in sent if m["id"] == urgent["id"])["reads"] == 1


def test_admin_updates_phone(client):
    admin, hr = login(client, "ADMIN-01"), login(client, "HR-01")
    assert client.patch("/admin/employees/CMD-01", headers=hr, json={"phone": "07701112233"}).status_code == 403
    assert client.patch("/admin/employees/CMD-01", headers=admin, json={"phone": "07701112233"}).status_code == 200
    assert client.patch("/admin/employees/JB-0492", headers=hr, json={"daily_target_iqd": 750000}).status_code == 200
    with db() as conn, conn.cursor() as cur:
        cur.execute("SELECT phone FROM employees WHERE employee_code = 'CMD-01'")
        assert cur.fetchone()[0] == "9647701112233"
    assert client.get("/collector/summary", headers=login(client, "JB-0492")).json()["daily_target"] == 750000


def test_audit_chain_valid(client):
    assert client.get("/command/audit/verify", headers=login(client, "CMD-01")).json()["valid"] is True


def test_property_detail(client):
    cmd = login(client, "CMD-01")
    props = client.get("/command/properties", headers=cmd).json()
    code = props[0]["property_code"]
    assert props[0]["citizen_name"]
    d = client.get(f"/command/properties/{code}", headers=cmd).json()
    assert d["property_code"] == code and d["phone_masked"].startswith("+964") and d["bills"]
    assert d["registered_by"].startswith("JB-0492")
    assert client.get("/command/properties/NOPE-1", headers=cmd).status_code == 404
