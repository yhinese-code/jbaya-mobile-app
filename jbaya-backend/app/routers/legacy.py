"""Endpoints from the first prototype, kept so older screens keep working.
Changes: they now require login, and /send-whatsapp was REMOVED (it returned the OTP to the caller)."""
import random
from typing import Optional

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel

from ..db import dict_cursor, get_conn
from ..security import current_user

router = APIRouter(tags=["legacy"])


class FieldCollectionPayload(BaseModel):
    serial_number: str
    mahalla: str
    house_address: str
    reading_value: float
    collection_path: str
    collector_id: str


@router.post("/sync")
def sync_field_collection(payload: FieldCollectionPayload, user: dict = Depends(current_user)):
    with get_conn() as conn, conn.cursor() as cur:
        cur.execute(
            """INSERT INTO field_collections (serial_number, mahalla, house_address, reading_value, collection_path, collector_id)
               VALUES (%s, %s, %s, %s, %s, %s)""",
            (payload.serial_number, payload.mahalla, payload.house_address, payload.reading_value,
             payload.collection_path, user["employee_code"]),
        )
    return {"status": "success"}


@router.get("/analytics/summary")
def get_supervisor_summary(user: dict = Depends(current_user)):
    with get_conn() as conn, conn.cursor() as cur:
        cur.execute("SELECT collection_path, COUNT(*), SUM(reading_value) FROM field_collections GROUP BY collection_path")
        path_stats = cur.fetchall()
        cur.execute("SELECT COUNT(DISTINCT serial_number) FROM field_collections")
        total_properties = cur.fetchone()[0]
    return {
        "status": "success",
        "total_properties_serviced": total_properties,
        "path_breakdown": {row[0]: {"count": row[1], "volume": row[2]} for row in path_stats},
    }


@router.get("/iot/alerts/{serial_number}")
def check_meter_telemetry_alerts(serial_number: str, user: dict = Depends(current_user)):
    with get_conn() as conn, conn.cursor() as cur:
        cur.execute(
            """SELECT time, flow_rate, battery_voltage, tamper_flag FROM smart_meter_telemetry
               WHERE serial_number = %s ORDER BY time DESC LIMIT 1""",
            (serial_number,),
        )
        record = cur.fetchone()
    if not record:
        return {"status": "error", "message": "No telemetry found for this serial number."}
    timestamp, flow_rate, battery_voltage, tamper_flag = record
    alerts = []
    if tamper_flag:
        alerts.append("CRITICAL: Physical casing tamper detected!")
    if battery_voltage is not None and battery_voltage < 3.5:
        alerts.append("WARNING: Smart meter battery voltage is critically low.")
    if flow_rate == 0.0:
        alerts.append("NOTICE: Zero flow rate reported during active cycle.")
    return {
        "status": "success",
        "serial_number": serial_number,
        "latest_reading_time": timestamp,
        "metrics": {"flow_rate": flow_rate, "battery_voltage": battery_voltage, "tamper_flag": tamper_flag},
        "active_alerts": alerts or ["All systems normal. No anomalies detected."],
    }


class SurveyAuditPayload(BaseModel):
    serial_number: Optional[str] = None
    mahalla: str
    house_address: str
    property_status: str
    surveyor_id: Optional[str] = None
    initial_reading: Optional[float] = 0.0


@router.post("/survey/audit-property")
def audit_and_register_property(payload: SurveyAuditPayload, user: dict = Depends(current_user)):
    with get_conn() as conn, dict_cursor(conn) as cur:
        cur.execute("SELECT serial_number FROM field_collections WHERE mahalla = %s AND house_address = %s",
                    (payload.mahalla, payload.house_address))
        existing = cur.fetchone()
        action = "updated"
        if not existing:
            action = "created_new_priority"
            cur.execute(
                """INSERT INTO field_collections (serial_number, mahalla, house_address, reading_value, collection_path, collector_id)
                   VALUES (%s, %s, %s, %s, %s, %s)""",
                (payload.serial_number or f"PENDING-{random.randint(100000, 999999)}", payload.mahalla,
                 payload.house_address, payload.initial_reading, payload.property_status, user["employee_code"]),
            )
    if action is None:
        raise HTTPException(500, "Failed to sync private survey record.")
    return {"status": "success", "action": action,
            "message": f"Property at {payload.house_address} successfully synchronized into private survey grid."}
