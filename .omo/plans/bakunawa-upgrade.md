# Bakunawa Fix & Power Upgrade

## TL;DR
> **Quick Summary**: Fix the critical `$ErrorActionPreference` initialization crash in Bakunawa.ps1 and Bakunawa.Core.psm1, then upgrade Bakunawa to definitively exceed SystemCleaner with FontCache service handling, system restore points, disk usage analysis, and console width robustness.
>
> **Deliverables**:
> - Fix: `Bakunawa.ps1` line 12 — `Set-Variable` for `$ErrorActionPreference`
> - Fix: `src/Bakunawa.Core.psm1` line 3 — `Set-Variable` for `$ErrorActionPreference`
> - Enhancement: `src/Bakunawa.Cleanup.psm1` — FontCache service stop/restart
> - Enhancement: `src/Bakunawa.Core.psm1` — System restore point creation
> - Enhancement: `src/Bakunawa.Cleanup.psm1` — Disk Usage Analyzer (new function)
> - Enhancement: `src/Bakunawa.Core.psm1` — `Get-ConsoleWidth` fallback for legacy consoles
>
> **Estimated Effort**: Short (6 files, targeted edits)
> **Parallel Execution**: YES — 2 waves
> **Critical Path**: Fix bugs → Add enhancements → Test all modes

---

## Context

### Original Request
Fix `Bakunawa.ps1` and make it more powerful than `SystemCleaner.ps1`.

### Interview Summary
**Key Findings**:
- **Bug**: `$ErrorActionPreference = 'SilentlyContinue'` at `Bakunawa.ps1:12` and `Bakunawa.Core.psm1:3` causes "Cannot overwrite variable because the variable has been optimized" error when running via `powershell -File`. This is a known PowerShell 5.1 scoping issue — preference variables become read-only when the script is compiled.
- `Clear-BrowserCaches` does not exist as a standalone function, but the parallel dispatch uses a `$taskMap` hashtable with inline script blocks, so this is not a bug — the dispatch is correct.
- Bakunawa is already architecturally superior (modular, JSON-driven, parallel execution, health dashboard, orphan risk scoring, WSL support, config file).
- SystemCleaner has a few specific implementation details Bakunawa can adopt: FontCache service management, more robust Windows Update service handling.

### Research Findings
- **SystemCleaner.ps1**: 1751 lines, monolithic. Has FontCache service stop/restart, wevtutil event log clearing, explorer restart for thumbcache, C# accelerators.
- **Bakunawa**: Modular (5 files, ~2100 total lines). Already has C# accelerator, parallel execution, health dashboard, orphan risk scoring, 59 Pester tests, JSON-driven app definitions (10 files), WSL support, config file.
- **Gap Analysis**: Bakunawa covers all SystemCleaner features already. It needs the initialization bug fixed and can add 3 enhancements to decisively surpass SystemCleaner.

---

## Work Objectives

### Core Objective
Fix Bakunawa's initialization crash and add 3 power enhancements that SystemCleaner doesn't have.

### Concrete Deliverables
- `Bakunawa.ps1` — `Set-Variable` fix
- `src/Bakunawa.Core.psm1` — `Set-Variable` fix + restore point function + console width fallback
- `src/Bakunawa.Cleanup.psm1` — FontCache enhancement + Disk Usage Analyzer
- `src/Bakunawa.UI.psm1` — Menu integration for Disk Usage
- Verification: Preview mode runs without crash, Menu shows all 6 options

### Must Have
- `Bakunawa.ps1` and `Bakunawa.Core.psm1` initialize without errors
- `powershell -File .\Bakunawa.ps1 -Mode Preview -NoPause -SkipBootstrap` completes without errors
- All existing 59 Pester tests still pass

### Must NOT Have (Guardrails)
- No breaking changes to existing function signatures
- No changes to JSON app-definition schema
- No removal of existing features
- No changes to the safety boundaries (excluded paths, running process detection)

---

## Verification Strategy

> **ZERO HUMAN INTERVENTION** — ALL verification is agent-executed.

### Test Decision
- **Infrastructure exists**: YES (Pester test framework in `tests/`)
- **Automated tests**: TDD — write failing test first, then implement
- **Framework**: Pester

### QA Policy
Every task includes agent-executed QA scenarios.

---

## Execution Strategy

### Parallel Execution Waves

```
Wave 1 (Critical fixes — sequential dependencies):
├── Task 1: Fix $ErrorActionPreference in Bakunawa.ps1 line 12
├── Task 2: Fix $ErrorActionPreference in Bakunawa.Core.psm1 line 3
├── Task 3: Add Get-ConsoleWidth fallback in Bakunawa.Core.psm1
└── Task 4: Test Preview mode (verification: runs without errors)

Wave 2 (Enhancements — can run after Wave 1):
├── Task 5: Add system restore point function (Bakunawa.Core.psm1)
├── Task 6: Enhance Clear-FontCache with service management (Bakunawa.Cleanup.psm1)
├── Task 7: Add Show-DiskUsage function + Menu option (Bakunawa.Cleanup.psm1 + Bakunawa.UI.psm1)
└── Task 8: Run Pester tests, verify all modes
```

---

## TODOs

- [ ] 1. **Fix `$ErrorActionPreference` in Bakunawa.ps1**

  **What to do**:
  - Change line 12 from `$ErrorActionPreference = 'SilentlyContinue'` to:
    ```powershell
    Set-Variable -Name ErrorActionPreference -Value 'SilentlyContinue' -Scope Script
    ```
  - PowerShell 5.1 with `-File` makes these variables read-only. `Set-Variable` bypasses this.

  **Must NOT do**:
  - Do not change any other lines in this file
  - Do not add any other initialization logic

  **References**:
  - `Bakunawa.ps1:12` — The exact line to fix

  **Acceptance Criteria**:
  - [ ] `powershell -NoProfile -Command "& { Set-Variable -Name ErrorActionPreference -Value 'SilentlyContinue' -Scope Script; Write-Host 'OK' }"` succeeds

  **QA Scenarios**:
  ```
  Scenario: Run Bakunawa.ps1 with Preview mode (after all tasks in Wave 1)
    Tool: Bash
    Steps:
      1. Run: powershell -NoProfile -ExecutionPolicy Bypass -File "Bakunawa.ps1" -Mode Preview -NoPause -SkipBootstrap
      2. Check: No "Cannot overwrite variable" error in output
    Expected Result: Script runs to completion showing Preview mode output
    Evidence: .omo/evidence/task-1-preview-test.txt
  ```

- [ ] 2. **Fix `$ErrorActionPreference` in Bakunawa.Core.psm1**

  **What to do**:
  - Change line 3 from `$ErrorActionPreference = 'SilentlyContinue'` to:
    ```powershell
    Set-Variable -Name ErrorActionPreference -Value 'SilentlyContinue' -Scope Script
    ```

  **References**:
  - `src/Bakunawa.Core.psm1:3` — The exact line to fix

  **Acceptance Criteria**:
  - [ ] Module imports without `VariableNotWritableRare` error

  **QA Scenarios**:
  ```
  Scenario: Module imports correctly
    Tool: Bash
    Steps:
      1. Run: powershell -NoProfile -Command "Import-Module 'src/Bakunawa.Core.psm1' -Force -ErrorAction Stop; Write-Host 'OK'"
    Expected Result: "OK" printed, no errors
    Evidence: .omo/evidence/task-2-core-import.txt
  ```

- [ ] 3. **Add `Get-ConsoleWidth` fallback in Bakunawa.Core.psm1**

  **What to do**:
  - Find the existing `Get-ConsoleWidth` function in Core.psm1 (around line ~380 area)
  - Add a fallback for when `$Host.UI.RawUI.WindowSize.Width` fails on legacy consoles
  - Pattern:
    ```powershell
    function Get-ConsoleWidth {
        try { return $Host.UI.RawUI.WindowSize.Width } catch { return 80 }
    }
    ```

  **Must NOT do**:
  - Do not change any other console UI functions

  **References**:
  - `src/Bakunawa.Core.psm1` — Find existing console functions

  **Acceptance Criteria**:
  - [ ] Function returns integer (80 on failure, actual width on success)

  **QA Scenarios**:
  ```
  Scenario: Get-ConsoleWidth returns a positive integer
    Tool: Bash
    Steps:
      1. Run: Import-Module; $w = Get-ConsoleWidth; Write-Host "Width: $w"
      2. Check: $w -gt 0 -and $w -is [int]
    Expected Result: Width > 0, no crash
    Evidence: .omo/evidence/task-3-console-width.txt
  ```

- [ ] 4. **Verify Preview mode runs cleanly**

  **What to do**:
  - After Tasks 1-3 are applied, run the full script in Preview mode
  - Capture output and check for errors

  **Acceptance Criteria**:
  - [ ] No initialization errors
  - [ ] Preview mode shows expected output (would-clean list, summary, no actual deletion)

  **QA Scenarios**:
  ```
  Scenario: Full Preview mode run
    Tool: Bash
    Steps:
      1. cd C:\.anyThing\cleaner\repo_tmp
      2. powershell -NoProfile -ExecutionPolicy Bypass -File "Bakunawa.ps1" -Mode Preview -NoPause -SkipBootstrap
      3. Grep output for "Cannot overwrite variable" — must be absent
      4. Grep output for "Run summary" — must be present
    Expected Result: Clean execution with summary output
    Evidence: .omo/evidence/task-4-preview-output.txt
  ```

- [ ] 5. **Add system restore point function to Bakunawa.Core.psm1**

  **What to do**:
  - Add new function `New-Checkpoint` to `Bakunawa.Core.psm1`
  - Uses `Checkpoint-Computer` cmdlet (Windows System Restore)
  - Called from `Invoke-CleanupRun` when Mode is 'Aggressive'
  - Export in `Export-ModuleMember`

  ```powershell
  function New-Checkpoint {
      param([string]$Description = 'Bakunawa cleanup checkpoint')
      try {
          Checkpoint-Computer -Description $Description -RestorePointType MODIFY_SETTINGS -EA Stop
          Write-Log "Restore point created: $Description" 'OK'
          return $true
      } catch {
          Write-Log "Restore point creation failed (may be disabled via Group Policy): $_" 'WARN'
          return $false
      }
  }
  ```

  **Must NOT do**:
  - Do not force reboot or require user interaction
  - Fail gracefully if System Restore is disabled

  **References**:
  - `src/Bakunawa.Core.psm1` — Add near other safety functions
  - `Export-ModuleMember` at end of Core.psm1 — Include `New-Checkpoint`

  **Acceptance Criteria**:
  - [ ] Function exists and is exported
  - [ ] Fails gracefully when System Restore unavailable

  **QA Scenarios**:
  ```
  Scenario: New-Checkpoint returns boolean
    Tool: Bash
    Steps:
      1. Import-Module Bakunawa.Core.psm1
      2. $result = New-Checkpoint -Description "Test checkpoint"
      3. Assert: $result -is [bool]
    Expected Result: True or False (system-dependent), never throws
    Evidence: .omo/evidence/task-5-checkpoint.txt
  ```

- [ ] 6. **Enhance `Clear-FontCache` with FontCache service management**

  **What to do**:
  - Update the existing `Clear-FontCache` function in `Bakunawa.Cleanup.psm1`
  - Add FontCache service stop before clearing, restart after
  - Pattern matches SystemCleaner's approach:

  ```powershell
  function Clear-FontCache {
      $fontPath = Join-Path $script:SysLoc.WindowsRoot 'ServiceProfiles\LocalService\AppData\Local\FontCache'
      if (-not (Test-Path -LiteralPath $fontPath)) { return }
      $wasRunning = $false
      try {
          $svc = Get-Service FontCache -EA SilentlyContinue
          if ($svc -and $svc.Status -ne 'Stopped') {
              if (-not $script:IsPreview) {
                  Write-CommandLog 'STOP' 'FontCache'
                  Stop-Service FontCache -Force -EA SilentlyContinue
                  $wasRunning = $true
              }
          }
          Write-CommandLog ($(if($script:IsPreview){'PREVIEW'}else{'CLEAR'})) 'Font Cache'
          if (-not $script:IsPreview) {
              Get-ChildItem $fontPath -Force -EA SilentlyContinue | ForEach-Object {
                  Remove-Item $_.FullName -Force -EA SilentlyContinue
              }
          }
      } finally {
          if ($wasRunning -and -not $script:IsPreview) {
              Write-CommandLog 'START' 'FontCache'
              Start-Service FontCache -EA SilentlyContinue
          }
      }
  }
  ```

  **Must NOT do**:
  - Do not restart FontCache if it was already stopped
  - Do not fail if FontCache service doesn't exist (Windows Server SKUs)

  **References**:
  - `src/Bakunawa.Cleanup.psm1` — Find existing Clear-FontCache function
  - SystemCleaner.ps1:1504-1531 — Reference implementation

  **Acceptance Criteria**:
  - [ ] Function completes without error
  - [ ] FontCache service is stopped before clearing, restarted after

  **QA Scenarios**:
  ```
  Scenario: Clear-FontCache handles missing FontCache service gracefully
    Tool: Bash
    Steps:
      1. Import-Module Bakunawa.Cleanup.psm1
      2. Set $script:IsPreview = $true
      3. Call Clear-FontCache
    Expected Result: No crash if FontCache service doesn't exist
    Evidence: .omo/evidence/task-6-fontcache-preview.txt
  ```

- [ ] 7. **Add Disk Usage Analyzer (`Show-DiskAnalyzer`)**

  **What to do**:
  - Add new function `Get-LargestDirectories` in `Bakunawa.Core.psm1`
  - Add new UI function in `Bakunawa.UI.psm1` to display it
  - Add "6" menu option in `Show-Menu`

  **New function in Core.psm1**:
  ```powershell
  function Get-LargestDirectories {
      param(
          [string]$RootPath = $env:SystemDrive,
          [int]$TopN = 20,
          [int]$MinDepth = 2,
          [int]$MaxDepth = 4
      )
      $results = [System.Collections.Generic.List[PSCustomObject]]::new()
      $visited = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
      
      # Scan common space-hungry roots
      $roots = @(
          "$env:LOCALAPPDATA"
          "$env:APPDATA"
          "$env:ProgramData"
          "$env:USERPROFILE\.cache" 2>$null
          "$env:SystemRoot\Temp"
      ) | Where-Object { $_ -and (Test-Path $_ -PathType Container) }
      
      foreach ($base in $roots) {
          Get-ChildItem $base -Directory -Force -EA SilentlyContinue | ForEach-Object {
              $p = $_.FullName
              if ($visited.Add($p)) {
                  $size = Get-DirectorySize $p
                  if ($size -gt 10MB) {
                      [void]$results.Add([PSCustomObject]@{
                          Path = $p
                          SizeBytes = $size
                          SizeText = Format-FileSize $size
                          LastWrite = $_.LastWriteTime
                      })
                  }
              }
          }
      }
      
      return ($results | Sort-Object SizeBytes -Descending | Select-Object -First $TopN)
  }
  ```

  **Add menu option in UI.psm1**:
  ```
  [6] Disk Usage   analyze largest space consumers on system drive
  ```

  **Must NOT do**:
  - Do not scan entire C:\ recursively (too slow)
  - Do not modify any existing cleanup behavior

  **References**:
  - `src/Bakunawa.Core.psm1` — Add function near `Get-DirectorySize`
  - `src/Bakunawa.UI.psm1` — Add option in `Show-Menu` after option 5
  - `Bakunawa.Cleanup.psm1` — `Invoke-CleanupRun` does NOT need changes (new feature, separate path)

  **Acceptance Criteria**:
  - [ ] `Get-LargestDirectories` returns array of objects with Path, SizeBytes, SizeText, LastWrite
  - [ ] Menu shows option 6
  - [ ] Selecting 6 shows disk usage table
  - [ ] Returns to menu after

  **QA Scenarios**:
  ```
  Scenario: Get-LargestDirectories returns results
    Tool: Bash
    Steps:
      1. Import-Module Bakunawa.Core.psm1
      2. $r = Get-LargestDirectories
      3. Assert: $r.Count -ge 0 (not null)
      4. If $r.Count -gt 0: Assert each has Path, SizeBytes, SizeText properties
    Expected Result: Array of directory size objects
    Evidence: .omo/evidence/task-7-disk-usage.txt
  ```

- [ ] 8. **Run all Pester tests and verify all modes**

  **What to do**:
  - Run `Invoke-Pester -Path 'tests/'` 
  - Test all 3 cleanup modes + Preview
  - Fix any regressions

  **Acceptance Criteria**:
  - [ ] All 59+ Pester tests pass
  - [ ] Preview mode runs clean
  - [ ] Standard mode runs clean
  - [ ] Aggressive mode runs clean
  - [ ] Menu mode loads and shows correct number of options

  **QA Scenarios**:
  ```
  Scenario: Run Pester tests
    Tool: Bash
    Steps:
      1. cd C:\.anyThing\cleaner\repo_tmp
      2. Invoke-Pester -Path 'tests/' -Output Detailed
      3. Check: All tests pass
    Expected Result: All tests green, 0 failures
    Evidence: .omo/evidence/task-8-pester-results.txt
  ```

---

## Commit Strategy

- **Task 1+2**: `fix(init): use Set-Variable for ErrorActionPreference to avoid powershell -File optimization crash`
- **Task 3**: `fix(ui): add Get-ConsoleWidth fallback for legacy consoles`
- **Task 5**: `feat(core): add system restore point creation for Aggressive mode`
- **Task 6**: `feat(cleanup): enhance Clear-FontCache with service stop/restart`
- **Task 7**: `feat(core+ui): add disk usage analyzer (Get-LargestDirectories + menu option)`

---

## Success Criteria

### Verification Commands
```bash
powershell -NoProfile -ExecutionPolicy Bypass -File "Bakunawa.ps1" -Mode Preview -NoPause -SkipBootstrap
powershell -NoProfile -Command "Invoke-Pester -Path 'tests/' -Output Detailed"
```

### Final Checklist
- [ ] `$ErrorActionPreference` bug fixed (both files)
- [ ] `Get-ConsoleWidth` has fallback
- [ ] `Clear-FontCache` manages FontCache service
- [ ] `New-Checkpoint` exists and is exported
- [ ] `Get-LargestDirectories` exists and returns results
- [ ] Menu shows disk usage option (6)
- [ ] All 59+ Pester tests pass
- [ ] All 3 cleanup modes + Preview run without errors
