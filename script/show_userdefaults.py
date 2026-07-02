#!/usr/bin/env python3
import json
import os
import plistlib
import subprocess
import sys

DOMAIN = "app.monitorflux.MonitorFlux"
KEY = "MonitorFlux.preferences.v1"
PLIST_PATH = os.path.expanduser(f"~/Library/Preferences/{DOMAIN}.plist")


def load_domain():
    result = subprocess.run(
        ["/usr/bin/defaults", "export", DOMAIN, "-"],
        capture_output=True,
    )
    if result.returncode == 0:
        return plistlib.loads(result.stdout)
    if os.path.exists(PLIST_PATH):
        with open(PLIST_PATH, "rb") as plist:
            return plistlib.load(plist)
    sys.exit(f"No UserDefaults found for {DOMAIN}")


def main():
    domain = load_domain()
    value = domain.get(KEY)
    if value is None:
        sys.exit(f"{KEY} not found in {DOMAIN}")
    if isinstance(value, bytes):
        value = value.decode("utf-8")
    print(json.dumps(json.loads(value), indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
