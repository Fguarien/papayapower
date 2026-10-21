# PapayaPower

<p align="center"><img src="docs/icon.png" width="128" alt="PapayaPower icon"></p>

Battery health for **Macs, iPhones, iPads, Linux laptops and UPS units** — one native app per
platform, and one view of every computer at home.

- **macOS** — SwiftUI app with a menu bar window (This Mac / History / iPhone & iPad / Network),
  universal binary (Apple silicon + Intel), macOS 13 Ventura or later.
- **Linux** — GTK 4 / libadwaita app, a `papaya` command line and a Waybar module
  (built for Omarchy / Hyprland, works on any desktop).

Original code, MIT licence. It reads the same public sources every battery tool reads
(the `AppleSmartBattery` IORegistry entry, `/sys/class/power_supply`, the iOS diagnostics relay,
UPower, Network UPS Tools); nothing is copied from another application.

## Features

| | macOS | Linux |
|---|---|---|
| Charge, health (full charge / design capacity), cycles, temperature, voltage, power in/out, time remaining | ✅ | ✅ |
| Battery identity: manufacturer, model, serial, manufacture date and age; Mac manufacture date from the serial | ✅ | ✅ (what the kernel exposes) |
| Lifetime data recorded by the gas gauge (min/avg/max temperature, max currents, pack voltages, operating time) | ✅ | iOS devices |
| Advanced viewer: every raw key, filterable, copyable | ✅ | ✅ |
| **iPhone / iPad** over USB and Wi-Fi | ✅ MobileDevice | ✅ libimobiledevice |
| History (SQLite), auto-save daily/weekly, charts, CSV export | ✅ | ✅ |
| Menu bar / Waybar with a battery icon (charge, time, watts or health) | ✅ | ✅ |
| Notifications: low battery, low iPhone, UPS on battery / low — once per crossing | ✅ | ✅ |
| **UPS**: USB HID UPS (macOS power sources / UPower) and NUT servers | ✅ | ✅ |
| Printable reports from HTML templates (`$MAC_BATTERY_HEALTH_PERCENT`, `$IOS_BATTERY_CYCLECOUNT`…) | ✅ | ✅ |
| Prometheus Pushgateway export (`papaya_battery_*`, `papaya_ups_*`) | ✅ | ✅ |
| **Network: master / member** — a master sees every computer running PapayaPower | ✅ | planned |

UPS support is written against the macOS IOPowerSources keys and the NUT standard variable
names, and tested with simulated data; it has not yet met real hardware.

## Master and members

Every PapayaPower announces itself with Bonjour (`_papayapower._tcp`) and serves its own
readings, read-only, to local addresses only. In **Settings › General › Local network**:

- **Member** (default): sees only its own readings and shares them with the master;
- **Master**: discovers every computer, shows their Macs, iPhones and UPS units, saves them in its
  history and publishes them to the Pushgateway — one place to configure, one credential.

With a **network key** (same value everywhere), members answer only a master that presents it.
The key is read from Settings, else from `~/Library/Application Support/PapayaPower/network.key`,
else from `/Users/Shared/PapayaPower/network.key` (machine-wide, so an administrator can set it
for every account).

## Install

### macOS

Download `PapayaPower-<version>.dmg` from the releases, drag the app to Applications. The app is
not notarised: the first time, open **System Settings › Privacy & Security** and click
**Open Anyway** (or right-click › Open on older systems).

Build it yourself (Xcode or the Swift 6 command line tools):

```bash
cd macos
./make-app.sh              # build/PapayaPower.app, universal
./make-app.sh --install    # … and copy it to /Applications
./make-app.sh --dmg        # … and build build/PapayaPower-<version>.dmg
```

The `papaya` command line ships inside the app (`PapayaPower.app/Contents/Helpers/papaya`):
`papaya`, `--json`, `--raw`, `--metrics`, `--ios`, `--nut host[:port]`, `--peers`.

### Linux (Arch / Omarchy)

```bash
sudo pacman -S --needed python-gobject python-cairo gtk4 libadwaita upower libimobiledevice usbmuxd libnotify
cd linux && ./install.sh          # ~/.local, desktop entry, systemd user timer
```

Then add the Waybar module from `linux/waybar/papaya.jsonc` and its style from
`linux/waybar/papaya.css`.

## Privacy

Readings stay on the computer. They leave it only if you turn on the Pushgateway export, or
share them with a master on your local network.

## Licence

MIT — see [LICENSE](LICENSE).
