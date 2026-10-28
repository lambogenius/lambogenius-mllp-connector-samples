<#
.SYNOPSIS
    Creates throwaway self-signed TLS certificates for this sample in certs/ (ignored by git).

.DESCRIPTION
    Three certificates, each for localhost and 127.0.0.1, valid for 30 days:
      logicapp  the Logic App's MLLP trigger presents it (logicapp.pfx); the sender trusts logicapp.pem
      lab       the stand-in lab presents it (lab.pem, lab.key); the Logic App pins its thumbprint
      impostor  another certificate for the same names, to show that pinning refuses it
    certs/settings.json holds the .pfx path, its random password and the lab's thumbprint; run.ps1 reads it.
    Nothing goes into the Windows certificate store. Never use these certificates for anything else.

.PARAMETER Force
    Create new certificates even when valid ones exist.
#>
[CmdletBinding()]
param([switch]$Force)

$ErrorActionPreference = 'Stop'
$certs = Join-Path $PSScriptRoot 'certs'
$settingsFile = Join-Path $certs 'settings.json'

if (-not $Force -and (Test-Path $settingsFile)) {
    $existing = Get-Content $settingsFile -Raw | ConvertFrom-Json
    if ([datetime]$existing.expires -gt (Get-Date).AddDays(1) -and (Test-Path $existing.logicAppPfx)) { return $existing }
}
New-Item -ItemType Directory -Force $certs | Out-Null

function New-Certificate([string]$name, [string]$subject) {
    $rsa = [System.Security.Cryptography.RSA]::Create(2048)
    $request = [System.Security.Cryptography.X509Certificates.CertificateRequest]::new(
        "CN=$subject, O=Sample only", $rsa, [System.Security.Cryptography.HashAlgorithmName]::SHA256,
        [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
    $names = [System.Security.Cryptography.X509Certificates.SubjectAlternativeNameBuilder]::new()
    $names.AddDnsName('localhost')
    $names.AddIpAddress([System.Net.IPAddress]::Loopback)
    $request.CertificateExtensions.Add($names.Build())
    $request.CertificateExtensions.Add([System.Security.Cryptography.X509Certificates.X509BasicConstraintsExtension]::new($false, $false, 0, $false))
    $usages = [System.Security.Cryptography.OidCollection]::new()
    $usages.Add([System.Security.Cryptography.Oid]::new('1.3.6.1.5.5.7.3.1')) | Out-Null   # server authentication
    $usages.Add([System.Security.Cryptography.Oid]::new('1.3.6.1.5.5.7.3.2')) | Out-Null   # client authentication
    $request.CertificateExtensions.Add([System.Security.Cryptography.X509Certificates.X509EnhancedKeyUsageExtension]::new($usages, $false))
    $certificate = $request.CreateSelfSigned((Get-Date).AddMinutes(-10), (Get-Date).AddDays(30))
    Set-Content (Join-Path $certs "$name.pem") $certificate.ExportCertificatePem() -NoNewline
    Set-Content (Join-Path $certs "$name.key") $rsa.ExportPkcs8PrivateKeyPem() -NoNewline
    $certificate
}

$password = [Convert]::ToHexString([System.Security.Cryptography.RandomNumberGenerator]::GetBytes(16))
$logicApp = New-Certificate 'logicapp' 'Sample Logic App MLLP listener'
[System.IO.File]::WriteAllBytes((Join-Path $certs 'logicapp.pfx'), $logicApp.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Pfx, $password))
$lab = New-Certificate 'lab' 'Sample lab MLLP listener'
$impostor = New-Certificate 'impostor' 'Sample lab MLLP listener'

$settings = [ordered]@{
    logicAppPfx         = Join-Path $certs 'logicapp.pfx'
    logicAppPfxPassword = $password
    logicAppThumbprint  = $logicApp.Thumbprint
    labThumbprint       = $lab.Thumbprint
    impostorThumbprint  = $impostor.Thumbprint
    expires             = $logicApp.NotAfter.ToString('o')
}
$settings | ConvertTo-Json | Set-Content $settingsFile
Write-Host "Created self-signed certificates in $certs (Logic App $($logicApp.Thumbprint), lab $($lab.Thumbprint))."
[pscustomobject]$settings
