"""Meta WhatsApp webhook (Phase 6): citizens' messages to the company number arrive here.

Setup in Meta (App > WhatsApp > Configuration > Webhook):
  Callback URL  https://<your domain>/whatsapp/webhook
  Verify token  the same text as WHATSAPP_VERIFY_TOKEN in .env
  Subscribe to  messages
WHATSAPP_APP_SECRET (App settings > Basic > App secret) lets the server reject anything not signed by Meta.
"""
import hashlib
import hmac
import json
from datetime import datetime, timezone

from fastapi import APIRouter, Depends, HTTPException, Query, Request
from fastapi.concurrency import run_in_threadpool
from fastapi.responses import PlainTextResponse
from pydantic import BaseModel, Field

from .. import audit, citizen_channel
from ..config import settings
from ..db import dict_cursor, get_conn
from ..security import require_roles
from ..utils import normalize_iraqi_phone

router = APIRouter(tags=["whatsapp"])


@router.get("/whatsapp/webhook", response_class=PlainTextResponse)
def verify_webhook(mode: str = Query("", alias="hub.mode"), token: str = Query("", alias="hub.verify_token"),
                   challenge: str = Query("", alias="hub.challenge")):
    if mode == "subscribe" and settings.WHATSAPP_VERIFY_TOKEN and hmac.compare_digest(token, settings.WHATSAPP_VERIFY_TOKEN):
        return challenge
    raise HTTPException(403, "verify token mismatch")


def _signature_ok(raw: bytes, header: str | None) -> bool:
    if not settings.WHATSAPP_APP_SECRET:
        # without the app secret nothing proves a call comes from Meta: refuse, except on a developer machine
        return settings.WEBHOOK_ALLOW_UNSIGNED and settings.WHATSAPP_MODE != "live"
    if not header or not header.startswith("sha256="):
        return False
    expected = hmac.new(settings.WHATSAPP_APP_SECRET.encode(), raw, hashlib.sha256).hexdigest()
    return hmac.compare_digest(header[7:], expected)


@router.post("/whatsapp/webhook")
async def receive_webhook(request: Request):
    raw = await request.body()
    if not _signature_ok(raw, request.headers.get("x-hub-signature-256")):
        raise HTTPException(403, "bad signature")
    try:
        payload = json.loads(raw or b"{}")
    except ValueError:
        return {"ok": True}
    # database work and WhatsApp calls block: run them off the event loop so other requests keep flowing
    results = await run_in_threadpool(_process, payload)
    return {"ok": True, "processed": len(results)}


def _process(payload: dict) -> list:
    results = []
    for entry in payload.get("entry", []) or []:
        for change in entry.get("changes", []) or []:
            value = change.get("value") or {}
            names = {c.get("wa_id"): (c.get("profile") or {}).get("name") for c in value.get("contacts", []) or []}
            for m in value.get("messages", []) or []:
                phone = normalize_iraqi_phone(m.get("from", "")) or m.get("from", "")
                body = (m.get("text") or {}).get("body") or (m.get("button") or {}).get("text") or ""
                try:
                    sent_at = datetime.fromtimestamp(int(m.get("timestamp")), tz=timezone.utc)
                except (TypeError, ValueError):
                    sent_at = None
                with get_conn() as conn, dict_cursor(conn) as cur:
                    results.append(citizen_channel.handle_inbound(
                        cur, phone=phone, body=body, profile_name=names.get(m.get("from")),
                        wa_message_id=m.get("id"), msg_type=m.get("type", "text"), sent_at=sent_at))
    return results


class SimulateIn(BaseModel):
    phone: str
    text: str = Field("", max_length=500)


@router.post("/whatsapp/simulate-inbound")
def simulate_inbound(body: SimulateIn, user: dict = Depends(require_roles("tech", "command"))):
    """TESTING ONLY (WhatsApp console mode): pretend a citizen sent a message, to try the flow without Meta."""
    if settings.WHATSAPP_MODE == "live":
        raise HTTPException(403, "المحاكاة متاحة في الوضع التجريبي فقط")
    phone = normalize_iraqi_phone(body.phone)
    if not phone:
        raise HTTPException(422, "رقم غير صالح")
    with get_conn() as conn, dict_cursor(conn) as cur:
        res = citizen_channel.handle_inbound(cur, phone=phone, body=body.text, profile_name="محاكاة",
                                             wa_message_id=None, msg_type="text")
        audit.log(cur, user["id"], "whatsapp_inbound_simulated", "phone", phone[-4:], {"handled": res["handled"]})
    return res
