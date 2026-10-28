<#
.SYNOPSIS
    Runs every step of the TLS scenario against the running app and checks the results.

.DESCRIPTION
    Start the sample first with ./run.ps1 (in another window); it creates the certificates in certs/. This script
    resets the stand-ins, sends over MLLP with TLS in both directions, tries the connections that must be refused,
    and checks the results. It exits with 1 when a check fails.
#>
[CmdletBinding()]
param(
    [int]$MllpPort = 2304,
    [string]$BaseUrl = 'http://localhost:7304',
    [string]$StandInUrl = 'http://127.0.0.1:8304'
)

Import-Module (Join-Path $PSScriptRoot '../shared/scripts/MllpSample.psm1') -Force
Set-Location $PSScriptRoot

$trust = Join-Path $PSScriptRoot 'certs/logicapp.pem'
if (-not (Test-Path $trust)) { throw 'certs/logicapp.pem is missing. Start the sample with ./run.ps1 first; it creates the certificates.' }

function Send([string]$what, [hashtable]$options) {
    $r = Send-Hl7 -Port $MllpPort -File 'messages/adt-a04.hl7' -Timeout 5 @options
    Write-Host "  MLLP $what -> $(if ($r.error) { $r.error } else { "$($r.ackCode) in $($r.elapsedMs) ms over $($r.tls)" })"
    $r
}
function ToLab {
    $r = Invoke-MllpWorkflow 'send-result-tls' 'messages/orm-o01.hl7' -BaseUrl $BaseUrl
    Write-Host "  POST send-result-tls orm-o01.hl7 -> HTTP $($r.Status) in $([math]::Round($r.Seconds, 1)) s"
    $r
}
function Received { Invoke-RestMethod "$StandInUrl/received" }
function Control([string]$what) { Invoke-RestMethod -Method Post "$StandInUrl/control/$what" | Out-Null }

try { Control 'reset' } catch { throw "The stand-ins are not answering on $StandInUrl. Start the sample with ./run.ps1 first." }
Assert-Listening $MllpPort 'the MLLP-over-TLS trigger'

Write-Host 'Receive: a sender connects to the Logic App over TLS 1.2.' -ForegroundColor White

Step "1. A sender that trusts the Logic App's certificate: AA, over TLS 1.2."
$r = Send 'TLS 1.2, trusting logicapp.pem' @{ Tls = $true; CaFile = $trust }
Check 'AA for BC-ADT-0001 over TLSv1.2' ($r.ackCode -eq 'AA' -and $r.acknowledgedControlId -eq 'BC-ADT-0001' -and $r.tls -eq 'TLSv1.2') "($($r.ackCode) $($r.tls) $($r.error))"
$m = Wait-For { @((Received).messages) | Where-Object controlId -eq 'BC-ADT-0001' } 60
Check 'the run saw tlsProtocol Tls12' ($m.tlsProtocol -eq 'Tls12') ($m | ConvertTo-Json -Compress)

Step '2. Plain MLLP (no TLS) to the TLS port: refused, no ACK.'
$r = Send 'plain MLLP' @{}
Check 'no acknowledgement; the connection is closed' (-not $r.ackCode -and $r.error) "($($r.ackCode))"

Step '3. TLS 1.3 to a listener set to TLS 1.2: refused during the handshake.'
$r = Send 'TLS 1.3' @{ Tls = $true; CaFile = $trust; TlsVersion = '1.3' }
Check 'the handshake fails (protocol version)' (-not $r.ackCode -and $r.error -match 'PROTOCOL_VERSION|protocol version') "($($r.ackCode) $($r.error))"

Step "4. A sender that doesn't trust the self-signed certificate: it refuses to send."
$r = Send 'TLS 1.2, default trust' @{ Tls = $true }
Check 'certificate verify failed: self-signed certificate' (-not $r.ackCode -and $r.error -match 'CERTIFICATE_VERIFY_FAILED') "($($r.ackCode) $($r.error))"
Start-Sleep -Seconds 2
Check 'no run started for steps 2-4' (@((Received).messages).Count -eq 1) "($(@((Received).messages).Count) messages)"

Write-Host ''
Write-Host "Send: the Logic App connects to the lab over TLS 1.2 and pins the lab's certificate thumbprint." -ForegroundColor White

Step '5. The lab presents its own certificate: AA.'
$r = ToLab
Check 'HTTP 200, AA for MG-ORM-0101' ($r.Status -eq 200 -and $r.Body.ackCode -eq 'AA' -and $r.Body.acknowledgedControlId -eq 'MG-ORM-0101') "($($r.Status) $($r.Body | ConvertTo-Json -Compress -Depth 5))"
Check 'the lab got the order' (@((Received).orders | Where-Object { $_.controlId -eq 'MG-ORM-0101' -and $_.certificate -eq 'genuine' }).Count -eq 1)

Step '6. Something else answers on the lab port, with another self-signed certificate for the same names.'
Control 'impostor'
$r = ToLab
Control 'genuine'
Check 'HTTP 502: the TLS handshake fails, the certificate is rejected' ($r.Status -eq 502 -and "$($r.Body.detail.body.message)" -match 'TLS handshake' -and "$($r.Body.detail.body.message)" -match 'certificate was rejected') "($($r.Status) $($r.Body.detail.body.message))"
Show "$($r.Body.detail.body.message)"
Check 'nothing was sent to it' (@((Received).orders).Count -eq 1) "($(@((Received).orders).Count) orders)"

Step '7. The real lab is back: AA again.'
$r = ToLab
Check 'HTTP 200, AA' ($r.Status -eq 200 -and $r.Body.ackCode -eq 'AA') "($($r.Status))"

Complete-Demo
