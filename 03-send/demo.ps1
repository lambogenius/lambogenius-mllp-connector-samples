<#
.SYNOPSIS
    Runs every step of the send scenario against the running app and checks the results.

.DESCRIPTION
    Start the sample first with ./run.ps1 (in another window). This script resets the stand-in lab, posts the
    orders in messages/ to the send-order workflow, and checks what the caller got back and what the lab received.
    It exits with 1 when a check fails.
#>
[CmdletBinding()]
param(
    [string]$BaseUrl = 'http://localhost:7303',
    [string]$LabUrl = 'http://127.0.0.1:8303'
)

Import-Module (Join-Path $PSScriptRoot '../shared/scripts/MllpSample.psm1') -Force
Set-Location $PSScriptRoot

function Send([string]$file) {
    $r = Invoke-MllpWorkflow 'send-order' $file -BaseUrl $BaseUrl
    Write-Host "  POST send-order $(Split-Path $file -Leaf) -> HTTP $($r.Status) in $([math]::Round($r.Seconds, 1)) s"
    $r
}
function Orders { @((Invoke-RestMethod "$LabUrl/received").orders) }
function Control([string]$what) { Invoke-RestMethod -Method Post "$LabUrl/control/$what" | Out-Null }

try { Control 'reset' } catch { throw "The stand-in lab is not answering on $LabUrl. Start the sample with ./run.ps1 first." }

Step '1. An order the lab accepts: HTTP 200 with the AA acknowledgement.'
$r = Send 'messages/orm-o01-glucose.hl7'
Check 'HTTP 200, ackCode AA, isPositive' ($r.Status -eq 200 -and $r.Body.ackCode -eq 'AA' -and $r.Body.isPositive -eq $true) "($($r.Status) $($r.Body | ConvertTo-Json -Compress))"
Check 'MSA-2 matches the sent MSH-10 (MG-ORM-0001); MSA-3 "Order accepted"' ($r.Body.acknowledgedControlId -eq 'MG-ORM-0001' -and $r.Body.messageControlId -eq 'MG-ORM-0001' -and $r.Body.ackText -eq 'Order accepted')
Show ($r.Body.acknowledgement -replace "`r", "`n")
Check 'the lab got the GLU order' ([bool](Orders | Where-Object { $_.controlId -eq 'MG-ORM-0001' -and $_.test -eq 'GLU' -and $_.ackCode -eq 'AA' }))

Step "2. An order for a test the lab doesn't do: HTTP 422 with the AE acknowledgement."
$r = Send 'messages/orm-o01-unknown-test.hl7'
Check 'HTTP 422, ackCode AE, "Unknown test code XYZ"' ($r.Status -eq 422 -and $r.Body.ackCode -eq 'AE' -and $r.Body.isPositive -eq $false -and $r.Body.ackText -eq 'Unknown test code XYZ') "($($r.Status) $($r.Body | ConvertTo-Json -Compress))"
Check "the lab's ERR segment is in ackErrors" ($r.Body.ackErrors -match '^ERR\|.*207') $r.Body.ackErrors
Check 'the same connection as step 1 (keepConnectionOpen): connectionReused' ($r.Body.connectionReused -eq $true)

Step '3. The lab reads the message but never answers: HTTP 504 after the 5-second ACK timeout.'
Control 'silent'
$r = Send 'messages/orm-o01-cbc.hl7'
Control 'normal'
Check 'HTTP 504 with "No acknowledgement was received within 5 seconds"' ($r.Status -eq 504 -and "$($r.Body.detail.body.message)" -match 'No acknowledgement was received within 5 seconds') "($($r.Status) $($r.Body | ConvertTo-Json -Compress -Depth 5))"
Check 'answered after about 5 seconds' ($r.Seconds -ge 5 -and $r.Seconds -lt 30) "($([math]::Round($r.Seconds, 1)) s)"
Check 'the lab did get MG-ORM-0003 (so it must not simply be sent again without checking)' ([bool](Orders | Where-Object { $_.controlId -eq 'MG-ORM-0003' -and -not $_.ackCode }))

Step '4. The lab answers again: the next order goes through on a new connection.'
$r = Send 'messages/orm-o01-cbc.hl7'
Check 'HTTP 200, AA for MG-ORM-0003' ($r.Status -eq 200 -and $r.Body.ackCode -eq 'AA' -and $r.Body.acknowledgedControlId -eq 'MG-ORM-0003') "($($r.Status) $($r.Body | ConvertTo-Json -Compress))"
Check 'a new connection: the timed-out one was closed, so a late ACK cannot be mistaken for this one' ($r.Body.connectionReused -eq $false) "(connectionReused $($r.Body.connectionReused))"

Complete-Demo
