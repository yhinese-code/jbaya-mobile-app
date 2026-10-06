"""Administration: employees, sectors (GIS polygons) and tariffs."""
import json
from typing import Literal

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field

from .. import audit
from ..db import dict_cursor, get_conn
from ..security import current_user, hash_password, require_roles
from ..utils import normalize_iraqi_phone

router = APIRouter(tags=["admin"])


class EmployeeIn(BaseModel):
    employee_code: str = Field(..., min_length=3, max_length=30)
    full_name: str = Field(..., min_length=3, max_length=120)
    role: Literal["collector", "supervisor", "finance", "command", "hr", "admin"]
    password: str = Field(..., min_length=8)
    phone: str | None = None
    sector_code: str | None = None
    supervisor_code: str | None = None


@router.post("/admin/employees")
def create_employee(body: EmployeeIn, user: dict = Depends(require_roles("hr"))):
    phone = None
    if body.phone:
        phone = normalize_iraqi_phone(body.phone)
        if not phone:
            raise HTTPException(422, "رقم الهاتف غير صالح")
    with get_conn() as conn, dict_cursor(conn) as cur:
        sector_id = supervisor_id = None
        if body.sector_code:
            cur.execute("SELECT id FROM sectors WHERE code = %s", (body.sector_code,))
            s = cur.fetchone()
            if not s:
                raise HTTPException(404, "القاطع غير موجود")
            sector_id = s["id"]
        if body.supervisor_code:
            cur.execute("SELECT id FROM employees WHERE employee_code = %s AND role = 'supervisor'", (body.supervisor_code,))
            s = cur.fetchone()
            if not s:
                raise HTTPException(404, "المشرف غير موجود")
            supervisor_id = s["id"]
        cur.execute("SELECT 1 FROM employees WHERE UPPER(employee_code) = UPPER(%s)", (body.employee_code,))
        if cur.fetchone():
            raise HTTPException(409, "رقم الموظف مستخدم مسبقاً")
        cur.execute(
            """INSERT INTO employees (employee_code, full_name, role, password_hash, phone, sector_id, supervisor_id)
               VALUES (%s,%s,%s,%s,%s,%s,%s) RETURNING id""",
            (body.employee_code.upper(), body.full_name, body.role, hash_password(body.password), phone, sector_id, supervisor_id),
        )
        new_id = cur.fetchone()["id"]
        audit.log(cur, user["id"], "employee_created", "employee", body.employee_code.upper(), {"role": body.role})
    return {"id": new_id}


@router.get("/admin/employees")
def list_employees(user: dict = Depends(require_roles("hr", "command"))):
    with get_conn() as conn, dict_cursor(conn) as cur:
        cur.execute(
            """SELECT e.id, e.employee_code, e.full_name, e.role, e.active, s.code AS sector_code, sup.employee_code AS supervisor_code
               FROM employees e LEFT JOIN sectors s ON s.id = e.sector_id LEFT JOIN employees sup ON sup.id = e.supervisor_id
               ORDER BY e.role, e.employee_code"""
        )
        return cur.fetchall()


class SectorIn(BaseModel):
    code: str
    name: str
    mahalla: str | None = None
    polygon: list[list[float]] = Field(..., min_length=3)   # [[lat, lng], ...]


@router.post("/admin/sectors")
def create_sector(body: SectorIn, user: dict = Depends(require_roles())):  # admin only
    with get_conn() as conn, dict_cursor(conn) as cur:
        cur.execute(
            """INSERT INTO sectors (code, name, mahalla, polygon) VALUES (%s,%s,%s,%s)
               ON CONFLICT (code) DO UPDATE SET name = EXCLUDED.name, mahalla = EXCLUDED.mahalla, polygon = EXCLUDED.polygon
               RETURNING id""",
            (body.code, body.name, body.mahalla, json.dumps(body.polygon)),
        )
        sid = cur.fetchone()["id"]
        audit.log(cur, user["id"], "sector_saved", "sector", body.code, {})
    return {"id": sid}


@router.get("/sectors")
def list_sectors(user: dict = Depends(current_user)):
    with get_conn() as conn, dict_cursor(conn) as cur:
        cur.execute("SELECT id, code, name, mahalla, polygon FROM sectors WHERE active ORDER BY code")
        return cur.fetchall()


@router.get("/tariffs")
def list_tariffs(user: dict = Depends(current_user)):
    with get_conn() as conn, dict_cursor(conn) as cur:
        cur.execute("SELECT property_class, unit_rate, monthly_estimate FROM tariffs ORDER BY property_class")
        return [{k: (float(v) if k != "property_class" else v) for k, v in r.items()} for r in cur.fetchall()]


class TariffIn(BaseModel):
    unit_rate: float = Field(..., ge=0)
    monthly_estimate: float = Field(..., ge=0)


@router.put("/admin/tariffs/{property_class}")
def update_tariff(property_class: Literal["Household", "Business", "Industrial", "Agricultural"], body: TariffIn,
                  user: dict = Depends(require_roles("finance"))):
    with get_conn() as conn, dict_cursor(conn) as cur:
        cur.execute(
            "UPDATE tariffs SET unit_rate = %s, monthly_estimate = %s, updated_at = NOW() WHERE property_class = %s",
            (body.unit_rate, body.monthly_estimate, property_class),
        )
        audit.log(cur, user["id"], "tariff_updated", "tariff", property_class, body.model_dump())
    return {"property_class": property_class, **body.model_dump()}


class EmployeeUpdateIn(BaseModel):
    full_name: str | None = Field(None, min_length=3, max_length=120)
    phone: str | None = None
    active: bool | None = None
    sector_code: str | None = None
    supervisor_code: str | None = None
    password: str | None = Field(None, min_length=8)
    daily_target_iqd: float | None = Field(None, ge=0)


@router.patch("/admin/employees/{employee_code}")
def update_employee(employee_code: str, body: EmployeeUpdateIn, user: dict = Depends(require_roles("hr"))):
    """Change an employee's phone (needed for Command 2FA), sector, supervisor, password, target, or suspend them."""
    sets, args = [], []
    with get_conn() as conn, dict_cursor(conn) as cur:
        cur.execute("SELECT id, role FROM employees WHERE UPPER(employee_code) = UPPER(%s)", (employee_code,))
        emp = cur.fetchone()
        if not emp:
            raise HTTPException(404, "الموظف غير موجود")
        if emp["role"] in ("admin", "command") and user["role"] != "admin":
            raise HTTPException(403, "تعديل حسابات القيادة والإدارة متاح لمدير النظام فقط")
        if body.full_name is not None:
            sets.append("full_name = %s"); args.append(body.full_name)
        if body.phone is not None:
            phone = normalize_iraqi_phone(body.phone)
            if not phone:
                raise HTTPException(422, "رقم الهاتف غير صالح")
            sets.append("phone = %s"); args.append(phone)
        if body.active is not None:
            sets.append("active = %s"); args.append(body.active)
        if body.sector_code is not None:
            cur.execute("SELECT id FROM sectors WHERE code = %s", (body.sector_code,))
            s = cur.fetchone()
            if not s:
                raise HTTPException(404, "القاطع غير موجود")
            sets.append("sector_id = %s"); args.append(s["id"])
        if body.supervisor_code is not None:
            cur.execute("SELECT id FROM employees WHERE employee_code = %s AND role = 'supervisor'", (body.supervisor_code,))
            s = cur.fetchone()
            if not s:
                raise HTTPException(404, "المشرف غير موجود")
            sets.append("supervisor_id = %s"); args.append(s["id"])
        if body.password is not None:
            sets.append("password_hash = %s"); args.append(hash_password(body.password))
        if body.daily_target_iqd is not None:
            sets.append("daily_target_iqd = %s"); args.append(body.daily_target_iqd)
        if not sets:
            raise HTTPException(422, "لا توجد تعديلات")
        cur.execute(f"UPDATE employees SET {', '.join(sets)} WHERE id = %s", (*args, emp["id"]))
        changed = [k for k, v in body.model_dump().items() if v is not None and k != "password"]
        audit.log(cur, user["id"], "employee_updated", "employee", employee_code.upper(),
                  {"fields": changed + (["password"] if body.password else [])})
    return {"employee_code": employee_code.upper(), "updated": True}
