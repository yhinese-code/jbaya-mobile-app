"""Phase 6: the citizen messages the company WhatsApp first (free window) and then gets the code; Meta webhook;
paid-template fallback; offline registrations and readings synced later."""
import hashlib
import hmac
import json
import re
from datetime import datetime, timedelta, timezone

import pytest

from app import whatsapp
from app.config import settings
from test_flows import client, db, login, outbox  # noqa: F401

LOCS = [(33.3120 + i * 0.0007, 44.3540) for i in range(12)]


@pytest.fixture(autouse=True)
def citizen_first(monkeypatch):
    monkeypatch.setattr(settings, "CITIZEN_FIRST_MESSAGE", True)
    monkeypatch.setattr(settings, "WHATSAPP_BUSINESS_NUMBER", "9647700001111")


@pytest.fixture
def texts(monkeypatch):
    box = []
    monkeypatch.setattr(whatsapp, "send_text", lambda phone, body, kind: box.append((phone, kind, body)))
    return box


def _code(texts, phone):
    body = next(b for p, k, b in reversed(texts) if p == phone and k == "otp")
    return re.search(r"\d{6}", body).group(0)


def _inbound(client, phone, text, msg_id):
    payload = {"entry": [{"changes": [{"value": {
        "contacts": [{"wa_id": phone, "profile": {"name": "مواطن"}}],
        "messages": [{"from": phone, "id": msg_id, "type": "text", "text": {"body": text}}]}}]}]}
    return client.post("/whatsapp/webhook", content=json.dumps(payload), headers={"Content-Type": "application/json"})


def _register(client, h, i, phone):
    return client.post("/registrations", headers=h, json={
        "full_name": f"مواطن {i}", "address": f"دار {i}", "property_class": "Household", "whatsapp_phone": phone,
        "lat": LOCS[i][0], "lng": LOCS[i][1], "gps_accuracy_m": 8, "meter_status": "working"})


def test_citizen_message_first_then_free_code_and_payment(client, outbox, texts):
    h = login(client, "JB-0492")
    r = _register(client, h, 0, "07861110000").json()
    assert r["code"]["state"] == "waiting" and "9647700001111" in r["code"]["wa_link"]
    assert not outbox["otp"] and not texts                       # nothing sent, nothing paid yet
    pid = r["property_id"]
    assert client.get(f"/registrations/{pid}/code-status", headers=h).json()["state"] == "waiting"

    # the citizen sends his name (with the property code from the QR text) -> the code goes out as free text
    assert _inbound(client, "9647861110000", f"رقم العقار {r['property_code']}\nالاسم: علي", "wamid.A1").status_code == 200
    assert client.get(f"/registrations/{pid}/code-status", headers=h).json()["state"] == "sent"
    code = _code(texts, "9647861110000")
    assert "لموظف الجباية الذي أمامك" in texts[-1][2]
    assert client.post(f"/registrations/{pid}/verify", headers=h, json={"code": code}).json()["status"] == "active"
    # Meta may deliver the same message twice: handled once
    assert _inbound(client, "9647861110000", "مكرر", "wamid.A1").status_code == 200
    with db() as conn, conn.cursor() as cur:
        cur.execute("SELECT COUNT(*) FROM whatsapp_inbound WHERE wa_message_id = 'wamid.A1'")
        assert cur.fetchone()[0] == 1

    # the window is open now: the payment notice + code go out immediately and free
    texts.clear()
    b = client.post("/bills", headers=h, json={"property_id": pid, "method": "reading", "current_reading": 100,
                                               "lat": LOCS[0][0], "lng": LOCS[0][1]}).json()
    assert b["otp"]["state"] == "sent" and b["otp"]["channel"] == "free"
    kinds = [k for _, k, _ in texts]
    assert kinds == ["bill_notice", "otp"] and not outbox["otp"]
    assert "لا تدفع أكثر" in texts[0][2]
    rc = client.post(f"/bills/{b['id']}/verify", headers=h, json={"code": _code(texts, "9647861110000")})
    assert rc.status_code == 200
    assert whatsapp.window_open("9647861110000")


def test_paid_template_fallback_and_expiry(client, outbox, texts):
    h = login(client, "JB-0492")
    r = _register(client, h, 1, "07861110001").json()
    pid = r["property_id"]
    with db() as conn, conn.cursor() as cur:
        cur.execute("UPDATE citizen_code_waits SET expires_at = NOW() - INTERVAL '1 minute' WHERE property_id = %s", (pid,))
    assert client.get(f"/registrations/{pid}/code-status", headers=h).json()["state"] == "expired"
    # the citizen cannot message us: the collector sends the paid code message instead
    res = client.post(f"/registrations/{pid}/resend-otp?channel=template", headers=h).json()
    assert res["code"]["channel"] == "template" and outbox["otp"][-1][0] == "9647861110001"
    assert client.get(f"/registrations/{pid}/code-status", headers=h).json()["state"] == "sent"
    assert client.post(f"/registrations/{pid}/verify", headers=h, json={"code": outbox["otp"][-1][1]}).status_code == 200
    # a message from someone with nothing waiting starts nothing (we never message first)
    texts.clear()
    _inbound(client, "9647869999999", "مرحبا", "wamid.Z9")
    assert texts == []


def test_webhook_security(client, monkeypatch):
    monkeypatch.setattr(settings, "WHATSAPP_VERIFY_TOKEN", "my-verify-token")
    ok = client.get("/whatsapp/webhook", params={"hub.mode": "subscribe", "hub.verify_token": "my-verify-token",
                                                 "hub.challenge": "12345"})
    assert ok.status_code == 200 and ok.text == "12345"
    assert client.get("/whatsapp/webhook", params={"hub.mode": "subscribe", "hub.verify_token": "x",
                                                   "hub.challenge": "1"}).status_code == 403
    monkeypatch.setattr(settings, "WHATSAPP_APP_SECRET", "s3cret")
    raw = json.dumps({"entry": []}).encode()
    assert client.post("/whatsapp/webhook", content=raw).status_code == 403
    sig = "sha256=" + hmac.new(b"s3cret", raw, hashlib.sha256).hexdigest()
    assert client.post("/whatsapp/webhook", content=raw, headers={"X-Hub-Signature-256": sig}).status_code == 200
    # the test-only simulator: tech / command, console mode only
    assert client.post("/whatsapp/simulate-inbound", headers=login(client, "JB-0492"),
                       json={"phone": "07861110002", "text": "x"}).status_code == 403
    assert client.post("/whatsapp/simulate-inbound", headers=login(client, "TECH-01"),
                       json={"phone": "07861110002", "text": "x"}).status_code == 200
    monkeypatch.setattr(settings, "WHATSAPP_MODE", "live")
    assert client.post("/whatsapp/simulate-inbound", headers=login(client, "TECH-01"),
                       json={"phone": "07861110002", "text": "x"}).status_code == 403


def test_offline_sync(client, outbox, texts):
    h = login(client, "JB-0492")
    now = datetime.now(timezone.utc)
    reg = {"client_id": "off-reg-0001", "captured_at": (now - timedelta(hours=2)).isoformat(),
           "full_name": "مواطن دون اتصال", "address": "دار 9", "property_class": "Household",
           "whatsapp_phone": "07861110009", "lat": LOCS[9][0], "lng": LOCS[9][1], "gps_accuracy_m": 9}
    bad = dict(reg, client_id="off-reg-0002", lat=33.40, lng=44.50, whatsapp_phone="07861110010")   # outside the sector
    r = client.post("/collector/offline/sync", headers=h, json={"registrations": [reg, bad]}).json()
    ok, fail = r["registrations"]
    assert ok["ok"] and ok["status"] == "pending_otp" and "offline_capture" in ok["flags"]
    assert not fail["ok"] and fail["status_code"] == 403
    # syncing the same items again changes nothing
    again = client.post("/collector/offline/sync", headers=h, json={"registrations": [reg, bad]}).json()
    assert again["registrations"][0]["duplicate"] and again["registrations"][0]["property_id"] == ok["property_id"]
    with db() as conn, conn.cursor() as cur:
        cur.execute("SELECT COUNT(*) FROM properties WHERE citizen_id IN (SELECT id FROM citizens WHERE whatsapp_phone = '9647861110009')")
        assert cur.fetchone()[0] == 1
    # the citizen messages the company number -> the offline house is activated (the message proves the number)
    _inbound(client, "9647861110009", "علي", "wamid.OFF1")
    with db() as conn, conn.cursor() as cur:
        cur.execute("SELECT status FROM properties WHERE id = %s", (ok["property_id"],))
        assert cur.fetchone()[0] == "active"
    assert any(k == "activation" for _, k, _ in texts)

    # an offline reading becomes a bill waiting for the next visit; money is never confirmed offline
    read = {"client_id": "off-read-0001", "captured_at": (now - timedelta(minutes=30)).isoformat(),
            "property_id": ok["property_id"], "method": "reading", "current_reading": 55, "lat": LOCS[9][0], "lng": LOCS[9][1]}
    rr = client.post("/collector/offline/sync", headers=h, json={"readings": [read]}).json()["readings"][0]
    assert rr["ok"] and rr["status"] == "awaiting_otp" and "offline_capture" in rr["flags"]
    with db() as conn, conn.cursor() as cur:
        cur.execute("SELECT COUNT(*) FROM otp_challenges WHERE bill_id = %s", (rr["bill_id"],))
        assert cur.fetchone()[0] == 0
    # next visit: the window is still open, the code goes out free
    s = client.post(f"/bills/{rr['bill_id']}/send-otp", headers=h).json()
    assert s["state"] == "sent" and s["channel"] == "free"
    # clock tricks are refused
    future = dict(read, client_id="off-read-0002", captured_at=(now + timedelta(hours=3)).isoformat())
    assert not client.post("/collector/offline/sync", headers=h, json={"readings": [future]}).json()["readings"][0]["ok"]


def test_offline_house_on_route_until_confirmed(client, outbox, texts):
    h = login(client, "JB-0492")
    now = datetime.now(timezone.utc)
    reg = {"client_id": "off-reg-0100", "captured_at": (now - timedelta(hours=1)).isoformat(),
           "full_name": "بيت دون اتصال", "address": "دار 10", "property_class": "Household",
           "whatsapp_phone": "07861110100", "lat": LOCS[10][0], "lng": LOCS[10][1], "gps_accuracy_m": 9}
    pid = client.post("/collector/offline/sync", headers=h, json={"registrations": [reg]}).json()["registrations"][0]["property_id"]
    route = client.get("/collector/route", headers=h).json()["properties"]
    row = next(p for p in route if p["id"] == pid)
    assert row["needs_verification"] and route[0]["needs_verification"]
    # next visit: wait for the citizen's message; the status carries the QR link so the screen can resume
    code = client.post(f"/registrations/{pid}/resend-otp", headers=h).json()["code"]
    assert code["state"] == "waiting"
    st = client.get(f"/registrations/{pid}/code-status", headers=h).json()
    assert st["state"] == "waiting" and "wa.me/9647700001111" in st["wa_link"]
    # a bill cannot be made for a house whose number is not confirmed
    assert client.post("/bills", headers=h, json={"property_id": pid, "method": "reading", "current_reading": 1,
                                                  "lat": LOCS[10][0], "lng": LOCS[10][1]}).status_code == 409
