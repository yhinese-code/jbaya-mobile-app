"""Breakeven and performance, each role at its own level (see app/performance.py)."""
from fastapi import APIRouter, Depends, Query

from .. import performance
from ..db import dict_cursor, get_conn
from ..security import require_roles

router = APIRouter(tags=["performance"])


@router.get("/performance/collectors")
def collectors(period: str | None = Query(None, pattern=r"^\d{4}-\d{2}$"),
               user: dict = Depends(require_roles("finance", "command", "owner"))):
    """Money view: earnings vs cost per collector per day, losing days, streaks, breakeven."""
    with get_conn() as conn, dict_cursor(conn) as cur:
        return performance.per_collector_money(cur, period)


@router.get("/supervisor/performance")
def team(user: dict = Depends(require_roles("supervisor"))):
    """House counts and labels for the supervisor's team — no money."""
    with get_conn() as conn, dict_cursor(conn) as cur:
        return performance.team_view(cur, None if user["role"] in ("admin", "tech") else user["id"])


@router.get("/collector/coach")
def coach(user: dict = Depends(require_roles("collector", "supervisor"))):
    """The collector's own daily target in houses, and how he compares with the team."""
    with get_conn() as conn, dict_cursor(conn) as cur:
        cur.execute("SELECT * FROM employees WHERE id = %s", (user["id"],))
        return performance.coach(cur, cur.fetchone())
