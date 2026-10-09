"""How a code reaches the citizen (Phase 6).

Citizen-first (CITIZEN_FIRST_MESSAGE, default on): the citizen sends any message (his name) to the company's WhatsApp
number. That opens Meta's free 24-hour window, and inside it the bill notice, the code and the receipt are normal text
messages that cost nothing.

    deliver_code()  window already open -> send the notice + code now as free text
                    window closed       -> remember a "wait"; the collector shows the citizen a QR / the number;
                                           when the citizen's message arrives (webhook) the code goes out for free
                    channel="template"  -> the paid authentication template, exactly as before (fallback)

The plain code is never stored and never returned to the collector's app.
"""
import re
import urllib.parse
from datetime import datetime, timedelta, timezone

from fastapi import HTTPException

from . import audit, codes, whatsapp
from .config import settings
from .utils import fmt_iqd

PROPERTY_CODE_RE = re.compile(r"BGD-\d{6}", re.IGNORECASE)


def wa_link(property_code: str) -> str:
    text = f"رقم العقار {property_code}\nالاسم: "
    return f"https://wa.me/{settings.WHATSAPP_BUSINESS_NUMBER}?text={urllib.parse.quote(text)}"


def _notice_params(cur, bill_id: int) -> tuple[str, list] | None:
    cur.execute(
        """SELECT b.total_amount, b.gov_amount, b.company_fee, p.property_code, c.full_name, c.whatsapp_phone,
                  e.employee_code
           FROM bills b JOIN properties p ON p.id = b.property_id JOIN citizens c ON c.id = p.citizen_id
           JOIN employees e ON e.id = b.collector_id WHERE b.id = %s""",
        (bill_id,),
    )
    r = cur.fetchone()
    if not r:
        return None
    return r["whatsapp_phone"], [r["full_name"], r["property_code"], fmt_iqd(float(r["total_amount"])),
                                 fmt_iqd(float(r["gov_amount"])), fmt_iqd(float(r["company_fee"])), r["employee_code"],
                                 settings.HOTLINE]


def _send_free(cur, *, purpose: str, property_id: int, bill_id: int | None, phone: str, created_by: int) -> dict:
    """Inside the window: (bill notice +) code as free text."""
    ch, code = codes.create_challenge(cur, purpose=purpose, property_id=property_id, bill_id=bill_id, phone=phone,
                                      created_by=created_by)
    if purpose == "payment" and bill_id:
        n = _notice_params(cur, bill_id)
        if n:
            whatsapp.send_text(phone, whatsapp.fill("bill_notice", n[1]), "bill_notice")
    whatsapp.send_text(phone, whatsapp.code_text(code), "otp")
    return {"state": "sent", "channel": "free", "expires_at": ch["expires_at"].isoformat(),
            "resend_after_seconds": settings.OTP_RESEND_COOLDOWN_SECONDS, "challenge_id": ch["id"]}


def deliver_code(cur, *, purpose: str, prop: dict, bill: dict | None, user: dict, channel: str = "auto") -> dict:
    """Returns {"state": "sent"|"waiting", ...}. prop needs id, property_code, whatsapp_phone, citizen_name."""
    phone = prop["whatsapp_phone"]
    bill_id = bill["id"] if bill else None
    # any older wait for the same house and purpose is replaced by this one
    cur.execute("""UPDATE citizen_code_waits SET status = 'cancelled'
                   WHERE property_id = %s AND purpose = %s AND status = 'waiting'""", (prop["id"], purpose))

    if channel == "template" or not settings.CITIZEN_FIRST_MESSAGE:
        ch, code = codes.create_challenge(cur, purpose=purpose, property_id=prop["id"], bill_id=bill_id, phone=phone,
                                          created_by=user["id"])
        if bill:
            whatsapp.send_bill_notice(phone, name=prop["citizen_name"], property_code=prop["property_code"],
                                      total=float(bill["total_amount"]), gov=float(bill["gov_amount"]),
                                      fee=float(bill["company_fee"]), collector_code=user["employee_code"])
        whatsapp.send_otp(phone, code)
        audit.log(cur, user["id"], f"{purpose}_otp_sent", "property", prop["id"], {"channel": "template", "bill_id": bill_id})
        return {"state": "sent", "channel": "template", "expires_at": ch["expires_at"].isoformat(),
                "resend_after_seconds": settings.OTP_RESEND_COOLDOWN_SECONDS}

    if whatsapp.window_open(phone, cur):
        out = _send_free(cur, purpose=purpose, property_id=prop["id"], bill_id=bill_id, phone=phone, created_by=user["id"])
        audit.log(cur, user["id"], f"{purpose}_otp_sent", "property", prop["id"], {"channel": "free", "bill_id": bill_id})
        out.pop("challenge_id", None)
        return out

    expires = datetime.now(timezone.utc) + timedelta(minutes=settings.CITIZEN_WAIT_MINUTES)
    cur.execute(
        """INSERT INTO citizen_code_waits (purpose, property_id, bill_id, phone, created_by, expires_at)
           VALUES (%s,%s,%s,%s,%s,%s) RETURNING id""",
        (purpose, prop["id"], bill_id, phone, user["id"], expires),
    )
    wait_id = cur.fetchone()["id"]
    audit.log(cur, user["id"], f"{purpose}_waiting_citizen", "property", prop["id"], {"wait_id": wait_id, "bill_id": bill_id})
    return {"state": "waiting", "channel": "free", "wait_id": wait_id, "expires_at": expires.isoformat(),
            "business_number": settings.WHATSAPP_BUSINESS_NUMBER, "wa_link": wa_link(prop["property_code"]),
            "instructions": "اطلب من المواطن إرسال اسمه برسالة واتساب إلى رقم الشركة (أو مسح الرمز)، وسيصله رمز التحقق فوراً."}


def code_status(cur, *, purpose: str, property_id: int, bill_id: int | None) -> dict:
    """What the collector's screen shows while it waits: waiting -> sent (then he types the code)."""
    cur.execute(
        """SELECT * FROM citizen_code_waits WHERE property_id = %s AND purpose = %s
             AND (%s::int IS NULL OR bill_id = %s::int) ORDER BY id DESC LIMIT 1""",
        (property_id, purpose, bill_id, bill_id),
    )
    w = cur.fetchone()
    cur.execute(
        """SELECT expires_at, created_at FROM otp_challenges WHERE property_id = %s AND purpose = %s AND status = 'pending'
             AND (%s::int IS NULL OR bill_id = %s::int) ORDER BY id DESC LIMIT 1""",
        (property_id, purpose, bill_id, bill_id),
    )
    ch = cur.fetchone()
    now = datetime.now(timezone.utc)
    if ch and ch["expires_at"] > now and (not w or w["status"] != "waiting" or ch["created_at"] >= w["created_at"]):
        return {"state": "sent", "expires_at": ch["expires_at"].isoformat()}
    if w and w["status"] == "waiting" and w["expires_at"] > now and whatsapp.window_open(w["phone"], cur):
        # the citizen's message arrived but was not matched (e.g. a resend replaced the wait at that very moment):
        # the window is open, so send the code now instead of leaving the collector waiting
        if _send_with_savepoint(cur, w):
            return {"state": "sent", "expires_at": (now + timedelta(seconds=settings.OTP_TTL_SECONDS)).isoformat()}
    if w and w["status"] == "waiting":
        if w["expires_at"] > now:
            cur.execute("SELECT property_code FROM properties WHERE id = %s", (property_id,))
            pc = cur.fetchone()["property_code"]
            return {"state": "waiting", "expires_at": w["expires_at"].isoformat(),
                    "business_number": settings.WHATSAPP_BUSINESS_NUMBER, "wa_link": wa_link(pc)}
        return {"state": "expired"}
    return {"state": "none"}


def _send_with_savepoint(cur, w: dict) -> bool:
    """Sends the code for a wait. If WhatsApp fails, nothing is kept (no half-made code reported as 'sent')."""
    cur.execute("SAVEPOINT send_code")
    try:
        _send_free(cur, purpose=w["purpose"], property_id=w["property_id"], bill_id=w["bill_id"], phone=w["phone"],
                   created_by=w["created_by"])
        cur.execute("UPDATE citizen_code_waits SET status = 'sent', sent_at = NOW() WHERE id = %s", (w["id"],))
        audit.log(cur, None, f"{w['purpose']}_otp_sent", "property", w["property_id"],
                  {"channel": "free", "wait_id": w["id"], "via": "citizen_message"})
        cur.execute("RELEASE SAVEPOINT send_code")
        return True
    except HTTPException:
        cur.execute("ROLLBACK TO SAVEPOINT send_code")
        return False


def handle_inbound(cur, *, phone: str, body: str | None, profile_name: str | None, wa_message_id: str | None,
                   msg_type: str = "text", sent_at: datetime | None = None) -> dict:
    """A citizen messaged the company number (webhook). Logs it (this is what opens the free window), then:
    1. sends the code for his newest waiting request (a property code in the text picks the right house), or
    2. activates a house registered offline with this number (the message proves he owns the number), or
    3. does nothing (no reply, so no conversation is started by us)."""
    if wa_message_id:
        cur.execute("SELECT 1 FROM whatsapp_inbound WHERE wa_message_id = %s", (wa_message_id,))
        if cur.fetchone():
            return {"duplicate": True}
    cur.execute(
        """INSERT INTO whatsapp_inbound (wa_message_id, phone, profile_name, msg_type, body, sent_at)
           VALUES (%s,%s,%s,%s,%s,%s) ON CONFLICT (wa_message_id) DO NOTHING RETURNING id""",
        (wa_message_id, phone, (profile_name or "")[:120] or None, msg_type, (body or "")[:2000], sent_at),
    )
    row = cur.fetchone()
    if row is None:              # the same Meta message delivered twice at the same moment
        return {"duplicate": True}
    inbound_id = row["id"]
    if sent_at is not None and sent_at < datetime.now(timezone.utc) - timedelta(hours=23):
        return {"inbound_id": inbound_id, "handled": [], "stale": True}    # a very late retry from Meta: window closed
    handled = []
    wanted = (PROPERTY_CODE_RE.search(body or "") or [None])[0]
    cur.execute(
        """SELECT w.*, p.property_code FROM citizen_code_waits w JOIN properties p ON p.id = w.property_id
           LEFT JOIN bills b ON b.id = w.bill_id
           WHERE w.phone = %s AND w.status = 'waiting' AND w.expires_at > NOW()
             AND ((w.purpose = 'payment' AND b.status = 'awaiting_otp')
                  OR (w.purpose = 'registration' AND p.status = 'pending_otp'))
           ORDER BY (UPPER(p.property_code) = UPPER(%s)) DESC, w.id DESC FOR UPDATE OF w""",
        (phone, wanted or ""),
    )
    waits = cur.fetchall()
    if waits:
        w = waits[0]
        if _send_with_savepoint(cur, w):
            handled.append({"wait": w["id"], "property_code": w["property_code"]})
        else:                            # e.g. WhatsApp failed: the wait stays open, the collector can resend
            handled.append({"wait": w["id"], "error": "send_failed"})
    else:
        cur.execute(
            """SELECT p.id, p.property_code, p.citizen_id FROM properties p JOIN citizens c ON c.id = p.citizen_id
               WHERE c.whatsapp_phone = %s AND p.status = 'pending_otp' AND p.flags ? 'offline_capture'
               ORDER BY p.id DESC""",
            (phone,),
        )
        offline = cur.fetchall()
        # one message activates the houses on this number only while the number stays within the normal limit;
        # beyond it, only the houses the citizen names by code (a collector can't hang many houses on one number)
        cur.execute("""SELECT COUNT(*) AS n FROM properties p JOIN citizens c ON c.id = p.citizen_id
                       WHERE c.whatsapp_phone = %s AND p.status = 'active'""", (phone,))
        active_n = cur.fetchone()["n"]
        if active_n + len(offline) > settings.MAX_PROPERTIES_PER_PHONE:
            named = {m.upper() for m in PROPERTY_CODE_RE.findall(body or "")}
            skipped = [p["property_code"] for p in offline if p["property_code"].upper() not in named]
            offline = [p for p in offline if p["property_code"].upper() in named]
            if skipped:
                handled.append({"needs_visit": skipped})
                audit.log(cur, None, "offline_activation_held", "phone", phone[-4:], {"houses": skipped})
        for p in offline:
            cur.execute("UPDATE properties SET status = 'active', activated_at = NOW(), "
                        "flags = flags || '[\"verified_by_citizen_message\"]'::jsonb WHERE id = %s", (p["id"],))
            cur.execute("UPDATE citizens SET phone_verified_at = NOW() WHERE id = %s", (p["citizen_id"],))
            audit.log(cur, None, "registration_verified", "property", p["id"], {"method": "citizen_message"})
            handled.append({"activated": p["property_code"]})
        if offline:
            whatsapp.send_text(phone, "تم تأكيد رقمك وتفعيل عقارك في منظومة الجباية: "
                               + "، ".join(p["property_code"] for p in offline)
                               + f". لا تدفع إلا بوصل رسمي. للشكاوى: {settings.HOTLINE}", "activation")
    cur.execute("UPDATE whatsapp_inbound SET handled = %s::jsonb WHERE id = %s",
                (__import__("json").dumps(handled, ensure_ascii=False), inbound_id))
    return {"inbound_id": inbound_id, "handled": handled}
