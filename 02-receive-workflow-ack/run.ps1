<#
.SYNOPSIS
    Builds and runs the workflow-ACK sample: the Logic App on http://localhost:7302 with MLLP triggers on ports 2302
    (ADT, two-way) and 2312 (lab results, enhanced mode), Azurite, and the stand-in EHR and lab (backends/app.py:
    HTTP on 8302, the lab's MLLP port for application ACKs on 2322).

.DESCRIPTION
    Needs the .NET 8 SDK, Azure Functions Core Tools 4, Azurite, Python 3, and the HL7 MLLP Connector package in
    ../packages. Ctrl+C stops the Logic App and what this script started. Then, in another window: ./demo.ps1, or
    ./send.ps1.
#>
[CmdletBinding()]
param(
    [int]$Port = 7302,
    [ValidateSet('Debug', 'Release')]
    [string]$Configuration = 'Debug'
)

Import-Module (Join-Path $PSScriptRoot '../shared/scripts/MllpSample.psm1') -Force
Start-MllpSample -App $PSScriptRoot -Port $Port -MllpPorts 2302, 2312 -BackendPort 8302 -BackendMllpPorts 2322 `
    -BackendArguments '--ack-port', '2322' -Configuration $Configuration -Examples @(
    './send.ps1 messages/adt-a01.hl7'
    './send.ps1 messages/oru-r01-al.hl7 -Port 2312'
)
