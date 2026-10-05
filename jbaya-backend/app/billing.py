"""Server-side billing. The app never calculates money; it only displays what this module returns.

Rules (agreed with the client):
- Mechanical meters show the TOTAL lifetime consumption, so a bill = (current - previous) x unit rate.
- First visit (no previous reading): the reading is stored as the baseline and the citizen pays an
  ESTIMATED amount for the period (FIRST_VISIT_PERIOD_DAYS).
- current < previous  -> collection blocked, sent to supervisor review (meter replaced / tampered / misread).
- consumption far above the property's own average -> flagged, collection still allowed.
- Meter broken/unreadable -> estimate from the property's history (or the class tariff);
  if the meter is registered as 'working', the estimate needs supervisor approval.
- Every bill adds the fixed company fee.
"""
from datetime import datetime, timezone
from decimal import Decimal

from fastapi import HTTPException

from .config import settings
from .utils import round_iqd


def _f(x) -> float | None:
    return float(x) if isinstance(x, (Decimal, int, float)) else x


def latest_reading(cur, property_id: int) -> dict | None:
    cur.execute(
        "SELECT reading, reading_type, taken_at FROM meter_readings WHERE property_id = %s ORDER BY taken_at DESC, id DESC LIMIT 1",
        (property_id,),
    )
    return cur.fetchone()


def last_paid_bill(cur, property_id: int) -> dict | None:
    cur.execute(
        "SELECT * FROM bills WHERE property_id = %s AND status = 'paid' ORDER BY paid_at DESC LIMIT 1",
        (property_id,),
    )
    return cur.fetchone()


def avg_daily_consumption(cur, property_id: int) -> float | None:
    cur.execute(
        """SELECT SUM(consumption) AS c, SUM(period_days) AS d FROM bills
           WHERE property_id = %s AND status = 'paid' AND billing_method = 'reading' AND consumption IS NOT NULL""",
        (property_id,),
    )
    r = cur.fetchone()
    if not r or not r["d"]:
        return None
    return float(r["c"]) / float(r["d"])


def _estimate_gov(tariff: dict, period_days: int, avg_daily: float | None) -> float:
    if avg_daily is not None and avg_daily > 0:
        return avg_daily * period_days * float(tariff["unit_rate"])
    return float(tariff["monthly_estimate"]) * period_days / 30.0


def compute(cur, prop: dict, tariff: dict, method: str, current_reading: float | None,
            now: datetime | None = None) -> dict:
    """Returns the bill fields (not yet inserted)."""
    now = now or datetime.now(timezone.utc)
    if method not in ("reading", "estimate"):
        raise HTTPException(422, "طريقة احتساب غير معروفة")

    prev = latest_reading(cur, prop["id"])
    last_paid = last_paid_bill(cur, prop["id"])
    flags: list[str] = []

    if last_paid and (now - last_paid["paid_at"]).total_seconds() < 24 * 3600:
        raise HTTPException(409, "تمت جباية هذا العقار خلال آخر 24 ساعة")

    if method == "reading":
        if current_reading is None:
            raise HTTPException(422, "يجب إدخال القراءة الحالية للعداد")
        if current_reading < 0:
            raise HTTPException(422, "القراءة لا يمكن أن تكون سالبة")

    # ---------------- First visit: baseline + estimated amount for the period
    if last_paid is None:
        if prop["meter_status"] == "working" and method == "reading":
            baseline = current_reading
        elif prop["meter_status"] == "working" and method == "estimate":
            baseline = None
            flags.append("estimate_on_working_meter")
        else:
            baseline = None
        period = settings.FIRST_VISIT_PERIOD_DAYS
        gov = round_iqd(_estimate_gov(tariff, period, None), settings.ROUND_TO_IQD)
        status = "pending_approval" if "estimate_on_working_meter" in flags else "awaiting_otp"
        return _bill(prop, "first_visit", "estimate", None, baseline, None, None, period, gov, status, flags)

    period = max(1, int((now - last_paid["paid_at"]).total_seconds() // 86400))
    avg_daily = avg_daily_consumption(cur, prop["id"])

    # ---------------- Periodic, actual reading
    if method == "reading":
        if prev is None:
            # meter newly installed / first reading ever: becomes the baseline, period is estimated
            flags.append("new_baseline")
            gov = round_iqd(_estimate_gov(tariff, period, None), settings.ROUND_TO_IQD)
            return _bill(prop, "periodic", "estimate", None, current_reading, None, None, period, gov, "awaiting_otp", flags)

        previous = float(prev["reading"])
        if current_reading < previous:
            flags.append("reading_lower_than_previous")
            gov = round_iqd(_estimate_gov(tariff, period, avg_daily), settings.ROUND_TO_IQD)
            return _bill(prop, "periodic", "reading", previous, current_reading, None, None, period, gov,
                         "blocked_review", flags)

        consumption = current_reading - previous
        if consumption == 0:
            flags.append("zero_consumption")
        if avg_daily and consumption / period > settings.HIGH_CONSUMPTION_FACTOR * avg_daily:
            flags.append("high_consumption")
        rate = float(tariff["unit_rate"])
        gov = round_iqd(consumption * rate, settings.ROUND_TO_IQD)
        return _bill(prop, "periodic", "reading", previous, current_reading, consumption, rate, period, gov,
                     "awaiting_otp", flags)

    # ---------------- Periodic, estimate (meter none / broken / unreadable)
    gov = round_iqd(_estimate_gov(tariff, period, avg_daily), settings.ROUND_TO_IQD)
    status = "awaiting_otp"
    if prop["meter_status"] == "working":
        flags.append("estimate_on_working_meter")
        status = "pending_approval"
    return _bill(prop, "periodic", "estimate", _f(prev["reading"]) if prev else None, None, None, None, period, gov,
                 status, flags)


def _bill(prop, visit_type, method, previous, current, consumption, rate, period, gov, status, flags) -> dict:
    fee = float(settings.COMPANY_FEE_IQD)
    return {
        "property_id": prop["id"],
        "visit_type": visit_type,
        "billing_method": method,
        "previous_reading": previous,
        "current_reading": current,
        "consumption": consumption,
        "unit_rate": rate,
        "period_days": period,
        "gov_amount": gov,
        "company_fee": fee,
        "total_amount": gov + fee,
        "status": status,
        "flags": flags,
    }
