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
set +e
ssh -p "$PORT" "${SSH_OPTS[@]}" "$SG_SSH_USER" 'bash -s' < "$SCRIPT"
RC=$?
set -e
echo "-- end (exit $RC) --"
exit $RC
