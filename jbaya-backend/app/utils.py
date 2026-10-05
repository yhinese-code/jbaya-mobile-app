"""Small pure helpers: Iraqi phone numbers, geofencing, money rounding."""
import math
import re

_IQ_MOBILE = re.compile(r"^7[3-9]\d{8}$")  # 7XXXXXXXXX after the country code / leading zero


def normalize_iraqi_phone(raw: str) -> str | None:
    """Accepts 07XXXXXXXXX, 9647XXXXXXXXX, +9647XXXXXXXXX, 009647XXXXXXXXX.
    Returns '9647XXXXXXXXX' or None if it is not a valid Iraqi mobile number."""
    digits = re.sub(r"\D", "", raw or "")
    if digits.startswith("00964"):
        digits = digits[5:]
    elif digits.startswith("964"):
        digits = digits[3:]
    elif digits.startswith("0"):
        digits = digits[1:]
    if not _IQ_MOBILE.match(digits):
        return None
    return "964" + digits


def mask_phone(phone: str) -> str:
    """9647801234567 -> +964 780 *** 4567"""
    if len(phone) < 8:
        return phone
    return f"+964 {phone[3:6]} *** {phone[-4:]}"


def point_in_polygon(lat: float, lng: float, polygon: list[list[float]]) -> bool:
    """Ray casting. polygon = [[lat, lng], ...] (closed or open ring)."""
    inside = False
    n = len(polygon)
    if n < 3:
        return False
    j = n - 1
    for i in range(n):
        yi, xi = polygon[i][0], polygon[i][1]
        yj, xj = polygon[j][0], polygon[j][1]
        if (yi > lat) != (yj > lat):
            x_cross = (xj - xi) * (lat - yi) / (yj - yi) + xi
            if lng < x_cross:
                inside = not inside
        j = i
    return inside


def haversine_m(lat1: float, lng1: float, lat2: float, lng2: float) -> float:
    r = 6_371_000
    p1, p2 = math.radians(lat1), math.radians(lat2)
    dp, dl = p2 - p1, math.radians(lng2 - lng1)
    a = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 2 * r * math.asin(math.sqrt(a))


def round_iqd(amount: float, step: int) -> float:
    """Round to the nearest practical note (e.g. 250 IQD)."""
    if step <= 1:
        return round(amount)
    return float(int((amount + step / 2) // step) * step)


def fmt_iqd(amount: float) -> str:
    return f"{amount:,.0f}"
