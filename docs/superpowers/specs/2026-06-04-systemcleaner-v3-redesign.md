# Bakunawa v3 — Devour Your Digital Waste

> **Bakunawa** (bah-kah-NAH-wah) — the Philippine moon-eating serpent of myth.
> This tool devours what you don't need: temp files, caches, logs, and digital debris.

## Overview

Bakunawa v3 is a full architectural overhaul of the existing SystemCleaner v2 utility. The v2 script (1,751 lines in a single file) is rebranded and rebuilt as a 5-module system with config-driven app definitions, a modern VT100-capable terminal UI, parallel execution, and production-grade error handling.

**All existing features are retained:** Standard, Aggressive, Preview, and Menu modes; orphan folder detection with risk scoring; system health dashboard; Recycle Bin, DISM, event log, prefetch, and font cache cleanup; safety skips for running processes; extra exclusion paths; C# accelerator for fast directory sizing.

**The user experience is identical:** launch is `.\Bakunawa.ps1`, the menu is the primary interface, and all option numbers (1-5, Q) remain the same.

---

## Identity & Rebranding

| v2 | v3 |
|----|-----|
| Name: SystemCleaner | **Bakunawa** |
| Tagline: *(none)* | **Devour Your Digital Waste** |
| Window title: `System Cleaner v2` | `Bakunawa v3` |
| Logo: ASCII block letters "SYSTEM CLEANER" | ASCII serpent-inspired header with moon motif |
| File: `SystemCleaner.ps1` | `Bakunawa.ps1` (entry point) |
| Modules: *(none)* | `Bakunawa.Core.psm1`, `.Cleanup.psm1`, `.UI.psm1`, `.Config.psm1` |
| Tests: `SystemCleaner.Formatting.Tests.ps1` | `Bakunawa.Core.Tests.ps1`, `.Cleanup.Tests.ps1`, `.UI.Tests.ps1`, `.Config.Tests.ps1` |
| Config: CLI args only | `app-definitions/*.json` + optional `Bakunawa.json` |

---

## Module Architecture

```
Bakunawa v3/
├── Bakunawa.ps1                    # Entry point (~50 lines)
├── Bakunawa.Core.psm1              # Engine (~200 lines)
├── Bakunawa.Cleanup.psm1           # Task registry + steps (~600 lines)
├── Bakunawa.UI.psm1                # Terminal rendering (~250 lines)
├── Bakunawa.Config.psm1            # Config I/O (~150 lines)
├── Bakunawa.json                   # User configuration (optional)
├── app-definitions/                # Data-driven app cleanup specs
│   ├── browsers.json
│   ├── messaging.json
│   ├── devtools.json
│   └── system.json
└── tests/
    ├── Bakunawa.Core.Tests.ps1
    ├── Bakunawa.Cleanup.Tests.ps1
    ├── Bakunawa.UI.Tests.ps1
    └── Bakunawa.Config.Tests.ps1
```

### Module Responsibilities

| Module | Responsibility |
|--------|---------------|
| **Bakunawa.ps1** | Param block (`-Mode`, `-ExtraExcludePath`, `-NoPause`, `-SkipBootstrap`, `-LogFile`), admin elevation, mode dispatch. Thin orchestrator only. |
| **Core** | `FastSys` C# accelerator, `Get-DirectorySize`, `Format-FileSize`, `New-TrackedSet`, `Test-IsAdministrator`, `Test-SafeCleanupTarget`, `Get-FreeSpaceInfo`, `Get-HealthScore`, `Get-OrphanRiskScore`, path resolution, exclusion checking, tracked state variables. |
| **Cleanup** | Task registry (`Get-CleanupTasks`), all step functions migrated from v2 but parameterized by config rather than hardcoded paths. Orphan detection, log sweep, empty directory removal, DISM, event logs, font cache. |
| **UI** | `Show-Header`, `Show-Menu`, `Write-Panel`, `Write-Log`, `Start-Step`/`Finish-Step`, VT100 terminal sequences, live progress dashboard, graceful ASCII fallback for legacy consoles. |
| **Config** | `Read-Config`, `Save-Config`, `Merge-Defaults`, `Resolve-AppDefinitions`, environment-variable path template expansion (`%APPDATA%/discord/Cache` → real path). |

### State Variables

All script-scoped state (`$script:IsPreview`, `$script:BytesFreed`, `$script:CategorySizes`, etc.) lives in the **Core** module. Modules are imported with `-Scope Global` so script-scoped variables are shared across the module graph.

---

## Config-Driven App Definitions

### Rationale

v2 hardcodes all app cache paths in `Clear-AppCaches` (~150 lines, ~20+ apps). Adding a new app requires editing the PowerShell file. v3 externalizes app definitions to JSON files.

### Format

```json
[
  {
    "name": "Discord",
    "process": "discord",
    "locations": [
      { "env": "APPDATA", "path": "discord/Cache" },
      { "env": "APPDATA", "path": "discord/Code Cache" },
      { "env": "APPDATA", "path": "discord/GPUCache" },
      { "env": "APPDATA", "path": "discord/blob_storage" }
    ]
  },
  {
    "name": "Slack",
    "process": "slack",
    "locations": [
      { "env": "APPDATA", "path": "Slack/Cache" },
      { "env": "APPDATA", "path": "Slack/Code Cache" },
      { "env": "LOCALAPPDATA", "path": "Slack/logs" }
    ]
  }
]
```

### Resolution

The Config module resolves each entry at startup:
1. Look up environment variable (e.g. `APPDATA` → `C:\Users\...\AppData\Roaming`)
2. Resolve full path: `C:\Users\...\AppData\Roaming\discord\Cache`
3. Check if process name is running (for safety skip)
4. Pass resolved paths to Cleanup module for processing

### Categories

| File | Apps |
|------|------|
| `browsers.json` | Chrome, Edge, Brave, Firefox, Opera, Vivaldi |
| `messaging.json` | Discord, Slack, Teams, WhatsApp, Telegram, Viber |
| `devtools.json` | VS Code, JetBrains IDEs, npm, pnpm, pip, uv, NuGet, Composer, Yarn, Go, Rust, Bun, Dart, Docker, Prisma, Playwright |
| `system.json` | Windows temp, WER, SoftwareDistribution, Delivery Optimization, GPU caches (D3D, NVIDIA, AMD, Intel), CEF, thumbnail/icon cache, Recycle Bin, prefetch, font cache, event logs |

---

## Rich Terminal UI

### Styles

Three rendering tiers determined at startup:

| Tier | Detection | Features |
|------|-----------|----------|
| **Full VT100** | `$Host.UI.SupportsVirtualTerminal` | Box drawing (`╔╗╚╝║═`), block progress bars (`████░░`), inline color, cursor positioning, live dashboard updates |
| **Simplified Unicode** | ISE or legacy-but-Unicode-capable | `+---+` borders, `#`/`.` bars, standard console colors |
| **ASCII fallback** | `[Console]::IsOutputRedirected` or legacy | Current v2 style — `[##..]` bars, text-panel borders, no special characters |

### Menu Layout (VT100)

```
╔══════════════════════════════════════════════════╗
║  🐍 Bakunawa  v3                                ║
║  Health: ████████░░ 78/100 Good    Free: 45.2 GB ║
║  Mode: MENU    Last: Standard | 12s | 1.8 GB     ║
╚══════════════════════════════════════════════════╝

┌─ MAIN MENU ──────────────────────────────────────┐
│  [1] Standard    temp, browsers, apps, orphans   │
│  [2] Aggressive  + DISM + event logs + prefetch  │
│  [3] Preview     dry run — see plan only         │
│  [4] Orphans     interactive orphan review       │
│  [5] Health      detailed system health report   │
│  [Q] Quit                                        │
├─ Running — skipped ──────────────────────────────┤
│  Chrome, Discord, Spotify                        │
└──────────────────────────────────────────────────┘
```

### Live Cleanup Dashboard

```
 Bakunawa — Standard Mode
[████████░░░░░░░░░░░░]  4/10  System temp caches

  ✓ System caches               1.2 GB
  ✓ Browser caches              342 MB
  ◷ App caches...
  ☐ Dev caches
  ☐ GPU/Shell caches
  ☐ Recycle Bin
  ...

  ⏱ 0:23   Clearing Discord caches...    ?? MB freed
```

### Key Differences from v2

| v2 | v3 |
|---|---|
| ASCII logo banner (7 lines) | Compact header (3 lines) |
| `[##..] 30%` ASCII bars | Block-character progress bars |
| `-- Section header -----` | Box-drawn section headers |
| Static info panel | Health gauge + space inline |
| Running-app skips at end only | Running apps shown in menu |
| Single-line progress spinner | Full dashboard with step table |

---

## Parallel Execution

### When to parallelize

| Category | Execution | Reason |
|----------|-----------|--------|
| System caches (temp, WER, Update) | **Sequential** | Must stop/restart services (wuauserv, bits, dosvc) |
| Browser cleanups (Chrome, Edge, Brave, Firefox) | **Parallel** | Each browser is independent |
| App cleanups (Discord, Slack, VS Code, etc.) | **Parallel** | Each app is independent; config-driven from JSON |
| GPU/Shell caches | **Sequential** | Must stop/restart explorer.exe |
| Recycle Bin | **Sequential** | Single API call |
| Log sweep / Empty dirs / Orphans | **Sequential** | Share state (`$script:Errors[]`, `$script:SkippedItems`) |

### Implementation

Use `[System.Management.Automation.Runspaces.RunspaceFactory]` for parallelism:

```powershell
$runspace = [RunspaceFactory]::CreateRunspace($InitialSessionState)
$runspace.Open()
$powershell = [PowerShell]::Create()
$powershell.Runspace = $runspace
$powershell.AddScript({ ... })
$asyncResult = $powershell.BeginInvoke()
```

Each parallel task reports results back via a synchronized `[System.Collections.Hashtable]` that the UI ticker reads.

### Expected Speedup

| Mode | v2 (sequential) | v3 (parallel) |
|------|----------------|---------------|
| Standard (no browsers running) | ~25-35s | ~10-15s |
| Standard (all browsers closed) | ~35-50s | ~15-20s |
| Aggressive | ~60-90s | ~30-45s |

---

## Configuration Persistence

### Config File

Optional `Bakunawa.json` in the script directory:

```json
{
  "mode": "Standard",
  "extraExcludePaths": ["D:\\Backups", "E:\\PortableApps"],
  "orphanThresholdDays": 30,
  "logRetention": 7,
  "parallel": true,
  "uiStyle": "auto"
}
```

CLI `-ExtraExcludePath` values are **appended** to config-file values. Config file is never required — all values have sensible defaults.

### App Definitions Directory

The `app-definitions/` directory path can be overridden in config. Defaults to `<script-root>/app-definitions`.

---

## Error Handling

### Current Problem

`$ErrorActionPreference = 'SilentlyContinue'` at line 11 — all errors swallowed. The user can't distinguish "failed because access denied" from "didn't find the path" from "unexpected exception."

### v3 Approach

1. **Per-operation try/catch:** Every `Remove-Item`, `Get-ChildItem`, and service operation is individually wrapped.
2. **Structured error log:** `$script:Errors[]` collects `[PSCustomObject]@{ Path, Exception, Category, Timestamp }` for each failure.
3. **Error summary at end:** After cleanup completes, errors are shown grouped by category (access denied, file in use, path not found, etc.).
4. **Warnings inline:** Skipped items (running processes) shown as they happen, same as v2.
5. **No global `SilentlyContinue`:** Instead, individual operations use `-EA SilentlyContinue` where appropriate, with explicit handling.

---

## Testing Strategy

| Test File | Coverage |
|-----------|----------|
| `Core.Tests.ps1` | `Get-DirectorySize`, `Format-FileSize`, `New-TrackedSet`, `Test-IsAdministrator`, `Test-SafeCleanupTarget`, `Get-FreeSpaceInfo`, `Get-HealthScore`, `Get-OrphanRiskScore`, path resolution, exclusion logic |
| `Cleanup.Tests.ps1` | Task registry returns correct tasks per mode, `Measure-AndClear` with mocked paths, `Remove-FilesByPattern`, `Find-OrphanFolders` with mocked app data |
| `UI.Tests.ps1` | `New-AsciiBar`, `Get-PathLabel`, `Format-CompactList`, `Get-ModeColor`, VT100 detection, fallback rendering |
| `Config.Tests.ps1` | JSON parsing, path template expansion, config merge with CLI args, app definition resolution, missing file handling |

---

## Migration Path

The v3 rewrite is done as a single atomic replacement of v2.

**Migration steps:**
1. Remove old `SystemCleaner.ps1` (1751 lines)
2. Write `Bakunawa.ps1` (entry point)
3. Write `Bakunawa.Core.psm1`, `Bakunawa.Cleanup.psm1`, `Bakunawa.UI.psm1`, `Bakunawa.Config.psm1`
4. Write `app-definitions/browsers.json`, `messaging.json`, `devtools.json`, `system.json`
5. Write optional `Bakunawa.json`
6. Update test files to new naming
7. Run test suite and verify all existing assertions pass
8. Update `README.md` to reflect Bakunawa identity + v3 architecture
9. Update design doc paths (this file)

---

## Scope Check

This design is scoped to a single implementation plan:
- One repo
- One set of ~12 files to create/modify
- No external dependencies
- No deployment infrastructure
- No new third-party tools
