# selfhosted-runners

Zero-touch setup for self-hosted GitHub Actions runners on Proxmox.

Runners are ephemeral: one job, shutdown, auto-destroy, watcher recreates. The
base image is a **generation** — a baked template plus provenance. The platform
bakes a new candidate when inputs change (or once a week); **you** promote it
with `runner upgrade`. Nothing in the normal path destroys the live clone
target.

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
1. Ask for GitHub org, PAT, network bridge, storage pool
2. Install to `/opt/selfhosted-runners`
3. Add `runner` command to `/usr/local/bin`
4. Adopt the existing template as generation 1, or bake and promote the first
   generation if none exists
5. Enable the watch, guard, and daily maintain timers

The watcher then fills each org's pool (`RUNNER_COUNT`). To add a spare by hand:

```bash
runner create runner-01
```

After setup, preview and promote a new image with:

```bash
runner upgrade --dry-run
runner upgrade
```

Do **not** `qm destroy` the live clone target (`TEMPLATE_ID`, often still 9000
until the first promotion).

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│ Proxmox Host                                                    │
│                                                                 │
│  /etc/github-runners.conf   TEMPLATE_ID ──► active generation   │
│  /var/lib/github-runners/generations/<vmid>.conf                │
│                                                                 │
│  Band 8900–8999                 Clone target (TEMPLATE_ID)      │
│  ┌────────────┐  runner upgrade  ┌────────────┐                 │
│  │ candidate  │ ───────────────► │   active   │  adopted 9000   │
│  │  gen N+1   │    (promote)     │   gen N    │  or a band VMID │
│  └────────────┘                  └─────┬──────┘                 │
│        ▲                               │ clone                  │
│        │ bake                          ▼                        │
│  maintain.timer 02:30         runner-01  runner-02  runner-03   │
│  (does not promote)             2c/8GB     2c/8GB     2c/8GB    │
│                                                                 │
│  watch.timer  30s   fill pools                                  │
│  guard.timer   5m   reap stopped / over-age VMs                 │
│                         GitHub orgs (runners shared by repos)   │
└─────────────────────────────────────────────────────────────────┘
```

`TEMPLATE_ID` stays the clone pointer. Promotion rewrites it. Existing clones
keep their old template until they recycle.

## Generations

A **generation** is one baked Proxmox template plus a record of how it was
built (runner version, cloud-image checksum, input digest). Generations are
immutable once baked. Exactly one is **active** — the clone target — at a time.

| State | Meaning |
|---|---|
| `baking` | Band VM installing tools. Not a template. Never cloned. |
| `candidate` | Bake confirmed and converted to a template. Not yet the clone target. |
| `active` | `TEMPLATE_ID` points here. New clones come from this VMID. |
| `superseded` | Was active; a newer generation was promoted. In-flight clones keep running on it. |
| `failed` | Bake failed. Partial band VM is destroyed; the live clone target is not. |
| `rejected` | Reserved for rollback (not in this release). |

Records live at `/var/lib/github-runners/generations/<vmid>.conf`. New bakes
allocate from `TEMPLATE_BAND_MIN`–`TEMPLATE_BAND_MAX` (default 8900–8999),
**below** runner VMIDs (`MIN_VMID`, default `TEMPLATE_ID + 1`). An adopted
template keeps its existing VMID (9000 on a host that already had one).

### What happens when a generation is promoted

1. The candidate is marked `active`.
2. `TEMPLATE_ID` in `/etc/github-runners.conf` is rewritten to that VMID.
3. The previous active is marked `superseded`.
4. In-flight runners finish on the old template. The watcher and shutdown
   hookscript clone **new** VMs from the new pointer.
5. Clones are tagged `runner,gen-<id>` from the template VMID they were
   actually cloned from.

The fleet does not drain for a promote. Garbage collection of superseded
templates is **not in this release** — they stay on disk. Do not destroy them
by hand; they may still have linked clones.

### Who bakes, who promotes

| Actor | What it does |
|---|---|
| `github-runner-maintain.timer` (daily 02:30) / `runner maintain` | Adopt if needed, reconcile interrupted bakes, detect, bake a **candidate** if needed. **Does not promote.** |
| You | `runner upgrade --dry-run` then `runner upgrade` — bake if needed and promote. |
| `runner setup` | No template at `TEMPLATE_ID`: bake and promote generation 1. Template already there: **adopt** it as generation 1 and skip the bake. |

`install.sh` on an existing host adopts and enables the maintain timer. It does
**not** bake or promote.

The first detect after adoption usually wants a bake: the adopted digest is
`unknown`, so it cannot match current inputs.

### Inspecting generations

`runner status` and `runner generations` are not in this release. Until they
ship:

```bash
runner upgrade --dry-run
ls /var/lib/github-runners/generations/
cat /var/lib/github-runners/generations/<vmid>.conf
grep ^TEMPLATE_ID= /etc/github-runners.conf
```

## Prerequisites

### Proxmox Host

- **Proxmox VE 7.x or 8.x**
- **Root access** to the Proxmox host
- **Storage pool** with at least 50GB free (template + runners); a bake needs
  `BAKE_MIN_FREE_GB` (default 60) free so a candidate can exist next to the
  active generation
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
- **Personal Access Token (PAT)** with `admin:org` scope

#### Creating a GitHub PAT

1. Go to GitHub → Settings → Developer settings → Personal access tokens → **Tokens (classic)**
2. Click **Generate new token (classic)**
3. Set expiration (recommend 90 days)
4. Select scope: **`admin:org`** (full control of orgs and teams)
5. Click **Generate token**
6. Copy the token (starts with `ghp_`)

> **Note**: Fine-grained tokens don't currently support runner registration. Use classic tokens.

## Runner Specs

| Resource | Value | Rationale |
|----------|-------|-----------|
| CPU | 2 cores | Matches GitHub-hosted |
| RAM | 8 GB | GitHub-hosted has 7GB |
| Disk | 30 GB | OS + Docker + headroom |

## Commands

After setup, the `runner` command is available globally (`runner help`):

| Command | Description |
|---------|-------------|
| `runner setup` | Re-run the setup wizard |
| `runner add-org` | Add a GitHub organization |
| `runner remove-org [<org>]` | Remove a GitHub organization |
| `runner list-orgs` | List configured organizations |
| `runner create [--org <org>] <name>` | Create a runner VM manually |
| `runner destroy <name>` | Destroy a managed runner VM (`--vmid <vmid>` also works) |
| `runner start` | Exit maintenance mode and resume watcher |
| `runner stop [options]` | Enter maintenance mode and stop managed runners |
| `runner list` | List all runner VMs |
| `runner watch` | Fill runner pools (run by timer) |
| `runner guard [--dry-run]` | Reap stopped and over-age runner VMs (run by timer) |
| `runner bake [--force] [--dry-run]` | Bake a new **candidate** generation (does not promote) |
| `runner promote <id> [--skip-canary]` | Promote a candidate to active. Canary is not implemented; `--skip-canary` is required and asks for confirmation |
| `runner maintain` | Unattended adopt/detect/bake cycle (run by timer). Does not promote |
| `runner upgrade [--dry-run] [--force] [--foreground]` | Bake if needed and promote. This is the operator confirmation |
| `runner help` | Show available commands |

`runner stop` options: `--watch-only`, `--vmid-range <min:max>`, `--yes`.
`runner guard` also accepts `--stopped-only`, `--now`, and `--wait <seconds>`
(used by `runner start`).

### Not in this release

These verbs are specified for later work. They are **not** in `runner help` and
will fail as unknown commands. Do not invent flags for them.

| Command | Later purpose |
|---|---|
| `runner status` | Fleet overview |
| `runner generations` | Generation table |
| `runner canary` | Promotion gate (real GitHub job) |
| `runner rollback` | Point active at the retained previous generation |
| `runner rollover` | Drain old-generation clones |
| `runner gc` | Destroy superseded templates with no clones |
| `runner drift` | 30-day window alarm |

## Generation configuration

Generation keys are **not** written into `/etc/github-runners.conf` by setup.
Code defaults apply; add a line only to override. Invalid integers/bools fall
back to the default (except `REBAKE_WINDOW`, which fail-closes the bake).

| Key | Default | Meaning |
|---|---|---|
| `TEMPLATE_BAND_MIN` | `8900` | Low end of the VMID band for new generation templates |
| `TEMPLATE_BAND_MAX` | `8999` | High end of the band. Must sit below `MIN_VMID` |
| `REBAKE_ENABLED` | `true` | `false` skips detect-driven bakes (`upgrade --force` still bakes) |
| `REBAKE_MAX_AGE_DAYS` | `7` | Bake even when the digest is unchanged (weekly floor) |
| `REBAKE_WINDOW` | `02:00-06:00` | Host-local window when `maintain` may **start** a bake. `HH:MM-HH:MM`, no midnight wrap. `runner bake` and `runner upgrade` ignore the window |
| `BAKE_TIMEOUT` | `5400` | Seconds to wait for the guest completion marker (90 minutes) |
| `BAKE_MIN_FREE_GB` | `60` | Refuse to bake if `VM_STORAGE` has less free than this |
| `CANARY_ENABLED` | `false` | Leave false. `true` makes `runner upgrade` refuse (it skip-canaries). `maintain` also refuses to bake when this is true and `CANARY_REPO` is empty |
| `CANARY_REPO` | *(empty)* | Required only if you set `CANARY_ENABLED=true` before canary ships |
| `DETECT_FAIL_WARN_HOURS` | `24` | Notify `detect.failed` after this many hours of consecutive digest-fetch failures. The weekly floor still applies |
| `GENERATION_RETAIN` | `1` | How many superseded generations to keep. **Unused until GC ships** |
| `FAILED_GEN_RETAIN_DAYS` | `7` | How long to keep a failed generation. **Unused until GC ships** |
| `CANDIDATE_MAX_AGE_DAYS` | `3` | Max age of an unpromoted candidate. **Unused until GC ships** |

`MIN_VMID` is required and must be an unsigned integer **greater than**
`TEMPLATE_BAND_MAX` (so `9000` or higher with the default band). `MIN_VMID=0`
(auto) is a hard error: `pvesh get /cluster/nextid` could land inside the band.
`install.sh` aborts an upgrade until it is set.

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
and run `runner upgrade` if you need to match a different server major version.

Note that the PGDG apt source is baked into the template permanently, so every
runner VM -- not just the Proxmox host at bake time -- needs `apt.postgresql.org`
reachable for any `apt-get update` a job runs. PGDG also supplies `libpq5`
(currently 18.x, which satisfies the client's dependency), so package listings
on runners will show a newer libpq than Ubuntu ships.

Playwright Chromium is baked into the runner user's default cache at
`/home/runner/.cache/ms-playwright`, so jobs running as `runner` can use it
without extra path configuration. Consumer repos need to pin Playwright to
`1.62.1` to use the prebaked cache. Change the pinned version in
`templates/template-setup.yaml` and run `runner upgrade` when upgrading
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

`runner canary` is **not in this release**. Promotion is `runner upgrade`, which
skip-canaries (and refuses if you set `CANARY_ENABLED=true`). Leave
`CANARY_ENABLED` at its default of `false`.

The workflow file is still the acceptance test for everything the bake installs,
and the future promotion gate: a runner cloned from the candidate must
**complete a real GitHub Actions job**. Registering is not evidence. Installing
it into `CANARY_REPO` now is optional prep.

Bake already stamps `/etc/github-runner/generation` on the guest after the
setup marker and before shutdown, so the binding step below works when the gate
ships.

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
revision is echoed into the job log and step summary so the gate can compare it
with the canonical copy before dispatching and refuse the run instead.

### The label contract

The canary job targets `gen-<generation>-canary` -- **that label alone, with no
`self-hosted`**. The canary registers with `--no-default-labels` so it carries
nothing else. GitHub assigns a queued job to any idle runner whose labels are a
superset of `runs-on`, so adding `self-hosted` here would make the canary
eligible for real production jobs: it would run one on an unvalidated image and
then destroy itself (it is `--ephemeral`), leaving the canary dispatch with no
runner and rejecting a good image.

The label decides who *may* answer the dispatch, not who did. Every toolchain
assertion below passes on any healthy runner of any generation, because the
pins are identical across generations by design -- so a stale `gen-N-canary`
label left on a production clone would absorb the dispatch, pass everything
trivially, and promote a candidate that never ran a job. The first step
therefore binds the run to the image under test and **fails** when it cannot:
it prefers the generation stamp at `/etc/github-runner/generation` and falls
back to the `canary-gen<N>` clone name.

Hand-dispatching against a runner you labelled yourself therefore needs
`strict=false`, which downgrades the binding to a notice and marks the summary
row NOT VERIFIED:

```bash
gh workflow run runner-canary.yml --repo <org>/<canary-repo> \
  -f generation=1 -f strict=false
```

### What it asserts

Roughly three minutes on a warm template. The job's own `timeout-minutes`
starts when the job begins executing.

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
what was found.

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
change, bumping `CANARY_WORKFLOW_REVISION`, and reinstalling the workflow.**
When the canary gate ships, a stale `env:` line can fail a good image and
memo the digest; keep them in sync now so the workflow is ready.

## Updating runners

### Cloud-init / bootstrap (every clone)

To update runner registration/bootstrap behavior (cloud-init that runs on every
cloned runner VM):

1. Edit `/opt/selfhosted-runners/templates/runner-user-data.yaml`
2. Re-run setup to regenerate the per-org runner cloud-init snippets:
   ```bash
   runner setup
   ```
3. Destroy and recreate **runner VMs** (not the template):
   ```bash
   runner destroy runner-01
   runner create runner-01
   ```

> **Record your config first.** The wizard re-prompts infrastructure questions
> and rewrites `/etc/github-runners.conf` from its own answers. It preserves
> `NOTIFY_*` and guard keys it already knows about, but it does not preserve
> keys it never asked about. Generation keys are code defaults, so they survive
> unless you had overrides in the file. Run `cat /etc/github-runners.conf`
> beforehand. Org PATs are not touched — `add-org` only runs when no orgs exist
> yet.

### Prebaked software (the normal path)

To update prebaked software in the base image, **do not destroy the live clone
target**:

```bash
runner upgrade --dry-run
runner upgrade
```

That is bake-if-needed then promote. Existing clones keep running on the
previous template until they recycle. Preview first with `--dry-run`. If the
active template is older than `REBAKE_MAX_AGE_DAYS` (default 7), `--dry-run`
shows `reason=weekly-floor` and upgrade rebakes even when the digest is
unchanged.

`runner upgrade` without `--foreground` starts `github-runner-upgrade.service`
and follows it. Ctrl-C detaches (non-zero); the unit keeps running. A dropped
SSH does **not** fail the bake or memo the digest.

`--foreground` bakes in this process (what the oneshot uses). `--force` ignores
digest equality, the weekly floor, a memoed digest, and `REBAKE_ENABLED=false`.

If a previous bake failed and the digest is memoed:

```bash
runner upgrade --force
```

`github-runner-maintain.timer` may already have baked a candidate overnight.
`upgrade --dry-run` then shows `bake_plan=skip (candidate exists)` and a
`promote_plan`; `runner upgrade` only promotes.

### The 30-day window

Runners register with `--disableupdate`, so they never self-update. That avoids
re-downloading the ~225 MB runner package on every job boot, but it puts the
image on a clock: a new `actions/runner` release must land in the fleet within
**30 days** (sooner if it is a critical security update).

Miss it and the failure is silent rather than loud. Registration keeps working,
runners show **Online / Idle** in the GitHub UI, and jobs simply queue forever
without being assigned -- which looks like a GitHub incident, not a stale
template.

This release handles detection and baking:

1. Daily `runner maintain` (02:30, inside `REBAKE_WINDOW`) compares the active
   digest to current inputs (`actions/runner` latest, Ubuntu `SHA256SUMS`,
   rendered `template-setup.yaml`, plus infra values). A new runner release
   changes the digest, so maintain bakes a **candidate**.
2. The weekly floor (`REBAKE_MAX_AGE_DAYS=7`) bakes even if detection is
   broken, unless that digest is memoed as failed.
3. **You** confirm promotion: `runner upgrade --dry-run` then `runner upgrade`.

Maintain does not auto-promote. `runner drift` is not in this release.

The manual probe is a **verification** step, not the primary detector. Probe a
**running runner clone** -- the template itself is never running, so
`qm guest exec` cannot reach it, and it has no `.runner` file because the bake
never runs `config.sh`:

```bash
vmid=$(qm list | awk '$3=="running" && $2 ~ /runner/ {print $1; exit}')
qm guest exec "$vmid" -- /home/runner/actions-runner/bin/Runner.Listener --version | jq -r '."out-data"'
curl -sf https://api.github.com/repos/actions/runner/releases/latest | jq -r .tag_name
```

With `--disableupdate` in force a clone's version equals the baked version, so
those two outputs should match. A successful `runner upgrade` prints
`runner_version=` in its summary.

Before `--disableupdate` shipped, a clone would silently self-update on boot. You
can still see the evidence on any long-lived clone: versioned `bin.<version>` and
`externals.<version>` directories under `/home/runner/actions-runner` are created
only by the self-update path, never by a fresh install.

### If the bake fails or appears stuck

The bake is gated so a partial template can never be published. The guest writes
its completion marker last and does **not** power itself off. Bake confirms that
marker over the guest agent while the VM is still running, then shuts the VM
down itself and only then converts it to a template.

- **Watch:** `journalctl -u github-runner-upgrade.service -f` (or
  `github-runner-maintain.service` for the timer). Guest log is on the **band**
  VMID (`planned_vmid` from `--dry-run`, or `bake_log=` on success), not on live
  `TEMPLATE_ID`:
  `qm guest exec <vmid> -- cat /var/log/template-setup.log`.
- **Timeout:** the bake aborts after 90 minutes. A healthy bake runs 30-45
  minutes. Override with `BAKE_TIMEOUT=<seconds> runner upgrade`.
- **`qm stop` on a stuck bake VM is safe.** The VM stopping without a confirmed
  marker is treated as failure — the cleanup trap destroys the partial **band**
  VM, never the live clone target, and memos the digest.
- **Memoed digest** (previous bake failed): `runner upgrade --force`. Do not
  run `runner setup` — on a host that already has a live template, setup
  adopts and skips the bake. Do not run `runner bake --force` over SSH; that
  is in-process and an SSH drop memos the digest again.
- **Checksum verification failed?** The cached Ubuntu image at
  `/var/cache/github-runners/` goes stale whenever upstream rotates
  `noble/current/`, roughly every 2-4 weeks. Bake deletes the bad file on its
  way out; `--force` downloads a fresh image. This is not a supply-chain
  compromise, though the error reads like one.

### Break-glass: bake and promote by hand

Use this only when `runner upgrade` cannot (oneshot unit missing, or you need
to inspect a candidate before promoting). It is **not** the normal path, and it
still must not destroy the live clone target.

Prefer `runner upgrade --force`, which runs as a systemd oneshot so an SSH drop
cannot memo the digest. If you must bake without promoting yet, do it under
`tmux` or `screen` — `runner bake` is in-process:

```bash
runner bake --dry-run
runner bake --force
# read GEN_ID from /var/lib/github-runners/generations/<vmid>.conf
runner promote <id> --skip-canary   # confirms on a tty; canary is not implemented
```

Never destroy the live clone target (`TEMPLATE_ID`, often still 9000 until the
first promotion). Never use `runner setup` to rebuild an existing template —
setup adopts it and skips the bake.

A failed bake cannot take the fleet down: the candidate is in the band, the
active pointer is unchanged, and cleanup refuses to destroy `TEMPLATE_ID`.

### Maintenance mode (`runner stop` / `runner start`)

`runner stop` leaves the pool in maintenance mode until you run `runner start`.
The flag is `/var/lib/github-runners/drain`. It is on disk rather than tmpfs, so
it **survives a host reboot**: the watcher and `runner create` keep refusing to
clone after a reboot taken between `runner stop` and `runner start`. You do
**not** need to avoid rebooting during a drain.

The shutdown hookscript honors the same flag, but only once the copy deployed at
`/var/lib/vz/snippets/runner-hookscript.sh` has been refreshed by `install.sh` or
`runner setup` -- an older deployed copy still reclones a VM that stops
mid-maintenance, so refresh it before relying on a reboot.

Older releases kept the flag on tmpfs at `/run/lock/github-runner-drain`. That
path is still read and written, `install.sh` migrates an active drain to the
persistent path when you upgrade, and `runner start` clears both. A drain set by
an older release and never migrated is still tmpfs-only, so it does **not**
survive a reboot -- upgrade first, or re-run `runner stop` after the upgrade.

On a full stop (no `--vmid-range`), `runner stop` also frees orphaned
linked-clone child volumes for the **current** `TEMPLATE_ID` when those volumes
no longer have a VM config anywhere in the cluster. If any child volumes still
belong to live VM/template configs, `runner stop` fails and tells you to resolve
those dependents. That cleanup is not a prelude to destroying the template —
leave `TEMPLATE_ID` alone.

`runner stop --vmid-range <min:max>` is for partial maintenance windows only;
it skips orphan-volume cleanup. `--watch-only` stops the watcher and sets the
drain but leaves running runner VMs in place (the lifetime guard still reaps
them). `--yes` skips the "type yes" prompt.

```bash
runner start    # reap stopped leftovers, clear drain, start watcher, fill pools
```

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

Create a Slack **incoming webhook** for the channel you want alerts in and paste
its URL. Default `NOTIFY_MIN_SEVERITY=warn` drops `info` events
(`bake.started`, `generation.promoted`) unless you set `info`.

> `runner setup` rewrites `/etc/github-runners.conf` from its own prompts. It
> preserves existing `NOTIFY_*` lines. Re-check the file if you re-run the
> wizard.

The body is a Slack incoming-webhook payload:

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
the `text` field alone as a plain body, for ntfy-style consumers. `generation`
is `null` unless the caller set a numeric generation id.

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

Events this release emits:

| Event | Typical severity | When |
|---|---|---|
| `clone.failed` | error (all slots) / warn (some) | Watcher cannot fill runner slots, or a re-clone left a slot empty. One notification per watch run, not per slot |
| `lifetime.forced_destroy` | warn | Guard destroyed a managed VM that outlived `MAX_VM_LIFETIME_HOURS` |
| `stopped_vm.reaped` | warn (info on `runner start`) | Guard destroyed a managed VM stuck `stopped` |
| `bake.started` | info | A bake began |
| `bake.failed` | error (warn if disk is short) | Bake failed or could not start |
| `generation.promoted` | info | A candidate is now active |
| `generation.reconciled` | warn | More than one `active` record; extras demoted to superseded |
| `promote.timeout` | warn | Promote gave up waiting for the pool activity lock |
| `detect.failed` | warn | Digest detection has failed for `DETECT_FAIL_WARN_HOURS` |
| `canary.unconfigured` | warn | `CANARY_ENABLED=true` but `CANARY_REPO` is empty — maintain refuses to bake |

Not in this release: `canary.attempt_failed`, `canary.failed`,
`generation.rolled_back`, `generation.destroyed`, `gc.blocked`,
`drift.warning`, `drift.critical`.

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
- PAT doesn't have `admin:org` scope
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

Do not re-run `runner setup` if VM 9000 (or whatever `TEMPLATE_ID` names) still
exists — setup will adopt it and skip the bake. Do not `qm destroy` a remaining
template to "force" a rebuild.

### VM creation fails with "storage not found"

The storage pool specified during setup doesn't exist. Re-run `runner setup` and select a valid storage pool.

### Runner shows "Offline" in GitHub

The runner VM might have stopped or the service crashed.

**Check VM status:**
```bash
qm status <vmid>
```

**Check runner service:**
```bash
qm guest exec <vmid> -- systemctl status actions.runner.*
```

**Restart runner service:**
```bash
qm guest exec <vmid> -- systemctl restart actions.runner.*
```

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
2. Update the configuration:
   ```bash
   runner setup  # Re-run wizard with new PAT
   ```
3. Recreate **runner VMs** (not the template):
   ```bash
   runner destroy runner-01
   runner create runner-01
   ```

## Files Created by Setup

| Location | Purpose |
|----------|---------|
| `/opt/selfhosted-runners/` | Installed scripts and templates |
| `/usr/local/bin/runner` | Symlink to runner entrypoint |
| `/etc/github-runners.conf` | Infrastructure config (bridge, storage, `TEMPLATE_ID` pointer) |
| `/etc/github-runners.d/<org>.conf` | Per-org config (PAT, runner prefix, pool size) |
| `/var/lib/vz/snippets/runner-user-data.yaml` | Cloud-init config for VMs |
| `/var/lib/github-runners/` | Persistent platform state (mode 700) |
| `/var/lib/github-runners/drain` | Maintenance flag (survives reboot) |
| `/var/lib/github-runners/generations/` | Generation records (`<vmid>.conf`, `.counter`, `archive.log`) |
| `/var/log/github-runners/` | Bake logs |
| `/var/cache/github-runners/` | Cached Ubuntu cloud image |
| `github-runner-watch.timer` | Fill runner pools (30s) |
| `github-runner-guard.timer` | Reap stopped / over-age VMs (5m) |
| `github-runner-maintain.timer` | Daily 02:30 adopt/detect/bake |
| `github-runner-upgrade.service` | Oneshot used by `runner upgrade` |
| Active generation template | Whatever `TEMPLATE_ID` names (9000 until the first promotion) |

## Security Notes

- **PAT storage**: PATs are stored per-org in `/etc/github-runners.d/<org>.conf` with mode 600 (root only readable). `/etc/github-runners.conf` holds infrastructure settings, and — if you configure notifications — `NOTIFY_WEBHOOK_URL`, which is itself a credential; it is written mode 600 for that reason.
- **Secrets in notifications**: notification payloads and log lines are scrubbed of the configured org PATs, the webhook URL, and known credential shapes (see [Notifications](#notifications) for what that does and does not cover), and the URL is handed to `curl` through a config file rather than argv so it never shows up in `ps`.
- **Runner user**: VMs run as user `runner` with sudo access (required for Docker)
- **Docker access**: The `runner` user is in the `docker` group
- **Rotate PAT**: Edit config, re-run `runner setup`, recreate runners

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

Plus ~30GB per generation template. Keep at least `BAKE_MIN_FREE_GB` (default
60) free on `VM_STORAGE` so a candidate can bake while the active generation
still has clones. Superseded templates stay until GC ships.

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
| `stub_status <cmd> <pattern> <rc]` | same, no output — "this call fails" |
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
