# Windows PowerShell 5.1 or PowerShell 7 on Windows. No administrator rights needed.
# Run: powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File ".\props_roblox_to_json_start.ps1"
param(
    [ValidateRange(1024, 65535)]
    [int]$Port = 28743
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Format-PropsJson {
    param([Parameter(Mandatory)][string]$Json)
    # Validate, then format the original text without converting its numbers,
    # empty objects, arrays, or case-sensitive keys through PowerShell objects.
    if ($PSVersionTable.PSVersion.Major -ge 6) {
        $document = [System.Text.Json.JsonDocument]::Parse($Json)
        $document.Dispose()
    } else {
        Add-Type -AssemblyName System.Web.Extensions
        $validator = New-Object System.Web.Script.Serialization.JavaScriptSerializer
        $validator.MaxJsonLength = 64MB
        $validator.RecursionLimit = 128
        $null = $validator.DeserializeObject($Json)
    }
    if (-not $Json.TrimStart().StartsWith('[')) { throw 'Expected a JSON array.' }
    $builder = New-Object System.Text.StringBuilder
    $indent = 0
    $inString = $false
    $escaped = $false
    for ($index = 0; $index -lt $Json.Length; $index++) {
        $character = $Json[$index]
        if ($inString) {
            $null = $builder.Append($character)
            if ($escaped) { $escaped = $false }
            elseif ($character -eq '\') { $escaped = $true }
            elseif ($character -eq '"') { $inString = $false }
            continue
        }
        if ([char]::IsWhiteSpace($character)) { continue }
        switch ($character) {
            '"' { $inString = $true; $null = $builder.Append($character) }
            { $_ -eq '[' -or $_ -eq '{' } {
                $null = $builder.Append($character)
                $nextIndex = $index + 1
                while ($nextIndex -lt $Json.Length -and [char]::IsWhiteSpace($Json[$nextIndex])) { $nextIndex++ }
                $closing = if ($character -eq '[') { ']' } else { '}' }
                if ($nextIndex -lt $Json.Length -and $Json[$nextIndex] -eq $closing) {
                    $null = $builder.Append($closing)
                    $index = $nextIndex
                } else {
                    $indent++
                    $null = $builder.Append("`r`n" + ('  ' * $indent))
                }
            }
            { $_ -eq ']' -or $_ -eq '}' } {
                $indent--
                $null = $builder.Append("`r`n" + ('  ' * $indent) + $character)
            }
            ',' { $null = $builder.Append(",`r`n" + ('  ' * $indent)) }
            ':' { $null = $builder.Append(': ') }
            default { $null = $builder.Append($character) }
        }
    }
    return $builder.ToString() + "`r`n"
}

function Write-PropsJsonFile {
    param([string]$Destination, [string]$FormattedJson)
    $temporaryPath = $null
    try {
        # Write beside the destination first; an interrupted write cannot truncate
        # an existing JSON. Replacement follows the user's overwrite confirmation.
        $directory = [System.IO.Path]::GetDirectoryName($Destination)
        $temporaryPath = [System.IO.Path]::Combine($directory, '.props-' + [guid]::NewGuid().ToString('N') + '.tmp')
        [System.IO.File]::WriteAllText($temporaryPath, $FormattedJson, (New-Object System.Text.UTF8Encoding($false)))
        if ([System.IO.File]::Exists($Destination)) {
            [System.IO.File]::Replace($temporaryPath, $Destination, [System.Management.Automation.Language.NullString]::Value)
        } else {
            [System.IO.File]::Move($temporaryPath, $Destination)
        }
        $temporaryPath = $null
    } finally {
        if ($temporaryPath -and [System.IO.File]::Exists($temporaryPath)) { [System.IO.File]::Delete($temporaryPath) }
    }
}

function Save-PropsJson {
    param([string]$Json, [string]$SuggestedName)
    $dialog = $null
    $owner = $null
    try {
        $formatted = Format-PropsJson -Json $Json
        Add-Type -AssemblyName System.Windows.Forms
        $dialog = New-Object System.Windows.Forms.SaveFileDialog
        $dialog.Title = 'Save Roblox props as JSON'
        $dialog.Filter = 'JSON files (*.json)|*.json'
        $dialog.DefaultExt = 'json'
        $dialog.AddExtension = $true
        $dialog.OverwritePrompt = $true
        $dialog.RestoreDirectory = $true
        $safeName = $SuggestedName -replace '[\x00-\x1F<>:"/\\|?*]', '_'
        $safeName = $safeName.Trim().TrimEnd('.')
        if ([string]::IsNullOrWhiteSpace($safeName)) { $safeName = 'props' }
        if ($safeName.Length -gt 100) { $safeName = $safeName.Substring(0, 100) }
        $dialog.FileName = $safeName + '.json'
        $owner = New-Object System.Windows.Forms.Form
        $owner.ShowInTaskbar = $false
        $owner.TopMost = $true
        $owner.Opacity = 0
        $owner.Width = 1
        $owner.Height = 1
        $owner.Show()
        $owner.Activate()
        if ($dialog.ShowDialog($owner) -ne [System.Windows.Forms.DialogResult]::OK) {
            return @{ state = 'cancelled' }
        }
        $destination = $dialog.FileName
        Write-PropsJsonFile -Destination $destination -FormattedJson $formatted
        return @{ state = 'saved'; path = $destination }
    } catch {
        return @{ state = 'error'; message = $_.Exception.Message }
    } finally {
        if ($dialog) { $dialog.Dispose() }
        if ($owner) { $owner.Dispose() }
    }
}

function New-PropsSaveWorker {
    param([string]$Json, [string]$SuggestedName)
    $runspace = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $runspace.ApartmentState = 'STA'
    $runspace.ThreadOptions = 'ReuseThread'
    $runspace.Open()
    $pipeline = [powershell]::Create()
    $pipeline.Runspace = $runspace
    $scriptText = 'param($Json, $SuggestedName)' + "`n" +
        'function Format-PropsJson {' + ${function:Format-PropsJson}.ToString() + "}`n" +
        'function Write-PropsJsonFile {' + ${function:Write-PropsJsonFile}.ToString() + "}`n" +
        'function Save-PropsJson {' + ${function:Save-PropsJson}.ToString() + "}`n" +
        'Save-PropsJson -Json $Json -SuggestedName $SuggestedName'
    $null = $pipeline.AddScript($scriptText).AddArgument($Json).AddArgument($SuggestedName)
    return @{ pipeline = $pipeline; runspace = $runspace; handle = $pipeline.BeginInvoke() }
}

function Read-PropsRequest {
    param([System.Net.Sockets.TcpClient]$Client)
    $stream = $Client.GetStream()
    $stream.ReadTimeout = 10000
    $stream.WriteTimeout = 10000
    $headerBytes = New-Object 'System.Collections.Generic.List[byte]'
    # Read only through CRLFCRLF; the remaining bytes belong to the UTF-8 body.
    while ($true) {
        $value = $stream.ReadByte()
        if ($value -lt 0) { throw 'Connection closed before HTTP headers.' }
        $headerBytes.Add([byte]$value)
        $count = $headerBytes.Count
        if ($count -gt 16384) { throw 'HTTP headers are too large.' }
        if ($count -ge 4 -and $headerBytes[$count-4] -eq 13 -and $headerBytes[$count-3] -eq 10 -and
            $headerBytes[$count-2] -eq 13 -and $headerBytes[$count-1] -eq 10) { break }
    }
    $lines = [System.Text.Encoding]::ASCII.GetString($headerBytes.ToArray()) -split "`r`n"
    $requestLine = $lines[0] -split ' '
    if ($requestLine.Count -ne 3) { throw 'Invalid HTTP request line.' }
    $headers = @{}
    foreach ($line in $lines[1..($lines.Length-1)]) {
        $separator = $line.IndexOf(':')
        if ($separator -gt 0) { $headers[$line.Substring(0, $separator).Trim()] = $line.Substring($separator+1).Trim() }
    }
    if ($headers.ContainsKey('Transfer-Encoding')) { throw 'Chunked requests are not supported.' }
    [int]$length = 0
    if ($headers.ContainsKey('Content-Length') -and -not [int]::TryParse($headers['Content-Length'], [ref]$length)) {
        throw 'Invalid Content-Length.'
    }
    if ($length -lt 0 -or $length -gt 32MB) { throw 'JSON exceeds the 32 MB limit.' }
    if ($headers.ContainsKey('Expect') -and $headers['Expect'] -eq '100-continue') {
        $interim = [System.Text.Encoding]::ASCII.GetBytes("HTTP/1.1 100 Continue`r`n`r`n")
        $stream.Write($interim, 0, $interim.Length)
    }
    $bodyBytes = New-Object byte[] $length
    $offset = 0
    while ($offset -lt $length) {
        $readCount = $stream.Read($bodyBytes, $offset, $length-$offset)
        if ($readCount -eq 0) { throw 'Connection closed before the complete JSON was received.' }
        $offset += $readCount
    }
    if ($headers.ContainsKey('Origin')) { throw 'Browser requests are not accepted.' }
    return @{ method = $requestLine[0]; path = $requestLine[1]; headers = $headers;
        body = (New-Object System.Text.UTF8Encoding($false, $true)).GetString($bodyBytes) }
}

function Write-PropsResponse {
    param([System.Net.Sockets.TcpClient]$Client, [int]$Status, [object]$Body)
    $json = ConvertTo-Json -InputObject $Body -Depth 10 -Compress
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $reason = switch ($Status) { 200 { 'OK' } 202 { 'Accepted' } 400 { 'Bad Request' } 404 { 'Not Found' } 409 { 'Conflict' } default { 'Error' } }
    $header = "HTTP/1.1 $Status $reason`r`nContent-Type: application/json; charset=utf-8`r`nContent-Length: $($bytes.Length)`r`nCache-Control: no-store`r`nConnection: close`r`n`r`n"
    $headerBytes = [System.Text.Encoding]::ASCII.GetBytes($header)
    $stream = $Client.GetStream()
    $stream.Write($headerBytes, 0, $headerBytes.Length)
    $stream.Write($bytes, 0, $bytes.Length)
    $stream.Flush()
}

function Start-PropsHelper {
    param([int]$ListenPort = 28743)
    $listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, $ListenPort)
    $listener.Server.ExclusiveAddressUse = $true
    $worker = $null
    $activeId = $null
    $statuses = @{}
    try {
        $listener.Start()
        Write-Host "props_roblox_to_json: ready at http://127.0.0.1:$ListenPort" -ForegroundColor Green
        Write-Host 'Run props_roblox_to_json.lua in Studio Command Bar. Ctrl+C stops this helper.'
        while ($true) {
            if ($worker -and $worker.handle.IsCompleted) {
                try {
                    $result = @($worker.pipeline.EndInvoke($worker.handle))
                    if ($result.Count -ne 1 -or -not $result[0].ContainsKey('state')) { throw 'Save worker returned no result.' }
                    $statuses[$activeId] = $result[0]
                } catch {
                    $statuses[$activeId] = @{ state = 'error'; message = $_.Exception.Message }
                } finally {
                    $worker.pipeline.Dispose()
                    $worker.runspace.Dispose()
                    $worker = $null
                }
                Write-Host (ConvertTo-Json -InputObject $statuses[$activeId] -Compress)
            }
            if (-not $listener.Pending()) { Start-Sleep -Milliseconds 100; continue }
            $client = $listener.AcceptTcpClient()
            try {
                $request = Read-PropsRequest -Client $client
                if ($request.method -eq 'GET' -and $request.path -eq '/health') {
                    Write-PropsResponse $client 200 @{ service = 'props_roblox_to_json'; version = 1 }
                } elseif ($request.method -eq 'GET' -and $request.path -match '^/status/([0-9a-fA-F-]{36})$') {
                    $requestedId = $Matches[1]
                    if ($statuses.ContainsKey($requestedId)) { Write-PropsResponse $client 200 $statuses[$requestedId] }
                    else { Write-PropsResponse $client 404 @{ message = 'Export not found; the helper may have restarted.' } }
                } elseif ($request.method -eq 'POST' -and $request.path -eq '/exports') {
                    if (-not $request.headers.ContainsKey('Content-Type') -or $request.headers['Content-Type'] -notmatch '^application/json(?:;|$)') {
                        throw 'Content-Type must be application/json.'
                    }
                    $payload = ConvertFrom-Json -InputObject $request.body
                    $parsedId = [guid]::Empty
                    if (-not [guid]::TryParse([string]$payload.id, [ref]$parsedId)) { throw 'Invalid export id.' }
                    $exportId = $parsedId.ToString()
                    if ($statuses.ContainsKey($exportId)) {
                        Write-PropsResponse $client 200 $statuses[$exportId]
                    } elseif ($worker) {
                        Write-PropsResponse $client 409 @{ message = 'Finish the previous Save As dialog first.' }
                    } else {
                        if ($payload.json -isnot [string] -or $payload.name -isnot [string]) { throw 'Expected string fields: json and name.' }
                        $null = Format-PropsJson -Json $payload.json
                        # Keep recent results for Studio polling, bound memory usage.
                        if ($statuses.Count -ge 20) { $statuses.Clear() }
                        $worker = New-PropsSaveWorker -Json $payload.json -SuggestedName $payload.name
                        $activeId = $exportId
                        $statuses[$exportId] = @{ state = 'pending' }
                        Write-PropsResponse $client 202 $statuses[$exportId]
                    }
                } else {
                    Write-PropsResponse $client 404 @{ message = 'Unknown helper endpoint.' }
                }
            } catch {
                try { Write-PropsResponse $client 400 @{ message = $_.Exception.Message } } catch { }
            } finally {
                $client.Close()
            }
        }
    } finally {
        $listener.Stop()
        if ($worker) {
            $worker.pipeline.Stop()
            $worker.pipeline.Dispose()
            $worker.runspace.Dispose()
        }
    }
}

# Dot sourcing exposes the functions for verification without starting a server.
if ($MyInvocation.InvocationName -ne '.') {
    try { Start-PropsHelper -ListenPort $Port }
    catch {
        Write-Host ('Helper stopped: ' + $_.Exception.Message) -ForegroundColor Red
        exit 1
    }
}
