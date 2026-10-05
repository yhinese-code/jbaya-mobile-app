import json
import paho.mqtt.client as mqtt
import psycopg2
from datetime import datetime

# --- TIMESCALEDB CREDENTIALS ---
import os
from dotenv import load_dotenv
load_dotenv()
from dotenv import load_dotenv
load_dotenv()
DB_CONN = os.getenv("DB_CONN")

# --- EMQX BROKER CONFIGURATION ---
# Running locally via your Docker container
MQTT_BROKER = "127.0.0.1"
MQTT_PORT = 1883
MQTT_TOPIC = "baghdad/water/meters/+/telemetry"

def init_iot_table():
    """Ensure the smart meter telemetry table exists in TimescaleDB"""
    try:
        conn = psycopg2.connect(DB_CONN)
        cursor = conn.cursor()
        cursor.execute("""
            CREATE TABLE IF NOT EXISTS smart_meter_telemetry (
                id SERIAL PRIMARY KEY,
                serial_number VARCHAR(50) NOT NULL,
                flow_rate FLOAT,
                total_consumption FLOAT,
                battery_voltage FLOAT,
                signal_rssi INT,
                timestamp TIMESTAMPTZ NOT NULL DEFAULT NOW()
            );
        """)
        conn.commit()
        cursor.close()
        conn.close()
        print("IoT Telemetry table 'smart_meter_telemetry' initialized.")
    except Exception as e:
        print(f"Database error initializing IoT table: {e}")

def on_connect(client, userdata, flags, rc):
    if rc == 0:
        print("Connected to EMQX MQTT Broker successfully!")
        client.subscribe(MQTT_TOPIC)
    else:
        print(f"Failed to connect to EMQX, return code {rc}")

def on_message(client, userdata, msg):
    try:
        payload_str = msg.payload.decode('utf-8')
        data = json.loads(payload_str)
        
        # Extract wildcard topic match for serial number if needed
        # Topic format: baghdad/water/meters/MCH-883920/telemetry
        topic_parts = msg.topic.split('/')
        serial_number = topic_parts[4] if len(topic_parts) > 4 else data.get("serial_number", "UNKNOWN")
        
        flow_rate = data.get("flow_rate", 0.0)
        total_consumption = data.get("total_consumption", 0.0)
        battery_voltage = data.get("battery_voltage", 3.6)
        signal_rssi = data.get("signal_rssi", -70)
        timestamp = data.get("timestamp", datetime.now().isoformat())

        # Save to TimescaleDB
        conn = psycopg2.connect(DB_CONN)
        cursor = conn.cursor()
        cursor.execute("""
            INSERT INTO smart_meter_telemetry 
            (serial_number, flow_rate, total_consumption, battery_voltage, signal_rssi, timestamp)
            VALUES (%s, %s, %s, %s, %s, %s)
        """, (serial_number, flow_rate, total_consumption, battery_voltage, signal_rssi, timestamp))
        conn.commit()
        cursor.close()
        conn.close()

        print(f" [IoT Data Logged] Meter: {serial_number} | Consumption: {total_consumption}m3 | Flow: {flow_rate}L/h")

    except Exception as e:
        print(f"Error processing MQTT message: {e}")

if __name__ == "__main__":
    init_iot_table()
    
    client = mqtt.Client()
    client.on_connect = on_connect
    client.on_message = on_message
    
    print(f"Connecting to EMQX Broker at {MQTT_BROKER}:{MQTT_PORT}...")
    client.connect(MQTT_BROKER, MQTT_PORT, 60)
    
    # Keep the background listener running
    client.loop_forever()