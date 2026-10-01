# SKYWARD.md

Skyward-specific workflows for `Skyward-AI/background-agents`. AGENTS.md covers the codebase; this
file covers how Skyward maintains, syncs, and deploys its copy. Keep Skyward-only guidance here, not
in AGENTS.md: upstream edits AGENTS.md often, and every line we change there can conflict during a
sync.

## Repository model

This repository is derived from `ColeMurray/background-agents` ("upstream"). It was detached from
upstream's GitHub fork network, so GitHub does not link the two. Pull requests from the browser
default to this repository, and GitHub's "Sync fork" button does not exist here. Syncing goes
through git remotes (see [Syncing with upstream](#syncing-with-upstream)).

| Branch    | Contents                                | Who writes to it                    |
| --------- | --------------------------------------- | ----------------------------------- |
| `skyward` | Default branch: `main` plus our commits | Pull requests, and the sync script  |
| `main`    | Exact mirror of `upstream/main`         | Only the sync script (fast-forward) |

Our changes are exactly `git log main..skyward`, the patch stack. There is no separate list to
maintain.

### Pull requests

- Open pull requests against base `skyward`. Never commit to `main`.
- Merge with **rebase** or **squash**, not merge commits, so each change stays one commit that the
  sync can replay.
- Keep each commit self-contained, and change upstream files as little as needed. Every line we
  change in an upstream file can conflict when upstream edits it.
- CI runs on pull requests into `skyward` and on pushes to `skyward`. Nothing runs for `main`.

## Clone setup

```bash
git clone git@github.com:Skyward-AI/background-agents.git
cd background-agents
git checkout skyward
gh repo set-default Skyward-AI/background-agents
scripts/sync-upstream.sh status   # adds the upstream remote and enables rerere
```

## Syncing with upstream

`scripts/sync-upstream.sh` pulls upstream changes and replays our commits on top. Run it whenever
you want; nothing schedules it.

```bash
scripts/sync-upstream.sh status   # upstream commits we don't have yet, and our patch stack
scripts/sync-upstream.sh          # sync and push
scripts/sync-upstream.sh sync --no-push   # sync, review locally, then: scripts/sync-upstream.sh push
```

A sync does the following:

1. Refuses to start if the working tree is dirty, a rebase is in progress, `main` has commits that
   are not in upstream, or local `skyward` has commits that are not on `origin/skyward`. Unpushed
   commits must go through a pull request first; the sync force-pushes `skyward`.
2. Fetches `upstream` and `origin`, then fast-forwards `main` to `upstream/main`.
3. Tags the old `skyward` as `sync-backup/<timestamp>-<sha>` (a local tag only).
4. Rebases `skyward` onto `main`. `rerere` reuses conflict resolutions from earlier syncs.
5. Prints a `range-diff` of the patch stack: `=` unchanged, `!` changed while replaying, `<` dropped
   (usually because upstream merged the same change), `>` new.
6. Pushes `main`, then force-pushes `skyward` with a lease. The push fails if someone pushed to
   `skyward` after the sync started.

### Conflicts

When the rebase stops on a conflict:

```bash
# fix the conflicted files, then
git add <files>
git rebase --continue             # repeat until the rebase finishes
scripts/sync-upstream.sh push     # prints the range-diff and pushes
```

To give up instead, run `scripts/sync-upstream.sh abort`. It restores `skyward` and `main` to where
the sync started, and pushes nothing.

### After a sync

- The push to `skyward` runs CI. Treat a failure as a sync regression: upstream code and one of our
  commits disagree even without a textual conflict.
- Read upstream's `CHANGELOG.md` diff and `scripts/sync-upstream.sh status` output for operator
  actions, such as new Terraform variables, migrations, or two-phase deploys.
- Check that new upstream Terraform doesn't hardcode `open-inspect-` resource names. Our
  `resource_name_prefix` change only covers names that existed when we made it:
  `grep -rn '"open-inspect-' terraform/environments/production/*.tf`.
- To roll back a bad sync, push the backup tag back over `skyward`:
  `git push --force-with-lease origin refs/tags/sync-backup/<tag>:refs/heads/skyward`.

## Deploying

### Secrets live in two places

- **Local, gitignored files** hold the secrets for deploying from your machine:
  `terraform/environments/production/terraform.tfvars`, `backend.tfvars`, and `.env`. Never commit
  them.
- **GitHub Actions secrets and variables** (Settings → Secrets and variables → Actions) are the only
  secrets CI can read. While they are empty, every deploy workflow skips itself. Deploy Web then
  shows as passed, but its deploy steps are skipped.

Once Actions secrets are configured, **every push to `skyward` deploys**, including each sync. Set
them up deliberately, and make each sync's push a release decision.

### Deploying from your machine

From the repo root, on an up-to-date `skyward`:

```bash
npm install
npm run build -w @open-inspect/shared
npm run build -w @open-inspect/control-plane -w @open-inspect/slack-bot -w @open-inspect/github-bot -w @open-inspect/linear-bot
cd terraform/environments/production
terraform init -backend-config=backend.tfvars   # first time, or after backend changes
terraform plan
terraform apply
```

Terraform deploys the control plane, D1 migrations, the bots, Modal (through the `modal-app`
module), and the web app when `web_platform = "cloudflare"`. See `docs/GETTING_STARTED.md` for
first-time setup and the two-phase Durable Object binding deploy.

### Skyward Terraform settings

- `resource_name_prefix` (default `open-inspect`) prefixes every Cloudflare and Vercel resource
  name: `<prefix>-<resource>-<deployment_name>`. Terraform passes it to the control-plane Worker as
  `RESOURCE_NAME_PREFIX`, which names the job queues. In CI it comes from the `RESOURCE_NAME_PREFIX`
  Actions variable. Changing it on an existing deployment renames, and therefore replaces, every
  resource, so plan carefully.
- The Terraform state bucket in `backend.tf` stays `open-inspect-terraform-state`; Terraform backend
  blocks can't use variables.
- Build telemetry is off: `NEXT_TELEMETRY_DISABLED=1` and `WRANGLER_SEND_METRICS=false`. OpenCode
  session sharing to opencode.ai is disabled in sandboxes.

### Deploy ordering

Some upstream changes require deploying services together. Since the 2026-10-01 sync, the control
plane supplies source-control credentials to Modal, and Modal rejects create, restore, and build
requests that don't include them. Deploy the control plane and Modal in the same `terraform apply`;
don't deploy one without the other.
