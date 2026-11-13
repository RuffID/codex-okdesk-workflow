#requires -Version 7.5
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'OkdeskApi.psm1') -DisableNameChecking -ErrorAction Stop

function Assert-OkdeskOwnedPath {
    param([string]$Root, [string]$Path)
    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd([IO.Path]::DirectorySeparatorChar)
    $pathFull = [IO.Path]::GetFullPath($Path)
    if ($pathFull -ne $rootFull -and -not $pathFull.StartsWith($rootFull + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Local path leaves the owned Okdesk data directory.'
    }
    $current = $pathFull
    while ($current) {
        if (Test-Path -LiteralPath $current) {
            if (([IO.File]::GetAttributes($current) -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw 'Reparse points are not allowed in Okdesk data paths.'
            }
        }
        $current = [IO.Path]::GetDirectoryName($current)
    }
}

function Write-OkdeskJson {
    param([string]$Path, $Value, [Collections.IDictionary]$Context)
    $json = ConvertTo-Json -InputObject $Value -Depth 100
    $json = Protect-OkdeskText $json $Context
    $temporary = $Path + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    try {
        [IO.File]::WriteAllText($temporary, $json, [Text.UTF8Encoding]::new($false))
        [IO.File]::Move($temporary, $Path, $true)
    }
    finally { if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) } }
}

function Remove-OkdeskExpiredRuns {
    param([string]$RunsRoot, [string]$Namespace, [datetimeoffset]$Now)
    $removed = 0
    foreach ($run in [IO.Directory]::EnumerateDirectories($RunsRoot)) {
        Assert-OkdeskOwnedPath $RunsRoot $run
        if ([IO.Path]::GetFileName($run) -cnotmatch '^[a-f0-9]{32}$') { throw 'Unexpected directory in the owned runs directory.' }
        $markerPath = Join-Path $run '.okdesk-run.json'
        Assert-OkdeskOwnedPath $RunsRoot $markerPath
        if (-not [IO.File]::Exists($markerPath)) { throw 'Owned run marker is missing; cleanup stopped.' }
        try { $marker = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($markerPath)) -AsHashtable -DateKind String -ErrorAction Stop }
        catch { throw 'Owned run marker is invalid; cleanup stopped.' }
        if ($marker['namespace'] -cne $Namespace -or $marker['runId'] -cne [IO.Path]::GetFileName($run)) { throw 'Owned run marker does not match its directory.' }
        $createdAt = [datetimeoffset]::MinValue
        if (-not [datetimeoffset]::TryParse([string]$marker['createdAt'], [ref]$createdAt)) { throw 'Owned run has an invalid timestamp.' }
        if ($createdAt -gt $Now.AddDays(-30)) { continue }

        # Validate the whole tree before the first deletion; never follow links.
        $files = [Collections.Generic.List[string]]::new()
        $directories = [Collections.Generic.List[string]]::new()
        $pending = [Collections.Generic.Stack[string]]::new()
        $pending.Push($run)
        while ($pending.Count -gt 0) {
            $directory = $pending.Pop()
            Assert-OkdeskOwnedPath $RunsRoot $directory
            $directories.Add($directory)
            foreach ($entry in [IO.Directory]::EnumerateFileSystemEntries($directory)) {
                Assert-OkdeskOwnedPath $RunsRoot $entry
                if (([IO.File]::GetAttributes($entry) -band [IO.FileAttributes]::Directory) -ne 0) { $pending.Push($entry) }
                else { $files.Add($entry) }
            }
        }
        foreach ($file in $files) { [IO.File]::Delete($file) }
        for ($index = $directories.Count - 1; $index -ge 0; $index--) { [IO.Directory]::Delete($directories[$index], $false) }
        $removed++
    }
    return $removed
}

function New-OkdeskState {
    param([string]$RepositoryRoot, [Collections.IDictionary]$Context)
    $dataRoot = Join-Path $RepositoryRoot 'data'
    $stateRoot = Join-Path $dataRoot $Context.namespace
    $runsRoot = Join-Path $stateRoot 'runs'
    Assert-OkdeskOwnedPath $dataRoot $runsRoot
    [void][IO.Directory]::CreateDirectory($runsRoot)
    $lockPath = Join-Path $stateRoot '.lock'
    Assert-OkdeskOwnedPath $dataRoot $lockPath
    try { $stateLock = [IO.File]::Open($lockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None) }
    catch { throw 'Okdesk data is busy; wait for the other client invocation to finish.' }
    try {
        $now = [datetimeoffset]::UtcNow
        $retentionPath = Join-Path $stateRoot 'retention.json'
        Assert-OkdeskOwnedPath $dataRoot $retentionPath
        $runCleanup = $true
        if ([IO.File]::Exists($retentionPath)) {
            try { $retention = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($retentionPath)) -AsHashtable -DateKind String -ErrorAction Stop }
            catch { throw 'Local retention state is invalid.' }
            $lastRun = [datetimeoffset]::MinValue
            if (-not [datetimeoffset]::TryParse([string]$retention['checkedAt'], [ref]$lastRun)) { throw 'Local retention timestamp is invalid.' }
            $runCleanup = $lastRun -le $now.AddHours(-24)
        }
        $removed = 0
        if ($runCleanup) {
            $removed = Remove-OkdeskExpiredRuns $runsRoot $Context.namespace $now
            Write-OkdeskJson $retentionPath @{ checkedAt = $now.ToString('o') } $Context
        }
        $runId = [guid]::NewGuid().ToString('N')
        $runPath = Join-Path $runsRoot $runId
        [void][IO.Directory]::CreateDirectory($runPath)
        Write-OkdeskJson (Join-Path $runPath '.okdesk-run.json') @{
            namespace = $Context.namespace; runId = $runId; createdAt = $now.ToString('o')
        } $Context
        return @{ root = $runPath; stateLock = $stateLock; cleanedRuns = $removed; collectedAt = $now.ToString('o') }
    }
    catch { $stateLock.Dispose(); throw }
}

function Get-OkdeskSafeFileName {
    param([string]$Name)
    $safe = [regex]::Replace($Name, '[\x00-\x1f<>:"/\\|?*]', '_').Trim().TrimEnd('.')
    if (-not $safe) { $safe = 'attachment.bin' }
    if ($safe.Length -gt 120) {
        $extension = [IO.Path]::GetExtension($safe)
        if ($extension.Length -gt 15) { $extension = '' }
        $safe = $safe.Substring(0, 100) + $extension
    }
    return $safe
}

Export-ModuleMember -Function Assert-OkdeskOwnedPath, Write-OkdeskJson, New-OkdeskState, Get-OkdeskSafeFileName
