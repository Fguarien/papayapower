"""Printable HTML reports and Prometheus exposition — same variables and metrics as on macOS."""
from __future__ import annotations

import base64
import html
import socket
import time
import urllib.parse
import urllib.request
from pathlib import Path

from . import __version__
from .core import UPS, Battery, fmt_pct


def template(kind: str, custom: str = "") -> str:
    if custom:
        try:
            return Path(custom).expanduser().read_text()
        except OSError:
            pass
    p = "IOS" if kind == "ios" else "MAC"
    title = "iPhone / iPad battery report" if kind == "ios" else "Battery report"
    rows = [("Model", f"${p}_MODEL"), ("Serial number", f"${p}_SERIAL"), ("System", "$OS_VERSION"),
            ("Battery health", f"<b>${p}_BATTERY_HEALTH_PERCENT</b>"),
            ("Full charge / design capacity", f"${p}_BATTERY_MAH"),
            ("Charge cycles", f"${p}_BATTERY_CYCLECOUNT"), ("Temperature", "$BATTERY_TEMPERATURE"),
            ("Battery manufacturer", f"${p}_BATTERY_MANUFACTURER"),
            ("Battery serial", f"${p}_BATTERY_SERIAL")]
    trs = "\n".join(f"<tr><td>{k}</td><td>{v}</td></tr>" for k, v in rows)
    return f"""<!doctype html>
<html><head><meta charset="utf-8"><title>{title}</title>
<style>
body {{ font: 13px system-ui, sans-serif; color: #1d1d1f; margin: 40px; }}
h1 {{ font-size: 22px; margin: 0 0 4px; color: #e8590c; }}
.sub {{ color: #6e6e73; margin-bottom: 24px; }}
table {{ border-collapse: collapse; width: 100%; max-width: 640px; }}
td {{ padding: 7px 10px; border-bottom: 1px solid #e5e5ea; }}
td:first-child {{ color: #6e6e73; width: 45%; }}
.foot {{ margin-top: 32px; color: #8e8e93; font-size: 11px; }}
</style></head><body>
<h1>{title}</h1>
<div class="sub">$DEVICE_NAME · $REPORT_CREATION</div>
<table>
{trs}
</table>
<div class="foot">$REPORT_VERSION</div>
</body></html>
"""


def variables(b: Battery) -> dict[str, str]:
    p = "IOS" if b.kind == "ios" else "MAC"
    mah = f"{b.full_charge_capacity} / {b.design_capacity} mAh" if b.full_charge_capacity and b.design_capacity else "—"
    return {
        "REPORT_CREATION": time.strftime("%d %B %Y %H:%M", time.localtime(b.timestamp)),
        "REPORT_VERSION": f"PapayaPower {__version__}",
        "DEVICE_NAME": b.device_name,
        "OS_VERSION": b.os_version or "—",
        "BATTERY_TEMPERATURE": f"{b.temperature:.1f} °C" if b.temperature is not None else "—",
        "MAC_MODEL": b.model or "—",
        f"{p}_MODEL": b.model or "—",
        f"{p}_SERIAL": b.device_serial or "—",
        f"{p}_MANUFACTURE_DATE": "—",
        f"{p}_BATTERY_CYCLECOUNT": str(b.cycle_count) if b.cycle_count is not None else "—",
        f"{p}_BATTERY_HEALTH_PERCENT": fmt_pct(b.health * 100) if b.health else "—",
        f"{p}_BATTERY_MAH": mah,
        f"{p}_BATTERY_MANUFACTURE_DATE": "—",
        f"{p}_BATTERY_SERIAL": b.battery_serial or "—",
        f"{p}_BATTERY_MANUFACTURER": b.battery_manufacturer or "—",
        f"{p}_BATTERY_FAILURE": "No",
    }


def render(tpl: str, v: dict[str, str]) -> str:
    for k in sorted(v, key=len, reverse=True):
        tpl = tpl.replace("$" + k, html.escape(v[k]))
    return tpl


def exposition(batteries: list[Battery], ups: list[UPS]) -> str:
    lines: list[str] = []
    declared: set[str] = set()

    def esc(s: str) -> str:
        return s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")

    def metric(name: str, help_: str, labels: dict[str, str], value) -> None:
        if value is None:
            return
        if name not in declared:
            lines.extend([f"# HELP {name} {help_}", f"# TYPE {name} gauge"])
            declared.add(name)
        lab = ",".join(f'{k}="{esc(v)}"' for k, v in sorted(labels.items()))
        lines.append(f"{name}{{{lab}}} {float(value)}")

    for b in batteries:
        lab = {"device": b.device_name, "device_id": b.device_id, "kind": b.kind}
        metric("papaya_battery_charge_percent", "Battery charge in percent.", lab, b.charge_percent)
        metric("papaya_battery_health_ratio", "Full charge capacity / design capacity.", lab, b.health)
        metric("papaya_battery_cycles", "Charge cycle count.", lab, b.cycle_count)
        metric("papaya_battery_full_charge_mah", "Full charge capacity in mAh.", lab, b.full_charge_capacity)
        metric("papaya_battery_design_mah", "Design capacity in mAh.", lab, b.design_capacity)
        metric("papaya_battery_temperature_celsius", "Battery temperature.", lab, b.temperature)
        metric("papaya_battery_power_watts", "Power into (+) or out of (-) the battery.", lab, b.power_watts)
        metric("papaya_battery_external_power", "1 when on external power.", lab,
               None if b.external_connected is None else int(b.external_connected))
        metric("papaya_battery_reading_timestamp_seconds", "Time of the reading.", lab, b.timestamp)
    for u in ups:
        lab = {"ups": u.name, "ups_id": u.id}
        metric("papaya_ups_charge_percent", "UPS battery charge in percent.", lab, u.charge_percent)
        metric("papaya_ups_on_battery", "1 when the UPS runs on battery.", lab,
               None if u.on_battery is None else int(u.on_battery))
        metric("papaya_ups_low_battery", "1 when the UPS reports low battery.", lab, int(u.low_battery))
        metric("papaya_ups_runtime_seconds", "Estimated runtime on battery.", lab, u.runtime_seconds)
        metric("papaya_ups_load_percent", "UPS load in percent.", lab, u.load_percent)
    return "\n".join(lines) + "\n"


def push(url: str, user: str | None, password: str | None, batteries: list[Battery], ups: list[UPS],
         instance: str | None = None) -> int:
    inst = urllib.parse.quote(instance or socket.gethostname(), safe="")
    req = urllib.request.Request(f"{url.rstrip('/')}/metrics/job/papayapower/instance/{inst}",
                                 data=exposition(batteries, ups).encode(), method="PUT",
                                 headers={"Content-Type": "text/plain; version=0.0.4"})
    if user and password:
        req.add_header("Authorization", "Basic " + base64.b64encode(f"{user}:{password}".encode()).decode())
    with urllib.request.urlopen(req, timeout=10) as r:
        return r.status
