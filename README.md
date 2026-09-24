# Bakunawa

Windows PowerShell 5.1 cleaner for **local disk C: only**, with cleanup previews and application-aware cache and orphan review.

Run the existing menu:

```powershell
.\Bakunawa.ps1
```

Choose **3 — Preview** to inspect routine cleanup, or **4 — Scan C:** to discover and review candidates. Results show category totals and the largest findings first, with complete paths, sizes, age, and evidence. Use **N/P** to move between pages, item numbers to select candidates, **E** to export JSON, **I** to inspect scan issues, and **R** to restore quarantined items. Moving a selection requires typing `QUARANTINE`.

Read-only command-line scan of C:\:

```powershell
.\Bakunawa.ps1 -Mode Scan -NoPause
```

Select a directory on C: and export a report:

```powershell
.\Bakunawa.ps1 -Mode Scan -ScanRoot 'C:\Users' -ReportPath '.\scan-report.json' -NoPause
```

Existing report files are preserved; choose a new filename for each export. Scan mode can run without elevation. Its coverage report identifies inaccessible locations. An administrator terminal can increase coverage.

## Scan progress and text logs

Every command-line run in **Standard, Aggressive, Preview, Scan, Health, or Benchmark** automatically writes a UTF-8 `.txt` log. Each action selected from the interactive menu gets a separate log, including repeated scans. Logs are stored at:

```text
%LOCALAPPDATA%\Bakunawa\Logs\yyyyMMdd-HHmmss-fff-Mode-uniqueId.txt
```

The terminal prints the full log path when the operation starts and ends. Existing automatic logs are never overwritten. `-LogFile 'C:\Reports\cleanup.txt'` appends an additional copy at your chosen path; it does not disable automatic logs. `-ReportPath` and the review's **E** command still create optional JSON reports.

Discovery shows preparation, the current root and path, elapsed time, observed traversal counts, provisional candidates, errors, and exclusions. It prints a persistent update approximately every five seconds while the walker returns entries, plus a completion line for each root. Counts marked `+` are lower bounds from the streaming walk; final file counts appear in the coverage report. An unknown tree size has no percentage or guessed completion time. Cleanup and benchmark progress tracks completed categories, whose running times can differ. `-NoAnimations` disables live progress overlays and retains the text updates.

The scan summary appears before detailed findings. It separates eligible temporary items from candidates requiring review and calls out incomplete coverage. Command-line scans show up to ten largest candidates and five issues when the full report was successfully written. **Every finding, full path, reason, configured exclusion, and encountered issue remains in the text log.** Interactive review retains paging and item selection. Long paths wrap instead of being shortened, including in narrow terminals. Reports use text labels without emojis; the existing logo and menu remain.

See [the sample terminal report](docs/ui-report-example.txt) for the layout with candidates and a coverage gap.

Cleanup summaries distinguish preview estimates, deleted data, and quarantined data that still occupies space. Health and benchmark summaries describe estimates and timing; they do not claim complete filesystem coverage.

Logs are written during the operation. A failed or interrupted run retains the details already recorded. An `Interrupted` status or missing `RUN FINISHED` footer means the run is incomplete. If the log cannot be created, the operation does not start. A later write failure produces an explicit warning and an `INCOMPLETE` log message. Logs are retained until you remove them yourself and are excluded from normal drive discovery through the protected Bakunawa application directory. Preview creates its log but does not modify cleanup targets or quarantine data.

Preview routine cleanup without deleting, moving, stopping services, creating cache directories, or expiring quarantine:

```powershell
.\Bakunawa.ps1 -Mode Preview -NoPause
```

## What scanning means

The scanner walks each selected tree once and aggregates file sizes and the newest modification time across descendants. Overlapping roots and nested findings are deduplicated. Progress reports the current path and elapsed time. There is no depth limit or silent time budget.

| Finding | Action |
| --- | --- |
| Known disposable cache directory matched to an application definition, including recently modified caches | Review before quarantining; the application may rebuild or download it again |
| Stale files and folders inside known temp locations | Eligible for routine cleanup after revalidation |
| Cache-like folders elsewhere, stale temporary files and logs | Review before quarantining |
| Stale app-data folders without a matching installed-app or process name | Possible leftovers; review required |
| Shortcuts with verified missing local targets on an available fixed drive | Review required |
| Stale empty folders | Review required outside known temp locations |

Age and registry-name matching cannot prove that an item is unused. Portable apps, Store apps, and retained settings can lack a matching uninstall entry. Personal documents are not flagged merely because they are old. Files changed after a scan require another scan before removal.

Known cache detection reuses the application's cleanup definitions and requires a disposable cache name; it does not label entire installations as caches. Busy application cache paths are skipped and reported. Review checks running applications again before moving a selection. Minimum age still applies to name-only cache matches and possible leftovers.

Protected user folders, configured exclusions, Windows-managed directories, installed program roots, quarantine, version-control metadata, junctions, symbolic links, and offline content are excluded from drive discovery. Each encountered exclusion or access error appears in the report. Dedicated cleanup tasks handle known Windows and application cache locations separately. An unavailable drive is reported as unavailable rather than empty.

## Cleanup and recovery

Routine cache cleanup preserves cache roots, processes siblings independently, and records locked-file failures. Installed SDKs, Python environments, and browser local storage are not routine cache targets. Running applications are checked against the application definitions. Preview totals are estimates; successful deletion and quarantined bytes are reported separately.

Scan roots outside C: are rejected, including saved configuration roots and network paths. Cleanup skips redirected locations outside C:, junctions, symbolic links, and offline paths. Wildcard expansion checks each directory before descending. Recycle Bin cleanup targets C: only. Event logs are retained because their storage can be redirected. Quarantine and restoration must also stay on C:; an existing quarantine location elsewhere is not moved or purged automatically.

Quarantine retains disk space until its contents are purged. Orphan-review selections always use quarantine. Manifests are written before moving data, incomplete moves retain recovery information, and restore refuses to overwrite an existing destination. Preview and scan startup do not purge quarantine.

Configuration is loaded from `%APPDATA%\Bakunawa\config.json`, using defaults from `src/Bakunawa.Config.psm1`. The repository's older `Bakunawa.json` is not the active configuration file. The `Orphan Scan` category is enabled in new defaults; an explicit setting in an existing user configuration takes precedence.

Optional scan settings in that configuration:

```json
"scanSettings": {
  "roots": ["C:\\"],
  "minAgeDays": 30
}
```

An empty `roots` array selects C:\. `-ScanRoot` overrides configured roots but cannot expand the C: boundary. Remove other drives from older saved root lists before scanning. Custom exclusions belong in `exclusions.userCustomExclusions` or the `-ExtraExcludePath` argument.

## Verification

```powershell
Import-Module Pester -MinimumVersion 5.0
Invoke-Pester -Path .\tests -Output Detailed
```

The tests use temporary fixtures for deletion, quarantine, restoration, and junction handling. No live drive cleanup is needed to run them.
