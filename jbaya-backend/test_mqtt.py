import paho.mqtt.client as mqtt

client = mqtt.Client()
client.connect("127.0.0.1", 1883, 60)

payload = '{"flow_rate": 12.5, "total_consumption": 156.4, "battery_voltage": 3.65, "signal_rssi": -65}'
client.publish("baghdad/water/meters/MCH-883920/telemetry", payload)
print("Mock smart meter packet successfully sent to EMQX!")