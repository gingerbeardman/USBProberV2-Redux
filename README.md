# USB Prober Redux

USB device and IORegistry inspection for macOS 15 or later. The application
builds as a universal binary for Apple Silicon (`arm64`) and Intel (`x86_64`).

Download the signed, notarized DMG from [GitHub Releases](https://github.com/gingerbeardman/USBProberV2/releases/latest),
then drag **USB Prober** to **Applications**.

Open `USBProber.xcodeproj` and select the **USB Prober** scheme, or build with:

```sh
xcodebuild -project USBProber.xcodeproj \
  -scheme 'USB Prober' \
  -configuration Development \
  -derivedDataPath build/macos15 \
  build
```

The app is written to `build/macos15/Build/Products/Development/USB Prober.app`.
The project uses ad hoc signing for local builds; no developer team is needed.
Use `-configuration Deployment` for an optimized build, with its app in the
corresponding `Deployment` directory.

Nova's `.nova/Tasks/app.json` provides Build, Clean, and Run actions using the
same Development configuration.

## Distribution

```sh
Scripts/make-notarized-dmg.sh
```

This follows Katana's release mechanism: archive both architectures, export with
Developer ID signing and hardened runtime, notarize and staple the app, then
create, sign, notarize, and staple a compressed DMG with an Applications link.
Both Gatekeeper assessments must pass. The final image and SHA-256 checksum are
written to `dist/`; build/export logs are in `build/release/`.

Requires Xcode, Matt Sephton's Developer ID Application identity (team
`Q3Z639YB49`), and the existing `notarytool-password` keychain profile.
`KEYCHAIN_PROFILE` and `SIGN_IDENTITY` can override those defaults. Credentials
stay in the keychain. Local Development builds still use ad hoc signing.

Command-line inspection:

```sh
'build/macos15/Build/Products/Development/USB Prober.app/Contents/MacOS/USB Prober' --help
'build/macos15/Build/Products/Development/USB Prober.app/Contents/MacOS/USB Prober' --busprobe
```

USB inspection requires access to the IOKit device user clients. Running the
executable inside a restrictive development-tool sandbox can return no devices.

## USB logging

Select **USB Logger** and press **Start**. Logging runs entirely in user space:

- An initial snapshot and IOKit notifications report present, connected, and
  removed devices, with vendor/product IDs and location IDs.
- `/usr/bin/log stream` supplies live USB unified logs, including messages from
  USB subsystems, USB driver images, and USB-related kernel messages.
- The level menu selects Errors & faults, Default, Info, or Debug. Device events
  are reported at every level. Changing level restarts only the system stream.
- Device events, system messages, and session markers use ISO timestamps with
  milliseconds and timezone. System labels show the driver image when available,
  or a driver name inferred from the kernel message.
- Capture headers record the selected level, and Start/Stop and level changes
  appear as timestamped session markers.
- Adjacent identical system messages are grouped in the window, with a count and
  last timestamp. Device changes and session markers break a group.
- Existing text filtering, markers, Save Output, and continuous file dumping
  work with both event sources. Both file paths preserve raw repetitions; Save
  Output exports the retained history matching the current text filter. Stop
  closes the stream and unregisters device notifications. Quitting also stops the backend.

No kext, DriverKit entitlement, root helper, or reduced security setting is
needed. The app is deliberately not sandboxed: restrictive tool sandboxes can
block both IOKit access and the `log` command. Stream errors appear in the log
window, and device monitoring continues if the system stream exits. Stop and
Start retries the stream.

This captures diagnostics exposed by macOS, not USB packets or every transfer.
Private values can remain redacted, and debug messages depend on the emitting
driver and its logging configuration. Changing the level does not change global
system logging settings. A quiet system may produce only device events.

The window keeps a bounded recent history (up to 10,000 entries and about 2 MiB
of displayed text); **Dump output to file** records every received event for
long sessions. macOS can drop messages when a system log source floods.

## USB vendor names

`USBVendors.txt` is generated from the [Linux USB ID database](http://www.linux-usb.org/usb.ids),
maintained by Stephen J. Gowdy. Its header records the upstream version and date.
To refresh the bundled vendor names:

```sh
curl --fail --location http://www.linux-usb.org/usb.ids -o /tmp/usb.ids
python3 Scripts/update-usb-vendors.py /tmp/usb.ids
```

The converter selects vendor entries, converts hexadecimal IDs to decimal, and
writes UTF-8 in the format the app reads. Products, interfaces, and classes are
excluded. Rebuild the app to include the updated resource.

## Logger tests

```sh
Tests/run-logger-tests.sh
Tests/run-logger-tests.sh --live
```

The first command checks fragmented UTF-8/JSON decoding and stopped-session
behavior, precise timestamps, driver labels, repeat grouping, and raw file
capture. The live test requires an unrestricted local process. It checks real
unified-log delivery with a synthetic USB message from another process, device
notification registration, level changes, Stop cleanup, and restart. Physical
hot-plug events can be checked by connecting or unplugging a USB device while
logging.

## Validation

Validated on macOS 15.8.1 with Xcode 26.3 (macOS 26.2 SDK), using a macOS 15.0
deployment target. Development and Deployment builds produce both architectures.
Native command-line probing reads descriptors for connected USB devices. The
USB Logger also displays live USB kernel diagnostics and the device snapshot.
