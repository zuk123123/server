import os, sqlite3

DB_PATH = os.environ.get("POS2_DB_PATH") or os.path.join(os.path.dirname(__file__), "db.sqlite")

def connect_db() -> sqlite3.Connection:
    conn = sqlite3.connect(DB_PATH, timeout=10, isolation_level=None)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA foreign_keys=ON")
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA synchronous=NORMAL")
    return conn
