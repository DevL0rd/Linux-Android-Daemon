import json
import os

CONFIG_FILE = "config.json"

DEFAULTS = {
    "enabled": True,
    "enable_tcpip": True,
    "tcpip_port": 5555,
    "scrcpy_args": [],
    "stay_awake": False,     # opt-in: keep the phone awake while plugged into USB
    "screen_off": True,      # blank the phone's physical screen while viewing the mirror
    "notify": False,
    "unlock": True,
    "lock_pin": "",
    "tether_failover": False,
    "tether_function": "rndis",
    "last_ip": "",
    "display_launcher": "",
    "orientation": "portrait",
    "mode": "clone",
    "kdeconnect_notify": False
}

def load_config():
    if not os.path.exists(CONFIG_FILE):
        return {"defaults": dict(DEFAULTS), "devices": {}}
    with open(CONFIG_FILE, "r") as f:
        try:
            config = json.load(f)
        except Exception:
            return {"defaults": dict(DEFAULTS), "devices": {}}
    # Make sure the top level keys always exist
    config.setdefault("defaults", dict(DEFAULTS))
    config.setdefault("devices", {})
    return config

def save_config(config):
    with open(CONFIG_FILE, "w") as f:
        json.dump(config, f, indent=4)

def ensure_device_in_config(config, serial, model=""):
    changed = False
    if serial not in config["devices"]:
        # New phone seen for the first time: seed it from the defaults
        entry = dict(config.get("defaults", DEFAULTS))
        entry["name"] = model or serial
        config["devices"][serial] = entry
        changed = True
    return changed
