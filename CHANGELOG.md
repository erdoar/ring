# Changelog

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

### Measured on the generated set

- Dry vowel: null below −200 dB against bypass.
- Rising 1 kHz tone: likelihood 0, resonator gain about 0.2, late level about 0.16 of dry.
- Vibrato: resonator gains stay at 1.
- Eight 32-sample instances take a few milliseconds in the JavaScript runtime. The 0.67 ms figure is the native budget and is not claimed here.

### Not in this build

- VST3 or AU.
- A network, a teacher, or a stored room.
- Bleed reduction.
- LOW using its lookahead for anything but the declared delay.
