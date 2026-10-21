"""History (SQLite, same schema as the macOS app), settings (JSON), secrets (libsecret)."""
from __future__ import annotations

import csv
import io
import json
import os
import shutil
import sqlite3
import subprocess
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from .core import Battery

DATA = Path(os.environ.get("XDG_DATA_HOME", Path.home() / ".local/share")) / "papayapower"
CONFIG = Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config")) / "papayapower"

DEFAULTS: dict[str, Any] = {
    "auto_save": "daily",            # off | daily | weekly
    "notify_enabled": True,
    "notify_percent": 15,
    "notify_ios_percent": 0,
    "notify_ups": True,
    "nut_hosts": "",
    "ios_enabled": True,
    "push_enabled": False,
    "push_url": "",
    "push_user": "",
    "refresh_seconds": 10,
    "waybar_format": "percent",      # percent | time | watts | health
    "mac_template": "",
    "ios_template": "",
}


def load_settings() -> dict[str, Any]:
    try:
        s = json.loads((CONFIG / "settings.json").read_text())
    except (OSError, ValueError):
        s = {}
    return {**DEFAULTS, **s}


def save_settings(s: dict[str, Any]) -> None:
    CONFIG.mkdir(parents=True, exist_ok=True)
    tmp = CONFIG / "settings.json.tmp"
    tmp.write_text(json.dumps({k: v for k, v in s.items() if k in DEFAULTS}, indent=2))
    tmp.replace(CONFIG / "settings.json")


AUTO = {"off": None, "daily": 86400, "weekly": 7 * 86400}


class History:
    def __init__(self, path: Path | None = None):
        DATA.mkdir(parents=True, exist_ok=True)
        self.path = path or DATA / "history.sqlite"
        self.db = sqlite3.connect(self.path)
        self.db.executescript(
            """
            PRAGMA journal_mode=WAL;
            CREATE TABLE IF NOT EXISTS reading (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                ts REAL NOT NULL, kind TEXT NOT NULL,
                device_id TEXT NOT NULL, device_name TEXT NOT NULL,
                charge REAL, cycles INTEGER, full_mah INTEGER, design_mah INTEGER, temp REAL,
                snapshot TEXT);
            CREATE INDEX IF NOT EXISTS reading_device ON reading(device_id, ts);
            """
        )

    def save(self, b: Battery) -> None:
        self.db.execute(
            "INSERT INTO reading(ts,kind,device_id,device_name,charge,cycles,full_mah,design_mah,temp,snapshot)"
            " VALUES(?,?,?,?,?,?,?,?,?,?)",
            (b.timestamp, b.kind, b.device_id, b.device_name, b.charge_percent, b.cycle_count,
             b.full_charge_capacity, b.design_capacity, b.temperature, json.dumps(b.to_dict())),
        )
        self.db.commit()

    def last_saved(self, device_id: str) -> float | None:
        r = self.db.execute("SELECT MAX(ts) FROM reading WHERE device_id=?", (device_id,)).fetchone()
        return r[0] if r and r[0] else None

    def auto_save(self, b: Battery, mode: str) -> bool:
        interval = AUTO.get(mode)
        if interval is None:
            return False
        last = self.last_saved(b.device_id)
        if last and time.time() - last < interval:
            return False
        self.save(b)
        return True

    def devices(self) -> list[tuple[str, str, str]]:
        return self.db.execute(
            "SELECT device_id, device_name, kind FROM reading GROUP BY device_id ORDER BY MAX(ts) DESC"
        ).fetchall()

    def entries(self, device_id: str | None = None) -> list[sqlite3.Row]:
        self.db.row_factory = sqlite3.Row
        try:
            if device_id:
                return self.db.execute("SELECT * FROM reading WHERE device_id=? ORDER BY ts DESC", (device_id,)).fetchall()
            return self.db.execute("SELECT * FROM reading ORDER BY ts DESC").fetchall()
        finally:
            self.db.row_factory = None

    def delete(self, ids: list[int]) -> None:
        self.db.executemany("DELETE FROM reading WHERE id=?", [(i,) for i in ids])
        self.db.commit()

    def delete_device(self, device_id: str) -> None:
        self.db.execute("DELETE FROM reading WHERE device_id=?", (device_id,))
        self.db.commit()

    def csv(self, device_id: str | None = None) -> str:
        buf = io.StringIO()
        w = csv.writer(buf)
        w.writerow(["timestamp", "kind", "device_id", "device_name", "charge_percent", "cycles",
                    "full_mah", "design_mah", "health_percent", "temperature_c"])
        for r in reversed(self.entries(device_id)):
            health = f"{r['full_mah'] / r['design_mah'] * 100:.1f}" if r["full_mah"] and r["design_mah"] else ""
            w.writerow([datetime.fromtimestamp(r["ts"], timezone.utc).isoformat(), r["kind"], r["device_id"],
                        r["device_name"], "" if r["charge"] is None else f"{r['charge']:.1f}",
                        r["cycles"] or "", r["full_mah"] or "", r["design_mah"] or "", health,
                        "" if r["temp"] is None else f"{r['temp']:.1f}"])
        return buf.getvalue()


# ---------------------------------------------------------------- secrets


def secret_get(account: str) -> str | None:
    """libsecret (GNOME Keyring / KeePassXC…) through secret-tool; a 0600 file as fallback."""
    if shutil.which("secret-tool"):
        r = subprocess.run(["secret-tool", "lookup", "service", "PapayaPower", "account", account],
                           capture_output=True, text=True, timeout=10)
        if r.returncode == 0 and r.stdout:
            return r.stdout.rstrip("\n")
    f = CONFIG / f".{account}.secret"
    try:
        return f.read_text().rstrip("\n") or None
    except OSError:
        return None


def secret_set(account: str, value: str) -> None:
    if shutil.which("secret-tool"):
        r = subprocess.run(["secret-tool", "store", "--label", f"PapayaPower {account}",
                            "service", "PapayaPower", "account", account],
                           input=value, text=True, capture_output=True, timeout=10)
        if r.returncode == 0:
            return
    CONFIG.mkdir(parents=True, exist_ok=True)
    f = CONFIG / f".{account}.secret"
    fd = os.open(f, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as fh:
        fh.write(value)
