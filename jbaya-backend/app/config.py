"""Central settings, read once from environment / .env file."""
import os
from dotenv import load_dotenv

load_dotenv()


def _str(name: str, default: str) -> str:
    """Empty values in .env count as missing."""
    return os.getenv(name) or default


def _int(name: str, default: int) -> int:
    return int(os.getenv(name) or default)


def _float(name: str, default: float) -> float:
    return float(os.getenv(name) or default)


class Settings:
    # --- Database ---
    DB_CONN = _str("DB_CONN", "postgresql://postgres:postgres@localhost:5432/postgres")

    # --- Secrets (MUST be changed in production, see .env.example) ---
    JWT_SECRET = _str("JWT_SECRET", "dev-only-change-me-jwt-0000000000000000")
    OTP_SECRET = _str("OTP_SECRET", "dev-only-change-me-otp-0000000000000000")
    MASTER_CODE_SECRET = _str("MASTER_CODE_SECRET", "dev-only-change-me-master-0000000000000")
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

    # --- Phase 1: field cash & evidence ---
    CASH_IN_HAND_CAP_IQD = _float("CASH_IN_HAND_CAP_IQD", 1_500_000)   # collector must hand over cash above this
    COLLECTOR_DAILY_TARGET_IQD = _float("COLLECTOR_DAILY_TARGET_IQD", 500_000)
    REQUIRE_METER_PHOTO = _str("REQUIRE_METER_PHOTO", "true").lower() == "true"
    MAX_PHOTO_BYTES = _int("MAX_PHOTO_BYTES", 3 * 1024 * 1024)
    OCR_MISMATCH_TOLERANCE = _float("OCR_MISMATCH_TOLERANCE", 1.0)      # m3
    RECON_TOLERANCE_IQD = _float("RECON_TOLERANCE_IQD", 0)              # differences up to this are auto-accepted
    STORAGE_DIR = _str("STORAGE_DIR", "storage")
    ENFORCE_GEOFENCE = _str("ENFORCE_GEOFENCE", "true").lower() == "true"

    # --- WhatsApp Business (Meta Cloud API) ---
    # console = print messages in the server terminal (development)
    # live    = send through Meta Cloud API
    WHATSAPP_MODE = _str("WHATSAPP_MODE", "console")
    WHATSAPP_TOKEN = os.getenv("WHATSAPP_TOKEN", "")
    WHATSAPP_PHONE_NUMBER_ID = os.getenv("WHATSAPP_PHONE_NUMBER_ID", "")
    WHATSAPP_API_VERSION = _str("WHATSAPP_API_VERSION", "v21.0")
    WHATSAPP_LANG = _str("WHATSAPP_LANG", "ar")
    WA_TEMPLATE_OTP = _str("WA_TEMPLATE_OTP", "jbaya_otp")                    # Authentication template
    WA_TEMPLATE_BILL_NOTICE = _str("WA_TEMPLATE_BILL_NOTICE", "jbaya_bill_notice")  # Utility template
    WA_TEMPLATE_RECEIPT = _str("WA_TEMPLATE_RECEIPT", "jbaya_receipt")        # Utility template
    HOTLINE = _str("HOTLINE", "8000")

    # --- CORS (Flutter web dev server runs on a random localhost port) ---
    CORS_ORIGIN_REGEX = os.getenv("CORS_ORIGIN_REGEX", r"https?://(localhost|127\.0\.0\.1)(:\d+)?")


settings = Settings()
