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
