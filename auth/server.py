"""Auth + container lifecycle service for the harness lab.

Two responsibilities:

  1. JWT-gate every harness subdomain.  Tokens are HS256-signed with the
     `harness` claim pinning a token to its subdomain (a `TOKEN_AIDER` cannot
     be replayed against `crush.lab.…`).  First visit with `?token=<jwt>` sets
     an `HttpOnly` cookie scoped to the harness host; subsequent requests use
     the cookie via Caddy `forward_auth`.

  2. Sablier-lite: on each `/verify` hit the service ensures the target
     harness container is running (cold-start ≈ 3-7s, blocking) and bumps a
     last-seen timestamp.  A background sweep stops containers that have been
     idle for `IDLE_TIMEOUT_MIN` minutes.

Sablier proper would give a nicer "starting…" loading page, but it needs a
third-party Caddy plugin to integrate cleanly.  This service is a
plugin-free substitute — same effect for a personal lab, simpler to deploy.
"""
from __future__ import annotations

import asyncio
import json
import logging
import os
import socket
import time

import docker
import httpx
import jwt
from docker.errors import NotFound
from fastapi import FastAPI, HTTPException, Query, Request, Response
from fastapi.responses import HTMLResponse, RedirectResponse, StreamingResponse

JWT_SECRET = os.environ["JWT_SECRET"]
JWT_ALG = "HS256"
IDLE_TIMEOUT_MIN = int(os.environ.get("IDLE_TIMEOUT_MIN", "30"))
BASE_DOMAIN = os.environ.get("HARNESS_BASE_DOMAIN", "lab.casava.space")
COOKIE_NAME = "harness_session"
CONTAINER_PREFIX = "harness-"
HARNESS_PORT = 7681  # ttyd default; OpenHands/Kilo override below
HARNESS_PORT_OVERRIDES = {"openhands": 3000, "kilocode": 8080}
COLD_START_TIMEOUT_S = 30

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("harness-auth")

docker_client = docker.from_env()
last_seen: dict[str, float] = {}

app = FastAPI(title="harness-auth", docs_url=None, redoc_url=None)


def _container_name(harness: str) -> str:
    return CONTAINER_PREFIX + harness


def _harness_port(harness: str) -> int:
    return HARNESS_PORT_OVERRIDES.get(harness, HARNESS_PORT)


def _decode(token: str, expected_harness: str) -> dict:
    try:
        payload = jwt.decode(token, JWT_SECRET, algorithms=[JWT_ALG])
    except jwt.ExpiredSignatureError:
        raise HTTPException(status_code=401, detail="token expired")
    except jwt.PyJWTError as e:
        raise HTTPException(status_code=401, detail=f"invalid token: {e}")
    if payload.get("harness") != expected_harness:
        raise HTTPException(status_code=403, detail="token not valid for this harness")
    return payload


def _ensure_running(harness: str) -> None:
    """Start the container if needed and block until ttyd is reachable."""
    name = _container_name(harness)
    try:
        container = docker_client.containers.get(name)
    except NotFound:
        raise HTTPException(status_code=502, detail=f"container {name} does not exist")

    if container.status != "running":
        log.info("starting %s (was %s)", name, container.status)
        container.start()

    port = _harness_port(harness)
    deadline = time.monotonic() + COLD_START_TIMEOUT_S
    while time.monotonic() < deadline:
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
            s.settimeout(0.5)
            try:
                s.connect((name, port))
                return
            except OSError:
                time.sleep(0.3)
    raise HTTPException(status_code=504, detail=f"{name} did not come up within {COLD_START_TIMEOUT_S}s")


@app.get("/healthz")
def healthz() -> dict:
    return {"ok": True}


@app.get("/issue")
def issue(request: Request, harness: str = Query(...), token: str = Query(...)) -> Response:
    """Visited as `https://<harness>.<base>/?token=<jwt>` (Caddy rewrites here).

    Validates the JWT, sets a host-scoped cookie, and 302-redirects to `/`
    (without the token query) so the URL bar no longer shows the secret.
    """
    _decode(token, harness)
    host = request.headers.get("host", "").split(":")[0]
    expected_host = f"{harness}.{BASE_DOMAIN}"
    if host != expected_host:
        raise HTTPException(status_code=400, detail=f"host {host} does not match harness {harness}")

    resp = RedirectResponse(url="/", status_code=302)
    resp.set_cookie(
        key=COOKIE_NAME,
        value=token,
        max_age=30 * 86400,
        httponly=True,
        secure=True,
        samesite="lax",
        path="/",
    )
    return resp


@app.get("/verify")
def verify(request: Request, harness: str = Query(...)) -> Response:
    """Caddy `forward_auth` target: 200 → allow, anything else → block."""
    token = request.cookies.get(COOKIE_NAME)
    if not token:
        return HTMLResponse(
            f"<h1>401</h1><p>No session cookie. Visit "
            f"<code>https://{harness}.{BASE_DOMAIN}/?token=&lt;your-jwt&gt;</code> first.</p>",
            status_code=401,
        )
    _decode(token, harness)
    _ensure_running(harness)
    last_seen[harness] = time.monotonic()
    return Response(status_code=200)


async def _idle_sweep() -> None:
    if IDLE_TIMEOUT_MIN <= 0:
        log.info("idle sweep disabled (IDLE_TIMEOUT_MIN=0)")
        return
    timeout_s = IDLE_TIMEOUT_MIN * 60
    while True:
        await asyncio.sleep(60)
        now = time.monotonic()
        for harness, ts in list(last_seen.items()):
            if now - ts < timeout_s:
                continue
            name = _container_name(harness)
            try:
                container = docker_client.containers.get(name)
            except NotFound:
                last_seen.pop(harness, None)
                continue
            if container.status == "running":
                log.info("stopping %s after %ds idle", name, int(now - ts))
                try:
                    container.stop(timeout=5)
                except Exception as e:
                    log.warning("failed to stop %s: %s", name, e)
            last_seen.pop(harness, None)


@app.on_event("startup")
async def _startup() -> None:
    asyncio.create_task(_idle_sweep())


# ── OpenRouter Anthropic-compat proxy ─────────────────────────────────────────
# Claude Code (and Droid) send Anthropic /v1/messages requests and expect the
# response content array to be just `[{type: text, …}]`.  OpenRouter on most
# free models wraps the response with `thinking` and `redacted_thinking`
# blocks, which Claude Code's content accumulator handles incorrectly —
# `result` ends up empty even though the model said something useful.
#
# This proxy sits between those harnesses and OpenRouter:
#   1. injects `reasoning: {exclude: true}` into the request body, asking
#      OpenRouter not to emit thinking blocks at all
#   2. for streaming responses, drops any SSE events for thinking content
#      blocks that slip through anyway
#
# Harnesses point at it via `ANTHROPIC_BASE_URL=http://harnesses-auth:8080/anthropic`.
# The proxy forwards to OpenRouter's Anthropic-compat endpoint.

OPENROUTER_ANTHROPIC = "https://openrouter.ai/api/v1/messages"
_PROXY_CLIENT = httpx.AsyncClient(timeout=httpx.Timeout(300.0))


def _strip_thinking(payload: dict) -> dict:
    """Remove thinking/redacted_thinking blocks from a non-streamed response."""
    if isinstance(payload.get("content"), list):
        payload["content"] = [
            c for c in payload["content"]
            if c.get("type") not in ("thinking", "redacted_thinking")
        ]
    return payload


async def _stream_filter(upstream: httpx.Response):
    """Iterate the upstream SSE stream and drop thinking-block events.

    SSE events arrive as `event: <name>\\ndata: <json>\\n\\n` triples; we have
    to buffer the event-line so we can drop or pass it together with its
    data-line, otherwise the consumer gets orphaned `event: ...` lines without
    matching data and complains.
    """
    pending_event = None
    drop = False
    async for raw_line in upstream.aiter_lines():
        if not raw_line:
            if pending_event is not None:
                yield pending_event + "\n"
                pending_event = None
            yield "\n"
            continue
        if raw_line.startswith("event: "):
            pending_event = raw_line
            continue
        if raw_line.startswith("data: "):
            payload = raw_line[6:]
            try:
                obj = json.loads(payload)
            except json.JSONDecodeError:
                if pending_event is not None:
                    yield pending_event + "\n"
                    pending_event = None
                yield raw_line + "\n"
                continue
            t = obj.get("type")
            if t == "content_block_start":
                block_type = (obj.get("content_block") or {}).get("type")
                if block_type in ("thinking", "redacted_thinking"):
                    drop = True
                    pending_event = None
                    continue
            elif t in ("content_block_delta", "content_block_stop") and drop:
                if t == "content_block_stop":
                    drop = False
                pending_event = None
                continue
            if pending_event is not None:
                yield pending_event + "\n"
                pending_event = None
            yield raw_line + "\n"
        else:
            if pending_event is not None:
                yield pending_event + "\n"
                pending_event = None
            yield raw_line + "\n"


@app.api_route("/anthropic/v1/messages", methods=["POST"])
async def proxy_messages(request: Request) -> Response:
    body = await request.body()
    try:
        payload = json.loads(body) if body else {}
    except json.JSONDecodeError:
        raise HTTPException(status_code=400, detail="invalid JSON")

    # Tell OpenRouter not to emit reasoning content.  This is the body-level
    # equivalent of OpenAI's `extra_body={"reasoning": {"exclude": True}}`.
    payload.setdefault("reasoning", {})["exclude"] = True

    # Pass through caller headers (Authorization, anthropic-version, etc.) but
    # drop hop-by-hop headers that httpx will set itself.
    fwd_headers = {
        k: v for k, v in request.headers.items()
        if k.lower() not in ("host", "content-length", "connection", "accept-encoding")
    }

    streaming = bool(payload.get("stream"))
    upstream_request = _PROXY_CLIENT.build_request(
        "POST", OPENROUTER_ANTHROPIC, json=payload, headers=fwd_headers,
    )

    if streaming:
        upstream = await _PROXY_CLIENT.send(upstream_request, stream=True)
        if upstream.status_code >= 400:
            text = await upstream.aread()
            await upstream.aclose()
            return Response(content=text, status_code=upstream.status_code,
                            media_type=upstream.headers.get("content-type", "application/json"))
        async def gen():
            try:
                async for chunk in _stream_filter(upstream):
                    yield chunk.encode()
            finally:
                await upstream.aclose()
        return StreamingResponse(gen(), status_code=upstream.status_code,
                                 media_type="text/event-stream")

    upstream = await _PROXY_CLIENT.send(upstream_request)
    if upstream.status_code >= 400:
        return Response(content=upstream.content, status_code=upstream.status_code,
                        media_type=upstream.headers.get("content-type", "application/json"))
    try:
        data = upstream.json()
        data = _strip_thinking(data)
        return Response(content=json.dumps(data), status_code=200,
                        media_type="application/json")
    except Exception:
        return Response(content=upstream.content, status_code=upstream.status_code,
                        media_type=upstream.headers.get("content-type", "application/json"))
