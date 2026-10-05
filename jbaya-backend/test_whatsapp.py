import requests

# Payload matching your FastAPI WhatsApp schema
payload = {
    "phone_number": "+9647800000000",  # Replace with your actual number to test
    "subscriber_name": "محمد عبد الله كاظم",
    "serial_number": "MCH-883920",
    "amount_due": 45000.0,
    "mahalla": "محلة 653 - حي الجامعة"
}

try:
    response = requests.post("http://127.0.0.1:8000/send-whatsapp", json=payload)
    print("--- WhatsApp Endpoint Response ---")
    print(response.json())
except Exception as e:
    print(f"Failed to connect to backend: {e}")