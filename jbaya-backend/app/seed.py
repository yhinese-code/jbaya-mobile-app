"""Development seed data.  Run once:  python -m app.seed
Creates tariffs, one demo sector (Al-Mansour) and one account per role.
All demo accounts share SEED_PASSWORD (default: Jbaya@2026). Change them before going live."""
import json
import os

from .db import apply_schema, dict_cursor, get_conn
from .security import hash_password

# Same rates the first prototype used. Edit later from PUT /admin/tariffs/{class}.
TARIFFS = [
    # class,         IQD per m3, IQD per 30 days (estimate)
    ("Household",     100,        22500),
    ("Business",      250,        50000),
    ("Industrial",    400,       120000),
    ("Agricultural",   50,        15000),
]

# Demo sector polygon around Al-Mansour (same area the prototype's geofence used)
MANSOUR = [[33.3100, 44.3500], [33.3300, 44.3500], [33.3300, 44.3800], [33.3100, 44.3800]]

ACCOUNTS = [
    # code,      name,                 role,         sector,  supervisor
    ("ADMIN-01", "مدير النظام",         "admin",      None,    None),
    ("CMD-01",   "غرفة القيادة",        "command",    None,    None),
    ("FN-01",    "المالية",             "finance",    None,    None),
    ("HR-01",    "الموارد البشرية",     "hr",         None,    None),
    ("SP-01",    "أحمد قاسم",           "supervisor", "S-01",  None),
    ("JB-0492",  "جابي تجريبي",         "collector",  "S-01",  "SP-01"),
]


def run():
    password = os.getenv("SEED_PASSWORD", "Jbaya@2026")
    apply_schema()
    with get_conn() as conn, dict_cursor(conn) as cur:
        for cls, rate, est in TARIFFS:
            cur.execute(
                """INSERT INTO tariffs (property_class, unit_rate, monthly_estimate) VALUES (%s,%s,%s)
                   ON CONFLICT (property_class) DO NOTHING""",
                (cls, rate, est),
            )
        cur.execute(
            """INSERT INTO sectors (code, name, mahalla, polygon) VALUES ('S-01', 'قاطع 1 - المنصور', '600', %s)
               ON CONFLICT (code) DO NOTHING""",
            (json.dumps(MANSOUR),),
        )
        for code, name, role, sector, sup in ACCOUNTS:
            cur.execute("SELECT id FROM sectors WHERE code = %s", (sector,))
            s = cur.fetchone()
            cur.execute("SELECT id FROM employees WHERE employee_code = %s", (sup,))
            sp = cur.fetchone()
            cur.execute(
                """INSERT INTO employees (employee_code, full_name, role, password_hash, sector_id, supervisor_id)
                   VALUES (%s,%s,%s,%s,%s,%s) ON CONFLICT (employee_code) DO NOTHING""",
                (code, name, role, hash_password(password), s["id"] if s else None, sp["id"] if sp else None),
            )
    print("Seed complete. Demo accounts (password: %s):" % password)
    for code, name, role, *_ in ACCOUNTS:
        print(f"  {code:10} {role}")


if __name__ == "__main__":
    run()
