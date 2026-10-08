"""Previous bills (Phase 5). About 90% of houses already have a bill from before the company; it is the basis of the
35% rule (per-house mode). Two ways in, both fool-proof:

1. File import (finance / tech): Excel or CSV -> rows matched to houses by directorate account no., meter no. or phone
   -> a review screen (matched / unmatched / duplicate / odd amount) -> nothing is saved until "commit".
   Rows from the directorate's own file are trusted (confirmed), except odd amounts which go to review.
2. At the house (collector / field supervisor): if an imported bill exists he confirms it against the paper bill or
   reports a mismatch with a photo; if none exists he photographs the paper bill and types the amount.
   Field entries always wait for the supervisor (photo side by side with the amount).
"""
import base64
import binascii
import csv
import io
import json
import re
from datetime import date, datetime
from typing import Literal

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field

from .. import audit, files
from ..config import settings
from ..db import dict_cursor, get_conn
from ..fieldwork import FIELD_ROLES
from ..security import require_roles
from ..utils import normalize_iraqi_phone

router = APIRouter(tags=["previous bills"])
importers = require_roles("finance", "owner")          # tech / admin pass every role check
readers = require_roles("finance", "owner", "command", "supervisor")
field = require_roles(*FIELD_ROLES)

# header words people actually use (Arabic / English) -> our column
HEADERS = {
    "account_no": ["رقم الحساب", "رقم المشترك", "الحساب", "المشترك", "account", "account_no", "subscriber"],
    "meter_serial": ["رقم العداد", "العداد", "meter", "meter_no", "meter_serial"],
    "phone": ["الهاتف", "رقم الهاتف", "الموبايل", "واتساب", "phone", "mobile", "whatsapp"],
    "name": ["الاسم", "اسم المشترك", "المالك", "name", "owner"],
    "amount": ["المبلغ", "مبلغ الفاتورة", "القيمة", "amount", "total", "bill"],
    "period_days": ["المدة", "عدد الايام", "عدد الأيام", "days", "period_days"],
    "bill_date": ["التاريخ", "تاريخ الفاتورة", "date", "bill_date"],
    "consumption": ["الاستهلاك", "consumption", "m3"],
}
MAX_ROWS = 50_000


def _norm(h) -> str:
    return re.sub(r"\s+", " ", str(h or "").strip().lower().replace("_", " "))


def _map_headers(header: list) -> dict[str, int]:
    out = {}
    normed = [_norm(h) for h in header]
    for col, words in HEADERS.items():
        for w in words:
            w = _norm(w)
            for i, h in enumerate(normed):
                if h == w and col not in out:
                    out[col] = i
        if col not in out:          # partial match as a second chance ("رقم العداد الجديد")
            for i, h in enumerate(normed):
                if any(_norm(w) in h for w in words) and i not in out.values():
                    out[col] = i
                    break
    return out


def _num(v) -> float | None:
    if v is None or str(v).strip() == "":
        return None
    try:
        return float(str(v).replace(",", "").replace("٫", ".").strip())
    except ValueError:
        return None


def _date(v) -> str | None:
    if isinstance(v, datetime):
        return v.date().isoformat()
    if isinstance(v, date):
        return v.isoformat()
    s = str(v or "").strip()
    for fmt in ("%Y-%m-%d", "%d/%m/%Y", "%Y/%m/%d", "%d-%m-%Y"):
        try:
            return datetime.strptime(s, fmt).date().isoformat()
        except ValueError:
            continue
    return None


def _read_rows(filename: str, data: bytes) -> list[list]:
    name = (filename or "").lower()
    if name.endswith(".xlsx") or data[:2] == b"PK":
        try:
            import openpyxl
        except ImportError:
            raise HTTPException(500, "مكتبة قراءة ملفات Excel غير مثبتة على الخادم (pip install openpyxl)")
        try:
            wb = openpyxl.load_workbook(io.BytesIO(data), read_only=True, data_only=True)
        except Exception:
            raise HTTPException(422, "تعذر قراءة ملف Excel")
        ws = wb.worksheets[0]
        return [list(r) for r in ws.iter_rows(values_only=True)]
    for enc in ("utf-8-sig", "cp1256", "latin-1"):
        try:
            text = data.decode(enc)
            break
        except UnicodeDecodeError:
            continue
    return [row for row in csv.reader(io.StringIO(text))]


def _class_daily_average(cur) -> dict[str, float]:
    """What a house of each class usually pays per day (confirmed previous bills, else the tariff estimate)."""
    cur.execute(
        """SELECT p.property_class, AVG(pb.amount / pb.period_days) AS d, COUNT(*) AS n FROM previous_bills pb
           JOIN properties p ON p.id = pb.property_id WHERE pb.status = 'confirmed' GROUP BY p.property_class"""
    )
    have = {r["property_class"]: float(r["d"]) for r in cur.fetchall() if r["n"] >= 20}
    cur.execute("SELECT property_class, monthly_estimate FROM tariffs")
    return {r["property_class"]: have.get(r["property_class"], float(r["monthly_estimate"]) / 30.0) for r in cur.fetchall()}


def _outlier(amount: float, period_days: int, cls: str | None, avg: dict[str, float]) -> bool:
    if not cls or cls not in avg or avg[cls] <= 0:
        return False
    per_day = amount / max(1, period_days)
    f = settings.PREV_BILL_OUTLIER_FACTOR
    return per_day > avg[cls] * f or per_day < avg[cls] / f


def _match(cur, row: dict) -> tuple[dict | None, str | None]:
    if row.get("account_no"):
        cur.execute("SELECT id, property_code, property_class FROM properties WHERE directorate_account_no = %s", (row["account_no"],))
        hits = cur.fetchall()
        if len(hits) == 1:
            return hits[0], "account_no"
    if row.get("meter_serial"):
        cur.execute("SELECT id, property_code, property_class FROM properties WHERE meter_serial = %s", (row["meter_serial"],))
        hits = cur.fetchall()
        if len(hits) == 1:
            return hits[0], "meter_serial"
    if row.get("phone"):
        cur.execute("""SELECT p.id, p.property_code, p.property_class FROM properties p JOIN citizens c ON c.id = p.citizen_id
                       WHERE c.whatsapp_phone = %s AND p.status <> 'suspended'""", (row["phone"],))
        hits = cur.fetchall()
        if len(hits) == 1:
            return hits[0], "phone"
    return None, None


class ImportIn(BaseModel):
    filename: str = Field(..., max_length=200)
    content_base64: str = Field(..., max_length=30_000_000)


def _classify(rows: list[dict]) -> dict:
    s = {"total": len(rows), "matched": 0, "unmatched": 0, "duplicates": 0, "odd_amount": 0, "invalid": 0, "skipped": 0}
    for r in rows:
        if r.get("skip"):
            s["skipped"] += 1
        elif r["issue"] == "invalid":
            s["invalid"] += 1
        elif r["property_id"] is None:
            s["unmatched"] += 1
        else:
            s["matched"] += 1
            if r["issue"] == "duplicate":
                s["duplicates"] += 1
            if r.get("odd"):
                s["odd_amount"] += 1
    return s


def _recheck_duplicates(rows: list[dict]) -> None:
    seen: dict[int, int] = {}
    for r in rows:
        if r["issue"] == "duplicate":
            r["issue"] = None
    for i, r in enumerate(rows):
        if r.get("skip") or r["property_id"] is None or r["issue"] == "invalid":
            continue
        if r["property_id"] in seen:
            r["issue"] = "duplicate"
            rows[seen[r["property_id"]]]["issue"] = rows[seen[r["property_id"]]]["issue"] or "duplicate"
        else:
            seen[r["property_id"]] = i


@router.post("/prev-bills/import")
def stage_import(body: ImportIn, user: dict = Depends(importers)):
    try:
        data = base64.b64decode(body.content_base64.split(",", 1)[-1], validate=True)
    except (binascii.Error, ValueError):
        raise HTTPException(422, "الملف غير صالح")
    table = [r for r in _read_rows(body.filename, data) if any(str(c or "").strip() for c in r)]
    if len(table) < 2:
        raise HTTPException(422, "الملف فارغ أو بلا صف عناوين")
    cols = _map_headers(table[0])
    if "amount" not in cols:
        raise HTTPException(422, "لم يُعثر على عمود المبلغ. سمّ العمود «المبلغ»")
    if not ({"account_no", "meter_serial", "phone"} & cols.keys()):
        raise HTTPException(422, "يجب أن يحتوي الملف على رقم الحساب أو رقم العداد أو رقم الهاتف لمطابقة العقارات")
    if len(table) - 1 > MAX_ROWS:
        raise HTTPException(413, f"الملف أكبر من {MAX_ROWS:,} صف، قسّمه إلى ملفات أصغر")

    def cell(r, c):
        i = cols.get(c)
        return r[i] if i is not None and i < len(r) else None

    with get_conn() as conn, dict_cursor(conn) as cur:
        avg = _class_daily_average(cur)
        rows = []
        for n, r in enumerate(table[1:], start=2):
            amount = _num(cell(r, "amount"))
            days = int(_num(cell(r, "period_days")) or 30)
            row = {
                "line": n,
                "account_no": str(cell(r, "account_no")).strip() if cell(r, "account_no") not in (None, "") else None,
                "meter_serial": str(cell(r, "meter_serial")).strip() if cell(r, "meter_serial") not in (None, "") else None,
                "phone": normalize_iraqi_phone(str(cell(r, "phone"))) if cell(r, "phone") not in (None, "") else None,
                "name": str(cell(r, "name")).strip() if cell(r, "name") not in (None, "") else None,
                "amount": amount, "period_days": max(1, days), "bill_date": _date(cell(r, "bill_date")),
                "consumption": _num(cell(r, "consumption")),
                "property_id": None, "property_code": None, "matched_by": None, "issue": None, "odd": False, "skip": False,
            }
            if amount is None or amount < 0:
                row["issue"] = "invalid"
            else:
                hit, by = _match(cur, row)
                if hit:
                    row.update(property_id=hit["id"], property_code=hit["property_code"], matched_by=by,
                               odd=_outlier(amount, row["period_days"], hit["property_class"], avg))
            rows.append(row)
        _recheck_duplicates(rows)
        summary = _classify(rows)
        cur.execute("INSERT INTO prev_bill_imports (filename, uploaded_by, rows, summary) VALUES (%s,%s,%s,%s) RETURNING id",
                    (body.filename, user["id"], json.dumps(rows, ensure_ascii=False), json.dumps(summary)))
        imp_id = cur.fetchone()["id"]
        audit.log(cur, user["id"], "prev_bills_staged", "prev_bill_import", imp_id, {"file": body.filename, **summary})
    return {"import_id": imp_id, "columns_found": list(cols.keys()), "summary": summary,
            "preview": [r for r in rows if r["issue"] or r["property_id"] is None or r["odd"]][:200]}


@router.get("/prev-bills/imports")
def list_imports(user: dict = Depends(importers)):
    with get_conn() as conn, dict_cursor(conn) as cur:
        cur.execute("""SELECT i.id, i.filename, i.status, i.summary, i.uploaded_at, e.employee_code AS uploaded_by
                       FROM prev_bill_imports i JOIN employees e ON e.id = i.uploaded_by ORDER BY i.id DESC LIMIT 50""")
        rows = cur.fetchall()
    return [{**r, "uploaded_at": r["uploaded_at"].isoformat()} for r in rows]


@router.get("/prev-bills/imports/{imp_id}")
def get_import(imp_id: int, show: Literal["problems", "all", "matched"] = "problems", user: dict = Depends(importers)):
    with get_conn() as conn, dict_cursor(conn) as cur:
        cur.execute("SELECT * FROM prev_bill_imports WHERE id = %s", (imp_id,))
        imp = cur.fetchone()
    if not imp:
        raise HTTPException(404, "الملف غير موجود")
    def keep(r: dict) -> bool:
        if show == "problems":
            return not r.get("skip") and bool(r["issue"] or r["property_id"] is None or r["odd"])
        if show == "matched":
            return r["property_id"] is not None and not r["issue"]
        return True
    out = []
    for i, r in enumerate(imp["rows"]):
        if keep(r):
            out.append(dict(r, index=i))
            if len(out) >= 500:
                break
    return {"id": imp["id"], "filename": imp["filename"], "status": imp["status"], "summary": imp["summary"], "rows": out}


class RowFixIn(BaseModel):
    property_code: str | None = None
    skip: bool | None = None
    amount: float | None = Field(None, ge=0)


@router.post("/prev-bills/imports/{imp_id}/rows/{index}")
def fix_row(imp_id: int, index: int, body: RowFixIn, user: dict = Depends(importers)):
    """Manually link a row to a house, correct its amount, or skip it — before commit."""
    with get_conn() as conn, dict_cursor(conn) as cur:
        cur.execute("SELECT * FROM prev_bill_imports WHERE id = %s FOR UPDATE", (imp_id,))
        imp = cur.fetchone()
        if not imp or imp["status"] != "staged":
            raise HTTPException(409, "لا يمكن تعديل ملف تم اعتماده أو إلغاؤه")
        rows = imp["rows"]
        if index < 0 or index >= len(rows):
            raise HTTPException(404, "الصف غير موجود")
        r = rows[index]
        if body.skip is not None:
            r["skip"] = body.skip
        if body.amount is not None:
            r["amount"] = body.amount
            if r["issue"] == "invalid":
                r["issue"] = None
        if body.property_code:
            cur.execute("SELECT id, property_code, property_class FROM properties WHERE UPPER(property_code) = UPPER(%s)",
                        (body.property_code.strip(),))
            p = cur.fetchone()
            if not p:
                raise HTTPException(404, "العقار غير موجود")
            avg = _class_daily_average(cur)
            r.update(property_id=p["id"], property_code=p["property_code"], matched_by="manual",
                     odd=_outlier(r["amount"] or 0, r["period_days"], p["property_class"], avg))
        _recheck_duplicates(rows)
        summary = _classify(rows)
        cur.execute("UPDATE prev_bill_imports SET rows = %s, summary = %s WHERE id = %s",
                    (json.dumps(rows, ensure_ascii=False), json.dumps(summary), imp_id))
    return {"row": dict(r, index=index), "summary": summary}


@router.post("/prev-bills/imports/{imp_id}/commit")
def commit_import(imp_id: int, user: dict = Depends(importers)):
    with get_conn() as conn, dict_cursor(conn) as cur:
        cur.execute("SELECT * FROM prev_bill_imports WHERE id = %s FOR UPDATE", (imp_id,))
        imp = cur.fetchone()
        if not imp or imp["status"] != "staged":
            raise HTTPException(409, "الملف معتمد أو ملغى مسبقاً")
        rows = imp["rows"]
        if any(r["issue"] == "duplicate" and not r.get("skip") for r in rows):
            raise HTTPException(409, "يوجد عقار مكرر في الملف. تخطَّ أحد الصفين أو صحّح الربط قبل الاعتماد")
        saved = review = 0
        for r in rows:
            if r.get("skip") or r["property_id"] is None or r["issue"] == "invalid" or r["amount"] is None:
                continue
            status = "pending_review" if r["odd"] else "confirmed"
            cur.execute(
                """INSERT INTO previous_bills (property_id, amount, period_days, bill_date, consumption, source, import_id,
                                               status, flags, entered_by)
                   VALUES (%s,%s,%s,%s,%s,'import',%s,%s,%s,%s)""",
                (r["property_id"], r["amount"], r["period_days"], r["bill_date"], r["consumption"], imp_id, status,
                 json.dumps(["odd_amount"] if r["odd"] else []), user["id"]),
            )
            if r["account_no"]:
                cur.execute("UPDATE properties SET directorate_account_no = %s WHERE id = %s AND directorate_account_no IS NULL",
                            (r["account_no"], r["property_id"]))
            saved += 1
            review += status == "pending_review"
        cur.execute("UPDATE prev_bill_imports SET status = 'committed', committed_by = %s, committed_at = NOW() WHERE id = %s",
                    (user["id"], imp_id))
        audit.log(cur, user["id"], "prev_bills_committed", "prev_bill_import", imp_id, {"saved": saved, "to_review": review})
    return {"saved": saved, "to_review": review, "left_out": len(rows) - saved}


@router.post("/prev-bills/imports/{imp_id}/discard")
def discard_import(imp_id: int, user: dict = Depends(importers)):
    with get_conn() as conn, dict_cursor(conn) as cur:
        cur.execute("UPDATE prev_bill_imports SET status = 'discarded' WHERE id = %s AND status = 'staged' RETURNING id", (imp_id,))
        if not cur.fetchone():
            raise HTTPException(409, "لا يمكن إلغاء هذا الملف")
        audit.log(cur, user["id"], "prev_bills_discarded", "prev_bill_import", imp_id, {})
    return {"ok": True}


@router.get("/prev-bills/summary")
def coverage(user: dict = Depends(readers)):
    with get_conn() as conn, dict_cursor(conn) as cur:
        cur.execute(
            """SELECT COUNT(*) AS houses,
                      COUNT(*) FILTER (WHERE EXISTS (SELECT 1 FROM previous_bills pb WHERE pb.property_id = p.id AND pb.status = 'confirmed')) AS confirmed,
                      COUNT(*) FILTER (WHERE EXISTS (SELECT 1 FROM previous_bills pb WHERE pb.property_id = p.id AND pb.status IN ('pending_review','mismatch'))) AS waiting
               FROM properties p WHERE p.status = 'active'"""
        )
        r = cur.fetchone()
        cur.execute("SELECT COUNT(*) AS n FROM previous_bills WHERE status = 'mismatch'")
        mism = cur.fetchone()["n"]
    return {**r, "mismatches": mism, "coverage": round(r["confirmed"] / r["houses"], 4) if r["houses"] else None}


# ---------------------------------------------------------------- at the house

def _pb_out(r: dict | None) -> dict | None:
    if not r:
        return None
    return {"id": r["id"], "amount": float(r["amount"]), "period_days": r["period_days"],
            "bill_date": r["bill_date"].isoformat() if r["bill_date"] else None, "source": r["source"],
            # a paper bill that differs from the imported one is shown as "mismatch" while it waits for review
            "status": "mismatch" if r.get("review_needed") else r["status"], "review_needed": bool(r.get("review_needed")),
            "field_amount": float(r["field_amount"]) if r["field_amount"] is not None else None, "flags": r["flags"]}


def _field_property(cur, property_id: int, user: dict) -> dict:
    cur.execute("SELECT id, property_code, property_class, sector_id, directorate_account_no, flags FROM properties WHERE id = %s",
                (property_id,))
    p = cur.fetchone()
    if not p:
        raise HTTPException(404, "العقار غير موجود")
    if p["sector_id"] != user["sector_id"]:
        raise HTTPException(403, "هذا العقار خارج القاطع المخصص لك")
    return p


@router.get("/collector/properties/{property_id}/prev-bill")
def field_prev_bill(property_id: int, user: dict = Depends(field)):
    with get_conn() as conn, dict_cursor(conn) as cur:
        p = _field_property(cur, property_id, user)
        cur.execute("""SELECT * FROM previous_bills WHERE property_id = %s AND status <> 'superseded' AND status <> 'rejected'
                       ORDER BY id DESC LIMIT 1""", (property_id,))
        r = cur.fetchone()
    return {"property_code": p["property_code"], "account_no": p["directorate_account_no"], "previous_bill": _pb_out(r),
            "needs_action": (r is None and "no_previous_bill" not in (p["flags"] or []))
                            or (r is not None and r["source"] == "import" and "field_checked" not in (r["flags"] or [])
                                and not r["review_needed"])}


class FieldPrevIn(BaseModel):
    action: Literal["confirm", "mismatch", "new", "none"]
    amount: float | None = Field(None, ge=0)
    period_days: int = Field(30, ge=1, le=400)
    bill_date: date | None = None
    account_no: str | None = Field(None, max_length=40)
    photo_base64: str | None = Field(None, max_length=6_000_000)
    note: str | None = Field(None, max_length=300)


@router.post("/collector/properties/{property_id}/prev-bill")
def field_prev_bill_save(property_id: int, body: FieldPrevIn, user: dict = Depends(field)):
    """confirm  = the paper bill matches the imported one
       mismatch = the paper bill shows a different amount (photo + amount required)
       new      = no imported bill: photograph the paper bill and type its amount
       none     = the citizen has no previous bill (recorded so nobody asks again)"""
    with get_conn() as conn, dict_cursor(conn) as cur:
        p = _field_property(cur, property_id, user)
        if body.account_no:
            cur.execute("UPDATE properties SET directorate_account_no = %s WHERE id = %s", (body.account_no.strip(), p["id"]))
        cur.execute("""SELECT * FROM previous_bills WHERE property_id = %s AND status NOT IN ('superseded','rejected')
                       ORDER BY id DESC LIMIT 1 FOR UPDATE""", (p["id"],))
        current = cur.fetchone()
        if body.action == "none":
            cur.execute("UPDATE properties SET flags = flags || '[\"no_previous_bill\"]'::jsonb WHERE id = %s", (p["id"],))
            audit.log(cur, user["id"], "prev_bill_none", "property", p["id"], {"note": body.note})
            return {"status": "recorded"}
        if body.action == "confirm":
            if not current:
                raise HTTPException(409, "لا توجد فاتورة سابقة لتأكيدها، اختر «إدخال فاتورة»")
            cur.execute("UPDATE previous_bills SET flags = flags || '[\"field_checked\"]'::jsonb WHERE id = %s", (current["id"],))
            audit.log(cur, user["id"], "prev_bill_field_confirmed", "previous_bill", current["id"], {})
            return {"status": current["status"]}
        if body.amount is None or not body.photo_base64:
            raise HTTPException(422, "صوّر الفاتورة الورقية وأدخل مبلغها")
        photo = files.save_photo(body.photo_base64, "prev_bills")
        avg = _class_daily_average(cur)
        odd = _outlier(body.amount, body.period_days, p["property_class"], avg)
        if body.action == "mismatch":
            if not current:
                raise HTTPException(409, "لا توجد فاتورة مستوردة للمقارنة، اختر «إدخال فاتورة»")
            if current["review_needed"]:
                raise HTTPException(409, "يوجد بلاغ اختلاف لهذه الفاتورة بانتظار المراجعة")
            # the imported (confirmed) amount stays the basis until someone else reviews the paper bill
            cur.execute("""UPDATE previous_bills SET review_needed = TRUE, field_amount = %s, photo_path = %s, note = %s,
                           field_entered_by = %s, flags = flags || %s::jsonb WHERE id = %s""",
                        (body.amount, photo, body.note, user["id"],
                         json.dumps(["field_mismatch"] + (["odd_amount"] if odd else [])), current["id"]))
            audit.log(cur, user["id"], "prev_bill_mismatch", "previous_bill", current["id"],
                      {"imported": float(current["amount"]), "field": body.amount})
            return {"status": "mismatch", "id": current["id"]}
        # new
        if current and current["status"] == "confirmed":
            raise HTTPException(409, "يوجد فاتورة سابقة مؤكدة لهذا العقار. إذا كانت مختلفة اختر «لا تطابق»")
        if current and current["status"] == "pending_review":
            raise HTTPException(409, "يوجد إدخال لهذه الفاتورة بانتظار مراجعة المشرف")
        if current:
            cur.execute("UPDATE previous_bills SET status = 'superseded' WHERE id = %s", (current["id"],))
        cur.execute(
            """INSERT INTO previous_bills (property_id, amount, period_days, bill_date, source, photo_path, status, flags, entered_by,
                                           field_entered_by, note)
               VALUES (%s,%s,%s,%s,'field',%s,'pending_review',%s,%s,%s,%s) RETURNING id""",
            (p["id"], body.amount, body.period_days, body.bill_date, photo, json.dumps(["odd_amount"] if odd else []),
             user["id"], user["id"], body.note),
        )
        new_id = cur.fetchone()["id"]
        audit.log(cur, user["id"], "prev_bill_entered", "previous_bill", new_id, {"amount": body.amount, "odd": odd})
    return {"status": "pending_review", "id": new_id}


# ---------------------------------------------------------------- supervisor review

def _team_ids(cur, user: dict) -> list[int]:
    cur.execute("SELECT id FROM employees WHERE supervisor_id = %s OR id = %s", (user["id"], user["id"]))
    return [r["id"] for r in cur.fetchall()]


@router.get("/supervisor/prev-bills")
def review_queue(user: dict = Depends(require_roles("supervisor", "finance"))):
    with get_conn() as conn, dict_cursor(conn) as cur:
        team = None if user["role"] != "supervisor" else _team_ids(cur, user)
        cur.execute(
            """SELECT pb.*, p.property_code, p.address, p.property_class, c.full_name AS citizen_name,
                      e.employee_code AS entered_by_code
               FROM previous_bills pb JOIN properties p ON p.id = pb.property_id JOIN citizens c ON c.id = p.citizen_id
               LEFT JOIN employees e ON e.id = pb.entered_by
               WHERE (pb.status = 'pending_review' OR pb.review_needed)
                 AND (%(t)s::int[] IS NULL OR pb.entered_by = ANY(%(t)s) OR p.registered_by = ANY(%(t)s)
                      OR p.sector_id IN (SELECT sector_id FROM employees WHERE id = ANY(%(t)s)))
               ORDER BY pb.created_at LIMIT 200""",
            {"t": team},
        )
        rows = cur.fetchall()
    return [{**_pb_out(r), "property_code": r["property_code"], "address": r["address"], "citizen_name": r["citizen_name"],
             "entered_by": r["entered_by_code"], "has_photo": bool(r["photo_path"]), "note": r["note"]} for r in rows]


def _in_scope(cur, user: dict, pb: dict) -> bool:
    """A supervisor only handles previous bills of his team's houses (same rule as his review queue)."""
    if user["role"] != "supervisor":
        return True
    team = _team_ids(cur, user)
    cur.execute("""SELECT 1 FROM properties p WHERE p.id = %(p)s AND (p.registered_by = ANY(%(t)s)
                     OR p.sector_id IN (SELECT sector_id FROM employees WHERE id = ANY(%(t)s)))""",
                {"p": pb["property_id"], "t": team})
    return cur.fetchone() is not None or pb.get("entered_by") in team


@router.get("/prev-bills/{pb_id}/photo")
def pb_photo(pb_id: int, user: dict = Depends(require_roles("supervisor", "finance", "command"))):
    with get_conn() as conn, dict_cursor(conn) as cur:
        cur.execute("SELECT photo_path, property_id, entered_by FROM previous_bills WHERE id = %s", (pb_id,))
        r = cur.fetchone()
        if r and not _in_scope(cur, user, r):
            r = None
    photo = files.load_photo(r["photo_path"]) if r else None
    if not photo:
        raise HTTPException(404, "لا توجد صورة")
    return photo


class ReviewIn(BaseModel):
    action: Literal["confirm", "use_field_amount", "keep_import", "reject"]
    note: str | None = Field(None, max_length=300)


@router.post("/supervisor/prev-bills/{pb_id}/decision")
def review(pb_id: int, body: ReviewIn, user: dict = Depends(require_roles("supervisor", "finance"))):
    """pending_review: confirm / reject.  mismatch (review_needed): use_field_amount / keep_import (reject = keep_import).
    Nobody reviews a paper bill he reported himself."""
    with get_conn() as conn, dict_cursor(conn) as cur:
        cur.execute("SELECT * FROM previous_bills WHERE id = %s FOR UPDATE", (pb_id,))
        r = cur.fetchone()
        if not r or not (r["status"] == "pending_review" or r["review_needed"]):
            raise HTTPException(409, "لا يوجد ما يُراجع في هذه الفاتورة")
        if not _in_scope(cur, user, r):
            raise HTTPException(404, "الفاتورة ليست ضمن فريقك")
        if r["field_entered_by"] == user["id"] or (r["source"] == "field" and r["entered_by"] == user["id"]):
            raise HTTPException(403, "لا يمكنك مراجعة فاتورة أدخلتها أو أبلغت عنها بنفسك")
        amount, status = r["amount"], r["status"]
        if r["review_needed"]:
            if body.action == "use_field_amount":
                amount, status = r["field_amount"], "confirmed"
            elif body.action == "confirm" and status == "pending_review":
                status = "confirmed"
            # keep_import / reject: the imported amount stays as it is
        else:
            if body.action in ("confirm", "keep_import"):
                status = "confirmed"
            elif body.action == "reject":
                status = "rejected"
            else:
                raise HTTPException(409, "لا يوجد مبلغ ميداني لهذه الفاتورة")
        cur.execute("""UPDATE previous_bills SET status = %s, amount = %s, review_needed = FALSE, reviewed_by = %s,
                       reviewed_at = NOW(), note = COALESCE(%s, note) WHERE id = %s""",
                    (status, amount, user["id"], body.note, pb_id))
        audit.log(cur, user["id"], "prev_bill_reviewed", "previous_bill", pb_id,
                  {"action": body.action, "amount": float(amount), "was": float(r["amount"]),
                   "field": float(r["field_amount"]) if r["field_amount"] is not None else None})
    return {"id": pb_id, "status": status, "amount": float(amount)}
