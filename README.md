# System Cleaner

`System Cleaner` is a Windows PowerShell cleanup utility with a terminal menu, live command logs, and a conservative safety model. It is designed to remove disposable cache and temporary data without touching common personal folders such as `Downloads`.

The project is intentionally simple:

- One script: `SystemCleaner.ps1`
- One interface: interactive terminal menu or direct CLI flags
- One priority: predictable cleanup behavior with visible logs

## What It Does

The script cleans well-known disposable data sources such as:

- User temp folders
- Windows temp folders
- Windows Update download cache
- Browser cache directories for Chromium-based browsers and Firefox
- Common app caches such as Discord, VS Code, Spotify, Telegram Desktop cache folders, and Stremio cache-like folders
- GPU shader caches
- Windows thumbnail and icon caches
- Recycle Bin
- Empty directories inside safe cache-oriented roots
- Stale junk folders named `cache`, `temp`, `logs`, and similar variants inside safe roots

It also supports an optional aggressive mode that adds:

- `DISM /StartComponentCleanup`
- Windows event log clearing

## What It Does Not Delete

By default, the script does not target:

- `Downloads`
- Documents, Desktop, Pictures, Music, Videos
- Source code repositories
- Arbitrary folders outside the defined cleanup roots
- Browser profiles as a whole
- Registry keys
- Installed applications
- User accounts, credentials, or saved passwords as a direct target

The stale-folder cleanup is limited to safe roots and only removes folders whose names strongly indicate disposable cache or temporary data. It does not sweep arbitrary project directories.

## Safety Model

This project is built around conservative cleanup, not “delete everything” behavior.

Safety controls:

- `Downloads` is excluded automatically for every user.
- Additional paths can be protected with `-ExtraExcludePath`.
- A `Preview` mode shows what would be processed before any deletion happens.
- The menu keeps the terminal open after each run so the operator can inspect logs.
- Only built-in Windows tooling is used for elevated system operations.
- Cleanup scope is limited to known cache, temp, update, crash, and shell-cache locations.

Important caveats:

- Some applications store useful-but-regenerable data in cache folders. Clearing those folders can sign the app out of transient sessions, remove local thumbnails, or force the app to rebuild caches.
- Aggressive mode is more disruptive than standard mode. Use it intentionally.
- The script uses administrator elevation because some system cleanup targets require it.

## Security Notes

The script does not:

- Upload files
- Call external web APIs
- Add scheduled tasks
- Modify startup entries
- Write to the registry as part of normal operation
- Execute arbitrary downloaded code

The script does:

- Request elevation through the normal Windows UAC flow
- Use PowerShell file operations to remove targeted cache data
- Stop and restart a small set of Windows services temporarily when cleaning the Windows Update download cache
- Call `Dism.exe` and `wevtutil.exe` only in aggressive mode

If you are distributing this publicly, users should still review the script before running it with administrator rights. `Preview` mode is the safest first run.

For a shorter security-specific summary, see [SECURITY.md](SECURITY.md).

## Requirements

- Windows
- PowerShell 5.1 or newer
- Administrator approval through UAC

## Usage

Interactive menu:

```powershell
powershell -ExecutionPolicy Bypass -File .\SystemCleaner.ps1
```

Standard run:

```powershell
powershell -ExecutionPolicy Bypass -File .\SystemCleaner.ps1 -Mode Standard
```

Aggressive run:

```powershell
powershell -ExecutionPolicy Bypass -File .\SystemCleaner.ps1 -Mode Aggressive
```

Preview / dry run:

```powershell
powershell -ExecutionPolicy Bypass -File .\SystemCleaner.ps1 -Mode Preview
```

Protect extra paths:

```powershell
powershell -ExecutionPolicy Bypass -File .\SystemCleaner.ps1 -Mode Preview -ExtraExcludePath 'D:\Backups','E:\PortableApps'
```

Run without the final pause in direct CLI mode:

```powershell
powershell -ExecutionPolicy Bypass -File .\SystemCleaner.ps1 -Mode Standard -NoPause
```

## Modes

- `Menu`: shows the interactive terminal UI
- `Standard`: runs the normal cleanup set
- `Aggressive`: runs the normal cleanup set plus component-store cleanup and event-log clearing
- `Preview`: prints intended actions without deleting anything

## Cleanup Scope

The script primarily operates inside:

- `%TEMP%`
- `%LOCALAPPDATA%`
- `%APPDATA%`
- `%ProgramData%`
- `%SystemRoot%\Temp`
- `%SystemRoot%\SoftwareDistribution\Download`

Within those roots it targets named cache and temporary folders rather than blindly deleting everything.

## First 30 Minutes

If this is your first time using the project:

1. Open `SystemCleaner.ps1` and read the top-level parameters.
2. Run `Preview` mode.
3. Review the live command logs in the terminal.
4. Add any custom protected folders with `-ExtraExcludePath`.
5. Run `Standard` mode if the preview looks correct.
6. Use `Aggressive` mode only if you specifically want the heavier system cleanup.

## Troubleshooting

If the script reopens with a UAC prompt:

- That is expected. Some cleanup targets require administrator rights.

If a cache folder cannot be removed:

- The owning application may still be running.
- Close the application and run the cleaner again.

If disk space does not change much:

- Many caches are already small or already empty.
- Use `Preview` mode to verify what the script finds.

If an application rebuilds data on next launch:

- That is normal for cache cleanup.

If you want to protect additional folders:

- Pass them with `-ExtraExcludePath`.

## Development Notes

- The project is intentionally a single-file PowerShell tool.
- The menu is interactive, but the script also supports direct non-interactive execution through `-Mode`.
- Logs are printed live so operators can see exactly what the script attempted to do.
