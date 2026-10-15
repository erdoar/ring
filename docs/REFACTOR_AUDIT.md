# Refactor audit — `gpt` branch

Date: 2026-10-15

## Status

This is a first safety-focused refactor tranche, not a release-ready DSP engine. It removes two real cross-thread hazards, disables the unsafe heuristic bleed gate, and adds regression tests. The remaining issues below must be resolved and tested on macOS hardware before this can be treated as a reliable live vocal insert.

## Changes in this tranche

- Replaced the tail's ineffective sequence-counter loop with a C11-atomic, three-slot publication store. The audio callback pins one immutable kernel slot for the duration of a render call; the worker publishes only to a slot that is neither active nor pinned.
- Added an atomic single-job state machine. The callback claims and fills a job slot, publishes it with release semantics, and never overwrites a job while the worker owns it.
- Made worker shutdown wait for the worker to exit before draining a pending job. The join/wait happens on the control thread, not the audio callback.
- Disabled the hand-written 16-band bleed heuristic for Phase 1. It could attenuate unvoiced consonants and transient content based on a coarse spectral claim, while the spec says Phase 1 bleed gains are unity until a trained causal student is available.
- Applied the declared host-block protection horizon to the tail FIR and fitting path. The job buffer is sized for the maximum supported block.
- Added tests for kernel-slot stability, job ownership, and unity bleed gains.

## Findings still open

### P0 — real-time deadline is not demonstrated

`Engine.render` still performs gate analysis and howl tracking in the callback. `Analyzer` runs a pure-Swift 1024-point FFT, performs trigonometric work, scans peaks, and refines frequencies. The callback also runs an up-to-512-tap FIR per sample. A release-mode synthetic test is not a substitute for timing the actual callback on the target M1 with eight engines. The spec's `vDSP` fast path is not implemented yet.

**Next:** move nonessential analysis to a worker using bounded, preallocated feature snapshots; keep only the minimum detector state update and subtraction in the callback. Add worst-case callback timing and deadline-miss tests on macOS.

### P0 — audio-device routing is incomplete

`CoreAudioHost.runDefault` opens the default input device and expects an output buffer from that device's IO proc. It does not provide a device picker or explicitly establish a duplex/aggregate route to the console output. Many default input devices cannot serve as a live input/output insert. The current `App` is a core/session object; the uploaded branch does not contain the full window and controls described by the spec.

**Next:** implement explicit input/output device selection and verify the exact supported duplex routing on macOS. Restore or build the actual UI (mix, trim, mute, meters, monitor address, mode and safety state) before claiming app parity.

### P0 — monitor snapshot publication is not thread-safe

`Meter.note` mutates ordinary Swift fields on the audio callback while `Meter.frame` may read them on the monitoring thread. The sequence integer is not an atomic synchronization primitive in Swift. This is another data race.

**Next:** publish fixed-size meter snapshots through an atomic double/triple buffer; format JSON only on the monitoring thread.

### P1 — device sample rate validation needs macOS verification

`CoreAudioHost.open` now reads the device's nominal sample rate and rejects a device that is not at the requested 48 kHz. This check was added in this tranche. The Core Audio branch now compiles on macOS (after a fix to the IO proc's optional binding), but the check has not been exercised against a device.

**Next:** test the rate check on macOS hardware, including devices whose nominal rate is not writable or changes while the stream is stopped.

### P1 — callback output handling needs hardening

If a host callback reports more samples than the configured maximum, the host clamps the frame count and may leave the remainder of the output buffer unwritten. Error paths also need deterministic silence/bypass behavior and explicit overrun accounting. Channel-layout, interleaved/noninterleaved, and input/output frame-count mismatch tests are absent.

**Next:** validate every `AudioBufferList` shape and byte count; always initialize the full output region; fail closed to a defined bypass/silence policy and increment lock-free counters.

### P1 — delay and algorithm claims need stronger tests

The synthetic horizon check previously measured the fitting index rather than proving the FIR used the entire host-block horizon. This tranche adds a 256-sample case, but a proper test should instrument the exact indices consumed by the FIR. The 0/127 delay report is a software property, not a measured round-trip device latency.

**Next:** add tap-level horizon instrumentation, variable block tests up to 2048 samples, and a physical loopback benchmark. Report device round-trip latency separately from the engine's declared algorithmic delay.

### P1 — howl attenuation needs adversarial voice protection

The current detector is heuristic. Synthetic vibrato and a growing stationary tone are useful smoke tests, but do not establish safety on sung notes, breathy/unvoiced consonants, vocal fry, harmonics near a feedback tone, or a tambourine. A real loudspeaker-reference canceller is impossible without a reference tap; this is detection and conservative attenuation, not full feedback cancellation.

**Next:** build a labeled, licensed test corpus and evaluate false cuts and gain-before-feedback across rooms. Keep ambiguous candidates at unity.

## Verification performed

On Linux with Swift 6.2.1:

- `swift test -c release`: **9 tests passed**.
- The tests include app/session checks, synthetic kernel checks, atomic kernel-slot stability, and job-slot ownership.

On macOS 15, Apple Silicon, with Swift 6.2.4:

- `swift build -c release`: builds after the IO proc fix (the Core Audio branch had never been compiled before).
- `swift test -c release`: **9 tests passed**.
- `scripts/bundle-macos.sh`: produces an ad-hoc signed `SI-01.app`.
- Running the binary with no recognised flag starts the live engine on the default device; there is no `--help`.

Not verified anywhere yet: Core Audio runtime behaviour, UI behavior, signing/permissions, physical device routing, Apple Silicon CPU budget, or real-room gain-before-feedback. The debug kernel test is very slow because the current callback path is computationally heavy; use release builds for functional tests, and treat that slowness as a further reason to benchmark and move analysis off the callback.
