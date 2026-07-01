# Bakunawa — Devour Your Digital Waste

[![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B-blue)](https://github.com/PowerShell/PowerShell)
[![Platform](https://img.shields.io/badge/Platform-Windows-lightgrey)](https://www.microsoft.com/windows)
[![License](https://img.shields.io/badge/License-MIT-green)](LICENSE)

A modern, modular Windows system cleanup utility named after the Philippine moon-eating serpent. Safely removes temporary files, browser caches, app caches, developer tool caches, GPU caches, orphan folders, and more.

---

## Features

- **5 cleanup modes:** Menu (interactive), Standard, Aggressive, Preview (dry-run), Orphan Scan
- **30+ app cache targets** across browsers, messaging apps, dev tools, and system caches
- **Config-driven app definitions** — add new apps via JSON, no PowerShell changes needed
- **VT100-rich terminal UI** with graceful ASCII fallback for legacy consoles
- **Safety-first:** excluded paths (Downloads, Documents, Desktop, etc.), running-process detection, approved-root validation
- **Health dashboard:** disk pressure, temp accumulation, browser cache age, orphan risk
- **Orphan detection** with risk scoring (staleness + size + install signal + path trust)
- **Structured error pipeline** — no global `$ErrorActionPreference = 'SilentlyContinue'`
- **Parallel execution** for independent cleanup tasks
- **Optional config file** (`Bakunawa.json`) for persistent exclusions and preferences
- **Zero external dependencies** — pure PowerShell 5.1+ with C# accelerator for fast directory sizing

---

## Architecture

```
Bakunawa.ps1              → Entry point (thin dispatcher / Controller)
├── src/                   → Module source files (MVC separation)
│   ├── Bakunawa.Core.psm1    → Model: engine, safety, sizing, health, orphan scoring  (30 functions)
│   ├── Bakunawa.Config.psm1  → Model: config I/O, JSON app definitions, user config   (5 functions)
│   ├── Bakunawa.Cleanup.psm1 → Controller: task registry, execution, parallel          (19 functions)
│   └── Bakunawa.UI.psm1      → View: VT100 rendering, menus, progress, fallback        (14 functions)
├── app-definitions/      → JSON files defining app cache paths
│   ├── browsers.json
│   ├── messaging.json
│   ├── devtools.json
│   └── system.json
└── Bakunawa.json          → Optional user configuration
```

### Module Responsibilities

| Module | MVC Role | Responsibility |
|--------|----------|---------------|
| `Bakunawa.ps1` | **Controller** | Entry point — auto-loads modules, handles elevation, dispatches to mode |
| `src/Bakunawa.Core.psm1` | **Model** | Protected path resolution, approved-root validation, directory sizing (C#), health analysis, orphan risk scoring |
| `src/Bakunawa.Config.psm1` | **Model** | Loads JSON app definitions, reads/writes user config, validates structure |
| `src/Bakunawa.Cleanup.psm1` | **Controller** | Task registry, step execution, parallel runspaces, error collection |
| `src/Bakunawa.UI.psm1` | **View** | VT100 rendering (with ASCII fallback), interactive menu, progress bars, health dashboard |

---

## Requirements

- Windows 10/11 or Windows Server 2016+
- PowerShell 5.1 or later
- Administrator rights (auto-elevates if needed)

## Installation

```powershell
# Clone or download, then run:
.\Bakunawa.ps1
```

---

## Usage

### Interactive menu (default)

```powershell
.\Bakunawa.ps1
```

### Standard cleanup (non-interactive)

```powershell
.\Bakunawa.ps1 -Mode Standard
```

### Aggressive cleanup (includes DISM, event logs, prefetch)

```powershell
.\Bakunawa.ps1 -Mode Aggressive
```

### Preview mode (dry-run — see what would be deleted)

```powershell
.\Bakunawa.ps1 -Mode Preview
```

### With extra exclusions

```powershell
.\Bakunawa.ps1 -Mode Standard -ExtraExcludePath "D:\Projects","E:\Cache"
```

### Log to file

```powershell
.\Bakunawa.ps1 -Mode Standard -LogFile "C:\Logs\bakunawa.log"
```

### Skip admin elevation (for testing)

```powershell
.\Bakunawa.ps1 -Mode Preview -NoPause -SkipBootstrap
```

---

## Menu Options

| Key | Mode | What It Does |
|-----|------|-------------|
| `1` | **Standard** | Temp files, browser caches, app caches, orphans |
| `2` | **Aggressive** | Standard + DISM component cleanup + event logs + prefetch |
| `3` | **Preview** | Dry run — shows cleanup plan without deleting |
| `4` | **Orphans** | Interactive orphan folder review with risk scoring |
| `5` | **Health** | Detailed system health report (disk, temps, caches, orphans) |
| `Q` | Quit | Exit |

---

## Configuration (`Bakunawa.json`)

Create `Bakunawa.json` alongside the script for persistent settings:

```json
{
  "mode": "Menu",
  "extraExcludePaths": ["D:\\Backups"],
  "orphanThresholdDays": 30,
  "logRetention": 7,
  "parallel": true,
  "uiStyle": "auto"
}
```

| Option | Description |
|--------|-------------|
| `mode` | Default mode: `Menu`, `Standard`, `Aggressive`, `Preview` |
| `extraExcludePaths` | Array of additional paths to never clean |
| `orphanThresholdDays` | Days of inactivity before a folder is considered orphaned |
| `logRetention` | Number of log files to keep |
| `parallel` | Enable parallel cleanup execution |
| `uiStyle` | `"auto"`, `"vt100"`, or `"ascii"` |

---

## Adding New Apps

Create or edit a JSON file in `app-definitions/`:

```json
{
  "name": "MyApp",
  "process": "myapp",
  "locations": [
    { "env": "LOCALAPPDATA", "path": "MyApp/Cache" },
    { "env": "APPDATA", "path": "MyApp/logs" }
  ]
}
```

- `name` — Display name
- `process` — Process name (semicolon-separated for multiple). If the process is running, the app's cache is skipped.
- `locations` — Array of `{ "env": "ENVVAR", "path": "relative/path" }` pairs

---

## Safety Features

- **Protected paths:** Downloads, Documents, Desktop, Pictures, Videos, Music, OneDrive, Windows packages
- **Running process detection:** Skips browser/app cache cleanup if the app is running
- **Approved-root validation:** Only cleans within known safe directories
- **Preview mode:** See exactly what would be deleted before committing
- **Structured error handling:** Per-operation try/catch, errors collected for review
- **Extra exclusion support:** Add custom paths via `-ExtraExcludePath` or config file

### What is NOT targeted

- `Downloads`, Documents, Desktop, Pictures, Music, Videos
- Source-code repositories
- Installed applications
- Registry keys
- Browser profiles as whole directories
- Credentials, passwords, or accounts
- Arbitrary folders outside approved cleanup roots

---

## Development

```powershell
# Run all tests
Invoke-Pester -Path 'tests/'

# Run specific test file
Invoke-Pester -Path 'tests/Bakunawa.Core.Tests.ps1'
```

### Project Structure

- `Bakunawa.ps1` — Entry point (Controller)
- `src/Bakunawa.Core.psm1` — Model: core engine (30 functions)
- `src/Bakunawa.Config.psm1` — Model: config I/O (5 functions)
- `src/Bakunawa.Cleanup.psm1` — Controller: cleanup execution (19 functions)
- `src/Bakunawa.UI.psm1` — View: terminal rendering (14 functions)
- `app-definitions/` — 4 JSON files
- `tests/` — 59 Pester tests

---

## License

MIT

## Acknowledgments

- Inspired by the original SystemCleaner concept
- Named after **Bakunawa**, the Philippine moon-eating serpent — devour your digital waste