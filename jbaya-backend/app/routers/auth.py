from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel

from .. import audit
from ..db import dict_cursor, get_conn
from ..security import create_token, current_user, verify_password

router = APIRouter(prefix="/auth", tags=["auth"])


class LoginIn(BaseModel):
    employee_code: str
    password: str


@router.post("/login")
def login(body: LoginIn):
    code = body.employee_code.strip().upper()
    error = None
    with get_conn() as conn, dict_cursor(conn) as cur:
        cur.execute(
            """SELECT e.*, s.name AS sector_name, s.code AS sector_code
               FROM employees e LEFT JOIN sectors s ON s.id = e.sector_id
               WHERE UPPER(e.employee_code) = %s""",
            (code,),
        )
        emp = cur.fetchone()
        if not emp or not verify_password(body.password, emp["password_hash"]):
            audit.log(cur, emp["id"] if emp else None, "login_failed", "employee", code, {})
            error = (401, "رقم الموظف أو كلمة المرور غير صحيحة")
        elif not emp["active"]:
            error = (403, "الحساب موقوف، راجع الإدارة")
        else:
            audit.log(cur, emp["id"], "login", "employee", emp["employee_code"], {"role": emp["role"]})
    if error:
        raise HTTPException(*error)
    return {
        "token": create_token(emp),
        "user": {
            "id": emp["id"],
            "employee_code": emp["employee_code"],
            "full_name": emp["full_name"],
            "role": emp["role"],
            "sector_id": emp["sector_id"],
            "sector_name": emp["sector_name"],
            "sector_code": emp["sector_code"],
        },
    }


@router.get("/me")
def me(user: dict = Depends(current_user)):
    return {k: user[k] for k in ("id", "employee_code", "full_name", "role", "sector_id", "sector_name", "sector_code")}
