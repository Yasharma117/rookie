"""Sign in with Apple identity-token verification.

Same shape as clerk.py: networkless verification against Apple's JWKS with
PyJWT's built-in signing-key cache (one fetch, then cached).
"""
import logging

import jwt
from jwt import PyJWKClient

from app.config import settings

logger = logging.getLogger(__name__)

APPLE_JWKS_URL = "https://appleid.apple.com/auth/keys"
APPLE_ISSUER = "https://appleid.apple.com"


class AppleAuthError(Exception):
    pass


_jwks_client: PyJWKClient | None = None


def _client() -> PyJWKClient:
    global _jwks_client
    if _jwks_client is None:
        _jwks_client = PyJWKClient(APPLE_JWKS_URL, cache_keys=True)
    return _jwks_client


def verify_identity_token(token: str) -> dict:
    """Verify an Apple identity token (from ASAuthorizationAppleIDCredential)
    and return the claims dict.

    Raises AppleAuthError on any failure (signature, expiry, issuer/audience
    mismatch).
    """
    try:
        signing_key = _client().get_signing_key_from_jwt(token)
        claims = jwt.decode(
            token,
            signing_key.key,
            algorithms=["RS256"],
            issuer=APPLE_ISSUER,
            audience=settings.apple_bundle_id,
        )
    except jwt.InvalidTokenError as e:
        raise AppleAuthError(str(e)) from e
    except Exception as e:
        logger.warning("Apple JWT verification error: %s: %s", type(e).__name__, e)
        raise AppleAuthError(str(e)) from e

    if not claims.get("sub"):
        raise AppleAuthError("token missing 'sub' claim")
    return claims
