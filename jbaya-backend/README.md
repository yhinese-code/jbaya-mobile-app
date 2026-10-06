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

**Two-factor login:** roles in `TWO_FACTOR_ROLES` (command, admin) get `{two_factor_required, challenge_id}` from
`/auth/login`; a code goes to the employee's own WhatsApp; `POST /auth/verify-2fa {challenge_id, code}` returns the token.
Tokens without the second step are rejected. Optional `COMMAND_IP_ALLOWLIST`. Sessions last `COMMAND_SESSION_HOURS`;
the screen locks after 15 minutes idle. Set a phone with `PATCH /admin/employees/{code} {"phone": "07..."}` (admin).
The seed gives CMD-01 / ADMIN-01 demo numbers; in console mode the code prints in the uvicorn window.

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

## Phase 4 additions (Finance)

**General ledger, derived, never typed:** the `ledger_postings` view turns operational records into double-entry
postings, so the books always match the field data:
receipt → Dr cash with collector / Cr due to water directorate + Cr company fee revenue;
reconciliation → cash moves collector → supervisor, any difference sits in suspense (1290) until resolved
(collector paid / salary deduction → employee receivable / write-off / surplus income);
deposit → in transit → bank when finance verifies (back to the supervisor if rejected);
payroll paid → salaries expense, reimbursements, recovered shortages, tax payable, net out of the bank;
government remittance → Dr due to government / Cr bank. Manual journal entries only for accounts marked manual
(bank, opening balances, suspense clearing, taxes, operating expenses); entries are reversed, never deleted.
Chart of accounts: `app/ledger.py`.

**Endpoints (finance; read-only ones also for command):** `/finance/overview`, `/finance/trial-balance?as_of=`,
`/finance/ledger?account=&start=&end=`, `/finance/income-statement?period=`, `/finance/journal` (+ `/reverse`),
`/finance/remittances`, `/finance/escalations` + `/finance/reconciliations/{id}/close`, `/finance/forecast`,
`/finance/benford?dataset=&collector=`, `/finance/anomalies?days=`, `/finance/risk?days=`, `/finance/aging`.

**Analytics (pure Python, `app/fin_math.py`):**
- Forecast: Holt-Winters with weekly seasonality (learns the Friday dip), parameters by grid search, 95% band,
  month-end projection.
- Benford first-digit test (Nigrini MAD thresholds + chi-square), per collector and **against the other collectors**
  (household consumption spans a narrow range, so peer comparison is the stronger signal), plus a last-digit test on
  meter readings (too many readings ending in 0/5 = typed without looking).
- Anomalies: flagged bills, meter that doesn't move twice in a row, receipts at night, two receipts too fast to walk
  between, tracker far from the house at receipt time, cash held > 48 h, supervisor not depositing > 72 h, deposit
  differences, master-code / estimate / digit-preference / low-ticket outliers vs peers, shortages.
- Risk score 0-100 per collector, explainable: shortage 20, master code 15, security events 15, estimates 10,
  digit preference 10, Benford 10, flagged bills 10, cash holding 10.
- Arrears aging: estimated government share owed since each property's last payment, by bucket and sector.

## WhatsApp templates to create in Meta Business Manager

Meta only allows business-initiated messages through approved templates, and codes must use an
**Authentication** template. So the payment step sends two messages: the bill notice and the code.

1. **`jbaya_otp`**, category *Authentication*, language Arabic, with "Copy code" button.
   (Meta writes the body for authentication templates; you only pick options.)
2. **`jbaya_bill_notice`**, category *Utility*, Arabic:
   ```
   عزيزي {{1}}، المبلغ المستحق للعقار {{2}} هو {{3}} د.ع (رسوم الاستهلاك {{4}} + أجور الجباية {{5}}).
   لا تدفع أكثر من هذا المبلغ. الجابي: {{6}}. للشكاوى: {{7}}
   ```
3. **`jbaya_receipt`**, category *Utility*, Arabic:
   ```
   عزيزي {{1}}، تم استلام دفعتكم. رقم الوصل: {{2}}، المبلغ: {{3}} د.ع، العقار: {{4}}، التاريخ: {{5}}.
   إذا دفعت مبلغاً أكبر يرجى الاتصال على {{6}}
   ```

When approved, put the token and phone number ID in `.env` and set `WHATSAPP_MODE=live`.

## Tests

```powershell
venv\Scripts\pip install -r requirements-dev.txt
$env:TEST_DB_CONN="postgresql://postgres:PASSWORD@localhost:5432/jbaya_test"   # a SEPARATE empty database, it is wiped
venv\Scripts\python -m pytest -q tests
```
