<#
.SYNOPSIS
    Builds and runs the auto-ACK sample: the Logic App on http://localhost:7301 with its MLLP trigger on port 2301,
    Azurite, and the stand-in patient registry (backends/app.py, port 8301).

.DESCRIPTION
    Needs the .NET 8 SDK, Azure Functions Core Tools 4, Azurite, Python 3, and the HL7 MLLP Connector package in
    ../packages. Ctrl+C stops the Logic App and what this script started. Then, in another window: ./demo.ps1, or
    ./send.ps1.
#>
[CmdletBinding()]
param(
    [int]$Port = 7301,
    [ValidateSet('Debug', 'Release')]
    [string]$Configuration = 'Debug'
)

Import-Module (Join-Path $PSScriptRoot '../shared/scripts/MllpSample.psm1') -Force
Start-MllpSample -App $PSScriptRoot -Port $Port -MllpPorts 2301 -BackendPort 8301 -Configuration $Configuration `
    -Settings @{ LamboHl7Mllp__Archive__File__Path = (Join-Path $PSScriptRoot 'archive') } -Examples @(
    './send.ps1 messages/adt-a01.hl7'
    './send.ps1 messages/adt-batch.hl7'
)
