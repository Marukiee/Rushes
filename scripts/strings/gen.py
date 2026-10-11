import re, subprocess, sys
sys.path.insert(0, sys.argv[1])
import importlib
T = {}
for name in ("nl1", "nl2"):
    try:
        T.update(importlib.import_module(name).T)
    except ModuleNotFoundError:
        pass
keys = subprocess.run(["python3", "scripts/check-strings.py", "--list"], capture_output=True, text=True).stdout.splitlines()
PH = re.compile(r"%(@|lld|\.1f)")
def norm(k): return PH.sub("#", k)
def convert(value, key):
    holders = PH.findall(key)
    it = iter(["%" + h for h in holders])
    return PH.sub(lambda m: next(it, m.group(0)), value)
byNorm = {norm(k): k for k in T}
for k in keys:
    if k not in T and norm(k) in byNorm:
        T[k] = convert(T[byNorm[norm(k)]], k)
missing = [k for k in keys if k not in T]
unused = [k for k in T if k not in keys]
print("in code:", len(keys), "translated:", len(T))
print("MISSING:"); [print("  ", m) for m in missing]
print("UNUSED:"); [print("  ", u) for u in unused]
T = {k: v for k, v in T.items() if k in keys}
# The code decides at build time whether an interpolation is a number (%lld) or a text (%@). Both spellings get the
# same translation, so neither a changed type nor a wrong guess leaves English on the screen.
import itertools
expanded = {}
for k, v in T.items():
    spots = [m for m in PH.finditer(k)]
    kinds = [m.group(1) for m in spots]
    if not any(x in ("@", "lld") for x in kinds) or len(spots) > 4:
        expanded[k] = v
        continue
    options = [("@", "lld") if x in ("@", "lld") else (x,) for x in kinds]
    for combo in itertools.product(*options):
        it = iter(combo)
        key = PH.sub(lambda m: "%" + next(it), k)
        it2 = iter(combo)
        value = PH.sub(lambda m: "%" + next(it2, m.group(1)), v)
        expanded[key] = value
# A percent sign in a text is written %% in the key that the system looks up.
LIT = re.compile(r"%(?!@|lld|\.1f|%)")
for k, v in list(expanded.items()):
    if LIT.search(k):
        expanded[LIT.sub("%%", k)] = LIT.sub("%%", v)
T = expanded
def esc(s): return s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")
lines = ["/* Dutch texts of Rushes. The English text in the code is the key. Run scripts/check-strings.py after changing this. */", ""]
for k in sorted(T): lines.append('"%s" = "%s";' % (esc(k), esc(T[k])))
open("Resources/nl.lproj/Localizable.strings", "w").write("\n".join(lines) + "\n")
open("Resources/en.lproj/Localizable.strings", "w").write("/* English is the language of the code: the text there is the key. */\n")
