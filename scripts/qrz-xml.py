#!/usr/bin/env python3

import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET
from pathlib import Path

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


def load_settings():
    if not SETTINGS_FILE.is_file():
        return {"username": "", "password": "", "sessionKey": ""}
    try:
        data = json.loads(SETTINGS_FILE.read_text(encoding="utf-8"))
    except Exception:
        return {"username": "", "password": "", "sessionKey": ""}
    if not isinstance(data, dict):
        return {"username": "", "password": "", "sessionKey": ""}
    return {
        "username": str(data.get("username") or ""),
        "password": str(data.get("password") or ""),
        "sessionKey": str(data.get("sessionKey") or ""),
    }


def save_settings(data):
    SETTINGS_DIR.mkdir(parents=True, exist_ok=True)
    payload = {
        "username": str(data.get("username") or ""),
        "password": str(data.get("password") or ""),
        "sessionKey": str(data.get("sessionKey") or ""),
    }
    tmp = SETTINGS_FILE.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
    os.chmod(tmp, 0o600)
    tmp.replace(SETTINGS_FILE)
    os.chmod(SETTINGS_FILE, 0o600)


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
    if not settings["sessionKey"] and not (settings["username"] and settings["password"]):
        return None

    def fetch(key):
        raw = xml_request({"s": key, "callsign": callsign})
        return parse_xml(raw)

    key = settings["sessionKey"]
    if not key:
        ok, _message, key = login(settings["username"], settings["password"])
        if not ok:
            return None
        settings["sessionKey"] = key
        save_settings(settings)

    try:
        session, call = fetch(key)
    except Exception:
        return None

    if session_needs_login(session) and settings["username"] and settings["password"]:
        ok, _message, key = login(settings["username"], settings["password"])
        if not ok:
            return {"error": session.get("Error") or "QRZ session expired"}
        settings["sessionKey"] = key
        save_settings(settings)
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
    maps_url = f"https://www.google.com/maps?q={lat},{lon}" if lat and lon else ""
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
    ok, message, key = login(settings["username"], settings["password"])
    if ok:
        settings["sessionKey"] = key
        save_settings(settings)
        emit({"ok": True, "hasSession": True, "error": ""})
        return
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
        save_settings(settings)
        emit({"ok": True, "hasSession": True, "error": ""})
        return
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
