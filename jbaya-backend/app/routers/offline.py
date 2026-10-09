"""Offline field work (Phase 6). With no internet the collector can still register houses and take meter readings;
the app keeps them on the phone and sends them here when the connection is back.

- Every item has a client_id made on the phone, so a sync can be repeated safely (each item is stored once).
- The time and GPS position are the ones recorded on the phone; the same rules as live work are applied with them
  (geofence, distance to the house, photo, switches) and the item is flagged `offline_capture`
  (`offline_late_sync` when it arrives later than OFFLINE_MAX_HOURS).
- An offline house stays "waiting for the citizen's number": it becomes active when the citizen sends any WhatsApp
  message to the company number (that proves the number), or with a normal code on the next visit.
- An offline reading becomes a bill waiting for payment: on the next visit the collector presses "send code".
  Money can never be confirmed offline.
"""
import json

import psycopg2
from datetime import datetime, timedelta, timezone

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field

from ..db import dict_cursor, get_conn
from ..fieldwork import FIELD_ROLES
from ..security import require_roles
from .collector import BillIn, RegistrationIn, create_bill_record, register_property

router = APIRouter(prefix="/collector/offline", tags=["offline"])
field = require_roles(*FIELD_ROLES)


class OfflineRegistration(RegistrationIn):
    client_id: str = Field(..., min_length=8, max_length=64)
    captured_at: datetime


class OfflineReading(BillIn):
    client_id: str = Field(..., min_length=8, max_length=64)
    captured_at: datetime


class SyncIn(BaseModel):
    registrations: list[OfflineRegistration] = Field(default_factory=list, max_length=200)
    readings: list[OfflineReading] = Field(default_factory=list, max_length=200)


def _check_time(captured_at: datetime) -> datetime:
    if captured_at.tzinfo is None:
        captured_at = captured_at.replace(tzinfo=timezone.utc)
    now = datetime.now(timezone.utc)
    if captured_at > now + timedelta(minutes=10):
        raise HTTPException(422, "وقت التسجيل في المستقبل: تأكد من ساعة الهاتف")
    if captured_at < now - timedelta(days=30):
        raise HTTPException(422, "مضى أكثر من 30 يوماً على هذا العمل، لا يمكن مزامنته")
    return captured_at


def _already(cur, client_id: str, user: dict) -> dict | None:
    cur.execute("SELECT employee_id, result FROM offline_submissions WHERE client_id = %s", (client_id,))
    r = cur.fetchone()
    if not r:
        return None
    if r["employee_id"] != user["id"]:
        return {"client_id": client_id, "ok": False, "error": "معرّف مكرر"}
    return {**r["result"], "duplicate": True}


def _record(client_id: str, user: dict, kind: str, captured_at: datetime, result: dict) -> None:
    with get_conn() as conn, conn.cursor() as cur:
        cur.execute("""INSERT INTO offline_submissions (client_id, employee_id, kind, captured_at, result)
                       VALUES (%s,%s,%s,%s,%s) ON CONFLICT (client_id) DO NOTHING""",
                    (client_id, user["id"], kind, captured_at, json.dumps(result, ensure_ascii=False)))


def _run(item, user: dict, kind: str) -> dict:
    with get_conn() as conn, dict_cursor(conn) as cur:
        done = _already(cur, item.client_id, user)
    if done:
        return done
    try:
        captured = _check_time(item.captured_at)
        with get_conn() as conn, dict_cursor(conn) as cur:
            if kind == "registration":
                prop = register_property(conn, cur, user, item, captured_at=captured)
                result = {"client_id": item.client_id, "ok": True, "property_id": prop["id"],
                          "property_code": prop["property_code"], "status": "pending_otp", "flags": prop["flags"]}
            else:
                bill, p = create_bill_record(conn, cur, user, item, captured_at=captured)
                result = {"client_id": item.client_id, "ok": True, "bill_id": bill["id"], "property_code": p["property_code"],
                          "status": bill["status"], "total_amount": float(bill["total_amount"]), "flags": bill["flags"]}
            cur.execute("""INSERT INTO offline_submissions (client_id, employee_id, kind, captured_at, result)
                           VALUES (%s,%s,%s,%s,%s)""",
                        (item.client_id, user["id"], kind, captured, json.dumps(result, ensure_ascii=False)))
        return result
    except psycopg2.IntegrityError:
        # the same item arrived twice at the same moment: the other request stored it
        with get_conn() as conn, dict_cursor(conn) as cur:
            done = _already(cur, item.client_id, user)
        return done or {"client_id": item.client_id, "ok": False, "error": "أعد المزامنة", "retry": True}
    except HTTPException as e:
        temporary = e.status_code == 423 or (e.status_code == 409 and "مراجعة" in str(e.detail))
        if not temporary and e.status_code in (401, 403, 404, 409, 413, 422):
            # a rule refused it: remember the answer so the phone stops retrying and shows the reason
            result = {"client_id": item.client_id, "ok": False, "error": e.detail, "status_code": e.status_code}
            _record(item.client_id, user, kind, datetime.now(timezone.utc), result)
            return result
        # switched off for now / waiting for a supervisor / server trouble: the phone keeps it and tries again later
        return {"client_id": item.client_id, "ok": False, "error": e.detail, "retry": True}


@router.post("/sync")
def sync(body: SyncIn, user: dict = Depends(field)):
    """Registrations first (oldest first), then readings. Each item succeeds or fails on its own."""
    regs = [_run(r, user, "registration") for r in sorted(body.registrations, key=lambda x: x.captured_at)]
    reads = [_run(r, user, "reading") for r in sorted(body.readings, key=lambda x: x.captured_at)]
    return {"registrations": regs, "readings": reads,
            "synced": sum(1 for r in regs + reads if r.get("ok")), "failed": sum(1 for r in regs + reads if not r.get("ok"))}
