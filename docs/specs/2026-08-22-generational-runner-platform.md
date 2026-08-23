# Generational Runner Platform

**Status:** Draft for approval
**Date:** 2026-08-22
**Repo:** ThayneStudio/selfhosted-runners
**Baseline commit:** `4019cc7`

## 1. Problem

`4019cc7` registered runners with `--disableupdate` (`templates/runner-user-data.yaml:189`).
That removed a ~226 MB per-job download across three orgs, but it converted a
self-maintaining fleet into one that requires a human to rebake the template
within 30 days of every `actions/runner` release. The failure mode is silent:
registration still succeeds, runners show **Online / Idle** in the GitHub UI,
and jobs queue forever without being assigned.

Three structural problems make that obligation impossible to discharge reliably:

1. **No unattended bake path.** `runner setup` is nine `read -rp` prompts
   (`lib/setup.sh:46-150`) and never calls `load_infra_config`, unlike
   `lib/stop.sh:8`. It also skips baking entirely when the template already
   exists (`lib/setup.sh:254`). Nothing can schedule it. Piping answers into it
   makes prompt order load-bearing.
2. **No safe rollover.** `TEMPLATE_ID` is a single scalar
   (`lib/common.sh:59`, cloned at `lib/common.sh:558`). Rebaking means
   `qm destroy 9000` first, so a failed bake leaves the fleet with no template
   and all three orgs down until a human intervenes. There is no rollback.
3. **No visibility.** Drift is only detectable by a manual probe documented in
   the README. It surfaces when someone is already suspicious, which is after
   jobs have been queueing.

## 2. Goal

A self-maintaining runner platform, coordinated entirely through the `runner`
command, where the operator does not track runner releases or perform manual
rebakes.

Specifically:

- The platform detects when its inputs change and bakes a new image on its own.
- A new image proves it can complete a real GitHub job before any production
  traffic reaches it.
- Promotion is seamless: in-flight runners on the old image finish their jobs
  undisturbed; new clones come from the newest image.
- Once an old image has no clones left, it is destroyed and its space reclaimed.
- Anything requiring a human is pushed to Slack, not left in a log.

## 3. Approved decisions

| Decision | Choice |
|---|---|
| Rebake trigger | Upstream-driven (new runner release, rotated Ubuntu image, changed template inputs) **plus** a weekly floor |
| Promotion gate | Canary clone must register **and complete a real workflow job** |
| Retention | Keep the previous generation until the next successful bake (exactly one rollback target) |
| Alerting | Push to a configurable webhook, Slack-shaped payload |

## 4. Core model: generations

A **generation** is one baked Proxmox template plus its provenance metadata.
Generations are immutable once baked. Exactly one is `active` — the clone
target — at any moment.

### 4.1 States

```
baking ──▶ candidate ──▶ active ──▶ superseded ──▶ (destroyed, record archived)
   │           │            │
   └──▶ failed ┘            └──▶ rejected        (rolled back away from)
```

| State | Meaning |
|---|---|
| `baking` | VM created, guest running the bake. Not a template yet. |
| `candidate` | Bake confirmed and converted to a template. Not yet a clone target. Canary may run against it. |
| `active` | The clone target. Exactly one generation holds this. |
| `superseded` | Was active, replaced by a newer generation. Still serves in-flight clones. Eligible for GC per retention policy. |
| `failed` | Bake or canary failed. Retained for inspection; never promoted. |
| `rejected` | Was active, then rolled back away from by an operator. Terminal. Never retained as a rollback target, never re-activated by reconciliation. |

`destroyed` is not a state — the record is removed and an entry is appended to
the archive log (§4.4).

### 4.2 VMID allocation

Generations allocate from a dedicated band, default `8900-8999`, configured as
`TEMPLATE_BAND_MIN` / `TEMPLATE_BAND_MAX`.

The band sits **below** the current template ID on purpose. The existing default
`MIN_VMID` is `TEMPLATE_ID + 1` = `9001`, so a band at `9000-9099` would collide
with live runner VMIDs. A band at `8900-8999` collides with nothing in the
current deployment.

Validation, enforced at config load and at bake time: the band must not overlap
`[MIN_VMID, ∞)` and must not contain a VMID with an existing config that is not
a known generation. Overlap is a hard error with a message naming both values.

`MIN_VMID=0` means "auto" — `reserve_vmid` falls back to
`pvesh get /cluster/nextid` (`lib/common.sh:183-189`), which could allocate
inside the band. The overlap rule cannot be expressed for auto mode, so:
generations require `MIN_VMID > 0`. Config validation rejects
`MIN_VMID=0` with a message naming a suggested value
(`TEMPLATE_BAND_MAX + 1`). The current deployment uses `9001` and is unaffected.

The currently deployed template (`9000`) keeps its VMID when adopted (§8) —
adopted generations are exempt from the band requirement. Only newly baked
generations allocate from the band.

### 4.3 Generation record

One shell-sourceable file per generation, matching the existing conf idiom
(`/etc/github-runners.conf`, `/etc/github-runners.d/*.conf`):

`/var/lib/github-runners/generations/<vmid>.conf`

```sh
GEN_ID=7                                    # monotonic, from a counter file
GEN_VMID=8903
GEN_STATE=active                            # baking|candidate|active|superseded|failed
GEN_RUNNER_VERSION=2.336.0                  # baked actions/runner version
GEN_IMAGE_SHA256=<sha256 of the noble cloud image used>
GEN_TEMPLATE_DIGEST=<sha256 of bake inputs, see 6.1>
GEN_CREATED_AT=2026-08-22T01:14:03Z         # UTC, ISO 8601
GEN_PROMOTED_AT=
GEN_SUPERSEDED_AT=
GEN_FAILED_REASON=
GEN_BAKE_LOG=/var/log/github-runners/bake-7.log
GEN_CANARY_RUN_URL=
```

All writes are atomic: `mktemp` in the same directory, `chmod 600`, then `mv`.
This is the pattern already used at `lib/setup.sh:203-215`.

`GEN_ID` comes from `/var/lib/github-runners/generations/.counter`, incremented
under `flock`. Never reused, including after a generation is destroyed.

"Never reused" is **not enforceable from surviving records alone**: once a
generation is destroyed its id exists only in the archive log (§4.4). Any reseed
of a lost or corrupted counter must therefore take the maximum across both the
surviving records **and** `archive.log`, and must treat a record it cannot parse
as fatal rather than skipping it — a skipped record silently lowers the maximum
and the next allocation hands out an id a live generation still holds.

### 4.4 Archive log

`/var/lib/github-runners/generations/archive.log`, append-only, one line per
terminal event, for post-hoc questions like "what did we run in July":

```
2026-08-22T04:11:07Z gen=6 vmid=8902 event=destroyed runner=2.335.0 age_days=34 reclaimed_gb=28
```

Deliberately no `clones_served` counter: incrementing one would put new shared
state and its locking on the clone hot path, which §4.5 exists to avoid. Clone
history is recoverable from the journal if anyone ever needs it.

### 4.5 Active pointer

`TEMPLATE_ID` in `/etc/github-runners.conf` **remains the pointer to the active
generation**. Promotion rewrites it atomically.

This is deliberate: `lib/create.sh:41` and `lib/watch.sh:20` keep working
unchanged, and `clone_runner` (`lib/common.sh:558`) keeps its structure, so the
generation model is additive rather than a rewrite of the clone path. The blast
radius of this spec is the lifecycle code, not the hot path.

`clone_runner` is not literally untouched — it gains three things: a re-read of
the active pointer after taking the shared lock (§7.3), a `qm set --tags` call
(§5), and a `vendor=` element in `--cicustom` for canary clones only (§7.1).
Each is additive and none changes how a normal clone is produced. No new shared
state is added to it — see §4.4 on why there is no per-clone counter.

## 5. Clone attribution and refcounting

GC correctness depends on knowing which generation each live clone came from.

**Primary mechanism — Proxmox tags.** `clone_runner` sets
`qm set <vmid> --tags runner,gen-<GEN_ID>` immediately after cloning.
`get_vm_generation()` parses `tags:` from `qm config`. This is uniform across
storage backends, survives host reboots, and is visible in the Proxmox UI.

**The tag must be derived from the VMID actually cloned**, by looking up the
generation record whose `GEN_VMID` matches — never from "whichever generation is
currently active." A promotion can land between a caller reading the pointer and
`clone_runner` running (§7.3), and tagging such a clone with the new generation
would undercount the old one's refcount and could let GC destroy a template that
still has children. On ZFS the origin cross-check would catch it; on `dir`/`lvm`
there is no origin and the accounting would be silently wrong.

**Cross-check — ZFS origin.** On ZFS storage, a linked clone's dataset carries
an `origin` property pointing at the generation's base volume snapshot.
`lib/common.sh` already implements exactly this traversal in
`zfs_dataset_from_volid` and `list_template_linked_clone_volids`. The refcount
routine uses ZFS origin as an authoritative cross-check where available, and
logs a warning on disagreement with the tag (which indicates manual VM
surgery).

**refcount(gen)** = number of VM configs, excluding template VMIDs, attributed
to that generation by tag or origin.

A generation with `refcount == 0` has no clones and is safe to destroy.
`cleanup_template_orphan_volumes` (`lib/common.sh:326-375`) already implements
the "refuse to delete while children have configs" guard and returns `2` for
that case; it is generalized from "the template" to "a given generation."

**Untagged clones.** Clones created before this work is deployed have no tag.
Adoption (§8) tags them as generation 1. A clone that is untagged and has no
resolvable ZFS origin is attributed to the active generation and logged at
`warn` — conservative, since it can only delay GC, never cause a premature
destroy.

## 6. Bake pipeline

New library `lib/bake.sh`, callable non-interactively. `lib/setup.sh` is
refactored to call it for the first-run interactive path, so there is exactly
one bake implementation.

Side effect worth stating: this removes the config-clobber footgun. Today the
wizard re-prompts all eight infrastructure questions with hardcoded defaults and
silently clears `DOCKER_MIRROR_URL` and `VLAN_TAG`. After this change, rebaking
never touches `/etc/github-runners.conf`.

### 6.1 Input digest

`GEN_TEMPLATE_DIGEST` is `sha256` over the concatenation of:

- `templates/template-setup.yaml` (rendered, after `DOCKER_MIRROR_URL` substitution)
- the resolved `actions/runner` version string
- the Ubuntu cloud image `SHA256SUMS` entry for `noble-server-cloudimg-amd64.img`
- the values of `DOCKER_MIRROR_URL`, `VM_STORAGE`, `NETWORK_BRIDGE`, `VLAN_TAG`, `DNS_SERVERS`, `BALLOON`

A bake is needed when the computed digest differs from the active generation's
digest, or when the active generation exceeds `REBAKE_MAX_AGE_DAYS`.

### 6.2 Steps

1. Acquire `/run/lock/github-runner-bake.lock` exclusively, non-blocking. A
   second bake exits 0 with a log line.
2. Pre-flight: free space on `VM_STORAGE` ≥ `BAKE_MIN_FREE_GB` (default 60).
   Insufficient space is a hard failure with a `warn` notification, before
   anything is created.
3. Resolve inputs, compute digest. Unless `--force`, exit 0 if unchanged and the
   active generation is within `REBAKE_MAX_AGE_DAYS`.
4. Allocate a generation VMID from the band. Write the record, `GEN_STATE=baking`.
5. Download and verify the Ubuntu image. **On checksum mismatch: delete,
   re-download once, re-verify.** A second mismatch is a hard failure. This is
   the fix for the recurring stale-cache failure (§11.3).
6. Create the VM, attach the rendered `template-setup.yaml` snippet, boot.
7. Poll for `/opt/.template-setup-complete` over the guest agent, exactly as
   `lib/setup.sh:399-443` does today, including the publish gate that refuses to
   convert a VM whose marker was never confirmed, the `BAKE_TIMEOUT` bound
   (default 5400s), and the guest-log tail on timeout.
8. Shut the VM down from the host, convert with `qm template`.
9. Read the baked runner version out of the template's disk metadata recorded
   during the bake (the bake writes `/opt/.runner-version` alongside the
   completion marker; the host reads it over the guest agent **before**
   shutdown, since a template cannot be executed).
10. `GEN_STATE=candidate`. Notify `info`.

### 6.3 Failure behavior

Any failure before step 10 destroys the partial VM (`qm destroy --purge`), frees
orphan volumes at that VMID, sets `GEN_STATE=failed` with `GEN_FAILED_REASON`,
and notifies at `error`.

**The active generation is never touched.** The fleet keeps serving jobs from it
for the entire bake. This is the core robustness property that the current
destroy-first procedure lacks.

Repeated failure on an unchanged digest does not retry indefinitely: a digest
recorded as failed is not re-attempted until the digest changes or
`runner bake --force` is run. Retry state lives in
`/var/lib/github-runners/failed-digests`.

**The memo covers bake failures only.** A canary failure never memos a digest on
its own (§7.5) — bake failures are deterministic in their inputs, canary
failures usually are not.

**Precedence, stated explicitly because these two rules otherwise contradict:**
the failed-digest memo **overrides** the weekly floor (§11.2). A digest that
failed to bake is not re-attempted just because seven days elapsed — that would
rebuild a known-broken input on a schedule. The generation instead keeps ageing,
so the drift alarm (§11.4) escalates it to a human, which is the correct
outcome: a bake that fails deterministically needs a person, not a retry.

## 7. Canary promotion gate

A candidate generation must complete a real GitHub Actions job before promotion.
Registering successfully is explicitly not sufficient — a runner that registers
and shows Idle while never being assigned work is the exact failure mode this
platform exists to prevent, and it is invisible to any local smoke test.

### 7.1 Mechanism

**Label isolation is the critical detail.** GitHub assigns a queued job to any
idle runner whose label set is a *superset* of the job's `runs-on`. A canary
carrying the production labels would therefore be handed real production jobs
while it waits for its dispatch — running them on an unvalidated image, and then
(being `--ephemeral`) destroying itself, so the canary dispatch finds no runner
and times out. That would both violate the platform's core promise and reject
good images routinely. The canary must carry **only** its own label.

Note that setting `RUNNER_LABELS` is not sufficient: `config.sh` *adds* the
default `self-hosted`/`Linux`/`X64` labels unless `--no-default-labels` is
passed (`templates/runner-user-data.yaml:182-190` builds the invocation).

1. Write a per-VM cloud-init **vendor-data** snippet containing
   `/etc/github-runner/labels.env` with
   `RUNNER_LABELS="gen-<GEN_ID>-canary"` and `RUNNER_NO_DEFAULT_LABELS=true`.
   `register-runner.sh` already sources that file if present
   (`templates/runner-user-data.yaml:49-51`) — nothing writes it today, so the
   hook exists and is unused. It gains one conditional that appends
   `--no-default-labels` to the `config.sh` invocation when
   `RUNNER_NO_DEFAULT_LABELS` is set.

   This is cheaper than the alternative of a separate rendered canary user-data
   file, and avoids threading a fourth `{{...}}` placeholder through the awk
   substitution in `lib/add-org.sh` and `install.sh`. `clone_runner` gains a
   `vendor=` element in its `--cicustom` argument (`lib/common.sh:599`) for this
   case only.

   Rejected alternative: a dedicated org runner group restricted to
   `CANARY_REPO`. It isolates just as well but requires org-admin configuration
   outside this repo for each of the three orgs, and cannot be asserted from the
   host at canary time.
2. Clone one VM from the candidate generation, named `canary-gen<GEN_ID>`,
   tagged `runner,gen-<GEN_ID>,runner-canary`.
3. Wait for it to appear as Online in the org's runner list (poll the API,
   `CANARY_REGISTER_TIMEOUT`, default 600s).
4. `workflow_dispatch` `CANARY_WORKFLOW` in `CANARY_REPO`, passing the
   generation id as an input so the workflow targets
   `runs-on: [gen-<GEN_ID>-canary]` — that label alone, no `self-hosted`, since
   the canary no longer carries the default labels.
5. Poll the run to conclusion, `CANARY_TIMEOUT` (default 1800s).
6. `success` → promote (§7.3). Anything else → retry per §7.5.

### 7.2 Canary workflow content

Lives in `CANARY_REPO`, authored as part of this work, and doubles as the
acceptance test for the bake:

- `psql --version` reports major `POSTGRES_CLIENT_VERSION`
- `supabase --version` matches `SUPABASE_VERSION`
- Chromium resolves from the prebaked `PLAYWRIGHT_BROWSERS_PATH` without
  downloading, at the revision the pinned CLI plans to use

  Explicitly **not** a CLI version assertion. `npm exec --package=playwright@X`
  fetches X from the registry and runs it, so it reports X by construction
  regardless of what the image contains — and the bake installs no global
  Playwright CLI to check. The resolved browser revision is the only signal here
  with teeth. (The bake's own verification at `templates/template-setup.yaml`
  carries the same tautology and should be corrected with it.)
- `docker pull` of one Supabase image resolves through `DOCKER_MIRROR_URL` when
  configured
- `aws --version` reports v2
- a trivial `supabase start` / `supabase stop` round trip

### 7.3 Promotion

Promotion holds `POOL_ACTIVITY_LOCK_FILE` (`lib/common.sh:28`) **exclusively**.
Two properties of the existing locking make the naive version of this wrong, and
both must be handled.

**There are now three exclusive takers, not two.** This section originally
enumerated `runner stop` and promotion. The §10.1 lifetime guard is a third, on a
five-minute cadence — and its first implementation held the lock across `qm`
destroys and two 10-second GitHub API calls per VM, which starved clones badly
enough that systemd SIGKILLed the watcher mid-`qm clone`. **The guard must not
take the pool lock at all.** It uses the per-slot locks that `lib/reclone.sh` and
`lib/watch.sh` already use (`/run/lock/runner-<name>.lock`), plus a config-mtime
freshness test to exclude a VM that is mid-clone. Anything that holds the pool
lock must complete in bounded time with no network calls inside the hold.

**Acquisition can starve.** `clone_runner` holds the lock *shared* for its
entire lifecycle (`lib/common.sh:445-655`, shared lock taken at `:449-450`) — including
`acquire_clone_slot`'s busy-wait and a `qm clone` that is minutes long on
`dir`/`lvm` full-copy storage. Linux `flock` has no writer preference: new
shared holders are granted even while an exclusive request waits. With a 30-second
watch timer and hookscript-driven reclones across three orgs, there may be no
moment with zero shared holders, and `runner promote` could block until the
maintain window closes. `runner stop` has the same structure but escapes it by
setting the drain flag first (`lib/common.sh:452-456` bails immediately after
taking the lock shared), which chokes off new acquisitions. Promotion cannot
drain the pool — that would defeat the point — so it uses a narrower
`PROMOTION_PAUSE_FILE` that `clone_runner` checks *after* taking the lock
shared: a paused clone releases and retries rather than proceeding. Acquisition
is `flock -w 120`; on timeout, promotion is abandoned and retried next
`maintain` with a `warn`, never forced.

**Holding the lock does not make in-flight callers see the new pointer.**
`clone_runner` uses `$TEMPLATE_ID` inherited from the caller's
`load_infra_config`, which ran much earlier — `lib/watch.sh:12` before forking up
to six workers, `lib/reclone.sh:12` before backoff bookkeeping and up to three
destroy attempts with sleeps. So `clone_runner` **must re-read the active
pointer after acquiring the shared lock**, and derive the generation tag from
the VMID it actually clones (§5). Without the re-read, post-promotion clones keep
coming from the superseded generation, delaying drain; without the correct tag
derivation, they are attributed to the wrong generation.

The sequence, once the exclusive lock is held:

1. Candidate → `active`, stamp `GEN_PROMOTED_AT`.
2. Rewrite `TEMPLATE_ID` in `/etc/github-runners.conf` atomically.
3. Previous active generation → `superseded`, stamp `GEN_SUPERSEDED_AT`.
4. Release the lock and the pause file. Notify `info`.

**Promote before demote, deliberately.** A crash between steps leaves two
generations stamped `active` — a case §15 defines a repair for — rather than
zero, which it cannot repair.

### 7.4 Canary cleanup

The canary VM is ephemeral and powers off after its one job, which fires the
existing hookscript. `lib/reclone.sh` must **skip re-cloning VMs tagged
`runner-canary`** — it currently re-clones anything whose name and org it can
read (`lib/reclone.sh:20-26`), which would resurrect the canary forever.
Instead: destroy, free volumes, do not re-clone.

`lib/watch.sh` needs no change — it fills slots by `RUNNER_PREFIX`-`N` name
match (`lib/watch.sh:43-46`) and `canary-gen<N>` matches no slot.

### 7.5 Canary retry policy

A canary failure is not by itself evidence of a bad image. Transient causes
include a GitHub Actions incident, Actions queue latency beyond
`CANARY_TIMEOUT`, a host reboot during the canary, and PAT expiry. Rejecting a
good generation on one of those, with no retry, would strand the fleet for the
4-6 weeks until the next upstream release changes the digest.

Therefore:

- The **candidate template is retained** on canary failure. Only the canary VM
  is destroyed. Retries are cheap — a clone and a dispatch, not a 45-minute
  bake.
- `maintain` retries the canary on subsequent runs, up to
  `CANARY_MAX_ATTEMPTS` (default 3), recorded as `GEN_CANARY_ATTEMPTS` in the
  record. Each failed attempt notifies at `warn` with the run URL.
- On the final attempt: `GEN_STATE=failed`, `error` notification, **and** the
  digest is memoed (§6.3) so the pipeline stops rebaking an image that cannot
  pass. This is the one path where a canary failure reaches the memo.
- A canary that cannot even be attempted — `CANARY_REPO` unset, PAT scope
  missing, workflow file absent — does not consume an attempt. It notifies
  `warn` and leaves the candidate pending, because retrying a misconfiguration
  is pointless and burning the attempt budget on it would reject a good image.

## 8. Migration and adoption

The upgrade must be a no-op for a running fleet. On first run of any
generation-aware command:

1. If `/var/lib/github-runners/generations/` is empty and `TEMPLATE_ID` names an
   existing template, write a record for it: `GEN_ID=1`, `GEN_STATE=active`,
   provenance fields populated where derivable (image sha and template digest
   are recorded as `unknown` — they cannot be reconstructed after the fact).
2. Tag every live clone whose disk traces to that template `gen-1`.
3. An `unknown` digest never matches, so the first scheduled run after adoption
   bakes generation 2. That is the intended behavior: the deployed template
   ships 2.334.0 and is already outside the 30-day window.

Adoption is idempotent and safe to re-run. It never destroys anything.

Deployment order is `install.sh` (host code, instant) then adoption, which runs
automatically. No rebake is required to adopt — the fleet keeps running on
generation 1 until generation 2 passes its canary.

## 9. Garbage collection

`runner gc`, run by the maintenance timer and available manually.

For each generation in `superseded`:

1. Compute refcount (§5).
2. `refcount > 0` → skip. If it has been blocked longer than
   `GC_STUCK_WARN_HOURS` (default 12), notify `warn` naming the blocking VMIDs.
   A superseded generation should drain within one job cycle; longer means a
   stuck clone (§10).
3. `refcount == 0` → apply retention: retain the single newest superseded
   generation as the rollback target. Older ones are destroyed.
4. Destroy: `qm destroy <vmid> --purge`, then free residual linked-clone child
   volumes via the generalized `cleanup_template_orphan_volumes`. Remove the
   record, append to the archive log, notify `info` with reclaimed bytes.

4a. If `qm destroy` or any volume free fails, the record **stays** in
   `superseded` and a `warn` is notified. The record is removed only after
   storage is verified clean. Removing it on a partial destroy would orphan the
   remaining volumes outside the generation model, where nothing would ever
   reclaim them.

   Note that ZFS refuses to destroy a base volume whose snapshot still has clone
   children. That is a useful backstop: a refcounting bug cannot silently
   destroy a template that clones still depend on — it fails loudly here
   instead.

`failed` and `rejected` generations are destroyed after
`FAILED_GEN_RETAIN_DAYS` (default 7), so inspection is possible without
unbounded accumulation.

**`candidate` generations are collected too**, or they leak a full template each
time one is orphaned. A candidate is orphaned when a newer candidate is baked
before it was promoted, or when it can never be canaried (§14). GC supersedes
any `candidate` that is not the newest candidate, and marks `failed` any
candidate older than `CANDIDATE_MAX_AGE_DAYS` (default 3) that has not been
promoted, notifying `warn` with the reason.

`runner gc --dry-run` prints what it would do and exits.

## 10. Termination robustness

GC correctness depends on clones actually terminating. A clone that never dies
holds a refcount forever and blocks its generation's destruction permanently.
Four known holes make that reachable, so they are in scope here rather than
optional hardening.

### 10.1 Host-side VM lifetime guard

The current 6-hour ceiling is `shutdown -h +360` inside the guest
(`templates/runner-user-data.yaml:220-223`). That is cooperative, not enforcing:
the `runner` user has `NOPASSWD:ALL` (`templates/template-setup.yaml:4-7`) so any
CI job can cancel it, and a wedged guest — hang, panic, reboot loop — runs
nothing at all, which is precisely the case a lifetime guard exists for.

The guard belongs on the Proxmox host: a systemd timer that `qm destroy`s
managed runner VMs whose uptime exceeds `MAX_VM_LIFETIME_HOURS` (default 8, above
the guest's 6h so the cooperative path wins normally). Scoped to VMIDs
`>= MIN_VMID` with a `runner` tag, never templates. Each forced destroy
notifies `warn`. No bake and no cloud-init change required.

### 10.2 Per-boot shutdown re-arm

`shutdown -h +360` is armed from `runcmd`, which cloud-init runs per-instance,
and the timer itself is in-memory logind state. A guest reboot cancels the
shutdown and cloud-init does not re-arm it, because the instance-id is pinned
host-side at clone time (`lib/common.sh:594`). The `EXIT` trap at
`templates/runner-user-data.yaml:37` dies with the process for the same reason.
Nothing reaps the result, and the hookscript only fires on `post-stop`
(`templates/runner-hookscript.sh:11`), which a guest-internal reboot never
triggers.

Fix: re-arm the ceiling on every boot from the host-side snippet.

The obvious version — move the line from `runcmd` to `bootcmd` — is one line and
needs no bake, but it is not reliable on its own: `shutdown -h +360` schedules
through logind over D-Bus, and `bootcmd` runs in cloud-init's init stage, where
dbus/logind may not be up yet. A silent failure there buys nothing. Use a
`bootcmd`-installed systemd transient timer (`systemd-run --on-active=6h`) or an
enabled unit instead, and verify the re-arm on a second boot as part of
acceptance. §10.1 remains the enforcing backstop regardless.

Reaching a second boot requires a job calling `sudo reboot`, a panic configured
to reboot, or an operator `qm reboot` — rare, but the consequence is now
permanent GC blockage rather than one wasted VM.

### 10.3 Maintenance state must survive a host reboot

`POOL_DRAIN_FILE` is `/run/lock/github-runner-drain` (`lib/common.sh:24`), which
is tmpfs. It does not survive a host reboot, and the watcher timer stays
enabled, so rebooting between `runner stop` and `runner start` silently resumes
runner creation mid-maintenance.

Move the flag to `/var/lib/github-runners/drain` and have `pool_is_draining()`
honor both paths during the transition — **and migrate an existing tmpfs flag to
the persistent path on upgrade**, in `install.sh`.

The migration is not optional, and an earlier revision of this section caused a
real defect by omitting it. "Honor both paths" alone leaves the legacy flag on
tmpfs, so the canonical sequence — `runner stop`, upgrade in the same
maintenance window, reboot the host — still loses the drain and the watcher
refills the pool mid-maintenance. That is the exact scenario the transition
handling exists to protect, so honoring a tmpfs flag cannot be the whole answer.
`enable_pool_drain` should also write both paths, so every version ordering
(including a downgrade) agrees. `templates/runner-hookscript.sh:9`
hardcodes the tmpfs path rather than calling `pool_is_draining()`, so it must be
updated in the same change — otherwise the hookscript reclones during a
persisted drain. (`lib/reclone.sh` re-checks via the function, so the blast
radius is contained, but the inconsistency is real.) The unattended pipeline must be able to
rely on maintenance mode holding across a reboot.

### 10.4 Stopped runner VMs must be reaped

The most likely GC blocker, and a fleet-availability bug that already exists
today independent of generations.

A managed runner that powers off while the drain flag is set is skipped by the
hookscript (`templates/runner-hookscript.sh:12-14`), leaving a **stopped VM with
its config intact**. `runner stop --watch-only` leaves VMs intact by design, and
a host reboot produces the same result — VMs come back stopped, and any
hookscript-spawned reclone died with the host.

Nothing reaps them. `lib/watch.sh:43-46` matches slot names against `qm list`,
which includes stopped VMs, so the slot counts as filled and is never refilled;
`lib/start.sh` only clears the drain flag. The §10.1 lifetime guard does not help
either, because it is keyed on **uptime**, which a stopped VM does not
accumulate. The slot stays dead until someone notices, and under generations the
config holds a refcount forever.

§10.3 makes this strictly worse by widening the window in which a drain can be
in force, which is why it belongs in the same phase.

Fix: a stopped VM tagged as a managed runner is always garbage — it either
finished its one job or crashed. The lifetime guard also destroys managed VMs in
`stopped` state older than `STOPPED_REAP_MINUTES` (default 10, comfortably above
the normal destroy-and-reclone turnaround), and `runner start` reaps them before
handing back to the watcher.

## 11. Scheduling and detection

### 11.1 Timer

`github-runner-maintain.timer`, `OnCalendar=*-*-* 02:30:00` — deliberately
**inside** `REBAKE_WINDOW`, since a daily timer firing outside the window would
run detection and drift checks but never actually bake. `Persistent=true` so a
missed run fires after downtime; a catch-up run that lands outside the window
performs every stage except starting a bake, and the bake defers to the next
window rather than being skipped for the day. `ExecStart=/usr/local/bin/runner maintain`, which runs:
adoption if needed → detect → bake if needed → canary → promote → gc → drift
check. Each stage is individually idempotent and safe to interrupt.

Bakes start only inside `REBAKE_WINDOW` (default `02:00-06:00` host local time)
so a 30-45 minute bake does not compete with CI. Detection, GC, and drift checks
run regardless of window. `runner bake --force` ignores the window.

### 11.2 Weekly floor

`REBAKE_MAX_AGE_DAYS` (default 7) forces a bake even with an unchanged digest.
This is the backstop for release-detection breaking silently — the failure the
upstream-only trigger cannot self-correct.

The floor does **not** override the failed-digest memo (§6.3). A digest that
failed to bake stays blocked until it changes or a human runs
`runner bake --force`; the drift alarm escalates in the meantime.

### 11.3 Detection inputs

- `actions/runner` latest release via the GitHub API, the same call the bake
  already makes at `templates/template-setup.yaml:290`
- Ubuntu `noble/current/SHA256SUMS` entry for the cloud image
- rendered `template-setup.yaml` content hash
- infrastructure config values listed in §6.1

Detection failure (API unreachable, rate limited) is logged, notified at `warn`
only after `DETECT_FAIL_WARN_HOURS` (default 24) of consecutive failures, and
never blocks the weekly floor.

### 11.4 Drift alarm

Independent of the bake pipeline, so it still fires when the pipeline is broken.
Compares the active generation's `GEN_RUNNER_VERSION` against the latest
upstream release and computes days remaining in the 30-day window:

- ≤ 10 days remaining → `warn`
- ≤ 3 days remaining, or already past → `error`

## 12. Notifications

`lib/notify.sh`, one function `notify <severity> <event> <message> [detail]`.

Config in `/etc/github-runners.conf`:

```sh
NOTIFY_WEBHOOK_URL=https://hooks.slack.com/services/...
NOTIFY_MIN_SEVERITY=warn          # info|warn|error
NOTIFY_FORMAT=slack               # slack|text
```

Slack payload — extra keys are ignored by Slack, so one shape serves generic
webhook consumers too:

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

The Slack shape is already valid generic JSON, so only two formats exist:
`slack` (the object above) and `text` (the `text` field alone, for ntfy-style
consumers that want a plain body).

Rules: `curl --max-time 10`, at most 2 retries, failure to notify is logged but
**never** fails the calling operation. `GITHUB_PAT`, `CANARY_PAT`, and
`NOTIFY_WEBHOOK_URL` are never included in a payload or log line — canary
failure notifications in particular are assembled next to PAT-using code.

Events: `bake.started`, `bake.failed`, `canary.attempt_failed`, `canary.failed`,
`canary.unconfigured`, `generation.promoted`, `generation.rolled_back`,
`generation.destroyed`, `gc.blocked`, `drift.warning`, `drift.critical`,
`lifetime.forced_destroy`, `stopped_vm.reaped`.

## 13. CLI surface

Existing commands are unchanged. New verbs:

| Command | Behavior |
|---|---|
| `runner status` | Fleet overview: generations with state/age/refcount, active runner version vs upstream latest, days left in the 30-day window, last bake result, per-org pool fill, drain state. The single "is everything fine" command. |
| `runner generations` | Table of generations: id, vmid, state, runner version, age, clone refcount, disk usage. |
| `runner bake [--force]` | Non-interactive bake to a new candidate. `--force` ignores digest and window. |
| `runner canary <gen>` | Run the canary gate against a candidate. |
| `runner promote <gen> [--skip-canary]` | Manual promotion. `--skip-canary` requires an interactive confirmation. |
| `runner rollback` | Point active at the retained previous generation, and move the generation being rolled away from to `rejected` (§4.1) with a reason. Refuses if none retained. |
| `runner rollover [--force]` | Report old-generation clones still in service. `--force` deregisters and destroys the ones GitHub reports as **not busy**, so the pool refills from the active generation without waiting. Never touches a busy runner. |
| `runner guard [--dry-run]` | Enforce VM lifetime and reap stopped managed VMs (§10.1, §10.4). Run by its own timer; `--dry-run` prints candidates and reasons without destroying. |
| `runner gc [--dry-run]` | Run garbage collection. |
| `runner maintain` | The full unattended cycle. What the timer calls. |

`runner rollover --force` uses the org runner API's `busy` field, reached with
the same PAT flow as `deregister_runner` (`lib/common.sh:411-432`).

## 14. Configuration additions

Appended to `/etc/github-runners.conf`.

**Adoption requires no config edits to keep running, but the platform does not
become self-maintaining until three values are supplied** (§20): `CANARY_REPO`,
a PAT with sufficient scope, and `NOTIFY_WEBHOOK_URL`. `CANARY_ENABLED` therefore
defaults to **false**: a default of true with an empty `CANARY_REPO` would bake a
candidate that can never be canaried or promoted, wedging silently and leaking a
~30 GB template per cycle.

While `CANARY_ENABLED=true` and `CANARY_REPO` is empty, `maintain` refuses to
start a bake at all and notifies `canary.unconfigured` at `warn`, rather than
baking something it cannot promote.

```sh
TEMPLATE_BAND_MIN=8900
TEMPLATE_BAND_MAX=8999
REBAKE_ENABLED=true
REBAKE_MAX_AGE_DAYS=7
REBAKE_WINDOW="02:00-06:00"
BAKE_TIMEOUT=5400
BAKE_MIN_FREE_GB=60
GENERATION_RETAIN=1
FAILED_GEN_RETAIN_DAYS=7
GC_STUCK_WARN_HOURS=12
MAX_VM_LIFETIME_HOURS=8
CANARY_ENABLED=false              # set true once CANARY_REPO is configured
CANARY_ORG=
CANARY_REPO=
CANARY_MAX_ATTEMPTS=3
CANDIDATE_MAX_AGE_DAYS=3
STOPPED_REAP_MINUTES=10
CANARY_WORKFLOW=runner-canary.yml
CANARY_PAT=                       # optional; defaults to the org PAT
CANARY_REGISTER_TIMEOUT=600
CANARY_TIMEOUT=1800
NOTIFY_WEBHOOK_URL=
NOTIFY_MIN_SEVERITY=warn
NOTIFY_FORMAT=slack
DETECT_FAIL_WARN_HOURS=24
```

**PAT scope.** `workflow_dispatch` needs `repo` scope on a classic PAT or
`actions:write` on a fine-grained one. The org PAT collected by `add-org.sh`
requires only `admin:org`, so it may be insufficient. `CANARY_PAT` overrides it.
Scope is validated when the canary is configured, with an error naming the
missing scope rather than a failed dispatch later.

## 15. Error paths

| Condition | Behavior |
|---|---|
| Bake fails at any step | Partial VM destroyed, volumes freed, `failed` state, `error` notification. Active generation untouched, fleet unaffected. |
| Image checksum mismatch | Delete, re-download once, re-verify. Second mismatch is a hard failure. |
| Bake exceeds `BAKE_TIMEOUT` | Abort, dump last 40 guest log lines, treat as bake failure. |
| Host reboots mid-bake | Bake lock is in tmpfs and clears. Next `maintain` finds a `baking` record, takes the bake lock non-blocking, and only if it **succeeds** (proving no live bake) destroys the VM and marks `failed`. The lock check is required: the record is written before the VM is created and stays "not running" during image download, so a concurrent manual `maintain` would otherwise kill a healthy in-flight bake. |
| Canary fails to register | `failed`, `error` notification, canary VM destroyed. |
| Canary job fails or times out | `failed`, `error` notification with run URL. Candidate template retained for inspection. |
| Promotion interrupted | Promote-before-demote (§7.3) means the crash window yields two `active` records, never zero. |
| Two generations marked `active` | Reconciliation prefers the generation `TEMPLATE_ID` names; if that is ambiguous, the one with the newest `GEN_PROMOTED_AT`. **Never the highest `GEN_ID`** — after a rollback the higher id is the generation the operator just escaped, and re-activating it would undo the rollback. The loser is demoted to `superseded`, `warn` notified. |
| Zero generations marked `active` | Cannot arise from §7.3's ordering, but is repairable if it does: the generation `TEMPLATE_ID` names is restored to `active`, `warn` notified. |
| Rollback target selection | Retention (§9) never retains a `rejected` generation as the rollback target, so a rolled-back-from image cannot become the thing a future rollback lands on. |
| GC blocked > `GC_STUCK_WARN_HOURS` | `warn` naming blocking VMIDs. Never force-destroys a generation with live clones. |
| Disk below `BAKE_MIN_FREE_GB` | Bake refuses to start, `warn` notification. |
| Webhook unreachable | Logged, operation proceeds. |
| Band overlaps `MIN_VMID` | Hard config error naming both values, before anything is created. |
| Untagged clone, no ZFS origin | Attributed to active generation, logged `warn`. Can only delay GC. |

## 16. Test strategy

The repo has no tests today. This work introduces the first ones.

- **Static:** `shellcheck` over `runner`, `lib/*.sh`, `install.sh` in CI, plus
  `yamllint` on the cloud-init templates. Gates every PR.
- **Unit (`bats-core`, `tests/unit/`):** pure helpers with no Proxmox
  dependency — generation state transitions, digest computation, band/`MIN_VMID`
  overlap validation, retention selection, tag parsing, ISO-8601 age math,
  notification payload shaping and secret redaction. Proxmox commands are stubbed
  by putting fake `qm`/`pvesm`/`zfs` on `PATH`.

  Two constraints, both learned the hard way. **Code under test must reference
  every host path through a constant in `lib/common.sh`, never a string
  literal** — the harness sandboxes by repointing variables, so a literal like
  `exec 200>"/run/lock/runner-${NAME}.lock"` escapes it and a unit test run on a
  real host takes a real lock against a live runner. And **the shared harness is
  the only stubbing mechanism**; parallel issues writing private stub setups
  produce divergent, unmaintainable fixtures and a false sense of isolation.
  A stub must fail loudly on an unprogrammed destructive call (`qm destroy`,
  `qm stop`, `pvesm free`, `zfs destroy`) rather than defaulting to success.
- **Integration (`pve-test`):** full bake → canary → promote → GC cycle against a
  real Proxmox host. Prerequisite: the broken weekly rebake on `pve-test` must be
  fixed first (§17), since it is the same checksum failure §6.2 step 5 addresses.
- **Production acceptance:** the canary itself. Every promotion is gated on a
  real job completing on the real image.
- **Dry-run:** `runner gc --dry-run` and `runner bake --force --dry-run` print
  planned actions without mutating, for validating logic against production
  state safely.

## 17. Rollout

**Ordering correction.** An earlier revision listed termination robustness
first and notifications seventh, which is impossible: §10.1 requires every forced
destroy to notify. Notifications (§12) land in the first wave, and the guard
emits `lifetime.forced_destroy` and `stopped_vm.reaped` — **after releasing any
lock**, since a black-holed webhook costs up to ~33 seconds per call. The
sequence below reflects that.

1. Land notifications (§12) and termination robustness (§10) together — both
   are independent of the generation model, §10 removes the conditions that make
   GC block, and §10.1 cannot meet its own notification requirement without §12.
   The lifetime guard must scope managed VMs by `get_vm_org != unknown` (how
   `lib/stop.sh` and
   `lib/destroy.sh` already identify them) rather than by the `runner` tag,
   because tagging does not exist until step 2 — a tag-scoped guard landed here
   would match zero VMs and silently do nothing.
2. Land the generation model and adoption (§4, §8) with `install.sh`. No rebake.
   The fleet keeps running on generation 1.
3. Verify `runner status` and `runner generations` report the adopted fleet
   correctly.
4. Land generation-aware cloning and GC (§5, §9). Still manually triggered.
5. Land the canary gate (§7), configure `CANARY_REPO`, validate PAT scope.
6. Run one full manual cycle: `runner bake` → `runner canary` → `runner promote`
   → watch rollover → `runner gc`. This produces generation 2 on 2.336.0 and is
   the first real test of zero-downtime rollover.
7. Confirm Slack delivery end to end for the full event set, including the
   guard events from step 1 and the promotion events from step 5.
8. Enable the timer (§11). Fleet becomes self-maintaining.

Steps 1-6 replace the manual rebake that is currently pending, so the 30-day
compliance problem is resolved by the rollout itself rather than needing a
separate manual rebake first. If the rollout slips past the enforcement dates,
the fallback is the manual procedure documented in the README; it stays valid.

## 18. Non-goals

Explicitly out of scope, with reasons:

- **Multi-node Proxmox clusters.** Single-host `pve`. Generation VMIDs, `/run`
  locks, and `/var/lib` state are all host-local. Clustering would need a shared
  state store.
- **Automatic rollback after promotion.** Rollback exists as a manual command
  (§13). Automating it risks flapping between two generations on an unrelated
  outage — for example a GitHub incident that looks like job starvation. A human
  decides.
- **Per-org or per-workflow images.** All orgs share one generation lineage.
- **GHES support.** The 30-day enforcement calendar driving this work applies to
  github.com only.
- **Non-ZFS storage optimization.** `dir`/`lvm` remain supported via tag-based
  attribution, but full-copy clone cost and space accounting are not optimized.
- **Rewriting the platform in another language.** It stays bash + `qm`/`pvesm`,
  consistent with the existing codebase.
- **Backing up or exporting generations.** Templates are reproducible from the
  digest inputs; a failed generation is rebuilt, not restored.
- **Replacing the pool watcher or hookscript recycle loop.** The existing
  ephemeral recycle mechanism *is* the rollover mechanism. It is reused, not
  redesigned.

## 19. Completeness check

> List everything this system touches that still has no spec section.

Walked every file in the repo against this spec:

| Touched | Covered by |
|---|---|
| `lib/setup.sh` | §6 (refactored to call `lib/bake.sh`) |
| `lib/common.sh` | §4.5, §5, §7.3, §9 |
| `lib/watch.sh` | §7.4 (canary needs no change, stated explicitly), §10.4 (stopped VMs counted as filled slots) |
| `lib/reclone.sh` | §7.4 (canary skip) |
| `lib/create.sh`, `lib/list.sh`, `lib/destroy.sh` | §4.5 (unchanged via the `TEMPLATE_ID` pointer); `list` gains a generation column under §13 |
| `lib/stop.sh` | §9 (generalized from one template to all generations) |
| `lib/add-org.sh` | §7.1 (extra-labels substitution), §14 (`CANARY_PAT` scope validation) |
| `lib/remove-org.sh`, `lib/list-orgs.sh` | Unchanged — no generation coupling |
| `install.sh` | §8 (adoption on upgrade), §17 |
| `templates/runner-user-data.yaml` | §7.1 (`labels.env` hook + `--no-default-labels`), §10.2 (per-boot re-arm) |
| `templates/template-setup.yaml` | §6.2 step 9 (`/opt/.runner-version` marker) |
| `templates/runner-hookscript.sh` | §7.4 (canary skip), §10.3 (hardcoded drain path), §10.4 (stopped-VM residue) |
| `templates/github-runner-watch.{service,timer}` | Unchanged; new maintain timer in §11.1 |
| `runner` dispatcher | §13 |
| `README.md` | Documentation leaf in the issue graph |
| Log growth in `/var/log/github-runners/` | Logrotate config, filed as part of the bake pipeline leaf |
| `notes.md` | Superseded by this spec; folded in and deleted at rollout |

| `lib/start.sh` | §10.4 (reap stopped managed VMs before resuming) |

Remaining gaps: none. Every in-scope area has a section or an explicit non-goal.

**Revision note.** Sections 4.1, 4.2, 4.4, 5, 6.3, 7.1, 7.3, 7.5, 9, 10.2, 10.3,
10.4, 11.1, 12, 13, 14, 15, 17, and 20 were revised after an adversarial review
of this document against the codebase.

**Second revision**, after implementing phase 1 and reviewing all eight branches
individually plus a cross-branch integration pass: §4.3 (the reseed must consult
the archive log — "never reused" is unenforceable from surviving records alone),
§7.2 (the Playwright CLI assertion was unverifiable as written), §7.3 (the
lifetime guard is a third exclusive taker of the pool lock and must not take it
at all), §10.3 (this section authored a real defect by requiring both paths be
honored without requiring the tmpfs flag be migrated), §13 (`runner guard`),
§16 (host paths as constants; one shared harness), §17 (the ordering was
impossible — §10.1 requires notifications that landed six steps later), and the
new §21 conventions. The material changes: canary label
isolation (the original design would have had production jobs routed to the
canary), canary retry semantics and their interaction with the failed-digest
memo, pointer re-read and lock-starvation handling in promotion, promote-before-
demote ordering, a `rejected` state so rollback is not defeated by
"newest wins" heuristics, GC paths for `candidate` generations, and the
stopped-VM reaper in §10.4.

## 20. Open items requiring an operator decision at implementation time

Not blockers for the spec; they need a value, not a design:

1. Which repo hosts the canary workflow (`CANARY_REPO`) and under which org.
2. Whether the existing org PAT carries `repo` scope or a separate `CANARY_PAT`
   is minted.
3. The Slack incoming webhook URL.

## 21. Implementation conventions

Derived from reviewing the first eight branches implemented against this spec.
Each rule exists because its absence produced a real defect.

**Host paths are constants, not literals.** Every path a script touches —
locks, state files, `/etc/pve` inventory — is a constant in `lib/common.sh`.
This is what makes test isolation possible (§16) and what lets state
directories be relocated in one place.

**One state directory, one owner.** `RUNNER_STATE_DIR` (`/var/lib/github-runners`)
is the single persistent-state root, created by one shared `ensure_state_dir`
helper at mode 700. Volatile per-boot state lives in `/run` and says why in a
comment. Two components calling `install -d -m` with different modes on the same
directory silently flip-flop its permissions.

**Defaults live in code, not in the config file.** `apply_*_defaults()` at load
time, using `:-`. Do not append the ~25 keys of §14 to
`/etc/github-runners.conf` on install — it makes upgrades non-idempotent and the
wizard's config writer will drop them anyway. Validate values with a
fallback-to-default idiom and log when a configured value is rejected.

**Enforcement fails loudly or fails closed; best-effort is for notification and
cleanup only.** Master's `|| true` / `2>/dev/null` idiom is correct for
tidying up and wrong for anything gating a destroy, a promotion, or a
verification. A component whose job is to notice failures must not be able to
silently do nothing: if it cannot act, it says so at `warn` or above. Three of
the first eight branches shipped a summary line indistinguishable from healthy
while doing nothing at all.

**A comment claiming a guarantee names the test that proves it.** Six of the
first eight branches carried prose asserting "never", "always", or "cannot" for
properties the code did not have — and those comments are what the next
implementer trusts instead of re-deriving. Either cite the test, or write it as
`ASSUMPTION:`.

**Do not parallelize issues that share a file.** The `blocked-by` graph already
records which ones do; use it for scheduling, not just documentation. Five
branches edited `lib/common.sh` simultaneously and produced three competing
state-directory concepts, two config-default philosophies, and five private test
harnesses.
