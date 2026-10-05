"""Hash-chained audit log. Every row stores sha256(prev_hash + row content),
so editing or deleting a past row breaks the chain and is detectable."""
import hashlib
import json

_AUDIT_LOCK_KEY = 74_001  # advisory lock id, serializes writers so the chain stays linear


def _digest(prev_hash: str | None, actor_id, action, entity, entity_id, details: dict) -> str:
    body = json.dumps(
        [prev_hash, actor_id, action, entity, str(entity_id) if entity_id is not None else None, details],
        sort_keys=True, ensure_ascii=False, default=str,
    )
    return hashlib.sha256(body.encode()).hexdigest()


def log(cur, actor_id, action: str, entity: str | None = None, entity_id=None, details: dict | None = None) -> None:
    """Write inside the caller's transaction (cur = any cursor on that connection)."""
    details = details or {}
    cur.execute("SELECT pg_advisory_xact_lock(%s)", (_AUDIT_LOCK_KEY,))
    cur.execute("SELECT hash FROM audit_log ORDER BY id DESC LIMIT 1")
    row = cur.fetchone()
    prev_hash = (row["hash"] if isinstance(row, dict) else row[0]) if row else None
    h = _digest(prev_hash, actor_id, action, entity, entity_id, details)
    cur.execute(
        """INSERT INTO audit_log (actor_id, action, entity, entity_id, details, prev_hash, hash)
           VALUES (%s, %s, %s, %s, %s, %s, %s)""",
        (actor_id, action, entity, str(entity_id) if entity_id is not None else None,
         json.dumps(details, ensure_ascii=False, default=str), prev_hash, h),
    )


def verify_chain(cur) -> dict:
    cur.execute("SELECT id, actor_id, action, entity, entity_id, details, prev_hash, hash FROM audit_log ORDER BY id")
    prev = None
    count = 0
    for r in cur.fetchall():
        r = dict(r) if not isinstance(r, dict) else r
        if r["prev_hash"] != prev:
            return {"valid": False, "broken_at_id": r["id"], "checked": count}
        if _digest(prev, r["actor_id"], r["action"], r["entity"], r["entity_id"], r["details"]) != r["hash"]:
            return {"valid": False, "broken_at_id": r["id"], "checked": count}
        prev = r["hash"]
        count += 1
    return {"valid": True, "checked": count}
