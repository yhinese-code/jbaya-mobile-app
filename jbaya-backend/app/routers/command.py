"""Central Command: master code (Command role ONLY), live operations (positions, feed, trails), sector progress,
leaderboard, receipts log, system health, and messages to the field."""
import shutil
from datetime import date, datetime, timedelta, timezone
from typing import Literal

from fastapi import APIRouter, Depends, HTTPException, Query
from pydantic import BaseModel, Field

from .. import audit, codes, files
from ..config import settings
from ..utils import haversine_m
from ..db import dict_cursor, get_conn
from ..security import current_user, require_roles

router = APIRouter(prefix="/command", tags=["command"])
command_or_admin = require_roles("command")


def command_strict(user: dict = Depends(current_user)) -> dict:
    """Master code is visible to the Command role only (not admin, not supervisors)."""
    if user["role"] != "command":
        raise HTTPException(403, "الرمز الرئيسي متاح لغرفة القيادة فقط")
    return user


@router.get("/master-code")
def master_code(user: dict = Depends(command_strict)):
    info = codes.current_master_code()
    with get_conn() as conn, dict_cursor(conn) as cur:
        # log once per window per viewer, so the log is not flooded by the screen's auto-refresh
        cur.execute(
            """SELECT 1 FROM audit_log WHERE actor_id = %s AND action = 'master_code_viewed'
               AND details->>'window' = %s LIMIT 1""",
            (user["id"], str(info["window_index"])),
        )
        if not cur.fetchone():
            audit.log(cur, user["id"], "master_code_viewed", "master_code", info["window_index"], {"window": str(info["window_index"])})
    return info


@router.get("/master-code/uses")
def master_code_uses(days: int = Query(7, ge=1, le=90), user: dict = Depends(command_or_admin)):
    with get_conn() as conn, dict_cursor(conn) as cur:
        cur.execute(
            """SELECT m.id, m.purpose, m.reason, m.used_at, e.employee_code AS collector_code, e.full_name AS collector_name,
                      p.property_code, p.address, b.total_amount
               FROM master_code_uses m
               JOIN employees e ON e.id = m.collector_id
               JOIN properties p ON p.id = m.property_id
               LEFT JOIN bills b ON b.id = m.bill_id
               WHERE m.used_at >= NOW() - (%s || ' days')::interval
               ORDER BY m.used_at DESC""",
            (days,),
        )
        rows = cur.fetchall()
        cur.execute(
            """SELECT e.employee_code, e.full_name, COUNT(*) AS uses
               FROM master_code_uses m JOIN employees e ON e.id = m.collector_id
               WHERE m.used_at >= NOW() - (%s || ' days')::interval
               GROUP BY e.employee_code, e.full_name ORDER BY uses DESC""",
            (days,),
        )
        per_collector = cur.fetchall()
    for r in rows:
        r["used_at"] = r["used_at"].isoformat()
        r["total_amount"] = float(r["total_amount"]) if r["total_amount"] is not None else None
    return {"uses": rows, "per_collector": per_collector}


@router.get("/overview")
def overview(user: dict = Depends(command_or_admin)):
    with get_conn() as conn, dict_cursor(conn) as cur:
        cur.execute(
            """SELECT
                 (SELECT COALESCE(SUM(total_amount),0) FROM receipts WHERE issued_at >= date_trunc('day', NOW())) AS collected_today,
                 (SELECT COUNT(*) FROM receipts WHERE issued_at >= date_trunc('day', NOW())) AS receipts_today,
                 (SELECT COUNT(*) FROM properties WHERE activated_at >= date_trunc('day', NOW())) AS registrations_today,
                 (SELECT COUNT(*) FROM master_code_uses WHERE used_at >= date_trunc('day', NOW())) AS master_code_uses_today,
                 (SELECT COUNT(*) FROM bills WHERE status IN ('pending_approval','blocked_review')) AS bills_in_review,
                 (SELECT COALESCE(SUM(total_amount),0) FROM receipts WHERE reconciliation_id IS NULL) AS cash_in_transit,
                 (SELECT COUNT(*) FROM properties WHERE status = 'active') AS active_properties,
                 (SELECT COUNT(*) FROM sos_alerts WHERE status = 'open') AS open_sos,
                 (SELECT COUNT(DISTINCT employee_id) FROM location_pings
                     WHERE received_at >= NOW() - (%(online)s || ' seconds')::interval
                       AND employee_id IN (SELECT id FROM employees WHERE role = 'collector' AND active)) AS online_staff,
                 (SELECT COUNT(*) FROM employees WHERE role = 'collector' AND active) AS total_collectors,
                 (SELECT COALESCE(SUM(COALESCE(daily_target_iqd, %(target)s)), 0) FROM employees
                     WHERE role = 'collector' AND active) AS target_today,
                 (SELECT COUNT(*) FROM reconciliations WHERE resolution_status = 'escalated') AS escalations,
                 (SELECT COALESCE(SUM(amount),0) FROM bank_deposits WHERE status = 'pending') AS deposits_pending_verification,
                 (SELECT COUNT(*) FROM audit_log WHERE action IN ('otp_failed','master_code_failed','geofence_violation','employee_phone_blocked','cash_cap_blocked',
                                                  'geofence_exit','mock_location','impossible_speed','login_2fa_failed')
                     AND created_at >= date_trunc('day', NOW())) AS security_events_today""",
            {"online": settings.PING_ONLINE_SECONDS, "target": settings.COLLECTOR_DAILY_TARGET_IQD},
        )
        r = cur.fetchone()
    return {k: (float(v) if k in ("collected_today", "cash_in_transit", "deposits_pending_verification", "target_today") else v) for k, v in r.items()}


@router.get("/receipts")
def receipts_log(limit: int = Query(100, ge=1, le=1000), user: dict = Depends(command_or_admin)):
    with get_conn() as conn, dict_cursor(conn) as cur:
        cur.execute(
            """SELECT r.receipt_no, r.issued_at, r.gov_amount, r.company_fee, r.total_amount, r.verification_method,
                      p.property_code, e.employee_code AS collector_code, b.flags
               FROM receipts r
               JOIN properties p ON p.id = r.property_id
               JOIN employees e ON e.id = r.collector_id
               JOIN bills b ON b.id = r.bill_id
               ORDER BY r.issued_at DESC LIMIT %s""",
            (limit,),
        )
        rows = cur.fetchall()
    for r in rows:
        r["issued_at"] = r["issued_at"].isoformat()
        for k in ("gov_amount", "company_fee", "total_amount"):
            r[k] = float(r[k])
    return rows


@router.get("/audit/verify")
def verify_audit_chain(user: dict = Depends(command_or_admin)):
    with get_conn() as conn, dict_cursor(conn) as cur:
        return audit.verify_chain(cur)


# ================================================================ live operations

def _iso(v):
    return v.isoformat() if v else None


@router.get("/live")
def live(user: dict = Depends(command_or_admin)):
    """Every active field employee with last position, online status and today's activity (Command sees amounts)."""
    with get_conn() as conn, dict_cursor(conn) as cur:
        cur.execute(
            """SELECT e.id, e.employee_code, e.full_name, e.role, s.code AS sector_code, s.name AS sector_name,
                      lp.lat, lp.lng, lp.accuracy_m, lp.is_mocked, lp.inside_sector, lp.recorded_at, lp.received_at,
                      (SELECT COALESCE(SUM(total_amount),0) FROM receipts r WHERE r.collector_id = e.id
                          AND r.issued_at >= date_trunc('day', NOW())) AS collected_today,
                      (SELECT COUNT(*) FROM receipts r WHERE r.collector_id = e.id
                          AND r.issued_at >= date_trunc('day', NOW())) AS receipts_today,
                      (SELECT COALESCE(SUM(total_amount),0) FROM receipts r WHERE r.collector_id = e.id
                          AND r.reconciliation_id IS NULL) AS cash_in_hand,
                      (SELECT COUNT(*) FROM sos_alerts a WHERE a.employee_id = e.id AND a.status = 'open') AS open_sos,
                      (SELECT COUNT(*) FROM master_code_uses m WHERE m.collector_id = e.id
                          AND m.used_at >= date_trunc('day', NOW())) AS master_uses_today,
                      (SELECT COUNT(*) FROM location_pings p WHERE p.employee_id = e.id
                          AND p.recorded_at >= date_trunc('day', NOW())) AS pings_today
               FROM employees e
               LEFT JOIN sectors s ON s.id = e.sector_id
               LEFT JOIN LATERAL (SELECT * FROM location_pings p WHERE p.employee_id = e.id
                                  ORDER BY recorded_at DESC LIMIT 1) lp ON TRUE
               WHERE e.active AND e.role IN ('collector','supervisor')
               ORDER BY e.role DESC, e.employee_code"""
        )
        rows = cur.fetchall()
    now = datetime.now(timezone.utc)
    out = []
    for r in rows:
        age = (now - r["received_at"]).total_seconds() if r["received_at"] else None
        if r["open_sos"]:
            status = "sos"
        elif age is not None and age <= settings.PING_ONLINE_SECONDS:
            status = "online"
        elif r["pings_today"]:
            status = "offline"        # was working today, went silent
        else:
            status = "not_started"
        out.append({
            "employee_code": r["employee_code"], "full_name": r["full_name"], "role": r["role"],
            "sector_code": r["sector_code"], "sector_name": r["sector_name"],
            "lat": r["lat"], "lng": r["lng"], "accuracy_m": r["accuracy_m"], "is_mocked": r["is_mocked"],
            "inside_sector": r["inside_sector"], "last_seen": _iso(r["recorded_at"]),
            "seconds_since_seen": round(age) if age is not None else None, "status": status,
            "collected_today": float(r["collected_today"]), "receipts_today": r["receipts_today"],
            "cash_in_hand": float(r["cash_in_hand"]), "open_sos": r["open_sos"],
            "master_uses_today": r["master_uses_today"],
        })
    return out


@router.get("/properties")
def properties_map(sector_code: str | None = None, limit: int = Query(3000, ge=1, le=20000),
                   user: dict = Depends(command_or_admin)):
    """Property dots for the map, coloured like the collector's route (red = due, yellow = soon, green = paid)."""
    with get_conn() as conn, dict_cursor(conn) as cur:
        cur.execute(
            """SELECT p.property_code, p.lat, p.lng, p.property_class, s.code AS sector_code,
                      (SELECT MAX(paid_at) FROM bills b WHERE b.property_id = p.id AND b.status = 'paid') AS last_paid
               FROM properties p JOIN sectors s ON s.id = p.sector_id
               WHERE p.status = 'active' AND (%s::text IS NULL OR s.code = %s)
               LIMIT %s""",
            (sector_code, sector_code, limit),
        )
        rows = cur.fetchall()
    now = datetime.now(timezone.utc)
    out = []
    for r in rows:
        days = None if r["last_paid"] is None else (now - r["last_paid"]).days
        color = "red" if days is None or days >= settings.ROUTE_DUE_DAYS else ("yellow" if days >= settings.ROUTE_WARNING_DAYS else "green")
        out.append({"property_code": r["property_code"], "lat": r["lat"], "lng": r["lng"],
                    "property_class": r["property_class"], "sector_code": r["sector_code"], "status_color": color})
    return out


# Which audit actions appear in the live feed, how serious they are, and their Arabic label.
FEED = {
    "sos": ("critical", "نداء استغاثة"),
    "impossible_speed": ("high", "حركة غير منطقية (احتمال تزييف الموقع)"),
    "mock_location": ("high", "تطبيق تزييف موقع على الهاتف"),
    "geofence_exit": ("high", "خروج من القاطع المخصص"),
    "master_code_failed": ("high", "رمز رئيسي خاطئ"),
    "master_code_limit_reached": ("high", "تجاوز حد الرمز الرئيسي"),
    "employee_phone_blocked": ("high", "محاولة تسجيل رقم موظف كمواطن"),
    "reconciliation_escalate": ("high", "فرق نقدي محال للقيادة"),
    "deposit_rejected": ("high", "رفض إيداع مصرفي"),
    "login_2fa_failed": ("high", "فشل تحقق دخول القيادة"),
    "login_blocked_ip": ("high", "محاولة دخول للقيادة من شبكة غير مسموحة"),
    "master_code_used": ("medium", "استخدام الرمز الرئيسي"),
    "geofence_violation": ("medium", "تسجيل خارج حدود القاطع"),
    "cash_cap_blocked": ("medium", "بلوغ سقف النقد"),
    "reconciliation": ("info", "مطابقة نقدية"),
    "bill_created": ("info", "فاتورة جديدة"),
    "otp_failed": ("low", "رمز مواطن خاطئ"),
    "login_failed": ("low", "فشل تسجيل دخول"),
    "payment_verified": ("info", "تحصيل"),
    "registration_verified": ("info", "تسجيل عقار"),
    "bank_deposit": ("info", "إيداع مصرفي"),
    "sos_acknowledge": ("info", "استلام نداء استغاثة"),
    "deposit_verified": ("info", "تدقيق إيداع"),
}
SEVERITY_ORDER = {"info": 0, "low": 1, "medium": 2, "high": 3, "critical": 4}


def _feed_item(r: dict) -> dict:
    severity, label = FEED[r["action"]]
    d = r["details"] or {}
    text = ""
    # escalate severity from the details where it matters
    if r["action"] == "reconciliation":
        status = d.get("status")
        if status == "shortage":
            severity, text = "high", f"عجز {abs(float(d.get('difference', 0))):,.0f} د.ع"
        elif status == "surplus":
            severity, text = "high", f"زيادة {float(d.get('difference', 0)):,.0f} د.ع"
        else:
            text = "مطابق"
    elif r["action"] == "bill_created":
        flags = d.get("flags") or []
        if d.get("status") == "blocked_review" or "ocr_mismatch" in flags or "high_consumption" in flags:
            severity = "medium"
        text = f"{float(d.get('total', 0)):,.0f} د.ع" + (f" | {', '.join(flags)}" if flags else "")
    elif r["action"] == "payment_verified":
        text = f"{float(d.get('total', 0)):,.0f} د.ع - {d.get('receipt_no', '')}"
        if d.get("method") == "master_code":
            severity = "medium"
            text += " (رمز رئيسي)"
    elif r["action"] == "impossible_speed":
        text = f"{d.get('km_h')} كم/ساعة لمسافة {d.get('meters')} م"
    elif r["action"] in ("master_code_used",):
        text = d.get("reason", "")
    elif r["action"] == "cash_cap_blocked":
        text = f"{float(d.get('cash_in_hand', 0)):,.0f} د.ع بحوزته"
    elif r["action"] == "bank_deposit":
        text = f"{float(d.get('amount', 0)):,.0f} د.ع"
    return {
        "id": r["id"], "action": r["action"], "label": label, "severity": severity, "text": text,
        "employee_code": r["employee_code"], "full_name": r["full_name"], "created_at": r["created_at"].isoformat(),
        "lat": d.get("lat"), "lng": d.get("lng"),
    }


@router.get("/feed")
def feed(after_id: int = 0, limit: int = Query(80, ge=1, le=500),
         min_severity: Literal["info", "low", "medium", "high", "critical"] = "info",
         user: dict = Depends(command_or_admin)):
    """Live event feed. Poll with after_id = the largest id you already have."""
    with get_conn() as conn, dict_cursor(conn) as cur:
        cur.execute(
            """SELECT l.id, l.action, l.details, l.created_at, e.employee_code, e.full_name
               FROM audit_log l LEFT JOIN employees e ON e.id = l.actor_id
               WHERE l.id > %s AND l.action = ANY(%s) AND l.created_at >= NOW() - INTERVAL '3 days'
               ORDER BY l.id DESC LIMIT %s""",
            (after_id, list(FEED.keys()), limit * 3),
        )
        rows = cur.fetchall()
    floor = SEVERITY_ORDER[min_severity]
    items = [i for i in (_feed_item(r) for r in rows) if SEVERITY_ORDER[i["severity"]] >= floor]
    return items[:limit]


@router.get("/trail/{employee_code}")
def trail(employee_code: str, day: date | None = None, user: dict = Depends(command_or_admin)):
    """GPS trail for one employee on one day (default today), plus where he collected, for replay on the map."""
    with get_conn() as conn, dict_cursor(conn) as cur:
        # day boundaries in the operation's local time (Baghdad), computed by PostgreSQL's time-zone database
        cur.execute(
            "SELECT (COALESCE(%s::date, (NOW() AT TIME ZONE %s)::date)) AS d",
            (day, settings.APP_TIMEZONE),
        )
        day = cur.fetchone()["d"]
        cur.execute(
            "SELECT (%s::date)::timestamp AT TIME ZONE %s AS s, ((%s::date) + 1)::timestamp AT TIME ZONE %s AS e",
            (day, settings.APP_TIMEZONE, day, settings.APP_TIMEZONE),
        )
        bounds = cur.fetchone()
        start, end = bounds["s"], bounds["e"]
        cur.execute("SELECT id, employee_code, full_name, sector_id FROM employees WHERE UPPER(employee_code) = UPPER(%s)",
                    (employee_code,))
        emp = cur.fetchone()
        if not emp:
            raise HTTPException(404, "الموظف غير موجود")
        cur.execute(
            """SELECT lat, lng, accuracy_m, is_mocked, inside_sector, recorded_at FROM location_pings
               WHERE employee_id = %s AND recorded_at >= %s AND recorded_at < %s ORDER BY recorded_at""",
            (emp["id"], start, end),
        )
        points = cur.fetchall()
        cur.execute(
            """SELECT r.receipt_no, r.total_amount, r.verification_method, r.issued_at, p.lat, p.lng, p.property_code
               FROM receipts r JOIN properties p ON p.id = r.property_id
               WHERE r.collector_id = %s AND r.issued_at >= %s AND r.issued_at < %s ORDER BY r.issued_at""",
            (emp["id"], start, end),
        )
        stops = cur.fetchall()
        sector = None
        if emp["sector_id"]:
            cur.execute("SELECT code, name, polygon FROM sectors WHERE id = %s", (emp["sector_id"],))
            sector = cur.fetchone()
    dist = 0.0
    for a, b in zip(points, points[1:]):
        dist += haversine_m(a["lat"], a["lng"], b["lat"], b["lng"])
    return {
        "employee_code": emp["employee_code"], "full_name": emp["full_name"], "day": day.isoformat(),
        "sector": sector,
        "distance_km": round(dist / 1000, 2),
        "points": [{"lat": p["lat"], "lng": p["lng"], "accuracy_m": p["accuracy_m"], "is_mocked": p["is_mocked"],
                    "inside_sector": p["inside_sector"], "t": p["recorded_at"].isoformat()} for p in points],
        "stops": [{"receipt_no": s["receipt_no"], "total_amount": float(s["total_amount"]),
                   "verification_method": s["verification_method"], "t": s["issued_at"].isoformat(),
                   "lat": s["lat"], "lng": s["lng"], "property_code": s["property_code"]} for s in stops],
    }


@router.get("/sectors")
def sector_progress(user: dict = Depends(command_or_admin)):
    with get_conn() as conn, dict_cursor(conn) as cur:
        cur.execute(
            """SELECT s.code, s.name, s.mahalla, s.polygon,
                      COUNT(p.id) FILTER (WHERE p.status = 'active') AS properties,
                      COUNT(p.id) FILTER (WHERE p.status = 'active' AND lp.last_paid >= NOW() - (%(due)s || ' days')::interval) AS paid_in_cycle,
                      COUNT(p.id) FILTER (WHERE p.status = 'active' AND (lp.last_paid IS NULL OR lp.last_paid < NOW() - (%(due)s || ' days')::interval)) AS due,
                      COUNT(p.id) FILTER (WHERE p.activated_at >= date_trunc('day', NOW())) AS registered_today,
                      (SELECT COALESCE(SUM(r.total_amount),0) FROM receipts r JOIN properties pp ON pp.id = r.property_id
                          WHERE pp.sector_id = s.id AND r.issued_at >= date_trunc('day', NOW())) AS collected_today,
                      (SELECT COALESCE(SUM(r.total_amount),0) FROM receipts r JOIN properties pp ON pp.id = r.property_id
                          WHERE pp.sector_id = s.id AND r.issued_at >= date_trunc('month', NOW())) AS collected_month,
                      (SELECT COUNT(*) FROM employees e WHERE e.sector_id = s.id AND e.role = 'collector' AND e.active) AS collectors
               FROM sectors s
               LEFT JOIN properties p ON p.sector_id = s.id
               LEFT JOIN LATERAL (SELECT MAX(paid_at) AS last_paid FROM bills b WHERE b.property_id = p.id AND b.status = 'paid') lp ON TRUE
               WHERE s.active
               GROUP BY s.id ORDER BY s.code""",
            {"due": settings.ROUTE_DUE_DAYS},
        )
        rows = cur.fetchall()
    for r in rows:
        r["collected_today"] = float(r["collected_today"])
        r["collected_month"] = float(r["collected_month"])
        r["coverage"] = round(r["paid_in_cycle"] / r["properties"], 3) if r["properties"] else 0.0
    return rows


@router.get("/leaderboard")
def leaderboard(days: int = Query(1, ge=1, le=90), user: dict = Depends(command_or_admin)):
    """Collector ranking over the last N days (1 = today). Includes risk signals, not only money."""
    with get_conn() as conn, dict_cursor(conn) as cur:
        cur.execute(
            """WITH since AS (SELECT CASE WHEN %(days)s = 1 THEN date_trunc('day', NOW())
                                          ELSE NOW() - (%(days)s || ' days')::interval END AS t)
               SELECT e.employee_code, e.full_name, s.name AS sector_name,
                      COALESCE(SUM(r.total_amount), 0) AS collected,
                      COUNT(r.id) AS receipts,
                      COUNT(r.id) FILTER (WHERE r.verification_method = 'master_code') AS master_code_receipts,
                      (SELECT COUNT(*) FROM properties p WHERE p.registered_by = e.id AND p.activated_at >= (SELECT t FROM since)) AS registrations,
                      (SELECT COUNT(*) FROM bills b WHERE b.collector_id = e.id AND b.created_at >= (SELECT t FROM since)
                          AND b.billing_method = 'estimate') AS estimates,
                      (SELECT COALESCE(SUM(difference), 0) FROM reconciliations x WHERE x.collector_id = e.id
                          AND x.created_at >= (SELECT t FROM since)) AS cash_difference,
                      (SELECT COUNT(*) FROM audit_log l WHERE l.actor_id = e.id AND l.created_at >= (SELECT t FROM since)
                          AND l.action IN ('geofence_exit','mock_location','impossible_speed','master_code_failed','employee_phone_blocked')) AS security_events
               FROM employees e
               LEFT JOIN sectors s ON s.id = e.sector_id
               LEFT JOIN receipts r ON r.collector_id = e.id AND r.issued_at >= (SELECT t FROM since)
               WHERE e.role = 'collector' AND e.active
               GROUP BY e.id, s.name
               ORDER BY collected DESC""",
            {"days": days},
        )
        rows = cur.fetchall()
    for r in rows:
        r["collected"] = float(r["collected"])
        r["cash_difference"] = float(r["cash_difference"])
    return rows


@router.get("/health")
def system_health(user: dict = Depends(command_or_admin)):
    with get_conn() as conn, dict_cursor(conn) as cur:
        cur.execute("SELECT NOW() AS now, version() AS version")
        db = cur.fetchone()
        cur.execute(
            """SELECT COUNT(*) FILTER (WHERE status = 'failed' AND created_at >= NOW() - INTERVAL '1 hour') AS failed_hour,
                      COUNT(*) FILTER (WHERE created_at >= NOW() - INTERVAL '1 hour') AS sent_hour,
                      MAX(created_at) FILTER (WHERE status IN ('sent','console')) AS last_ok
               FROM whatsapp_messages"""
        )
        wa = cur.fetchone()
        cur.execute("SELECT MAX(received_at) AS last_ping, COUNT(*) FILTER (WHERE received_at >= NOW() - INTERVAL '5 minutes') AS pings_5min FROM location_pings")
        pings = cur.fetchone()
        cur.execute("SELECT COUNT(*) AS n FROM audit_log")
        audit_rows = cur.fetchone()["n"]
    usage = shutil.disk_usage(files._root().parent if not files._root().exists() else files._root())
    return {
        "database": {"ok": True, "server_time": db["now"].isoformat(), "version": db["version"].split(",")[0]},
        "whatsapp": {"mode": settings.WHATSAPP_MODE, "sent_last_hour": wa["sent_hour"], "failed_last_hour": wa["failed_hour"],
                     "last_success": _iso(wa["last_ok"])},
        "tracking": {"last_ping": _iso(pings["last_ping"]), "pings_last_5_min": pings["pings_5min"]},
        "storage": {"free_gb": round(usage.free / 1e9, 1), "total_gb": round(usage.total / 1e9, 1)},
        "audit_log_rows": audit_rows,
        "geofence_enforced": settings.ENFORCE_GEOFENCE,
        "two_factor_roles": settings.TWO_FACTOR_ROLES,
    }


# ================================================================ messages to the field

class MessageIn(BaseModel):
    audience: Literal["one", "all", "collectors", "supervisors"]
    employee_code: str | None = None
    body: str = Field(..., min_length=2, max_length=1000)
    priority: Literal["normal", "urgent"] = "normal"


@router.post("/messages")
def send_message(body: MessageIn, user: dict = Depends(command_or_admin)):
    with get_conn() as conn, dict_cursor(conn) as cur:
        recipient_id = None
        if body.audience == "one":
            if not body.employee_code:
                raise HTTPException(422, "يجب اختيار الموظف")
            cur.execute("SELECT id FROM employees WHERE UPPER(employee_code) = UPPER(%s) AND active", (body.employee_code,))
            r = cur.fetchone()
            if not r:
                raise HTTPException(404, "الموظف غير موجود")
            recipient_id = r["id"]
        cur.execute(
            "INSERT INTO messages (sender_id, recipient_id, audience, body, priority) VALUES (%s,%s,%s,%s,%s) RETURNING id",
            (user["id"], recipient_id, body.audience, body.body.strip(), body.priority),
        )
        mid = cur.fetchone()["id"]
        audit.log(cur, user["id"], "message_sent", "message", mid,
                  {"audience": body.audience, "to": body.employee_code, "priority": body.priority})
    return {"message_id": mid}


@router.get("/messages")
def sent_messages(user: dict = Depends(command_or_admin)):
    with get_conn() as conn, dict_cursor(conn) as cur:
        cur.execute(
            """SELECT m.id, m.body, m.priority, m.audience, m.created_at, r.employee_code AS recipient_code,
                      (SELECT COUNT(*) FROM message_reads mr WHERE mr.message_id = m.id) AS reads
               FROM messages m LEFT JOIN employees r ON r.id = m.recipient_id
               ORDER BY m.created_at DESC LIMIT 100"""
        )
        rows = cur.fetchall()
    for r in rows:
        r["created_at"] = r["created_at"].isoformat()
    return rows
