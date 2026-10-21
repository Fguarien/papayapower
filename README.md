# PapayaPower

<p align="center"><img src="docs/icon.png" width="128" alt="PapayaPower icon"></p>

Battery health for **Macs, iPhones, iPads, Linux laptops and UPS units** — one native app per
platform, and one view of every computer at home.

- **macOS** — SwiftUI app living in the menu bar: a compact panel, a PapayaPower window
  (This Mac / History / iPhone & iPad / Network) and a Details window; universal binary
  (Apple silicon + Intel), macOS 13 Ventura or later.
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

## Help

The user guide is [`docs/HELP.md`](docs/HELP.md). The same file is shipped in the app and shown
by **Help › PapayaPower Help** (⌘?) or the **?** button on macOS, and by **Menu › Help** on Linux.

## Versions

Versioning follows [Semantic Versioning](https://semver.org): `MAJOR.MINOR.PATCH`.
`macos/VERSION` and `linux/papayapower/__init__.py` always carry the same number; each release is
a `vX.Y.Z` tag with its DMG on the releases page.

### 1.0.3 — 2026-10-21

- **One window at a time.** More Details…, Lifetime Details… and Open History Viewer close the
  PapayaPower window and open Details on the right item; the menu bar panel's expand button
  brings PapayaPower back.
- **History moves into Details**, as a sidebar entry with a device picker, instead of a third
  window. Deleting a device's whole history moved to the ⋯ toolbar button.
- **UPS section hidden** in the Details sidebar until a UPS is connected (still shown when a
  configured NUT server fails, so the error is visible).
- **Help**: `docs/HELP.md`, shown in a Help window (⌘?, ? buttons) on macOS and a Help dialog on
  Linux.
- Settings › Notifications: stepper first, text on its right — no more clipped labels.

### 1.0.2 — 2026-10-21

- **coconutBattery-style menu bar**: a compact panel (charge, health, time remaining, cycles,
  temperature) with version, settings and an expand button.
- The expand button opens the **PapayaPower** window: This Mac / History / iPhone & iPad /
  Network tabs. Overview, Lifetime and Advanced move to **More Details…**.
- Macs are named after the computer (“Arya’s MacBook Air”), so two Macs of the same family stay
  distinct in the history and in Prometheus.
- Intel Macs: `product-name` ignored when it only repeats the model identifier.
- Pushgateway: first push after 45 s, never an empty push (a PUT replaces the whole group).

### 1.0.1 — 2026-10-21

- Stable signing identity (“PapayaPower Local Signing”): Keychain access and firewall rules
  (Little Snitch) survive rebuilds instead of being asked again for every build.
- App Nap opt-out: a menu-bar-only app had its timers frozen after the first run (no more
  readings, peer fetches or pushes).
- Peer fetch prefers IPv4 and reports a connection stuck “waiting” as a failure.

### 1.0.0 — 2026-10-21

First release, macOS and Linux:

- Mac and laptop batteries: charge, health, cycles, temperature, voltage, power, time remaining,
  battery identity and age, Mac manufacture date from the serial, lifetime data, raw keys.
- iPhone / iPad over USB and Wi-Fi (MobileDevice on macOS, libimobiledevice on Linux).
- UPS: USB (IOPowerSources / UPower) and NUT servers.
- History in SQLite with charts and CSV export; notifications with hysteresis; HTML report
  templates; Prometheus Pushgateway export; `papaya` command line; Waybar module.
- Menu bar battery icon with charge, time, watts or health.
- **Master / member** network mode over Bonjour, with an optional network key.

### 0.x — development, 2026-10-21 (not released)

Iterations numbered after the fact. Built in one day from a feature survey of coconutBattery 4.4 (surface only: classes, services
and template variables; no code copied):

- 0.1 — tabbed main window (Overview / Lifetime / Advanced), iPhone & iPad, history, UPS, Linux
  GTK 4 app and Waybar module.
- 0.2 — battery icon in the menu bar and in Settings.
- 0.3 — discovery of the other computers running PapayaPower (Bonjour + HTTP).
- 0.4 — menu bar window modelled on coconutBattery's (This Mac / History / iPhone/iPad tabs,
  Mac Info and Battery Info popovers).
- 0.5 — master / member roles and the network key; became 1.0.0.

## Privacy

Readings stay on the computer. They leave it only if you turn on the Pushgateway export, or
share them with a master on your local network.

## Licence

MIT — see [LICENSE](LICENSE).
