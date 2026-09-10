#!/usr/bin/env bash
# remote.test.sh — proves the one thing remote.sh decides: WHEN a read is a failure.
#
# A read fails only when the connection fails. A script that ran and returned
# non-zero is an answer, not a verdict, and must not fail the job (or GitHub mails
# the owner "Run failed" for a read that worked — see the header of remote.sh).
#
# It stubs `ssh` on PATH, so it opens no connection and needs no key.
#   bash remote.test.sh
#
# sg-connections: 0   (the stub dials nothing — nothing here leaves the machine)
set -uo pipefail
cd "$(dirname "$0")"

STUB=$(mktemp -d); trap 'rm -rf "$STUB"' EXIT
PASS=0; FAIL=0

# The stub reads the script on stdin exactly as the remote shell does, runs it, and
# appends the stamp — or, for the transport case, dies the way ssh dies.
make_stub() { # $1 = mode: run | timeout | denied
  cat > "$STUB/ssh" <<STUBEOF
#!/usr/bin/env bash
if [ "$1" = timeout ]; then
  echo "ssh: connect to host giowm1287.siteground.biz port 18765: Connection timed out" >&2
  exit 255
fi
if [ "$1" = denied ]; then
  echo "u1234-abcd@giowm1287.siteground.biz: Permission denied (publickey)." >&2
  exit 255
fi
# Everything after the options is the remote command; run it under a shell the way
# the remote login shell would, with the script arriving on stdin.
CMD="\${@: -1}"
bash -c "\$CMD"
STUBEOF
  chmod +x "$STUB/ssh"
}

run_case() { # $1 name  $2 stub-mode  $3 script  $4 expected-exit   ($SOFT arms the retry path)
  make_stub "$2"
  local gho="$STUB/gh_output"; : > "$gho"
  local out rc
  out=$(SSH_KEY_FILE=/dev/null SG_SSH_USER=u@example.com APP=testapp \
        SOFT_FAIL_ON_BLOCK="${SOFT:-false}" GITHUB_OUTPUT="$gho" \
        SCRIPT_B64=$(printf '%s' "$3" | base64 -w0) \
        PATH="$STUB:$PATH" bash remote.sh 2>&1)
  rc=$?
  out="$out
GITHUB_OUTPUT: $(cat "$gho")"
  local ok=1
  [ "$rc" = "$4" ] || { ok=0; echo "  want exit $4, got $rc"; }
  shift 4
  for want in "$@"; do
    case "$want" in
      !*) grep -qF -- "${want#!}" <<<"$out" && { ok=0; echo "  should NOT contain: ${want#!}"; } ;;
      *)  grep -qF -- "$want"<<<"$out" || { ok=0; echo "  missing: $want"; } ;;
    esac
  done
  if [ "$ok" = 1 ]; then PASS=$((PASS+1)); echo "ok   $CASE"; else
    FAIL=$((FAIL+1)); echo "FAIL $CASE"; echo "$out" | sed 's/^/     | /'; fi
}

CASE="a clean read succeeds and shows exit 0"
run_case "$CASE" run 'echo hello from the server' 0 \
  "hello from the server" "-- end (exit 0) --" '!::warning::the script returned' '!__sg_remote_rc'

CASE="a script returning 3 is an ANSWER: job succeeds, code shown, warning raised"
run_case "$CASE" run 'echo "WORKER BUSY"; exit 3' 0 \
  "WORKER BUSY" "-- end (exit 3) --" "::warning::the script returned exit 3"

CASE="a falsy last command (the leadavie case) does not fail the job"
run_case "$CASE" run 'echo "--- counts ---"
for f in /nope/a.json /nope/b.json; do [ -f "$f" ] && echo "$f"; done' 0 \
  "--- counts ---" "-- end (exit 1) --" "::warning::the script returned exit 1"

CASE="a timed-out connection DOES fail the job, with the re-run rule"
run_case "$CASE" timeout 'echo never reached' 255 \
  "-- end (exit 255) --" "::error::ssh could not run the script on testapp" \
  "re-run once" "NEVER re-run a 'Permission denied'" '!never reached'

# The hard case, and the reason the stamp exists at all: ssh returns 255 for its OWN
# failures, so a script that exits 255 is indistinguishable from a dead connection by
# exit code alone. scrumrl-85 hit exactly this on 2026-09-10 — a PHP snippet that
# "printed its output fine" and still ended `-- end (exit 255) --`. The stamp is
# present in one case and absent in the other, which is the whole distinction.
CASE="a script that exits 255 is NOT a dead connection"
run_case "$CASE" run 'echo "the output arrived"; exit 255' 0 \
  "the output arrived" "-- end (exit 255) --" "::warning::the script returned exit 255" \
  '!::error::ssh could not run the script'

# A blocked runner address is not a failed read either (2026-09-10) — the workflow's
# second job runs the same script from a runner that drew a different address.
CASE="a blocked address asks for a second runner instead of failing"
SOFT=true run_case "$CASE" timeout 'echo never reached' 0 \
  "GITHUB_OUTPUT: blocked=1" "::warning::SiteGround is not answering this runner's address" \
  '!::error::ssh could not run the script' '!never reached'

CASE="a refused key is NEVER soft-failed, even when the caller allows it"
SOFT=true run_case "$CASE" denied 'echo never reached' 255 \
  "Permission denied (publickey)" "::error::ssh could not run the script on testapp" \
  '!blocked=1'

CASE="the stamp never leaks into the output"
run_case "$CASE" run 'echo "__sg_remote_rc_9__ is not mine"; exit 0' 0 \
  "__sg_remote_rc_9__ is not mine" "-- end (exit 0) --"

CASE="output with no trailing newline keeps its last line"
run_case "$CASE" run 'printf "abc"' 0 "abc" "-- end (exit 0) --"

# The stamp used to arrive on a line of its own, which left a blank line in every
# ops log. The end marker must follow the last real line immediately.
CASE="the stamp adds no blank line before the end marker"
make_stub run
got=$(SSH_KEY_FILE=/dev/null SG_SSH_USER=u@example.com APP=testapp       SCRIPT_B64=$(printf '%s' 'echo last-real-line' | base64 -w0)       PATH="$STUB:$PATH" bash remote.sh 2>/dev/null | grep -A1 -F -- 'last-real-line' | tail -1)
if [ "$got" = "-- end (exit 0) --" ]; then PASS=$((PASS+1)); echo "ok   $CASE"
else FAIL=$((FAIL+1)); echo "FAIL $CASE"; echo "     | line after the output was: [$got]"; fi

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
