<#
.SYNOPSIS
    Runs every step of the auto-ACK scenario against the running app and checks the results.

.DESCRIPTION
    Start the sample first with ./run.ps1 (in another window). This script resets the stand-in patient registry,
    sends the messages in messages/ over MLLP, and checks the acknowledgements, what the registry received and what
    the connector archived. It exits with 1 when a check fails.
#>
[CmdletBinding()]
param(
    [int]$MllpPort = 2301,
    [string]$RegistryUrl = 'http://127.0.0.1:8301'
)

Import-Module (Join-Path $PSScriptRoot '../shared/scripts/MllpSample.psm1') -Force
Set-Location $PSScriptRoot

function Send([string[]]$files) {
    $results = Send-Hl7 -Port $MllpPort -File $files
    foreach ($r in $results) { Write-Host "  MLLP $($r.name) -> $(if ($r.error) { $r.error } else { "$($r.ackCode) in $($r.elapsedMs) ms" })" }
    $results
}
function Received { @((Invoke-RestMethod "$RegistryUrl/received").adt) }
function Registered([string]$controlId) { Wait-For { Received | Where-Object controlId -eq $controlId | Select-Object -Last 1 } 60 }

try { Invoke-RestMethod -Method Post "$RegistryUrl/control/reset" | Out-Null } catch { throw "The stand-in registry is not answering on $RegistryUrl. Start the sample with ./run.ps1 first." }
Assert-Listening $MllpPort 'the MLLP trigger'

Step '1. An admission (ADT^A01): the connector answers AA once the run is saved; the run passes it on.'
$r = Send 'messages/adt-a01.hl7'
Check 'AA for MG-ADT-0001' ($r.ackCode -eq 'AA' -and $r.acknowledgedControlId -eq 'MG-ADT-0001') "($($r.ackCode) $($r.error))"
Check 'the ACK swaps sender and receiver (MSH-3 LOGICAPP, MSH-5 PAS) and answers ACK^A01^ACK' ($r.ack -match '^MSH\|\^~\\&\|LOGICAPP\|INTEGRATION\|PAS\|MAPLE_GROVE\|' -and $r.ack -match 'ACK\^A01\^ACK')
Show $r.ack
$adt = Registered 'MG-ADT-0001'
Check 'the registry got MG-ADT-0001 for patient MRN100001, SAMPLE^ALICE^M' ($adt.patientId -eq 'MRN100001' -and $adt.patientName -eq 'SAMPLE^ALICE^M' -and $adt.event -eq 'A01') ($adt | ConvertTo-Json -Compress)

Step '2. An update in enhanced mode (MSH-15 = AL): a commit acknowledgement, CA.'
$r = Send 'messages/adt-a08-enhanced.hl7'
Check 'CA for MG-ADT-0002' ($r.ackCode -eq 'CA' -and $r.acknowledgedControlId -eq 'MG-ADT-0002') "($($r.ackCode) $($r.error))"
Check 'the registry got the A08' ([bool](Registered 'MG-ADT-0002'))

Step '3. A batch of three messages (BHS ... BTS): one run per message and one batch acknowledgement.'
$r = Send 'messages/adt-batch.hl7'
Check 'a batch ACK: BHS-12 names the batch, three MSA AA, BTS|3' ($r.ack -match '(?m)^BHS\|.*\|MG-BATCH-0001$' -and @($r.acks).Count -eq 3 -and @($r.acks | Where-Object code -eq 'AA').Count -eq 3 -and $r.ack -match 'BTS\|3') ($r.ack -replace "`n", ' / ')
Check 'the ACKs are for MG-ADT-0101, 0102 and 0103, in order' ((@($r.acks).controlId -join ',') -eq 'MG-ADT-0101,MG-ADT-0102,MG-ADT-0103') (@($r.acks).controlId -join ',')
$batch = Wait-For { $b = @(Received | Where-Object batchControlId -eq 'MG-BATCH-0001'); if ($b.Count -ge 3) { , $b } } 60
Check 'the registry got three runs with batchIndex 1-3 of batchCount 3' (@($batch).Count -eq 3 -and ((@($batch).batchIndex | Sort-Object) -join ',') -eq '1,2,3' -and @($batch | Where-Object batchCount -eq 3).Count -eq 3) (@($batch).batchIndex -join ',')

Step '4. Something that is not HL7 (no MSH segment): AR, and no run starts.'
$before = (Received).Count
$r = Send 'messages/no-msh.hl7'
Check 'AR with an ERR segment (code 100)' ($r.ackCode -eq 'AR' -and "$($r.errors)" -match '100') "($($r.ackCode) $($r.errors))"
Check 'the reason is in MSA-3' ($r.ackText -match 'MSH') $r.ackText

Step '5. A message without MSH-10 (message control ID): AR, and no run starts.'
$r = Send 'messages/missing-control-id.hl7'
Check 'AR with ERR code 101 (required field missing)' ($r.ackCode -eq 'AR' -and "$($r.errors)" -match '101') "($($r.ackCode) $($r.errors))"
Start-Sleep -Seconds 3
Check 'the registry got nothing from steps 4 and 5' ((Received).Count -eq $before) "($((Received).Count) instead of $before)"

Step '6. Two messages on one connection (persistent connection, like an interface engine).'
$r = Send 'messages/adt-a01.hl7', 'messages/adt-a08-enhanced.hl7'
Check 'AA, then CA' ($r[0].ackCode -eq 'AA' -and $r[1].ackCode -eq 'CA') "($($r.ackCode -join ', '))"
$pair = Wait-For { $all = Received; $a = $all | Where-Object controlId -eq 'MG-ADT-0001' | Select-Object -Last 1; $b = $all | Where-Object controlId -eq 'MG-ADT-0002' | Select-Object -Last 1; if ($a -and $b -and $a.connectionId -eq $b.connectionId) { , @($a, $b) } } 60
Check 'both runs have the same connectionId, with sequenceNumber 1 and 2' ($pair -and $pair[0].sequenceNumber -eq 1 -and $pair[1].sequenceNumber -eq 2) ($pair | ConvertTo-Json -Compress -Depth 2)

Step '7. The archive: each message as it came off the wire, and the ACK that went back.'
$archive = Join-Path $PSScriptRoot 'archive'
$adt = Registered 'MG-ADT-0001'
$message = Get-ChildItem $archive -Recurse -Filter "*_in_msg_MG-ADT-0001_$($adt.archiveId).hl7" -ErrorAction SilentlyContinue | Select-Object -First 1
Check "the message is in archive/ under its archiveId ($($adt.archiveId))" ([bool]$message)
if ($message) {
    Check 'byte for byte what the sender sent (CR segment ends)' ((Get-Content $message.FullName -Raw) -ceq ((Get-Content 'messages/adt-a01.hl7' -Raw) -replace "`r?`n", "`r"))
    $ackMeta = Get-ChildItem $archive -Recurse -Filter '*_out_ack_*.json' | Where-Object { (Get-Content $_.FullName -Raw | ConvertFrom-Json).relatedId -eq $adt.archiveId } | Select-Object -First 1
    $meta = if ($ackMeta) { Get-Content $ackMeta.FullName -Raw | ConvertFrom-Json }
    Check 'the ACK is archived next to it, linked by relatedId, with ackCode AA' ($meta.ackCode -eq 'AA' -and $meta.direction -eq 'Outbound') ($meta | ConvertTo-Json -Compress)
    Show ($message.FullName.Substring($PSScriptRoot.Length + 1))
    if ($ackMeta) { Show ($ackMeta.FullName.Substring($PSScriptRoot.Length + 1) -replace '\.json$', '.hl7') }
}

Complete-Demo
