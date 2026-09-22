# RemSound Phase 1 protocol research

Research authority: [`Ednunp/RemSound`](https://github.com/Ednunp/RemSound), `main` commit `cd749143c0d1ad65870bb89c6ad98a0e311e7889`, inspected 2026-09-22. RemSound is MIT licensed (copyright 2026 Ednun). The public Android companion receiver, [`aryanchoudharypro/RemSoundAndroid`](https://github.com/aryanchoudharypro/RemSoundAndroid), commit `50c21d04b1176fa8336e28ce36d5e8f6a63f8435`, is also MIT licensed and was used only as a corroborating implementation reference. RemSound’s iOS companion is listed by upstream as a TestFlight beta; no public source repository was found. No external source code is copied into FarRelay.

## Phase 1 compatibility target

FarRelay implements only direct, authenticated **PCM 48 kHz, stereo, signed 24-bit little-endian** receive/playback from a configured RemSound Windows sender. PCM frames announced by current sender code are 120 or 240 samples per channel (2.5 or 5 ms); the Windows default non-tight PCM sender uses 240 samples (5 ms).

The target deliberately excludes discovery, relay operation, remote-control packets, sending audio, microphone capture, Opus decoding, FEC, and control of the Windows sender. The FarRelay receiver is an app-owned UDP capability; it does not use SSH, `farrelay --ipc`, controller transport, BSI, or command mode.

## Transport

- The RemSound packet header is 12 bytes and every integer is little-endian: `uint32 magic` (`0x444E4D52`, bytes `RMND`), `uint8 version` (1), `uint8 type`, `uint16 streamID` (zero is treated as 1), `uint32 sequence`.
- The canonical audio, peer-dial, and relay port is UDP **47830**. The Windows sender documents an Ethernet-safe maximum audio payload of 1454 bytes, excluding the 12-byte RemSound header and six-byte PCM subheader.
- LAN discovery is a separate optional UDP mechanism on port 47831. Phase 1 does not advertise or consume discovery packets; the Windows sender is configured with the iPhone/iPad address and port.
- Upstream’s Windows receiver binds IPv4 `IPAddress.Any`. Phase 1’s tested interoperability target is direct IPv4. Network.framework accepts the system’s supported UDP families, but IPv6 and relay routes remain physical-test follow-up work.
- Relay forwarding exists upstream, but Phase 1 uses no relay path and makes no relay compatibility claim.

## Session establishment and security

There is no TCP-style audio handshake. A selected Windows sender periodically sends plaintext `Format` announcements while it has audio frames to send; an accepted format establishes/replaces the receiver’s active `(peer, streamID)` stream. A codec/rate restart rotates `streamID`. FarRelay rejects audio from any streamID other than the most recently authenticated Phase 1 format, which prevents stale session data from reaching a replacement stream.

- Format payload base is 32 bytes: `int32` sample rate, channel count, bits/sample, encoding, block alignment, average bytes/s, codec, and frame samples/channel. Current extensions append a lane byte at offset 32, an eight-byte password fingerprint at offset 36, and optional capture latency at offset 44.
- Passwords are never sent. The key is PBKDF2-HMAC-SHA256 with UTF-8 password, salt `RemSound.v1.audio-key`, 100,000 iterations, and 32 output bytes. The fingerprint uses the same PBKDF2 parameters with salt `RemSound.v1.fingerprint` and eight output bytes.
- A fingerprint mismatch is a deterministic authentication failure. Missing fingerprints are rejected by FarRelay Phase 1 rather than allowing a legacy/insecure compatibility path.
- Audio payloads are AES-256-GCM. Their layout is `nonce(12) || tag(16) || ciphertext`; a bad tag, missing key, or malformed encrypted payload is dropped silently and counted. The Windows sender’s live nonce sequence is random 48-bit prefix plus 48-bit counter; receivers only consume the transmitted nonce.
- Format packets themselves are not encrypted, so FarRelay validates every field before acting on it and never treats a format alone as playable audio.

## PCM framing and resilience

`Audio` packets contain a per-stream packet sequence. PCM encrypted frames have a six-byte subheader before encrypted bytes: `uint32 frameID`, `uint8 partIndex`, `uint8 totalParts`. The receiver requires in-order parts, bounds an assembly to 8192 bytes, and drops a partial frame when the next frame starts or a part is malformed/out of order. This contains packet loss/reordering to audible degradation instead of unbounded buffering or process failure.

The receiver tracks forward packet gaps, duplicates, and reordering. It rejects late/duplicate packet data from the current stream, and all packets from a former stream. Its local PCM queue is capped at two seconds (96,000 stereo frames); overflow discards old queued frames rather than growing memory. UDP datagrams are limited to 2048 bytes, partial encrypted frames to 8192 bytes, receiver connections to four, and each downstream PCM delivery stream to 16 pending frames. The AVAudioPlayerNode scheduling window is independently capped at 16 frames, with surplus playback frames dropped rather than accumulating.

Upstream sends heartbeat packets with a one-byte ping/pong kind plus an eight-byte originator timestamp. Its desktop receiver uses a jitter/ring buffer and records underruns; Opus uses in-band FEC for a single missed packet. FarRelay Phase 1 safely ignores heartbeat/control/address-check traffic and does not claim Opus/FEC support. After an authenticated stream has no valid format/audio activity for five seconds, FarRelay reports a reconnectable, audio-local failure. Stalled sender or route failure never changes FarRelay control state.

## Playback and audio session

FarRelay normalizes accepted PCM into its own float PCM frame type before `AVAudioEngine` playback. RemSound wire objects do not escape to SwiftUI. Playback configures a playback-only `AVAudioSession`; it requests no recording or microphone permission and does not set ducking/screen-reader-suppression options. Interruption completion and route changes attempt an engine restart; a local engine failure stops only audio. Real interruption, Bluetooth/AirPods, wired route, speaker, and VoiceOver behavior require the physical checklist below.

## Diagnostics and non-secret policy

The receiver exposes state, peer endpoint, PCM format, packet counts, loss/reorder/drop counts, authentication failures, bounded-buffer depth/drops, underruns, reconnect count, and sanitized last error. Passwords, PBKDF2 output, GCM keys/nonces/tags, and audio plaintext are not rendered or logged.

## Required physical interoperability checklist

Use Windows G14 with the RemSound sender and an iPhone/iPad FarRelay build.

- [ ] Configure the Windows sender with the device’s current LAN address and UDP 47830, matching non-empty shared passwords.
- [ ] Select PCM 48 kHz / 24-bit, start FarRelay audio, and confirm authenticated playback.
- [ ] While audio plays, test controller navigation, arrows, Tab/Shift+Tab, F1–F12, BSI/text input, and command mode.
- [ ] Stop/restart FarRelay audio while leaving NVDA Remote control connected.
- [ ] Restart the Windows sender, then reconnect FarRelay audio; confirm only one playback pipeline remains.
- [ ] Test password mismatch, malformed/unavailable sender, network interruption, and route changes; verify controller input continues every time.
- [ ] Test speaker, wired headphones, Bluetooth/AirPods, interruption/phone call where available, foreground/background behavior, and VoiceOver with Quick Nav on and off.
- [ ] Record results before claiming relay, IPv6, Opus, FEC, or background playback support.
