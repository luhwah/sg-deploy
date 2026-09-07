# sg-deploy

A two-connection SiteGround deploy that runs on a GitHub-hosted runner, so no
SiteGround SSH traffic ever originates from a developer's machine.

It reads a `deploy.json` in the app's directory:

```json
{
  "site": "app.example.com",
  "sshUser": "u1234-abcdefghijkl@ssh.example.com",
  "exclude": ["migrate.php"],
  "extraDirs": ["js", "shell"],
  "pingResource": "ping",
  "canaryPath": "data/settings.json"
}
```

and ships, from `git ls-files`: every root `*.php` / `*.css` / `*.js` / `*.html`,
`version.json` (rewritten from the nearest git tag), `.htaccess`, every `api/<file>`,
and the `extraDirs` — minus `exclude`. One `scp` carries a tarball to
`www/<site>/`; one `ssh` extracts it into `www/<site>/public_html/` with `api.php`
last, runs `php -l` on every shipped PHP file, and smoke-tests: the ping URL must
answer 200 and the canary path must not. A failed smoke fails the job.

## Wiring a repo

1. Put `deploy.json` in the app directory.
2. Add `.github/workflows/deploy.yml`:

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
       secrets: inherit
   ```

3. Repo secrets: `SG_SSH_KEY` (a **dedicated** CI key's private half — never a
   person's own key) and `SG_SSH_USER`. Repo variable `SG_KNOWN_HOSTS`: the
   `[ssh.host]:18765 …` line(s), which pins the host key.
4. Authorize the CI key's public half on the hosting account
   (`~/.ssh/authorized_keys`, or Site Tools → SSH Keys Manager).
5. Run it with `verify: true` first — one connection, nothing uploaded — then for real.

Revoking GitHub's access is one line out of `authorized_keys`.

## Modes

| input | connections | what happens |
| --- | --- | --- |
| `dry_run` | 0 | prints the upload set, connects to nothing |
| `verify` | 1 | the smoke test only |
| (default) | 2 | deploy |

The composite action can also be used directly (`uses: luhwah/sg-deploy@main`) with
`ssh-key`, `ssh-user`, `known-hosts`, `dir`, `app`, `dry-run`, `verify`, `skip-lint`.

Runner addresses are shared with every other GitHub Actions user. A run that times
out on the connection may have landed on an address a stranger got blocked; re-run
it once. A run that fails with `Permission denied` is a key or username problem —
do not re-run it.
