<#
.SYNOPSIS
    Sends an HL7 file to the Logic App's MLLP-over-TLS trigger (port 2304), trusting the sample's self-signed
    certificate. With -ToLab, posts it to the send-result-tls workflow instead, which sends it to the lab over TLS.

.EXAMPLE
    ./send.ps1 messages/adt-a04.hl7
.EXAMPLE
    ./send.ps1 messages/orm-o01.hl7 -ToLab
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)]
    [string]$File,

    [switch]$ToLab,
    [int]$Port = 2304,
    [string]$BaseUrl = 'http://localhost:7304'
)

Import-Module (Join-Path $PSScriptRoot '../shared/scripts/MllpSample.psm1') -Force
if ($ToLab) {
    $r = Invoke-MllpWorkflow 'send-result-tls' $File -BaseUrl $BaseUrl
    Write-Host "POST send-result-tls $(Split-Path $File -Leaf) -> HTTP $($r.Status)" -ForegroundColor $(if ($r.Status -lt 300) { 'Green' } else { 'Red' })
    if ($r.ContentType -like '*json*') { $r.Body | ConvertTo-Json -Depth 10 } else { $r.Text }
}
else {
    Write-Hl7Result (Send-Hl7 -Port $Port -File $File -Tls -CaFile (Join-Path $PSScriptRoot 'certs/logicapp.pem'))
}
