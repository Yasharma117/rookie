"""Generate, hash, and look up ingest tokens.

Tokens are high-entropy random strings. We store only their SHA-256 hash —
even if the database leaks, the raw tokens cannot be reconstructed. SHA-256
(rather than bcrypt/argon2) is fine here because the input is uniformly
random over 32 bytes — there is nothing to brute-force.
"""
import hashlib
import secrets

TOKEN_PREFIX = "rk_ingest_"


def generate() -> tuple[str, str]:
    """Return (raw_token, token_hash). Hand raw_token to the caller once;
    persist token_hash in the DB."""
    raw = TOKEN_PREFIX + secrets.token_urlsafe(32)
    return raw, hash_token(raw)


def hash_token(raw: str) -> str:
    return hashlib.sha256(raw.encode("utf-8")).hexdigest()
