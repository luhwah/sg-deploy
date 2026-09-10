#!/usr/bin/env bash
# deploy.test.sh — proves the one thing deploy.sh now DECIDES rather than reports:
# which failures are the deploy's, and which are only this runner's address.
#
# A blocked address is not a failed deploy. SiteGround drops SSH from addresses it
# has blocked and a runner draws its address from a shared pool, so a deploy can fail
# for a reason that has nothing to do with the deploy — and mail its owner about it.
# With SOFT_FAIL_ON_BLOCK=true that case records blocked=1 and exits 0 so the workflow
# can try a second runner; everything else still fails, loudly, the way it always did.
#
# It stubs `ssh` and `scp` on PATH, so it opens no connection and needs no key.
#   bash deploy.test.sh
#
# sg-connections: 0   (the stubs dial nothing — nothing here leaves the machine)
set -uo pipefail
cd "$(dirname "$0")"
HERE=$PWD

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
STUB="$WORK/bin"; mkdir -p "$STUB"
PASS=0; FAIL=0

# A minimal app: one tracked file, a deploy.json, a git repo (deploy.sh ships what
# git tracks, so an untracked tree stages nothing and the run stops before the wire).
APP="$WORK/app"; mkdir -p "$APP"
cd "$APP"
git init -q .
git config user.email t@example.com; git config user.name test; git config core.autocrlf false
printf '<?php echo "hi";\n' > index.php
printf '{"site":"test.example.com","lint":"none","include":["index.php"]}\n' > deploy.json
git add -A; git commit -qm init
cd "$HERE"

# ── The stubs ───────────────────────────────────────────────────────────────
# `mode` is how the connection behaves. `timeout` is the real line OpenSSH prints
# when the TCP connect never completed — the only shape that counts as blocked.
make_stubs() { # $1 = ok | timeout | denied | refused-by-remote
  local mode="$1" f
  for f in ssh scp; do
    cat > "$STUB/$f" <<STUBEOF
#!/usr/bin/env bash
case "$mode" in
  timeout)
    echo "ssh: connect to host ssh.test.example.com port 18765: Connection timed out" >&2
    exit 255 ;;
  denied)
    echo "u1234-abcd@ssh.test.example.com: Permission denied (publickey)." >&2
    exit 255 ;;
esac
if [ "\$(basename "\$0")" = scp ]; then exit 0; fi
# The ssh stub runs the remote script the way the remote login shell would.
if [ "$mode" = refused-by-remote ]; then
  echo "::error::ping did not answer 200" >&2
  exit 1
fi
cat > /dev/null
echo "extracted into /home/u/www/test.example.com"
exit 0
STUBEOF
    chmod +x "$STUB/$f"
  done
}

run_case() { # $1 name  $2 stub-mode  $3 SOFT_FAIL_ON_BLOCK  $4 expected-exit  then wants
  make_stubs "$2"
  local gho="$WORK/gh_output"; : > "$gho"
  local out rc
  out=$(cd "$APP" && SSH_KEY_FILE="$APP/deploy.json" SG_SSH_USER=u1234-abcd@ssh.test.example.com \
        APP=testapp SOFT_FAIL_ON_BLOCK="$3" GITHUB_OUTPUT="$gho" \
        PATH="$STUB:$PATH" bash "$HERE/deploy.sh" 2>&1)
  rc=$?
  out="$out
GITHUB_OUTPUT: $(cat "$gho")"
  local ok=1
  [ "$rc" = "$4" ] || { ok=0; echo "  want exit $4, got $rc"; }
  shift 4
  local want
  for want in "$@"; do
    case "$want" in
      !*) grep -qF -- "${want#!}" <<<"$out" && { ok=0; echo "  should NOT contain: ${want#!}"; } ;;
      *)  grep -qF -- "$want"  <<<"$out" || { ok=0; echo "  missing: $want"; } ;;
    esac
  done
  if [ "$ok" = 1 ]; then PASS=$((PASS+1)); echo "ok   $CASE"; else
    FAIL=$((FAIL+1)); echo "FAIL $CASE"; echo "$out" | sed 's/^/     | /'; fi
}

CASE="a clean deploy succeeds and says nothing about being blocked"
run_case "$CASE" ok false 0 \
  "== testapp done (2 connections) ==" '!blocked=1' '!::warning::SiteGround is not answering'

# The email that started this: mindbodysolutions, 2026-09-10 22:25Z, "All jobs have
# failed" for a deploy that was live eleven seconds into the next attempt.
CASE="a blocked address deploys nothing, exits 0 and tells the workflow to try again"
run_case "$CASE" timeout true 0 \
  "GITHUB_OUTPUT: blocked=1" "::warning::SiteGround is not answering this runner's address" \
  "Retrying elsewhere" '!done (2 connections)'

CASE="the same block on the SECOND runner is a real failure"
run_case "$CASE" timeout false 1 \
  "::error::the connection to test.example.com timed out from this runner too" \
  '!blocked=1' '!done (2 connections)'

# The rule the docs have carried since the first block: a refused key is never a
# fluke, and retrying one is how this house's own IP got firewalled.
# 255 is ssh's own "I failed", passed straight through: the run stops where it stood
# and the reason is on the line above it.
CASE="a refused key is NEVER soft-failed, even when the caller allows it"
run_case "$CASE" denied true 255 \
  "Permission denied (publickey)" '!blocked=1' '!::warning::SiteGround is not answering'

CASE="a failure the DEPLOY caused is not a blocked address"
run_case "$CASE" refused-by-remote true 1 \
  "::error::ping did not answer 200" '!blocked=1' '!::warning::SiteGround is not answering'

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
