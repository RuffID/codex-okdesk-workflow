#requires -Version 7.5
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'OkdeskApi.psm1') -DisableNameChecking -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'OkdeskStorage.psm1') -DisableNameChecking -ErrorAction Stop

function ConvertTo-OkdeskPlainText {
    param([AllowEmptyString()][string]$Text)
    $textValue = [regex]::Replace($Text, '(?is)<(script|style)\b[^>]*>.*?</\1>', '')
    $textValue = [regex]::Replace($textValue, '(?i)<br\s*/?>|</(?:p|div|li|tr|h[1-6])>', "`n")
    $textValue = [regex]::Replace($textValue, '(?s)<[^>]*>', '')
    return [Net.WebUtility]::HtmlDecode($textValue).Trim()
}

function Get-OkdeskAttachmentCatalog {
    param([Collections.IDictionary]$Issue, [array]$Comments)
    $catalog = [ordered]@{}
    $owners = @(@{ source = 'issue'; value = $Issue })
    foreach ($comment in $Comments) { $owners += @{ source = "comment:$($comment['id'])"; value = $comment } }
    foreach ($owner in $owners) {
        if ($owner.value['attachments'] -isnot [array]) { throw 'Attachment list is missing or invalid; issue data may be restricted.' }
        foreach ($attachment in $owner.value['attachments']) {
            if ($attachment -isnot [Collections.IDictionary]) { throw 'Attachment metadata is invalid.' }
            Assert-OkdeskId $attachment['id']
            $size = 0L
            if (-not $attachment['attachment_file_name'] -or
                -not [long]::TryParse([string]$attachment['attachment_file_size'], [ref]$size) -or $size -lt 0) {
                throw 'Attachment filename or size is missing or invalid.'
            }
            $key = [string]$attachment['id']
            if (-not $catalog.Contains($key)) {
                $catalog[$key] = @{
                    id = $key; name = [string]$attachment['attachment_file_name']; bytes = $size
                    sources = [Collections.Generic.List[string]]::new()
                }
            }
            elseif ($catalog[$key].name -cne [string]$attachment['attachment_file_name'] -or $catalog[$key].bytes -ne $size) {
                throw 'Conflicting metadata was returned for the same attachment ID.'
            }
            $catalog[$key].sources.Add($owner.source)
        }
    }
    return ,@($catalog.Values)
}

function Read-OkdeskIssueData {
    param([Collections.IDictionary]$Context, [long]$IssueId, [switch]$WithEquipment)
    $issue = Get-OkdeskObject $Context "issues/$IssueId" $IssueId
    if ($issue['equipment_ids'] -isnot [array] -or $issue['parameters'] -isnot [array]) {
        throw 'Full issue data is missing. Use an employee API key with access to the issue and equipment.'
    }
    $comments = Get-OkdeskArray $Context "issues/$IssueId/comments"
    $seen = [Collections.Generic.HashSet[long]]::new()
    foreach ($comment in $comments) {
        Assert-OkdeskId $comment['id']
        if (-not $seen.Add([long]$comment['id']) -or -not $comment.Contains('content')) { throw 'Comment list contains an invalid or duplicate comment.' }
    }
    if ($issue['comments'] -isnot [Collections.IDictionary] -or -not $issue['comments'].Contains('count') -or
        [long]$issue['comments']['count'] -ne $comments.Count) {
        throw 'Comment count does not match the issue. Data may be restricted or may have changed during collection; read the issue again.'
    }
    $equipment = [Collections.Generic.List[object]]::new()
    $equipmentIds = [Collections.Generic.HashSet[long]]::new()
    foreach ($id in $issue['equipment_ids']) {
        Assert-OkdeskId $id
        if ($WithEquipment -and $equipmentIds.Add([long]$id)) {
            $item = Get-OkdeskObject $Context "equipments/$id" ([long]$id)
            if ($item['parameters'] -isnot [array]) { throw 'Equipment parameters are missing or invalid.' }
            $equipment.Add($item)
        }
    }
    return @{
        issue = $issue; comments = $comments; equipment = $equipment.ToArray()
        attachments = (Get-OkdeskAttachmentCatalog $issue $comments)
    }
}

function Save-OkdeskAttachments {
    param(
        [Collections.IDictionary]$Context, [Collections.IDictionary]$State, [long]$IssueId,
        [array]$Catalog, [string[]]$AttachmentIds, [string[]]$ApprovedLargeAttachmentIds
    )
    foreach ($id in @($AttachmentIds) + @($ApprovedLargeAttachmentIds)) {
        Assert-OkdeskId $id
        if ($id -notin @($Catalog | ForEach-Object { $_.id })) { throw 'Selected attachment does not belong to the requested issue or its comments.' }
        if ($AttachmentIds.Count -gt 0 -and $id -notin $AttachmentIds) { throw 'Large-file approval must refer to a selected attachment.' }
    }
    $directory = Join-Path $State.root 'attachments'
    [void][IO.Directory]::CreateDirectory($directory)
    foreach ($item in $Catalog) {
        if ($AttachmentIds.Count -gt 0 -and $item.id -notin $AttachmentIds) {
            @{ id = $item.id; name = $item.name; bytes = $item.bytes; sources = $item.sources.ToArray(); status = 'not-selected' }
            continue
        }
        $approved = $item.id -in $ApprovedLargeAttachmentIds
        if ($item.bytes -gt 500000000 -and -not $approved) {
            @{ id = $item.id; name = $item.name; bytes = $item.bytes; sources = $item.sources.ToArray(); status = 'confirmation-required' }
            continue
        }
        # The signed URL expires after 30 seconds: request it only when ready to download.
        $metadata = Get-OkdeskObject $Context "issues/$IssueId/attachments/$($item.id)" ([long]$item.id)
        if (-not $metadata['attachment_url'] -or [string]$metadata['attachment_file_name'] -cne $item.name -or
            [string]$metadata['attachment_file_size'] -cne [string]$item.bytes) {
            throw 'Attachment metadata changed or is incomplete; collect the issue again.'
        }
        $name = Get-OkdeskSafeFileName (Protect-OkdeskText $item.name $Context)
        $path = Join-Path $directory ($item.id + '-' + $name)
        Assert-OkdeskOwnedPath $State.root $path
        $download = Save-OkdeskRemoteFile $Context $metadata['attachment_url'] $path -ExpectedSize $item.bytes -ApprovedLarge:$approved
        $download['id'] = $item.id
        $download['name'] = $item.name
        $download['sources'] = $item.sources.ToArray()
        $download
    }
}

function Get-OkdeskImageReferences {
    param([Collections.IDictionary]$Bundle)
    $texts = @(@{ source = 'issue.description'; value = [string]$Bundle.issue['description'] })
    foreach ($comment in $Bundle.comments) { $texts += @{ source = "comment:$($comment['id'])"; value = [string]$comment['content'] } }
    foreach ($text in $texts) {
        foreach ($tag in [regex]::Matches($text.value, '(?is)<img\b[^>]*>')) {
            $match = [regex]::Match($tag.Value, '(?is)\ssrc\s*=\s*(?:"(?<v>[^"]*)"|''(?<v>[^'']*)''|(?<v>[^\s>]+))')
            @{ source = $text.source; value = [Net.WebUtility]::HtmlDecode($match.Groups['v'].Value) }
        }
    }
    $owners = @(@{ source = 'issue.parameter'; parameters = $Bundle.issue['parameters'] })
    foreach ($equipment in $Bundle.equipment) { $owners += @{ source = "equipment:$($equipment['id']).parameter"; parameters = $equipment['parameters'] } }
    foreach ($owner in $owners) {
        foreach ($parameter in $owner.parameters) {
            if ($parameter -isnot [Collections.IDictionary]) { throw 'A custom parameter has an invalid shape.' }
            $value = $parameter['value']
            if ($value -is [string] -and ($value -match '^data:image/' -or $value -match '^iVBORw0KGgo')) {
                @{ source = $owner.source + ':' + [string]$parameter['code']; value = $value }
            }
        }
    }
}

function Save-OkdeskImages {
    param([Collections.IDictionary]$Context, [Collections.IDictionary]$State, [Collections.IDictionary]$Bundle)
    $directory = Join-Path $State.root 'images'
    [void][IO.Directory]::CreateDirectory($directory)
    $index = 0
    foreach ($reference in @(Get-OkdeskImageReferences $Bundle)) {
        $index++
        $imageId = 'inline-' + $index.ToString('D4')
        $result = @{ id = $imageId; source = $reference.source }
        try {
            if (-not $reference.value) { throw 'Image has no src attribute; it may use srcset or another unsupported representation.' }
            $encoded = $null
            $extension = '.png'
            if ($reference.value -match '^data:image/(?<format>png|jpeg|gif|webp|bmp);base64,(?<encoded>[A-Za-z0-9+/=\s]+)$') {
                $encoded = $Matches['encoded']
                $extension = '.' + $Matches['format']
            }
            elseif ($reference.value -match '^iVBORw0KGgo[A-Za-z0-9+/=\s]*$') { $encoded = $reference.value }
            elseif ($reference.value -match '^data:') { throw 'Unsupported embedded image format.' }
            if ($null -ne $encoded) {
                if ($encoded.Length -gt 666666668) { throw 'Embedded image exceeds 500 MB; review it separately.' }
                try { $bytes = [Convert]::FromBase64String($encoded) }
                catch { throw 'Embedded image contains invalid base64.' }
                $path = Join-Path $directory ($imageId + $extension)
                [IO.File]::WriteAllBytes($path, $bytes)
                $result.status = 'downloaded'
                $result.path = $path
                $result.bytes = $bytes.LongLength
                $result.sha256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
            }
            else {
                $parsed = $null
                if (-not [uri]::TryCreate([uri]($Context.siteUrl + '/'), $reference.value, [ref]$parsed)) { throw 'Invalid inline image URL.' }
                $fileName = [uri]::UnescapeDataString([IO.Path]::GetFileName($parsed.AbsolutePath))
                $extension = [IO.Path]::GetExtension($fileName)
                if ($extension -notmatch '^\.(png|jpe?g|gif|webp|bmp|tiff?|avif)$') { $extension = '.image' }
                $path = Join-Path $directory ($imageId + $extension)
                $download = Save-OkdeskRemoteFile $Context $reference.value $path -ImageOnly
                foreach ($key in $download.Keys) { $result[$key] = $download[$key] }
            }
        }
        catch {
            $result.status = 'unavailable'
            $result.reason = Protect-OkdeskText $_.Exception.Message $Context
        }
        $result
    }
}

function Format-OkdeskParameter {
    param([Collections.IDictionary]$Parameter)
    $value = $Parameter['value']
    if ($value -is [string] -and ($value -match '^data:image/' -or $value -match '^iVBORw0KGgo')) { $valueText = '[embedded image: see snapshot and manifest]' }
    else { $valueText = ConvertTo-Json -InputObject $value -Depth 20 -Compress }
    return '- ' + [string]$Parameter['name'] + ' [' + [string]$Parameter['code'] + ']: ' + $valueText
}

function Write-OkdeskBundle {
    param([Collections.IDictionary]$Context, [Collections.IDictionary]$State, [Collections.IDictionary]$Bundle, [string]$Kind)
    $snapshotPath = Join-Path $State.root 'snapshot.json'
    Write-OkdeskJson $snapshotPath $Bundle $Context
    $lines = [Collections.Generic.List[string]]::new()
    $lines.Add('Collected at (UTC): ' + $State.collectedAt)
    if ($Kind -eq 'issue') {
        $issue = $Bundle.issue
        $lines.Add("# Issue $($issue['id']): $($issue['title'])")
        foreach ($field in @('status', 'priority', 'type', 'assignee', 'company_id', 'service_object_id', 'created_at', 'updated_at', 'equipment_ids')) {
            $lines.Add($field + ': ' + (ConvertTo-Json -InputObject $issue[$field] -Depth 10 -Compress))
        }
        $lines.Add("`n## Description")
        $lines.Add((ConvertTo-OkdeskPlainText ([string]$issue['description'])))
        $lines.Add("`n## Issue parameters")
        foreach ($parameter in $issue['parameters']) { $lines.Add((Format-OkdeskParameter $parameter)) }
        $lines.Add("`n## Comments")
        foreach ($comment in $Bundle.comments) {
            $lines.Add("### Comment $($comment['id']) | $($comment['published_at']) | public=$($comment['public'])")
            $lines.Add('Author: ' + (ConvertTo-Json -InputObject $comment['author'] -Depth 10 -Compress))
            $lines.Add((ConvertTo-OkdeskPlainText ([string]$comment['content'])))
        }
        $lines.Add("`n## Attachments")
        foreach ($attachment in $Bundle.attachments) { $lines.Add("- $($attachment.id): $($attachment.name) ($($attachment.bytes) bytes)") }
    }
    $lines.Add("`n## Equipment")
    foreach ($equipment in $Bundle.equipment) {
        $lines.Add("### Equipment $($equipment['id'])")
        foreach ($field in @('equipment_kind', 'equipment_manufacturer', 'equipment_model', 'serial_number', 'inventory_number', 'company', 'maintenance_entity_id', 'parent_id', 'updated_at')) {
            $lines.Add($field + ': ' + (ConvertTo-Json -InputObject $equipment[$field] -Depth 10 -Compress))
        }
        $lines.Add((ConvertTo-OkdeskPlainText ([string]$equipment['comment'])))
        foreach ($parameter in $equipment['parameters']) { $lines.Add((Format-OkdeskParameter $parameter)) }
    }
    $textPath = Join-Path $State.root 'context.txt'
    [IO.File]::WriteAllText($textPath, (Protect-OkdeskText ($lines -join "`n") $Context), [Text.UTF8Encoding]::new($false))
    return @{ snapshotPath = $snapshotPath; textPath = $textPath }
}

function Get-OkdeskIssueBundle {
    param(
        [Collections.IDictionary]$Context, [Collections.IDictionary]$State, [long]$IssueId,
        [switch]$WithAttachments, [switch]$AttachmentsOnly,
        [string[]]$AttachmentIds = @(), [string[]]$ApprovedLargeAttachmentIds = @()
    )
    $bundle = Read-OkdeskIssueData $Context $IssueId -WithEquipment:(-not $AttachmentsOnly)
    $paths = Write-OkdeskBundle $Context $State $bundle 'issue'
    $downloads = @()
    $images = @()
    if ($WithAttachments) {
        $downloads = @(Save-OkdeskAttachments $Context $State $IssueId $bundle.attachments $AttachmentIds $ApprovedLargeAttachmentIds)
        if (-not $AttachmentsOnly) { $images = @(Save-OkdeskImages $Context $State $bundle) }
    }
    $manifestPath = Join-Path $State.root 'manifest.json'
    $reviewRequired = @($downloads | Where-Object { $_['status'] -eq 'confirmation-required' }).Count -gt 0 -or
        @($images | Where-Object { $_['status'] -in @('unavailable', 'confirmation-required') }).Count -gt 0
    Write-OkdeskJson $manifestPath @{ downloads = $downloads; images = $images; reviewRequired = $reviewRequired } $Context
    return @{
        issueId = $IssueId; title = $bundle.issue['title']; collectedAt = $State.collectedAt
        snapshotPath = $paths.snapshotPath; textPath = $paths.textPath; manifestPath = $manifestPath
        commentsCount = $bundle.comments.Count; equipmentCount = $bundle.equipment.Count
        attachmentsCount = $bundle.attachments.Count; attachmentsRequested = [bool]$WithAttachments
        downloads = $downloads; images = $images; reviewRequired = $reviewRequired
    }
}

function Get-OkdeskEquipmentBundle {
    param([Collections.IDictionary]$Context, [Collections.IDictionary]$State, [long]$EquipmentId)
    $equipment = Get-OkdeskObject $Context "equipments/$EquipmentId" $EquipmentId
    if ($equipment['parameters'] -isnot [array]) { throw 'Equipment parameters are missing or invalid.' }
    $bundle = @{ equipment = @($equipment) }
    $paths = Write-OkdeskBundle $Context $State $bundle 'equipment'
    return @{ equipmentId = $EquipmentId; collectedAt = $State.collectedAt; snapshotPath = $paths.snapshotPath; textPath = $paths.textPath }
}

Export-ModuleMember -Function Get-OkdeskIssueBundle, Get-OkdeskEquipmentBundle
