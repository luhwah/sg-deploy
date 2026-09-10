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
# Inputs (env): SSH_KEY_FILE, SSH_KNOWN_HOSTS_FILE (optional), SG_SSH_USER,
#               SCRIPT_B64 (the script, base64 — newlines and quotes travel intact).
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
LINES=$(wc -l < "$SCRIPT" | tr -d ' ')
echo "== remote: ${APP:-$(echo "$SG_SSH_USER" | cut -d@ -f2)} — $LINES line(s), one connection =="
echo "-- output --"

# The remote shell stamps its own exit status onto stdout, so a connection that never
# ran anything is told apart from a script that ran and returned non-zero. The stamp
# is stripped back out here, and `-- end (exit N) --` keeps its exact shape because
# tools/remote.mjs parses that line.
RCFILE=$(mktemp)
trap 'rm -f "$SCRIPT" "$RCFILE"' EXIT
set +e
ssh -p "$PORT" "${SSH_OPTS[@]}" "$SG_SSH_USER" 'bash -s; printf "__sg_remote_rc_%s__" "$?"' < "$SCRIPT" | awk -v rcf="$RCFILE" '
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

if [ -s "$RCFILE" ]; then
  RC=$(cat "$RCFILE")
  echo "-- end (exit $RC) --"
  if [ "$RC" != "0" ]; then
    echo "::warning::the script returned exit $RC - it CONNECTED and its output is above. A read-only run does not fail on the script own exit code; read the output."
  fi
  exit 0
fi

# Nothing came back from the remote shell: the connection is what failed.
echo "-- end (exit $SSH_RC) --"
echo "::error::ssh could not run the script on ${APP:-this account} (exit $SSH_RC). A timeout is usually a runner address SiteGround has blocked - re-run once. NEVER re-run a Permission denied: that is a key or username problem, not a fluke."
exit "$SSH_RC"
