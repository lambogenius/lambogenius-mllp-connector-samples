<#
.SYNOPSIS
    Posts an HL7 file to the send-order workflow, which sends it to the lab over MLLP, and prints the answer.

.EXAMPLE
    ./send.ps1 messages/orm-o01-glucose.hl7
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)]
    [string]$File,

    [string]$BaseUrl = 'http://localhost:7303'
)

Import-Module (Join-Path $PSScriptRoot '../shared/scripts/MllpSample.psm1') -Force
$r = Invoke-MllpWorkflow 'send-order' $File -BaseUrl $BaseUrl
Write-Host "POST send-order $(Split-Path $File -Leaf) -> HTTP $($r.Status)" -ForegroundColor $(if ($r.Status -lt 300) { 'Green' } else { 'Red' })
if ($r.ContentType -like '*json*') { $r.Body | ConvertTo-Json -Depth 10 } else { $r.Text }
