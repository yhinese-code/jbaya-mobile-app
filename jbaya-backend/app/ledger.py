"""Chart of accounts and ledger queries over the `ledger_postings` view (see schema.sql).

The ledger is derived from operational records (receipts, reconciliations, deposits, payroll, remittances),
plus manual journal entries for things the system can't see (bank charges, opening balances ...).
"""
from datetime import date

from .config import settings

# code: (Arabic name, type, manual entries allowed)
CHART: dict[str, tuple[str, str, bool]] = {
    "1010": ("نقد لدى الجباة", "asset", False),
    "1020": ("نقد لدى المشرفين", "asset", False),
    "1030": ("نقد قيد الإيداع (بانتظار تدقيق المالية)", "asset", False),
    "1100": ("المصرف", "asset", True),
    "1200": ("ذمم الموظفين (عجز يُسترد من الرواتب)", "asset", True),
    "1290": ("حساب معلّق - فروقات قيد التحقيق", "asset", True),
    "2100": ("مستحق لدائرة الماء (الحصة الحكومية)", "liability", False),
    "2200": ("ضرائب وضمان اجتماعي مستحقة", "liability", True),
    "3000": ("رأس المال والأرصدة الافتتاحية", "equity", True),
    "4100": ("إيرادات أجور الشركة", "revenue", False),
    "4200": ("إيرادات أخرى (غرامات وزيادات نقدية)", "revenue", True),
    "5100": ("الرواتب والأجور", "expense", False),
    "5200": ("تعويض مصروفات الموظفين", "expense", False),
    "5300": ("عجز نقدي مشطوب", "expense", True),
    "5400": ("مصاريف تشغيلية (عمولات مصرفية وغيرها)", "expense", True),
}
TYPE_LABELS = {"asset": "الأصول", "liability": "الالتزامات", "equity": "حقوق الملكية", "revenue": "الإيرادات", "expense": "المصروفات"}
DEBIT_NORMAL = {"asset", "expense"}


def account_out(code: str) -> dict:
    name, typ, manual = CHART[code]
    return {"code": code, "name": name, "type": typ, "type_label": TYPE_LABELS[typ], "manual": manual}


def signed(code: str, debit: float, credit: float) -> float:
    """Balance in the account's natural direction."""
    return debit - credit if CHART[code][1] in DEBIT_NORMAL else credit - debit




def local_bounds(start: date, end: date) -> dict:
    """Params for `posted_at >= LO AND posted_at < HI` covering local days start..end inclusive."""
    return {"s": start, "e": end, "tz": settings.APP_TIMEZONE}


LO = "((%(s)s::date)::timestamp AT TIME ZONE %(tz)s)"
HI = "((%(e)s::date + 1)::timestamp AT TIME ZONE %(tz)s)"


def balances(cur, as_of: date | None = None) -> dict[str, dict]:
    """Debit/credit totals and natural balance per account, up to the end of `as_of` (local day)."""
    if as_of:
        cur.execute(
            f"""SELECT account, COALESCE(SUM(debit),0) AS d, COALESCE(SUM(credit),0) AS c FROM ledger_postings
                WHERE posted_at < {HI} GROUP BY account""",
            {"e": as_of, "tz": settings.APP_TIMEZONE},
        )
    else:
        cur.execute("SELECT account, COALESCE(SUM(debit),0) AS d, COALESCE(SUM(credit),0) AS c FROM ledger_postings GROUP BY account")
    rows = {r["account"]: (float(r["d"]), float(r["c"])) for r in cur.fetchall()}
    out = {}
    for code in CHART:
        d, c = rows.get(code, (0.0, 0.0))
        out[code] = {**account_out(code), "debit": round(d, 2), "credit": round(c, 2), "balance": round(signed(code, d, c), 2)}
    unknown = set(rows) - set(CHART)
    for code in unknown:      # should never happen; shown so it can't hide
        d, c = rows[code]
        out[code] = {"code": code, "name": "حساب غير معرّف", "type": "asset", "type_label": "غير معرّف", "manual": False,
                     "debit": d, "credit": c, "balance": d - c}
    return out


def period_movements(cur, start: date, end: date) -> dict[str, dict]:
    cur.execute(
        f"""SELECT account, COALESCE(SUM(debit),0) AS d, COALESCE(SUM(credit),0) AS c FROM ledger_postings
            WHERE posted_at >= {LO} AND posted_at < {HI} GROUP BY account""",
        local_bounds(start, end),
    )
    rows = {r["account"]: (float(r["d"]), float(r["c"])) for r in cur.fetchall()}
    return {code: {"debit": rows.get(code, (0, 0))[0], "credit": rows.get(code, (0, 0))[1],
                   "net": round(signed(code, *rows.get(code, (0.0, 0.0))), 2)} for code in CHART}


def cash_position(b: dict[str, dict]) -> dict:
    """Where the money physically is right now."""
    def bal(code):
        return b[code]["balance"]
    return {
        "with_collectors": bal("1010"), "with_supervisors": bal("1020"), "in_transit": bal("1030"), "bank": bal("1100"),
        "total_cash": round(bal("1010") + bal("1020") + bal("1030") + bal("1100"), 2),
        "due_to_government": bal("2100"), "suspense": bal("1290"), "employee_receivables": bal("1200"),
        "taxes_payable": bal("2200"),
        "company_cash_after_government": round(bal("1010") + bal("1020") + bal("1030") + bal("1100") - bal("2100"), 2),
    }
