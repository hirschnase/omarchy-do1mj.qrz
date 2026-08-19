#!/usr/bin/env python3

import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET
from pathlib import Path

COORD_RE = re.compile(r"^-?\d+(?:\.\d+)?$")

SETTINGS_DIR = Path.home() / ".config" / "do1mj.qrz"
SETTINGS_FILE = SETTINGS_DIR / "settings.json"
API_URL = "https://xmldata.qrz.com/xml/current/"
AGENT = "omarchy.plugin.qrz/1.0"


def emit(payload):
    sys.stdout.write(json.dumps(payload, ensure_ascii=False))
    sys.stdout.write("\n")


def read_stdin_json():
    line = sys.stdin.readline()
    if not line.strip():
        return {}
    try:
        data = json.loads(line)
    except Exception:
        return {}
    return data if isinstance(data, dict) else {}


def ensure_private_dir(path):
    path.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(path, 0o700)


def write_private_text(path, text):
    ensure_private_dir(path.parent)
    tmp = path.with_suffix(path.suffix + ".tmp")
    data = text.encode("utf-8")
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    try:
        os.fchmod(fd, 0o600)
        view = memoryview(data)
        while view:
            written = os.write(fd, view)
            view = view[written:]
    finally:
        os.close(fd)
    os.replace(tmp, path)
    os.chmod(path, 0o600)


def harden_settings_paths():
    try:
        if SETTINGS_DIR.is_dir():
            os.chmod(SETTINGS_DIR, 0o700)
        if SETTINGS_FILE.is_file():
            os.chmod(SETTINGS_FILE, 0o600)
    except Exception:
        pass


def load_settings():
    harden_settings_paths()
    if not SETTINGS_FILE.is_file():
        return {"username": "", "password": "", "sessionKey": "", "authError": ""}
    try:
        data = json.loads(SETTINGS_FILE.read_text(encoding="utf-8"))
    except Exception:
        return {"username": "", "password": "", "sessionKey": "", "authError": ""}
    if not isinstance(data, dict):
        return {"username": "", "password": "", "sessionKey": "", "authError": ""}
    return {
        "username": str(data.get("username") or ""),
        "password": str(data.get("password") or ""),
        "sessionKey": str(data.get("sessionKey") or ""),
        "authError": str(data.get("authError") or ""),
    }


def save_settings(data):
    payload = {
        "username": str(data.get("username") or ""),
        "password": str(data.get("password") or ""),
        "sessionKey": str(data.get("sessionKey") or ""),
        "authError": str(data.get("authError") or ""),
    }
    write_private_text(SETTINGS_FILE, json.dumps(payload, indent=2) + "\n")
    harden_settings_paths()


def google_maps_url(lat, lon):
    lat_s = str(lat or "").strip()
    lon_s = str(lon or "").strip()
    if not COORD_RE.fullmatch(lat_s) or not COORD_RE.fullmatch(lon_s):
        return ""
    try:
        lat_f = float(lat_s)
        lon_f = float(lon_s)
    except ValueError:
        return ""
    if not (-90.0 <= lat_f <= 90.0 and -180.0 <= lon_f <= 180.0):
        return ""
    return f"https://www.google.com/maps?q={lat_s},{lon_s}"


def local_tag(tag):
    return str(tag).split("}")[-1]


def parse_xml(raw):
    root = ET.fromstring(raw)
    session = {}
    callsign = {}
    for child in list(root):
        name = local_tag(child.tag)
        fields = {}
        for item in list(child):
            fields[local_tag(item.tag)] = (item.text or "").strip()
        if name == "Session":
            session = fields
        elif name == "Callsign":
            callsign = fields
    return session, callsign


def xml_request(params):
    query = urllib.parse.urlencode(params)
    request = urllib.request.Request(
        API_URL + "?" + query,
        headers={"User-Agent": AGENT, "Accept": "application/xml"},
    )
    with urllib.request.urlopen(request, timeout=15) as response:
        return response.read()


def login(username, password):
    username = str(username or "").strip()
    password = str(password or "")
    if not username or not password:
        return False, "Username and password are required", ""
    try:
        raw = xml_request({"username": username, "password": password, "agent": AGENT})
    except urllib.error.HTTPError as exc:
        return False, f"QRZ XML HTTP {exc.code}", ""
    except urllib.error.URLError as exc:
        return False, f"Could not reach QRZ XML API: {exc.reason}", ""
    except Exception as exc:
        return False, str(exc), ""
    session, _ = parse_xml(raw)
    if session.get("Error"):
        return False, session["Error"], ""
    key = session.get("Key") or ""
    if not key:
        return False, session.get("Message") or "Login failed", ""
    return True, session.get("Message") or "", key


def session_needs_login(session):
    if session.get("Key"):
        return False
    error = (session.get("Error") or "").lower()
    if "not found" in error:
        return False
    return True


def lookup_callsign(callsign):
    settings = load_settings()

    # A previous automatic renewal already failed and the stored credentials
    # have not changed since (that only happens via a fresh Save/Check from
    # the settings page, which clears this field). Don't hammer QRZ's login
    # endpoint again on every lookup with credentials already known to be
    # bad; the failure is surfaced in the settings page instead.
    if settings["authError"]:
        return None

    if not settings["sessionKey"] and not (settings["username"] and settings["password"]):
        return None

    def fetch(key):
        raw = xml_request({"s": key, "callsign": callsign})
        return parse_xml(raw)

    def renew():
        if not (settings["username"] and settings["password"]):
            return False
        ok, message, key = login(settings["username"], settings["password"])
        if ok:
            settings["sessionKey"] = key
            settings["authError"] = ""
            save_settings(settings)
            return True
        # Renewal failed: drop the now-unusable key and remember why, so the
        # next lookup skips straight to "not attempting" instead of retrying
        # the same failing login.
        settings["sessionKey"] = ""
        settings["authError"] = message or "QRZ login failed"
        save_settings(settings)
        return False

    key = settings["sessionKey"]
    if not key:
        if not renew():
            return None
        key = settings["sessionKey"]

    try:
        session, call = fetch(key)
    except Exception:
        return None

    if session_needs_login(session):
        if not renew():
            return {"error": settings["authError"]}
        key = settings["sessionKey"]
        try:
            session, call = fetch(key)
        except Exception:
            return None

    if session.get("Key") and session["Key"] != settings.get("sessionKey"):
        settings["sessionKey"] = session["Key"]
        save_settings(settings)

    error = session.get("Error") or ""
    if error and "not found" in error.lower():
        return {"found": False, "error": error}
    if not call:
        return {"error": error} if error else None

    addr_parts = [call.get(k, "") for k in ("attn", "addr1", "addr2", "state", "zip")]
    address = ", ".join([part for part in addr_parts if part])
    lat = call.get("lat") or ""
    lon = call.get("lon") or ""
    maps_url = google_maps_url(lat, lon)
    name = call.get("name_fmt") or " ".join(
        part for part in (call.get("fname") or "", call.get("nickname") and f'"{call.get("nickname")}"' or "", call.get("name") or "") if part
    ).strip()
    return {
        "found": True,
        "name": name,
        "email": call.get("email") or "",
        "address": address,
        "country": call.get("country") or call.get("land") or "",
        "grid": call.get("grid") or "",
        "lat": lat,
        "lon": lon,
        "mapsUrl": maps_url,
        "county": call.get("county") or "",
        "class": call.get("class") or "",
        "cqzone": call.get("cqzone") or "",
        "ituzone": call.get("ituzone") or "",
        "qslmgr": call.get("qslmgr") or "",
        "emailPref": "",
        "lotw": call.get("lotw") or "",
        "eqsl": call.get("eqsl") or "",
        "mqsl": call.get("mqsl") or "",
        "image": call.get("image") or "",
    }


def cmd_load():
    settings = load_settings()
    emit({
        "ok": True,
        "username": settings["username"],
        "hasPassword": bool(settings["password"]),
        "hasSession": bool(settings["sessionKey"]),
        "authError": settings["authError"],
    })


def cmd_save():
    incoming = read_stdin_json()
    settings = load_settings()
    username = str(incoming.get("username") or "").strip()
    password = str(incoming.get("password") or "")
    if username:
        settings["username"] = username
    if password:
        settings["password"] = password
    if not settings["username"] or not settings["password"]:
        emit({"ok": False, "error": "Username and password are required"})
        return
    # Saving is the explicit "try these credentials" action, so it always
    # re-arms automatic renewal regardless of any prior recorded failure.
    settings["authError"] = ""
    ok, message, key = login(settings["username"], settings["password"])
    if ok:
        settings["sessionKey"] = key
        save_settings(settings)
        emit({"ok": True, "hasSession": True, "error": ""})
        return
    settings["sessionKey"] = ""
    settings["authError"] = message or "QRZ login failed"
    save_settings(settings)
    emit({"ok": False, "hasSession": False, "error": message})


def cmd_check():
    incoming = read_stdin_json()
    settings = load_settings()
    username = str(incoming.get("username") or "").strip() or settings["username"]
    password = str(incoming.get("password") or "") or settings["password"]
    ok, message, key = login(username, password)
    if ok:
        settings["username"] = username
        settings["password"] = password
        settings["sessionKey"] = key
        settings["authError"] = ""
        save_settings(settings)
        emit({"ok": True, "hasSession": True, "error": ""})
        return
    settings["sessionKey"] = ""
    settings["authError"] = message or "QRZ login failed"
    save_settings(settings)
    emit({"ok": False, "hasSession": False, "error": message})


def main():
    action = sys.argv[1] if len(sys.argv) > 1 else ""
    if action == "load":
        cmd_load()
    elif action == "save":
        cmd_save()
    elif action == "check":
        cmd_check()
    else:
        emit({"ok": False, "error": "Unknown settings action"})


if __name__ == "__main__":
    main()
