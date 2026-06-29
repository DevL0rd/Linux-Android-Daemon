"""Shared helpers for the phone-as-webcam feature.

This is the camera counterpart to scrcpy_launch.py: it knows how to pick the
right transport for a phone (USB if plugged in, else its saved WiFi IP), find
the v4l2loopback "Phone Camera" sink, tell whether anything is actually
consuming that sink, and build the scrcpy command that pumps the phone camera
into it. Both the resident daemon and the `phonecamctl` CLI import from here so
the two always agree on config layout and device resolution.
"""
import os
import re
import json
import subprocess

# core/ -> src/ -> repo root. Computed from this file so it is correct no matter
# what the caller's working directory is (the CLI is launched from plasmashell).
REPO_DIR = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
CONFIG_PATH = os.path.join(REPO_DIR, "config.json")

RUNTIME_DIR = os.path.join(os.environ.get("XDG_RUNTIME_DIR", "/tmp"), "Linux-Android-Daemon")
STATUS_PATH = os.path.join(RUNTIME_DIR, "phonecam.json")
PREVIEW_HEARTBEAT = os.path.join(RUNTIME_DIR, "phonecam_preview")
PROBE_REQUEST = os.path.join(RUNTIME_DIR, "phonecam_probe")
CAPS_PATH = os.path.join(RUNTIME_DIR, "phonecam_caps.json")
SIZES_PATH = os.path.join(RUNTIME_DIR, "phonecam_sizes.json")
PREVIEW_JPG = os.path.join(RUNTIME_DIR, "preview.jpg")

# Common Android camera sizes, used to snap a requested size to something the
# camera is very likely to support BEFORE we've probed the real list. Once the
# daemon probes `--list-camera-sizes` the real per-facing list is used instead.
FALLBACK_SIZES = [(3840, 2160), (2560, 1440), (1920, 1440), (1920, 1080),
                  (1440, 1080), (1280, 720), (1088, 1088), (960, 720),
                  (720, 720), (640, 480), (640, 360), (352, 288), (320, 240)]

CARD_LABEL = "Phone Camera"

# scrcpy's v4l2 sink outputs planar YUV 4:2:0 (FourCC "YU12"). We pin the
# loopback to exactly this format while idle so a consumer that opens it is
# forced to YU12 instead of negotiating MJPG/YUYV (which scrcpy can't produce,
# giving a black/garbled image). The pinned size and scrcpy's --camera-size are
# always driven from the same resolution so producer and consumer agree.
OUTPUT_FOURCC = "YU12"
DEFAULT_RESOLUTION = "1280x720"

# Camera settings live in a single top-level "camera" block in config.json (the
# virtual webcam is global, not per-phone). Anything not present falls back to
# these.
CAMERA_DEFAULTS = {
    "active_serial": "",     # "" = auto-pick (USB phone first, else a saved IP)
    "video_nr": 9,           # the /dev/videoN the loopback is created on
    "facing": "back",        # back | front | external (ignored if camera_id set)
    "camera_id": "",         # explicit scrcpy --camera-id (overrides facing)
    "resolution": "2160",    # height tier; default to highest
    "fps": 60,               # --camera-fps; default to highest
    "aspect_ratio": "16:9",  # frame shape; combined with the height into a size
    "zoom": 1.0,             # --camera-zoom initial value
    "rotation": "@0",        # --capture-orientation, locked (0/90/180/270/flip…)
    "high_speed": False,     # --camera-high-speed
    "torch": False,          # --camera-torch
    "extra_args": [],        # any extra raw scrcpy args
}


# --- config -----------------------------------------------------------------

def load_config():
    try:
        with open(CONFIG_PATH) as f:
            cfg = json.load(f)
    except Exception:
        cfg = {}
    cfg.setdefault("defaults", {})
    cfg.setdefault("devices", {})
    cfg.setdefault("camera", {})
    return cfg


def save_config(cfg):
    tmp = CONFIG_PATH + ".tmp"
    with open(tmp, "w") as f:
        json.dump(cfg, f, indent=4)
    os.replace(tmp, CONFIG_PATH)


def camera_settings(cfg):
    """Effective camera settings: defaults overlaid with the saved camera block."""
    s = dict(CAMERA_DEFAULTS)
    s.update(cfg.get("camera", {}) or {})
    return s


# --- adb / transport --------------------------------------------------------

def adb(target, *args, timeout=10, capture=False):
    cmd = ["adb"]
    if target:
        cmd += ["-s", target]
    cmd += list(args)
    return subprocess.run(cmd, capture_output=capture, text=True, timeout=timeout)


def usb_serials():
    """{serial: model} for phones on a USB transport in 'device' state."""
    out_map = {}
    try:
        out = adb(None, "devices", "-l", capture=True, timeout=10).stdout
    except Exception:
        return out_map
    for line in out.splitlines()[1:]:
        line = line.strip()
        if not line:
            continue
        parts = line.split()
        if len(parts) < 2 or parts[1] != "device" or "usb:" not in line:
            continue
        model = ""
        for p in parts:
            if p.startswith("model:"):
                model = p.split(":", 1)[1].replace("_", " ")
        out_map[parts[0]] = model
    return out_map


def resolve_target(serial, cfg, usb_map=None):
    """Pick the transport for a phone: USB serial if plugged in, else its saved
    last_ip over WiFi. Returns (target, transport) with transport in
    {"usb","wifi"} or (None, "") when the phone is unreachable."""
    if not serial:
        return (None, "")
    if usb_map is None:
        usb_map = usb_serials()
    if serial in usb_map:
        return (serial, "usb")
    dev = cfg.get("devices", {}).get(serial, {})
    ip = dev.get("last_ip", "")
    if ip:
        port = dev.get("tcpip_port", 5555)
        return (f"{ip}:{port}", "wifi")
    return (None, "")


def pick_active_serial(settings, cfg, usb_map=None):
    """Which phone the webcam should use. An explicit, known selection wins;
    otherwise auto-pick a plugged-in phone, then any phone with a saved IP.
    Devices marked "enabled": false in config are skipped entirely, even if
    plugged in or explicitly selected, so the webcam never grabs them."""
    if usb_map is None:
        usb_map = usb_serials()
    devices = cfg.get("devices", {})

    def enabled(s):
        return devices.get(s, {}).get("enabled", True)

    sel = settings.get("active_serial", "")
    if sel and sel in devices and enabled(sel):
        return sel
    for s in usb_map:
        if enabled(s):
            return s
    for s, d in devices.items():
        if d.get("last_ip") and enabled(s):
            return s
    return next((s for s in devices if enabled(s)), "")


# --- v4l2loopback -----------------------------------------------------------

def loopback_devnode(video_nr=None, label=CARD_LABEL):
    """Find the /dev/videoN created by v4l2loopback for our card label. Prefers
    the configured video_nr when several match. Returns None if not loaded."""
    base = "/sys/class/video4linux"
    matches = []
    try:
        nodes = os.listdir(base)
    except OSError:
        return None
    for n in nodes:
        if not n.startswith("video"):
            continue
        try:
            with open(os.path.join(base, n, "name")) as f:
                name = f.read().strip()
        except OSError:
            continue
        if name == label:
            num = int(n[5:]) if n[5:].isdigit() else -1
            matches.append((num, "/dev/" + n))
    if not matches:
        return None
    if video_nr is not None:
        for num, dev in matches:
            if num == video_nr:
                return dev
    matches.sort()
    return matches[0][1]


def _comm(pid):
    try:
        with open("/proc/%d/comm" % pid) as f:
            return f.read().strip()
    except OSError:
        return ""


def _consumers_proc_scan(devnode, exclude):
    """Fallback consumer scan over /proc: checks both open fds AND mmap'd regions
    (apps like Discord/Chromium mmap the v4l2 buffers and may drop the fd)."""
    real = os.path.realpath(devnode)
    targets = (devnode, real)
    found = []
    for pid in os.listdir("/proc"):
        if not pid.isdigit():
            continue
        p = int(pid)
        if p in exclude:
            continue
        hit = False
        fddir = "/proc/%s/fd" % pid
        try:
            for fd in os.listdir(fddir):
                try:
                    link = os.readlink(os.path.join(fddir, fd))
                except OSError:
                    continue
                if link in targets:
                    hit = True
                    break
        except OSError:
            pass
        if not hit:
            try:
                with open("/proc/%s/maps" % pid) as f:
                    for line in f:
                        if devnode in line or real in line:
                            hit = True
                            break
            except OSError:
                pass
        if hit:
            found.append({"pid": p, "name": _comm(p)})
    return found


def device_consumers(devnode, exclude_pids=()):
    """Processes holding `devnode`, minus our own feeder.

    Uses `fuser`, which reports file descriptors AND memory maps — crucial
    because many camera apps (Discord, Chromium, ...) mmap the v4l2 buffers and
    no longer show an open fd. Falls back to a /proc fd+maps scan if fuser is
    missing."""
    exclude = set(exclude_pids)
    try:
        out = subprocess.run(["fuser", devnode], capture_output=True, text=True, timeout=5)
        blob = (out.stdout or "") + " " + (out.stderr or "")
    except FileNotFoundError:
        return _consumers_proc_scan(devnode, exclude)
    except Exception:
        return []
    pids = set()
    for tok in blob.split():
        m = re.match(r"(\d+)", tok)          # tokens look like "177284m" / "1850488"
        if m:
            pids.add(int(m.group(1)))
    return [{"pid": p, "name": _comm(p)} for p in sorted(pids) if p not in exclude]


# --- scrcpy camera command --------------------------------------------------

ASPECT_RATIOS = {"16:9": (16, 9), "4:3": (4, 3), "1:1": (1, 1), "3:2": (3, 2)}

# Parses the "- 1280x720" lines under each "--camera-id=N (back, ...)" block.
_SIZE_LINE = re.compile(r"^\s*-\s*(\d+)x(\d+)\s*$")
_CAM_HDR = re.compile(r"--camera-id=\S+\s+\((\w+)")


def parse_camera_sizes(output):
    """Parse `scrcpy --list-camera-sizes` into {facing: [(w,h), ...]}."""
    cams, cur = {}, None
    for line in output.splitlines():
        m = _CAM_HDR.search(line)
        if m:
            cur = m.group(1)            # back / front / external
            cams.setdefault(cur, [])
            continue
        m = _SIZE_LINE.match(line)
        if m and cur:
            cams[cur].append((int(m.group(1)), int(m.group(2))))
    return cams


def probe_camera_sizes(target, timeout=20):
    """Run `--list-camera-sizes` and return {facing: [(w,h)...]} (best-effort)."""
    try:
        out = subprocess.run(["scrcpy", "-s", target, "--list-camera-sizes"],
                             capture_output=True, text=True, timeout=timeout)
    except Exception:
        return {}
    return parse_camera_sizes((out.stdout or "") + (out.stderr or ""))


def load_camera_sizes():
    try:
        with open(SIZES_PATH) as f:
            return json.load(f)
    except Exception:
        return {}


def save_camera_sizes(sizes):
    try:
        os.makedirs(RUNTIME_DIR, exist_ok=True)
        tmp = SIZES_PATH + ".tmp"
        with open(tmp, "w") as f:
            json.dump(sizes, f)
        os.replace(tmp, SIZES_PATH)
    except OSError:
        pass


def pick_supported_size(sizes, target_w, target_h):
    """Nearest camera-supported size to the requested one: closest aspect ratio
    first, then closest pixel count. Returns "WxH"."""
    if not sizes:
        return "%dx%d" % (target_w, target_h)
    ta = target_w / float(target_h)
    tarea = target_w * target_h

    def score(s):
        w, h = s
        return (abs((w / float(h)) - ta), abs(w * h - tarea))

    w, h = min(sizes, key=score)
    return "%dx%d" % (w, h)


def effective_resolution(settings):
    """The concrete capture WxH for scrcpy's --camera-size (pre-rotation).

    The resolution is a height tier ("720"/"1080"…) and the aspect ratio gives
    the shape; together they form a *target* size which is then SNAPPED to the
    nearest size the camera actually supports (from the probed list, else a
    common-sizes fallback). Generating an unsupported size is what produced the
    corrupted/green image. An explicit "WxH" is honoured as-is."""
    r = str(settings.get("resolution", "") or "").strip().lower()
    if "x" in r:
        return r
    try:
        h = int(r)
    except ValueError:
        h = 720
    aw, ah = ASPECT_RATIOS.get(str(settings.get("aspect_ratio", "") or "16:9"), (16, 9))
    target_w = int(round(h * aw / float(ah)))

    facing = str(settings.get("facing", "back") or "back")
    sizes = load_camera_sizes().get(facing)
    sizes = [tuple(s) for s in sizes] if sizes else FALLBACK_SIZES
    return pick_supported_size(sizes, target_w, h)


def _is_portrait_rotation(settings):
    """True when the rotation turns the frame on its side (90/270), which swaps
    width and height in scrcpy's output."""
    rot = str(settings.get("rotation", "") or "").lstrip("@").replace("flip", "")
    return rot in ("90", "270")


def effective_output_size(settings):
    """The WxH scrcpy actually WRITES to the loopback — the capture size with
    width/height swapped for a 90/270 rotation. The loopback must be pinned to
    THIS (not the capture size) or a rotated frame is read with the wrong stride
    and comes out corrupted."""
    res = effective_resolution(settings)
    if "x" not in res:
        return res
    w, h = res.split("x", 1)
    return ("%sx%s" % (h, w)) if _is_portrait_rotation(settings) else res


def pin_caps(devnode, settings):
    """Pin the loopback to YU12 at the effective OUTPUT size (best-effort; only
    works while the device is idle). Returns the size on success, else None.

    CRITICAL: scrcpy leaves the v4l2loopback `keep_format=1` control set, which
    LOCKS the format and makes `set-caps` a silent no-op (it returns success but
    nothing changes). We must clear keep_format first, or the pin never moves off
    the first size it ever had — which was the whole "everything but 720 is a
    green corrupt mess" bug."""
    res = effective_output_size(settings)
    try:
        subprocess.run(["v4l2-ctl", "-d", devnode, "-c", "keep_format=0"],
                       capture_output=True, timeout=5)
        out = subprocess.run(["v4l2loopback-ctl", "set-caps", devnode,
                              "%s:%s" % (OUTPUT_FOURCC, res)],
                             capture_output=True, text=True, timeout=5)
        # verify it actually took (the format really changed), not just rc==0
        fmt = subprocess.run(["v4l2-ctl", "-d", devnode, "--get-fmt-video"],
                             capture_output=True, text=True, timeout=5).stdout
        w, h = res.split("x")
        return res if ("%s/%s" % (w, h)) in fmt else None
    except Exception:
        return None


def start_preview_stream(devnode, fps=15):
    """Run a small ffmpeg that writes a scaled JPEG of the current feed to
    PREVIEW_JPG at the selected fps. The applet shows that file as an Image —
    unlike QtMultimedia, an Image renders each JPEG at its OWN dimensions, so it
    can't go stale/stretched, and a size change is handled simply by restarting
    this. Returns the Popen or None."""
    try:
        fps = max(1, min(int(fps or 15), 60))
    except (TypeError, ValueError):
        fps = 15
    try:
        os.makedirs(RUNTIME_DIR, exist_ok=True)
        return subprocess.Popen(
            ["ffmpeg", "-hide_banner", "-loglevel", "error", "-nostdin",
             "-f", "v4l2", "-i", devnode,
             "-vf", "fps=%d,scale=360:-2" % fps,
             "-q:v", "6", "-update", "1", "-y", PREVIEW_JPG],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except Exception:
        return None


def build_scrcpy_cmd(target, settings, devnode):
    """The scrcpy invocation that streams the phone camera into the loopback.
    No window, no audio, no control: this is a pure capture pipe."""
    cmd = [
        "scrcpy",
        "-s", target,
        "--video-source=camera",
        "--v4l2-sink=%s" % devnode,
        "--no-audio",
        "--no-window",
        "--no-control",
    ]
    cam_id = str(settings.get("camera_id", "") or "")
    if cam_id:
        cmd.append("--camera-id=%s" % cam_id)
    else:
        facing = str(settings.get("facing", "back") or "back")
        if facing in ("front", "back", "external"):
            cmd.append("--camera-facing=%s" % facing)
    # NB: --camera-size and --camera-ar are mutually exclusive in scrcpy
    # (both choose the capture size). We always need an explicit size for the
    # loopback pin, so --camera-ar is never used — the resolution choice sets
    # the aspect.
    cmd.append("--camera-size=%s" % effective_resolution(settings))
    try:
        fps = int(settings.get("fps", 0) or 0)
    except (TypeError, ValueError):
        fps = 0
    if fps > 0:
        cmd.append("--camera-fps=%d" % fps)
    try:
        zoom = float(settings.get("zoom", 1.0) or 1.0)
    except (TypeError, ValueError):
        zoom = 1.0
    if abs(zoom - 1.0) > 1e-6:
        cmd.append("--camera-zoom=%s" % ("%g" % zoom))
    rot = str(settings.get("rotation", "0") or "0")
    if rot and rot != "0":
        cmd.append("--capture-orientation=%s" % rot)
    if settings.get("high_speed"):
        cmd.append("--camera-high-speed")
    if settings.get("torch"):
        cmd.append("--camera-torch")
    for a in settings.get("extra_args", []) or []:
        cmd.append(str(a))
    return cmd


def settings_signature(settings, devnode):
    """A tuple identifying the *content* of the feed (everything except which
    transport carries it). When this changes the feed must be rebuilt; when only
    the transport changes we restart immediately without a debounce."""
    return tuple(build_scrcpy_cmd("?", settings, devnode))


# --- camera capability probe ------------------------------------------------

_CAM_LINE = re.compile(r"--camera-id=(\S+)\s+\(([^,)]+)")


def probe_cameras(target, timeout=12):
    """Run `scrcpy --list-cameras` against a phone and parse the id/facing list.
    Best-effort: returns [] on any failure. This briefly starts a scrcpy server
    on the phone, so callers do it sparingly (on popup open, cached after)."""
    try:
        out = subprocess.run(
            ["scrcpy", "-s", target, "--list-cameras"],
            capture_output=True, text=True, timeout=timeout,
        )
    except Exception:
        return []
    blob = (out.stdout or "") + (out.stderr or "")
    cams = []
    for m in _CAM_LINE.finditer(blob):
        cams.append({"id": m.group(1), "facing": m.group(2).strip()})
    return cams


def load_caps():
    try:
        with open(CAPS_PATH) as f:
            return json.load(f)
    except Exception:
        return {}


def save_caps(caps):
    try:
        os.makedirs(RUNTIME_DIR, exist_ok=True)
        tmp = CAPS_PATH + ".tmp"
        with open(tmp, "w") as f:
            json.dump(caps, f)
        os.replace(tmp, CAPS_PATH)
    except OSError:
        pass
