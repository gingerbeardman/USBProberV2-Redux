# USB Prober V2 Redux

A USB device and IORegistry inspection tool for macOS 15 or later, based on
[Apple's USB Prober](https://github.com/apple-oss-distributions/IOUSBFamily/tree/main/USBProberV2).
Builds run on Apple Silicon and Intel Macs.

- Inspect connected USB devices and decode their descriptors.
- Browse the IORegistry and inspect USB port status.
- Monitor device connections and live USB system diagnostics.
- Filter, mark, and save diagnostic captures.

<img width="1554" height="1088" alt="73925" src="https://github.com/user-attachments/assets/9a913dd0-5600-420c-a352-0e2553c15cd9" />

## Install

Download the signed, notarized DMG from
[GitHub Releases](https://github.com/gingerbeardman/USBProberV2-Redux/releases/latest),
open it, and drag **USB Prober** to **Applications**.

## USB logging

Select **USB Logger** and press **Start**. Logging combines an initial device
snapshot, IOKit connection/removal notifications, and USB messages from
`/usr/bin/log stream`. Device events include vendor, product, and location IDs.

Choose **Errors & faults**, **Default**, **Info**, or **Debug**. Device events
appear at every level; changing the level restarts the system stream. Records
use timestamps with milliseconds and timezone, driver labels where available,
and session markers for Start, Stop, and level changes.

Adjacent identical system messages are grouped in the window. Saved captures
preserve raw repetitions. **Save Output** exports the retained history matching
the text filter; **Dump output to file** records every received event for longer
sessions. The window retains up to 10,000 entries and about 2 MiB of text.

Logging runs in user space without a kernel extension or root helper. It
captures diagnostics exposed by macOS rather than USB packets or every transfer.
Private values may be redacted, and available debug messages depend on the
driver. Changing the level does not change global system logging settings.
If the system stream exits, device monitoring continues; Stop and Start retries
it. macOS may drop messages when a log source floods.

## Build

Requires Xcode and the macOS SDK. Open `USBProber.xcodeproj` and select the
**USB Prober** scheme, or run:

```sh
xcodebuild -project USBProber.xcodeproj \
  -scheme 'USB Prober' \
  -configuration Development \
  -derivedDataPath build/macos15 \
  build
```

The app is written to `build/macos15/Build/Products/Development/USB Prober.app`.
Local builds use ad hoc signing and do not require a developer team. Use
`-configuration Deployment` for an optimized build in the corresponding
`Deployment` directory. Both configurations build `arm64` and `x86_64`.

Nova's `.nova/Tasks/app.json` provides Build, Clean, and Run actions.

Command-line inspection is also available:

```sh
'build/macos15/Build/Products/Development/USB Prober.app/Contents/MacOS/USB Prober' --help
'build/macos15/Build/Products/Development/USB Prober.app/Contents/MacOS/USB Prober' --busprobe
```

The app is not sandboxed. Restrictive development-tool sandboxes can block IOKit
access and the system log command, preventing inspection or logging.

## Create a release DMG

Configure the signing team and Developer ID identity in
`Scripts/make-notarized-dmg.sh` and `ExportOptions.plist`. Store notarization
credentials in a `notarytool` keychain profile, then run:

```sh
KEYCHAIN_PROFILE='your-notary-profile' \
SIGN_IDENTITY='Developer ID Application: Your Name (TEAMID)' \
Scripts/make-notarized-dmg.sh
```

The script archives a universal build with hardened runtime, exports it with
Developer ID signing, and notarizes and staples both the app and a compressed
DMG containing an Applications link. Both Gatekeeper assessments must pass.
The DMG and SHA-256 checksum are written to `dist/`; build and export logs are
in `build/release/`. Notarization credentials remain in the keychain.

## Update vendor names

`USBVendors.txt` is generated from the
[Linux USB ID database](http://www.linux-usb.org/usb.ids). Its header records
upstream attribution, version, and date. To refresh it:

```sh
curl --fail --location http://www.linux-usb.org/usb.ids -o /tmp/usb.ids
python3 Scripts/update-usb-vendors.py /tmp/usb.ids
```

The converter selects vendor entries and writes UTF-8 names with decimal IDs
in the format the app reads. Products, interfaces, and classes are excluded.
Rebuild the app to include the updated resource.

## Tests

```sh
Tests/run-logger-tests.sh
Tests/run-logger-tests.sh --live
```

Tests cover fragmented UTF-8/JSON decoding, timestamps, driver labels, repeat
grouping, raw file capture, and logger lifecycle. The live test requires an
unrestricted local process and checks real unified-log delivery, device
notification registration, level changes, Stop cleanup, and restart.
Physical connection events can be checked by plugging or unplugging a USB device.

Builds and live logging have been validated on macOS 15.8.1 with Xcode 26.3
(macOS 26.2 SDK), using a macOS 15.0 deployment target.

## Licence and origins

The original Apple source and this fork's modifications are distributed under
**Apple Public Source License 2.0 (APSL-2.0)**. See [LICENSE](LICENSE) for the full
text, copied from Apple's
[IOUSBFamily repository](https://github.com/apple-oss-distributions/IOUSBFamily/blob/main/APPLE_LICENSE).
Existing Apple copyright and licence notices are retained.

Source code, including the fork's modifications, is available at
<https://github.com/gingerbeardman/USBProberV2-Redux>. The app bundles the licence
and displays the source location in its About credits. The vendor database is
sourced separately from linux-usb.org, as noted above.

This fork builds on [USBProberV2](https://github.com/vampirecat35/USBProberV2)
and Apple's original USB Prober. Apple's historical
[IOUSBFamily README](https://github.com/apple-oss-distributions/IOUSBFamily/blob/main/Readme.rtf)
is marked out of date; the instructions here describe this fork.
