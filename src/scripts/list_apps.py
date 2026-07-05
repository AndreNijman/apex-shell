#!/usr/bin/env python3
import os, json, re, configparser

def main():
    # Build the app dir list from the XDG base-dir spec so we pick up flatpak
    # exports (/var/lib/flatpak/exports/share, ~/.local/share/flatpak/exports/
    # share) and everything else on XDG_DATA_DIRS. The old hard-coded list only
    # had /usr/share + ~/.local/share, so flatpak apps (Modrinth, etc.) were
    # never listed. Order follows the spec: XDG_DATA_HOME first (user overrides
    # win via the `seen` de-dupe), then XDG_DATA_DIRS in order.
    data_home = os.environ.get("XDG_DATA_HOME") or os.path.expanduser("~/.local/share")
    data_dirs = os.environ.get("XDG_DATA_DIRS") or "/usr/local/share:/usr/share"

    bases = [data_home] + data_dirs.split(":")
    # Belt-and-suspenders: ensure flatpak exports are present even if
    # XDG_DATA_DIRS is unset/stripped in the launching environment.
    bases += [
        "/var/lib/flatpak/exports/share",
        os.path.expanduser("~/.local/share/flatpak/exports/share"),
    ]

    dirs = []
    for base in bases:
        base = base.strip()
        if not base:
            continue
        d = os.path.join(base, "applications")
        if d not in dirs:
            dirs.append(d)

    apps, seen = [], set()

    for d in dirs:
        if not os.path.isdir(d):
            continue
        for fname in sorted(os.listdir(d)):
            if not fname.endswith(".desktop") or fname in seen:
                continue
            seen.add(fname)
            try:
                cp = configparser.ConfigParser(interpolation=None, strict=False)
                cp.read(os.path.join(d, fname), encoding="utf-8")
                if not cp.has_section("Desktop Entry"):
                    continue
                de = cp["Desktop Entry"]
                if de.get("Type", "")              != "Application": continue
                if de.get("NoDisplay", "false").lower() == "true":   continue
                if de.get("Hidden",    "false").lower() == "true":   continue

                name  = de.get("Name", "").strip()
                exec_ = re.sub(r"%[a-zA-Z]", "", de.get("Exec", "")).strip()
                if not name or not exec_:
                    continue

                apps.append({
                    "name":       name,
                    "exec":       exec_,
                    "icon":       de.get("Icon", ""),
                    "categories": de.get("Categories", "")
                })
            except Exception:
                continue

    apps.sort(key=lambda a: a["name"].lower())
    print(json.dumps(apps))

main()
