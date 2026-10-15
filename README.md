# ring

Causal vocal isolation for a digital-console insert. The shipping app is Ring FBD.

Download the disk image: [Ring-FBD-0.5.2.dmg](https://github.com/erdoar/ring/releases/download/v0.5.2/Ring-FBD-0.5.2.dmg) ([release](https://github.com/erdoar/ring/releases/tag/v0.5.2)). The app inside is named Ring FBD 0.5.2. Drag that into Applications and open it. A window opens after the first compile. The first time, use System Settings, Privacy and Security, Open Anyway. The first launch needs the Xcode command line tools.

[Ring FBD](docs/SI-01.md) is the coding spec. The product is a macOS app that owns the USB device. The kernel in the note is what each channel runs. Code to that document.

The app package is [SI01](SI01/). `swift test` runs the session and the kernel. `swift run SI01 --self-test` prints the kernel checks. On a Mac, `scripts/bundle-macos.sh` builds the app. The Core Audio host is in that package and compiles on macOS only.

**Branch status:** this source snapshot is still a prototype, not a validated live vocal insert. See [the refactor audit](docs/REFACTOR_AUDIT.md) for the fixes in this pass and the remaining macOS/audio-thread blockers.

It is not a manual for any commercial plug-in. Field numbers are cited from public tests and are labelled measured, reported, or estimated.
