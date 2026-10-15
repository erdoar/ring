# ring-bench

Black-box comparison of feedback suppressors. It plays the same test signals through each processor and measures what comes out. It never looks inside a processor: a commercial plug-in is only loaded and run as a host would, so the results are measured behaviour, not its code.

## Quick start

```sh
cd bench
swift build -c release
B=.build/release/ring-bench
$B selftest
$B generate runs/stimuli
$B render si01 runs/stimuli runs/si01
$B render au De-Feedback runs/stimuli runs/defeedback
$B analyse runs/stimuli runs/si01 runs/defeedback --out runs/report.md
```

`render au` needs the plug-in installed as an Audio Unit (for De-Feedback, run its installer). Each file gets a fresh plug-in instance. A take where the output drops out while the input has signal (a trial mute) is rejected and rendered again with a longer pre-roll. `--preroll S` renders S seconds of silence first and drops them. `$B plugins` lists the effects the system can see. The plug-in runs offline at its default settings, fed the same signal on both channels, in 256-frame blocks (`--block N` to change).

## Test signals

All are 48 kHz mono. `stimuli.json` describes each one.

| Name | What it checks |
|---|---|
| sweep | Latency and level. Every other file in a run uses its latency. |
| howl-2k5, howl-315 | A tone rising 6 dB/s from 1 s over a pink-noise room bed. It should be cut. |
| howl-under-note | A howl on the 6th harmonic of a sung note with vibrato. The howl should go and the note should stay. |
| vibrato-note, straight-note | Sung notes with no feedback. A straight note is the closest thing to a howl, so it is the hardest to leave alone. |
| fricatives, fry | 's' bursts and vocal fry. No feedback. |

## Measures

- **Time to 6 dB cut**: from the start of the howl's growth until the howl band is at least 6 dB down for 100 ms. A howl still buried in the room bed cannot register, so this includes time for it to become audible.
- **Howl cut at end**: the median cut on the howl band over the last second.
- **Howl peak out vs in**: how much lower the loudest howl is at the output. More negative is better.
- **Other content lost**: the loss on third-octave bands away from the howl, over frames with signal in them. Near 0 dB is good. The 95th percentile and the share of band-frames cut by more than 3 dB show the occasional false cut that a mean hides.

## Live hardware

`$B record runs/stimuli runs/console` plays each file on the default output and records the default input, both at 48 kHz. Use it for a console insert or an app that owns the device. Record a run with the processor bypassed first. The latency it measures includes the device round trip, so subtract the bypass latency. Pass `--calibrate` to `analyse` to remove the level change measured on the sweep.

## Results

See [RESULTS.md](RESULTS.md).

## SI-01

`render si01` runs `SI01Core.Engine` offline (add `--low` for low mode). The tail fit runs between blocks, as an ideal worker would, so this measures the algorithm, not the callback deadline.
