from contextlib import asynccontextmanager

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from .config import settings
from . import runtime
from .db import apply_schema, close_pool, dict_cursor, get_conn, init_pool
from .routers import (admin, alerts, analytics, auth, collector, command, finance, hr, me, offline, owner,
                      performance, prev_bills, supervisor, tech, tracking, whatsapp_hook)

_INSECURE = {"dev-only-change-me-jwt-0000000000000000", "dev-only-change-me-otp-0000000000000000", "dev-only-change-me-master-0000000000000"}


@asynccontextmanager
async def lifespan(app: FastAPI):
    init_pool()
    apply_schema()
    with get_conn() as conn, dict_cursor(conn) as cur:
        runtime.refresh(cur, force=True)       # settings changed in the tech panel survive restarts
    if {settings.JWT_SECRET, settings.OTP_SECRET, settings.MASTER_CODE_SECRET} & _INSECURE:
        print("WARNING: development secrets in use. Set JWT_SECRET, OTP_SECRET and MASTER_CODE_SECRET in .env before going live.")
    if settings.WHATSAPP_MODE != "live":
        print("WhatsApp is in CONSOLE mode: messages (including OTP codes) are printed here, not sent.")
    yield
    close_pool()


app = FastAPI(title="Jbaya Collection System API", version="0.9.0", lifespan=lifespan)

app.add_middleware(
    CORSMiddleware,
    allow_origin_regex=settings.CORS_ORIGIN_REGEX,
    allow_methods=["*"],
    allow_headers=["*"],
)

app.include_router(auth.router)
app.include_router(collector.router)
app.include_router(supervisor.router)
app.include_router(command.router)
app.include_router(admin.router)
app.include_router(finance.router)
app.include_router(analytics.router)
app.include_router(performance.router)
app.include_router(owner.router)
app.include_router(tech.router)
app.include_router(prev_bills.router)
app.include_router(offline.router)
app.include_router(whatsapp_hook.router)
app.include_router(alerts.router)
app.include_router(tracking.router)
app.include_router(hr.router)
app.include_router(me.router)


@app.get("/health")
def health():
    return {"status": "ok"}
