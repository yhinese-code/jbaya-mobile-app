"""Pure-Python statistics used by the finance analytics (no numpy/scipy so it runs anywhere).

- holt_winters(): additive Holt-Winters with weekly seasonality, parameters picked by grid search.
- benford_first_digit(): first-digit test (Nigrini MAD thresholds + chi-square).
- last_digit_test(): digit preference in meter readings (fabricated readings tend to end in 0 or 5).
- chi2_sf(): chi-square survival function (p-value).
- robust_z(): median / MAD z-score.
"""
import math
from statistics import median

BENFORD = [math.log10(1 + 1 / d) for d in range(1, 10)]

# Nigrini (2012) first-digit MAD conformity ranges
MAD_LEVELS = [(0.006, "close", "مطابقة تامة"), (0.012, "acceptable", "مطابقة مقبولة"),
              (0.015, "marginal", "مطابقة هامشية")]
MIN_BENFORD_N = 50


# ---------------------------------------------------------------- chi-square p-value

def _gammainc_lower_series(a: float, x: float) -> float:
    total = term = 1.0 / a
    n = 1
    while n < 500:
        term *= x / (a + n)
        total += term
        if abs(term) < abs(total) * 1e-12:
            break
        n += 1
    return total * math.exp(-x + a * math.log(x) - math.lgamma(a))


def _gammainc_upper_cf(a: float, x: float) -> float:
    tiny = 1e-300
    b = x + 1 - a
    c = 1 / tiny
    d = 1 / b
    h = d
    for i in range(1, 500):
        an = -i * (i - a)
        b += 2
        d = an * d + b
        d = tiny if abs(d) < tiny else d
        c = b + an / c
        c = tiny if abs(c) < tiny else c
        d = 1 / d
        delta = d * c
        h *= delta
        if abs(delta - 1) < 1e-12:
            break
    return math.exp(-x + a * math.log(x) - math.lgamma(a)) * h


def chi2_sf(x: float, k: int) -> float:
    """P(X >= x) for a chi-square distribution with k degrees of freedom."""
    if x <= 0:
        return 1.0
    a, y = k / 2.0, x / 2.0
    if y < a + 1:
        return max(0.0, min(1.0, 1 - _gammainc_lower_series(a, y)))
    return max(0.0, min(1.0, _gammainc_upper_cf(a, y)))


# ---------------------------------------------------------------- Benford

def first_digit(v: float) -> int | None:
    v = abs(float(v))
    if v < 1e-9 or math.isnan(v) or math.isinf(v):
        return None
    while v >= 10:
        v /= 10
    while v < 1:
        v *= 10
    return int(v)


def benford_first_digit(values, expected: list[float] | None = None) -> dict:
    """First-digit test. `expected` defaults to Benford's law; pass a peer distribution to compare against peers."""
    exp = expected or BENFORD
    digits = [d for d in (first_digit(v) for v in values) if d]
    n = len(digits)
    counts = [digits.count(d) for d in range(1, 10)]
    observed = [c / n if n else 0.0 for c in counts]
    mad = sum(abs(o - e) for o, e in zip(observed, exp)) / 9 if n else None
    chi2 = sum((c - n * e) ** 2 / (n * e) for c, e in zip(counts, exp) if e > 0) if n else None
    p = chi2_sf(chi2, 8) if chi2 is not None else None
    if n < MIN_BENFORD_N:
        level, label = "insufficient", f"بيانات غير كافية (أقل من {MIN_BENFORD_N} قيمة)"
    else:
        level, label = "nonconformity", "عدم مطابقة - يستوجب التدقيق"
        for limit, lv, lb in MAD_LEVELS:
            if mad <= limit:
                level, label = lv, lb
                break
    # digits that deviate most (z-test per digit, Nigrini's continuity correction)
    z = []
    for d, (o, e) in enumerate(zip(observed, exp), start=1):
        if n and 0 < e < 1:
            se = math.sqrt(e * (1 - e) / n)
            z.append(round((abs(o - e) - 1 / (2 * n)) / se, 2) if se else 0.0)
        else:
            z.append(0.0)
    return {
        "n": n, "counts": counts, "observed": [round(o, 4) for o in observed], "expected": [round(e, 4) for e in exp],
        "mad": round(mad, 5) if mad is not None else None, "chi2": round(chi2, 2) if chi2 is not None else None,
        "p_value": round(p, 4) if p is not None else None, "level": level, "label": label, "z": z,
        "suspicious_digits": [d for d, zz in enumerate(z, start=1) if zz > 1.96 and n >= MIN_BENFORD_N],
    }


def last_digit_test(values) -> dict:
    """Last digit of the integer part should be ~uniform. Too many 0s/5s suggests readings typed without looking."""
    digits = [int(abs(float(v))) % 10 for v in values if v is not None and abs(float(v)) >= 10]
    n = len(digits)
    counts = [digits.count(d) for d in range(10)]
    chi2 = sum((c - n / 10) ** 2 / (n / 10) for c in counts) if n else None
    p = chi2_sf(chi2, 9) if chi2 is not None else None
    zero_five = (counts[0] + counts[5]) / n if n else None
    return {"n": n, "counts": counts, "chi2": round(chi2, 2) if chi2 is not None else None,
            "p_value": round(p, 4) if p is not None else None,
            "share_0_5": round(zero_five, 4) if zero_five is not None else None,
            "suspicious": bool(n >= 20 and p is not None and p < 0.01 and zero_five is not None and zero_five > 0.3)}


# ---------------------------------------------------------------- robust statistics

def robust_z(x: float, sample: list[float]) -> float:
    if len(sample) < 3:
        return 0.0
    med = median(sample)
    mad = median(abs(s - med) for s in sample)
    if mad == 0:
        return 0.0 if x == med else (10.0 if x > med else -10.0)
    return 0.6745 * (x - med) / mad


# ---------------------------------------------------------------- forecasting

def _hw_fit(y: list[float], m: int, alpha: float, beta: float, gamma: float):
    level = sum(y[:m]) / m
    trend = (sum(y[m:2 * m]) - sum(y[:m])) / (m * m) if len(y) >= 2 * m else 0.0
    season = [y[i] - level for i in range(m)]
    sse, fitted = 0.0, []
    for t in range(len(y)):
        s = season[t % m]
        f = level + trend + s
        fitted.append(f)
        if t >= m:
            sse += (y[t] - f) ** 2
        new_level = alpha * (y[t] - s) + (1 - alpha) * (level + trend)
        trend = beta * (new_level - level) + (1 - beta) * trend
        season[t % m] = gamma * (y[t] - new_level) + (1 - gamma) * s
        level = new_level
    return sse, level, trend, season, fitted


def holt_winters(y: list[float], horizon: int = 30, m: int = 7) -> dict:
    """Daily forecast. Returns forecast, lower/upper 95% band, method and accuracy metrics."""
    y = [float(v) for v in y]
    if len(y) < 2 * m:
        avg = sum(y) / len(y) if y else 0.0
        sd = math.sqrt(sum((v - avg) ** 2 for v in y) / len(y)) if y else 0.0
        fc = [avg] * horizon
        return {"method": "average", "params": {}, "forecast": fc, "sd": [sd] * horizon,
                "lower": [max(0.0, avg - 1.96 * sd)] * horizon, "upper": [avg + 1.96 * sd] * horizon,
                "rmse": round(sd, 2), "mape": None, "fitted": [avg] * len(y)}
    best = None
    for a in (0.1, 0.2, 0.3, 0.5, 0.7):
        for b in (0.0, 0.02, 0.05, 0.1):
            for g in (0.05, 0.1, 0.2, 0.3, 0.5):
                fit = _hw_fit(y, m, a, b, g)
                if best is None or fit[0] < best[0][0]:
                    best = (fit, (a, b, g))
    (sse, level, trend, season, fitted), (a, b, g) = best
    n_eval = max(1, len(y) - m)
    rmse = math.sqrt(sse / n_eval)
    errs = [abs(y[t] - fitted[t]) / y[t] for t in range(m, len(y)) if y[t] > 0]
    mape = sum(errs) / len(errs) if errs else None
    n = len(y)
    fc, lo, hi, sds = [], [], [], []
    for h in range(1, horizon + 1):
        f = max(0.0, level + h * trend + season[(n + h - 1) % m])
        sd = rmse * math.sqrt(1 + (h - 1) * a * a)
        width = 1.96 * sd
        sds.append(sd)
        fc.append(f)
        lo.append(max(0.0, f - width))
        hi.append(f + width)
    return {"method": "holt_winters", "params": {"alpha": a, "beta": b, "gamma": g, "season": m},
            "forecast": fc, "lower": lo, "upper": hi, "sd": sds, "rmse": round(rmse, 2),
            "mape": round(mape, 4) if mape is not None else None, "fitted": fitted}
