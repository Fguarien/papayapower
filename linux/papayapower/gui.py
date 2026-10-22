"""PapayaPower window — GTK 4 + libadwaita (≥ 1.5)."""
from __future__ import annotations

import math
import subprocess
import sys
import tempfile
import threading
import time
from datetime import datetime

import gi

gi.require_version("Gtk", "4.0")
gi.require_version("Adw", "1")
from gi.repository import Adw, Gio, GLib, Gtk  # noqa: E402

from . import __version__, cli, core, report, store  # noqa: E402

ORANGE = (0.95, 0.55, 0.15)
GREEN = (0.20, 0.70, 0.35)
RED = (0.88, 0.22, 0.20)
AMBER = (0.96, 0.62, 0.10)
GREY = (0.6, 0.6, 0.6)


def _rgb_charge(c):
    if c is None:
        return GREY
    return RED if c < 15 else AMBER if c < 30 else GREEN


def _rgb_health(h):
    if h is None:
        return GREY
    # Same scale as macOS: green only above 95 % (as good as new).
    return RED if h < 0.6 else AMBER if h < 0.8 else ORANGE if h <= 0.95 else GREEN


class Gauge(Gtk.DrawingArea):
    """Ring gauge with the value in the middle."""

    def __init__(self, title: str):
        super().__init__()
        self.value = None
        self.color = GREY
        self.set_content_width(160)
        self.set_content_height(160)
        self.set_draw_func(self._draw)
        self.title = title

    def set(self, value, color):
        self.value, self.color = value, color
        self.queue_draw()

    def _draw(self, area, cr, w, h):
        cx, cy, r = w / 2, h / 2, min(w, h) / 2 - 12
        fg = area.get_color()
        cr.set_line_width(14)
        cr.set_source_rgba(fg.red, fg.green, fg.blue, 0.12)
        cr.arc(cx, cy, r, 0, 2 * math.pi)
        cr.stroke()
        if self.value is not None:
            cr.set_source_rgb(*self.color)
            cr.set_line_cap(1)  # round
            cr.arc(cx, cy, r, -math.pi / 2, -math.pi / 2 + 2 * math.pi * max(0.0, min(1.0, self.value)))
            cr.stroke()
        txt = f"{self.value * 100:.1f} %" if self.value is not None else "—"
        cr.set_source_rgba(fg.red, fg.green, fg.blue, 1)
        cr.select_font_face("sans-serif", 0, 1)
        cr.set_font_size(24)
        ext = cr.text_extents(txt)
        cr.move_to(cx - ext.width / 2 - ext.x_bearing, cy - ext.height / 2 - ext.y_bearing)
        cr.show_text(txt)


class Chart(Gtk.DrawingArea):
    """Line chart of (timestamp, value) points."""

    def __init__(self):
        super().__init__()
        self.points: list[tuple[float, float]] = []
        self.set_content_height(200)
        self.set_hexpand(True)
        self.set_draw_func(self._draw)

    def set(self, points):
        self.points = sorted(points)
        self.queue_draw()

    def _draw(self, area, cr, w, h):
        fg = area.get_color()
        pad_l, pad_r, pad_t, pad_b = 48, 16, 12, 24
        cr.select_font_face("sans-serif", 0, 0)
        cr.set_font_size(10)
        if len(self.points) < 2:
            cr.set_source_rgba(fg.red, fg.green, fg.blue, 0.6)
            cr.move_to(pad_l, h / 2)
            cr.show_text("At least two readings are needed for a chart.")
            return
        xs = [p[0] for p in self.points]
        ys = [p[1] for p in self.points]
        x0, x1 = min(xs), max(xs)
        y0, y1 = min(ys), max(ys)
        if y1 - y0 < 1e-9:
            y0, y1 = y0 - 1, y1 + 1
        span = y1 - y0
        y0, y1 = y0 - span * 0.1, y1 + span * 0.1

        def px(x):
            return pad_l + (x - x0) / (x1 - x0 or 1) * (w - pad_l - pad_r)

        def py(y):
            return pad_t + (1 - (y - y0) / (y1 - y0)) * (h - pad_t - pad_b)

        cr.set_line_width(1)
        for i in range(5):
            yv = y0 + (y1 - y0) * i / 4
            cr.set_source_rgba(fg.red, fg.green, fg.blue, 0.10)
            cr.move_to(pad_l, py(yv)); cr.line_to(w - pad_r, py(yv)); cr.stroke()
            cr.set_source_rgba(fg.red, fg.green, fg.blue, 0.6)
            cr.move_to(4, py(yv) + 3); cr.show_text(f"{yv:.1f}")
        for xv in (x0, x1):
            label = datetime.fromtimestamp(xv).strftime("%d/%m/%y")
            ext = cr.text_extents(label)
            cr.move_to(min(max(px(xv) - ext.width / 2, pad_l), w - pad_r - ext.width), h - 6)
            cr.show_text(label)
        cr.set_source_rgb(*ORANGE)
        cr.set_line_width(2)
        cr.move_to(px(xs[0]), py(ys[0]))
        for x, y in self.points[1:]:
            cr.line_to(px(x), py(y))
        cr.stroke()
        for x, y in self.points:
            cr.arc(px(x), py(y), 2.5, 0, 2 * math.pi)
            cr.fill()


def _row(title: str, value) -> Adw.ActionRow | None:
    if value in (None, ""):
        return None
    r = Adw.ActionRow(title=title)
    lbl = Gtk.Label(label=str(value), selectable=True, xalign=1)
    lbl.add_css_class("dim-label")
    r.add_suffix(lbl)
    return r


def _group(title: str, rows) -> Adw.PreferencesGroup:
    g = Adw.PreferencesGroup(title=title)
    for r in rows:
        if r is not None:
            g.add(r)
    return g


class DevicePage(Gtk.Box):
    """Overview / Lifetime / Advanced of one battery or UPS."""

    def __init__(self, win: "Window"):
        super().__init__(orientation=Gtk.Orientation.VERTICAL)
        self.win = win
        self.stack = Adw.ViewStack()
        switcher = Adw.ViewSwitcher(stack=self.stack, policy=Adw.ViewSwitcherPolicy.WIDE)
        switcher.set_halign(Gtk.Align.CENTER)
        switcher.set_margin_top(8)
        self.append(switcher)
        self.append(self.stack)
        self.stack.set_vexpand(True)

        self.overview = Adw.PreferencesPage()
        self.g1, self.g2 = Gauge("Current charge"), Gauge("Battery health")
        gauges = Gtk.Box(spacing=48, halign=Gtk.Align.CENTER, margin_top=12)
        for g, cap in ((self.g1, "Current charge"), (self.g2, "Battery health")):
            col = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4)
            col.append(g)
            t = Gtk.Label(label=cap)
            t.add_css_class("heading")
            col.append(t)
            sub = Gtk.Label()
            sub.add_css_class("caption")
            sub.add_css_class("dim-label")
            col.append(sub)
            g.caption = sub
            gauges.append(col)
        self.gauges_group = Adw.PreferencesGroup()
        self.gauges_group.add(gauges)
        self.overview.add(self.gauges_group)
        self.detail_groups: list[Adw.PreferencesGroup] = []
        self.stack.add_titled_with_icon(self.overview, "overview", "Overview", "battery-good-symbolic")

        self.lifetime = Adw.PreferencesPage()
        self.lifetime_groups: list = []
        self.stack.add_titled_with_icon(self.lifetime, "lifetime", "Lifetime", "document-open-recent-symbolic")

        adv = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6, margin_start=12, margin_end=12, margin_bottom=12)
        self.filter = Gtk.SearchEntry(placeholder_text="Filter keys")
        self.filter.connect("search-changed", lambda *_: self._fill_raw())
        adv.append(self.filter)
        self.raw_list = Gtk.ListBox(selection_mode=Gtk.SelectionMode.NONE)
        self.raw_list.add_css_class("boxed-list")
        sc = Gtk.ScrolledWindow(vexpand=True)
        sc.set_child(self.raw_list)
        adv.append(sc)
        self.stack.add_titled_with_icon(adv, "advanced", "Advanced", "utilities-terminal-symbolic")
        self.raw: dict[str, str] = {}

    def _clear(self, page, groups):
        for g in groups:
            page.remove(g)
        groups.clear()

    def _fill_raw(self):
        while (c := self.raw_list.get_first_child()) is not None:
            self.raw_list.remove(c)
        q = self.filter.get_text().lower()
        for k, v in sorted(self.raw.items()):
            if q and q not in k.lower() and q not in v.lower():
                continue
            r = Adw.ActionRow(title=k, subtitle=v, subtitle_selectable=True)
            r.add_css_class("property")
            self.raw_list.append(r)

    def show_battery(self, b: core.Battery):
        self.g1.set(b.charge_percent / 100 if b.charge_percent is not None else None, _rgb_charge(b.charge_percent))
        self.g2.set(b.health, _rgb_health(b.health))
        self.g1.caption.set_label(f"{b.current_capacity} of {b.full_charge_capacity} mAh"
                                  if b.current_capacity is not None and b.full_charge_capacity else
                                  ("Charging" if b.is_charging else ""))
        self.g2.caption.set_label(f"{b.full_charge_capacity} of {b.design_capacity} mAh design"
                                  + (" — unreliable" if b.gauge_warning else "")
                                  if b.full_charge_capacity and b.design_capacity else "Not reported")
        self._clear(self.overview, self.detail_groups)
        if b.gauge_warning:
            warn = Adw.PreferencesGroup()
            row = Adw.ActionRow(title="Gauge out of calibration", subtitle=b.gauge_warning)
            row.add_prefix(Gtk.Image.new_from_icon_name("dialog-warning-symbolic"))
            row.add_css_class("warning")
            warn.add(row)
            self.overview.add(warn)
            self.detail_groups.append(warn)
        status = ", ".join(x for x in (
            "on power adapter" if b.external_connected else "on battery" if b.external_connected is False else None,
            "charging" if b.is_charging else None, "fully charged" if b.fully_charged else None) if x)
        t_label, t_val = ("Time to full", b.time_to_full) if b.is_charging else ("Time to empty", b.time_to_empty)
        g = _group("Battery", [
            _row("Charge cycles", b.cycle_count),
            _row("Temperature", f"{b.temperature:.1f} °C" if b.temperature is not None else None),
            _row("Battery power", f"{b.power_watts:+.1f} W" if b.power_watts is not None else None),
            _row("Voltage", f"{b.voltage / 1000:.2f} V" if b.voltage else None),
            _row(t_label, core.fmt_minutes(t_val) if t_val else None),
            _row("Status", status.capitalize() if status else None),
        ])
        g2 = _group("Identity", [
            _row("Manufacturer", b.battery_manufacturer), _row("Model", b.battery_model),
            _row("Chemistry", b.technology), _row("Battery serial", b.battery_serial),
            _row("Device", b.model), _row("System", b.os_version), _row("Device serial", b.device_serial),
        ])
        for grp in (g, g2):
            self.overview.add(grp)
            self.detail_groups.append(grp)

        self._clear(self.lifetime, self.lifetime_groups)
        lt = b.lifetime
        if lt:
            grp = _group("Recorded by the gas gauge since manufacture", [
                _row("Temperature min / avg / max", " / ".join(
                    f"{x:.1f}" if x is not None else "—"
                    for x in (lt.minimum_temperature, lt.average_temperature, lt.maximum_temperature)) + " °C"),
                _row("Pack voltage min / max", f"{(lt.minimum_pack_voltage or 0) / 1000:.2f} / {(lt.maximum_pack_voltage or 0) / 1000:.2f} V"
                     if lt.maximum_pack_voltage else None),
                _row("Max charge current", f"{lt.maximum_charge_current} mA" if lt.maximum_charge_current else None),
                _row("Max discharge current", f"{lt.maximum_discharge_current} mA" if lt.maximum_discharge_current else None),
                _row("Operating time", f"{lt.total_operating_time} h ({lt.total_operating_time / 24:.0f} days)"
                     if lt.total_operating_time else None),
            ])
        else:
            grp = Adw.PreferencesGroup(title="No lifetime data",
                                       description="Linux batteries rarely expose lifetime statistics; iPhones and iPads do.")
        self.lifetime.add(grp)
        self.lifetime_groups.append(grp)
        self.raw = b.raw
        self._fill_raw()

    def show_ups(self, u: core.UPS):
        self.g1.set(u.charge_percent / 100 if u.charge_percent is not None else None,
                    AMBER if u.on_battery else GREEN)
        self.g1.caption.set_label("On battery" if u.on_battery else "On mains")
        self.g2.set(u.load_percent / 100 if u.load_percent is not None else None,
                    RED if (u.load_percent or 0) > 80 else (0.2, 0.5, 0.9))
        self.g2.caption.set_label("Load")
        self._clear(self.overview, self.detail_groups)
        words = {"OL": "on line", "OB": "on battery", "LB": "low battery", "RB": "replace battery",
                 "CHRG": "charging", "DISCHRG": "discharging", "OVER": "overloaded", "FSD": "forced shutdown"}
        st = ", ".join(words.get(x, x) for x in (u.status or "").split())
        g = _group("UPS", [
            _row("Status", st.capitalize() if st else None),
            _row("Runtime", core.fmt_minutes(u.runtime_seconds // 60) if u.runtime_seconds else None),
            _row("Input voltage", f"{u.input_voltage:.0f} V" if u.input_voltage else None),
            _row("Output voltage", f"{u.output_voltage:.0f} V" if u.output_voltage else None),
            _row("Battery voltage", f"{u.battery_voltage:.1f} V" if u.battery_voltage else None),
            _row("Battery date", u.battery_date), _row("Manufacturer", u.manufacturer),
            _row("Model", u.model), _row("Serial", u.serial), _row("Source", u.source),
        ])
        self.overview.add(g)
        self.detail_groups.append(g)
        self._clear(self.lifetime, self.lifetime_groups)
        grp = Adw.PreferencesGroup(title="No lifetime data for a UPS")
        self.lifetime.add(grp)
        self.lifetime_groups.append(grp)
        self.raw = u.raw
        self._fill_raw()


class HistoryPage(Gtk.Box):
    METRICS = [("Health", lambda r: r["full_mah"] / r["design_mah"] * 100 if r["full_mah"] and r["design_mah"] else None),
               ("Full charge (mAh)", lambda r: r["full_mah"]),
               ("Cycles", lambda r: r["cycles"]),
               ("Temperature", lambda r: r["temp"])]

    def __init__(self, win: "Window"):
        super().__init__(orientation=Gtk.Orientation.VERTICAL, spacing=8,
                         margin_start=12, margin_end=12, margin_top=12, margin_bottom=12)
        self.win = win
        bar = Gtk.Box(spacing=8)
        self.device = Gtk.DropDown()
        self.device.connect("notify::selected", lambda *_: self.reload())
        bar.append(self.device)
        self.metric = Gtk.DropDown.new_from_strings([m[0] for m in self.METRICS])
        self.metric.connect("notify::selected", lambda *_: self.reload())
        bar.append(self.metric)
        spacer = Gtk.Box(hexpand=True)
        bar.append(spacer)
        exp = Gtk.Button(icon_name="document-save-symbolic", tooltip_text="Export CSV")
        exp.connect("clicked", self.export)
        bar.append(exp)
        dele = Gtk.Button(icon_name="user-trash-symbolic", tooltip_text="Delete this device's history")
        dele.connect("clicked", self.delete)
        bar.append(dele)
        self.append(bar)
        self.chart = Chart()
        self.append(self.chart)
        self.list = Gtk.ListBox(selection_mode=Gtk.SelectionMode.NONE)
        self.list.add_css_class("boxed-list")
        sc = Gtk.ScrolledWindow(vexpand=True)
        sc.set_child(self.list)
        self.append(sc)
        self.devices: list[tuple[str, str, str]] = []

    def refresh_devices(self):
        self.devices = self.win.history.devices()
        names = Gtk.StringList.new([d[1] for d in self.devices] or ["No history yet"])
        self.device.set_model(names)
        self.reload()

    def current(self):
        i = self.device.get_selected()
        return self.devices[i][0] if 0 <= i < len(self.devices) else None

    def reload(self):
        while (c := self.list.get_first_child()) is not None:
            self.list.remove(c)
        dev = self.current()
        if not dev:
            self.chart.set([])
            return
        rows = self.win.history.entries(dev)
        f = self.METRICS[self.metric.get_selected()][1]
        self.chart.set([(r["ts"], f(r)) for r in rows if f(r) is not None])
        for r in rows[:500]:
            health = f"{r['full_mah'] / r['design_mah'] * 100:.1f} %" if r["full_mah"] and r["design_mah"] else "—"
            sub = " · ".join(x for x in (
                f"charge {r['charge']:.0f} %" if r["charge"] is not None else None,
                f"{r['full_mah']} / {r['design_mah']} mAh" if r["full_mah"] else None,
                f"{r['cycles']} cycles" if r["cycles"] is not None else None,
                f"{r['temp']:.1f} °C" if r["temp"] is not None else None) if x)
            self.list.append(Adw.ActionRow(title=f"{datetime.fromtimestamp(r['ts']):%d/%m/%Y %H:%M} — health {health}",
                                           subtitle=sub))

    def export(self, *_):
        dev = self.current()
        dlg = Gtk.FileDialog(initial_name="papayapower-history.csv")

        def done(d, res):
            try:
                f = d.save_finish(res)
            except GLib.Error:
                return
            f.replace_contents(self.win.history.csv(dev).encode(), None, False, Gio.FileCreateFlags.NONE, None)

        dlg.save(self.win, None, done)

    def delete(self, *_):
        dev = self.current()
        if not dev:
            return
        d = Adw.AlertDialog(heading="Delete the whole history of this device?", body="This cannot be undone.")
        d.add_response("cancel", "Cancel")
        d.add_response("delete", "Delete")
        d.set_response_appearance("delete", Adw.ResponseAppearance.DESTRUCTIVE)

        def resp(_d, r):
            if r == "delete":
                self.win.history.delete_device(dev)
                self.refresh_devices()

        d.connect("response", resp)
        d.present(self.win)


class Window(Adw.ApplicationWindow):
    def __init__(self, app):
        super().__init__(application=app, title="PapayaPower", default_width=900, default_height=640)
        self.settings = store.load_settings()
        self.history = store.History()
        self.batteries: list[core.Battery] = []
        self.ups: list[core.UPS] = []
        self.errors: list[str] = []
        self.selected = ("battery", 0)
        self._busy = False

        split = Adw.NavigationSplitView()
        self.sidebar = Gtk.ListBox(selection_mode=Gtk.SelectionMode.SINGLE)
        self.sidebar.add_css_class("navigation-sidebar")
        self.sidebar.connect("row-selected", self.on_select)
        side_tb = Adw.ToolbarView()
        side_head = Adw.HeaderBar()
        menu = Gio.Menu()
        menu.append("Save Reading to History", "win.save")
        menu.append("Print / Export Report", "win.report")
        menu.append("Preferences", "win.prefs")
        menu.append("Help", "win.help")
        menu.append("About PapayaPower", "win.about")
        side_head.pack_end(Gtk.MenuButton(icon_name="open-menu-symbolic", menu_model=menu))
        side_tb.add_top_bar(side_head)
        sc = Gtk.ScrolledWindow(vexpand=True)
        sc.set_child(self.sidebar)
        side_tb.set_content(sc)
        split.set_sidebar(Adw.NavigationPage(title="PapayaPower", child=side_tb))

        self.content_tb = Adw.ToolbarView()
        head = Adw.HeaderBar()
        self.title = Adw.WindowTitle(title="PapayaPower")
        head.set_title_widget(self.title)
        refresh = Gtk.Button(icon_name="view-refresh-symbolic", tooltip_text="Refresh (iPhone/iPad too)")
        refresh.connect("clicked", lambda *_: self.refresh(ios=True))
        head.pack_end(refresh)
        self.spinner = Gtk.Spinner()
        head.pack_end(self.spinner)
        self.content_tb.add_top_bar(head)
        self.page = DevicePage(self)
        self.hist = HistoryPage(self)
        self.empty = Adw.StatusPage(icon_name="battery-missing-symbolic", title="No battery",
                                    description="This computer has no battery. Plug a UPS in, add a NUT server in "
                                                "Preferences, or connect an iPhone.")
        self.content_tb.set_content(self.empty)
        split.set_content(Adw.NavigationPage(title="Details", child=self.content_tb))
        self.set_content(split)

        for name, cb in (("save", self.save_now), ("report", self.export_report), ("prefs", self.prefs),
                         ("help", self.help), ("about", self.about)):
            a = Gio.SimpleAction.new(name, None)
            a.connect("activate", cb)
            self.add_action(a)

        self.refresh(ios=self.settings.get("ios_enabled"))
        GLib.timeout_add_seconds(max(2, int(self.settings.get("refresh_seconds", 10))), self._tick)
        GLib.timeout_add_seconds(120, lambda: (self.refresh(ios=self.settings.get("ios_enabled")), True)[1])

    def _tick(self):
        self.refresh(ios=False)
        return True

    def refresh(self, ios: bool = False):
        if self._busy:
            return
        self._busy = True
        if ios:
            self.spinner.start()
        prev_ios = [b for b in self.batteries if b.kind == "ios"]

        def work():
            batteries, ups, errors = cli.gather(self.settings, ios, [])
            if not ios:
                batteries += prev_ios
            GLib.idle_add(self._apply, batteries, ups, errors)

        threading.Thread(target=work, daemon=True).start()

    def _apply(self, batteries, ups, errors):
        self._busy = False
        self.spinner.stop()
        self.batteries, self.ups, self.errors = batteries, ups, errors
        for b in batteries:
            if b.kind != "peripheral":
                self.history.auto_save(b, self.settings.get("auto_save", "daily"))
        self._rebuild_sidebar()
        return False

    def _rebuild_sidebar(self):
        keep = self.selected
        self.sidebar.disconnect_by_func(self.on_select)
        while (c := self.sidebar.get_first_child()) is not None:
            self.sidebar.remove(c)
        self.rows = []

        def add(kind, idx, icon, title, sub):
            row = Adw.ActionRow(title=title, subtitle=sub)
            row.add_prefix(Gtk.Image(icon_name=icon))
            self.sidebar.append(row)
            self.rows.append((kind, idx))

        def header(text):
            lbl = Gtk.Label(label=text, xalign=0, margin_top=10, margin_start=8)
            lbl.add_css_class("caption-heading")
            lbl.add_css_class("dim-label")
            r = Gtk.ListBoxRow(child=lbl, selectable=False, activatable=False)
            self.sidebar.append(r)
            self.rows.append(("header", -1))

        icons = {"laptop": "computer-symbolic", "ios": "phone-symbolic", "peripheral": "input-mouse-symbolic"}
        if self.batteries:
            header("Batteries")
        for i, b in enumerate(self.batteries):
            add("battery", i, icons.get(b.kind, "battery-symbolic"), b.device_name,
                f"{b.charge_percent:.0f} %" if b.charge_percent is not None else "")
        if self.ups:
            header("UPS")
        for i, u in enumerate(self.ups):
            add("ups", i, "battery-caution-symbolic" if u.on_battery else "ac-adapter-symbolic", u.name,
                f"{u.charge_percent:.0f} %" if u.charge_percent is not None else u.source)
        header("History")
        add("history", 0, "document-open-recent-symbolic", "History", "Saved readings")
        if self.errors:
            lbl = Gtk.Label(label="\n".join(self.errors), wrap=True, xalign=0, margin_start=8, margin_end=8)
            lbl.add_css_class("caption")
            lbl.add_css_class("warning")
            self.sidebar.append(Gtk.ListBoxRow(child=lbl, selectable=False, activatable=False))
            self.rows.append(("header", -1))
        self.sidebar.connect("row-selected", self.on_select)
        target = keep if keep in self.rows else next((r for r in self.rows if r[0] != "header"), None)
        if target:
            self.sidebar.select_row(self.sidebar.get_row_at_index(self.rows.index(target)))
        else:
            self.content_tb.set_content(self.empty)

    def on_select(self, _lb, row):
        if row is None:
            return
        kind, idx = self.rows[row.get_index()]
        if kind == "header":
            return
        self.selected = (kind, idx)
        if kind == "battery":
            b = self.batteries[idx]
            self.title.set_title(b.device_name)
            self.title.set_subtitle(" · ".join(x for x in (b.model, b.os_version) if x))
            self.page.show_battery(b)
            self.content_tb.set_content(self.page)
        elif kind == "ups":
            u = self.ups[idx]
            self.title.set_title(u.name)
            self.title.set_subtitle(u.source)
            self.page.show_ups(u)
            self.content_tb.set_content(self.page)
        else:
            self.title.set_title("History")
            self.title.set_subtitle("")
            self.hist.refresh_devices()
            self.content_tb.set_content(self.hist)

    def _current_battery(self):
        kind, idx = self.selected
        if kind == "battery" and idx < len(self.batteries):
            return self.batteries[idx]
        return next((b for b in self.batteries if b.kind == "laptop"), None)

    def save_now(self, *_):
        b = self._current_battery()
        if b:
            self.history.save(b)
            self.add_toast(f"Saved a reading of {b.device_name}")

    def add_toast(self, text):
        # No ToastOverlay at the root (keeps the layout simple): use a notification.
        cli.notify("PapayaPower", text)

    def export_report(self, *_):
        b = self._current_battery()
        if not b:
            return
        key = "ios_template" if b.kind == "ios" else "mac_template"
        html = report.render(report.template(b.kind, self.settings.get(key, "")), report.variables(b))
        f = tempfile.NamedTemporaryFile("w", suffix=".html", prefix="papayapower-report-", delete=False)
        f.write(html)
        f.close()
        Gtk.FileLauncher.new(Gio.File.new_for_path(f.name)).launch(self, None, None)

    def help(self, *_):
        """docs/HELP.md (copied next to the package by install.sh), rendered as Pango markup."""
        import re
        from pathlib import Path
        here = Path(__file__).resolve().parent
        src = next((p for p in (here / "HELP.md", here.parent.parent / "docs" / "HELP.md") if p.exists()), None)
        text = src.read_text() if src else "Help file missing: see https://github.com/Fguarien/papayapower/blob/main/docs/HELP.md"
        out = []
        for line in text.splitlines():
            esc = GLib.markup_escape_text(line.strip())
            esc = re.sub(r"\*\*(.+?)\*\*", r"<b>\1</b>", esc)
            esc = re.sub(r"`(.+?)`", r"<tt>\1</tt>", esc)
            if esc.startswith("# "):
                out.append(f'<span size="x-large" weight="bold">{esc[2:]}</span>')
            elif esc.startswith("## "):
                out.append(f'\n<span size="large" weight="bold">{esc[3:]}</span>')
            elif esc.startswith("- "):
                out.append("  •  " + esc[2:])
            elif esc:
                out.append(esc)
        label = Gtk.Label(use_markup=True, wrap=True, xalign=0, selectable=True,
                          margin_top=18, margin_bottom=18, margin_start=24, margin_end=24)
        label.set_markup("\n".join(out))
        sc = Gtk.ScrolledWindow(vexpand=True)
        sc.set_child(label)
        tb = Adw.ToolbarView()
        tb.add_top_bar(Adw.HeaderBar())
        tb.set_content(sc)
        Adw.Window(title="PapayaPower Help", default_width=720, default_height=640,
                   content=tb, transient_for=self).present()

    def about(self, *_):
        Adw.AboutDialog(application_name="PapayaPower", version=__version__, developer_name="Frédéric Guariento",
                        license_type=Gtk.License.MIT_X11, website="https://github.com/Fguarien/papayapower",
                        comments="Battery health for laptops, iPhones, iPads and UPS units.",
                        application_icon="papayapower").present(self)

    def prefs(self, *_):
        s = self.settings
        dlg = Adw.PreferencesDialog(title="Preferences")
        page = Adw.PreferencesPage(title="General", icon_name="preferences-system-symbolic")
        dlg.add(page)

        def switch(group, key, title, subtitle=""):
            r = Adw.SwitchRow(title=title, subtitle=subtitle, active=bool(s.get(key)))
            r.connect("notify::active", lambda w, _p: s.__setitem__(key, w.get_active()))
            group.add(r)

        def spin(group, key, title, lo, hi, step, subtitle=""):
            r = Adw.SpinRow.new_with_range(lo, hi, step)
            r.set_title(title)
            r.set_subtitle(subtitle)
            r.set_value(int(s.get(key) or 0))
            r.connect("notify::value", lambda w, _p: s.__setitem__(key, int(w.get_value())))
            group.add(r)

        def entry(group, key, title):
            r = Adw.EntryRow(title=title, text=str(s.get(key) or ""))
            r.connect("changed", lambda w: s.__setitem__(key, w.get_text()))
            group.add(r)

        def combo(group, key, title, values, labels):
            r = Adw.ComboRow(title=title, model=Gtk.StringList.new(labels))
            r.set_selected(values.index(s.get(key)) if s.get(key) in values else 0)
            r.connect("notify::selected", lambda w, _p: s.__setitem__(key, values[w.get_selected()]))
            group.add(r)

        g = Adw.PreferencesGroup(title="Devices")
        switch(g, "ios_enabled", "Look for iPhone and iPad", "Needs libimobiledevice and usbmuxd; trust the computer once over USB")
        spin(g, "refresh_seconds", "Refresh every (s)", 2, 120, 1)
        combo(g, "waybar_format", "Waybar shows", ["percent", "time", "watts", "health"],
              ["Charge (%)", "Time remaining", "Battery power (W)", "Battery health (%)"])
        page.add(g)
        g = Adw.PreferencesGroup(title="History")
        combo(g, "auto_save", "Save readings automatically", ["off", "daily", "weekly"], ["Never", "Once a day", "Once a week"])
        page.add(g)
        g = Adw.PreferencesGroup(title="Notifications", description="Each alert fires once per crossing.")
        switch(g, "notify_enabled", "Send notifications")
        spin(g, "notify_percent", "Laptop battery below (%)", 0, 95, 5)
        spin(g, "notify_ios_percent", "iPhone / iPad below (%) — 0 = off", 0, 95, 5)
        switch(g, "notify_ups", "UPS on battery or low")
        page.add(g)

        page2 = Adw.PreferencesPage(title="UPS & monitoring", icon_name="network-server-symbolic")
        dlg.add(page2)
        g = Adw.PreferencesGroup(title="UPS", description="A USB UPS is read through UPower. NUT servers are read directly (read-only).")
        entry(g, "nut_hosts", "NUT servers (host[:port], comma-separated)")
        page2.add(g)
        g = Adw.PreferencesGroup(title="Prometheus Pushgateway", description="Metrics papaya_battery_* and papaya_ups_*.")
        switch(g, "push_enabled", "Publish metrics")
        entry(g, "push_url", "URL")
        entry(g, "push_user", "User")
        pw = Adw.PasswordEntryRow(title="Password (kept in the Secret Service)")
        pw.set_text(store.secret_get("pushgateway") or "")
        g.add(pw)
        page2.add(g)

        page3 = Adw.PreferencesPage(title="Printing", icon_name="printer-symbolic")
        dlg.add(page3)
        g = Adw.PreferencesGroup(title="Report templates",
                                 description="HTML with $MAC_BATTERY_HEALTH_PERCENT, $IOS_BATTERY_CYCLECOUNT, $REPORT_CREATION… Empty = built-in.")
        entry(g, "mac_template", "Computer report template (path)")
        entry(g, "ios_template", "iPhone / iPad report template (path)")
        page3.add(g)

        def closed(*_):
            store.save_settings(s)
            if pw.get_text():
                store.secret_set("pushgateway", pw.get_text())

        dlg.connect("closed", closed)
        dlg.present(self)


class App(Adw.Application):
    def __init__(self):
        super().__init__(application_id="eu.savethemall.papayapower", flags=Gio.ApplicationFlags.DEFAULT_FLAGS)

    def do_activate(self):
        win = self.props.active_window or Window(self)
        win.present()


def main() -> int:
    return App().run([sys.argv[0]])


if __name__ == "__main__":
    sys.exit(main())
