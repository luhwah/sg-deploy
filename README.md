# sg-deploy

A two-connection SiteGround deploy that runs on a GitHub-hosted runner, so no
SiteGround SSH traffic ever originates from a developer's machine. One `scp` carries
the archive(s) to `www/<site>/`; one `ssh` extracts into `www/<site>/public_html/`,
runs the manifest's server-side steps, lints every shipped PHP file and smoke-tests.
The smoke test is a gate: the ping must answer 200 and no canary may.

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
| `stageScript` | `"tools/stage.sh"` | repo script run after staging, before the archive; env `STAGE` (the `www/<site>` mirror), `DOCROOT_STAGE`, `TAG`, `APP`, `SITE` |
| `remoteSteps` | `["rm -f \"$D/Default.html\"", "chmod 700 data"]` | run in `$HOME/www/<site>` after the extract, under `set -e`, before the lint; `$D` is `public_html`, `$SITE` the site |
| `lint` | `"shipped"` (default) or `"none"` | `php -l` every shipped `.php`, or skip |
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
(the files are deployed by then — fix and deploy again). Inputs `migrate`,
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
         skip_lint: { type: boolean, default: false, description: "Skip the server-side php -l" }
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
`skip-lint`, `migrate`, `ensure-admin`, `seed`, `seed-all`, `expect-digest`.
`deploy.sh` also runs locally under bash (`-DryRun`, `-Verify`; needs `jq`).

Runner addresses are shared with every other GitHub Actions user. A run that times
out on the connection may have landed on an address a stranger got blocked; re-run
it once. A run that fails with `Permission denied` is a key or username problem —
do not re-run it.
