# PapayaPower Help

PapayaPower shows the health of the batteries around you: this computer, your iPhones and iPads, UPS units, and — on a master — every other computer at home that runs PapayaPower.

## Getting started

- **macOS**: PapayaPower lives in the **menu bar**. Click its battery icon for the essentials; click the **expand** button (bottom right) to open the PapayaPower window.
- **Linux**: open **PapayaPower** from your launcher. The Waybar module shows the charge and opens the app on click.
- Nothing to set up: readings start at once. Settings are only needed for the network, notifications and monitoring.

## The three views (macOS)

- **Menu bar panel**: battery charge, battery health, time remaining (or until full), cycles and temperature. Footer: version, **Settings** (gear), **Help** (?), **expand**.
- **PapayaPower window**: tabs **This Mac**, **History**, **iPhone/iPad** and, on a master, **Network**. The **Mac Info** and **Battery Info** buttons show more in a popover.
- **Details window**: opened by **More Details…**, **Lifetime Details…** or **Open History Viewer**. It replaces the PapayaPower window — one window at a time. To get the PapayaPower window back, use the menu bar panel's expand button.
- In Details, the left column lists this Mac, iPhones and iPads, UPS units (only when one is connected), the network (master only) and **History**.

## What the numbers mean

- **Battery charge**: current charge, against what the battery can hold today.
- **Battery health**: full charge capacity ÷ design capacity. 100 % = as new. Under **80 %** Apple considers the battery worn; under **50 %** it should be replaced. Green ≥ 80 %, yellow ≥ 50 %, red below.
- **Cycles**: one cycle = 100 % of the capacity used, in one go or in several. Mac batteries are rated 1000 cycles (300–500 for older models).
- **Temperature**: of the battery pack. Above 35 °C, capacity wears faster.
- **Lifetime**: what the battery's own gauge recorded since it was made — min/avg/max temperature, peak currents, operating time.
- **Advanced**: every raw key the system reports, filterable, copyable.

## iPhone and iPad

- Connect the device by **USB** and tap **Trust** on it. Once trusted, it is also seen over **Wi-Fi** when Wi-Fi sync is on (Finder › device › "Show this iPhone when on Wi-Fi").
- Scan interval: **Settings › General**. Refresh at once: ⌘⇧R.
- Recent iOS versions no longer answer some diagnostics: health may then be missing while charge and cycles are shown.
- Linux needs `libimobiledevice` and `usbmuxd`.

## History

- Readings are saved **automatically** (daily by default, **Settings › History**) or at once with **⌘S**.
- In Details › History: choose a device, then Health / Full charge / Cycles / Temperature. Export as **CSV** with the share button; delete selected rows with the bin; delete a device's whole history from the **⋯** button.
- The database stays on this computer.

## Master and members (local network)

- Every PapayaPower announces itself on the local network (Bonjour `_papayapower._tcp`).
- **Member** (default): shows its own readings only, and shares them with the master.
- **Master**: finds every member, shows their batteries (Details › Network, and the Network tab), saves them in its history and publishes them to Prometheus.
- Set the role in **Settings › General › Local network**. Use the same **network key** everywhere: a member then answers only a master that knows it.
- The key can also be stored in `/Users/Shared/PapayaPower/network.key` (all accounts of the Mac) or `~/Library/Application Support/PapayaPower/network.key`.

## UPS

- A UPS plugged in by **USB** is found by macOS (or UPower on Linux) by itself.
- A UPS managed by a **NUT** server: add `host` or `host:port` in **Settings › UPS** (read-only, no login).
- The UPS section appears only when a UPS is there.

## Notifications

- **Settings › Notifications**: Mac battery below a threshold, remaining time below a threshold, iPhone/iPad low, UPS on battery or low.
- Each alert fires **once** when the threshold is crossed, and re-arms when the level is back above it.

## Monitoring (Prometheus)

- **Settings › Monitoring**: Pushgateway URL, user, password (kept in the Keychain), interval.
- Metrics `papaya_battery_*` and `papaya_ups_*`, job `papayapower`, instance = computer name. On a master, members are included.
- The first push waits 45 s so the network has been read; an empty reading is never pushed.

## Printing

- **⌘P** prints a report of this Mac. Templates are HTML files with placeholders (`$MAC_BATTERY_HEALTH_PERCENT`, `$IOS_BATTERY_CYCLECOUNT`, `$REPORT_CREATION`…). **Settings › Printing › Save Built-in Templates…** gives a starting point.

## Command line

- macOS: `/Applications/PapayaPower.app/Contents/Helpers/papaya` · Linux: `papaya`.
- `papaya` (summary), `--json`, `--raw`, `--metrics`, `--ios`, `--nut host[:port]`, `--peers` (macOS; key in the `PAPAYA_KEY` variable). Linux also: `--waybar`, `--record`, `--gui`.

## Troubleshooting

- **"Unidentified developer"** on first launch: System Settings › Privacy & Security › **Open Anyway**. Once is enough.
- **A firewall (Little Snitch, LuLu) asks about PapayaPower**: allow it. It needs the local network to find members and, if set, the Pushgateway. Builds share one signature, so the rule survives updates.
- **The master does not see a member**: same network key on both? Member app running? From the master: `papaya --peers`.
- **No battery shown**: a desktop Mac has none. Connect an iPhone, a UPS, or make it the master.
- **Updating**: quit PapayaPower (power button in the PapayaPower window footer), replace the app in Applications, open it again.
