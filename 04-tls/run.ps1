<#
.SYNOPSIS
    Builds and runs the TLS sample: the Logic App on http://localhost:7304 with its MLLP-over-TLS trigger on port
    2304, Azurite, and the stand-ins (backends/app.py: recorder and control on HTTP 8304, the lab on MLLP over TLS
    port 2314).

.DESCRIPTION
    Needs the .NET 8 SDK, Azure Functions Core Tools 4, Azurite, Python 3, and the HL7 MLLP Connector package in
    ../packages. The first run creates throwaway self-signed certificates in certs/ (New-SampleCertificates.ps1).
    Ctrl+C stops the Logic App and what this script started. Then, in another window: ./demo.ps1, or ./send.ps1.
#>
[CmdletBinding()]
param(
    [int]$Port = 7304,
    [ValidateSet('Debug', 'Release')]
    [string]$Configuration = 'Debug'
)

Import-Module (Join-Path $PSScriptRoot '../shared/scripts/MllpSample.psm1') -Force
$certs = & (Join-Path $PSScriptRoot 'New-SampleCertificates.ps1')
$dir = Join-Path $PSScriptRoot 'certs'

Start-MllpSample -App $PSScriptRoot -Port $Port -MllpPorts 2304 -BackendPort 8304 -BackendMllpPorts 2314 -Configuration $Configuration `
    -BackendArguments '--mllp-port', '2314',
        '--cert', "`"$(Join-Path $dir 'lab.pem')`"", '--key', "`"$(Join-Path $dir 'lab.key')`"",
        '--impostor-cert', "`"$(Join-Path $dir 'impostor.pem')`"", '--impostor-key', "`"$(Join-Path $dir 'impostor.key')`"" `
    -Settings @{
        MLLP_TLS_CERTIFICATE          = $certs.logicAppPfx
        MLLP_TLS_CERTIFICATE_PASSWORD = $certs.logicAppPfxPassword
        LAB_TLS_THUMBPRINT            = $certs.labThumbprint
    } -Examples @(
    './send.ps1 messages/adt-a04.hl7'
    './send.ps1 messages/orm-o01.hl7 -ToLab'
)
