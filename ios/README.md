# Moto Service Tool — iOS

A Bluetooth-LE iOS app (iPhone/iPad) that reuses the same engine as the macOS
app: service-indicator reset, live data, VIN, and fault codes.

> **iOS is Bluetooth-LE only.** Apple blocks generic USB serial without MFi
> certification, so the iOS app connects to a **BLE ELM327 adapter** (e.g.
> Carista, Vgate iCar Pro BLE, OBDLink CX/MX+). The USB FTDI adapter used by the
> macOS app does **not** work on iOS.

## Build & run

You need **full Xcode** (not just Command Line Tools) and a **real iPhone**
(CoreBluetooth does not work in the Simulator).

```bash
# 0) one-time, if the CLI complains about the license:
sudo xcodebuild -license accept

# 1) install the project generator
brew install xcodegen

# 2) generate the Xcode project
cd ios
xcodegen generate          # creates MotoServiceTool.xcodeproj

# 3) open it
open MotoServiceTool.xcodeproj
```

In Xcode:
1. Select the **MotoServiceTool** target → **Signing & Capabilities** → choose
   your **Team** (a free Apple ID works for sideloading; 7-day expiry).
2. Plug in your iPhone, select it as the run destination, press **Run**.
3. On the phone: **Scan for Bluetooth adapter** → pick yours → **Connect**
   (allow the Bluetooth permission prompt) → with ignition ON, use **Reset
   Service Indicator** or the **Live Data** tab.

## Notes
- The engine source is shared from `../Sources/DucatiResetKit`; the serial /
  capture files are `#if os(macOS)` and compile to nothing on iOS.
- Distribution: free personal-team sideload (re-sign weekly), or an Apple
  Developer account ($99/yr) for TestFlight / the App Store.

⚠️ Use at your own risk. The author takes no responsibility for any damage.
Not affiliated with Ducati. Created by V-twin Fanatics.
