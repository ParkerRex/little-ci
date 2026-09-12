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
  root-owned fleet identity creation, guest bootstrap, and invoking guest
  provisioning.
- `install-runners-orb.sh` owns copying this checkout into the isolated guest,
  verifying machine identity, obtaining or forwarding the registration token,
  invoking runner registration, and root-side service setup.
- `doctor.sh` is read-only Mac-side diagnosis across OrbStack, the guest, and the
  configured GitHub fleet.
- `uninstall-runners-orb.sh` owns confirmed Mac-side selection, removal-token
  forwarding, stale-registration cleanup, and optional machine deletion.

Linux guest or server operations:

- `provision-box.sh` owns physical-host swap policy and its ownership manifest,
  fleet/runner scratch directories, and fleet-specific tmpfiles cleanup.
- `install-runners.sh` owns runner download, registration, directories, and
  systemd service installation. The generated `.service` file is authoritative;
  the installer validates that unit before writing its scratch drop-in.
- `provision-postgres.sh` owns only the optional local CI database.
- `uninstall-runners.sh` owns only explicitly selected runners matching the
  configured fleet prefix, GitHub target, and install root.

Shared/read-only operations:

- `check-runners.sh` reads GitHub's repository or organization runner API and
  evaluates only the configured fleet.
- `lib/github-target.sh` is the single source of truth for GitHub scope, target,
  fleet identity, API path, and derived runner prefix.
- `lib/orbstack-machine.sh` is the single source of truth for OrbStack JSON
  validation and protected machine identity.
- `config.env.example` is the canonical public configuration contract.
- `examples/` contains opt-in consuming-project workflows, not workflows that
  operate this repository automatically.

OrbStack machines are created without Mac filesystem mounts. Do not introduce a
dependency on `/mnt/mac`, forwarded SSH agents, Mac command bridging, or shared
host paths. Transfer the minimum required files explicitly.

Mac wrappers must build guest archives from an explicit runtime-file allowlist.
Never archive `.` or copy arbitrary untracked files, docs, tests, examples,
`.git`, runner state, or credentials. Include `config.env` only as the optional
validated local configuration file; registration/removal tokens use the narrow
environment bridge instead.

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

`FLEET_ID` is required when `RUNNER_NAME_PREFIX` is unset. It must be lowercase,
stable, and unique to one fleet on the host. The normal prefix and machine name
are `little-ci-<lowercase-target>-<fleet-id>`. Treat an explicit
`RUNNER_NAME_PREFIX` as an advanced compatibility override. Organization scope
requires a nonblank `RUNNER_GROUP`; repository scope rejects it.

Reject `RUNNER_USER=root`. Validate every GitHub label at the boundary: each
configured label, fleet-prefix label, and exact runner-name label is limited to
256 characters.

Keep GitHub permission documentation exact: repository health reads require
Administration read and mutations require Administration write; organization
health reads require Self-hosted runners read and mutations require Self-hosted
runners write. Classic tokens use `repo` for repositories or `admin:org` for
organizations, with `repo` additionally required for private repositories.

## Naming

Use domain-specific names. Avoid placeholders such as `data`, `handler`, `temp`,
`helper`, `misc`, `utils2`, `thing`, or `stuff`.

- Shell variables local to a function: lowercase and descriptive.
- Exported/configuration variables: uppercase snake case.
- Functions: lowercase snake case beginning with a clear verb.
- Scripts: lowercase kebab case describing the operation and target.
- Runner fleet input: stable lowercase `FLEET_ID`.
- Runner fleets: derived, target-and-fleet-unique `RUNNER_NAME_PREFIX`.
- Runner instances: `<prefix>-<number>`.
- OrbStack machines: derived `ORB_MACHINE` by default; an explicit value must
  remain stable and target/fleet-unique.

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
isolation, empty mount list, disabled SSH-agent forwarding, default user,
resource settings when provisioning, and runner ownership. Fail closed on a
mismatch or unreadable OrbStack JSON. OrbStack 2.2.3 is the tested minimum.
OrbStack 2.2.3 omits an empty mounts field from JSON. Treat a successful, empty
`orbctl config get machine.<name>.mounts` as the sole authoritative mount check;
an unreadable or nonempty result is a failure.
Teardown intentionally skips resource-size matching so drift cannot block safe
unregistration, cleanup, or deletion, but still requires every security and
identity check.

Every managed machine has `/etc/little-ci/identity`: root-owned mode `0600`
inside a root-owned mode `0700` directory. Its machine, scope, target, prefix,
user, and runner-home values must match before install, uninstall, or deletion.
Never add an automatic adoption or identity-rewrite path for an existing machine.

- Never delete or recreate a same-named machine automatically.
- Never unregister, stop, or remove all self-hosted runners broadly.
- Match the configured prefix, exact expected names, and fleet label.
- Check `busy` state before update, restart, removal, or downscaling. Fail rather
  than interrupting a job; do not introduce an implicit force path.
- Unregister a runner from the correct repository or organization before removing
  its local credential directory.
- Make machine deletion a separate explicit choice after fleet uninstall.
- Preserve unrelated services, runners, files, images, and machines.
- Use `.runner` for registration ownership and `.service` for the authoritative
  systemd unit. Validate the unit's executable, user, and working directory.
- Remove only selected runner resources: its exact service drop-in,
  `/scratch/<prefix>/<number>`, tmpfiles entry, and manifest-owned generic-Linux
  `/swapfile-<prefix>-<number>`. Never infer swapfile ownership from its filename
  alone.
- Use exact paths and validated names for destructive commands. Avoid globs when
  deleting live state.
- If cleanup fails halfway, report the remaining GitHub registrations, services,
  directories, and an exact recovery command. Do not hide partial failure.

Preserve recoverable teardown order: validate runner/service/resource ownership;
atomically create the protected pending-cleanup record; uninstall the exact
service; unregister through GitHub; remove the owned drop-in,
scratch/tmpfiles/manifest-owned swap state and runner directory; then remove the
record last. The root-owned `0700` directory and regular `0600` record bind the
runner number, name, directory, target, and service under
`/var/lib/little-ci/fleets/<prefix>/pending-cleanup/<number>`.

Record creation failure permits no mutation. Retain and validate the record on
unregister/cleanup interruption so a retry can safely continue after `.runner`
is gone. Reject malformed, symlinked, misowned, or mismatched records. Any failed
remote list/delete must prevent machine deletion.

Provision and install operations should remain idempotent. A re-run may reconcile
known state, but it must not silently adopt incompatible or ambiguously owned
state.

Existing registrations are retained without `--replace`. A re-run may restore
their exact local service/drop-in, but it must not claim to reconcile server-side
labels or runner-group membership. Label/group changes require doctor, exact idle
uninstall, reinstall, and verification. Preserve the `needrestart` override that
prevents package maintenance from interrupting `actions.runner.*` services.

Never overwrite a missing or changed owned drop-in for an active service. Fail
with drain/stop/installer-rerun guidance. An unchanged active drop-in is valid;
an inactive service may receive the desired drop-in before it starts.

## Security invariants

- Default to repository scope. Organization scope must be explicit.
- Require `RUNNER_GROUP` for organization scope, reject it for repository scope,
  and document restricted repository access for organization fleets.
- Keep both OrbStack `--isolated` and `--isolate-network` enabled.
- Do not add Mac mounts, host access, SSH-agent forwarding, or inbound services to
  make a workflow convenient.
- Do not imply OrbStack is a separate-kernel security boundary.
- Do not present persistent runners as safe for public-fork or otherwise untrusted
  workflows.
- Runner Docker access is root-equivalent inside the guest. Do not restore a
  permanent passwordless-sudo grant to the OrbStack runner user.
- The configured runner account itself must never be `root`.
- Health and lifecycle checks must be fleet-specific so unrelated online runners
  cannot create a false green result.
- Always verify the stable `little-ci` label as well as configured,
  fleet-prefix, exact-name, and architecture labels.

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
- protected machine identity and no-mount/no-SSH-forward checks;
- OrbStack swap skipping and normal-Linux swap behavior;
- fleet-specific scratch, authoritative service drop-ins, and selected cleanup;
- protected pending-cleanup creation, retry, and malformed-state rejection;
- fleet-specific pagination and missing/offline/busy states;
- no-replace install, label/group drift, automatic self-update, unregister, and
  partial-failure recovery paths;
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
