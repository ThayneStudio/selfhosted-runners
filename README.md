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
│  /etc/github-runners.conf          ← Configuration (PAT, org)  │
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
| cloud-images.ubuntu.com | 443 | Ubuntu cloud image |

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
| `runner destroy <name>` | Destroy a runner VM |
| `runner list` | List all runner VMs |
| `runner help` | Show available commands |

## Installed Software

Runners come pre-installed with:

- **Docker CE** + Docker Compose
- **Node.js LTS** (via NodeSource)
- **Playwright** system dependencies
- **Build tools**: git, curl, jq, build-essential, wget

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

To update runner configuration or installed software:

1. Edit `/opt/selfhosted-runners/templates/runner-user-data.yaml`
2. Re-run setup to regenerate the cloud-init snippet:
   ```bash
   runner setup
   ```
3. Destroy and recreate runners:
   ```bash
   runner destroy runner-01
   runner create runner-01
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

Run `./setup.sh` first to create the configuration.

### "Template VM does not exist" error

The template was deleted. Re-run `./setup.sh` to recreate it.

### VM creation fails with "storage not found"

The storage pool specified during setup doesn't exist. Re-run `./setup.sh` and select a valid storage pool.

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
| `/etc/github-runners.conf` | Configuration (org, PAT, storage) |
| `/var/lib/vz/snippets/runner-user-data.yaml` | Cloud-init config for VMs |
| VM template (default ID 9000) | Ubuntu cloud image template |

## Security Notes

- **PAT storage**: The PAT is stored in `/etc/github-runners.conf` with mode 600 (root only readable)
- **Runner user**: VMs run as user `runner` with sudo access (required for Docker)
- **Docker access**: The `runner` user is in the `docker` group
- **Rotate PAT**: Edit config, re-run `./setup.sh`, recreate runners

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
