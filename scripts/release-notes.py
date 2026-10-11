#!/usr/bin/env python3
"""Prints the release notes for one version from changelog.json, as Markdown.

Usage: scripts/release-notes.py 0.1.0
The text is the same the app shows under What's new, so the release page and the app agree.
Without an entry for the version it prints a plain line, so the release never fails over it.
"""
import json
import sys
from pathlib import Path

version = sys.argv[1].lstrip("v") if len(sys.argv) > 1 else ""
entries = json.loads((Path(__file__).resolve().parent.parent / "changelog.json").read_text())
entry = next((e for e in entries if e["version"] == version), None)
if entry is None:
    print(f"Rushes {version}")
    sys.exit(0)

print("""## Which file do I need? / Welk bestand heb ik nodig?

| You have / Je hebt | Download |
| --- | --- |
| Mac (Apple silicon), macOS 26 or newer | `Rushes-v%s-macOS.zip` |

Open the zip and move Rushes to Applications. The first time, right click the app and choose Open: it is signed with a certificate of its own, not by Apple. After that it updates itself.
De eerste keer: klik met rechts op de app en kies Open, want hij is ondertekend met een eigen certificaat en niet door Apple. Daarna werkt hij zichzelf bij.
""" % version)

groups = [("new", "New", "Nieuw"), ("better", "Better", "Beter"), ("fixed", "Fixed", "Opgelost")]
for lang, label in (("en", "English"), ("nl", "Nederlands")):
    text = entry[lang]
    print(f"## {text['title']} ({label})\n")
    for key, en, nl in groups:
        items = text.get(key)
        if items:
            print(f"**{en if lang == 'en' else nl}**\n")
            print("\n".join(f"- {item}" for item in items))
            print()
