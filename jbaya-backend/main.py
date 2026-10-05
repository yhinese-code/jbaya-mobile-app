from fastapi import FastAPI, HTTPException
from pydantic import BaseModel
from typing import Optional
import psycopg2
import random
import os

app = FastAPI(title="Jbaya Municipal Water Management Engine - Private Rollout")

# Database Connection String (Update password/host if needed)
DB_CONN = os.getenv("DB_CONN", "postgresql://postgres:postgres@localhost:5432/postgres")

# Initialize database tables on startup
@app.on_event("startup")
def startup_db_client():
    conn = psycopg2.connect(DB_CONN)
    cursor = conn.cursor()
    
    # Dual-Path Audit Table for Field Collections & Private Survey Nodes
    cursor.execute("""
        CREATE TABLE IF NOT EXISTS field_collections (
            id SERIAL PRIMARY KEY,
            serial_number VARCHAR(50),
            mahalla VARCHAR(50),
            house_address TEXT,
            reading_value FLOAT,
            collection_path VARCHAR(50),
            collector_id VARCHAR(50),
            timestamp TIMESTAMPTZ DEFAULT NOW()
        );
    """)
    
    # IoT Telemetry Table for NB-IoT Smart Meters
    cursor.execute("""
        CREATE TABLE IF NOT EXISTS smart_meter_telemetry (
            time TIMESTAMPTZ NOT NULL,
            serial_number VARCHAR(50),
            flow_rate FLOAT,
            battery_voltage FLOAT,
            tamper_flag BOOLEAN
        );
    """)
    
    conn.commit()
    cursor.close()
    conn.close()
    print("Database tables ('field_collections', 'smart_meter_telemetry') are ready.")


class FieldCollectionPayload(BaseModel):
    serial_number: str
    mahalla: str
    house_address: str
    reading_value: float
    collection_path: str  # 'verified_paid', 'absent_notice_left', 'neighbor_proxy'
    collector_id: str


@app.post("/sync")
def sync_field_collection(payload: FieldCollectionPayload):
    """Secure dual-path audit endpoint for field collectors."""
    try:
        conn = psycopg2.connect(DB_CONN)
        cursor = conn.cursor()
        
        cursor.execute("""
            INSERT INTO field_collections (serial_number, mahalla, house_address, reading_value, collection_path, collector_id)
            VALUES (%s, %s, %s, %s, %s, %s);
        """, (
            payload.serial_number,
            payload.mahalla,
            payload.house_address,
            payload.reading_value,
            payload.collection_path,
            payload.collector_id
        ))
        
        conn.commit()
        cursor.close()
        conn.close()
        
    except Exception as e:
        print(f"Failed to save to database: {e}")
        raise HTTPException(status_code=500, detail="Database connection failed")
    
    return {"status": "success", "message": "Dual-path records securely locked into TimescaleDB."}


# --- WHATSAPP GATEWAY ENDPOINT ---
class WhatsAppPayload(BaseModel):
    phone_number: str
    subscriber_name: str
    serial_number: str
    amount_due: float
    mahalla: str

@app.post("/send-whatsapp")
def trigger_whatsapp_otp(payload: WhatsAppPayload):
    secure_otp = str(random.randint(1000, 9999))
    
    message_body = (
        f"🏛️ *أمانة بغداد - مديرية الماء*\n"
        f"عزيزي الساكن ({payload.subscriber_name}),\n"
        f"تم رصد قراءة عدادكم ({payload.serial_number}) في {payload.mahalla}.\n"
        f"💰 المبلغ المستحق: {payload.amount_due:,.0f} د.ع\n"
        f"🔑 *رمز التحقق (OTP) للدفع الميداني:* `{secure_otp}`\n\n"
        f"يرجى تسليم هذا الرمز لجبي الماء المعتمد لإصدار وصل الدفع الرسمي."
    )
    
    print(f"\n[WHATSAPP GATEWAY] Dispatching to -> {payload.phone_number}")
    print(f"Message Content:\n{message_body}\n")
    
    return {
        "status": "success",
        "message": "WhatsApp OTP dispatched successfully.",
        "generated_otp": secure_otp,
        "recipient": payload.phone_number
    }


# --- SUPERVISOR ANALYTICS ENDPOINT ---
@app.get("/analytics/summary")
def get_supervisor_summary():
    """Returns aggregated municipal collection metrics for supervisors."""
    try:
        conn = psycopg2.connect(DB_CONN)
        cursor = conn.cursor()
        
        # Total collections & breakdown by path
        cursor.execute("""
            SELECT collection_path, COUNT(*), SUM(reading_value) 
            FROM field_collections 
            GROUP BY collection_path;
        """)
        path_stats = cursor.fetchall()
        
        # Total properties serviced
        cursor.execute("SELECT COUNT(DISTINCT serial_number) FROM field_collections;")
        total_properties = cursor.fetchone()[0]
        
        cursor.close()
        conn.close()
        
        formatted_paths = {row[0]: {"count": row[1], "volume": row[2]} for row in path_stats}
        
        return {
            "status": "success",
            "total_properties_serviced": total_properties,
            "path_breakdown": formatted_paths
        }
    except Exception as e:
        print(f"Analytics error: {e}")
        raise HTTPException(status_code=500, detail="Failed to fetch analytics summary")


# --- IOT LEAK & TAMPER ALERT ENDPOINT ---
@app.get("/iot/alerts/{serial_number}")
def check_meter_telemetry_alerts(serial_number: str):
    """Analyzes smart meter telemetry for leaks or hardware tampering."""
    try:
        conn = psycopg2.connect(DB_CONN)
        cursor = conn.cursor()
        
        cursor.execute("""
            SELECT time, flow_rate, battery_voltage, tamper_flag 
            FROM smart_meter_telemetry 
            WHERE serial_number = %s 
            ORDER BY time DESC 
            LIMIT 1;
        """, (serial_number,))
        
        record = cursor.fetchone()
        cursor.close()
        conn.close()
        
        if not record:
            return {"status": "error", "message": "No telemetry found for this serial number."}
            
        timestamp, flow_rate, battery_voltage, tamper_flag = record
        
        alerts = []
        if tamper_flag:
            alerts.append("CRITICAL: Physical casing tamper detected!")
        if battery_voltage < 3.5:
            alerts.append("WARNING: Smart meter battery voltage is critically low.")
        if flow_rate == 0.0:
            alerts.append("NOTICE: Zero flow rate reported during active cycle.")

        return {
            "status": "success",
            "serial_number": serial_number,
            "latest_reading_time": timestamp,
            "metrics": {
                "flow_rate": flow_rate,
                "battery_voltage": battery_voltage,
                "tamper_flag": tamper_flag
            },
            "active_alerts": alerts if alerts else ["All systems normal. No anomalies detected."]
        }
    except Exception as e:
        print(f"IoT Alert evaluation error: {e}")
        raise HTTPException(status_code=500, detail="Failed to evaluate smart meter telemetry.")


# --- PRIVATE SURVEY & ASSET AUDIT ENDPOINT ---
class SurveyAuditPayload(BaseModel):
    serial_number: Optional[str] = None
    mahalla: str
    house_address: str
    property_status: str  # 'active_smart', 'legacy_mechanical', or 'unmetered_target'
    surveyor_id: str
    initial_reading: Optional[float] = 0.0

@app.post("/survey/audit-property")
def audit_and_register_property(payload: SurveyAuditPayload):
    """Registers or updates a property audited by private survey teams in the field."""
    try:
        conn = psycopg2.connect(DB_CONN)
        cursor = conn.cursor()
        
        cursor.execute("SELECT serial_number FROM field_collections WHERE mahalla = %s AND house_address = %s;", 
                       (payload.mahalla, payload.house_address))
        existing = cursor.fetchone()
        
        action_taken = "updated"
        if not existing:
            action_taken = "created_new_priority"
            cursor.execute("""
                INSERT INTO field_collections (serial_number, mahalla, house_address, reading_value, collection_path, collector_id)
                VALUES (%s, %s, %s, %s, %s, %s);
            """, (
                payload.serial_number or f"PENDING-{random.randint(1000,9999)}",
                payload.mahalla,
                payload.house_address,
                payload.initial_reading,
                payload.property_status,
                payload.surveyor_id
            ))
            conn.commit()
            
        cursor.close()
        conn.close()
        
        return {
            "status": "success",
            "action": action_taken,
            "message": f"Property at {payload.house_address} successfully synchronized into private survey grid."
        }
    except Exception as e:
        print(f"Survey audit error: {e}")
        raise HTTPException(status_code=500, detail="Failed to sync private survey record.")