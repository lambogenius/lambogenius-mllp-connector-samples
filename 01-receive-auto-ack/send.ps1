<#
.SYNOPSIS
    Sends HL7 files to the sample's MLLP trigger (port 2301) over one connection and prints the acknowledgements.

.EXAMPLE
    ./send.ps1 messages/adt-a01.hl7
.EXAMPLE
    ./send.ps1 messages/adt-a01.hl7, messages/adt-a08-enhanced.hl7
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)]
    [string[]]$File,

    [int]$Port = 2301
)

Import-Module (Join-Path $PSScriptRoot '../shared/scripts/MllpSample.psm1') -Force
Write-Hl7Result (Send-Hl7 -Port $Port -File $File)
