"""Phase 1: meter photos + OCR flag, cash-in-hand cap, collector summary/receipts, SOS,
denomination reconciliation, discrepancy resolution, bank deposits, finance verification."""
import base64

import pytest

from app.config import settings
from test_flows import INSIDE, _active_property, _pay, age_last_payment, client, db, login, outbox  # noqa: F401

# smallest valid JPEG header + filler (the server only checks the signature and size)
JPEG = base64.b64encode(b"\xff\xd8\xff\xe0" + b"\x00" * 200).decode()


@pytest.fixture(autouse=True)
def photos_required(monkeypatch):
    monkeypatch.setattr(settings, "REQUIRE_METER_PHOTO", True)


def _bill(client, h, pid, loc, reading=None, **extra):
    body = {"property_id": pid, "method": "reading" if reading is not None else "estimate",
            "current_reading": reading, "lat": loc[0], "lng": loc[1], **extra}
    return client.post("/bills", headers=h, json=body)


def test_photo_required_stored_and_ocr_flag(client, outbox):
    h, sp = login(client, "JB-0492"), login(client, "SP-01")
    loc = (33.3155, 44.3655)
    pid = _active_property(client, h, outbox, "07812340001", loc)

    no_photo = _bill(client, h, pid, loc, 100)
    assert no_photo.status_code == 422 and "تصوير" in no_photo.json()["detail"]

    bad = _bill(client, h, pid, loc, 100, photo_base64=base64.b64encode(b"not an image").decode())
    assert bad.status_code == 422

    b = _bill(client, h, pid, loc, 100, photo_base64=JPEG, ocr_reading=100.4).json()
    assert b["has_photo"] and "ocr_mismatch" not in b["flags"]
    _pay(client, h, outbox, b)
    with db() as conn, conn.cursor() as cur:
        cur.execute("SELECT photo_url FROM meter_readings WHERE property_id = %s", (pid,))
        assert cur.fetchone()[0].startswith("meters/")

    age_last_payment(pid, 30)
    b2 = _bill(client, h, pid, loc, 160, photo_base64=JPEG, ocr_reading=190).json()
    assert "ocr_mismatch" in b2["flags"] and b2["status"] == "awaiting_otp"   # flagged, not blocked
    photo = client.get(f"/bills/{b2['id']}/photo", headers=sp).json()
    assert photo["mime"] == "image/jpeg" and base64.b64decode(photo["base64"])[:3] == b"\xff\xd8\xff"
    _pay(client, h, outbox, b2)

    # estimates on a broken meter need no photo
    pid2 = _active_property(client, h, outbox, "07812340002", (33.3156, 44.3654), meter="broken")
    assert _bill(client, h, pid2, (33.3156, 44.3654)).status_code == 200


def test_summary_receipts_and_cash_cap(client, outbox, monkeypatch):
    h = login(client, "JB-0492")
    s = client.get("/collector/summary", headers=h).json()
    held = s["cash_in_hand"]
    assert s["receipts_today"] >= 2 and held > 0 and s["daily_target"] == settings.COLLECTOR_DAILY_TARGET_IQD
    receipts = client.get("/collector/receipts", headers=h).json()
    assert receipts and not receipts[0]["handed_over"]

    monkeypatch.setattr(settings, "CASH_IN_HAND_CAP_IQD", held)       # already at the cap
    loc = (33.3157, 44.3653)
    pid = _active_property(client, h, outbox, "07812340003", loc)
    blocked = _bill(client, h, pid, loc, 50, photo_base64=JPEG)
    assert blocked.status_code == 423 and "سلّم النقد" in blocked.json()["detail"]
    assert client.get("/collector/summary", headers=h).json()["cash_cap_reached"] is True


def test_sos_flow(client):
    h, sp, cmd = login(client, "JB-0492"), login(client, "SP-01"), login(client, "CMD-01")
    r = client.post("/sos", headers=h, json={"lat": 33.31, "lng": 44.36, "note": "تهديد"})
    assert r.status_code == 200
    aid = r.json()["alert_id"]
    assert client.get("/collector/summary", headers=h).json()["open_sos"]["id"] == aid
    assert any(a["id"] == aid for a in client.get("/alerts", headers=sp).json())
    assert any(a["id"] == aid for a in client.get("/alerts", headers=cmd).json())
    assert client.get("/command/overview", headers=cmd).json()["open_sos"] >= 1
    assert client.get("/alerts", headers=h).status_code == 403            # collectors can't list alerts
    assert client.post(f"/alerts/{aid}", headers=sp, json={"action": "acknowledge"}).json()["status"] == "acknowledged"
    assert client.post(f"/alerts/{aid}", headers=sp, json={"action": "acknowledge"}).status_code == 409
    assert client.post(f"/alerts/{aid}", headers=cmd, json={"action": "close", "note": "تم الوصول"}).status_code == 200
    assert client.get("/collector/summary", headers=h).json()["open_sos"] is None


def test_team_view_has_no_amounts(client):
    sp = login(client, "SP-01")
    team = client.get("/supervisor/team", headers=sp).json()
    me = next(t for t in team if t["employee_code"] == "JB-0492")
    assert me["receipts_today"] >= 2 and me["open_receipts"] >= 2
    assert not any(k for k in me if "amount" in k or "cash" in k)


def test_denominations_discrepancy_and_hq_handover(client, outbox):
    sp, fn, cmd = login(client, "SP-01"), login(client, "FN-01"), login(client, "CMD-01")
    with db() as conn, conn.cursor() as cur:
        cur.execute("SELECT SUM(total_amount)::float FROM receipts r JOIN employees e ON e.id = r.collector_id "
                    "WHERE e.employee_code = 'JB-0492' AND reconciliation_id IS NULL")
        expected = cur.fetchone()[0]

    bad_note = client.post("/supervisor/reconciliations", headers=sp,
                           json={"collector_code": "JB-0492", "denominations": {"20000": 1}})
    assert bad_note.status_code == 422
    mismatch = client.post("/supervisor/reconciliations", headers=sp,
                           json={"collector_code": "JB-0492", "denominations": {"250": 4}, "counted_cash": 5000})
    assert mismatch.status_code == 422

    # count notes that are 1,000 short
    short = expected - 1000
    notes = {}
    rest = int(short)
    for v in (50000, 25000, 10000, 5000, 1000, 500, 250):
        notes[str(v)], rest = divmod(rest, v)
    assert rest == 0
    r = client.post("/supervisor/reconciliations", headers=sp, json={"collector_code": "JB-0492", "denominations": notes}).json()
    assert r["counted_cash"] == short and r["difference"] == -1000
    assert r["status"] == "shortage" and r["resolution_status"] == "pending"

    # supervisors no longer use banks: the cash goes to finance at headquarters
    dep_body = {"amount": short, "bank_name": "مصرف الرافدين", "slip_number": "RF-778899", "slip_photo_base64": JPEG}
    assert client.post("/supervisor/deposits", headers=sp, json=dep_body).status_code == 410
    waiting = client.get("/finance/handovers/waiting", headers=fn).json()
    row = next(w for w in waiting if w["employee_code"] == "SP-01")
    assert row["unresolved"] >= 1 and not any("cash" in k or "amount" in k for k in row)     # finance counts blind
    blocked = client.post("/finance/handovers", headers=fn, json={"supervisor_code": "SP-01", "counted_cash": 1})
    assert blocked.status_code == 409          # only the shortage is waiting, and it isn't resolved yet

    wrong = client.post(f"/supervisor/reconciliations/{r['reconciliation_id']}/resolve", headers=sp,
                        json={"action": "deposit_surplus", "note": "x x x"})
    assert wrong.status_code == 422
    ok = client.post(f"/supervisor/reconciliations/{r['reconciliation_id']}/resolve", headers=sp,
                     json={"action": "collector_paid", "note": "دفع الجابي 1000 نقداً"}).json()
    assert ok["settled_cash"] == expected

    cash = client.get("/supervisor/cash", headers=sp).json()
    assert cash["cash_to_hand_over"] >= expected and cash["reconciliations_pending_resolution"] == 0

    for rec in client.get("/supervisor/reconciliations", headers=sp).json():
        if rec["resolution_status"] == "pending":
            client.post(f"/supervisor/reconciliations/{rec['id']}/resolve", headers=sp, json={"action": "escalate", "note": "للتحقيق"})
    held = client.get("/supervisor/cash", headers=sp).json()["cash_to_hand_over"]
    assert client.post("/finance/handovers", headers=sp, json={"supervisor_code": "SP-01", "counted_cash": held}).status_code == 403
    h = client.post("/finance/handovers", headers=fn, json={"supervisor_code": "SP-01", "counted_cash": held}).json()
    assert h["difference"] == 0 and h["status"] == "matched" and h["expected_cash"] == held
    assert client.get("/supervisor/cash", headers=sp).json()["cash_to_hand_over"] == 0
    assert client.post("/finance/handovers", headers=fn, json={"supervisor_code": "SP-01", "counted_cash": held}).status_code == 409
    mine = client.get("/supervisor/handovers", headers=sp).json()
    assert mine[0]["counted_cash"] == held and mine[0]["received_by"] == "FN-01"
    assert client.get("/finance/deposits", headers=fn).json()["totals"]["pending_count"] == 0    # legacy list still works


def test_surplus_escalated_to_command(client, outbox):
    h, sp, cmd = login(client, "JB-0492"), login(client, "SP-01"), login(client, "CMD-01")
    loc = (33.3158, 44.3652)
    pid = _active_property(client, h, outbox, "07812340004", loc)
    receipt = _pay(client, h, outbox, _bill(client, h, pid, loc, 10, photo_base64=JPEG).json())
    r = client.post("/supervisor/reconciliations", headers=sp,
                    json={"collector_code": "JB-0492", "counted_cash": receipt["total_amount"] + 5000}).json()
    assert r["status"] == "surplus" and r["resolution_status"] == "pending"
    assert client.post(f"/supervisor/reconciliations/{r['reconciliation_id']}/resolve", headers=sp,
                       json={"action": "collector_paid", "note": "x x x"}).status_code == 422   # only for shortages
    client.post(f"/supervisor/reconciliations/{r['reconciliation_id']}/resolve", headers=sp,
                json={"action": "escalate", "note": "فائض: احتمال استيفاء مبلغ أكبر من المواطن"})
    esc = client.get("/command/escalations", headers=cmd).json()
    assert any(e["id"] == r["reconciliation_id"] and e["difference"] == 5000 for e in esc)
    assert client.get("/command/overview", headers=cmd).json()["escalations"] >= 1


def test_audit_chain_still_valid(client):
    assert client.get("/command/audit/verify", headers=login(client, "CMD-01")).json()["valid"] is True
