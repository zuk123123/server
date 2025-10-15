import hashlib

def verify_password(stored: str, provided: str) -> bool:
    if not isinstance(stored, str):
        return False
    s = stored.strip()
    if s.startswith("{sha256}"):
        hexhash = s[len("{sha256}"):].strip()
        return hashlib.sha256(provided.encode()).hexdigest() == hexhash
    # plain
    return s == provided
