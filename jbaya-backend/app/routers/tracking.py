"""Live tracking from the field app + the employee message inbox.

The app sends its GPS position every ~30 s (batched, so fixes taken while offline are not lost).
The server turns suspicious movement into audit events that feed the Central Command alert feed:
  geofence_exit     collector left his sector (logged on the transition only)
  mock_location     the phone reports a fake-GPS app (at most once per 30 min)
  impossible_speed  two fixes imply > MAX_PLAUSIBLE_SPEED_MPS (teleporting = spoofing or a shared account)
"""
from datetime import datetime, timedelta, timezone

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field

from .. import audit
from ..config import settings
from ..db import dict_cursor, get_conn
from ..security import current_user, require_roles
from ..utils import haversine_m, point_in_polygon

router = APIRouter(tags=["tracking"])
field_staff = require_roles("collector", "supervisor")


class PingIn(BaseModel):
    lat: float = Field(..., ge=-90, le=90)
    lng: float = Field(..., ge=-180, le=180)
    accuracy_m: float | None = None
    speed_mps: float | None = None
    is_mocked: bool = False
    recorded_at: datetime | None = None   # phone time of the fix; server time if missing


class PingBatchIn(BaseModel):
    points: list[PingIn] = Field(..., min_length=1)


@router.post("/tracking/ping")
def ping(body: PingBatchIn, user: dict = Depends(field_staff)):
    if len(body.points) > settings.MAX_PINGS_PER_REQUEST:
        raise HTTPException(413, "عدد كبير من النقاط في طلب واحد")
    now = datetime.now(timezone.utc)
    accepted = 0
    events = []
    with get_conn() as conn, dict_cursor(conn) as cur:
        polygon = None
        if user["sector_id"]:
            cur.execute("SELECT polygon FROM sectors WHERE id = %s", (user["sector_id"],))
            row = cur.fetchone()
            polygon = row["polygon"] if row else None
        cur.execute(
            "SELECT lat, lng, accuracy_m, inside_sector, recorded_at FROM location_pings "
            "WHERE employee_id = %s ORDER BY recorded_at DESC LIMIT 1",
            (user["id"],),
        )
        prev = cur.fetchone()
        cur.execute(
            "SELECT MAX(created_at) AS t FROM audit_log WHERE actor_id = %s AND action = 'mock_location'",
            (user["id"],),
        )
        last_mock_event = cur.fetchone()["t"]

        points = sorted(body.points, key=lambda p: p.recorded_at or now)
        for p in points:
            t = p.recorded_at or now
            if t.tzinfo is None:
                t = t.replace(tzinfo=timezone.utc)
            # ignore clock-skewed / stale fixes
            if t > now + timedelta(minutes=5) or t < now - timedelta(hours=24):
                continue
            if prev and t <= prev["recorded_at"]:
                continue
            good_fix = p.accuracy_m is None or p.accuracy_m <= max(settings.MAX_GPS_ACCURACY_METERS, 100)
            inside = point_in_polygon(p.lat, p.lng, polygon) if (polygon and user["role"] == "collector") else None

            if p.is_mocked and (last_mock_event is None or (now - last_mock_event).total_seconds() > 1800):
                events.append(("mock_location", {"lat": p.lat, "lng": p.lng}))
                last_mock_event = now
            if (settings.ENFORCE_GEOFENCE and good_fix and inside is False
                    and (prev is None or prev["inside_sector"] is not False)):
                events.append(("geofence_exit", {"lat": p.lat, "lng": p.lng, "accuracy_m": p.accuracy_m}))
            if prev and good_fix and (prev["accuracy_m"] is None or prev["accuracy_m"] <= 100):
                seconds = (t - prev["recorded_at"]).total_seconds()
                dist = haversine_m(prev["lat"], prev["lng"], p.lat, p.lng)
                if seconds > 0 and dist > 500 and dist / seconds > settings.MAX_PLAUSIBLE_SPEED_MPS:
                    events.append(("impossible_speed", {"km_h": round(dist / seconds * 3.6), "meters": round(dist),
                                                        "seconds": round(seconds)}))

            cur.execute(
                """INSERT INTO location_pings (employee_id, lat, lng, accuracy_m, speed_mps, is_mocked, inside_sector, recorded_at)
                   VALUES (%s,%s,%s,%s,%s,%s,%s,%s)""",
                (user["id"], p.lat, p.lng, p.accuracy_m, p.speed_mps, p.is_mocked, inside, t),
            )
            prev = {"lat": p.lat, "lng": p.lng, "accuracy_m": p.accuracy_m, "inside_sector": inside, "recorded_at": t}
            accepted += 1

        for action, details in events:
            audit.log(cur, user["id"], action, "employee", user["employee_code"], details)
    return {"accepted": accepted, "events": [e[0] for e in events]}


# ---------------------------------------------------------------- messages (Command -> field)

def _visible_messages_sql() -> str:
    return """(m.recipient_id = %(me)s
               OR m.audience = 'all'
               OR (m.audience = 'collectors' AND %(role)s = 'collector')
               OR (m.audience = 'supervisors' AND %(role)s = 'supervisor'))
              AND m.created_at >= NOW() - INTERVAL '14 days'"""


@router.get("/messages/inbox")
def inbox(user: dict = Depends(current_user)):
    with get_conn() as conn, dict_cursor(conn) as cur:
        cur.execute(
            f"""SELECT m.id, m.body, m.priority, m.audience, m.created_at, s.employee_code AS sender_code,
                       s.full_name AS sender_name, (r.message_id IS NOT NULL) AS is_read
                FROM messages m
                JOIN employees s ON s.id = m.sender_id
                LEFT JOIN message_reads r ON r.message_id = m.id AND r.employee_id = %(me)s
                WHERE {_visible_messages_sql()}
                ORDER BY m.created_at DESC LIMIT 50""",
            {"me": user["id"], "role": user["role"]},
        )
        rows = cur.fetchall()
    for r in rows:
        r["created_at"] = r["created_at"].isoformat()
    return {"messages": rows, "unread": sum(1 for r in rows if not r["is_read"])}


@router.post("/messages/{message_id}/read")
def mark_read(message_id: int, user: dict = Depends(current_user)):
    with get_conn() as conn, dict_cursor(conn) as cur:
        cur.execute(f"SELECT m.id FROM messages m WHERE m.id = %(id)s AND {_visible_messages_sql()}",
                    {"id": message_id, "me": user["id"], "role": user["role"]})
        if not cur.fetchone():
            raise HTTPException(404, "الرسالة غير موجودة")
        cur.execute("INSERT INTO message_reads (message_id, employee_id) VALUES (%s, %s) ON CONFLICT DO NOTHING",
                    (message_id, user["id"]))
    return {"ok": True}
