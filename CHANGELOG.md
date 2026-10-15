# Changelog

## 0.6.5 — 2026-10-15 — entry

The entry file is no longer named `main.swift`. Swift treats that name as a script, which cannot also carry `@main`.

## 0.6.4 — 2026-10-15 — deployment

The package now requires macOS 13, so the accent color and the system fonts compile.

## 0.6.3 — 2026-10-15 — build

`pow` and `log10` are imported, so the trim and the input meter compile.

## 0.6.2 — 2026-10-15 — window

The app is named Ring. It opens a window again, the same shape as the earlier one: channel count, ZERO or LOW, a mix knob, a level, a trim knob on the right (±8 dB), mute, voice, and cut. Mix at the bottom is bypass, and that drops the trim too. The monitor address is shown once and can be selected. The window can shrink to 300 points. New files for this build carry the name and the version.

## 0.6.1 — 2026-10-15 — howl notch

The 0.6.0 bench showed SI-01 cutting a 2.5 kHz howl by 3.7 dB and missing a howl on a sung harmonic. A 6 dB/s rise never reaches the old 1.3× test inside the tenth-second memory, and any voice likelihood cancelled the notch.

### Changed

- A partial is a howl when its frequency stays put and its level is still rising, measured in dB/s on both the whole memory and the recent quarter. A finished note fade does not qualify, because its recent slope is flat.
- Once that rise is seen, the notch stays while the frequency stays put, including after the howl stops growing. It releases if the partial wanders.
- The notch target is 0.05 rather than 0.2. Voice likelihood no longer vetoes a stationary rising partial, so a howl on a harmonic of a moving note can be cut. A partial whose frequency is moving is not cut.
- Not re-measured. `ring-bench render si01` then `analyse` is the check. The numbers in `bench/RESULTS.md` are still the 0.6.0 run.


## 0.6.0 — 2026-10-15 — benchmark

### Added

- `bench/` holds `ring-bench`, a black-box benchmark. It generates howl and voice test signals, renders them through SI-01's engine offline, through any Audio Unit plug-in offline, or through live hardware, and reports latency, time to cut, howl depth and collateral loss. `ring-bench selftest` checks the measures against a known delay and a known notch.

### First results (main at c8472c8, offline, 256-frame blocks)

- SI-01 cuts the 2.5 kHz howl by only 3.7 dB and the 315 Hz howl by 13.7 dB (6 dB reached after 2.7 s). It misses a howl on a sung note's harmonic entirely.
- SI-01 leaves voice content intact: 95th-percentile loss is 1.5 dB or less on every voice file.

## Unreleased — safety refactor tranche

### Changed

- Replaced the tail kernel's ineffective sequence-counter loop with an atomic three-slot publication store. A render pins one immutable kernel snapshot for the entire host block.
- Added an atomic single-job handoff between callback and fit worker; the callback does not overwrite a job owned by the worker.
- Worker shutdown now waits on the control thread before draining pending work.
- Disabled the hand-written bleed-band heuristic. Phase 1 passes all bands unchanged until a causal student is trained and validated.
- Applied a protected horizon of `max(128, hostBlockFrames)` to the tail FIR and fitting path.
- Fixed the Core Audio IO proc so the macOS host compiles: the input and output buffer lists are non-optional, so only the context is checked.
- Added kernel-store/job-state tests and a source-level risk audit at [`docs/REFACTOR_AUDIT.md`](docs/REFACTOR_AUDIT.md).

### Verification

- `cd SI01 && swift test -c release` — 9 tests pass on Linux / Swift 6.2.1 and on macOS 15 (Apple Silicon) / Swift 6.2.4.
- `scripts/bundle-macos.sh` builds and ad-hoc signs `SI-01.app` on macOS.
- This does not verify Core Audio routing at runtime, the macOS UI, Apple Silicon callback deadlines, or real-room feedback performance. See the audit for blockers.

## 0.5.2 — 2026-10-15

Ring FBD. The disk image is `Ring-FBD-0.5.2.dmg`. The app inside is named Ring FBD 0.5.2.

### Changed

- The window shrinks to 300 points wide.
- The external monitor address is shown once, and the window text can be selected.
- Trim is a knob on the right of each channel, ±8 dB. Mix at the bottom is bypass: the effect and the trim are both out. Mute is separate.
- While a voice is present, bands at the learned room floor are lowered about 8 dB. Voice bands stay up.
- The analysis transform is not on the callback. A buffer-size change does not reset the filters. The output sample is not allowed to exceed the dry sample.


## 0.2.0-alpha — 2026-10-14

VST3 processor, bleed gains, and the LOW lookahead.

### Added

- `Vst3Processor`. Parameters: bypass, mode, strength, dereverb, freeze. Reports 0 samples in ZERO and 127 in LOW.
- Sixteen bleed bands. A harmonic series, or a partial that moves like vibrato, keeps its band at 1. A loud unclaimed band may go to 0, still inside the broadband cap.
- LOW uses the 127 reported samples as lookahead for those gains. ZERO applies them one partition late.

### Measured on the generated set

- Dry vowel, both modes: null below −200 dB.
- Noise wash through the processor at full strength: about 0.77 of dry.
- A 60-sample hit inside one partition: ZERO leaves it. LOW, shifted by the 127-sample report, reduces it.

### Not in this build

- A compiled `.vst3` bundle. The processor is the class a wrapper calls.
- AU, a network, or a stored room.

## 0.1.0-alpha — 2026-10-14

Phase 1 of [SI-01](docs/SI-01.md). The kernel runs in the note, not as a plugin wrapper yet.

### Added

- Causal tail. 512 taps. Inputs to the fit are older than 128 samples. Coefficients publish through a sequence counter. On overrun the previous tail is kept.
- Eight resonators. A partial is turned down only when it is steady, rising, and not a harmonic stack. Once it is down, it stays until it wanders or a voice claims it.
- Harmonic voice gate. Likelihood freezes the tail step. The sample that leaves is still the microphone.
- Broadband cap. 12 dB scaled by strength. Default strength 0.5.
- Host blocks from 16 to 2048. Internal partition fixed at 128. One crossfade per block-size change.
- ZERO reports 0 samples. LOW reports 127 and delays the output. Bleed gains are 1.
- Merge checks: dead room, voiced freeze, note on a howl, growing tone, cap, block change, overrun, delay report, bypass ramp, eight instances, horizon.
