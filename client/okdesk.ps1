#requires -Version 7.5
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('GetIssue', 'DownloadAttachments', 'GetEquipment', 'GetEquipmentParameters')][string]$Command,
    [ValidateRange(1, [long]::MaxValue)][long]$IssueId,
    [ValidateRange(1, [long]::MaxValue)][long]$EquipmentId,
    [string[]]$AttachmentIds = @(),
    [string[]]$ApprovedLargeAttachmentIds = @(),
    [string[]]$TrustedFileHosts = @(),
    [switch]$WithAttachments
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$context = $null
$state = $null

try {
    $allowedParameters = switch ($Command) {
        'GetIssue' { @('Command', 'IssueId', 'WithAttachments', 'AttachmentIds', 'ApprovedLargeAttachmentIds', 'TrustedFileHosts') }
        'DownloadAttachments' { @('Command', 'IssueId', 'AttachmentIds', 'ApprovedLargeAttachmentIds', 'TrustedFileHosts') }
        'GetEquipment' { @('Command', 'EquipmentId') }
        'GetEquipmentParameters' { @('Command') }
    }
    foreach ($name in $PSBoundParameters.Keys) {
        if ($name -notin $allowedParameters) { throw "Parameter $name is not supported by $Command." }
    }
    if ($Command -in @('GetIssue', 'DownloadAttachments') -and -not $PSBoundParameters.ContainsKey('IssueId')) { throw 'IssueId is required.' }
    if ($Command -eq 'GetEquipment' -and -not $PSBoundParameters.ContainsKey('EquipmentId')) { throw 'EquipmentId is required.' }
    if ($Command -eq 'GetIssue' -and -not $WithAttachments -and ($AttachmentIds.Count -gt 0 -or $ApprovedLargeAttachmentIds.Count -gt 0)) {
        throw 'Attachment selection and approval require WithAttachments.'
    }
    if ($Command -eq 'GetIssue' -and -not $WithAttachments -and $TrustedFileHosts.Count -gt 0) {
        throw 'TrustedFileHosts requires WithAttachments.'
    }
    foreach ($id in @($AttachmentIds) + @($ApprovedLargeAttachmentIds)) {
        $parsed = 0L
        if ($id -cnotmatch '^[1-9][0-9]*$' -or -not [long]::TryParse($id, [ref]$parsed)) { throw 'Attachment IDs must be positive numbers.' }
    }
    Import-Module (Join-Path $PSScriptRoot 'modules/OkdeskApi.psm1') -Force -DisableNameChecking
    Import-Module (Join-Path $PSScriptRoot 'modules/OkdeskStorage.psm1') -Force -DisableNameChecking
    Import-Module (Join-Path $PSScriptRoot 'modules/OkdeskRead.psm1') -Force -DisableNameChecking
    $context = New-OkdeskContext -TrustedFileHosts $TrustedFileHosts
    $state = New-OkdeskState (Split-Path $PSScriptRoot -Parent) $context
    $result = switch ($Command) {
        'GetIssue' { Get-OkdeskIssueBundle $context $state $IssueId -WithAttachments:$WithAttachments -AttachmentIds $AttachmentIds -ApprovedLargeAttachmentIds $ApprovedLargeAttachmentIds }
        'DownloadAttachments' { Get-OkdeskIssueBundle $context $state $IssueId -WithAttachments -AttachmentsOnly -AttachmentIds $AttachmentIds -ApprovedLargeAttachmentIds $ApprovedLargeAttachmentIds }
        'GetEquipment' { Get-OkdeskEquipmentBundle $context $state $EquipmentId }
        'GetEquipmentParameters' {
            $parameters = Get-OkdeskArray $context 'equipments/parameters'
            $path = Join-Path $state.root 'equipment-parameters.json'
            Write-OkdeskJson $path $parameters $context
            @{ snapshotPath = $path; count = $parameters.Count }
        }
    }
    $output = ConvertTo-Json -InputObject @{ ok = $true; command = $Command; cleanedRuns = $state.cleanedRuns; data = $result } -Depth 100
    Protect-OkdeskText $output $context
}
catch {
    $message = $_.Exception.Message
    if ($null -ne $context) { $message = Protect-OkdeskText $message $context }
    $errorResult = @{ ok = $false; message = $message }
    if ($null -ne $state) { $errorResult['partialDataPath'] = $state.root }
    [Console]::Error.WriteLine((ConvertTo-Json -InputObject $errorResult -Compress))
    exit 1
}
finally {
    if ($null -ne $state) { $state.stateLock.Dispose() }
    if ($null -ne $context) { $context.apiClient.Dispose(); $context.fileClient.Dispose() }
}
