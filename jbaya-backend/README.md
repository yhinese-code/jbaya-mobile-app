# Jbaya backend (FastAPI + PostgreSQL)

## Run it (Windows, PowerShell, inside `jbaya-backend`)

```powershell
venv\Scripts\pip install -r requirements.txt
copy .env.example .env          # then edit .env (DB password, secrets)
venv\Scripts\python -m app.seed # once: tariffs, demo sector, demo accounts
venv\Scripts\uvicorn main:app --reload
```

API docs: http://127.0.0.1:8000/docs

Demo accounts (password `Jbaya@2026`, change before going live):

| Code | Role |
|---|---|
| JB-0492 | collector (sector S-01, supervisor SP-01) |
| SP-01 | supervisor |
| CMD-01 | command (sees the master code) |
| FN-01 | finance |
| HR-01 | hr |
| ADMIN-01 | admin |

**Testing from a laptop:** your laptop is not inside the demo sector (Al-Mansour), so set
`ENFORCE_GEOFENCE=false` in `.env` while testing. With `WHATSAPP_MODE=console` the WhatsApp
messages (including the OTP) are printed in the uvicorn terminal: read the code from there,
exactly as the citizen would read it from WhatsApp.

## The flows

**A. Registration:** `POST /registrations` checks GPS accuracy, the sector polygon (server-side),
and blocks employee phone numbers, then sends the OTP to the citizen's WhatsApp. `POST /registrations/{id}/verify`
activates the property.

**B. Collection:** `POST /bills` computes the amount on the server:
- First visit: reading saved as baseline, amount = tariff estimate for `FIRST_VISIT_PERIOD_DAYS`.
- Later visits: (current − previous) × unit rate.
- Current < previous: blocked, goes to the supervisor (`approve` / `reject` / `rebaseline`).
- Very high consumption: flagged, still collectable.
- Estimate on a meter registered as working: needs supervisor approval.

The citizen receives the exact amount ("do not pay more") and the code. `POST /bills/{id}/verify` → receipt
+ WhatsApp receipt. A fixed company fee (`COMPANY_FEE_IQD`) is added to every bill. Amounts are rounded to 250 IQD.

**C. Master code:** `GET /command/master-code` (role `command` only). Changes every 10 minutes, derived from
`MASTER_CODE_SECRET` + time (not stored). Collector sends `use_master_code: true` + a mandatory `reason`.
Limit: 3 uses per collector per day. Every use is listed at `GET /command/master-code/uses`.

The OTP is generated, hashed and checked only on the server: 6 digits, 5-minute expiry, 3 attempts, 60s resend cooldown.
The audit log is hash-chained; `GET /command/audit/verify` detects any edited/deleted row.

## Phase 1 additions

**Collector:** meter photo is required for readings (`REQUIRE_METER_PHOTO`). On Android/iOS the phone reads
the digits (OCR) and the server flags `ocr_mismatch` when the typed reading differs. A collector holding more than
`CASH_IN_HAND_CAP_IQD` in un-handed cash cannot issue new bills until the supervisor reconciles him.
`GET /collector/summary` (today vs target, cash in hand), `GET /collector/receipts`, `POST /sos`.

**Supervisor:** `GET /supervisor/team` (activity counts only, no money, to keep reconciliation blind),
`POST /supervisor/reconciliations` with `denominations` (50,000 … 250 IQD notes). A difference above
`RECON_TOLERANCE_IQD` must be resolved with `POST /supervisor/reconciliations/{id}/resolve`
(`collector_paid` / `salary_deduction` for shortages, `deposit_surplus` for surpluses, `escalate` for both).
`POST /supervisor/deposits` deposits all resolved cash with a bank-slip photo.

**Finance:** `GET /finance/deposits`, `GET /finance/deposits/{id}/slip`, `POST /finance/deposits/{id}/decision`
(`verify` / `reject`; a rejected deposit puts the cash back on the supervisor's books).

**Command / alerts:** `GET /alerts`, `POST /alerts/{id}` (`acknowledge` / `close`), `GET /command/escalations`.

Photos are stored under `jbaya-backend/storage/` (ignored by Git) and only served through these authenticated endpoints.
Back this folder up together with the database.

## Phase 2 additions (Central Command)

**Login (replaced in Phase 5):** no WhatsApp codes for employees any more, see "Phase 5" below.

**Live tracking:** the field app posts `POST /tracking/ping {points:[{lat,lng,accuracy_m,is_mocked,recorded_at}]}`
every 30 s (batched when offline). The server records `geofence_exit`, `mock_location` and `impossible_speed` events.

**Command endpoints:** `/command/live`, `/command/feed?after_id=`, `/command/trail/{code}?day=`, `/command/properties`,
`/command/sectors`, `/command/leaderboard?days=`, `/command/health`, `/command/messages` (send/list);
field inbox: `/messages/inbox`, `/messages/{id}/read`.

## Phase 3 additions (HR)

**Self-service (every employee, "خدماتي" button):** `/me/profile`, `/me/attendance/check-in|check-out` (selfie + GPS;
fake GPS is refused, late and outside-sector are flagged), `/me/leave` (balances, request, cancel), `/me/payslips`
(only after finance approves), `/me/expenses` (receipt photo required), `/me/custody`, `/me/appraisals`, `/me/training`.

**Approval chains:** leave goes supervisor → HR (straight to HR when the employee has no supervisor). Expenses are
approved by HR or finance and paid with the next salary. Payroll is computed by HR (draft, can be recomputed) and
approved then marked paid by **finance only**.

**Payroll formula:** base + allowances + commission (`COMMISSION_PER_RECEIPT_IQD` per OTP-confirmed receipt) +
approved expenses − absent days − unpaid leave − cash shortages resolved as salary deduction − penalties − tax% − social security%.
Working days exclude `WEEKEND_DAYS`.

**Appraisal:** automatic monthly score (collection vs target, attendance, punctuality, cash accuracy, security events,
warnings); final = auto × 0.7 + supervisor stars × 20 × 0.3.

**HR portal (`/hr/...`):** dashboard, employee files and documents, daily attendance with selfies, leave queue,
payroll runs, expenses, appraisals, custody (lost item can be charged to salary), discipline (suspension deactivates
the account; `WARNINGS_BEFORE_SUSPENSION` written warnings in 12 months recommends suspension), recruitment
(opening → applicants → one-click hire creates the account), training (mandatory courses auto-assigned by role).
Termination is blocked while the employee holds custody items or unreconciled cash.

## Phase 4 additions (Finance, reworked)

**Money model.** Each receipt splits into: the **company's income** (the service fee + `COMPANY_SHARE_PCT` % of the
water amount, fixed on the receipt) and the **water directorate's trust money** (أمانة دائرة الماء: the rest of the
water amount). The trust is neither company income nor a company debt: it is collected, held, and handed over.

**Cash chain.** Collector → supervisor (blind count in the field) → **finance at headquarters** (second blind count:
finance sees who has cash, not how much, until the count is saved) → finance cash box (صندوق المالية) → bank (finance
transfer) → the directorate (trust handover, from the cash box or the bank). Supervisors no longer deposit in banks
(`POST /supervisor/deposits` returns 410); old deposits still show and balance.

**Account book (دفتر الحساب).** Still double entry underneath (`ledger_postings` view, always balanced), but shown as
"دخل / خرج / فيه الآن". Finance sees where the cash is, the trust, and what employees owe; company income and cost
accounts and profit are **owner only**. Manual corrections come as plain choices (bank charge, cash expense, tax paid,
opening balances); write-offs and corrections above `OWNER_APPROVAL_IQD` wait for the owner.

**Owner panel (`owner` role, WhatsApp code at login).** Profit by month, company income by sector and per property,
company breakeven (receipts needed this month to cover all salaries), approvals, a log of every finance action,
alerts (cash outside HQ above `CASH_OUTSIDE_HQ_ALERT_IQD`, differences, approvals waiting, behind breakeven).

**Breakeven & performance** (`app/performance.py`). Per collector per working day: cost = (salary + allowances) ÷
working days + commission; company earnings = fee + share on his receipts. A day below cost is a losing day;
`LOSING_STREAK_ALERT_DAYS` in a row flags him. Owner/finance/Command see money (`/performance/collectors`);
supervisors see houses and labels only (`/supervisor/performance`); the collector sees his own target in houses and
how far he is from the team average (`/collector/coach`).

**Endpoints:** `/finance/handovers/waiting`, `/finance/handovers` (+ `/{id}/resolve`), `/finance/transfers`,
`/finance/book`, `/finance/book/{account}`, `/finance/trust`, `/finance/remittances`, `/finance/differences`,
`/finance/reconciliations/{id}/close`, `/finance/journal` (+ `/simple`, `/{id}/reverse`); owner:
`/owner/summary`, `/owner/approvals` (+ `/{kind}/{id}`), `/owner/finance-log`, `/owner/performance`,
`/finance/income-statement`, `/finance/trial-balance`. Analytics as before: `/finance/overview`, `/finance/forecast`,
`/finance/benford`, `/finance/anomalies`, `/finance/risk`, `/finance/aging`.

**Demo history (test databases only):** `python -m app.demo_finance --yes` (90 days, an honest and a suspicious collector).

## Phase 5 additions (tech panel, devices, 35% rule, previous bills)

After pulling: `pip install -r requirements.txt` (adds `openpyxl` for Excel imports), restart uvicorn (the schema
updates itself), run `python -m app.seed` once (adds **TECH-01**), and in the Flutter folder `flutter pub get`
(adds `shared_preferences` and `file_picker`).

**Logging in now:** each phone / PC sends a random device id. A new device gets "waiting for approval" and appears in
the tech panel (الأجهزة). Once approved it is bound to that one account (it can never log into another one) and logs in
normally. Everyone is logged out daily at `DAILY_LOGOUT_AT` (midnight Baghdad). Limits per role: `DEVICE_LIMITS`
(Command 2). The very first device that logs into TECH-01 is approved automatically, so log into TECH-01 first.

**Tech panel (role `tech`, TECH-01):** approve/revoke devices, end sessions, create/edit/suspend accounts and change
roles, every setting and formula (`/tech/settings`, each change logged with old/new value), switches globally / per
sector / per person, the permission matrix (enforced on the API as well as hiding tabs), tariffs, sectors, WhatsApp
log and cost, fraud watch, audit log. The tech panel also picks which settings the owner may change himself.

**Behind a reverse proxy (nginx etc.):** the IP allow-list reads the client address, so start uvicorn with
`--proxy-headers --forwarded-allow-ips=<proxy ip>`, otherwise every request looks like it comes from the proxy.

**Other Phase 5 rules:** citizen-number protocol (hard limit, flags, fast-code flag, daily random call-backs for
Command); supervisors collect in the field with the same quota (their own cash goes into their handover; their own
estimates are reviewed by another supervisor); leave is decided by HR only (never by the applicant); the 35% rule
(`GAIN_SHARE_MODE`, finance tab صيغة الـ35%); previous bills (file import with review, or at the house with a photo).

## WhatsApp templates to create in Meta Business Manager

Meta only allows business-initiated messages through approved templates, and codes must use an
**Authentication** template. So the payment step sends two messages: the bill notice and the code.

1. **`jbaya_otp`**, category *Authentication*, language Arabic, with "Copy code" button.
   (Meta writes the body for authentication templates; you only pick options.)
2. **`jbaya_bill_notice`**, category *Utility*, Arabic:
   ```
   عزيزي {{1}}، المبلغ المستحق للعقار {{2}} هو {{3}} د.ع (رسوم الاستهلاك {{4}} + أجور الجباية {{5}}).
   سيصلك الآن رمز تحقق: اقرأه لموظف الجباية الذي أمامك فقط.
   لا تدفع أكثر من هذا المبلغ. الموظف: {{6}}. للشكاوى: {{7}}
   ```
3. **`jbaya_receipt`**, category *Utility*, Arabic:
   ```
   عزيزي {{1}}، تم استلام {{3}} د.ع للعقار {{4}}. رقم الوصل {{2}} بتاريخ {{5}}.
   لا تدفع أكثر من المبلغ المذكور في هذا الوصل. إذا طُلب منك مبلغ أكبر اتصل على {{6}}
   ```

When approved, put the token and phone number ID in `.env` and set `WHATSAPP_MODE=live`.

## Tests

```powershell
venv\Scripts\pip install -r requirements-dev.txt
$env:TEST_DB_CONN="postgresql://postgres:PASSWORD@localhost:5432/jbaya_test"   # a SEPARATE empty database, it is wiped
venv\Scripts\python -m pytest -q tests
```
