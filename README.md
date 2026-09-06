# selfhosted-runners

Zero-touch setup for self-hosted GitHub Actions runners on Proxmox.

## Quick Start

```bash
# On your Proxmox host
curl -fsSL https://raw.githubusercontent.com/ThayneStudio/selfhosted-runners/master/install.sh | bash
runner setup
```

Or manually:
```bash
git clone https://github.com/ThayneStudio/selfhosted-runners.git
cd selfhosted-runners
./runner setup
```

The wizard will:
1. Ask for network bridge, storage pool, and template settings
2. Install to `/opt/selfhosted-runners` and add the `runner` command to `/usr/local/bin`
3. Download the Ubuntu cloud image and bake the VM template
4. Hand off to `runner add-org` for your first org + PAT

Then create runners from anywhere:
```bash
runner create runner-01
runner create runner-02
```

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│ Proxmox Host                                                    │
│                                                                 │
│  /etc/github-runners.conf          ← Infra config (no secrets) │
│  /etc/github-runners.d/<org>.conf  ← Per-org PAT (600)         │
│  /var/lib/vz/snippets/             ← Per-VM cloud-init         │
│                                                                 │
│  ┌──────────────────┐                                          │
│  │ Template (9000)  │  ← Ubuntu 24.04 cloud image              │
│  └──────────────────┘                                          │
│           │                                                     │
│           │ clone                                               │
│           ▼                                                     │
│  ┌─────────┐  ┌─────────┐  ┌─────────┐                        │
│  │runner-01│  │runner-02│  │runner-03│  ...                   │
│  │ 2c/8GB  │  │ 2c/8GB  │  │ 2c/8GB  │                        │
│  │  30GB   │  │  30GB   │  │  30GB   │                        │
│  └─────────┘  └─────────┘  └─────────┘                        │
│       │            │            │                               │
│       └────────────┼────────────┘                               │
│                    │                                            │
│                    ▼                                            │
│         GitHub Organization                                     │
│    (runners shared by all repos)                                │
└─────────────────────────────────────────────────────────────────┘
```

## Prerequisites

### Proxmox Host

- **Proxmox VE 7.x or 8.x**
- **Root access** to the Proxmox host
- **Storage pool** with at least 50GB free (template + runners)
- **Network bridge** (vmbr0 or custom) with internet access

### Network Requirements

The Proxmox host and runner VMs need outbound access to:

| Destination | Port | Purpose |
|-------------|------|---------|
| github.com | 443 | Runner registration, API |
| api.github.com | 443 | API calls |
| *.actions.githubusercontent.com | 443 | Workflow artifacts |
| download.docker.com | 443 | Docker installation |
| deb.nodesource.com | 443 | Node.js installation |
| awscli.amazonaws.com | 443 | AWS CLI v2 installer |
| www.postgresql.org | 443 | PGDG repository signing key |
| apt.postgresql.org | 443 | PostgreSQL client packages |
| registry.npmjs.org | 443 | Playwright package download |
| cdn.playwright.dev | 443 | Playwright Chromium download (required) |
| playwright.download.prss.microsoft.com | 443 | Playwright fallback mirror (optional, resilience only) |
| cloud-images.ubuntu.com | 443 | Ubuntu cloud image |
| release-assets.githubusercontent.com | 443 | Supabase CLI `.deb` and Actions runner tarball (GitHub release downloads 302 here) |
| cli.github.com | 443 | GitHub CLI packages |
| archive.ubuntu.com, security.ubuntu.com | 80/443 | Ubuntu package archive and security updates |
| public.ecr.aws | 443 | Supabase service and database job images |
| d2glxqk2uabbnd.cloudfront.net | 443 | ECR Public blob storage (image layers 307-redirect here) |

### GitHub Requirements

- **GitHub organization** (free tier works)
- **Personal Access Token (PAT)** — either a fine-grained or classic token (below)

#### Creating a GitHub PAT

The host uses the PAT only to mint single-use JIT runner configs
(`generate-jitconfig`) and to deregister stale runners. Two options:

**Fine-grained (recommended — least privilege):**
1. GitHub → Settings → Developer settings → Personal access tokens → **Fine-grained tokens**
2. **Resource owner**: your organization. Set an expiration.
3. **Organization permissions** → **Self-hosted runners**: **Read and write**
   (the mint needs *write* — "Read" alone is not enough; see the note below)
4. Generate and copy the token (starts with `github_pat_`)

This scopes the token to one capability on one org — if it leaks, the blast
radius is "manage that org's runners," not full org control.

**Classic (simpler, broader):**
1. GitHub → Settings → Developer settings → Personal access tokens → **Tokens (classic)**
2. Select scope **`admin:org`**, generate, and copy (starts with `ghp_`)

`runner add-org` validates the token against the org's runner API, which catches
a wrong org or a token with no runner access. Note: it confirms *read* access, so
a fine-grained token granted only "Self-hosted runners: **Read**" passes setup but
then fails at the first clone (the mint needs **write**) — grant **Read and
write**. A classic `admin:org` token has both.

## Runner Specs

| Resource | Value | Rationale |
|----------|-------|-----------|
| CPU | 2 cores | Matches GitHub-hosted |
| RAM | 8 GB | GitHub-hosted has 7GB |
| Disk | 30 GB | OS + Docker + headroom |

## Commands

After setup, the `runner` command is available globally:

| Command | Description |
|---------|-------------|
| `runner setup` | Re-run the infrastructure setup wizard |
| `runner add-org` | Add a GitHub org (or rotate its PAT) |
| `runner remove-org [<org>]` | Remove a configured org |
| `runner list-orgs` | List configured orgs and runner counts |
| `runner create [--org <org>] <name>` | Create a runner VM manually |
| `runner destroy <name>` | Destroy a managed runner VM |
| `runner start` | Exit maintenance mode and resume watcher |
| `runner stop [options]` | Enter maintenance mode and stop managed runners |
| `runner list` | List all runner VMs |
| `runner watch` | Fill missing runner slots (run by a 30s timer) |
| `runner guard [--dry-run]` | Reap stopped and over-age runner VMs (normally run by timer) |
| `runner gc [--dry-run]` | Collect drained template generations according to retention policy |
| `runner canary <id>` | Run the canary gate against a candidate generation |
| `runner upgrade [--dry-run] [--force]` | Bake a candidate if needed and promote it |
| `runner help` | Show available commands |

## Runner Lifetime and Reaping

Runners are ephemeral: one job, shutdown, auto-destroy, watcher recreates. Two
things break that cycle and silently kill a pool slot, so `setup` installs
`github-runner-guard.timer` (5 minute interval) to enforce it from the host:

- **A managed VM stuck in `stopped`.** The hookscript skips its re-clone while
  maintenance mode is active, and a host reboot brings VMs back stopped with
  any in-flight re-clone long dead. The watcher still sees the name in
  `qm list`, so it counts the slot as filled and never refills it. A stopped
  ephemeral runner is always garbage — it either finished its job or crashed.
- **A managed VM that outlives its ceiling.** The guest arms
  `shutdown -h +360` itself, but the `runner` user has passwordless sudo so a
  job can cancel it, and a wedged guest never runs it at all.

`runner start` also reaps stopped runner VMs before resuming the watcher, so a
slot that died during maintenance comes back on its own.

| Setting in `/etc/github-runners.conf` | Default | Meaning |
|---|---|---|
| `MAX_VM_LIFETIME_HOURS` | `8` | Destroy a managed runner VM whose uptime exceeds this. Keep it above the guest's own 6h ceiling so the cooperative shutdown normally wins. |
| `STOPPED_REAP_MINUTES` | `10` | Destroy a managed runner VM seen `stopped` for this long. Keep it comfortably above normal destroy-and-re-clone turnaround. |
| `GUARD_EXCLUDE_VMIDS` | *(empty)* | VMIDs the guard never touches, space- or comma-separated. |

A missing or non-numeric value falls back to the default — the guard is never
disabled by a typo, because the failure mode is a dead pool slot.

**See what it would do before it does it:**

```bash
runner guard --dry-run     # prints candidates and reasons, destroys nothing
```

### What the guard will never touch

- Any VM whose cloud-init snippet does not identify a configured org — the same
  check `runner destroy` uses. Unrelated VMs on the same host are invisible to
  it.
- `TEMPLATE_ID`, and any VM that is itself a template.
- Any VM below the runner VMID floor (`MIN_VMID`). `MIN_VMID` is required and
  must sit above the generation template band (`TEMPLATE_BAND_MAX`, default
  8999, so `9000` or higher). Absent or `MIN_VMID=0` is a hard error at
  config load; `install.sh` aborts an upgrade until it is set.
- Any VM with `protection: 1` or a `lock:` line — including one suspended to
  disk. **This is the escape hatch**: to keep a wedged runner for forensics,
  `qm set <vmid> --protection 1`. A copy taken with `qm clone`/`qm restore`
  inherits the runner's `cicustom` and *is* a candidate, so protect it too.
- Anything listed in `GUARD_EXCLUDE_VMIDS`.
- Anything whose slot is locked by an in-flight clone or re-clone, or whose
  Proxmox config was written in the last 60 seconds.

Every run and every forced destroy is logged, and each destroy also emits a
`lifetime.forced_destroy` or `stopped_vm.reaped` notification when the webhook
notifier is configured:

```bash
journalctl -t github-runner | grep '\[guard\]'
systemctl list-timers github-runner-guard.timer
```

The summary line each run carries `deferred`, `skipped`, `no-uptime`,
`no-mtime` and `unreadable` counts alongside `destroyed`, so a guard that has
gone quietly inert does not look like a guard with nothing to do.

## Installed Software

Runners come pre-installed with:

- **Docker CE** + Docker Compose
- **Node.js LTS** (via NodeSource)
- **AWS CLI v2**
- **GitHub CLI** (`gh`)
- **PostgreSQL client `17`** (`psql`, `pg_dump`, `pg_restore`, `pg_isready`, ...) from PGDG
- **Supabase CLI** `2.115.0` with warmed local development and database job Docker image cache
- **Playwright Chromium** for `playwright@1.62.1`, plus Playwright system dependencies
- **Build tools**: git, curl, jq, build-essential, wget, unzip, zstd

The PostgreSQL client comes from the PGDG apt repository rather than the Ubuntu
archive, which only ships version 16. This client is for **your workflow steps**
that invoke `psql` or `pg_dump` directly against the local database on
`127.0.0.1:54322` -- the Supabase CLI itself never uses it, running its own
dump/test tooling in one-shot containers chosen by `db.major_version`.

Supabase local development defaults to Postgres 17. `psql` 16 would connect to a
17 server without complaint, but `pg_dump`/`pg_restore` hard-abort against a
server newer than themselves, so a 16 client would break exactly the dump and
restore steps. A 17 client still works against older (15/16) servers, so it is
the safe default. Change the pinned version in `templates/template-setup.yaml`
and rebuild the template if you need to match a different server major version.

Note that the PGDG apt source is baked into the template permanently, so every
runner VM -- not just the Proxmox host at bake time -- needs `apt.postgresql.org`
reachable for any `apt-get update` a job runs. PGDG also supplies `libpq5`
(currently 18.x, which satisfies the client's dependency), so package listings
on runners will show a newer libpq than Ubuntu ships.

Playwright Chromium is baked into the runner user's default cache at
`/home/runner/.cache/ms-playwright`, so jobs running as `runner` can use it
without extra path configuration. Consumer repos need to pin Playwright to
`1.62.1` to use the prebaked cache. Change the pinned version in
`templates/template-setup.yaml` and rebuild the template when upgrading
intentionally.

During template baking, the installer also runs a throwaway `supabase init`,
`supabase start`, and `supabase stop --no-backup` in a temporary directory.
It also explicitly pulls the database job images used by `supabase test db` and
`supabase db diff`: `public.ecr.aws/supabase/pg_prove:3.36`,
`public.ecr.aws/supabase/pgadmin-schema-diff:cli-0.0.5`, and
`public.ecr.aws/supabase/migra:3.0.1663481299`.
The temporary working directory is deleted afterwards, while the Docker artifacts
from that warmup run remain on the VM so later `supabase start` and
database test/diff runs avoid cold pulls.

### What the 2.115.0 bump changes for schema diffing

Despite the release-note headline, **existing repos keep using migra.** Whether
pg-delta runs at all is gated on `[experimental.pgdelta] enabled` in
`supabase/config.toml`, and a config without that section resolves to migra --
deliberately, so the change is non-breaking. Only repos whose `config.toml` is
generated by a fresh `supabase init` on 2.115.0 opt in by default -- adding the
section by hand, `--use-pg-delta`, or `SUPABASE_EXPERIMENTAL_PG_DELTA` also opts
in.

`--use-migra` likewise defaults to true; passing it explicitly is the *opt-out*
from pg-delta, not the opt-in to migra.

What 2.115.0 actually changed is pg-delta's implementation, for the repos using
it: previously a Deno module in the edge-runtime container, now bundled and run
in-process by the CLI. So the bump introduces **no new runtime package fetch on
any default path**. (`SUPABASE_USE_PG_DELTA_NEXT=false` reverts to the old
implementation and is scheduled for removal.)

The prebaked `migra` image is worth keeping, but not for the reason you might
assume: the normal migra path runs `npm:@pgkit/migra` inside the edge-runtime
container, and the `supabase/migra` image is reached only via the out-of-memory
bash fallback. `--use-pgadmin` uses the prebaked `pgadmin-schema-diff` image
directly. This is all unchanged from 2.98.1.

Two 2.115.0 changes that can bite after a template rebuild:

- `supabase test db` now exits non-zero when it finds no pgTAP tests, where
  earlier versions passed silently. Repos with an empty or misconfigured test
  path will start failing.
- For repos already using pg-delta declarative schemas, the declarative schema
  directory default moved from `supabase/database` to `supabase/schemas`. Set
  `declarative_schema_path = "./database"` under `[experimental.pgdelta]` to keep
  the old layout. Migra users are unaffected.

### Docker mirror

If a Docker mirror URL is supplied during `runner setup`, the template bake and
cloned runners route Supabase image pulls through that registry cache.
Local HTTP mirrors are supported by entering the URL with an explicit `http://`
scheme, for example `http://10.0.0.20:5000`. For HTTP mirrors, the bake pins
Docker to the classic `overlay2` storage driver as a compatibility workaround
for Docker 29's containerd image store trying HTTPS against local HTTP mirrors.

## Using in Workflows

```yaml
jobs:
  build:
    runs-on: [self-hosted, linux, x64]
    steps:
      - uses: actions/checkout@v4
      - run: npm install
      - run: npm test
```

## Canary workflow

A newly baked template is promoted only after a runner cloned from it
**completes a real GitHub Actions job**. Registering is not evidence: a runner
that registers, shows Online/Idle and is never assigned work is the exact
failure this platform exists to catch, and no local smoke test sees it. The job
that supplies that evidence is `templates/canary-workflow.yml`, which doubles as
the acceptance test for everything the bake installs.

### The gate (`runner canary <id>`)

`runner canary <generation-id>` is what turns a `candidate` generation into the
`active` one, and it is the only path to promotion that needs no human. It is
written to be run unattended on every `runner maintain` cycle -- maintain does
not call it yet -- so it is safe to run at any time: a second run while one is
in flight does nothing, an already-active generation is a no-op, and a canary
that cannot be attempted changes nothing at all.

One attempt is:

1. Clone `canary-gen<id>` from **that generation's** template -- never from
   `TEMPLATE_ID` -- tagged `runner,gen-<id>,runner-canary`, with a JIT config
   carrying only the `gen-<id>-canary` label (see the label contract above).
2. Wait up to `CANARY_REGISTER_TIMEOUT` (600s) for it to show **Online** in the
   org's runner list.
3. `workflow_dispatch` `CANARY_WORKFLOW` in `CANARY_REPO`, on the repository's
   default branch, with `generation=<id>` as the input.
4. Poll the run that dispatch created through to a conclusion, up to
   `CANARY_TIMEOUT` (1800s, measured from the dispatch -- Actions queue latency
   counts against it). The run is identified by the highest run id that existed
   *before* the dispatch, so a previous run can never be mistaken for this one,
   and preferred by the `Runner canary gen-<id>` run-name.
5. `success` promotes the generation. Anything else is a failed attempt.
6. Destroy the canary VM either way. **The candidate template is retained**, so
   a retry is a clone and a dispatch, not a 45-minute rebake.

Its exit status is a contract, because the unattended cycle will branch on it:

| Code | Meaning |
|---|---|
| `0` | passed, and the generation was promoted (or was already active) |
| `1` | an error in the gate itself: bad arguments, an unreadable store, a generation it cannot act on, or a promotion that failed after a passing canary |
| `2` | not attempted, and **no attempt was consumed** |
| `3` | the attempt failed and attempts remain -- retried on a later cycle |
| `4` | the budget is spent: the generation is `failed` and its digest is memoed |

**A canary failure is not by itself evidence of a bad image.** A GitHub Actions
incident, queue latency beyond `CANARY_TIMEOUT`, a host reboot mid-canary and
an expired PAT all look identical to one. So each failure notifies `warn`
(`canary.attempt_failed`) with the run URL and increments
`GEN_CANARY_ATTEMPTS`, and only the attempt that reaches `CANARY_MAX_ATTEMPTS`
(default 3) marks the generation `failed`, notifies `error` (`canary.failed`),
and **memoizes the digest** so the pipeline stops rebaking an image that cannot
pass. That is the one path where a canary failure reaches the memo; clearing it
means editing `/var/lib/github-runners/failed-digests`.

**Anything that cannot be attempted costs nothing.** `CANARY_ENABLED` not
`true`, an empty `CANARY_REPO`, a `CANARY_ORG` that names no configured
organization, a PAT GitHub rejects or that lacks the scope to dispatch, a
workflow that is missing or disabled, an unreachable API, a promotion holding
the clone path, or another canary already running: all of these leave the
candidate `pending` with its attempt budget untouched, and all but the last two
notify `warn` (`canary.unconfigured`). Burning the budget on a misconfiguration
would reject a perfectly good image.

Configuration (`/etc/github-runners.conf`, all optional -- the defaults are in
code, not written into the file):

```sh
CANARY_ENABLED=false              # set true once CANARY_REPO is configured
CANARY_ORG=                       # org config hosting the canary; the only
                                  # configured org when there is just one
CANARY_REPO=                      # <owner>/<repo>, or <repo> under CANARY_ORG
CANARY_WORKFLOW=runner-canary.yml
CANARY_PAT=                       # optional; defaults to the org PAT
CANARY_MAX_ATTEMPTS=3
CANARY_REGISTER_TIMEOUT=600
CANARY_TIMEOUT=1800
```

**PAT scope is validated before the clone, not discovered at the dispatch.**
`workflow_dispatch` needs `repo` on a classic PAT (`public_repo` suffices for a
public canary repo) or Actions: read and write on a fine-grained one, while the
org PAT `runner add-org` collects only needs `admin:org`. A classic PAT
advertises its scopes in `X-OAuth-Scopes`, so a missing one is named up front
and no attempt is consumed. Fine-grained tokens send no such header and cannot
be checked that way -- for those, a dispatch GitHub refuses with 401/403/404 is
classified the same way (not attempted, budget handed back, `warn`) rather than
counted as a canary failure. Two different tokens are in play: the canary
*registers* with the org PAT, like every other runner, and *dispatches* with
`CANARY_PAT` when one is set.

**Locks.** The gate holds one lock of its own, `/run/lock/github-runner-canary.lock`,
for the whole run, and takes no other lock directly -- that is what keeps it
clear of the promotion it exists to trigger. Underneath it, `clone_runner`
takes the pool activity lock *shared* (and defers while a promotion is paused),
and `runner promote` takes the promotion pause plus the pool lock
*exclusively*; neither wants the canary lock. The only other lock it touches is
the per-slot lock around its own VM destroy -- the same one the hookscript
re-clone path holds -- with a bounded wait.

**The canary VM is never re-cloned.** It is `--ephemeral`, so it powers off
after its one job and the hookscript fires `lib/reclone.sh`, which destroys any
VM tagged `runner-canary` and stops there. Re-cloning it would resurrect the
canary forever, and every resurrection would carry `gen-<id>-canary` and absorb
the next dispatch. `lib/watch.sh` needs no such rule: it fills slots by
`<RUNNER_PREFIX>-N` name match, and `canary-gen<N>` matches none.

### Installing it into `CANARY_REPO`

The copy in this repo is canonical; it has to be installed into whichever repo
hosts the canary (`CANARY_REPO`):

```bash
# in a clone of CANARY_REPO
mkdir -p .github/workflows
cp /opt/selfhosted-runners/templates/canary-workflow.yml \
   .github/workflows/runner-canary.yml
git add .github/workflows/runner-canary.yml
git commit -m "Add runner canary workflow"
git push
```

The filename must match `CANARY_WORKFLOW` (default `runner-canary.yml`), and
`workflow_dispatch` only becomes dispatchable once the file is on the repo's
default branch. Dispatching it needs `repo` scope on a classic PAT or
`actions:write` on a fine-grained one -- the org PAT collected by `runner setup`
only needs `admin:org`, so a separate `CANARY_PAT` may be required.

Edit the copy in this repo and reinstall it, **bumping
`CANARY_WORKFLOW_REVISION` in the same change**. A stale installed copy fails
an image for a reason that reads, in the log, exactly like a bad image; the
revision is echoed into the job log and step summary so an operator reading a
red run can tell the two apart at a glance.

### The label contract

The canary gate dispatches the workflow with the generation id as the
`generation` input, and the job targets `gen-<generation>-canary` -- **that label
alone, with no `self-hosted`**. Runner registration is JIT: the config a canary
clone boots with is minted on the Proxmox host (`fetch_jit_config` in
`lib/common.sh`) with `RUNNER_LABELS=gen-<generation>-canary`, and GitHub does
not add default labels to a JIT-registered runner, so that is exactly what the
canary carries -- there is no guest-side `config.sh`/`--no-default-labels` step
to opt out of defaults with. GitHub assigns a queued job to any idle runner
whose labels are a superset of `runs-on`, so adding `self-hosted` here would
make the canary eligible for real production jobs: it would run one on an
unvalidated image and then destroy itself (it is `--ephemeral`), leaving the
canary dispatch with no runner and rejecting a good image.

That "GitHub adds no default labels to a JIT-registered runner" is not just
trusted -- `fetch_jit_config` enforces it for every canary mint by comparing
the labels the `generate-jitconfig` response actually attached to the runner
against exactly what was requested. If GitHub ever does start attaching a
default (a read-only `self-hosted`/`Linux`/`X64`, say), the canary mint
deregisters that runner immediately and the clone fails closed -- **the
canary refuses to start rather than run unisolated**. This check applies to
canary mints only; a production mint is never second-guessed over a
legitimate read-only default GitHub attaches there.

The label decides who *may* answer the dispatch, not who did. Every toolchain
assertion below passes on any healthy runner of any generation, because the
pins are identical across generations by design -- so a stale `gen-N-canary`
label left on a production clone would absorb the dispatch, pass everything
trivially, and promote a candidate that never ran a job. The first step
therefore binds the run to the image under test and **fails** when it cannot:
it prefers a generation stamp at `/etc/github-runner/generation` and falls back
to the `canary-gen<N>` clone name. Nothing writes that stamp yet; when the bake
does, the binding survives any label mix-up.

Hand-dispatching against a runner you labelled yourself therefore needs
`strict=false`, which downgrades the binding to a notice and marks the summary
row NOT VERIFIED:

```bash
gh workflow run runner-canary.yml --repo <org>/<canary-repo> \
  -f generation=1 -f strict=false
```

### What it asserts

Roughly three minutes on a warm template, against `CANARY_TIMEOUT`'s 1800s
budget for dispatch through conclusion. (The job's own `timeout-minutes` starts
when the job begins executing, so queue latency counts against `CANARY_TIMEOUT`
only.)

- every baked tool actually **runs** -- `--version` on each, not `command -v`,
  since a binary whose runtime the bake pruned still resolves on `PATH`
- `psql` reports major `17`, and `pg_dump` completes a schema dump against the
  Supabase database it starts -- the version string alone would not catch the
  client/server mismatch the `17` pin exists to prevent
- `supabase --version` is `2.115.0`, parsed from stdout only so the CLI's
  "a new version is available" notice on stderr cannot be mistaken for the
  installed version
- `playwright install --dry-run` resolves Chromium into the prebaked
  `/home/runner/.cache/ms-playwright` rather than planning a download, both
  with `PLAYWRIGHT_BROWSERS_PATH` set and with it unset (which is how real jobs
  arrive, since the bake never exports it), and the resolved binary executes.
  There is no Playwright *CLI* version assertion: the bake installs browsers
  only and resolves the CLI from npm per invocation, so asking npm for
  `playwright@1.62.1` and checking that it reports `1.62.1` would assert
  nothing
- `aws --version` reports v2
- `docker pull` of the `pg_prove` image succeeds. When the runner has a mirror,
  it pulls the **rewritten** name from `SUPABASE_INTERNAL_IMAGE_REGISTRY`, the
  same way a Supabase job reaches the mirror, because that name has no upstream
  fallback -- pulling `public.ecr.aws/...` would succeed through the fallback in
  the bake's `hosts.toml` even with the mirror dead
- a `supabase start` / `supabase stop` round trip

Each assertion emits a GitHub `::error::` annotation naming what was expected and
what was found, because that annotation is what an operator sees quoted in the
promotion-blocked notification.

### Keeping version expectations in sync

The workflow runs in `CANARY_REPO` and cannot read this repo, so its expectations
are duplicated in the `env:` block at the top of the file rather than derived:

| `templates/template-setup.yaml` | `templates/canary-workflow.yml` |
|---|---|
| `POSTGRES_CLIENT_VERSION` | `EXPECTED_PSQL_MAJOR` |
| `SUPABASE_VERSION` | `EXPECTED_SUPABASE_VERSION` |
| `PLAYWRIGHT_VERSION` | `EXPECTED_PLAYWRIGHT_VERSION` |
| `PLAYWRIGHT_BROWSERS_PATH` | `PLAYWRIGHT_BROWSERS_PATH` |
| `SUPABASE_PG_PROVE_IMAGE` | `CANARY_PROBE_IMAGE` |

**Bumping a version on the left means bumping it on the right in the same
change, bumping `CANARY_WORKFLOW_REVISION`, and reinstalling the workflow.** The
cost of forgetting is not one red run: a canary failure is retried, and the
third failure marks the generation `failed` *and* memoizes its digest, so the
pipeline stops rebaking that image. A forgotten one-line `env:` bump can
blacklist a perfectly good template until someone clears the memo by hand, with
the log naming a version that was never installed. The failure messages name the
mapping for that reason.

## Updating Runners

The per-VM cloud-init snippet is rendered fresh from the template at every
clone, so to change runner bootstrap behavior you only edit the template and recycle:

1. Edit `/opt/selfhosted-runners/templates/runner-user-data.yaml`
2. Destroy a runner; the watcher recreates it from the updated template:
   ```bash
   runner destroy runner-01   # watcher recreates within ~30s
   ```

### Rotating a PAT

The PAT lives only on the Proxmox host in `/etc/github-runners.d/<org>.conf`.
Re-run `runner add-org`, enter the same org and the new PAT. The new token takes
effect on the next clone — no runner stores the PAT, so nothing else is needed.

To update prebaked software in the base VM template (does **not** destroy
the live clone target):

```bash
runner upgrade --dry-run
runner upgrade
```

That bakes a new generation in the 8900–8999 band and promotes it. Existing
clones keep running on the previous template until they recycle. Preview first
with `--dry-run`. If the active template is older than `REBAKE_MAX_AGE_DAYS`
(default 7), `--dry-run` shows `reason=weekly-floor` and upgrade rebakes even
when the digest is unchanged.

If a previous bake failed and the digest is memoed:

```bash
runner upgrade --force
```

### If the bake fails or appears stuck

`runner upgrade` bakes in `github-runner-upgrade.service`, not in the SSH
session. Ctrl-C on the CLI detaches (non-zero) and the unit keeps running.
A dropped SSH does **not** `bake_fail` or memo the digest.

The bake is gated so a partial template can never be published. The guest writes
its completion marker last and does **not** power itself off. Bake confirms that
marker over the guest agent while the VM is still running, then shuts the VM
down itself and only then converts it to a template.

- **Watch:** `journalctl -u github-runner-upgrade.service -f`. Guest log is on
  the **band** VMID (`planned_vmid` from `--dry-run`, or `bake_log=` on success),
  not on live `TEMPLATE_ID`:
  `qm guest exec <vmid> -- cat /var/log/template-setup.log`.
- **Timeout:** the bake aborts after 90 minutes. A healthy bake runs 30-45
  minutes. Override with `BAKE_TIMEOUT=<seconds> runner upgrade`.
- **`qm stop` on a stuck bake VM is safe.** The VM stopping without a confirmed
  marker is treated as failure — the cleanup trap destroys the partial band VM,
  never the live clone target, and memos the digest.
- **Memoed digest** (previous bake failed): `runner upgrade --force`. Do not
  run `runner setup` — on a host that already has a live template, setup
  adopts and skips the bake. Do not run `runner bake --force` over SSH; that
  is in-process and an SSH drop memos the digest again.
- **Checksum verification failed?** The cached Ubuntu image at
  `/var/cache/github-runners/` goes stale whenever upstream rotates
  `noble/current/`, roughly every 2-4 weeks. Bake deletes the bad file on its
  way out; `--force` downloads a fresh image. This is not a supply-chain
  compromise, though the error reads like one.

### The 30-day rebake deadline

Clones start the baked runner with `run.sh --jitconfig` (no `config.sh`, so
`--disableupdate` is not applied). GitHub still requires a reasonably current
runner version. **Rebake within 30 days of each new `actions/runner` release**
(sooner if it is a critical security update).

Miss it and the failure can be silent: runners show **Online / Idle** in the
GitHub UI while jobs queue forever — which looks like a GitHub incident, not a
stale template. Check the baked version against upstream by probing a **running
runner clone** — the template itself is never running, so `qm guest exec` cannot
reach it:

```bash
vmid=$(qm list | awk '$3=="running" && $2 ~ /runner/ {print $1; exit}')
qm guest exec "$vmid" -- /home/runner/actions-runner/bin/Runner.Listener --version | jq -r '."out-data"'
curl -sf https://api.github.com/repos/actions/runner/releases/latest | jq -r .tag_name
```

If those two outputs have drifted, the rebake is overdue. A clone that
self-updates on boot leaves versioned `bin.<version>` and `externals.<version>`
directories under `/home/runner/actions-runner` and re-downloads the ~225 MB
runner package on every job until the template is rebaked.

`runner stop` leaves the pool in maintenance mode until you run `runner start`.
The maintenance flag is `/var/lib/github-runners/drain`. It is on disk rather
than tmpfs, so it survives a host reboot: the watcher and `runner create` keep
refusing to clone after a reboot taken between `runner stop` and `runner start`.
The shutdown hookscript honors the same flag, but only once the copy deployed at
`/var/lib/vz/snippets/runner-hookscript.sh` has been refreshed by `install.sh` or
`runner setup` -- an older deployed copy still reclones a VM that stops
mid-maintenance, so refresh it before relying on a reboot.

Older releases kept the flag on tmpfs at `/run/lock/github-runner-drain`. That
path is still read and written, `install.sh` migrates an active drain to the
persistent path when you upgrade, and `runner start` clears both. A drain set by
an older release and never migrated is still tmpfs-only, so it does **not**
survive a reboot -- upgrade first, or re-run `runner stop` after the upgrade.
On full stops, it also frees orphaned linked-clone child volumes for every
recorded generation when those volumes no longer have a VM config anywhere in the cluster.
If any child volumes still belong to live VM/template configs, `runner stop`
fails and tells you to resolve those dependents before deleting the template.

`runner stop --vmid-range <min:max>` is for partial maintenance windows only.
Do not use a VMID-limited stop immediately before destroying a linked-clone
template, because every dependent clone must be removed before `qm destroy`
will succeed.

`runner rollover --force` locates the guest's single `Runner.Listener`, freezes
its actual cgroup-v2 cgroup before removal, verifies that no `Runner.Worker`
exists, waits for GitHub to acknowledge it offline, and preserves another
GitHub-online runner for the organization. Zero-downtime rollover is not
supported when `RUNNER_COUNT=1`: the command exits nonzero before mutating the
runner. Temporarily increase the configured pool to at least two, wait for the
watcher to register a GitHub-online peer, and then rerun rollover. GitHub
exposes no atomic "lease idle runner and delete" operation, so
the host-side freeze is the assignment boundary; the REST `busy` field is not
treated as a lock. Interrupted operations are recovered from
`/var/lib/github-runners/rollover-pending`, and the watcher may refill a slot
while it keeps retrying destruction of a deregistered residual by VMID.

## Generation Garbage Collection

`runner maintain` runs generation garbage collection automatically. Preview the
same decisions without changing records, VMs, or storage with:

```bash
runner gc --dry-run
```

GC keeps the newest superseded generation as the rollback target and destroys
older superseded generations only after their last runner clone is gone. It
also expires abandoned candidates and retains failed or rejected generations
for inspection for `FAILED_GEN_RETAIN_DAYS` (default 7). A superseded
generation blocked longer than `GC_STUCK_WARN_HOURS` (default 12) emits a warn
notification naming the blocking VMIDs. A destroy or volume-cleanup failure
leaves the generation record in place so the next run can safely retry.

## Notifications

Failures that need a human are pushed to a webhook instead of being left in
journald. Notifications are **off until you configure a webhook URL** -- with
none set, nothing changes anywhere in the platform.

Add these keys to `/etc/github-runners.conf`:

```sh
NOTIFY_WEBHOOK_URL="https://hooks.slack.com/services/T000/B000/xxxx"
NOTIFY_MIN_SEVERITY="warn"   # info|warn|error -- anything below this is dropped
NOTIFY_FORMAT="slack"        # slack|text
```

> `runner setup` rewrites `/etc/github-runners.conf` from its own prompts and
> does not preserve keys it did not ask about. Re-add the `NOTIFY_*` lines after
> re-running the wizard.

For Slack, create an **incoming webhook** for the channel you want alerts in and
paste its URL. The body is a Slack incoming-webhook payload:

```json
{
  "text": "[pve] bake failed for generation 8: image checksum mismatch after retry",
  "severity": "error",
  "event": "bake.failed",
  "host": "pve",
  "generation": 8,
  "detail": "expected 5fa5b05e... got ..."
}
```

Slack renders `text` and ignores the rest, so the same body also serves a
generic consumer that wants the structured fields. `NOTIFY_FORMAT="text"` sends
the `text` field alone as a plain body, for ntfy-style consumers.

What this is designed to do, and not do:

- **A notification never fails or blocks a runner operation.** A webhook that is
  down, wrong, or unset is treated exactly like one that was never configured:
  the failure is logged and the operation continues.
- **Delivery is bounded.** One attempt plus at most two retries, 10 seconds each
  with 3 seconds of backoff, so a black-holed webhook can hold an operation for
  about 33 seconds and no longer.
- **Secrets are scrubbed, within limits.** Every payload and every log line goes
  through a redaction pass. It strips this platform's own secrets verbatim --
  the org PATs from `/etc/github-runners.d/*.conf` and `NOTIFY_WEBHOOK_URL` --
  plus known credential shapes that arrive embedded in someone else's error
  text: `ghp_...`, `github_pat_...`, `https://user:token@host/...`,
  `Authorization: Bearer|Basic ...`, `password ...`, `-u user:pass`,
  `?access_token=...`, and Slack/Discord/Teams webhook URLs. This is a
  chokepoint, not a proof -- a third-party credential in a shape none of those
  rules match can still get through, so prefer a summary over raw command
  output when you build a `detail` string.
- **No history, no dedup, no email.** This is a push to one webhook.

Currently emitted: `clone.failed`, when the watcher cannot fill runner slots
and when a re-clone leaves a slot empty. The watcher sends one notification per
run rather than one per slot, at `error` when every slot it attempted failed
(a pool-wide problem: bad template, revoked PAT, full storage) and at `warn`
when only some did.

To try it without waiting for a real failure:

```bash
bash -c 'source /opt/selfhosted-runners/lib/common.sh
         notify warn test.notification "test from $(hostname -s)" "no action needed"'
```

## Troubleshooting

### Runner doesn't appear in GitHub after 5 minutes

**Check cloud-init logs:**
```bash
qm guest exec <vmid> -- cat /var/log/cloud-init-output.log
```

**Check runner setup log:**
```bash
qm guest exec <vmid> -- cat /var/log/runner-setup.log
```

**Common causes:**
- PAT lacks runner access (`admin:org`, or fine-grained `Self-hosted runners: Read and write`)
- Organization name is misspelled
- Network connectivity issues (check DNS, firewall)

### "Configuration not found" error

Run `runner setup` first to create the configuration.

### "Template VM does not exist" error

The live clone target is gone. Preview then bake a new generation:

```bash
runner upgrade --dry-run
runner upgrade
```

Do not re-run `runner setup` if VM 9000 still exists — setup will adopt it and skip the bake.

### VM creation fails with "storage not found"

The storage pool specified during setup doesn't exist. Re-run `runner setup` and select a valid storage pool.

### Runner shows "Offline" in GitHub

The runner is a foreground `run.sh --jitconfig` started by cloud-init, not a
systemd unit. If that process exits, the EXIT trap shuts the VM down and the
hookscript reclones the slot.

**Check VM status:**
```bash
qm status <vmid>
```

**Check the directly launched runner listener:**
```bash
qm guest exec <vmid> -- pgrep -a -x Runner.Listener
```

**Check the in-guest setup log (while the VM is still running):**
```bash
qm guest exec <vmid> -- cat /var/log/runner-setup.log
```

Inspect it while it is still up: a stopped VM is reclaimed by the lifetime guard
and refilled by the watcher, so `qm stop` is a recycle, not a pause. That does
make `qm stop` the right way to *replace* a stuck ephemeral runner — the Proxmox
hookscript destroys the VM and reclones its slot:
```bash
qm stop <vmid>
```
If the VM is already stopped, wait for the watcher (or run `runner watch`) to
refill the slot.

### Docker commands fail in workflows

Make sure your workflow uses the correct user context:
```yaml
jobs:
  build:
    runs-on: [self-hosted, linux, x64]
    steps:
      - run: docker run hello-world
```

### Network timeouts during setup

The runner VM might not have network connectivity. Check:
- Network bridge exists and is configured
- DHCP is working on the network
- No firewall blocking outbound connections

### PAT expired or invalid

1. Generate a new PAT in GitHub
2. Update the org config (PAT stays on the host, never in a VM):
   ```bash
   runner add-org   # enter the same org name and the new PAT
   ```
   The new token is used on the next clone. Existing runners keep working until
   their next job; recycle one immediately with `runner destroy <name>` if needed.

## Files Created by Setup

| Location | Purpose |
|----------|---------|
| `/opt/selfhosted-runners/` | Installed scripts and templates |
| `/usr/local/bin/runner` | Symlink to runner entrypoint |
| `/etc/github-runners.conf` | Infrastructure config (bridge, storage, template ID) |
| `/etc/github-runners.d/<org>.conf` | Per-org config (PAT, prefix, count, runner group ID) — mode 600 |
| `/var/lib/vz/snippets/runner-<vmid>-user-<org>.yaml` | Per-VM cloud-init (single-use JIT config) |
| `/var/lib/vz/snippets/runner-<vmid>-meta.yaml` | Per-VM cloud-init metadata |
| VM template (default ID 9000) | Ubuntu cloud image template |

## Security Notes

- **PAT never enters the VM**: The org PAT (`admin:org`, or a least-privilege
  fine-grained token — see Prerequisites) stays on the Proxmox host in
  `/etc/github-runners.d/<org>.conf` (mode 600, root-only). At clone time
  the host calls GitHub's `generate-jitconfig` API and injects only the returned
  **single-use JIT (just-in-time) config** via cloud-init.
- **JIT config is single-use**: the config registers exactly one ephemeral
  runner and cannot be replayed to register another. The in-VM script removes the
  at-rest filesystem copies before the job runs; the config does still exist on
  the attached cloud-init drive (`/dev/sr0`) and on `run.sh`'s command line while
  the runner is up, but because it is single-use a job that recovers it cannot
  register a rogue runner. This is the recommended GitHub mechanism for
  short-lived runners and removes the reusable-token exposure entirely.
- **Upgrade recycle**: after deploying this change, existing VMs still have the
  old PAT on their cloud-init drive until they are destroyed. Recycle the pool
  with `runner stop` then `runner start`.
- **Other host-side secrets**: `/etc/github-runners.conf` holds infrastructure
  settings and — if you configure notifications — `NOTIFY_WEBHOOK_URL`, which is
  itself a credential; it is written mode 600 for that reason.
- **Secrets in notifications**: notification payloads and log lines are scrubbed of the configured org PATs, the webhook URL, and known credential shapes (see [Notifications](#notifications) for what that does and does not cover), and the URL is handed to `curl` through a config file rather than argv so it never shows up in `ps`.
- **Runner user**: VMs run as user `runner` with NOPASSWD sudo and `docker`
  group membership (both root-equivalent inside the VM) — required for Docker.
- **⚠️ Do not use these runners on public repositories.** Self-hosted runners
  execute workflow code from any PR, including forks. A malicious PR would get
  full root inside the VM. Restrict the org's runners to **private repos** in
  GitHub → Org Settings → Actions → Runner groups. The VM is ephemeral, but the
  job is still arbitrary code execution on your host's network.
- **Rotate PAT**: re-run `runner add-org` with the new PAT (effective next clone).

## Limitations

- **Single Proxmox node**: Scripts assume single-node setup
- **DHCP required**: VMs get IPs via DHCP
- **No auto-scaling**: Manual runner creation/destruction
- **Org-level only**: Repository-level runners not supported by these scripts

## Resource Planning

| Runners | CPU Cores | RAM | Storage |
|---------|-----------|-----|---------|
| 1 | 2 | 8 GB | 30 GB |
| 4 | 8 | 32 GB | 120 GB |
| 8 | 16 | 64 GB | 240 GB |

Plus ~30GB for the template VM.

## Development

Everything here runs on a laptop. No Proxmox host is involved: `qm`, `pvesm`,
`pvesh`, `zfs`, `curl`, `jq` and `logger` are fake executables placed ahead of
the real ones on `PATH`. Needs bash 4+ (`brew install bash` on macOS).

```bash
./tests/run.sh          # everything CI runs: shellcheck, yamllint, bats
./tests/run.sh lint     # shellcheck + yamllint only
./tests/run.sh unit     # bats only
```

`tests/run.sh` fetches `bats-core` into `tests/.bats/` (gitignored) the first
time it runs, unless a recent enough `bats` is already installed. With bats on
your `PATH`, `bats tests/unit` works directly. `shellcheck` and `yamllint` are
skipped with a notice if you do not have them; in CI a missing linter is a
failure. The same gates run on every pull request
(`.github/workflows/ci.yml`).

### Writing a test

Test files are `tests/unit/*.bats`. Read `tests/unit/harness_smoke.bats`
first — it is the worked example for the whole stub API.

```bash
load test_helper

setup() {
    load_lib                      # sources lib/common.sh
}

@test "get_vm_org reads the org out of cicustom" {
    stub_out qm 'config 501' <<'EOF'
cicustom: user=local:snippets/runner-user-data-acme.yaml
EOF

    run get_vm_org 501
    [ "$output" = "acme" ]
    assert_called qm 'config 501'
}
```

`load test_helper` (`tests/test_helper.bash`) is what makes a test file safe to
run anywhere:

- `tests/stubs/bin` goes first on `PATH`, so the Proxmox CLI, `curl`, `jq` and
  `logger` are fakes that record every call.
- `tests/compat/bin` goes last, filling in GNU tools missing on macOS. Real
  coreutils always win.
- `load_lib` sources `lib/common.sh`, repoints its host path constants into a
  per-test temp directory, and only then sources the file you asked for.

| Helper | Purpose |
|---|---|
| `stub_out <cmd> <pattern> [rc]` | stdout (from stdin) for calls whose arguments glob-match `<pattern>` |
| `stub_status <cmd> <pattern> <rc>` | same, no output — "this call fails" |
| `stub_lenient` / `stub_strict` | opt out of / back into strict stubbing |
| `stub_calls <cmd>` | every invocation, one argument list per line |
| `call_count <cmd> [pattern]` | how many times it was called |
| `assert_called` / `refute_called` | assert on the call log |
| `write_infra_config` | write `$CONFIG_FILE` and set `VM_STORAGE`/`TEMPLATE_ID`/… |
| `write_org_config <org>` | drop an org config into the sandbox |

The newest matching rule wins, so a test can override something registered in
`setup()`. For behavior a canned response cannot express — output that changes
between calls — define a `<cmd>_stub` function and `export -f` it; the fake
command calls it instead.

**Strict by default.** A call no rule matches fails with exit 97 and prints the
call log. Real `qm` and `pvesm` exit non-zero on a bad subcommand or a missing
volume, so a stub that returned 0 for everything would make every error path
unreachable and let a test pass while asserting nothing. `stub_lenient` turns
that off where the calls genuinely do not matter — except for `qm destroy`,
`qm stop`, `pvesm free` and `zfs destroy`, which always need an explicit rule.

**What isolation covers.** `load_lib` rewrites the host path constants in
`lib/common.sh` — `CONFIG_FILE`, `ORG_CONFIG_DIR`, `SNIPPETS_DIR`,
`PVE_NODES_DIR` and the `/run/lock` paths — plus any later constant whose value
points at `/etc`, `/run`, `/var/lib`, `/var/log` or `/var/spool`, including one
derived from another at source time. Demonstrated by the three isolation tests
in `tests/unit/harness_smoke.bats`. It covers **shell constants only**: a host
path written as a literal inside a function body is invisible to it and would
be used for real, so keep host paths in the constants block at the top of
`lib/common.sh`. Renaming one of them fails the suite rather than silently
un-sandboxing it.

Faking another command is one symlink:

```bash
ln -s _stub tests/stubs/bin/systemctl
```

Do not fake `flock`. `reserve_vmid` and the clone-slot allocator are contention
loops; a `flock` that always succeeds would validate them against semantics
that cannot occur on a real host. Every lock path is inside the sandbox
already, so real `flock` calls are harmless.

Unit tests cover pure shell logic only. Anything that just shells out to `qm`
with no logic of its own is validated on the test host, not here.

## License

MIT License - see [LICENSE](LICENSE) file.
