# Bakunawa.Runspace.psm1 — Parallel runspace pool execution engine

$script:RunspacePool = $null
$script:RunspaceThrottle = 0

function Get-RunspaceThrottleLimit {
    [CmdletBinding()]
    param()
    if ($script:RunspaceThrottle -gt 0) { return $script:RunspaceThrottle }
    $cfg = Get-UserConfig
    $limit = if ($cfg.cleanupMode.parallelEnabled) { $cfg.runspaceThrottle } else { 0 }
    if ($limit -and [int]::TryParse($limit, [ref]0)) {
        $script:RunspaceThrottle = $limit
    } else {
        $script:RunspaceThrottle = [Math]::Max(1, [Environment]::ProcessorCount)
    }
    return $script:RunspaceThrottle
}

function Initialize-RunspacePool {
    [CmdletBinding()]
    param()
    if ($script:RunspacePool -and -not $script:RunspacePool.IsDisposed) { return $script:RunspacePool }

    try {
        $throttle = Get-RunspaceThrottleLimit
        $runspacePool = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspacePool(1, $throttle)
        $runspacePool.ApartmentState = [System.Threading.ApartmentState]::STA
        $runspacePool.Open()
        $script:RunspacePool = $runspacePool
        return $runspacePool
    } catch {
        Write-Verbose "Initialize-RunspacePool error: $($_.Exception.Message)"
        throw
    }
}

function Close-RunspacePool {
    [CmdletBinding()]
    param()
    if ($script:RunspacePool -and -not $script:RunspacePool.IsDisposed) {
        try {
            $script:RunspacePool.Close()
        } catch {
            Write-Verbose "Close-RunspacePool Close error: $($_.Exception.Message)"
        }
        try {
            $script:RunspacePool.Dispose()
        } catch {
            Write-Verbose "Close-RunspacePool Dispose error: $($_.Exception.Message)"
        }
        $script:RunspacePool = $null
    }
}

function Invoke-Parallel {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Items,
        [Parameter(Mandatory)][ValidateNotNull()][scriptblock]$ScriptBlock,
        [ValidateRange(0, 512)][int]$ThrottleLimit = 0
    )

    if (-not $Items -or $Items.Count -eq 0) { return @() }

    $ownPool = $false
    $pool = if ($ThrottleLimit -gt 0) {
        $throttle = $ThrottleLimit
        $runspacePool = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspacePool(1, $throttle)
        $runspacePool.ApartmentState = [System.Threading.ApartmentState]::STA
        $runspacePool.Open()
        $ownPool = $true
        $runspacePool
    } else {
        Initialize-RunspacePool
    }

    $results = [System.Collections.Concurrent.ConcurrentBag[System.Object]]::new()
    $jobs = [System.Collections.Generic.List[PSCustomObject]]::new()

    foreach ($item in $Items) {
        $ps = [System.Management.Automation.PowerShell]::Create()
        $ps.RunspacePool = $pool
        $null = $ps.AddScript($ScriptBlock).AddArgument($item)
        $jobs.Add([PSCustomObject]@{
            PowerShell = $ps
            AsyncResult = $ps.BeginInvoke()
        })
    }

    foreach ($job in $jobs) {
        try {
            $output = $job.PowerShell.EndInvoke($job.AsyncResult)
            foreach ($o in $output) {
                if ($null -ne $o) { $results.Add($o) }
            }
        } catch {
            Write-Verbose "Invoke-Parallel job error: $($_.Exception.Message)"
        } finally {
            $job.PowerShell.Dispose()
        }
    }

    # Clean up owned pool; do NOT dispose the global pool
    if ($ownPool -and $pool) {
        try { $pool.Close() } catch {}
        try { $pool.Dispose() } catch {}
    }

    return @($results.ToArray())
}

function Get-DirectorySizeParallel {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateNotNullOrEmpty()][string[]]$Paths)
    $validPaths = $Paths | Where-Object { Test-Path -LiteralPath $_ -PathType Container }
    if (-not $validPaths) { return @{} }

    $scriptBlock = {
        param($path)
        $size = 0
        try {
            $d = [System.IO.DirectoryInfo]::new($path)
            foreach ($f in $d.GetFiles()) { $size += $f.Length }
            foreach ($s in $d.GetDirectories()) {
                if (($s.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
                foreach ($sf in $s.GetFiles('*', [System.IO.SearchOption]::AllDirectories)) { $size += $sf.Length }
            }
        } catch {
            $size = Get-DirectorySize $path
        }
        [PSCustomObject]@{ Path = $path; Size = $size }
    }

    $results = Invoke-Parallel -Items $validPaths -ScriptBlock $scriptBlock
    $dict = @{}
    foreach ($r in $results) { if ($r -and $r.Path) { $dict[$r.Path] = $r.Size } }
    return $dict
}

Export-ModuleMember -Function Get-RunspaceThrottleLimit, Initialize-RunspacePool, Close-RunspacePool, Invoke-Parallel, Get-DirectorySizeParallel
