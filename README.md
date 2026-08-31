# PenBridge

Turn a Galaxy Tab and S Pen into a pressure-sensitive input surface for macOS.
PenBridge forwards hover, pressure, tilt, position and stylus-button data over a
direct USB Type-C connection. It is an early open-source prototype intended for
Blender, drawing tools and other tablet-aware Mac applications.

## How it works

- The Android app reads native Flutter stylus pointer events.
- `adb reverse` carries the local WebSocket stream over USB; no Wi-Fi is used.
- The macOS app converts packets into Quartz tablet/mouse events.

## Requirements

- macOS 13 or newer
- Android tablet with a supported stylus (tested target: Galaxy Tab S9)
- Flutter 3.47 or newer
- Android platform tools (`adb`)
- A USB data cable

## Run

```bash
flutter run -d macos
```

Connect the tablet, enable **Developer options > USB debugging**, accept the Mac
on the tablet, then press **Type-C bağlantısını hazırla** in the Mac app.

In a second terminal:

```bash
flutter devices
flutter run -d <android-device-id>
```

Press **Bağlan** on the tablet. macOS will ask for Accessibility permission the
first time input injection is enabled. Restart PenBridge after granting it.

## Current limitations

- Coordinates map the complete tablet pad to the Mac's main display.
- The MVP uses JSON/WebSocket packets; a compact binary protocol is planned.
- Quartz tablet-event compatibility varies by application. A DriverKit virtual
  HID backend is planned, but distribution requires an Apple entitlement.
- USB debugging is required for this first version. Android Open Accessory mode
  is the planned no-ADB transport.

## Safety

The receiver binds only to `127.0.0.1`. The USB tunnel exposes no LAN port and
the project stores no pen data.

## License

MIT
