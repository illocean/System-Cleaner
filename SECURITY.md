# Security

## Summary

`System Cleaner` is a local Windows cleanup script that runs with administrator approval and deletes targeted cache and temporary data. It is designed to be inspectable, conservative by default, and usable in `Preview` mode before any deletion happens.

## Intended Safety Properties

- Excludes `Downloads` by default
- Supports additional protected paths through `-ExtraExcludePath`
- Limits cleanup to known cache, temp, crash, update, and shell-cache locations
- Keeps logs visible in the terminal after each run
- Uses built-in Windows commands for elevated system tasks
- Makes aggressive actions optional instead of default

## Non-Goals

The project is not intended to:

- Securely wipe files for forensic resistance
- Replace antivirus or endpoint security tooling
- Optimize registry state
- Manage startup entries or scheduled tasks
- Clean arbitrary user-selected folders recursively

## Elevated Operations

Administrator rights are required because the script can access system-owned cleanup targets such as:

- Windows temp folders
- Windows Update download cache
- Recycle Bin cleanup across protected locations
- Optional component-store cleanup
- Optional event-log clearing

The script requests elevation through the standard Windows UAC prompt.

## External Effects

The script does not include built-in telemetry or outbound API calls. It operates locally on the machine and uses native Windows commands such as:

- `Dism.exe`
- `wevtutil.exe`
- PowerShell service-control cmdlets
- PowerShell file-system cmdlets

## Risk Areas

Even conservative cleanup has tradeoffs:

- Clearing caches can remove offline cache data that an application later rebuilds.
- Some applications may need to recreate thumbnails, indexes, or temporary working files on next launch.
- Aggressive mode can make log-based troubleshooting harder because it clears event logs.
- If a third-party application stores important data inside folders named like cache or temp under standard cache roots, stale-folder cleanup can remove it.

## Recommended Safe Usage

1. Read `SystemCleaner.ps1`.
2. Run `Preview` mode first.
3. Review the printed actions.
4. Add any custom protected paths with `-ExtraExcludePath`.
5. Use `Standard` mode before considering `Aggressive`.

## Reporting Concerns

If you find a path that should not be cleaned by default, treat that as a bug in cleanup scope and tighten the exclusion or target rules before distributing the script further.
