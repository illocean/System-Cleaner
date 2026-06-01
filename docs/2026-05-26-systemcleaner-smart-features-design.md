# SystemCleaner — Smart Features Design

## Overview

Two complementary features that make SystemCleaner "smarter": a real-time System Health Dashboard and a multi-signal Smart Orphan Detector. Both integrate into the existing single-file architecture with zero external dependencies.

---

## Feature 1: System Health Dashboard

### Purpose
Show the user a single, intuitive health score at a glance, with actionable sub-metrics.

### Where
Integration into `Show-Header` — the existing header panel gains a health gauge. Menu mode also gets a `[5] Health` option for full detail.

### Signals (max 100 pts)

| Signal | Weight | Source | Scoring |
|--------|--------|--------|---------|
| Disk Pressure | 30 | `Get-FreeSpaceInfo` | >30% free=30, 20–30%=25, 10–20%=15, 5–10%=5, <5%=0 |
| Temp Accumulation | 25 | `Get-DirectorySize` on TEMP + LocalAppData\Temp | <500MB=25, 500MB–2GB=18, 2–5GB=10, 5–10GB=5, >10GB=0 |
| Browser Cache Age | 20 | LastWriteTime on Chrome/Edge/Brave cache roots | <7d=20, 7–30d=14, 30–90d=8, >90d=0 |
| Orphan Risk | 25 | Count of High + Medium orphan candidates (from last run) | 0 High + <3 Med=25, 1–2 High/3–5 Med=15, 3+ High/6–10 Med=5, 10+ Med/5+ High=0 |

### Performance: 30-second cache
The health score is cached in `$script:HealthCache` with a 30-second TTL. Verified: `Get-DirectorySize` (C# accelerator) + `Get-FreeSpaceInfo` (WMI) take ~1s on first call. Cache avoids blocking the menu on every render.

### Grades
- **85–100** Excellent (green)
- **65–84** Good (cyan)
- **40–64** Fair (yellow)
- **0–39** Needs attention (red)

### New functions
- `Get-HealthScore` — computes and returns `[pscustomobject]@{ Score; Grade; Color; Signals; Cached }`
- `Show-HealthDetail` — expanded breakdown screen (menu option 5)

### Header integration
```
Health      : ████████░░ 78/100 Good
```

### Menu option `[5] Health`
Shows expanded breakdown:
```
── Health Report ─────────────────────────────────────
Score: 78/100 Good
  Disk Pressure   : ████████░░ 30/30 (34% free)
  Temp/Cache      : ██████░░░░ 18/25 (1.0 GB)
  Browser Age     : ████░░░░░░  8/20 (stale)
  Orphan Risk     : ██████████ 25/25 (none detected)
```

---

## Feature 2: Smart Orphan Detection

### Purpose
Replace the binary flag/no-flag with a risk-scored classification so the user can prioritize cleanup by confidence.

### 4-Signal Scoring Engine

```
RiskScore = max(0, Staleness + SizeImpact + InstallSignal + PathTrust)
```

| Signal | Range | Logic |
|--------|-------|-------|
| **Staleness** | 0–40 | 30–90d=15, 90–365d=30, >365d=40 |
| **Size Impact** | 0–20 | <1MB=0, 1–50MB=5, 50–200MB=10, 200–500MB=15, >500MB=20 |
| **Install Signal** | -30–0 | Registry/process exact name match=-30, partial/contains match=-10, no match=0 |
| **Path Trust** | 0–10 | ProgramData=5, AppData\Local=3, AppData\Roaming=0 |

### Classification
- **0–15 Low** (green) — likely still in use or negligible
- **16–40 Medium** (yellow) — review before deleting
- **41–70 High** (red) — strong orphan candidate

### New functions
- `Get-OrphanRiskScore` — takes folder metadata, returns `[pscustomobject]@{ Score; RiskLevel; Color }`

### Changes to `Find-OrphanFolders`
- Orphan entries gain `RiskScore`, `RiskLevel`, `RiskColor` properties
- Orphans sorted by score descending (riskiest first)
- Interactive delete shows `[HIGH]` / `[ MED ]` / `[ low ]` badges
- Summary shows count per risk level

### Verified scoring against real test data

| Folder | Days | Size | St | Sz | In | Pt | Σ | Level | Notes |
|--------|------|------|----|----|----|----|---|-------|-------|
| VS Revo Group | 1156 | 187 MB | 40 | 10 | 0 | 3 | **53** | HIGH | Unused for 3+ years |
| SpeedAutoClickerV3 | 1033 | 55 MB | 40 | 10 | 0 | 0 | **50** | HIGH | Unused for 2+ years |
| obsidian-updater | 140 | 282 MB | 30 | 15 | 0 | 3 | **48** | HIGH | Stale updater cache |
| Eclipse | 244 | 2 KB | 30 | 0 | 0 | 3 | **33** | MEDIUM | Stale but tiny |
| Composer | 80 | 208 MB | 15 | 15 | 0 | 3 | **33** | MEDIUM | Not in safe list |
| BraveSoftware | 57 | 2.09 GB | 15 | 20 | -10 | 3 | **28** | MEDIUM | Partial match "Brave" (process) |
| 0install.net | 57 | 1.7 MB | 15 | 5 | 0 | 3 | **23** | MEDIUM | Small, borderline |
| CEF | 34 | 0 B | 15 | 0 | 0 | 3 | **18** | MEDIUM | Zero-byte folder |
| Amazon Q | 57 | 701 B | 15 | 0 | 0 | 0 | **15** | LOW | Negligible |

### Orphan risk stored in last-run summary
`$script:LastRunSummary` gains `HighOrphans` and `MedOrphans` fields so the header health gauge can read them without rescanning.

---

## Testing

- All new functions get Pester tests
- `Get-OrphanRiskScore` tested with known inputs/outputs matching verified table above
- `Get-HealthScore` tested with mocked signal data
- Health score caching tested
- Existing 17 tests continue to pass