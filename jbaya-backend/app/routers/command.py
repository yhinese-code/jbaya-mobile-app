"""Central Command: rotating master code (Command role ONLY), master-code usage log, live KPIs, receipts log."""
from fastapi import APIRouter, Depends, HTTPException, Query

from .. import audit, codes
from ..db import dict_cursor, get_conn
from ..security import current_user, require_roles

router = APIRouter(prefix="/command", tags=["command"])
command_or_admin = require_roles("command")


def command_strict(user: dict = Depends(current_user)) -> dict:
    """Master code is visible to the Command role only (not admin, not supervisors)."""
    if user["role"] != "command":
        raise HTTPException(403, "الرمز الرئيسي متاح لغرفة القيادة فقط")
    return user


@router.get("/master-code")
def master_code(user: dict = Depends(command_strict)):
    info = codes.current_master_code()
    with get_conn() as conn, dict_cursor(conn) as cur:
        # log once per window per viewer, so the log is not flooded by the screen's auto-refresh
        cur.execute(
            """SELECT 1 FROM audit_log WHERE actor_id = %s AND action = 'master_code_viewed'
               AND details->>'window' = %s LIMIT 1""",
            (user["id"], str(info["window_index"])),
        )
        if not cur.fetchone():
            audit.log(cur, user["id"], "master_code_viewed", "master_code", info["window_index"], {"window": str(info["window_index"])})
    return info


@router.get("/master-code/uses")
def master_code_uses(days: int = Query(7, ge=1, le=90), user: dict = Depends(command_or_admin)):
    with get_conn() as conn, dict_cursor(conn) as cur:
        cur.execute(
            """SELECT m.id, m.purpose, m.reason, m.used_at, e.employee_code AS collector_code, e.full_name AS collector_name,
                      p.property_code, p.address, b.total_amount
               FROM master_code_uses m
               JOIN employees e ON e.id = m.collector_id
               JOIN properties p ON p.id = m.property_id
               LEFT JOIN bills b ON b.id = m.bill_id
               WHERE m.used_at >= NOW() - (%s || ' days')::interval
               ORDER BY m.used_at DESC""",
            (days,),
        )
        rows = cur.fetchall()
        cur.execute(
            """SELECT e.employee_code, e.full_name, COUNT(*) AS uses
               FROM master_code_uses m JOIN employees e ON e.id = m.collector_id
               WHERE m.used_at >= NOW() - (%s || ' days')::interval
               GROUP BY e.employee_code, e.full_name ORDER BY uses DESC""",
            (days,),
        )
        per_collector = cur.fetchall()
    for r in rows:
        r["used_at"] = r["used_at"].isoformat()
        r["total_amount"] = float(r["total_amount"]) if r["total_amount"] is not None else None
    return {"uses": rows, "per_collector": per_collector}


@router.get("/overview")
def overview(user: dict = Depends(command_or_admin)):
    with get_conn() as conn, dict_cursor(conn) as cur:
        cur.execute(
            """SELECT
                 (SELECT COALESCE(SUM(total_amount),0) FROM receipts WHERE issued_at >= date_trunc('day', NOW())) AS collected_today,
                 (SELECT COUNT(*) FROM receipts WHERE issued_at >= date_trunc('day', NOW())) AS receipts_today,
                 (SELECT COUNT(*) FROM properties WHERE activated_at >= date_trunc('day', NOW())) AS registrations_today,
                 (SELECT COUNT(*) FROM master_code_uses WHERE used_at >= date_trunc('day', NOW())) AS master_code_uses_today,
                 (SELECT COUNT(*) FROM bills WHERE status IN ('pending_approval','blocked_review')) AS bills_in_review,
                 (SELECT COALESCE(SUM(total_amount),0) FROM receipts WHERE reconciliation_id IS NULL) AS cash_in_transit,
                 (SELECT COUNT(*) FROM properties WHERE status = 'active') AS active_properties,
                 (SELECT COUNT(*) FROM sos_alerts WHERE status = 'open') AS open_sos,
                 (SELECT COUNT(*) FROM reconciliations WHERE resolution_status = 'escalated') AS escalations,
                 (SELECT COALESCE(SUM(amount),0) FROM bank_deposits WHERE status = 'pending') AS deposits_pending_verification,
                 (SELECT COUNT(*) FROM audit_log WHERE action IN ('otp_failed','master_code_failed','geofence_violation','employee_phone_blocked','cash_cap_blocked')
                     AND created_at >= date_trunc('day', NOW())) AS security_events_today"""
        )
        r = cur.fetchone()
    return {k: (float(v) if k in ("collected_today", "cash_in_transit", "deposits_pending_verification") else v) for k, v in r.items()}


@router.get("/receipts")
def receipts_log(limit: int = Query(100, ge=1, le=1000), user: dict = Depends(command_or_admin)):
    with get_conn() as conn, dict_cursor(conn) as cur:
        cur.execute(
            """SELECT r.receipt_no, r.issued_at, r.gov_amount, r.company_fee, r.total_amount, r.verification_method,
                      p.property_code, e.employee_code AS collector_code, b.flags
               FROM receipts r
               JOIN properties p ON p.id = r.property_id
               JOIN employees e ON e.id = r.collector_id
               JOIN bills b ON b.id = r.bill_id
               ORDER BY r.issued_at DESC LIMIT %s""",
            (limit,),
        )
        rows = cur.fetchall()
    for r in rows:
        r["issued_at"] = r["issued_at"].isoformat()
        for k in ("gov_amount", "company_fee", "total_amount"):
            r[k] = float(r[k])
    return rows


@router.get("/audit/verify")
def verify_audit_chain(user: dict = Depends(command_or_admin)):
    with get_conn() as conn, dict_cursor(conn) as cur:
        return audit.verify_chain(cur)
