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
| `runner help` | Show available commands |

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

### Template rebake

GitHub stops accepting a runner about 30 days after its release. A daily timer,
`github-runner-rebake.timer`, is separate from `github-runner-watch.timer`. Once
a day it compares the `Runner.Listener` version recorded on the host with the
latest `actions/runner` release. It bakes when those versions differ, or when
the template was last successfully baked 21 days ago, whichever comes first.
A matching runner version in a template younger than 21 days does not start a
bake. Baking the same release resets the template age.

`runner rebake` reads `/etc/github-runners.conf` and does not ask the eight
setup questions. The bridge, VLAN, storage, minimum VMID, balloon, DNS, and
Docker mirror stay as they are. It builds a second VM while the current
template keeps serving clones, and it holds that VMID's reservation for the
whole bake. `reserve_vmid` starts at `MIN_VMID` and walks upward, and the
watcher runs every 30 seconds. `TEMPLATE_ID` changes only after `qm template`
succeeds on the new VM. Running clones finish their current job, or hit the
6-hour shutdown, and the next clone of that slot comes from the new image.
The previous template is destroyed only once no linked clone still depends on
it. A failed bake destroys the partial VM and leaves `TEMPLATE_ID` and the live
template as they were.

The runner tarball download stays inside this bake, as do the image pulls the
template already bakes (Supabase CLI, Playwright, and Docker images via the
configured mirror). Clones do not gain a download path for any of those.

Both `run.sh --jitconfig` lines pass `--disableupdate`. That flag is not a
valid `run` option: the listener warns and continues. What stops GitHub pushing
a new runner package onto the clone is `disableUpdate: true` in the JIT
`.runner` document. The clone sets that bit before `run.sh` and exits 1 if the
patch fails, so it does not start a self-updating runner. A clone that did
self-update leaves versioned `bin.<version>` and `externals.<version>`
directories under `/home/runner/actions-runner` and re-downloads the runner
package on every job.

The host records the baked version in
`/var/lib/github-runners/baked-runner-version` at the end of a successful bake.
The record also stores `baked_at`, the successful bake time as Unix seconds;
release publication time is metadata and does not drive template freshness.
Older records without `baked_at` trigger one refresh to establish that time.
The guest writes the version from `Runner.Listener --version` while it is still
up. The template is stopped afterward, so `qm guest exec` cannot read it later.

`runner rebake` detaches from the SSH session (the systemd service when that
unit is installed, otherwise `setsid`) so a dropped connection does not kill
the bake. Follow it with `journalctl -u github-runner-rebake.service -f`, or
`/var/log/github-runner-rebake.log` when it detached with `setsid`.
`runner rebake --foreground` stays attached; run that form inside tmux.

A healthy bake is 30–45 minutes. The bake aborts after 90 minutes
(`BAKE_TIMEOUT`, default 5400). The guest writes `/opt/.template-setup-complete`
last and does not power itself off. The host confirms that marker over the
guest agent, then shuts the VM down, and only then runs `qm template`. Stopping
the bake VM before that marker is confirmed destroys the partial VM and does
not publish it.

A Noble checksum mismatch deletes
`/var/cache/github-runners/noble-server-cloudimg-amd64.img` and exits 1 before
creating a template VM. Upstream rotates `noble/current/` every few weeks. Run
the bake again; it downloads a fresh image. The error is a stale cache, not a
supply-chain alarm.

The first check on a host with no recorded version bakes once. After a template
baked by an older setup, record the version that bake installed if that extra
bake should wait. Use the version the bake logged (`Latest runner version`),
which the guest wipes from its own log before it finishes. Set `baked_at` to
the time that manual bake completed:

```bash
install -d -m 700 /var/lib/github-runners
cat > /var/lib/github-runners/baked-runner-version <<EOF
version=2.329.0
published_at=''
template_id=9000
baked_at=$(date -u +%s)
EOF
chmod 600 /var/lib/github-runners/baked-runner-version
```

`github-runner-rebake.timer` is persistent (`OnCalendar=daily`). Enabling it
after today's slot has passed can start that check immediately. Enable it only
after the current template bake has finished.

To refresh prebaked software before the release is stale, edit
`/opt/selfhosted-runners/templates/template-setup.yaml`, remove
`/var/lib/github-runners/baked-runner-version`, and run `runner rebake`. That
reads the saved infra config. It does not re-prompt, and it leaves running
clones up.

`runner setup` is still the interactive wizard, and it is how you create the
template the first time. It skips the bake when the configured template VMID
already exists (`qm status` succeeds), so a second setup does not refresh the
image. The wizard reads `/etc/github-runners.conf`, when present, and prefills
its eight prompts with editable saved settings. Press Enter to keep a prefilled
value, edit it to change the setting, or clear the line with Ctrl-U and press
Enter to select the standard default shown in brackets. Empty VLAN and Docker
mirror inputs disable those options. With no saved config, or with piped input,
an empty line selects the standard default. Org configs and PATs are not touched; `add-org`
runs only when no orgs exist yet. Run `runner setup` under tmux. It is
interactive, and a dropped SSH session fires the cleanup trap and throws away
an in-progress setup bake.

Before running `install.sh` on a host that already has `/opt/selfhosted-runners`,
diff that tree. `install.sh` replaces it with GitHub master, and the copy on
the host is not necessarily the commit you last installed.

`runner stop` without `--vmid-range` destroys every managed runner VM for every
configured org. With three orgs, that is every managed VM across all three.
The in-progress rebake VM is named `ubuntu-cloud-template` and has no org
snippet, so stop does not treat it as a managed runner. `runner stop` leaves
the pool in maintenance mode until `runner start`. The maintenance flag lives
in `/run/lock/`, which is tmpfs. It does not survive a host reboot, and the
watcher timer stays enabled, so a reboot mid-maintenance resumes runner
creation. Do not reboot the Proxmox host between `runner stop` and
`runner start`. On a full stop it also frees orphaned linked-clone child
volumes for the current template when those volumes no longer have a VM config
anywhere in the cluster. If any child volumes still belong to live VM or
template configs, `runner stop` fails and tells you to resolve those dependents
before deleting the template.

`runner stop --vmid-range <min:max>` is for partial maintenance windows only.
Do not use a VMID-limited stop immediately before destroying a linked-clone
template, because every dependent clone must be removed before `qm destroy`
will succeed. `runner stop --watch-only` stops the watcher and leaves the VMs
up.

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

The template was deleted. Re-run `runner setup` to recreate it.

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

**Check the in-guest setup log (while the VM is still running):**
```bash
qm guest exec <vmid> -- cat /var/log/runner-setup.log
```

If the VM is already stopped, wait for the watcher (or run `runner watch`) to
refill the slot. Do not `qm stop` a runner to inspect it — the watcher will
reclaim a stopped VM.

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
| `/var/lib/github-runners/baked-runner-version` | `Runner.Listener` version recorded at the end of a successful bake |
| `github-runner-watch.timer` | Pool filler, 30 seconds after the previous run |
| `github-runner-rebake.timer` | Daily template staleness check, separate from the watcher |
| VM template (default ID 9000) | Ubuntu cloud image template |

## Security Notes

- **PAT never enters the VM**: The org PAT (`admin:org`, or a least-privilege
  fine-grained token — see Prerequisites) stays on the Proxmox host in
  `/etc/github-runners.d/<org>.conf` (mode 600, root-only). `/etc/github-runners.conf`
  holds infrastructure settings only and contains no secrets. At clone time
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

## License

MIT License - see [LICENSE](LICENSE) file.
