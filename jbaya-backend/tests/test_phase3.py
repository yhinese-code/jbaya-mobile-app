"""Phase 3: HR - employees, self-service attendance, leave workflow & balances, expenses, payroll math,
appraisals, custody, discipline, recruitment and training."""
import base64
from datetime import date, timedelta

import pytest

from app.config import settings
from test_flows import PWD, client, db, login, outbox  # noqa: F401

JPEG = base64.b64encode(b"\xff\xd8\xff\xe0" + b"\x00" * 200).decode()


@pytest.fixture(autouse=True)
def hr_settings(monkeypatch):
    monkeypatch.setattr(settings, "WEEKEND_DAYS", [4])            # Friday
    monkeypatch.setattr(settings, "INCOME_TAX_PCT", 0)
    monkeypatch.setattr(settings, "SOCIAL_SECURITY_PCT", 5)
    monkeypatch.setattr(settings, "COMMISSION_PER_RECEIPT_IQD", 500)


def _next_working_days(n: int, start_after: int = 7) -> tuple[date, date]:
    d = date.today() + timedelta(days=start_after)
    days = []
    while len(days) < n:
        if d.weekday() != 4:
            days.append(d)
        d += timedelta(days=1)
    return days[0], days[-1]


def test_create_employee_and_training(client):
    hr = login(client, "HR-01")
    c = client.post("/hr/training/courses", headers=hr, json={"title": "السلامة الميدانية", "mandatory_for": "collector"}).json()
    r = client.post("/hr/employees", headers=hr, json={
        "employee_code": "JB-0777", "full_name": "حسين علي", "role": "collector", "password": PWD, "phone": "07711223344",
        "sector_code": "S-01", "supervisor_code": "SP-01", "job_title": "جابي", "hire_date": "2026-01-01",
        "base_salary": 600000, "allowance_transport": 50000, "allowance_risk": 25000,
    })
    assert r.status_code == 200, r.text
    prof = client.get("/hr/employees/JB-0777", headers=hr).json()
    assert prof["profile"]["base_salary"] == 600000 and prof["profile"]["supervisor_code"] == "SP-01"
    assert prof["training"][0]["title"] == "السلامة الميدانية" and prof["training"][0]["status"] == "assigned"
    assert prof["leave_balances"]["annual"]["entitlement"] == settings.LEAVE_ANNUAL_DAYS
    assert client.post("/hr/employees", headers=hr, json={"employee_code": "CMD-09", "full_name": "x x x", "role": "command",
                                                          "password": PWD}).status_code == 403
    assert client.get("/hr/employees", headers=login(client, "JB-0492")).status_code == 403
    # existing collectors got the mandatory course too
    courses = client.get("/hr/training/courses", headers=hr).json()
    codes = [rec["employee_code"] for rec in courses[0]["records"]]
    assert "JB-0492" in codes and "JB-0777" in codes
    rec = next(rec for rec in courses[0]["records"] if rec["employee_code"] == "JB-0777")
    client.post(f"/hr/training/records/{rec['id']}/complete", headers=hr, json={"score": 90})
    mine = client.get("/me/training", headers=login(client, "JB-0777")).json()
    assert mine[0]["status"] == "completed" and mine[0]["score"] == 90


def test_attendance_self_service(client, monkeypatch):
    h = login(client, "JB-0777")
    assert client.post("/me/attendance/check-in", headers=h, json={"lat": 33.3152, "lng": 44.3661}).status_code == 422  # no selfie
    assert client.post("/me/attendance/check-in", headers=h, json={"lat": 33.3152, "lng": 44.3661, "is_mocked": True,
                                                                  "selfie_base64": JPEG}).status_code == 403
    monkeypatch.setattr(settings, "SHIFT_START", "00:00")
    monkeypatch.setattr(settings, "LATE_GRACE_MINUTES", 0)
    r = client.post("/me/attendance/check-in", headers=h, json={"lat": 33.40, "lng": 44.50, "selfie_base64": JPEG}).json()
    assert "outside_sector" in r["flags"]
    assert client.post("/me/attendance/check-in", headers=h, json={"selfie_base64": JPEG}).status_code == 409
    out = client.post("/me/attendance/check-out", headers=h, json={"selfie_base64": JPEG})
    assert out.status_code == 200
    assert client.post("/me/attendance/check-out", headers=h, json={}).status_code == 409
    mine = client.get("/me/attendance", headers=h).json()
    assert mine["today"]["checked_in_at"] and mine["today"]["checked_out_at"] and len(mine["records"]) == 1

    hr = login(client, "HR-01")
    day = client.get("/hr/attendance", headers=hr).json()
    row = next(x for x in day["rows"] if x["employee_code"] == "JB-0777")
    assert row["has_selfie"] and row["status"] in ("present", "late")
    assert client.get(f"/hr/attendance/{row['attendance_id']}/selfie", headers=hr).json()["mime"] == "image/jpeg"
    team = client.get("/hr/attendance", headers=login(client, "SP-01")).json()
    assert {x["employee_code"] for x in team["rows"]} <= {"JB-0492", "JB-0777"}


def test_leave_workflow(client):
    h, sp, hr = login(client, "JB-0777"), login(client, "SP-01"), login(client, "HR-01")
    s, e = _next_working_days(3)
    r = client.post("/me/leave", headers=h, json={"leave_type": "annual", "start_date": s.isoformat(), "end_date": e.isoformat(),
                                                   "reason": "سفر"}).json()
    assert r["status"] == "pending_hr" and r["days"] == 3       # Phase 5: straight to HR
    assert client.post("/me/leave", headers=h, json={"leave_type": "emergency", "start_date": s.isoformat(),
                                                      "end_date": s.isoformat()}).status_code == 409        # overlap
    bal = client.get("/me/leave", headers=h).json()["balances"]["annual"]
    assert bal["pending"] == 3 and bal["remaining"] == settings.LEAVE_ANNUAL_DAYS - 3
    s2, e2 = _next_working_days(settings.LEAVE_ANNUAL_DAYS, start_after=30)
    assert client.post("/me/leave", headers=h, json={"leave_type": "annual", "start_date": s2.isoformat(),
                                                      "end_date": e2.isoformat()}).status_code == 422       # over balance

    assert client.post(f"/hr/leave/{r['id']}/decision", headers=login(client, "JB-0492"), json={"action": "approve"}).status_code == 403
    queue = client.get("/hr/leave", headers=sp).json()
    assert [q["id"] for q in queue] == [r["id"]]
    # the supervisor sees the request but cannot decide it
    assert client.post(f"/hr/leave/{r['id']}/decision", headers=sp, json={"action": "approve"}).status_code == 403
    assert client.post(f"/hr/leave/{r['id']}/decision", headers=hr, json={"action": "approve", "note": "موافق"}).json()["status"] == "approved"
    bal = client.get("/me/leave", headers=h).json()["balances"]["annual"]
    assert bal["used"] == 3 and bal["pending"] == 0
    assert client.post(f"/me/leave/{r['id']}/cancel", headers=h).status_code == 409

    s3, e3 = _next_working_days(1, start_after=60)
    r3 = client.post("/me/leave", headers=h, json={"leave_type": "unpaid", "start_date": s3.isoformat(), "end_date": e3.isoformat()}).json()
    assert client.post(f"/me/leave/{r3['id']}/cancel", headers=h).json()["status"] == "cancelled"


def test_expenses(client):
    h, hr = login(client, "JB-0777"), login(client, "HR-01")
    d = (date.today() - timedelta(days=2)).isoformat()
    assert client.post("/me/expenses", headers=h, json={"category": "fuel", "amount": 15000, "expense_date": d}).status_code == 422
    x = client.post("/me/expenses", headers=h, json={"category": "fuel", "amount": 15000, "expense_date": d,
                                                      "receipt_base64": JPEG}).json()
    assert x["status"] == "pending"
    assert client.get(f"/hr/expenses/{x['id']}/receipt", headers=hr).json()["mime"] == "image/jpeg"
    assert client.post(f"/hr/expenses/{x['id']}/decision", headers=hr, json={"action": "approve"}).json()["status"] == "approved"
    assert client.post(f"/hr/expenses/{x['id']}/decision", headers=hr, json={"action": "reject"}).status_code == 409


def test_payroll_math(client):
    """August 2026 for JB-0777: 31 days, 4 Fridays -> 27 working days; base 600,000 -> 22,222.2/day."""
    hr, fn = login(client, "HR-01"), login(client, "FN-01")
    with db() as conn, conn.cursor() as cur:
        cur.execute("SELECT id FROM employees WHERE employee_code = 'JB-0777'")
        emp = cur.fetchone()[0]
        work = [date(2026, 8, d) for d in range(1, 32) if date(2026, 8, d).weekday() != 4]
        absent = work[:2]
        annual = work[2:5]
        unpaid = work[5:6]
        for d in work:
            if d in absent or d in annual or d in unpaid:
                continue
            cur.execute("INSERT INTO attendance (employee_id, work_date, check_in_at, late_minutes) VALUES (%s,%s,%s,%s)",
                        (emp, d, f"{d} 08:00+03", 20 if d == work[6] else 0))
        cur.execute("INSERT INTO leave_requests (employee_id, leave_type, start_date, end_date, days, status) VALUES (%s,'annual',%s,%s,3,'approved')",
                    (emp, annual[0], annual[-1]))
        cur.execute("INSERT INTO leave_requests (employee_id, leave_type, start_date, end_date, days, status) VALUES (%s,'unpaid',%s,%s,1,'approved')",
                    (emp, unpaid[0], unpaid[0]))
        cur.execute("INSERT INTO disciplinary_actions (employee_id, action_type, reason, penalty_iqd, effective_date) VALUES (%s,'penalty','تأخير',10000,'2026-08-10')",
                    (emp,))
        cur.execute("UPDATE expense_claims SET expense_date = '2026-08-20' WHERE employee_id = %s", (emp,))

    run = client.post("/hr/payroll/runs", headers=hr, json={"period": "2026-08"}).json()
    assert run["status"] == "draft" and run["totals"]["employees"] >= 6
    detail = client.get("/hr/payroll/runs/2026-08", headers=fn).json()
    slip = next(p for p in detail["payslips"] if p["employee_code"] == "JB-0777")
    lines = {l["code"]: l["amount"] for l in slip["lines"]}
    daily = 600000 / 27
    assert slip["stats"]["working_days_month"] == 27 and slip["stats"]["absent_days"] == 2
    assert slip["stats"]["paid_leave_days"] == 3 and slip["stats"]["unpaid_leave_days"] == 1 and slip["stats"]["late_days"] == 1
    assert lines["base"] == 600000 and lines["allow_transport"] == 50000 and lines["allow_risk"] == 25000
    assert lines["reimbursement"] == 15000
    assert lines["absence"] == round(2 * daily) and lines["unpaid_leave"] == round(daily)
    assert lines["penalty"] == 10000 and lines["social_security"] == 30000
    assert "commission" not in lines                      # no receipts in August
    assert slip["gross"] == 690000
    assert slip["net"] == 690000 - (round(2 * daily) + round(daily) + 10000 + 30000)

    assert client.get("/me/payslips", headers=login(client, "JB-0777")).json() == []        # not visible while draft
    assert client.post("/hr/payroll/runs/2026-08/action", headers=hr, json={"action": "approve"}).status_code == 403
    assert client.post("/hr/payroll/runs/2026-08/action", headers=fn, json={"action": "mark_paid"}).status_code == 409
    assert client.post("/hr/payroll/runs/2026-08/action", headers=fn, json={"action": "approve"}).json()["status"] == "approved"
    assert client.post("/hr/payroll/runs", headers=hr, json={"period": "2026-08"}).status_code == 409
    client.post("/hr/payroll/runs/2026-08/action", headers=fn, json={"action": "mark_paid"})
    mine = client.get("/me/payslips", headers=login(client, "JB-0777")).json()
    assert mine[0]["period"] == "2026-08" and mine[0]["net"] == slip["net"]
    full = client.get(f"/me/payslips/{mine[0]['id']}", headers=login(client, "JB-0777")).json()
    assert any(l["code"] == "absence" for l in full["lines"])
    assert client.get(f"/me/payslips/{mine[0]['id']}", headers=login(client, "JB-0492")).status_code == 404
    assert client.get("/me/expenses", headers=login(client, "JB-0777")).json()[0]["status"] == "paid"


def test_commission_current_month(client):
    hr = login(client, "HR-01")
    with db() as conn, conn.cursor() as cur:
        cur.execute("SELECT to_char(NOW() AT TIME ZONE 'Asia/Baghdad', 'YYYY-MM')")
        period = cur.fetchone()[0]
    client.post("/hr/payroll/runs", headers=hr, json={"period": period})
    detail = client.get(f"/hr/payroll/runs/{period}", headers=hr).json()
    # JB-0492 has no OTP receipts in this module's fresh database: commission line absent, but the slip exists
    assert any(p["employee_code"] == "JB-0492" for p in detail["payslips"])


def test_appraisals(client):
    hr, sp = login(client, "HR-01"), login(client, "SP-01")
    with db() as conn, conn.cursor() as cur:
        cur.execute("SELECT to_char(NOW() AT TIME ZONE 'Asia/Baghdad', 'YYYY-MM')")
        period = cur.fetchone()[0]
    assert client.post("/hr/appraisals/run", headers=hr, json={"period": period}).json()["employees"] >= 3
    rows = client.get(f"/hr/appraisals?period={period}", headers=sp).json()
    mine = next(r for r in rows if r["employee_code"] == "JB-0777")
    assert 0 <= mine["auto_score"] <= 100 and "attendance_rate" in mine["metrics"]
    rated = client.post(f"/hr/appraisals/{mine['id']}/rate", headers=sp, json={"rating": 5, "note": "ممتاز"}).json()
    assert rated["final_score"] == round(mine["auto_score"] * 0.7 + 30, 1)
    client.post("/hr/appraisals/run", headers=hr, json={"period": period})          # recompute keeps the rating
    again = next(r for r in client.get(f"/hr/appraisals?period={period}", headers=hr).json() if r["employee_code"] == "JB-0777")
    assert again["supervisor_rating"] == 5
    assert client.get("/me/appraisals", headers=login(client, "JB-0777")).json()[0]["supervisor_rating"] == 5


def test_custody_discipline_termination(client):
    hr = login(client, "HR-01")
    c = client.post("/hr/custody", headers=hr, json={"employee_code": "JB-0777", "item_type": "phone",
                                                      "description": "Samsung A15", "serial_no": "IMEI-1", "value_iqd": 200000}).json()
    assert client.get("/me/custody", headers=login(client, "JB-0777")).json()[0]["status"] == "assigned"
    t = client.post("/hr/employees/JB-0777/terminate", headers=hr, json={"reason": "استقالة"})
    assert t.status_code == 409 and "عهدة" in t.json()["detail"]
    client.post(f"/hr/custody/{c['id']}/return", headers=hr, json={"outcome": "lost", "charge_employee": True, "note": "فُقد"})
    prof = client.get("/hr/employees/JB-0777", headers=hr).json()
    assert any(d["penalty_iqd"] == 200000 for d in prof["discipline"])

    for i in range(3):
        r = client.post("/hr/discipline", headers=hr, json={"employee_code": "JB-0777", "action_type": "written_warning",
                                                             "reason": f"إنذار {i + 1}"}).json()
    assert r["suspension_recommended"] is True
    assert client.post("/hr/employees/JB-0777/terminate", headers=hr, json={"reason": "إنهاء خدمات"}).json()["active"] is False
    assert client.post("/auth/login", json={"employee_code": "JB-0777", "password": PWD}).status_code == 403
    client.post("/hr/employees/JB-0777/reactivate", headers=hr)
    s = client.post("/hr/discipline", headers=hr, json={"employee_code": "JB-0777", "action_type": "suspension", "reason": "إيقاف"}).json()
    assert s["employee_active"] is False


def test_recruitment_hire(client):
    hr = login(client, "HR-01")
    o = client.post("/hr/openings", headers=hr, json={"title": "جابي ميداني - المنصور", "role": "collector", "positions": 1}).json()
    a = client.post("/hr/applicants", headers=hr, json={"opening_id": o["id"], "full_name": "مصطفى خالد", "phone": "07812345678"}).json()
    client.post(f"/hr/applicants/{a['id']}/stage", headers=hr, json={"stage": "interview", "score": 80})
    h = client.post(f"/hr/applicants/{a['id']}/hire", headers=hr, json={"employee_code": "JB-0900", "password": PWD,
                                                                      "sector_code": "S-01", "supervisor_code": "SP-01",
                                                                      "base_salary": 550000}).json()
    assert h["employee_code"] == "JB-0900"
    assert client.post("/auth/login", json={"employee_code": "JB-0900", "password": PWD}).status_code == 200
    openings = client.get("/hr/openings", headers=hr).json()
    op = next(x for x in openings if x["id"] == o["id"])
    assert op["status"] == "closed" and op["hired"] == 1 and op["pipeline"][0]["stage"] == "hired"
    assert client.post(f"/hr/applicants/{a['id']}/hire", headers=hr, json={"employee_code": "JB-0901", "password": PWD}).status_code == 409
    prof = client.get("/hr/employees/JB-0900", headers=hr).json()
    assert prof["profile"]["job_title"] == "جابي ميداني - المنصور" and prof["training"]       # mandatory course assigned


def test_documents_and_dashboard(client):
    hr = login(client, "HR-01")
    soon = (date.today() + timedelta(days=10)).isoformat()
    d = client.post("/hr/employees/JB-0492/documents", headers=hr, json={"doc_type": "national_id", "title": "البطاقة الوطنية",
                                                                         "file_base64": JPEG, "expires_on": soon}).json()
    assert client.get(f"/hr/documents/{d['id']}/file", headers=hr).json()["mime"] == "image/jpeg"
    client.patch("/hr/employees/JB-0492", headers=hr, json={"contract_end": soon, "job_title": "جابي أول"})
    dash = client.get("/hr/dashboard", headers=hr).json()
    kinds = {x["kind"] for x in dash["expiring"]}
    assert {"contract", "document"} <= kinds and dash["last_payroll"] is not None
    assert "present_today" in dash and dash["headcount"]


def test_audit_chain_valid(client):
    assert client.get("/command/audit/verify", headers=login(client, "CMD-01")).json()["valid"] is True
