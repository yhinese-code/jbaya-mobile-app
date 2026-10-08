"""Breakeven and collector performance.

A collector "pays for himself" on a working day when the company's earnings from his receipts that day
(service fee + the company's % of the water amount) cover what he costs that day:
    daily cost   = (base salary + allowances) / working days in the month  +  commission earned that day
    earnings     = sum over his receipts of (company fee + company share)
    losing day   = a working day (not on leave) where earnings < daily cost; a day with no receipts is a losing day
    breakeven    = receipts per day needed = daily fixed cost / average net earning per receipt
                   (net = earning - commission when the receipt was confirmed by the citizen's code)

Who sees what:
- owner, finance, command: everything, in money (per_collector_money)
- supervisor: house counts and plain-language labels, never money (team_view)
- collector: his own coaching — houses still needed today, vs the team average (coach)
"""
import math
from datetime import date, timedelta

from . import hr_logic
from .config import settings

def houses(n: int) -> str:
    """Arabic count of houses with correct agreement."""
    if n == 1:
        return "منزل واحد"
    if n == 2:
        return "منزلان"
    if 3 <= n <= 10:
        return f"{n} منازل"
    return f"{n} منزلاً"


def days_ar(n: int) -> str:
    if n == 1:
        return "يوم واحد"
    if n == 2:
        return "يومان"
    if 3 <= n <= 10:
        return f"{n} أيام"
    return f"{n} يوماً"


def _f(v) -> float:
    return float(v) if v is not None else 0.0


def _fixed_monthly(emp: dict) -> float:
    return _f(emp["base_salary"]) + _f(emp["allowance_transport"]) + _f(emp["allowance_phone"]) + _f(emp["allowance_risk"])


def _daily_receipts(cur, start: date, end: date, collector_ids: list[int]) -> dict[int, dict[date, dict]]:
    """{collector: {local day: {n, otp, earnings}}}"""
    cur.execute(
        f"""SELECT collector_id AS cid, (issued_at AT TIME ZONE %(tz)s)::date AS day, COUNT(*) AS n,
                   COUNT(*) FILTER (WHERE verification_method = 'otp') AS otp,
                   COALESCE(SUM(company_fee + company_share + gain_share), 0) AS earn
            FROM receipts WHERE issued_at >= {hr_logic.LO} AND issued_at < {hr_logic.HI} AND collector_id = ANY(%(ids)s)
            GROUP BY 1, 2""",
        {"s": start, "e": end, "tz": settings.APP_TIMEZONE, "ids": collector_ids},
    )
    out: dict[int, dict[date, dict]] = {}
    for r in cur.fetchall():
        out.setdefault(r["cid"], {})[r["day"]] = {"n": r["n"], "otp": r["otp"], "earnings": _f(r["earn"])}
    return out


def _avg_net_per_receipt(cur, collector_id: int | None, today: date) -> float:
    """Average company earning per receipt over the last 60 days, minus commission where it applies."""
    cur.execute(
        """SELECT COUNT(*) AS n, COALESCE(SUM(company_fee + company_share + gain_share), 0) AS earn,
                  COUNT(*) FILTER (WHERE verification_method = 'otp') AS otp
           FROM receipts WHERE issued_at >= NOW() - INTERVAL '60 days' AND (%(c)s::int IS NULL OR collector_id = %(c)s)""",
        {"c": collector_id},
    )
    r = cur.fetchone()
    if r["n"] >= 20:
        return max(1.0, (_f(r["earn"]) - r["otp"] * settings.COMMISSION_PER_RECEIPT_IQD) / r["n"])
    if collector_id is not None:
        return _avg_net_per_receipt(cur, None, today)            # too little history: use the company average
    fallback = settings.COMPANY_FEE_IQD - settings.COMMISSION_PER_RECEIPT_IQD
    return max(1.0, (_f(r["earn"]) - r["otp"] * settings.COMMISSION_PER_RECEIPT_IQD) / r["n"]) if r["n"] else max(1.0, fallback)


def _team_avg_per_day(cur, today: date) -> float:
    """Receipts per collector per working day over the last 30 days (complete days)."""
    start = today - timedelta(days=30)
    days = len(hr_logic.working_days(start, today - timedelta(days=1)))
    cur.execute("SELECT COUNT(*) AS n FROM employees WHERE role IN ('collector','supervisor') AND active")
    collectors = cur.fetchone()["n"]
    cur.execute(
        f"""SELECT COUNT(*) AS n FROM receipts r JOIN employees e ON e.id = r.collector_id AND e.active
            WHERE r.issued_at >= {hr_logic.LO} AND r.issued_at < {hr_logic.HI}""",
        {"s": start, "e": today - timedelta(days=1), "tz": settings.APP_TIMEZONE},
    )
    n = cur.fetchone()["n"]
    return n / (collectors * days) if collectors and days else 0.0


def collector_month(cur, emp: dict, start: date, end: date, today: date, receipts: dict[date, dict]) -> dict:
    """Day-by-day money picture of one collector for one month."""
    month_days = hr_logic.working_days(start, end)
    daily_fixed = _fixed_monthly(emp) / len(month_days) if month_days else 0.0
    hire = emp.get("hire_date")
    leave = hr_logic.approved_leave_days(cur, emp["id"], start, end)
    days, earnings, cost, losing, profitable, streak, receipts_n, counted_days = [], 0.0, 0.0, 0, 0, 0, 0, 0
    d = start
    while d <= min(end, today):
        r = receipts.get(d, {"n": 0, "otp": 0, "earnings": 0.0})
        if d in month_days and (not hire or d >= hire):
            commission = r["otp"] * settings.COMMISSION_PER_RECEIPT_IQD
            day_cost = daily_fixed + commission
            if d == today:
                status = "today"
            elif d in leave:
                status = "leave"
            else:
                status = "profitable" if r["earnings"] >= day_cost else "losing"
            days.append({"day": d.isoformat(), "receipts": r["n"], "earnings": round(r["earnings"]), "cost": round(day_cost),
                         "status": status})
            earnings += r["earnings"]
            cost += day_cost
            receipts_n += r["n"]
            if status in ("profitable", "losing"):
                counted_days += 1
                if status == "losing":
                    losing += 1
                    streak += 1
                else:
                    profitable += 1
                    streak = 0
        elif r["n"]:                        # a weekend/pre-hire day with receipts still earned money
            earnings += r["earnings"]
            receipts_n += r["n"]
            days.append({"day": d.isoformat(), "receipts": r["n"], "earnings": round(r["earnings"]), "cost": 0, "status": "extra"})
        d += timedelta(days=1)
    return {"daily_fixed_cost": round(daily_fixed), "monthly_fixed_cost": round(_fixed_monthly(emp)),
            "earnings": round(earnings), "cost": round(cost), "net": round(earnings - cost),
            "receipts": receipts_n, "working_days_counted": counted_days, "profitable_days": profitable,
            "losing_days": losing, "losing_streak": streak, "days": days,
            "receipts_per_day": round(receipts_n / counted_days, 1) if counted_days else None}


def per_collector_money(cur, period: str | None = None) -> dict:
    today = hr_logic.local_today(cur)
    if not period:
        period = f"{today.year}-{today.month:02d}"
    start, end = hr_logic.parse_period(period)
    # supervisors also collect with the same quota (Phase 5)
    cur.execute("SELECT * FROM employees WHERE role IN ('collector','supervisor') AND active ORDER BY employee_code")
    emps = cur.fetchall()
    receipts = _daily_receipts(cur, start, end, [e["id"] for e in emps])
    team_avg = _team_avg_per_day(cur, today)
    company_avg = _avg_net_per_receipt(cur, None, today)
    rows = []
    for e in emps:
        m = collector_month(cur, e, start, end, today, receipts.get(e["id"], {}))
        net_per = _avg_net_per_receipt(cur, e["id"], today)
        be = math.ceil(m["daily_fixed_cost"] / net_per) if net_per > 0 else None
        flag = m["losing_streak"] >= settings.LOSING_STREAK_ALERT_DAYS
        rows.append({"employee_code": e["employee_code"], "full_name": e["full_name"], "role": e["role"], **m,
                     "net_per_receipt": round(net_per), "breakeven_receipts_per_day": be,
                     "lazy_flag": flag, "label": _label(m, be, team_avg)})
    rows.sort(key=lambda r: r["net"])
    return {"period": period, "today": today.isoformat(), "team_avg_receipts_per_day": round(team_avg, 1),
            "company_net_per_receipt": round(company_avg), "streak_alert_days": settings.LOSING_STREAK_ALERT_DAYS,
            "collectors": rows,
            "totals": {"earnings": sum(r["earnings"] for r in rows), "cost": sum(r["cost"] for r in rows),
                       "net": sum(r["net"] for r in rows), "flagged": sum(1 for r in rows if r["lazy_flag"])}}


def _label(m: dict, breakeven: int | None, team_avg: float) -> str:
    rpd = m["receipts_per_day"]
    if m["working_days_counted"] == 0:
        return "لا توجد أيام عمل مكتملة بعد"
    if m["losing_streak"] >= settings.LOSING_STREAK_ALERT_DAYS:
        return f"متقاعس: {days_ar(m['losing_streak'])} متتالية دون تغطية كلفته"
    if breakeven and rpd is not None and rpd < breakeven:
        return "أقل من نقطة التعادل"
    if rpd is not None and team_avg and rpd < team_avg * 0.8:
        return "أقل من معدل الفريق"
    return "يغطي كلفته"


def company_breakeven(cur) -> dict:
    """Owner only: receipts the whole company needs this month to cover every salary and allowance."""
    today = hr_logic.local_today(cur)
    start, end = hr_logic.parse_period(f"{today.year}-{today.month:02d}")
    cur.execute("SELECT * FROM employees WHERE active AND role <> 'admin'")
    staff = cur.fetchall()
    monthly = sum(_fixed_monthly(e) for e in staff)
    net_per = _avg_net_per_receipt(cur, None, today)
    need = math.ceil(monthly / net_per) if net_per else None
    cur.execute(
        f"""SELECT COUNT(*) AS n, COALESCE(SUM(company_fee + company_share + gain_share), 0) AS earn FROM receipts
            WHERE issued_at >= {hr_logic.LO} AND issued_at < {hr_logic.HI}""",
        {"s": start, "e": end, "tz": settings.APP_TIMEZONE},
    )
    r = cur.fetchone()
    wd = hr_logic.working_days(start, end)
    done = [d for d in wd if d < today]
    return {"monthly_staff_cost": round(monthly), "staff": len(staff), "net_per_receipt": round(net_per),
            "receipts_needed_month": need, "receipts_this_month": r["n"], "earnings_this_month": round(_f(r["earn"])),
            "receipts_needed_per_working_day": math.ceil(need / len(wd)) if need and wd else None,
            "on_track": (r["n"] >= (need or 0) * len(done) / len(wd)) if wd else None,
            "working_days": len(wd), "working_days_done": len(done)}


# ---------------------------------------------------------------- views without money

def team_view(cur, supervisor_id: int | None) -> dict:
    """Supervisor: house counts and labels for his collectors — never money."""
    today = hr_logic.local_today(cur)
    data = per_collector_money(cur)
    cur.execute("SELECT employee_code FROM employees WHERE role = 'collector' AND active AND (%s::int IS NULL OR supervisor_id = %s)",
                (supervisor_id, supervisor_id))
    mine = {r["employee_code"] for r in cur.fetchall()}
    today_iso = today.isoformat()
    out = []
    for c in data["collectors"]:
        if c["employee_code"] not in mine:
            continue
        today_n = next((d["receipts"] for d in c["days"] if d["day"] == today_iso), 0)
        target = c["breakeven_receipts_per_day"]
        out.append({"employee_code": c["employee_code"], "full_name": c["full_name"], "today_receipts": today_n,
                    "daily_target": target, "remaining_today": max(0, (target or 0) - today_n),
                    "receipts_per_day": c["receipts_per_day"], "weak_days": c["losing_days"], "good_days": c["profitable_days"],
                    "weak_streak": c["losing_streak"], "flag": c["lazy_flag"], "label": _team_label(c, data["team_avg_receipts_per_day"]),
                    "days": [{"day": d["day"], "receipts": d["receipts"], "status": d["status"]} for d in c["days"]]})
    out.sort(key=lambda r: (not r["flag"], r["receipts_per_day"] or 0))
    behind = [r for r in out if r["label"] != "ضمن الهدف"]
    laggards = [r for r in out if r["flag"]]
    if not out:
        banner = None
    elif laggards or len(behind) * 2 >= len(out):
        names = "، ".join(r["full_name"] for r in (laggards or behind)[:4])
        banner = {"level": "bad", "title": "فريقك دون المستوى المطلوب",
                  "text": f"{len(behind)} من أصل {len(out)} في فريقك دون الهدف هذا الشهر. الأكثر تأخراً: {names}. "
                          "تابعهم ميدانياً اليوم ووزّع العقارات المتأخرة."}
    elif behind:
        banner = {"level": "warn", "title": "بعض أعضاء فريقك متأخرون",
                  "text": "، ".join(r["full_name"] for r in behind[:4]) + " دون الهدف هذا الشهر."}
    else:
        banner = {"level": "good", "title": "فريقك ضمن الهدف", "text": "استمروا على هذا المستوى."}
    return {"today": today_iso, "team_avg_receipts_per_day": data["team_avg_receipts_per_day"], "collectors": out,
            "laggards": len(laggards), "behind": len(behind), "banner": banner}


def _team_label(c: dict, team_avg: float) -> str:
    if c["lazy_flag"]:
        return f"موظف متأخر: {days_ar(c['losing_streak'])} متتالية تحت الهدف"
    rpd = c["receipts_per_day"]
    if rpd is not None and c["breakeven_receipts_per_day"] and rpd < c["breakeven_receipts_per_day"]:
        return "دون الهدف اليومي هذا الشهر"
    if rpd is not None and team_avg and rpd < team_avg * 0.8:
        return "أبطأ من بقية الفريق"
    return "ضمن الهدف"


def coach(cur, emp: dict) -> dict:
    """The collector's (or field supervisor's) own card: whether he is on track — NO numbers, no money (Phase 5)."""
    today = hr_logic.local_today(cur)
    start, end = hr_logic.parse_period(f"{today.year}-{today.month:02d}")
    receipts = _daily_receipts(cur, start, end, [emp["id"]]).get(emp["id"], {})
    m = collector_month(cur, emp, start, end, today, receipts)
    net_per = _avg_net_per_receipt(cur, emp["id"], today)
    target = math.ceil(m["daily_fixed_cost"] / net_per) if net_per > 0 and m["daily_fixed_cost"] else None
    team_avg = _team_avg_per_day(cur, today)
    today_n = receipts.get(today, {"n": 0})["n"]
    working = hr_logic.is_working_day(today)
    rpd = m["receipts_per_day"]
    streak = m["losing_streak"]

    if streak >= settings.LOSING_STREAK_ALERT_DAYS:
        status, title = "underperforming", "أداؤك ضعيف"
        text = "أنت دون المستوى المطلوب منذ عدة أيام متتالية، ومشرفك يرى هذا التنبيه. ارفع عدد المنازل التي تجبيها يومياً."
    elif streak or (target and rpd is not None and rpd < target) or (team_avg and rpd is not None and rpd < team_avg * 0.8):
        status, title = "behind", "أنت متأخر قليلاً"
        text = "أداؤك هذا الشهر أقل من المطلوب. زد عدد المنازل اليوم لتعود إلى المسار."
    else:
        status, title = "on_track", "أداؤك جيد"
        text = "أنت ضمن الهدف المطلوب. استمر على هذا المستوى."
    messages = [{"level": {"underperforming": "bad", "behind": "warn", "on_track": "good"}[status], "text": text}]
    if not working:
        messages.append({"level": "info", "text": "اليوم عطلة. أي منزل تجبيه اليوم يُحسب لك إضافة."})
    elif target and today_n >= target:
        messages.append({"level": "good", "text": "أحسنت! حققت هدف اليوم. كل منزل إضافي يرفع تقييمك."})
    elif target:
        messages.append({"level": "info", "text": "لم تحقق هدف اليوم بعد. استمر."})
    return {"today": today.isoformat(), "working_day": working, "status": status, "title": title, "messages": messages,
            "days": [{"day": d["day"], "status": d["status"]} for d in m["days"]]}
