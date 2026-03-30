# System Cleaner

`System Cleaner` is a Windows PowerShell cleanup utility built as a console-style application. It focuses on disposable data such as temp files, browser caches, shader caches, update-download leftovers, and selected app caches, while deliberately avoiding common personal folders such as `Downloads`.

The project stays intentionally small:

- One main script: `SystemCleaner.ps1`
- One operator experience: interactive menu or direct CLI mode
- One design goal: visible, reviewable cleanup behavior with conservative defaults

## What The Tool Does

The cleaner targets well-known disposable locations, including:

- User temp folders and `%LOCALAPPDATA%\Temp`
- Windows temp folders
- Windows Error Reporting cache and queue folders
- Windows Update download cache
- Chromium browser caches for Chrome, Edge, and Brave
- Firefox cache directories
- App caches for Discord, VS Code, Spotify, Telegram Desktop, and Stremio
- GPU shader caches
- Windows thumbnail and icon caches
- Recycle Bin contents
- Empty cache-like directories under safe roots
- Stale cache, temp, and log folders inside approved roots

`Aggressive` mode adds:

- `Dism.exe /online /Cleanup-Image /StartComponentCleanup`
- Windows event-log clearing through `wevtutil.exe`

## How The System Works

The script follows a predictable runtime flow:

1. It resolves protected paths and system cleanup roots.
2. It checks whether the current PowerShell session is elevated.
3. If elevation is required, it relaunches itself through the normal Windows UAC prompt.
4. It shows the interactive console menu or runs the selected `-Mode`.
5. It processes cleanup steps in a fixed order and prints live command-style logs.
6. It calculates before-and-after disk free space and prints a run summary.

The cleanup pipeline is ordered to keep the operator informed:

1. System temp, crash, and update-related caches
2. Chromium browser caches
3. Firefox caches
4. Selected application caches
5. GPU, thumbnail, and icon caches
6. Recycle Bin
7. Empty and stale cache-like folders
8. Optional aggressive maintenance tasks

The current console interface is designed to behave like a small terminal application:

- Centered ASCII title banner
- Status panel with mode, free space, protected paths, and last-run recap
- Boxed main menu and post-run actions
- Persistent logs after execution so the user can inspect exactly what happened

## Safety Boundaries

This project is designed around scoped cleanup, not broad deletion.

By default, the script does not target:

- `Downloads`
- Documents, Desktop, Pictures, Music, or Videos
- Source-code repositories as a general class
- Installed applications
- Registry keys
- Browser profiles as whole directories
- Credentials, passwords, or accounts as direct cleanup targets
- Arbitrary folders outside the approved cleanup roots

Safety controls include:

- Automatic exclusion of `Downloads`
- Additional protected paths through `-ExtraExcludePath`
- `Preview` mode for dry-run execution
- Visible step-by-step logs
- Narrow targeting of known cache and temporary paths
- Optional aggressive actions instead of default aggressive behavior

Important operational notes:

- Some applications will rebuild caches on next launch.
- Some applications may lose thumbnails, transient sessions, or offline cache data.
- `Aggressive` mode is intentionally more disruptive than `Standard`.
- Administrator rights are required because some system-owned targets cannot be accessed otherwise.

## Modes

- `Menu`: interactive console menu
- `Standard`: regular cleanup scope
- `Aggressive`: standard scope plus component-store cleanup and event-log clearing
- `Preview`: dry run with no file deletion

## Cleanup Scope

The cleaner primarily operates inside these roots:

- `%TEMP%`
- `%LOCALAPPDATA%`
- `%APPDATA%`
- `%ProgramData%`
- `%SystemRoot%\Temp`
- `%SystemRoot%\SoftwareDistribution\Download`

Within those areas, it removes named cache, temp, update, crash, and shell-cache data instead of sweeping entire trees blindly.

## Requirements

- Windows
- PowerShell 5.1 or newer
- Permission to approve UAC elevation

## Usage

Launch the interactive console:

```powershell
powershell -ExecutionPolicy Bypass -File .\SystemCleaner.ps1
```

Run the standard cleanup directly:

```powershell
powershell -ExecutionPolicy Bypass -File .\SystemCleaner.ps1 -Mode Standard
```

Run the aggressive cleanup:

```powershell
powershell -ExecutionPolicy Bypass -File .\SystemCleaner.ps1 -Mode Aggressive
```

Preview the cleanup plan without deleting anything:

```powershell
powershell -ExecutionPolicy Bypass -File .\SystemCleaner.ps1 -Mode Preview
```

Protect additional paths:

```powershell
powershell -ExecutionPolicy Bypass -File .\SystemCleaner.ps1 -Mode Preview -ExtraExcludePath 'D:\Backups','E:\PortableApps'
```

Skip the final pause in non-menu runs:

```powershell
powershell -ExecutionPolicy Bypass -File .\SystemCleaner.ps1 -Mode Standard -NoPause
```

## Recommended First Run

For a first-time operator:

1. Review `SystemCleaner.ps1`.
2. Run `Preview` mode first.
3. Read the live logs and confirm the scope.
4. Add any additional protected paths with `-ExtraExcludePath`.
5. Run `Standard` mode.
6. Use `Aggressive` mode only when the heavier maintenance tradeoff is acceptable.

## Troubleshooting

If the tool reopens with a UAC prompt:

- That is expected for system-level cleanup targets.

If some cache folders cannot be removed:

- The owning application may still be running.
- Close the application and rerun the cleaner.

If reported free space changes only slightly:

- The targeted caches may already be small or empty.
- Use `Preview` mode to confirm what the script plans to touch.

If an application rebuilds data on next launch:

- That is normal behavior for cache cleanup.

## Development Notes

- The project is intentionally kept as a single PowerShell script for inspectability.
- The interface is interactive, but every mode can also be run directly from the CLI.
- Logs are emitted in real time so operators can audit actions during execution.
- The summary section reports duration, before/after free space, and processed cleanup counts.

For security-specific guidance, see [SECURITY.md](SECURITY.md).
