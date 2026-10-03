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
4. Start the pool watcher and the daily template rebake timers
5. Hand off to `runner add-org` for your first org + PAT

There is nothing else to run. The pool watcher, a 30-second timer, fills each
org's `RUNNER_COUNT` slots, named `<prefix>-1` to `<prefix>-<RUNNER_COUNT>`
(`runner-1` and `runner-2` with the `add-org` defaults). Each runner takes one
job, and its slot is cloned again afterwards. See them with:
```bash
runner list
```

`runner create <name>` adds an extra runner outside those slots. It is
re-cloned after every job, like a slot, until `runner destroy <name>` removes it.

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
│  │runner-1 │  │runner-2 │  │runner-3 │  ...                   │
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
- **Storage pool** for VM disks that supports linked clones, such as a
  `zfspool` (`local-zfs`) or `lvmthin` (`local-lvm`) storage. Setup lists only
  storages that allow VM disk images, and refuses thick LVM (`lvm`) and iSCSI,
  where `qm template` makes no base volume and every linked clone fails. A bake
  needs 30 GiB free on it, or 60 GiB on thick-provisioned ZFS; see
  [Resource Planning](#resource-planning).
- **Network bridge** (vmbr0 or custom) with internet access and DHCP. The bake
  VM and every runner VM use it.

### Network Requirements

The Proxmox host, the template bake VM and the runner VMs need outbound access
to the hosts below. The bake VM and the runners sit on the bridge and VLAN
chosen in setup, so allow that network as well as the host.

| Destination | Port | Purpose |
|-------------|------|---------|
| github.com | 443 | Runner connection, release downloads, `install.sh` archive. Host: `actions/runner` release check when api.github.com fails |
| api.github.com | 443 | Host: PAT check, JIT runner configs, stale-runner cleanup, `actions/runner` release check. Runners: GitHub API and action download links |
| *.actions.githubusercontent.com | 443 | Runner job messages, results service and OIDC tokens |
| codeload.github.com | 443 | Action downloads in jobs and the `install.sh` archive (api.github.com and github.com redirect here) |
| *.blob.core.windows.net | 443 | Job logs, job summaries, artifacts and caches |
| raw.githubusercontent.com | 443 | Quick Start one-liner (host) |
| download.docker.com | 443 | Docker installation |
| deb.nodesource.com | 443 | Node.js installation |
| awscli.amazonaws.com | 443 | AWS CLI v2 installer |
| www.postgresql.org | 443 | PGDG repository signing key |
| apt.postgresql.org | 443 | PostgreSQL client packages |
| registry.npmjs.org | 443 | Playwright package download |
| cdn.playwright.dev | 443 | Playwright browser downloads (required) |
| storage.googleapis.com | 443 | Playwright Chromium builds (Chrome for Testing); cdn.playwright.dev 307-redirects here (required) |
| playwright.download.prss.microsoft.com | 443 | Playwright FFmpeg mirror (optional: Playwright falls back to cdn.playwright.dev, and Chromium never uses it) |
| cloud-images.ubuntu.com | 443 | Ubuntu cloud image (host) |
| release-assets.githubusercontent.com | 443 | Supabase CLI `.deb` and Actions runner tarball (GitHub release downloads 302 here) |
| cli.github.com | 443 | GitHub CLI packages |
| archive.ubuntu.com, security.ubuntu.com | 80/443 | Ubuntu package archive and security updates |
| public.ecr.aws | 443 | Supabase service and database job images |
| d2glxqk2uabbnd.cloudfront.net | 443 | ECR Public blob storage (image layers 307-redirect here) |
| `DNS_SERVERS` (default 1.1.1.1, 8.8.8.8), or the DHCP servers | 53 | DNS for runner VMs (below) |

The table covers this tool, the template bake and the runner itself. The
Playwright rows follow from the pinned Playwright version, so recheck them when
you change it. Workflows also reach whatever their steps use, such as `ghcr.io`
for container actions. GitHub lists every host a self-hosted runner talks to,
including those for runner self-updates, packages and LFS, under *Accessible
domains by function* in its
[self-hosted runners reference](https://docs.github.com/en/actions/reference/runners/self-hosted-runners).

**DNS.** Each runner VM applies `DNS_SERVERS` from `/etc/github-runners.conf`
to `eth0` with `resolvectl`, in place of the servers DHCP offers. It keeps them
only if they resolve `github.com`, and the mirror's host name when
`DOCKER_MIRROR_URL` names a host rather than an IP address. Each name gets up
to three `resolvectl query` tries of at most 10 seconds, so a name that does
not resolve delays the boot by up to about 35 seconds. The clone then logs
`WARNING: DNS servers <list> cannot resolve <name>; using the DHCP servers instead`
in `/var/log/runner-setup.log`, runs `resolvectl revert eth0` and uses the DHCP
servers. Clones therefore still come up on a network that blocks public DNS,
or with a mirror that only a LAN resolver knows, as long as the DHCP servers
answer, but the fallback hides a wrong setting. Enter resolvers that answer
from the runner network, or answer `dhcp` at setup's DNS prompt to store
`DNS_SERVERS=''`. Without `DNS_SERVERS`, and after a fallback, clones use the
DHCP servers without the gateway, unless the gateway is the only one. The bake
VM always resolves through the servers DHCP gives it.

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

Each runner VM is a linked clone of the template. It runs one job, powers off,
and is replaced by a fresh clone with the same name. A runner that gets no job
powers off 6 hours after boot. When a job starts, the job-started hook
`/opt/runner-job-started.sh` (`ACTIONS_RUNNER_HOOK_JOB_STARTED`) restarts that
timer, so a job gets 6 hours from its own start. Job logs show:
`A job started hook has been configured by the self-hosted runner administrator`.
The watcher stops and recycles a runner VM that is still up after 12.5 hours.

Runner VMs take the first free VMIDs from `MIN_VMID` up (setup's default is
`TEMPLATE_ID+1`), and each rebake puts the new template in that range too. With
`MIN_VMID=0` they take the cluster's next free VMIDs, among your other guests.
Each watcher run also frees leftover VM volumes, such as those of failed
clones, unless a clone is in progress: image volumes on `VM_STORAGE` named
`vm-<id>-disk-N` or `vm-<id>-cloudinit` whose VMID has no VM or container
config on any node. A missing config counts only while pmxcfs serves
`/etc/pve`, which the sweep checks by listing `/etc/pve/nodes` just before and
just after each lookup. While pmxcfs is not serving it, for example while
pve-cluster restarts during an upgrade or after pmxcfs crashed, the sweep stops
for that run and logs
`[orphan-sweep] pmxcfs is not serving /etc/pve, so guest configs cannot be checked; stopping the sweep`;
the next run tries again. A failed clone then leaves its VMID's snippets and
volumes alone too, since a live runner's config at that VMID would be just as
invisible, and leaves the volumes to the sweep. The sweep covers VMIDs from `MIN_VMID` up,
never `TEMPLATE_ID` itself. With `MIN_VMID=0` it covers every VMID above
`TEMPLATE_ID`, your other guests' included, a floor that moves whenever a
rebake puts the template on a new VMID. Below the VMIDs it covers, it frees
such a volume only when `pvesm list` shows it as a linked clone of a runner
template (`base-<template>-disk-N/vm-<id>-disk-M` on ZFS or Ceph RBD): the
current template, or one on the rebake's retirement list that is still a
template named `ubuntu-cloud-template`. That way a runner disk left behind
there does not keep its template from being retired. Other volumes there, a
leftover `vm-<id>-cloudinit` included, stay. Set `MIN_VMID` above every VMID
your other guests use, keep no volume you want without a VM in that range, and
keep no linked clone of a runner template without a VM at any VMID.

The Notes field (`description`) of each runner VM reads
`selfhosted-runners org=<org> kind=slot|extra vmid=<vmid>`. Together with the
per-VM snippets, that is how the tool recognises its VMs, so do not edit it. A
VM is a managed runner of `<org>` when its `cicustom` has the whole property
`user=local:snippets/runner-<vmid>-user-<org>.yaml`, with its own VMID as
`<vmid>`, or `user=local:snippets/runner-user-data-<org>.yaml`, the per-org
snippet of runners cloned before single-use JIT configs, which names no VMID.
Failing both, the marker counts, but only on the VM whose VMID it names. A VM
whose snippet name only resembles these, such as `runner-2-user-data.yaml` or
`gitlab-runner-user-data-prod.yaml`, is not a managed runner, and no `runner`
command lists, stops or destroys it. A full clone of a runner VM copies its
Notes, `cicustom` and hookscript, but the marker and the per-VM snippet it
copies name the VMID of the VM it was cloned from. Without a per-org snippet,
such a clone is not a managed runner: `runner list` and `runner list-orgs`
leave it out, `runner stop` leaves it alone, `runner destroy` refuses it as not
managed, the watcher does not reclaim it, and when it stops, the reclone that
its copied hookscript starts skips it (`could not identify VM`).

Runner VMs are set to `reboot: 0`: a reboot inside the guest ends the VM like a
shutdown, and the runner is recycled.

## Commands

After setup, the `runner` command is available globally:

| Command | Description |
|---------|-------------|
| `runner setup` | Re-run the infrastructure setup wizard |
| `runner add-org` | Add a GitHub org (or rotate its PAT, or change its pool) |
| `runner remove-org [<org>]` | Remove a configured org |
| `runner list-orgs` | List configured orgs and runner counts |
| `runner create [--org <org>] <name>` | Create an extra runner VM outside the pool's slots |
| `runner destroy <name>` | Destroy a managed runner VM (the watcher refills a slot, not an extra runner) |
| `runner start` | Exit maintenance mode, clear failure holds and fill the pool |
| `runner stop [options]` | Enter maintenance mode and stop managed runners |
| `runner list` | List all runner VMs |
| `runner watch` | Fill missing slots and recorded extra runners, and reclaim dead runner VMs (run by a 30s timer) |
| `runner rebake [--foreground]` | Bake a replacement template when the baked runner is stale |
| `runner help` | Show available commands |

Runner names and prefixes become Proxmox VM names, so `runner create` and
`runner add-org` accept only DNS names: letters, digits and hyphens, with dots
only between labels, each label starting and ending with a letter or digit, and
no underscores. A prefix may end in a hyphen, since `-<n>` follows it. A prefix
that an older `add-org` saved without these checks still has its slots tried,
and every clone of them fails. Re-run `runner add-org` for that org and enter a
valid prefix.

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

The template turns off apt's periodic jobs: `apt-daily.timer` and
`apt-daily-upgrade.timer` are disabled, their services masked, and
`/etc/apt/apt.conf.d/99runner-template` sets
`APT::Periodic::Update-Package-Lists` and `APT::Periodic::Unattended-Upgrade`
to `"0"`. Unattended upgrades never hold the dpkg lock under a job, and an
`apt-get` in a job waits up to 5 minutes for a lock that is already held
(`DPkg::Lock::Timeout "300"`). Runners get package updates only from the next
template bake, which runs `apt-get upgrade`.

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
for Docker 29's containerd image store trying HTTPS against local HTTP mirrors,
and lists the mirror under `insecure-registries`.

HTTPS mirrors keep Docker's containerd image store. The bake and every clone
write `hosts.toml` under `/etc/docker/certs.d/public.ecr.aws/` and
`/etc/docker/certs.d/<host:port>/`, so every `public.ecr.aws` pull tries the
mirror first. Docker checks the certificate of a mirror entered by host name
against the template's system CA certificates. Only a mirror entered by IP
address (IPv4, or IPv6 in brackets) gets `skip_verify = true`, in the bake and
in every clone, so nothing checks that it is genuine (see
[Security Notes](#security-notes)). A mirror entered by host name therefore
needs a certificate those CAs trust. With a self-signed or private-CA
certificate, the bake's Supabase warmup through the mirror fails, and the bake
with it, and so do the clones' Supabase pulls through the mirror. Give it a
publicly trusted certificate, enter it by IP address, or use `http://`. Clones
write these files at boot, so the rule applies from the first clone after
`install.sh`, without a rebake.

The baked-version record keeps the mirror the template was baked with
(`docker_mirror_url`). Changing `DOCKER_MIRROR_URL` with `runner setup` makes
the next daily check bake once, because the template's warmed images sit under
the old mirror's registry name and image store. A record written before that
field existed is not compared. Until that bake, the template still holds the
old mirror's `hosts.toml` files, so each clone removes at boot every
`hosts.toml` under `/etc/docker/certs.d/` that the configured mirror does not
use, all of them when no mirror is set, and logs
`Removed the template's stale Docker mirror config: <path>` for each. A cleared
or replaced mirror stops taking `public.ecr.aws` pulls from the next clone on.
The cleanup does not touch `daemon.json` or the warmed images; the bake
replaces those.

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

Those are the default labels. `RUNNER_LABELS` in an org's config changes them,
from the next clone of each runner.

## Updating Runners

The per-VM cloud-init snippet is rendered fresh from the template at every
clone, so to change runner bootstrap behavior you only edit the template and recycle:

1. Edit `/opt/selfhosted-runners/templates/runner-user-data.yaml`
2. Destroy a runner; the watcher recreates it from the updated template:
   ```bash
   runner destroy runner-1   # watcher recreates within ~30s
   ```

### Rotating a PAT

The PAT lives only on the Proxmox host in `/etc/github-runners.d/<org>.conf`.
Re-run `runner add-org`, enter the same org and the new PAT, and press Enter at
the prefix, count and group prompts to keep them. The new token takes effect on
the next clone — no runner stores the PAT, so nothing else is needed. `add-org`
rewrites each line that starts with an assignment to one of the five prompted
keys (`GITHUB_ORG`, `GITHUB_PAT`, `RUNNER_PREFIX`, `RUNNER_COUNT`,
`RUNNER_GROUP_ID`), indented or after `export` too, as `KEY="value"` where it
stands. It keeps every other line of the org config, such as a hand-set
`RUNNER_LABELS` or comments, where it is, and a key the file lacked goes at
the end. So a line after those keys can use them, for example
`RUNNER_LABELS="self-hosted,linux,x64,${RUNNER_PREFIX}"`. A comment at the end
of a rewritten line is lost. `add-org` also clears the failure holds of the
org's slots, `<prefix>-1` to `<prefix>-<RUNNER_COUNT>` as just saved, so slots
that an expired PAT left empty are tried again on the watcher's next run.
Other orgs' holds stay.

### Pool size and prefix

Re-running `runner add-org` for an org also changes its prefix, slot count and
runner group. The watcher fills new slots on its next run. A runner VM whose
slot no longer exists (a lowered count, or a changed prefix) is retired after
its current job: it is destroyed and not cloned again. An idle one goes when it
reaches its 6-hour shutdown, so for a while the old VMs run beside the new
slots. `runner remove-org` retires all of that org's runner VMs the same way.
To remove them sooner, run `runner destroy <name>` for each once the org is
removed; before that, the watcher clones a destroyed slot again. GitHub drops
the registration of an ephemeral runner a day after it goes offline, so nothing
needs removing there by hand. Extra runners from `runner create` are not slots:
they keep being re-cloned until `runner destroy`, or until their org is
removed.

`runner create` records each extra runner as a `<name> <org>` line in
`/var/lib/github-runners/extras`, unless the name is one of the org's slots.
The watcher fills a recorded extra runner of a configured org as it fills a
slot: failure holds, maintenance mode and an unfinished template keep it empty
the same way, and a slot of the same name comes first. So an extra runner that
a hold, a template rebuild or a failed re-clone left empty comes back.
`runner destroy`, by name or `--vmid`, removes the record once the VM is gone
and prints `Extra runner removed; the watcher will not recreate it.` If it
cannot, it says so and exits 1; run `runner destroy <name>` again. For a
recorded extra runner that has no VM at the moment, such as one that is held,
`runner destroy <name>` removes just the record. A full `runner stop` removes
every record, `runner stop --vmid-range` only those of the extra runners it
destroys, and `runner stop --watch-only` none. `runner remove-org` removes the
org's records, and a reclone or the watcher removes the record of a name it
retires, such as one whose org is gone or that another org now uses as a slot.
An extra runner that an older version created is not recorded until
`runner create` creates it again.

Runner VMs cloned by an older version have no `kind=` in their Notes. A lowered
count still retires them, but after a prefix change they keep recycling as
extras. After upgrading, run `runner stop && runner start` once before you
change a prefix.

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
whole bake. `reserve_vmid` starts at `MIN_VMID` (at the cluster's next free
VMID when that is 0) and walks upward, and the watcher runs every 30 seconds.
`TEMPLATE_ID` changes only after `qm template` has converted the new VM's disks
to base volumes. `qm template` can exit 0 without converting them, so the
rebake reads the result from `qm config`, and a VM it did not convert is
destroyed like any failed bake. Running clones finish their current job, or
reach their 6-hour shutdown, and the next clone of that slot comes from the new
image. The previous template goes on the retirement list,
`/var/lib/github-runners/retired-templates`. Every rebake run, including a
daily check that does not bake, destroys a listed template once no linked clone
depends on it, provided it is still a template named `ubuntu-cloud-template`.
A failed bake destroys the partial VM and leaves `TEMPLATE_ID` and the live
template as they were.

Each run first checks the live template. If `TEMPLATE_ID` does not exist, is
not a template, or has disks that are not base volumes (a template made on
thick LVM, for example), `runner rebake` stops with an error and bakes nothing.
Inspect it with `qm config <TEMPLATE_ID>`, destroy it, and run `runner setup`
to bake a new one.

A bake, from setup or a rebake, checks `VM_STORAGE` before it creates its VM.
It refuses to start unless `pvesm status` shows the storage active with at
least 30 GiB available, the size of the bake disk, because a storage that fills
up pauses every VM on it. On thick-provisioned ZFS the floor is 60 GiB (see
[Resource Planning](#resource-planning)). `BAKE_MIN_FREE_GIB=<GiB>`, a whole
number, replaces that floor, and `0` turns the check off. Set it in
`/etc/github-runners.conf`; the daily rebake and `runner setup` both use it,
and `runner setup` keeps the line when it rewrites that file. For one run,
put it on the command line of `runner setup` or `runner rebake`, as the
refusal suggests. That value wins over the conf, and `runner rebake` then
detaches with `setsid` (below). An `Environment=` line from `systemctl edit
github-runner-rebake.service` is the same kind of override: it wins over the
conf for runs of that unit.

The host picks the `actions/runner` release for each bake: the rebake uses the
release it just compared, and setup looks up the latest release once when its
bake starts. The host logs `The bake installs actions/runner X.Y.Z` and renders
that version into the bake's cloud-init, so the bake VM makes no api.github.com
call. The runner tarball download stays inside this bake, as do the image pulls
the template already bakes (Supabase CLI, Playwright, and Docker images via the
configured mirror). Clones do not gain a download path for any of those. Both
lookups ask api.github.com first. When that fails (a rate limit, an error, an
outage), the host logs
`The GitHub API did not return the latest actions/runner release; reading it from github.com instead`
and reads the version from the redirect of
`https://github.com/actions/runner/releases/latest`.
`Could not read the latest actions/runner release; not baking` means both
failed.

Both `run.sh --jitconfig` lines pass `--disableupdate`. That flag is not a
valid `run` option: the listener warns and continues. What stops GitHub pushing
a new runner package onto the clone is `disableUpdate: true` in the JIT
`.runner` document. The clone sets that bit before `run.sh` when the template
has `/opt/.baked-runner-version`, which every bake since the daily rebake
writes, and exits 1 if the patch fails, so it does not start a self-updating
runner. A clone of an older template, which has no such file, logs
`leaving runner self-update on` and updates itself until a rebake replaces the
template. A clone that did self-update leaves versioned `bin.<version>` and
`externals.<version>` directories under `/home/runner/actions-runner` and
re-downloads the runner package on every job.

The host records the baked version in
`/var/lib/github-runners/baked-runner-version` at the end of a successful bake.
The record also stores `baked_at`, the successful bake time as Unix seconds;
release publication time is metadata and does not drive template freshness.
Older records without `baked_at` trigger one refresh to establish that time.
The record names the template (`template_id`) and the Docker mirror the bake
used (`docker_mirror_url`). A check ignores a record for a template other than
`TEMPLATE_ID` and bakes once, and it queues the template the record names for
retirement. It also ignores a record whose `docker_mirror_url` differs from the
configured `DOCKER_MIRROR_URL`, and bakes once. A record that lacks one of those
fields is not compared on it. The guest writes the version from
`Runner.Listener --version` while it is still up. The template is stopped
afterward, so `qm guest exec` cannot read it later.

`runner rebake` detaches from the SSH session (the systemd service when that
unit is installed, otherwise `setsid`) so a dropped connection does not kill
the bake. Follow it with `journalctl -u github-runner-rebake.service -f`, or
`/var/log/github-runner-rebake.log` when it detached with `setsid`.
`runner rebake` with `BAKE_TIMEOUT` or `BAKE_MIN_FREE_GIB` set in the
environment always detaches with `setsid`, because `systemctl start` cannot
pass that environment into the unit. The unit's `TimeoutStartSec` is 9000
by default: the 5400-second poll limit plus an hour for the cloud-image
download, `qm importdisk` and `qm template`, which `BAKE_TIMEOUT` does not
cover. When `BAKE_TIMEOUT` is set in the conf, `runner setup`, `install.sh`
and `runner rebake` write
`/etc/systemd/system/github-runner-rebake.service.d/timeout.conf` with
`TimeoutStartSec` set to that many seconds plus 3600, and reload systemd,
before the service starts. A one-run environment value does not change the
drop-in. `TimeoutStopSec=180` and `KillMode=mixed` still apply when the
service is stopped, so the script's trap can destroy a partial VM before
leftover `qm` children are killed. It checks an environment override before it
detaches, so a bad one fails in the terminal with exit status 1. A bad value
in the conf fails with the same message once the rebake has read the file,
before it creates a VM. `runner rebake --foreground` stays attached; run that
form inside tmux.

A healthy bake is 30–45 minutes. The guest writes
`/opt/.template-setup-complete` last and does not power itself off. The host
confirms that marker over the guest agent, then shuts the VM down, and only then
runs `qm template`. A guest setup that fails writes
`/opt/.template-setup-failed` instead: the host sees it within one 15-second
poll, prints the last 40 lines of the guest's `/var/log/template-setup.log`, and
fails the bake. A setup that fails before the guest agent runs (network, DNS or
apt in the first steps) powers the VM off, and the host reports
`Template VM stopped before setup completion was confirmed (status: stopped)`.
That leaves the timeout for a guest that hangs: the bake aborts after 90
minutes (`BAKE_TIMEOUT`, default 5400). Set `BAKE_TIMEOUT` to a positive
whole number of seconds in `/etc/github-runners.conf`, such as `7200`, to
change it for the daily rebake and for setup. An environment value on one
run wins over the conf. A value such as `2h`, `90m`, `0` or `0900` is refused
with
`BAKE_TIMEOUT must be a whole number of seconds, such as 7200, not '<value>'`
before a bake VM is created. Stopping the bake VM before the completion marker
is confirmed destroys the partial VM and does not publish it.

Upstream rotates `noble/current/` every few weeks. A cached
`/var/cache/github-runners/noble-server-cloudimg-amd64.img` that no longer
matches the published checksum is replaced with a fresh download. A freshly
downloaded image that still fails the checksum exits 1 before a template VM is
created. An interrupted download leaves a
`noble-server-cloudimg-amd64.img.XXXXXX` file in that directory; bakes remove
such files once they have been idle for 3 hours.

`github-runner-rebake.timer` starts the check daily, shortly after midnight
(`OnCalendar=daily`, `Persistent=true`). A timer that has never run waits for
the next midnight, even when it is enabled later in the day. After that, a
midnight missed while the host was off or the timer was stopped runs at once
when the timer starts again. A rebake that starts while another rebake, or a
setup bake, holds the rebake lock logs `A rebake is already running` and exits
before it reads `/etc/github-runners.conf`.

To refresh prebaked software before the release is stale, edit
`/opt/selfhosted-runners/templates/template-setup.yaml`, remove
`/var/lib/github-runners/baked-runner-version`, and run `runner rebake`. That
reads the saved infra config. It does not re-prompt, and it leaves running
clones up.

`runner setup` is still the interactive wizard, and it is how you create the
template the first time. It checks the Template VM ID right after that prompt,
before it changes anything on the host. A finished template there
(`template: 1`, with its disks converted to base volumes) is used as it is, so
a second setup does not refresh the image. Any other VM at that ID is refused.
For a bake that stopped before `qm template` finished, setup prints the
commands that remove it (`qm stop <id>; qm destroy <id>`); run setup again
afterwards. For a runner, another VM or a container, choose another ID. A free
ID is baked.

Entering a new, free Template VM ID while the saved template is finished bakes
the new one beside it. The saved template keeps serving clones, and
`TEMPLATE_ID` moves to the new VM only once it is a finished template; the old
template then goes on the retirement list. A failed bake leaves `TEMPLATE_ID`
and the live template unchanged. The setup bake holds the rebake lock from its
start until `TEMPLATE_ID`, the retirement list and the baked-version record
name the new template, a window that ends with a release-date lookup on
api.github.com of up to about 2 minutes. So setup will not bake while a rebake
runs, and a rebake started in that time logs `A rebake is already running` and
exits.

Setup records the new VM in `/var/lib/github-runners/pending-bake`, as a
rebake records its own bake, and removes the record once `TEMPLATE_ID` names
the new template or its cleanup has destroyed a failed VM. A bake that stops
before its VM exists, such as one that the `BAKE_TIMEOUT`, free-space or
release check refuses, loses its record as well, when the cluster inventory
confirms that no VM has that ID. If setup leaves the VM behind, because it was
killed before its cleanup ran (`kill -9`, a power loss), could not destroy a
failed VM (it then shows `qm`'s error and the commands that remove the VM by
hand) or could not rewrite `TEMPLATE_ID`, the next rebake run takes over. It
destroys a VM that is not a finished template
(`Destroying incomplete rebake VM <id>`), or publishes a finished one
(`Finishing publish of template <id>`) and then bakes once more, because that
publish records no runner version. It drops a record that names no VM. A
record whose VMID now belongs to a VM with another name on this node
(`Pending bake id <id> is <name>; leaving that VM and dropping the stale pending record`),
to a container, or to a guest on another node
(`Pending bake id <id> is a guest on node <node>, not a bake VM on this node; dropping the stale pending record`)
is stale too: the rebake drops it and leaves that guest alone. While the record
names another VM that may still exist, setup refuses to bake beside the live
template and asks you to run `runner rebake` first. Its message also says that
the record is stale when `qm config <id>` on this node shows no VM named
`ubuntu-cloud-template`, and that you can then remove it instead with
`rm /var/lib/github-runners/pending-bake`. Choose an ID below `MIN_VMID`. Setup
does not reserve the ID while it downloads the cloud image, so a runner clone
can take an ID in the runner range first. The bake then fails, and setup logs
`Refusing to destroy VM <id> (<name>); it is not the template bake VM` after
`qm`'s error. The next rebake drops a record that names that runner.

Entering the ID of another finished template switches `TEMPLATE_ID` to it at
once. The next daily check then finds a baked-version record for a different
template, so it bakes a fresh one, and both the template the record names and
the one you entered go on the retirement list. Changing the storage pool does
not move an existing template: runners stay linked clones on the template's
storage until a template is baked on the new pool. Setup warns about this and
prints the command that bakes one now:
`rm -f /var/lib/github-runners/baked-runner-version && runner rebake`.
Changing the Docker mirror makes the next daily check bake once (see the record
above).

The wizard reads `/etc/github-runners.conf`, when present, and prefills
its eight prompts with editable saved settings. Press Enter to keep a prefilled
value, edit it to change the setting, or clear the line with Ctrl-U and press
Enter to select the standard default shown in brackets. Empty VLAN and Docker
mirror inputs disable those options; an empty DNS input selects
`1.1.1.1 8.8.8.8`. The DNS answer `dhcp`, in any case, stores an empty
`DNS_SERVERS`, so clones use the DHCP servers (see
[Network Requirements](#network-requirements)), and the summary shows
`DNS Servers: DHCP only`. A saved `DNS_SERVERS` that is empty or missing is
prefilled as `dhcp`, so Enter keeps it. With no saved config, or with piped
input, an empty line selects the standard default. Setup replaces a line
only when it is exactly one assignment of one of the eight keys it prompts
for, and keeps every other line, so `BAKE_TIMEOUT`, `BAKE_MIN_FREE_GIB`, a
second command on the same line and a value continued on the next line stay.
The new assignment is appended, so it wins when the file is sourced. If that
result is not valid shell, the old file is left unchanged. Org configs and
PATs are not touched; `add-org` runs only when no orgs exist yet. Run `runner setup` under tmux. It is interactive, and
a dropped SSH session fires the cleanup trap and throws away an in-progress
setup bake.

`runner stop` without `--vmid-range` destroys every managed runner VM for every
configured org, extra runners from `runner create` included; `runner start`
refills only the slots. With three orgs, that is every managed VM across all
three. It also clears the record of extra runners,
`/var/lib/github-runners/extras`, including those that have no VM at the
moment. If it cannot, it logs
`Could not clear the extra runners recorded in /var/lib/github-runners/extras`
and fails before it destroys any VM. The in-progress rebake VM is named
`ubuntu-cloud-template` and has no org snippet, so stop does not treat it as a
managed runner. `runner stop` leaves the pool in maintenance mode until
`runner start`. The maintenance flag lives in `/run/lock/`, which is tmpfs. It
does not survive a host reboot, and the watcher timer stays enabled, so a
reboot mid-maintenance resumes runner creation. Do not reboot the Proxmox host
between `runner stop` and `runner start`. On a full stop it also frees
orphaned linked-clone child volumes for the current template when those
volumes no longer have a VM or container config anywhere in the cluster. Each
freed volume must then be gone from `pvesm list`, because `pvesm free` exits 0
even when its deletion task fails; a volume that is still listed fails the
stop. If any child volumes still belong to a VM, template or container config,
`runner stop` fails and tells you to resolve those dependents before deleting
the template. While pmxcfs is not serving `/etc/pve` (pve-cluster restarting
during an upgrade, or a crashed pmxcfs), no config can be checked: the stop
frees no more volumes, logs
`pmxcfs is not serving /etc/pve, so VM configs cannot be checked; not freeing <volid>`
and fails. Check that pve-cluster is running, then run `runner stop` again.

`runner start` clears the maintenance flag and every slot's failure hold,
starts the watcher timer, and runs one pool fill inside
`github-runner-watch.service`, so a dropped SSH session cannot cut a clone in
half. It waits for that fill, which logs to the journal:
`journalctl -u github-runner-watch -f`.

`runner stop --vmid-range <min:max>` is for partial maintenance windows only.
Do not use a VMID-limited stop immediately before destroying a linked-clone
template, because every dependent clone must be removed before `qm destroy`
will succeed. It removes the records of the extra runners it destroys and
keeps the others. `runner stop --watch-only` stops the watcher, and leaves the
VMs up and every extra runner recorded. Its maintenance flag also keeps the
hookscript from recycling a VM that stops, so use it before you stop or reboot
a runner VM by hand.

### Upgrading an existing host

Before running `install.sh` on a host that already has `/opt/selfhosted-runners`,
diff that tree. `install.sh` extracts GitHub master over it, and the copy on
the host is not necessarily the commit you last installed. If the download
stops partway, run `install.sh` again at once.

1. Check the settings that older versions ignored or could break:
   - `DNS_SERVERS` in `/etc/github-runners.conf`: clones apply them, and fall
     back to the DHCP servers with a warning when they cannot resolve
     `github.com` or the mirror's host name (see
     [Network Requirements](#network-requirements)). Check them anyway,
     because a fallback hides a wrong setting. To use the DHCP servers, run
     `runner setup` again and answer `dhcp` at the DNS prompt.
   - `DOCKER_MIRROR_URL`: from the first clone after `install.sh`, an
     `https://` mirror entered by host name needs a certificate the template
     trusts (see [Docker mirror](#docker-mirror)). For a self-signed or
     private-CA certificate, enter the mirror by IP address with
     `runner setup`, or use `http://`.
   - `RUNNER_PREFIX` in each `/etc/github-runners.d/<org>.conf` must be a valid
     VM name (see [Commands](#commands)).
   - The content types of `local`: an older `runner setup` could replace them
     with `iso,backup,vztmpl,snippets`, dropping any other type, such as
     `import`, or `images,rootdir` on an install without a separate data
     volume. Check with `grep -A4 '^dir: local' /etc/pve/storage.cfg` and put
     back what is missing with `pvesm set local --content <full list>`. Setup
     adds `snippets` to the existing list and repairs nothing.
   - At least 30 GiB free on `VM_STORAGE` for the bake (`pvesm status`), or
     60 GiB on thick-provisioned ZFS (see
     [Resource Planning](#resource-planning)).
2. Install, while no template bake is running:
   ```bash
   curl -fsSL https://raw.githubusercontent.com/ThayneStudio/selfhosted-runners/master/install.sh | bash
   ```
   It refreshes the hookscript and the systemd units and enables
   `github-runner-rebake.timer`. When `/etc/github-runners.conf` exists, it
   then checks that `TEMPLATE_ID` is a finished template. If it is, it says
   there is no need to re-run setup. If it is not, it says so and tells you
   to run `runner setup`. If `qm` is unavailable, pmxcfs is not serving
   `/etc/pve`, or the check cannot be made, it says it could not check. On a
   host that still has the per-org snippets
   of a version before single-use JIT configs
   (`/var/lib/vz/snippets/runner-user-data-<org>.yaml`, which held the org PAT),
   it also removes them. While any VM's cicustom still names one of those
   snippets, it warns with the count of runner VMs that still have the PAT on
   their cloud-init drive, on every run until they are gone. Step 4 destroys
   those VMs (see [Security Notes](#security-notes)).
3. Bake a template now. A template baked before the daily rebake has no
   baked-version record, so this bakes. The timer's first check would wait for
   the next midnight, and until a bake publishes, clones of the old template
   keep runner self-update on.
   ```bash
   runner rebake
   journalctl -u github-runner-rebake.service -f
   ```
   Wait for `TEMPLATE_ID is now <N>`. If the journal shows
   `the template is under 21 days old; not baking` instead, the recorded
   template is current; go on to step 4.
4. Recycle the pool onto the new template. This also gives every runner VM the
   Notes marker that [pool size changes](#pool-size-and-prefix) rely on:
   ```bash
   runner stop && runner start
   ```
   Extra runners from `runner create` are destroyed and not recreated; create
   them again if you need them. The next rebake run destroys the old template
   once no linked clone depends on it. A template with any name other than
   `ubuntu-cloud-template` is left in place, and each run logs
   `Refusing to destroy VM <id>`; remove it with `qm destroy <id>`.

To postpone the first bake instead (step 3), record the version the current
template holds. The record postpones the bake only while that version is the
latest `actions/runner` release and the template is under 21 days old, and
clones of the old template keep runner self-update on until a bake replaces
it. A running runner prints its version to `/var/log/runner-setup.log` when it
connects. `template_id` must be the configured `TEMPLATE_ID`: a record for
another template is ignored, and that template is queued for retirement.
`baked_at` comes from the template's creation time (`ctime` in its `meta:`
line), a little before that bake finished. An empty `version` or `baked_at`
makes the next check bake anyway. Leave out `docker_mirror_url`: a record
without it is not compared with the configured mirror.

```bash
VMID=9001   # a running runner's VMID, from runner list
VERSION=$(qm guest exec "$VMID" -- grep -m1 'Current runner version' /var/log/runner-setup.log \
    | jq -r '."out-data" // empty' | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')
TEMPLATE_ID=$(. /etc/github-runners.conf && echo "$TEMPLATE_ID")
BAKED_AT=$(qm config "$TEMPLATE_ID" | sed -n 's/^meta:.*ctime=\([0-9]*\).*/\1/p')
echo "version=$VERSION template_id=$TEMPLATE_ID baked_at=$BAKED_AT"
install -d -m 700 /var/lib/github-runners
cat > /var/lib/github-runners/baked-runner-version <<EOF
version=$VERSION
published_at=''
template_id=$TEMPLATE_ID
baked_at=$BAKED_AT
EOF
chmod 600 /var/lib/github-runners/baked-runner-version
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
- Network connectivity issues (check DNS, firewall). The log's `DNS servers:`
  line names the servers the clone uses; a `cannot resolve` warning before it
  means `DNS_SERVERS` failed and the clone fell back to the DHCP servers
- The slot is held after repeated failures (see [A slot stays empty](#a-slot-stays-empty))

### "Configuration not found" error

Run `runner setup` first to create the configuration.

### "Template VM does not exist" error

The template was deleted. Re-run `runner setup` to recreate it. While
`TEMPLATE_ID` is not a finished template (`template: 1` with its disks
converted to base volumes), the watcher does nothing: it fills no slot and
reclaims no VM. `runner rebake` stops with an error for the same reason. A
runner VM that stops in that time is still destroyed by its reclone, but its
slot stays empty, and `/var/log/github-runner.log` shows
`reclone: template <id> is not a finished template; leaving <name> empty for the watcher`.
That does not count as a failed clone, and the watcher fills the slot, or the
recorded extra runner, once the template is finished.

### VM creation fails with "storage not found"

The storage pool specified during setup doesn't exist. Re-run `runner setup` and select a valid storage pool.

### Runner shows "Offline" in GitHub

The runner is a foreground `run.sh --jitconfig` started by cloud-init, not a
systemd unit. If that process exits, the EXIT trap shuts the VM down and the
hookscript reclones the slot. The hookscript starts that reclone as its own
transient unit, `github-runner-reclone-<vmid>`, which logs to
`/var/log/github-runner.log`.

**Check VM status:**
```bash
qm status <vmid>
```

**Check the in-guest setup log (while the VM is still running):**
```bash
qm guest exec <vmid> -- cat /var/log/runner-setup.log
```

When the runner stops, the log shows `run.sh exited N` before
`Shutting down VM...`. Exit 7 means GitHub refused the runner version (runner
2.333.0 and later report it this way): run `runner rebake`. After exit 7 the
clone writes `/opt/.runner-version-refused` (`rc=7` and the baked
`runner_version`), logs `Holding the VM for 300s before it powers off`, and
stays up those 5 minutes before it shuts down, so the cause can still be read:

```bash
qm guest exec <vmid> -- cat /opt/.runner-version-refused
```

Until a rebake replaces the template, every clone is refused the same way. The
slot runs no job, and a new clone takes its place about every 6 to 7 minutes,
or later while the slot is held (see [A slot stays empty](#a-slot-stays-empty)).

If the VM is already stopped, wait for the watcher (or run `runner watch`) to
refill the slot. The watcher destroys a runner VM and clones its slot again when
the VM:
- has been stopped for about a minute and nothing recycled it (a host reboot
  or power loss, a reclone that failed, a missing hookscript);
- is still up 12.5 hours after boot;
- was started again more than about 2 minutes after its clone (a stop-mode
  backup, `qm reboot`), since cloud-init starts the runner only once.

The watcher stops and destroys only a VM it can prove it cloned. Besides being
a managed runner (see [Runner Specs](#runner-specs)), the VM must have its own
meta snippet in `cicustom` (`meta=local:snippets/runner-<vmid>-meta.yaml`) or
the Notes marker with its own VMID. A per-org snippet names no VMID, so it is
not enough alone.

A clone made while `/var/lib/vz/snippets/runner-hookscript.sh` is missing logs
a warning with the command that restores it,
`install -m 755 /opt/selfhosted-runners/templates/runner-hookscript.sh /var/lib/vz/snippets/runner-hookscript.sh`;
`install.sh` and `runner setup` put it back too.

A VM that stops while the host shuts down is not recycled then; the watcher
reclaims it a few minutes after boot. Do not `qm stop` or `qm reboot` a runner
to inspect it — the hookscript and the watcher recycle it. Run
`runner stop --watch-only` first, and `runner start` when you are done.

### A slot stays empty

A slot whose clone keeps failing is held instead of retried on every tick: for
30 seconds after the first failure, doubling with each failure in a row up to
30 minutes. Three VMs in a row that die within 10 minutes (600 seconds) of
their clone hold the slot the same way, as long as the clones in between find
each dead runner still registered on GitHub (`JIT mint conflict`). GitHub
removes an ephemeral runner once it finishes a job, so a run of short jobs does
not hold a slot: a clone whose mint finds no such runner, or a VM that lives at
least 10 minutes, starts the count over. The reclone counts each death, and so
does the watcher for a stopped VM it reclaims because nothing recycled it (no
hookscript on the VM, a reclone unit that systemd refused), measuring the VM's
life up to when it first saw the VM stopped. Either logs the hold as
`<name> died within 600s of its clone 3 times in a row`, prefixed with
`reclone:` or `[watch]`. The watcher fills the slot when the hold ends. A
recorded extra runner from `runner create` is held and filled the same way.
`runner start` clears every hold, and `runner add-org` clears the holds of the
org's slots; a hand edit of an org config clears none. A hold with more than
30 minutes left, which only a backward clock step can leave, counts as over.
Holds live in `/run/github-runners/` and do not survive a reboot.

```bash
journalctl -u github-runner-watch --since -1h | grep -E 'Holding|Failed to create|qm clone|JIT mint'
journalctl -t github-runner --since -1h | grep 'died within 600s'
grep -E 'Holding|failed to re-clone|JIT mint' /var/log/github-runner.log | tail
```

A VM that holds the slot's name also keeps it empty. The watcher logs:
- `is stopped and locked (clone)`: a clone killed inside `qm clone` leaves
  `lock: clone`, which nothing clears. Run `qm unlock <vmid>`; the watcher then
  reclaims the VM.
- `carries no selfhosted-runners snippet or marker; leaving it`: a VM named
  like a slot or a recorded extra runner that the watcher cannot prove it
  cloned (see [Runner shows "Offline"](#runner-shows-offline-in-github)), such
  as a full clone of a runner, or a clone that an older version left
  half-configured, with no `vmid=` in its Notes. Remove a leftover clone with
  `qm destroy <vmid>`, or rename a VM you keep.

`runner destroy <name>` refuses a VM that is not a managed runner (see
[Runner Specs](#runner-specs)). While such a VM holds the name of a recorded
extra runner, `runner destroy` cannot end that extra runner either; rename or
remove the VM first.

A plain `qm destroy` of a runner leaves its snippets behind. When a VM that the
watcher cannot prove it cloned, and that is not named like a slot or a recorded
extra runner, later takes that VMID, the watcher leaves the VM alone and
removes those snippets, except any that the VM's own config names. When it
removed one, it logs
`[watch] VMID <id> is now <name>, not a runner VM; removed the runner snippets left behind for it`.

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
- DNS answers on the runner network: the bake VM uses the DHCP servers, and
  clones use `DNS_SERVERS` or fall back to the DHCP servers (see
  [Network Requirements](#network-requirements))

### PAT expired or invalid

1. Generate a new PAT in GitHub
2. Update the org config (PAT stays on the host, never in a VM):
   ```bash
   runner add-org   # enter the same org name and the new PAT
   ```
   The new token is used on the next clone. Existing runners keep working until
   their next job; recycle a slot immediately with `runner destroy <name>` if
   needed (the watcher recreates slots, not extra runners). `add-org` also
   clears the failure holds of the org's slots, so slots that the expired PAT
   left empty are tried again on the watcher's next run, instead of when their
   holds end.

## Files Created by Setup

| Location | Purpose |
|----------|---------|
| `/opt/selfhosted-runners/` | Installed scripts and templates |
| `/usr/local/bin/runner` | Symlink to runner entrypoint |
| `/etc/github-runners.conf` | Infrastructure config (bridge, storage, template ID) |
| `/etc/github-runners.d/<org>.conf` | Per-org config (PAT, prefix, count, runner group ID, optional `RUNNER_LABELS`) — mode 600 |
| `/var/lib/vz/snippets/runner-<vmid>-user-<org>.yaml` | Per-VM cloud-init (single-use JIT config) |
| `/var/lib/vz/snippets/runner-<vmid>-meta.yaml` | Per-VM cloud-init metadata |
| `/var/lib/vz/snippets/runner-hookscript.sh` | Post-stop hookscript that starts each reclone |
| `/var/lib/github-runners/baked-runner-version` | Baked-version record: `Runner.Listener` version, template ID, bake time and Docker mirror of the last successful bake |
| `/var/lib/github-runners/retired-templates` | Replaced templates, destroyed by the rebake once no linked clone depends on them |
| `/var/lib/github-runners/pending-bake` | The VM of a bake beside the live template, from a rebake or from setup, until it is published or destroyed; the next rebake run finishes or removes a VM left there, and drops a record that names no bake VM on this node |
| `/var/lib/github-runners/extras` | Extra runners from `runner create`, one `<name> <org>` per line, which the watcher fills like slots (see [Pool size and prefix](#pool-size-and-prefix)) — mode 600 |
| `/run/github-runners/` | Per-slot failure holds (`slot-<name>`) and when the watcher first saw each stopped runner VM (`watch-stopped`); gone after a reboot |
| `/run/lock/github-runner-drain` | Maintenance flag; the pool's lock files sit beside it in `/run/lock/` |
| `/var/log/github-runner.log` | Output of each reclone (`github-runner-reclone-<vmid>` units) |
| `/var/log/github-runner-rebake.log` | Rebake output when `runner rebake` detached with `setsid` |
| `github-runner-watch.timer` | Pool filler, 30 seconds after the previous run |
| `github-runner-rebake.timer` | Daily template staleness check, separate from the watcher |
| VM template (default ID 9000) | Ubuntu cloud image template; each rebake replaces it with one on a new VMID |

`RUNNER_LABELS` is a comma-separated label list (default
`self-hosted,linux,x64`).

Inside the VMs:

| Location | In | Purpose |
|----------|----|---------|
| `/opt/.baked-runner-version` | Template | Runner version the bake installed; clones set `disableUpdate` only when it exists |
| `/etc/apt/apt.conf.d/99runner-template` | Template | Turns apt's periodic jobs off; apt waits up to 5 minutes for the dpkg lock |
| `/etc/netplan/99-dhcp-mac.yaml` | Template | Uses the MAC as the DHCP client ID |
| `/opt/register-runner.sh` | Each clone | Applies DNS and the Docker mirror, then runs the JIT runner |
| `/opt/runner-job-started.sh` | Each clone | Job-started hook that restarts the 6-hour shutdown |
| `/var/log/runner-setup.log` | Each clone | Runner start log, including the runner's output and `run.sh exited N` |
| `/opt/.runner-version-refused` | A clone after `run.sh` exit 7 | `rc=7` and the baked `runner_version`; the VM stays up 5 minutes after writing it |

## Security Notes

- **PAT never enters the VM**: The org PAT (`admin:org`, or a least-privilege
  fine-grained token — see Prerequisites) stays on the Proxmox host in
  `/etc/github-runners.d/<org>.conf` (mode 600, root-only). `/etc/github-runners.conf`
  holds infrastructure settings only and contains no secrets. At clone time
  the host calls GitHub's `generate-jitconfig` API and injects only the returned
  **single-use JIT (just-in-time) config** via cloud-init.
- **JIT config is single-use**: the config registers exactly one ephemeral
  runner and cannot be replayed to register another. Before the job runs, the
  in-VM script deletes `/etc/github-runner/config.env` and cloud-init's
  `user-data.txt` copies. The config still exists on the attached cloud-init
  drive (`/dev/sr0`), in cloud-init's merged `cloud-config.txt` under
  `/var/lib/cloud/instances/`, and on `run.sh`'s command line while the runner
  is up, and the listener writes the runner's credentials (`.runner`,
  `.credentials`, `.credentials_rsaparams`) into `/home/runner/actions-runner`.
  A job can read all of them, but because the config is single-use it cannot
  register a rogue runner. Copies that leave the VM are another matter: keep
  runner VMs out of backups (see [Backups](#backups)). This is the recommended
  GitHub mechanism for short-lived runners and removes the reusable-token
  exposure entirely.
- **Upgrade recycle**: on a host upgraded from a version before single-use JIT
  configs, runner VMs cloned from the old per-org snippets still have the org
  PAT on their cloud-init drive, where any job they run can read it, until they
  are destroyed. `install.sh`, and `runner setup` on a host with orgs
  configured, warn with their count on every run while any VM's cicustom still
  names a per-org snippet, even after an earlier run removed the snippets. Step 4 of
  [Upgrading an existing host](#upgrading-an-existing-host) destroys them
  (`runner stop && runner start`); recycling before the bake only removes the
  PAT sooner.
- **Runner user**: VMs run as user `runner` with NOPASSWD sudo and `docker`
  group membership (both root-equivalent inside the VM) — required for Docker.
- **⚠️ Do not use these runners on public repositories.** Self-hosted runners
  execute workflow code from any PR, including forks. A malicious PR would get
  full root inside the VM. Restrict the org's runners to **private repos** in
  GitHub → Org Settings → Actions → Runner groups. The VM is ephemeral, but the
  job is still arbitrary code execution on your host's network.
- **The rebake trusts the runner network**: the daily rebake bakes the next
  template unattended, on the same bridge and VLAN as the runners, while jobs
  keep running, and every later clone starts from what it bakes. A job has root
  in its VM, and this tool puts nothing between runner VMs, or between them and
  the bake VM. apt checks package signatures and the other bake downloads use
  TLS with certificate checks, and so does an HTTPS Docker mirror entered by
  host name. A plain HTTP mirror, or an HTTPS mirror entered by IP address
  (`skip_verify = true`), is trusted without checks: nothing authenticates it,
  so a job that answers as the mirror could plant images in the template. With
  such a mirror, every job on the pool must be trusted not to attack that
  network. Leave `DOCKER_MIRROR_URL` empty, or use an HTTPS mirror by host name
  with a trusted certificate, to bake without that trust, and do not share a
  host between orgs that do not trust each other's jobs.
- **Security updates come from rebakes**: runners do not update their packages
  (apt's periodic jobs are off, see [Installed Software](#installed-software)).
  Each bake runs `apt-get upgrade`, so while bakes succeed a template's
  packages are at most about 21 days old.
- **Rotate PAT**: re-run `runner add-org` with the new PAT (effective next
  clone). It keeps the rest of the org config and clears the failure holds of
  the org's slots.

## Backups

Keep runner VMs and templates out of Proxmox backup jobs. A job that backs up
all guests also takes every runner VM and template on the node:

- A runner VM's backup holds that runner's credentials and JIT config (see
  [Security Notes](#security-notes)). Whoever can read the backup could start a
  listener as that runner while GitHub still has it registered.
- A stop-mode backup shuts a running runner down, killing any job on it, and
  then starts it again without a runner. The watcher reclaims it later.
- While vzdump backs up a template it holds a `backup` lock on it, and every
  clone from that template fails until the backup ends. The failure holds then
  delay refilling the empty slots.
- Runner VMIDs can change as slots recycle, and every rebake moves the template
  to a new VMID, so a list of VMIDs to exclude falls behind.

Select your own guests instead: by VMID, or by pool. This tool puts no VM in a
pool. It never runs `qm destroy --purge`, so it leaves a backup job's VMID
lists alone.

## Limitations

- **Single Proxmox node**: Scripts assume single-node setup
- **DHCP required**: VMs get IPs via DHCP. A slot keeps its MAC across
  recycles, and clones of a template that has `/etc/netplan/99-dhcp-mac.yaml`
  send it as their DHCP client ID, so a slot usually keeps its address
- **No demand-based scaling**: each org runs a fixed pool of `RUNNER_COUNT`
  slots; `runner create` adds extras by hand
- **Org-level only**: Repository-level runners not supported by these scripts
- **No untrusted local accounts**: the maintenance flag and the pool's lock
  files live in `/run/lock`, which every local account can write. Any account
  on the host could pause refills with a fake maintenance flag, hold a lock to
  stall recycling and `runner stop`, or hold the rebake lock so every daily
  check logs `A rebake is already running` and skips. A Proxmox host should
  have no untrusted local users.

## Resource Planning

| Runners | CPU Cores | RAM | Storage |
|---------|-----------|-----|---------|
| 1 | 2 | 8 GB | 30 GB |
| 4 | 8 | 32 GB | 120 GB |
| 8 | 16 | 64 GB | 240 GB |

The table counts runner VMs only. Also plan for:

- **A bake VM**: 8 GB RAM and 2 cores for 30–45 minutes (up to 90), running
  beside the full pool. Setup bakes the first template. After that a rebake
  runs for each new `actions/runner` release or when the template turns 21 days
  old, and again every night while bakes keep failing. Size the host for one VM
  more than the pool, plus memory for Proxmox itself and, on ZFS, the ARC.
- **Templates**: each has a 30 GB disk. Next to the live template, a rebake
  builds a second one, and a replaced template stays until its last linked
  clone is gone. Runner disks are linked clones, so each uses only what its
  runner writes, up to 30 GB.
- **Free space at bake time**: a bake will not start with less than 30 GiB
  available on `VM_STORAGE`, or 60 GiB on thick-provisioned ZFS (see below
  and [Template rebake](#template-rebake)). A storage that fills up pauses
  every VM on it, so keep runner storage apart from the host's root filesystem
  (on a ZFS-root install, `rpool/ROOT` and the default `local-zfs` share one
  pool), or protect the root with a quota or reservation.
- **Thick-provisioned ZFS**: a `zfspool` or ZFS over iSCSI `VM_STORAGE`
  without `sparse` in `/etc/pve/storage.cfg` (Thin provision off; the
  installer's `local-zfs` has it on) reserves the full size of each volume.
  The bake's disk reserves its whole 30 GiB, and the snapshot `qm template`
  takes needs room for the bake's data besides, so a bake there needs 60 GiB
  free. A template keeps its reservation plus its data for as long as it
  exists, and during a rebake the live, the new and any retired templates each
  hold that much. Turn on Thin provision (`sparse 1`) for `VM_STORAGE` so that
  later bakes reserve nothing. If `pvesh` cannot read the storage's config, the
  bake counts it as thick and logs a warning.

## License

MIT License - see [LICENSE](LICENSE) file.
