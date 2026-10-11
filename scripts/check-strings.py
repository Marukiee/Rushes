#!/usr/bin/env python3
"""Checks the Dutch translations of the app.

The texts in the code are the English ones and also the keys. This reads every string literal in the code that
could reach the screen and checks that each has a line in Resources/nl.lproj/Localizable.strings. It also checks the
file itself: every line parses, no key is there twice, no text uses a dash to break a sentence, and placeholders match.

  scripts/check-strings.py          check, exit 1 on a problem
  scripts/check-strings.py --list   print every text found, with %@ or %lld for each interpolation
"""
import re
import sys
from pathlib import Path

root = Path(__file__).resolve().parent.parent
sources = [p for p in sorted((root / "Sources/Rushes").glob("**/*.swift")) if p.name not in ("DebugSupport.swift",)]

# Words in an interpolation that say it is a whole number. SwiftUI and String(localized:) write the key as %lld for those.
INT_HINTS = ("count", "Count", "Int(", "number", "suggested", "newItems", "knownItems", "skippedBefore", "done", "total",
             "relinked", "imported", "alreadyThere", "enrichDone", "available / average", "files", "minutes", "seconds")


def kind_of(expression: str) -> str:
    if "specifier" in expression:
        return "%.1f"
    lowered = expression.lower()
    if "format." in lowered or "bytes" in lowered or "name" in lowered or "formatted" in lowered:
        return "%@"
    if any(hint in expression for hint in INT_HINTS):
        return "%lld"
    return "%@"


def read_string(line: str, start: int):
    """Reads the literal that opens at line[start]. Returns (text with placeholders, index after it, nested literals)."""
    j, out, nested = start + 1, "", []
    while j < len(line):
        c = line[j]
        if c == "\\" and line[j + 1:j + 2] == "(":
            depth, k, expression = 1, j + 2, ""
            while k < len(line) and depth:
                if line[k] == '"':
                    text, after, inner = read_string(line, k)
                    nested.append(text)
                    nested.extend(inner)
                    expression += line[k:after]
                    k = after
                    continue
                depth += (line[k] == "(") - (line[k] == ")")
                if depth:
                    expression += line[k]
                k += 1
            out += kind_of(expression)
            j = k
        elif c == "\\":
            out += line[j:j + 2]
            j += 2
        elif c == '"':
            return out, j + 1, nested
        else:
            out += c
            j += 1
    return out, j, nested


def literals(line: str):
    found, i = [], 0
    while i < len(line):
        if line.startswith("//", i):
            break
        if line[i] == '"':
            if line.startswith('"""', i):
                break
            text, after, nested = read_string(line, i)
            found.append(text)
            found.extend(nested)
            i = after
        else:
            i += 1
    return found


def is_ui_text(text: str, line: str) -> bool:
    plain = re.sub(r"%(@|lld|\.1f)", "", text)
    if not re.search(r"[A-Za-z]{2}", plain):
        return False
    # One plain word is a text when it starts with a capital or sits in String(localized:), and an identifier otherwise.
    if re.fullmatch(r"[A-Za-z]+", text):
        if any(token in line for token in ("systemName:", "systemImage:", "id:", "forKey", "identifier", "PrefKey.", "Selector(", "Image(", "kind:", "role:")):
            return False
        return text[0].isupper() or f'localized: "{text}"' in line
    # Identifiers, symbol names, keys, paths, formats: no spaces, or made of identifier characters only.
    if re.fullmatch(r"[A-Za-z0-9_.\-/:$]+", text) and " " not in text:
        return False
    if any(token in text for token in ("http", ".sqlite", "SELECT ", "com.", "nl.markmaaktmedia", "/Users", "Application Support", "{datum}")) and " " not in text:
        return False
    if any(token in line for token in ("trace(", "systemName:", "systemImage:", "Selector(", "forKey", "PrefKey.", "setValue", "identifier:", "UNNotificationRequest", "Logger")):
        # A literal on a line with a symbol or key may still carry text: look at the text itself only.
        if " " not in text.strip():
            return False
    return True


found = {}
for path in sources:
    for number, line in enumerate(path.read_text().splitlines(), 1):
        if line.strip().startswith("//") or "trace(" in line:
            continue
        for text in literals(line):
            if is_ui_text(text, line):
                found.setdefault(text, f"{path.relative_to(root)}:{number}")

# Texts that are part of the program and not shown as they are.
IGNORED = {"CFBundleShortVersionString", "RushesUpdatePublicKey", "Accept", "Marukiee", "Rushes Dev", "NO NAME", "Debug SSD", "Copying a card", "S-Log3", "{datum} Selects", "SD 5"}
for ignored in IGNORED:
    found.pop(ignored, None)
# Identifiers for notifications, keys of the choices table and file names have no spaces and a separator.
for key in [k for k in found if " " not in k and re.search(r"[.|]|%", k)]:
    found.pop(key)

if "--list" in sys.argv:
    for key in sorted(found):
        print(key)
    sys.exit(0)

strings_path = root / "Resources/nl.lproj/Localizable.strings"
problems = []
translations = {}
for number, line in enumerate(strings_path.read_text().splitlines(), 1):
    line = line.strip()
    if not line or line.startswith("/*") or line.startswith("//") or line.startswith("*"):
        continue
    match = re.fullmatch(r'"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)";', line)
    if not match:
        problems.append(f"{strings_path.name}:{number}: cannot parse: {line[:70]}")
        continue
    key, value = match.groups()
    if key in translations:
        problems.append(f"{strings_path.name}:{number}: twice: {key[:60]}")
    translations[key] = value
    for dash in ("—", "–"):
        if dash in value:
            problems.append(f"{strings_path.name}:{number}: has a dash that breaks a sentence: {value[:60]}")
    if len(re.findall(r"%(@|lld|\.1f)", key)) != len(re.findall(r"%(@|lld|\.1f)", value)):
        problems.append(f"{strings_path.name}:{number}: placeholders differ: {key[:60]}")

# An interpolation may be a number or a text; the code decides which at build time, so either spelling counts.
normalised = {re.sub(r"%(@|lld|\.1f)", "#", key) for key in translations}
for key, where in sorted(found.items(), key=lambda item: item[1]):
    if key not in translations and re.sub(r"%(@|lld|\.1f)", "#", key) not in normalised:
        problems.append(f"{where}: no Dutch text for: {key[:80]}")

if problems:
    print("\n".join(problems))
    print(f"\n{len(problems)} problems")
    sys.exit(1)
print(f"{len(translations)} Dutch texts, {len(found)} texts in the code, all there")
