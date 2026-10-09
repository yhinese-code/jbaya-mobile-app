"""PostgreSQL connection pool + helpers."""
from contextlib import contextmanager
from pathlib import Path

import psycopg2
import psycopg2.extras
from psycopg2.pool import ThreadedConnectionPool

from .config import settings

_pool: ThreadedConnectionPool | None = None


def init_pool(minconn: int = 1, maxconn: int = 20) -> None:
    global _pool
    if _pool is None:
        _pool = ThreadedConnectionPool(minconn, maxconn, settings.DB_CONN)


def close_pool() -> None:
    global _pool
    if _pool is not None:
        _pool.closeall()
        _pool = None


@contextmanager
def get_conn():
    """Yields a connection; commits on success, rolls back on any error."""
    if _pool is None:
        init_pool()
    conn = _pool.getconn()
    try:
        yield conn
        conn.commit()
    except Exception:
        conn.rollback()
        raise
    finally:
        _pool.putconn(conn)


def dict_cursor(conn):
    return conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor)


def apply_schema() -> None:
    sql = (Path(__file__).parent / "schema.sql").read_text(encoding="utf-8")
    with get_conn() as conn:
        with conn.cursor() as cur:
            # several uvicorn workers start at once: only one applies the schema at a time
            cur.execute("SELECT pg_advisory_xact_lock(74000)")
            cur.execute(sql)
