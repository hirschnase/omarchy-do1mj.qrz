#!/usr/bin/env python3

import pathlib
import sys


def replace_block(text, begin, end, block):
    start = text.find(begin)
    stop = text.find(end)
    if start != -1 and stop != -1 and stop > start:
        stop += len(end)
        while stop < len(text) and text[stop] == "\n":
            stop += 1
        return text[:start] + block + text[stop:]
    if text and not text.endswith("\n"):
        text += "\n"
    if text and not text.endswith("\n\n"):
        text += "\n"
    return text + block


def bind(path, begin, end, line):
    path.parent.mkdir(parents=True, exist_ok=True)
    text = path.read_text(encoding="utf-8") if path.exists() else ""
    path.write_text(replace_block(text, begin, end, f"{begin}\n{line}\n{end}\n"), encoding="utf-8")


def unbind(path, begin, end):
    if not path.exists():
        return
    text = path.read_text(encoding="utf-8")
    path.write_text(replace_block(text, begin, end, ""), encoding="utf-8")


def main():
    if len(sys.argv) < 4:
        raise SystemExit("usage: hypr-bind.py bind|unbind PATH BEGIN END [KEY PLUGIN_ID]")
    action, raw_path, begin, end = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
    path = pathlib.Path(raw_path)
    if action == "bind":
        if len(sys.argv) < 7:
            raise SystemExit("bind requires KEY and PLUGIN_ID")
        key, plugin_id = sys.argv[5], sys.argv[6]
        line = f'o.bind("{key}", "QRZ callsign lookup", "omarchy-shell shell toggle {plugin_id} \'{{}}\'")'
        bind(path, begin, end, line)
    elif action == "unbind":
        unbind(path, begin, end)
    else:
        raise SystemExit(f"unknown action: {action}")


if __name__ == "__main__":
    main()
