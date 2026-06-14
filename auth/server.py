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
RETENTION_DAYS = int(os.environ.get("RETENTION_DAYS", "7"))
# Cap on concurrently-existing dynamic instances per harness type (the base
# harness-<type> container is not counted).  0 disables the cap.
MAX_INSTANCES_PER_HARNESS = int(os.environ.get("MAX_INSTANCES_PER_HARNESS", "5"))
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
# OpenHands has its own web UI on :3000 with a stateful WORKSPACE_MOUNT_PATH;
# Kilo Code is code-server on :8080 — neither maps cleanly to a plain ttyd
# clone with a fresh workspace volume, so they stay single-instance.
MULTI_INSTANCE_HARNESSES = {h for h in HARNESSES if h not in ("openhands", "kilocode")}
INSTANCE_NAME_RE = re.compile(r"^[a-z0-9]([a-z0-9-]{0,28}[a-z0-9])?$")
ENV_FILE = "/app/.env"  # bind-mounted from host docker-compose.yml
INSTANCES_FILE = "/data/instances.json"  # persisted across auth-service restarts

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("harness-auth")

docker_client = docker.from_env()

# Per-container idle tracking (monotonic, used by _idle_sweep for precision).
# Key is the container name (e.g., "harness-claude-blog"), value is when it
# was last accessed via /verify.
last_seen: dict[str, float] = {}

# Per-instance metadata persisted to /data/instances.json so retention survives
# auth-service restarts.  Only contains *created* instances (not the base 13
# single-instance harnesses, which are managed by docker-compose).
# Key is the container name, value is {harness_type, created, last_seen_ts, pinned}.
instances: dict[str, dict] = {}

app = FastAPI(title="harness-auth", docs_url=None, redoc_url=None)


def _harness_port(harness_type: str) -> int:
    return HARNESS_PORT_OVERRIDES.get(harness_type, HARNESS_PORT)


def _parse_subdomain(subdomain: str) -> tuple[str, str | None]:
    """Resolve a subdomain label to (harness_type, instance|None).

    `claude`        → ("claude", None)     # the prebuilt single-instance harness
    `claude-blog`   → ("claude", "blog")   # dynamic instance to create/route
    `claude-9f3a2b` → ("claude", "9f3a2b") # auto-generated slug works the same
    """
    if subdomain in HARNESSES:
        return subdomain, None
    for harness in MULTI_INSTANCE_HARNESSES:
        prefix = harness + "-"
        if subdomain.startswith(prefix):
            instance = subdomain[len(prefix):]
            if not INSTANCE_NAME_RE.match(instance):
                raise HTTPException(400, f"invalid instance name: {instance!r}")
            return harness, instance
    raise HTTPException(404, f"unknown harness or instance: {subdomain!r}")


def _container_for(harness_type: str, instance: str | None) -> str:
    if instance is None:
        return CONTAINER_PREFIX + harness_type
    return CONTAINER_PREFIX + harness_type + "-" + instance


def _volume_for(harness_type: str, instance: str) -> str:
    return f"workspace-{harness_type}-{instance}"


def _instances_load() -> None:
    global instances
    if not os.path.exists(INSTANCES_FILE):
        return
    try:
        with open(INSTANCES_FILE) as f:
            instances = json.load(f)
        log.info("loaded %d tracked instance(s) from %s", len(instances), INSTANCES_FILE)
    except (OSError, json.JSONDecodeError) as e:
        log.warning("could not load %s: %s — starting empty", INSTANCES_FILE, e)


def _instances_save() -> None:
    try:
        os.makedirs(os.path.dirname(INSTANCES_FILE), exist_ok=True)
        tmp = INSTANCES_FILE + ".tmp"
        with open(tmp, "w") as f:
            json.dump(instances, f, indent=2)
        os.replace(tmp, INSTANCES_FILE)
    except OSError as e:
        log.warning("could not save %s: %s", INSTANCES_FILE, e)


def _count_instances(harness_type: str) -> int:
    """Number of existing dynamic instances of a harness type.

    Counts only auto-created instance containers (tagged with the
    `harness.type` label by _ensure_instance_container).  The base
    `harness-<type>` container is created by docker-compose without that
    label, so it is never counted toward the cap.
    """
    try:
        return len(docker_client.containers.list(
            all=True, filters={"label": f"harness.type={harness_type}"}))
    except docker.errors.APIError as e:
        log.warning("could not list instances for %s: %s — using tracked count", harness_type, e)
        return sum(1 for m in instances.values() if m.get("harness_type") == harness_type)


def _ensure_instance_container(harness_type: str, instance: str) -> str:
    """Create a per-instance container from the base image if it doesn't exist.

    Clones env from the base `harness-<type>` container so .env / compose
    overrides stay the single source of truth — we never have to keep two
    copies of the harness's environment in sync.  Each instance gets its own
    named volume mounted at /workspace, isolated from every other instance
    and from the base.
    """
    name = _container_for(harness_type, instance)
    try:
        docker_client.containers.get(name)
        return name
    except NotFound:
        pass

    # Cap concurrent dynamic instances per harness type.  Reconnecting to an
    # already-existing instance is never blocked (handled by the early return
    # above); only the creation of a *new* distinct slug is gated here.
    if MAX_INSTANCES_PER_HARNESS > 0:
        n = _count_instances(harness_type)
        if n >= MAX_INSTANCES_PER_HARNESS:
            raise HTTPException(
                status_code=429,
                detail=(
                    f"instance cap reached for '{harness_type}': "
                    f"{n}/{MAX_INSTANCES_PER_HARNESS} already running. "
                    f"Remove an existing {harness_type}-<slug> instance before "
                    f"creating a new one."
                ),
            )

    base_name = CONTAINER_PREFIX + harness_type
    try:
        base = docker_client.containers.get(base_name)
    except NotFound:
        raise HTTPException(
            502, f"base container {base_name} not found — `docker compose up -d` it first"
        )

    image = base.attrs["Config"]["Image"]
    env = base.attrs["Config"]["Env"]
    networks = list(base.attrs["NetworkSettings"]["Networks"].keys()) or ["harnesses_net"]

    volume_name = _volume_for(harness_type, instance)
    try:
        docker_client.volumes.get(volume_name)
    except NotFound:
        docker_client.volumes.create(
            name=volume_name,
            labels={"harness.type": harness_type, "harness.instance": instance},
        )

    log.info("creating instance container %s (image=%s, volume=%s)",
             name, image, volume_name)
    container = docker_client.containers.create(
        image=image,
        name=name,
        environment=env,
        network=networks[0],
        volumes={volume_name: {"bind": "/workspace", "mode": "rw"}},
        restart_policy={"Name": "no"},
        detach=True,
        labels={"harness.type": harness_type, "harness.instance": instance},
    )
    for n in networks[1:]:
        try:
            docker_client.networks.get(n).connect(container)
        except docker.errors.APIError as e:
            log.warning("could not attach %s to network %s: %s", name, n, e)

    instances[name] = {
        "harness_type": harness_type,
        "created": time.time(),
        "last_seen_ts": time.time(),
        "pinned": False,
    }
    _instances_save()
    return name


def _decode(token: str, subdomain: str, harness_type: str) -> dict:
    """Validate the JWT (or master JWT_SECRET) against the calling subdomain.

    Master JWT_SECRET → ok for everything (operator convenience).
    Signed JWTs → the `harness` claim must match the full subdomain
    (`claude-blog`), the harness type (`claude`, useful when the operator
    issued a token before knowing the instance name), or the wildcard `*`.
    """
    if token == JWT_SECRET:
        return {"harness": "*", "master": True}
    try:
        payload = jwt.decode(token, JWT_SECRET, algorithms=[JWT_ALG])
    except jwt.ExpiredSignatureError:
        raise HTTPException(status_code=401, detail="token expired")
    except jwt.PyJWTError as e:
        raise HTTPException(status_code=401, detail=f"invalid token: {e}")
    claim = payload.get("harness")
    if claim not in (subdomain, harness_type, "*"):
        raise HTTPException(status_code=403, detail="token not valid for this harness")
    return payload


def _ensure_running(harness_type: str, instance: str | None) -> str:
    """Make sure the target container exists (creating instances on demand),
    is started, and is reachable on its ttyd port.  Returns its name."""
    if instance is not None:
        _ensure_instance_container(harness_type, instance)
    name = _container_for(harness_type, instance)
    try:
        container = docker_client.containers.get(name)
    except NotFound:
        raise HTTPException(status_code=502, detail=f"container {name} does not exist")

    if container.status != "running":
        log.info("starting %s (was %s)", name, container.status)
        container.start()

    port = _harness_port(harness_type)
    deadline = time.monotonic() + COLD_START_TIMEOUT_S
    while time.monotonic() < deadline:
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
            s.settimeout(0.5)
            try:
                s.connect((name, port))
                return name
            except OSError:
                time.sleep(0.3)
    raise HTTPException(
        status_code=504, detail=f"{name} did not come up within {COLD_START_TIMEOUT_S}s"
    )


@app.get("/healthz")
def healthz() -> dict:
    return {"ok": True}


@app.get("/issue")
def issue(request: Request, token: str = Query(...)) -> Response:
    """Visited as `https://<subdomain>.<base>/?token=<jwt>` (Caddy rewrites here).

    Derives the subdomain from the Host header, parses out the harness type
    and optional instance, validates the JWT, sets a *domain-scoped* cookie
    (so one login covers every subdomain under .<BASE_DOMAIN>), then 302s
    to `/` so the token leaves the URL bar.
    """
    host = request.headers.get("host", "").split(":")[0]
    suffix = "." + BASE_DOMAIN
    if not host.endswith(suffix):
        raise HTTPException(
            status_code=400, detail=f"host {host} does not match base domain {BASE_DOMAIN}"
        )
    subdomain = host[: -len(suffix)]
    harness_type, _instance = _parse_subdomain(subdomain)
    _decode(token, subdomain, harness_type)

    resp = RedirectResponse(url="/", status_code=302)
    # domain=lab.casava.space (no leading dot — RFC 6265 spec; browsers extend
    # to subdomains automatically) → one cookie unlocks every <name>.lab.…
    resp.set_cookie(
        key=COOKIE_NAME,
        value=token,
        max_age=30 * 86400,
        httponly=True,
        secure=True,
        samesite="lax",
        path="/",
        domain=BASE_DOMAIN,
    )
    return resp


@app.get("/verify")
def verify(request: Request, harness: str = Query(...)) -> Response:
    """Caddy `forward_auth` target: 200 → allow, anything else → block.

    `harness` query param is the full subdomain label (e.g., `claude` or
    `claude-blog`); we parse it and route to (or create) the right container.
    """
    token = request.cookies.get(COOKIE_NAME)
    if not token:
        return HTMLResponse(
            f"<h1>401</h1><p>No session cookie. Visit "
            f"<code>https://{harness}.{BASE_DOMAIN}/?token=&lt;your-jwt&gt;</code> first.</p>",
            status_code=401,
        )
    harness_type, instance = _parse_subdomain(harness)
    _decode(token, harness, harness_type)
    container = _ensure_running(harness_type, instance)

    last_seen[container] = time.monotonic()
    if container in instances:
        instances[container]["last_seen_ts"] = time.time()
        _instances_save()
    return Response(status_code=200)


@app.get("/ask")
def ask_tls(domain: str = Query(...)) -> Response:
    """Caddy on-demand TLS gate.

    Caddy hits this before provisioning a certificate for an unknown hostname.
    We say yes only if the hostname matches a real harness or a valid instance
    pattern — stops random SNI noise from burning Let's Encrypt rate limits.
    """
    suffix = "." + BASE_DOMAIN
    if not domain.endswith(suffix):
        return Response(status_code=403)
    subdomain = domain[: -len(suffix)]
    try:
        _parse_subdomain(subdomain)
    except HTTPException:
        return Response(status_code=403)
    return Response(status_code=200)


@app.api_route("/pin", methods=["GET", "POST"])
def pin_endpoint(request: Request) -> Response:
    return _set_pin(request, pinned=True)


@app.api_route("/unpin", methods=["GET", "POST"])
def unpin_endpoint(request: Request) -> Response:
    return _set_pin(request, pinned=False)


def _set_pin(request: Request, pinned: bool) -> Response:
    """Toggle the pinned flag on the calling subdomain's instance.  Pinned
    instances skip the retention sweep and live until manually unpinned."""
    host = request.headers.get("host", "").split(":")[0]
    suffix = "." + BASE_DOMAIN
    if not host.endswith(suffix):
        raise HTTPException(400, "host mismatch")
    subdomain = host[: -len(suffix)]
    token = request.cookies.get(COOKIE_NAME)
    if not token:
        raise HTTPException(401, "no session cookie")
    harness_type, instance = _parse_subdomain(subdomain)
    _decode(token, subdomain, harness_type)
    if instance is None:
        return HTMLResponse(
            f"<h1>n/a</h1><p>{subdomain} is the base harness, not an instance — "
            f"nothing to pin.  Visit a slug variant like "
            f"<code>{subdomain}-myproject.{BASE_DOMAIN}</code> first.</p>",
            status_code=400,
        )
    name = _container_for(harness_type, instance)
    if name not in instances:
        raise HTTPException(404, f"instance {name} unknown — visit / first to create it")
    instances[name]["pinned"] = pinned
    _instances_save()
    state = "pinned (kept forever)" if pinned else f"unpinned (retention {RETENTION_DAYS}d)"
    return HTMLResponse(
        f"<h1>{state}</h1><p>{name}</p>"
        f'<p><a href="/">back to terminal</a></p>',
        status_code=200,
    )


def _harness_type_of(name: str) -> str | None:
    """Map a container name (harness-claude / harness-claude-blog) to its harness
    type, or None when the name isn't a managed harness container."""
    if not name.startswith(CONTAINER_PREFIX):
        return None
    head = name[len(CONTAINER_PREFIX):].split("-", 1)[0]
    return head if head in HARNESSES else None


def _terminal_busy(container, port: int) -> bool:
    """True when a client holds an ESTABLISHED TCP connection to the harness's
    serving port (ttyd, or the web UI for OpenHands/Kilo).

    Caddy proxies the browser terminal's websocket straight to
    harness-<type>:<port>, and a websocket only triggers /verify once at connect
    — so a long-lived session looks 'idle' to a timestamp-only tracker and would
    be killed mid-use.  Reading /proc/net/tcp{,6} (always present in a Linux
    container, no extra tooling needed) is the reliable 'visitor present' signal.
    On any error we report not-busy and let the /verify timestamp decide.
    """
    hexport = "%04X" % port
    try:
        res = container.exec_run(
            ["sh", "-c", "cat /proc/net/tcp /proc/net/tcp6 2>/dev/null"])
        out = (res.output or b"").decode("latin-1", "replace")
    except Exception as e:
        log.debug("connection check failed for %s: %s", container.name, e)
        return False
    for line in out.splitlines():
        parts = line.split()
        if len(parts) < 4:
            continue
        local, state = parts[1], parts[3]
        # state 01 = TCP_ESTABLISHED; `local` is HEXIP:HEXPORT.
        if state == "01" and local.upper().endswith(":" + hexport):
            return True
    return False


async def _idle_sweep() -> None:
    """Stop harness containers with no connected client for IDLE_TIMEOUT_MIN.

    Reconciles against the *actually-running* harness containers each pass rather
    than only the in-memory last_seen map.  That is the bug fix: containers
    started by docker-compose, or still up from before the last auth-service
    restart (which wipes last_seen), were never in the map and so never stopped.
    Now every running harness is tracked; a container is stopped only once it has
    had no client connection for the full timeout.  Stopping frees RAM but keeps
    the workspace volume — the next visit restarts it (files, not the tmux
    session, intact) via _ensure_running.
    """
    if IDLE_TIMEOUT_MIN <= 0:
        log.info("idle sweep disabled (IDLE_TIMEOUT_MIN=0)")
        return
    timeout_s = IDLE_TIMEOUT_MIN * 60
    while True:
        await asyncio.sleep(60)
        now = time.monotonic()
        try:
            running = docker_client.containers.list(
                filters={"name": CONTAINER_PREFIX, "status": "running"})
        except docker.errors.APIError as e:
            log.warning("idle sweep: container list failed: %s", e)
            continue
        alive: set[str] = set()
        for container in running:
            name = container.name
            htype = _harness_type_of(name)
            if htype is None:
                continue  # not a managed harness container
            alive.add(name)
            if _terminal_busy(container, _harness_port(htype)):
                last_seen[name] = now  # active visitor → keep alive
                if name in instances:
                    instances[name]["last_seen_ts"] = time.time()
                continue
            ts = last_seen.get(name)
            if ts is None:
                last_seen[name] = now  # first sighting → start its idle clock
                continue
            if now - ts >= timeout_s:
                log.info("stopping %s after %ds with no connected client",
                         name, int(now - ts))
                try:
                    container.stop(timeout=5)
                except Exception as e:
                    log.warning("failed to stop %s: %s", name, e)
                last_seen.pop(name, None)
        # Forget bookkeeping for containers that are no longer running.
        for name in [n for n in last_seen if n not in alive]:
            last_seen.pop(name, None)


async def _retention_sweep() -> None:
    """Delete per-instance containers + volumes after RETENTION_DAYS of inactivity.

    Only affects tracked instances (the ones the auth-service created).  The
    base 13 harnesses are owned by docker-compose and never touched.  Pinned
    instances are also exempt — operator opts them in via /pin.
    """
    if RETENTION_DAYS <= 0:
        log.info("retention sweep disabled (RETENTION_DAYS=0)")
        return
    cutoff_s = RETENTION_DAYS * 86400
    # Sweep every hour; 7 days of unpinned silence triggers cleanup.
    while True:
        await asyncio.sleep(3600)
        now = time.time()
        for name, meta in list(instances.items()):
            if meta.get("pinned"):
                continue
            last = meta.get("last_seen_ts", 0)
            if now - last < cutoff_s:
                continue
            age_days = (now - last) / 86400
            log.info("retention: removing %s (idle %.1fd, exceeds %dd)",
                     name, age_days, RETENTION_DAYS)
            try:
                docker_client.containers.get(name).remove(force=True)
            except NotFound:
                pass
            except Exception as e:
                log.warning("could not remove container %s: %s", name, e)
            harness_type = meta.get("harness_type", "")
            short = name[len(CONTAINER_PREFIX):]  # e.g., 'claude-blog'
            if harness_type and short.startswith(harness_type + "-"):
                instance = short[len(harness_type) + 1:]
                try:
                    docker_client.volumes.get(_volume_for(harness_type, instance)).remove()
                except NotFound:
                    pass
                except Exception as e:
                    log.warning("could not remove volume for %s: %s", name, e)
            instances.pop(name, None)
            last_seen.pop(name, None)
        _instances_save()


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
    log.info("Master login (JWT_SECRET works on every subdomain + every instance):")
    log.info(sep)
    log.info("  cookie domain is .%s — log in once on ANY subdomain, all unlocked", BASE_DOMAIN)
    log.info(sep)
    log.info("Base harnesses (always present, no auto-cleanup):")
    log.info(sep)
    for h in HARNESSES:
        log.info("  https://%s.%s/?token=%s", h, BASE_DOMAIN, JWT_SECRET)
    log.info(sep)
    cap = f"max {MAX_INSTANCES_PER_HARNESS}/harness" if MAX_INSTANCES_PER_HARNESS > 0 else "uncapped"
    log.info("Multi-instance pattern (%s, idle-stop %dmin) — visit any URL of this", cap, IDLE_TIMEOUT_MIN)
    log.info("shape to spin up a fresh isolated container + workspace volume")
    log.info("(auto-cleanup after %dd of no activity unless you /pin it):", RETENTION_DAYS)
    log.info(sep)
    for h in sorted(MULTI_INSTANCE_HARNESSES):
        log.info("  https://%s-<your-slug>.%s/?token=%s", h, BASE_DOMAIN, JWT_SECRET)
    log.info(sep)
    if instances:
        log.info("Currently tracked instances (use /pin and /unpin to manage):")
        log.info(sep)
        for name, meta in sorted(instances.items()):
            idle_days = (time.time() - meta.get("last_seen_ts", time.time())) / 86400
            tag = "PINNED" if meta.get("pinned") else f"idle {idle_days:.1f}d / {RETENTION_DAYS}d"
            log.info("  %-40s [%s]", name, tag)
        log.info(sep)


@app.on_event("startup")
async def _startup() -> None:
    _instances_load()
    _autofill_tokens_and_log_urls()
    asyncio.create_task(_idle_sweep())
    asyncio.create_task(_retention_sweep())
    asyncio.create_task(_free_models_sweep())


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

# ── Free-model catalog (dynamic fallback list) ────────────────────────────────
# OpenRouter publishes its full model list (public, no auth) at /api/v1/models.
# We periodically fetch it, keep only the *free* (zero-priced) models that
# advertise tool-calling, and use that subset two ways:
#
#   1. As the ordered `models` fallback array on every upstream request, so a
#      rate-limited or deprecated primary transparently rolls over to the next
#      free model — OpenRouter's native model-routing does the failover.
#   2. As the catalog returned by GET /v1/models, so OpenAI-compatible harness
#      pickers list exactly the free models, self-updating as OpenRouter adds or
#      retires them — no manual catalog maintenance.
#
# Only free models ever enter the list; paid models are never added as fallback.
OPENROUTER_MODELS_URL = "https://openrouter.ai/api/v1/models"
PRIMARY_MODEL = os.environ.get("MODEL_NAME", "")
FREE_FALLBACK = os.environ.get("FREE_FALLBACK", "1") not in ("0", "false", "False", "")
FREE_MODELS_REFRESH_MIN = int(os.environ.get("FREE_MODELS_REFRESH_MIN", "60"))
FREE_MODELS_LIMIT = int(os.environ.get("FREE_MODELS_LIMIT", "3"))  # cap on fallback array length
# OpenRouter rejects a `models` array longer than 3 items
# ("'models' array must have 3 items or fewer"), so keep this <= 3.
# By default the catalog keeps only tool-calling models, since agentic harnesses
# need tools.  Set FREE_REQUIRE_TOOLS=0 to surface *every* free model in the
# pickers (e.g. to drive a chat-only model by hand) — those models simply can't
# call tools.  Pair it with FREE_FALLBACK=0 so a hand-picked model is used
# verbatim instead of being silently rolled over to another free model.
FREE_REQUIRE_TOOLS = os.environ.get("FREE_REQUIRE_TOOLS", "1") not in ("0", "false", "False", "")

# Claude Code's gateway model discovery only adds models whose id begins with
# "claude"/"anthropic" to the /model picker, so /anthropic/v1/models exposes free
# models under this prefix and the Anthropic proxy strips it back off.
GATEWAY_MODEL_PREFIX = "anthropic/"

# Caches populated by _refresh_free_models().  `_free_model_ids` is the ordered
# id list (fallback array source); `_free_models_catalog` holds OpenAI-shaped
# model dicts served by GET /v1/models.
_free_model_ids: list[str] = []
_free_models_catalog: list[dict] = []
_free_models_ts: float = 0.0


def _is_free(pricing: dict) -> bool:
    """A model is free only when both prompt and completion cost nothing."""
    if not isinstance(pricing, dict):
        return False

    def _zero(v) -> bool:
        try:
            return float(v) == 0.0
        except (TypeError, ValueError):
            return False

    return _zero(pricing.get("prompt")) and _zero(pricing.get("completion"))


async def _refresh_free_models() -> None:
    """Fetch OpenRouter's catalog and cache the free, tool-capable subset."""
    global _free_model_ids, _free_models_catalog, _free_models_ts
    key = os.environ.get("PROVIDER_API_KEY")
    headers = {"Authorization": f"Bearer {key}"} if key else {}
    try:
        resp = await _PROXY_CLIENT.get(OPENROUTER_MODELS_URL, headers=headers)
        resp.raise_for_status()
        models = resp.json().get("data", []) or []
    except Exception as e:
        log.warning("free-model catalog refresh failed: %s", e)
        return

    ids: list[str] = []
    catalog: list[dict] = []
    for m in models:
        mid = m.get("id")
        if not mid or not _is_free(m.get("pricing", {})):
            continue
        # Tool-calling models are required for agentic work, so by default we keep
        # only those (see the proxy note below about OpenRouter's tool routing).
        # FREE_REQUIRE_TOOLS=0 lists every free model instead.
        if FREE_REQUIRE_TOOLS and "tools" not in (m.get("supported_parameters") or []):
            continue
        ids.append(mid)
        catalog.append({
            "id": mid,
            "object": "model",
            "created": int(m.get("created", 0) or 0),
            "owned_by": mid.split("/")[0] if "/" in mid else "openrouter",
            "context_length": m.get("context_length"),
        })

    if not ids:
        log.warning("free-model catalog: 0 free tool-capable models found; keeping previous list")
        return

    _free_model_ids = ids
    _free_models_catalog = catalog
    _free_models_ts = time.time()
    log.info("free-model catalog: %d free tool-capable models", len(ids))


async def _free_models_sweep() -> None:
    """Refresh the catalog at startup and every FREE_MODELS_REFRESH_MIN."""
    await _refresh_free_models()
    if FREE_MODELS_REFRESH_MIN <= 0:
        return
    while True:
        await asyncio.sleep(FREE_MODELS_REFRESH_MIN * 60)
        await _refresh_free_models()


def _fallback_models(primary: str) -> list[str]:
    """Ordered routing list: primary first, then free models (capped)."""
    out = [primary] if primary else []
    for mid in _free_model_ids:
        if mid == primary:
            continue
        if len(out) >= FREE_MODELS_LIMIT:
            break
        out.append(mid)
    return out

_FINISH_TO_STOP = {
    "stop": "end_turn",
    "length": "max_tokens",
    "tool_calls": "tool_use",
    "function_call": "tool_use",
    "content_filter": "stop_sequence",
}


def _normalize_schema(node):
    """In-place fix of a JSON-Schema fragment for strict validators — notably
    Google Gemini (reached via OpenRouter), which 400s with
    `predicate failed: $type == Type.ARRAY` when a property carries `items`
    without `type: "array"`, and which also requires every array to declare
    `items`.  Both transforms keep the schema valid JSON Schema, so lenient
    providers are unaffected.  Walks every place a subschema can nest.
    """
    if isinstance(node, list):
        for item in node:
            _normalize_schema(item)
        return node
    if not isinstance(node, dict):
        return node
    props = node.get("properties")
    if isinstance(props, dict):
        for v in props.values():
            _normalize_schema(v)
    for key in ("items", "additionalProperties", "not"):
        if isinstance(node.get(key), dict):
            _normalize_schema(node[key])
    for key in ("anyOf", "oneOf", "allOf", "prefixItems"):
        if isinstance(node.get(key), list):
            for v in node[key]:
                _normalize_schema(v)
    defs = node.get("$defs") or node.get("definitions")
    if isinstance(defs, dict):
        for v in defs.values():
            _normalize_schema(v)
    # `items` is only meaningful on arrays; some tool schemas omit/mistype it.
    if "items" in node and node.get("type") != "array":
        node["type"] = "array"
    # Gemini rejects an array with no `items`; give it a permissive default.
    if node.get("type") == "array" and "items" not in node:
        node["items"] = {"type": "string"}
    return node


def _sanitize_tools(tools):
    """Normalize each tool's parameter schema for cross-provider compatibility."""
    if not isinstance(tools, list):
        return tools
    for t in tools:
        fn = t.get("function") if isinstance(t, dict) else None
        if isinstance(fn, dict) and isinstance(fn.get("parameters"), dict):
            _normalize_schema(fn["parameters"])
    return tools


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
        out["tools"] = _sanitize_tools([
            {
                "type": "function",
                "function": {
                    "name": t.get("name"),
                    "description": t.get("description", ""),
                    "parameters": t.get("input_schema") or {"type": "object", "properties": {}},
                },
            }
            for t in tools
        ])

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


def _norm_model(m: str) -> str:
    """Strip the :free/:nitro variant tag for model-identity comparison."""
    return (m or "").split(":")[0]


def _model_switched(requested: str, served: str) -> bool:
    """True only when `served` is a genuinely different model than `requested`.

    Ignores variant tags and dated-snapshot suffixes — OpenRouter serves e.g.
    `google/gemma-4-31b-it:free` as `google/gemma-4-31b-it-20260402:free`, which
    is the same model and must NOT be reported as a fallback.
    """
    if not requested or not served:
        return False
    r, s = _norm_model(requested), _norm_model(served)
    return not (s == r or s.startswith(r) or r.startswith(s))


def _switch_notice(requested: str, served: str) -> str:
    """One-line, human-visible note prepended to a reply when fallback kicked in."""
    return f"↳ {requested} unavailable\n  → answered by {served}\n\n"


def _openai_to_anthropic_response(data: dict, requested: str = "") -> dict:
    """OpenAI chat.completion → Anthropic /v1/messages non-streaming response."""
    choice = (data.get("choices") or [{}])[0]
    msg = choice.get("message") or {}

    content: list = []
    served = data.get("model", "")
    if _model_switched(requested, served):
        log.warning("fallback: requested %s -> served %s", requested, served)
        content.append({"type": "text", "text": _switch_notice(requested, served)})
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

    text_block_open = False
    text_block_index = -1
    # tool_call index (from OpenAI) → block index in Anthropic stream
    tool_blocks: dict[int, int] = {}
    next_block_index = 0
    final_finish: str | None = None
    final_usage: dict = {}
    started = False

    def _message_start(served: str) -> bytes:
        return sse("message_start", {
            "type": "message_start",
            "message": {
                "id": msg_id,
                "type": "message",
                "role": "assistant",
                "model": served,
                "content": [],
                "stop_reason": None,
                "stop_sequence": None,
                "usage": {"input_tokens": 0, "output_tokens": 0},
            },
        })

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

        # Emit message_start lazily, using the model the upstream actually
        # served — so a fallback is reported truthfully, not as the requested
        # model.  If it differs, lead with a one-line, visible switch notice.
        if not started:
            served = chunk.get("model") or model
            yield _message_start(served)
            if _model_switched(model, served):
                log.warning("fallback (stream): requested %s -> served %s", model, served)
                ni = next_block_index
                next_block_index += 1
                yield sse("content_block_start", {
                    "type": "content_block_start",
                    "index": ni,
                    "content_block": {"type": "text", "text": ""},
                })
                yield sse("content_block_delta", {
                    "type": "content_block_delta",
                    "index": ni,
                    "delta": {"type": "text_delta", "text": _switch_notice(model, served)},
                })
                yield sse("content_block_stop", {"type": "content_block_stop", "index": ni})
            started = True

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

    # If the upstream sent no data chunks, still emit a valid message envelope.
    if not started:
        yield _message_start(model)

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
    # Gateway model discovery (CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY) only
    # adds models whose id starts with claude/anthropic to the picker, so
    # /anthropic/v1/models advertises free models as "anthropic/<real-id>".
    # Strip that synthetic prefix back to the real OpenRouter id here.  No free
    # model id genuinely starts with "anthropic/", so this is unambiguous.
    if model.startswith(GATEWAY_MODEL_PREFIX):
        model = model[len(GATEWAY_MODEL_PREFIX):]
        payload["model"] = model
    msg_id = "msg_" + str(int(time.time() * 1000))

    openai_body = _anthropic_to_openai_request(payload)

    # Roll over to other free models on rate-limit / deprecation.  Primary
    # (whatever Claude Code sent, i.e. MODEL_NAME) stays first; only free,
    # tool-capable models follow — OpenRouter routes through them in order.
    if FREE_FALLBACK and _free_model_ids:
        openai_body["models"] = _fallback_models(model)

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
        translated = _openai_to_anthropic_response(data, model)
        return Response(content=json.dumps(translated), status_code=200,
                        media_type="application/json")
    except Exception as e:
        log.exception("translation failed: %s", e)
        return Response(content=upstream.content, status_code=502,
                        media_type=upstream.headers.get("content-type", "application/json"))


# ── OpenAI-compat passthrough (for OpenAI-protocol harnesses) ──────────────────
# Aider, OpenCode, gptme, Goose, Qwen, Codex, Pi, … speak OpenAI natively, so no
# translation is needed — we just relay to OpenRouter while (a) serving a
# free-only /v1/models catalog to their pickers and (b) injecting the same free
# fallback array as the Anthropic proxy.  Point a harness here with
# OPENAI_API_BASE/OPENAI_BASE_URL=http://harnesses-auth:8080/v1 (or
# OPENAI_HOST=http://harnesses-auth:8080).  Both /v1/* and /openai/v1/* work.

@app.get("/anthropic/v1/models")
def list_models_anthropic() -> dict:
    """Anthropic-format catalog for Claude Code's gateway model discovery.

    Claude Code queries ${ANTHROPIC_BASE_URL}/v1/models at startup when
    CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY=1 and adds entries whose id starts
    with claude/anthropic to the /model picker, using `display_name` as the label.
    We prefix each free id with GATEWAY_MODEL_PREFIX so it passes that filter and
    show the real id as the display name; proxy_messages strips the prefix back.
    """
    ids = _free_model_ids or ([PRIMARY_MODEL] if PRIMARY_MODEL else [])
    data = [
        {"type": "model", "id": GATEWAY_MODEL_PREFIX + mid, "display_name": mid}
        for mid in ids
    ]
    log.info("gateway model discovery: served %d models", len(data))
    return {"object": "list", "data": data}


@app.get("/v1/models")
@app.get("/openai/v1/models")
def list_models() -> dict:
    """Free, tool-capable catalog in OpenAI list shape.

    Falls back to the configured primary model if the catalog hasn't populated
    yet (startup race / OpenRouter unreachable), so pickers always show ≥1.
    """
    data = _free_models_catalog or (
        [{"id": PRIMARY_MODEL, "object": "model", "created": 0, "owned_by": "openrouter"}]
        if PRIMARY_MODEL else []
    )
    return {"object": "list", "data": data}


@app.api_route("/v1/chat/completions", methods=["POST"])
@app.api_route("/openai/v1/chat/completions", methods=["POST"])
async def proxy_chat_completions(request: Request) -> Response:
    body = await request.body()
    try:
        payload = json.loads(body) if body else {}
    except json.JSONDecodeError:
        raise HTTPException(status_code=400, detail="invalid JSON")

    # Inject the free fallback array unless the caller already set one.  The
    # harness-supplied model stays primary.
    if FREE_FALLBACK and _free_model_ids and "models" not in payload:
        payload["models"] = _fallback_models(payload.get("model", ""))

    # Normalize tool schemas so strict providers (Google Gemini) don't 400.
    if isinstance(payload.get("tools"), list):
        _sanitize_tools(payload["tools"])

    streaming = bool(payload.get("stream"))
    auth_hdr = (
        request.headers.get("authorization")
        or (f"Bearer {request.headers.get('x-api-key')}" if request.headers.get("x-api-key") else None)
    )
    fwd_headers = {"Content-Type": "application/json"}
    if auth_hdr:
        fwd_headers["Authorization"] = auth_hdr

    upstream_request = _PROXY_CLIENT.build_request(
        "POST", OPENROUTER_OPENAI, json=payload, headers=fwd_headers,
    )

    if streaming:
        upstream = await _PROXY_CLIENT.send(upstream_request, stream=True)
        if upstream.status_code >= 400:
            text = await upstream.aread()
            await upstream.aclose()
            log.warning("openai passthrough %d: %s", upstream.status_code, text[:300])
            return Response(content=text, status_code=upstream.status_code,
                            media_type=upstream.headers.get("content-type", "application/json"))

        requested = payload.get("model", "")

        async def gen():
            # Buffer only until the first real `data:` event arrives (OpenRouter
            # often leads with `: OPENROUTER PROCESSING` comment lines), read the
            # model it actually served, and — if that differs from the requested
            # model — inject a visible switch-notice chunk before relaying the
            # rest byte-for-byte.
            buf = b""
            head_done = False

            def _served_from(buffer: bytes):
                """First served model in any complete data: event, or None if
                none has fully arrived yet (keep buffering)."""
                for ev in buffer.split(b"\n\n"):
                    for line in ev.split(b"\n"):
                        if line.startswith(b"data: "):
                            pl = line[6:].strip()
                            if not pl or pl == b"[DONE]":
                                return ""
                            try:
                                return (json.loads(pl) or {}).get("model", "") or ""
                            except json.JSONDecodeError:
                                return None  # partial JSON — wait for more
                return None

            try:
                async for chunk in upstream.aiter_raw():
                    if head_done:
                        yield chunk
                        continue
                    buf += chunk
                    if b"\n\n" not in buf:
                        continue
                    served = _served_from(buf)
                    if served is None:
                        continue  # only comments / partial so far — keep buffering
                    head_done = True
                    if _model_switched(requested, served):
                        log.warning("fallback (stream): requested %s -> served %s", requested, served)
                        notice = {
                            "id": "", "object": "chat.completion.chunk", "model": served,
                            "choices": [{"index": 0, "finish_reason": None, "delta": {
                                "role": "assistant", "content": _switch_notice(requested, served)}}],
                        }
                        yield ("data: " + json.dumps(notice) + "\n\n").encode()
                    yield buf
                    buf = b""
                if buf:
                    yield buf
            finally:
                await upstream.aclose()

        return StreamingResponse(
            gen(), status_code=200,
            media_type=upstream.headers.get("content-type", "text/event-stream"),
        )

    upstream = await _PROXY_CLIENT.send(upstream_request)
    if upstream.status_code >= 400:
        log.warning("openai passthrough %d: %s", upstream.status_code, upstream.text[:300])
        return Response(content=upstream.content, status_code=upstream.status_code,
                        media_type=upstream.headers.get("content-type", "application/json"))

    # Success: surface a fallback (served ≠ requested) with a leading notice.
    requested = payload.get("model", "")
    try:
        data = upstream.json()
        served = data.get("model", "")
        if _model_switched(requested, served):
            log.warning("fallback: requested %s -> served %s", requested, served)
            ch = (data.get("choices") or [{}])[0]
            msg = ch.get("message")
            if isinstance(msg, dict):
                msg["content"] = _switch_notice(requested, served) + (msg.get("content") or "")
        return Response(content=json.dumps(data), status_code=200,
                        media_type="application/json")
    except (ValueError, json.JSONDecodeError):
        return Response(content=upstream.content, status_code=upstream.status_code,
                        media_type=upstream.headers.get("content-type", "application/json"))
