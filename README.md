# ring

Causal vocal isolation for a digital-console insert.

[SI-01](docs/SI-01.md) is the coding spec. The product is a macOS app that owns the USB device. The kernel in the note is what each channel runs. Code to that document.

The app package is [SI01](SI01/). `swift test` covers the session. `swift run SI01 --check` prints one snapshot. Core Audio is not in this package yet.

It is not a manual for any commercial plug-in. Field numbers are cited from public tests and are labelled measured, reported, or estimated.
