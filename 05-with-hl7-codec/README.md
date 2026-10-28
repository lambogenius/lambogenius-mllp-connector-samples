# 05 · With the HL7 v2 Codec

Receive over MLLP, decode with the [HL7 v2 Codec](https://lambogenius.com/app/downloads/hl7-v2-codec), and answer
with the codec's acknowledgement. The decoded message, as JSON, goes to a clinical data repository. This sample
needs both packages in [`../packages`](../packages).

```
PAS / lab ──MLLP──▶ hl7-decode-ack :2305
          ◀──ACK──    trigger: When a message is received (Workflow mode)
                      HL7 v2 Codec: Decode HL7 message (schemaless, JSON)
                      AA? HTTP: POST /messages ──────────────────────▶ repository :8305 (backends/app.py)
                          Send acknowledgement: the codec's ACK
                      else Send acknowledgement: the codec's ACK (AR / AE)
```

**No XSDs.** The codec decodes in schemaless mode (`allowSchemaless: true`): no schema is deployed, and fields get
generic names. `PID_5` is the patient name and `PID_5_0` its first component; a repeating field is an array.
With your own XSDs in `Artifacts/Schemas`, names come from the schema and the codec validates the message. See the
codec's documentation and its samples: <https://github.com/lambogenius/lambogenius-hl7-v2-codec-samples>.

The codec's connection needs one value, even an empty one:

```json
"lamboHl7Codec": {
  "displayName": "HL7 v2 (Lambogenius)",
  "serviceProvider": { "id": "/serviceProviders/lamboHl7Codec" },
  "parameterValues": { "schemaFolder": "" }
}
```

The decode action:

```json
"Decode_HL7_message": {
  "type": "ServiceProvider",
  "inputs": {
    "parameters": {
      "message": "@triggerBody()?['message']",
      "allowSchemaless": true, "validateXml": false, "outputFormat": "json",
      "generateAck": true, "ackMode": "Original", "supportedVersions": "2.3,2.3.1,2.4,2.5,2.5.1"
    },
    "serviceProviderConfiguration": { "connectionName": "lamboHl7Codec", "operationId": "decode", "serviceProviderId": "/serviceProviders/lamboHl7Codec" }
  }
}
```

**Send acknowledgement** then returns the codec's ACK as it is: `"acknowledgement": "@body('Decode_HL7_message')?['ack']"`.

## Run it

See the [prerequisites](../README.md#prerequisites).

```powershell
./run.ps1      # Azurite, the stand-in repository on 8305, the Logic App on 7305 with MLLP on 2305
./demo.ps1     # in a second window: the 4 steps below, checked
```

Or step by step:

```powershell
./send.ps1 messages/adt-a01.hl7
Invoke-RestMethod http://127.0.0.1:8305/received | ConvertTo-Json -Depth 10     # the decoded messages
```

1. **An admission (`adt-a01.hl7`).** AA from the codec. The repository gets:
   ```json
   { "ADT_A01": {
       "MSH": { "MSH_3": "PAS", "MSH_9": { "MSH_9_0": "ADT", "MSH_9_1": "A01", "MSH_9_2": "ADT_A01" }, "MSH_10": "MG-ADT-0501", … },
       "PID": { "PID_3": [ { "PID_3_0": "MRN100005", "PID_3_3": "MAPLE_GROVE", "PID_3_4": "MR" },
                           { "PID_3_0": "5550001", "PID_3_3": "PROV", "PID_3_4": "HC" } ],
                "PID_5": { "PID_5_0": "SAMPLE", "PID_5_1": "HANNAH", "PID_5_2": "R" }, … },
       "PV1": { … } } }
   ```
2. **A lab result (`oru-r01.hl7`).** AA; the two OBX segments are an array, in order.
3. **HL7 v2.2 (`adt-a01-v22.hl7`).** Not in `supportedVersions`: the codec answers AR, nothing is stored.
   ```
   MSA|AR|MG-ADT-0502|HL7 version '2.2' is not supported.
   ERR|MSH^1^12^203&Unsupported version id&HL70357
   ```
   The ERR segment has the layout of the message's version (ERR-1 before v2.5, ERR-3 from v2.5 on).
4. **The repository is down (`POST /control/down`).** The workflow answers AR itself ("The repository is not
   available. Send the message again later."); sent again once it's back: AA.

## Design notes

- **Who checks what.** The MLLP connector checks the envelope: a message without a valid MSH gets AR from the
  connector, and no run starts. The codec checks the content and the version, and builds the ACK.
- **The codec's `json` output is a string.** The workflow parses it with `json()` before sending it on, so the
  repository gets an object.
- **HL7 problems never fail the decode action.** Check `ackCode` (or `success`) and return `ack`. The action only
  fails for a missing message or an unexpected error.
