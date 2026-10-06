"""The account book (دفتر الحساب): plain-language accounts over the `ledger_postings` view (see schema.sql).

Every account is shown to people as "وارد / صادر / الرصيد" (in / out / balance) — never debit/credit.
Internally it is still double entry, so the book always balances.

Groups:
- place:   where cash physically is (collectors, supervisors, finance cash box, bank)
- trust:   the water directorate's money we hold for it (أمانة) — not company income, not a company debt
- people:  what employees owe, taxes withheld for the authority, differences under investigation
- company: company income and costs — profit is visible to the OWNER only
"""
from datetime import date

from .config import settings

# code: (Arabic name, group, increases-on-debit, manual corrections allowed, finance can see)
CHART: dict[str, tuple[str, str, bool, bool, bool]] = {
    "1010": ("نقد لدى الجباة", "place", True, False, True),
    "1020": ("نقد لدى المشرفين", "place", True, False, True),
    "1030": ("إيداعات مصرفية قديمة بانتظار التدقيق", "place", True, False, True),
    "1050": ("صندوق المالية (المقر)", "place", True, True, True),
    "1100": ("المصرف", "place", True, True, True),
    "1200": ("مبالغ على الموظفين (تُخصم من الرواتب)", "people", True, True, True),
    "1290": ("فروقات نقدية قيد التحقيق", "people", True, True, True),
    "2100": ("أمانة دائرة الماء", "trust", False, False, True),
    "2200": ("ضرائب وضمان مستقطعة من الرواتب", "people", False, True, True),
    "3000": ("رأس المال والأرصدة الافتتاحية", "company", False, True, False),
    "4100": ("أجور خدمة الجباية", "company", False, False, False),
    "4110": ("حصة الشركة من مبالغ الماء", "company", False, False, False),
    "4200": ("إيرادات أخرى (غرامات وزيادات)", "company", False, True, False),
    "5100": ("الرواتب والأجور", "company", True, False, False),
    "5200": ("تعويض مصاريف الموظفين", "company", True, False, False),
    "5300": ("نقص نقدي مشطوب", "company", True, True, False),
    "5400": ("مصاريف تشغيلية (عمولات مصرفية وغيرها)", "company", True, True, False),
}
GROUP_LABELS = {"place": "أين النقد", "trust": "الأمانة", "people": "على الموظفين وقيد التحقيق", "company": "حسابات الشركة (للمالك)"}
INCOME = ("4100", "4110", "4200")
COSTS = ("5100", "5200", "5300", "5400")
PLACES = ("1010", "1020", "1030", "1050", "1100")


def visible(code: str, role: str) -> bool:
    return role in ("owner", "admin") or CHART[code][4]


def account_out(code: str) -> dict:
    name, group, _, manual, finance = CHART[code]
    return {"code": code, "name": name, "group": group, "group_label": GROUP_LABELS[group], "manual": manual,
            "finance_visible": finance}


def signed(code: str, debit: float, credit: float) -> float:
    """Balance in plain terms: positive = the account holds that much."""
    return debit - credit if CHART[code][2] else credit - debit


def in_out(code: str, debit: float, credit: float) -> tuple[float, float]:
    """(in, out) as people read it: money coming into the account / leaving it."""
    return (debit, credit) if CHART[code][2] else (credit, debit)


LO = "((%(s)s::date)::timestamp AT TIME ZONE %(tz)s)"
HI = "((%(e)s::date + 1)::timestamp AT TIME ZONE %(tz)s)"


def local_bounds(start: date, end: date) -> dict:
    """Params for `posted_at >= LO AND posted_at < HI` covering local days start..end inclusive."""
    return {"s": start, "e": end, "tz": settings.APP_TIMEZONE}


def balances(cur, as_of: date | None = None) -> dict[str, dict]:
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
        i, o = in_out(code, d, c)
        out[code] = {**account_out(code), "debit": round(d, 2), "credit": round(c, 2), "in": round(i, 2), "out": round(o, 2),
                     "balance": round(signed(code, d, c), 2)}
    for code in set(rows) - set(CHART):      # should never happen; shown so it can't hide
        d, c = rows[code]
        out[code] = {"code": code, "name": "حساب غير معرّف", "group": "people", "group_label": "غير معرّف", "manual": False,
                     "finance_visible": True, "debit": d, "credit": c, "in": d, "out": c, "balance": d - c}
    return out


def period_movements(cur, start: date, end: date) -> dict[str, dict]:
    cur.execute(
        f"""SELECT account, COALESCE(SUM(debit),0) AS d, COALESCE(SUM(credit),0) AS c FROM ledger_postings
            WHERE posted_at >= {LO} AND posted_at < {HI} GROUP BY account""",
        local_bounds(start, end),
    )
    rows = {r["account"]: (float(r["d"]), float(r["c"])) for r in cur.fetchall()}
    out = {}
    for code in CHART:
        d, c = rows.get(code, (0.0, 0.0))
        i, o = in_out(code, d, c)
        out[code] = {"debit": d, "credit": c, "in": i, "out": o, "net": round(signed(code, d, c), 2)}
    return out


def cash_position(b: dict[str, dict]) -> dict:
    """Where the money physically is right now, and how much of it is the directorate's."""
    def bal(code):
        return b[code]["balance"]
    total = round(sum(bal(c) for c in PLACES), 2)
    return {
        "with_collectors": bal("1010"), "with_supervisors": bal("1020"), "cash_box": bal("1050"), "bank": bal("1100"),
        "old_deposits_pending": bal("1030"), "total_cash": total,
        "outside_hq": round(bal("1010") + bal("1020"), 2),
        "government_trust": bal("2100"),
        "company_cash": round(total - bal("2100") - bal("2200"), 2),
        "differences": bal("1290"), "employees_owe": bal("1200"), "taxes_withheld": bal("2200"),
    }
