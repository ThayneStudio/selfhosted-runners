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
1. Ask for GitHub org, PAT, network bridge, storage pool
2. Install to `/opt/selfhosted-runners`
3. Add `runner` command to `/usr/local/bin`
4. Download Ubuntu cloud image and create VM template

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
│  /etc/github-runners.conf          ← Infra config (no secrets)  │
│  /var/lib/vz/snippets/             ← Cloud-init config         │
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

After setup, the `runner` command is available globally:

| Command | Description |
|---------|-------------|
| `runner setup` | Re-run the setup wizard |
| `runner create <name>` | Create a new runner VM |
| `runner destroy <name>` | Destroy a managed runner VM |
| `runner start` | Exit maintenance mode and resume watcher |
| `runner stop [options]` | Enter maintenance mode and stop managed runners |
| `runner list` | List all runner VMs |
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

To update runner registration/bootstrap behavior (cloud-init that runs on every
cloned runner VM):

1. Edit `/opt/selfhosted-runners/templates/runner-user-data.yaml`
2. Re-run setup to regenerate the per-org runner cloud-init snippets:
   ```bash
   runner setup
   ```
3. Destroy and recreate runners:
   ```bash
   runner destroy runner-01
   runner create runner-01
   ```

To update prebaked software in the base VM template:

1. Edit `/opt/selfhosted-runners/templates/template-setup.yaml`
2. Stop the watcher, remove managed runners, and free any orphaned linked-clone child volumes that still point at the current template:
   ```bash
   runner stop
   ```
3. Destroy the existing template VM (default ID `9000`, or your configured template ID):
   ```bash
   qm destroy 9000
   ```
4. Re-run setup to bake a fresh template:
   ```bash
   runner setup
   ```
   > **Record your config first.** The wizard re-prompts all eight infrastructure
   > questions with *hardcoded* defaults -- it does not read your existing
   > `/etc/github-runners.conf`. Pressing Enter through it silently clears
   > `DOCKER_MIRROR_URL` and `VLAN_TAG`, for the bake and for every future clone.
   > Run `cat /etc/github-runners.conf` beforehand and retype every
   > non-default value. Your PAT and org configs are not touched -- `add-org` only
   > runs when no orgs exist yet.
5. Resume the pool and refill it:
   ```bash
   runner start
   ```

### If the bake fails or appears stuck

The bake is gated so a partial template can never be published. The guest writes
its completion marker last and does **not** power itself off; `runner setup`
confirms that marker over the guest agent while the VM is still running, then
shuts the VM down itself and only then converts it to a template.

- **Timeout**: the bake aborts after 90 minutes and prints the last 40 lines from
  the guest log. A healthy bake runs 30-45 minutes. Override with
  `BAKE_TIMEOUT=<seconds> runner setup`.
- **`qm stop` on a stuck bake is safe.** The VM stopping without a confirmed
  marker is treated as failure -- setup aborts and the cleanup trap destroys the
  partial VM rather than publishing it.
- **Ctrl-C is also safe**, and does the same thing.
- **Run `runner setup` under `tmux` or `screen`.** The wizard is interactive, so it
  runs over SSH -- and a dropped connection fires the same cleanup trap, throwing
  away an in-progress bake.
- Watch progress with
  `qm guest exec <TEMPLATE_ID> -- cat /var/log/template-setup.log`.
- **Checksum verification failed?** The cached Ubuntu image at
  `/var/cache/github-runners/` goes stale whenever upstream rotates
  `noble/current/`, roughly every 2-4 weeks. Setup deletes the bad file on its way
  out, so just run `runner setup` again -- it downloads a fresh image. This is not
  a supply-chain compromise, though the error reads like one.

### The 30-day rebake deadline

Runners register with `--disableupdate`, so they never self-update. That avoids
re-downloading the ~225 MB runner package on every job boot, but it puts the
template on a clock: **rebake within 30 days of each new `actions/runner`
release** (sooner if it is a critical security update).

Miss it and the failure is silent rather than loud. Registration keeps working,
runners show **Online / Idle** in the GitHub UI, and jobs simply queue forever
without being assigned -- which looks like a GitHub incident, not a stale
template. Check the baked version against upstream by probing a **running runner
clone** -- the template itself is never running, so `qm guest exec` cannot reach
it, and it has no `.runner` file because the bake never runs `config.sh`:

```bash
vmid=$(qm list | awk '$3=="running" && $2 ~ /runner/ {print $1; exit}')
qm guest exec "$vmid" -- /home/runner/actions-runner/bin/Runner.Listener --version | jq -r '."out-data"'
curl -sf https://api.github.com/repos/actions/runner/releases/latest | jq -r .tag_name
```

With `--disableupdate` in force a clone's version equals the baked version, so
those two outputs should match. If they have drifted, the rebake is overdue.

Before `--disableupdate` shipped, a clone would silently self-update on boot. You
can still see the evidence on any long-lived clone: versioned `bin.<version>` and
`externals.<version>` directories under `/home/runner/actions-runner` are created
only by the self-update path, never by a fresh install.

`runner stop` leaves the pool in maintenance mode until you run `runner start`.
The maintenance flag lives in `/run/lock/`, which is tmpfs -- it does **not**
survive a host reboot, and the watcher timer is still enabled, so rebooting
mid-maintenance silently resumes runner creation. Do not reboot the Proxmox host
between `runner stop` and `runner start`.
On full stops, it also frees orphaned linked-clone child volumes for the current
template when those volumes no longer have a VM config anywhere in the cluster.
If any child volumes still belong to live VM/template configs, `runner stop`
fails and tells you to resolve those dependents before deleting the template.

`runner stop --vmid-range <min:max>` is for partial maintenance windows only.
Do not use a VMID-limited stop immediately before destroying a linked-clone
template, because every dependent clone must be removed before `qm destroy`
will succeed.

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

The template was deleted. Re-run `runner setup` to recreate it.

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
3. Recreate runners:
   ```bash
   runner destroy runner-01
   runner create runner-01
   ```

## Files Created by Setup

| Location | Purpose |
|----------|---------|
| `/opt/selfhosted-runners/` | Installed scripts and templates |
| `/usr/local/bin/runner` | Symlink to runner entrypoint |
| `/etc/github-runners.conf` | Infrastructure config (bridge, storage, template ID) |
| `/etc/github-runners.d/<org>.conf` | Per-org config (PAT, runner prefix, pool size) |
| `/var/lib/vz/snippets/runner-user-data.yaml` | Cloud-init config for VMs |
| VM template (default ID 9000) | Ubuntu cloud image template |

## Security Notes

- **PAT storage**: PATs are stored per-org in `/etc/github-runners.d/<org>.conf` with mode 600 (root only readable). `/etc/github-runners.conf` holds infrastructure settings only and contains no secrets.
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
