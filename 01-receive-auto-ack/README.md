# 01 · Receive with auto ACK

A hospital's patient administration system (PAS) sends ADT messages over MLLP. The Logic App listens on port 2301.
The connector answers each message as soon as the run is saved, like a BizTalk one-way MLLP receive location with
the HL7 pipeline generating ACKs. The run then passes the message to the patient registry.

```
PAS (mllp.py) ──MLLP──▶ adt-receive :2301                       patient registry :8301
            ◀──AA/CA──    trigger: When a message is received      (backends/app.py)
                          Query: find the PID segment
                          HTTP: POST /adt ────────────────────────▶
                          archive/: the message and the ACK, as files
```

| Trigger input | Value | Why |
|---|---|---|
| `acknowledgementMode` | `Auto` | the connector answers once the run is saved (stateful workflow), or AE if it can't start one |
| `acknowledgementType` | `Original` | AA / AE / AR; CA / CE / CR when the sender fills in MSH-15 (enhanced mode) |
| `batchMode` | `Split` | a batch (BHS … BTS) becomes one run per message, in order, and one batch ACK |
| `rejectInvalidMessages` | `true` | no valid MSH, or no MSH-9, -10, -11 or -12: AR, and no run |
| `keepConnectionOpen` | `true` | the sender may send many messages on one connection |
| `archive` | `true` | the raw message and the ACK are written to `archive/` (app settings `LamboHl7Mllp__Archive__*`) |

## Run it

See the [prerequisites](../README.md#prerequisites).

```powershell
./run.ps1      # Azurite, the stand-in registry on 8301, the Logic App on 7301 with MLLP on 2301
./demo.ps1     # in a second window: the 7 steps below, checked
```

Or step by step:

```powershell
./send.ps1 messages/adt-a01.hl7
./send.ps1 messages/adt-batch.hl7
Invoke-RestMethod http://127.0.0.1:8301/received | ConvertTo-Json -Depth 5     # what the registry got
```

1. **An admission (`adt-a01.hl7`).** AA. The ACK swaps sender and receiver and echoes MSH-10 in MSA-2:
   ```
   MSH|^~\&|LOGICAPP|INTEGRATION|PAS|MAPLE_GROVE|20261028063825-0400||ACK^A01^ACK|26102810382535300001|P|2.5.1
   MSA|AA|MG-ADT-0001
   ```
   The registry gets patient `MRN100001`, `SAMPLE^ALICE^M`, read from PID-3 and PID-5 with a Query action and
   `split()`.
2. **Enhanced mode (`adt-a08-enhanced.hl7`, MSH-15 = `AL`).** CA, a commit acknowledgement.
3. **A batch (`adt-batch.hl7`) of three messages.** One batch ACK: BHS (BHS-12 = the batch's BHS-11
   `MG-BATCH-0001`), an MSH and MSA AA per message, and `BTS|3`. Three runs; each has `batchIndex` 1–3 and
   `batchCount` 3.
4. **Not HL7 (`no-msh.hl7`).** AR with `ERR|^^^100&Segment sequence error&HL70357`, and no run.
5. **No message control ID (`missing-control-id.hl7`).** AR with ERR code 101, and no run.
6. **Two messages on one connection.** Both runs have the same `connectionId`, with `sequenceNumber` 1 and 2.
7. **The archive.** `archive/<date>/adt-receive/` holds each message byte for byte, the ACK sent back, and a
   `.json` with the metadata of each. The ACK's `relatedId` is the message's `archiveId`, which the run also has.
   File names sort in the order things happened:
   ```
   20261028T103824.9835053Z_000001_in_msg_MG-ADT-0001_6ca36880….hl7
   20261028T103825.3558942Z_000001_out_ack_26102810382535300001_f236e541….hl7
   ```

## Design notes

- **Auto ACK means "received", not "processed".** The sender gets AA as soon as the run is saved; the registry
  call happens after that. If the registry is down, the HTTP action retries (3 times, 5 seconds apart), and a failed
  run stays in the run history to resubmit. To answer only after processing, use Workflow mode (sample 02).
- **Runs are not FIFO.** Stateful runs start in order but can finish in any order, so the registry may get a
  batch's messages out of order. Each run has `batchIndex` and `sequenceNumber`. When order matters, process in a
  stateless workflow in Workflow mode, where the sender waits for each ACK.
- **Archiving is off by default.** It is switched on per trigger (`archive: true`) and set up in app settings:
  `LamboHl7Mllp__Archive__Targets` = `File` and `LamboHl7Mllp__Archive__File__Path`. `run.ps1` points the path at
  this folder's `archive/` (ignored by git). The targets can also be a NAS share or SQL Server; see the
  [documentation](https://docs.lambogenius.com/hl7-mllp-connector). When a message can't be archived, the sender gets
  AE and no run starts.
