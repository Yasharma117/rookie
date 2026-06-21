"""Tiny ETag / conditional-response helper for read endpoints.

Lets clients (the iOS app) send `If-None-Match` and get a cheap `304 Not
Modified` when nothing changed — saving body serialization transfer and letting
the client keep its local cache without re-processing. Correctness-first: the
ETag is a hash of the actual response body, so a 304 is only ever returned when
the payload is byte-identical.
"""
import hashlib
import json as _json
from typing import Any

from fastapi import Request, Response
from fastapi.responses import JSONResponse

_CACHE_CONTROL = "private, max-age=0, must-revalidate"


def _etag_for(payload: Any) -> str:
    body = _json.dumps(payload, sort_keys=True, default=str, separators=(",", ":")).encode()
    return '"' + hashlib.sha256(body).hexdigest()[:32] + '"'


def conditional_json(request: Request, payload: Any) -> Response:
    """Return a JSON response with an ETag, or 304 if the client's matches."""
    etag = _etag_for(payload)
    headers = {"ETag": etag, "Cache-Control": _CACHE_CONTROL}
    if request.headers.get("if-none-match") == etag:
        return Response(status_code=304, headers=headers)
    return JSONResponse(content=payload, headers=headers)
