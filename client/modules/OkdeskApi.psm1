#requires -Version 7.5
Set-StrictMode -Version Latest

function New-OkdeskContext {
    $siteText = [Environment]::GetEnvironmentVariable('OKDESK_SITE_URL')
    $token = [Environment]::GetEnvironmentVariable('OKDESK_API_TOKEN')
    if (-not $siteText -or -not $token) { throw 'Set OKDESK_SITE_URL and OKDESK_API_TOKEN locally before connecting.' }
    $site = $null
    if (-not [uri]::TryCreate($siteText.Trim(), [UriKind]::Absolute, [ref]$site) -or
        $site.Scheme -ne 'https' -or $site.Host -notmatch '^[a-z0-9-]+\.okdesk\.ru$' -or
        $site.Port -ne 443 -or $site.UserInfo -or $site.Query -or $site.Fragment -or $site.AbsolutePath -ne '/') {
        throw 'OKDESK_SITE_URL must be https://<account>.okdesk.ru without a path, query or credentials.'
    }
    if ($token -match '\s') { throw 'OKDESK_API_TOKEN contains whitespace.' }
    $apiHandler = [Net.Http.HttpClientHandler]::new()
    $apiHandler.AllowAutoRedirect = $false
    $apiHandler.UseCookies = $false
    $fileHandler = [Net.Http.HttpClientHandler]::new()
    $fileHandler.AllowAutoRedirect = $false
    $fileHandler.UseCookies = $false
    $apiClient = [Net.Http.HttpClient]::new($apiHandler)
    $fileClient = [Net.Http.HttpClient]::new($fileHandler)
    $apiClient.Timeout = [timespan]::FromSeconds(60)
    $fileClient.Timeout = [timespan]::FromMinutes(10)
    $siteUrl = $site.GetLeftPart([UriPartial]::Authority)
    return @{
        apiClient = $apiClient; fileClient = $fileClient; siteUrl = $siteUrl; token = $token
        namespace = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData(
            [Text.Encoding]::UTF8.GetBytes($siteUrl + '|' + $token))).ToLowerInvariant()
    }
}

function Protect-OkdeskText {
    param([string]$Text, [Collections.IDictionary]$Context)
    if ($null -eq $Text) { return '' }
    if ($null -ne $Context) {
        $Text = $Text.Replace([string]$Context.token, '[REDACTED]')
        $Text = $Text.Replace([uri]::EscapeDataString([string]$Context.token), '[REDACTED]')
        $jsonToken = ConvertTo-Json -InputObject ([string]$Context.token) -Compress
        $Text = $Text.Replace($jsonToken.Substring(1, $jsonToken.Length - 2), '[REDACTED]')
    }
    return $Text
}

function Assert-OkdeskId {
    param($Value)
    $parsed = 0L
    if ([string]$Value -cnotmatch '^[1-9][0-9]*$' -or -not [long]::TryParse([string]$Value, [ref]$parsed)) {
        throw 'Okdesk returned an invalid positive numeric ID.'
    }
}

function Invoke-OkdeskJson {
    param([Collections.IDictionary]$Context, [string]$Resource)
    # No caller-controlled HTTP method, query, body, host or arbitrary resource.
    if ($Resource -cnotmatch '^(issues/[1-9][0-9]*(/comments|/attachments/[1-9][0-9]*)?|equipments/([1-9][0-9]*|parameters))$') {
        throw 'Resource is outside the read-only Okdesk allowlist.'
    }
    $url = $Context.siteUrl + '/api/v1/' + $Resource + '?api_token=' + [uri]::EscapeDataString($Context.token)
    $request = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Get, $url)
    [void]$request.Headers.TryAddWithoutValidation('Accept', 'application/json')
    $response = $null
    $cts = [Threading.CancellationTokenSource]::new([timespan]::FromSeconds(60))
    try {
        try { $response = $Context.apiClient.SendAsync($request, [Net.Http.HttpCompletionOption]::ResponseHeadersRead, $cts.Token).GetAwaiter().GetResult() }
        catch { throw 'Okdesk connection failed or timed out; no automatic retry was made.' }
        if (-not $response.IsSuccessStatusCode) { throw "Okdesk returned HTTP $([int]$response.StatusCode); no automatic retry was made." }
        if ($null -eq $response.Content.Headers.ContentType -or $response.Content.Headers.ContentType.MediaType -ne 'application/json') {
            throw 'Okdesk returned an unexpected content type instead of JSON.'
        }
        try {
            $json = $response.Content.ReadAsStringAsync($cts.Token).GetAwaiter().GetResult()
            $parsed = ConvertFrom-Json -InputObject $json -AsHashtable -Depth 100 -DateKind String -NoEnumerate -ErrorAction Stop
        }
        catch { throw 'Okdesk response could not be read as JSON.' }
        return ,$parsed
    }
    finally {
        if ($null -ne $response) { $response.Dispose() }
        $request.Dispose()
        $cts.Dispose()
    }
}

function Get-OkdeskObject {
    param([Collections.IDictionary]$Context, [string]$Resource, [long]$ExpectedId)
    $item = Invoke-OkdeskJson $Context $Resource
    if ($item -isnot [Collections.IDictionary]) { throw 'Okdesk object response has an unexpected shape.' }
    Assert-OkdeskId $item['id']
    if ([long]$item['id'] -ne $ExpectedId) { throw 'Okdesk returned an object with a different ID.' }
    return $item
}

function Get-OkdeskArray {
    param([Collections.IDictionary]$Context, [string]$Resource)
    $items = Invoke-OkdeskJson $Context $Resource
    if ($items -isnot [array]) { throw 'Okdesk list response has an unexpected shape; results may be incomplete.' }
    foreach ($item in $items) {
        if ($item -isnot [Collections.IDictionary]) { throw 'Okdesk list contains an invalid object.' }
    }
    return ,$items
}

function Get-OkdeskFileUri {
    param([Collections.IDictionary]$Context, [string]$Url)
    $target = $null
    if (-not [uri]::TryCreate([uri]($Context.siteUrl + '/'), $Url, [ref]$target)) { throw 'Invalid file URL.' }
    $siteHost = ([uri]$Context.siteUrl).Host
    if ($target.Scheme -ne 'https' -or $target.Port -ne 443 -or $target.UserInfo -or $target.Fragment -or
        $target.Host -notin @($siteHost, 'static.okdesk.ru') -or
        $target.Query -match '(?i)(^|[?&])api_token=' -or
        $target.AbsoluteUri.Contains([string]$Context.token) -or
        $target.AbsoluteUri.Contains([uri]::EscapeDataString([string]$Context.token))) {
        throw 'File URL is outside the trusted Okdesk hosts or contains an API token.'
    }
    return $target
}

function Save-OkdeskRemoteFile {
    param(
        [Collections.IDictionary]$Context, [string]$Url, [string]$Path,
        [long]$ExpectedSize = -1, [switch]$ApprovedLarge, [switch]$ImageOnly
    )
    $limit = 500000000L
    $target = Get-OkdeskFileUri $Context $Url
    $response = $null
    $cts = [Threading.CancellationTokenSource]::new([timespan]::FromMinutes(10))
    $partPath = $Path + '.part'
    try {
        for ($redirect = 0; $redirect -le 3; $redirect++) {
            $request = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Get, $target)
            try {
                try { $response = $Context.fileClient.SendAsync($request, [Net.Http.HttpCompletionOption]::ResponseHeadersRead, $cts.Token).GetAwaiter().GetResult() }
                catch { throw 'File download failed or timed out.' }
            }
            finally { $request.Dispose() }
            if ([int]$response.StatusCode -notin @(301, 302, 303, 307, 308)) { break }
            $location = $response.Headers.Location
            $response.Dispose()
            $response = $null
            if ($null -eq $location -or $redirect -eq 3) { throw 'File redirect is missing or exceeds the redirect limit.' }
            $next = [uri]::new($target, $location)
            $target = Get-OkdeskFileUri $Context $next.AbsoluteUri
        }
        if (-not $response.IsSuccessStatusCode) { throw "File download returned HTTP $([int]$response.StatusCode)." }
        $contentType = if ($null -ne $response.Content.Headers.ContentType) { $response.Content.Headers.ContentType.MediaType } else { '' }
        if ($contentType -in @('text/html', 'application/xhtml+xml') -or ($ImageOnly -and $contentType -notlike 'image/*')) {
            throw 'File endpoint returned a page or an unexpected image content type.'
        }
        $length = $response.Content.Headers.ContentLength
        if (-not $ApprovedLarge -and (($ExpectedSize -gt $limit) -or ($null -ne $length -and $length -gt $limit))) {
            return @{ status = 'confirmation-required'; bytes = $length }
        }
        $source = $null
        $destination = $null
        $total = 0L
        try {
            $source = $response.Content.ReadAsStreamAsync($cts.Token).GetAwaiter().GetResult()
            $destination = [IO.File]::Open($partPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
            $buffer = [byte[]]::new(81920)
            while (($read = $source.ReadAsync($buffer, 0, $buffer.Length, $cts.Token).GetAwaiter().GetResult()) -gt 0) {
                $total += $read
                if (-not $ApprovedLarge -and $total -gt $limit) { return @{ status = 'confirmation-required'; bytes = $total } }
                $destination.Write($buffer, 0, $read)
            }
        }
        catch { throw 'File stream could not be saved completely.' }
        finally {
            if ($null -ne $destination) { $destination.Dispose() }
            if ($null -ne $source) { $source.Dispose() }
        }
        if (($ExpectedSize -ge 0 -and $total -ne $ExpectedSize) -or ($null -ne $length -and $total -ne $length)) {
            throw 'Downloaded file size does not match its metadata.'
        }
        [IO.File]::Move($partPath, $Path)
        $hash = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
        return @{ status = 'downloaded'; path = $Path; bytes = $total; sha256 = $hash; contentType = $contentType }
    }
    finally {
        if ($null -ne $response) { $response.Dispose() }
        $cts.Dispose()
        if ([IO.File]::Exists($partPath)) { [IO.File]::Delete($partPath) }
    }
}

Export-ModuleMember -Function New-OkdeskContext, Protect-OkdeskText, Assert-OkdeskId, Get-OkdeskObject, Get-OkdeskArray, Save-OkdeskRemoteFile
