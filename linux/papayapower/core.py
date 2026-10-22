"""Readings: laptop batteries (sysfs), UPS units (UPower, NUT), iPhone/iPad (libimobiledevice).

Pure standard library: the GUI is optional, the CLI and the Waybar module only need this file.
"""
from __future__ import annotations

import dataclasses
import os
import plistlib
import shutil
import socket
import subprocess
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

SYSFS = Path(os.environ.get("PAPAYA_SYSFS", "/sys/class/power_supply"))


@dataclass
class Lifetime:
    maximum_temperature: float | None = None
    minimum_temperature: float | None = None
    average_temperature: float | None = None
    maximum_charge_current: int | None = None
    maximum_discharge_current: int | None = None
    maximum_pack_voltage: int | None = None
    minimum_pack_voltage: int | None = None
    total_operating_time: int | None = None


@dataclass
class Battery:
    kind: str                      # "laptop" | "ios" | "peripheral"
    device_id: str
    device_name: str
    timestamp: float = field(default_factory=time.time)
    model: str | None = None
    os_version: str | None = None
    device_serial: str | None = None
    charge_percent: float | None = None
    current_capacity: int | None = None     # mAh
    full_charge_capacity: int | None = None  # mAh
    design_capacity: int | None = None      # mAh
    cycle_count: int | None = None
    temperature: float | None = None        # °C
    voltage: int | None = None              # mV
    amperage: int | None = None             # mA, negative = discharging
    power_watts: float | None = None        # battery power, negative = discharging
    is_charging: bool | None = None
    external_connected: bool | None = None
    fully_charged: bool | None = None
    time_to_empty: int | None = None        # minutes
    time_to_full: int | None = None
    adapter_watts: int | None = None
    battery_serial: str | None = None
    battery_manufacturer: str | None = None
    battery_model: str | None = None
    technology: str | None = None
    lifetime: Lifetime | None = None
    gauge_warning: str | None = None        # the gauge contradicts itself (see sysfs_batteries)
    raw: dict[str, str] = field(default_factory=dict)

    @property
    def health(self) -> float | None:
        if self.full_charge_capacity and self.design_capacity:
            return self.full_charge_capacity / self.design_capacity
        return None

    def to_dict(self, raw: bool = False) -> dict[str, Any]:
        d = dataclasses.asdict(self)
        d["health"] = self.health
        if not raw:
            d.pop("raw")
        return d


@dataclass
class UPS:
    id: str
    name: str
    source: str
    timestamp: float = field(default_factory=time.time)
    charge_percent: float | None = None
    on_battery: bool | None = None
    runtime_seconds: int | None = None
    load_percent: float | None = None
    input_voltage: float | None = None
    output_voltage: float | None = None
    battery_voltage: float | None = None
    status: str | None = None
    manufacturer: str | None = None
    model: str | None = None
    serial: str | None = None
    battery_date: str | None = None
    raw: dict[str, str] = field(default_factory=dict)

    @property
    def low_battery(self) -> bool:
        return "LB" in (self.status or "").split()

    def to_dict(self, raw: bool = False) -> dict[str, Any]:
        d = dataclasses.asdict(self)
        d["low_battery"] = self.low_battery
        if not raw:
            d.pop("raw")
        return d


# ---------------------------------------------------------------- sysfs


def _read(p: Path) -> str | None:
    try:
        return p.read_text().strip()
    except OSError:
        return None


def _int(v: str | None) -> int | None:
    try:
        return int(v) if v not in (None, "") else None
    except ValueError:
        return None


def machine_name() -> tuple[str, str | None, str | None]:
    """(display name, model, serial) from DMI."""
    dmi = Path("/sys/class/dmi/id")
    vendor = _read(dmi / "sys_vendor") or ""
    product = _read(dmi / "product_name") or ""
    serial = _read(dmi / "product_serial")   # root-only on most systems: None is normal
    host = socket.gethostname()
    name = f"{host}"
    model = " ".join(x for x in (vendor, product) if x and x not in ("To be filled by O.E.M.",)) or None
    return name, model, serial


def os_version() -> str | None:
    try:
        rel = dict(
            line.split("=", 1) for line in Path("/etc/os-release").read_text().splitlines() if "=" in line
        )
        pretty = rel.get("PRETTY_NAME", "").strip('"')
        return f"{pretty} · Linux {os.uname().release}" if pretty else f"Linux {os.uname().release}"
    except OSError:
        return f"Linux {os.uname().release}"


def external_power() -> bool | None:
    seen = False
    for d in SYSFS.glob("*"):
        if _read(d / "type") == "Mains":
            seen = True
            if _read(d / "online") == "1":
                return True
    return False if seen else None


def sysfs_batteries() -> list[Battery]:
    """Every battery the kernel exposes. Laptop packs first, then peripherals (mice, pens…)."""
    out: list[Battery] = []
    if not SYSFS.exists():
        return out
    host, model, serial = machine_name()
    ext = external_power()
    for d in sorted(SYSFS.iterdir()):
        if _read(d / "type") != "Battery":
            continue
        raw = {}
        for f in sorted(d.iterdir()):
            if f.is_file() and f.name not in ("uevent",):
                v = _read(f)
                if v is not None and len(v) < 200:
                    raw[f.name] = v
        if raw.get("present") == "0":
            continue
        peripheral = raw.get("scope") == "Device"
        b = Battery(
            kind="peripheral" if peripheral else "laptop",
            device_id=(serial or host) + ":" + d.name if not peripheral else raw.get("serial_number", d.name),
            device_name=(raw.get("model_name") or d.name) if peripheral else host,
            model=model if not peripheral else raw.get("manufacturer"),
            os_version=os_version() if not peripheral else None,
            device_serial=serial,
        )
        b.raw = raw
        cap = _int(raw.get("capacity"))
        b.charge_percent = float(cap) if cap is not None else None
        uv = _int(raw.get("voltage_now"))
        b.voltage = uv // 1000 if uv is not None else None
        vmin = _int(raw.get("voltage_min_design")) or uv
        # charge_* in µAh; energy_* in µWh (converted to mAh with the design voltage).
        if "charge_full" in raw:
            def ua(k: str) -> int | None:
                v = _int(raw.get(k))
                return v // 1000 if v is not None else None
            b.full_charge_capacity = ua("charge_full")
            b.design_capacity = ua("charge_full_design")
            b.current_capacity = ua("charge_now")
        elif "energy_full" in raw and vmin:
            def mah(k: str) -> int | None:
                v = _int(raw.get(k))
                return round(v / vmin * 1000) if v is not None else None   # µWh / µV = Ah → ×1000 mAh
            b.full_charge_capacity = mah("energy_full")
            b.design_capacity = mah("energy_full_design")
            b.current_capacity = mah("energy_now")
        b.cycle_count = _int(raw.get("cycle_count")) or None
        # A worn gauge (bq20z451 at 560+ cycles) can report more charge left than its own full
        # charge capacity. Its numbers are then shown as read, never « fixed », but flagged:
        # health and time estimates built on them are not to be trusted until a calibration.
        if b.current_capacity and b.full_charge_capacity and b.current_capacity > b.full_charge_capacity:
            b.gauge_warning = (f"Gauge out of calibration: {b.current_capacity} mAh left > "
                               f"{b.full_charge_capacity} mAh full charge capacity. Health and times are "
                               "unreliable — charge to 100 %, then run down to shutdown once.")
        status = raw.get("status", "")
        b.is_charging = status == "Charging"
        b.fully_charged = status == "Full"
        b.external_connected = ext
        cur = _int(raw.get("current_now"))
        pw = _int(raw.get("power_now"))
        sign = -1 if status == "Discharging" else 1
        if cur is not None:
            b.amperage = sign * abs(cur) // 1000
        if pw is not None:
            b.power_watts = sign * abs(pw) / 1e6
        elif cur is not None and uv is not None:
            b.power_watts = sign * abs(cur) * uv / 1e12
        if _int(raw.get("temp")) is not None:
            b.temperature = _int(raw["temp"]) / 10
        b.battery_manufacturer = raw.get("manufacturer")
        b.battery_model = raw.get("model_name")
        b.battery_serial = raw.get("serial_number") or None
        b.technology = raw.get("technology")
        # Time estimates from current flow.
        if b.amperage and b.current_capacity is not None:
            a = abs(b.amperage)
            if status == "Discharging" and a > 0:
                b.time_to_empty = int(b.current_capacity / a * 60)
            elif status == "Charging" and a > 0 and b.full_charge_capacity and not b.gauge_warning:
                b.time_to_full = int(max(0, b.full_charge_capacity - b.current_capacity) / a * 60)
        out.append(b)
    out.sort(key=lambda x: x.kind != "laptop")
    return out


# ---------------------------------------------------------------- UPS: UPower


def upower_ups() -> list[UPS]:
    """UPS units UPower manages (USB HID UPS, or NUT through upower's own backend)."""
    if not shutil.which("upower"):
        return []
    try:
        lines = subprocess.run(["upower", "-e"], capture_output=True, text=True, timeout=5).stdout.split()
    except (OSError, subprocess.SubprocessError):
        return []
    out = []
    for path in lines:
        if "/ups_" not in path:
            continue
        try:
            info = subprocess.run(["upower", "-i", path], capture_output=True, text=True, timeout=5).stdout
        except (OSError, subprocess.SubprocessError):
            continue
        kv = {}
        for line in info.splitlines():
            if ":" in line:
                k, v = line.split(":", 1)
                kv[k.strip()] = v.strip()
        u = UPS(id=f"upower:{path.rsplit('/', 1)[-1]}", name=kv.get("model") or "UPS", source="USB (UPower)")
        u.raw = kv
        if "percentage" in kv:
            u.charge_percent = float(kv["percentage"].rstrip("%").replace(",", "."))
        state = kv.get("state", "")
        u.on_battery = state == "discharging"
        u.status = "OB" if u.on_battery else "OL"
        u.manufacturer = kv.get("vendor")
        u.model = kv.get("model")
        u.serial = kv.get("serial")
        tte = kv.get("time to empty")
        if tte:
            n, unit = (tte.replace(",", ".").split() + [""])[:2]
            try:
                f = float(n)
                u.runtime_seconds = int(f * (3600 if unit.startswith("hour") else 60))
            except ValueError:
                pass
        out.append(u)
    return out


# ---------------------------------------------------------------- UPS: NUT


def _nut_tokens(line: str) -> list[str]:
    out, cur, q, esc, has = [], "", False, False, False
    for ch in line:
        if esc:
            cur += ch; esc = False; continue
        if ch == "\\":
            esc = True; continue
        if ch == '"':
            q = not q; has = True; continue
        if ch == " " and not q:
            if has or cur:
                out.append(cur); cur = ""; has = False
            continue
        cur += ch
    if has or cur:
        out.append(cur)
    return out


def nut_read(host: str, port: int = 3493, timeout: float = 3) -> list[UPS]:
    """Read-only NUT client: LIST UPS, then LIST VAR for each."""
    with socket.create_connection((host, port), timeout=timeout) as s:
        f = s.makefile("rw", encoding="utf-8", newline="\n")

        def lst(cmd: str) -> list[str]:
            f.write(cmd + "\n"); f.flush()
            first = f.readline().strip()
            if first.startswith("ERR"):
                raise RuntimeError(f"NUT {host}: {first}")
            if not first.startswith("BEGIN LIST"):
                raise RuntimeError(f"NUT {host}: unexpected {first!r}")
            lines = []
            while True:
                l = f.readline()
                if not l:
                    raise RuntimeError(f"NUT {host}: connection closed")
                l = l.strip()
                if l.startswith("END LIST"):
                    return lines
                lines.append(l)

        out = []
        for line in lst("LIST UPS"):
            t = _nut_tokens(line)
            if len(t) < 2 or t[0] != "UPS":
                continue
            name, desc = t[1], (t[2] if len(t) > 2 else "")
            v = {}
            for vl in lst(f"LIST VAR {name}"):
                vt = _nut_tokens(vl)
                if len(vt) >= 4 and vt[0] == "VAR":
                    v[vt[2]] = vt[3]
            out.append(nut_snapshot(name, f"{host}:{port}", v, desc))
        try:
            f.write("LOGOUT\n"); f.flush()
        except OSError:
            pass
        return out


def nut_snapshot(ups: str, host: str, v: dict[str, str], desc: str | None = None) -> UPS:
    def num(k: str) -> float | None:
        try:
            return float(v[k])
        except (KeyError, ValueError):
            return None

    u = UPS(id=f"nut:{host}/{ups}", name=desc or ups, source=f"NUT {host}")
    u.charge_percent = num("battery.charge")
    rt = num("battery.runtime")
    u.runtime_seconds = int(rt) if rt is not None else None
    u.load_percent = num("ups.load")
    u.input_voltage = num("input.voltage")
    u.output_voltage = num("output.voltage")
    u.battery_voltage = num("battery.voltage")
    u.status = v.get("ups.status")
    if u.status:
        u.on_battery = "OB" in u.status.split()
    u.manufacturer = v.get("ups.mfr") or v.get("device.mfr")
    u.model = v.get("ups.model") or v.get("device.model")
    u.serial = v.get("ups.serial") or v.get("device.serial")
    u.battery_date = v.get("battery.date") or v.get("battery.mfr.date")
    u.raw = dict(v)
    return u


# ---------------------------------------------------------------- iOS


def _run(args: list[str], timeout: float = 15) -> str | None:
    try:
        r = subprocess.run(args, capture_output=True, timeout=timeout)
    except (OSError, subprocess.SubprocessError):
        return None
    return r.stdout.decode("utf-8", "replace") if r.returncode == 0 else None


def ios_available() -> bool:
    return bool(shutil.which("idevice_id") and shutil.which("ideviceinfo") and shutil.which("idevicediagnostics"))


def _plist(text: str | None) -> dict[str, Any] | None:
    if not text:
        return None
    try:
        v = plistlib.loads(text.encode())
        return v if isinstance(v, dict) else None
    except Exception:
        return None


def ios_devices(network: bool = True) -> list[Battery]:
    """Paired iPhones/iPads via usbmuxd (USB, and Wi-Fi when the device allows it)."""
    if not ios_available():
        return []
    seen: dict[str, str] = {}
    for flag, itf in (("-l", "usb"), ("-n", "wifi")) if network else (("-l", "usb"),):
        for udid in (_run(["idevice_id", flag], 10) or "").split():
            seen.setdefault(udid, itf)
    out = []
    for udid, itf in seen.items():
        net = ["-n"] if itf == "wifi" else []
        info = _plist(_run(["ideviceinfo", *net, "-u", udid, "-x"]))
        if info is None:
            continue
        b = Battery(kind="ios", device_id=udid, device_name=info.get("DeviceName", "iOS device"))
        b.model = info.get("ProductType")
        osname = "iPadOS" if info.get("DeviceClass") == "iPad" else "iOS"
        b.os_version = f"{osname} {info.get('ProductVersion', '')}".strip()
        b.device_serial = info.get("SerialNumber")
        raw = {"Interface": "Wi-Fi" if itf == "wifi" else "USB"}
        bat = _plist(_run(["ideviceinfo", *net, "-u", udid, "-q", "com.apple.mobile.battery", "-x"]))
        if bat:
            if "BatteryCurrentCapacity" in bat:
                b.charge_percent = float(bat["BatteryCurrentCapacity"])
            b.is_charging = bat.get("BatteryIsCharging")
            b.external_connected = bat.get("ExternalConnected", bat.get("ExternalChargeCapable"))
            b.fully_charged = bat.get("FullyCharged")
            raw.update({f"lockdown.{k}": str(v) for k, v in bat.items()})
        reg = None
        for entry in ("AppleSmartBattery", "AppleARMPMUCharger"):
            d = _plist(_run(["idevicediagnostics", *net, "-u", udid, "ioregentry", entry]))
            if d:
                r = d.get("IORegistry", d)
                if isinstance(r, dict) and ("DesignCapacity" in r or "CycleCount" in r):
                    reg = r
                    break
        if reg:
            pct = b.charge_percent
            fill_from_ioreg(b, reg)
            if pct is not None:
                b.charge_percent = pct
            raw.update(b.raw)
        b.raw = raw
        out.append(b)
    return sorted(out, key=lambda x: x.device_name)


def fill_from_ioreg(b: Battery, p: dict[str, Any]) -> None:
    """Same AppleSmartBattery keys as on a Mac."""
    def i(k: str) -> int | None:
        v = p.get(k)
        if isinstance(v, bool) or v is None:
            return None
        try:
            v = int(v)
        except (TypeError, ValueError):
            return None
        return v - (1 << 64) if v >= (1 << 63) else v

    b.full_charge_capacity = i("AppleRawMaxCapacity") or i("NominalChargeCapacity") or i("MaxCapacity")
    b.current_capacity = i("AppleRawCurrentCapacity") or i("CurrentCapacity")
    b.design_capacity = i("DesignCapacity")
    b.cycle_count = i("CycleCount")
    if i("Temperature") is not None:
        b.temperature = i("Temperature") / 100
    b.voltage = i("Voltage") or i("AppleRawBatteryVoltage")
    b.amperage = i("InstantAmperage") if i("InstantAmperage") is not None else i("Amperage")
    if b.voltage is not None and b.amperage is not None:
        b.power_watts = b.voltage * b.amperage / 1e6
    b.battery_serial = p.get("BatterySerialNumber") or p.get("Serial")
    b.battery_manufacturer = p.get("Manufacturer")
    b.battery_model = p.get("DeviceName")
    bd = p.get("BatteryData") or {}
    lt = bd.get("LifetimeData") if isinstance(bd, dict) else None
    if isinstance(lt, dict):
        def t(k: str) -> float | None:
            v = lt.get(k)
            if not isinstance(v, int):
                return None
            return v / 10 if abs(v) > 200 else float(v)
        b.lifetime = Lifetime(
            maximum_temperature=t("MaximumTemperature"), minimum_temperature=t("MinimumTemperature"),
            average_temperature=t("AverageTemperature"), maximum_charge_current=lt.get("MaximumChargeCurrent"),
            maximum_discharge_current=abs(lt["MaximumDischargeCurrent"]) if isinstance(lt.get("MaximumDischargeCurrent"), int) else None,
            maximum_pack_voltage=lt.get("MaximumPackVoltage"), minimum_pack_voltage=lt.get("MinimumPackVoltage"),
            total_operating_time=lt.get("TotalOperatingTime"))
    b.raw = flatten(p)


def flatten(d: dict[str, Any], prefix: str = "") -> dict[str, str]:
    out: dict[str, str] = {}
    for k, v in d.items():
        key = f"{prefix}.{k}" if prefix else str(k)
        if isinstance(v, dict):
            out.update(flatten(v, key))
        elif isinstance(v, (bytes, bytearray)):
            out[key] = v.hex() if len(v) <= 64 else f"<{len(v)} bytes>"
        elif isinstance(v, list) and v and all(isinstance(e, dict) for e in v):
            for n, e in enumerate(v):
                out.update(flatten(e, f"{key}[{n}]"))
        elif isinstance(v, list):
            out[key] = ", ".join(map(str, v))
        else:
            out[key] = str(v)
    return out


# ---------------------------------------------------------------- formatting


def fmt_minutes(m: int) -> str:
    return f"{m // 60}:{m % 60:02d}"


def fmt_pct(v: float, digits: int = 1) -> str:
    return f"{v:.{digits}f} %"
