"""One place that decides whether a citizen confirmation is valid: WhatsApp OTP or rotating master code."""
from datetime import datetime, timezone

from pydantic import BaseModel, Field

from . import audit, codes
from .config import settings


class VerifyIn(BaseModel):
    code: str = Field(..., min_length=4, max_length=10)
    use_master_code: bool = False
    reason: str | None = Field(None, max_length=500)


def verify(cur, user: dict, *, purpose: str, property_id: int, bill_id: int | None, body: VerifyIn) -> dict:
    """Returns {"ok": True, "method": "otp"|"master_code"} or {"ok": False, "status": int, "message": str}.
    Never raises, so the caller can commit attempt counters / audit rows before returning an error."""
    if not body.use_master_code:
        res = codes.check_challenge(cur, purpose=purpose, property_id=property_id, bill_id=bill_id, code=body.code)
        if res["ok"]:
            # the citizen has to open WhatsApp and read the code aloud: an instant entry is suspicious
            elapsed = (datetime.now(timezone.utc) - res["challenge"]["created_at"]).total_seconds()
            fast = elapsed < settings.FAST_OTP_SECONDS
            if fast:
                audit.log(cur, user["id"], "fast_otp", "property", property_id,
                          {"purpose": purpose, "bill_id": bill_id, "seconds": round(elapsed, 1)})
            return {"ok": True, "method": "otp", "fast": fast}
        audit.log(cur, user["id"], "otp_failed", "property", property_id, {"purpose": purpose, "bill_id": bill_id, "message": res["message"]})
        return res

    # ---------------- master code path
    if not settings.MASTER_CODE_ENABLED:
        return {"ok": False, "status": 423, "message": "الرمز الرئيسي متوقف حالياً من الإدارة التقنية"}
    cur.execute("SELECT permissions FROM employees WHERE id = %s", (user["id"],))
    perms = (cur.fetchone() or {}).get("permissions") or {}
    if perms.get("master_code") is False:
        return {"ok": False, "status": 423, "message": "الرمز الرئيسي غير مسموح لحسابك"}
    if user.get("sector_id"):
        cur.execute("SELECT switches FROM sectors WHERE id = %s", (user["sector_id"],))
        if ((cur.fetchone() or {}).get("switches") or {}).get("master_code") is False:
            return {"ok": False, "status": 423, "message": "الرمز الرئيسي متوقف في قاطعك"}
    reason = (body.reason or "").strip()
    if len(reason) < 5:
        return {"ok": False, "status": 422, "message": "يجب كتابة سبب استخدام الرمز الرئيسي"}

    cur.execute(
        "SELECT COUNT(*) AS n FROM audit_log WHERE actor_id = %s AND action = 'master_code_failed' AND created_at >= date_trunc('day', NOW())",
        (user["id"],),
    )
    if cur.fetchone()["n"] >= settings.MASTER_CODE_MAX_FAILED_PER_DAY:
        return {"ok": False, "status": 429, "message": "تم إيقاف استخدام الرمز الرئيسي لك اليوم بسبب كثرة المحاولات الخاطئة"}

    cur.execute(
        "SELECT COUNT(*) AS n FROM master_code_uses WHERE collector_id = %s AND used_at >= date_trunc('day', NOW())",
        (user["id"],),
    )
    if cur.fetchone()["n"] >= settings.MASTER_CODE_DAILY_LIMIT_PER_COLLECTOR:
        audit.log(cur, user["id"], "master_code_limit_reached", "property", property_id, {"purpose": purpose})
        return {"ok": False, "status": 429, "message": "وصلت الحد اليومي لاستخدام الرمز الرئيسي، يرجى التواصل مع القيادة"}

    window = codes.match_master_code(body.code)
    if window is None:
        audit.log(cur, user["id"], "master_code_failed", "property", property_id, {"purpose": purpose, "bill_id": bill_id})
        return {"ok": False, "status": 400, "message": "الرمز الرئيسي غير صحيح أو منتهي الصلاحية"}

    cur.execute(
        """INSERT INTO master_code_uses (collector_id, property_id, bill_id, purpose, reason, window_index)
           VALUES (%s, %s, %s, %s, %s, %s)""",
        (user["id"], property_id, bill_id, purpose, reason, window),
    )
    cur.execute(
        "UPDATE otp_challenges SET status = 'superseded' WHERE property_id = %s AND purpose = %s AND status = 'pending'",
        (property_id, purpose),
    )
    audit.log(cur, user["id"], "master_code_used", "property", property_id,
              {"purpose": purpose, "bill_id": bill_id, "reason": reason, "window": window})
    return {"ok": True, "method": "master_code"}
