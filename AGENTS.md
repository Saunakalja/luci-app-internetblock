# Working agreements

## Planning and implementation permission

- Plan and discuss by default. Reading source, inspecting the environment and
  other read-only checks are allowed for planning.
- Modify files, settings or external systems only when the user explicitly
  requests implementation. A question, suggestion or status update does not
  authorize changes.
- Keep each authorization within its scope. A request to edit documentation
  authorizes those documentation changes, not application implementation or
  router deployment.
- This project uses ordinary, explicit requests. No custom workflow commands,
  task/report/patch-file process or separate approval ceremony is required.
- Once a task is authorized, make routine implementation decisions and complete
  the necessary work within scope. Do not ask again for permission already given.
- Stop for missing credentials/permissions or a decision that could interrupt
  router LAN/WAN connectivity. Explain the concrete issue before asking.

## Coding principles

- **KISS:** Use the simplest readable solution that meets all requirements.
- **YAGNI:** Implement the current v1 requirements, without speculative features
  or future extension layers.
- **Small changes:** Keep diffs focused on the requested task. Avoid unrelated
  refactoring, dependency changes or formatting churn.
- **Useful abstractions:** Reuse established OpenWrt/LuCI patterns. Add helpers
  or layers only when they clarify the current implementation.
- **Real validation:** Validate actual trust boundaries and known failure cases.
  Avoid guessed fallbacks, redundant defensive layers and silent failures.
- **Preserve behavior:** Keep existing interfaces, user edits and unrelated
  configuration intact unless the task explicitly requires a change.
- Never simplify away correctness, security, necessary error handling or
  relevant regression tests. Prefer maintainable code over cleverness.

Inspect the current files and Git status before editing. Preserve uncommitted
user changes. Treat any enclosing project's read-only reference directories,
including `sources/`, as reference material only. Search for relevant sections
of large files rather than repeatedly reading entire documents.

## V1 scope

- Initial target: upstream OpenWrt 25.12.5, apk, fw4/nftables and a directly
  connected IPv4 LAN. Prefer an architecture-independent package and few
  dependencies.
- Provide a native LuCI page at **Network -> Internet Access**, with a device
  list and one allow/block control per device. Support light and dark themes.
- Merge static DHCP hosts, DHCP leases, LAN neighbors, Wi-Fi stations and a
  persistent seen-device list. Keep static reservations and known offline
  devices visible. Do not treat a lease alone as proof of online status.
- Store only the device identity information needed for discovery and saved
  block decisions. Batch changed discovery data to reduce flash writes.
- Do not add traffic analytics, rate limiting, QoS, DPI, Telegram, schedules or
  other features outside the agreed v1.

## Router and firewall boundaries

- Block only IPv4 LAN-to-WAN forwarding, primarily by client source MAC.
  Preserve communication between LAN devices and the router's DHCP, DNS, LuCI
  and other local services.
- Do not implement IPv6 support in v1 or change the router's IPv6 settings.
- Reject router identities and inappropriate network/broadcast targets. Never
  create an uncertain MAC rule for a missing or invalid MAC address.
- Give the application's sets, chains, rules and runtime components clear
  ownership names. Change or remove only components the application owns.
  Cleanup of another package's remnants requires explicit authorization.
- Account for established connections and flow offloading. Do not silently
  change global offload settings or clear unrelated clients' connections.
- Apply rule changes atomically where appropriate, verify the resulting state
  and report failures clearly. Unblocking must remove the application's actual
  restriction. Reboot and firewall reload must restore saved decisions.
- Before an authorized router installation or modification, back up the
  relevant UCI configuration and firewall state outside version control.
- Before a firewall reload, account for unrelated runtime rules that a reload
  could discard. Do not use a full ruleset flush for cleanup or recovery.
- Do not change unrelated router settings. Reboot only when actually needed.
- If SSH authentication fails, stop and ask the user to add an SSH key.
  Do not request, store or embed a router password.

## Validation and documentation

- Test device merging/deduplication, static/dynamic/offline devices, target
  validation, block/unblock generation, LAN/router exclusions, persistence and
  uninstall cleanup. Include meaningful failure-path tests.
- Run checks appropriate to each change and `git diff --check`. Documentation
  edits do not require implementation-mirroring tests.
- Use an isolated test environment for rule validation before live deployment.
  Live client tests must verify both blocked internet access and working LAN
  access; traffic originating on the router is not sufficient evidence.
- Uninstall must clean up owned runtime/firewall components without removing
  unrelated configuration. Document the treatment of saved application data.
- Keep README instructions consistent with the implementation and verified
  results. Distinguish planned behavior from tested support. Document install,
  removal, device discovery, storage and precise manual recovery before release.

## Git and public repository

- Use focused commits during authorized implementation. Follow the user's
  publication instructions; an authorization for one change does not authorize
  publishing unrelated work or private material.
- Preserve user work. Do not use destructive Git cleanup, history rewriting or
  force pushes without explicit authorization.
- Never publish router backups, real device inventories, private keys, passwords
  or tokens. Use fictional examples in public documentation.
- Check licensing and required attribution before reusing third-party code.
