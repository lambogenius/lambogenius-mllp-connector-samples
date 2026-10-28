<#
.SYNOPSIS
    Runs every step of the codec scenario against the running app and checks the results.

.DESCRIPTION
    Start the sample first with ./run.ps1 (in another window). This script resets the stand-in repository, sends
    the messages in messages/ over MLLP, and checks the codec's acknowledgements and the decoded JSON the repository
    got. It exits with 1 when a check fails.
#>
[CmdletBinding()]
param(
    [int]$MllpPort = 2305,
    [string]$RepositoryUrl = 'http://127.0.0.1:8305'
)

Import-Module (Join-Path $PSScriptRoot '../shared/scripts/MllpSample.psm1') -Force
Set-Location $PSScriptRoot

function Send([string]$file) {
    $r = Send-Hl7 -Port $MllpPort -File $file
    Write-Host "  MLLP $($r.name) -> $(if ($r.error) { $r.error } else { "$($r.ackCode) in $($r.elapsedMs) ms" })"
    $r
}
function Stored([string]$controlId) { @((Invoke-RestMethod "$RepositoryUrl/received").messages) | Where-Object controlId -eq $controlId | Select-Object -Last 1 }
function Control([string]$what) { Invoke-RestMethod -Method Post "$RepositoryUrl/control/$what" | Out-Null }

try { Control 'reset' } catch { throw "The stand-in repository is not answering on $RepositoryUrl. Start the sample with ./run.ps1 first." }
Assert-Listening $MllpPort 'the MLLP trigger'

Step '1. An admission: decoded without a schema, stored as JSON, and answered with the codec''s AA.'
$r = Send 'messages/adt-a01.hl7'
Check 'AA for MG-ADT-0501' ($r.ackCode -eq 'AA' -and $r.acknowledgedControlId -eq 'MG-ADT-0501') "($($r.ackCode) $($r.error))"
Check "the codec's ACK: sender and receiver swapped, ACK^A01^ACK, version 2.5.1" ($r.ack -match '^MSH\|\^~\\&\|LOGICAPP\|INTEGRATION\|PAS\|MAPLE_GROVE\|' -and $r.ack -match '\|ACK\^A01\^ACK\|' -and $r.ack -match '\|P\|2\.5\.1')
Show $r.ack
$doc = (Stored 'MG-ADT-0501').decoded.ADT_A01
Check 'the repository got the JSON form: root ADT_A01, MSH_10' ($doc.MSH.MSH_10 -eq 'MG-ADT-0501') "(MSH_10 '$($doc.MSH.MSH_10)')"
Check 'generic field names: PID_5 family and given name (SAMPLE, HANNAH)' ($doc.PID.PID_5.PID_5_0 -eq 'SAMPLE' -and $doc.PID.PID_5.PID_5_1 -eq 'HANNAH') ($doc.PID.PID_5 | ConvertTo-Json -Compress)
Check 'a repeating field becomes an array: two PID_3 identifiers (MRN100005, 5550001)' (@($doc.PID.PID_3).Count -eq 2 -and $doc.PID.PID_3[0].PID_3_0 -eq 'MRN100005' -and $doc.PID.PID_3[1].PID_3_0 -eq '5550001') ($doc.PID.PID_3 | ConvertTo-Json -Compress)
Show ($doc.PID | ConvertTo-Json -Compress -Depth 5)

Step '2. A lab result with two OBX segments.'
$r = Send 'messages/oru-r01.hl7'
Check 'AA for CL-ORU-0501' ($r.ackCode -eq 'AA' -and $r.acknowledgedControlId -eq 'CL-ORU-0501') "($($r.ackCode) $($r.error))"
$doc = (Stored 'CL-ORU-0501').decoded.ORU_R01
Check 'two OBX in order: HGB 135 g/L, WBC 6.2' (@($doc.OBX).Count -eq 2 -and $doc.OBX[0].OBX_3.OBX_3_0 -eq 'HGB' -and $doc.OBX[0].OBX_5 -eq '135' -and $doc.OBX[1].OBX_3.OBX_3_0 -eq 'WBC' -and $doc.OBX[1].OBX_5 -eq '6.2') ($doc.OBX | ConvertTo-Json -Compress -Depth 4)

Step "3. An HL7 v2.2 message, a version this interface doesn't take: the codec's AR, code 203."
$r = Send 'messages/adt-a01-v22.hl7'
Check 'AR for MG-ADT-0502, "HL7 version ''2.2'' is not supported."' ($r.ackCode -eq 'AR' -and $r.acknowledgedControlId -eq 'MG-ADT-0502' -and $r.ackText -match "version '2\.2' is not supported") "($($r.ackCode) '$($r.ackText)')"
Check 'ERR code 203 (unsupported version ID), in the v2.2 layout (ERR-1)' ("$($r.errors)" -match '^ERR\|MSH\^1\^12\^203') "$($r.errors)"
Show $r.ack
Check 'nothing was stored' (-not (Stored 'MG-ADT-0502'))

Step '4. The repository is down: AR from the workflow, so the sender sends again later.'
Control 'down'
$r = Send 'messages/oru-r01.hl7'
Control 'up'
Check 'AR, "The repository is not available ..."' ($r.ackCode -eq 'AR' -and $r.acknowledgedControlId -eq 'CL-ORU-0501' -and $r.ackText -match 'not available') "($($r.ackCode) '$($r.ackText)')"
$r = Send 'messages/oru-r01.hl7'
Check 'sent again: AA' ($r.ackCode -eq 'AA') "($($r.ackCode))"

Complete-Demo
