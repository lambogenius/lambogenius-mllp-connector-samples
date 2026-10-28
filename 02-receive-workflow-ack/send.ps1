<#
.SYNOPSIS
    Sends HL7 files over MLLP and prints the acknowledgements: ADT to port 2302 (the workflow answers), lab results
    to port 2312 (the connector answers CA; the application ACK goes to the lab later).

.EXAMPLE
    ./send.ps1 messages/adt-a01.hl7
.EXAMPLE
    ./send.ps1 messages/oru-r01-al.hl7 -Port 2312
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)]
    [string[]]$File,

    [int]$Port = 2302
)

Import-Module (Join-Path $PSScriptRoot '../shared/scripts/MllpSample.psm1') -Force
Write-Hl7Result (Send-Hl7 -Port $Port -File $File)
