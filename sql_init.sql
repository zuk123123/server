PRAGMA foreign_keys=ON;
CREATE TABLE IF NOT EXISTS users (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  login TEXT UNIQUE NOT NULL,
  password_hash TEXT NOT NULL,
  created_at TEXT NOT NULL DEFAULT (datetime('now'))
);
CREATE TABLE IF NOT EXISTS settings (
  user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  theme TEXT CHECK(theme IN ('Light','Dark')) NOT NULL DEFAULT 'Dark',
  PRIMARY KEY (user_id)
);

INSERT OR IGNORE INTO users(login, password_hash) VALUES
 ('admin', 'admin'),
 ('demo',  '123456'),
 ('bob',   '{sha256}' || lower(hex(sha256('qwerty')))); -- пример sha256

INSERT OR IGNORE INTO settings(user_id, theme)
SELECT id, CASE login
             WHEN 'admin' THEN 'Dark'
             WHEN 'demo'  THEN 'Light'
             ELSE 'Dark'
           END
FROM users;
