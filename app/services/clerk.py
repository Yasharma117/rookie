"""Clerk session JWT verification.

Verifies tokens networklessly using Clerk's JWKS endpoint with PyJWT's
built-in signing-key cache (no extra round trip after the first request).
"""
import logging

import jwt
from jwt import PyJWKClient

from app.config import settings

logger = logging.getLogger(__name__)


class ClerkAuthError(Exception):
    pass


_jwks_client: PyJWKClient | None = None


def _client() -> PyJWKClient:
    global _jwks_client
    if _jwks_client is None:
        if not settings.clerk_jwks_url:
            raise ClerkAuthError("CLERK_JWKS_URL not configured")
        _jwks_client = PyJWKClient(settings.clerk_jwks_url, cache_keys=True)
    return _jwks_client


def is_configured() -> bool:
    return bool(settings.clerk_jwks_url and settings.clerk_issuer)


def verify_session_token(token: str) -> dict:
    """Verify a Clerk session JWT and return the claims dict.

    Raises ClerkAuthError on any failure (signature, expiry, issuer mismatch).
    """
    try:
        signing_key = _client().get_signing_key_from_jwt(token)
        claims = jwt.decode(
            token,
            signing_key.key,
            algorithms=["RS256"],
            issuer=settings.clerk_issuer,
            options={"verify_aud": False},  # Clerk session JWTs omit aud
        )
    except jwt.InvalidTokenError as e:
        raise ClerkAuthError(str(e)) from e
    except Exception as e:
        logger.warning("Clerk JWT verification error: %s: %s", type(e).__name__, e)
        raise ClerkAuthError(str(e)) from e

    if not claims.get("sub"):
        raise ClerkAuthError("token missing 'sub' claim")
    return claims
