"""papaya — command line, Waybar module and background recorder.

  papaya                 human summary
  papaya --json          batteries + UPS as JSON
  papaya --raw           every sysfs / IORegistry key
  papaya --metrics       Prometheus exposition (what --record pushes)
  papaya --waybar        one JSON line for a Waybar custom module
  papaya --record        auto-save to history, notify, push (run by the systemd user timer)
  papaya --gui           open the window (same as `papayapower`)
  papaya --serve         member: serve readings to the master over Bonjour (systemd user service)
  papaya --peer-json     print what --serve answers
  --ios / --no-ios       include iPhone/iPad (default: settings)
  --nut host[:port]      also read a NUT server (repeatable; adds to settings)
"""
from __future__ import annotations

import argparse
import json
import shutil
import subprocess
import sys
from pathlib import Path

from . import core, report, store


def gather(settings: dict, ios: bool | None, extra_nut: list[str]) -> tuple[list[core.Battery], list[core.UPS], list[str]]:
    errors: list[str] = []
    batteries = core.sysfs_batteries()
    if ios if ios is not None else settings.get("ios_enabled"):
        batteries += core.ios_devices()
    ups = core.upower_ups()
    hosts = [h for h in settings.get("nut_hosts", "").replace(",", " ").split() if h] + extra_nut
    for h in hosts:
        host, _, port = h.partition(":")
        try:
            ups += core.nut_read(host, int(port or 3493))
        except Exception as e:      # network errors are reported, never fatal
            errors.append(f"NUT {h}: {e}")
    return batteries, ups, errors


def summary(batteries, ups) -> str:
    out = []

    def line(k, v):
        if v is not None:
            out.append(f"{k:<24}{v}")

    for b in batteries:
        out.append(f"== {b.device_name} ({b.model or b.kind}) — {b.os_version or ''}")
        line("Charge", core.fmt_pct(b.charge_percent) if b.charge_percent is not None else None)
        if b.current_capacity is not None and b.full_charge_capacity:
            line("Current / full", f"{b.current_capacity} / {b.full_charge_capacity} mAh")
        line("Design capacity", f"{b.design_capacity} mAh" if b.design_capacity else None)
        line("Health", core.fmt_pct(b.health * 100) + (" (unreliable)" if b.gauge_warning else "") if b.health else None)
        line("⚠ Gauge", b.gauge_warning)
        line("Cycles", b.cycle_count)
        line("Temperature", f"{b.temperature:.1f} °C" if b.temperature is not None else None)
        line("Battery power", f"{b.power_watts:+.1f} W" if b.power_watts is not None else None)
        line("Time to empty", core.fmt_minutes(b.time_to_empty) if b.time_to_empty else None)
        line("Time to full", core.fmt_minutes(b.time_to_full) if b.time_to_full else None)
        line("Battery", " ".join(x for x in (b.battery_manufacturer, b.battery_model, b.technology) if x) or None)
        line("Battery serial", b.battery_serial)
        out.append("")
    if not any(b.kind == "laptop" for b in batteries):
        out.append("No laptop battery.\n")
    for u in ups:
        out.append(f"== UPS {u.name} — {u.source}")
        line("Charge", core.fmt_pct(u.charge_percent) if u.charge_percent is not None else None)
        line("Status", u.status)
        line("Runtime", core.fmt_minutes(u.runtime_seconds // 60) if u.runtime_seconds else None)
        line("Load", core.fmt_pct(u.load_percent, 0) if u.load_percent is not None else None)
        out.append("")
    return "\n".join(out)


def waybar(batteries, ups, fmt: str) -> dict:
    lap = next((b for b in batteries if b.kind == "laptop"), None)
    ups_ob = next((u for u in ups if u.on_battery), None)
    if lap is None:
        u = ups[0] if ups else None
        text = f"⚡ {u.charge_percent:.0f}%" if u and u.charge_percent is not None else "⚡"
        cls = "ups-battery" if ups_ob else "ac"
        pct = int(u.charge_percent) if u and u.charge_percent is not None else 0
    else:
        c = lap.charge_percent or 0
        icons = "󰂎󰁺󰁻󰁼󰁽󰁾󰁿󰂀󰂁󰂂󰁹"
        icon = "󰂄" if lap.is_charging else icons[min(10, int(c // 10))]
        if fmt == "time" and (lap.time_to_empty or lap.time_to_full):
            val = core.fmt_minutes(lap.time_to_full if lap.is_charging else lap.time_to_empty)
        elif fmt == "watts" and lap.power_watts is not None:
            val = f"{lap.power_watts:+.1f}W"
        elif fmt == "health" and lap.health:
            val = f"♥{lap.health * 100:.0f}%"
        else:
            val = f"{c:.0f}%"
        text = f"{icon} {val}" + (" ⚠" if ups_ob else "")
        cls = "charging" if lap.is_charging else "critical" if c < 10 else "warning" if c < 20 else "normal"
        if ups_ob:
            cls = "ups-battery"
        pct = int(c)
    tips = []
    for b in batteries:
        bits = [f"{b.charge_percent:.0f} %" if b.charge_percent is not None else None,
                f"health {b.health * 100:.1f} %" if b.health else None,
                f"{b.cycle_count} cycles" if b.cycle_count is not None else None,
                f"{b.power_watts:+.1f} W" if b.power_watts is not None else None]
        tips.append(f"<b>{b.device_name}</b>  " + " · ".join(x for x in bits if x)
                    + ("\n⚠ gauge out of calibration — health unreliable" if b.gauge_warning else ""))
    for u in ups:
        bits = [f"{u.charge_percent:.0f} %" if u.charge_percent is not None else None,
                "ON BATTERY" if u.on_battery else "mains",
                f"runtime {core.fmt_minutes(u.runtime_seconds // 60)}" if u.runtime_seconds else None]
        tips.append(f"<b>UPS {u.name}</b>  " + " · ".join(x for x in bits if x))
    return {"text": text, "tooltip": "\n".join(tips) or "No battery", "class": cls, "percentage": pct}


def notify(title: str, body: str) -> None:
    if shutil.which("notify-send"):
        subprocess.run(["notify-send", "-a", "PapayaPower", "-i", "battery-caution", title, body], check=False)


def record(settings: dict, batteries, ups) -> list[str]:
    """Auto-save, alerts with hysteresis (state kept between runs), Pushgateway."""
    log = []
    hist = store.History()
    for b in batteries:
        if b.kind != "peripheral" and hist.auto_save(b, settings.get("auto_save", "daily")):
            log.append(f"saved {b.device_name}")
    state_f = store.DATA / "alerts.json"
    try:
        alerted = set(json.loads(state_f.read_text()))
    except (OSError, ValueError):
        alerted = set()

    def alert(key, when, clear, title, body):
        if when and key not in alerted:
            alerted.add(key)
            notify(title, body)
            log.append(f"alert {key}")
        elif clear:
            alerted.discard(key)

    if settings.get("notify_enabled"):
        pct = settings.get("notify_percent", 0)
        for b in batteries:
            if b.charge_percent is None:
                continue
            if b.kind == "laptop" and pct:
                alert(f"lap-{b.device_id}", b.charge_percent <= pct and not b.external_connected,
                      b.charge_percent > pct + 3 or bool(b.external_connected),
                      "Battery low", f"{b.device_name} is at {b.charge_percent:.0f} %.")
            ip = settings.get("notify_ios_percent", 0)
            if b.kind == "ios" and ip:
                alert(f"ios-{b.device_id}", b.charge_percent <= ip and not b.is_charging,
                      b.charge_percent > ip + 3 or bool(b.is_charging),
                      f"{b.device_name} battery low", f"{b.device_name} is at {b.charge_percent:.0f} %.")
        if settings.get("notify_ups"):
            for u in ups:
                alert(f"ups-ob-{u.id}", bool(u.on_battery), u.on_battery is False,
                      f"{u.name}: on battery", "Mains power lost.")
                alert(f"ups-lb-{u.id}", u.low_battery, not u.low_battery,
                      f"{u.name}: battery low", "The UPS reports a low battery.")
    store.DATA.mkdir(parents=True, exist_ok=True)
    state_f.write_text(json.dumps(sorted(alerted)))

    if settings.get("push_enabled") and settings.get("push_url"):
        try:
            code = report.push(settings["push_url"], settings.get("push_user"), store.secret_get("pushgateway"),
                               [b for b in batteries if b.kind != "peripheral"], ups)
            log.append(f"push {code}")
        except Exception as e:
            log.append(f"push failed: {e}")
    return log


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(prog="papaya", description="Battery and UPS health.")
    for f in ("json", "raw", "metrics", "waybar", "record", "gui"):
        ap.add_argument(f"--{f}", action="store_true")
    ap.add_argument("--ios", dest="ios", action="store_true", default=None)
    ap.add_argument("--no-ios", dest="ios", action="store_false")
    ap.add_argument("--nut", action="append", default=[])
    ap.add_argument("--serve", action="store_true", help="member: serve readings to the master (Bonjour)")
    ap.add_argument("--peer-json", action="store_true", help="print what --serve answers")
    ap.add_argument("--port", type=int, default=None)
    a = ap.parse_args(argv)

    if a.serve or a.peer_json:
        from . import peer
        if a.peer_json:
            print(json.dumps(peer.readings(), indent=2, sort_keys=True))
            return 0
        return peer.serve(a.port or store.load_settings().get("peer_port") or peer.DEFAULT_PORT)

    if a.gui:
        from .gui import main as gui_main
        return gui_main()

    settings = store.load_settings()
    # The Waybar module refreshes often: skip iOS (slow) unless asked.
    ios = a.ios if a.ios is not None else (False if a.waybar else None)
    batteries, ups, errors = gather(settings, ios, a.nut)
    for e in errors:
        print(e, file=sys.stderr)

    if a.waybar:
        print(json.dumps(waybar(batteries, ups, settings.get("waybar_format", "percent"))))
    elif a.json:
        print(json.dumps({"batteries": [b.to_dict() for b in batteries],
                          "ups": [u.to_dict() for u in ups]}, indent=2, sort_keys=True))
    elif a.raw:
        for b in batteries:
            print(f"== {b.device_name}")
            for k, v in sorted(b.raw.items()):
                print(f"{k} = {v}")
        for u in ups:
            print(f"== UPS {u.name}")
            for k, v in sorted(u.raw.items()):
                print(f"{k} = {v}")
    elif a.metrics:
        print(report.exposition([b for b in batteries if b.kind != "peripheral"], ups), end="")
    elif a.record:
        for l in record(settings, batteries, ups):
            print(l)
    else:
        print(summary(batteries, ups))
    return 0


if __name__ == "__main__":
    sys.exit(main())
