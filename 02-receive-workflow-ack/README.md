# 02 · Workflow acknowledgements

Two ways for a workflow, not the connector, to decide what the sender is told.

**Two-way receive (`adt-two-way`, port 2302).** Like a BizTalk request-response MLLP receive location: the sender
waits on the connection while the workflow stores the admission in the EHR, then the workflow answers with **Send
acknowledgement**. The workflow is stateless, so it answers in milliseconds.

**Enhanced mode (`results-enhanced`, port 2312).** The lab fills in MSH-15 and MSH-16. The connector answers the
commit acknowledgement (CA) as soon as the run is saved. Once the result is filed, the workflow builds the
application acknowledgement with **Create acknowledgement** and sends it to the lab as a new message with **Send
message**, as the HL7 standard describes.

```
PAS ──ADT──▶ adt-two-way :2302                                EHR :8302 (backends/app.py)
    ◀─AA/AE/AR── is it ADT?  HTTP: POST /patients ─────────────▶ 201 / 422 / 503
                 Send acknowledgement (code and text from the EHR's answer)

lab ──ORU──▶ results-enhanced :2312                               EHR :8302
    ◀──CA──   HTTP: POST /results ─────────────────────────────▶ 201 / 422
              MSH-16 asks for it? Create acknowledgement, Send message ──MLLP──▶ lab :2322
```

## Run it

See the [prerequisites](../README.md#prerequisites).

```powershell
./run.ps1      # Azurite, the stand-in EHR on 8302 and lab on 2322, the Logic App on 7302 with MLLP on 2302 and 2312
./demo.ps1     # in a second window: the 8 steps below, checked
```

Or step by step:

```powershell
./send.ps1 messages/adt-a01.hl7
./send.ps1 messages/oru-r01-al.hl7 -Port 2312
Invoke-RestMethod http://127.0.0.1:8302/received | ConvertTo-Json -Depth 5     # patients, results, application ACKs
```

| Step | Message | The EHR | The sender gets |
|---|---|---|---|
| 1 | `adt-a01.hl7` | 201, key `EHR-000001` | `MSA\|AA\|MG-ADT-0201\|Stored as EHR-000001` |
| 2 | `adt-a01-unknown-ward.hl7` | 422 "Ward WARD9 does not exist" | AE with that text, and `ERR\|\|\|207^Application internal error^HL70357\|E\|\|\|\|Ward WARD9 does not exist` |
| 3 | `siu-s12.hl7` | not called | AR "Unsupported message type SIU S12", ERR code 200 |
| 4 | `adt-a04.hl7`, EHR down (`POST /control/down`) | 503 | AR "The EHR is not available. Send the message again later."; sent again once it's back: AA |
| 5 | `adt-a04.hl7`, EHR slow (`POST /control/slow`, 15 s) | answers too late | after 10 s, AE from the connector: "Timed out waiting for the application response." |
| 6 | `oru-r01-al.hl7` (MSH-15 `AL`, MSH-16 `AL`) | 201 | CA at once; then the lab gets `MSA\|AA\|CL-ORU-0001\|Result filed` |
| 7 | `oru-r01-ne.hl7` (MSH-16 `NE`) | 201 | CA, and no application ACK |
| 8 | `oru-r01-unknown-patient.hl7` (MSH-16 `ER`) | 422 "Unknown patient MRN999999" | CA; then the lab gets an application AE with that text |

## Design notes

- **Which code when.** AA: processed. AE: the message has a problem the sender must fix; sending it again won't
  help. AR: rejected, for example because a system is down; the sender may send it again. The workflow maps the
  EHR's 201, 422 and anything else to these.
- **The timeout.** `responseTimeoutSeconds` (10 here, 60 by default) is how long the connector waits for **Send
  acknowledgement**. Then `timeoutBehavior` applies: `SendNegativeAck` (AE, as here), `CloseConnection` or
  `NoResponse`. Keep it below the sender's own ACK timeout. The workflow's late **Send acknowledgement** then fails,
  and its run shows that.
- **Prefer stateless workflows in Workflow mode.** The sender waits for the whole run. Each connection is answered
  in order, so the receiving system processes messages in the order it got them (FIFO).
- **Send acknowledgement runs on the instance that holds the connection.** The connector marks it so, and the
  pending ACK is in memory. If the instance restarts, the sender sees the connection drop and sends again, which is
  normal MLLP behaviour.
- **Enhanced mode and the trigger.** With `acknowledgementType: Original`, the connector answers AA/AE/AR when
  MSH-15 and MSH-16 are empty, and CA/CE/CR when the sender fills them in. The trigger outputs
  `acceptAckType` (MSH-15), `applicationAckType` (MSH-16) and `applicationAckRequested`.
