# Results

## 2026-10-15: SI-01 (main at c8472c8) and De-Feedback 1.1.4

Offline, 256-frame blocks, default settings. De-Feedback was a trial copy. A trial instance is silent for its first 5 s and for 5 s in every 30 s, so each file was rendered on a fresh instance after 6 s of discarded silence (`--preroll 6`). Takes with a dropout were rejected and rendered again. Every take scored here passed the dropout check.

```sh
ring-bench render si01 runs/stimuli runs/si01
ring-bench render au De-Feedback --preroll 6 runs/stimuli runs/defeedback
ring-bench analyse runs/stimuli runs/si01 runs/defeedback
```

### What it shows

- **De-Feedback turns everything down, not just the howl.** On every howl file the loss on other content matches the howl cut (about 29 dB on the 2.5 kHz howl, for example). It reacts within one analysis frame. Its own registration calls it a "broadband loop gain limiter".
- **De-Feedback also turns down signals with no feedback**, by 7–9 dB on average at default settings.
- **SI-01 leaves voices alone but barely cuts howls.** It cuts 3.7 dB at 2.5 kHz and 13.7 dB at 315 Hz, takes 0.9–2.7 s to reach a 6 dB cut, and misses a howl on a sung note's harmonic entirely.
- The target for SI-01 is De-Feedback's reaction time and depth, without its broadband loss.

### Table

| Stimulus | Measure | si01 | defeedback |
|---|---|---|---|
| sweep | Latency (ms) | 0.00 | 0.00 |
| sweep | Match to input | 0.993 | 0.863 |
| sweep | Level (dB) | -1.9 | -6.7 |
| howl-2k5 | Time to 6 dB cut (s) | 0.88 | 0.00 |
| howl-2k5 | Howl cut at end (dB) | 3.7 | 29.1 |
| howl-2k5 | Howl peak out vs in (dB) | -3.7 | -29.2 |
| howl-2k5 | Other content lost, mean (dB) | 0.2 | 28.6 |
| howl-2k5 | Other content lost, 95th pct (dB) | 1.3 | 30.0 |
| howl-2k5 | Band-frames cut > 3 dB (%) | 0.8 | 100.0 |
| howl-315 | Time to 6 dB cut (s) | 2.68 | 0.00 |
| howl-315 | Howl cut at end (dB) | 13.7 | 30.4 |
| howl-315 | Howl peak out vs in (dB) | -10.6 | -27.7 |
| howl-315 | Other content lost, mean (dB) | 0.1 | 29.5 |
| howl-315 | Other content lost, 95th pct (dB) | 1.4 | 30.0 |
| howl-315 | Band-frames cut > 3 dB (%) | 0.6 | 100.0 |
| howl-under-note | Time to 6 dB cut (s) | — | 0.00 |
| howl-under-note | Howl cut at end (dB) | 0.0 | 9.1 |
| howl-under-note | Howl peak out vs in (dB) | 0.0 | -9.1 |
| howl-under-note | Other content lost, mean (dB) | 0.0 | 10.0 |
| howl-under-note | Other content lost, 95th pct (dB) | 0.0 | 13.9 |
| howl-under-note | Band-frames cut > 3 dB (%) | 0.0 | 100.0 |
| vibrato-note | Other content lost, mean (dB) | 0.0 | 7.5 |
| vibrato-note | Other content lost, 95th pct (dB) | 0.0 | 9.8 |
| vibrato-note | Band-frames cut > 3 dB (%) | 0.0 | 95.8 |
| straight-note | Other content lost, mean (dB) | 0.0 | 8.8 |
| straight-note | Other content lost, 95th pct (dB) | 0.0 | 12.4 |
| straight-note | Band-frames cut > 3 dB (%) | 0.0 | 100.0 |
| fricatives | Other content lost, mean (dB) | -0.5 | 7.7 |
| fricatives | Other content lost, 95th pct (dB) | 0.6 | 10.2 |
| fricatives | Band-frames cut > 3 dB (%) | 0.3 | 100.0 |
| fry | Other content lost, mean (dB) | -0.1 | 7.1 |
| fry | Other content lost, 95th pct (dB) | 1.5 | 11.1 |
| fry | Band-frames cut > 3 dB (%) | 0.5 | 100.0 |
