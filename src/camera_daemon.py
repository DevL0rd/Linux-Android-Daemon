#!/usr/bin/env python3
"""Phone-as-webcam daemon.

Owns the lifecycle of the phone-camera feed. It does *not* launch anything on
plug-in. Instead it watches the v4l2loopback "Phone Camera" sink and only brings
the feed up when something actually wants frames:

  * a real app (browser, OBS, Zoom, ...) opens the loopback device, or
  * the system-tray popup is open (it sends a `preview` heartbeat so you can
    frame/zoom with a live preview).

While a feed is live it:
  * rebuilds it (debounced) whenever the camera settings change, and
  * hot-swaps the transport USB<->WiFi the moment the cable is plugged or pulled,
    so an in-use webcam follows the faster link without dropping the consumer.

When nothing wants frames anymore it tears the feed down and disconnects.

A status snapshot is written to $XDG_RUNTIME_DIR/Linux-Android-Daemon/phonecam.json
for the plasmoid to read.
"""
import os
import sys
import json
import time
import signal
import threading
import subprocess

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))  # make `core` importable
from core import camera as cam

POLL = 0.5                 # main loop cadence (s)
PREVIEW_TTL = 4.0          # a preview heartbeat counts as "wants frames" for this long
SETTINGS_DEBOUNCE = 0.5    # wait this long after the last settings change before rebuilding
PROBE_TTL = 30.0           # honour a probe request newer than this
# A v4l2 consumer's device handle is often held by a short-lived child/thread
# that flickers in and out of `fuser`/`lsof` while streaming. Keep the feed up
# for this long after the last sighting so a single missed poll doesn't tear it
# down and freeze the consumer.
CONSUMER_GRACE = 5.0
# Settings that change the device SIZE / which camera. scrcpy is locked to these
# as they were when the device was last pinned — they can only change while the
# device is idle (so the stream size and the pin move together). Changing one
# while an app holds the device must NOT restart scrcpy at a size the device
# isn't pinned to (that's the permanent-green/no-video bug). zoom/fps/torch are
# free to change live.
GEOM_KEYS = ("resolution", "aspect_ratio", "rotation", "facing", "camera_id")


class CameraDaemon:
    def __init__(self):
        self.proc = None            # the running scrcpy feeder (subprocess.Popen)
        self.preview_proc = None     # the preview-JPEG ffmpeg (subprocess.Popen)
        self.cur_target = None       # transport target the feeder is using
        self.cur_transport = ""
        self.cur_sig = None          # settings signature the feeder was built from
        self.cur_serial = ""
        self.pending_at = 0.0        # debounce deadline for a settings rebuild
        self.gen = 0                 # incremented on every (re)start, for the UI preview
        self.start_time = 0.0        # when the current feeder was launched
        self.fail_count = 0          # consecutive feeds that died almost immediately
        self.backoff_until = 0.0     # don't relaunch before this (anti-thrash)
        self.pinned = None           # output size the loopback is pinned to
        self.pin_gen = 0             # bumped each time the pin actually changes
        self.geom = None             # geometry (size/rotation/lens) scrcpy is locked to
        self.last_pin_try = 0.0      # rate-limit set-caps attempts
        self.last_consumer_seen = 0.0  # last time a consumer was detected
        self.error = ""
        self.config_mtime = 0.0
        self.config = {}
        self.caps = cam.load_caps()
        self._probing = set()        # serials currently being capability-probed
        os.makedirs(cam.RUNTIME_DIR, exist_ok=True)

    # --- helpers ----------------------------------------------------------

    def _geom_of(self, settings):
        return {k: settings.get(k) for k in GEOM_KEYS}

    def _effective(self, settings):
        """Live settings, but with the size/lens geometry pinned to what the
        device currently is (self.geom). Keeps scrcpy's output size from ever
        getting ahead of the pin — geometry only moves at idle."""
        s = dict(settings)
        if self.geom:
            s.update(self.geom)
        return s

    def _reload_config(self):
        try:
            mtime = os.path.getmtime(cam.CONFIG_PATH)
        except OSError:
            mtime = 0.0
        if mtime != self.config_mtime or not self.config:
            self.config = cam.load_config()
            self.config_mtime = mtime
            return True
        return False

    def _feeder_alive(self):
        return self.proc is not None and self.proc.poll() is None

    def _feeder_pids(self):
        # scrcpy (producer) AND our own preview ffmpeg (consumer) are ours, not
        # real apps — exclude both from consumer detection.
        pids = set()
        if self._feeder_alive():
            pids.add(self.proc.pid)
        if self.preview_proc is not None and self.preview_proc.poll() is None:
            pids.add(self.preview_proc.pid)
        return pids

    def _preview_alive(self):
        return self.preview_proc is not None and self.preview_proc.poll() is None

    def _stop_preview(self):
        if self.preview_proc is None:
            return
        if self._preview_alive():
            try:
                self.preview_proc.terminate()
                try:
                    self.preview_proc.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    self.preview_proc.kill()
            except Exception:
                pass
        self.preview_proc = None

    def _manage_preview(self, devnode, preview_wanted, app_using, fps):
        """Run the preview JPEG ffmpeg while the applet wants it AND scrcpy is
        producing AND no real app holds the device. v4l2loopback only allows a
        single reader, so the preview must yield to an actual app (the applet
        shows an 'in use' overlay instead)."""
        want = preview_wanted and self._feeder_alive() and not app_using
        if want and not self._preview_alive():
            self.preview_proc = cam.start_preview_stream(devnode, fps)
        elif not want and self._preview_alive():
            self._stop_preview()

    def _preview_active(self):
        try:
            return (time.time() - os.path.getmtime(cam.PREVIEW_HEARTBEAT)) <= PREVIEW_TTL
        except OSError:
            return False

    def _stop(self, why=""):
        if self.proc is None:
            return
        if self._feeder_alive():
            print("[feed] stopping%s (pid %s)" % ((" — " + why) if why else "", self.proc.pid))
            try:
                self.proc.terminate()
                try:
                    self.proc.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    self.proc.kill()
            except Exception:
                pass
        self.proc = None
        self.cur_target = None
        self.cur_transport = ""
        self.cur_sig = None
        self.cur_serial = ""
        self.pending_at = 0.0

    def _start(self, serial, target, transport, settings, devnode, sig):
        if transport == "wifi":
            # Network transports need an explicit connect before scrcpy attaches.
            try:
                cam.adb(None, "connect", target, timeout=10)
            except Exception:
                pass
        command = cam.build_scrcpy_cmd(target, settings, devnode)
        self.gen += 1
        print("[feed] start gen=%d (%s over %s): %s" % (self.gen, serial, transport, " ".join(command)))
        try:
            self.proc = subprocess.Popen(command,
                                         stdout=subprocess.DEVNULL,
                                         stderr=subprocess.DEVNULL)
            self.error = ""
        except FileNotFoundError:
            self.error = "scrcpy not found"
            self.proc = None
            return
        self.cur_target = target
        self.cur_transport = transport
        self.cur_serial = serial
        self.cur_sig = sig
        self.pending_at = 0.0
        self.start_time = time.time()

    def _maybe_probe(self, serial, target):
        """Kick a one-shot capability probe for a phone we have no caps for. Runs
        in a thread so the main loop never blocks on scrcpy --list-cameras."""
        if not serial or not target or serial in self.caps or serial in self._probing:
            return
        self._probing.add(serial)

        def run():
            cams = cam.probe_cameras(target)
            if cams:
                self.caps[serial] = cams
                cam.save_caps(self.caps)
                print("[probe] %s -> %s" % (serial, cams))
            self._probing.discard(serial)

        threading.Thread(target=run, daemon=True).start()

    def _maybe_probe_sizes(self, target):
        """Probe the camera's supported sizes once (when reachable and idle) so
        the resolution+aspect controls snap to a real size instead of a made-up
        one. Runs in a thread; cached to tmpfs."""
        if not target or self._feeder_alive() or "sizes" in self._probing:
            return
        if cam.load_camera_sizes():
            return
        self._probing.add("sizes")

        def run():
            sizes = cam.probe_camera_sizes(target)
            if sizes:
                cam.save_camera_sizes(sizes)
                print("[probe] camera sizes cached: %s" % {k: len(v) for k, v in sizes.items()})
            self._probing.discard("sizes")

        threading.Thread(target=run, daemon=True).start()

    def _probe_requested(self):
        try:
            return (time.time() - os.path.getmtime(cam.PROBE_REQUEST)) <= PROBE_TTL
        except OSError:
            return False

    # --- status snapshot --------------------------------------------------

    def _write_status(self, devnode, settings, consumers, preview, serial, target, transport):
        usb_map = cam.usb_serials()
        devices = []
        seen = set()
        for s, d in self.config.get("devices", {}).items():
            seen.add(s)
            devices.append({
                "serial": s,
                "name": d.get("name") or s,
                "usb": s in usb_map,
                "last_ip": d.get("last_ip", ""),
                "config": dict(d),          # full per-device settings for the UI
            })
        for s, model in usb_map.items():
            if s not in seen:
                devices.append({"serial": s, "name": model or s, "usb": True,
                                "last_ip": "", "config": {}})

        active_name = ""
        for d in devices:
            if d["serial"] == serial:
                active_name = d["name"]
                break

        status = {
            "ts": time.time(),
            "loopback": devnode is not None,
            "devnode": devnode or "",
            "streaming": self._feeder_alive(),
            "gen": self.gen,
            "transport": transport if self._feeder_alive() else "",
            "target": target or "",
            "active_serial": serial,
            "active_name": active_name,
            "consumers": consumers,
            "preview": preview,
            "pinned": self.pinned or "",
            "pin_gen": self.pin_gen,
            "error": self.error,
            "settings": settings,
            "devices": devices,
            "defaults": dict(self.config.get("defaults", {})),
            "caps": self.caps,
        }
        try:
            tmp = cam.STATUS_PATH + ".tmp"
            with open(tmp, "w") as f:
                json.dump(status, f)
            os.replace(tmp, cam.STATUS_PATH)
        except OSError as e:
            print("[status] write failed: %s" % e)

    # --- main loop --------------------------------------------------------

    def run(self):
        print("Starting phone-camera daemon. Feed comes up only on demand.")
        while True:
            try:
                self._tick()
            except Exception as e:
                self.error = str(e)
                print("[loop] error: %s" % e)
            time.sleep(POLL)

    def _tick(self):
        self._reload_config()
        settings = cam.camera_settings(self.config)
        try:
            video_nr = int(settings.get("video_nr", 9))
        except (TypeError, ValueError):
            video_nr = 9
        devnode = cam.loopback_devnode(video_nr)

        if devnode is None:
            # No loopback -> nothing to feed. Make sure we're torn down and say so.
            self._stop("loopback gone")
            self.error = "v4l2loopback 'Phone Camera' device not found (run install.sh)"
            self._write_status(None, settings, [], self._preview_active(), "", None, "")
            return

        # Reap a feeder that died on its own (phone went away, scrcpy crashed).
        if self.proc is not None and not self._feeder_alive():
            ran = time.time() - self.start_time
            self.proc = None
            self.cur_sig = None
            self.cur_target = None
            self.cur_serial = ""
            # A feed that dies within a few seconds usually means the v4l2 sink
            # was busy or the format was rejected. Don't relaunch in a tight
            # loop (it overloads adb) — count rapid failures and back off.
            if ran < 5.0:
                self.fail_count += 1
                if self.fail_count >= 3:
                    self.backoff_until = time.time() + 15.0
                    self.error = "camera feed keeps exiting (device busy or unsupported format?)"
                    print("[feed] %d rapid failures — backing off 15s" % self.fail_count)
            else:
                self.fail_count = 0

        consumers = cam.device_consumers(devnode, exclude_pids=self._feeder_pids())
        preview = self._preview_active()
        now0 = time.time()
        # The applet's own preview (plasmashell) is tracked via the heartbeat,
        # NOT the grace window — so when it drops its preview to apply a size
        # change, the device can go idle and re-pin right away. Grace stays for
        # EXTERNAL apps (Discord) whose handle flickers in fuser while streaming.
        if [c for c in consumers if c.get("name") != "plasmashell"]:
            self.last_consumer_seen = now0
        recent_consumer = (now0 - self.last_consumer_seen) < CONSUMER_GRACE
        want = bool(consumers) or preview or recent_consumer

        usb_map = cam.usb_serials()
        serial = cam.pick_active_serial(settings, self.config, usb_map)
        target, transport = cam.resolve_target(serial, self.config, usb_map)

        self._maybe_probe_sizes(target)
        if self._probe_requested():
            self._maybe_probe(serial, target)

        # scrcpy is built from the LIVE settings, but with size/lens geometry
        # locked to what the device is actually pinned to (self.geom). So a size
        # change made while an app holds the device does NOT restart scrcpy at a
        # mismatched size — it stays put until the device is idle and both move
        # together.
        # Lock geometry on first use even if we never caught the device idle
        # (e.g. the daemon started while an app already held it) — otherwise a
        # later size change WOULD restart scrcpy mismatched and freeze the app.
        if self.geom is None and want and target:
            self.geom = self._geom_of(settings)
        eff = self._effective(settings)

        if want and target and time.time() < self.backoff_until:
            # In anti-thrash backoff: keep the error, don't relaunch yet.
            pass
        elif want and target:
            self.error = ""
            sig = cam.settings_signature(eff, devnode)
            if self.proc is None:
                self._start(serial, target, transport, eff, devnode, sig)
            elif serial != self.cur_serial or target != self.cur_target:
                # Cable plugged/pulled (or device switched): hot-swap now, no wait.
                print("[feed] transport/device change %s/%s -> %s/%s" %
                      (self.cur_serial, self.cur_transport, serial, transport))
                self._stop("transport swap")
                self._start(serial, target, transport, eff, devnode, sig)
            elif sig != self.cur_sig:
                # A LIVE setting changed (zoom/fps/torch). Geometry can't reach
                # here — it's locked in eff — so this never resizes the device.
                now = time.time()
                if self.pending_at == 0.0:
                    self.pending_at = now + SETTINGS_DEBOUNCE
                elif now >= self.pending_at:
                    self._stop("settings change")
                    self._start(serial, target, transport, eff, devnode, sig)
            else:
                self.pending_at = 0.0
        elif want and not target:
            self.error = "no reachable phone (plug in USB or connect over WiFi)"
            self._stop("phone unreachable")
        else:
            # Device idle → adopt the live geometry and re-pin to it. This is the
            # ONLY place the size/lens changes, so the pin and the stream always
            # move together.
            self._stop("no consumers")
            self._stop_preview()   # our preview ffmpeg also holds the device — free it before re-pin
            self.fail_count = 0
            self.backoff_until = 0.0
            live_geom = self._geom_of(settings)
            desired = cam.effective_output_size(settings)
            now = time.time()
            if not consumers and (now - self.last_pin_try) > 1.0:
                if self.pinned != desired:
                    self.last_pin_try = now
                    # Re-pin the format IN PLACE (set-caps). We do NOT delete and
                    # recreate the device: that only helped the (now-removed) live
                    # preview re-read the size, and it let consumers race in and
                    # grab MJPG on the fresh device, breaking the stream.
                    res = cam.pin_caps(devnode, settings)
                    if res:
                        self.pinned = res
                        self.geom = live_geom
                        self.pin_gen += 1
                        print("[caps] pinned %s -> YU12:%s (gen %d)" % (devnode, res, self.pin_gen))
                elif self.geom != live_geom:
                    # geometry changed but same output size (e.g. lens or a flip)
                    # — no device change needed, just let scrcpy adopt it.
                    self.geom = live_geom

        # run/stop the preview-JPEG ffmpeg — but only when no real app holds the
        # device (single-reader limit); the applet shows an overlay otherwise.
        self._manage_preview(devnode, preview, bool(consumers), settings.get("fps"))
        self._write_status(devnode, settings, consumers, preview, serial, target, transport)


def _term(*_):
    raise SystemExit(0)


if __name__ == "__main__":
    daemon = CameraDaemon()
    signal.signal(signal.SIGTERM, _term)
    signal.signal(signal.SIGINT, _term)
    try:
        daemon.run()
    finally:
        daemon._stop("shutdown")
        daemon._stop_preview()
