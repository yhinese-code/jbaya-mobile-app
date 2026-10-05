"""SOS alerts and escalations.
Supervisors see their own team's alerts; Command (and admin) see everything."""
from typing import Literal

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field

from .. import audit
from ..db import dict_cursor, get_conn
from ..security import require_roles

router = APIRouter(tags=["alerts"])
viewer = require_roles("supervisor", "command")


def _scope(user: dict) -> tuple[str, tuple]:
    if user["role"] == "supervisor":
        return "e.supervisor_id = %s", (user["id"],)
    return "TRUE", ()


@router.get("/alerts")
def list_alerts(include_closed: bool = False, user: dict = Depends(viewer)):
    cond, args = _scope(user)
    with get_conn() as conn, dict_cursor(conn) as cur:
        cur.execute(
            f"""SELECT a.id, a.lat, a.lng, a.gps_accuracy_m, a.note, a.status, a.created_at, a.acknowledged_at,
                       e.employee_code, e.full_name, e.role, s.name AS sector_name, ack.employee_code AS acknowledged_by
                FROM sos_alerts a
                JOIN employees e ON e.id = a.employee_id
                LEFT JOIN sectors s ON s.id = e.sector_id
                LEFT JOIN employees ack ON ack.id = a.acknowledged_by
                WHERE {cond} AND (%s OR a.status <> 'closed') AND a.created_at >= NOW() - INTERVAL '7 days'
                ORDER BY (a.status = 'open') DESC, a.created_at DESC""",
            (*args, include_closed),
        )
        rows = cur.fetchall()
    for r in rows:
        r["created_at"] = r["created_at"].isoformat()
        r["acknowledged_at"] = r["acknowledged_at"].isoformat() if r["acknowledged_at"] else None
    return rows


class AlertActionIn(BaseModel):
    action: Literal["acknowledge", "close"]
    note: str | None = Field(None, max_length=500)


@router.post("/alerts/{alert_id}")
def act_on_alert(alert_id: int, body: AlertActionIn, user: dict = Depends(viewer)):
    cond, args = _scope(user)
    with get_conn() as conn, dict_cursor(conn) as cur:
        cur.execute(
            f"SELECT a.* FROM sos_alerts a JOIN employees e ON e.id = a.employee_id WHERE a.id = %s AND {cond} FOR UPDATE OF a",
            (alert_id, *args),
        )
        a = cur.fetchone()
        if not a:
            raise HTTPException(404, "التنبيه غير موجود")
        if body.action == "acknowledge":
            if a["status"] != "open":
                raise HTTPException(409, "تم استلام هذا التنبيه مسبقاً")
            cur.execute("UPDATE sos_alerts SET status = 'acknowledged', acknowledged_by = %s, acknowledged_at = NOW() WHERE id = %s",
                        (user["id"], alert_id))
        else:
            cur.execute(
                """UPDATE sos_alerts SET status = 'closed', acknowledged_by = COALESCE(acknowledged_by, %s),
                          acknowledged_at = COALESCE(acknowledged_at, NOW()) WHERE id = %s""",
                (user["id"], alert_id),
            )
        audit.log(cur, user["id"], f"sos_{body.action}", "sos", alert_id, {"note": body.note})
    return {"alert_id": alert_id, "status": "acknowledged" if body.action == "acknowledge" else "closed"}


@router.get("/command/escalations")
def escalations(user: dict = Depends(require_roles("command"))):
    """Cash discrepancies the supervisor escalated, plus any discrepancy still unresolved after 24 hours."""
    with get_conn() as conn, dict_cursor(conn) as cur:
        cur.execute(
            """SELECT r.id, r.created_at, r.counted_cash, r.expected_cash, r.difference, r.status, r.resolution_status,
                      r.resolution_note, c.employee_code AS collector_code, c.full_name AS collector_name,
                      s.employee_code AS supervisor_code
               FROM reconciliations r
               JOIN employees c ON c.id = r.collector_id
               JOIN employees s ON s.id = r.supervisor_id
               WHERE r.resolution_status = 'escalated'
                  OR (r.resolution_status = 'pending' AND r.created_at < NOW() - INTERVAL '24 hours')
               ORDER BY r.created_at DESC LIMIT 100"""
        )
        rows = cur.fetchall()
    for r in rows:
        for k in ("counted_cash", "expected_cash", "difference"):
            r[k] = float(r[k])
        r["created_at"] = r["created_at"].isoformat()
    return rows
