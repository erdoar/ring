# ring

Causal vocal isolation for a digital-console insert.

Download the disk image: [SI-01.dmg](https://github.com/erdoar/ring/releases/download/v0.3.1/SI-01.dmg) ([release](https://github.com/erdoar/ring/releases/tag/v0.3.1)). Open it and drag SI-01 onto Applications. If macOS says it cannot be opened, Control-click the app and choose Open. The first launch compiles the insert and needs the Xcode command line tools.

[SI-01](docs/SI-01.md) is the coding spec. The product is a macOS app that owns the USB device. The kernel in the note is what each channel runs. Code to that document.

The app package is [SI01](SI01/). `swift test` runs the session and the kernel. `swift run SI01 --self-test` prints the kernel checks. On a Mac, `scripts/bundle-macos.sh` builds `SI-01.app`. The Core Audio host is in that package and is not compiled here.

It is not a manual for any commercial plug-in. Field numbers are cited from public tests and are labelled measured, reported, or estimated.
