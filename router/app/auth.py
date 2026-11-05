"""Cognito access-token verification (defense in depth behind the ALB).

Signing keys come from PyJWT's PyJWKClient, which caches the user pool JWKS
and refetches it on expiry or when a token names an unknown key id. The
router adds the Cognito claim checks: issuer, expiry, token_use == "access"
and the required scope.
"""

from __future__ import annotations

from typing import Any

import jwt
from starlette.concurrency import run_in_threadpool


class AuthError(Exception):
    """The request carries no valid access token (HTTP 401)."""


class KeysUnavailable(Exception):
    """The JWKS endpoint could not be reached (HTTP 503)."""


def jwk_client(jwks_url: str, *, lifespan_seconds: float) -> jwt.PyJWKClient:
    return jwt.PyJWKClient(jwks_url, cache_keys=True, lifespan=lifespan_seconds, timeout=5)


class TokenVerifier:
    def __init__(self, *, issuer: str, required_scope: str, jwks: jwt.PyJWKClient) -> None:
        self._issuer = issuer
        self._required_scope = required_scope
        self._jwks = jwks

    async def verify(self, authorization: str | None) -> dict[str, Any]:
        token = _bearer_token(authorization)
        try:
            # PyJWKClient fetches over blocking HTTP; keep it off the event loop.
            key = await run_in_threadpool(self._jwks.get_signing_key_from_jwt, token)
        except jwt.PyJWKClientConnectionError as exc:
            raise KeysUnavailable("signing keys unavailable") from exc
        except jwt.PyJWTError as exc:  # malformed token, unknown kid, empty JWKS
            raise AuthError("invalid token") from exc

        try:
            claims = jwt.decode(
                token,
                key,
                algorithms=["RS256"],
                issuer=self._issuer,
                options={"require": ["exp", "iss"], "verify_aud": False},
            )
        except jwt.PyJWTError as exc:
            raise AuthError("invalid token") from exc

        if claims.get("token_use") != "access":
            raise AuthError("not an access token")
        if self._required_scope not in str(claims.get("scope", "")).split():
            raise AuthError("missing required scope")
        return claims


def _bearer_token(authorization: str | None) -> str:
    if not authorization:
        raise AuthError("missing Authorization header")
    scheme, _, token = authorization.partition(" ")
    token = token.strip()
    if scheme.lower() != "bearer" or not token:
        raise AuthError("Authorization header must be 'Bearer <token>'")
    return token
