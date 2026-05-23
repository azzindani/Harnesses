.PHONY: help tokens build pull up down logs restart router-up router-reload validate

SHELL := /bin/bash
ENV    := .env
PYTHON ?= python3

help:
	@grep -E '^[a-zA-Z_-]+:.*?##' $(MAKEFILE_LIST) | awk 'BEGIN {FS=":.*?##"} {printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'

tokens: ## Print TOKEN_* lines using JWT_SECRET from .env
	@set -a; source $(ENV); set +a; \
	  $(PYTHON) scripts/generate-tokens.py

tokens-write: ## Regenerate TOKEN_* in .env in-place (keeps other vars intact)
	@set -a; source $(ENV); set +a; \
	  tmp=$$($(PYTHON) scripts/generate-tokens.py) || exit 1; \
	  awk -v new="$$tmp" 'BEGIN{n=split(new,L,"\n"); for(i=1;i<=n;i++){split(L[i],kv,"="); M[kv[1]]=L[i]}} \
	    {if(match($$0,/^TOKEN_[A-Z_]+=/)){k=substr($$0,1,RLENGTH-1); if(M[k]){print M[k]; delete M[k]; next}} print} \
	    END{for(k in M) print M[k]}' $(ENV) > $(ENV).new && mv $(ENV).new $(ENV)
	@echo "rotated tokens in $(ENV)"

build: ## Build base + all harness images
	docker compose build harness-base
	docker compose build

up: ## Start auth (harnesses come up on demand via the auth service)
	docker compose up -d auth

down: ## Stop everything
	docker compose down

logs: ## Tail auth + harness logs
	docker compose logs -f --tail=100

restart: down up ## Restart auth service

router-up: ## Apply caddy-router compose (after editing its networks list)
	cd /root/caddy-router && docker compose up -d

router-reload: ## Hot-reload Caddy without restarting the container
	docker exec caddy-router caddy reload --config /etc/caddy/Caddyfile

validate: ## Smoke-test JWT issuance + auth /verify
	@set -a; source $(ENV); set +a; \
	  echo "auth healthz:"; \
	  docker exec harnesses-auth curl -sS http://localhost:8080/healthz; echo; \
	  echo "verify (no cookie, should be 401):"; \
	  docker exec harnesses-auth curl -sS -o /dev/null -w '%{http_code}\n' \
	    "http://localhost:8080/verify?harness=aider"
