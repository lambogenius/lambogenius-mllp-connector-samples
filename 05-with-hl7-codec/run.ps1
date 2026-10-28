<#
.SYNOPSIS
    Builds and runs the codec sample: the Logic App on http://localhost:7305 with its MLLP trigger on port 2305,
    Azurite, and the stand-in clinical data repository (backends/app.py, port 8305).

.DESCRIPTION
    Needs the .NET 8 SDK, Azure Functions Core Tools 4, Azurite, Python 3, and two packages in ../packages: the HL7
    MLLP Connector and the HL7 v2 Codec. Ctrl+C stops the Logic App and what this script started. Then, in another
    window: ./demo.ps1, or ./send.ps1.
#>
[CmdletBinding()]
param(
    [int]$Port = 7305,
    [ValidateSet('Debug', 'Release')]
    [string]$Configuration = 'Debug'
)

Import-Module (Join-Path $PSScriptRoot '../shared/scripts/MllpSample.psm1') -Force
Start-MllpSample -App $PSScriptRoot -Port $Port -MllpPorts 2305 -BackendPort 8305 -Configuration $Configuration `
    -Packages 'Lambogenius.MllpConnector.LogicApps', 'Lambogenius.Hl7Codec.LogicApps' -Examples @(
    './send.ps1 messages/adt-a01.hl7'
    './send.ps1 messages/adt-a01-v22.hl7'
)
