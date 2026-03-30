# Security

## Summary

`System Cleaner` is a local Windows cleanup script that runs with administrator approval and deletes a scoped set of cache and temporary data. It is designed to be readable, auditable, conservative by default, and safer to inspect in `Preview` mode before any deletion takes place.

## Security Model

The project assumes:

- The operator can read the script before executing it.
- The operator can decide whether to approve Windows UAC elevation.
- Cleanup should remain local to the machine and avoid external communication.
- Destructive actions should be limited to known disposable paths.

This tool is not a sandbox, anti-malware product, secure-erase utility, or endpoint-control framework.

## How It Works From A Security Perspective

At runtime, the script follows a constrained flow:

1. It resolves cleanup roots and protected exclusions.
2. It requests elevation through the standard Windows UAC mechanism if required.
3. It performs only the cleanup steps associated with the chosen mode.
4. It prints live logs so the operator can review exactly what was attempted.
5. It prints a final summary with disk-space impact and processed counts.

This is important because the tool runs elevated. The safest operating pattern is to review the script, run `Preview`, inspect the output, and only then run a destructive mode.

## Default Trust Boundaries

The script is intentionally scoped away from common user-content locations. By default, it does not target:

- `Downloads`
- Documents, Desktop, Pictures, Music, or Videos
- Arbitrary user-selected directories outside the approved cleanup roots
- Registry keys
- Startup entries
- Scheduled tasks
- Installed applications
- Credentials, password stores, or browser profiles as whole directories

Additional protected paths can be added with `-ExtraExcludePath`.

## Elevated Operations

Administrator rights are required because some cleanup targets are system-owned. Elevated actions may include:

- Cleaning Windows temp directories
- Cleaning the Windows Update download cache
- Clearing the Recycle Bin in protected locations
- Stopping and restarting update-related services when needed
- Running `Dism.exe` in `Aggressive` mode
- Clearing Windows event logs in `Aggressive` mode

The script uses the standard UAC prompt for elevation. It does not implement a custom privilege-escalation mechanism.

## Local-Only Behavior

The script is intended to remain local to the machine. It does not include built-in behavior for:

- Telemetry
- Cloud sync
- Web API calls
- Remote command execution
- Downloading payloads

Its core operations are limited to PowerShell file-system cmdlets, service-control cmdlets, `Dism.exe`, and `wevtutil.exe`.

## Risk Areas

Even conservative cleanup has real tradeoffs:

- Cache directories can contain useful offline data that will need to be rebuilt.
- Thumbnail, icon, and shader caches will be regenerated after cleanup.
- Some applications may lose transient state, thumbnails, or local cache indexes.
- `Aggressive` mode clears event logs, which can reduce available troubleshooting history.
- A third-party application that stores important data inside misleadingly named cache or temp folders under approved roots may still be affected.

These are operational risks, not hidden behavior. They are the reason `Preview` mode exists.

## Recommended Safe Usage

1. Review `SystemCleaner.ps1`.
2. Run `Preview` mode first.
3. Check the printed actions against your environment.
4. Add extra protected paths with `-ExtraExcludePath` where needed.
5. Prefer `Standard` mode unless you explicitly need the aggressive maintenance steps.

## What To Review Before Distribution

If you plan to distribute or publish the script:

- Re-check the default exclusion list.
- Re-check every hardcoded cleanup target.
- Confirm the stale-folder logic only covers acceptable roots and names.
- Confirm the aggressive mode description matches the actual behavior.
- Test `Preview` mode on representative machines before recommending destructive execution.

## Reporting Concerns

If you discover a path that should not be cleaned by default, treat it as a scope bug. Tighten the exclusions or cleanup rules before further distribution.
