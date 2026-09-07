#!/usr/bin/env bash
# sg-deploy/deploy.sh — a two-connection SiteGround deploy, run FROM A GITHUB RUNNER.
#
# Reads deploy.json in the current directory (the "shared-driver" manifest that the
# Luhwah family's luhwah-ui/tools/deploy-plan.ps1 + deploy.ps1 read; this is a
# faithful bash port of both, 2026-09-07):
#
#   {
#     "site":         "app.example.com",     REQUIRED — remote base www/<site>, docroot www/<site>/public_html
#     "sshUser":      "u####-xxxx@ssh.host", the account (the SG_SSH_USER env var overrides)
#     "exclude":      ["a.php"],             tracked files that must NOT ship
#     "extraDirs":    ["js", "shell"],       tracked dirs shipped whole
#     "pingResource": "ping",                smoke: api.php?resource=<this> must answer 200; absent → the site root
#     "canaryPath":   "data/settings.json"   must NOT answer 200 — the leak check
#   }
#
# The upload set is derived from `git ls-files`: root *.php/*.css/*.js/*.html plus
# version.json and .htaccess, every api/<file>, and the extraDirs — minus the excludes
# and the driver's own files. version.json is rewritten from the nearest git tag so
# the site publishes what it runs. Two connections: one scp of a tarball, one ssh that
# extracts (api.php LAST, so the router never require()s a missing handler), lints
# every shipped .php server-side, and smoke-tests. The smoke test is a GATE: the job
# fails if the ping is not 200 or the canary answers 200.
#
# Modes:
#   (default)        deploy — 2 connections
#   -DryRun/-WhatIf  print the plan, connect to nothing
#   -Verify          ONE connection: the smoke test only, nothing uploaded. Proves the
#                    key, the host and the site are all answering — use it first on
#                    every new hosting account.
#   -SkipLint        skip the server-side php -l sweep
#
# Environment: SSH_KEY_FILE (required unless dry run), SG_SSH_USER, SSH_KNOWN_HOSTS_FILE
# (optional; when set the host key is pinned), APP (name for the archive; default cwd).
#
# sg-connections: 2   (one scp, one ssh — only if run LOCALLY; on a runner it costs the local ration nothing)
set -euo pipefail
shopt -s nocasematch   # PowerShell's -match / -in are case-insensitive; keep parity

DRY_RUN="${DRY_RUN:-false}"; VERIFY="${VERIFY:-false}"; SKIP_LINT="${SKIP_LINT:-false}"
for a in "$@"; do
  case "$a" in
    -DryRun|-WhatIf|--dry-run) DRY_RUN=true ;;
    -Verify|--verify)          VERIFY=true ;;
    -SkipLint|--skip-lint)     SKIP_LINT=true ;;
    *) echo "::error::unknown argument: $a"; exit 2 ;;
  esac
done
APP="${APP:-$(basename "$PWD")}"
M=deploy.json

need() { command -v "$1" >/dev/null 2>&1 || { echo "::error::missing tool: $1"; exit 1; }; }
need jq; need git; need tar
[ -f "$M" ] || { echo "::error::no $M in $PWD — this is not a shared-driver app"; exit 1; }
# jq on Windows writes CRLF; a stray \r turns "admin" into a directory that does not
# exist. Strip it everywhere, so a local dry run on a laptop reads like the runner.
J() { jq -r "$@" | tr -d '\r'; }

# ── The TARGET: everything derivable from the manifest alone ─────────────────
SITE=$(J '.site // empty' "$M")
[ -n "$SITE" ] || { echo "::error::$M is missing 'site'"; exit 1; }
SSH_USER="${SG_SSH_USER:-$(J '.sshUser // empty' "$M")}"
PORT=18765
BASE="www/$SITE"                     # home-relative, never ~/ — a quoted ~ is not expanded remotely
DOCROOT="www/$SITE/public_html"
PING_RES=$(J '.pingResource // empty' "$M")
CANARY=$(J '.canaryPath // "data/settings.json"' "$M")
CB="$RANDOM$RANDOM"
if [ -n "$PING_RES" ]; then PING_URL="https://$SITE/api.php?resource=$PING_RES&cb=$CB"; else PING_URL="https://$SITE/?cb=$CB"; fi

# ── Connection setup (deploy and verify) ─────────────────────────────────────
ssh_setup() {
  [ -n "$SSH_USER" ] || { echo "::error::no SSH user — set the SG_SSH_USER secret (or deploy.json sshUser)"; exit 1; }
  : "${SSH_KEY_FILE:?SSH_KEY_FILE must point at the private key}"
  [ -s "$SSH_KEY_FILE" ] || { echo "::error::SSH key file is empty or missing"; exit 1; }
  SSH_OPTS=(-i "$SSH_KEY_FILE" -o BatchMode=yes -o IdentitiesOnly=yes -o ConnectTimeout=30
            -o ServerAliveInterval=30 -o ServerAliveCountMax=4 -o NumberOfPasswordPrompts=0)
  if [ -n "${SSH_KNOWN_HOSTS_FILE:-}" ] && [ -s "$SSH_KNOWN_HOSTS_FILE" ]; then
    SSH_OPTS+=(-o StrictHostKeyChecking=yes -o "UserKnownHostsFile=$SSH_KNOWN_HOSTS_FILE")
  else
    echo "::warning::no SG_KNOWN_HOSTS variable — the host key is accepted on first use (no pinning)"
    SSH_OPTS+=(-o StrictHostKeyChecking=accept-new)
  fi
}

# The smoke test, as a remote script. Shared by deploy (after the extract) and verify.
smoke_script() {
  echo 'set +e'
  printf 'P=$(curl -s -o /dev/null -w "%%{http_code}" %q); echo "ping HTTP $P  %s"\n' "$PING_URL" "$PING_URL"
  printf 'C=$(curl -s -o /dev/null -w "%%{http_code}" %q); echo "canary HTTP $C  %s (want 403/404)"\n' "https://$SITE/$CANARY" "https://$SITE/$CANARY"
  echo 'echo "server saw this connection arrive from ${SSH_CONNECTION%% *}"'
  echo '[ "$P" = 200 ] || { echo "::error::ping did not answer 200"; exit 1; }'
  echo '[ "$C" != 200 ] || { echo "::error::CANARY ANSWERED 200 — the data dir is web-readable"; exit 1; }'
}

if [ "$VERIFY" = true ]; then
  echo "== $APP verify ($SITE) — one connection, nothing uploaded =="
  ssh_setup
  R=$(mktemp -t remote-XXXXXX.sh); smoke_script > "$R"
  ssh -p "$PORT" "${SSH_OPTS[@]}" "$SSH_USER" 'bash -s' < "$R"; rm -f "$R"
  echo "== $APP verified (1 connection) =="
  exit 0
fi

echo "== $APP deploy ($SITE)$([ "$DRY_RUN" = true ] && echo ' [DRY RUN — nothing transferred, nothing connected]') =="

# ── The PLAN: the upload set, derived from git — what is versioned is what ships ─
mapfile -t TRACKED < <(git ls-files)
mapfile -t EXCL < <(printf '%s\n' deploy.json dashavie.json deploy.ps1 check_php_braces.py; J '.exclude[]? // empty' "$M")
excluded() { local x; for x in "${EXCL[@]}"; do [[ "$1" == "$x" ]] && return 0; done; return 1; }

ROOT=(); API=()
for f in "${TRACKED[@]}"; do
  if [[ "$f" =~ ^[^/]+\.(php|css|js|html)$ || "$f" == version.json || "$f" == .htaccess ]]; then
    excluded "$f" || ROOT+=("$f")
  fi
  [[ "$f" =~ ^api/[^/]+$ ]] && API+=("$f")
done

# version.json from the latest tag — the site publishes what it runs
TAG=$(git describe --tags --abbrev=0 2>/dev/null || true)
if [ -n "$TAG" ]; then
  WANT=$(printf '{"version":"%s"}' "$TAG")
  HAVE=$(cat version.json 2>/dev/null || true)
  if [ "$HAVE" != "$WANT" ]; then
    echo "version.json -> $TAG$([ "$DRY_RUN" = true ] && echo '  (would be written)')"
    [ "$DRY_RUN" = true ] || printf '%s\n' "$WANT" > version.json
  fi
  has_v=false; for f in "${ROOT[@]}"; do [[ "$f" == version.json ]] && has_v=true; done
  [ $has_v = true ] || ROOT+=(version.json)
else
  echo "no git tags — version.json left alone (blank chip is graceful)"
fi

HAS_API=false; for f in "${ROOT[@]}"; do [[ "$f" == api.php ]] && HAS_API=true; done
[ $HAS_API = true ] || echo "note: no api.php in $APP (static app?)"
STAGE=("${API[@]}"); for f in "${ROOT[@]}"; do [[ "$f" == api.php ]] || STAGE+=("$f"); done
mapfile -t EXTRA < <(J '.extraDirs[]? // empty' "$M")

for f in "${STAGE[@]}"; do
  [ -f "$f" ] || { [ "$f" == version.json ] && [ "$DRY_RUN" = true ]; } || { echo "::error::Local file missing: $f"; exit 1; }
done
for d in "${EXTRA[@]}"; do [ -d "$d" ] || { echo "::error::Local dir missing: $d"; exit 1; }; done

ENTRIES=("${STAGE[@]}" "${EXTRA[@]}"); [ $HAS_API = true ] && ENTRIES+=(api.php)
PHP=(); for f in "${API[@]}" "${ROOT[@]}"; do [[ "$f" == *.php ]] && PHP+=("$f"); done

echo "tar  ${#STAGE[@]} file(s) + ${#EXTRA[@]} dir(s)$([ $HAS_API = true ] && echo ' + api.php (extracted last)')"
for f in "${STAGE[@]}"; do echo "     $f"; done
for d in "${EXTRA[@]}"; do echo "     $d/  (whole directory)"; done
echo "ping   $PING_URL"
echo "canary https://$SITE/$CANARY  (must NOT answer 200)"

if [ "$DRY_RUN" = true ]; then
  echo "dry run: nothing transferred, nothing connected"
  exit 0
fi

ssh_setup

TARBALL=$(mktemp -t "deploy-$APP-XXXXXX.tgz")
printf '%s\n' "${ENTRIES[@]}" > "$TARBALL.list"
tar -czf "$TARBALL" -T "$TARBALL.list"
rm -f "$TARBALL.list"
echo "archive: $(du -h "$TARBALL" | cut -f1)"
REMOTE_TAR="$BASE/deploy-$APP.tgz"          # beside public_html, never inside it

# Boundary: every remote path must carry the manifest's site (the driver's own rule)
for p in "$REMOTE_TAR" "$DOCROOT"; do
  [[ "$p" == *"$SITE"* ]] || { echo "::error::REFUSING: remote path '$p' is outside $SITE"; exit 1; }
done

# ── Connection 1 of 2: the archive goes up ───────────────────────────────────
echo "-- connection 1 of 2: scp $(basename "$TARBALL") -> $REMOTE_TAR"
scp -P "$PORT" "${SSH_OPTS[@]}" "$TARBALL" "$SSH_USER:$REMOTE_TAR"
rm -f "$TARBALL"

# ── Connection 2 of 2: extract (api.php last), lint, smoke, tidy ─────────────
R=$(mktemp -t remote-XXXXXX.sh)
{
  echo 'set -e'
  printf 'D=%q; T=%q\n' "$DOCROOT" "$REMOTE_TAR"
  echo 'mkdir -p "$D/api"'
  if [ $HAS_API = true ]; then
    echo 'tar -xzf "$T" -C "$D" --exclude="api.php"'
    echo 'tar -xzf "$T" -C "$D" api.php'
  else
    echo 'tar -xzf "$T" -C "$D"'
  fi
  echo 'rm -f "$T"'
  echo 'echo "extracted into $D"'
  if [ "$SKIP_LINT" != true ]; then
    for f in "${PHP[@]}"; do printf 'php -l %q\n' "$DOCROOT/$f"; done
  fi
  smoke_script
} > "$R"
echo "-- connection 2 of 2: extract (api.php last), lint ${#PHP[@]} php file(s), smoke"
ssh -p "$PORT" "${SSH_OPTS[@]}" "$SSH_USER" 'bash -s' < "$R"
rm -f "$R"

echo "== $APP done (2 connections) =="
