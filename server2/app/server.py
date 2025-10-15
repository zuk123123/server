from __future__ import annotations
from fastapi import FastAPI, Depends
from fastapi.responses import JSONResponse
from fastapi.middleware.cors import CORSMiddleware
from fastapi.middleware.trustedhost import TrustedHostMiddleware
from starlette.requests import Request
from pydantic import BaseModel, Field
from typing import Optional
import os, base64, hmac, hashlib, time, sqlite3
from datetime import datetime, timedelta, timezone

from .db import connect_db, DB_PATH
from .auth import verify_password

APP_NAME        = os.getenv("POS2_APP_NAME", "AuthServer2")
JWT_SECRET      = os.getenv("POS2_JWT_SECRET", "CHANGE_ME_IN_PROD")
JWT_EXPIRES_MIN = int(os.getenv("POS2_JWT_EXPIRES_MIN", "60"))
ALLOWED_ORIGINS = [o.strip() for o in os.getenv("POS2_CORS_ORIGINS", "").split(",") if o.strip()]
TRUSTED_HOSTS   = [h.strip() for h in os.getenv("POS2_TRUSTED_HOSTS", "*").split(",") if h.strip()]

def _b64url(d: bytes) -> str:
    return base64.urlsafe_b64encode(d).rstrip(b"=").decode()
def jwt_encode(payload: dict, secret: str) -> str:
    import json
    header = {"alg":"HS256","typ":"JWT"}
    h = _b64url(json.dumps(header, separators=(",",":")).encode())
    p = _b64url(json.dumps(payload, separators=(",",":")).encode())
    sig = hmac.new(secret.encode(), f"{h}.{p}".encode(), hashlib.sha256).digest()
    return f"{h}.{p}.{_b64url(sig)}"

def get_db():
    conn = connect_db()
    try:
        yield conn
    finally:
        conn.close()

class LoginIn(BaseModel):
    login: str = Field(min_length=1, max_length=128)
    password: str = Field(min_length=1, max_length=256)

class LoginOut(BaseModel):
    ok: bool
    themeName: Optional[str] = None
    token: Optional[str] = None
    error: Optional[str] = None

class OkOut(BaseModel):
    ok: bool
    error: Optional[str] = None

app = FastAPI(title=APP_NAME)
app.add_middleware(TrustedHostMiddleware, allowed_hosts=TRUSTED_HOSTS or ["*"])
if ALLOWED_ORIGINS:
    app.add_middleware(CORSMiddleware,
        allow_origins=ALLOWED_ORIGINS, allow_credentials=True,
        allow_methods=["*"], allow_headers=["*"])

@app.middleware("http")
async def log_requests(request: Request, call_next):
    t0 = datetime.now()
    ip = request.client.host if request.client else "unknown"
    print(f"[{t0:%Y-%m-%d %H:%M:%S}] {ip} {request.method} {request.url.path}")
    try:
        resp = await call_next(request)
        return resp
    except Exception as e:
        return JSONResponse(status_code=500, content={"ok": False, "error": f"internal:{e.__class__.__name__}"})
    finally:
        t1 = datetime.now()
        print(f"[{t1:%Y-%m-%d %H:%M:%S}] done {request.method} {request.url.path} ({int((t1-t0).total_seconds()*1000)} ms)")

@app.on_event("startup")
def on_startup():
    conn = connect_db()
    try:
        cur = conn.cursor()
        try:
            cur.execute("SELECT COUNT(*) FROM users")
            n = cur.fetchone()[0]
        except Exception:
            n = -1
        print(f"[Srv2] DB: {DB_PATH} (users={n})")
    finally:
        conn.close()

@app.get("/ping", response_model=OkOut)
def ping():
    return {"ok": True}

@app.post("/api/login", response_model=LoginOut)
def login(payload: LoginIn, conn: sqlite3.Connection = Depends(get_db)):
    cur = conn.cursor()
    cur.execute("SELECT id, password_hash FROM users WHERE login=?", (payload.login.strip(),))
    row = cur.fetchone()
    if not row:
        return {"ok": False, "error": "bad credentials"}
    if not verify_password(row["password_hash"], payload.password):
        return {"ok": False, "error": "bad credentials"}

    user_id = row["id"]
    cur.execute("SELECT theme FROM settings WHERE user_id=?", (user_id,))
    srow = cur.fetchone()
    theme = srow["theme"] if srow else "Dark"

    now = datetime.now(tz=timezone.utc)
    exp = now + timedelta(minutes=JWT_EXPIRES_MIN)
    token = jwt_encode({"sub": str(user_id), "login": payload.login, "exp": exp.timestamp()}, JWT_SECRET)
    return {"ok": True, "themeName": theme, "token": token}

@app.get("/debug/dbinfo")
def dbinfo(conn: sqlite3.Connection = Depends(get_db)):
    cur = conn.cursor()
    try:
        cur.execute("SELECT COUNT(*) FROM users")
        n = cur.fetchone()[0]
    except Exception:
        n = -1
    return {"dbPath": DB_PATH, "users": n}
