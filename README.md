# Linux-Android-Daemon

A small suite that makes an Android phone a first-class part of a Linux (KDE
Plasma) desktop:

* **Screen mirror** — plug in over USB and the phone is mirrored with `scrcpy`,
  with wireless ADB armed so it keeps working over Wi-Fi when you unplug. The
  mirror **follows the connection** (USB ⇄ Wi-Fi) on its own.
* **Phone Screen widget** (desktop) — a live, always-connected mirror pinned
  right on your desktop. Lock/unlock, volume, Back/Home/Recents, pop-out.
* **Phone Manager widget** (system tray) — the same live phone in a drop-down,
  plus **Camera** and **Settings** tabs, and a **pin** to keep it open on top.
* **Phone Camera** — use the phone's camera as a normal Linux webcam
  (v4l2loopback), controlled from the tray, connected only on demand.
* **USB-tethering failover** — if the PC loses its real uplink, the plugged-in
  phone is switched into USB tethering; switched back when a real uplink returns.

It's mostly for myself, but in case my friends use it, here are the instructions.

---

## Requirements

`install.sh` installs the packages it can from the official repos (Arch/CachyOS).

* `adb` (`android-tools`), `scrcpy` (3.0+; 4.0 here), `ffmpeg` — installed by
  `install.sh`.
* `v4l2loopback-dkms` + `v4l2loopback-utils` (the **Phone Camera**) + the kernel
  headers for your running kernel — installed by `install.sh`.
* KDE **Plasma 6** with `kpackagetool6` (the widgets).
* `ydotool` (repo) + `kdotool` (AUR) — only for the "turn the phone screen off
  again after an in-widget unlock" nicety; everything else works without them.
* USB debugging enabled on the phone, with this computer authorised.
* An **Android 12+** phone for the camera feature (scrcpy camera mirroring).

`install.sh` also sets `QML_XHR_ALLOW_FILE_READ=1` (so the widgets can read the
daemon's status snapshots) and makes the daemon inherit the graphical session env
(needed for the mirror's KWin/fullscreen/screen-off bits).

## Installation

Clone **with submodules** — the shared QML components live in the
[Linux-Plasma-Shared](https://github.com/DevL0rd/Linux-Plasma-Shared) submodule:

```bash
git clone --recurse-submodules https://github.com/DevL0rd/Linux-Android-Daemon.git
# already cloned without it?  git submodule update --init --recursive
./install.sh
```

This generates a git-ignored `config.json` from `config.example.json` (it holds
your device list and lock PIN), installs the two systemd **user** services and
the two Plasma widgets. If you were just added to the `input` group (for
`ydotool`), log out/in once.

## Uninstallation

```bash
./uninstall.sh
```

Stops/removes the services, widgets, helper scripts, the v4l2loopback device and
the KWin rule. It deliberately leaves the general-purpose packages
(`adb`/`scrcpy`/`ffmpeg`/`v4l2loopback`/`ydotool`/`kdotool`) installed.

---

## How it all fits together

Two systemd **user** services do the work; the widgets are thin clients that
read tmpfs status snapshots and write small request files.

```
 daemon.py  (linux-android-daemon.service)
   ├─ watches adb for USB plug/unplug, arms wireless ADB, auto-mirror on plug
   ├─ USB-tethering failover, KDE Connect click-to-open
   └─ owns the SHARED pinned mirror (core/phonescreen.py: PinnedMirror)

 camera_daemon.py  (linux-phonecam.service)
   └─ the on-demand phone-as-webcam feed (v4l2loopback)

 widgets (Plasma 6)
   ├─ org.devl0rd.phonescreen  — desktop "Phone Screen"
   └─ org.devl0rd.phonecam     — tray "Phone Manager" (Phone/Camera/Settings)
```

### The shared pinned mirror

There is **one** pinned `scrcpy` mirror, owned entirely by the daemon. Widgets
don't manage `scrcpy` — they write a **claim** (a priority + the rectangle they
want the mirror in) and heartbeat it while they want the phone on screen. The
daemon points the single mirror at the highest-priority live claim and **moves
its window without relaunching `scrcpy`**:

* The desktop widget claims at priority 1; the tray popup claims at priority 2.
* Open the popup → it wins → the mirror **moves** to the popup. Close it → the
  mirror **falls back** to the desktop widget's claim (it is never relaunched on
  a hand-off).
* When **no** claim is left, the daemon locks the phone and kills `scrcpy` after
  a short grace period.

The daemon also follows the phone across transports for the pinned mirror: when
the USB-bound `scrcpy` dies on unplug it relaunches over Wi-Fi (using the LAN IP
captured while plugged), and plugging the cable back in nudges it onto USB.

Helper CLIs (symlinked into `~/.local/bin`):

* `phonecamctl` — drives the camera daemon (settings, preview, device select).
* `phonescreenctl` — the thin mirror client: `claim/release`, `lock/unlock`,
  `volume`, `nav`, `window` (pop-out), `state`.

---

## Phone Screen widget (desktop)

Add it from **right-click desktop → Add Widgets → "Phone Screen"**. It pins the
real, interactive `scrcpy` mirror over itself and keeps it connected.

* **Visible toggle** (top-right, default on) — keep the mirror pinned and always
  reconnecting; off disconnects.
* **Status badge** — USB / Wi-Fi / offline.
* **Volume**, a **lock/unlock toggle** (reflects the *actual* phone lock state —
  it also tracks the phone locking itself from a timeout), and a **pop-out**
  button (a movable `scrcpy` window).
* **Back / Home / Recents** along the bottom.
* It **pauses** if a fullscreen app (e.g. a game) is focused, or if `scrcpy` is
  opened elsewhere, and resumes afterwards.
* When the phone is **locked** the mirror is hidden (not killed) and the panel
  says so — double-click to unlock. Unlock is instant and, if your `scrcpy_args`
  include `--turn-screen-off`, the phone panel is put back to sleep afterwards.

Settings (standard Plasma config): which phone, keep-below, borderless, an X/Y
position nudge (for fractional-scaling/multi-monitor), extra `scrcpy` args,
accent colour, poll interval.

## Phone Manager widget (system tray)

Add it from **system tray → Add Widgets → "Phone Manager"**, or drop it into the
tray's configured entries. Clicking the tray icon drops down a tabbed panel:

* **Phone** — the same live mirror as the desktop widget (volume, lock/unlock,
  pop-out, Back/Home/Recents). Opening the popup auto-unlocks the phone; closing
  it hands the mirror back to the desktop widget (or locks + stops it).
* **Camera** — the webcam live preview and every `scrcpy` camera option.
* **Settings** — the per-device daemon settings (so `config.json` never needs
  editing by hand).
* **Pin** (top-right) — keep the popup open and the mirror on top, so you can
  actually use the phone without the popup closing when it loses focus.

> A tray popup closes when it loses focus, and clicking the mirror (a separate
> window) does exactly that — so the embedded mirror is only fully *usable* when
> **pinned**. Unpinned it's a glance.

## Phone Camera (virtual webcam)

A second, independent feature: use the phone's camera as a regular Linux webcam.
Unlike the screen mirror it **never auto-launches** — the phone is contacted only
when something wants frames.

* `v4l2loopback` provides a persistent virtual camera named **"Phone Camera"**
  (on `/dev/video9` by default) that shows up in every app's camera list.
* `camera_daemon.py` (the `linux-phonecam` service) watches that device. When a
  consumer opens it — a real app, **or** the Camera tab showing its live preview
  — it runs `scrcpy --video-source=camera --v4l2-sink=/dev/video9 …` with your
  current settings, and disconnects when the last consumer goes away.
* The feed follows the faster link (USB ⇄ Wi-Fi) live.

> Because nothing connects until an app opens the camera, the first frame arrives
> ~1–3 s after the app starts. Most apps tolerate a delayed first frame.

Camera settings live under a top-level **`camera`** block in `config.json` (the
webcam is global, not per-phone):

| key | meaning |
|-----|---------|
| `active_serial` | which phone; `""` = auto (USB phone first, else a saved IP) |
| `video_nr` | the `/dev/videoN` the loopback is created on (match `modprobe.d`) |
| `facing` | `back` / `front` / `external` (ignored if `camera_id` is set) |
| `camera_id` | explicit scrcpy `--camera-id` (overrides `facing`) |
| `resolution` | `"WxH"` or `""` for the camera default |
| `fps` | capture frame rate, `0` = default |
| `aspect_ratio` | e.g. `"16:9"`, `"sensor"`, or `""` |
| `zoom` | scrcpy `--camera-zoom` initial value |
| `high_speed` | scrcpy `--camera-high-speed` |
| `torch` | turn the camera torch on |
| `extra_args` | extra scrcpy args appended verbatim |

---

## Configuration (`config.json`)

`config.json` is **git-ignored** and generated from `config.example.json` on
install. Phones are **automatically added** the first time you plug them in,
keyed by their ADB serial and seeded from `defaults`.

Each phone entry supports:

* **`name`** — friendly name shown in notifications and the widgets.
* **`enabled`** — `false` to ignore this phone entirely.
* **`enable_tcpip`** / **`tcpip_port`** — arm wireless ADB on plug-in (default
  port `5555`), so the phone stays reachable over Wi-Fi until it reboots.
* **`launch_scrcpy`** — auto-mirror over USB on plug-in. Turn this **off** for a
  phone you mirror with the Phone Screen widget, so the daemon leaves that
  phone's mirror entirely to the widget.
* **`scrcpy_args`** — args passed to `scrcpy`. `defaults` ships with
  `["--turn-screen-off", "--stay-awake"]`; a device's own `scrcpy_args` are
  **appended** to (not a replacement for) the defaults.
* **`notify`** — desktop notifications (default `false`).
* **`unlock`** + **`lock_pin`** — auto-unlock before scrcpy (wakes, types the
  PIN). PIN/password only; left blank by default so nothing is typed.
* **`tether_failover`** / **`tether_function`** — USB-tethering failover and the
  USB function used (`rndis` default, or `ncm`).
* **`last_ip`** — the phone's LAN IP, **auto-updated on every USB connect** so the
  Wi-Fi fallback survives reboots. Not set by hand.
* **`mode`** / **`orientation`** / **`display_launcher`** / **`dex_desktop_mode`**
  — clone vs extended-display ("Phone (DEX)") behaviour for the daemon's own
  scrcpy launchers.
* **`kdeconnect_notify`** — post clickable KDE Connect notifications that open
  scrcpy and expand the phone's shade.

The config is re-read automatically whenever you edit and save it.

Example:

```json
{
    "defaults": {
        "enabled": true,
        "enable_tcpip": true,
        "tcpip_port": 5555,
        "launch_scrcpy": true,
        "scrcpy_args": ["--turn-screen-off", "--stay-awake"],
        "unlock": true,
        "lock_pin": ""
    },
    "devices": {
        "RFCY8112TKV": { "name": "Galaxy Z Fold", "lock_pin": "1234" }
    }
}
```

## Logs

```bash
journalctl --user -u linux-android-daemon.service -u linux-phonecam.service -f
```

## Security note

`lock_pin` is stored in plaintext in the local (git-ignored) `config.json`.
Anyone with read access to your home directory can read it. Don't commit it and
don't enable auto-unlock on a shared machine.
