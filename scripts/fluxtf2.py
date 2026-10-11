#!/usr/bin/env python3
"""The hub's commands for the Team Fortress 2 server's files. Each prints one JSON document.

    flux-tf2 files                     the game's own maps, custom maps, the map cycle, SourceMod (installed, on), its
                                       plugins, its admins, and the ban lists
    flux-tf2 map-install <file>        a .bsp (or .bsp.bz2) into custom/flux/maps
    flux-tf2 map-remove <name>         delete a custom map
    flux-tf2 set-mapcycle '<json>'     ["ctf_2fort", "pl_upward", ...] -> custom/flux/cfg/mapcycle_flux.txt,
                                       and `mapcyclefile mapcycle_flux.txt` in server.cfg
    flux-tf2 plugin-install <file>     a .smx into addons/sourcemod/plugins
    flux-tf2 plugin-enable <name> on|off   off = moved to plugins/disabled (SourceMod's own convention)
    flux-tf2 plugin-remove <name>      delete a plugin
    flux-tf2 set-admins '<json>'       [{"id": "<SteamID64 | STEAM_0:x:y | [U:1:n]>", "flags": "z", "immunity": 99,
                                       "name": "..."}] -> addons/sourcemod/configs/admins_simple.ini

Everything is on the data volume (/mnt/tf2/data), which the install's tf/custom and tf/addons
link to. Bans are the console's (banid/removeid + writeid): this only reads the two lists.
Names are file names, never paths: anything that would leave its folder is refused.
"""

import json
import os
import re
import shutil
import sys
import tempfile

DATA = os.environ.get("FLUX_DATA_DIR", "/mnt/tf2/data")
MAPS = os.path.join(DATA, "custom", "flux", "maps")
CFG = os.path.join(DATA, "custom", "flux", "cfg")
SERVER_CFG = os.path.join(CFG, "server.cfg")
MAPCYCLE = "mapcycle_flux.txt"
SM = os.path.join(DATA, "addons", "sourcemod")
PLUGINS = os.path.join(SM, "plugins")
DISABLED = os.path.join(PLUGINS, "disabled")
ADMINS = os.path.join(SM, "configs", "admins_simple.ini")
VDF = os.path.join(DATA, "addons", "metamod_x64.vdf")
STOCK_MAPS = os.path.join(os.environ.get("FLUX_SERVER_DIR", "/mnt/tf2/server"), "tf", "maps")

ADMINS_HEADER = """// Written by the Flux panel (runonflux/tf2-server-flux): one admin per line.
// "<SteamID>" "<immunity>:<flags>" // name    flags: z = root, see wiki.alliedmods.net/Adding_Admins_(SourceMod)
"""


def out(data):
    print(json.dumps(data, ensure_ascii=False))


def fail(message, code=2):
    out({"ok": False, "error": message})
    sys.exit(code)


def write_text(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".flux-")
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.write(text)
    os.replace(tmp, path)


def read(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            return f.read()
    except OSError:
        return None


def safe_name(name, pattern):
    name = os.path.basename(str(name or "").strip())
    if not re.fullmatch(pattern, name):
        fail(f"not an allowed file name: {name or '(empty)'}")
    return name


def listing(folder, suffixes):
    rows = []
    try:
        names = sorted(os.listdir(folder), key=str.lower)
    except OSError:
        return rows
    for n in names:
        p = os.path.join(folder, n)
        if os.path.isfile(p) and n.lower().endswith(suffixes):
            st = os.stat(p)
            rows.append({"file": n, "size": st.st_size, "modified": int(st.st_mtime)})
    return rows


# ------------------------------------------------------------------------------------------------
# SteamIDs: admins_simple.ini takes STEAM_0:x:y; owners paste a SteamID64 or a profile's [U:1:n]
# ------------------------------------------------------------------------------------------------

STEAM64_BASE = 76561197960265728


def steam2(value):
    """STEAM_0:x:y from a SteamID64, a [U:1:n] SteamID3 or a STEAM_x:y:z; None otherwise."""
    v = str(value or "").strip()
    m = re.fullmatch(r"STEAM_[0-5]:([01]):(\d{1,10})", v)
    if m:
        return f"STEAM_0:{m.group(1)}:{m.group(2)}"
    m = re.fullmatch(r"\[?U:1:(\d{1,10})\]?", v)
    if m:
        n = int(m.group(1))
        return f"STEAM_0:{n % 2}:{n // 2}"
    if re.fullmatch(r"7656119\d{10}", v):
        n = int(v) - STEAM64_BASE
        return f"STEAM_0:{n % 2}:{n // 2}" if n >= 0 else None
    return None


def steam64(value):
    """The SteamID64 of a STEAM_x:y:z or a [U:1:n] (TF2's writeid writes the latter, measured)."""
    m = re.fullmatch(r"STEAM_[0-5]:([01]):(\d+)", value or "")
    if m:
        return str(STEAM64_BASE + int(m.group(2)) * 2 + int(m.group(1)))
    m = re.fullmatch(r"\[U:1:(\d+)\]", value or "")
    return str(STEAM64_BASE + int(m.group(1))) if m else None


ADMIN_LINE = re.compile(r'^\s*"([^"]+)"\s+"([^"]*)"(?:\s+"([^"]*)")?\s*(?://\s*(.*))?$')


def parse_admins(text):
    admins = []
    for line in (text or "").splitlines():
        m = ADMIN_LINE.match(line)
        if not m:
            continue
        ident, perms = m.group(1), m.group(2)
        immunity, flags = (perms.split(":", 1) if ":" in perms else ("0", perms))
        admins.append({"id": ident, "steam64": steam64(ident), "flags": flags, "immunity": int(immunity) if immunity.isdigit() else 0,
                       "name": (m.group(4) or "").strip(), "password": bool(m.group(3))})
    return admins


# ------------------------------------------------------------------------------------------------
# Bans: banned_user.cfg (banid <minutes> <SteamID>) and banned_ip.cfg (addip <minutes> <ip>)
# ------------------------------------------------------------------------------------------------

def parse_bans(user_text, ip_text):
    bans = []
    for line in (user_text or "").splitlines():
        m = re.match(r"^\s*banid\s+(\d+(?:\.\d+)?)\s+(\S+)", line)
        if m:
            bans.append({"kind": "id", "id": m.group(2), "steam64": steam64(m.group(2)), "minutes": float(m.group(1))})
    for line in (ip_text or "").splitlines():
        m = re.match(r"^\s*addip\s+(\d+(?:\.\d+)?)\s+(\S+)", line)
        if m:
            bans.append({"kind": "ip", "id": m.group(2), "minutes": float(m.group(1))})
    return bans


def mapcycle():
    text = read(os.path.join(CFG, MAPCYCLE))
    return [l.strip() for l in (text or "").splitlines() if l.strip() and not l.strip().startswith("//")]


def cmd_files():
    sm_installed = os.path.isdir(os.path.join(SM, "bin"))
    out({
        "maps": listing(MAPS, (".bsp", ".bsp.bz2")),
        # The maps the game ships (tf/maps in the install): what changelevel takes with no download.
        "stock": sorted(n[:-4] for n in (os.listdir(STOCK_MAPS) if os.path.isdir(STOCK_MAPS) else []) if n.endswith(".bsp")),
        "mapcycle": mapcycle(),
        "mapcycleActive": bool(re.search(r'^\s*mapcyclefile\s+"?' + re.escape(MAPCYCLE), read(SERVER_CFG) or "", re.M)),
        "sourcemod": {"installed": sm_installed, "on": os.path.isfile(VDF)},
        "plugins": [dict(p, enabled=True) for p in listing(PLUGINS, (".smx",))] + [dict(p, enabled=False) for p in listing(DISABLED, (".smx",))],
        "admins": parse_admins(read(ADMINS)),
        "bans": parse_bans(read(os.path.join(DATA, "banned_user.cfg")), read(os.path.join(DATA, "banned_ip.cfg"))),
    })


def install(src, folder, name):
    if not os.path.isfile(src):
        fail("the uploaded file is not there")
    os.makedirs(folder, exist_ok=True)
    dst = os.path.join(folder, name)
    shutil.copyfile(src, dst + ".flux-new")
    os.replace(dst + ".flux-new", dst)
    return dst


def cmd_map_install(src):
    name = re.sub(r"^\d+-", "", os.path.basename(src))
    name = safe_name(name, r"[A-Za-z0-9_.-]{1,80}\.bsp(\.bz2)?")
    with open(src, "rb") as f:
        head = f.read(4)
    if name.endswith(".bsp") and head != b"VBSP":
        fail("not a Source map: a .bsp starts with VBSP")
    install(src, MAPS, name)
    out({"ok": True, "map": name.split(".")[0], "file": name})


def cmd_map_remove(name):
    name = safe_name(name, r"[A-Za-z0-9_.-]{1,80}\.bsp(\.bz2)?")
    try:
        os.remove(os.path.join(MAPS, name))
    except OSError:
        fail("no such map")
    out({"ok": True, "file": name})


def cmd_set_mapcycle(raw):
    try:
        maps = json.loads(raw)
    except ValueError:
        fail("not JSON")
    if not isinstance(maps, list) or not all(isinstance(m, str) and re.fullmatch(r"(workshop/\d{1,20}|[A-Za-z0-9_.-]{1,64})", m) for m in maps):
        fail("a list of map names (or workshop/<id>)")
    write_text(os.path.join(CFG, MAPCYCLE), "".join(f"{m}\n" for m in maps))
    cfg = read(SERVER_CFG) or ""
    line = f'mapcyclefile "{MAPCYCLE}"'
    if re.search(r"^\s*mapcyclefile\b.*$", cfg, re.M):
        cfg = re.sub(r"^\s*mapcyclefile\b.*$", line, cfg, flags=re.M)
    else:
        cfg = cfg.rstrip("\n") + ("\n" if cfg else "") + line + "\n"
    write_text(SERVER_CFG, cfg)
    out({"ok": True, "mapcycle": maps})


def cmd_plugin_install(src):
    name = re.sub(r"^\d+-", "", os.path.basename(src))
    name = safe_name(name, r"[A-Za-z0-9_.-]{1,80}\.smx")
    with open(src, "rb") as f:
        head = f.read(4)
    if head != b"FFPS":
        fail("not a compiled SourceMod plugin: a .smx starts with FFPS")
    for old in (os.path.join(DISABLED, name),):
        if os.path.exists(old):
            os.remove(old)
    install(src, PLUGINS, name)
    out({"ok": True, "plugin": name})


def cmd_plugin_enable(name, on):
    name = safe_name(name, r"[A-Za-z0-9_.-]{1,80}\.smx")
    on = str(on).lower() in ("1", "on", "true", "yes")
    src, dst = (os.path.join(DISABLED, name), os.path.join(PLUGINS, name)) if on else (os.path.join(PLUGINS, name), os.path.join(DISABLED, name))
    if not os.path.exists(src):
        if os.path.exists(dst):
            out({"ok": True, "plugin": name, "enabled": on})
            return
        fail("no such plugin")
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    os.replace(src, dst)
    out({"ok": True, "plugin": name, "enabled": on})


def cmd_plugin_remove(name):
    name = safe_name(name, r"[A-Za-z0-9_.-]{1,80}\.smx")
    removed = False
    for folder in (PLUGINS, DISABLED):
        try:
            os.remove(os.path.join(folder, name))
            removed = True
        except OSError:
            pass
    if not removed:
        fail("no such plugin")
    out({"ok": True, "plugin": name})


def cmd_set_admins(raw):
    try:
        admins = json.loads(raw)
    except ValueError:
        fail("not JSON")
    if not isinstance(admins, list):
        fail("a list of admins")
    lines = []
    seen = set()
    for a in admins:
        if not isinstance(a, dict):
            fail("each admin is an object")
        sid = steam2(a.get("id"))
        if not sid:
            fail(f"not a SteamID: {a.get('id')}")
        if sid in seen:
            continue
        seen.add(sid)
        flags = str(a.get("flags") or "z")
        if not re.fullmatch(r"[a-tz]{1,21}", flags):
            fail(f"SourceMod flags are letters a-t, or z for all: {flags}")
        immunity = int(a.get("immunity") or 0)
        if not 0 <= immunity <= 100:
            fail("immunity is 0 to 100")
        name = re.sub(r"[\r\n\"]", "", str(a.get("name") or "")).strip()[:60]
        lines.append(f'"{sid}" "{immunity}:{flags}"' + (f" // {name}" if name else ""))
    write_text(ADMINS, ADMINS_HEADER + "".join(f"{l}\n" for l in lines))
    out({"ok": True, "admins": parse_admins(read(ADMINS))})


def main(argv):
    commands = {
        "files": (cmd_files, 0), "map-install": (cmd_map_install, 1), "map-remove": (cmd_map_remove, 1),
        "set-mapcycle": (cmd_set_mapcycle, 1), "plugin-install": (cmd_plugin_install, 1),
        "plugin-enable": (cmd_plugin_enable, 2), "plugin-remove": (cmd_plugin_remove, 1),
        "set-admins": (cmd_set_admins, 1),
    }
    if not argv or argv[0] not in commands or len(argv) - 1 != commands[argv[0]][1]:
        print(__doc__, file=sys.stderr)
        return 64
    commands[argv[0]][0](*argv[1:])
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
