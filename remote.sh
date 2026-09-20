#!/usr/bin/env bash
# remote.sh — run ONE script on a SiteGround account over ONE ssh, from a GitHub
# runner, and print what it printed. The read-only, ops-only sibling of deploy.sh.
#
# WHY (2026-09-08). Every deploy already runs from a runner (deploy.sh), so the only
# SiteGround connections a developer's machine still opens are for READING the
# server: a worker's progress file, a log tail, a run report, a one-off census.
# Those reads are what spend the machine's ration — the day Quil's fleet run was
# resumed, the daily allowance was gone by early afternoon and a fixed engine had
# been live for hours with nobody able to say whether it worked. This moves the
# read to where the deploy already is: a runner with a clean egress address,
# SiteGround's own tolerance for the ACCOUNT still applying (keep it to a few an
# hour; it is one authenticated connection per run), and nothing charged to the
# house or the jump host.
#
# WHAT IT IS NOT. It uploads nothing, and it is not a shell: one script, one
# connection, output to the Actions log. Anyone with write access to the calling
# repository can run any command as the hosting user — the same trust the deploy
# workflow already carries, since a deploy uploads arbitrary code. Never print a
# secret from the script; the log is visible to every collaborator.
#
# WHAT "FAILED" MEANS HERE (2026-09-10). A read has exactly one way to fail: the
# connection. Whatever the script itself returns is a READING, not a verdict - the
# exit status of a read-only diagnostic is usually just whatever its last command
# happened to be, and sometimes it is a deliberate signal (genavie's plugin census
# returns 3 for "the worker is mid-round, run again between rounds", run
# 34266024245). Propagating that as the job's exit code marked the run failed and
# mailed the owner "Run failed" for a read that had connected, printed its answer
# and told him something useful. Four such mails went out in three days against
# four real ones - which is how a person learns to skim past the real ones.
#
# So: ssh could not run the script -> the job FAILS (that is the timed-out or
# refused connection, and it is worth a mail). The script ran and returned N -> the
# output is the product, N is printed on the end line and raised as a warning
# annotation, and the job SUCCEEDS. deploy.sh is unchanged and still fails on
# anything non-zero: a deploy has a verdict, a read has an answer.
#
# AND A BLOCKED ADDRESS IS NOT A FAILED READ EITHER (2026-09-10). The connection is
# the one way a read fails, and its commonest cause is not the read: SiteGround drops
# SSH from an address it has blocked, and a runner draws its address from a shared
# pool. A job cannot change its own address, so with SOFT_FAIL_ON_BLOCK=true a connect
# timeout records blocked=1 and exits 0, and the retry job in
# .github/workflows/remote.yml runs the script from a runner that got a different
# draw. Only the TCP connect qualifies — "Permission denied" is a key or username
# problem and stays a failure on the first attempt.
#
# Inputs (env): SSH_KEY_FILE, SSH_KNOWN_HOSTS_FILE (optional), SG_SSH_USER,
#               SCRIPT_B64 (the script, base64 — newlines and quotes travel intact),
#               SOFT_FAIL_ON_BLOCK (see above).
# sg-connections: 1   (one ssh — on a runner it costs the local ration nothing)
set -euo pipefail

: "${SSH_KEY_FILE:?}" "${SG_SSH_USER:?}" "${SCRIPT_B64:?}"
PORT=18765
SSH_OPTS=(-i "$SSH_KEY_FILE" -o BatchMode=yes -o IdentitiesOnly=yes -o ConnectTimeout=30
          -o ServerAliveInterval=30 -o ServerAliveCountMax=4)
if [ -n "${SSH_KNOWN_HOSTS_FILE:-}" ] && [ -s "${SSH_KNOWN_HOSTS_FILE:-}" ]; then
  SSH_OPTS+=(-o StrictHostKeyChecking=yes -o "UserKnownHostsFile=$SSH_KNOWN_HOSTS_FILE")
else
  echo "::warning::no SG_KNOWN_HOSTS variable — the host key is accepted on first use (no pinning)"
  SSH_OPTS+=(-o StrictHostKeyChecking=accept-new)
fi

SCRIPT=$(mktemp)
trap 'rm -f "$SCRIPT"' EXIT
printf '%s' "$SCRIPT_B64" | base64 -d | tr -d '\r' > "$SCRIPT"

# ── CARRYING A SECRET TO THE SERVER (2026-09-16) ─────────────────────────────
# APP_SECRET, when the calling repo passes one, is prepended to the script as a
# shell variable so the script can use "$APP_SECRET" without the VALUE ever
# being in the script.
#
# WHY THIS IS THE ONLY SAFE ROUTE FROM A DEVELOPER'S MACHINE. The script itself
# travels as a workflow_dispatch INPUT, which is rendered in the Actions UI and
# readable by anyone with access to the repository — so a secret written into
# the script is a secret published to every collaborator. A repository secret is
# not: GitHub masks a registered secret everywhere it appears in a log, and it
# is never shown in the run's inputs. `gh secret set` puts one there without it
# passing through an argument or a transcript.
#
# IT IS BASE64 ON THE WIRE so that a value containing a quote, a newline or a
# dollar sign arrives byte for byte — a token spliced in raw would be re-parsed
# by the remote shell, which is both a corruption and an injection. base64's own
# alphabet is shell-inert, so the single-quoted literal below cannot be escaped
# out of whatever the secret contains.
#
# AND IT IS NEVER ECHOED. `set -x` in a caller's script would print it, so the
# assignment is written to happen before anything the caller controls, and the
# decoded value exists only in the remote shell's memory.
#
# ★ AND THERE ARE TWO SLOTS, BECAUSE ONE APP CAN NEED TWO CREDENTIALS (2026-09-19).
# APP_SECRET is spoken for on most sites — it carries that site's Postmark server
# token — and the scrumrl manifest already warns in writing that a second need
# must "give it a differently-named secret rather than overwriting this one, or
# the site silently starts sending with the app's token". APP_SECRET2 is that
# differently-named secret, and the warning is why it exists rather than a second
# use being squeezed into the first.
#
# Both are OPTIONAL and an unset one is simply not emitted, so no app changes
# behaviour by this existing.
for VAR in APP_SECRET APP_SECRET2; do
  eval "VAL=\${$VAR:-}"
  [ -n "$VAL" ] || continue
  WITH=$(mktemp)
  trap 'rm -f "$SCRIPT" "$WITH"' EXIT
  {
    printf '%s=$(printf %%s %s | base64 -d); export %s\n' \
      "$VAR" "'$(printf '%s' "$VAL" | base64 | tr -d '\n')'" "$VAR"
    cat "$SCRIPT"
  } > "$WITH"
  mv "$WITH" "$SCRIPT"
  echo "== a repository secret is being passed to the script as \$$VAR (not printed) =="
done
unset VAL

LINES=$(wc -l < "$SCRIPT" | tr -d ' ')
echo "== remote: ${APP:-$(echo "$SG_SSH_USER" | cut -d@ -f2)} — $LINES line(s), one connection =="
echo "-- output --"

# The remote shell stamps its own exit status onto stdout, so a connection that never
# ran anything is told apart from a script that ran and returned non-zero. The stamp
# is stripped back out here, and `-- end (exit N) --` keeps its exact shape because
# tools/remote.mjs parses that line.
RCFILE=$(mktemp)
# ssh's own stderr is held aside rather than let straight through, because telling a
# blocked address from a refused key means reading what OpenSSH said. It is replayed
# below, before the end marker, so nothing is swallowed.
ERRFILE=$(mktemp)
trap 'rm -f "$SCRIPT" "$RCFILE" "$ERRFILE"' EXIT
set +e
ssh -p "$PORT" "${SSH_OPTS[@]}" "$SG_SSH_USER" 'bash -s; printf "__sg_remote_rc_%s__" "$?"' < "$SCRIPT" 2>"$ERRFILE" | awk -v rcf="$RCFILE" '
      # The stamp carries no newline of its own, so a script whose output ended
      # without one keeps its last line intact and nothing gains a blank line.
      match($0, /__sg_remote_rc_[0-9]+__$/) {
        r = substr($0, RSTART); gsub(/[^0-9]/, "", r); print r > rcf; close(rcf)
        head = substr($0, 1, RSTART - 1); if (head != "") print head
        next
      }
      { print; fflush() }'
SSH_RC=${PIPESTATUS[0]}
set -e
if [ -s "$ERRFILE" ]; then cat "$ERRFILE" >&2; fi

if [ -s "$RCFILE" ]; then
  RC=$(cat "$RCFILE")
  echo "-- end (exit $RC) --"
  if [ "$RC" != "0" ]; then
    echo "::warning::the script returned exit $RC — it CONNECTED and its output is above. A read-only run does not fail on the script's own exit code; read the output."
  fi
  exit 0
fi

# Nothing came back from the remote shell: the connection is what failed.
echo "-- end (exit $SSH_RC) --"

# ... and if it never connected at all, the address is the likeliest reason. This is
# the one line OpenSSH prints when the TCP connect itself fails; an auth failure says
# something else entirely and falls through to the error below.
if [ "${SOFT_FAIL_ON_BLOCK:-false}" = true ] \
   && grep -Eq '^(ssh: connect to host .* port [0-9]+: |kex_exchange_identification: )' "$ERRFILE"; then
  if [ -n "${GITHUB_OUTPUT:-}" ]; then echo "blocked=1" >> "$GITHUB_OUTPUT"; fi
  echo "::warning::SiteGround is not answering this runner's address, so the script did not run — trying again from a fresh runner."
  exit 0
fi

echo "::error::ssh could not run the script on ${APP:-this account} (exit $SSH_RC). A timeout is usually a runner address SiteGround has blocked — re-run once. NEVER re-run a 'Permission denied': that is a key or username problem, not a fluke."
exit "$SSH_RC"
