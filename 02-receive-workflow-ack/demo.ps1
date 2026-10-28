<#
.SYNOPSIS
    Runs every step of the workflow-ACK scenario against the running app and checks the results.

.DESCRIPTION
    Start the sample first with ./run.ps1 (in another window). This script resets the stand-in EHR and lab, sends
    the messages in messages/ over MLLP, and checks the acknowledgements, what the EHR filed and which application
    acknowledgements the lab got. It exits with 1 when a check fails.
#>
[CmdletBinding()]
param(
    [int]$AdtPort = 2302,
    [int]$ResultsPort = 2312,
    [string]$EhrUrl = 'http://127.0.0.1:8302'
)

Import-Module (Join-Path $PSScriptRoot '../shared/scripts/MllpSample.psm1') -Force
Set-Location $PSScriptRoot

function Send([int]$port, [string[]]$files) {
    $results = Send-Hl7 -Port $port -File $files
    foreach ($r in $results) { Write-Host "  MLLP :$port $($r.name) -> $(if ($r.error) { $r.error } else { "$($r.ackCode) in $($r.elapsedMs) ms" })" }
    $results
}
function Received { Invoke-RestMethod "$EhrUrl/received" }
function Control([string]$what) { Invoke-RestMethod -Method Post "$EhrUrl/control/$what" | Out-Null }
function ApplicationAck([string]$controlId) { Wait-For { @((Received).applicationAcks) | Where-Object acknowledgedControlId -eq $controlId } 60 }

try { Control 'reset' } catch { throw "The stand-in EHR is not answering on $EhrUrl. Start the sample with ./run.ps1 first." }
Assert-Listening $AdtPort 'the two-way ADT trigger'
Assert-Listening $ResultsPort 'the lab results trigger'

Write-Host 'Two-way receive (port 2302): the sender waits until the workflow answers.' -ForegroundColor White

Step '1. An admission the EHR accepts: the workflow answers AA with the EHR key.'
$r = Send $AdtPort 'messages/adt-a01.hl7'
Check 'AA for MG-ADT-0201, MSA-3 "Stored as EHR-000001"' ($r.ackCode -eq 'AA' -and $r.acknowledgedControlId -eq 'MG-ADT-0201' -and $r.ackText -eq 'Stored as EHR-000001') "($($r.ackCode) '$($r.ackText)' $($r.error))"
Show $r.ack
Check 'the EHR has the patient' ([bool](@((Received).patients) | Where-Object { $_.patientId -eq 'MRN200001' -and $_.patientKey -eq 'EHR-000001' }))

Step "2. An admission to a ward the EHR doesn't know: AE with the EHR's reason."
$r = Send $AdtPort 'messages/adt-a01-unknown-ward.hl7'
Check 'AE for MG-ADT-0202, MSA-3 "Ward WARD9 does not exist"' ($r.ackCode -eq 'AE' -and $r.acknowledgedControlId -eq 'MG-ADT-0202' -and $r.ackText -eq 'Ward WARD9 does not exist') "($($r.ackCode) '$($r.ackText)')"
Check 'an ERR segment with code 207 (application internal error)' ("$($r.errors)" -match '207') "$($r.errors)"
Show $r.ack

Step '3. A message type this interface does not take (SIU^S12): AR, code 200.'
$r = Send $AdtPort 'messages/siu-s12.hl7'
Check 'AR, MSA-3 "Unsupported message type SIU S12", ERR code 200' ($r.ackCode -eq 'AR' -and $r.ackText -eq 'Unsupported message type SIU S12' -and "$($r.errors)" -match '200') "($($r.ackCode) '$($r.ackText)' $($r.errors))"

Step '4. The EHR is down: AR, so the sender sends again later.'
Control 'down'
$r = Send $AdtPort 'messages/adt-a04.hl7'
Control 'up'
Check 'AR for MG-ADT-0203, "The EHR is not available ..."' ($r.ackCode -eq 'AR' -and $r.acknowledgedControlId -eq 'MG-ADT-0203' -and $r.ackText -match 'not available') "($($r.ackCode) '$($r.ackText)')"
$r = Send $AdtPort 'messages/adt-a04.hl7'
Check 'sent again once the EHR is back: AA' ($r.ackCode -eq 'AA' -and $r.ackText -eq 'Stored as EHR-000002') "($($r.ackCode) '$($r.ackText)')"

Step '5. The EHR takes 15 seconds; the trigger waits 10 (responseTimeoutSeconds), then answers AE itself.'
Control 'slow'
$r = Send $AdtPort 'messages/adt-a04.hl7'
Control 'up'
Check 'AE for MG-ADT-0203, sent by the connector' ($r.ackCode -eq 'AE' -and $r.acknowledgedControlId -eq 'MG-ADT-0203') "($($r.ackCode) '$($r.ackText)' $($r.error))"
Check 'after about 10 seconds, not 15' ($r.elapsedMs -ge 9000 -and $r.elapsedMs -lt 14000) "($($r.elapsedMs) ms)"
Show $r.ack

Write-Host ''
Write-Host 'Enhanced mode (port 2312): CA at once, the application ACK later as a new message to the lab.' -ForegroundColor White

Step '6. A result with MSH-15 = AL and MSH-16 = AL: CA now, and an application AA to the lab.'
$r = Send $ResultsPort 'messages/oru-r01-al.hl7'
Check 'CA (commit accept) for CL-ORU-0001' ($r.ackCode -eq 'CA' -and $r.acknowledgedControlId -eq 'CL-ORU-0001') "($($r.ackCode) $($r.error))"
$ack = ApplicationAck 'CL-ORU-0001'
Check 'the lab got an application AA for CL-ORU-0001, "Result filed"' ($ack.ackCode -eq 'AA' -and $ack.text -eq 'Result filed' -and $ack.messageType -eq 'ACK^R01^ACK') ($ack | ConvertTo-Json -Compress)
if ($ack) { Show $ack.ack }
Check 'the EHR filed the result' ([bool](@((Received).results) | Where-Object controlId -eq 'CL-ORU-0001'))

Step '7. A result with MSH-16 = NE (never): CA, and no application ACK.'
$r = Send $ResultsPort 'messages/oru-r01-ne.hl7'
Check 'CA for CL-ORU-0002' ($r.ackCode -eq 'CA' -and $r.acknowledgedControlId -eq 'CL-ORU-0002') "($($r.ackCode))"
$filed = Wait-For { @((Received).results) | Where-Object controlId -eq 'CL-ORU-0002' } 60
Start-Sleep -Seconds 3
Check 'the EHR filed it, and the lab got no application ACK' ($filed -and -not (@((Received).applicationAcks) | Where-Object acknowledgedControlId -eq 'CL-ORU-0002'))

Step '8. A result for an unknown patient, MSH-16 = ER (on error): CA, then an application AE.'
$r = Send $ResultsPort 'messages/oru-r01-unknown-patient.hl7'
Check 'CA for CL-ORU-0003: the message was received safely' ($r.ackCode -eq 'CA' -and $r.acknowledgedControlId -eq 'CL-ORU-0003') "($($r.ackCode))"
$ack = ApplicationAck 'CL-ORU-0003'
Check 'the lab got an application AE, "Unknown patient MRN999999"' ($ack.ackCode -eq 'AE' -and $ack.text -eq 'Unknown patient MRN999999') ($ack | ConvertTo-Json -Compress)

Complete-Demo
