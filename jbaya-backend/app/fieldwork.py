"""Phase 5: supervisors also collect in the field with the same quota as collectors.

A supervisor's own receipts never need a blind count by himself: when finance receives his cash at headquarters
(or when he looks at what he must hand over), they are moved into an automatic, already-matched reconciliation,
so the cash chain and the account book stay exactly the same as for his team's cash."""
FIELD_ROLES = ("collector", "supervisor")


def own_open_cash(cur, supervisor_id: int) -> tuple[float, int]:
    cur.execute("SELECT COALESCE(SUM(total_amount), 0) AS s, COUNT(*) AS n FROM receipts "
                "WHERE collector_id = %s AND reconciliation_id IS NULL", (supervisor_id,))
    r = cur.fetchone()
    return float(r["s"]), r["n"]


def settle_self(cur, supervisor_id: int) -> int | None:
    """Moves the supervisor's own unreconciled receipts into a matched reconciliation. Returns its id or None."""
    cur.execute("SELECT id, total_amount FROM receipts WHERE collector_id = %s AND reconciliation_id IS NULL FOR UPDATE",
                (supervisor_id,))
    rows = cur.fetchall()
    if not rows:
        return None
    total = round(sum(float(r["total_amount"]) for r in rows), 2)
    cur.execute(
        """INSERT INTO reconciliations (collector_id, supervisor_id, counted_cash, expected_cash, difference, receipts_count,
                                        status, note, resolution_status, settled_cash)
           VALUES (%s,%s,%s,%s,0,%s,'matched','جباية المشرف الخاصة (تسوية تلقائية)','none_needed',%s) RETURNING id""",
        (supervisor_id, supervisor_id, total, total, len(rows), total),
    )
    rec_id = cur.fetchone()["id"]
    cur.execute("UPDATE receipts SET reconciliation_id = %s WHERE id = ANY(%s)", (rec_id, [r["id"] for r in rows]))
    return rec_id
