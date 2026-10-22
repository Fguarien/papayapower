"""Member side of the master/member network, for Linux.

Same protocol as the macOS app (`PeerServer` in Peers.swift): Bonjour `_papayapower._tcp`,
plain HTTP, `GET /v1/readings` → `PeerReadings` JSON (camelCase keys, dates as seconds since
1970), read-only, local addresses only, optional network key in `X-Papaya-Key`.

Bonjour goes through Avahi (`avahi-publish`, package `avahi`): no Python dependency. The key
is read from ~/.config/papayapower/network.key on every request, so dropping or rotating it
needs no restart.
"""
from __future__ import annotations

import hmac
import ipaddress
import json
import shutil
import signal
import socket
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from . import __version__, core, store

SERVICE_TYPE = "_papayapower._tcp"
PATH = "/v1/readings"
DEFAULT_PORT = 47823
KEY_FILE = store.CONFIG / "network.key"
CACHE_SECONDS = 20          # a master polling several members must not re-read sysfs each time

_LOCAL_NETS = [ipaddress.ip_network(n) for n in (
    "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "127.0.0.0/8", "169.254.0.0/16",
    "100.64.0.0/10", "::1/128", "fe80::/10", "fc00::/7")]


def is_local(addr: str) -> bool:
    try:
        ip = ipaddress.ip_address(addr)
    except ValueError:
        return False
    if isinstance(ip, ipaddress.IPv6Address) and ip.ipv4_mapped:
        ip = ip.ipv4_mapped
    return any(ip in n for n in _LOCAL_NETS)


def network_key() -> str:
    try:
        return KEY_FILE.read_text().strip()
    except OSError:
        return ""


def _camel(d: dict, rename: dict[str, str]) -> dict:
    out = {}
    for k, v in d.items():
        if v is None:
            continue
        k = rename.get(k) or k.split("_")[0] + "".join(w.title() for w in k.split("_")[1:])
        out[k] = v
    return out


def battery_json(b: core.Battery) -> dict:
    d = _camel({
        "device_id": b.device_id, "device_name": b.device_name, "model": b.model,
        "os_version": b.os_version, "device_serial": b.device_serial, "timestamp": b.timestamp,
        "charge_percent": b.charge_percent, "current_capacity": b.current_capacity,
        "full_charge_capacity": b.full_charge_capacity, "design_capacity": b.design_capacity,
        "cycle_count": b.cycle_count, "temperature": b.temperature, "voltage": b.voltage,
        "amperage": b.amperage, "is_charging": b.is_charging, "external_connected": b.external_connected,
        "fully_charged": b.fully_charged, "time_to_empty": b.time_to_empty, "time_to_full": b.time_to_full,
        "adapter_watts": b.adapter_watts, "battery_serial": b.battery_serial,
        "battery_manufacturer": b.battery_manufacturer, "battery_model": b.battery_model,
    }, {"device_id": "deviceID"})
    # DeviceKind on macOS is mac | ios | ups: a laptop pack is the « mac » kind there.
    d["kind"] = "ios" if b.kind == "ios" else "mac"
    raw = dict(b.raw)
    if b.gauge_warning:
        raw["papaya.gaugeWarning"] = b.gauge_warning
    d["raw"] = raw
    return d


def ups_json(u: core.UPS) -> dict:
    d = _camel({
        "id": u.id, "name": u.name, "source": u.source, "timestamp": u.timestamp,
        "charge_percent": u.charge_percent, "on_battery": u.on_battery,
        "runtime_seconds": u.runtime_seconds, "load_percent": u.load_percent,
        "input_voltage": u.input_voltage, "output_voltage": u.output_voltage,
        "battery_voltage": u.battery_voltage, "status": u.status, "manufacturer": u.manufacturer,
        "model": u.model, "serial": u.serial, "battery_date": u.battery_date,
    }, {})
    d["raw"] = dict(u.raw)
    return d


def readings() -> dict:
    host, _, _ = core.machine_name()
    batteries = [b for b in core.sysfs_batteries() if b.kind == "laptop"]
    ups = core.upower_ups()
    settings = store.load_settings()
    for h in [h for h in settings.get("nut_hosts", "").replace(",", " ").split() if h]:
        name, _, port = h.partition(":")
        try:
            ups += core.nut_read(name, int(port or 3493))
        except Exception:
            pass
    return {"host": host, "platform": "Linux " + (core.os_version() or ""), "version": __version__,
            "timestamp": time.time(), "batteries": [battery_json(b) for b in batteries],
            "ups": [ups_json(u) for u in ups]}


class _Cache:
    def __init__(self):
        self.lock = threading.Lock()
        self.at = 0.0
        self.body = b""

    def get(self) -> bytes:
        with self.lock:
            if time.monotonic() - self.at > CACHE_SECONDS:
                self.body = json.dumps(readings()).encode()
                self.at = time.monotonic()
            return self.body


_cache = _Cache()


class Handler(BaseHTTPRequestHandler):
    server_version = "PapayaPower"
    sys_version = ""

    def _send(self, status: int, body: bytes, ctype: str = "text/plain") -> None:
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):  # noqa: N802 (http.server API)
        if not is_local(self.client_address[0]):
            self.close_connection = True
            return
        expected = network_key()
        sent = self.headers.get("X-Papaya-Key", "").strip()
        if expected and not hmac.compare_digest(sent.encode(), expected.encode()):
            return self._send(403, b"network key required\n")
        if self.path.split("?")[0] != PATH:
            return self._send(404, b"not found\n")
        try:
            self._send(200, _cache.get(), "application/json")
        except Exception as e:      # a reading error must not kill the server
            self._send(500, f"{e}\n".encode())

    def log_message(self, fmt, *args):  # journald gets errors only
        pass


class _Server(ThreadingHTTPServer):
    address_family = socket.AF_INET6
    daemon_threads = True

    def server_bind(self):
        self.socket.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 0)   # v4 too
        super().server_bind()


def serve(port: int = DEFAULT_PORT) -> int:
    name = socket.gethostname().split(".")[0]
    httpd = _Server(("::", port), Handler)
    publisher = None
    if shutil.which("avahi-publish"):
        publisher = subprocess.Popen(["avahi-publish", "-s", name, SERVICE_TYPE, str(port), f"version={__version__}"],
                                     stdout=subprocess.DEVNULL)
    else:
        print("avahi-publish missing (package avahi): serving without Bonjour", file=sys.stderr)

    def stop(*_):
        threading.Thread(target=httpd.shutdown, daemon=True).start()

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    print(f"serving {SERVICE_TYPE} « {name} » on port {port}"
          + (" — network key required" if network_key() else " — no network key: any LAN client can read"))
    try:
        httpd.serve_forever()
    finally:
        if publisher:
            publisher.terminate()
    return 0
