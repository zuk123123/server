from __future__ import annotations
from fastapi import FastAPI, HTTPException, Depends
from fastapi.responses import JSONResponse
from fastapi.middleware.cors import CORSMiddleware
from fastapi.middleware.trustedhost import TrustedHostMiddleware
from pydantic import BaseModel, Field
from typing import Optional
import os, sqlite3, time, hashlib, hmac, base64
from datetime import datetime, timedelta, timezone
from passlib.hash import bcrypt

APP_NAME        = os.getenv("POS2_APP_NAME", "AuthServer")
JWT_SECRET      = os.getenv("POS2_JWT_SECRET", "CHANGE_ME_IN_PROD")
JWT_EXPIRES_MIN = int(os.getenv("POS2_JWT_EXPIRES_MIN", "60"))
ALLOWED_ORIGINS = [o.strip() for o in os.getenv("POS2_CORS_ORIGINS", "").split(",") if o.strip()]
TRUSTED_HOSTS   = [h.strip() for h in os.getenv("POS2_TRUSTED_HOSTS", "*").split(",") if h.strip()]
DB_PATH         = os.getenv("POS2_DB_PATH", os.path.join(os.path.dirname(__file__), "db.sqlite"))

def _b64url(d: bytes) -> str:
    return base64.urlsafe_b64encode(d).rstrip(b"=").decode("utf-8")

def _b64url_decode(s: str) -> bytes:
    pad = "=" * ((4 - len(s) % 4) % 4)
    return base64.urlsafe_b64decode(s + pad)

def jwt_encode(payload: dict, secret: str) -> str:
    import json
    header = {"alg": "HS256", "typ": "JWT"}
    h = _b64url(json.dumps(header, separators=(",", ":")).encode())
    p = _b64url(json.dumps(payload, separators=(",", ":")).encode())
    signing_input = f"{h}.{p}".encode()
    sig = hmac.new(secret.encode(), signing_input, hashlib.sha256).digest()
    s = _b64url(sig)
    return f"{h}.{p}.{s}"

def jwt_decode(token: str, secret: str) -> dict:
    import json
    try:
        hb64, pb64, sb64 = token.split(".")
    except ValueError:
        raise HTTPException(status_code=401, detail="bad token")
    signing_input = f"{hb64}.{pb64}".encode()
    expected = hmac.new(secret.encode(), signing_input, hashlib.sha256).digest()
    actual = _b64url_decode(sb64)
    if not hmac.compare_digest(expected, actual):
        raise HTTPException(status_code=401, detail="bad signature")
    payload = json.loads(_b64url_decode(pb64))
    exp = payload.get("exp")
    if exp is not None and time.time() > float(exp):
        raise HTTPException(status_code=401, detail="token expired")
    return payload

def connect_db() -> sqlite3.Connection:
    os.makedirs(os.path.dirname(DB_PATH), exist_ok=True)
    conn = sqlite3.connect(DB_PATH, timeout=10, isolation_level=None)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA foreign_keys=ON")
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA synchronous=NORMAL")
    return conn

def get_db():
    conn = connect_db()
    try:
        yield conn
    finally:
        conn.close()

def init_schema(conn: sqlite3.Connection):
    cur = conn.cursor()
    cur.execute("""
        CREATE TABLE IF NOT EXISTS users (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            login TEXT UNIQUE NOT NULL,
            password_hash TEXT NOT NULL,
            created_at TEXT NOT NULL DEFAULT (datetime('now'))
        )
    """)
    cur.execute("""
        CREATE TABLE IF NOT EXISTS settings (
            user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
            theme TEXT CHECK(theme IN ('Light','Dark')) NOT NULL DEFAULT 'Dark',
            PRIMARY KEY (user_id)
        )
    """)
    cur.execute("CREATE INDEX IF NOT EXISTS users_login_idx ON users(login)")
    conn.commit()

class LoginIn(BaseModel):
    login: str = Field(min_length=1, max_length=128)
    password: str = Field(min_length=1, max_length=128)

class RegisterIn(BaseModel):
    login: str = Field(min_length=1, max_length=128)
    password: str = Field(min_length=6, max_length=128)
    theme: Optional[str] = Field(default="Dark")

class LoginOut(BaseModel):
    ok: bool
    themeName: Optional[str] = None
    token: Optional[str] = None

class OkOut(BaseModel):
    ok: bool

app = FastAPI(title=APP_NAME)
app.add_middleware(TrustedHostMiddleware, allowed_hosts=TRUSTED_HOSTS or ["*"])
if ALLOWED_ORIGINS:
    app.add_middleware(
        CORSMiddleware,
        allow_origins=ALLOWED_ORIGINS,
        allow_credentials=True,
        allow_methods=["*"],
        allow_headers=["*"],
    )

@app.on_event("startup")
def on_startup():
    conn = connect_db()
    init_schema(conn)
    conn.close()
    print(f"[Srv] Database initialized: {DB_PATH}")

@app.get("/ping", response_model=OkOut)
def ping():
    return {"ok": True}

@app.post("/api/register", response_model=OkOut)
def register(payload: RegisterIn, conn: sqlite3.Connection = Depends(get_db)):
    login = payload.login.strip()
    theme = (payload.theme or "Dark").strip()
    if theme not in ("Light", "Dark"):
        theme = "Dark"
    cur = conn.cursor()
    try:
        cur.execute("INSERT INTO users(login, password_hash) VALUES(?,?)",
                    (login, bcrypt.hash(payload.password)))
        user_id = cur.lastrowid
        cur.execute("INSERT INTO settings(user_id, theme) VALUES(?,?)",
                    (user_id, theme))
        conn.commit()
        return {"ok": True}
    except sqlite3.IntegrityError:
        raise HTTPException(status_code=409, detail="user exists")

@app.post("/api/login", response_model=LoginOut)
def login(payload: LoginIn, conn: sqlite3.Connection = Depends(get_db)):
    login = payload.login.strip()
    cur = conn.cursor()
    cur.execute("SELECT id, password_hash FROM users WHERE login=?", (login,))
    row = cur.fetchone()
    if not row or not bcrypt.verify(payload.password, row["password_hash"]):
        return {"ok": False}
    user_id = row["id"]
    cur.execute("SELECT theme FROM settings WHERE user_id=?", (user_id,))
    srow = cur.fetchone()
    theme = srow["theme"] if srow else "Dark"
    now = datetime.now(tz=timezone.utc)
    exp = now + timedelta(minutes=JWT_EXPIRES_MIN)
    token = jwt_encode({"sub": str(user_id), "login": login, "exp": exp.timestamp()}, JWT_SECRET)
    return {"ok": True, "themeName": theme, "token": token}

@app.exception_handler(HTTPException)
async def http_exc_handler(_, exc: HTTPException):
    return JSONResponse(status_code=exc.status_code, content={"ok": False, "error": exc.detail or "http_error"})
