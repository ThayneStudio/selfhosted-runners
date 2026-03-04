# selfhosted-runners

One-command setup for self-hosted GitHub Actions runners on Proxmox.

## Quick Start

```bash
# On your Proxmox host
git clone https://github.com/youruser/selfhosted-runners.git
cd selfhosted-runners
./setup.sh
```

The wizard will ask for:
- GitHub organization name
- GitHub PAT (with `admin:org` scope)
- Network bridge (default: vmbr0)
- Storage pool (default: local-zfs)

Then create runners:
```bash
./create-runner.sh runner-01
./create-runner.sh runner-02
```

## Prerequisites

- Proxmox VE 7.x or 8.x
- GitHub organization (free tier works)
- GitHub PAT with `admin:org` scope

### Creating a GitHub PAT

1. Go to GitHub → Settings → Developer settings → Personal access tokens → Tokens (classic)
2. Generate new token with `admin:org` scope
3. Copy the token (starts with `ghp_`)

## Runner Specs

| Resource | Value |
|----------|-------|
| CPU | 2 cores |
| RAM | 8 GB |
| Disk | 30 GB |

Matches GitHub-hosted runner specs.

## Commands

| Command | Description |
|---------|-------------|
| `./setup.sh` | Initial setup wizard |
| `./create-runner.sh <name>` | Create a new runner VM |
| `./destroy-runner.sh <name>` | Destroy a runner VM |
| `./list-runners.sh` | List all runner VMs |

## Installed Software

Runners come with:
- Docker + Docker Compose
- Node.js (LTS)
- Playwright system dependencies
- Git, curl, jq, build-essential

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

1. Edit `templates/runner-user-data.yaml`
2. Re-run setup to regenerate the cloud-init snippet:
   ```bash
   ./setup.sh
   ```
3. Destroy and recreate runners:
   ```bash
   ./destroy-runner.sh runner-01
   ./create-runner.sh runner-01
   ```

## Troubleshooting

Check cloud-init logs:
```bash
qm guest exec <vmid> -- cat /var/log/cloud-init-output.log
```

Check runner service:
```bash
qm guest exec <vmid> -- systemctl status actions.runner.*
```

## Files Created by Setup

| Location | Purpose |
|----------|---------|
| `/etc/github-runners.conf` | Saved configuration (org, PAT, storage) |
| `/var/lib/vz/snippets/runner-user-data.yaml` | Generated cloud-init config |
| VM template (ID 9000) | Ubuntu cloud image ready for cloning |

## Security Notes

- PAT is stored in `/etc/github-runners.conf` with mode 600 (root only)
- To rotate PAT: edit the config file, re-run `./setup.sh`, recreate runners
- VMs are disposable: change config → destroy → recreate
