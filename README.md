# sg-deploy

A two-connection SiteGround deploy that runs on a GitHub-hosted runner, so no
SiteGround SSH traffic ever originates from a developer's machine. One `scp` carries
the archive(s) to `www/<site>/`; one `ssh` lints them with the host's PHP, keeps one
spare copy of what is live, extracts into `www/<site>/public_html/`, runs the
manifest's server-side steps and smoke-tests. The smoke test is a gate: the ping must
answer 200 and no canary may — and a failure after the extract restores the spare.
See **Lint, the spare and the rollback** below.

It reads a `deploy.json` in the app's directory. Only `site` is required.

| key | example | meaning |
| --- | --- | --- |
| `site` | `"app.example.com"` | remote base `www/<site>`, docroot `www/<site>/public_html` |
| `sshUser` | `"u1234-abcd@ssh.example.com"` | the account (the `SG_SSH_USER` secret overrides) |
| `shape` | `"manifest"` (default) or `"webavie"` | see below |
| `srcDir` | `"public"` | ship every tracked file under this dir into the docroot, prefix stripped. Without it the legacy rule applies: root `*.php/css/js/html` + `version.json` + `.htaccess`, every `api/<file>`, and the `extraDirs` |
| `include` | `["site/*", "directory/*.php"]` | instead of `srcDir`: tracked files matching these globs (repo-relative) form the docroot set |
| `extraDirs` | `["js", "shell"]` | legacy: tracked dirs shipped whole into the docroot |
| `exclude` | `["lv.js", "public/assets/fonts/*.ttf"]` | globs, repo-relative, never ship |
| `map` | `{"site/": "", "directory/": "api/", "directory/root.htaccess": ".htaccess"}` | rename docroot-relative paths; the longest matching key wins; a key ending in `/` is a prefix |
| `extra` | `{"server/backup.sh": "backup.sh"}` | repo file or dir → a destination beside the docroot (`www/<site>/<dst>`) |
| `last` | `"api.php"` (default) | docroot-relative file extracted last — a router that must not `require()` a missing handler, a service worker that must not see stale assets |
| `versionJson` | `true` (default) | write `{"version":"<nearest git tag>"}` into the docroot root; `false` for an app whose `version.json` is its own (an update manifest) |
| `tagPrefix` | `"app-"` | this app's releases are its own series (`app-v1.2.3`) — for a repo where two apps would otherwise both fire on every `v*` tag. Only `<prefix>v[0-9]*` tags are read, and `version.json` shows the version without the prefix. Without it, only `v[0-9]*` tags are read |
| `stageScript` | `"tools/stage.sh"` | repo script run after staging, before the archive; env `STAGE` (the `www/<site>` mirror), `DOCROOT_STAGE`, `TAG`, `APP`, `SITE` |
| `remoteSteps` | `["rm -f \"$D/Default.html\"", "chmod 700 data"]` | run in `$HOME/www/<site>` after the extract, under `set -e`; `$D` is `public_html`, `$SITE` the site. A failing step rolls the release back |
| `lint` | `"shipped"` (default) or `"none"` | the SERVER's `php -l` of every shipped `.php`, on an unpacked copy before the switch, or skip it. The runner's pre-upload lint always runs; only the `skip_lint` input skips both |
| `pingPath` | `"api.php?resource=health&op=ping"` | smoke URL path (a cache-buster is appended); or `pingResource` (`api.php?resource=<x>`); default the site root |
| `canaryPath` / `canaries` | `"data/settings.json"` / `["build.php"]` | paths that must NOT answer 200 — the leak check |
| `staging` | `true` | webavie: pass `--staging` to the deploy checks (a rehearsal host must be noindexed) |

## shape "webavie"

For a site built on the webavie engine. The site's tracked `public/` is the docroot;
its tracked `.engine/` (`deploy-checks.sh`, the migration runner, the admin and seed
tools, `migrations/`, `starters/` — vendored by the engine's `sync.ps1`) travels above
the docroot; a manifest of every engine file plus a stale-file sweep over the two
engine-owned directories is generated; the engine digest is computed in the wire
format `deploy-checks.sh` expects and, when `EXPECT_DIGEST` is passed, the run aborts
before uploading if the staged engine differs from the one the caller computed. After
the extract the platform's `deploy-checks.sh` runs; a `PROBLEM(S)` line fails the job
and rolls the release back. Inputs `migrate`,
`ensure-admin`, `seed`, `seed-all` run the corresponding engine tools.

## Wiring a repo

1. `deploy.json` in the app directory.
2. `.github/workflows/deploy.yml`:

   ```yaml
   name: Deploy
   on:
     workflow_dispatch:
       inputs:
         dry_run:   { type: boolean, default: false, description: "Plan only — connect to nothing" }
         verify:    { type: boolean, default: false, description: "One connection — smoke test only" }
         skip_lint: { type: boolean, default: false, description: "Skip the php -l passes" }
   jobs:
     deploy:
       uses: luhwah/sg-deploy/.github/workflows/deploy.yml@main
       with:
         dry_run: ${{ inputs.dry_run }}
         verify: ${{ inputs.verify }}
         skip_lint: ${{ inputs.skip_lint }}
       secrets:
         SG_SSH_KEY: ${{ secrets.SG_SSH_KEY }}
         SG_SSH_USER: ${{ secrets.SG_SSH_USER }}
   ```

   A repo holding more than one site passes `dir:` and `app:`; a webavie site adds the
   `migrate` / `ensure_admin` / `seed` / `seed_all` / `expect_digest` inputs. Name the
   secrets explicitly — `secrets: inherit` did not reach the reusable workflow from a
   user-owned repo.
3. Repo secrets `SG_SSH_KEY` (a **dedicated** CI key's private half — never a person's
   own key) and `SG_SSH_USER`; repo variable `SG_KNOWN_HOSTS` with the
   `[ssh.host]:18765 …` line(s), which pins the host key.
4. Authorize the CI key's public half on the hosting account (`~/.ssh/authorized_keys`
   works on SiteGround; or Site Tools → SSH Keys Manager).
5. Run with `verify: true` first — one connection, nothing uploaded — then for real.

Revoking GitHub's access to an account is one line out of its `authorized_keys`.

## Modes

| input | connections | what happens |
| --- | --- | --- |
| `dry_run` | 0 | prints the upload set, connects to nothing |
| `verify` | 1 | the smoke test only |
| (default) | 2 | deploy |

The composite action can also be used directly (`uses: luhwah/sg-deploy@main`) with the
inputs `ssh-key`, `ssh-user`, `known-hosts`, `dir`, `app`, `dry-run`, `verify`,
`skip-lint`, `migrate`, `ensure-admin`, `seed`, `seed-all`, `expect-digest`,
`soft-fail-on-block`. `deploy.sh` also runs locally under bash (`-DryRun`, `-Verify`;
needs `jq`).

## Lint, the spare and the rollback (since 2026-10-14)

1. **Runner lint, before upload.** Every staged `.php` (docroot, `extra`, `.engine`) is
   `php -l`'d on the runner. One failure: `lint: <php's message>` lines, then
   `::error::PHP LINT FAILED on the runner … NOTHING was uploaded`. Runs in a dry run too.
2. **Server lint, before the switch.** The archive is unpacked into
   `www/<site>/.deploy-next-<app>/`, linted with the host's own `php`, and deleted. A
   failure deletes the archive and says `PHP LINT FAILED on the server … NOTHING was
   switched`. Turned off per app by `"lint": "none"`.
3. **One spare.** The current version of every path the archive will write (plus, for
   webavie, `lib/lws` and `assets/lws` whole, because the stale sweep deletes there) is
   tarred into `www/<site>/.deploy-spare-<app>/files.tgz`, and paths that do not exist
   yet are listed in `new.list`. It replaces the previous spare every deploy — exactly
   one. Nothing the archive does not carry is in it: data, uploads, stores, config and
   the database are never copied and never restored.
4. **Rollback.** From the first byte extracted, any failure — the extract, a remote
   step, `deploy-checks.sh`, the ping, a canary — removes the files this release added,
   unpacks the spare, re-pings, and ends the job red. The log says
   `ROLLED BACK: N file(s) restored, M … removed`, `after rollback: ping HTTP …`,
   `after rollback: version on disk …`, and the annotation
   `DEPLOY FAILED AND WAS ROLLED BACK`. A migration that ran is not undone.

## Reads and deploys queue separately

`deploy.yml` runs in the concurrency group `sg-deploy-<repo>-<dir>`; `remote.yml` in
`sg-remote-<repo>-<dir>`. GitHub keeps one PENDING run per group and a newer one
replaces it, so while they shared a group a read could cancel a waiting deploy.

## `strict: true` — a scheduled job, not a read

A read's exit code is an answer, so `remote.yml` stays green whatever the script
returns. A scheduled job (the nightly off-site backup) has nobody reading its log, and
its exit code is its verdict: with `strict: true` a non-zero exit fails the run, which
is what makes GitHub mail the owner. Added 2026-10-23 after the client sites' nightly
backup failed silently for five nights behind green runs.

## The second runner address

Runner addresses are shared with every other GitHub Actions user, and SiteGround's
firewall drops SSH from addresses it has blocked — so a deploy can fail for a reason
that has nothing to do with the deploy. A job cannot change its own address, so the
workflow uses two of them: **the first job exits green having deployed nothing and
says so in an annotation, and a second job does the deploy from a fresh runner.** Only
the TCP connect qualifies, which is the one thing OpenSSH reports unambiguously:

```
ssh: connect to host ssh.example.com port 18765: Connection timed out
```

A failed auth (`Permission denied`) is a key or username problem, never a fluke, and
fails on the first attempt — retrying one is how a house IP gets firewalled. A lint
error, a canary answering 200, a wrong engine digest and a failed ping all fail the
first job outright, and the second never starts.

Two blocked addresses in a row still fails the run, which is the point: a red run
should mean something. `deploy.test.sh` and `remote.test.sh` hold the cases (they stub
`ssh`/`scp` and connect to nothing — `bash deploy.test.sh`).

The one link those cannot reach is `blocked=1` travelling out through the action's
output and firing the second job's `if`. A dispatch-only `selftest-retry.yml` proved it
against `127.0.0.1` on the runner — nothing listens there, so the connect is refused
instantly and no real host is contacted. **It was deleted after it passed**, because its
pass is a RED run and a workflow that exists to fail is one somebody eventually mistakes
for a broken deploy. To re-prove the chain after changing it,
`git log --diff-filter=D -- .github/workflows/selftest-retry.yml` names the commit and
`git checkout <that>^ -- .github/workflows/selftest-retry.yml .selftest/` brings it back.
