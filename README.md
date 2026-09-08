# self-hosted-ci-runner

Stand up a small fleet of **GitHub Actions self-hosted runners** on one Linux box,
provisioned so heavy CI jobs don't OOM the machine or fill its disk.

It's three short, idempotent scripts plus a config file:

| Script | What it does |
|---|---|
| `provision-box.sh` | Host prep: per-runner swap, low swappiness, per-runner `/scratch`, and a `/tmp`+scratch reaper. |
| `install-runners.sh` | Downloads the runner, registers N runners against your repo/org, installs them as systemd services. |
| `provision-postgres.sh` | Optional: one small native Postgres for CI to share, with per-run schema isolation. |
| `check-runners.sh` | Health check — how many runners are online vs expected. GREEN / RED / DARK. |

Everything is parameterized through `config.env` — set your repo, runner count,
swap size, and labels there. Nothing here is specific to any one project.

---

## Operating model: provision 3, run 2 concurrent

The reference box below is an **8 GB** machine. On that class of box the guidance is:

- **Provision 3 runners** — gives you throughput headroom and a warm spare if one
  wedges, and lets a workflow pin an exact runner by label (`ci-1` / `ci-2` / `ci-3`).
- **Run at most 2 jobs concurrently** — three heavy jobs at once can OOM an 8 GB box
  even with swap. Cap concurrency at 2 and the third runner stays a hot standby.

Two easy ways to enforce the 2-concurrent cap (pick one; **it's your call** — bigger
box, bump both numbers):

1. **Workflow-level** — put your CI jobs in a `concurrency` group with a limit, or
   only apply two of the three runner labels in your `runs-on` rotation.
2. **Box-level** — install 3 but only `systemctl start` two of the services, leaving
   the third stopped-but-registered as the spare.

`RUNNER_COUNT` controls how many get provisioned. The concurrency cap is a policy you
apply in your workflows — this repo doesn't force one.

---

## The box we run it on

The reference deployment is a single **Hetzner Cloud** VM. Observed configuration:

| | |
|---|---|
| Provider | Hetzner Cloud |
| Class | Shared-vCPU AMD (CPX line) — comparable to **CPX31 or larger** |
| vCPU | 4 (AMD EPYC) |
| RAM | 8 GB |
| Disk | ~75 GB SSD |
| OS | Ubuntu 24.04 LTS |
| Swap | **3 × 10 GB** (one swapfile per runner, ~30 GB) — set up by `provision-box.sh` |
| Container runtime | Docker 29.x (jobs that build/run containers) |
| Node | 22.x (only if your jobs need it) |
| Runner user | non-root `deploy`, in the `sudo` and `docker` groups |

The box runs **nothing but the runners** — no app, no database. Keep it that way; a
CI box that also serves traffic is where the OOM surprises come from.

### Setting up the box on Hetzner

1. **Create the server.** In the Hetzner Cloud console (or `hcloud`): a **CPX31**
   (4 vCPU / 8 GB / 160 GB) or larger, image **Ubuntu 24.04**, in a region near
   your team. Add your SSH key at create time.

   ```bash
   # with the hcloud CLI:
   hcloud server create --name ci-runner --type cpx31 --image ubuntu-24.04 --ssh-key YOUR_KEY
   ```

2. **Base packages + Docker.** SSH in as root and:

   ```bash
   apt-get update && apt-get install -y curl ca-certificates git jq
   # Docker (official convenience script):
   curl -fsSL https://get.docker.com | sh
   ```

3. **A non-root runner user** with sudo + docker, and passwordless sudo (svc.sh needs it):

   ```bash
   adduser --disabled-password --gecos "" deploy
   usermod -aG sudo,docker deploy
   echo 'deploy ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/deploy && chmod 440 /etc/sudoers.d/deploy
   ```

4. *(Optional)* **Node**, if your jobs run it directly on the box rather than in a container:

   ```bash
   curl -fsSL https://deb.nodesource.com/setup_22.x | bash - && apt-get install -y nodejs
   ```

Then run this repo (below).

---

## Quickstart

```bash
git clone https://github.com/OWNER/self-hosted-ci-runner.git
cd self-hosted-ci-runner
cp config.env.example config.env
$EDITOR config.env          # set GITHUB_URL, RUNNER_COUNT, RUNNER_USER, etc.

# 1. Provision the host (swap / scratch / reaper). Run as root, ON the box:
sudo ./provision-box.sh

# 2. Get a short-lived registration token (expires ~1h; needs gh auth or a PAT):
export REGTOKEN="$(gh api -X POST repos/OWNER/REPO/actions/runners/registration-token --jq .token)"

# 3. Install + register + start the runners. Run as your RUNNER_USER (e.g. deploy):
./install-runners.sh

# 3b. (Optional) if your tests need Postgres — one small shared instance:
sudo ./provision-postgres.sh

# 4. Verify (from anywhere with gh access to the repo/org):
./check-runners.sh
```

That's it — the runners show up under **Settings → Actions → Runners** and pick up
any workflow with `runs-on: [self-hosted]` (or your custom label).

---

## What the host provisioning actually sets up

`provision-box.sh` is idempotent (safe to re-run) and configures:

- **Swap — one swapfile per runner** (`/swapfile1..N`, `SWAP_GB` each), enabled and
  persisted in `/etc/fstab`. On a memory-constrained box this is the difference
  between a job that swaps briefly and a job that gets OOM-killed.
- **`vm.swappiness`** low (default 10), persisted in `/etc/sysctl.d/` — swap is
  insurance, not the default path.
- **Per-runner scratch** — `/scratch/N` with a systemd drop-in that sets `TMPDIR`/`TMP`
  for that runner's service, so runners don't fight over one shared `/tmp`.
- **A reaper** — `/etc/tmpfiles.d/runner-scratch.conf` ages `/tmp` and every
  `/scratch/N` at `REAP_AGE` (default 6h) using the stock `systemd-tmpfiles-clean.timer`.
  Dead job-workspace dirs are the usual cause of a slow creep to
  "No space left on device"; this sweeps them.

## The test database (optional): one small Postgres, per-run schemas

If your suite needs Postgres, the naive setup — one shared instance every job writes
into — means parallel runs clobber each other's data and exhaust connections. The
other extreme, a fresh Postgres container per job, is heavier and slower than it needs
to be.

What's here instead:

- **`provision-postgres.sh`** installs **one small native Postgres** on the box
  (default `shared_buffers=128MB` — deliberately tiny) with a role that owns a single
  database. All runners share it.
- **Each run gets its own schema.** `examples/ci-per-run-schema.yml` shows the pattern:
  a run creates `run_<id>_<attempt>`, points `search_path` at it via `DATABASE_URL`,
  and drops it in an `if: always()` cleanup step so a crashed run can't leave schemas
  piling up. Because the role owns the database, `CREATE SCHEMA` needs no extra grants,
  and per-run schemas make concurrent runs safe without a container per job.

Tune it in `config.env` (`PG_USER`, `PG_DB`, `PG_SHARED_BUFFERS`, `PG_MAX_CONNECTIONS`).
Keep it small: on a constrained box, a lean shared instance beats N heavy ones.

## Configuration

All knobs live in `config.env` (copied from `config.env.example`). Key ones:

- `GITHUB_URL` — repo or org URL the runners register against.
- `RUNNER_COUNT` — how many runners (and how many swapfiles / scratch dirs).
- `RUNNER_NAME_PREFIX` / `RUNNER_LABELS` — naming + labels; each runner also gets a
  unique `<prefix>-<n>` label so a workflow can target one exact runner.
- `RUNNER_USER` — the account the services run as (needs passwordless sudo + docker group).
- `SWAP_GB`, `SWAPPINESS`, `REAP_AGE` — host tuning.
- `RUNNER_VERSION` — pin the actions/runner release.

## Optional: scheduled disk hygiene

`provision-box.sh`'s reaper handles workspace silt. If your jobs also pile up Docker
build cache or package caches, `examples/disk-hygiene.yml` is a drop-in scheduled
workflow that reclaims those when a runner's disk crosses a threshold. Copy it into
your repo's `.github/workflows/`.

## Security notes

- **`REGTOKEN` is a short-lived registration token (~1h), never a PAT.** It's passed
  as an environment variable at install time and never written to disk by these
  scripts. Don't commit it, don't paste it into `config.env`.
- **Never commit a registered runner's `.runner` / `.credentials` files.** They hold
  the runner's live auth. `.gitignore` already excludes them, the runner tarball, and
  `_work` / `_diag`.
- Give the runner user only what it needs; keep the box single-purpose.
- **The Postgres `PG_PASSWORD` is a local-only CI credential**, not a secret to guard —
  but only because the box keeps Postgres bound to `localhost` and never exposes `5432`.
  Keep it that way; a self-hosted CI DB should not be reachable from the internet.

## License

MIT — see [LICENSE](LICENSE). Use it, fork it, adapt it.
