<#
.SYNOPSIS
    Builds and runs the send sample: the Logic App on http://localhost:7303, Azurite, and the stand-in lab
    (backends/app.py: MLLP on port 2303, control on HTTP 8303).

.DESCRIPTION
    Needs the .NET 8 SDK, Azure Functions Core Tools 4, Azurite, Python 3, and the HL7 MLLP Connector package in
    ../packages. Ctrl+C stops the Logic App and what this script started. Then, in another window: ./demo.ps1, or
    ./send.ps1.

.PARAMETER NoStandIns
    Don't start the stand-in lab, so another MLLP receiver can listen on port 2303 (for example
    `mllp receive --port 2303`). demo.ps1 needs the stand-in.
#>
[CmdletBinding()]
param(
    [int]$Port = 7303,
    [switch]$NoStandIns,
    [ValidateSet('Debug', 'Release')]
    [string]$Configuration = 'Debug'
)

Import-Module (Join-Path $PSScriptRoot '../shared/scripts/MllpSample.psm1') -Force
$standIns = if ($NoStandIns) { @{} } else { @{ BackendPort = 8303; BackendMllpPorts = 2303; BackendArguments = '--mllp-port', '2303' } }
Start-MllpSample -App $PSScriptRoot -Port $Port -Configuration $Configuration @standIns -Examples @(
    './send.ps1 messages/orm-o01-glucose.hl7'
    './send.ps1 messages/orm-o01-unknown-test.hl7'
)
