#!/bin/bash
set -e

REPO_DIR=$(pwd)
if [ ! -f "$REPO_DIR/src/daemon.py" ]; then
    echo "Please run this script from the repository directory."
    exit 1
fi

# Install the tools the daemon shells out to (official repos: pacman).
#   adb  -> android-tools     scrcpy -> scrcpy     preview/feed -> ffmpeg
# (v4l2loopback for the virtual webcam is installed in the Phone Camera step below.)
echo "Checking dependencies..."
deps=()
pacman -Qq android-tools >/dev/null 2>&1 || deps+=(android-tools)
pacman -Qq scrcpy        >/dev/null 2>&1 || deps+=(scrcpy)
pacman -Qq ffmpeg        >/dev/null 2>&1 || deps+=(ffmpeg)
if [ ${#deps[@]} -gt 0 ]; then
    echo "Installing: ${deps[*]} (needs sudo)..."
    sudo pacman -S --needed "${deps[@]}" || \
        echo "  ! could not install ${deps[*]} — install them manually before using the service"
else
    echo "  base dependencies present (adb, scrcpy, ffmpeg)."
fi

# Generate the local (git-ignored) config from the template on first install.
# It holds per-device settings and the optional lock PIN, so it never goes in git.
if [ ! -f "$REPO_DIR/config.json" ]; then
    cp "$REPO_DIR/config.example.json" "$REPO_DIR/config.json"
    echo "Created config.json from config.example.json."
    echo "  -> To auto-unlock, set \"lock_pin\" in config.json (it is git-ignored)."
fi

echo "Setting up systemd user service..."
mkdir -p ~/.config/systemd/user

cat <<EOF > ~/.config/systemd/user/linux-android-daemon.service
[Unit]
Description=Linux-Android-Daemon (wireless ADB + scrcpy + USB tethering failover)
After=graphical-session.target

[Service]
Type=simple
WorkingDirectory=$REPO_DIR
ExecStart=/usr/bin/python3 $REPO_DIR/src/daemon.py
Restart=always
RestartSec=3
Environment=PYTHONUNBUFFERED=1
Environment=PYTHONPATH=$REPO_DIR/src

[Install]
WantedBy=default.target
EOF

systemctl --user daemon-reload
systemctl --user enable --now linux-android-daemon.service

# ===========================================================================
# Phone-as-webcam: v4l2loopback "Phone Camera" + on-demand daemon + tray applet
# This part needs root (kernel module) and reloads Plasma at the end. It is
# guarded so a hiccup here never undoes the screen-mirror daemon set up above.
# ===========================================================================
echo ""
echo "Setting up the Phone Camera (virtual webcam)..."

VIDEO_NR=9

# 1. v4l2loopback (the virtual camera kernel module) from the official repos
if ! pacman -Qq v4l2loopback-dkms >/dev/null 2>&1; then
    echo "Installing v4l2loopback-dkms + utils (needs sudo)..."
    sudo pacman -S --needed v4l2loopback-dkms v4l2loopback-utils || \
        echo "  ! could not install v4l2loopback — the webcam won't work until it is installed"
fi

# 2. Make the loopback device persistent and named, created on boot
if command -v sudo >/dev/null 2>&1 && pacman -Qq v4l2loopback-dkms >/dev/null 2>&1; then
    echo "Writing /etc/modprobe.d + /etc/modules-load.d for the 'Phone Camera' device (sudo)..."
    sudo tee /etc/modprobe.d/linux-phonecam.conf >/dev/null <<EOF
# Linux-Android-Daemon :: phone webcam sink.
# exclusive_caps=0 keeps the device always visible so apps can select it while
# idle (selecting/opening it is what wakes the on-demand feed).
options v4l2loopback video_nr=$VIDEO_NR card_label="Phone Camera" exclusive_caps=0 max_width=4096 max_height=4096
EOF
    echo v4l2loopback | sudo tee /etc/modules-load.d/linux-phonecam.conf >/dev/null

    # Load it now (reload if it's loaded without our device present and not busy)
    if [ -z "$(python3 -c "import sys;sys.path.insert(0,'$REPO_DIR/src');from core import camera as c;print(c.loopback_devnode($VIDEO_NR) or '')" 2>/dev/null)" ]; then
        sudo modprobe -r v4l2loopback 2>/dev/null || true
        sudo modprobe v4l2loopback || echo "  ! modprobe v4l2loopback failed (a reboot will load it from modules-load.d)"
    fi
fi

# 3. phonecamctl + phonescreenctl onto PATH (symlinked back to the repo)
BIN_DIR="$HOME/.local/bin"
mkdir -p "$BIN_DIR"
chmod +x "$REPO_DIR/bin/phonecamctl" "$REPO_DIR/bin/phonescreenctl"
ln -sf "$REPO_DIR/bin/phonecamctl" "$BIN_DIR/phonecamctl"
ln -sf "$REPO_DIR/bin/phonescreenctl" "$BIN_DIR/phonescreenctl"
echo "Linked phonecamctl + phonescreenctl into $BIN_DIR"

# 4. let the applet read the tmpfs status snapshot in-process via QML XHR
mkdir -p "$HOME/.config/environment.d"
echo 'QML_XHR_ALLOW_FILE_READ=1' > "$HOME/.config/environment.d/linux-android-daemon.conf"
systemctl --user set-environment QML_XHR_ALLOW_FILE_READ=1 2>/dev/null || true

# 5. the on-demand camera daemon (separate service; does NOT auto-launch on plug-in)
cat <<EOF > ~/.config/systemd/user/linux-phonecam.service
[Unit]
Description=Linux-Android-Daemon phone webcam (on-demand camera feed)
After=graphical-session.target

[Service]
Type=simple
WorkingDirectory=$REPO_DIR
ExecStart=/usr/bin/python3 $REPO_DIR/src/camera_daemon.py
Restart=always
RestartSec=3
Environment=PYTHONUNBUFFERED=1
Environment=PYTHONPATH=$REPO_DIR/src

[Install]
WantedBy=default.target
EOF
systemctl --user daemon-reload
systemctl --user enable --now linux-phonecam.service >/dev/null 2>&1 \
    && echo "Enabled linux-phonecam.service" \
    || echo "  ! could not enable linux-phonecam.service — enable it manually"

# 6. install the plasmoids (tray Phone Camera + desktop Phone Screen)
if command -v kpackagetool6 >/dev/null 2>&1; then
    echo "Installing the Plasma widgets..."
    for d in "$REPO_DIR"/plasmoids/org.devl0rd.phonecam "$REPO_DIR"/plasmoids/org.devl0rd.phonescreen; do
        id=$(basename "$d")
        if kpackagetool6 -t Plasma/Applet -u "$d" >/dev/null 2>&1; then
            echo "  upgraded $id"
        else
            kpackagetool6 -t Plasma/Applet -i "$d" >/dev/null 2>&1 \
                && echo "  installed $id" \
                || echo "  ! applet install failed — run: kpackagetool6 -t Plasma/Applet -i $d"
        fi
    done
else
    echo "  ! kpackagetool6 not found — install the applets manually from plasmoids/"
fi

# 7. "Turn the phone panel off after an in-widget unlock" for Phone Screen.
#    Unlocking wakes the phone's panel; to put it back to sleep WITHOUT reopening
#    scrcpy we press scrcpy's MOD+o shortcut, which needs to inject a key into the
#    (native-Wayland) mirror window. That takes ydotool (uinput key injection) +
#    kdotool (focus the window on KWin). All optional — skipped if it can't be set
#    up, and the only cost is the panel staying on after unlock.
echo ""
echo "Setting up ydotool + kdotool (Phone Screen: panel-off after unlock)..."
if ! command -v ydotool >/dev/null 2>&1; then
    sudo pacman -S --needed --noconfirm ydotool 2>/dev/null \
        || echo "  ! could not install ydotool (panel-off-after-unlock will be skipped)"
fi
if ! command -v kdotool >/dev/null 2>&1; then
    if command -v paru >/dev/null 2>&1; then
        paru -S --needed --noconfirm kdotool 2>/dev/null \
            || echo "  ! could not install kdotool from the AUR (panel-off-after-unlock will be skipped)"
    else
        echo "  ! paru not found — install 'kdotool' from the AUR for panel-off-after-unlock"
    fi
fi
# uinput module (ydotool injects through it), now + on every boot
lsmod | grep -q '^uinput' || sudo modprobe uinput 2>/dev/null || echo "  ! could not load uinput"
echo uinput | sudo tee /etc/modules-load.d/uinput.conf >/dev/null 2>&1 || true
# let your user open /dev/uinput (group 'input')
sudo tee /etc/udev/rules.d/99-uinput-ydotool.rules >/dev/null 2>&1 <<'EOF' || true
KERNEL=="uinput", GROUP="input", MODE="0660", OPTIONS+="static_node=uinput"
EOF
sudo udevadm control --reload-rules 2>/dev/null && sudo udevadm trigger 2>/dev/null || true
if ! id -nG "$USER" | grep -qw input; then
    sudo usermod -aG input "$USER" 2>/dev/null \
        && echo "  added $USER to the 'input' group — LOG OUT/IN once for it to take effect" || true
fi
# ydotoold user daemon (owns the socket ydotool talks to)
if command -v ydotoold >/dev/null 2>&1; then
    cat > "$HOME/.config/systemd/user/ydotoold.service" <<EOF
[Unit]
Description=ydotool daemon (virtual input for Phone Screen)
After=graphical-session.target

[Service]
ExecStart=/usr/bin/ydotoold --socket-path=%t/.ydotool_socket --socket-own=$(id -u):$(id -g)
Restart=always
RestartSec=3

[Install]
WantedBy=default.target
EOF
    echo "YDOTOOL_SOCKET=\"$XDG_RUNTIME_DIR/.ydotool_socket\"" > "$HOME/.config/environment.d/ydotool.conf"
    systemctl --user set-environment YDOTOOL_SOCKET="$XDG_RUNTIME_DIR/.ydotool_socket" 2>/dev/null || true
    systemctl --user daemon-reload || true
    systemctl --user enable --now ydotoold.service 2>/dev/null \
        && echo "  ydotoold running" \
        || echo "  ! could not start ydotoold — run: systemctl --user enable --now ydotoold.service"
fi

# The daemon now owns the Phone Screen pinned mirror, so it needs the graphical
# session env (KWin minimize, xprop fullscreen, ydotool screen-off). Import those
# into the user manager and restart the daemon so it inherits them.
systemctl --user import-environment DISPLAY WAYLAND_DISPLAY YDOTOOL_SOCKET QML_XHR_ALLOW_FILE_READ 2>/dev/null || true
systemctl --user restart linux-android-daemon.service 2>/dev/null || true

echo ""
echo "Done!"
echo "  Screen mirror : plug in over USB (wireless adb + scrcpy), or the 'Phone' shortcut."
echo "  Webcam        : add the 'Phone Camera' widget to your system tray / panel."
echo "                  It connects the phone only when an app uses the camera"
echo "                  (or while the popup is open), and follows USB<->WiFi live."
echo "  Desktop screen: add the 'Phone Screen' widget directly to your desktop."
echo "                  Press Show to pin the real (interactive) scrcpy mirror over"
echo "                  it; it stays connected and auto-picks USB/Wi-Fi."
echo "  Edit config.json to tweak per-phone behavior; camera settings live under \"camera\"."
echo "  Logs: journalctl --user -u linux-android-daemon.service -u linux-phonecam.service -f"

# reload Plasma so the new applet shows up (unless --no-reload)
if ! printf '%s\n' "$@" | grep -qx -- --no-reload; then
    echo "Reloading Plasma…"
    # plasmashell may be run by plasma-plasmashell.service OR as an app-plasmashell@<hash>
    # scope (then plasma-plasmashell.service is inactive and "restarting" it just spawns a
    # doomed duplicate). Restart the unit only when it actually runs the shell; otherwise
    # quit + relaunch the running instance directly.
    if systemctl --user --quiet is-active plasma-plasmashell.service; then
        systemctl --user restart plasma-plasmashell.service
    else
        kquitapp6 plasmashell 2>/dev/null; (kstart plasmashell >/dev/null 2>&1 &)
    fi
fi
