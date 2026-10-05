"""Central settings, read once from environment / .env file."""
import os
from dotenv import load_dotenv

load_dotenv()


def _int(name: str, default: int) -> int:
    return int(os.getenv(name, default))


def _float(name: str, default: float) -> float:
    return float(os.getenv(name, default))


class Settings:
    # --- Database ---
    DB_CONN = os.getenv("DB_CONN", "postgresql://postgres:postgres@localhost:5432/postgres")

    # --- Secrets (MUST be changed in production, see .env.example) ---
    JWT_SECRET = os.getenv("JWT_SECRET", "dev-only-change-me-jwt-0000000000000000")
    OTP_SECRET = os.getenv("OTP_SECRET", "dev-only-change-me-otp-0000000000000000")
    MASTER_CODE_SECRET = os.getenv("MASTER_CODE_SECRET", "dev-only-change-me-master-0000000000000")
    JWT_TTL_HOURS = _int("JWT_TTL_HOURS", 12)

    # --- OTP ---
    OTP_DIGITS = _int("OTP_DIGITS", 6)
    OTP_TTL_SECONDS = _int("OTP_TTL_SECONDS", 300)          # 5 minutes
    OTP_MAX_ATTEMPTS = _int("OTP_MAX_ATTEMPTS", 3)
    OTP_RESEND_COOLDOWN_SECONDS = _int("OTP_RESEND_COOLDOWN_SECONDS", 60)

    # --- Rotating master code (Command only) ---
    MASTER_CODE_WINDOW_SECONDS = _int("MASTER_CODE_WINDOW_SECONDS", 600)   # 10 minutes
    MASTER_CODE_GRACE_SECONDS = _int("MASTER_CODE_GRACE_SECONDS", 60)      # previous code still valid 60s after rotation
    MASTER_CODE_DAILY_LIMIT_PER_COLLECTOR = _int("MASTER_CODE_DAILY_LIMIT_PER_COLLECTOR", 3)

    # --- Billing ---
    COMPANY_FEE_IQD = _float("COMPANY_FEE_IQD", 3000)
    ROUND_TO_IQD = _int("ROUND_TO_IQD", 250)                 # smallest practical note
    FIRST_VISIT_PERIOD_DAYS = _int("FIRST_VISIT_PERIOD_DAYS", 30)
    HIGH_CONSUMPTION_FACTOR = _float("HIGH_CONSUMPTION_FACTOR", 3.0)
    ROUTE_DUE_DAYS = _int("ROUTE_DUE_DAYS", 60)              # red after this many days
    ROUTE_WARNING_DAYS = _int("ROUTE_WARNING_DAYS", 29)      # yellow after this many days

    # --- Field rules ---
    MAX_GPS_ACCURACY_METERS = _float("MAX_GPS_ACCURACY_METERS", 50)
    MAX_PROPERTIES_PER_PHONE = _int("MAX_PROPERTIES_PER_PHONE", 5)     # above this: flagged, not blocked
    MAX_DISTANCE_FROM_PROPERTY_M = _float("MAX_DISTANCE_FROM_PROPERTY_M", 150)  # collector must be at the house to bill
    DUPLICATE_RADIUS_M = _float("DUPLICATE_RADIUS_M", 10)
    MASTER_CODE_MAX_FAILED_PER_DAY = _int("MASTER_CODE_MAX_FAILED_PER_DAY", 5)
    ENFORCE_GEOFENCE = os.getenv("ENFORCE_GEOFENCE", "true").lower() == "true"

    # --- WhatsApp Business (Meta Cloud API) ---
    # console = print messages in the server terminal (development)
    # live    = send through Meta Cloud API
    WHATSAPP_MODE = os.getenv("WHATSAPP_MODE", "console")
    WHATSAPP_TOKEN = os.getenv("WHATSAPP_TOKEN", "")
    WHATSAPP_PHONE_NUMBER_ID = os.getenv("WHATSAPP_PHONE_NUMBER_ID", "")
    WHATSAPP_API_VERSION = os.getenv("WHATSAPP_API_VERSION", "v21.0")
    WHATSAPP_LANG = os.getenv("WHATSAPP_LANG", "ar")
    WA_TEMPLATE_OTP = os.getenv("WA_TEMPLATE_OTP", "jbaya_otp")                    # Authentication template
    WA_TEMPLATE_BILL_NOTICE = os.getenv("WA_TEMPLATE_BILL_NOTICE", "jbaya_bill_notice")  # Utility template
    WA_TEMPLATE_RECEIPT = os.getenv("WA_TEMPLATE_RECEIPT", "jbaya_receipt")        # Utility template
    HOTLINE = os.getenv("HOTLINE", "8000")

    # --- CORS (Flutter web dev server runs on a random localhost port) ---
    CORS_ORIGIN_REGEX = os.getenv("CORS_ORIGIN_REGEX", r"https?://(localhost|127\.0\.0\.1)(:\d+)?")


settings = Settings()
