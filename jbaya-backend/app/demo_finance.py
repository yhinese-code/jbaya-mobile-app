"""Fills a TEST database with ~90 days of realistic collection history so the finance dashboards,
forecast, Benford and risk scores have something to show.

    .\\venv\\Scripts\\python -m app.demo_finance --yes

- JB-0492 behaves honestly.
- JB-0493 (created here) is the "suspicious" demo collector: readings typed as round numbers, many estimates,
  frequent master-code use, small cash shortages.
Everything goes through the same tables the app uses, so the ledger stays balanced.
NEVER run this on the production database: it creates fake citizens, bills and money.
"""
import json
import random
import sys
from datetime import datetime, time, timedelta, timezone
from zoneinfo import ZoneInfo

from .config import settings
from .db import dict_cursor, get_conn, init_pool
from .security import hash_password
from .seed import MANSOUR
from .seed import run as seed_run
from .utils import round_iqd

PROPS_PER_COLLECTOR = 120
DAYS = 90


def _tz():
    try:
        return ZoneInfo(settings.APP_TIMEZONE)
    except Exception:                       # Windows without tzdata: Baghdad is UTC+3 all year
        return timezone(timedelta(hours=3))


def main():
    if "--yes" not in sys.argv:
        print(__doc__)
        print("Add --yes to continue (test databases only).")
        return
    random.seed(2026)
    init_pool()
    seed_run()
    tz = _tz()
    today = datetime.now(tz).date()
    fee = settings.COMPANY_FEE_IQD
    with get_conn() as conn, dict_cursor(conn) as cur:
        cur.execute("SELECT COUNT(*) AS n FROM citizens WHERE full_name LIKE 'مواطن تجريبي%%'")
        if cur.fetchone()["n"]:
            print("Demo data already exists. Nothing done.")
            return
        cur.execute("SELECT id FROM sectors WHERE code = 'S-01'")
        sector = cur.fetchone()["id"]
        cur.execute("SELECT id FROM employees WHERE employee_code = 'SP-01'")
        sup = cur.fetchone()["id"]
        cur.execute("SELECT id FROM employees WHERE employee_code = 'FN-01'")
        fin = cur.fetchone()["id"]
        cur.execute(
            """INSERT INTO employees (employee_code, full_name, role, password_hash, sector_id, supervisor_id, base_salary,
                                      allowance_transport, allowance_risk, hire_date)
               VALUES ('JB-0493', 'جابي تجريبي 2', 'collector', %s, %s, %s, 600000, 50000, 25000, DATE '2026-01-01')
               ON CONFLICT (employee_code) DO NOTHING""",
            (hash_password("Jbaya@2026"), sector, sup),
        )
        cur.execute("SELECT id, employee_code FROM employees WHERE employee_code IN ('JB-0492', 'JB-0493')")
        collectors = {r["employee_code"]: r["id"] for r in cur.fetchall()}
        cur.execute("SELECT unit_rate, monthly_estimate FROM tariffs WHERE property_class = 'Household'")
        t = cur.fetchone()
        rate, monthly = float(t["unit_rate"]), float(t["monthly_estimate"])
        lat0, lat1, lng0, lng1 = MANSOUR[0][0], MANSOUR[1][0], MANSOUR[0][1], MANSOUR[2][1]

        start = today - timedelta(days=DAYS)
        n_receipts = 0
        for code, cid in collectors.items():
            shady = code == "JB-0493"
            day_receipts: dict = {}
            for i in range(PROPS_PER_COLLECTOR):
                cur.execute("INSERT INTO citizens (full_name, whatsapp_phone, phone_verified_at) VALUES (%s, %s, NOW()) RETURNING id",
                            (f"مواطن تجريبي {code[-3:]}-{i}", f"96478{random.randint(10_000_000, 99_999_999)}"))
                citizen = cur.fetchone()["id"]
                cur.execute("SELECT 'BGD-' || LPAD(nextval('property_code_seq')::text, 6, '0') AS c")
                pcode = cur.fetchone()["c"]
                lat, lng = random.uniform(lat0 + 0.001, lat1 - 0.001), random.uniform(lng0 + 0.001, lng1 - 0.001)
                first_day = start + timedelta(days=i % 30)
                reg_at = datetime.combine(first_day, time(9, 0), tz)
                cur.execute(
                    """INSERT INTO properties (property_code, citizen_id, sector_id, address, property_class, lat, lng, gps_accuracy_m,
                                               meter_status, status, registered_by, registered_at, activated_at)
                       VALUES (%s,%s,%s,%s,'Household',%s,%s,8,'working','active',%s,%s,%s) RETURNING id""",
                    (pcode, citizen, sector, f"محلة 600 زقاق {i // 10} دار {i}", lat, lng, cid, reg_at, reg_at),
                )
                pid = cur.fetchone()["id"]
                daily_use = random.lognormvariate(0.2, 0.5)                 # m3/day, ~1.2 on average
                reading = float(random.randint(150, 4000))
                visit = first_day
                first = True
                while visit < today:
                    if visit.weekday() in settings.WEEKEND_DAYS:
                        visit += timedelta(days=1)
                        continue
                    hour = random.choice([9, 10, 11, 12, 13, 14, 15]) if not (shady and random.random() < 0.05) else 22
                    paid_at = datetime.combine(visit, time(hour, random.randint(0, 59), random.randint(0, 59)), tz)
                    if first:
                        method, visit_type, prev, cur_r, cons, gov = "estimate", "first_visit", None, reading, None, monthly
                    elif shady and random.random() < 0.3:
                        method, visit_type, prev, cur_r, cons = "estimate", "periodic", reading, None, None
                        gov = monthly * 0.6                                   # undercharged estimate
                    else:
                        cons = round(daily_use * 30 * random.uniform(0.8, 1.2))
                        prev, cur_r = reading, reading + cons
                        if shady and random.random() < 0.7:                 # typed without looking: a round number
                            cur_r = max(prev, round(cur_r / 10) * 10)
                            cons = cur_r - prev
                        method, visit_type, gov = "reading", "periodic", cons * rate
                    gov = round_iqd(gov, settings.ROUND_TO_IQD)
                    flags = ["estimate_on_working_meter"] if (method == "estimate" and not first) else []
                    cur.execute(
                        """INSERT INTO bills (property_id, collector_id, visit_type, billing_method, previous_reading, current_reading,
                                              consumption, unit_rate, period_days, gov_amount, company_fee, total_amount, status, flags,
                                              created_at, paid_at)
                           VALUES (%s,%s,%s,%s,%s,%s,%s,%s,30,%s,%s,%s,'paid',%s,%s,%s) RETURNING id""",
                        (pid, cid, visit_type, method, prev, cur_r, cons, rate, gov, fee, gov + fee, json.dumps(flags), paid_at, paid_at),
                    )
                    bill = cur.fetchone()["id"]
                    if cur_r is not None:
                        cur.execute("""INSERT INTO meter_readings (property_id, bill_id, reading, reading_type, taken_by, taken_at)
                                       VALUES (%s,%s,%s,%s,%s,%s)""", (pid, bill, cur_r, "baseline" if first else "actual", cid, paid_at))
                        reading = cur_r
                    master = random.random() < (0.18 if shady else 0.01)
                    cur.execute("SELECT 'RCP-' || nextval('receipt_no_seq')::text AS no")
                    rno = cur.fetchone()["no"]
                    cur.execute(
                        """INSERT INTO receipts (receipt_no, bill_id, property_id, collector_id, gov_amount, company_fee, total_amount,
                                                 verification_method, issued_at) VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s) RETURNING id""",
                        (rno, bill, pid, cid, gov, fee, gov + fee, "master_code" if master else "otp", paid_at),
                    )
                    rid = cur.fetchone()["id"]
                    if master:
                        cur.execute("""INSERT INTO master_code_uses (collector_id, property_id, bill_id, purpose, reason, window_index, used_at)
                                       VALUES (%s,%s,%s,'payment','المواطن لا يملك هاتفاً',0,%s)""", (cid, pid, bill, paid_at))
                    day_receipts.setdefault(visit, []).append((rid, gov + fee))
                    n_receipts += 1
                    first = False
                    visit += timedelta(days=random.randint(27, 33))

            # end-of-day blind reconciliation with the supervisor (today's cash stays with the collector)
            undeposited = []
            for day in sorted(day_receipts):
                if day >= today:
                    continue
                recs = day_receipts[day]
                expected = sum(a for _, a in recs)
                short = 5000.0 if (shady and random.random() < 0.15) else 0.0
                counted = expected - short
                at = datetime.combine(day, time(17, 0), tz)
                cur.execute(
                    """INSERT INTO reconciliations (collector_id, supervisor_id, counted_cash, expected_cash, difference, receipts_count,
                                                    status, resolution_status, resolution_action, resolution_note, resolved_by, resolved_at,
                                                    settled_cash, created_at)
                       VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s) RETURNING id""",
                    (cid, sup, counted, expected, -short, len(recs), "shortage" if short else "matched",
                     "resolved" if short else "none_needed", "salary_deduction" if short else None,
                     "عجز - يستقطع من الراتب" if short else None, sup if short else None, at if short else None, counted, at),
                )
                rec = cur.fetchone()["id"]
                cur.execute("UPDATE receipts SET reconciliation_id = %s WHERE id = ANY(%s)", (rec, [r for r, _ in recs]))
                undeposited.append((rec, counted, day))
                # weekly bank deposit by the supervisor, verified by finance the next day (not the last few days)
                if day.weekday() == 3 and day < today - timedelta(days=3):
                    total = sum(c for _, c, _ in undeposited)
                    dep_at = datetime.combine(day, time(18, 0), tz)
                    cur.execute(
                        """INSERT INTO bank_deposits (supervisor_id, amount, expected_amount, difference, bank_name, slip_number,
                                                      slip_photo_path, status, finance_note, verified_by, verified_at, created_at)
                           VALUES (%s,%s,%s,0,'مصرف الرافدين',%s,'demo/none.jpg','verified','بيانات تجريبية',%s,%s,%s) RETURNING id""",
                        (sup, total, total, f"DEMO-{code[-3:]}-{day.isoformat()}", fin, dep_at + timedelta(days=1), dep_at),
                    )
                    dep = cur.fetchone()["id"]
                    cur.execute("UPDATE reconciliations SET deposit_id = %s WHERE id = ANY(%s)", (dep, [r for r, _, _ in undeposited]))
                    undeposited = []
    print(f"Demo finance data created: {n_receipts} receipts over {DAYS} days for JB-0492 (honest) and JB-0493 (suspicious).")


if __name__ == "__main__":
    main()
