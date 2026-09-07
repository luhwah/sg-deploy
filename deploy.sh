#!/usr/bin/env bash
# sg-deploy/deploy.sh — a two-connection SiteGround deploy, run FROM A GITHUB RUNNER.
#
# Reads deploy.json in the current directory and ships what git tracks. Two
# connections: one scp of the archive(s), one ssh that extracts, runs the manifest's
# server-side steps, lints every shipped PHP file and smoke-tests. The smoke test is a
# GATE: the job fails if the ping is not 200 or a canary answers 200.
#
# deploy.json — every key but `site` is optional:
#   site          "app.example.com"      remote base www/<site>, docroot www/<site>/public_html
#   sshUser       "u####-x@ssh.host"     the account (the SG_SSH_USER env var overrides)
#   shape         "manifest" | "webavie" see below
#   docroot       "public_html"          the dir under www/<site> the set lands in; "laravel" for an
#                                         app root that public_html merely symlinks into
#   srcDir        "public"               ship every tracked file under this dir into the docroot
#                                         (prefix stripped); "." ships the whole tracked tree.
#                                         Without it, the legacy rule applies:
#                                         root *.php/css/js/html + version.json + .htaccess,
#                                         every api/<file>, and the extraDirs.
#   include       ["site/**","directory/*.php"]  instead of srcDir: tracked files matching these
#                                         globs (repo-relative) form the docroot set
#   extraDirs     ["js","shell"]         legacy: tracked dirs shipped whole into the docroot
#   exclude       ["lv.js","public/assets/fonts/*.ttf"]  globs, repo-relative, never ship
#   map           {"site/":"","directory/":"api/","directory/root.htaccess":".htaccess"}
#                                         rename docroot-relative paths; longest key wins
#   extra         {"server/backup.sh":"backup.sh"}  repo file/dir -> BASE-relative destination
#                                         (outside the docroot: www/<site>/<dst>)
#   last          "api.php"              docroot-relative file extracted LAST (a router must
#                                         never require() a handler that is not there yet;
#                                         a service worker must never see stale assets)
#   versionJson   true                   write {"version":"<nearest tag>"} into the docroot
#                                         root; false for apps whose version.json is their own
#   stageScript   "tools/stage.sh"       repo script run after staging, before the tar:
#                                         env STAGE (the www/<site> mirror), DOCROOT_STAGE, TAG
#   remoteSteps   ["rm -f public_html/Default.html", ...]  run in $HOME/www/<site> after the
#                                         extract, under set -e, before the lint; $D = public_html
#   lint          "shipped" | "none"     php -l every shipped .php (default) or skip
#   pingPath      "api.php?resource=health&op=ping"  smoke URL path (cb= appended); or
#   pingResource  "ping"                 legacy: api.php?resource=<this>
#   canaryPath    "data/settings.json"   must NOT answer 200 (the leak check)
#   canaries      ["a","b"]              more of the same
#   staging       true                   webavie: pass --staging to the deploy checks
#
# shape "webavie": the site's tracked public/ is the docroot set, its tracked .engine/
# (deploy-checks.sh, migrate/ensure-admin/seed tools, migrations, starters — vendored by
# the engine's sync.ps1) travels above the docroot, a manifest + stale-file sweep over
# the two engine-owned dirs is generated, the engine digest is computed in the wire
# format deploy-checks.sh expects (and checked against EXPECT_DIGEST when set), and the
# platform's deploy-checks.sh runs at the end — a "PROBLEM(S)" line fails the job.
#
# Modes:  (default) deploy — 2 connections · -DryRun/-WhatIf — plan only, 0 · -Verify —
# smoke only, 1 · -SkipLint. webavie extras via env: MIGRATE, ENSURE_ADMIN, SEED, SEED_ALL.
#
# Environment: SSH_KEY_FILE (required unless dry run), SG_SSH_USER, SSH_KNOWN_HOSTS_FILE
# (optional; pins the host key), APP (archive/heading name; default cwd), EXPECT_DIGEST.
#
# sg-connections: 2   (one scp, one ssh — only if run LOCALLY; on a runner it costs the local ration nothing)
set -euo pipefail
shopt -s nocasematch   # PowerShell's -match / -in are case-insensitive; keep parity

DRY_RUN="${DRY_RUN:-false}"; VERIFY="${VERIFY:-false}"; SKIP_LINT="${SKIP_LINT:-false}"
MIGRATE="${MIGRATE:-false}"; ENSURE_ADMIN="${ENSURE_ADMIN:-false}"; SEED="${SEED:-false}"; SEED_ALL="${SEED_ALL:-false}"
for a in "$@"; do
  case "$a" in
    -DryRun|-WhatIf|--dry-run) DRY_RUN=true ;;
    -Verify|--verify)          VERIFY=true ;;
    -SkipLint|--skip-lint)     SKIP_LINT=true ;;
    -Migrate|--migrate)        MIGRATE=true ;;
    -EnsureAdmin|--ensure-admin) ENSURE_ADMIN=true ;;
    -Seed|--seed)              SEED=true ;;
    -SeedAll|--seed-all)       SEED_ALL=true ;;
    *) echo "::error::unknown argument: $a"; exit 2 ;;
  esac
done
APP="${APP:-$(basename "$PWD")}"
APP_DIR="$PWD"
M=deploy.json

need() { command -v "$1" >/dev/null 2>&1 || { echo "::error::missing tool: $1"; exit 1; }; }
need jq; need git; need tar; need sha256sum
[ -f "$M" ] || { echo "::error::no $M in $PWD"; exit 1; }
# jq on Windows writes CRLF; strip it so a local dry run reads like the runner.
J() { jq -r "$@" | tr -d '\r'; }

# ── The TARGET ───────────────────────────────────────────────────────────────
SITE=$(J '.site // empty' "$M"); [ -n "$SITE" ] || { echo "::error::$M is missing 'site'"; exit 1; }
SSH_USER="${SG_SSH_USER:-$(J '.sshUser // empty' "$M")}"
SHAPE=$(J '.shape // "manifest"' "$M")
PORT=18765
BASE="www/$SITE"
DOC=$(J '.docroot // "public_html"' "$M")   # the dir under www/<site> the set lands in — "laravel" when public_html is a symlink into it
SRC_DIR=$(J '.srcDir // empty' "$M")
mapfile -t INCLUDE < <(J '.include[]? // empty' "$M")
mapfile -t EXCL    < <(printf '%s\n' deploy.json dashavie.json deploy.ps1 check_php_braces.py; J '.exclude[]? // empty' "$M")
mapfile -t EXTRA_DIRS < <(J '.extraDirs[]? // empty' "$M")
mapfile -t REMOTE_STEPS < <(J '.remoteSteps[]? // empty' "$M")
LAST=$(J '.last // "api.php"' "$M")
VERSION_JSON=$(J 'if .versionJson == false then "false" else "true" end' "$M")
STAGE_SCRIPT=$(J '.stageScript // empty' "$M")
LINT=$(J '.lint // "shipped"' "$M")
PING_PATH=$(J '.pingPath // empty' "$M"); PING_RES=$(J '.pingResource // empty' "$M")
STAGING=$(J 'if .staging == true then "true" else "false" end' "$M")
declare -A MAP=(); while IFS=$'\t' read -r k v; do [ -n "$k" ] && MAP["$k"]="$v"; done < <(J '.map // {} | to_entries[] | "\(.key)\t\(.value)"' "$M")
declare -A EXTRA=(); while IFS=$'\t' read -r k v; do [ -n "$k" ] && EXTRA["$k"]="$v"; done < <(J '.extra // {} | to_entries[] | "\(.key)\t\(.value)"' "$M")
mapfile -t CANARIES < <(J '.canaries[]? // empty' "$M")
CANARY=$(J '.canaryPath // empty' "$M")
if [ -z "$CANARY" ]; then if [[ "$SHAPE" == webavie ]]; then CANARY=data/config.php; else CANARY=data/settings.json; fi; fi
CANARIES=("$CANARY" "${CANARIES[@]}")
[[ "$SHAPE" == webavie ]] && { CANARIES+=(lib/lws/site.php); SRC_DIR=public; LINT=none; }

CB="$RANDOM$RANDOM"
if   [ -n "$PING_PATH" ]; then PING_URL="https://$SITE/$PING_PATH$([[ "$PING_PATH" == *\?* ]] && echo '&' || echo '?')cb=$CB"
elif [ -n "$PING_RES" ];  then PING_URL="https://$SITE/api.php?resource=$PING_RES&cb=$CB"
else                            PING_URL="https://$SITE/?cb=$CB"; fi

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

# The smoke test as a remote script — shared by deploy (after the steps) and verify.
smoke_script() {
  echo 'set +e'
  printf 'P=$(curl -s -o /dev/null -m 20 -w "%%{http_code}" %q); echo "ping HTTP $P  %s"\n' "$PING_URL" "$PING_URL"
  echo 'BAD=0'
  local c; for c in "${CANARIES[@]}"; do
    printf 'C=$(curl -s -o /dev/null -m 20 -w "%%{http_code}" %q); echo "canary HTTP $C  %s (want 403/404)"; [ "$C" = 200 ] && BAD=1\n' "https://$SITE/$c" "https://$SITE/$c"
  done
  echo 'echo "server saw this connection arrive from ${SSH_CONNECTION%% *}"'
  echo '[ "$P" = 200 ] || { echo "::error::ping did not answer 200"; exit 1; }'
  echo '[ "$BAD" = 0 ] || { echo "::error::A CANARY ANSWERED 200 — something above the docroot or inside the engine is web-readable"; exit 1; }'
}

if [ "$VERIFY" = true ]; then
  echo "== $APP verify ($SITE) — one connection, nothing uploaded =="
  ssh_setup
  R=$(mktemp -t remote-XXXXXX.sh); smoke_script > "$R"
  ssh -p "$PORT" "${SSH_OPTS[@]}" "$SSH_USER" 'bash -s' < "$R"; rm -f "$R"
  echo "== $APP verified (1 connection) =="
  exit 0
fi

echo "== $APP deploy ($SITE, shape $SHAPE)$([ "$DRY_RUN" = true ] && echo ' [DRY RUN — nothing transferred, nothing connected]') =="

# ── The PLAN: what git tracks, selected, mapped ──────────────────────────────
mapfile -t TRACKED < <(git ls-files)
excluded() { local x; for x in "${EXCL[@]}"; do [[ "$1" == $x ]] && return 0; done; return 1; }
included() { local x; for x in "${INCLUDE[@]}"; do [[ "$1" == $x ]] && return 0; done; return 1; }

CAND=()   # "src<TAB>dst" — src repo-relative, dst docroot-relative
if [ "$SRC_DIR" = "." ]; then
  # the whole tracked tree is the app (a Laravel root, say) — excludes carry the weight
  for f in "${TRACKED[@]}"; do excluded "$f" && continue; CAND+=("$f"$'\t'"$f"); done
elif [ -n "$SRC_DIR" ]; then
  for f in "${TRACKED[@]}"; do [[ "$f" == "$SRC_DIR"/* ]] || continue; excluded "$f" && continue; CAND+=("$f"$'\t'"${f#"$SRC_DIR"/}"); done
elif [ ${#INCLUDE[@]} -gt 0 ]; then
  for f in "${TRACKED[@]}"; do included "$f" || continue; excluded "$f" && continue; CAND+=("$f"$'\t'"$f"); done
else
  for f in "${TRACKED[@]}"; do
    if [[ "$f" =~ ^[^/]+\.(php|css|js|html)$ || "$f" == version.json || "$f" == .htaccess || "$f" =~ ^api/[^/]+$ ]]; then
      excluded "$f" && continue; CAND+=("$f"$'\t'"$f"); continue
    fi
    for d in "${EXTRA_DIRS[@]}"; do [[ "$f" == "$d"/* ]] && { excluded "$f" || CAND+=("$f"$'\t'"$f"); break; }; done
  done
  for d in "${EXTRA_DIRS[@]}"; do [ -d "$d" ] || { echo "::error::Local dir missing: $d"; exit 1; }; done
fi
# map: longest key first; a key ending in / is a prefix, otherwise an exact rename
if [ ${#MAP[@]} -gt 0 ]; then
  mapfile -t MKEYS < <(printf '%s\n' "${!MAP[@]}" | awk '{ print length, $0 }' | sort -rn | cut -d' ' -f2-)
  for i in "${!CAND[@]}"; do
    src="${CAND[$i]%%$'\t'*}"; dst="${CAND[$i]#*$'\t'}"
    for k in "${MKEYS[@]}"; do
      if [[ "$k" == */ ]]; then [[ "$dst" == "$k"* ]] && { dst="${MAP[$k]}${dst#"$k"}"; break; }
      else [[ "$dst" == "$k" ]] && { dst="${MAP[$k]}"; break; }; fi
    done
    CAND[$i]="$src"$'\t'"$dst"
  done
fi
[ ${#CAND[@]} -gt 0 ] || { echo "::error::nothing selected to ship — check srcDir/include/extraDirs against git ls-files"; exit 1; }

TAG=$(git describe --tags --abbrev=0 2>/dev/null || true)

# ── Staging: a mirror of www/<site>/ ─────────────────────────────────────────
STAGE=$(mktemp -d -t "stage-$APP-XXXXXX"); DST="$STAGE/$DOC"; mkdir -p "$DST"
trap 'rm -rf "$STAGE"' EXIT
for pair in "${CAND[@]}"; do
  src="${pair%%$'\t'*}"; dst="${pair#*$'\t'}"
  [ -f "$src" ] || { echo "::error::Local file missing: $src"; exit 1; }
  mkdir -p "$(dirname "$DST/$dst")"; cp -p "$src" "$DST/$dst"
done
for src in "${!EXTRA[@]}"; do
  dst="${EXTRA[$src]}"; [ -e "$src" ] || { echo "::error::extra source missing: $src"; exit 1; }
  mkdir -p "$(dirname "$STAGE/$dst")"; cp -rp "$src" "$STAGE/$dst"
done
if [[ "$SHAPE" == webavie ]]; then
  [ -f .engine/deploy-checks.sh ] || { echo "::error::.engine/deploy-checks.sh is not in this repo — run the engine's tools/sync.ps1 and commit .engine/"; exit 1; }
  mkdir -p "$STAGE/.engine"; cp -rp .engine/. "$STAGE/.engine/"
  if { [ "$SEED" = true ] || [ "$SEED_ALL" = true ]; } && [ -d content ]; then cp -rp content "$STAGE/content"; fi
fi
if [ "$VERSION_JSON" = true ] && [ -n "$TAG" ]; then
  printf '{"version":"%s"}\n' "$TAG" > "$DST/version.json"; echo "version.json -> $TAG"
elif [ "$VERSION_JSON" = true ]; then echo "no git tags — version.json left alone (blank chip is graceful)"; fi
if [ -n "$STAGE_SCRIPT" ]; then
  [ -f "$STAGE_SCRIPT" ] || { echo "::error::stageScript missing: $STAGE_SCRIPT"; exit 1; }
  echo "stage script: $STAGE_SCRIPT"
  STAGE="$STAGE" DOCROOT_STAGE="$DST" TAG="$TAG" APP="$APP" SITE="$SITE" bash "$STAGE_SCRIPT"
fi

DIGEST=""
if [[ "$SHAPE" == webavie ]]; then
  # The manifest of engine files this release ships, and the sweep that removes the ones
  # it no longer does — scoped to the two engine-owned dirs, never assets/uploads.
  ( cd "$DST" && find lib/lws assets/lws -type f 2>/dev/null | LC_ALL=C sort ) > "$STAGE/.engine-manifest"
  N=$(grep -c . "$STAGE/.engine-manifest" || true)
  [ "$N" -ge 30 ] || { echo "::error::staging produced only $N engine files — is public/lib/lws tracked? refusing to deploy"; exit 1; }
  cat > "$STAGE/.engine-clean.sh" <<'EOS'
#!/bin/sh
# Remove engine files this release no longer ships. Extraction overlays and never
# deletes, so without this a file the engine has stopped shipping lives on in the
# docroot forever. SCOPE IS THE POINT: only lib/lws and assets/lws, the two directories
# the engine owns outright — never assets/uploads, which are the client's files.
cd "$(dirname "$0")" || exit 0
[ -s .engine-manifest ] || { echo "  (no manifest - stale check skipped)"; exit 0; }
n=$(wc -l < .engine-manifest)
[ "$n" -ge 30 ] || { echo "  (manifest has only $n entries - refusing to delete anything)"; exit 0; }
cd public_html || exit 0
for owned in lib/lws assets/lws; do
  [ -d "$owned" ] || continue
  find "$owned" -type f | while read -r f; do
    grep -qxF "$f" ../.engine-manifest || { rm -f "$f" && echo "  removed stale: $f"; }
  done
done
exit 0
EOS
  # The digest, in deploy-checks.sh's wire format: POSIX paths, byte-sorted, "<path> <sha256>\n".
  DIGEST=$(cd "$DST" && find lib/lws assets/lws -type f | LC_ALL=C sort | while IFS= read -r f; do printf '%s %s\n' "$f" "$(sha256sum "$f" | cut -d' ' -f1)"; done | sha256sum | cut -d' ' -f1)
  echo "engine digest   ${DIGEST:0:8}…  ($N engine files)"
  if [ -n "${EXPECT_DIGEST:-}" ] && [ "$EXPECT_DIGEST" != "$DIGEST" ]; then
    echo "::error::the engine staged here (${DIGEST:0:8}…) is not the one the laptop computed (${EXPECT_DIGEST:0:8}…) — is everything committed and pushed?"; exit 1
  fi
fi

mapfile -t ENTRIES < <(cd "$STAGE" && find . -type f | sed 's#^\./##' | LC_ALL=C sort)
LAST_PATH=""; [ -n "$LAST" ] && [ -f "$STAGE/$DOC/$LAST" ] && LAST_PATH="$DOC/$LAST"
PHP=(); for e in "${ENTRIES[@]}"; do [[ "$e" == "$DOC"/*.php ]] && PHP+=("$e"); done

# The plan, printed without the engine's 150 files (those are one line)
n_engine=0; shown=()
for e in "${ENTRIES[@]}"; do
  if [[ "$e" == "$DOC"/lib/lws/* || "$e" == "$DOC"/assets/lws/* ]]; then n_engine=$((n_engine+1)); else shown+=("$e"); fi
done
echo "ship ${#ENTRIES[@]} file(s)$([ -n "$LAST_PATH" ] && echo " — $LAST extracted last")"
for e in "${shown[@]}"; do echo "     $e"; done
[ $n_engine -gt 0 ] && echo "     … + $n_engine engine files under $DOC/lib/lws and $DOC/assets/lws"
[ ${#REMOTE_STEPS[@]} -gt 0 ] && { echo "remote steps:"; for s in "${REMOTE_STEPS[@]}"; do echo "     $s"; done; }
echo "ping   $PING_URL"
for c in "${CANARIES[@]}"; do echo "canary https://$SITE/$c  (must NOT answer 200)"; done

if [ "$DRY_RUN" = true ]; then echo "dry run: nothing transferred, nothing connected"; exit 0; fi

ssh_setup
TB=$(mktemp -d -t "tar-$APP-XXXXXX"); trap 'rm -rf "$STAGE" "$TB"' EXIT
printf '%s\n' "${ENTRIES[@]}" | { if [ -n "$LAST_PATH" ]; then grep -vxF "$LAST_PATH"; else cat; fi; } > "$TB/main.list"
tar -czf "$TB/deploy-$APP.tgz" -C "$STAGE" -T "$TB/main.list"
UP=("$TB/deploy-$APP.tgz")
if [ -n "$LAST_PATH" ]; then tar -czf "$TB/deploy-$APP-last.tgz" -C "$STAGE" "$LAST_PATH"; UP+=("$TB/deploy-$APP-last.tgz"); fi
echo "archive: $(du -ch "${UP[@]}" | tail -1 | cut -f1)"

# ── Connection 1 of 2: the archive(s) go up, beside public_html — ONE scp ────
# Both files ride the same scp, so the "last" file cannot be missing on the server
# while the rest has landed: either the connection carried both or the run stops here.
echo "-- connection 1 of 2: scp -> $BASE/deploy-$APP.tgz$([ -n "$LAST_PATH" ] && echo " + deploy-$APP-last.tgz")"
scp -P "$PORT" "${SSH_OPTS[@]}" "${UP[@]}" "$SSH_USER:$BASE/"

# ── Connection 2 of 2: extract (last file last), steps, checks, lint, smoke ──
R=$(mktemp -t remote-XXXXXX.sh)
{
  echo 'set -e'
  printf 'SITE=%q; D=%q; APP=%q\n' "$SITE" "$DOC" "$APP"
  echo '[ -d "$HOME/www/$SITE" ] && [ ! -L "$HOME/www/$SITE" ] || { echo "::error::www/$SITE is not a real directory on this account"; exit 1; }'
  echo 'cd "$HOME/www/$SITE"'
  echo 'mkdir -p "$D"'
  echo 'tar -xzf "deploy-$APP.tgz" && rm -f "deploy-$APP.tgz"'
  if [ -n "$LAST_PATH" ]; then echo 'if [ -f "deploy-$APP-last.tgz" ]; then tar -xzf "deploy-$APP-last.tgz" && rm -f "deploy-$APP-last.tgz"; fi'; fi
  echo 'echo "extracted into $HOME/www/$SITE"'
  if [[ "$SHAPE" == webavie ]]; then
    echo 'rm -f "$D/index.html" "$D/Default.html"'
    echo 'chmod 600 data/config.php 2>/dev/null || true'
    echo 'sh .engine-clean.sh; rm -f .engine-clean.sh .engine-manifest'
    [ "$MIGRATE" = true ]      && echo 'php .engine/tools/migrate.php --site="$HOME/www/$SITE"'
    [ "$ENSURE_ADMIN" = true ] && echo 'php .engine/tools/ensure-admin.php --site="$HOME/www/$SITE" --commit'
    if   [ "$SEED_ALL" = true ]; then echo 'php .engine/tools/seed.php --site="$HOME/www/$SITE" --all'
    elif [ "$SEED" = true ];     then echo 'php .engine/tools/seed.php --site="$HOME/www/$SITE"'; fi
  fi
  for s in "${REMOTE_STEPS[@]}"; do printf '%s\n' "$s"; done
  if [[ "$SHAPE" == webavie ]]; then
    printf 'echo ""; set +e; sh .engine/deploy-checks.sh --site="$HOME/www/$SITE" --domain="$SITE" --docroot="$D" --engine-digest=%q%s | tee .deploy-checks.out; set -e\n' "$DIGEST" "$([ "$STAGING" = true ] && echo ' --staging')"
    echo 'rm -f .engine/deploy-checks.sh'
    echo 'if grep -q "PROBLEM(S)" .deploy-checks.out; then rm -f .deploy-checks.out; echo "::error::the deploy checks reported problems — the files are deployed; fix and deploy again"; exit 1; fi; rm -f .deploy-checks.out'
  fi
  if [ "$SKIP_LINT" != true ] && [ "$LINT" != none ]; then for f in "${PHP[@]}"; do printf 'php -l %q\n' "$f"; done; fi
  smoke_script
} > "$R"
NLINT=${#PHP[@]}; { [ "$SKIP_LINT" = true ] || [ "$LINT" = none ]; } && NLINT=0
echo "-- connection 2 of 2: extract, ${#REMOTE_STEPS[@]} step(s)$([[ "$SHAPE" == webavie ]] && echo ', sweep, deploy checks (which lint the engine)'), lint $NLINT php file(s), smoke"
ssh -p "$PORT" "${SSH_OPTS[@]}" "$SSH_USER" 'bash -s' < "$R"
rm -f "$R"
[ -n "$DIGEST" ] && echo "engine digest $DIGEST"
echo "== $APP done (2 connections) =="
