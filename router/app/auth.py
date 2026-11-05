"""Cognito access-token verification (defense in depth behind the ALB).

Checks: RS256 signature against the user pool JWKS, issuer, expiry,
token_use == "access", and the required scope.
"""

from __future__ import annotations

import asyncio
import time
from typing import Any

import httpx
import jwt


class AuthError(Exception):
    """The request carries no valid access token (HTTP 401)."""


class KeysUnavailable(Exception):
    """The JWKS could not be fetched and no keys are cached (HTTP 503)."""


class JWKSCache:
    """Caches the user pool signing keys.

    Keys are refetched when the cache is older than ttl_seconds or when a token
    names an unknown key id (key rotation). Fetch attempts are throttled to one
    per min_refresh_seconds so unknown key ids cannot flood the JWKS endpoint.
    """

    def __init__(
        self,
        url: str,
        client: httpx.AsyncClient,
        *,
        ttl_seconds: float,
        min_refresh_seconds: float,
    ) -> None:
        self._url = url
        self._client = client
        self._ttl = ttl_seconds
        self._min_refresh = min_refresh_seconds
        self._keys: dict[str, jwt.PyJWK] = {}
        self._fetched_at = float("-inf")
        self._last_attempt = float("-inf")
        self._lock = asyncio.Lock()

    async def get(self, kid: str) -> jwt.PyJWK:
        if self._needs_refresh(kid):
            async with self._lock:
                if self._needs_refresh(kid):
                    await self._refresh()
        if not self._keys:
            raise KeysUnavailable("signing keys unavailable")
        key = self._keys.get(kid)
        if key is None:
            raise AuthError("unknown signing key")
        return key

    def _needs_refresh(self, kid: str) -> bool:
        now = time.monotonic()
        if now - self._last_attempt < self._min_refresh:
            return False
        return not self._keys or now - self._fetched_at > self._ttl or kid not in self._keys

    async def _refresh(self) -> None:
        self._last_attempt = time.monotonic()
        try:
            response = await self._client.get(self._url)
            response.raise_for_status()
            jwks = jwt.PyJWKSet.from_dict(response.json())
        except (httpx.HTTPError, ValueError, jwt.PyJWTError):
            return  # keep serving with the last known keys, if any
        self._keys = {k.key_id: k for k in jwks.keys if k.key_id}
        self._fetched_at = time.monotonic()


class TokenVerifier:
    def __init__(self, *, issuer: str, required_scope: str, jwks: JWKSCache) -> None:
        self._issuer = issuer
        self._required_scope = required_scope
        self._jwks = jwks

    async def verify(self, authorization: str | None) -> dict[str, Any]:
        token = _bearer_token(authorization)
        try:
            header = jwt.get_unverified_header(token)
        except jwt.PyJWTError as exc:
            raise AuthError("malformed token") from exc
        if header.get("alg") != "RS256" or not header.get("kid"):
            raise AuthError("unsupported token")

        key = await self._jwks.get(str(header["kid"]))
        try:
            claims = jwt.decode(
                token,
                key.key,
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
