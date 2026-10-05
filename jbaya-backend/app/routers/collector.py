"""Field collector flows:
A) registration: details + GPS -> OTP to citizen WhatsApp -> verify -> property active
B) collection:   reading/estimate -> server computes amount -> bill notice + OTP to citizen -> verify -> receipt
C) fallback:     rotating master code (from Command) with a mandatory reason
"""
import json
from datetime import datetime, timezone
from typing import Literal

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field

from .. import audit, billing, codes, files, whatsapp
from ..config import settings
from ..db import dict_cursor, get_conn
from ..security import require_roles
from ..utils import haversine_m, mask_phone, normalize_iraqi_phone, point_in_polygon
from ..verification import VerifyIn, verify

router = APIRouter(tags=["collector"])
collector_only = require_roles("collector")


# ------------------------------------------------------------------ helpers

def _load_sector(cur, sector_id: int | None) -> dict:
    if not sector_id:
        raise HTTPException(403, "لم يتم تعيين قاطع لك، راجع المشرف")
    cur.execute("SELECT * FROM sectors WHERE id = %s AND active", (sector_id,))
    s = cur.fetchone()
    if not s:
        raise HTTPException(403, "القاطع المخصص لك غير فعال")
    return s


def _load_property(cur, property_id: int, user: dict, lock: bool = False) -> dict:
    cur.execute(
        f"""SELECT p.*, c.full_name AS citizen_name, c.whatsapp_phone
            FROM properties p JOIN citizens c ON c.id = p.citizen_id
            WHERE p.id = %s {'FOR UPDATE OF p' if lock else ''}""",
        (property_id,),
    )
    p = cur.fetchone()
    if not p:
        raise HTTPException(404, "العقار غير موجود")
    if user["role"] == "collector" and p["sector_id"] != user["sector_id"]:
        raise HTTPException(403, "هذا العقار خارج القاطع المخصص لك")
    return p


def _load_bill(cur, bill_id: int, user: dict, lock: bool = False) -> dict:
    cur.execute(f"SELECT * FROM bills WHERE id = %s {'FOR UPDATE' if lock else ''}", (bill_id,))
    b = cur.fetchone()
    if not b:
        raise HTTPException(404, "الفاتورة غير موجودة")
    if user["role"] == "collector" and b["collector_id"] != user["id"]:
        raise HTTPException(403, "هذه الفاتورة لا تخصك")
    return b


def _check_gps(lat: float, lng: float, accuracy: float | None, is_mocked: bool = False):
    if is_mocked:
        raise HTTPException(403, "تم اكتشاف تطبيق لتزييف الموقع. أغلقه ثم حاول مجدداً")
    if not (-90 <= lat <= 90 and -180 <= lng <= 180):
        raise HTTPException(422, "إحداثيات غير صالحة")
    if accuracy is not None and accuracy > settings.MAX_GPS_ACCURACY_METERS:
        raise HTTPException(422, f"دقة الموقع ضعيفة ({accuracy:.0f} م). انتظر قليلاً في مكان مفتوح ثم أعد الالتقاط")


def cash_in_hand(cur, collector_id: int) -> float:
    """Cash the collector is carrying: receipts not yet handed to the supervisor."""
    cur.execute(
        "SELECT COALESCE(SUM(total_amount), 0) AS s FROM receipts WHERE collector_id = %s AND reconciliation_id IS NULL",
        (collector_id,),
    )
    return float(cur.fetchone()["s"])


def _num(x):
    return float(x) if x is not None else None


def _bill_out(b: dict, p: dict | None = None) -> dict:
    out = {
        "id": b["id"],
        "property_id": b["property_id"],
        "visit_type": b["visit_type"],
        "billing_method": b["billing_method"],
        "previous_reading": _num(b["previous_reading"]),
        "current_reading": _num(b["current_reading"]),
        "consumption": _num(b["consumption"]),
        "unit_rate": _num(b["unit_rate"]),
        "period_days": b["period_days"],
        "gov_amount": _num(b["gov_amount"]),
        "company_fee": _num(b["company_fee"]),
        "total_amount": _num(b["total_amount"]),
        "status": b["status"],
        "flags": b["flags"],
        "review_note": b.get("review_note"),
        "has_photo": bool(b.get("photo_path")),
        "ocr_reading": _num(b.get("ocr_reading")),
    }
    if p:
        out["property_code"] = p["property_code"]
        out["citizen_name"] = p["citizen_name"]
        out["phone_masked"] = mask_phone(p["whatsapp_phone"])
    return out


def _send_payment_messages(cur, user: dict, bill: dict, prop: dict) -> dict:
    """Creates a fresh payment OTP and sends: (1) bill notice with exact amount, (2) the code."""
    ch, code = codes.create_challenge(cur, purpose="payment", property_id=prop["id"], bill_id=bill["id"],
                                      phone=prop["whatsapp_phone"], created_by=user["id"])
    whatsapp.send_bill_notice(prop["whatsapp_phone"], name=prop["citizen_name"], property_code=prop["property_code"],
                              total=float(bill["total_amount"]), gov=float(bill["gov_amount"]),
                              fee=float(bill["company_fee"]), collector_code=user["employee_code"])
    whatsapp.send_otp(prop["whatsapp_phone"], code)
    audit.log(cur, user["id"], "payment_otp_sent", "bill", bill["id"], {"challenge_id": ch["id"]})
    return {"expires_at": ch["expires_at"].isoformat(), "resend_after_seconds": settings.OTP_RESEND_COOLDOWN_SECONDS}


# ------------------------------------------------------------------ route (visit list)

@router.get("/collector/route")
def my_route(user: dict = Depends(collector_only)):
    with get_conn() as conn, dict_cursor(conn) as cur:
        sector = _load_sector(cur, user["sector_id"])
        cur.execute(
            """SELECT p.id, p.property_code, p.address, p.property_class, p.meter_status, p.lat, p.lng, p.status,
                      c.full_name AS citizen_name,
                      lp.paid_at AS last_paid_at,
                      lr.reading AS last_reading,
                      ob.id AS open_bill_id, ob.status AS open_bill_status
               FROM properties p
               JOIN citizens c ON c.id = p.citizen_id
               LEFT JOIN LATERAL (SELECT paid_at FROM bills WHERE property_id = p.id AND status = 'paid'
                                  ORDER BY paid_at DESC LIMIT 1) lp ON TRUE
               LEFT JOIN LATERAL (SELECT reading FROM meter_readings WHERE property_id = p.id
                                  ORDER BY taken_at DESC, id DESC LIMIT 1) lr ON TRUE
               LEFT JOIN LATERAL (SELECT id, status FROM bills WHERE property_id = p.id
                                  AND status IN ('awaiting_otp','pending_approval','blocked_review')
                                  ORDER BY created_at DESC LIMIT 1) ob ON TRUE
               WHERE p.sector_id = %s AND p.status = 'active'
               ORDER BY lp.paid_at ASC NULLS FIRST""",
            (sector["id"],),
        )
        rows = cur.fetchall()
    now = datetime.now(timezone.utc)
    items = []
    for r in rows:
        days = None if r["last_paid_at"] is None else int((now - r["last_paid_at"]).total_seconds() // 86400)
        if days is None or days >= settings.ROUTE_DUE_DAYS:
            color = "red"
        elif days >= settings.ROUTE_WARNING_DAYS:
            color = "yellow"
        else:
            color = "green"
        items.append({
            "id": r["id"], "property_code": r["property_code"], "citizen_name": r["citizen_name"],
            "address": r["address"], "property_class": r["property_class"], "meter_status": r["meter_status"],
            "lat": r["lat"], "lng": r["lng"],
            "days_since_paid": days, "never_paid": r["last_paid_at"] is None,
            "last_reading": _num(r["last_reading"]), "status_color": color,
            "open_bill_id": r["open_bill_id"], "open_bill_status": r["open_bill_status"],
        })
    return {"sector": {"id": sector["id"], "code": sector["code"], "name": sector["name"], "polygon": sector["polygon"]},
            "properties": items}


# ------------------------------------------------------------------ A) registration

class RegistrationIn(BaseModel):
    full_name: str = Field(..., min_length=3, max_length=120)
    address: str = Field(..., min_length=3, max_length=300)
    property_class: Literal["Household", "Business", "Industrial", "Agricultural"]
    whatsapp_phone: str
    lat: float
    lng: float
    gps_accuracy_m: float | None = None
    meter_status: Literal["working", "none", "broken"] = "working"
    meter_serial: str | None = Field(None, max_length=50)
    is_mocked: bool = False


@router.post("/registrations")
def start_registration(body: RegistrationIn, user: dict = Depends(collector_only)):
    phone = normalize_iraqi_phone(body.whatsapp_phone)
    if not phone:
        raise HTTPException(422, "رقم الواتساب غير صالح. مثال: 07801234567")
    _check_gps(body.lat, body.lng, body.gps_accuracy_m, body.is_mocked)

    with get_conn() as conn, dict_cursor(conn) as cur:
        sector = _load_sector(cur, user["sector_id"])
        if settings.ENFORCE_GEOFENCE and not point_in_polygon(body.lat, body.lng, sector["polygon"]):
            audit.log(cur, user["id"], "geofence_violation", "sector", sector["id"], {"lat": body.lat, "lng": body.lng})
            conn.commit()
            raise HTTPException(403, "أنت خارج حدود القاطع المخصص لك. يرجى التواجد داخل الزقاق")

        # A collector must never register his own / a colleague's number as the citizen's.
        cur.execute("SELECT employee_code FROM employees WHERE phone = %s", (phone,))
        if cur.fetchone():
            audit.log(cur, user["id"], "employee_phone_blocked", "phone", phone[-4:], {})
            conn.commit()
            raise HTTPException(403, "لا يمكن استخدام رقم يعود لموظف في المنظومة")

        flags = []
        cur.execute(
            """SELECT COUNT(*) AS n FROM properties p JOIN citizens c ON c.id = p.citizen_id
               WHERE c.whatsapp_phone = %s AND p.status = 'active'""",
            (phone,),
        )
        if cur.fetchone()["n"] >= settings.MAX_PROPERTIES_PER_PHONE:
            flags.append("phone_many_properties")

        cur.execute("SELECT id, lat, lng FROM properties WHERE sector_id = %s AND status <> 'suspended'", (sector["id"],))
        for other in cur.fetchall():
            if haversine_m(body.lat, body.lng, other["lat"], other["lng"]) <= settings.DUPLICATE_RADIUS_M:
                flags.append("possible_duplicate_location")
                break

        cur.execute("INSERT INTO citizens (full_name, whatsapp_phone) VALUES (%s, %s) RETURNING id",
                    (body.full_name.strip(), phone))
        citizen_id = cur.fetchone()["id"]
        cur.execute("SELECT 'BGD-' || LPAD(nextval('property_code_seq')::text, 6, '0') AS code")
        code = cur.fetchone()["code"]
        cur.execute(
            """INSERT INTO properties (property_code, citizen_id, sector_id, address, property_class, lat, lng,
                                       gps_accuracy_m, meter_serial, meter_status, flags, registered_by)
               VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s) RETURNING id""",
            (code, citizen_id, sector["id"], body.address.strip(), body.property_class, body.lat, body.lng,
             body.gps_accuracy_m, body.meter_serial, body.meter_status, json.dumps(flags), user["id"]),
        )
        property_id = cur.fetchone()["id"]
        ch, otp = codes.create_challenge(cur, purpose="registration", property_id=property_id, bill_id=None,
                                         phone=phone, created_by=user["id"])
        whatsapp.send_otp(phone, otp)
        audit.log(cur, user["id"], "registration_started", "property", property_id, {"flags": flags})

    return {
        "property_id": property_id,
        "property_code": code,
        "phone_masked": mask_phone(phone),
        "expires_at": ch["expires_at"].isoformat(),
        "resend_after_seconds": settings.OTP_RESEND_COOLDOWN_SECONDS,
        "flags": flags,
    }


@router.post("/registrations/{property_id}/resend-otp")
def resend_registration_otp(property_id: int, user: dict = Depends(collector_only)):
    with get_conn() as conn, dict_cursor(conn) as cur:
        p = _load_property(cur, property_id, user, lock=True)
        if p["status"] != "pending_otp":
            raise HTTPException(409, "تم تأكيد هذا التسجيل مسبقاً")
        ch, otp = codes.create_challenge(cur, purpose="registration", property_id=p["id"], bill_id=None,
                                         phone=p["whatsapp_phone"], created_by=user["id"])
        whatsapp.send_otp(p["whatsapp_phone"], otp)
        audit.log(cur, user["id"], "registration_otp_resent", "property", p["id"], {})
    return {"expires_at": ch["expires_at"].isoformat(), "resend_after_seconds": settings.OTP_RESEND_COOLDOWN_SECONDS}


@router.post("/registrations/{property_id}/verify")
def verify_registration(property_id: int, body: VerifyIn, user: dict = Depends(collector_only)):
    with get_conn() as conn, dict_cursor(conn) as cur:
        p = _load_property(cur, property_id, user, lock=True)
        if p["status"] != "pending_otp":
            raise HTTPException(409, "تم تأكيد هذا التسجيل مسبقاً")
        res = verify(cur, user, purpose="registration", property_id=p["id"], bill_id=None, body=body)
        if res["ok"]:
            cur.execute("UPDATE properties SET status = 'active', activated_at = NOW() WHERE id = %s", (p["id"],))
            cur.execute("UPDATE citizens SET phone_verified_at = NOW() WHERE id = %s", (p["citizen_id"],))
            audit.log(cur, user["id"], "registration_verified", "property", p["id"], {"method": res["method"]})
    if not res["ok"]:
        raise HTTPException(res["status"], res["message"])
    return {"property_id": p["id"], "property_code": p["property_code"], "status": "active",
            "verification_method": res["method"], "meter_status": p["meter_status"]}


# ------------------------------------------------------------------ B) collection

class BillIn(BaseModel):
    property_id: int
    method: Literal["reading", "estimate"]
    current_reading: float | None = None
    lat: float | None = None
    lng: float | None = None
    gps_accuracy_m: float | None = None
    is_mocked: bool = False
    photo_base64: str | None = Field(None, max_length=6_000_000)   # meter photo (required for readings)
    ocr_reading: float | None = None                                # what the phone's OCR read, if available


@router.post("/bills")
def create_bill(body: BillIn, user: dict = Depends(collector_only)):
    with get_conn() as conn, dict_cursor(conn) as cur:
        p = _load_property(cur, body.property_id, user, lock=True)
        if p["status"] != "active":
            raise HTTPException(409, "يجب تأكيد رقم المواطن (OTP) قبل الجباية")

        held = cash_in_hand(cur, user["id"])
        if held >= settings.CASH_IN_HAND_CAP_IQD:
            audit.log(cur, user["id"], "cash_cap_blocked", "employee", user["employee_code"], {"cash_in_hand": held})
            conn.commit()
            raise HTTPException(423, f"تجاوزت الحد الأعلى للنقد بحوزتك ({held:,.0f} د.ع). سلّم النقد للمشرف قبل متابعة الجباية")
        if body.method == "reading" and settings.REQUIRE_METER_PHOTO and not body.photo_base64:
            raise HTTPException(422, "يجب تصوير العداد قبل إصدار الفاتورة")

        extra_flags = []
        if body.lat is None or body.lng is None:
            extra_flags.append("no_gps")
        else:
            _check_gps(body.lat, body.lng, body.gps_accuracy_m, body.is_mocked)
            dist = haversine_m(body.lat, body.lng, p["lat"], p["lng"])
            if dist > settings.MAX_DISTANCE_FROM_PROPERTY_M:
                raise HTTPException(403, f"أنت على بعد {dist:.0f} م من العقار. يجب التواجد عند العقار لإصدار الفاتورة")

        cur.execute(
            "SELECT id, status FROM bills WHERE property_id = %s AND status IN ('pending_approval','blocked_review')",
            (p["id"],),
        )
        if cur.fetchone():
            raise HTTPException(409, "يوجد فاتورة لهذا العقار قيد مراجعة المشرف")
        # a new reading replaces any unpaid bill that is still waiting for the citizen's code
        cur.execute("UPDATE bills SET status = 'cancelled', review_note = 'replaced by new bill' "
                    "WHERE property_id = %s AND status = 'awaiting_otp'", (p["id"],))
        cur.execute("UPDATE otp_challenges SET status = 'superseded' WHERE property_id = %s AND purpose = 'payment' AND status = 'pending'",
                    (p["id"],))

        cur.execute("SELECT * FROM tariffs WHERE property_class = %s", (p["property_class"],))
        tariff = cur.fetchone()
        if not tariff:
            raise HTTPException(500, "لا توجد تعرفة لفئة هذا العقار")

        reading = body.current_reading if body.method == "reading" else None
        calc = billing.compute(cur, p, tariff, body.method, reading)
        if reading is not None and body.ocr_reading is not None \
                and abs(body.ocr_reading - reading) > settings.OCR_MISMATCH_TOLERANCE:
            extra_flags.append("ocr_mismatch")
        if body.method == "reading" and not body.photo_base64:
            extra_flags.append("no_photo")
        calc["flags"] = calc["flags"] + extra_flags
        photo_path = files.save_photo(body.photo_base64, "meters") if body.photo_base64 else None
        cur.execute(
            """INSERT INTO bills (property_id, collector_id, visit_type, billing_method, previous_reading, current_reading,
                                  consumption, unit_rate, period_days, gov_amount, company_fee, total_amount, status, flags,
                                  photo_path, ocr_reading)
               VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s) RETURNING *""",
            (p["id"], user["id"], calc["visit_type"], calc["billing_method"], calc["previous_reading"],
             calc["current_reading"], calc["consumption"], calc["unit_rate"], calc["period_days"],
             calc["gov_amount"], calc["company_fee"], calc["total_amount"], calc["status"], json.dumps(calc["flags"]),
             photo_path, body.ocr_reading),
        )
        bill = cur.fetchone()
        audit.log(cur, user["id"], "bill_created", "bill", bill["id"],
                  {"property_id": p["id"], "total": calc["total_amount"], "status": calc["status"], "flags": calc["flags"]})
        otp_info = None
        if bill["status"] == "awaiting_otp":
            otp_info = _send_payment_messages(cur, user, bill, p)

    out = _bill_out(bill, p)
    out["otp"] = otp_info
    return out


@router.get("/bills/{bill_id}")
def get_bill(bill_id: int, user: dict = Depends(require_roles("collector", "supervisor", "command", "finance"))):
    with get_conn() as conn, dict_cursor(conn) as cur:
        b = _load_bill(cur, bill_id, user)
        p = _load_property(cur, b["property_id"], {"role": "any"})
    return _bill_out(b, p)


@router.post("/bills/{bill_id}/send-otp")
def send_bill_otp(bill_id: int, user: dict = Depends(collector_only)):
    """Used for resend, and after a supervisor approves an estimate."""
    with get_conn() as conn, dict_cursor(conn) as cur:
        b = _load_bill(cur, bill_id, user, lock=True)
        if b["status"] != "awaiting_otp":
            raise HTTPException(409, "لا يمكن إرسال رمز لهذه الفاتورة في حالتها الحالية")
        p = _load_property(cur, b["property_id"], user)
        info = _send_payment_messages(cur, user, b, p)
    return info


@router.post("/bills/{bill_id}/verify")
def verify_bill(bill_id: int, body: VerifyIn, user: dict = Depends(collector_only)):
    receipt = None
    with get_conn() as conn, dict_cursor(conn) as cur:
        b = _load_bill(cur, bill_id, user, lock=True)
        if b["status"] != "awaiting_otp":
            raise HTTPException(409, "هذه الفاتورة ليست بانتظار التأكيد")
        p = _load_property(cur, b["property_id"], user)
        res = verify(cur, user, purpose="payment", property_id=p["id"], bill_id=b["id"], body=body)
        if res["ok"]:
            cur.execute("UPDATE bills SET status = 'paid', paid_at = NOW() WHERE id = %s", (b["id"],))
            if b["current_reading"] is not None:
                if "rebaseline" in (b["flags"] or []):
                    rtype = "rebaseline"
                elif b["previous_reading"] is None:
                    rtype = "baseline"
                else:
                    rtype = "actual"
                cur.execute(
                    "INSERT INTO meter_readings (property_id, bill_id, reading, reading_type, photo_url, taken_by) VALUES (%s,%s,%s,%s,%s,%s)",
                    (p["id"], b["id"], b["current_reading"], rtype, b.get("photo_path"), user["id"]),
                )
            cur.execute("SELECT 'RCP-' || nextval('receipt_no_seq')::text AS no")
            receipt_no = cur.fetchone()["no"]
            cur.execute(
                """INSERT INTO receipts (receipt_no, bill_id, property_id, collector_id, gov_amount, company_fee,
                                         total_amount, verification_method)
                   VALUES (%s,%s,%s,%s,%s,%s,%s,%s) RETURNING *""",
                (receipt_no, b["id"], p["id"], user["id"], b["gov_amount"], b["company_fee"], b["total_amount"], res["method"]),
            )
            receipt = cur.fetchone()
            audit.log(cur, user["id"], "payment_verified", "bill", b["id"],
                      {"receipt_no": receipt_no, "total": str(b["total_amount"]), "method": res["method"]})
    if not res["ok"]:
        raise HTTPException(res["status"], res["message"])

    try:
        whatsapp.send_receipt(p["whatsapp_phone"], name=p["citizen_name"], receipt_no=receipt["receipt_no"],
                              property_code=p["property_code"], total=float(receipt["total_amount"]),
                              date_str=receipt["issued_at"].strftime("%Y-%m-%d %H:%M"))
        receipt_sent = True
    except HTTPException:
        receipt_sent = False  # payment is already recorded; the failure is logged in whatsapp_messages

    return {
        "receipt_no": receipt["receipt_no"],
        "property_code": p["property_code"],
        "citizen_name": p["citizen_name"],
        "gov_amount": float(receipt["gov_amount"]),
        "company_fee": float(receipt["company_fee"]),
        "total_amount": float(receipt["total_amount"]),
        "verification_method": receipt["verification_method"],
        "issued_at": receipt["issued_at"].isoformat(),
        "collector_code": user["employee_code"],
        "receipt_whatsapp_sent": receipt_sent,
    }


@router.get("/bills/{bill_id}/photo")
def bill_photo(bill_id: int, user: dict = Depends(require_roles("collector", "supervisor", "command", "finance"))):
    with get_conn() as conn, dict_cursor(conn) as cur:
        b = _load_bill(cur, bill_id, user)
        if user["role"] == "supervisor":
            cur.execute("SELECT supervisor_id FROM employees WHERE id = %s", (b["collector_id"],))
            if cur.fetchone()["supervisor_id"] != user["id"]:
                raise HTTPException(403, "هذه الفاتورة ليست ضمن فريقك")
    photo = files.load_photo(b.get("photo_path"))
    if not photo:
        raise HTTPException(404, "لا توجد صورة لهذه الفاتورة")
    return photo


# ------------------------------------------------------------------ collector dashboard, receipts, SOS

@router.get("/collector/summary")
def my_summary(user: dict = Depends(collector_only)):
    with get_conn() as conn, dict_cursor(conn) as cur:
        cur.execute(
            """SELECT COALESCE(SUM(total_amount), 0) AS collected, COUNT(*) AS receipts,
                      COUNT(*) FILTER (WHERE verification_method = 'master_code') AS master_uses
               FROM receipts WHERE collector_id = %s AND issued_at >= date_trunc('day', NOW())""",
            (user["id"],),
        )
        today = cur.fetchone()
        cur.execute(
            "SELECT COUNT(*) AS n FROM properties WHERE registered_by = %s AND activated_at >= date_trunc('day', NOW())",
            (user["id"],),
        )
        registrations = cur.fetchone()["n"]
        cur.execute("SELECT daily_target_iqd FROM employees WHERE id = %s", (user["id"],))
        target = cur.fetchone()["daily_target_iqd"]
        held = cash_in_hand(cur, user["id"])
        cur.execute("SELECT id, status, created_at FROM sos_alerts WHERE employee_id = %s AND status <> 'closed' "
                    "ORDER BY created_at DESC LIMIT 1", (user["id"],))
        sos = cur.fetchone()
    target = float(target) if target is not None else settings.COLLECTOR_DAILY_TARGET_IQD
    return {
        "collected_today": float(today["collected"]),
        "receipts_today": today["receipts"],
        "master_code_uses_today": today["master_uses"],
        "registrations_today": registrations,
        "daily_target": target,
        "cash_in_hand": held,
        "cash_cap": settings.CASH_IN_HAND_CAP_IQD,
        "cash_cap_reached": held >= settings.CASH_IN_HAND_CAP_IQD,
        "open_sos": {"id": sos["id"], "status": sos["status"], "created_at": sos["created_at"].isoformat()} if sos else None,
    }


@router.get("/collector/receipts")
def my_receipts(user: dict = Depends(collector_only)):
    with get_conn() as conn, dict_cursor(conn) as cur:
        cur.execute(
            """SELECT r.receipt_no, r.issued_at, r.total_amount, r.verification_method, r.reconciliation_id,
                      p.property_code, c.full_name AS citizen_name
               FROM receipts r JOIN properties p ON p.id = r.property_id JOIN citizens c ON c.id = p.citizen_id
               WHERE r.collector_id = %s AND (r.issued_at >= date_trunc('day', NOW()) OR r.reconciliation_id IS NULL)
               ORDER BY r.issued_at DESC""",
            (user["id"],),
        )
        rows = cur.fetchall()
    return [{
        "receipt_no": r["receipt_no"], "issued_at": r["issued_at"].isoformat(), "total_amount": float(r["total_amount"]),
        "verification_method": r["verification_method"], "handed_over": r["reconciliation_id"] is not None,
        "property_code": r["property_code"], "citizen_name": r["citizen_name"],
    } for r in rows]


class SosIn(BaseModel):
    lat: float | None = None
    lng: float | None = None
    gps_accuracy_m: float | None = None
    note: str | None = Field(None, max_length=500)


@router.post("/sos")
def send_sos(body: SosIn, user: dict = Depends(require_roles("collector", "supervisor"))):
    """Panic button. Does not block on GPS: a location is attached when available."""
    with get_conn() as conn, dict_cursor(conn) as cur:
        cur.execute(
            """INSERT INTO sos_alerts (employee_id, lat, lng, gps_accuracy_m, note) VALUES (%s,%s,%s,%s,%s)
               RETURNING id, created_at""",
            (user["id"], body.lat, body.lng, body.gps_accuracy_m, body.note),
        )
        a = cur.fetchone()
        audit.log(cur, user["id"], "sos", "employee", user["employee_code"],
                  {"alert_id": a["id"], "lat": body.lat, "lng": body.lng})
    print(f"\n!!! SOS from {user['employee_code']} at {body.lat},{body.lng} ({body.note or ''}) !!!\n")
    return {"alert_id": a["id"], "created_at": a["created_at"].isoformat()}
