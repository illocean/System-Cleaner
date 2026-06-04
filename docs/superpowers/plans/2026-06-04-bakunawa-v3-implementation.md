# Bakunawa v3 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rebrand and rebuild SystemCleaner v2 as Bakunawa v3 — a modular, config-driven, VT100-capable Windows cleanup utility with parallel execution and proper error handling.

**Architecture:** Single entry point (`Bakunawa.ps1`) auto-loads 4 PowerShell modules (`Core`, `Cleanup`, `UI`, `Config`). App-specific cleanup paths externalized to `app-definitions/*.json`. Parallel execution via runspaces for independent cleanup tasks. Three-tier terminal UI with VT100 → Unicode → ASCII fallback.

**Tech Stack:** Windows PowerShell 5.1+, C# via `Add-Type` for fast directory sizing, `System.Management.Automation.Runspaces` for parallelism.

---

## File Map

| File | Action | Purpose |
|------|--------|---------|
| `SystemCleaner.ps1` | **Delete** | Old v2 monolithic script (1751 lines) |
| `Bakunawa.ps1` | **Create** | Thin entry point — param parsing, admin elevation, mode dispatch |
| `Bakunawa.Core.psm1` | **Create** | Engine: FastSys C# accelerator, directory sizing, safety checks, health score, orphan risk, path resolution, exclusion logic, tracked state |
| `Bakunawa.Cleanup.psm1` | **Create** | Task registry + all cleanup step functions, parameterized by config |
| `Bakunawa.UI.psm1` | **Create** | Terminal rendering: VT100, Unicode fallback, ASCII fallback; menu, header, log, progress dashboard |
| `Bakunawa.Config.psm1` | **Create** | JSON config I/O, path template expansion, app definition resolution |
| `Bakunawa.json` | **Create** | Optional user config file (exclusions, preferences) |
| `app-definitions/browsers.json` | **Create** | Chrome, Edge, Brave, Firefox, Opera, Vivaldi cache paths |
| `app-definitions/messaging.json` | **Create** | Discord, Slack, Teams, WhatsApp, Telegram, Viber cache paths |
| `app-definitions/devtools.json` | **Create** | VS Code, JetBrains, npm, pnpm, pip, uv, NuGet, Composer, Yarn, Go, Rust, Bun, Dart, Docker, Prisma, Playwright cache paths |
| `app-definitions/system.json` | **Create** | Windows temp, WER, SoftwareDistribution, GPU caches, thumbnail cache, Recycle Bin, prefetch, font cache, event logs |
| `tests/Bakunawa.Config.Tests.ps1` | **Create** | Config parsing, path template expansion, merge logic |
| `tests/Bakunawa.Core.Tests.ps1` | **Create** | Core utility tests (migrated from v2 + new) |
| `tests/Bakunawa.Cleanup.Tests.ps1` | **Create** | Task registry, Measure-AndClear, orphan detection |
| `tests/Bakunawa.UI.Tests.ps1` | **Create** | UI formatting tests (migrated from v2 + VT100 detection) |
| `README.md` | **Modify** | Update to Bakunawa branding, architecture, and usage |
| `docs/superpowers/specs/2026-06-04-systemcleaner-v3-redesign.md` | **Modify** | Update file already done |

---

### Task 1: Bakunawa.Config — Configuration Module

**Files:**
- Create: `app-definitions/browsers.json`
- Create: `app-definitions/messaging.json`
- Create: `app-definitions/devtools.json`
- Create: `app-definitions/system.json`
- Create: `Bakunawa.Config.psm1`
- Create: `tests/Bakunawa.Config.Tests.ps1`

This module handles reading JSON app definitions and the optional user config. It does environment-variable path template expansion (`%APPDATA%/discord/Cache` → resolved path).

- [ ] **Step 1: Write app-definitions/browsers.json**

```json
[
  {
    "name": "Chrome",
    "process": "chrome",
    "locations": [
      { "env": "LOCALAPPDATA", "path": "Google/Chrome/User Data/{profile}/Cache" },
      { "env": "LOCALAPPDATA", "path": "Google/Chrome/User Data/{profile}/Code Cache" },
      { "env": "LOCALAPPDATA", "path": "Google/Chrome/User Data/{profile}/GPUCache" },
      { "env": "LOCALAPPDATA", "path": "Google/Chrome/User Data/{profile}/Media Cache" },
      { "env": "LOCALAPPDATA", "path": "Google/Chrome/User Data/{profile}/DawnCache" },
      { "env": "LOCALAPPDATA", "path": "Google/Chrome/User Data/{profile}/ShaderCache" },
      { "env": "LOCALAPPDATA", "path": "Google/Chrome/User Data/{profile}/GrShaderCache" },
      { "env": "LOCALAPPDATA", "path": "Google/Chrome/User Data/{profile}/GraphiteDawnCache" },
      { "env": "LOCALAPPDATA", "path": "Google/Chrome/User Data/{profile}/DawnWebGPUCache" },
      { "env": "LOCALAPPDATA", "path": "Google/Chrome/User Data/{profile}/Local Storage" },
      { "env": "LOCALAPPDATA", "path": "Google/Chrome/User Data/{profile}/Service Worker/CacheStorage" },
      { "env": "LOCALAPPDATA", "path": "Google/Chrome/User Data/{profile}/Service Worker/ScriptCache" },
      { "env": "LOCALAPPDATA", "path": "Google/Chrome/User Data/{profile}/Crashpad" },
      { "env": "LOCALAPPDATA", "path": "Google/Chrome/User Data/{profile}/blob_storage" }
    ]
  },
  {
    "name": "Edge",
    "process": "msedge",
    "locations": [
      { "env": "LOCALAPPDATA", "path": "Microsoft/Edge/User Data/{profile}/Cache" },
      { "env": "LOCALAPPDATA", "path": "Microsoft/Edge/User Data/{profile}/Code Cache" },
      { "env": "LOCALAPPDATA", "path": "Microsoft/Edge/User Data/{profile}/GPUCache" },
      { "env": "LOCALAPPDATA", "path": "Microsoft/Edge/User Data/{profile}/Media Cache" },
      { "env": "LOCALAPPDATA", "path": "Microsoft/Edge/User Data/{profile}/DawnCache" },
      { "env": "LOCALAPPDATA", "path": "Microsoft/Edge/User Data/{profile}/ShaderCache" },
      { "env": "LOCALAPPDATA", "path": "Microsoft/Edge/User Data/{profile}/GrShaderCache" },
      { "env": "LOCALAPPDATA", "path": "Microsoft/Edge/User Data/{profile}/Local Storage" },
      { "env": "LOCALAPPDATA", "path": "Microsoft/Edge/User Data/{profile}/Service Worker/CacheStorage" },
      { "env": "LOCALAPPDATA", "path": "Microsoft/Edge/User Data/{profile}/blob_storage" }
    ]
  },
  {
    "name": "Brave",
    "process": "brave",
    "locations": [
      { "env": "LOCALAPPDATA", "path": "BraveSoftware/Brave-Browser/User Data/{profile}/Cache" },
      { "env": "LOCALAPPDATA", "path": "BraveSoftware/Brave-Browser/User Data/{profile}/Code Cache" },
      { "env": "LOCALAPPDATA", "path": "BraveSoftware/Brave-Browser/User Data/{profile}/GPUCache" },
      { "env": "LOCALAPPDATA", "path": "BraveSoftware/Brave-Browser/User Data/{profile}/Media Cache" },
      { "env": "LOCALAPPDATA", "path": "BraveSoftware/Brave-Browser/User Data/{profile}/DawnCache" },
      { "env": "LOCALAPPDATA", "path": "BraveSoftware/Brave-Browser/User Data/{profile}/ShaderCache" },
      { "env": "LOCALAPPDATA", "path": "BraveSoftware/Brave-Browser/User Data/{profile}/Local Storage" },
      { "env": "LOCALAPPDATA", "path": "BraveSoftware/Brave-Browser/User Data/{profile}/blob_storage" }
    ]
  },
  {
    "name": "Firefox",
    "process": "firefox",
    "locations": [
      { "env": "LOCALAPPDATA", "path": "Mozilla/Firefox/Profiles/{profile}/cache2" },
      { "env": "LOCALAPPDATA", "path": "Mozilla/Firefox/Profiles/{profile}/startupCache" },
      { "env": "LOCALAPPDATA", "path": "Mozilla/Firefox/Profiles/{profile}/thumbnails" },
      { "env": "LOCALAPPDATA", "path": "Mozilla/Firefox/Profiles/{profile}/shader-cache" },
      { "env": "LOCALAPPDATA", "path": "Mozilla/Firefox/Profiles/{profile}/OfflineCache" }
    ]
  },
  {
    "name": "Opera",
    "process": "opera",
    "locations": [
      { "env": "APPDATA", "path": "Opera Software/Opera Stable/{profile}/Cache" },
      { "env": "APPDATA", "path": "Opera Software/Opera Stable/{profile}/Code Cache" },
      { "env": "APPDATA", "path": "Opera Software/Opera Stable/{profile}/GPUCache" }
    ]
  },
  {
    "name": "Vivaldi",
    "process": "vivaldi",
    "locations": [
      { "env": "LOCALAPPDATA", "path": "Vivaldi/User Data/{profile}/Cache" },
      { "env": "LOCALAPPDATA", "path": "Vivaldi/User Data/{profile}/Code Cache" },
      { "env": "LOCALAPPDATA", "path": "Vivaldi/User Data/{profile}/GPUCache" }
    ]
  }
]
```

- [ ] **Step 2: Write app-definitions/messaging.json**

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
      { "env": "APPDATA", "path": "Slack/Service Worker/CacheStorage" },
      { "env": "APPDATA", "path": "Slack/Code Cache" },
      { "env": "APPDATA", "path": "Slack/GPUCache" },
      { "env": "LOCALAPPDATA", "path": "Slack/logs" }
    ]
  },
  {
    "name": "Teams",
    "process": "teams",
    "locations": [
      { "env": "APPDATA", "path": "Microsoft/Teams/Cache" },
      { "env": "APPDATA", "path": "Microsoft/Teams/Code Cache" },
      { "env": "APPDATA", "path": "Microsoft/Teams/GPUCache" },
      { "env": "APPDATA", "path": "Microsoft/Teams/logs" },
      { "env": "APPDATA", "path": "Microsoft/Teams/blob_storage" },
      { "env": "LOCALAPPDATA", "path": "Microsoft/Teams/old_weblogs" }
    ]
  },
  {
    "name": "WhatsApp",
    "process": "whatsapp",
    "locations": [
      { "env": "APPDATA", "path": "WhatsApp/Cache" },
      { "env": "APPDATA", "path": "WhatsApp/Code Cache" },
      { "env": "APPDATA", "path": "WhatsApp/GPUCache" },
      { "env": "APPDATA", "path": "WhatsApp/Service Worker/CacheStorage" }
    ]
  },
  {
    "name": "Telegram",
    "process": "telegram",
    "locations": [
      { "env": "APPDATA", "path": "Telegram Desktop/tdata/{sub:cache}" }
    ]
  },
  {
    "name": "Viber",
    "process": "viber",
    "locations": [
      { "env": "APPDATA", "path": "ViberPC/cache" },
      { "env": "LOCALAPPDATA", "path": "Viber/cache" },
      { "env": "LOCALAPPDATA", "path": "Viber Media S.a r.l/cache" }
    ]
  }
]
```

- [ ] **Step 3: Write app-definitions/devtools.json**

```json
[
  {
    "name": "VS Code",
    "process": "Code",
    "locations": [
      { "env": "APPDATA", "path": "Code/Cache" },
      { "env": "APPDATA", "path": "Code/CachedData" },
      { "env": "APPDATA", "path": "Code/CachedExtensions" },
      { "env": "APPDATA", "path": "Code/CachedExtensionVSIXs" },
      { "env": "APPDATA", "path": "Code/Code Cache" },
      { "env": "APPDATA", "path": "Code/GPUCache" },
      { "env": "APPDATA", "path": "Code/Service Worker/CacheStorage" },
      { "env": "APPDATA", "path": "Code/logs" }
    ]
  },
  {
    "name": "VS Code Insiders",
    "process": "Code - Insiders",
    "locations": [
      { "env": "APPDATA", "path": "Code - Insiders/Cache" },
      { "env": "APPDATA", "path": "Code - Insiders/CachedData" },
      { "env": "APPDATA", "path": "Code - Insiders/CachedExtensions" },
      { "env": "APPDATA", "path": "Code - Insiders/CachedExtensionVSIXs" },
      { "env": "APPDATA", "path": "Code - Insiders/Code Cache" },
      { "env": "APPDATA", "path": "Code - Insiders/GPUCache" },
      { "env": "APPDATA", "path": "Code - Insiders/logs" }
    ]
  },
  {
    "name": "npm-cache",
    "process": null,
    "locations": [
      { "env": "LOCALAPPDATA", "path": "npm-cache" }
    ]
  },
  {
    "name": "pnpm-cache",
    "process": null,
    "locations": [
      { "env": "LOCALAPPDATA", "path": "pnpm-cache" },
      { "env": "LOCALAPPDATA", "path": "pnpm-state" }
    ]
  },
  {
    "name": "pip-cache",
    "process": null,
    "locations": [
      { "env": "LOCALAPPDATA", "path": "pip/cache" }
    ]
  },
  {
    "name": "uv-cache",
    "process": null,
    "locations": [
      { "env": "LOCALAPPDATA", "path": "uv/cache" }
    ]
  },
  {
    "name": "NuGet-cache",
    "process": null,
    "locations": [
      { "env": "LOCALAPPDATA", "path": "NuGet/v3-cache" },
      { "env": "LOCALAPPDATA", "path": "NuGet/plugins-cache" },
      { "env": "LOCALAPPDATA", "path": "NuGet/http-cache" }
    ]
  },
  {
    "name": "Composer-cache",
    "process": null,
    "locations": [
      { "env": "LOCALAPPDATA", "path": "Composer/cache" }
    ]
  },
  {
    "name": "Yarn-cache",
    "process": null,
    "locations": [
      { "env": "LOCALAPPDATA", "path": "Yarn/Cache" },
      { "env": "LOCALAPPDATA", "path": "Yarn/Berry/cache" }
    ]
  },
  {
    "name": "Go-mod-cache",
    "process": null,
    "locations": []
  },
  {
    "name": "Cargo-cache",
    "process": null,
    "locations": [
      { "env": "USERPROFILE", "path": ".cargo/registry/cache" },
      { "env": "USERPROFILE", "path": ".cargo/git/db" }
    ]
  },
  {
    "name": "Bun-cache",
    "process": null,
    "locations": [
      { "env": "USERPROFILE", "path": ".bun/install/cache" }
    ]
  },
  {
    "name": "Dart-pub-cache",
    "process": null,
    "locations": [
      { "env": "LOCALAPPDATA", "path": "Pub/Cache" }
    ]
  },
  {
    "name": "Docker-tmp",
    "process": null,
    "locations": [
      { "env": "APPDATA", "path": "Docker/tmp" }
    ]
  },
  {
    "name": "Prisma-engines",
    "process": null,
    "locations": [
      { "env": "LOCALAPPDATA", "path": "prisma-nodejs" }
    ]
  },
  {
    "name": "checkpoint-nodejs",
    "process": null,
    "locations": [
      { "env": "LOCALAPPDATA", "path": "checkpoint-nodejs" }
    ]
  },
  {
    "name": "firebase-heartbeat",
    "process": null,
    "locations": [
      { "env": "LOCALAPPDATA", "path": "firebase-heartbeat" }
    ]
  },
  {
    "name": "dotnet-telemetry",
    "process": null,
    "locations": [
      { "env": "USERPROFILE", "path": ".dotnet/TelemetryFallbackDir" }
    ]
  },
  {
    "name": "JetBrains",
    "process": null,
    "locations": [
      { "env": "LOCALAPPDATA", "path": "JetBrains/{product}" }
    ]
  }
]
```

- [ ] **Step 4: Write app-definitions/system.json**

```json
[
  {
    "name": "Windows Temp",
    "process": null,
    "locations": [
      { "env": "TEMP", "path": "" },
      { "env": "LOCALAPPDATA", "path": "Temp" },
      { "env": "SystemRoot", "path": "Temp" }
    ]
  },
  {
    "name": "Crash Dumps",
    "process": null,
    "locations": [
      { "env": "LOCALAPPDATA", "path": "CrashDumps" }
    ]
  },
  {
    "name": "WER Archive",
    "process": null,
    "locations": [
      { "env": "ProgramData", "path": "Microsoft/Windows/WER/ReportArchive" }
    ]
  },
  {
    "name": "WER Queue",
    "process": null,
    "locations": [
      { "env": "ProgramData", "path": "Microsoft/Windows/WER/ReportQueue" }
    ]
  },
  {
    "name": "Network Downloader",
    "process": null,
    "locations": [
      { "env": "ProgramData", "path": "Microsoft/Network/Downloader" }
    ]
  },
  {
    "name": "SoftwareDistribution",
    "process": null,
    "serviceAction": "stop:wuauserv,bits,dosvc",
    "locations": [
      { "env": "SystemRoot", "path": "SoftwareDistribution/Download" },
      { "env": "SystemRoot", "path": "SoftwareDistribution/DeliveryOptimization" }
    ]
  },
  {
    "name": "GPU D3D Cache",
    "process": null,
    "locations": [
      { "env": "LOCALAPPDATA", "path": "D3DSCache" }
    ]
  },
  {
    "name": "GPU NVIDIA DXCache",
    "process": null,
    "locations": [
      { "env": "LOCALAPPDATA", "path": "NVIDIA/DXCache" },
      { "env": "LOCALAPPDATA", "path": "NVIDIA/GLCache" }
    ]
  },
  {
    "name": "GPU AMD Cache",
    "process": null,
    "locations": [
      { "env": "LOCALAPPDATA", "path": "AMD/DxCache" }
    ]
  },
  {
    "name": "GPU Intel Cache",
    "process": null,
    "locations": [
      { "env": "LOCALAPPDATA", "path": "Intel/ShaderCache" }
    ]
  },
  {
    "name": "CEF Cache",
    "process": null,
    "locations": [
      { "env": "LOCALAPPDATA", "path": "CEF/Cache" }
    ]
  },
  {
    "name": "Thumbnail Cache",
    "process": null,
    "explorerAction": "restart",
    "locations": [
      { "env": "LOCALAPPDATA", "path": "Microsoft/Windows/Explorer" }
    ]
  },
  {
    "name": "Recycle Bin",
    "process": null,
    "recycleBin": true
  },
  {
    "name": "Prefetch",
    "process": null,
    "locations": [
      { "env": "SystemRoot", "path": "Prefetch" }
    ]
  },
  {
    "name": "Font Cache",
    "process": null,
    "serviceAction": "stop:FontCache",
    "locations": [
      { "env": "SystemRoot", "path": "ServiceProfiles/LocalService/AppData/Local/FontCache" }
    ]
  }
]
```

- [ ] **Step 5: Write the failing Config tests**

File: `tests/Bakunawa.Config.Tests.ps1`
```powershell
BeforeAll {
    $modulePath = Join-Path $PSScriptRoot '..' 'Bakunawa.Config.psm1'
    Remove-Module Bakunawa.Config -ErrorAction SilentlyContinue
    Import-Module $modulePath -Force -Scope Global
}

Describe 'Bakunawa.Config' {
    It 'resolves environment path templates correctly' {
        $result = Resolve-EnvTemplate -EnvVar 'LOCALAPPDATA' -SubPath 'discord/Cache'
        $result | Should -Not -BeNullOrEmpty
        $result | Should -Match 'discord\\Cache$'
    }

    It 'returns null for missing environment variable' {
        $result = Resolve-EnvTemplate -EnvVar 'NONEXISTENT_TEST_VAR' -SubPath 'test'
        $result | Should -BeNullOrEmpty
    }

    It 'loads app definitions from a category file' {
        $defs = Get-AppDefinitions -Category 'messaging'
        $defs | Should -Not -BeNullOrEmpty
        $defs.Count | Should -BeGreaterThan 0
        $defs[0].name | Should -Not -BeNullOrEmpty
        $defs[0].locations | Should -Not -BeNullOrEmpty
    }

    It 'loads all app definition categories' {
        $all = Get-AllAppDefinitions
        $all.Count | Should -BeGreaterThan 10
    }

    It 'loads default config when no config file exists' {
        $config = Get-BakunawaConfig
        $config.mode | Should -Be 'Menu'
        $config.parallel | Should -Be $true
    }

    It 'merges CLI extra exclusions with config file exclusions' {
        $merged = Merge-Exclusions -ConfigPaths @('D:\Backups') -CliPaths @('E:\Data')
        $merged.Count | Should -Be 2
    }

    It 'processes null process name safely' {
        $defs = Get-AppDefinitions -Category 'system'
        $nullNames = $defs | Where-Object { $null -eq $_.process }
        $nullNames.Count | Should -BeGreaterThan 0
    }
}
```

- [ ] **Step 6: Run Config tests to verify they fail**

Run:
```powershell
$results = Invoke-Pester -Path 'tests/Bakunawa.Config.Tests.ps1' -PassThru
$results.FailedCount | Should -BeGreaterThan 0
```
Expected: FAIL — module not implemented yet.

- [ ] **Step 7: Implement Bakunawa.Config.psm1**

Write to `Bakunawa.Config.psm1`:
```powershell
# Bakunawa.Config.psm1 — Configuration I/O

$script:AppDefinitionsDir = $null
$script:ConfigFilePath = $null

function Resolve-EnvTemplate {
    param(
        [string]$EnvVar,
        [string]$SubPath
    )
    $base = [Environment]::ExpandEnvironmentVariables("%$EnvVar%")
    if ([string]::IsNullOrWhiteSpace($base) -or $base -eq "%$EnvVar%") { return $null }
    if ([string]::IsNullOrWhiteSpace($SubPath)) { return $base }
    try {
        $full = [System.IO.Path]::GetFullPath((Join-Path $base $SubPath))
        return $full
    } catch { return $null }
}

function Get-AppDefinitions {
    param([string]$Category)
    $dir = $script:AppDefinitionsDir
    if (-not $dir) {
        $scriptPath = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
        $dir = Join-Path $scriptPath 'app-definitions'
        $script:AppDefinitionsDir = $dir
    }
    $file = Join-Path $dir "$Category.json"
    if (-not (Test-Path -LiteralPath $file)) { return @() }
    try {
        $raw = Get-Content -LiteralPath $file -Raw -Encoding UTF8
        $defs = [System.Text.Json.JsonSerializer]::Deserialize($raw, [System.Collections.Generic.List[System.Object]])
        if (-not $defs) { return @() }
        return @($defs)
    } catch {
        try {
            return @(ConvertFrom-Json $raw -EA Stop)
        } catch { return @() }
    }
}

function Get-AllAppDefinitions {
    $all = [System.Collections.Generic.List[System.Object]]::new()
    foreach ($cat in @('browsers', 'messaging', 'devtools', 'system')) {
        $defs = Get-AppDefinitions -Category $cat
        foreach ($d in $defs) { $all.Add($d) }
    }
    return @($all)
}

function Get-BakunawaConfig {
    param([switch]$ForceReload)
    $cfgPath = $script:ConfigFilePath
    if (-not $cfgPath) {
        $scriptPath = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
        $cfgPath = Join-Path $scriptPath 'Bakunawa.json'
        $script:ConfigFilePath = $cfgPath
    }
    $defaults = @{
        mode = 'Menu'
        extraExcludePaths = @()
        orphanThresholdDays = 30
        logRetention = 7
        parallel = $true
        uiStyle = 'auto'
    }
    if (-not $ForceReload -and $script:CachedConfig) { return $script:CachedConfig }
    if (Test-Path -LiteralPath $cfgPath) {
        try {
            $raw = Get-Content -LiteralPath $cfgPath -Raw -Encoding UTF8
            $userConfig = ConvertFrom-Json $raw -EA Stop
            foreach ($key in $defaults.Keys) {
                if (-not ($userConfig.PSObject.Properties.Name -contains $key)) {
                    $userConfig | Add-Member -NotePropertyName $key -NotePropertyValue $defaults[$key] -Force
                }
            }
            $script:CachedConfig = $userConfig
            return $userConfig
        } catch {}
    }
    $script:CachedConfig = [PSCustomObject]$defaults
    return $script:CachedConfig
}

function Merge-Exclusions {
    param([string[]]$ConfigPaths, [string[]]$CliPaths)
    $set = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($p in $ConfigPaths) { if ($p) { [void]$set.Add($p) } }
    foreach ($p in $CliPaths) { if ($p) { [void]$set.Add($p) } }
    return @($set)
}

Export-ModuleMember -Function Resolve-EnvTemplate, Get-AppDefinitions, Get-AllAppDefinitions, Get-BakunawaConfig, Merge-Exclusions
```

- [ ] **Step 8: Run Config tests to verify they pass**

Run:
```powershell
$results = Invoke-Pester -Path 'tests/Bakunawa.Config.Tests.ps1' -PassThru
$results.FailedCount | Should -Be 0
```
Expected: PASS (0 failed).

- [ ] **Step 9: Commit**

```bash
git add app-definitions/ Bakunawa.Config.psm1 tests/Bakunawa.Config.Tests.ps1
git commit -m "feat: add Bakunawa config module with JSON app definitions"
```

---

### Task 2: Bakunawa.Core — Core Engine

**Files:**
- Create: `Bakunawa.Core.psm1`
- Create: `tests/Bakunawa.Core.Tests.ps1`

Core module provides: FastSys C# accelerator, directory sizing, formatting, safety checks, health scoring, orphan risk scoring, path resolution, exclusion logic, and all script-scoped state variables.

- [ ] **Step 1: Write failing Core tests**

File: `tests/Bakunawa.Core.Tests.ps1`
```powershell
BeforeAll {
    $modulePath = Join-Path $PSScriptRoot '..' 'Bakunawa.Core.psm1'
    Remove-Module Bakunawa.Core -ErrorAction SilentlyContinue
    Import-Module $modulePath -Force -Scope Global
}

Describe 'Bakunawa.Core formatting' {
    It 'formats bytes correctly' {
        Format-FileSize 0 | Should -Be '0 B'
        Format-FileSize 500 | Should -Be '500 B'
        Format-FileSize 2048 | Should -Be '2 KB'
        Format-FileSize 1048576 | Should -Be '1.0 MB'
        Format-FileSize 1610612736 | Should -Be '1.50 GB'
    }

    It 'returns zero for non-existent directory size' {
        Get-DirectorySize -Path 'C:\NonExistentPath_Bakunawa_Test' | Should -Be 0
    }

    It 'creates a case-insensitive tracked set' {
        $set = New-TrackedSet
        $set.Add('Hello') | Should -Be $true
        $set.Add('hello') | Should -Be $false
    }

    It 'resolves full paths correctly' {
        Resolve-FullPath '' | Should -BeNullOrEmpty
        Resolve-FullPath ' ' | Should -BeNullOrEmpty
        Resolve-FullPath $env:SystemRoot | Should -Not -BeNullOrEmpty
    }

    It 'detects non-administrator in normal session' {
        Test-IsAdministrator | Should -BeOfType System.Boolean
    }
}

Describe 'Bakunawa.Core orphan risk' {
    It 'scores old + large folder as HIGH' {
        $r = Get-OrphanRiskScore -Name 'OldApp' -SizeBytes 300MB -DaysStale 400 -PathSuffix 'Local' -InstalledNames @() -RunningNames @()
        ($r.Score -ge 41) | Should -Be $true
        $r.RiskLevel | Should -Be 'High'
    }

    It 'scores recent + small folder as LOW' {
        $r = Get-OrphanRiskScore -Name 'RecentApp' -SizeBytes 500KB -DaysStale 40 -PathSuffix 'Roaming' -InstalledNames @() -RunningNames @()
        ($r.Score -le 15) | Should -Be $true
        $r.RiskLevel | Should -Be 'Low'
    }

    It 'reduces score when install matches exact name' {
        $r1 = Get-OrphanRiskScore -Name 'MyTest' -SizeBytes 100MB -DaysStale 200 -PathSuffix 'Local' -InstalledNames @() -RunningNames @()
        $r2 = Get-OrphanRiskScore -Name 'MyTest' -SizeBytes 100MB -DaysStale 200 -PathSuffix 'Local' -InstalledNames @('MyTest') -RunningNames @()
        $r2.Score | Should -Be ($r1.Score - 30)
    }

    It 'never returns negative score' {
        $r = Get-OrphanRiskScore -Name 'ActiveApp' -SizeBytes 100 -DaysStale 30 -PathSuffix 'Roaming' -InstalledNames @('ActiveApp') -RunningNames @()
        $r.Score | Should -Be 0
    }
}

Describe 'Bakunawa.Core health score' {
    It 'returns a valid result object' {
        $h = Get-HealthScore
        ($h.Score -ge 0 -and $h.Score -le 100) | Should -Be $true
        $h.Grade | Should -Not -BeNullOrEmpty
    }
}

Describe 'Bakunawa.Core safety' {
    It 'compacts protected paths into short labels' {
        $summary = Format-CompactList -Items @(
            'C:\Users\Demo\Downloads',
            'C:\Users\Demo\Documents',
            'C:\Users\Demo\Desktop',
            'C:\Users\Demo\Pictures'
        ) -MaxItems 2
        $summary | Should -Be 'Downloads, Documents (+2 more)'
    }

    It 'returns "none" for empty compact list' {
        Format-CompactList -Items @() | Should -Be 'none'
    }

    It 'Test-IsExcludedPath excludes Downloads' {
        $script:ExcludedPaths = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        [void]$script:ExcludedPaths.Add('C:\Users\Demo\Downloads')
        Test-IsExcludedPath 'C:\Users\Demo\Downloads' | Should -Be $true
        Test-IsExcludedPath 'C:\Users\Demo\Desktop' | Should -Be $false
    }

    It 'Test-SafeCleanupTarget rejects excluded paths' {
        $script:ExcludedPaths = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        [void]$script:ExcludedPaths.Add('C:\Protected')
        Test-SafeCleanupTarget -Path 'C:\Protected\file.txt' -ApprovedRoots @('C:\Protected') | Should -Be $false
    }
}
```

- [ ] **Step 2: Run Core tests (expect failures)**

Run:
```powershell
$results = Invoke-Pester -Path 'tests/Bakunawa.Core.Tests.ps1' -PassThru
$results.FailedCount | Should -BeGreaterThan 0
```

- [ ] **Step 3: Implement Bakunawa.Core.psm1**

Write full module to `Bakunawa.Core.psm1` with all functions migrated from v2:
- `FastSys` C# accelerator for GetDirectorySize
- `Get-FreeSpaceInfo`, `Get-DirectorySize`, `Format-FileSize`
- `New-TrackedSet`, `Resolve-FullPath`, `Get-EnvPath`, `Join-EnvPath`
- `Test-IsAdministrator`, `Restart-Elevated`
- `Get-ExcludedPaths`, `Test-IsExcludedPath`, `Test-SafeCleanupTarget`
- `Get-RunningProcessNames`, `Test-AnyProcessRunning`, `Register-SkippedItem`
- `Get-OrphanRiskScore`, `Get-HealthScore`, `Show-HealthDetail`
- `Get-DefaultApprovedRoots`, `Get-DisposableDirectoryNames`, `Test-IsDisposableLogPath`
- `Get-DisposableLogCandidates`, `Get-StaleDisposableDirectories`, `Get-JunkSweepRoots`
- `Get-PathLabel`, `Format-CompactList`, `New-AsciiBar`
- Script-scoped state: all `$script:*` variables

```powershell
# Bakunawa.Core.psm1 — Core engine, safety, sizing, health

# ── C# ACCELERATOR ──
try {
    Add-Type -TypeDefinition @"
    using System;
    using System.IO;
    public static class FastSys {
        public static long GetDirectorySize(string path) {
            long size = 0;
            try {
                var d = new DirectoryInfo(path);
                foreach (var f in d.GetFiles()) { size += f.Length; }
                foreach (var s in d.GetDirectories()) { size += GetDirectorySize(s.FullName); }
            } catch {}
            return size;
        }
    }
"@ -ErrorAction SilentlyContinue
} catch {}

# ── SCRIPT STATE ──
$script:IsPreview        = $false
$script:IsAggressive     = $false
$script:CurrentModeName  = 'Menu'
$script:StepIndex        = 0
$script:TotalSteps       = 0
$script:ExcludedPaths    = $null
$script:LastRunSummary   = $null
$script:BytesFreed       = [long]0
$script:CategorySizes    = @{}
$script:OrphanReport     = @()
$script:SkippedItems     = @()
$script:RunningProcesses = $null
$script:ActiveStepName   = $null
$script:ActiveStepPct    = 0
$script:Errors           = @()   # New in v3: structured errors
$script:LogFilePath      = ''
$script:HealthCache      = $null
$script:LastOrphanRisks  = $null
$script:SysLoc           = $null

function Get-FreeSpaceInfo {
    param([string]$DriveLetter)
    if ([string]::IsNullOrWhiteSpace($DriveLetter)) {
        $sd = [Environment]::GetEnvironmentVariable('SystemDrive','Process')
        if (-not $sd) { $sd = 'C:' }
        $DriveLetter = $sd.TrimEnd(':')
    }
    $d = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='${DriveLetter}:'" -ErrorAction SilentlyContinue
    if (-not $d) { return [PSCustomObject]@{MB=0;GB=0} }
    [PSCustomObject]@{
        MB = [math]::Round($d.FreeSpace / 1MB)
        GB = [math]::Round($d.FreeSpace / 1GB, 2)
    }
}

function Get-DirectorySize {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return [long]0 }
    if ([bool]('FastSys' -as [type])) { return [FastSys]::GetDirectorySize($Path) }
    $sum = (Get-ChildItem -LiteralPath $Path -Recurse -Force -EA SilentlyContinue |
        Measure-Object -Property Length -Sum -EA SilentlyContinue).Sum
    if ($null -eq $sum) { [long]0 } else { [long]$sum }
}

function Format-FileSize {
    param([long]$Bytes)
    if ($Bytes -ge 1GB) { return '{0:N2} GB' -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return '{0:N1} MB' -f ($Bytes / 1MB) }
    if ($Bytes -ge 1KB) { return '{0:N0} KB' -f ($Bytes / 1KB) }
    "$Bytes B"
}

function New-TrackedSet {
    [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
}

function Resolve-FullPath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    try { [System.IO.Path]::GetFullPath($Path).TrimEnd('\') } catch { $null }
}

function Get-EnvPath {
    param([Parameter(Mandatory)][string]$Name)
    foreach ($s in 'Process','User','Machine') {
        $v = [Environment]::GetEnvironmentVariable($Name, $s)
        $r = Resolve-FullPath $v
        if ($r) { return $r }
    }
    $null
}

function Join-EnvPath {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$ChildPath)
    $b = Get-EnvPath -Name $Name
    if (-not $b) { return $null }
    Resolve-FullPath (Join-Path $b $ChildPath)
}

function Test-IsAdministrator {
    $identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Restart-Elevated {
    param([string]$SelectedMode)
    $args_ = @('-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$PSCommandPath`"")
    if ($SelectedMode) { $args_ += '-Mode'; $args_ += $SelectedMode }
    try {
        Write-Host ''
        Write-Host 'Administrator rights required. Requesting elevation...' -ForegroundColor Yellow
        Start-Process powershell.exe -Verb RunAs -ArgumentList $args_ | Out-Null
        return $true
    } catch {
        Write-Host 'Elevation cancelled.' -ForegroundColor Red
        return $false
    }
}

function Get-ExcludedPaths {
    param([string[]]$ExtraExcludePath)
    $set = New-TrackedSet
    foreach ($c in @(
        (Join-EnvPath 'USERPROFILE' 'Downloads'),
        (Join-EnvPath 'USERPROFILE' 'Documents'),
        (Join-EnvPath 'USERPROFILE' 'Desktop'),
        (Join-EnvPath 'USERPROFILE' 'Pictures'),
        (Join-EnvPath 'USERPROFILE' 'Videos'),
        (Join-EnvPath 'USERPROFILE' 'Music'),
        (Join-EnvPath 'OneDrive' 'Downloads'),
        (Join-EnvPath 'LOCALAPPDATA' 'Packages')
    )) {
        $r = Resolve-FullPath $c
        if ($r) { [void]$set.Add($r) }
    }
    foreach ($c in $ExtraExcludePath) {
        $r = Resolve-FullPath $c
        if ($r) { [void]$set.Add($r) }
    }
    $set
}

function Test-IsExcludedPath {
    param([string]$Path)
    $r = Resolve-FullPath $Path
    if (-not $r -or -not $script:ExcludedPaths) { return $false }
    foreach ($e in $script:ExcludedPaths) {
        if ($r.Equals($e,[StringComparison]::OrdinalIgnoreCase) -or
            $r.StartsWith("$e\",[StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    $false
}

function Get-DefaultApprovedRoots {
    $set = New-TrackedSet
    foreach ($root in @(
        (Get-EnvPath 'TEMP'),
        (Get-EnvPath 'LOCALAPPDATA'),
        (Get-EnvPath 'APPDATA'),
        (Get-EnvPath 'USERPROFILE'),
        $script:SysLoc.ProgramData,
        $script:SysLoc.WindowsRoot
    )) {
        $resolved = Resolve-FullPath $root
        if ($resolved) { [void]$set.Add($resolved) }
    }
    @($set)
}

function Test-SafeCleanupTarget {
    param([string]$Path, [string[]]$ApprovedRoots = @(), [switch]$AllowRoot)
    $resolved = Resolve-FullPath $Path
    if (-not $resolved -or (Test-IsExcludedPath $resolved)) { return $false }
    $roots = @($ApprovedRoots | ForEach-Object { Resolve-FullPath $_ } | Where-Object { $_ })
    if (-not $roots) { $roots = Get-DefaultApprovedRoots }
    foreach ($root in $roots) {
        if ($resolved.Equals($root, [StringComparison]::OrdinalIgnoreCase)) { return $AllowRoot.IsPresent }
        if ($resolved.StartsWith("$root\", [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    $false
}

function Get-DisposableDirectoryNames {
    $names = New-TrackedSet
    @(
        'cache','caches','code cache','gpucache','media cache','dawncache',
        'shadercache','grshadercache','graphitedawncache','startupcache','cache2',
        'temp','tmp','logs','log','crashpad','crashdumps','blob_storage'
    ) | ForEach-Object { [void]$names.Add($_) }
    $names
}

function Test-IsDisposableLogPath {
    param([string]$Path, [string]$Root)
    $resolvedPath = Resolve-FullPath $Path
    $resolvedRoot = Resolve-FullPath $Root
    if (-not $resolvedPath -or -not $resolvedRoot) { return $false }
    if (-not $resolvedPath.StartsWith("$resolvedRoot\", [StringComparison]::OrdinalIgnoreCase)) { return $false }
    $relativeDirectory = Split-Path -Parent $resolvedPath
    if (-not $relativeDirectory.StartsWith("$resolvedRoot\", [StringComparison]::OrdinalIgnoreCase)) { return $false }
    $segmentNames = (Split-Path -NoQualifier $relativeDirectory).TrimStart('\').Split('\', [StringSplitOptions]::RemoveEmptyEntries)
    $disposableNames = Get-DisposableDirectoryNames
    foreach ($segment in $segmentNames) {
        if ($disposableNames.Contains($segment)) { return $true }
    }
    $false
}

function Get-DisposableLogCandidates {
    param([string[]]$Roots, [int]$OlderThanDays = 14)
    $cutoff = (Get-Date).AddDays(-$OlderThanDays)
    $candidates = [System.Collections.Generic.List[System.IO.FileInfo]]::new()
    foreach ($root in $Roots) {
        $resolvedRoot = Resolve-FullPath $root
        if (-not $resolvedRoot -or -not (Test-Path -LiteralPath $resolvedRoot -PathType Container)) { continue }
        $files = [System.Collections.Generic.List[System.IO.FileInfo]]::new()
        try {
            $directory = [System.IO.DirectoryInfo]::new($resolvedRoot)
            foreach ($file in $directory.EnumerateFiles('*.log', [System.IO.SearchOption]::AllDirectories)) { $files.Add($file) }
        } catch {
            foreach ($file in (Get-ChildItem -LiteralPath $resolvedRoot -Filter '*.log' -File -Recurse -Force -EA SilentlyContinue)) { $files.Add($file) }
        }
        foreach ($file in $files) {
            if ($file.LastWriteTime -ge $cutoff) { continue }
            if (-not (Test-SafeCleanupTarget -Path $file.FullName -ApprovedRoots @($resolvedRoot) -AllowRoot)) { continue }
            if (-not (Test-IsDisposableLogPath -Path $file.FullName -Root $resolvedRoot)) { continue }
            $candidates.Add($file)
        }
    }
    $candidates
}

function Get-StaleDisposableDirectories {
    param([string[]]$Roots, [int]$OlderThanDays = 45)
    $cutoff = (Get-Date).AddDays(-$OlderThanDays)
    $disposableNames = Get-DisposableDirectoryNames
    $candidates = [System.Collections.Generic.List[System.IO.DirectoryInfo]]::new()
    foreach ($root in $Roots) {
        $resolvedRoot = Resolve-FullPath $root
        if (-not $resolvedRoot -or -not (Test-Path -LiteralPath $resolvedRoot -PathType Container)) { continue }
        foreach ($directory in (Get-ChildItem -LiteralPath $resolvedRoot -Directory -Recurse -Force -EA SilentlyContinue)) {
            if ($directory.LastWriteTime -ge $cutoff) { continue }
            if (-not $disposableNames.Contains($directory.Name)) { continue }
            if (-not (Test-SafeCleanupTarget -Path $directory.FullName -ApprovedRoots @($resolvedRoot))) { continue }
            $candidates.Add($directory)
        }
    }
    $candidates
}

function Get-JunkSweepRoots {
    $set = New-TrackedSet
    foreach ($root in @(
        (Get-EnvPath 'TEMP'),
        (Join-EnvPath 'LOCALAPPDATA' 'Temp'),
        $script:SysLoc.WindowsTemp,
        $script:SysLoc.SoftDistDL,
        $script:SysLoc.DeliveryOpt
    )) {
        $resolved = Resolve-FullPath $root
        if ($resolved) { [void]$set.Add($resolved) }
    }
    @($set)
}

function Get-RunningProcessNames {
    $set = New-TrackedSet
    foreach ($name in (Get-Process -EA SilentlyContinue | Select-Object -ExpandProperty Name -Unique)) {
        [void]$set.Add($name)
    }
    $set
}

function Test-AnyProcessRunning {
    param($RunningProcesses, [string[]]$Names)
    foreach ($name in $Names) {
        if ($RunningProcesses.Contains($name)) { return $true }
    }
    $false
}

function Register-SkippedItem {
    param([string]$Reason, [string]$Target)
    $script:SkippedItems += [PSCustomObject]@{ Reason = $Reason; Target = $Target }
}

function Get-OrphanRiskScore {
    param([string]$Name, [long]$SizeBytes, [int]$DaysStale, [string]$PathSuffix,
          [string[]]$InstalledNames = @(), [string[]]$RunningNames = @())
    $staleness = if ($DaysStale -ge 365) { 40 } elseif ($DaysStale -ge 90) { 30 } elseif ($DaysStale -ge 30) { 15 } else { 0 }
    $sizeMB = $SizeBytes / 1MB
    $sizeScore = if ($sizeMB -ge 500) { 20 } elseif ($sizeMB -ge 200) { 15 } elseif ($sizeMB -ge 50) { 10 } elseif ($sizeMB -ge 1) { 5 } else { 0 }
    $installSignal = 0
    $nameLower = $Name.ToLowerInvariant()
    $foundExact = $false; $foundPartial = $false
    foreach ($n in $InstalledNames) {
        $nl = $n.ToLowerInvariant()
        if ($nl -eq $nameLower) { $foundExact = $true; break }
        if ($nl.Contains($nameLower) -or $nameLower.Contains($nl)) { $foundPartial = $true }
    }
    if (-not $foundExact) {
        foreach ($n in $RunningNames) {
            $nl = $n.ToLowerInvariant()
            if ($nl -eq $nameLower) { $foundExact = $true; break }
            if ($nl.Contains($nameLower) -or $nameLower.Contains($nl)) { $foundPartial = $true }
        }
    }
    $installSignal = if ($foundExact) { -30 } elseif ($foundPartial) { -10 } else { 0 }
    $pathScore = if ($PathSuffix -match 'ProgramData') { 5 } elseif ($PathSuffix -match 'Local') { 3 } else { 0 }
    $total = [Math]::Max(0, $staleness + $sizeScore + $installSignal + $pathScore)
    $level = if ($total -le 15) { 'Low' } elseif ($total -le 40) { 'Medium' } else { 'High' }
    $color = if ($total -le 15) { 'Green' } elseif ($total -le 40) { 'Yellow' } else { 'Red' }
    [PSCustomObject]@{ Score = $total; RiskLevel = $level; Color = $color; Staleness = $staleness; SizeScore = $sizeScore; InstallSig = $installSignal; PathTrust = $pathScore }
}

function Get-HealthScore {
    $now = Get-Date
    if ($script:HealthCache -and ($now -lt $script:HealthCache.Expires)) { return $script:HealthCache.Data }
    $free = Get-FreeSpaceInfo
    $diskPct = [math]::Round(($free.MB / [math]::Max(1, ($free.MB + 1))) * 100)
    $diskScore = if ($diskPct -ge 30) { 30 } elseif ($diskPct -ge 20) { 25 } elseif ($diskPct -ge 10) { 15 } elseif ($diskPct -ge 5) { 5 } else { 0 }
    $tempTotal = 0L
    foreach ($tp in @((Get-EnvPath 'TEMP'), (Join-EnvPath 'LOCALAPPDATA' 'Temp'))) { $tempTotal += Get-DirectorySize $tp }
    $tempMB = $tempTotal / 1MB
    $tempScore = if ($tempMB -lt 500) { 25 } elseif ($tempMB -lt 2000) { 18 } elseif ($tempMB -lt 5000) { 10 } elseif ($tempMB -lt 10000) { 5 } else { 0 }
    $browserScore = 20
    $browserRoots = @(
        (Join-EnvPath 'LOCALAPPDATA' 'Google\Chrome\User Data\Default\Cache'),
        (Join-EnvPath 'LOCALAPPDATA' 'Microsoft\Edge\User Data\Default\Cache'),
        (Join-EnvPath 'LOCALAPPDATA' 'BraveSoftware\Brave-Browser\User Data\Default\Cache')
    )
    $oldestCacheDays = 0
    foreach ($br in $browserRoots) {
        if (Test-Path $br) { $age = ((Get-Date) - (Get-Item $br -EA SilentlyContinue).LastWriteTime).TotalDays; if ($age -gt $oldestCacheDays) { $oldestCacheDays = [int]$age } }
    }
    $browserScore = if ($oldestCacheDays -lt 7) { 20 } elseif ($oldestCacheDays -lt 30) { 14 } elseif ($oldestCacheDays -lt 90) { 8 } else { 0 }
    $orphanScore = 25
    $orphanInfo = $script:LastOrphanRisks
    if ($orphanInfo) {
        $orphanScore = if ($orphanInfo.HighCount -eq 0 -and $orphanInfo.MedCount -lt 3) { 25 }
                    elseif ($orphanInfo.HighCount -le 2 -or $orphanInfo.MedCount -le 5) { 15 }
                    elseif ($orphanInfo.HighCount -le 5 -or $orphanInfo.MedCount -le 10) { 5 }
                    else { 0 }
    }
    $totalScore = $diskScore + $tempScore + $browserScore + $orphanScore
    $grade = if ($totalScore -ge 85) { 'Excellent' } elseif ($totalScore -ge 65) { 'Good' } elseif ($totalScore -ge 40) { 'Fair' } else { 'Needs attention' }
    $gradeColor = if ($totalScore -ge 85) { 'Green' } elseif ($totalScore -ge 65) { 'Cyan' } elseif ($totalScore -ge 40) { 'Yellow' } else { 'Red' }
    $result = [PSCustomObject]@{ Score = $totalScore; Grade = $grade; GradeColor = $gradeColor; DiskScore = $diskScore; TempScore = $tempScore; BrowserScore = $browserScore; OrphanScore = $orphanScore; DiskPct = $diskPct; TempMB = [math]::Round($tempMB); BrowserAge = $oldestCacheDays; OrphanInfo = $orphanInfo }
    $script:HealthCache = @{ Data = $result; Expires = $now.AddSeconds(30) }
    $result
}

function Get-ConsoleWidth {
    try { $w = $Host.UI.RawUI.WindowSize.Width; if($w -lt 60){60}else{$w} } catch {100}
}

function Get-DisplayText { param([string]$Text,[int]$MaxWidth)
    if(!$Text){return ''}
    if($Text.Length -le $MaxWidth){return $Text}
    if($MaxWidth -le 3){return $Text.Substring(0,[Math]::Max(0,$MaxWidth))}
    $Text.Substring(0,$MaxWidth-3)+'...'
}

function Get-PathLabel {
    param([string]$Path)
    $resolved = Resolve-FullPath $Path
    if (-not $resolved) { return $null }
    $leaf = Split-Path -Path $resolved -Leaf
    if ($leaf) { return $leaf }
    $resolved
}

function Format-CompactList {
    param([string[]]$Items,[int]$MaxItems=3)
    $labels = @($Items | Where-Object { $_ } | ForEach-Object { Get-PathLabel $_ } | Where-Object { $_ } | Select-Object -Unique)
    if (-not $labels) { return 'none' }
    $shown = @($labels | Select-Object -First $MaxItems)
    $extra = $labels.Count - $shown.Count
    if ($extra -gt 0) { return ('{0} (+{1} more)' -f ($shown -join ', '), $extra) }
    $shown -join ', '
}

function New-AsciiBar {
    param([int]$Value,[int]$Total,[int]$Width=18)
    if ($Width -lt 1) { $Width = 1 }
    $safeValue = [Math]::Max(0, $Value)
    $safeTotal = [Math]::Max(0, $Total)
    if ($safeTotal -le 0) { return ('[{0}] 0%' -f ('.' * $Width)) }
    if ($safeValue -gt $safeTotal) { $safeValue = $safeTotal }
    $filled = [Math]::Min($Width, [int][Math]::Round(($safeValue / [double]$safeTotal) * $Width))
    $empty  = [Math]::Max(0, $Width - $filled)
    $pct    = [int][Math]::Round(($safeValue / [double]$safeTotal) * 100)
    ('[{0}{1}] {2}%' -f ('#' * $filled), ('.' * $empty), $pct)
}

function Get-SystemLocations {
    $wr = Get-EnvPath 'SystemRoot'
    $pd = Get-EnvPath 'ProgramData'
    $sd = Get-EnvPath 'SystemDrive'
    [PSCustomObject]@{
        WindowsRoot  = $wr
        ProgramData  = $pd
        SystemDrive  = $sd
        WindowsTemp  = $(if($wr){Join-Path $wr 'Temp'})
        WerArchive   = $(if($pd){Join-Path $pd 'Microsoft\Windows\WER\ReportArchive'})
        WerQueue     = $(if($pd){Join-Path $pd 'Microsoft\Windows\WER\ReportQueue'})
        NetDownloader= $(if($pd){Join-Path $pd 'Microsoft\Network\Downloader'})
        SoftDistDL   = $(if($wr){Join-Path $wr 'SoftwareDistribution\Download'})
        Prefetch     = $(if($wr){Join-Path $wr 'Prefetch'})
        DeliveryOpt  = $(if($wr){Join-Path $wr 'SoftwareDistribution\DeliveryOptimization'})
    }
}

function Show-HealthDetail {
    $h = Get-HealthScore
    Clear-Host
    Write-Host ''
    # Will be rendered via UI module; placeholder for Core self-test
    Write-Host "Health Score: $($h.Score)/100 $($h.Grade)" -ForegroundColor $h.GradeColor
    Write-Host "Disk: $($h.DiskScore)/30  Temp: $($h.TempScore)/25  Browser: $($h.BrowserScore)/20  Orphan: $($h.OrphanScore)/25"
    Write-Host ''
}

Export-ModuleMember -Function * -Variable *
```

- [ ] **Step 4: Run Core tests to verify they pass**

Run:
```powershell
$results = Invoke-Pester -Path 'tests/Bakunawa.Core.Tests.ps1' -PassThru
$results.FailedCount | Should -Be 0
```

- [ ] **Step 5: Commit**

```bash
git add Bakunawa.Core.psm1 tests/Bakunawa.Core.Tests.ps1
git commit -m "feat: add Bakunawa core engine module with safety, health, and sizing"
```

---

### Task 3: Bakunawa.Cleanup — Cleanup Task Module

**Files:**
- Create: `Bakunawa.Cleanup.psm1`
- Create: `tests/Bakunawa.Cleanup.Tests.ps1`

This module registers all cleanup tasks, reads app definitions from Config, executes cleanup with parallel runspaces for independent tasks, and collects results.

- [ ] **Step 1: Write failing Cleanup tests**

File: `tests/Bakunawa.Cleanup.Tests.ps1`
```powershell
BeforeAll {
    $modulePath = Join-Path $PSScriptRoot '..' 'Bakunawa.Cleanup.psm1'
    Remove-Module Bakunawa.Cleanup -ErrorAction SilentlyContinue
    Remove-Module Bakunawa.Core -ErrorAction SilentlyContinue
    Import-Module (Join-Path $PSScriptRoot '..' 'Bakunawa.Core.psm1') -Force -Scope Global
    Import-Module $modulePath -Force -Scope Global
    $script:ExcludedPaths = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
}

Describe 'Bakunawa.Cleanup task registry' {
    It 'returns different task counts per mode' {
        $std = Get-CleanupTasks -Mode 'Standard'
        $agg = Get-CleanupTasks -Mode 'Aggressive'
        $std.Count | Should -BeGreaterThan 0
        $agg.Count | Should -BeGreaterThan $std.Count
    }

    It 'includes orphan detection as a task' {
        $tasks = Get-CleanupTasks -Mode 'Standard'
        $orphanTask = $tasks | Where-Object { $_.Name -eq 'Orphan Scan' }
        $orphanTask | Should -Not -BeNullOrEmpty
    }

    It 'includes orphan scan task' {
        $tasks = Get-CleanupTasks -Mode 'Standard'
        $tasks.Name -contains 'Orphan Scan' | Should -Be $true
    }
}
```

- [ ] **Step 2: Run Cleanup tests (expect failures)**

Run:
```powershell
$results = Invoke-Pester -Path 'tests/Bakunawa.Cleanup.Tests.ps1' -PassThru
$results.FailedCount | Should -BeGreaterThan 0
```

- [ ] **Step 3: Implement Bakunawa.Cleanup.psm1**

Write to `Bakunawa.Cleanup.psm1` with these key functions:
- `Get-CleanupTasks` — returns ordered task list per mode
- `Measure-AndClear` — size, clear, track bytes
- `Remove-FilesByPattern` — pattern-based file deletion
- `Clear-SystemCaches` — temp, WER, SoftwareDistribution with service management
- `Clear-ChromiumCaches` — per-browser config-driven
- `Clear-FirefoxCaches` — Firefox profiles
- `Clear-AppCaches` — iterate app-definitions, resolve paths, clean
- `Clear-DevCaches` — developer tool caches
- `Clear-GpuAndShellCaches` — GPU, thumbnail caches
- `Clear-RecycleBinSafe` — Recycle Bin
- `Clear-SystemLogFiles` — log sweep
- `Remove-EmptyDirectories` — cascade empty dir removal
- `Remove-StaleJunkFolders` — stale disposable dirs
- `Find-OrphanFolders` — orphan detection with risk scoring
- `Clear-Prefetch`, `Clear-EventLogs`, `Invoke-ComponentCleanup`, `Clear-FontCache`
- `Invoke-CleanupRun` — orchestrate all steps, collect summary

The key structural change: `Clear-AppCaches` now iterates `Get-AllAppDefinitions` instead of hardcoded paths. Browser caches use `{profile}` wildcards resolved at runtime.

```powershell
# Bakunawa.Cleanup.psm1 — Cleanup task execution

function Get-CleanupTasks {
    param([ValidateSet('Standard','Aggressive')][string]$Mode = 'Standard')
    $tasks = [System.Collections.Generic.List[System.Object]]::new()
    $null = $tasks.Add([PSCustomObject]@{ Name = 'System Caches'; Parallel = $false })
    $null = $tasks.Add([PSCustomObject]@{ Name = 'Browser Caches'; Parallel = $true })
    $null = $tasks.Add([PSCustomObject]@{ Name = 'App Caches'; Parallel = $true })
    $null = $tasks.Add([PSCustomObject]@{ Name = 'Dev Caches'; Parallel = $true })
    $null = $tasks.Add([PSCustomObject]@{ Name = 'GPU/Shell Caches'; Parallel = $false })
    $null = $tasks.Add([PSCustomObject]@{ Name = 'Recycle Bin'; Parallel = $false })
    $null = $tasks.Add([PSCustomObject]@{ Name = 'Log Files'; Parallel = $false })
    $null = $tasks.Add([PSCustomObject]@{ Name = 'Empty/Stale Folders'; Parallel = $false })
    $null = $tasks.Add([PSCustomObject]@{ Name = 'Orphan Scan'; Parallel = $false })
    if ($Mode -eq 'Aggressive') {
        $null = $tasks.Add([PSCustomObject]@{ Name = 'Prefetch'; Parallel = $false })
        $null = $tasks.Add([PSCustomObject]@{ Name = 'DISM'; Parallel = $false })
        $null = $tasks.Add([PSCustomObject]@{ Name = 'Event Logs + Font Cache'; Parallel = $false })
    }
    return @($tasks)
}

function Measure-AndClear {
    param([string]$Path, [switch]$EnsureDirectory, [string]$Category = 'General')
    $resolved = Resolve-FullPath $Path
    if (-not $resolved -or -not (Test-Path -LiteralPath $resolved -PathType Container)) { return $false }
    if (-not (Test-SafeCleanupTarget -Path $resolved)) { return $false }
    $sizeBefore = Get-DirectorySize $resolved
    $verb = if($script:IsPreview){'PREVIEW'}else{'CLEAR'}
    Write-CommandLog $verb $resolved
    if (-not $script:IsPreview) {
        try {
            Get-ChildItem -LiteralPath $resolved -Force -EA SilentlyContinue | ForEach-Object {
                Remove-Item -LiteralPath $_.FullName -Recurse -Force -EA SilentlyContinue -ErrorVariable rmErr
                if ($rmErr) { $script:Errors += [PSCustomObject]@{ Path = $_.FullName; Exception = $rmErr[0].Exception.Message; Category = 'Remove-Item'; Timestamp = Get-Date } }
            }
        } catch {
            $script:Errors += [PSCustomObject]@{ Path = $resolved; Exception = $_.Exception.Message; Category = 'Measure-AndClear'; Timestamp = Get-Date }
        }
        if ($EnsureDirectory -and -not (Test-Path -LiteralPath $resolved)) { New-Item -ItemType Directory -Path $resolved -Force | Out-Null }
        $sizeAfter = Get-DirectorySize $resolved
        $freed = [Math]::Max(0, $sizeBefore - $sizeAfter)
    } else { $freed = $sizeBefore }
    $script:BytesFreed += $freed
    if (-not $script:CategorySizes.ContainsKey($Category)) { $script:CategorySizes[$Category] = [long]0 }
    $script:CategorySizes[$Category] += $freed
    return $true
}

function Remove-FilesByPattern {
    param([string]$Directory, [string[]]$Patterns, [string]$Category='General')
    if (-not (Test-Path -LiteralPath $Directory -PathType Container)) { return 0 }
    $count = 0
    foreach ($pat in $Patterns) {
        $files = [System.Collections.Generic.List[System.IO.FileInfo]]::new()
        try {
            $di = [System.IO.DirectoryInfo]::new($Directory)
            foreach ($f in $di.EnumerateFiles($pat, [System.IO.SearchOption]::AllDirectories)) { $files.Add($f) }
        } catch {
            $files = Get-ChildItem -LiteralPath $Directory -Filter $pat -File -Force -Recurse -EA SilentlyContinue
        }
        foreach ($f in $files) {
            $full = $f.FullName
            if (Test-IsExcludedPath $full) { continue }
            $sz = $f.Length
            Write-CommandLog ($(if($script:IsPreview){'PREVIEW rm'}else{'REMOVE'})) $full
            if (-not $script:IsPreview) {
                Remove-Item -LiteralPath $full -Force -EA SilentlyContinue
                if (-not (Test-Path -LiteralPath $full)) {
                    $script:BytesFreed += $sz
                    if(-not $script:CategorySizes.ContainsKey($Category)){$script:CategorySizes[$Category]=[long]0}
                    $script:CategorySizes[$Category] += $sz
                }
            } else {
                $script:BytesFreed += $sz
                if(-not $script:CategorySizes.ContainsKey($Category)){$script:CategorySizes[$Category]=[long]0}
                $script:CategorySizes[$Category] += $sz
            }
            $count++
        }
    }
    $count
}

function Clear-SystemCaches {
    $cat = 'System Caches'; $n = 0
    foreach ($t in @(
        (Get-EnvPath 'TEMP'), (Join-EnvPath 'LOCALAPPDATA' 'Temp'),
        $script:SysLoc.WindowsTemp, (Join-EnvPath 'LOCALAPPDATA' 'CrashDumps'),
        $script:SysLoc.WerArchive, $script:SysLoc.WerQueue, $script:SysLoc.NetDownloader
    )) { if ($t -and (Measure-AndClear $t -EnsureDirectory -Category $cat)) { $n++ } }
    $restart = @()
    try {
        foreach ($svc in 'wuauserv','bits','dosvc') {
            $s = Get-Service $svc -EA SilentlyContinue
            if ($s -and $s.Status -ne 'Stopped') {
                Write-CommandLog ($(if($script:IsPreview){'PREVIEW stop'}else{'STOP'})) $svc
                if (-not $script:IsPreview) { Stop-Service $svc -Force -EA SilentlyContinue; $restart += $svc }
            }
        }
        if ($script:SysLoc.SoftDistDL -and (Measure-AndClear $script:SysLoc.SoftDistDL -EnsureDirectory -Category $cat)) { $n++ }
        if ($script:SysLoc.DeliveryOpt -and (Measure-AndClear $script:SysLoc.DeliveryOpt -EnsureDirectory -Category $cat)) { $n++ }
    } finally {
        foreach ($svc in $restart) { Write-CommandLog 'START' $svc; Start-Service $svc -EA SilentlyContinue }
    }
    $n
}

function Clear-ChromiumCaches {
    param([string]$UserDataRoot, [string]$Label)
    $cat = 'Browser Caches'; $n = 0
    if (-not (Test-Path -LiteralPath $UserDataRoot -PathType Container)) { return 0 }
    $running = if ($script:RunningProcesses) { $script:RunningProcesses } else { Get-RunningProcessNames }
    $processNames = switch ($Label) { 'Chrome' { @('chrome') } 'Edge' { @('msedge') } 'Brave' { @('brave') } 'Opera' { @('opera') } 'Vivaldi'{ @('vivaldi') } default { @() } }
    if ($processNames.Count -gt 0 -and (Test-AnyProcessRunning -RunningProcesses $running -Names $processNames)) {
        Register-SkippedItem -Reason 'close the browser for a deeper cache cleanup' -Target $Label
        return 0
    }
    $cacheDirs = @('Cache','Code Cache','GPUCache','Media Cache','DawnCache','ShaderCache','GrShaderCache','GraphiteDawnCache','DawnWebGPUCache','Local Storage')
    foreach ($prof in (Get-ChildItem $UserDataRoot -Directory -Force -EA SilentlyContinue)) {
        $hit = $false
        foreach ($cd in $cacheDirs) { $t = Join-Path $prof.FullName $cd; if (Test-Path -LiteralPath $t) { [void](Measure-AndClear $t -EnsureDirectory -Category $cat); $hit=$true } }
        foreach ($extra in @((Join-Path $prof.FullName 'Service Worker\CacheStorage'),(Join-Path $prof.FullName 'Service Worker\ScriptCache'),(Join-Path $prof.FullName 'Crashpad'),(Join-Path $prof.FullName 'blob_storage'))) {
            if (Test-Path -LiteralPath $extra) { [void](Measure-AndClear $extra -EnsureDirectory -Category $cat); $hit=$true }
        }
        if ($hit) { $n++ }
    }
    $n
}

function Clear-FirefoxCaches {
    $cat = 'Browser Caches'; $n = 0
    $root = Join-EnvPath 'LOCALAPPDATA' 'Mozilla\Firefox\Profiles'
    if (-not (Test-Path -LiteralPath $root -PathType Container)) { return 0 }
    $running = if ($script:RunningProcesses) { $script:RunningProcesses } else { Get-RunningProcessNames }
    if (Test-AnyProcessRunning -RunningProcesses $running -Names @('firefox')) {
        Register-SkippedItem -Reason 'close Firefox for a deeper cache cleanup' -Target 'Firefox'
        return 0
    }
    foreach ($p in (Get-ChildItem $root -Directory -Force -EA SilentlyContinue)) {
        $hit = $false
        foreach ($t in @('cache2','startupCache','thumbnails','shader-cache','OfflineCache')) {
            $fp = Join-Path $p.FullName $t
            if (Test-Path -LiteralPath $fp) { [void](Measure-AndClear $fp -EnsureDirectory -Category $cat); $hit=$true }
        }
        if ($hit) { $n++ }
    }
    $n
}

function Clear-AppCaches {
    $cat = 'App Caches'; $n = 0
    $running = if ($script:RunningProcesses) { $script:RunningProcesses } else { Get-RunningProcessNames }
    # Load app definitions from messaging + devtools (browsers handled separately)
    $appDefs = Get-AppDefinitions -Category 'messaging'
    $appDefs += Get-AppDefinitions -Category 'devtools' | Where-Object { @('npm-cache','pnpm-cache','pip-cache','uv-cache','NuGet-cache','Composer-cache','Yarn-cache','Cargo-cache','Bun-cache','Dart-pub-cache','Docker-tmp','Prisma-engines','checkpoint-nodejs','firebase-heartbeat','dotnet-telemetry','JetBrains') -contains $_.name }
    foreach ($app in $appDefs) {
        $procName = $app.process
        if ($procName -and (Test-AnyProcessRunning -RunningProcesses $running -Names @($procName))) {
            Register-SkippedItem -Reason "close $($app.name) before clearing caches" -Target $app.name
            continue
        }
        $hit = $false
        foreach ($loc in $app.locations) {
            $path = Resolve-EnvTemplate -EnvVar $loc.env -SubPath $loc.path
            if ($path -and (Measure-AndClear $path -EnsureDirectory -Category $cat)) { $hit = $true }
        }
        if ($hit) { $n++ }
    }
    return $n
}

function Clear-DevCaches {
    $cat = 'Dev Tool Caches'; $n = 0
    # Load devtool definitions (non-app items like npm, pnpm, etc.)
    $devDefs = Get-AppDefinitions -Category 'devtools' | Where-Object { @('Go-mod-cache','Playwright') -contains $_.name }
    foreach ($def in $devDefs) {
        if ($def.name -eq 'Go-mod-cache') {
            $go = Join-EnvPath 'USERPROFILE' 'go\pkg\mod'
            if ($go -and (Test-Path $go)) {
                $goSize = Get-DirectorySize $go
                if ($goSize -gt 0) { Write-Log "Go module cache: $(Format-FileSize $goSize) - SKIPPED (run 'go clean -modcache' to remove safely)" 'WARN' }
            }
        }
    }
    # Playwright is warned, not cleaned
    $pw = Join-EnvPath 'LOCALAPPDATA' 'ms-playwright'
    if ($pw -and (Test-Path $pw)) {
        $pwSize = Get-DirectorySize $pw
        if ($pwSize -gt 0) { Write-Log "Playwright browsers: $(Format-FileSize $pwSize) - SKIPPED (run 'npx playwright install' to reinstall)" 'WARN' }
    }
    $n
}

function Clear-GpuAndShellCaches {
    $cat = 'GPU/Shell Caches'; $n = 0
    foreach ($t in @(
        (Join-EnvPath 'LOCALAPPDATA' 'D3DSCache'), (Join-EnvPath 'LOCALAPPDATA' 'NVIDIA\DXCache'),
        (Join-EnvPath 'LOCALAPPDATA' 'NVIDIA\GLCache'), (Join-EnvPath 'LOCALAPPDATA' 'AMD\DxCache'),
        (Join-EnvPath 'LOCALAPPDATA' 'Intel\ShaderCache'), (Join-EnvPath 'LOCALAPPDATA' 'CEF\Cache')
    )) { if ($t -and (Measure-AndClear $t -EnsureDirectory -Category $cat)) { $n++ } }
    $exRoot = Join-EnvPath 'LOCALAPPDATA' 'Microsoft\Windows\Explorer'
    if (Test-Path -LiteralPath $exRoot) {
        $files = Get-ChildItem $exRoot -File -Force -EA SilentlyContinue | Where-Object { $_.Name -like 'thumbcache_*.db' -or $_.Name -like 'iconcache_*.db' }
        if ($files) {
            $wasRunning = $false
            try {
                if (-not $script:IsPreview) { $wasRunning = @(Get-Process explorer -EA SilentlyContinue).Count -gt 0; if ($wasRunning) { Write-CommandLog 'STOP' 'explorer.exe'; Stop-Process -Name explorer -Force -EA SilentlyContinue; Start-Sleep -Milliseconds 500 } }
                foreach ($f in $files) {
                    $sz = $f.Length
                    Write-CommandLog ($(if($script:IsPreview){'PREVIEW rm'}else{'REMOVE'})) $f.FullName
                    if (-not $script:IsPreview) { Remove-Item -LiteralPath $f.FullName -Force -EA SilentlyContinue; $script:BytesFreed += $sz }
                    if(-not $script:CategorySizes.ContainsKey($cat)){$script:CategorySizes[$cat]=[long]0}
                    $script:CategorySizes[$cat] += $sz
                }
            } finally { if (-not $script:IsPreview -and $wasRunning) { Write-CommandLog 'START' 'explorer.exe'; Start-Process explorer.exe } }
            $n++
        }
    }
    $n
}

function Clear-RecycleBinSafe {
    Write-CommandLog ($(if($script:IsPreview){'PREVIEW'}else{'CLEAR'})) 'Recycle Bin'
    if (-not $script:IsPreview) { Clear-RecycleBin -Force -EA SilentlyContinue }
    $true
}

function Clear-SystemLogFiles {
    $cat = 'Log Files'; $count = 0
    $roots = @((Get-EnvPath 'LOCALAPPDATA'), (Get-EnvPath 'APPDATA'), $script:SysLoc.ProgramData)
    $logFiles = Get-DisposableLogCandidates -Roots $roots -OlderThanDays 14 | Sort-Object LastWriteTime | Select-Object -First 400
    foreach ($file in $logFiles) {
        $sz = $file.Length
        Write-CommandLog ($(if($script:IsPreview){'PREVIEW rm'}else{'REMOVE'})) $file.FullName
        if (-not $script:IsPreview) {
            Remove-Item -LiteralPath $file.FullName -Force -EA SilentlyContinue
            if (-not (Test-Path -LiteralPath $file.FullName)) { $script:BytesFreed += $sz; if(-not $script:CategorySizes.ContainsKey($cat)){$script:CategorySizes[$cat]=[long]0}; $script:CategorySizes[$cat] += $sz }
        } else { $script:BytesFreed += $sz; if(-not $script:CategorySizes.ContainsKey($cat)){$script:CategorySizes[$cat]=[long]0}; $script:CategorySizes[$cat] += $sz }
        $count++
    }
    $count
}

function Remove-EmptyDirectories {
    param([string[]]$Roots)
    $removed = 0
    foreach ($root in $Roots) {
        if (-not (Test-Path -LiteralPath $root -PathType Container)) { continue }
        Get-ChildItem $root -Directory -Recurse -Force -EA SilentlyContinue | Sort-Object FullName -Descending | ForEach-Object {
            if (Test-IsExcludedPath $_.FullName) { return }
            $has = Get-ChildItem -LiteralPath $_.FullName -Force -EA SilentlyContinue | Select-Object -First 1
            if (-not $has) {
                Write-CommandLog ($(if($script:IsPreview){'PREVIEW rm-empty'}else{'RM-EMPTY'})) $_.FullName
                if (-not $script:IsPreview) { Remove-Item -LiteralPath $_.FullName -Force -EA SilentlyContinue }
                $removed++
            }
        }
    }
    $removed
}

function Remove-StaleJunkFolders {
    param([string[]]$Roots,[int]$OlderThanDays=45)
    $removed = 0
    foreach ($directory in (Get-StaleDisposableDirectories -Roots $Roots -OlderThanDays $OlderThanDays | Sort-Object FullName -Descending)) {
        Write-CommandLog ($(if($script:IsPreview){'PREVIEW rm-stale'}else{'RM-STALE'})) $directory.FullName
        if (-not $script:IsPreview) { Remove-Item -LiteralPath $directory.FullName -Recurse -Force -EA SilentlyContinue }
        $removed++
    }
    $removed
}

function Find-OrphanFolders {
    param([switch]$InteractiveDelete)
    $cat = 'Orphan Cleanup'; $found = 0
    $script:OrphanReport = @()
    $installedNames = New-TrackedSet
    $regPaths = @('HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*','HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*','HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*')
    foreach ($rp in $regPaths) {
        Get-ItemProperty $rp -EA SilentlyContinue | ForEach-Object {
            if ($_.DisplayName) { [void]$installedNames.Add($_.DisplayName.Trim()) }
            if ($_.InstallLocation) { $leaf = [IO.Path]::GetFileName($_.InstallLocation.TrimEnd('\')); if ($leaf) { [void]$installedNames.Add($leaf) } }
        }
    }
    $running = Get-Process -EA SilentlyContinue | Select-Object -ExpandProperty Name -Unique
    foreach ($r in $running) { [void]$installedNames.Add($r) }
    $safeNames = New-TrackedSet
    @('Microsoft','Google','Mozilla','Windows','Common Files','Reference Assemblies','dotnet','MSBuild','WindowsPowerShell','Packages','assembly','Programs','cache','ConnectedDevicesPlatform','IdentityNexusIntegration','IsolatedStorage','ProductData','Publishers','speech','Temp','node','npm','pip','Sentry','ServiceHub','Package Cache','NuGet','aws','gcloud','uv','pnpm-cache','npm-cache','pnpm-state','PlaceholderTileLogoFolder','Comms','firebase-heartbeat','cloud-code','github-copilot','prisma-nodejs','checkpoint-nodejs','ms-playwright','GitHub','Slack','Teams','Discord','Spotify','Telegram Desktop','Notion','Figma','Zoom','Viber','Adobe','obs-studio','qBittorrent','draw.io','Stremio','Docker','Canva','Postman','Insomnia','1Password','Bitwarden','Signal','Sublime Text','GitHubDesktop','OpenVPN','Tailscale','Cloudflare','MongoDBCompass','Tableau','PyCharm','IntelliJ','Rider','WebStorm','Goland','CLion','DataGrip','RubyMine','AppCode','PhpStorm'
    ) | ForEach-Object { [void]$safeNames.Add($_) }
    foreach ($baseEnv in @('LOCALAPPDATA','APPDATA')) {
        $base = Get-EnvPath $baseEnv
        if (-not $base -or -not (Test-Path $base)) { continue }
        Get-ChildItem $base -Directory -Force -EA SilentlyContinue | ForEach-Object {
            $name = $_.Name
            if ($safeNames.Contains($name)) { return }
            if ($installedNames.Contains($name)) { return }
            $lastWrite = $_.LastWriteTime; $daysSince = ((Get-Date) - $lastWrite).TotalDays
            if ($daysSince -lt 30) { return }
            $dirSize = Get-DirectorySize $_.FullName
            $baseEnvLabel = if ($baseEnv -eq 'LOCALAPPDATA') { 'Local' } else { 'Roaming' }
            $risk = Get-OrphanRiskScore -Name $name -SizeBytes $dirSize -DaysStale $daysSince -PathSuffix $baseEnvLabel -InstalledNames @($installedNames) -RunningNames $running
            $entry = [PSCustomObject]@{ Path = $_.FullName; Name = $name; Size = $dirSize; SizeText = Format-FileSize $dirSize; DaysStale = [int]$daysSince; RiskScore = $risk.Score; RiskLevel = $risk.RiskLevel; RiskColor = $risk.Color }
            $script:OrphanReport += $entry
            Write-Log "ORPHAN? [$($risk.RiskLevel.ToUpper().Substring(0,4))] $name ($(Format-FileSize $dirSize), $([int]$daysSince)d stale)" 'WARN'
            $found++
        }
    }
    $highC = 0; $medC = 0; $lowC = 0
    foreach ($e in $script:OrphanReport) { if ($e.RiskLevel -eq 'High') { $highC++ } elseif ($e.RiskLevel -eq 'Medium') { $medC++ } else { $lowC++ } }
    $script:LastOrphanRisks = [PSCustomObject]@{ Count = $found; HighCount = $highC; MedCount = $medC; LowCount = $lowC }
    $script:OrphanReport = $script:OrphanReport | Sort-Object RiskScore -Descending
    if ($found -eq 0) {
        Write-Log 'No obvious orphan folders detected.' 'OK'
    } else {
        Write-Log "$found potential orphan folder(s) found. ($highC high, $medC medium, $lowC low risk)" 'WARN'
        if ($InteractiveDelete -and -not $script:IsPreview) {
            $deleteAll = $false; $deletedCount = 0
            foreach ($o in $script:OrphanReport) {
                $badge = "[$($o.RiskLevel.ToUpper().Substring(0,4))]"
                if (-not $deleteAll) {
                    $ans = (Read-Host "Delete $badge '$($o.Name)' at $($o.Path)? (y/n/a/q) [n]").Trim().ToLowerInvariant()
                    if ($ans -eq 'q') { break }
                    if ($ans -eq 'a') { $deleteAll = $true }
                    if ($ans -ne 'y' -and $ans -ne 'a') { continue }
                }
                Remove-Item -LiteralPath $o.Path -Recurse -Force -EA SilentlyContinue
                $deletedCount++; $script:BytesFreed += $o.Size
                if (-not $script:CategorySizes.ContainsKey($cat)) { $script:CategorySizes[$cat] = [long]0 }
                $script:CategorySizes[$cat] += $o.Size
            }
            Write-Log "Deleted $deletedCount orphan folder(s)." $(if($deletedCount -gt 0){'OK'}else{'INFO'})
        }
    }
    $found
}

function Invoke-ComponentCleanup {
    Write-CommandLog 'RUN' 'Dism.exe /online /Cleanup-Image /StartComponentCleanup'
    if ($script:IsPreview) { return $true }
    & Dism.exe /online /Cleanup-Image /StartComponentCleanup | Out-Null
    $LASTEXITCODE -eq 0
}

function Clear-EventLogs {
    $cleared = 0
    $logs = & wevtutil.exe el
    foreach ($l in $logs) {
        Write-CommandLog ($(if($script:IsPreview){'PREVIEW cl'}else{'CLEAR-LOG'})) $l
        if (-not $script:IsPreview) { & wevtutil.exe cl $l; if($LASTEXITCODE -eq 0){$cleared++} }
        else { $cleared++ }
    }
    $cleared
}

function Clear-Prefetch {
    $cat = 'Aggressive Extras'
    $pf = $script:SysLoc.Prefetch
    if ($pf -and (Test-Path $pf)) { $c = Remove-FilesByPattern $pf @('*.pf') -Category $cat; Write-Log "Removed $c prefetch files" }
}

function Clear-FontCache {
    $fontPath = Join-Path $script:SysLoc.WindowsRoot 'ServiceProfiles\LocalService\AppData\Local\FontCache'
    if (Test-Path -LiteralPath $fontPath) {
        Write-CommandLog ($(if($script:IsPreview){'PREVIEW'}else{'CLEAR'})) 'Font Cache'
        $wasRunning = $false
        try {
            $svc = Get-Service FontCache -EA SilentlyContinue
            if ($svc -and $svc.Status -ne 'Stopped') {
                if (-not $script:IsPreview) { Write-CommandLog 'STOP' 'FontCache'; Stop-Service FontCache -Force -EA SilentlyContinue; $wasRunning = $true }
            }
            if (-not $script:IsPreview) { Get-ChildItem $fontPath -Force -EA SilentlyContinue | ForEach-Object { Remove-Item $_.FullName -Force -EA SilentlyContinue } }
        } finally { if ($wasRunning -and -not $script:IsPreview) { Write-CommandLog 'START' 'FontCache'; Start-Service FontCache -EA SilentlyContinue } }
    }
}

function Invoke-CleanupRun {
    param([ValidateSet('Standard','Aggressive','Preview')][string]$SelectedMode)
    $script:IsPreview = $SelectedMode -eq 'Preview'
    $script:IsAggressive = $SelectedMode -eq 'Aggressive'
    $script:CurrentModeName = $SelectedMode
    $script:StepIndex = 0
    $script:TotalSteps = 9 + $(if($script:IsAggressive){3}else{0})
    $script:BytesFreed = [long]0; $script:CategorySizes = @{}; $script:OrphanReport = @(); $script:SkippedItems = @(); $script:Errors = @()
    $script:RunningProcesses = Get-RunningProcessNames
    $start = Get-Date; $startSpace = Get-FreeSpaceInfo; $junkRoots = Get-JunkSweepRoots | Where-Object { Test-Path -LiteralPath $_ -PathType Container }
    Show-Header
    Write-Log "Mode: $SelectedMode"; Write-Log "Started: $($start.ToString('yyyy-MM-dd HH:mm:ss'))"; Write-Log "Initial free: $($startSpace.MB) MB ($($startSpace.GB) GB)"
    Start-Step 'System temp, update, crash, delivery caches'; $s1 = Clear-SystemCaches; Finish-Step "$s1 locations processed"
    Start-Step 'Chromium browser caches (Chrome, Edge, Brave, Opera, Vivaldi)'; $s2 = 0
    $s2 += Clear-ChromiumCaches (Join-EnvPath 'LOCALAPPDATA' 'Google\Chrome\User Data') 'Chrome'
    $s2 += Clear-ChromiumCaches (Join-EnvPath 'LOCALAPPDATA' 'Microsoft\Edge\User Data') 'Edge'
    $s2 += Clear-ChromiumCaches (Join-EnvPath 'LOCALAPPDATA' 'BraveSoftware\Brave-Browser\User Data') 'Brave'
    $s2 += Clear-ChromiumCaches (Join-EnvPath 'APPDATA' 'Opera Software\Opera Stable') 'Opera'
    $s2 += Clear-ChromiumCaches (Join-EnvPath 'LOCALAPPDATA' 'Vivaldi\User Data') 'Vivaldi'
    Finish-Step "$s2 browser profiles cleaned"
    Start-Step 'Firefox caches'; $s3 = Clear-FirefoxCaches; Finish-Step "$s3 Firefox profiles cleaned"
    Start-Step 'Application caches (Discord, Slack, Teams, etc.)'; $s4 = Clear-AppCaches; Finish-Step "$s4 app locations cleaned"
    Start-Step 'Developer tool caches (npm, pip, NuGet, etc.)'; $s5 = Clear-DevCaches; Finish-Step "$s5 dev cache locations cleaned"
    Start-Step 'GPU, thumbnail, and icon caches'; $s6 = Clear-GpuAndShellCaches; Finish-Step "$s6 cache locations cleaned"
    Start-Step 'Recycle Bin'; [void](Clear-RecycleBinSafe); Finish-Step 'Recycle Bin emptied'
    Start-Step 'Old log files (14+ days)'; $s8 = Clear-SystemLogFiles; Finish-Step "$s8 log files cleaned"
    Start-Step 'Empty and stale junk folders'; $emptyRm = Remove-EmptyDirectories -Roots $junkRoots; $staleRm = Remove-StaleJunkFolders -Roots $junkRoots; Finish-Step "$emptyRm empty, $staleRm stale folders removed"
    Start-Step 'Orphan folder scan'; $orphans = Find-OrphanFolders; Finish-Step "$orphans potential orphans detected"
    if ($script:IsAggressive) {
        Start-Step 'Prefetch cleanup'; Clear-Prefetch; Finish-Step 'Prefetch cleaned'
        Start-Step 'Component store cleanup (DISM)'; [void](Invoke-ComponentCleanup); Finish-Step 'DISM cleanup finished'
        Start-Step 'Event logs + Font cache'; $logsCl = Clear-EventLogs; Clear-FontCache; Finish-Step "$logsCl event logs cleared, font cache cleaned"
    }
    $finish = Get-Date; $endSpace = Get-FreeSpaceInfo; $freedMB = $endSpace.MB - $startSpace.MB; $freedGB = [math]::Round($freedMB / 1024, 2); $dur = [math]::Round(($finish - $start).TotalSeconds, 1)
    $script:LastRunSummary = [PSCustomObject]@{ Mode = $SelectedMode; FinishedAt = $finish; DurationSeconds = $dur; TotalFreed = [Math]::Max(0, $script:BytesFreed); FreedMB = $freedMB; FreedGB = $freedGB }
    Show-RunSummary -Mode $SelectedMode -Duration $dur -StartSpace $startSpace -EndSpace $endSpace `
        -Steps @{s1=$s1;s2=$s2;s3=$s3;s4=$s4;s5=$s5;s6=$s6;s8=$s8;emptyRm=$emptyRm;staleRm=$staleRm;orphans=$orphans} `
        -Aggressive:$script:IsAggressive -LogsCl $logsCl
    if ($script:Errors.Count -gt 0) {
        Write-Host ''; Write-SectionHeader 'Errors'
        $script:Errors | Group-Object Category | Sort-Object Count -Descending | ForEach-Object {
            Write-Host ("  {0,2}x {1}" -f $_.Count, $_.Name) -ForegroundColor Red
        }
    }
}

Export-ModuleMember -Function Get-CleanupTasks, Measure-AndClear, Remove-FilesByPattern, Clear-SystemCaches, Clear-ChromiumCaches, Clear-FirefoxCaches, Clear-AppCaches, Clear-DevCaches, Clear-GpuAndShellCaches, Clear-RecycleBinSafe, Clear-SystemLogFiles, Remove-EmptyDirectories, Remove-StaleJunkFolders, Find-OrphanFolders, Invoke-ComponentCleanup, Clear-EventLogs, Clear-Prefetch, Clear-FontCache, Invoke-CleanupRun
```

- [ ] **Step 4: Run Cleanup tests to verify they pass**

Run:
```powershell
$results = Invoke-Pester -Path 'tests/Bakunawa.Cleanup.Tests.ps1' -PassThru
$results.FailedCount | Should -Be 0
```

- [ ] **Step 5: Commit**

```bash
git add Bakunawa.Cleanup.psm1 tests/Bakunawa.Cleanup.Tests.ps1
git commit -m "feat: add Bakunawa cleanup module with config-driven app tasks"
```

---

### Task 4: Bakunawa.UI — Terminal UI Module

**Files:**
- Create: `Bakunawa.UI.psm1`
- Create: `tests/Bakunawa.UI.Tests.ps1`

UI module provides all terminal rendering: VT100 detection and sequences, ASCII fallback, header, menu, log output, step progression, and the run summary panel.

- [ ] **Step 1: Write failing UI tests**

File: `tests/Bakunawa.UI.Tests.ps1`
```powershell
BeforeAll {
    $modulePath = Join-Path $PSScriptRoot '..' 'Bakunawa.UI.psm1'
    Remove-Module Bakunawa.UI -ErrorAction SilentlyContinue
    Import-Module $modulePath -Force -Scope Global
}

Describe 'Bakunawa.UI mode colors' {
    It 'returns expected color for each mode' {
        Get-ModeColor 'Standard'   | Should -Be 'Green'
        Get-ModeColor 'Aggressive' | Should -Be 'Yellow'
        Get-ModeColor 'Preview'    | Should -Be 'DarkGray'
        Get-ModeColor 'Menu'       | Should -Be 'DarkCyan'
        Get-ModeColor 'Unknown'    | Should -Be 'DarkCyan'
    }
}

Describe 'Bakunawa.UI VT100 detection' {
    It 'detects VT100 support without crashing' {
        $result = Test-VT100Supported
        $result | Should -BeOfType System.Boolean
    }
}

Describe 'Bakunawa.UI logging' {
    It 'writes log entries without crashing' {
        { Write-Log 'Test message' 'INFO' } | Should -Not -Throw
        { Write-Log 'Test ok' 'OK' } | Should -Not -Throw
        { Write-Log 'Test warn' 'WARN' } | Should -Not -Throw
    }
}
```

- [ ] **Step 2: Run UI tests (expect failures)**

Run:
```powershell
$results = Invoke-Pester -Path 'tests/Bakunawa.UI.Tests.ps1' -PassThru
$results.FailedCount | Should -BeGreaterThan 0
```

- [ ] **Step 3: Implement Bakunawa.UI.psm1**

Write to `Bakunawa.UI.psm1`:
```powershell
# Bakunawa.UI.psm1 — Terminal rendering engine

function Test-VT100Supported {
    try { return $Host.UI.SupportsVirtualTerminal } catch { return $false }
}

function Get-ModeColor {
    param([string]$Mode)
    switch ($Mode) {
        'Standard'   { 'Green' }
        'Aggressive' { 'Yellow' }
        'Preview'    { 'DarkGray' }
        default      { 'DarkCyan' }
    }
}

function Write-Log {
    param([string]$Message, [ValidateSet('INFO','OK','WARN','ERR','CMD','STEP','SIZE')][string]$Level='INFO')
    $ts = Get-Date -Format 'HH:mm:ss'
    $prefix, $color = switch($Level) {
        'OK'   { ' [+] ', 'Green' }
        'WARN' { ' [!] ', 'Yellow' }
        'ERR'  { ' [X] ', 'Red' }
        'CMD'  { ' > ', 'DarkGray' }
        'STEP' { ' >> ', 'Cyan' }
        'SIZE' { ' vv ', 'Magenta' }
        default{ ' [i] ', 'Gray' }
    }
    Write-Host "[$ts]$prefix $Message" -ForegroundColor $color
    if ($script:LogFilePath) {
        $line = "[$ts][$Level] $Message"
        try { Add-Content -LiteralPath $script:LogFilePath -Value $line -Encoding UTF8 -EA SilentlyContinue } catch {}
    }
}

function Write-CommandLog {
    param([string]$Verb,[string]$Target)
    if ([string]::IsNullOrWhiteSpace($Target)) { Write-Log $Verb 'CMD'; return }
    Write-Log "$Verb $Target" 'CMD'
}

function Write-CenteredLine {
    param([string]$Text,[string]$ForegroundColor='White')
    $cw = Get-ConsoleWidth
    $rt = Get-DisplayText $Text $cw
    $pad = [Math]::Max(0,[int](($cw-$rt.Length)/2))
    Write-Host ((' '*$pad)+$rt) -ForegroundColor $ForegroundColor
}

function Write-SectionHeader {
    param([string]$Title,[string]$ForegroundColor='Cyan')
    $cw = Get-ConsoleWidth
    $useVT = Test-VT100Supported
    if ($useVT) {
        $line = "─" * [Math]::Max(0, $cw - 4)
        Write-Host "┌─ $Title $line" -ForegroundColor $ForegroundColor
    } else {
        $prefix = "-- $Title "
        $line = $prefix + ('-' * [Math]::Max(0, $cw - $prefix.Length))
        Write-Host (Get-DisplayText $line $cw) -ForegroundColor $ForegroundColor
    }
}

function Write-Panel {
    param([string[]]$Lines,[string]$BorderColor='DarkCyan',[string]$TextColor='White',[int]$MinWidth=60,[int]$MaxWidth=92)
    $cw = Get-ConsoleWidth; $aw = [Math]::Max(20,$cw-4); $mxl=0
    foreach($l in $Lines){if($l.Length -gt $mxl){$mxl=$l.Length}}
    $pw = [Math]::Min($aw,[Math]::Max($MinWidth,$mxl+4))
    $pw = [Math]::Min($pw,$MaxWidth); $pw = [Math]::Min($pw,$cw)
    $iw = [Math]::Max(1,$pw-4); $pad = [Math]::Max(0,[int](($cw-$pw)/2))
    $lp = ' '*$pad
    $useVT = Test-VT100Supported
    if ($useVT) {
        Write-Host ($lp+"╔"+("═"*($pw-2))+"╗") -ForegroundColor $BorderColor
        foreach($l in $Lines){
            $rl = (Get-DisplayText $l $iw).PadRight($iw)
            Write-Host ($lp+"║ "+$rl+" ║") -ForegroundColor $TextColor
        }
        Write-Host ($lp+"╚"+("═"*($pw-2))+"╝") -ForegroundColor $BorderColor
    } else {
        Write-Host ($lp+'+'+('-'*($pw-2))+'+') -ForegroundColor $BorderColor
        foreach($l in $Lines){
            $rl = (Get-DisplayText $l $iw).PadRight($iw)
            Write-Host ($lp+'| '+$rl+' |') -ForegroundColor $TextColor
        }
        Write-Host ($lp+'+'+('-'*($pw-2))+'+') -ForegroundColor $BorderColor
    }
}

function Show-AppLogo {
    $logo = @(
        ' .------------------------------------------------------------. '
        ' |   ____        _           _                                | '
        ' |  |  _ \      | |         | |                               | '
        ' |  | |_) | __ _| | ____ _  | |__   __ _ _ __  _   _ ___      | '
        ' |  |  _ < / _` | |/ / _` | | `_ \ / _` | `_ \| | | / __|     | '
        ' |  | |_) | (_| |   < (_| | | |_) | (_| | |_) | |_| \__ \     | '
        ' |  |____/ \__,_|_|\_\__,_| |_.__/ \__,_| .__/ \__,_|___/     | '
        ' |                                       | |                  | '
        ' |    B A K U N A W A   v3              |_|   Devour Waste    | '
        ' `------------------------------------------------------------` '
    )
    $colors = @('DarkCyan','Cyan','Cyan','White','Cyan','DarkCyan')
    for ($index = 0; $index -lt $logo.Count; $index++) {
        $color = $colors[[Math]::Min($index, $colors.Count - 1)]
        Write-CenteredLine $logo[$index] $color
    }
    Write-CenteredLine '🐍 Bakunawa — Devour Your Digital Waste' 'DarkGray'
}

function Start-Step {
    param([string]$Name)
    $script:StepIndex++
    Write-Host ''
    $stepTag = if ($script:TotalSteps -gt 0) { '[{0:D2}/{1:D2}]' -f $script:StepIndex, $script:TotalSteps } else { '[--/--]' }
    $stepBar = New-AsciiBar -Value $script:StepIndex -Total $script:TotalSteps -Width 12
    Write-Log "$stepTag $stepBar $Name" 'STEP'
    if ($script:TotalSteps -gt 0) {
        $pct = [Math]::Max(1,[int](($script:StepIndex / $script:TotalSteps) * 100))
        $script:ActiveStepName = $Name; $script:ActiveStepPct = $pct; $script:LastUiMs = -999999
        Update-UiTicker
    }
}

function Finish-Step {
    param([string]$Summary)
    Write-Log $Summary 'OK'
    $script:ActiveStepName = $null
    if ($script:StepIndex -ge $script:TotalSteps -and $script:TotalSteps -gt 0) {
        Write-Progress -Activity 'Bakunawa devours digital waste...' -Completed -Id 1
        $Host.UI.RawUI.WindowTitle = 'Bakunawa v3 — Sweep Complete'
    }
}

function Update-UiTicker {
    param([string]$CurrentOperation)
    if (-not $script:ActiveStepName -or $script:TotalSteps -le 0) { return }
    $frame = $script:SpinnerFrames[$script:SpinnerIndex % $script:SpinnerFrames.Count]
    $script:SpinnerIndex++
    $op = if ([string]::IsNullOrWhiteSpace($CurrentOperation)) { $script:ActiveStepName } else { $CurrentOperation }
    $bar = New-AsciiBar -Value $script:StepIndex -Total $script:TotalSteps -Width 10
    $status = "[${frame}] $bar $op"
    Write-Progress -Activity 'Bakunawa devouring digital waste...' -Status $status -PercentComplete $script:ActiveStepPct -Id 1
    $Host.UI.RawUI.WindowTitle = "Bakunawa v3 $frame $($script:StepIndex)/$($script:TotalSteps) $($script:ActiveStepName)"
}

function Show-Header {
    Clear-Host; Write-Host ''; Show-AppLogo; Write-Host ''
    $modeColor = Get-ModeColor $script:CurrentModeName
    $free = Get-FreeSpaceInfo
    $ml = if($script:CurrentModeName -eq 'Menu'){'INTERACTIVE'}else{$script:CurrentModeName.ToUpperInvariant()}
    $lr = if($script:LastRunSummary){"$($script:LastRunSummary.Mode) | $($script:LastRunSummary.DurationSeconds)s | $(Format-FileSize $script:LastRunSummary.TotalFreed)"}else{'none yet'}
    $protected = Format-CompactList -Items ($script:ExcludedPaths | Sort-Object) -MaxItems 3
    $runBar = if($script:CurrentModeName -eq 'Menu'){'[..................] idle'}else{New-AsciiBar -Value $script:StepIndex -Total $script:TotalSteps -Width 18}
    $healthLine = 'Health     : not available'
    try {
        $h = Get-HealthScore
        $barChar = if (Test-VT100Supported) { [char]0x2588 } else { '#' }
        $filled = [math]::Floor($h.Score / 10)
        $hb = "$($barChar.ToString() * $filled)$('.' * (10 - $filled))"
        $healthLine = "Health     : $hb $($h.Score)/100 $($h.Grade)"
    } catch {}
    Write-Panel @(
        "Mode       : $ml"
        "Free       : $($free.MB) MB ($($free.GB) GB)"
        "Protected  : $protected"
        $healthLine
        "Last run   : $lr"
        "Run bar    : $runBar"
    ) -BorderColor $modeColor -TextColor 'White' -MinWidth 62 -MaxWidth 92
    Write-Host ''
}

function Show-Menu {
    while ($true) {
        $script:CurrentModeName = 'Menu'
        Show-Header
        $runningApps = @()
        if ($script:RunningProcesses) {
            $checkNames = @('chrome','msedge','brave','firefox','discord','slack','teams','spotify','Code')
            $runningApps = $checkNames | Where-Object { $script:RunningProcesses.Contains($_) } | ForEach-Object {
                $label = switch ($_) {
                    'chrome' { 'Chrome' }; 'msedge' { 'Edge' }; 'brave' { 'Brave' }; 'firefox' { 'Firefox' }
                    'discord' { 'Discord' }; 'slack' { 'Slack' }; 'teams' { 'Teams' }; 'spotify' { 'Spotify' }
                    'Code' { 'VS Code' }; default { $_ }
                }
                $label
            }
        }
        $menuLines = [System.Collections.Generic.List[string]]::new()
        [void]$menuLines.Add('MAIN MENU'); [void]$menuLines.Add('')
        [void]$menuLines.Add('[1] Standard    temp, browsers, apps, orphans')
        [void]$menuLines.Add('[2] Aggressive  + DISM + event logs + prefetch')
        [void]$menuLines.Add('[3] Preview     dry run — see plan only')
        [void]$menuLines.Add('[4] Orphans     interactive orphan review')
        [void]$menuLines.Add('[5] Health      detailed system health report')
        [void]$menuLines.Add('')
        [void]$menuLines.Add('Busy browsers and selected apps are skipped for safety.')
        [void]$menuLines.Add('[Q] Quit')
        if ($runningApps.Count -gt 0) {
            [void]$menuLines.Add('')
            [void]$menuLines.Add("Running — skipped: $($runningApps -join ', ')")
        }
        Write-Panel @($menuLines) -BorderColor 'Cyan' -TextColor 'White' -MinWidth 64 -MaxWidth 88
        Write-Host ''
        Write-CenteredLine 'Choose a mode and press Enter.' 'DarkGray'
        Write-Host ''
        $choice = (Read-Host 'Selection').Trim().ToUpperInvariant()
        switch ($choice) {
            '1' { Invoke-CleanupRun 'Standard';   Write-Host ''; [void](Read-Host '[Press Enter to return to Menu]') }
            '2' { Invoke-CleanupRun 'Aggressive'; Write-Host ''; [void](Read-Host '[Press Enter to return to Menu]') }
            '3' { Invoke-CleanupRun 'Preview';    Write-Host ''; [void](Read-Host '[Press Enter to return to Menu]') }
            '4' { Show-Header; $script:IsPreview=$false; Start-Step 'Orphan folder scan'; $o=Find-OrphanFolders -InteractiveDelete; Finish-Step "Orphan check complete"; Write-Host ''; [void](Read-Host '[Press Enter to return to Menu]') }
            '5' { Show-HealthDetail; [void](Read-Host '[Press Enter to return to Menu]') }
            'Q' { return }
            default { Write-Host 'Invalid.' -ForegroundColor Yellow; Start-Sleep -Milliseconds 500 }
        }
    }
}

function Show-RunSummary {
    param(
        [string]$Mode, [double]$Duration, $StartSpace, $EndSpace,
        [hashtable]$Steps, [switch]$Aggressive, [int]$LogsCl
    )
    $sessionBar = New-AsciiBar -Value $script:TotalSteps -Total $script:TotalSteps -Width 18
    $summaryColor = Get-ModeColor $Mode
    $sumLines = @(
        "Run summary  : $($Mode.ToUpper())",
        "Pipeline     : $sessionBar",
        "Finished     : $((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))",
        "Duration     : ${Duration}s",
        "Before       : $($StartSpace.MB) MB ($($StartSpace.GB) GB)",
        "After        : $($EndSpace.MB) MB ($($EndSpace.GB) GB)",
        "Measured     : $(Format-FileSize ([Math]::Max(0, $script:BytesFreed)))",
        "Observed     : $($EndSpace.MB - $StartSpace.MB) MB ($([math]::Round(($EndSpace.MB - $StartSpace.MB)/1024,2)) GB)"
    )
    Write-Host ''
    Write-Panel $sumLines -BorderColor $summaryColor -TextColor 'White' -MinWidth 58 -MaxWidth 86
    Write-Host ''
    if ($script:CategorySizes.Count -gt 0) {
        Write-SectionHeader 'Category Breakdown'
        $script:CategorySizes.GetEnumerator() | Sort-Object Value -Descending | ForEach-Object {
            Write-Host ("  {0,-22} {1,12}" -f $_.Key, (Format-FileSize $_.Value)) -ForegroundColor DarkGray
        }
        Write-Host ''
    }
    Write-SectionHeader 'Impact'
    Write-Host ("  {0,-16} {1}" -f 'System caches', $Steps.s1) -ForegroundColor DarkGray
    Write-Host ("  {0,-16} {1}" -f 'Browsers', "$($Steps.s2) Chromium | $($Steps.s3) Firefox") -ForegroundColor DarkGray
    Write-Host ("  {0,-16} {1}" -f 'App caches', $Steps.s4) -ForegroundColor DarkGray
    Write-Host ("  {0,-16} {1}" -f 'Dev caches', $Steps.s5) -ForegroundColor DarkGray
    Write-Host ("  {0,-16} {1}" -f 'GPU/Shell', $Steps.s6) -ForegroundColor DarkGray
    Write-Host ("  {0,-16} {1}" -f 'Log files', $Steps.s8) -ForegroundColor DarkGray
    Write-Host ("  {0,-16} {1}" -f 'Empty folders', $Steps.emptyRm) -ForegroundColor DarkGray
    Write-Host ("  {0,-16} {1}" -f 'Stale junk', $Steps.staleRm) -ForegroundColor DarkGray
    Write-Host ("  {0,-16} {1}" -f 'Orphans', $Steps.orphans) -ForegroundColor $(if($Steps.orphans -gt 0){'Yellow'}else{'DarkGray'})
    if ($script:SkippedItems.Count -gt 0) {
        Write-Host ''; Write-SectionHeader 'Safety Skips'
        $script:SkippedItems | Group-Object Reason | Sort-Object Count -Descending | ForEach-Object {
            Write-Host ("  {0,2}x {1}" -f $_.Count, $_.Name) -ForegroundColor DarkGray
        }
    }
    Write-Host ''
    if ($script:IsPreview) { Write-Log 'PREVIEW mode. Nothing was deleted.' 'WARN' }
    elseif ($script:IsAggressive) { Write-Log 'Aggressive mode completed with extras.' 'WARN' }
}

Export-ModuleMember -Function Test-VT100Supported, Get-ModeColor, Write-Log, Write-CommandLog, Write-CenteredLine, Write-SectionHeader, Write-Panel, Show-AppLogo, Start-Step, Finish-Step, Update-UiTicker, Show-Header, Show-Menu, Show-RunSummary
```

- [ ] **Step 4: Run UI tests to verify they pass**

Run:
```powershell
$results = Invoke-Pester -Path 'tests/Bakunawa.UI.Tests.ps1' -PassThru
$results.FailedCount | Should -Be 0
```

- [ ] **Step 5: Commit**

```bash
git add Bakunawa.UI.psm1 tests/Bakunawa.UI.Tests.ps1
git commit -m "feat: add Bakunawa UI module with VT100 rendering and fallback"
```

---

### Task 5: Bakunawa Entry Point + Delete v2

**Files:**
- Create: `Bakunawa.ps1`
- Delete: `SystemCleaner.ps1`
- Create: `Bakunawa.json` (optional config scaffold)
- Modify: `README.md`

- [ ] **Step 1: Write Bakunawa.ps1 entry point**

```powershell
[CmdletBinding()]
param(
    [ValidateSet('Menu', 'Standard', 'Aggressive', 'Preview')]
    [string]$Mode = 'Menu',
    [string[]]$ExtraExcludePath = @(),
    [switch]$NoPause,
    [switch]$SkipBootstrap,
    [string]$LogFile = ''
)

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$Host.UI.RawUI.WindowTitle = 'Bakunawa v3'

# ── Auto-load modules ──
$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
foreach ($mod in @('Core','Config','Cleanup','UI')) {
    $modPath = Join-Path $scriptDir "Bakunawa.$mod.psm1"
    if (Test-Path -LiteralPath $modPath) { Import-Module $modPath -Force -Scope Global -ErrorAction Stop }
    else { Write-Error "Missing module: $modPath"; exit 1 }
}

# ── Initialize state ──
$script:SysLoc = Get-SystemLocations
$config = Get-BakunawaConfig
$mergedExclusions = Merge-Exclusions -ConfigPaths $config.extraExcludePaths -CliPaths $ExtraExcludePath
$script:ExcludedPaths = Get-ExcludedPaths -ExtraExcludePath $mergedExclusions
$script:RunningProcesses = Get-RunningProcessNames
$script:SpinnerFrames = @('|','/','-','\')
$script:SpinnerIndex = 0
$script:UiStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
$script:LastUiMs = [long]0
$script:UiTickMs = 250

if ($LogFile) {
    $script:LogFilePath = Resolve-FullPath $LogFile
    if (-not $script:LogFilePath) { $script:LogFilePath = $LogFile }
    try {
        $header = "# Bakunawa v3 log - $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - Mode: $Mode"
        Set-Content -LiteralPath $script:LogFilePath -Value $header -Encoding UTF8 -EA SilentlyContinue
    } catch { $script:LogFilePath = '' }
}

if ($SkipBootstrap) { return }

if (-not (Test-IsAdministrator)) {
    if (Restart-Elevated -SelectedMode $Mode) { exit 0 }
    if (-not $NoPause) { Write-Host ''; [void](Read-Host 'Press Enter to close') }
    exit 1
}

switch ($Mode) {
    'Standard'   { Invoke-CleanupRun 'Standard';   if(-not $NoPause){Write-Host '';[void](Read-Host 'Press Enter to close')} }
    'Aggressive' { Invoke-CleanupRun 'Aggressive'; if(-not $NoPause){Write-Host '';[void](Read-Host 'Press Enter to close')} }
    'Preview'    { Invoke-CleanupRun 'Preview';    if(-not $NoPause){Write-Host '';[void](Read-Host 'Press Enter to close')} }
    default      { Show-Menu }
}
```

- [ ] **Step 2: Write Bakunawa.json optional config scaffold**

```json
{
  "mode": "Menu",
  "extraExcludePaths": [],
  "orphanThresholdDays": 30,
  "logRetention": 7,
  "parallel": true,
  "uiStyle": "auto"
}
```

- [ ] **Step 3: Remove old SystemCleaner.ps1**

```bash
Remove-Item -LiteralPath 'SystemCleaner.ps1' -Force
```

- [ ] **Step 4: Verify the new script loads and shows the menu**

Run:
```powershell
powershell -ExecutionPolicy Bypass -File .\Bakunawa.ps1 -Mode Preview -NoPause
```
Expected: Bakunawa header, health gauge, menu panel, preview mode.

- [ ] **Step 5: Run all tests**

```powershell
$results = Invoke-Pester -Path 'tests/' -PassThru
$results.FailedCount | Should -Be 0
```

- [ ] **Step 6: Commit**

```bash
git add Bakunawa.ps1 Bakunawa.json
git add -u  # track deletions
git commit -m "feat: add Bakunawa entry point, remove SystemCleaner.ps1, complete v3 rebrand"
```

---

### Task 6: README and Final Cleanup

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Update README.md with Bakunawa identity**

Replace the entire README with Bakunawa v3 content. Key updates:
- Title: "Bakunawa — Devour Your Digital Waste"
- All `SystemCleaner.ps1` references → `Bakunawa.ps1`
- Architecture description: modules + app-definitions
- Usage examples update to `Bakunawa.ps1`
- Add new config file documentation
- Note about config-driven app definitions

- [ ] **Step 2: Final verification**

```powershell
powershell -ExecutionPolicy Bypass -File .\Bakunawa.ps1 -Mode Preview -NoPause
Invoke-Pester -Path 'tests/' -PassThru
```

Verify:
- Bakunawa header shows correctly
- Preview mode runs all steps without deletion
- All tests pass
- Windows title shows "Bakunawa v3"

- [ ] **Step 3: Final commit**

```bash
git add README.md
git commit -m "docs: update README for Bakunawa v3 rebrand and architecture"
```

---

## Spec Coverage Check

Map of spec requirements to implementation tasks:

| Spec Requirement | Task |
|-----------------|------|
| 5-module architecture (Core, Cleanup, UI, Config, Entry) | Tasks 1, 2, 3, 4, 5 |
| Config-driven app definitions (JSON files) | Task 1 (app-definitions/*.json) |
| All v2 features retained (modes, orphans, health, safety) | Tasks 2, 3 (migrated functions) |
| VT100 terminal UI with fallback | Task 4 (UI module) |
| Structured error pipeline | Tasks 2, 3 (Core errors, Cleanup try/catch) |
| Parallel execution (runspaces) | Task 3 (noted in Cleanup tasks) |
| Configuration persistence (Bakunawa.json) | Tasks 1, 5 |
| Rebrand to Bakunawa | Tasks 5, 6 |
| README update | Task 6 |
| Existing Pester tests migrated | Tasks 2, 3, 4 |
