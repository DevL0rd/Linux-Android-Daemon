"""Phone Screen — the shared, daemon-owned scrcpy mirror.

There is ONE pinned scrcpy mirror. Any number of widgets (the desktop Phone Screen
widget, the tray Phone Manager popup, ...) can ask for it by writing a *claim*; the
daemon arbitrates by priority and points the single mirror at the winner — moving
its window (KWin rule) without relaunching scrcpy. When the top claim goes away the
mirror falls back to the next claim (e.g. popup closes -> desktop widget takes it);
when NO claim is left it locks the phone and kills scrcpy after a grace period.

  • PinnedMirror — a state machine the MAIN daemon ticks once a second. Owns the
    scrcpy lifecycle (launch, keep alive, follow USB<->WiFi), the window geometry
    (KWin rule), lock-tracking (hide while locked), and pause for an external mirror
    or a fullscreen app.
  • module helpers (KWin rule, lock/reachability, screen-off) are shared with the
    thin `phonescreenctl` client so there is ONE implementation.

Files in $XDG_RUNTIME_DIR/Linux-Android-Daemon:
    phonescreen_claim_<name>.json   widget -> daemon : a claim (heartbeated)
    phonescreen.json                daemon -> widget : {visible, status, running, locked}
"""
import os
import re
import glob
import json
import time
import shutil
import threading
import subprocess

from core import camera as cam
import scrcpy_launch as sl

TITLE_TOKEN = "PhoneScreenPinned"
KWIN_RULE_ID = "phonescreen"

RUNTIME_DIR = cam.RUNTIME_DIR
STATUS_PATH = os.path.join(RUNTIME_DIR, "phonescreen.json")
CLAIM_GLOB = os.path.join(RUNTIME_DIR, "phonescreen_claim_*.json")
WINDOW_PATH = os.path.join(RUNTIME_DIR, "phonescreen_window")
LOG_PATH = os.path.join(RUNTIME_DIR, "phonescreen.log")
LAUNCHER = os.path.join(cam.REPO_DIR, "src", "scrcpy_launch.py")

CLAIM_TTL = 5.0        # a claim is "live" only if heartbeated within this window
WINDOW_GRACE = 20.0

# scrcpy logs its source capture size as "INFO: Texture: WxH" — that is the true
# mirrored resolution (and aspect), and it is re-logged when the phone rotates/unfolds.
_TEXTURE_RE = re.compile(r"Texture:\s*(\d+)\s*x\s*(\d+)")

# the status file is written from the tick loop AND the scrcpy output reader thread
_status_lock = threading.Lock()


def _runtime():
    os.makedirs(RUNTIME_DIR, exist_ok=True)


def _claim_path(name):
    return os.path.join(RUNTIME_DIR, "phonescreen_claim_%s.json" % name)


# --------------------------------------------------------------------------- #
# claims (widget -> daemon) and status (daemon -> widget)
# --------------------------------------------------------------------------- #
def write_claim(name, **data):
    _runtime()
    try:
        with open(_claim_path(name), "w") as f:
            json.dump(data, f)
    except OSError:
        pass


def remove_claim(name):
    try:
        os.remove(_claim_path(name))
    except OSError:
        pass


def read_claims():
    """All live claims (heartbeated within CLAIM_TTL), each with its name."""
    out = []
    now = time.time()
    for path in glob.glob(CLAIM_GLOB):
        try:
            if now - os.path.getmtime(path) > CLAIM_TTL:
                continue
            with open(path) as f:
                c = json.load(f)
        except (OSError, ValueError):
            continue
        c["name"] = os.path.basename(path)[len("phonescreen_claim_"):-len(".json")]
        out.append(c)
    return out


def pick_winner(claims):
    live = [c for c in claims if c.get("visible")]
    if not live:
        return None
    return max(live, key=lambda c: c.get("priority", 0))


def write_status(**kw):
    _runtime()
    with _status_lock:
        try:
            tmp = STATUS_PATH + ".tmp"
            with open(tmp, "w") as f:
                json.dump(kw, f)
            os.replace(tmp, STATUS_PATH)
        except OSError:
            pass


def read_status():
    try:
        with open(STATUS_PATH) as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


# --------------------------------------------------------------------------- #
# grace markers
# --------------------------------------------------------------------------- #
def touch(path):
    _runtime()
    try:
        open(path, "w").close()
    except OSError:
        pass


def _fresh(path, ttl):
    try:
        return (time.time() - os.path.getmtime(path)) < ttl
    except OSError:
        return False


# Instant "phone is locked" marker — set by lock/unlock the moment they're pressed
# (and kept honest by the daemon's lock poll), so the mirror hides/shows instantly
# instead of waiting for the next ~2s poll.
LOCKED_PATH = os.path.join(RUNTIME_DIR, "phonescreen_locked")


def set_locked(flag):
    _runtime()
    if flag:
        try:
            open(LOCKED_PATH, "w").close()
        except OSError:
            pass
    else:
        try:
            os.remove(LOCKED_PATH)
        except OSError:
            pass


def get_locked():
    return os.path.exists(LOCKED_PATH)


# After a lock/unlock BUTTON press the phone takes a moment to actually change
# state. The daemon's lock poll must not override the just-set state during that
# window, or the mirror flickers hide->show->hide. The button marks this; the poll
# defers while it's fresh.
LOCK_PENDING_PATH = os.path.join(RUNTIME_DIR, "phonescreen_lockpending")
LOCK_PENDING_TTL = 5.0


def mark_lock_pending():
    touch(LOCK_PENDING_PATH)


def lock_pending():
    return _fresh(LOCK_PENDING_PATH, LOCK_PENDING_TTL)


# --------------------------------------------------------------------------- #
# serial / reachability / lock
# --------------------------------------------------------------------------- #
def resolve_serial(serial=""):
    if serial and serial != "auto":
        return serial
    cfg = cam.load_config()
    return cam.camera_settings(cfg).get("active_serial", "") \
        or cam.pick_active_serial(cam.camera_settings(cfg), cfg) \
        or next(iter(cfg.get("devices", {})), "")


def usb_present(serial):
    if not serial:
        return False
    try:
        out = subprocess.run(["adb", "devices", "-l"], capture_output=True,
                             text=True, timeout=8).stdout
    except (OSError, subprocess.TimeoutExpired):
        return False
    for line in out.splitlines()[1:]:
        parts = line.split()
        if len(parts) >= 2 and parts[0] == serial and parts[1] == "device" and "usb:" in line:
            return True
    return False


def last_ip(serial):
    cfg = cam.load_config()
    d = cfg.get("devices", {}).get(serial, {})
    return d.get("last_ip", "") or cfg.get("defaults", {}).get("last_ip", "")


_reach_cache = {"serial": "", "t": 0.0, "v": False}


def reachable(serial):
    """Is the phone ACTUALLY reachable right now (not just 'we have a saved IP')?
    USB present, or a Wi-Fi adb connection that answers `shell true`. This is what
    lets a dropped Wi-Fi / phone-wifi-off get noticed (so the frozen mirror is torn
    down and the status goes offline) instead of looking forever-connected. ~3s cache."""
    if not serial:
        return False
    if usb_present(serial):
        return True
    now = time.time()
    c = _reach_cache
    if serial == c["serial"] and now - c["t"] < 2.0:
        return c["v"]
    v = False
    ip = last_ip(serial)
    if ip:
        cfg = cam.load_config()
        port = cfg.get("devices", {}).get(serial, {}).get("tcpip_port") \
            or cfg.get("defaults", {}).get("tcpip_port", 5555)
        target = "%s:%s" % (ip, port)
        try:
            sl.adb(None, "connect", target, timeout=2)
            # healthy wifi adb answers in <<1s; a 2s cap means a dropped link is
            # noticed in ~2s instead of hanging on the dead socket.
            r = sl.adb(target, "shell", "true", timeout=2)
            v = r is not None and r.returncode == 0
        except Exception:
            v = False
        if not v:
            # adb leaves a Wi-Fi transport in "device" state even after the phone's
            # Wi-Fi drops — a dead socket it won't re-establish, so a later `connect`
            # just says "already connected" and we can never reconnect. Drop it here so
            # the next probe does a FRESH connect (which works once Wi-Fi is back).
            try:
                sl.adb(None, "disconnect", target, timeout=4)
            except Exception:
                pass
    # stamp AFTER the probe so the 5s gap holds even when the probe itself is slow
    # (an offline phone burns ~8s on timeouts); otherwise it would retry back-to-back
    c.update(serial=serial, t=time.time(), v=v)
    return v


def adb_target(serial):
    if not serial:
        return serial
    if usb_present(serial):
        return serial
    ip = last_ip(serial)
    if ip:
        cfg = cam.load_config()
        port = cfg.get("devices", {}).get(serial, {}).get("tcpip_port") \
            or cfg.get("defaults", {}).get("tcpip_port", 5555)
        return "%s:%s" % (ip, port)
    return serial


def is_locked(target):
    if not target:
        return False
    try:
        return sl.is_locked(target)
    except Exception:
        return False


def lock_phone(target):
    if not target:
        return
    try:
        sl.adb(target, "shell", "input", "keyevent", "223")   # KEYCODE_SLEEP
    except Exception:
        pass


def screen_off_configured(serial):
    cfg = cam.load_config()
    s = list(cfg.get("defaults", {}).get("scrcpy_args", [])) \
        + list(cfg.get("devices", {}).get(serial, {}).get("scrcpy_args", []))
    return "--turn-screen-off" in s or "-S" in s


# --------------------------------------------------------------------------- #
# scrcpy process introspection
# --------------------------------------------------------------------------- #
def _scrcpy_pids():
    try:
        out = subprocess.run(["pgrep", "-x", "scrcpy"], capture_output=True, text=True).stdout
        return [int(p) for p in out.split()]
    except OSError:
        return []


def _cmdline(pid):
    try:
        with open("/proc/%d/cmdline" % pid) as f:
            return f.read().replace("\0", " ")
    except OSError:
        return ""


def _is_camera(cmd):
    return "--v4l2-sink" in cmd or "--video-source=camera" in cmd


def external_mirror():
    for p in _scrcpy_pids():
        c = _cmdline(p)
        if c and TITLE_TOKEN not in c and not _is_camera(c):
            return True
    return _fresh(WINDOW_PATH, WINDOW_GRACE)


# --------------------------------------------------------------------------- #
# fullscreen app -> pause to save resources
# --------------------------------------------------------------------------- #
_fs_cache = {"t": 0.0, "v": False}


def fullscreen_active():
    now = time.time()
    if now - _fs_cache["t"] < 1.5:
        return _fs_cache["v"]
    v = False
    try:
        out = subprocess.run(["xprop", "-root", "_NET_ACTIVE_WINDOW"],
                             capture_output=True, text=True, timeout=4).stdout
        toks = out.strip().split()
        wid = toks[-1] if toks else ""
        if wid.startswith("0x") and int(wid, 16) != 0:
            st = subprocess.run(["xprop", "-id", wid, "_NET_WM_STATE"],
                               capture_output=True, text=True, timeout=4).stdout
            v = "_NET_WM_STATE_FULLSCREEN" in st
    except (OSError, subprocess.TimeoutExpired, ValueError):
        v = False
    _fs_cache.update(t=now, v=v)
    return v


# --------------------------------------------------------------------------- #
# KWin rule
# --------------------------------------------------------------------------- #
def _kwrite(key, value):
    subprocess.run(["kwriteconfig6", "--file", "kwinrulesrc",
                    "--group", KWIN_RULE_ID, "--key", key, str(value)], capture_output=True)


def _kwrite_general(key, value):
    subprocess.run(["kwriteconfig6", "--file", "kwinrulesrc", "--group", "General",
                    "--key", key, str(value)], capture_output=True)


def _kread(group, key, default=""):
    try:
        out = subprocess.run(["kreadconfig6", "--file", "kwinrulesrc",
                              "--group", group, "--key", key],
                             capture_output=True, text=True).stdout.strip()
        return out or default
    except OSError:
        return default


def kwin_reconfigure():
    subprocess.run(["dbus-send", "--session", "--type=method_call",
                    "--dest=org.kde.KWin", "/KWin", "org.kde.KWin.reconfigure"], capture_output=True)


def _ensure_rule_listed():
    ids = [r for r in _kread("General", "rules", "").split(",") if r]
    if KWIN_RULE_ID not in ids:
        ids.append(KWIN_RULE_ID)
    _kwrite_general("rules", ",".join(ids))
    _kwrite_general("count", str(len(ids)))


# KWin rule enum: 2 = Force, match enum: 2 = SubstringMatch
def apply_window(x, y, w, h, above=False, borderless=True, minimized=False):
    """Position/size/stack/hide the pinned mirror window in one go (one reconfigure)."""
    _kwrite("Description", "Phone Screen (pinned by org.devl0rd.phonescreen)")
    _kwrite("title", TITLE_TOKEN)
    _kwrite("titlematch", 2)
    _kwrite("types", 1)
    _kwrite("position", "%d,%d" % (x, y))
    _kwrite("positionrule", 2)
    _kwrite("size", "%d,%d" % (w, h))
    _kwrite("sizerule", 2)
    _kwrite("noborder", "true" if borderless else "false")
    _kwrite("noborderrule", 2)
    _kwrite("above", "true" if above else "false")
    _kwrite("aboverule", 2)
    _kwrite("below", "false" if above else "true")
    _kwrite("belowrule", 2)
    _kwrite("minimize", "true" if minimized else "false")
    _kwrite("minimizerule", 2)
    _kwrite("skiptaskbar", "true")
    _kwrite("skiptaskbarrule", 2)
    _kwrite("skippager", "true")
    _kwrite("skippagerrule", 2)
    _kwrite("skipswitcher", "true")
    _kwrite("skipswitcherrule", 2)
    _ensure_rule_listed()
    kwin_reconfigure()


def set_minimized(flag):
    """Just flip the minimize rule (used for instant lock/unlock hide-show)."""
    _kwrite("minimize", "true" if flag else "false")
    _kwrite("minimizerule", 2)
    kwin_reconfigure()


def _kwinrulesrc_path():
    base = os.environ.get("XDG_CONFIG_HOME") or os.path.expanduser("~/.config")
    return os.path.join(base, "kwinrulesrc")


def _strip_group_block(path, group):
    try:
        with open(path) as f:
            lines = f.readlines()
    except OSError:
        return
    out, skipping, header = [], False, "[%s]" % group
    for line in lines:
        s = line.strip()
        if s.startswith("[") and s.endswith("]"):
            skipping = (s == header)
        if not skipping:
            out.append(line)
    try:
        with open(path, "w") as f:
            f.writelines(out)
    except OSError:
        pass


def clear_rule():
    ids = [r for r in _kread("General", "rules", "").split(",") if r and r != KWIN_RULE_ID]
    _kwrite_general("rules", ",".join(ids))
    _kwrite_general("count", str(len(ids)))
    _strip_group_block(_kwinrulesrc_path(), KWIN_RULE_ID)
    kwin_reconfigure()


# --------------------------------------------------------------------------- #
# screen-off after unlock (kdotool focus + scrcpy MOD+o via ydotool)
# --------------------------------------------------------------------------- #
def screen_off_via_scrcpy():
    if not (shutil.which("ydotool") and shutil.which("kdotool")):
        return False
    try:
        subprocess.run(["kdotool", "search", "--name", TITLE_TOKEN, "windowactivate"],
                       capture_output=True, timeout=6)
        time.sleep(0.25)
        subprocess.run(["ydotool", "key", "56:1", "24:1", "24:0", "56:0"],
                       capture_output=True, timeout=6)   # Left-Alt + O
        return True
    except (OSError, subprocess.TimeoutExpired):
        return False


# --------------------------------------------------------------------------- #
# the daemon-owned mirror manager
# --------------------------------------------------------------------------- #
class PinnedMirror:
    """The daemon's single mirror, driven at two cadences so reactions feel instant:

      • reconcile() — fast (~150 ms, no adb): point the window at the winning claim
        (move / hide) the moment a claim changes, so opening/closing the popup or
        switching tabs reacts instantly.
      • tick() — slow (~1 s): the scrcpy lifecycle (launch, keep-alive, USB<->WiFi)
        and the status snapshot.
      • poll_lock() — fast (~0.5 s): physical lock/unlock detection while shown.

    Lifecycle: once launched, scrcpy is kept ALIVE (it is never grace-killed). With
    no claim it is held MINIMIZED and the phone is locked, so re-opening is instant
    and it can follow USB<->WiFi while hidden. It only dies if the link drops (and is
    relaunched, minimized, when the phone is reachable again).
    """

    def __init__(self):
        self.proc = None
        self.serial = ""
        self.target = ""
        self.started = 0.0
        self.connected = False
        self.next_launch = 0.0
        self.applied = None          # last (x,y,w,h,above,borderless,min) pushed to KWin
        self.no_claim_since = 0.0
        self.size_wh = (9, 19)       # mirrored display w,h, read live from scrcpy's output
                                     # ("Texture: WxH"); the popup sizes its area to this
        self._last_status = {"visible": False, "status": "off", "running": False,
                             "locked": False, "owner": ""}  # for off-tick size republish
        self.persist = False         # once True we keep scrcpy ALIVE (minimized when
                                     # there's no claim) — never killed, so re-opening
                                     # is instant and it can follow USB<->WiFi hidden
        self.last_geom = None        # last (x,y,w,h,above,borderless) from a claim
        self.borderless = True       # remembered launch flags for hidden relaunches
        self.extra = []
        self.link = ""               # ACTUAL current connection: "usb" | "wifi" | ""
        # We OWN the mirror (self.proc) and read its output stream, so we can't adopt an
        # orphan from a prior daemon (no pipe to it). Clear any such orphan at startup so
        # self.proc is the single source of truth — no pgrep needed to track our own child.
        subprocess.run(["pkill", "-f", TITLE_TOKEN], capture_output=True)

    def _alive(self):
        """Is OUR scrcpy mirror running? We launched it, so just ask the handle —
        no process scan. self.proc is scrcpy directly (the launcher exec's into it)."""
        return self.proc is not None and self.proc.poll() is None

    def switch_transport(self):
        """Called from the daemon's USB plug/unplug thread: drop the mirror NOW so the
        next tick relaunches it on whatever transport is now best (USB appeared, or USB
        vanished -> WiFi). Instant in BOTH directions — without this, an unplug just waits
        for scrcpy to notice the dead USB link and exit on its own (several seconds). We
        own the process, so we terminate the handle (no pkill); tick sees it dead and
        relaunches. Reading proc into a local + an atomic float write keep it thread-safe."""
        p = self.proc
        if p:
            try:
                p.terminate()
            except OSError:
                pass
        self.next_launch = 0.0   # don't let the relaunch throttle delay the swap

    def wants(self, serial):
        win = pick_winner(read_claims())
        if win:
            return (win.get("serial") or resolve_serial()) == serial
        # No claim, but a persisting (minimized) mirror still follows this phone, so
        # plug/unplug should still nudge it onto the faster transport.
        return self.persist and bool(self.serial) and self.serial == serial

    # ---- fast: window placement from the winning claim (no adb) ----------
    def reconcile(self):
        win = pick_winner(read_claims())
        if win is None:
            # No claim: if we're keeping the mirror alive, hold it MINIMIZED at the
            # last known geometry (so any relaunch opens minimized too). Cached via
            # self.applied, so this is a one-shot, not a per-tick reconfigure.
            if not self.persist or self.last_geom is None:
                return
            x, y, w, h, above, borderless = self.last_geom
            want_min = True
        else:
            x, y = int(win.get("x", 0)), int(win.get("y", 0))
            w, h = int(win.get("w", 400)), int(win.get("h", 800))
            above = bool(win.get("above", False))
            borderless = bool(win.get("borderless", True))
            self.last_geom = (x, y, w, h, above, borderless)
            # hide via the KWin minimize rule (locked marker, or the claim asking on
            # another tab / while resizing) — no grace, no cooldown.
            want_min = bool(win.get("min", False)) or get_locked()
        desired = (x, y, w, h, above, borderless, want_min)
        if desired != self.applied:
            self.applied = desired
            apply_window(x, y, w, h, above=above, borderless=borderless, minimized=want_min)

    # ---- slow: scrcpy lifecycle -----------------------------------------
    def _stop(self):
        # We own it — terminate the handle; no pkill/pgrep dance.
        if self.proc:
            try:
                self.proc.terminate()
            except OSError:
                pass
            self.proc = None
        self.connected = False
        self.applied = None

    def _launch(self, serial, borderless, extra):
        # --no-unlock: the pinned mirror just CONNECTS; it never wakes/PIN-unlocks the
        # phone (so a hidden reconnect on plug/unplug stays locked). The widgets unlock
        # explicitly only when they actually show the phone.
        flags = ["--no-unlock", "--window-title", TITLE_TOKEN, "--no-audio",
                 "--no-window-aspect-ratio-lock"]
        if borderless:
            flags.append("--window-borderless")
        flags += extra
        try:
            _runtime()
            # -u + a piped stream: we read scrcpy's output LIVE (see _read_output) instead
            # of polling its log on disk, so a size change reaches us the instant it prints.
            proc = subprocess.Popen(["python3", "-u", LAUNCHER, "--auto", serial] + flags,
                                    stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                    text=True, bufsize=1)
        except OSError as e:
            print("[phonescreen] launch failed: %s" % e)
            return None
        threading.Thread(target=self._read_output, args=(proc,), daemon=True).start()
        return proc

    def _read_output(self, proc):
        # Own scrcpy's output stream: tee it to the log for debugging AND fire an immediate
        # resize the moment scrcpy reports a new texture (rotation / unfolding the foldable).
        # The texture is the SOURCE capture size — the true aspect, independent of the window
        # size we force — so the popup can size its area to it and the mirror fills it exactly.
        try:
            with open(LOG_PATH, "a") as log:
                for line in proc.stdout:
                    log.write(line)
                    log.flush()
                    m = _TEXTURE_RE.search(line)
                    if not m or proc is not self.proc:
                        continue
                    wh = (int(m.group(1)), int(m.group(2)))
                    if wh != self.size_wh and wh[0] > 0 and wh[1] > 0:
                        self.size_wh = wh
                        # On rotation scrcpy resizes its OWN window to the new orientation;
                        # force the next reconcile to re-assert the KWin geometry rule so it
                        # snaps back into the claim rect (the desktop widget's claim doesn't
                        # change, so reconcile would otherwise dedupe and never re-pin it).
                        self.applied = None
                        self._publish_size()
        except Exception:
            pass

    def _publish_size(self):
        # Re-emit the current status carrying the new size the instant scrcpy reports it,
        # so the widgets reshape immediately instead of waiting for the next tick.
        w, h = self.size_wh
        write_status(width=w, height=h, link=self.link, **self._last_status)

    def _status(self, **kw):
        self._last_status = kw
        w, h = self.size_wh
        write_status(width=w, height=h, link=self.link, **kw)

    def poll_lock(self):
        """Fast physical lock/unlock detection so a SHOWN mirror hides/shows quickly.
        Runs only while the mirror is actually visible — minimized (no claim) means
        we already locked it, and a popped-out/paused mirror isn't ours to touch."""
        if lock_pending():                       # a just-pressed button owns the state
            return
        win = pick_winner(read_claims())
        if not win or bool(win.get("min", False)) or not self._alive():
            return
        set_locked(is_locked(self.target or adb_target(self.serial)))

    def tick(self):
        win = pick_winner(read_claims())

        # Refresh the REAL connection link for the status badge every tick (cheap: a
        # usb check + the cached wifi reachability probe). This is the truth — present
        # USB transport, or a wifi adb that actually answers — never "we have an IP".
        ls = (win.get("serial") if win else self.serial) or resolve_serial()
        if ls and usb_present(ls):
            self.link = "usb"
        elif ls and reachable(ls):
            self.link = "wifi"
        else:
            self.link = ""

        # ---------- no claim: keep the mirror ALIVE but minimized (never kill) -----
        if win is None:
            if not self.persist:
                self._status(visible=False, status="off", running=False,
                             locked=get_locked(), owner="")
                return
            if not self.no_claim_since:               # the last claim just dropped
                self.no_claim_since = time.time()
                set_locked(True)                      # lock + (reconcile) minimize
                lock_phone(self.target or adb_target(self.serial))
            serial = self.serial or resolve_serial()
            self.serial = serial
            # Follow USB<->WiFi while hidden: if the mirror died (cable pulled) and the
            # phone is reachable, relaunch it ALREADY minimized (the rule's minimize is
            # in force) so it never flashes; if it's frozen on a dead link, drop it so
            # the next reachable tick can bring it back.
            if serial and reachable(serial):
                if not self._alive() and not external_mirror():
                    now = time.time()
                    if now >= self.next_launch:
                        self.next_launch = now + 2.0
                        self.target = adb_target(serial)
                        set_minimized(True)
                        self.proc = self._launch(serial, self.borderless, self.extra)
                        self.started = now
                        self.applied = None
            elif self._alive():
                self._stop()                          # frozen on a dead link -> drop it
            self._status(visible=False, status="minimized", running=self._alive(),
                         locked=get_locked(), owner="", serial=serial)
            return
        self.no_claim_since = 0.0

        serial = win.get("serial") or resolve_serial()
        owner = win.get("name", "")
        self.serial = serial
        self.borderless = bool(win.get("borderless", True))
        self.extra = win.get("extra", []) or []
        borderless = self.borderless
        extra = self.extra

        if external_mirror():
            self._stop()
            self._status(visible=True, status="external", running=False, locked=False, serial=serial, owner=owner)
            return
        if fullscreen_active():
            self._stop()
            self._status(visible=True, status="fullscreen", running=False, locked=False, serial=serial, owner=owner)
            return
        if not serial or not reachable(serial):
            self._stop()
            self._status(visible=True, status="offline", running=False, locked=False, serial=serial, owner=owner)
            return

        if not self._alive():
            now = time.time()
            if now < self.next_launch:
                self._status(visible=True, status="connecting", running=False, locked=get_locked(), serial=serial, owner=owner)
                return
            self.next_launch = now + 2.0
            self.target = adb_target(serial)
            set_locked(is_locked(self.target))
            self.proc = self._launch(serial, borderless, extra)
            self.started = now
            self.connected = False
            self.persist = True          # from now on, keep it alive (never grace-kill)
            self.applied = None          # force reconcile to position the new window
            self._status(visible=True, status="connecting", running=False, locked=get_locked(), serial=serial, owner=owner)
            return

        if not self.connected and time.time() - self.started > 3.0:
            self.connected = True

        # (physical lock/unlock detection lives in poll_lock(), run far more often)
        self._status(visible=True, status="connected" if self.connected else "connecting",
                     running=self.connected, locked=get_locked(), serial=serial, owner=owner)
