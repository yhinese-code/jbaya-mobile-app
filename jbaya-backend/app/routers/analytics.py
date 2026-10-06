"""Finance analytics for finance and Command: overview, forecasting, Benford, anomalies, risk scores, arrears."""
from typing import Literal

from fastapi import APIRouter, Depends, Query

from .. import fin_data
from ..db import dict_cursor, get_conn
from ..security import require_roles

router = APIRouter(prefix="/finance", tags=["finance-analytics"])
readers = require_roles("finance", "command", "owner")


@router.get("/overview")
def overview(days: int = Query(30, ge=7, le=180), user: dict = Depends(readers)):
    with get_conn() as conn, dict_cursor(conn) as cur:
        return fin_data.overview(cur, days, user["role"])


@router.get("/forecast")
def forecast(horizon: int = Query(30, ge=7, le=90), user: dict = Depends(readers)):
    with get_conn() as conn, dict_cursor(conn) as cur:
        return fin_data.forecast(cur, horizon)


@router.get("/benford")
def benford(dataset: Literal["consumption", "gov_amount"] = "consumption", days: int = Query(365, ge=30, le=1095),
            collector: str | None = None, user: dict = Depends(readers)):
    with get_conn() as conn, dict_cursor(conn) as cur:
        return fin_data.benford(cur, dataset, days, collector)


@router.get("/anomalies")
def anomalies(days: int = Query(30, ge=1, le=180), user: dict = Depends(readers)):
    with get_conn() as conn, dict_cursor(conn) as cur:
        return fin_data.anomalies(cur, days)


@router.get("/risk")
def risk(days: int = Query(30, ge=7, le=180), user: dict = Depends(readers)):
    with get_conn() as conn, dict_cursor(conn) as cur:
        return fin_data.risk(cur, days)


@router.get("/aging")
def aging(user: dict = Depends(readers)):
    with get_conn() as conn, dict_cursor(conn) as cur:
        return fin_data.aging(cur)
