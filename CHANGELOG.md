# Changelog

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
