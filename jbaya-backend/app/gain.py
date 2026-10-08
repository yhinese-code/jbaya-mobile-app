"""The 35% rule (Phase 5): the company gets the fixed fee on every receipt PLUS a share of the INCREASE in collections.
Which increase is not confirmed yet, so the formula is a setting (GAIN_SHARE_MODE):

- not_set        nothing is booked; both options are shown side by side as estimates
- per_house      GAIN_SHARE_PCT of how much each bill's water amount is above that house's previous bill
                 (the previous bill scaled to the same number of days). Booked on each receipt.
- baseline_2025  GAIN_SHARE_PCT of the month's water collections above the same month of 2025.
                 Settled once per month by finance, approved by the owner, then booked.
"""
from datetime import date

from .config import settings
from .utils import round_iqd


def previous_bill(cur, property_id: int) -> dict | None:
    """The latest CONFIRMED previous bill of a house (imported from the directorate or confirmed by the supervisor)."""
    cur.execute(
        """SELECT * FROM previous_bills WHERE property_id = %s AND status = 'confirmed'
           ORDER BY bill_date DESC NULLS LAST, id DESC LIMIT 1""",
        (property_id,),
    )
    return cur.fetchone()


def basis_for(cur, property_id: int, period_days: int) -> float | None:
    """What the house used to pay for the same number of days, or None if there is no confirmed previous bill."""
    pb = previous_bill(cur, property_id)
    if not pb:
        return None
    return round(float(pb["amount"]) / max(1, int(pb["period_days"])) * max(1, period_days), 2)


def share_on_receipt(gov_amount: float, basis: float | None) -> float:
    """Booked on the receipt only in per_house mode."""
    if settings.GAIN_SHARE_MODE != "per_house" or basis is None:
        return 0.0
    increase = max(0.0, float(gov_amount) - basis)
    return float(round_iqd(increase * settings.GAIN_SHARE_PCT / 100, 1)) if increase else 0.0


def month_bounds(m: date) -> tuple[date, date]:
    start = m.replace(day=1)
    end = date(start.year + (start.month == 12), start.month % 12 + 1, 1)
    return start, end


def month_figures(cur, month: date) -> dict:
    """Both formulas for one month, as estimates (whatever the chosen mode is)."""
    start, end = month_bounds(month)
    tz = settings.APP_TIMEZONE
    cur.execute(
        """SELECT COALESCE(SUM(gov_amount), 0) AS gov, COUNT(*) AS n,
                  COUNT(gain_basis) AS with_basis,
                  COALESCE(SUM(GREATEST(gov_amount - gain_basis, 0)) FILTER (WHERE gain_basis IS NOT NULL), 0) AS increase,
                  COALESCE(SUM(gain_share), 0) AS booked
           FROM receipts
           WHERE issued_at >= (%(s)s::timestamp AT TIME ZONE %(tz)s) AND issued_at < (%(e)s::timestamp AT TIME ZONE %(tz)s)""",
        {"s": start, "e": end, "tz": tz},
    )
    r = cur.fetchone()
    gov = float(r["gov"])
    base_month = date(2025, start.month, 1)
    cur.execute("SELECT amount FROM gain_share_baselines WHERE month = %s", (base_month,))
    b = cur.fetchone()
    baseline = float(b["amount"]) if b else None
    pct = settings.GAIN_SHARE_PCT
    excess = max(0.0, gov - baseline) if baseline is not None else None
    cur.execute("SELECT * FROM gain_share_settlements WHERE month = %s", (start,))
    st = cur.fetchone()
    return {
        "month": start.isoformat()[:7],
        "water_collected": round(gov),
        "receipts": r["n"],
        "baseline_2025": round(baseline) if baseline is not None else None,
        "above_baseline": round(excess) if excess is not None else None,
        "estimate_baseline_2025": round(excess * pct / 100) if excess is not None else None,
        "receipts_with_previous_bill": r["with_basis"],
        "coverage": round(r["with_basis"] / r["n"], 4) if r["n"] else None,
        "per_house_increase": round(float(r["increase"])),
        "estimate_per_house": round(float(r["increase"]) * pct / 100),
        "booked_per_house": round(float(r["booked"])),
        "settlement": {"id": st["id"], "status": st["status"], "amount": float(st["amount"]),
                       "decided_at": st["decided_at"].isoformat() if st["decided_at"] else None} if st else None,
    }
