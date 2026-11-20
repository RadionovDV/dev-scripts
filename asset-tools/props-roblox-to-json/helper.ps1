# Windows PowerShell 5.1 or PowerShell 7 on Windows. No administrator rights needed.
# Run using props_roblox_to_json_start.cmd.
param(
    [ValidateRange(1024, 65535)]
    [int]$Port = 28743,
    [string]$SaveJobPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:PropsHelperPath = $PSCommandPath
$script:PropsSaveStagePath = $null

function Set-PropsSaveStage {
    param([string]$Message)
    if ($script:PropsSaveStagePath) {
        [System.IO.File]::WriteAllText($script:PropsSaveStagePath, $Message, (New-Object System.Text.UTF8Encoding($false)))
    }
}

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
        Set-PropsSaveStage 'Preparing JSON'
        $formatted = Format-PropsJson -Json $Json
        Set-PropsSaveStage 'Loading Windows dialog'
        Add-Type -AssemblyName System.Windows.Forms
        [System.Windows.Forms.Application]::EnableVisualStyles()
        $dialog = New-Object System.Windows.Forms.SaveFileDialog
        # The classic dialog avoids shell-extension/COM initialization hangs.
        $dialog.AutoUpgradeEnabled = $false
        $dialog.Title = 'Save Roblox props as JSON'
        $dialog.Filter = 'JSON files (*.json)|*.json'
        $dialog.DefaultExt = 'json'
        $dialog.AddExtension = $true
        $dialog.OverwritePrompt = $true
        $dialog.RestoreDirectory = $true
        $dialog.InitialDirectory = [Environment]::GetFolderPath('MyDocuments')
        $safeName = $SuggestedName -replace '[\x00-\x1F<>:"/\\|?*]', '_'
        $safeName = $safeName.Trim().TrimEnd('.')
        if ([string]::IsNullOrWhiteSpace($safeName)) { $safeName = 'props' }
        if ($safeName.Length -gt 100) { $safeName = $safeName.Substring(0, 100) }
        $dialog.FileName = $safeName + '.json'
        $owner = New-Object System.Windows.Forms.Form
        $owner.Text = 'Roblox props - Save JSON'
        $owner.StartPosition = 'CenterScreen'
        $owner.ShowInTaskbar = $true
        $owner.TopMost = $true
        $owner.Width = 440
        $owner.Height = 140
        $label = New-Object System.Windows.Forms.Label
        $label.Text = 'Choose a location for the exported JSON file.'
        $label.AutoSize = $true
        $label.Left = 20
        $label.Top = 25
        $owner.Controls.Add($label)
        $owner.Show()
        $owner.Activate()
        [System.Windows.Forms.Application]::DoEvents()
        Set-PropsSaveStage 'Save As dialog is open'
        if ($dialog.ShowDialog($owner) -ne [System.Windows.Forms.DialogResult]::OK) {
            return @{ state = 'cancelled' }
        }
        $destination = $dialog.FileName
        Set-PropsSaveStage 'Writing JSON file'
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
    $directory = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), 'props-json-' + [guid]::NewGuid().ToString('N'))
    $null = [System.IO.Directory]::CreateDirectory($directory)
    $jobPath = [System.IO.Path]::Combine($directory, 'job.json')
    $resultPath = [System.IO.Path]::Combine($directory, 'result.json')
    $stagePath = [System.IO.Path]::Combine($directory, 'stage.txt')
    $jobJson = ConvertTo-Json -InputObject @{ json = $Json; name = $SuggestedName } -Depth 5 -Compress
    [System.IO.File]::WriteAllText($jobPath, $jobJson, (New-Object System.Text.UTF8Encoding($false)))
    # Launch the native dialog in its own STA main thread, outside the HTTP loop.
    $executable = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $executable
    $startInfo.Arguments = '-NoProfile -STA -ExecutionPolicy Bypass -File "' + $script:PropsHelperPath + '" -SaveJobPath "' + $jobPath + '"'
    $startInfo.WorkingDirectory = $directory
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    # This child is an interactive file chooser. SW_HIDE would hide its first
    # native window even when Form.Show() is called explicitly.
    $startInfo.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Normal
    try {
        $process = [System.Diagnostics.Process]::Start($startInfo)
        return @{ process = $process; directory = $directory; resultPath = $resultPath; stagePath = $stagePath }
    } catch {
        [System.IO.File]::Delete($jobPath)
        [System.IO.Directory]::Delete($directory)
        throw
    }
}

function Get-PropsSaveResult {
    param([hashtable]$Worker)
    if ([System.IO.File]::Exists($Worker.resultPath)) {
        $text = [System.IO.File]::ReadAllText($Worker.resultPath, [System.Text.Encoding]::UTF8)
        return ConvertFrom-Json -InputObject $text
    }
    if ($Worker.process.HasExited) {
        return @{ state = 'error'; message = 'The Save As process exited without a result (exit code ' + $Worker.process.ExitCode + '). See helper.log.' }
    }
    return $null
}

function Close-PropsSaveWorker {
    param([hashtable]$Worker)
    if (-not $Worker.process.HasExited) { $Worker.process.WaitForExit(1000) | Out-Null }
    if (-not $Worker.process.HasExited) { $Worker.process.Kill(); $Worker.process.WaitForExit() }
    $Worker.process.Dispose()
    # Remove only the four files created for this one job, without recursive deletion.
    foreach ($fileName in @('job.json', 'result.json', 'result.tmp', 'stage.txt')) {
        $filePath = [System.IO.Path]::Combine($Worker.directory, $fileName)
        if ([System.IO.File]::Exists($filePath)) { [System.IO.File]::Delete($filePath) }
    }
    [System.IO.Directory]::Delete($Worker.directory)
}

function Write-PropsHelperLog {
    param([string]$Message)
    $line = [DateTime]::Now.ToString('yyyy-MM-dd HH:mm:ss') + ' ' + $Message
    Write-Host $line
    try { Add-Content -LiteralPath ([System.IO.Path]::ChangeExtension($script:PropsHelperPath, '.log')) -Value $line -Encoding UTF8 } catch { }
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
    $lastStage = $null
    $statuses = @{}
    try {
        $listener.Start()
        Write-Host "props_roblox_to_json: ready at http://127.0.0.1:$ListenPort" -ForegroundColor Green
        Write-Host 'Run props_roblox_to_json.lua in Studio Command Bar. Ctrl+C stops this helper.'
        while ($true) {
            if ($worker) {
                try {
                    $result = Get-PropsSaveResult -Worker $worker
                    if ($result) {
                        $statuses[$activeId] = $result
                        Close-PropsSaveWorker -Worker $worker
                        $worker = $null
                        Write-PropsHelperLog (ConvertTo-Json -InputObject $result -Compress)
                    } elseif ([System.IO.File]::Exists($worker.stagePath)) {
                        $stage = [System.IO.File]::ReadAllText($worker.stagePath)
                        $statuses[$activeId] = @{ state = 'pending'; stage = $stage }
                        if ($stage -and $stage -ne $lastStage) {
                            Write-PropsHelperLog ('Export ' + $activeId + ': ' + $stage)
                            $lastStage = $stage
                        }
                    }
                } catch {
                    $statuses[$activeId] = @{ state = 'error'; message = $_.Exception.Message }
                    if ($worker) { try { Close-PropsSaveWorker -Worker $worker } catch { } }
                    $worker = $null
                    Write-PropsHelperLog ('Save failed: ' + $_.Exception.Message)
                }
            }
            if (-not $listener.Pending()) { Start-Sleep -Milliseconds 100; continue }
            $client = $listener.AcceptTcpClient()
            try {
                $request = Read-PropsRequest -Client $client
                if ($request.method -eq 'GET' -and $request.path -eq '/health') {
                    $health = @{ service = 'props_roblox_to_json'; version = 1; build = 'dialog-process-2'; busy = [bool]$worker }
                    if ($worker) { $health.exportId = $activeId; $health.stage = $lastStage; $health.saveProcessId = $worker.process.Id }
                    Write-PropsResponse $client 200 $health
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
                        $lastStage = $null
                        $statuses[$exportId] = @{ state = 'pending' }
                        Write-PropsHelperLog ('Received export ' + $exportId + '; opening Save As, process ' + $worker.process.Id)
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
            Close-PropsSaveWorker -Worker $worker
        }
    }
}

# Dot sourcing exposes the functions for verification without starting a server.
if ($MyInvocation.InvocationName -ne '.') {
    try {
        if ($SaveJobPath) {
            $jobDirectory = [System.IO.Path]::GetDirectoryName($SaveJobPath)
            $script:PropsSaveStagePath = [System.IO.Path]::Combine($jobDirectory, 'stage.txt')
            $job = ConvertFrom-Json -InputObject ([System.IO.File]::ReadAllText($SaveJobPath, [System.Text.Encoding]::UTF8))
            $result = Save-PropsJson -Json $job.json -SuggestedName $job.name
            $resultTemporaryPath = [System.IO.Path]::Combine($jobDirectory, 'result.tmp')
            [System.IO.File]::WriteAllText($resultTemporaryPath, (ConvertTo-Json -InputObject $result -Compress), (New-Object System.Text.UTF8Encoding($false)))
            [System.IO.File]::Move($resultTemporaryPath, [System.IO.Path]::Combine($jobDirectory, 'result.json'))
        } else {
            Start-PropsHelper -ListenPort $Port
        }
    }
    catch {
        Write-Host ('Helper stopped: ' + $_.Exception.Message) -ForegroundColor Red
        exit 1
    }
}
