#!/usr/bin/env python3
"""The hub's commands for the Team Fortress 2 server's files. Each prints one JSON document.

    flux-tf2 files                     the game's own maps, custom maps, the map cycle, SourceMod (installed, on), its
                                       plugins, its admins, and the ban lists
    flux-tf2 map-install <file>        a .bsp into custom/flux/maps; a .bsp.bz2 is unpacked first (srcds
                                       loads only plain .bsp: .bz2 is for FastDL web servers)
    flux-tf2 map-remove <name>         delete a custom map, and take it out of the map cycle
    flux-tf2 set-mapcycle '<json>'     ["ctf_2fort", "pl_upward", ...] -> custom/flux/cfg/mapcycle_flux.txt,
                                       and `mapcyclefile mapcycle_flux.txt` in server.cfg; [] goes back to the
                                       game's own cycle (file and line removed)
    flux-tf2 plugin-install <file>     a .smx into addons/sourcemod/plugins
    flux-tf2 plugin-enable <name> on|off   off = moved to plugins/disabled (SourceMod's own convention)
    flux-tf2 plugin-remove <name>      delete a plugin
    flux-tf2 set-admins '<json>'       [{"id": "<SteamID64 | STEAM_0:x:y | [U:1:n]>", "flags": "z" | "@Group", "immunity": 99,
                                       "name": "..."}] -> addons/sourcemod/configs/admins_simple.ini, MERGED: the
                                       SteamID admins listed are written (a password the line had is kept), the
                                       SteamID admins left out are removed, and every other line (comments, IP or
                                       name admins, lines this cannot read) is kept as it is, where it is
    flux-tf2 backups                   the backups in flux/backups: name, size, date, why it was made
    flux-tf2 restore <backup>          restore one: the server quits, a safety backup of what is there now is
                                       taken, the backup replaces custom/, addons/, cfg-sourcemod/ and the ban lists,
                                       and the server starts again (the supervisor does it: ./flux-entrypoint.sh)

For the supervisor (not the hub):
    fluxtf2.py backup <why> [force]    a backup of the data volume, unless one is younger than
                                       FLUX_BACKUP_MIN_AGE_MINUTES (60) and `force` is not given; then pruning
    fluxtf2.py apply-restore           a restore the hub asked for, before the server starts

Everything is on the data volume (/mnt/tf2/data), which the install's tf/custom and tf/addons
link to. Bans are the console's (banid/removeid + writeid): this only reads the two lists.
Names are file names, never paths: anything that would leave its folder is refused.
"""

import bz2
import calendar
import json
import os
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import time

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
STATE_DIR = os.path.join(DATA, "flux")
BACKUPS = os.path.join(STATE_DIR, "backups")
BACKUP_REASONS = os.path.join(BACKUPS, "reasons.json")
RESTORE_REQUEST = os.path.join(STATE_DIR, "restore-request")
RESTART_MARKER = os.environ.get("FLUX_RESTART_MARKER", "/tmp/flux-restart-requested")
GENERATION_FILE = os.environ.get("FLUX_GENERATION_FILE", "/tmp/flux-generation")
# What a backup holds: the owner's part of tf/, all on the data volume. SourceMod's logs are left
# out (they only grow); the game itself is downloaded again on any node.
BACKUP_ITEMS = ["custom", "addons", "cfg-sourcemod", "banned_user.cfg", "banned_ip.cfg"]
BACKUP_EXCLUDE = re.compile(r"^addons/sourcemod/(logs|data/sqlite/.*\.sq3-journal)(/|$)")
BACKUP_NAME = re.compile(r"^\d{8}-\d{6}-tf2\.tar\.gz$")

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
GROUP = re.compile(r"@[^\"\r\n]{1,60}")
FLAGS = re.compile(r"[a-tz]{1,21}")


def split_perms(perms):
    """admins_simple.ini's second field: "<flags>", "<immunity>:<flags>", "@Group" or
    "<immunity>:@Group". Returns (immunity, flags, group)."""
    immunity, rest = 0, perms.strip()
    m = re.fullmatch(r"(\d{1,3}):(.*)", rest)
    if m:
        immunity, rest = int(m.group(1)), m.group(2)
    if rest.startswith("@"):
        return immunity, "", rest
    return immunity, rest, None


def parse_admin_lines(text):
    """Every line of admins_simple.ini, each either an admin this panel edits (by SteamID) or kept
    as it is: comments, blank lines, IP (!1.2.3.4) and name admins, and anything unreadable."""
    rows = []
    for line in (text or "").splitlines():
        m = ADMIN_LINE.match(line)
        ident = m.group(1) if m else None
        if m and steam2(ident):
            immunity, flags, group = split_perms(m.group(2))
            rows.append({"kind": "admin", "line": line, "id": ident, "sid": steam2(ident), "steam64": steam64(ident) or steam64(steam2(ident)),
                         "flags": group or flags, "group": bool(group), "immunity": immunity,
                         "name": (m.group(4) or "").strip(), "password": m.group(3)})
        elif m:
            rows.append({"kind": "other", "line": line, "id": ident, "admin": True})
        else:
            rows.append({"kind": "other", "line": line, "admin": False})
    return rows


def parse_admins(text):
    """The admins for the hub: the editable ones by SteamID, and the others read-only (`raw`)."""
    admins = []
    for r in parse_admin_lines(text):
        if r["kind"] == "admin":
            admins.append({"id": r["id"], "steam64": r["steam64"], "flags": r["flags"], "group": r["group"],
                           "immunity": r["immunity"], "name": r["name"], "password": bool(r["password"]), "editable": True})
        elif r.get("admin"):
            admins.append({"id": r["id"], "raw": r["line"], "editable": False})
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


def generation():
    """(number, epoch) of the server the supervisor runs now: a restart is over when it changes."""
    parts = (read(GENERATION_FILE) or "").split()
    return {"n": int(parts[0]), "since": int(parts[1])} if len(parts) == 2 and all(p.isdigit() for p in parts) else None


def cmd_files():
    sm_installed = os.path.isdir(os.path.join(SM, "bin"))
    out({
        "generation": generation(),
        "maps": listing(MAPS, (".bsp",)),
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


# The most a .bsp may be after unpacking a .bz2 (the hub's upload cap is 1 GB): a bomb stops here.
MAX_MAP_BYTES = 1024 * 1024 * 1024


def cmd_map_install(src):
    name = re.sub(r"^\d+-", "", os.path.basename(src))
    name = safe_name(name, r"[A-Za-z0-9_.-]{1,80}\.bsp(\.bz2)?")
    if not os.path.isfile(src):
        fail("the uploaded file is not there")
    if name.endswith(".bz2"):
        # srcds loads plain .bsp only; .bz2 is what FastDL web servers hand players. Unpacked
        # here, checked, and kept as the .bsp it is.
        name = name[:-4]
        plain = src + ".flux-bsp"
        try:
            with bz2.open(src, "rb") as f, open(plain, "wb") as o:
                total = 0
                while True:
                    chunk = f.read(1024 * 1024)
                    if not chunk:
                        break
                    total += len(chunk)
                    if total > MAX_MAP_BYTES:
                        fail("the map unpacks to more than 1 GB")
                    o.write(chunk)
        except (OSError, EOFError, ValueError):
            try:
                os.remove(plain)
            except OSError:
                pass
            fail("not a bzip2 file: a .bsp.bz2 is a map compressed with bzip2")
        src = plain
    try:
        with open(src, "rb") as f:
            head = f.read(4)
        if head != b"VBSP":
            fail("not a Source map: a .bsp starts with VBSP")
        install(src, MAPS, name)
    finally:
        if src.endswith(".flux-bsp"):
            try:
                os.remove(src)
            except OSError:
                pass
    # An older .bz2 copy of the same map (image 1.0.1 kept them) is useless to srcds: gone.
    try:
        os.remove(os.path.join(MAPS, name + ".bz2"))
    except OSError:
        pass
    out({"ok": True, "map": name[:-4], "file": name, "size": os.path.getsize(os.path.join(MAPS, name))})


def cmd_map_remove(name):
    name = safe_name(name, r"[A-Za-z0-9_.-]{1,80}\.bsp(\.bz2)?")
    try:
        os.remove(os.path.join(MAPS, name))
    except OSError:
        fail("no such map")
    # A map that is gone cannot stay in the cycle: the server would skip it with an error at
    # every turn.
    map_name = re.sub(r"\.bsp(\.bz2)?$", "", name)
    cycle = mapcycle()
    if map_name in cycle:
        write_mapcycle([m for m in cycle if m != map_name])
    out({"ok": True, "file": name, "mapcycle": mapcycle()})


def write_mapcycle(maps):
    """The cycle file and the `mapcyclefile` line; an empty cycle removes both (the game's own
    mapcycle.txt again)."""
    cfg = read(SERVER_CFG) or ""
    if not maps:
        try:
            os.remove(os.path.join(CFG, MAPCYCLE))
        except OSError:
            pass
        cfg = re.sub(r"^\s*mapcyclefile\b.*\n?", "", cfg, flags=re.M)
        write_text(SERVER_CFG, cfg)
        return
    write_text(os.path.join(CFG, MAPCYCLE), "".join(f"{m}\n" for m in maps))
    line = f'mapcyclefile "{MAPCYCLE}"'
    if re.search(r"^\s*mapcyclefile\b.*$", cfg, re.M):
        cfg = re.sub(r"^\s*mapcyclefile\b.*$", line, cfg, flags=re.M)
    else:
        cfg = cfg.rstrip("\n") + ("\n" if cfg else "") + line + "\n"
    write_text(SERVER_CFG, cfg)


def cmd_set_mapcycle(raw):
    try:
        maps = json.loads(raw)
    except ValueError:
        fail("not JSON")
    if not isinstance(maps, list) or not all(isinstance(m, str) and re.fullmatch(r"(workshop/\d{1,20}|[A-Za-z0-9_.-]{1,64})", m) for m in maps):
        fail("a list of map names (or workshop/<id>)")
    write_mapcycle(maps)
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
    """Deletes a plugin. A SourceMod stock plugin removed here (or through the Files tab) stays
    removed: the supervisor's SourceMod update skips a stock plugin it installed before and finds
    gone (flux-entrypoint.sh place_plugins, addons/sourcemod/.flux-stock-plugins)."""
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


def render_admin(sid, flags, immunity, name, password):
    perms = flags if (flags.startswith("@") and not immunity) else f"{immunity}:{flags}"
    line = f'"{sid}" "{perms}"' + (f' "{password}"' if password else "")
    return line + (f" // {name}" if name else "")


def cmd_set_admins(raw):
    try:
        admins = json.loads(raw)
    except ValueError:
        fail("not JSON")
    if not isinstance(admins, list):
        fail("a list of admins")
    wanted = {}
    for a in admins:
        if not isinstance(a, dict):
            fail("each admin is an object")
        sid = steam2(a.get("id"))
        if not sid:
            fail(f"not a SteamID: {a.get('id')}")
        flags = str(a.get("flags") or "z").strip()
        if not (FLAGS.fullmatch(flags) or GROUP.fullmatch(flags)):
            fail(f"SourceMod flags are letters a-t, z for all, or a group as @Name: {flags}")
        try:
            immunity = int(a.get("immunity") or 0)
        except (TypeError, ValueError):
            fail("immunity is a number")
        if not 0 <= immunity <= 100:
            fail("immunity is 0 to 100")
        name = re.sub(r"[\r\n\"]", "", str(a.get("name") or "")).strip()[:60]
        wanted.setdefault(sid, (flags, immunity, name))
    existing = read(ADMINS)
    lines, done = [], set()
    if existing is None:
        lines = ADMINS_HEADER.splitlines()
    for r in parse_admin_lines(existing):
        if r["kind"] != "admin":
            lines.append(r["line"])
            continue
        if r["sid"] in wanted and r["sid"] not in done:
            flags, immunity, name = wanted[r["sid"]]
            lines.append(render_admin(r["id"], flags, immunity, name, r["password"]))
            done.add(r["sid"])
        # A SteamID admin left out of the list is removed: that is the panel's remove button.
    for sid, (flags, immunity, name) in wanted.items():
        if sid not in done:
            lines.append(render_admin(sid, flags, immunity, name, None))
    write_text(ADMINS, "".join(f"{l}\n" for l in lines))
    out({"ok": True, "admins": parse_admins(read(ADMINS))})


# ------------------------------------------------------------------------------------------------
# Backups and restores. A backup is a .tar.gz of the owner's part of tf/ (BACKUP_ITEMS). The
# supervisor makes one on start (unless one is younger than FLUX_BACKUP_MIN_AGE_MINUTES) and every
# FLUX_BACKUP_HOURS; pruning keeps the newest FLUX_BACKUP_KEEP and, whatever happens in between,
# the newest one older than a day and the newest one older than a week, so a server that keeps
# restarting can never rotate every good backup away.
# ------------------------------------------------------------------------------------------------

def backup_rows():
    reasons = {}
    try:
        reasons = json.load(open(BACKUP_REASONS)) or {}
    except (OSError, ValueError):
        pass
    rows = []
    for n in os.listdir(BACKUPS) if os.path.isdir(BACKUPS) else []:
        if BACKUP_NAME.match(n):
            st = os.stat(os.path.join(BACKUPS, n))
            stamp = calendar.timegm(time.strptime(n[:15], "%Y%m%d-%H%M%S"))
            rows.append({"name": n, "size": st.st_size, "created": int(stamp), "reason": reasons.get(n)})
    return sorted(rows, key=lambda r: r["name"], reverse=True)


def backups_to_prune(rows, keep, now):
    """rows newest first. Keep the newest `keep`, plus the newest one older than a day and the
    newest one older than a week. Returns the names to delete."""
    kept = {r["name"] for r in rows[:max(keep, 1)]}
    for age in (86400, 7 * 86400):
        older = next((r for r in rows if now - r["created"] >= age), None)
        if older:
            kept.add(older["name"])
    return [r["name"] for r in rows if r["name"] not in kept]


def cmd_backups():
    out({"backups": backup_rows(), "pendingRestore": read(RESTORE_REQUEST).strip() if read(RESTORE_REQUEST) else None})


def make_backup(reason):
    os.makedirs(BACKUPS, exist_ok=True)
    name = time.strftime("%Y%m%d-%H%M%S", time.gmtime()) + "-tf2.tar.gz"
    path = os.path.join(BACKUPS, name)
    while os.path.exists(path):  # two in the same second (a restore's safety backup)
        time.sleep(1)
        name = time.strftime("%Y%m%d-%H%M%S", time.gmtime()) + "-tf2.tar.gz"
        path = os.path.join(BACKUPS, name)
    part = path + ".part"

    def skip(info):
        rel = info.name
        return None if BACKUP_EXCLUDE.match(rel) else info

    with tarfile.open(part, "w:gz") as tar:
        for item in BACKUP_ITEMS:
            src = os.path.join(DATA, item)
            if os.path.lexists(src):
                tar.add(src, arcname=item, filter=skip)
    os.replace(part, path)
    try:
        reasons = json.load(open(BACKUP_REASONS)) if os.path.exists(BACKUP_REASONS) else {}
    except (OSError, ValueError):
        reasons = {}
    reasons[name] = reason
    names = {r["name"] for r in backup_rows()}
    write_text(BACKUP_REASONS, json.dumps({k: v for k, v in reasons.items() if k in names or k == name}))
    return name


def cmd_backup(reason, force=None):
    rows = backup_rows()
    min_age = int(os.environ.get("FLUX_BACKUP_MIN_AGE_MINUTES", "60") or 60) * 60
    now = time.time()
    if force != "force" and rows and now - rows[0]["created"] < min_age:
        out({"ok": True, "skipped": f"a backup from {int((now - rows[0]['created']) // 60)} min ago is recent enough"})
        return
    name = make_backup(reason)
    pruned = backups_to_prune(backup_rows(), int(os.environ.get("FLUX_BACKUP_KEEP", "10") or 10), now)
    for n in pruned:
        try:
            os.remove(os.path.join(BACKUPS, n))
        except OSError:
            pass
    out({"ok": True, "backup": name, "size": os.path.getsize(os.path.join(BACKUPS, name)), "pruned": pruned})


def cmd_restore(name):
    name = os.path.basename(str(name or "").strip())
    if not BACKUP_NAME.match(name):
        fail("not a backup name")
    if not os.path.isfile(os.path.join(BACKUPS, name)):
        fail("no such backup")
    write_text(RESTORE_REQUEST, name + "\n")
    # The supervisor restores between two servers: the running one quits (exit 0, a requested
    # restart), and the next start applies the request before the server runs.
    write_text(RESTART_MARKER, f"requested: restore {name}\n")
    try:
        sent = subprocess.run(["flux-console", "quit"], capture_output=True, text=True, timeout=30).returncode == 0
    except (OSError, subprocess.TimeoutExpired):
        sent = False
    out({"ok": True, "restoring": name, "serverQuit": sent,
         "note": None if sent else "The server is not running: the backup is restored when it next starts."})


def cmd_apply_restore():
    name = (read(RESTORE_REQUEST) or "").strip()
    if not name:
        out({"ok": True, "restored": None})
        return
    try:
        os.remove(RESTORE_REQUEST)
    except OSError:
        pass
    src = os.path.join(BACKUPS, name)
    if not BACKUP_NAME.match(name) or not os.path.isfile(src):
        fail(f"the backup to restore is gone: {name}")
    safety = make_backup(f"before restoring {name}")
    staging = tempfile.mkdtemp(dir=STATE_DIR, prefix="restore-")
    try:
        with tarfile.open(src, "r:gz") as tar:
            tar.extractall(staging, filter="data")
        for item in BACKUP_ITEMS:
            new, cur = os.path.join(staging, item), os.path.join(DATA, item)
            if not os.path.lexists(new):
                continue
            old = cur + ".flux-old"
            if os.path.lexists(old):
                shutil.rmtree(old) if os.path.isdir(old) and not os.path.islink(old) else os.remove(old)
            if os.path.lexists(cur):
                os.replace(cur, old)
            os.replace(new, cur)
            if os.path.lexists(old):
                shutil.rmtree(old) if os.path.isdir(old) and not os.path.islink(old) else os.remove(old)
    finally:
        shutil.rmtree(staging, ignore_errors=True)
    out({"ok": True, "restored": name, "safetyBackup": safety})


def main(argv):
    commands = {
        "files": (cmd_files, 0), "map-install": (cmd_map_install, 1), "map-remove": (cmd_map_remove, 1),
        "set-mapcycle": (cmd_set_mapcycle, 1), "plugin-install": (cmd_plugin_install, 1),
        "plugin-enable": (cmd_plugin_enable, 2), "plugin-remove": (cmd_plugin_remove, 1),
        "set-admins": (cmd_set_admins, 1), "backups": (cmd_backups, 0), "restore": (cmd_restore, 1),
        "backup": (cmd_backup, (1, 2)), "apply-restore": (cmd_apply_restore, 0),
    }
    if not argv or argv[0] not in commands:
        print(__doc__, file=sys.stderr)
        return 64
    arity = commands[argv[0]][1]
    if len(argv) - 1 not in (arity if isinstance(arity, tuple) else (arity,)):
        print(__doc__, file=sys.stderr)
        return 64
    commands[argv[0]][0](*argv[1:])
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
