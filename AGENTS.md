# AGENTS.md

## Project purpose

Little-CI provisions persistent GitHub Actions self-hosted runners. The primary
deployment is an isolated Ubuntu 24.04 arm64 machine on an Apple Silicon Mac with
OrbStack. Generic Ubuntu arm64/x64 hosts, including Hetzner, are secondary.
Intel Mac support is intentionally out of scope.

Keep changes small, explicit, and safe around live runners. Prefer the existing
Bash and Python standard-library toolchain. Do not add dependencies without a
clear requirement.

## Architecture and execution boundaries

Mac-side orchestration:

- `provision-orbstack.sh` owns OrbStack machine creation, compatibility checks,
  guest bootstrap, and invoking guest provisioning.
- `install-runners-orb.sh` owns copying this checkout into the isolated guest,
  obtaining or forwarding the registration token, and invoking runner install.
- `doctor.sh` is read-only Mac-side diagnosis across OrbStack, the guest, and the
  configured GitHub fleet.
- `uninstall-runners-orb.sh` owns confirmed Mac-side selection, removal-token
  forwarding, stale-registration cleanup, and optional machine deletion.

Linux guest or server operations:

- `provision-box.sh` owns physical-host swap policy, runner scratch directories,
  tmpfiles cleanup, and systemd drop-ins.
- `install-runners.sh` owns runner download, registration, directories, and
  systemd service installation.
- `provision-postgres.sh` owns only the optional local CI database.
- `uninstall-runners.sh` owns only explicitly selected runners matching the
  configured fleet prefix, GitHub target, and install root.

Shared/read-only operations:

- `check-runners.sh` reads GitHub's repository or organization runner API and
  evaluates only the configured fleet.
- `config.env.example` is the canonical public configuration contract.
- `examples/` contains opt-in consuming-project workflows, not workflows that
  operate this repository automatically.

OrbStack machines are created without Mac filesystem mounts. Do not introduce a
dependency on `/mnt/mac`, forwarded SSH agents, Mac command bridging, or shared
host paths. Transfer the minimum required files explicitly.

## Configuration contract

Every script resolves its own directory and sources `config.env` from there.
Keep that behavior consistent; invocation from another working directory must not
change which configuration is loaded.

`config.env` is trusted shell code, not a dotenv parser. Validate all external
values immediately after sourcing and before any mutation. Fail with a specific
message on unsupported scope, malformed GitHub URL, invalid count, invalid
architecture, or incompatible runner-group use. Do not mask bad configuration
with fallback behavior.

When adding or changing a setting:

- Update `config.env.example` and its comment.
- Update the README configuration reference and affected commands.
- Add focused tests for defaults, valid variants, and invalid boundaries.
- Preserve repository and organization behavior unless the change deliberately
  narrows scope.

The OrbStack path is arm64-only. Generic Linux may support `linux-arm64` and
`linux-x64`; do not generalize that into Intel Mac support.

## Naming

Use domain-specific names. Avoid placeholders such as `data`, `handler`, `temp`,
`helper`, `misc`, `utils2`, `thing`, or `stuff`.

- Shell variables local to a function: lowercase and descriptive.
- Exported/configuration variables: uppercase snake case.
- Functions: lowercase snake case beginning with a clear verb.
- Scripts: lowercase kebab case describing the operation and target.
- Runner fleets: stable, target-unique `RUNNER_NAME_PREFIX`.
- Runner instances: `<prefix>-<number>`.
- OrbStack machines: stable, target-unique `ORB_MACHINE`; do not assume `ci` is
  globally available.

Centralize parsing and validation when multiple scripts must produce the exact
same GitHub scope, slug, API path, fleet prefix, or service identity. Do not allow
slightly different copies of target logic to drift.

## Secrets and runner state

- Registration and removal tokens are short-lived environment values. Never write
  them to `config.env`, command logs, archives, or disk-backed temporary files.
- Forward only the named token for the one guest command that needs it. Disable
  shell tracing before handling credentials.
- Never print `REGTOKEN`, `GH_TOKEN`, PATs, or broad environment dumps.
- Never commit `.runner`, `.credentials`, `.credentials_rsaparams`, `_work`,
  `_diag`, a runner distribution, or an archive containing them.
- Treat a registered runner directory as live credentials, not ordinary build
  output.
- `PG_PASSWORD` is test-only and PostgreSQL must remain bound to loopback. Do not
  describe a local default password as safe if the port becomes reachable.

## Live-machine safety

Before mutating an existing OrbStack machine, inspect and validate the exact
configured name, architecture, distribution/version, isolation, network
isolation, resource settings, and runner ownership. Fail closed on a mismatch.

- Never delete or recreate a same-named machine automatically.
- Never unregister, stop, or remove all self-hosted runners broadly.
- Match the configured prefix, exact expected names, and fleet label.
- Check `busy` state before update, restart, removal, or downscaling. Fail unless
  the operator explicitly chose a force path.
- Unregister a runner from the correct repository or organization before removing
  its local credential directory.
- Make machine deletion a separate explicit choice after fleet uninstall.
- Preserve unrelated services, runners, files, images, and machines.
- Use exact paths and validated names for destructive commands. Avoid globs when
  deleting live state.
- If cleanup fails halfway, report the remaining GitHub registrations, services,
  directories, and an exact recovery command. Do not hide partial failure.

Provision and install operations should remain idempotent. A re-run may reconcile
known state, but it must not silently adopt incompatible or ambiguously owned
state.

## Security invariants

- Default to repository scope. Organization scope must be explicit.
- Reject `RUNNER_GROUP` outside organization scope and document restricted group
  access for organization fleets.
- Keep both OrbStack `--isolated` and `--isolate-network` enabled.
- Do not add Mac mounts, host access, SSH-agent forwarding, or inbound services to
  make a workflow convenient.
- Do not imply OrbStack is a separate-kernel security boundary.
- Do not present persistent runners as safe for public-fork or otherwise untrusted
  workflows.
- Runner Docker access is root-equivalent inside the guest. Do not restore a
  permanent passwordless-sudo grant to the OrbStack runner user.
- Health and lifecycle checks must be fleet-specific so unrelated online runners
  cannot create a false green result.

## Code style

Use `set -euo pipefail` in mutating scripts. A read-only diagnostic may
deliberately omit `-e` to aggregate independent failures, but must still return
nonzero when required invariants fail. Quote expansions. Prefer early validation
and shallow control flow. Keep external I/O, parsing, and mutations in focused
functions. Represent GitHub scope explicitly instead of inferring behavior from
loosely related flags after validation.

Use `mktemp` for archives and add a trap immediately so interruption cannot leave
credentials or large files behind. Prefer streaming across the OrbStack boundary.
Do not swallow failures from registration, unregistration, service management, or
state validation. A read-only diagnostic may report multiple failures, but must
return nonzero when the fleet is unhealthy.

## Tests

Run before commit:

```bash
bash -n ./*.sh lib/*.sh tests/*.sh
./tests/run.sh
```

Also run ShellCheck when available:

```bash
shellcheck ./*.sh lib/*.sh tests/*.sh
```

Tests must not require a live OrbStack machine, GitHub token, or runner
registration. Mock commands at the process boundary and cover:

- repository and organization API routing;
- URL and scope validation;
- target-derived default names and explicit names;
- arm64 OrbStack enforcement;
- existing-machine compatibility rejection;
- OrbStack swap skipping and normal-Linux swap behavior;
- fleet-specific pagination and missing/offline/busy states;
- install, self-update/reconcile, unregister, and partial-failure recovery paths;
- secret non-disclosure.

Live smoke tests are supplemental and require an explicit target. Never point a
test at an arbitrary machine or GitHub organization discovered from local state.

## Documentation

README commands must be copyable and reflect current option names, defaults, exit
codes, paths, and platform boundaries. When behavior changes, update README and
`config.env.example` in the same change. Keep the security model, repo/org setup,
resource guidance, sleep/startup behavior, lifecycle recovery, and original
project attribution accurate.

Preserve the MIT license and credit
`senoff/self-hosted-ci-runner`, Bob Senoff, and commit co-author Claude Opus 4.8.
