"""Entry point kept for compatibility:  uvicorn main:app --reload
All code lives in the app/ package."""
from app.main import app  # noqa: F401
