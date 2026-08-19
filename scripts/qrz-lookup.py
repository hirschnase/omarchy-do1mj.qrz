#!/usr/bin/env python3

import base64
import importlib.util
import ipaddress
import json
import os
import re
import sys
import urllib.error
import urllib.request
from html import unescape
from pathlib import Path
from urllib.parse import unquote, urljoin, urlparse, urlunparse

# The dynamic import of qrz-xml.py below (via importlib) would otherwise let
# Python write a bytecode cache into scripts/__pycache__ inside the plugin's
# own installed directory. Omarchy's plugin registry watches that whole
# directory tree for live-reload, so creating that file fires a "plugin
# changed" event mid-lookup — which tears down and recreates the running
# overlay, including one that is currently open and showing a result. Never
# write bytecode cache for this process.
sys.dont_write_bytecode = True

CALLSIGN_RE = re.compile(
    r"^(?:[A-Z0-9]{1,3}/)?[A-Z0-9]{1,3}[0-9][A-Z0-9]{0,5}(?:/[A-Z0-9]{1,8})?$"
)
USER_AGENT = (
    "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
)
QRZ_BASE_URL = "https://www.qrz.com/"
NO_RESULTS_RE = re.compile(r"The search for\s+.*?produced no results", re.I | re.S)
BIO_B64_RE = re.compile(
    r"""find\(['\"]#biodata['\"]\)\.html\(\s*Base64\.decode\(\s*['\"]([A-Za-z0-9+/=]+)['\"]\s*\)""",
    re.I,
)
EMAIL_RE = re.compile(r"^[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,24}$")
HOST_RE = re.compile(r"^[a-z0-9-]+(\.[a-z0-9-]+)+$")
MAPS_QUERY_RE = re.compile(r"^q=-?\d+(?:\.\d+)?,-?\d+(?:\.\d+)?$")
UNSAFE_URL_CHARS_RE = re.compile(r"[\x00-\x20\x7f\\]")
MAPS_HOSTS = {"google.com", "www.google.com", "maps.google.com"}


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


def harden_private_dir(path):
    try:
        if not path.is_dir():
            return
        os.chmod(path, 0o700)
        for child in path.iterdir():
            if child.is_file():
                os.chmod(child, 0o600)
    except Exception:
        pass


def is_qrz_host(host):
    return host == "qrz.com" or host.endswith(".qrz.com")


def _parse_web_url(url):
    raw = unescape(str(url or "")).strip()
    if not raw or UNSAFE_URL_CHARS_RE.search(raw):
        return None
    try:
        parsed = urlparse(raw)
    except Exception:
        return None
    scheme = (parsed.scheme or "").lower()
    if scheme not in ("http", "https"):
        return None
    host = (parsed.hostname or "").lower().rstrip(".")
    if not host or not HOST_RE.fullmatch(host):
        return None
    try:
        ipaddress.ip_address(host)
        return None
    except ValueError:
        pass
    try:
        port = parsed.port
    except ValueError:
        return None
    if port not in (None, 80, 443):
        return None
    return parsed, host


def safe_qrz_url(url):
    parsed = _parse_web_url(url)
    if not parsed:
        return ""
    parsed, host = parsed
    if not is_qrz_host(host):
        return ""
    return urlunparse(("https", host, parsed.path, parsed.params, parsed.query, parsed.fragment))


def safe_maps_url(url):
    parsed = _parse_web_url(url)
    if not parsed:
        return ""
    parsed, host = parsed
    if host not in MAPS_HOSTS:
        return ""
    path = parsed.path or ""
    if not path.startswith("/maps"):
        return ""
    if not MAPS_QUERY_RE.fullmatch(parsed.query or ""):
        return ""
    if parsed.params or parsed.fragment:
        return ""
    return urlunparse(("https", host, path, "", parsed.query, ""))


def safe_email(value):
    text = unescape(str(value or "")).strip()
    if not EMAIL_RE.fullmatch(text):
        return ""
    return text


def safe_mailto(url):
    raw = unescape(str(url or "")).strip()
    if not raw or UNSAFE_URL_CHARS_RE.search(raw):
        return ""
    try:
        parsed = urlparse(raw)
    except Exception:
        return ""
    if (parsed.scheme or "").lower() != "mailto":
        return ""
    addr = safe_email(unquote(parsed.path or ""))
    if not addr:
        return ""
    return "mailto:" + addr


def safe_link_url(url):
    raw = str(url or "").strip()
    if raw.lower().startswith("mailto:"):
        return safe_mailto(raw)
    return safe_qrz_url(raw) or safe_maps_url(raw)


def restrict_html_urls(html):
    def src_repl(match):
        url = safe_qrz_url(match.group(1))
        return f'src="{url}"' if url else ""

    def href_repl(match):
        url = safe_link_url(match.group(1))
        return f'href="{url}"' if url else 'href="#"'

    text = html or ""
    text = re.sub(r'\bsrc\s*=\s*["\']([^"\']*)["\']', src_repl, text, flags=re.I)
    text = re.sub(r'\bhref\s*=\s*["\']([^"\']*)["\']', href_repl, text, flags=re.I)
    text = re.sub(r'\s+srcset\s*=\s*["\'][^"\']*["\']', "", text, flags=re.I)

    def img_repl(match):
        tag = match.group(0)
        if re.search(r'\bsrc\s*=\s*["\'][^"\']+["\']', tag, re.I):
            return tag
        return ""

    return re.sub(r"<img\b[^>]*>", img_repl, text, flags=re.I)


def sanitize_payload(payload):
    if not isinstance(payload, dict):
        return payload
    payload["url"] = safe_qrz_url(payload.get("url") or "")
    payload["photo"] = safe_qrz_url(payload.get("photo") or "")
    payload["flag"] = safe_qrz_url(payload.get("flag") or "")
    payload["xmlMapsUrl"] = safe_maps_url(payload.get("xmlMapsUrl") or "")
    payload["xmlEmail"] = safe_email(payload.get("xmlEmail") or "")
    payload["biodataHtml"] = restrict_html_urls(payload.get("biodataHtml") or "")
    return payload


def empty(**overrides):
    payload = {
        "ok": False,
        "found": False,
        "callsign": "",
        "url": "",
        "error": "",
        "country": "",
        "flag": "",
        "photo": "",
        "qsl": "",
        "manager": "",
        "lookups": "",
        "details": [],
        "biodataHtml": "",
        "xmlName": "",
        "xmlEmail": "",
        "xmlAddress": "",
        "xmlGrid": "",
        "xmlLat": "",
        "xmlLon": "",
        "xmlMapsUrl": "",
        "xmlCounty": "",
        "xmlClass": "",
        "xmlCq": "",
        "xmlItu": "",
        "xmlQslmgr": "",
        "xmlLotw": "",
        "xmlEqsl": "",
        "xmlMqsl": "",
    }
    payload.update(overrides)
    return payload


def emit(payload):
    if len(sys.argv) > 3:
        try:
            payload["serial"] = int(sys.argv[3])
        except Exception:
            payload["serial"] = 0
    payload = sanitize_payload(payload)
    text = json.dumps(payload, ensure_ascii=False) + "\n"
    out_path = sys.argv[2] if len(sys.argv) > 2 else ""
    if out_path:
        dest = Path(out_path)
        write_private_text(dest, text)
        harden_private_dir(dest.parent)
        _cleanup_old_results(dest)
        return
    sys.stdout.write(text)


def _cleanup_old_results(current):
    # Each lookup writes its own uniquely-named result file (see Overlay.qml)
    # so a stale result from an earlier search can never be mistaken for a
    # fresh one. That means this directory would otherwise grow by one file
    # per search forever; keep only the most recent few.
    try:
        harden_private_dir(current.parent)
        candidates = sorted(
            current.parent.glob("lookup-*.json"),
            key=lambda p: p.stat().st_mtime,
            reverse=True,
        )
        for stale in candidates[5:]:
            if stale != current:
                stale.unlink(missing_ok=True)
    except Exception:
        pass


def fail(message, callsign="", url=""):
    emit(empty(error=message, callsign=callsign, url=url))
    raise SystemExit(0)


def normalize_callsign(value):
    return re.sub(r"\s+", "", str(value or "")).upper()


def extract_element(html_text, tag, elem_id):
    opener = re.compile(rf"<{tag}\b[^>]*\bid=['\"]{re.escape(elem_id)}['\"][^>]*>", re.I)
    match = opener.search(html_text)
    if not match:
        return ""
    start = match.start()
    open_pat = re.compile(rf"<{tag}\b", re.I)
    close_pat = re.compile(rf"</{tag}\s*>", re.I)
    pos = match.end()
    depth = 1
    while pos < len(html_text) and depth:
        nxt_open = open_pat.search(html_text, pos)
        nxt_close = close_pat.search(html_text, pos)
        if not nxt_close:
            return html_text[start:]
        if nxt_open and nxt_open.start() < nxt_close.start():
            depth += 1
            pos = nxt_open.end()
        else:
            depth -= 1
            pos = nxt_close.end()
    return html_text[start:pos]


def strip_tags(html):
    text = re.sub(r"<br\s*/?>", "\n", html or "", flags=re.I)
    text = re.sub(r"</p>", "\n", text, flags=re.I)
    text = re.sub(r"<[^>]+>", "", text)
    text = unescape(text)
    return re.sub(r"[ \t]+", " ", text).strip()


def attr(tag_html, name):
    match = re.search(rf"""{name}\s*=\s*['"]([^'"]+)""", tag_html or "", re.I)
    return unescape(match.group(1)).strip() if match else ""


def first_tag(html, pattern):
    match = re.search(pattern, html or "", re.I | re.S)
    return match.group(0) if match else ""


def decode_biodata(html_text):
    direct = extract_element(html_text, "div", "biodata")
    if direct and "iframe" not in direct.lower() and strip_tags(direct):
        return direct
    match = BIO_B64_RE.search(html_text)
    if not match:
        return ""
    try:
        raw = match.group(1).encode("ascii")
        pad = (-len(raw)) % 4
        decoded = base64.b64decode(raw + b"=" * pad).decode("utf-8", "replace")
        return decoded
    except Exception:
        return ""


REAL_SRC_RE = re.compile(r'(?<![-\w])src\s*=\s*["\']([^"\']*)["\']', re.I)
DATA_SRC_RE = re.compile(r'data-src\s*=\s*["\']([^"\']+)["\']', re.I)


def delazify_images(html):
    def repl(match):
        attrs = match.group(1)
        real_match = REAL_SRC_RE.search(attrs)
        if real_match and real_match.group(1).strip():
            return f"<img{attrs}>"
        data_match = DATA_SRC_RE.search(attrs)
        if not data_match:
            return f"<img{attrs}>"
        return f'<img src="{data_match.group(1)}"{attrs}>'

    return re.sub(r"<img\b([^>]*)>", repl, html, flags=re.I)


def sanitize_images(html):
    # Preserve the width/height QRZ authored for each image (the size it
    # actually shows at on qrz.com) instead of falling back to the image's
    # full natural resolution. Qt's rich text renderer sizes <img> from the
    # HTML width/height *attributes*, not from CSS style dimensions, so the
    # values are written as attributes rather than inline style.
    def repl(match):
        attrs = match.group(1)
        style_match = re.search(r'style\s*=\s*["\']([^"\']*)["\']', attrs, re.I)
        style_val = style_match.group(1) if style_match else ""

        width = None
        height = None
        width_match = re.search(r"width\s*:\s*(\d+)\s*px", style_val, re.I)
        height_match = re.search(r"height\s*:\s*(\d+)\s*px", style_val, re.I)
        if width_match:
            width = width_match.group(1)
        if height_match:
            height = height_match.group(1)
        if width is None:
            attr_match = re.search(r'\bwidth\s*=\s*["\']?(\d+)', attrs, re.I)
            if attr_match:
                width = attr_match.group(1)
        if height is None:
            attr_match = re.search(r'\bheight\s*=\s*["\']?(\d+)', attrs, re.I)
            if attr_match:
                height = attr_match.group(1)

        attrs = re.sub(r'\sstyle\s*=\s*["\'][^"\']*["\']', "", attrs, flags=re.I)
        attrs = re.sub(r'\swidth\s*=\s*["\'][^"\']*["\']', "", attrs, flags=re.I)
        attrs = re.sub(r'\sheight\s*=\s*["\'][^"\']*["\']', "", attrs, flags=re.I)
        attrs = re.sub(r'\sdata-loading\s*=\s*["\'][^"\']*["\']', "", attrs, flags=re.I)
        attrs = re.sub(r'\sdata-src\s*=\s*["\'][^"\']*["\']', "", attrs, flags=re.I)

        size_attrs = ""
        if width:
            size_attrs += f' width="{width}"'
        if height:
            size_attrs += f' height="{height}"'

        return f"<img{attrs}{size_attrs}>"

    return re.sub(r"<img\b([^>]*)>", repl, html, flags=re.I)


def absolutize_urls(html, base=QRZ_BASE_URL):
    def repl_src(match):
        return 'src="' + urljoin(base, match.group(1)) + '"'

    def repl_href(match):
        return 'href="' + urljoin(base, match.group(1)) + '"'

    html = re.sub(r'src=["\']([^"\']+)["\']', repl_src, html, flags=re.I)
    html = re.sub(r'href=["\']([^"\']+)["\']', repl_href, html, flags=re.I)
    return html


def strip_dark_theme_styles(html):
    def repl_style(match):
        style = match.group(1)
        style = re.sub(r"color\s*:\s*(#fff(?:fff)?|white)\s*;?", "", style, flags=re.I)
        style = re.sub(r"background(-color)?\s*:\s*[^;\"']+;?", "", style, flags=re.I)
        style = style.strip()
        return f'style="{style}"' if style else ""

    return re.sub(r'style=["\']([^"\']*)["\']', repl_style, html, flags=re.I)


def rich_html(html):
    text = re.sub(r"<script[\s\S]*?</script>", "", html or "", flags=re.I)
    text = re.sub(r"<style[\s\S]*?</style>", "", text, flags=re.I)
    text = re.sub(r"""\son\w+\s*=\s*['"][^'"]*['"]""", "", text)
    text = strip_dark_theme_styles(text)
    text = delazify_images(text)
    text = sanitize_images(text)
    text = absolutize_urls(text)
    text = restrict_html_urls(text)
    return text.strip()


def load_xml_module():
    path = Path(__file__).resolve().parent / "qrz-xml.py"
    spec = importlib.util.spec_from_file_location("qrz_xml", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def xml_extras(callsign):
    try:
        module = load_xml_module()
        data = module.lookup_callsign(callsign)
    except Exception:
        return {}
    if not data or not data.get("found"):
        return {}
    return {
        "xmlName": data.get("name") or "",
        "xmlEmail": data.get("email") or "",
        "xmlAddress": data.get("address") or "",
        "xmlGrid": data.get("grid") or "",
        "xmlLat": data.get("lat") or "",
        "xmlLon": data.get("lon") or "",
        "xmlMapsUrl": data.get("mapsUrl") or "",
        "xmlCounty": data.get("county") or "",
        "xmlClass": data.get("class") or "",
        "xmlCq": data.get("cqzone") or "",
        "xmlItu": data.get("ituzone") or "",
        "xmlQslmgr": data.get("qslmgr") or "",
        "xmlLotw": data.get("lotw") or "",
        "xmlEqsl": data.get("eqsl") or "",
        "xmlMqsl": data.get("mqsl") or "",
        "photo": data.get("image") or "",
        "country": data.get("country") or "",
    }


def parse_jq(jq, hide_login_noise=False):
    ham = re.search(r'class=["\'][^"\']*hamcall[^"\']*["\'][^>]*>([^<]+)', jq, re.I)
    callsign = strip_tags(ham.group(1)) if ham else ""

    flag_tag = first_tag(jq, r"<img[^>]*id=['\"]flg['\"][^>]*>")
    flag = urljoin(QRZ_BASE_URL, attr(flag_tag, "src")) if attr(flag_tag, "src") else ""
    country = attr(flag_tag, "title") or attr(flag_tag, "alt")
    nearby = re.search(r"id=['\"]flg['\"][\s\S]{0,400}?<span[^>]*>([^<]+)</span>", jq, re.I)
    if nearby:
        country = strip_tags(nearby.group(1)) or country
    if country.lower().startswith("dx atlas"):
        country = country.split(":")[-1].strip()
    country = re.sub(r"\s+flag$", "", country, flags=re.I)

    photo_tag = first_tag(jq, r"<img[^>]*id=['\"]mypic['\"][^>]*>")
    photo = urljoin(QRZ_BASE_URL, attr(photo_tag, "src")) if attr(photo_tag, "src") else ""

    qsl_match = re.search(r"<b>\s*QSL:\s*</b>\s*([^<]+)", jq, re.I)
    qsl = strip_tags(qsl_match.group(1)) if qsl_match else ""

    manager_match = re.search(r"Page managed by\s*(?:<a[^>]*>)?([^<]+)", jq, re.I)
    manager = strip_tags(manager_match.group(1)) if manager_match else ""

    lookups_match = re.search(r"Lookups:\s*([0-9,]+)", jq, re.I)
    lookups = lookups_match.group(1) if lookups_match else ""

    details = []
    for para in re.finditer(r"<p\b[^>]*>(.*?)</p>", jq, re.I | re.S):
        text = strip_tags(para.group(1))
        if not text:
            continue
        if text.upper().startswith("QSL:"):
            continue
        if text.lower().startswith("page managed by"):
            continue
        if re.search(r"lookups:\s*[0-9]", text, re.I):
            continue
        if hide_login_noise and ("login is required" in text.lower() or "login required to view" in text.lower()):
            continue
        details.append(text)

    return {
        "callsign": callsign,
        "country": country,
        "flag": flag,
        "photo": photo,
        "qsl": qsl,
        "manager": manager,
        "lookups": lookups,
        "details": details,
    }


def main():
    callsign = normalize_callsign(sys.argv[1] if len(sys.argv) > 1 else "")
    if not callsign:
        fail("Callsign is required")
    if not CALLSIGN_RE.fullmatch(callsign):
        fail("Not a valid amateur radio callsign", callsign)

    url = f"https://www.qrz.com/db/{callsign}"
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT, "Accept": "text/html"})
    try:
        with urllib.request.urlopen(request, timeout=15) as response:
            page = response.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as exc:
        fail(f"QRZ returned HTTP {exc.code}", callsign, url)
    except urllib.error.URLError as exc:
        fail(f"Could not reach QRZ.com: {exc.reason}", callsign, url)
    except Exception as exc:
        fail(str(exc), callsign, url)

    if NO_RESULTS_RE.search(page):
        extras = xml_extras(callsign)
        if extras.get("xmlName") or extras.get("xmlEmail") or extras.get("photo"):
            emit(empty(
                ok=True,
                found=True,
                callsign=callsign,
                url=url,
                country=extras.get("country") or "",
                photo=extras.get("photo") or "",
                qsl=extras.get("xmlQslmgr") or "",
                xmlName=extras.get("xmlName") or "",
                xmlEmail=extras.get("xmlEmail") or "",
                xmlAddress=extras.get("xmlAddress") or "",
                xmlGrid=extras.get("xmlGrid") or "",
                xmlLat=extras.get("xmlLat") or "",
                xmlLon=extras.get("xmlLon") or "",
                xmlMapsUrl=extras.get("xmlMapsUrl") or "",
                xmlCounty=extras.get("xmlCounty") or "",
                xmlClass=extras.get("xmlClass") or "",
                xmlCq=extras.get("xmlCq") or "",
                xmlItu=extras.get("xmlItu") or "",
                xmlQslmgr=extras.get("xmlQslmgr") or "",
                xmlLotw=extras.get("xmlLotw") or "",
                xmlEqsl=extras.get("xmlEqsl") or "",
                xmlMqsl=extras.get("xmlMqsl") or "",
            ))
            return
        emit(empty(ok=True, found=False, callsign=callsign, url=url))
        return

    jq = extract_element(page, "table", "jq")
    biodata = decode_biodata(page)
    if not jq and not biodata:
        fail("QRZ page did not contain callsign data", callsign, url)

    extras = xml_extras(callsign)
    parsed = parse_jq(jq, hide_login_noise=bool(extras))
    photo = parsed["photo"] or extras.get("photo") or ""
    country = parsed["country"] or extras.get("country") or ""
    emit(empty(
        ok=True,
        found=True,
        callsign=parsed["callsign"] or callsign,
        url=url,
        country=country,
        flag=parsed["flag"],
        photo=photo,
        qsl=parsed["qsl"] or extras.get("xmlQslmgr") or "",
        manager=parsed["manager"],
        lookups=parsed["lookups"],
        details=parsed["details"],
        biodataHtml=rich_html(biodata),
        xmlName=extras.get("xmlName") or "",
        xmlEmail=extras.get("xmlEmail") or "",
        xmlAddress=extras.get("xmlAddress") or "",
        xmlGrid=extras.get("xmlGrid") or "",
        xmlLat=extras.get("xmlLat") or "",
        xmlLon=extras.get("xmlLon") or "",
        xmlMapsUrl=extras.get("xmlMapsUrl") or "",
        xmlCounty=extras.get("xmlCounty") or "",
        xmlClass=extras.get("xmlClass") or "",
        xmlCq=extras.get("xmlCq") or "",
        xmlItu=extras.get("xmlItu") or "",
        xmlQslmgr=extras.get("xmlQslmgr") or "",
        xmlLotw=extras.get("xmlLotw") or "",
        xmlEqsl=extras.get("xmlEqsl") or "",
        xmlMqsl=extras.get("xmlMqsl") or "",
    ))


if __name__ == "__main__":
    main()
