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
import re
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
TOKEN_TTL_DAYS = 30

# Mirrored from scripts/generate-tokens.py so the auth service can self-issue
# tokens at startup (avoids running the script as a separate step).
HARNESSES = [
    "claude", "aider", "opencode", "crush", "gptme", "goose", "plandex",
    "qwencode", "openhands", "kilocode", "codex", "pi", "droid",
]
ENV_FILE = "/app/.env"  # bind-mounted from host docker-compose.yml

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
    # Master-key shortcut: passing JWT_SECRET directly grants access to every
    # harness, no signing dance.  Convenient for the operator (one value to
    # remember, lives in .env) but it does mean the secret travels in URLs +
    # cookies — keep those out of screen-shares and browser sync.
    if token == JWT_SECRET:
        return {"harness": "*", "master": True}
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
def issue(request: Request, token: str = Query(...)) -> Response:
    """Visited as `https://<harness>.<base>/?token=<jwt>` (Caddy rewrites here).

    Derives the harness name from the Host header (everything before the
    base domain), validates the JWT, sets a host-scoped cookie, and
    302-redirects to `/` (without the token query) so the URL bar no longer
    shows the secret.
    """
    host = request.headers.get("host", "").split(":")[0]
    suffix = "." + BASE_DOMAIN
    if not host.endswith(suffix):
        raise HTTPException(status_code=400, detail=f"host {host} does not match base domain {BASE_DOMAIN}")
    harness = host[: -len(suffix)]
    _decode(token, harness)

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


def _sign_token(harness: str) -> str:
    now = int(time.time())
    return jwt.encode(
        {"harness": harness, "iat": now, "exp": now + TOKEN_TTL_DAYS * 86400},
        JWT_SECRET,
        algorithm=JWT_ALG,
    )


def _token_valid(token: str, harness: str) -> bool:
    try:
        payload = jwt.decode(token, JWT_SECRET, algorithms=[JWT_ALG])
    except jwt.PyJWTError:
        return False
    return payload.get("harness") == harness


def _autofill_tokens_and_log_urls() -> None:
    """Fill empty/invalid TOKEN_*= lines in .env, then log a URL per harness.

    Tokens are stateless — the auth service only needs JWT_SECRET to validate
    anything signed with it.  Writing tokens back to .env is purely for the
    operator's convenience: a stable place to copy-paste the login URL from.
    On every startup we (a) regenerate any missing or no-longer-valid token,
    and (b) log the full `https://<harness>.<base>/?token=<jwt>` URL so the
    operator can grab one from `docker logs harnesses-auth` without running
    a separate script.
    """
    tokens: dict[str, str] = {}
    env_lines: list[str] | None = None
    if os.path.exists(ENV_FILE):
        try:
            with open(ENV_FILE) as f:
                env_lines = f.readlines()
        except OSError as e:
            log.warning("could not read %s: %s", ENV_FILE, e)

    if env_lines is not None:
        changed = False
        for i, line in enumerate(env_lines):
            m = re.match(r"^(TOKEN_([A-Z_]+))=(.*)$", line.rstrip("\n"))
            if not m:
                continue
            harness = m.group(2).lower()
            if harness not in HARNESSES:
                continue
            value = m.group(3).strip()
            if not value or not _token_valid(value, harness):
                value = _sign_token(harness)
                env_lines[i] = f"TOKEN_{m.group(2)}={value}\n"
                changed = True
                log.info("auto-filled TOKEN_%s in .env", m.group(2))
            tokens[harness] = value
        if changed:
            try:
                with open(ENV_FILE, "w") as f:
                    f.writelines(env_lines)
            except OSError as e:
                log.warning("could not write %s (token autofill skipped): %s", ENV_FILE, e)
    else:
        log.warning("%s not present; logging URLs without persisting tokens", ENV_FILE)

    # Make sure every harness has at least an in-memory token to log a URL for.
    for h in HARNESSES:
        tokens.setdefault(h, _sign_token(h))

    sep = "=" * 78
    log.info(sep)
    log.info("Master login (JWT_SECRET works on every harness, no expiry):")
    log.info(sep)
    for h in HARNESSES:
        log.info("  https://%s.%s/?token=%s", h, BASE_DOMAIN, JWT_SECRET)
    log.info(sep)
    log.info("Per-harness tokens (30-day, scoped to one subdomain) — same effect:")
    log.info(sep)
    for h in HARNESSES:
        log.info("  https://%s.%s/?token=%s", h, BASE_DOMAIN, tokens[h])
    log.info(sep)


@app.on_event("startup")
async def _startup() -> None:
    _autofill_tokens_and_log_urls()
    asyncio.create_task(_idle_sweep())


# ── Anthropic-on-OpenAI translation proxy ─────────────────────────────────────
# Claude Code (and Droid) send Anthropic /v1/messages requests.  OpenRouter
# does expose an Anthropic-compat surface at /v1/messages, but its tool routing
# is only wired up for a subset of models — most NVIDIA/MiniMax/etc free models
# return "No endpoints found that support the provided 'tool_choice' value" any
# time the request has a `tools` array.
#
# OpenRouter's OpenAI-compat surface at /v1/chat/completions does have tool
# routing for those same models.  So this proxy:
#
#   1. Translates the incoming Anthropic body into OpenAI chat.completions
#      form (system + messages + tools + tool_choice + sampling params).
#   2. Sends it to OpenRouter's OpenAI-compat endpoint.
#   3. Translates the response (or SSE stream) back to Anthropic /v1/messages
#      shape, so Claude Code's content accumulator sees exactly what it
#      expects: `content: [{type:text|tool_use, …}]` + `stop_reason`.
#   4. Suppresses OpenRouter's reasoning blocks via `reasoning.exclude=true`,
#      so reasoning-class models don't double-charge tokens emitting thoughts
#      we'd drop anyway.
#
# Harnesses point at this via `ANTHROPIC_BASE_URL=http://harnesses-auth:8080/anthropic`.

OPENROUTER_OPENAI = "https://openrouter.ai/api/v1/chat/completions"
_PROXY_CLIENT = httpx.AsyncClient(timeout=httpx.Timeout(300.0))

_FINISH_TO_STOP = {
    "stop": "end_turn",
    "length": "max_tokens",
    "tool_calls": "tool_use",
    "function_call": "tool_use",
    "content_filter": "stop_sequence",
}


def _anthropic_to_openai_request(payload: dict) -> dict:
    """Translate an Anthropic /v1/messages body → OpenAI /v1/chat/completions."""
    out: dict = {"model": payload.get("model"), "messages": []}

    # System field: Anthropic allows a string or a list of {type:text} blocks.
    sys = payload.get("system")
    if sys:
        if isinstance(sys, list):
            sys_text = "\n\n".join(
                b.get("text", "") for b in sys if b.get("type") == "text"
            )
        else:
            sys_text = sys
        if sys_text:
            out["messages"].append({"role": "system", "content": sys_text})

    # Messages: each Anthropic block may map to one or several OpenAI messages
    # (a single user turn with N tool_result blocks becomes N role=tool msgs).
    for msg in payload.get("messages", []) or []:
        role = msg.get("role")
        content = msg.get("content")

        if isinstance(content, str):
            out["messages"].append({"role": role, "content": content})
            continue

        if role == "assistant":
            text_parts, tool_calls = [], []
            for block in content or []:
                btype = block.get("type")
                if btype == "text":
                    text_parts.append(block.get("text", ""))
                elif btype == "tool_use":
                    tool_calls.append({
                        "id": block.get("id"),
                        "type": "function",
                        "function": {
                            "name": block.get("name"),
                            "arguments": json.dumps(block.get("input", {})),
                        },
                    })
            asst = {"role": "assistant", "content": "\n".join(text_parts) or None}
            if tool_calls:
                asst["tool_calls"] = tool_calls
            out["messages"].append(asst)
            continue

        # Walk user-role blocks in source order; emit a user message with
        # accumulated text/image content, then flush tool_result blocks as
        # separate role=tool messages (OpenAI requires this split).
        buf: list = []
        for block in content or []:
            btype = block.get("type")
            if btype == "text":
                buf.append({"type": "text", "text": block.get("text", "")})
            elif btype == "image":
                src = block.get("source") or {}
                if src.get("type") == "base64":
                    url = f"data:{src.get('media_type', 'image/png')};base64,{src.get('data', '')}"
                    buf.append({"type": "image_url", "image_url": {"url": url}})
            elif btype == "tool_result":
                if buf:
                    flat = "".join(b.get("text", "") for b in buf if b.get("type") == "text")
                    out["messages"].append({"role": "user", "content": flat or buf})
                    buf = []
                tc = block.get("content", "")
                if isinstance(tc, list):
                    tc = "".join(c.get("text", "") for c in tc if c.get("type") == "text")
                out["messages"].append({
                    "role": "tool",
                    "tool_call_id": block.get("tool_use_id"),
                    "content": tc if isinstance(tc, str) else json.dumps(tc),
                })
        if buf:
            flat = "".join(b.get("text", "") for b in buf if b.get("type") == "text")
            out["messages"].append({"role": "user", "content": flat or buf})

    # Tools: Anthropic {name, description, input_schema} → OpenAI function schema.
    tools = payload.get("tools")
    if tools:
        out["tools"] = [
            {
                "type": "function",
                "function": {
                    "name": t.get("name"),
                    "description": t.get("description", ""),
                    "parameters": t.get("input_schema") or {"type": "object", "properties": {}},
                },
            }
            for t in tools
        ]

    tc = payload.get("tool_choice")
    if isinstance(tc, dict):
        tct = tc.get("type")
        if tct == "auto":
            out["tool_choice"] = "auto"
        elif tct == "any":
            out["tool_choice"] = "required"
        elif tct == "tool":
            out["tool_choice"] = {"type": "function", "function": {"name": tc.get("name")}}
        elif tct == "none":
            out["tool_choice"] = "none"

    for k in ("max_tokens", "temperature", "top_p"):
        if k in payload:
            out[k] = payload[k]
    if "stop_sequences" in payload:
        out["stop"] = payload["stop_sequences"]
    if "metadata" in payload and isinstance(payload["metadata"], dict):
        user_id = payload["metadata"].get("user_id")
        if user_id:
            out["user"] = user_id
    if payload.get("stream"):
        out["stream"] = True
        out["stream_options"] = {"include_usage": True}

    # OpenRouter-specific: suppress reasoning emissions so we don't pay for
    # tokens we'd strip anyway.
    out["reasoning"] = {"exclude": True}

    return out


def _openai_to_anthropic_response(data: dict) -> dict:
    """OpenAI chat.completion → Anthropic /v1/messages non-streaming response."""
    choice = (data.get("choices") or [{}])[0]
    msg = choice.get("message") or {}

    content: list = []
    text = msg.get("content")
    if text:
        content.append({"type": "text", "text": text})

    for tc in msg.get("tool_calls") or []:
        fn = tc.get("function") or {}
        try:
            args = json.loads(fn.get("arguments") or "{}")
        except json.JSONDecodeError:
            args = {}
        content.append({
            "type": "tool_use",
            "id": tc.get("id"),
            "name": fn.get("name"),
            "input": args,
        })

    if not content:
        content = [{"type": "text", "text": ""}]

    usage = data.get("usage") or {}
    return {
        "id": data.get("id", ""),
        "type": "message",
        "role": "assistant",
        "model": data.get("model", ""),
        "content": content,
        "stop_reason": _FINISH_TO_STOP.get(choice.get("finish_reason"), "end_turn"),
        "stop_sequence": None,
        "usage": {
            "input_tokens": usage.get("prompt_tokens", 0),
            "output_tokens": usage.get("completion_tokens", 0),
        },
    }


async def _translate_stream(upstream: httpx.Response, model: str, msg_id: str):
    """Convert an OpenAI chat.completion SSE stream → Anthropic /v1/messages SSE.

    The shapes are wildly different.  OpenAI emits one `delta` chunk per token
    with optional `content` and/or `tool_calls` partials; Anthropic emits a
    `message_start`, then per content-block start/delta/stop events, then a
    `message_delta` + `message_stop`.  We track which block index we're inside
    for text vs. each tool_call, and open/close blocks as the data shifts.
    """

    def sse(event: str, data: dict) -> bytes:
        return f"event: {event}\ndata: {json.dumps(data)}\n\n".encode()

    yield sse("message_start", {
        "type": "message_start",
        "message": {
            "id": msg_id,
            "type": "message",
            "role": "assistant",
            "model": model,
            "content": [],
            "stop_reason": None,
            "stop_sequence": None,
            "usage": {"input_tokens": 0, "output_tokens": 0},
        },
    })

    text_block_open = False
    text_block_index = -1
    # tool_call index (from OpenAI) → block index in Anthropic stream
    tool_blocks: dict[int, int] = {}
    next_block_index = 0
    final_finish: str | None = None
    final_usage: dict = {}

    async for raw in upstream.aiter_lines():
        if not raw.startswith("data: "):
            continue
        body = raw[6:].strip()
        if body == "[DONE]":
            break
        try:
            chunk = json.loads(body)
        except json.JSONDecodeError:
            continue

        if chunk.get("usage"):
            final_usage = chunk["usage"]
        choices = chunk.get("choices") or []
        if not choices:
            continue
        choice = choices[0]
        delta = choice.get("delta") or {}

        # Text content delta
        text = delta.get("content")
        if text:
            if not text_block_open:
                text_block_index = next_block_index
                next_block_index += 1
                text_block_open = True
                yield sse("content_block_start", {
                    "type": "content_block_start",
                    "index": text_block_index,
                    "content_block": {"type": "text", "text": ""},
                })
            yield sse("content_block_delta", {
                "type": "content_block_delta",
                "index": text_block_index,
                "delta": {"type": "text_delta", "text": text},
            })

        # Tool call deltas — OpenAI emits these incrementally, with `index`
        # pointing at the tool call slot.  First chunk has id+name, subsequent
        # chunks add to `arguments` (partial JSON).
        for tc in delta.get("tool_calls") or []:
            oi = tc.get("index", 0)
            if oi not in tool_blocks:
                # Close text block if still open before starting a tool block.
                if text_block_open:
                    yield sse("content_block_stop", {
                        "type": "content_block_stop",
                        "index": text_block_index,
                    })
                    text_block_open = False
                bi = next_block_index
                next_block_index += 1
                tool_blocks[oi] = bi
                fn = tc.get("function") or {}
                yield sse("content_block_start", {
                    "type": "content_block_start",
                    "index": bi,
                    "content_block": {
                        "type": "tool_use",
                        "id": tc.get("id") or f"call_{oi}",
                        "name": fn.get("name", ""),
                        "input": {},
                    },
                })
            fn = tc.get("function") or {}
            args_partial = fn.get("arguments")
            if args_partial:
                yield sse("content_block_delta", {
                    "type": "content_block_delta",
                    "index": tool_blocks[oi],
                    "delta": {"type": "input_json_delta", "partial_json": args_partial},
                })

        if choice.get("finish_reason"):
            final_finish = choice["finish_reason"]

    # Close any blocks still open.
    if text_block_open:
        yield sse("content_block_stop", {"type": "content_block_stop", "index": text_block_index})
    for bi in tool_blocks.values():
        yield sse("content_block_stop", {"type": "content_block_stop", "index": bi})

    yield sse("message_delta", {
        "type": "message_delta",
        "delta": {
            "stop_reason": _FINISH_TO_STOP.get(final_finish, "end_turn"),
            "stop_sequence": None,
        },
        "usage": {"output_tokens": final_usage.get("completion_tokens", 0)},
    })
    yield sse("message_stop", {"type": "message_stop"})


@app.api_route("/anthropic/v1/messages", methods=["POST"])
async def proxy_messages(request: Request) -> Response:
    body = await request.body()
    try:
        payload = json.loads(body) if body else {}
    except json.JSONDecodeError:
        raise HTTPException(status_code=400, detail="invalid JSON")

    streaming = bool(payload.get("stream"))
    model = payload.get("model", "")
    msg_id = "msg_" + str(int(time.time() * 1000))

    openai_body = _anthropic_to_openai_request(payload)

    # Forward only the auth header (Authorization or x-api-key).  Drop the
    # Anthropic-specific headers (anthropic-version, anthropic-beta, etc.) —
    # OpenRouter's OpenAI endpoint doesn't understand them and warns on some.
    auth_hdr = (
        request.headers.get("authorization")
        or (f"Bearer {request.headers.get('x-api-key')}" if request.headers.get("x-api-key") else None)
    )
    fwd_headers = {"Content-Type": "application/json"}
    if auth_hdr:
        fwd_headers["Authorization"] = auth_hdr

    upstream_request = _PROXY_CLIENT.build_request(
        "POST", OPENROUTER_OPENAI, json=openai_body, headers=fwd_headers,
    )

    if streaming:
        upstream = await _PROXY_CLIENT.send(upstream_request, stream=True)
        if upstream.status_code >= 400:
            text = await upstream.aread()
            await upstream.aclose()
            log.warning("upstream %d: %s", upstream.status_code, text[:300])
            return Response(content=text, status_code=upstream.status_code,
                            media_type=upstream.headers.get("content-type", "application/json"))

        async def gen():
            try:
                async for chunk in _translate_stream(upstream, model, msg_id):
                    yield chunk
            finally:
                await upstream.aclose()

        return StreamingResponse(gen(), status_code=200, media_type="text/event-stream")

    upstream = await _PROXY_CLIENT.send(upstream_request)
    if upstream.status_code >= 400:
        log.warning("upstream %d: %s", upstream.status_code, upstream.text[:300])
        return Response(content=upstream.content, status_code=upstream.status_code,
                        media_type=upstream.headers.get("content-type", "application/json"))
    try:
        data = upstream.json()
        translated = _openai_to_anthropic_response(data)
        return Response(content=json.dumps(translated), status_code=200,
                        media_type="application/json")
    except Exception as e:
        log.exception("translation failed: %s", e)
        return Response(content=upstream.content, status_code=502,
                        media_type=upstream.headers.get("content-type", "application/json"))
