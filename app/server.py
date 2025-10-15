#!/usr/bin/env python3
# -*- coding: utf-8 -*-

from __future__ import annotations
from fastapi import FastAPI, Depends
from fastapi.responses import JSONResponse
from fastapi.middleware.cors import CORSMiddleware
from fastapi.middleware.trustedhost import TrustedHostMiddleware
from starlette.requests import Request
from pydantic import BaseModel, Field
from typing import Optional
import os, sqlite3, base64, hashlib, hmac, time
from datetime import datetime, timedelta, timezone

# ────────────────────────────────────────────────────────────────────────────────
# Конфиг (ничего не создаём, только читаем готовую БД)
# ────────────────────────────────────────────────────────────────────────────────
APP_NAME        = os.getenv("POS2_APP_NAME", "AuthServer")
JWT_SECRET      = os.getenv("POS2_JWT_SECRET", "CHANGE_ME_IN_PROD")
JWT_EXPIRES_MIN = int(os.getenv("POS2_JWT_EXPIRES_MIN", "60"))
ALLOWED_ORIGINS = [o.strip() for o in os.getenv("POS2_CORS_ORIGINS", "").split(",") if o.strip()]
TRUSTED_HOSTS   = [h.strip() for h in os.getenv("POS2_TRUSTED_HOSTS", "*").split(",") if h.strip()]
DB_PATH         = os.getenv("POS2_DB_PATH") or os.path.join(os.path.dirname(__file__), "db.sqlite")

# ────────────────────────────────────────────────────────────────────────────────
# JWT (HS256)
# ────────────────────────────────────────────────────────────────────────────────
def _b64url(d: bytes) -> str:
    return base64.urlsafe_b64encode(d).rstrip(b"=").decode()

def _b64url_decode(s: str) -> bytes:
    pad = "=" * ((4 - len(s) % 4) % 4)
    return base64.urlsafe_b64decode(s + pad)

def jwt_encode(payload: dict, secret: str) -> str:
    import json
    header = {"alg": "HS256", "typ": "JWT"}
    h = _b64url(json.dumps(header, separators=(",", ":")).encode())
    p = _b64url(json.dumps(payload, separators=(",", ":")).encode())
    sig = hmac.new(secret.encode(), f"{h}.{p}".encode(), hashlib.sha256).digest()
    return f"{h}.{p}.{_b64url(sig)}"

# ────────────────────────────────────────────────────────────────────────────────
# DB (без создания схемы)
# ────────────────────────────────────────────────────────────────────────────────
def connect_db() -> sqlite3.Connection:
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

# ────────────────────────────────────────────────────────────────────────────────
# Пароли: поддержка bcrypt / sha256 / plain
# ────────────────────────────────────────────────────────────────────────────────
def verify_password(stored: str, provided: str) -> bool:
    if not isinstance(stored, str):
        return False
    s = stored.strip()

    # 1) bcrypt ($2a/$2b/$2y)
    if s.startswith("$2"):
        try:
            from passlib.hash import bcrypt as pl_bcrypt  # lazy import
            return bool(pl_bcrypt.verify(provided, s))
        except Exception as e:
            # логируем в консоль и пробуем дальше (ниже есть plain/sha256)
            print(f"[verify] bcrypt backend error: {e.__class__.__name__}: {e}")
            return False

    # 2) {sha256}hex
    if s.startswith("{sha256}"):
        hexhash = s[len("{sha256}"):]
        try:
            return hashlib.sha256(provided.encode()).hexdigest() == hexhash
        except Exception:
            return False

    # 3) иначе считаем, что это plain
    return provided == s

# ────────────────────────────────────────────────────────────────────────────────
# Модели
# ────────────────────────────────────────────────────────────────────────────────
class LoginIn(BaseModel):
    login: str = Field(min_length=1, max_length=128)
    password: str = Field(min_length=1, max_length=256)

class RegisterIn(BaseModel):
    login: str = Field(min_length=1, max_length=128)
    password: str = Field(min_length=1, max_length=256)
    theme: Optional[str] = Field(default="Dark")

class LoginOut(BaseModel):
    ok: bool
    themeName: Optional[str] = None
    token: Optional[str] = None
    error: Optional[str] = None

class OkOut(BaseModel):
    ok: bool
    error: Optional[str] = None

# ────────────────────────────────────────────────────────────────────────────────
# FastAPI
# ────────────────────────────────────────────────────────────────────────────────
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
    # Ничего не создаём — просто покажем куда подключились и сколько users
    try:
        conn = connect_db()
        cur = conn.cursor()
        try:
            cur.execute("SELECT COUNT(*) FROM users")
            n_users = cur.fetchone()[0]
        except Exception:
            n_users = -1
        print(f"[Srv] DB: {DB_PATH} (users={n_users})")
    finally:
        try:
            conn.close()
        except Exception:
            pass

@app.get("/ping", response_model=OkOut)
def ping():
    return {"ok": True}

@app.post("/api/login", response_model=LoginOut)
def login(payload: LoginIn, conn: sqlite3.Connection = Depends(get_db)):
    try:
        login = payload.login.strip()
        cur = conn.cursor()
        cur.execute("SELECT id, password_hash FROM users WHERE login=?", (login,))
        row = cur.fetchone()

        if not row:
            print("[login] user not found")
            return {"ok": False, "error": "bad credentials"}

        stored = row["password_hash"]
        ok = verify_password(stored, payload.password)
        print(f"[login] verify -> {ok}")

        if not ok:
            return {"ok": False, "error": "bad credentials"}

        user_id = row["id"]
        cur.execute("SELECT theme FROM settings WHERE user_id=?", (user_id,))
        srow = cur.fetchone()
        theme = srow["theme"] if srow else "Dark"

        now = datetime.now(tz=timezone.utc)
        exp = now + timedelta(minutes=JWT_EXPIRES_MIN)
        token = jwt_encode({"sub": str(user_id), "login": login, "exp": exp.timestamp()}, JWT_SECRET)

        return {"ok": True, "themeName": theme, "token": token}
    except sqlite3.OperationalError as e:
        print(f"[login] db error: {e}")
        return {"ok": False, "error": f"db_error:{e.__class__.__name__}"}

@app.get("/debug/dbinfo")
def dbinfo(conn: sqlite3.Connection = Depends(get_db)):
    cur = conn.cursor()
    try:
        cur.execute("SELECT COUNT(*) FROM users")
        n = cur.fetchone()[0]
    except Exception:
        n = -1
    return {"dbPath": DB_PATH, "users": n}
