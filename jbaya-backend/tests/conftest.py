"""Loaded by pytest before any test module, so the app is always pointed at the TEST database,
whatever a test file imports first. WARNING: the test database is wiped on every run."""
import os
import sys
import tempfile

TEST_DB = os.environ.get("TEST_DB_CONN", "postgresql://postgres@localhost:5432/jbaya_test")
os.environ["DB_CONN"] = TEST_DB
os.environ["WHATSAPP_MODE"] = "console"
os.environ["OTP_RESEND_COOLDOWN_SECONDS"] = "0"
os.environ["REQUIRE_METER_PHOTO"] = "false"
os.environ["DEVICE_APPROVAL_REQUIRED"] = "false"   # test_phase5 switches it on
os.environ["FAST_OTP_SECONDS"] = "0"
os.environ["STORAGE_DIR"] = os.path.join(tempfile.gettempdir(), "jbaya-test-storage")
sys.path.insert(0, os.path.dirname(__file__))
