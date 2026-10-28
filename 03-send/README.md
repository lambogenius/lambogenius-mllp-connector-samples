# 03 · Send

An HTTP-triggered workflow sends lab orders (ORM^O01) to the laboratory system over MLLP and returns the lab's
acknowledgement. **Send message** works like a BizTalk solicit-response MLLP send port: it connects, sends, waits for
the ACK on the same connection, checks that MSA-2 matches the MSH-10 it sent, and keeps the connection open for the
next message.

```
caller ──POST HL7──▶ send-order                                     lab :2303 (backends/app.py)
       ◀──200/422/504──  Send message ──────────MLLP──────────────▶ AA, or AE for an unknown test
                         isPositive? 200 : 422                        (or nothing, while switched silent)
                         no ACK in 5 s? 504
```

| Action input | Value | Why |
|---|---|---|
| `waitForAck` | `true` | wait for the ACK and return it |
| `ackTimeoutSeconds` | `5` | short, so the demo doesn't wait long (30 by default) |
| `keepConnectionOpen` | `true` | one pooled connection to the lab, messages one after the other |
| `validateAckControlId` | `true` | an ACK whose MSA-2 isn't the sent MSH-10 fails the action |
| `failOnNegativeAck` | `false` | AE/AR is a normal result here, and the workflow answers 422. With `true`, it fails the action, so the retry policy sends again |

## Run it

See the [prerequisites](../README.md#prerequisites).

```powershell
./run.ps1      # Azurite, the stand-in lab on MLLP 2303 (control on 8303), the Logic App on 7303
./demo.ps1     # in a second window: the 4 steps below, checked
```

Or step by step:

```powershell
./send.ps1 messages/orm-o01-glucose.hl7
./send.ps1 messages/orm-o01-unknown-test.hl7
Invoke-RestMethod -Method Post http://127.0.0.1:8303/control/silent      # the lab stops answering
./send.ps1 messages/orm-o01-cbc.hl7
Invoke-RestMethod -Method Post http://127.0.0.1:8303/control/normal
```

1. **An order the lab accepts.** HTTP 200 with the send result:
   ```json
   { "messageControlId": "MG-ORM-0001", "ackReceived": true, "ackCode": "AA", "isPositive": true,
     "acknowledgedControlId": "MG-ORM-0001", "ackText": "Order accepted", "connectionReused": false,
     "acknowledgement": "MSH|^~\\&|LIS|CEDAR_LAB|LOGICAPP|MAPLE_GROVE|…|ACK^O01^ACK|…\rMSA|AA|MG-ORM-0001|Order accepted\r", … }
   ```
2. **A test the lab doesn't do (`XYZ`).** HTTP 422, `ackCode` AE, `ackText` "Unknown test code XYZ", and the lab's
   ERR segment in `ackErrors`. It went over the same connection: `connectionReused` is true.
3. **The lab reads the order and never answers.** After 5 seconds the action fails with "No acknowledgement was
   received within 5 seconds", and the caller gets HTTP 504. The lab did get the order.
4. **The lab answers again.** HTTP 200 on a new connection: after a timeout the connector closes the connection, so a
   late ACK can't be taken for the next message's.

## Design notes

- **Retries and duplicates.** A message that timed out may have arrived (step 3). This workflow doesn't retry
  (`retryPolicy: none`) and tells the caller. With retries, the lab must recognize a message it already has, by its
  MSH-10.
- **One connection per destination, one message at a time.** With `keepConnectionOpen`, messages to the same host
  and port share one connection and wait for each other's ACK, as MLLP requires.
- **Use your own receiver.** `./run.ps1 -NoStandIns` starts the Logic App without the stand-in lab, so another MLLP
  receiver can listen on port 2303.
