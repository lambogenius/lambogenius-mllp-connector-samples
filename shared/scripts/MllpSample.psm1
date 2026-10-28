<#
    Shared helpers for the samples' run.ps1, demo.ps1 and send.ps1 scripts.

    Start-MllpSample builds and runs one sample Logic App with what it needs: Azurite and the sample's stand-in
    systems (backends/app.py). Send-Hl7 sends HL7 messages over MLLP with shared/tools/mllp.py and returns the
    acknowledgements. Invoke-MllpWorkflow calls a workflow's HTTP trigger. Step, Check and Complete-Demo print a
    demo's checks and set its exit code.
#>

$ErrorActionPreference = 'Stop'
$script:RepoRoot = Resolve-Path (Join-Path $PSScriptRoot '../..')
$script:MllpTool = Join-Path $script:RepoRoot 'shared/tools/mllp.py'
$script:Failures = 0

$script:Packages = @{
    'Lambogenius.MllpConnector.LogicApps' = @{ Property = 'MllpConnectorVersion'; Default = '1.4.0'; Download = 'https://lambogenius.com/app/downloads/hl7-mllp-connector' }
    'Lambogenius.Hl7Codec.LogicApps'      = @{ Property = 'Hl7CodecVersion'; Default = '1.1.0'; Download = 'https://lambogenius.com/app/downloads/hl7-v2-codec' }
}

function Find-Tool([string]$name, [string]$hint) {
    # npm installs PowerShell and cmd shims; Start-Process needs the .exe or .cmd.
    $tool = Get-Command $name -CommandType Application -ErrorAction SilentlyContinue | Where-Object Extension -in '.exe', '.cmd', '' |
        Sort-Object { $_.Extension -ne '.exe' } | Select-Object -First 1
    if (-not $tool) { throw "$name was not found on PATH. $hint" }
    $tool.Source
}

function Find-Python {
    $python = Find-Tool 'python' 'Install Python 3: https://www.python.org/downloads/'
    # Windows has a "python" alias that opens the Microsoft Store instead of running Python.
    $version = & $python --version 2>&1
    if ("$version" -notmatch '^Python 3') { throw "python on PATH is not Python 3 ($version). Install Python 3: https://www.python.org/downloads/" }
    $python
}

function Test-Listening([int]$port) {
    $client = [System.Net.Sockets.TcpClient]::new()
    try { $client.ConnectAsync('127.0.0.1', $port).Wait(300) -and $client.Connected } catch { $false } finally { $client.Dispose() }
}

function Wait-Until([scriptblock]$condition, [string]$what, [int]$seconds = 120) {
    $deadline = (Get-Date).AddSeconds($seconds)
    while (-not (& $condition)) {
        if ((Get-Date) -gt $deadline) { throw "Timed out waiting for $what." }
        Start-Sleep -Milliseconds 500
    }
}

function Get-PackageVersion([string]$app, [string]$package) {
    $info = $script:Packages[$package]
    [xml]$project = Get-Content (Join-Path $app 'LogicApp.csproj')
    $version = $project.Project.PropertyGroup | ForEach-Object { $_.($info.Property) } | Where-Object { $_ } | Select-Object -First 1
    if ($version -is [System.Xml.XmlElement]) { $version = $version.'#text' }
    if ($version) { $version } else { $info.Default }
}

<#
.SYNOPSIS
    Builds one sample Logic App and runs it with `func start` in the current window. Ctrl+C stops it and whatever
    this function started; an Azurite that was already running is left alone.
#>
function Start-MllpSample {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$App,
        [Parameter(Mandatory)][int]$Port,
        # The ports the workflows' MLLP triggers listen on; they must be free.
        [int[]]$MllpPorts = @(),
        # The stand-in systems (backends/app.py): their HTTP port, and the extra ports and arguments they use.
        [int]$BackendPort = 0,
        [int[]]$BackendMllpPorts = @(),
        [string[]]$BackendArguments = @(),
        [string[]]$Packages = @('Lambogenius.MllpConnector.LogicApps'),
        # App settings for this run, such as absolute paths. Core Tools prefers them to local.settings.json.
        [hashtable]$Settings = @{},
        [string[]]$Examples = @(),
        [ValidateSet('Debug', 'Release')][string]$Configuration = 'Debug'
    )

    $logs = Join-Path $App 'logs'
    $started = [System.Collections.Generic.List[System.Diagnostics.Process]]::new()
    $previous = @{}

    # 1. Prerequisites.
    if (-not ((dotnet --list-sdks) -match '^8\.')) { throw '.NET SDK 8 is required: https://dotnet.microsoft.com/download/dotnet/8.0' }
    $func = Find-Tool 'func' 'Install Azure Functions Core Tools 4: npm install -g azure-functions-core-tools@4'
    $python = Find-Python
    Write-Host "dotnet $((dotnet --version)), func $((& $func --version)), $((& $python --version))"
    New-Item -ItemType Directory -Force $logs | Out-Null

    # 2. The connector packages, downloaded from lambogenius.com into packages/.
    foreach ($id in $Packages) {
        $version = Get-PackageVersion $App $id
        $file = "$id.$version.nupkg"
        if (-not (Test-Path (Join-Path $script:RepoRoot "packages/$file"))) {
            throw "packages/$file is missing. Sign in at $($script:Packages[$id].Download), download it, and save it in $(Join-Path $script:RepoRoot 'packages')."
        }
    }

    foreach ($p in @($MllpPorts) + @($BackendMllpPorts) + @($BackendPort | Where-Object { $_ })) {
        if (Test-Listening $p) { throw "Port $p is already in use. Stop what uses it (another copy of this sample?), or change the port in local.settings.json and run.ps1." }
    }
    if (Test-Listening $Port) { throw "Port $Port is already in use. Pass -Port <other port>." }

    try {
        # 3. Storage emulator.
        $storagePorts = 10000, 10001, 10002
        $busy = @($storagePorts | Where-Object { Test-Listening $_ })
        if ($busy.Count -eq $storagePorts.Count) {
            Write-Host 'Storage emulator: using the one already listening on ports 10000-10002.'
        }
        else {
            if ($busy) {
                # Another program holds some of the default ports (VS Code sometimes holds 10001), so Azurite gets free
                # ones and the Logic App is pointed at them. Core Tools prefers this environment variable over
                # local.settings.json. The key is the emulator's public, well-known development account key.
                $first = 10100
                while (@($first..($first + 2) | Where-Object { Test-Listening $_ }).Count) { $first += 3 }
                $storagePorts = $first, ($first + 1), ($first + 2)
                Write-Host "Another program is using port(s) $($busy -join ', '); Azurite will listen on $($storagePorts -join ', ')."
                $env:AzureWebJobsStorage = 'DefaultEndpointsProtocol=http;AccountName=devstoreaccount1;' +
                    'AccountKey=Eby8vdM02xNOcqFlqUwJPLlmEtlCDXJ1OUzFT50uSRZ6IFsuFq2UVErCz4I6tq/K1SZFPTOtr/KBHBeksoGMGw==;' +
                    "BlobEndpoint=http://127.0.0.1:$($storagePorts[0])/devstoreaccount1;" +
                    "QueueEndpoint=http://127.0.0.1:$($storagePorts[1])/devstoreaccount1;" +
                    "TableEndpoint=http://127.0.0.1:$($storagePorts[2])/devstoreaccount1;"
            }
            $azurite = Find-Tool 'azurite' 'Install Azurite: npm install -g azurite'
            $data = Join-Path $App '.azurite'
            New-Item -ItemType Directory -Force $data | Out-Null
            Write-Host "Starting Azurite (data in $data) ..."
            $started.Add((Start-Process $azurite -ArgumentList '--silent', '--skipApiVersionCheck', '--location', "`"$data`"",
                '--blobPort', $storagePorts[0], '--queuePort', $storagePorts[1], '--tablePort', $storagePorts[2] -PassThru -WindowStyle Hidden))
            Wait-Until { @($storagePorts | Where-Object { Test-Listening $_ }).Count -eq 3 } "Azurite on ports $($storagePorts -join ', ')" 60
        }

        # 4. The sample's stand-in systems.
        if ($BackendPort) {
            Write-Host "Starting the stand-in systems (HTTP on port $BackendPort$(if ($BackendMllpPorts) { ", MLLP on $($BackendMllpPorts -join ', ')" })) ..."
            $arguments = @('-u', "`"$(Join-Path $App 'backends/app.py')`"", '--port', $BackendPort) + $BackendArguments
            $started.Add((Start-Process $python -ArgumentList $arguments -PassThru -WindowStyle Hidden `
                -RedirectStandardOutput (Join-Path $logs 'backends.log') -RedirectStandardError (Join-Path $logs 'backends.err.log')))
            Wait-Until { @(@($BackendPort) + $BackendMllpPorts | Where-Object { -not (Test-Listening $_) }).Count -eq 0 } "the stand-in systems (see $logs/backends.err.log)" 30
        }

        # 5. Build and run the Logic App.
        if (-not (Test-Path (Join-Path $App 'local.settings.json'))) { Copy-Item (Join-Path $App 'local.settings.sample.json') (Join-Path $App 'local.settings.json') }
        foreach ($name in $Settings.Keys) {
            $previous[$name] = [Environment]::GetEnvironmentVariable($name)
            [Environment]::SetEnvironmentVariable($name, $Settings[$name])
        }
        Write-Host 'Building the Logic App ...'
        dotnet build (Join-Path $App 'LogicApp.csproj') -c $Configuration --nologo -v q
        if ($LASTEXITCODE) { throw 'The Logic App failed to build.' }

        Write-Host ''
        Write-Host "Starting the Logic App on http://localhost:$Port$(if ($MllpPorts) { ", MLLP on port $($MllpPorts -join ', ')" }). In another window, try:" -ForegroundColor Green
        foreach ($example in $Examples) { Write-Host "  $example" -ForegroundColor Green }
        Write-Host '  ./demo.ps1        # every step, checked' -ForegroundColor Green
        Write-Host 'Press Ctrl+C to stop.' -ForegroundColor Green
        Write-Host ''
        Push-Location (Join-Path $App "bin/$Configuration/net8.0")
        try { & $func start --port $Port } finally { Pop-Location }
    }
    finally {
        foreach ($name in $previous.Keys) { [Environment]::SetEnvironmentVariable($name, $previous[$name]) }
        foreach ($process in $started) {
            if (-not $process.HasExited) {
                Write-Host "Stopping $($process.ProcessName) (pid $($process.Id))"
                taskkill /PID $process.Id /T /F | Out-Null
            }
        }
    }
}

<#
.SYNOPSIS
    Sends HL7 messages over MLLP (shared/tools/mllp.py) and returns one result per message: ackCode, ackText,
    acknowledgedControlId, acks (every MSA, for a batch), errors (ERR segments), ack (the whole ACK), elapsedMs,
    tls, or error when there was no acknowledgement. All messages go over one connection, in order.
#>
function Send-Hl7 {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][int]$Port,
        [string[]]$File = @(),
        [string[]]$Message = @(),
        [string]$HostName = '127.0.0.1',
        [double]$Timeout = 30,
        [switch]$Tls,
        [string]$CaFile,
        [string]$ServerName,
        [ValidateSet('1.2', '1.3')][string]$TlsVersion = '1.2'
    )

    $arguments = @('-I', $script:MllpTool, 'send', '--host', $HostName, '--port', $Port, '--timeout', $Timeout, '--json')
    if ($File) { $arguments += '--file'; $arguments += @($File | ForEach-Object { (Resolve-Path $_).Path }) }
    foreach ($m in $Message) { $arguments += '--message'; $arguments += $m }
    if ($Tls) { $arguments += '--tls', '--tls-version', $TlsVersion }
    if ($CaFile) { $arguments += '--cafile', (Resolve-Path $CaFile).Path }
    if ($ServerName) { $arguments += '--server-name', $ServerName }
    $output = & (Find-Python) @arguments
    if ($LASTEXITCODE -gt 1 -or -not $output) { throw "mllp.py failed: $output" }
    $output | ConvertFrom-Json
}

<#
.SYNOPSIS
    Posts a file to a workflow's HTTP trigger ("When_an_HTTP_request_is_received") and returns the status, the parsed
    body (JSON) or the text, the content type and the time taken.
#>
function Invoke-MllpWorkflow {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Workflow,
        [Parameter(Mandatory, Position = 1)][string]$File,
        [Parameter(Mandatory)][string]$BaseUrl,
        [string]$Query = ''
    )

    $path = (Resolve-Path $File).Path
    # Request triggers need a signed URL; the local runtime hands it out through its management API.
    try {
        $url = (Invoke-RestMethod -Method Post -Uri "$BaseUrl/runtime/webhooks/workflow/api/management/workflows/$Workflow/triggers/When_an_HTTP_request_is_received/listCallbackUrl?api-version=2020-05-01-preview").value
    }
    catch {
        throw "Could not reach the Logic App at $BaseUrl, or it has no workflow '$Workflow'. Is ./run.ps1 running? $($_.Exception.Message)"
    }
    if ($Query) { $url += "&$Query" }

    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $response = Invoke-WebRequest -Method Post -Uri $url -InFile $path -ContentType 'text/plain' -SkipHttpErrorCheck -TimeoutSec 180
    $type = "$($response.Headers['Content-Type'])"
    $text = if ($response.Content -is [byte[]]) { [System.Text.Encoding]::UTF8.GetString($response.Content) } else { $response.Content }
    [pscustomobject]@{
        Status      = [int]$response.StatusCode
        ContentType = $type
        Text        = $text
        Body        = if ($type -like '*json*' -and $text) { $text | ConvertFrom-Json } else { $text }
        Seconds     = $watch.Elapsed.TotalSeconds
    }
}

<#
.SYNOPSIS
    Prints the results of Send-Hl7 (used by the samples' send.ps1).
#>
function Write-Hl7Result($results) {
    foreach ($r in @($results)) {
        if ($r.error) { Write-Host "$($r.name): $($r.error)" -ForegroundColor Red; continue }
        $color = if ($r.ackCode -in 'AA', 'CA') { 'Green' } else { 'Red' }
        Write-Host "$($r.name): $($r.ackCode) for '$($r.acknowledgedControlId)' in $($r.elapsedMs) ms$(if ($r.tls) { " over $($r.tls)" })" -ForegroundColor $color
        Show $r.ack
    }
}

<#
.SYNOPSIS
    Throws a clear message when nothing listens on a sample's port (the demo was started before run.ps1).
#>
function Assert-Listening([int]$port, [string]$what) {
    if (-not (Test-Listening $port)) { throw "Nothing is listening on port $port ($what). Start the sample with ./run.ps1 first, and wait for 'Host lock lease acquired'." }
}

<#
.SYNOPSIS
    Runs a script block every half second until it returns something truthy, and returns that; returns $null after
    the timeout. Workflows run after the ACK in Auto mode, so a demo waits for what they deliver.
#>
function Wait-For([scriptblock]$Condition, [int]$Seconds = 60) {
    $deadline = (Get-Date).AddSeconds($Seconds)
    do {
        $result = & $Condition
        if ($result) { return $result }
        Start-Sleep -Milliseconds 500
    } while ((Get-Date) -lt $deadline)
    $null
}

function Step([string]$title) { Write-Host ''; Write-Host $title -ForegroundColor Cyan }

function Check([string]$what, [bool]$ok, [string]$actual = '') {
    if ($ok) { Write-Host "  ok    $what" -ForegroundColor Green }
    else { Write-Host "  FAIL  $what $actual" -ForegroundColor Red; $script:Failures++ }
}

function Show([string]$text) { Write-Host ($text.TrimEnd() -replace '(?m)^', '        ') -ForegroundColor DarkGray }

function Complete-Demo {
    Write-Host ''
    if ($script:Failures) { Write-Host "$script:Failures check(s) failed." -ForegroundColor Red; exit 1 }
    Write-Host 'All checks passed.' -ForegroundColor Green
    exit 0
}

Export-ModuleMember -Function Start-MllpSample, Send-Hl7, Invoke-MllpWorkflow, Write-Hl7Result, Assert-Listening, Wait-For, Step, Check, Show, Complete-Demo, Test-Listening
