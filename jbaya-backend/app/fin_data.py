"""Finance analytics: data access + scoring. Statistics live in fin_math.py, accounts in ledger.py."""
import calendar
from datetime import date, datetime, timedelta, timezone
from statistics import median

from . import fin_math, hr_logic, ledger
from .config import settings
from .ledger import HI, LO

WEEKDAYS_AR = ["الاثنين", "الثلاثاء", "الأربعاء", "الخميس", "الجمعة", "السبت", "الأحد"]


def _b(start: date, end: date, **extra) -> dict:
    return {"s": start, "e": end, "tz": settings.APP_TIMEZONE, **extra}


def _f(x) -> float:
    return float(x) if x is not None else 0.0


# ================================================================ series

def daily_series(cur, start: date, end: date, collector_id: int | None = None) -> list[dict]:
    """Collections per LOCAL day, zero-filled."""
    cur.execute(
        """SELECT d::date AS day, COALESCE(SUM(r.total_amount),0) AS total, COALESCE(SUM(r.gov_amount),0) AS gov,
                  COALESCE(SUM(r.company_fee),0) AS fee, COUNT(r.id) AS n
           FROM generate_series(%(s)s::date, %(e)s::date, interval '1 day') AS d
           LEFT JOIN receipts r ON r.issued_at >= ((d::date)::timestamp AT TIME ZONE %(tz)s)
                               AND r.issued_at < ((d::date + 1)::timestamp AT TIME ZONE %(tz)s)
                               AND (%(c)s::int IS NULL OR r.collector_id = %(c)s)
           GROUP BY d ORDER BY d""",
        _b(start, end, c=collector_id),
    )
    return [{"day": r["day"].isoformat(), "total": _f(r["total"]), "gov": _f(r["gov"]), "fee": _f(r["fee"]), "count": r["n"]}
            for r in cur.fetchall()]


def _sum_receipts(cur, start: date, end: date) -> dict:
    cur.execute(
        f"""SELECT COALESCE(SUM(total_amount),0) AS total, COALESCE(SUM(gov_amount),0) AS gov,
                   COALESCE(SUM(company_fee),0) AS fee, COUNT(*) AS n,
                   COUNT(*) FILTER (WHERE verification_method = 'otp') AS otp
            FROM receipts WHERE issued_at >= {LO} AND issued_at < {HI}""",
        _b(start, end),
    )
    r = cur.fetchone()
    n = r["n"]
    return {"total": _f(r["total"]), "gov": _f(r["gov"]), "fee": _f(r["fee"]), "count": n,
            "avg_ticket": round(_f(r["total"]) / n) if n else 0, "otp_share": round(r["otp"] / n, 4) if n else None}


def _pct_change(cur_v: float, prev_v: float) -> float | None:
    return round((cur_v - prev_v) / prev_v, 4) if prev_v else None


# ================================================================ overview

def overview(cur, days: int = 30) -> dict:
    today = hr_logic.local_today(cur)
    month_start = today.replace(day=1)
    prev_month_end = month_start - timedelta(days=1)
    prev_month_start = prev_month_end.replace(day=1)
    prev_same_end = min(prev_month_start + timedelta(days=today.day - 1), prev_month_end)

    t = _sum_receipts(cur, today, today)
    y = _sum_receipts(cur, today - timedelta(days=1), today - timedelta(days=1))
    mtd = _sum_receipts(cur, month_start, today)
    prev = _sum_receipts(cur, prev_month_start, prev_same_end)

    cur.execute(
        f"""SELECT COUNT(*) AS n, COUNT(*) FILTER (WHERE billing_method = 'estimate') AS est,
                   COUNT(*) FILTER (WHERE jsonb_array_length(flags) > 0) AS flagged
            FROM bills WHERE status = 'paid' AND paid_at >= {LO} AND paid_at < {HI}""",
        _b(month_start, today),
    )
    bm = cur.fetchone()

    cur.execute(
        """SELECT COUNT(*) FILTER (WHERE status = 'active') AS active,
                  COUNT(*) FILTER (WHERE status = 'active' AND EXISTS (SELECT 1 FROM bills b WHERE b.property_id = p.id
                        AND b.status = 'paid' AND b.paid_at >= NOW() - INTERVAL '30 days')) AS covered30,
                  COUNT(*) FILTER (WHERE status = 'pending_otp') AS pending
           FROM properties p"""
    )
    props = cur.fetchone()

    cur.execute(
        f"""SELECT s.code, s.name,
                   (SELECT COUNT(*) FROM properties p WHERE p.sector_id = s.id AND p.status = 'active') AS active_properties,
                   (SELECT COUNT(*) FROM properties p WHERE p.sector_id = s.id AND p.status = 'active' AND EXISTS (
                        SELECT 1 FROM bills b WHERE b.property_id = p.id AND b.status = 'paid'
                        AND b.paid_at >= NOW() - INTERVAL '30 days')) AS covered30,
                   COALESCE(SUM(r.total_amount),0) AS collected, COUNT(r.id) AS receipts
            FROM sectors s
            LEFT JOIN properties p ON p.sector_id = s.id
            LEFT JOIN receipts r ON r.property_id = p.id AND r.issued_at >= {LO} AND r.issued_at < {HI}
            WHERE s.active GROUP BY s.id ORDER BY collected DESC""",
        _b(month_start, today),
    )
    sectors = [{"code": r["code"], "name": r["name"], "active_properties": r["active_properties"], "covered30": r["covered30"],
                "coverage": round(r["covered30"] / r["active_properties"], 4) if r["active_properties"] else None,
                "collected": _f(r["collected"]), "receipts": r["receipts"]} for r in cur.fetchall()]

    cur.execute(
        f"""SELECT p.property_class, COALESCE(SUM(r.total_amount),0) AS collected, COUNT(r.id) AS receipts
            FROM receipts r JOIN properties p ON p.id = r.property_id
            WHERE r.issued_at >= {LO} AND r.issued_at < {HI} GROUP BY p.property_class ORDER BY collected DESC""",
        _b(month_start, today),
    )
    classes = [{"property_class": r["property_class"], "collected": _f(r["collected"]), "receipts": r["receipts"]}
               for r in cur.fetchall()]

    cur.execute(
        f"""SELECT e.employee_code, e.full_name, COALESCE(SUM(r.total_amount),0) AS collected, COUNT(r.id) AS receipts,
                   COUNT(r.id) FILTER (WHERE r.verification_method = 'master_code') AS master
            FROM employees e LEFT JOIN receipts r ON r.collector_id = e.id AND r.issued_at >= {LO} AND r.issued_at < {HI}
            WHERE e.role = 'collector' AND e.active GROUP BY e.id ORDER BY collected DESC""",
        _b(month_start, today),
    )
    collectors = [{"employee_code": r["employee_code"], "full_name": r["full_name"], "collected": _f(r["collected"]),
                   "receipts": r["receipts"], "master_uses": r["master"],
                   "avg_ticket": round(_f(r["collected"]) / r["receipts"]) if r["receipts"] else 0} for r in cur.fetchall()]

    bal = ledger.balances(cur)
    mov = ledger.period_movements(cur, month_start, today)
    revenue = sum(m["net"] for c, m in mov.items() if ledger.CHART[c][1] == "revenue")
    expenses = sum(m["net"] for c, m in mov.items() if ledger.CHART[c][1] == "expense")

    return {
        "today": today.isoformat(), "month_start": month_start.isoformat(),
        "kpis": {
            "today": t, "yesterday": y, "mtd": mtd, "prev_month_same_period": prev,
            "mtd_change": _pct_change(mtd["total"], prev["total"]),
            "paid_bills_mtd": bm["n"], "estimate_share_mtd": round(bm["est"] / bm["n"], 4) if bm["n"] else None,
            "flagged_share_mtd": round(bm["flagged"] / bm["n"], 4) if bm["n"] else None,
            "active_properties": props["active"], "pending_properties": props["pending"],
            "coverage_30d": round(props["covered30"] / props["active"], 4) if props["active"] else None,
            "company_revenue_mtd": round(revenue, 2), "company_expenses_mtd": round(expenses, 2),
            "company_net_mtd": round(revenue - expenses, 2),
        },
        "cash": ledger.cash_position(bal),
        "series": daily_series(cur, today - timedelta(days=days - 1), today),
        "sectors": sectors, "classes": classes, "collectors": collectors,
    }


# ================================================================ forecast

def forecast(cur, horizon: int = 30, history_days: int = 120) -> dict:
    today = hr_logic.local_today(cur)
    cur.execute(f"SELECT MIN((issued_at AT TIME ZONE %(tz)s)::date) AS d FROM receipts", {"tz": settings.APP_TIMEZONE})
    first = cur.fetchone()["d"]
    month_end = today.replace(day=calendar.monthrange(today.year, today.month)[1])
    horizon = max(horizon, (month_end - today).days + 1)
    if not first or first >= today:
        return {"available": False, "message": "لا توجد بيانات تحصيل كافية للتنبؤ بعد (يلزم يوم كامل على الأقل).",
                "history": [], "forecast": []}
    start = max(first, today - timedelta(days=history_days))
    hist = daily_series(cur, start, today - timedelta(days=1))          # complete days only
    y = [h["total"] for h in hist]
    model = fin_math.holt_winters(y, horizon=horizon)
    fc_days = [today + timedelta(days=i) for i in range(horizon)]
    fc = [{"day": d.isoformat(), "value": round(v), "lower": round(lo), "upper": round(hi)}
          for d, v, lo, hi in zip(fc_days, model["forecast"], model["lower"], model["upper"])]

    today_so_far = _sum_receipts(cur, today, today)["total"]
    month_actual_to_yesterday = sum(h["total"] for h in hist if h["day"] >= today.replace(day=1).isoformat())
    rest_idx = [i for i, d in enumerate(fc_days) if d <= month_end]
    rest = [fc[i] for i in rest_idx]
    projection = month_actual_to_yesterday + sum(f["value"] for f in rest)
    # band of the month TOTAL: daily errors partly cancel out, so add variances (not the daily bounds)
    month_sd = sum(model["sd"][i] ** 2 for i in rest_idx) ** 0.5
    floor = month_actual_to_yesterday + today_so_far
    projection = max(projection, floor)
    prof = {}
    for h in hist:
        wd = date.fromisoformat(h["day"]).weekday()
        prof.setdefault(wd, []).append(h["total"])
    weekday_profile = [{"weekday": wd, "label": WEEKDAYS_AR[wd], "avg": round(sum(v) / len(v)) if v else 0}
                       for wd, v in sorted(prof.items())]
    warn = None
    if len(y) < 28:
        warn = f"التنبؤ مبني على {len(y)} يوم فقط؛ تتحسن الدقة بعد 4 أسابيع من البيانات."
    return {
        "available": True, "method": model["method"], "params": model["params"], "rmse": model["rmse"], "mape": model["mape"],
        "history_days": len(y), "warning": warn,
        "history": [{"day": h["day"], "value": h["total"], "fitted": round(f)} for h, f in zip(hist, model["fitted"])][-60:],
        "forecast": fc[:horizon],
        "today_so_far": today_so_far,
        "month": {"actual_to_yesterday": round(month_actual_to_yesterday), "projected_total": round(projection),
                  "projected_low": round(max(floor, projection - 1.96 * month_sd)),
                  "projected_high": round(projection + 1.96 * month_sd),
                  "month_end": month_end.isoformat()},
        "next_30_days": round(sum(f["value"] for f in fc[:30])),
        "weekday_profile": weekday_profile,
    }


# ================================================================ Benford / digit tests

DATASETS = {
    "consumption": "الاستهلاك (م³) في فواتير القراءة",
    "gov_amount": "مبالغ الحصة الحكومية في الوصولات",
}


def _dataset_values(cur, dataset: str, start: date, end: date) -> list[tuple[str, float]]:
    """(collector_code, value) pairs."""
    if dataset == "consumption":
        cur.execute(
            f"""SELECT e.employee_code AS c, b.consumption AS v FROM bills b JOIN employees e ON e.id = b.collector_id
                WHERE b.status = 'paid' AND b.billing_method = 'reading' AND b.consumption > 0
                  AND b.paid_at >= {LO} AND b.paid_at < {HI}""",
            _b(start, end),
        )
    else:
        cur.execute(
            f"""SELECT e.employee_code AS c, r.gov_amount AS v FROM receipts r JOIN employees e ON e.id = r.collector_id
                WHERE r.gov_amount > 0 AND r.issued_at >= {LO} AND r.issued_at < {HI}""",
            _b(start, end),
        )
    return [(r["c"], float(r["v"])) for r in cur.fetchall()]


def _readings(cur, start: date, end: date) -> list[tuple[str, float]]:
    cur.execute(
        f"""SELECT e.employee_code AS c, b.current_reading AS v FROM bills b JOIN employees e ON e.id = b.collector_id
            WHERE b.status = 'paid' AND b.billing_method = 'reading' AND b.current_reading IS NOT NULL
              AND b.paid_at >= {LO} AND b.paid_at < {HI}""",
        _b(start, end),
    )
    return [(r["c"], float(r["v"])) for r in cur.fetchall()]


def benford(cur, dataset: str = "consumption", days: int = 365, collector: str | None = None) -> dict:
    today = hr_logic.local_today(cur)
    start = today - timedelta(days=days - 1)
    pairs = _dataset_values(cur, dataset, start, today)
    readings = _readings(cur, start, today)
    collector = collector.upper() if collector else None
    scope = [v for c, v in pairs if not collector or c == collector]
    result = {"dataset": dataset, "dataset_label": DATASETS[dataset], "collector": collector,
              "start": start.isoformat(), "end": today.isoformat(),
              "law": fin_math.benford_first_digit(scope),
              "last_digit": fin_math.last_digit_test([v for c, v in readings if not collector or c == collector])}
    counts_by_c: dict[str, int] = {}
    for c, _ in pairs:
        counts_by_c[c] = counts_by_c.get(c, 0) + 1

    def enough_peers(me: str) -> bool:
        return sum(1 for k, n in counts_by_c.items() if k != me and n >= fin_math.MIN_BENFORD_N) >= 3

    if collector:
        peers = [v for c, v in pairs if c != collector]
        if enough_peers(collector):
            peer_dist = fin_math.benford_first_digit(peers)["observed"]
            if all(p > 0 for p in peer_dist):
                result["vs_peers"] = fin_math.benford_first_digit(scope, expected=peer_dist)
    by_c: dict[str, list[float]] = {}
    for c, v in pairs:
        by_c.setdefault(c, []).append(v)
    rd: dict[str, list[float]] = {}
    for c, v in readings:
        rd.setdefault(c, []).append(v)
    table = []
    for c in sorted(set(by_c) | set(rd)):
        bt = fin_math.benford_first_digit(by_c.get(c, []))
        ld = fin_math.last_digit_test(rd.get(c, []))
        row = {"collector": c, "n": bt["n"], "mad": bt["mad"], "level": bt["level"], "label": bt["label"],
               "peer_mad": None, "peer_level": "insufficient", "peer_label": "يحتاج 3 جباة آخرين",
               "readings_n": ld["n"], "share_0_5": ld["share_0_5"], "last_digit_p": ld["p_value"],
               "digit_preference": ld["suspicious"]}
        others = [v for k, vals in by_c.items() if k != c for v in vals]
        if enough_peers(c) and bt["n"] >= fin_math.MIN_BENFORD_N:
            pd = fin_math.benford_first_digit(others)["observed"]
            if all(x > 0 for x in pd):
                vp = fin_math.benford_first_digit(by_c[c], expected=pd)
                row.update(peer_mad=vp["mad"], peer_level=vp["level"], peer_label=vp["label"])
        table.append(row)
    result["collectors"] = sorted(table, key=lambda r: -(r["peer_mad"] or 0))
    result["notes"] = [
        "قانون بنفورد يناسب البيانات التي تمتد على عدة مراتب عشرية؛ استهلاك المنازل قد يتركز في نطاق ضيق، "
        "لذلك المقارنة مع بقية الجباة (vs_peers) أدق من المقارنة مع القانون النظري.",
        "اختبار الرقم الأخير: القراءات الحقيقية تنتهي بأي رقم بالتساوي تقريباً؛ كثرة 0 و5 تدل على قراءات مكتوبة دون النظر للعداد.",
        f"يلزم {fin_math.MIN_BENFORD_N} قيمة على الأقل لإصدار حكم.",
    ]
    return result


# ================================================================ anomalies

SEV_ORDER = {"high": 0, "medium": 1, "low": 2}
FLAG_RULES = {
    "reading_lower_than_previous": ("high", "قراءة أقل من السابقة"),
    "ocr_mismatch": ("high", "القراءة المدخلة تخالف قراءة الكاميرا"),
    "no_gps": ("medium", "فاتورة بدون موقع"),
    "high_consumption": ("medium", "استهلاك مرتفع بشكل غير طبيعي"),
    "estimate_on_working_meter": ("medium", "تقدير على عداد عامل"),
    "zero_consumption": ("low", "استهلاك صفري"),
    "no_photo": ("low", "بدون صورة عداد"),
}


def _iso(v):
    return v.isoformat() if v else None


def anomalies(cur, days: int = 30) -> dict:
    today = hr_logic.local_today(cur)
    start = today - timedelta(days=days - 1)
    bounds = _b(start, today)
    out: list[dict] = []

    def add(kind, sev, title, detail, at=None, collector=None, ref=None):
        out.append({"type": kind, "severity": sev, "title": title, "detail": detail, "at": _iso(at),
                    "collector": collector, "ref": ref})

    # 1. bills paid with warning flags
    cur.execute(
        f"""SELECT b.id, b.flags, b.paid_at, b.consumption, b.total_amount, e.employee_code, p.property_code
            FROM bills b JOIN employees e ON e.id = b.collector_id JOIN properties p ON p.id = b.property_id
            WHERE b.status = 'paid' AND jsonb_array_length(b.flags) > 0 AND b.paid_at >= {LO} AND b.paid_at < {HI}
            ORDER BY b.paid_at DESC LIMIT 400""",
        bounds,
    )
    for b in cur.fetchall():
        for fl in b["flags"]:
            if fl in FLAG_RULES:
                sev, label = FLAG_RULES[fl]
                add("bill_flag", sev, label, f"العقار {b['property_code']} | {float(b['total_amount']):,.0f} د.ع",
                    b["paid_at"], b["employee_code"], b["property_code"])

    # 2. the same reading twice in a row (meter not actually read?)
    cur.execute(
        f"""WITH x AS (
              SELECT b.property_id, b.collector_id, b.consumption, b.paid_at,
                     LAG(b.consumption) OVER (PARTITION BY b.property_id ORDER BY b.paid_at) AS prev_c
              FROM bills b WHERE b.status = 'paid' AND b.billing_method = 'reading' AND b.visit_type = 'periodic')
            SELECT x.paid_at, e.employee_code, p.property_code FROM x
            JOIN employees e ON e.id = x.collector_id JOIN properties p ON p.id = x.property_id
            WHERE x.consumption = 0 AND x.prev_c = 0 AND x.paid_at >= {LO} AND x.paid_at < {HI} LIMIT 100""",
        bounds,
    )
    for r in cur.fetchall():
        add("repeated_zero", "medium", "استهلاك صفري لزيارتين متتاليتين",
            f"العقار {r['property_code']}: العداد لم يتحرك، تحقق من صحة القراءة أو تعطل العداد", r["paid_at"],
            r["employee_code"], r["property_code"])

    # 3. receipts outside working hours
    cur.execute(
        f"""SELECT r.receipt_no, r.issued_at, r.total_amount, e.employee_code,
                   EXTRACT(HOUR FROM r.issued_at AT TIME ZONE %(tz)s) AS h
            FROM receipts r JOIN employees e ON e.id = r.collector_id
            WHERE r.issued_at >= {LO} AND r.issued_at < {HI}
              AND (EXTRACT(HOUR FROM r.issued_at AT TIME ZONE %(tz)s) < 7 OR EXTRACT(HOUR FROM r.issued_at AT TIME ZONE %(tz)s) >= 21)
            ORDER BY r.issued_at DESC LIMIT 100""",
        bounds,
    )
    for r in cur.fetchall():
        add("off_hours", "medium", "وصل خارج ساعات العمل",
            f"{r['receipt_no']} الساعة {int(r['h']):02d}:00 بمبلغ {float(r['total_amount']):,.0f} د.ع", r["issued_at"],
            r["employee_code"], r["receipt_no"])

    # 4. two receipts too close together (can't walk between two houses in 90 s)
    cur.execute(
        f"""WITH x AS (SELECT r.receipt_no, r.issued_at, r.collector_id, r.property_id,
                              LAG(r.issued_at) OVER (PARTITION BY r.collector_id ORDER BY r.issued_at) AS prev_at,
                              LAG(r.property_id) OVER (PARTITION BY r.collector_id ORDER BY r.issued_at) AS prev_p
                       FROM receipts r WHERE r.issued_at >= {LO} AND r.issued_at < {HI})
            SELECT x.receipt_no, x.issued_at, EXTRACT(EPOCH FROM x.issued_at - x.prev_at) AS gap, e.employee_code,
                   p1.lat, p1.lng, p2.lat AS plat, p2.lng AS plng
            FROM x JOIN employees e ON e.id = x.collector_id
            JOIN properties p1 ON p1.id = x.property_id JOIN properties p2 ON p2.id = x.prev_p
            WHERE x.prev_at IS NOT NULL AND x.issued_at - x.prev_at < INTERVAL '90 seconds' LIMIT 100""",
        bounds,
    )
    from .utils import haversine_m
    for r in cur.fetchall():
        dist = haversine_m(r["lat"], r["lng"], r["plat"], r["plng"])
        if dist > 30:
            add("rapid_receipts", "high", "وصلان متتاليان خلال وقت غير ممكن",
                f"{r['receipt_no']} بعد {int(r['gap'])} ثانية من الوصل السابق وعلى بعد {dist:.0f} م", r["issued_at"],
                r["employee_code"], r["receipt_no"])

    # 5. phone tracker says the collector was elsewhere when the receipt was issued
    cur.execute(
        f"""SELECT r.receipt_no, r.issued_at, e.employee_code, p.lat AS plat, p.lng AS plng, lp.lat, lp.lng, lp.accuracy_m
            FROM receipts r JOIN employees e ON e.id = r.collector_id JOIN properties p ON p.id = r.property_id
            JOIN LATERAL (SELECT lat, lng, accuracy_m FROM location_pings l WHERE l.employee_id = r.collector_id
                          AND l.recorded_at BETWEEN r.issued_at - INTERVAL '5 minutes' AND r.issued_at + INTERVAL '5 minutes'
                          ORDER BY ABS(EXTRACT(EPOCH FROM l.recorded_at - r.issued_at)) LIMIT 1) lp ON TRUE
            WHERE r.issued_at >= {LO} AND r.issued_at < {HI} ORDER BY r.issued_at DESC LIMIT 2000""",
        bounds,
    )
    for r in cur.fetchall():
        dist = haversine_m(r["lat"], r["lng"], r["plat"], r["plng"])
        if dist > 300 + float(r["accuracy_m"] or 0):
            add("far_from_property", "high", "موقع الجابي بعيد عن العقار وقت الوصل",
                f"{r['receipt_no']}: التتبع يضعه على بعد {dist:.0f} م من العقار", r["issued_at"], r["employee_code"],
                r["receipt_no"])

    # 6. cash held too long by collectors (now)
    cur.execute(
        """SELECT e.employee_code, MIN(r.issued_at) AS oldest, SUM(r.total_amount) AS held, COUNT(*) AS n
           FROM receipts r JOIN employees e ON e.id = r.collector_id WHERE r.reconciliation_id IS NULL
           GROUP BY e.employee_code HAVING MIN(r.issued_at) < NOW() - INTERVAL '48 hours'"""
    )
    for r in cur.fetchall():
        add("cash_held", "high" if float(r["held"]) > settings.CASH_IN_HAND_CAP_IQD / 2 else "medium",
            "نقد لم يُسلّم للمشرف منذ أكثر من 48 ساعة",
            f"{float(r['held']):,.0f} د.ع في {r['n']} وصل", r["oldest"], r["employee_code"], None)

    # 7. supervisors holding cash not deposited for > 72 h; deposits with a difference
    cur.execute(
        """SELECT e.employee_code, MIN(c.created_at) AS oldest, SUM(c.settled_cash) AS held
           FROM reconciliations c JOIN employees e ON e.id = c.supervisor_id
           WHERE c.deposit_id IS NULL AND c.resolution_status <> 'pending'
           GROUP BY e.employee_code HAVING MIN(c.created_at) < NOW() - INTERVAL '72 hours'"""
    )
    for r in cur.fetchall():
        add("deposit_delay", "high", "مشرف لم يودع النقد منذ أكثر من 72 ساعة", f"{_f(r['held']):,.0f} د.ع",
            r["oldest"], r["employee_code"], None)
    cur.execute(
        f"""SELECT d.id, d.created_at, d.difference, e.employee_code FROM bank_deposits d JOIN employees e ON e.id = d.supervisor_id
            WHERE d.difference <> 0 AND d.created_at >= {LO} AND d.created_at < {HI}""",
        bounds,
    )
    for r in cur.fetchall():
        add("deposit_difference", "high", "وصل الإيداع لا يطابق النقد المستلم",
            f"الإيداع #{r['id']}: الفرق {float(r['difference']):,.0f} د.ع", r["created_at"], r["employee_code"], str(r["id"]))

    # 8. per-collector behaviour vs peers
    risk_rows = risk(cur, days)["collectors"]
    for c in risk_rows:
        f = {x["key"]: x for x in c["factors"]}
        if f["master"]["raw"] and f["master"]["raw"] >= 0.1:
            add("master_share", "high" if f["master"]["raw"] >= 0.2 else "medium", "استخدام مرتفع للرمز الرئيسي",
                f["master"]["display"], None, c["employee_code"], None)
        if f["estimates"]["points"] >= 5:
            add("estimate_share", "medium", "نسبة تقديرات أعلى من بقية الجباة", f["estimates"]["display"], None, c["employee_code"], None)
        if f["digits"]["points"] >= 5:
            add("digit_preference", "high", "تفضيل الأرقام في القراءات", f["digits"]["display"], None, c["employee_code"], None)
        if c.get("low_ticket"):
            add("low_ticket", "medium", "متوسط الفاتورة أقل بكثير من بقية الجباة", c["low_ticket"], None, c["employee_code"], None)
        if f["shortage"]["raw"] and f["shortage"]["raw"] > 0:
            add("shortage", "high" if f["shortage"]["points"] >= 10 else "medium", "عجز نقدي في المطابقة",
                f["shortage"]["display"], None, c["employee_code"], None)

    out.sort(key=lambda a: (SEV_ORDER[a["severity"]], -(datetime.fromisoformat(a["at"]).timestamp() if a["at"] else 0)))
    counts: dict[str, int] = {}
    for a in out:
        counts[a["severity"]] = counts.get(a["severity"], 0) + 1
    return {"start": start.isoformat(), "end": today.isoformat(), "items": out, "counts": counts}


# ================================================================ risk score

def _clamp(x: float) -> float:
    return max(0.0, min(1.0, x))


def risk(cur, days: int = 30) -> dict:
    """Explainable 0-100 risk score per collector. Each factor shows its raw value and the points it adds."""
    today = hr_logic.local_today(cur)
    start = today - timedelta(days=days - 1)
    bounds = _b(start, today)
    cur.execute("SELECT id, employee_code, full_name, sector_id FROM employees WHERE role = 'collector' AND active ORDER BY employee_code")
    cols = cur.fetchall()
    if not cols:
        return {"start": start.isoformat(), "end": today.isoformat(), "collectors": [], "weights": WEIGHTS}

    def grouped(sql: str, extra: dict | None = None) -> dict[int, dict]:
        cur.execute(sql, {**bounds, **(extra or {})})
        return {r["cid"]: r for r in cur.fetchall()}

    rec = grouped(f"""SELECT collector_id AS cid, COALESCE(SUM(total_amount),0) AS total, COUNT(*) AS n,
                             COUNT(*) FILTER (WHERE verification_method = 'master_code') AS master
                      FROM receipts WHERE issued_at >= {LO} AND issued_at < {HI} GROUP BY collector_id""")
    bills = grouped(f"""SELECT collector_id AS cid, COUNT(*) AS n, COUNT(*) FILTER (WHERE billing_method = 'estimate') AS est,
                               COUNT(*) FILTER (WHERE flags ?| array['reading_lower_than_previous','ocr_mismatch','no_gps',
                                     'high_consumption','estimate_on_working_meter']) AS flagged,
                               AVG(gov_amount) FILTER (WHERE billing_method = 'reading' AND visit_type = 'periodic') AS avg_gov,
                               COUNT(*) FILTER (WHERE billing_method = 'reading' AND visit_type = 'periodic') AS n_read
                        FROM bills WHERE status = 'paid' AND paid_at >= {LO} AND paid_at < {HI} GROUP BY collector_id""")
    short = grouped(f"""SELECT collector_id AS cid, COALESCE(SUM(-difference) FILTER (WHERE difference < 0),0) AS short,
                               COUNT(*) FILTER (WHERE difference < 0) AS n_short
                        FROM reconciliations WHERE created_at >= {LO} AND created_at < {HI} GROUP BY collector_id""")
    sec = grouped(f"""SELECT actor_id AS cid,
                             COUNT(*) FILTER (WHERE action = 'mock_location') AS mock,
                             COUNT(*) FILTER (WHERE action = 'impossible_speed') AS speed,
                             COUNT(*) FILTER (WHERE action IN ('geofence_exit','geofence_violation')) AS geo,
                             COUNT(*) FILTER (WHERE action IN ('otp_failed','master_code_failed')) AS failed_codes
                      FROM audit_log WHERE created_at >= {LO} AND created_at < {HI} GROUP BY actor_id""")
    held = grouped("""SELECT collector_id AS cid, EXTRACT(EPOCH FROM NOW() - MIN(issued_at)) / 3600 AS hours
                      FROM receipts WHERE reconciliation_id IS NULL GROUP BY collector_id""")

    readings: dict[str, list[float]] = {}
    for c, v in _readings(cur, start, today):
        readings.setdefault(c, []).append(v)
    cons: dict[str, list[float]] = {}
    for c, v in _dataset_values(cur, "consumption", start, today):
        cons.setdefault(c, []).append(v)

    est_shares = [b["est"] / b["n"] for b in bills.values() if b["n"] >= 5]
    est_median = median(est_shares) if est_shares else 0.0
    tickets = [float(b["avg_gov"]) for b in bills.values() if b["n_read"] >= 10 and b["avg_gov"]]
    ticket_median = median(tickets) if len(tickets) >= 3 else None

    result = []
    for c in cols:
        cid, code = c["id"], c["employee_code"]
        r, b, s, se, h = rec.get(cid), bills.get(cid), short.get(cid), sec.get(cid), held.get(cid)
        collected = _f(r["total"]) if r else 0.0
        n_rec = r["n"] if r else 0
        factors = []

        def factor(key, label, weight, norm, raw, display):
            factors.append({"key": key, "label": label, "weight": weight, "raw": raw,
                            "points": round(weight * _clamp(norm), 1), "display": display})

        shortage = _f(s["short"]) if s else 0.0
        ratio = shortage / collected if collected else (1.0 if shortage else 0.0)
        factor("shortage", "العجز النقدي", WEIGHTS["shortage"], ratio / 0.01, round(ratio, 5),
               f"{shortage:,.0f} د.ع ({ratio:.2%} من المحصل) في {s['n_short'] if s else 0} مطابقة")
        master = r["master"] / n_rec if n_rec else 0.0
        factor("master", "الرمز الرئيسي", WEIGHTS["master"], master / 0.2, round(master, 4),
               f"{r['master'] if r else 0} من {n_rec} وصل ({master:.0%})")
        est = b["est"] / b["n"] if b and b["n"] else 0.0
        excess = est - est_median if b and b["n"] >= 5 else 0.0
        factor("estimates", "التقديرات بدل القراءة", WEIGHTS["estimates"], excess / 0.3, round(est, 4),
               f"{est:.0%} مقابل {est_median:.0%} لبقية الجباة")
        ld = fin_math.last_digit_test(readings.get(code, []))
        dig = (ld["share_0_5"] - 0.2) / 0.3 if ld["n"] >= 20 and ld["share_0_5"] is not None else 0.0
        factor("digits", "تفضيل الأرقام (0 و5)", WEIGHTS["digits"], dig, ld["share_0_5"],
               f"{(ld['share_0_5'] or 0):.0%} من {ld['n']} قراءة تنتهي بـ 0 أو 5 (الطبيعي ~20%)" if ld["n"] else "لا قراءات كافية")
        # household consumption spans a narrow range, so Benford's theoretical law doesn't apply to it;
        # compare the collector's first digits with everyone else's instead
        others = [k for k, v in cons.items() if k != code and len(v) >= fin_math.MIN_BENFORD_N]
        mine = cons.get(code, [])
        if len(others) >= 3 and len(mine) >= fin_math.MIN_BENFORD_N:
            peer_dist = fin_math.benford_first_digit([v for k in others for v in cons[k]])["observed"]
            bt = fin_math.benford_first_digit(mine, expected=peer_dist) if all(p > 0 for p in peer_dist) else None
        else:
            bt = None
        if bt:
            factor("benford", "توزيع الأرقام (مقارنة بالزملاء)", WEIGHTS["benford"], (bt["mad"] - 0.015) / 0.03, bt["mad"],
                   f"MAD {bt['mad']:.3f} مقابل بقية الجباة، n={bt['n']}")
        else:
            factor("benford", "توزيع الأرقام (مقارنة بالزملاء)", WEIGHTS["benford"], 0, None,
                   f"غير متاح: يحتاج {fin_math.MIN_BENFORD_N} قراءة له و3 جباة آخرين على الأقل")
        sec_score = ((se["mock"] * 3 + se["speed"] + se["geo"] + se["failed_codes"] * 0.5) if se else 0)
        factor("security", "أحداث أمنية", WEIGHTS["security"], sec_score / 6, sec_score,
               (f"موقع مزيف {se['mock']} | سرعة مستحيلة {se['speed']} | خروج من القاطع {se['geo']} | رموز خاطئة {se['failed_codes']}"
                if se else "لا شيء"))
        flagged = b["flagged"] / b["n"] if b and b["n"] else 0.0
        factor("flags", "فواتير عليها ملاحظات", WEIGHTS["flags"], flagged / 0.3, round(flagged, 4),
               f"{b['flagged'] if b else 0} من {b['n'] if b else 0} فاتورة")
        hours = float(h["hours"]) if h else 0.0
        factor("holding", "الاحتفاظ بالنقد", WEIGHTS["holding"], (hours - 24) / 72, round(hours, 1),
               f"أقدم نقد غير مسلّم منذ {hours:.0f} ساعة" if h else "لا نقد بحوزته")

        score = round(sum(f["points"] for f in factors))
        level = "high" if score >= 60 else ("medium" if score >= 30 else "low")
        row = {"employee_code": code, "full_name": c["full_name"], "score": score, "level": level,
               "level_label": {"high": "مرتفع", "medium": "متوسط", "low": "منخفض"}[level],
               "collected": collected, "receipts": n_rec, "factors": factors,
               "top_reasons": [f["label"] for f in sorted(factors, key=lambda x: -x["points"]) if f["points"] >= 3][:3]}
        if ticket_median and b and b["n_read"] >= 10 and b["avg_gov"] and float(b["avg_gov"]) < 0.5 * ticket_median:
            row["low_ticket"] = f"{float(b['avg_gov']):,.0f} د.ع مقابل {ticket_median:,.0f} د.ع لبقية الجباة"
        result.append(row)
    result.sort(key=lambda x: -x["score"])
    return {"start": start.isoformat(), "end": today.isoformat(), "collectors": result, "weights": WEIGHTS}


WEIGHTS = {"shortage": 20, "master": 15, "security": 15, "estimates": 10, "digits": 10, "benford": 10, "flags": 10, "holding": 10}


# ================================================================ arrears aging

BUCKETS = [(30, "0-30", "منتظم"), (60, "31-60", "متأخر"), (90, "61-90", "متأخر جداً"), (180, "91-180", "متعثر"),
           (10 ** 6, "180+", "متعثر جداً")]


def aging(cur, top: int = 50) -> dict:
    cur.execute(
        """WITH p AS (
             SELECT p.id, p.property_code, p.address, p.property_class, p.sector_id, p.citizen_id,
                    COALESCE(p.activated_at, p.registered_at) AS since,
                    (SELECT MAX(paid_at) FROM bills b WHERE b.property_id = p.id AND b.status = 'paid') AS last_paid,
                    (SELECT SUM(consumption) / NULLIF(SUM(period_days), 0) FROM bills b WHERE b.property_id = p.id
                       AND b.status = 'paid' AND b.billing_method = 'reading' AND b.consumption IS NOT NULL) AS avg_daily
             FROM properties p WHERE p.status = 'active')
           SELECT p.*, t.unit_rate, t.monthly_estimate, s.code AS sector_code, s.name AS sector_name, c.full_name AS citizen
           FROM p JOIN tariffs t ON t.property_class = p.property_class JOIN sectors s ON s.id = p.sector_id
           JOIN citizens c ON c.id = p.citizen_id"""
    )
    now = datetime.now(timezone.utc)
    buckets = {key: {"key": key, "label": label, "properties": 0, "estimated": 0.0} for _, key, label in BUCKETS}
    sectors: dict[str, dict] = {}
    items = []
    for r in cur.fetchall():
        ref = r["last_paid"] or r["since"]
        d = max(0, (now - ref).days)
        daily = (float(r["avg_daily"]) * float(r["unit_rate"])) if r["avg_daily"] else float(r["monthly_estimate"]) / 30
        est = round(d * daily)
        key = next(k for lim, k, _ in BUCKETS if d <= lim)
        buckets[key]["properties"] += 1
        buckets[key]["estimated"] += est
        sec = sectors.setdefault(r["sector_code"], {"code": r["sector_code"], "name": r["sector_name"], "properties": 0,
                                                     "overdue": 0, "estimated": 0.0})
        sec["properties"] += 1
        sec["estimated"] += est
        if d > settings.ROUTE_DUE_DAYS:
            sec["overdue"] += 1
        items.append({"property_code": r["property_code"], "citizen": r["citizen"], "address": r["address"],
                      "sector": r["sector_name"], "property_class": r["property_class"], "days": d,
                      "never_paid": r["last_paid"] is None, "last_paid": _iso(r["last_paid"]), "estimated": est})
    items.sort(key=lambda x: -x["estimated"])
    total = sum(b["estimated"] for b in buckets.values())
    return {"buckets": list(buckets.values()), "total_estimated": round(total),
            "sectors": sorted(sectors.values(), key=lambda s: -s["estimated"]), "top": items[:top],
            "note": "المبالغ تقديرية للحصة الحكومية منذ آخر دفعة: (متوسط الاستهلاك اليومي للعقار × التعرفة) أو تقدير الفئة إن لم توجد قراءات."}
