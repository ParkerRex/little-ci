# Little-CI

Little-CI runs a small, persistent fleet of GitHub Actions self-hosted runners in
an isolated Ubuntu machine on an Apple Silicon Mac. OrbStack is the primary host;
a dedicated Ubuntu server such as a Hetzner VM remains supported as a secondary
deployment.

The project provisions the Linux guest, registers one or more runner services,
keeps their scratch space under control, and provides fleet-specific health and
lifecycle commands. The safe default is one runner with 2 CPUs, 4 GB memory, and
a 48 GB disk. Increase that only after measuring your jobs on the host Mac.

> [!WARNING]
> A self-hosted runner executes repository workflow code with the runner user's
> authority. Little-CI is for trusted workflows in private repositories. Do not
> route public-fork pull requests or other untrusted code to a persistent runner.
> Read [Security model](#security-model) before installing it.

## Requirements

For the recommended Mac setup:

- An Apple Silicon Mac. Intel Mac support is intentionally out of scope.
- [OrbStack](https://orbstack.dev/download) running, with `orbctl` available on
  `PATH`.
- [GitHub CLI](https://cli.github.com/) authenticated as a repository or
  organization administrator.
- Python 3 for fleet-specific GitHub API checks.
- Git and a shell capable of running Bash scripts.
- Enough free disk for the Ubuntu machine, runner workspaces, Docker images, and
  build caches.

Install the Mac-side dependencies with Homebrew, start OrbStack once, and log in:

```bash
brew install orbstack gh python
gh auth login
gh auth status
orbctl version
```

For a generic Linux host, use Ubuntu 24.04 with systemd, a non-root runner user,
`sudo`, and Docker access if workflows build or run containers.

## Quick start on a Mac

Clone Little-CI and create the local configuration:

```bash
git clone https://github.com/YOUR-ACCOUNT/Little-CI.git
cd Little-CI
cp config.env.example config.env
$EDITOR config.env
```

At minimum, choose a GitHub target and give the Mac machine a unique name:

```bash
GITHUB_SCOPE="repository"
GITHUB_URL="https://github.com/OWNER/REPO"
ORB_MACHINE="little-ci-owner-repo"
```

The defaults create one runner with the stable workflow label `little-ci` and a
target-derived, collision-resistant runner name. Then provision, install, and
verify:

```bash
./provision-orbstack.sh
./install-runners-orb.sh
./check-runners.sh
```

`install-runners-orb.sh` obtains a short-lived registration token with your
existing `gh` login when `REGTOKEN` is not already set. The token is forwarded to
the guest for the registration command and is not written to `config.env`.

The machine appears in OrbStack and the runners appear under the target's
**Settings → Actions → Runners** page.

## Choose a resource profile

One runner service accepts one job at a time. Start with one runner even on a
large Mac, observe peak memory and disk use, and then add capacity deliberately.
These profiles are starting points, not guarantees; JavaScript type checks,
linkers, browsers, databases, and Docker builds can each change the right answer.

- 8 GB Mac: one runner, 2 CPUs, 3–4 GB guest memory, 48 GB disk. Keep other
  local workloads light.
- 16 GB Mac: one runner by default, 2–4 CPUs, 4–8 GB memory, 48–80 GB disk. A
  second runner is reasonable only for consistently light jobs.
- 32 GB Mac: one or two runners, 4–6 CPUs, 10–16 GB memory, 80–120 GB disk.
- 64 GB or larger Mac: two runners are a conservative baseline; 6–10 CPUs,
  20–32 GB memory, and 120–200 GB disk leave room for heavier parallel jobs.

Set the profile with `RUNNER_COUNT`, `EXPECTED_RUNNERS`, `ORB_CPUS`,
`ORB_MEMORY`, and `ORB_DISK`. OrbStack also has a global memory limit, which may
default below the per-machine limit you request. Raise the global limit in
OrbStack settings when necessary.

Do not create swapfiles inside the OrbStack guest. OrbStack manages memory and
swap for its shared Linux VM. `provision-box.sh` detects OrbStack and skips the
physical-host swapfile setup while retaining runner scratch and cleanup policy.
On a generic Linux host, the same script can provision per-runner swapfiles. An
upgraded guest with old `/swapfileN` entries warns but preserves them by default;
inspect the warning before opting into `REMOVE_LEGACY_SWAPFILES=1`.

## Repository and organization targets

Repository scope is the default and the smallest security boundary:

```bash
GITHUB_SCOPE="repository"
GITHUB_URL="https://github.com/OWNER/REPO"
```

The corresponding GitHub API endpoint is:

```bash
gh api --method POST \
  /repos/OWNER/REPO/actions/runners/registration-token \
  --jq .token
```

Organization scope is opt-in:

```bash
GITHUB_SCOPE="organization"
GITHUB_URL="https://github.com/ORG"
RUNNER_GROUP="little-ci-approved-repositories"
```

The organization token endpoint is:

```bash
gh api --method POST \
  /orgs/ORG/actions/runners/registration-token \
  --jq .token
```

Before registering organization runners, create a dedicated runner group under
**Organization Settings → Actions → Runner groups**, allow only the repositories
that need this fleet, and set `RUNNER_GROUP` to its exact name. Little-CI rejects
`RUNNER_GROUP` for repository-scoped registration. GitHub documents the available
[runner-group access policies](https://docs.github.com/en/actions/how-tos/manage-runners/self-hosted-runners/manage-access)
and [self-hosted runner API permissions](https://docs.github.com/en/rest/actions/self-hosted-runners).

Use a different `ORB_MACHINE` for every target on a Mac. Little-CI derives a
target-specific runner prefix unless `RUNNER_NAME_PREFIX` is set explicitly.
Runner names are `<prefix>-1`, `<prefix>-2`, and so on. Each runner receives the
stable `little-ci` workflow label, its target-specific fleet label, its exact
runner-name label, and an architecture label in addition to `RUNNER_LABELS`.

## Route workflows to Little-CI

Use the stable label to route ordinary jobs:

```yaml
jobs:
  test:
    runs-on: [self-hosted, little-ci]
    steps:
      - uses: actions/checkout@v4
      - run: ./scripts/test
```

When several Little-CI fleets can serve the same GitHub target, add the
target-specific fleet label. For an organization runner group, constrain both
group and labels:

```yaml
jobs:
  test:
    runs-on:
      group: little-ci-approved-repositories
      labels: [self-hosted, little-ci, little-ci-ORG]
```

Do not use `ubuntu-24.04` in `runs-on`; that identifies GitHub-hosted runner
images, not this Ubuntu guest.

### Concurrency is runner capacity

Each online runner service runs one job at a time. A fleet with two active
services can therefore run two jobs concurrently. `RUNNER_COUNT` controls the
installed services; Little-CI does not implement a separate numeric concurrency
limit.

GitHub Actions `concurrency` groups do **not** accept a numeric job limit. A group
retains at most one running and one pending run or job for the same key, optionally
cancelling the in-progress member. Use them when serialization or superseding old
runs is the desired behavior, not to express “run N jobs.” See GitHub's
[concurrency documentation](https://docs.github.com/en/actions/concepts/workflows-and-actions/concurrency).

To reduce parallelism, reduce the installed runner count through the lifecycle
commands or stop a specific runner service. Do not register idle spares unless
you intend GitHub to schedule work on them.

## What provisioning creates

`provision-orbstack.sh` runs on macOS. It creates an Ubuntu 24.04 arm64 machine
with both OrbStack isolation modes enabled, installs base packages and Docker,
creates the runner account, copies this repository into the isolated guest, and
invokes guest provisioning. Re-runs validate an existing machine before using it
instead of treating any same-named machine as compatible.

`provision-box.sh` runs as root inside Ubuntu. It creates per-runner scratch
directories, adds systemd service drop-ins for `TMPDIR` and `TMP`, and configures
`systemd-tmpfiles` to age abandoned scratch files. On a normal Linux server it
also creates the configured swapfiles and sets low swappiness. It skips that
swapfile work in OrbStack.

`install-runners-orb.sh` runs on macOS. It copies the current checkout to the
isolated guest without relying on a Mac filesystem mount, obtains or forwards a
short-lived registration token, and invokes `install-runners.sh`. Service install
is performed through the Mac wrapper as root; the OrbStack guest does not retain
a passwordless-sudo grant for the runner user.

`install-runners.sh` runs in Linux. It downloads the pinned GitHub Actions runner,
registers the requested fleet, and installs a systemd service for each runner.

`check-runners.sh` runs wherever `gh` and Python 3 are available. It reads every
page of the repository or organization runner API and checks only this fleet's
label and exact expected names. It returns:

- `0` / GREEN: every expected fleet member is online.
- `1` / RED: a fleet member is missing or offline.
- `2` / DARK: configuration is invalid or the GitHub API could not be read.

Other lifecycle scripts are described in [Operate the fleet](#operate-the-fleet).

## Operate the fleet

### Health and diagnosis

Run the GitHub-side fleet check from the Mac:

```bash
./check-runners.sh
```

For a local view, inspect the OrbStack machine and the services inside it:

```bash
./doctor.sh
orbctl list
source config.env
orbctl run -m "$ORB_MACHINE" -u root \
  systemctl list-units 'actions.runner.*' --type=service --no-pager
orbctl logs "$ORB_MACHINE"
```

`doctor.sh` is read-only. It checks the OrbStack CLI and daemon, machine image and
isolation settings, SSH-agent forwarding, login and sleep settings, Docker access,
systemd services, and this exact fleet's GitHub registrations. Warnings do not
fail the command; any failed invariant does.

### Updates

GitHub's runner service updates itself when GitHub requires a newer release.
`RUNNER_VERSION` pins new installations; changing it does not replace an already
registered runner directory. Re-run provisioning and installation to refresh
configuration and reconcile missing runners or services:

```bash
./provision-orbstack.sh
./install-runners-orb.sh
./doctor.sh
./check-runners.sh
```

Do not update or remove a runner while it reports `busy` unless abandoning that
job is intentional. To force a clean version change, remove one exact idle runner
with `--runner`, change `RUNNER_VERSION`, re-run installation, and verify it before
moving to the next runner.

`doctor.sh` reports each installed `Runner.Listener` version and warns when it
differs from the bootstrap pin. Little-CI does not automate Ubuntu distribution
upgrades; treat guest OS upgrades as explicit administrator maintenance, then run
provision, doctor, and health checks again.

Re-run `provision-orbstack.sh` after changing compatible resource or host
configuration. Existing-machine validation fails closed when the named machine
has the wrong architecture, distro, or isolation settings; review the mismatch
rather than deleting a machine blindly.

### Removal and recovery

Every removal requires both an exact selection mode and `--confirm`:

```bash
# Remove runners above the newly lowered RUNNER_COUNT.
./uninstall-runners-orb.sh --prune --confirm

# Remove one exact fleet runner.
./uninstall-runners-orb.sh \
  --runner little-ci-OWNER-REPO-2 --confirm

# Remove this entire fleet but retain the machine.
./uninstall-runners-orb.sh --all --confirm

# Remove the fleet and then permanently delete the OrbStack machine.
./uninstall-runners-orb.sh --all --confirm --delete-machine
```

The Mac wrapper fetches a short-lived GitHub removal token, stops and unregisters
the selected local services, then deletes only matching offline stale GitHub
registrations. Before any of those mutations it queries GitHub and refuses to
interrupt a selected runner with `busy: true`. `--prune` selects numbered runners
above `RUNNER_COUNT`.
`--delete-machine` is accepted only with `--all`, and the machine is otherwise
retained. Review any `busy` runner reported by `doctor.sh` before removal.

On a generic Linux host, obtain a removal token from the matching repo/org API and
use the same selection modes:

```bash
REMOVETOKEN="$(gh api --method POST \
  /repos/OWNER/REPO/actions/runners/remove-token --jq .token)" \
  ./uninstall-runners.sh --all --confirm
```

If a machine was lost before clean unregistration, remove only the stale runners
with this fleet's names from **Settings → Actions → Runners**, then reprovision.
Never delete runners based only on a broad `self-hosted` label; other fleets can
share the same GitHub target.

## Sleep, startup, and availability

OrbStack and macOS must both be running for jobs to start. A sleeping or powered
off Mac makes the runners offline; this is expected, not a GitHub failure.

Recommended OrbStack settings:

```bash
orbctl config set app.start_at_login true
orbctl config set power.pause_in_sleep false
```

- Enable OrbStack at login. The project commands start the configured machine
  explicitly; run `doctor.sh` after login or wake before relying on the fleet.
- Keep OrbStack's `power.pause_in_sleep` setting false. This avoids an additional
  OrbStack pause, but it cannot make a sleeping Mac execute jobs.
- Configure macOS not to enter system sleep while it is acting as a runner host.
  `caffeinate` is useful for a temporary session, not durable server policy.
- After an OS or OrbStack update, start the machine and run the health/doctor
  checks before relying on it.
- Prefer an always-on desktop Mac or a real Linux server when jobs must start at
  any hour. A laptop that travels or closes its lid is not a reliable CI host.

GitHub discards self-hosted jobs that remain queued for more than 24 hours, so a
machine that will be offline longer should not be the only required merge runner.

## Security model

Little-CI reduces exposure; it does not make hostile workflow code safe.

- Use trusted workflows in private repositories. GitHub explicitly recommends
  against self-hosted runners for public repositories because a fork can open a
  pull request that runs dangerous code. Do not route fork PRs to this fleet.
- Treat every repository allowed into one runner group as the same trust domain.
  A compromised workflow can persist in workspaces, caches, tools, services, or
  Docker state and affect a later job.
- Do not use `pull_request_target` to check out and execute pull-request code on
  Little-CI. That trigger can expose base-repository secrets to attacker-controlled
  code when used incorrectly.
- Docker group membership is effectively root-equivalent inside the guest. A
  workflow can take control of the Linux guest even though the runner user does
  not retain a general passwordless-sudo grant in the OrbStack setup.
- OrbStack `--isolated` removes Mac filesystem mounts, direct host networking,
  default SSH-agent forwarding, and other Mac integrations.
  `--isolate-network` also blocks access to the host and other OrbStack machines
  while preserving internet access.
- OrbStack machines and containers share one Linux kernel. OrbStack documents
  isolated machines as risk reduction, not a full security boundary. Do not use
  this setup for malware analysis or code actively attempting a kernel escape.
- Keep GitHub registration and removal tokens in environment variables only.
  Never put `REGTOKEN`, `GH_TOKEN`, a PAT, `.runner`, `.credentials`, or runner
  `_work` state in Git. The repository's `.gitignore` excludes runner state.
- GitHub Actions secrets available to an authorized job are still available to
  that job. Minimize secret scope, environment access, and token permissions.
- Use a dedicated machine and fleet for each trust boundary. Never co-host an app
  server or production database with CI runners.

Read GitHub's [secure-use guidance](https://docs.github.com/en/actions/reference/security/secure-use)
and OrbStack's [isolated-machine security model](https://docs.orbstack.dev/machines/isolated)
before exposing the fleet to additional repositories.

## Configuration reference

`config.env` is executable shell syntax and is sourced by the scripts from the
project directory. Copy it from `config.env.example`, keep it untracked, quote
values containing special characters, and treat edits as trusted code.

GitHub target and runner settings:

- `GITHUB_SCOPE`: `repository` or `organization`; defaults to `repository`.
- `GITHUB_URL`: exact `https://github.com/OWNER/REPO` or
  `https://github.com/ORG` URL matching the selected scope.
- `RUNNER_GROUP`: optional organization runner group name; invalid with repository
  scope.
- `RUNNER_COUNT`: number of runner services to install; default and recommended
  starting value is `1`.
- `EXPECTED_RUNNERS`: health-check fleet size; normally equal to `RUNNER_COUNT`.
- `RUNNER_NAME_PREFIX`: stable, target-unique fleet and name prefix. If unset,
  Little-CI derives it from `GITHUB_URL`.
- `RUNNER_LABELS`: comma-separated additional labels. The stable `little-ci`,
  fleet, exact-name, and architecture labels are added automatically.
- `RUNNER_VERSION`: pinned `actions/runner` release.
- `RUNNER_ARCH`: guest package architecture. OrbStack is fixed to `linux-arm64`;
  generic Linux can detect `linux-arm64` or `linux-x64`.
- `RUNNER_USER`: non-root Linux account used by runner services.
- `RUNNER_HOME`: optional runner install parent inside Linux.

OrbStack settings:

- `ORB_MACHINE`: target-unique OrbStack machine name. If unset, it defaults to the
  target-derived runner prefix, such as `little-ci-OWNER-REPO`.
- `ORB_CPUS`: guest CPU limit; defaults to `2`.
- `ORB_MEMORY`: guest memory limit; defaults to `4G`.
- `ORB_DISK`: guest disk limit; defaults to `48G`.

Linux host settings:

- `SWAP_GB`: size of each per-runner swapfile on a normal Linux host; ignored in
  OrbStack.
- `SWAPPINESS`: Linux swap preference on a normal Linux host.
- `REAP_AGE`: age at which systemd-tmpfiles can remove scratch entries.
- `REMOVE_LEGACY_SWAPFILES`: `0` preserves numbered swapfiles left by an older
  release; `1` removes only entries matching Little-CI's exact legacy fstab shape
  when running inside OrbStack.

Optional Postgres settings:

- `PG_USER`, `PG_PASSWORD`, and `PG_DB`: local test role and database.
- `PG_SHARED_BUFFERS`: server buffer target; defaults to a deliberately small
  value.
- `PG_MAX_CONNECTIONS`: shared server connection ceiling.

## Optional shared Postgres

`provision-postgres.sh` installs one small native Postgres instance in the Linux
guest. `examples/ci-per-run-schema.yml` demonstrates creating a unique schema for
each matrix job, placing it first in `search_path`, and dropping it in a guarded
`if: always()` cleanup step.

```bash
source config.env
orbctl run -m "$ORB_MACHINE" -u root \
  bash -lc 'cd /home/deploy/little-ci && ./provision-postgres.sh'
```

This is a lightweight test convenience, not strong tenant isolation:

- Schemas do not isolate database-wide objects, extensions, roles, connection
  limits, or resource exhaustion.
- Applications that ignore PostgreSQL `search_path` are not isolated by the
  example.
- A forcibly terminated job can leave a schema behind despite `if: always()`;
  periodic cleanup is still prudent.
- `127.0.0.1` works for steps running directly on the runner host. Inside job or
  service containers it refers to that container, so configure explicit host
  networking instead.
- The default credentials are test-only. Keep PostgreSQL bound to loopback, do
  not expose port 5432, and never reuse production data or credentials.

For workloads requiring stronger isolation or database-level migrations, start a
dedicated disposable database per job instead.

## Optional disk hygiene

`provision-box.sh` ages abandoned scratch files. Consuming repositories can also
copy `examples/disk-hygiene.yml` into `.github/workflows/`. It uses a non-overlap
concurrency group and, only after disk crosses its threshold, prunes seven-day
Docker build cache, dangling images, and old runner diagnostics. It intentionally
does not delete containers, networks, volumes, or npm caches.

## Generic Ubuntu or Hetzner setup

OrbStack is optional when the runner is a dedicated Ubuntu server. For example,
a Hetzner CPX-class Ubuntu 24.04 host can use the guest-side scripts directly.
Size the server for the workload; an 8 GB host should start with one runner.

Install the prerequisites and create a dedicated account:

```bash
apt-get update
apt-get install -y curl ca-certificates git jq python3
curl -fsSL https://get.docker.com | sh

adduser --disabled-password --gecos "" deploy
usermod -aG sudo,docker deploy
printf 'deploy ALL=(ALL) NOPASSWD:ALL\n' \
  > /etc/sudoers.d/deploy
chmod 440 /etc/sudoers.d/deploy
```

Copy Little-CI and `config.env` to the server, then run:

```bash
sudo ./provision-box.sh
export REGTOKEN="$(gh api --method POST \
  /repos/OWNER/REPO/actions/runners/registration-token --jq .token)"
sudo -u deploy -H --preserve-env=REGTOKEN ./install-runners.sh
./check-runners.sh
```

Use the organization token endpoint shown earlier for organization scope. Unlike
OrbStack, a normal Linux host uses the architecture detected by
`install-runners.sh` and can create configured swapfiles. Lock down SSH and the
network separately; OrbStack isolation settings do not apply. The direct Linux
uninstall command cannot determine `busy` state from a removal token, so drain the
selected jobs first. Prefer the Mac wrapper for OrbStack fleets.

## Troubleshooting

`check-runners.sh` is DARK:

- Run `gh auth status` and confirm the active account is an administrator of the
  configured target.
- Confirm `GITHUB_SCOPE` and `GITHUB_URL` have matching shapes.
- For organizations, confirm the token has self-hosted runner permissions.

The OrbStack machine is rejected during provisioning:

- Read the reported mismatch. Little-CI validates same-named machines to avoid
  silently reusing a non-isolated or wrong-architecture machine.
- Choose another `ORB_MACHINE`, or correct the existing machine's configuration
  and restart it. Do not delete an unknown machine to make the error disappear.

A runner is offline after a restart:

```bash
orbctl start "$ORB_MACHINE"
orbctl run -m "$ORB_MACHINE" -u root \
  systemctl list-units 'actions.runner.*' --type=service --no-pager
./check-runners.sh
```

Jobs run out of memory:

- Reduce `RUNNER_COUNT` before increasing memory.
- Raise both the OrbStack global memory limit and `ORB_MEMORY` when the Mac has
  headroom.
- Measure the job itself; adding swap inside an OrbStack guest is not the fix.

Jobs run out of disk:

- Inspect guest filesystem, runner workspaces, and Docker usage.
- Confirm the tmpfiles cleanup timer runs and `REAP_AGE` fits your longest job.
- Copy `examples/disk-hygiene.yml` into a consuming repository only if its
  targeted cache deletion is acceptable there.

Docker fails with a permission error:

- Confirm `RUNNER_USER` belongs to the `docker` group and restart the runner
  services after changing group membership.
- Remember that this permission is root-equivalent inside the guest.

## Development

Run the repository's local checks before opening a pull request:

```bash
bash -n ./*.sh lib/*.sh tests/*.sh
./tests/run.sh
shellcheck ./*.sh lib/*.sh tests/*.sh
```

ShellCheck is optional for users but expected for contributors when installed.
See [AGENTS.md](AGENTS.md) for project boundaries and live-runner safety rules.

## Attribution and license

Little-CI is derived from
[senoff/self-hosted-ci-runner](https://github.com/senoff/self-hosted-ci-runner),
originally created by Bob Senoff with commits co-authored by Claude Opus 4.8.
Thank you to the original authors for the focused foundation.

The original Git history and MIT terms are preserved. Little-CI remains available
under the [MIT License](LICENSE); retain the license and copyright notice in copies
or substantial portions of the software.
