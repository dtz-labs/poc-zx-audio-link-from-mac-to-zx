# Half-Duplex Terminal Protocol (v1) — Design

Date: 2026-07-26
Status: approved design, implementation pending physical-layer validation

## Purpose

Define a reliable, bidirectional byte pipe between a Mac and a Timex TC2048
acting as a VT-100 terminal, over the existing half-duplex audio link. The
protocol emulates an RS-232 cable: bytes flowing down are host (pty) output,
bytes flowing up are keyboard input. The protocol does not interpret either
stream — all VT-100 semantics live in the existing terminal emulator code.

## Scope and non-goals

In scope:

- Frame format, integrity checking, duplicate suppression.
- Session establishment (HELLO/WELCOME), version and capability negotiation.
- Retransmission (ARQ), flow control, keep-alive.
- Disconnect detection and automatic reconnection.

Out of scope (owned elsewhere):

- Physical layer: pulse encoding, preamble, bit rate, the ZX→Mac audio path
  and its Mac-side decoder. Currently being validated separately.
- VT-100 emulation, screen rendering, keyboard mapping (existing code).
- Keystroke echo: the terminal implements local echo; the protocol carries
  bytes only.
- File transfer, compression, encryption, sliding windows. Note: because the
  protocol presents a transparent serial pipe, classic serial protocols
  (e.g. XMODEM) could later run over it unchanged.

## Assumptions about the physical layer

The protocol requires only these primitives from the layer below:

1. Send a block of N bytes (half-duplex; the line is yours while sending).
2. Receive a block with a timeout (returns bytes, or nothing on timeout).
3. Bit errors are possible; block boundaries are delivered by the physical
   framing (preamble + sync), so no start-of-frame byte is needed here.

Any pulse scheme that provides these three properties works without protocol
changes.

## Roles

- **Mac = master.** Initiates the session and every exchange. Runs the pty
  (shell) whose output feeds downstream frames.
- **Timex = slave.** Speaks only in response to a valid master frame. Renders
  downstream bytes via the VT-100 emulator; queues keyboard bytes upstream.

Collisions are structurally impossible: the slave transmits only inside the
response slot that follows a master frame.

## Frame format

```
+------+------+-----------+--------+
| CTRL | LEN  | PAYLOAD   | CRC-16 |
| 1 B  | 1 B  | 0..64 B   | 2 B    |
+------+------+-----------+--------+
```

- **CTRL** — see bit layout below.
- **LEN** — payload length in bytes, 0..64. Values above the negotiated
  maximum invalidate the frame.
- **PAYLOAD** — opaque bytes (stream data, or negotiation fields in
  HELLO/WELCOME).
- **CRC-16** — CRC-16/CCITT-FALSE (poly 0x1021, init 0xFFFF, no reflection,
  xorout 0x0000) over CTRL, LEN and PAYLOAD. Transmitted high byte first.
  A frame with a bad CRC is treated as if it never arrived.

### CTRL bit layout

```
bit 7 6 5   4 3 2   1     0
   [TYPE ] [rsvd] [SEQ] [ACK]
```

| TYPE | Name    | Direction   | Meaning                                    |
|------|---------|-------------|--------------------------------------------|
| 0    | HELLO   | Mac→Timex   | Session request + negotiation offer        |
| 1    | WELCOME | Timex→Mac   | Session accept + negotiation answer        |
| 2    | LINK    | both        | Normal traffic; LEN=0 is a poll/keep-alive |
| 3    | BYE     | both        | Courtesy close; no reply required          |
| 4–7  | —       | —           | Reserved; receiver ignores the frame       |

Reserved CTRL bits (4–2) are sent as 0 and ignored on receive.

- **SEQ** — alternating sequence bit of this frame's payload. Advances only
  on frames with LEN>0; empty frames repeat the sender's current SEQ.
- **ACK** — the SEQ value of the last payload frame correctly accepted from
  the peer.
- HELLO and WELCOME send SEQ=0, ACK=0 (both sides reset sequence state on
  session establishment: first payload in each direction uses SEQ=0, and
  "last accepted" starts as 1 so that SEQ=0 counts as new).

### HELLO / WELCOME payload (3 bytes)

| Offset | Field       | v1 value | Rule                                      |
|--------|-------------|----------|-------------------------------------------|
| 0      | version     | 1        | Effective version = min(offered, answered)|
| 1      | capability flags | 0x00 | Effective caps = AND of both sides       |
| 2      | max payload | 64       | Sender must not exceed peer's advertised value |

If the effective version is unsupported by the master, it reports an error
and stays down (no retry storm: retry interval T_HELLO_RETRY still applies).

## Exchange model

```
Mac (master)                          Timex (VT-100)
  |--- HELLO [ver, caps, max] --------->|
  |<-- WELCOME [ver, caps, max] --------|   1 round trip; session is LINKED
  |--- LINK seq=0 [pty output] -------->|   Timex renders, then replies
  |<-- LINK seq=0 ack=0 [key bytes] ----|
  |--- LINK seq=1 ack=0 [more output]-->|
  |<-- LINK seq=1 ack=1 [empty] --------|
  ... idle: empty LINK every T_POLL_IDLE = keep-alive
  ... busy: next transaction immediately (T_POLL_ACTIVE)
```

Properties that follow from the model:

- **Implicit flow control.** The master sends the next chunk only after a
  response; the slave responds only after consuming the previous payload
  (e.g. after scrolling). A slow terminal automatically slows the host.
- **Stop-and-wait is sufficient.** With ~170 B/s of raw throughput and 64-byte
  frames, a window of 1 saturates the link; no sliding window.
- **Piggybacking.** Keyboard bytes ride in the response to any poll; there is
  no separate upstream mechanism.

## ARQ rules

Master transaction:

1. Send a frame; wait up to T_RESP for a response.
2. Valid response (CRC ok): if its ACK equals the master's current SEQ, the
   downstream payload is delivered — toggle SEQ before the next new payload.
   If the response carries a new payload (LEN>0, SEQ differs from the last
   accepted upstream SEQ), accept it and update the ACK the master will send.
3. Timeout or invalid response: resend the identical frame (same SEQ, same
   ACK, same payload), up to RETRIES attempts, then declare the link down.

Slave rules:

1. Respond to every valid master frame, always echoing ACK = last accepted
   downstream SEQ.
2. Accept a master payload only when LEN>0 and SEQ differs from the last
   accepted downstream SEQ (duplicates are answered but not re-delivered).
3. Keep the current upstream payload (and its SEQ) until a master frame
   arrives with ACK equal to that SEQ; until then repeat the same payload in
   every response. After acknowledgement, toggle SEQ and the next response
   may carry the next chunk from the keyboard buffer.
4. A HELLO received in any state resets the session: reply WELCOME, clear
   sequence state and pending buffers.

Together these give exactly-once, in-order delivery in both directions.

## Session state machines

Master:

```
DOWN --HELLO sent, WELCOME received--> LINKED
LINKED --RETRIES consecutive failed transactions--> DOWN (auto: retry HELLO every T_HELLO_RETRY)
LINKED --user quits / pty closes--> send BYE, DOWN
LINKED --BYE received as response--> DOWN
DOWN: HELLO retries continue indefinitely (auto-reconnect)
```

Slave:

```
LISTEN --valid HELLO--> reply WELCOME, LINKED
LINKED --no valid frame for T_DEAD--> show "NO CARRIER", LISTEN
LINKED --BYE received--> show "NO CARRIER", LISTEN
any state --valid HELLO--> reply WELCOME, LINKED (session reset)
```

There are no half-open sessions: HELLO always wins, so a restart of either
side converges to a fresh session within one HELLO retry interval.

## Error scenarios

| Scenario | Recovery |
|----------|----------|
| Frame corrupted on the way down | Slave silent → master retransmits same SEQ |
| Response corrupted or lost | Master retransmits; slave sees duplicate, re-answers; upstream payload repeats until ACKed |
| Timex reboots mid-session | Stops answering → master goes DOWN → HELLO retry → rebooted terminal answers WELCOME |
| Mac restarts mid-session | Sends HELLO → slave resets and answers WELCOME |
| Line dead (audio routing broken) | Master: DOWN after RETRIES; slave: NO CARRIER after T_DEAD; both keep listening/retrying |

Stale in-flight data after a session reset is dropped by design; the shell
prompt or a redraw restores terminal state.

## Timing constants (v1, all tunable)

| Constant | Side | Value | Meaning |
|----------|------|-------|---------|
| T_RESP | Mac | 1.0 s | Wait for a response before retransmitting |
| RETRIES | Mac | 3 | Failed transactions before declaring DOWN |
| T_POLL_ACTIVE | Mac | 0 ms | Next transaction delay when either direction carried payload |
| T_POLL_IDLE | Mac | 1.0 s | Poll interval when idle (doubles as keep-alive) |
| T_HELLO_RETRY | Mac | 2.0 s | HELLO retry interval while DOWN |
| T_DEAD | Timex | 5.0 s | Silence before declaring NO CARRIER |

Values assume the current tape-rate physical layer (~0.4 s air time for a
full 64-byte frame). If the physical layer speeds up, only this table needs
revisiting.

## Testing strategy

- **Protocol engine (Python):** pure state machine, no audio dependency.
  Unit tests drive it over a simulated channel that drops, corrupts and
  duplicates frames; assert exactly-once in-order delivery both ways,
  reconnection after silence, and HELLO-resets-everything.
- **Frame codec:** round-trip and CRC tests, including truncated and
  bit-flipped frames.
- **Z80 slave:** the same state machine is small enough to test in ZEsarUX
  against the real Python master once the physical layer is validated;
  screenshot/memory checks via the emulator's MCP interface.

## Open items

- Physical-layer parameters (preamble length, pulse widths, response-slot
  turnaround time) — pending the ZX→Mac validation work; T_RESP may need
  adjustment once real turnaround times are measured.
