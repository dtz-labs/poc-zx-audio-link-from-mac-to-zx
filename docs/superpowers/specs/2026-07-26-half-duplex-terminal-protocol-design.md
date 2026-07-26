# Half-Duplex Terminal Protocol (v1) — Design

Date: 2026-07-26
Status: approved design, revised after adversarial review; implementation
pending physical-layer validation

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

Collisions are impossible provided the master never transmits into the
slave's response slot — the T_RESP formula in the timing section exists to
guarantee exactly that, so T_RESP must cover the slave's worst-case
consume-and-respond time.

## Frame format

```
+------+------+-----------+--------+
| CTRL | LEN  | PAYLOAD   | CRC-16 |
| 1 B  | 1 B  | 0..64 B   | 2 B    |
+------+------+-----------+--------+
```

- **CTRL** — see bit layout below.
- **LEN** — payload length in bytes, 0..64.
- **PAYLOAD** — opaque bytes (stream data, or negotiation fields in
  HELLO/WELCOME).
- **CRC-16** — CRC-16/CCITT-FALSE (poly 0x1021, init 0xFFFF, no reflection,
  xorout 0x0000) over CTRL, LEN and PAYLOAD. Transmitted high byte first.

**Frame validation.** A received block is a valid frame only if all of these
hold; anything else is treated as if the frame never arrived:

1. Physical block length equals LEN + 4.
2. CRC matches.
3. LEN ≤ 64 (absolute cap, applies before and after negotiation). For LINK
   frames, LEN must also not exceed the receiver's advertised max payload.
4. For HELLO and WELCOME, LEN ≥ 3; bytes beyond offset 2 are reserved for
   future versions and are ignored.

### CTRL bit layout

```
bit 7 6 5   4 3 2   1     0
   [TYPE ] [rsvd] [SEQ] [ACK]
```

| TYPE | Name    | Direction | Meaning                                    |
|------|---------|-----------|--------------------------------------------|
| 0    | HELLO   | Mac→Timex | Session request + negotiation offer        |
| 1    | WELCOME | Timex→Mac | Session accept + negotiation answer        |
| 2    | LINK    | both      | Normal traffic; LEN=0 is a poll/keep-alive |
| 3    | BYE     | Mac→Timex | Courtesy close; no reply required          |
| 4–7  | —       | —         | Reserved; receiver ignores the frame       |

Reserved CTRL bits (4–2) are sent as 0 and ignored on receive. BYE is
master-only in v1; a future version may define a slave quit gesture (e.g. a
key combo turning the next response into a BYE).

### SEQ and ACK

- **Sequence accounting and stream delivery apply to LINK frames only.**
  HELLO, WELCOME and BYE never touch sequence state, and their payloads are
  consumed by negotiation logic — they must never enter the byte streams.
- **SEQ** — the sender's current sequence bit. It advances (toggles) exactly
  when the sender's outstanding payload is acknowledged; the next new payload
  is sent with the advanced value. Frames with LEN=0 carry the sender's
  current SEQ, and **receivers ignore the SEQ bit of LEN=0 frames**.
- **ACK** — the SEQ value of the last LINK payload accepted from the peer.
- HELLO and WELCOME are sent with SEQ=0, ACK=0. On session establishment
  both sides reset: the first payload in each direction uses SEQ=0, and
  "last accepted" starts as 1 so that SEQ=0 counts as new.

### HELLO / WELCOME payload (3 bytes)

| Offset | Field            | v1 value | Rule                                        |
|--------|------------------|----------|---------------------------------------------|
| 0      | version          | 1        | Effective version = min(offered, answered)  |
| 1      | capability flags | 0x00     | Effective caps = AND of both sides          |
| 2      | max payload      | 64       | Sender must not exceed peer's advertised value |

Validation: the master treats a WELCOME advertising version 0 or a max
payload outside 1..64 as an invalid response. The slave answers any
parseable HELLO with its own version; if the effective version is
unsupported by the master, it reports an error to the user and stays DOWN
(HELLO retries continue at T_HELLO_RETRY — no retry storm).

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

1. Send a frame; wait up to T_RESP — measured from the end of the master's
   own transmission — for a response.
2. **Any valid response (per Frame validation) completes the transaction**
   and resets the retry counter. A transaction fails only on timeout or on
   an invalid block. The ACK bit is never a failure condition.
3. Downstream delivery: if a downstream payload is outstanding and the
   response's ACK equals its SEQ, it is delivered — advance SEQ. Otherwise
   the payload stays outstanding and is retransmitted as the next
   transaction's frame.
4. Upstream acceptance: if the response is a LINK with LEN>0 and SEQ
   different from the last accepted upstream SEQ, accept the payload and
   update the ACK the master sends from now on.
5. On failure: resend the identical frame (same CTRL, same payload). A
   transaction is attempted at most RETRIES times **in total** (the original
   transmission counts as the first attempt); exhausting them declares the
   link DOWN.
6. Pty backpressure: while not LINKED, the master stops draining the pty
   (the shell blocks on write). On reconnect it resumes with live output
   only. Unacknowledged in-flight payloads are dropped on any session reset
   and must never be resent into a new session.

Slave rules:

1. While LINKED, respond to every valid master frame, always echoing
   ACK = last accepted downstream SEQ. While in LISTEN, silently ignore
   everything except HELLO.
2. Accept a downstream payload only from a LINK frame with LEN>0 and SEQ
   different from the last accepted downstream SEQ. Duplicates are answered
   but not re-delivered.
3. Keep the current upstream payload (and its SEQ) until a master frame
   arrives with ACK equal to that SEQ; until then repeat the same payload in
   every response. After acknowledgement, advance SEQ; the next response may
   carry the next chunk from the keyboard buffer.
4. A valid HELLO received in any state resets the session: reply WELCOME,
   clear sequence state and pending buffers.
5. Keyboard buffer: fixed size, v1 = 128 bytes. On overflow, drop the
   **newest** bytes and signal the user (BEL / visual bell). Never
   drop-oldest — that would corrupt the command being typed rather than
   truncate it.
6. The slave consumes a payload before replying, so its response latency is
   bounded by its worst-case rendering time; T_RESP is derived from that
   bound (see timing).

Together these give exactly-once, in-order delivery in both directions
**within a single session**. Every session reset (retry exhaustion, T_DEAD,
reboot, HELLO) drops in-flight data in both directions by design; the shell
prompt or a redraw restores terminal state.

## Session state machines

Master:

```
DOWN   --HELLO sent, valid WELCOME received--> LINKED
LINKED --RETRIES exhausted--> DOWN   (auto: retry HELLO every T_HELLO_RETRY, indefinitely)
LINKED --user quits / pty closes--> send BYE (best effort), CLOSED
DOWN   --user quits--> CLOSED
CLOSED: terminal state — no frames are sent; restarting the program reconnects
```

Slave:

```
LISTEN --valid HELLO--> reply WELCOME, LINKED
LISTEN --any other frame--> ignore silently
LINKED --no valid frame for T_DEAD--> show "NO CARRIER", LISTEN
LINKED --BYE received--> show "NO CARRIER", LISTEN
any state --valid HELLO--> reply WELCOME, LINKED (session reset)
```

Intentional close (CLOSED) is distinct from link failure (DOWN): only DOWN
auto-reconnects. There are no half-open sessions: HELLO always wins, so a
restart of either side converges to a fresh session within one HELLO retry
interval.

## Error scenarios

| Scenario | Recovery |
|----------|----------|
| Frame corrupted on the way down | Slave silent → master retransmits same SEQ |
| Response corrupted or lost | Master retransmits; slave sees duplicate, re-answers; upstream payload repeats until ACKed |
| Timex reboots mid-session | Stops answering → master goes DOWN → HELLO retry → rebooted terminal answers WELCOME |
| Mac restarts mid-session | Sends HELLO → slave resets and answers WELCOME |
| Line dead (audio routing broken) | Master: DOWN after RETRIES; slave: NO CARRIER after T_DEAD; both keep listening/retrying |
| Idle link | Empty polls complete transactions regardless of ACK bits — no flapping |

## Timing constants (v1)

The table is normative as formulas; concrete values must be derived from air
times measured on the actual physical layer. Symbols: `t_dn` / `t_up` = air
time of a maximum-size frame (preamble included) down / up, `t_turn` = slave
turnaround, `t_render` = worst-case slave consume time (e.g. a 64-byte
payload of newlines forcing 64 full-screen scrolls — on the order of
seconds on a 3.5 MHz Z80).

| Constant | Side | Formula | Example* |
|----------|------|---------|----------|
| T_RESP | Mac | t_turn + t_render + t_up + margin | ~3.5 s |
| RETRIES | Mac | total attempts per transaction | 3 |
| T_POLL_ACTIVE | Mac | 0 (immediate when either direction carried payload) | 0 ms |
| T_POLL_IDLE | Mac | poll interval when idle (doubles as keep-alive) | 1.0 s |
| T_HELLO_RETRY | Mac | HELLO retry interval while DOWN | 2.0 s |
| T_DEAD | Timex | > RETRIES × (t_dn + T_RESP) | ~15 s |

\* Example values assume the planned short-preamble physical layer
(~15 ms preamble, ~0.42 s per full 64-byte frame). **They are infeasible
with the current ROM-pilot encoding** (~2 s pilot + guard silences ≈ 2.8 s
per frame even for an empty poll) — with that layer every constant must be
recomputed from the formulas, or the preamble shortened first.

T_RESP is dominated by t_render, so retransmission after a genuinely lost
frame is slow; that is acceptable in v1 (losses are rare in the emulator)
and can later be improved without protocol changes by bounding t_render
(e.g. slower scroll regions) rather than by changing the ARQ.

## Testing strategy

- **Protocol engine (Python):** pure state machine, no audio dependency.
  Unit tests drive it over a simulated channel that drops, corrupts and
  duplicates frames; assert exactly-once in-order delivery both ways,
  reconnection after silence, and HELLO-resets-everything. Regression cases
  from review: an idle link polled forever must never flap; WELCOME payload
  must never reach the pty; a keyboard chunk pending during a retransmit
  storm must survive un-duplicated; keyboard overflow drops newest + BEL.
- **Frame codec:** round-trip and CRC tests, including truncated blocks,
  bit flips, LEN/block-length mismatches, and HELLO frames with LEN>3
  (extra bytes ignored).
- **Z80 slave:** the same state machine is small enough to test in ZEsarUX
  against the real Python master once the physical layer is validated;
  screenshot/memory checks via the emulator's MCP interface.

## Open items

- Physical-layer parameters (preamble length, pulse widths, turnaround
  time) — pending the ZX→Mac validation work. Once measured, instantiate
  the timing table from its formulas.
