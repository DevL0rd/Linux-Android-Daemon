#!/bin/bash
set -e

echo "Stopping and disabling systemd user service..."
systemctl --user disable --now linux-android-daemon.service 2>/dev/null || true

echo "Removing service file..."
rm -f ~/.config/systemd/user/linux-android-daemon.service
systemctl --user daemon-reload

# --- Phone Camera (virtual webcam) ---------------------------------------
echo "Stopping the phone-camera daemon..."
systemctl --user disable --now linux-phonecam.service 2>/dev/null || true
rm -f ~/.config/systemd/user/linux-phonecam.service
systemctl --user daemon-reload 2>/dev/null || true

echo "Stopping any pinned Phone Screen mirror + removing its KWin rule..."
"$HOME/.local/bin/phonescreenctl" hide 2>/dev/null || true
"$HOME/.local/bin/phonescreenctl" rule-clear 2>/dev/null || true

echo "Removing the ydotool daemon + helper bits (leaving the ydotool/kdotool packages)..."
systemctl --user disable --now ydotoold.service 2>/dev/null || true
rm -f "$HOME/.config/systemd/user/ydotoold.service"
rm -f "$HOME/.config/environment.d/ydotool.conf"
systemctl --user unset-environment YDOTOOL_SOCKET 2>/dev/null || true
systemctl --user daemon-reload 2>/dev/null || true
if command -v sudo >/dev/null 2>&1; then
    sudo rm -f /etc/udev/rules.d/99-uinput-ydotool.rules /etc/modules-load.d/uinput.conf 2>/dev/null || true
fi

echo "Removing phonecamctl + phonescreenctl + applets..."
rm -f "$HOME/.local/bin/phonecamctl" "$HOME/.local/bin/phonescreenctl"
rm -f "$HOME/.config/environment.d/linux-android-daemon.conf"
systemctl --user unset-environment QML_XHR_ALLOW_FILE_READ 2>/dev/null || true
for id in org.devl0rd.phonecam org.devl0rd.phonescreen; do
    kpackagetool6 -t Plasma/Applet -r "$id" >/dev/null 2>&1 \
        && echo "  removed $id" || true
done

echo "Removing the v4l2loopback 'Phone Camera' device (needs sudo)..."
if command -v sudo >/dev/null 2>&1; then
    sudo rm -f /etc/modprobe.d/linux-phonecam.conf /etc/modules-load.d/linux-phonecam.conf
    sudo modprobe -r v4l2loopback 2>/dev/null || true
fi

rm -rf "${XDG_RUNTIME_DIR:-/tmp}/Linux-Android-Daemon" 2>/dev/null || true

# Requirements are intentionally LEFT installed — they're general-purpose tools,
# not owned by this project. Remove them yourself with pacman if you truly want:
#   sudo pacman -Rns android-tools scrcpy ffmpeg v4l2loopback-dkms v4l2loopback-utils
echo "  (left requirements installed: adb/android-tools, scrcpy, ffmpeg, v4l2loopback)"

echo "Uninstallation complete!"
