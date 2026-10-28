# 04 · TLS

MLLP over TLS 1.2 in both directions. A clinic sends ADT messages to the Logic App over TLS, and the Logic App
sends orders to the lab over TLS, trusting only the lab's certificate.

```
clinic ──MLLP/TLS──▶ adt-receive-tls :2304                           recorder :8304
       ◀──AA────────   certificate: certs/logicapp.pfx                (backends/app.py)
                       HTTP: POST /received-messages (with tlsProtocol) ─▶

caller ──POST──▶ send-result-tls
                   Send message ──MLLP/TLS, pinned thumbprint──▶ lab :2314 (certs/lab.pem)
```

## The certificates

`run.ps1` runs `New-SampleCertificates.ps1` first. It creates three throwaway self-signed certificates in `certs/`
(ignored by git), for `localhost` and `127.0.0.1`, valid for 30 days, with a random PFX password. Nothing goes into
the Windows certificate store, and no certificate or key is part of this repository.

| File | Used by |
|---|---|
| `logicapp.pfx` | the Logic App's trigger: app settings `MLLP_TLS_CERTIFICATE` (the path) and `MLLP_TLS_CERTIFICATE_PASSWORD` |
| `logicapp.pem` | the sender, to trust the Logic App |
| `lab.pem`, `lab.key` | the stand-in lab. Its SHA-1 thumbprint goes into the app setting `LAB_TLS_THUMBPRINT` |
| `impostor.pem`, `impostor.key` | the stand-in lab, while switched to the impostor (step 6) |
| `settings.json` | the path, password and thumbprints; `run.ps1` passes them to the Logic App as app settings |

Run `./New-SampleCertificates.ps1 -Force` to make new ones.

The connections:

```json
"lamboHl7MllpTlsListener": {
  "parameterValues": {
    "host": "@appsetting('MLLP_LISTEN_HOST')", "port": "@appsetting('MLLP_TLS_PORT')",
    "useTls": "true", "tlsVersion": "1.2",
    "tlsCertificate": "@appsetting('MLLP_TLS_CERTIFICATE')",
    "tlsCertificatePassword": "@appsetting('MLLP_TLS_CERTIFICATE_PASSWORD')"
  }
},
"lamboHl7MllpLabTls": {
  "parameterValues": {
    "host": "@appsetting('LAB_HOST')", "port": "@appsetting('LAB_TLS_PORT')",
    "useTls": "true", "tlsVersion": "1.2",
    "tlsTrustedThumbprints": "@appsetting('LAB_TLS_THUMBPRINT')", "tlsTrustedThumbprintsOnly": "true"
  }
}
```

## Run it

See the [prerequisites](../README.md#prerequisites).

```powershell
./run.ps1      # the certificates, Azurite, the stand-ins (HTTP 8304, lab on MLLP/TLS 2314), the Logic App on 7304 with MLLP/TLS on 2304
./demo.ps1     # in a second window: the 7 steps below, checked
```

Or step by step:

```powershell
./send.ps1 messages/adt-a04.hl7              # over TLS, trusting certs/logicapp.pem
./send.ps1 messages/orm-o01.hl7 -ToLab       # the Logic App sends it to the lab over TLS
```

| Step | What happens |
|---|---|
| **1.** A sender that trusts `logicapp.pem` | AA over TLSv1.2; the run's `tlsProtocol` output is `Tls12` |
| **2.** Plain MLLP to port 2304 | the connection is closed, no ACK, no run |
| **3.** TLS 1.3 to the TLS 1.2 listener | the handshake fails (protocol version). Each connection uses exactly one version, `1.2` or `1.3` |
| **4.** A sender that doesn't trust the self-signed certificate | the sender refuses ("certificate verify failed: self-signed certificate") |
| **5.** Send to the lab | HTTP 200, AA |
| **6.** The lab port presents another certificate for the same names (`POST /control/impostor`) | HTTP 502: "The TLS handshake with 127.0.0.1:2314 failed (Tls12): The remote certificate was rejected …"; nothing is sent |
| **7.** The real lab is back | HTTP 200, AA |

## Design notes

- **The certificate setting** takes a `.pfx` or `.pem` path, Base64 PFX content, or a certificate store thumbprint.
  In Azure, keep the certificate in Key Vault and use a Key Vault reference in the app setting; it arrives as Base64
  PFX.
- **Pinning.** `tlsTrustedThumbprints` alone *adds* trust: the listed self-signed certificate is accepted, and so is
  any certificate that validates normally. `tlsTrustedThumbprintsOnly` accepts *only* the listed certificates, which
  is what refuses the impostor in step 6, even though it is for the same names.
- **Mutual TLS.** Set `tlsRequireClientCertificate` (and `tlsTrustedThumbprints` for the allowed clients) on the
  listener's connection, and `tlsCertificate` on the sending connection for its client certificate.
- **Requiring TLS everywhere.** The app setting `LamboHl7Mllp__Security__RequireTls` = `true` stops plain-MLLP
  triggers from starting and makes plain **Send message** fail with 403.
