# LosslessMusic

**Let your Mac’s audio output follow Apple Music’s lossless tracks.**

English · [简体中文](README.zh-CN.md)

LosslessMusic is a lightweight macOS menu bar app that automatically adjusts your audio output’s sample rate and bit depth to the detected format of the current Apple Music track. No more repeated trips to Audio MIDI Setup when the next song uses a different sample rate.

## Features

- Automatically follows the detected lossless format of the current track.
- Displays the output device name, sample rate, and source bit depth in a compact menu.
- Switches the system output through **Output Devices**, with a checkmark beside the current device.
- Updates the available device list when devices are connected or disconnected; Bluetooth devices are excluded.
- Supports 16-bit sources on DACs that only offer 24-bit output.
- Can recover playback information when launched while Music is already playing.
- Runs in the menu bar, with no main window, Dock icon, account setup, or third-party dependencies.

## Requirements

- **macOS 27.0 or later** — the current project’s minimum system version.
- Apple Music with **Lossless Audio** enabled. Select **Hi-Res Lossless** to use higher-resolution tracks when available.
- An output device that supports the track’s sample rate, such as a USB DAC or audio interface.

### Dolby Atmos

**Dolby Atmos can stay on Automatic; it does not need to be turned off.** With a regular stereo DAC that does not support automatic Atmos playback, Music uses the stereo version, including ALAC when lossless is enabled and available. Avoid **Always On** if you want Music to choose the format according to the output device. See [Apple’s Dolby Atmos guide](https://support.apple.com/en-us/109354).

## Build and run

The current development environment is **Xcode 27.1**, using Swift 6 language mode.

1. Clone or download this repository and open `LosslessMusic.xcodeproj`.
2. Select the **LosslessMusic** scheme and **My Mac**.
3. Under **Signing & Capabilities**, select your own development team; change the bundle identifier if needed for signing.
4. Run the app and play a lossless track in Music.

Keep the project’s existing App Sandbox setting disabled; it is required by the current log-reading approach.

## Usage

Click the menu bar icon to see the output device name and detected track format. Use **Output Devices** to switch the system output, or **Quit** to exit. Long device names can be viewed in full by hovering.

The app works in the background. Waiting messages mean it has not yet obtained the playback or format information it needs. If the current track has no known ALAC format, the output format stays unchanged.

The bit depth shown is the **source** bit depth. A 16-bit track can therefore still display `16-bit` while a 24-bit-only DAC uses 24-bit output.

## Things to know

- Changing the system output device or its format affects other applications too, and may briefly interrupt audio.
- Detection depends on Music’s logs. Some local or offline tracks may not provide enough information, and macOS updates can affect compatibility.
- The app targets the highest available ALAC format it detects for the current track; it does not provide exclusive output or guarantee bit-perfect playback.
- Quitting does not restore the previous device format.
- The app makes no network requests and includes no analytics.

For bug reports, include your macOS version, device model, and reproduction steps. If you attach logs, remove personal information first.

## Acknowledgments

Inspired by [LosslessSwitcher](https://github.com/vincentneo/LosslessSwitcher) by vincentneo and [WindowsLosslessSwitcher](https://github.com/jordanmgibson/WindowsLosslessSwitcher) by jordanmgibson.

This project is not affiliated with or endorsed by Apple.

## License

Copyright (C) 2026 LosslessMusic contributors.

Licensed under **GNU GPL v3.0**. See [LICENSE](LICENSE). The software is provided without warranty.
