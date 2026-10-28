# HL7 MLLP Connector for Azure Logic Apps: samples

Complete, runnable Azure Logic Apps (Standard) projects that use the **HL7 MLLP Connector**, the Lambogenius
built-in connector that sends and receives HL7 v2 messages over MLLP. It works the way HTTP does in Logic Apps, and
its acknowledgements follow the BizTalk Accelerator for HL7:

| HTTP in Logic Apps | HL7 MLLP Connector |
|---|---|
| **When an HTTP request is received** (trigger) | **When a message is received**: listens on a TCP port and starts a run per HL7 message |
| **Response** action | **Send acknowledgement**: returns the ACK on the sender's open connection |
| **HTTP** action | **Send message**: connects, sends, waits for the ACK and returns it |
| | **Create acknowledgement**: builds an ACK for a message, to send later |

Each sample folder holds:
- a NuGet-based Logic App project with its workflows;
- a stand-in for every system it talks to (Python, standard library only), and an MLLP sender
  ([`shared/tools/mllp.py`](shared/tools/mllp.py));
- test messages, all made up: no real patients, facilities or identifiers;
- `run.ps1`, which starts everything, and `demo.ps1`, which runs each step and checks the result.

Documentation: <https://docs.lambogenius.com/hl7-mllp-connector>

| Sample | What it shows |
|---|---|
| [01 · Receive with auto ACK](01-receive-auto-ack) | An ADT source sends over MLLP; the connector answers AA (CA in enhanced mode) once the run is saved, and the run passes the message to a patient registry. Malformed messages get AR and start no run. An HL7 batch becomes one run per message and one batch ACK. Every message and ACK is archived to files |
| [02 · Workflow acknowledgements](02-receive-workflow-ack) | Two-way receive, as in BizTalk: the workflow stores the admission in an EHR and answers AA, AE with the EHR's reason, or AR, with **Send acknowledgement**; a slow EHR gets the connector's timeout AE. Enhanced mode: CA at once, then an application ACK, built with **Create acknowledgement**, sent back to the lab |
| [03 · Send](03-send) | An HTTP-triggered workflow sends orders to a lab over MLLP and returns its ACK: AA, AE, and a lab that doesn't answer (ACK timeout). Persistent connections |
| [04 · TLS](04-tls) | MLLP over TLS 1.2 in both directions with throwaway self-signed certificates: receive, plain MLLP and the wrong TLS version refused, send with a pinned certificate thumbprint, and an impostor certificate refused |
| [05 · With the HL7 v2 Codec](05-with-hl7-codec) | Receive over MLLP, decode with the HL7 v2 Codec in schemaless mode (no XSDs), store the JSON form, and return the codec's acknowledgement, AR for an unsupported HL7 version |

## Prerequisites

1. **Windows** (the samples are tested on Windows 11) with:
   - the [.NET SDK 8](https://dotnet.microsoft.com/download/dotnet/8.0);
   - [Azure Functions Core Tools 4](https://learn.microsoft.com/azure/azure-functions/functions-run-local): `npm install -g azure-functions-core-tools@4`;
   - [Azurite](https://learn.microsoft.com/azure/storage/common/storage-use-azurite): `npm install -g azurite`;
   - [PowerShell 7](https://aka.ms/powershell);
   - [Python 3](https://www.python.org/downloads/) for the stand-in systems and the MLLP sender (every sample).
2. **The HL7 MLLP Connector package.** Sign in at <https://lambogenius.com/app/downloads/hl7-mllp-connector>,
   download `Lambogenius.MllpConnector.LogicApps.1.4.0.nupkg`, and save it in [`packages/`](packages). Sample 05
   also needs the HL7 v2 Codec: `Lambogenius.Hl7Codec.LogicApps.1.1.0.nupkg` from
   <https://lambogenius.com/app/downloads/hl7-v2-codec>. Every sample's project finds them there through the
   repository's `nuget.config`.
3. **No license to run the samples.** Under Azure Functions Core Tools (`func start`, which `run.ps1` uses) the
   connector runs without one and logs a reminder. Anywhere else, Azure included, it needs a license token in the
   app setting `LAMBOGENIUS_LICENSE`: a free [developer license](https://lambogenius.com/app/licensing?start=hl7-developer)
   for development and testing, or the [30-day trial](https://lambogenius.com/app/licensing?start=hl7-trial) or a
   paid license for production. One token covers the HL7 MLLP Connector and the HL7 v2 Codec.

Every sample starts the same way:

```powershell
cd 01-receive-auto-ack
./run.ps1          # builds the project, starts Azurite and the stand-ins, then the Logic App
# in a second window:
./demo.ps1         # every step, checked; exits with 1 when a check fails
./send.ps1 messages/adt-a01.hl7    # or send one message yourself
```

Clone to a short path, such as `C:\src\mllp-samples`. The builds write files up to about 165 characters below the
clone folder. A clone folder path longer than about 90 characters exceeds the Windows 260-character path limit. The
build then fails with `MSB3030: Could not copy the file … CustomCodeNetFxWorker …`.

The first build restores NuGet packages and takes a few minutes. The Logic App is ready when its log shows
`Host lock lease acquired`. **Ctrl+C** stops it and everything `run.ps1` started.

Each sample has its own ports, so several can run at once:

| Sample | Logic App | MLLP trigger (Logic App listens) | Stand-in HTTP | Stand-in MLLP (stand-in listens) |
|---|---|---|---|---|
| 01 | 7301 | 2301 | 8301 registry | |
| 02 | 7302 | 2302 ADT, 2312 lab results | 8302 EHR | 2322 lab, for application ACKs |
| 03 | 7303 | | 8303 lab control | 2303 lab |
| 04 | 7304 | 2304 (TLS) | 8304 recorder, lab control | 2314 lab (TLS) |
| 05 | 7305 | 2305 | 8305 repository | |

The MLLP triggers listen on 127.0.0.1 only (app setting `MLLP_LISTEN_HOST`). Set it to `0.0.0.0` to take
messages from other machines. All samples share one Azurite on ports 10000–10002. If another program holds one of
those ports (VS Code sometimes holds 10001), `run.ps1` starts Azurite on free ports and points the Logic App at them.

### Testing with the `mllp` tool

`demo.ps1` and `send.ps1` use the Python sender in `shared/tools`. You can also drive any sample with the `mllp`
test tool (`mllp send`, `mllp receive`, `mllp load`, `mllp cert`), the equivalent of BizTalk's MLLPSend.exe and
MLLPReceive.exe. It is a self-contained executable for Windows, Linux and macOS: no .NET, no license. Download it
next to the package at <https://lambogenius.com/app/downloads/hl7-mllp-connector>. Guide:
<https://docs.lambogenius.com/hl7-mllp-connector/testing>.

| Sample | Try |
|---|---|
| 01 | `mllp send --port 2301 --file messages\adt-a01.hl7`, or `--file messages\adt-batch.hl7` for a batch ACK |
| 02 | `mllp send --port 2302 --file messages\adt-a01-unknown-ward.hl7` (AE from the workflow; exit code 1) |
| 03 | `./run.ps1 -NoStandIns`, then `mllp receive --port 2303` (or `--ack-code AE`, or `--no-ack`) in its place, and `./send.ps1 messages/orm-o01-glucose.hl7` |
| 04 | `mllp send --port 2304 --tls --pin <logicAppThumbprint from certs\settings.json> --file messages\adt-a04.hl7` |
| 05 | `mllp send --port 2305 --file messages\adt-a01.hl7` |

## How a sample is put together

| File | What it is |
|---|---|
| `LogicApp.csproj` | references `Microsoft.Azure.Workflows.WebJobs.Extension` 1.170.91 and `Lambogenius.MllpConnector.LogicApps` (and, in 05, `Lambogenius.Hl7Codec.LogicApps`). It also removes `extensionBundle` from the `host.json` the runtime uses, so the host loads the built-in connectors from this project's packages |
| `connections.json` | one `lamboHl7Mllp` connection per listening port and per destination |
| `local.settings.sample.json` | app settings; `run.ps1` copies it to `local.settings.json` (ignored by git) on the first run |
| `<workflow>/workflow.json` | the workflows |
| `messages/` | test messages, one message or batch per file. The files use line feeds so they read well; the sender turns them into the carriage returns HL7 uses |
| `backends/app.py` | the stand-in systems |

A trigger and its connection:

```json
"When_a_message_is_received": {
  "type": "ServiceProvider",
  "inputs": {
    "parameters": { "acknowledgementMode": "Auto", "acknowledgementType": "Original", "batchMode": "Split" },
    "serviceProviderConfiguration": {
      "connectionName": "lamboHl7MllpAdtListener",
      "operationId": "receiveMessage",
      "serviceProviderId": "/serviceProviders/lamboHl7Mllp"
    }
  }
}
```

```json
"lamboHl7MllpAdtListener": {
  "displayName": "MLLP listener for ADT (Lambogenius)",
  "serviceProvider": { "id": "/serviceProviders/lamboHl7Mllp" },
  "parameterValues": { "host": "@appsetting('MLLP_LISTEN_HOST')", "port": "@appsetting('MLLP_ADT_PORT')" }
}
```

Things to know:
- **A trigger's `host` must be an `@appsetting(...)` reference.** The runtime rejects a literal value.
- **One connection, and one port, per receiving workflow.** **Send acknowledgement** names the trigger's connection.
- The operations are `receiveMessage` (trigger), `sendMessage`, `sendAcknowledgement` and `createAcknowledgement`.
  The trigger's outputs are in `triggerBody()`: `message`, `messageControlId`, `messageType`, `contextId`, the MSH
  fields, `connectionId`, `batchIndex`, `tlsProtocol`, `archiveId` and more.
- `retryPolicy` goes **inside** `inputs`. Placed next to `inputs`, it is ignored and the runtime's default policy
  applies.

## Running in Azure

The samples run locally. The receive trigger opens a TCP port inside the Logic Apps host, so the host must accept
inbound TCP on that port: use hybrid deployment (Logic Apps Standard on Container Apps) or containers. App
Service-based plans (WS1–WS3) don't route inbound traffic to other ports, so there only **Send message** and
**Create acknowledgement** apply. For Consumption Logic Apps, contact sales.

To deploy a sample:
1. Run `dotnet publish -c Release`.
2. Deploy the publish folder to the Logic App.
3. Set the app settings from `local.settings.sample.json`, with real hosts and ports, and set `LAMBOGENIUS_LICENSE`
   to a license token from the [Licensing page](https://lambogenius.com/app/licensing). Without it, the trigger
   answers AR and starts no run, and the actions fail with 403.
4. Keep certificates in Key Vault and reference them from app settings
   (`@Microsoft.KeyVault(SecretUri=...)`); see sample 04.

See the [documentation](https://docs.lambogenius.com/hl7-mllp-connector).

## Support

Questions and bug reports: <hello@lambogenius.com>. The connector packages are not part of this repository.
