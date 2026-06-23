import os
import re
import time
import signal
import threading
import subprocess
from core.config import load_config, save_config, ensure_device_in_config, CONFIG_FILE
from core.adb_monitor import AdbMonitor
from core.network_monitor import NetworkMonitor
from core.phonescreen import PinnedMirror
import kdeconnect_notify


def adb_cmd(args, timeout=15, retries=2):
    """Run an adb command, surviving an adb-server crash. adb's server
    occasionally SIGSEGVs during USB plug/unplug churn; on failure we restart it
    and retry, so a single crash doesn't make us mis-read state (e.g. think
    tcpip is off and needlessly restart adbd)."""
    last = None
    for _ in range(retries + 1):
        try:
            last = subprocess.run(["adb"] + args, capture_output=True, text=True, timeout=timeout)
            if last.returncode == 0:
                return last
        except subprocess.TimeoutExpired:
            last = None
        try:
            subprocess.run(["adb", "start-server"], capture_output=True, timeout=timeout)
        except subprocess.TimeoutExpired:
            pass
        time.sleep(0.1)   # tiny buffer for the device transport to re-attach
    return last if last is not None else subprocess.CompletedProcess(["adb"] + args, 1, "", "")


def send_notification(title, message, icon="smartphone", urgency="normal"):
    try:
        subprocess.run([
            "notify-send",
            "-a", "Linux-Android-Daemon",
            "-i", icon,
            "-u", urgency,
            title,
            message
        ])
    except Exception as e:
        print(f"[Notify] Failed to send notification: {e}")

class PhoneWatcher:
    def __init__(self):
        self.config = load_config()
        self.last_config_mtime = os.path.getmtime(CONFIG_FILE) if os.path.exists(CONFIG_FILE) else 0
        self.adb_monitor = AdbMonitor(self.on_phone_connect, self.on_phone_disconnect)
        self.net_monitor = NetworkMonitor(self.on_network_change)

        # The desktop / popup "Phone Screen" pinned mirror is owned here (single
        # scrcpy authority) — the widget is just a thin client over request/status
        # tmpfs files. Ticked from the main loop below.
        self.pinned = PinnedMirror()

        # Mirror state
        self.scrcpy_procs = {}        # serial -> Popen we launched (best-effort)
        self.phone_ip = {}            # serial -> last known LAN IP (for WiFi fallback)
        self.mirror_seen = {}         # serial -> last monotonic time scrcpy was alive
                                      # (so an unplug that races scrcpy's exit still
                                      # follows the mirror onto WiFi)

        # Seed last-known IPs from config so a fresh daemon (e.g. after reboot)
        # already knows where to reach each phone over WiFi.
        for serial, dev in self.config.get("devices", {}).items():
            if dev.get("last_ip"):
                self.phone_ip[serial] = dev["last_ip"]

        # Tethering / network-failover state
        self.plugged = set()          # USB serials currently plugged in
        self.wifi_online = True       # does the PC have a real (non-phone) uplink?
        self.tether_active = False    # have we switched a phone into USB tethering?
        self.tether_phone = None      # serial of the phone we tethered through
        self.tether_lock = threading.Lock()

    def start(self):
        print("Starting Linux-Android-Daemon...")
        print("Waiting for a phone to be plugged in over USB.")
        self.wifi_online = self.net_monitor.has_real_uplink()
        print(f"[Net] Real uplink present at startup: {self.wifi_online}")
        self.adb_monitor.start()
        self.net_monitor.start()

        # Optional KDE Connect notification integration (click a phone
        # notification on the PC -> open scrcpy + expand the shade in the mirror)
        if self.config.get("defaults", {}).get("kdeconnect_notify", False):
            launcher = os.path.join(os.path.dirname(os.path.abspath(__file__)), "scrcpy_launch.py")
            kdeconnect_notify.start(launcher)

        # Main loop: a fast reconcile (window move/hide — instant reactions) plus the
        # slower lifecycle tick (scrcpy launch/keep-alive/lock, ~1s).
        last_tick = 0.0
        last_lock = 0.0
        while True:
            try:
                self.pinned.reconcile()
            except Exception as e:
                print(f"[phonescreen] reconcile error: {e}")
            now = time.monotonic()
            if now - last_lock >= 0.5:        # fast physical lock/unlock detection
                last_lock = now
                try:
                    self.pinned.poll_lock()
                except Exception as e:
                    print(f"[phonescreen] poll_lock error: {e}")
            if now - last_tick >= 1.0:
                last_tick = now
                try:
                    self.pinned.tick()
                except Exception as e:
                    print(f"[phonescreen] tick error: {e}")
                for serial in list(self.plugged):
                    if self._scrcpy_running(serial):
                        self.mirror_seen[serial] = now
            time.sleep(0.15)

    # ---- helpers ---------------------------------------------------------

    def _cfg_for(self, serial):
        """Effective config for a serial: defaults overlaid with its device entry."""
        cfg = dict(self.config.get("defaults", {}))
        cfg.update(self.config.get("devices", {}).get(serial, {}))
        return cfg

    def _reload_config_if_changed(self):
        if os.path.exists(CONFIG_FILE):
            current_mtime = os.path.getmtime(CONFIG_FILE)
            if current_mtime > self.last_config_mtime:
                self.config = load_config()
                self.last_config_mtime = current_mtime
                print("[Config] Reloaded changes from config.json")

    def _get_phone_ip(self, serial):
        """The phone's wlan0 IPv4, used to reconnect scrcpy over WiFi later."""
        try:
            out = subprocess.run(
                ["adb", "-s", serial, "shell", "ip", "-f", "inet", "addr", "show", "wlan0"],
                capture_output=True, text=True, timeout=10
            ).stdout
            m = re.search(r"inet (\d+\.\d+\.\d+\.\d+)", out)
            if m:
                return m.group(1)
        except Exception:
            pass
        return None

    def _scrcpy_pids(self, serial):
        """PIDs of the actual scrcpy *binary* targeting this phone (by serial or
        its LAN IP), regardless of who launched it. We deliberately do NOT match
        the `scrcpy_launch.py` wrapper: killing only the scrcpy binary lets the
        wrapper run its rotation-restore on exit. (Also excludes scrcpy's
        `adb shell ... scrcpy-server.jar` helper, which dies with the client.)"""
        patterns = [serial]
        ip = self.phone_ip.get(serial)
        if ip:
            patterns.append(ip)
        pids = []
        try:
            out = subprocess.run(["pgrep", "-af", "scrcpy"], capture_output=True, text=True).stdout
        except FileNotFoundError:
            return pids
        for line in out.splitlines():
            parts = line.split(None, 1)
            if len(parts) < 2:
                continue
            pid, cmd = parts
            if "scrcpy_launch.py" in cmd:
                continue  # the wrapper — leave it to restore rotation and exit
            if "--v4l2-sink" in cmd or "--video-source=camera" in cmd:
                continue  # the phone-camera webcam feed, NOT a screen mirror
            if "PhoneScreenPinned" in cmd:
                continue  # the desktop Phone Screen widget's mirror — it manages its
                          # own USB<->WiFi switching, so the daemon must not grab it
            is_client = re.search(r"(^|/|\s)scrcpy(\s|$)", cmd)
            if is_client and any(p in cmd for p in patterns):
                try:
                    pids.append(int(pid))
                except ValueError:
                    pass
        return pids

    def _scrcpy_running(self, serial):
        return bool(self._scrcpy_pids(serial))

    def _kill_scrcpy(self, serial):
        """Immediately SIGKILL every scrcpy session for this phone. No graceful
        SIGTERM-then-wait — we want the swap to a new transport to be instant.
        Returns True if any were running (so callers know to relaunch)."""
        pids = self._scrcpy_pids(serial)
        self.scrcpy_procs.pop(serial, None)
        if not pids:
            return False
        print(f"[scrcpy] Killing mirror for {serial} (pids {pids})")
        for pid in pids:
            try:
                os.kill(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        return True

    def _wait_until_ready(self, serial, timeout=20):
        """Block until the phone's USB transport is back and responsive.

        After `adb tcpip` or a USB-function switch the transport flaps; polling
        `adb shell true` confirms the device is genuinely ready before scrcpy.
        """
        time.sleep(1.5)
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            try:
                result = subprocess.run(
                    ["adb", "-s", serial, "shell", "true"],
                    capture_output=True, timeout=5
                )
                if result.returncode == 0:
                    return True
            except subprocess.TimeoutExpired:
                pass
            time.sleep(0.5)
        return False

    # ---- events ----------------------------------------------------------

    def on_phone_connect(self, serial, model):
        print(f"\n[Event] Phone Connected: {model or serial} ({serial})")
        self._reload_config_if_changed()

        if ensure_device_in_config(self.config, serial, model):
            save_config(self.config)
            self.last_config_mtime = os.path.getmtime(CONFIG_FILE)

        cfg = self.config["devices"][serial]
        name = cfg.get("name") or model or serial

        if not cfg.get("enabled", True):
            print(f"[Skip] {name} is disabled in config.json")
            return

        self.plugged.add(serial)
        notify = cfg.get("notify", False)
        if notify:
            send_notification("Phone Connected", f"{name} plugged in over USB", "smartphone")

        # Remember the LAN IP so we can move scrcpy to WiFi when unplugged, and
        # persist it to config so it survives a daemon/PC reboot.
        ip = self._get_phone_ip(serial)
        if ip:
            self.phone_ip[serial] = ip
            print(f"[Net] {name} LAN IP: {ip}")
            if self.config["devices"][serial].get("last_ip") != ip:
                self.config["devices"][serial]["last_ip"] = ip
                save_config(self.config)
                self.last_config_mtime = os.path.getmtime(CONFIG_FILE)
                print(f"[Config] Saved last_ip={ip} for {name}")

        # 1. Enable wireless ADB on this phone — but ONLY if it isn't already on.
        # Re-running `adb tcpip` restarts the phone's adbd, which tears down every
        # existing transport (including the WiFi one the camera daemon holds to
        # this same phone) and can SIGSEGV the adb server mid-churn — which kills
        # the scrcpy we're about to launch and breaks the next few adb calls. Ask
        # adbd directly over USB whether it's already in tcp mode (the
        # service.adb.tcp.port prop) and leave it alone if so.
        if cfg.get("enable_tcpip", True):
            port = str(cfg.get("tcpip_port", 5555))
            cur = adb_cmd(["-s", serial, "shell", "getprop", "service.adb.tcp.port"]).stdout.strip()
            if cur == port:
                print(f"[ADB] {name} already in tcp mode on {port} — skipping tcpip (avoids adb-server churn)")
            else:
                print(f"[ADB] Enabling wireless adb on {name} (port {port})")
                try:
                    subprocess.run(["adb", "-s", serial, "tcpip", port], timeout=15)
                except subprocess.TimeoutExpired:
                    print("[ADB] tcpip timed out, continuing anyway")
                if self._wait_until_ready(serial):
                    if notify:
                        send_notification("Wireless ADB Enabled", f"{name} is now reachable on port {port}", "network-wireless")
                else:
                    print("[ADB] device did not become ready in time after tcpip")

        # 2. We no longer auto-pop a scrcpy mirror on plug-in. The ONLY mirror is the
        # one a widget claims (the pinned manager owns it). If the Phone Screen widget
        # is pinning this phone, nudge its mirror onto the now-faster USB cable.
        if self.pinned.wants(serial):
            print(f"[scrcpy] {name} is pinned by the Phone Screen widget — nudging it onto USB")
            subprocess.run(["pkill", "-f", "PhoneScreenPinned"], capture_output=True)

        # 3. If there's no real uplink, fall back to this phone's USB tethering
        self.evaluate_tethering()

    def on_phone_disconnect(self, serial):
        cfg = self._cfg_for(serial)
        name = cfg.get("name") or serial
        print(f"\n[Event] Phone Disconnected: {name} ({serial})")

        self.plugged.discard(serial)
        if self.tether_phone == serial:
            self.tether_active = False
            self.tether_phone = None

        self.mirror_seen.pop(serial, None)
        # Only the pinned widget mirror exists now; it follows the phone onto WiFi on
        # its own. Anything else (a leftover) just gets cleaned up.
        if self.pinned.wants(serial):
            print(f"[scrcpy] {name} unplugged — pinned manager will move it to WiFi")
        else:
            self._kill_scrcpy(serial)

        self.evaluate_tethering()

    def on_network_change(self, online):
        print(f"\n[Net] Real uplink {'available' if online else 'lost'}")
        self.wifi_online = online
        self.evaluate_tethering()

    # ---- tethering -------------------------------------------------------

    def evaluate_tethering(self):
        """Keep exactly one uplink active: prefer wifi/ethernet, fall back to the
        phone's USB tethering only when no real uplink exists."""
        with self.tether_lock:
            self._reload_config_if_changed()

            candidate = None
            for serial in self.plugged:
                if self._cfg_for(serial).get("tether_failover", False):
                    candidate = serial
                    break

            want_tether = candidate is not None and not self.wifi_online

            if want_tether and not self.tether_active:
                func = self._cfg_for(candidate).get("tether_function", "rndis")
                print(f"[Tether] No real uplink — enabling USB tethering ({func}) via {candidate}")
                self._switch_usb_function(candidate, ["svc", "usb", "setFunctions", func])
                self.tether_active = True
                self.tether_phone = candidate

            elif not want_tether and self.tether_active:
                serial = self.tether_phone
                print(f"[Tether] Real uplink available — disabling USB tethering via {serial}")
                if serial in self.plugged:
                    self._switch_usb_function(serial, ["svc", "usb", "setFunctions"])
                self.tether_active = False
                self.tether_phone = None

    def _switch_usb_function(self, serial, svc_cmd):
        """Run an `svc usb setFunctions ...` switch. Because that re-enumerates
        the USB device and kills a USB-bound scrcpy, stop any running mirror
        first and bring it back (over USB) afterwards if it was up."""
        self._kill_scrcpy(serial)
        try:
            subprocess.run(["adb", "-s", serial] + ["shell"] + svc_cmd, timeout=15)
        except Exception as e:
            print(f"[Tether] usb function switch failed: {e}")

if __name__ == "__main__":
    watcher = PhoneWatcher()
    watcher.start()
