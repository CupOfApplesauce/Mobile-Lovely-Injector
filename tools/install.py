#!/usr/bin/env python3
"""Mobile Lovely Injector — APK installer.

Patches a Balatro Android APK (produced by balatro-mobile-maker, or any LÖVE
APK) so that mods are loaded at runtime by the pure-Lua injector in ../mli.

What it does:
  1. Locate the LÖVE game source inside the APK. The game is either stored as
     loose .lua files (with main.lua) or inside a nested *.love zip.
  2. Move the game's main.lua aside to mli/main_original.lua.
  3. Drop in our shim main.lua (which boots the injector) and the mli/ runtime.
  4. Strip the old signature, then zipalign + sign the result.

After installing, copy your mods onto the device (see docs/INSTALL.md) — no PC
re-dump step is needed; patches are applied on-device every launch.

Signing note: a correctly signed APK is required to install on Android. This
tool uses `apksigner` (preferred) or falls back to `jarsigner`, both from the
Android SDK / JDK. If neither is found it still writes the repackaged APK and
tells you how to sign it yourself.
"""

import argparse
import io
import os
import re
import shutil
import subprocess
import sys
import tempfile
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
MLI_DIR = os.path.join(REPO, "mli")
SHIM_MAIN = os.path.join(REPO, "shim", "main.lua")

# Files that mark a directory as the Balatro/LÖVE game root.
GAME_MARKERS = ("main.lua",)
BALATRO_HINTS = ("game.lua", "globals.lua", "functions")


def log(msg):
    print(f"[install] {msg}")


def which(name):
    return shutil.which(name)


# ---------------------------------------------------------------------------
# Game-source location
# ---------------------------------------------------------------------------
def find_game_root(names):
    """Given a list of zip entry names, return the directory prefix that
    contains the game's main.lua (and looks like Balatro), or None."""
    candidates = []
    for n in names:
        base = n.rsplit("/", 1)
        if base[-1] == "main.lua":
            prefix = base[0] + "/" if len(base) == 2 else ""
            candidates.append(prefix)
    # Prefer a candidate whose directory also contains Balatro hint files.
    name_set = set(names)
    for prefix in candidates:
        if any((prefix + hint) in name_set or
               any(x.startswith(prefix + hint) for x in name_set)
               for hint in BALATRO_HINTS):
            return prefix
    return candidates[0] if candidates else None


def find_nested_love(names):
    for n in names:
        if n.lower().endswith(".love"):
            return n
    return None


# ---------------------------------------------------------------------------
# The actual Lua transform, applied to a set of {name: bytes} game files.
# ---------------------------------------------------------------------------
def collect_mli_payload():
    """Return {relative_path: bytes} for the shim + all mli/*.lua files."""
    payload = {}
    with open(SHIM_MAIN, "rb") as f:
        shim = f.read()
    for fn in sorted(os.listdir(MLI_DIR)):
        if fn.endswith(".lua"):
            with open(os.path.join(MLI_DIR, fn), "rb") as f:
                payload[f"mli/{fn}"] = f.read()
    return shim, payload


def patch_conf_externalstorage(entries):
    """Enable t.externalstorage in conf.lua so the save directory (and thus
    Mods/) lives on shared storage the user can reach without root. No-op if
    conf.lua is missing or already sets it."""
    if "conf.lua" not in entries:
        log("no conf.lua found; cannot enable external storage "
            "(Mods/ may be unreachable without root)")
        return
    text = entries["conf.lua"].decode("utf-8", errors="replace")
    if "externalstorage" in text:
        log("conf.lua already sets externalstorage; leaving as-is")
        return
    m = re.search(r"function\s+love\.conf\s*\(\s*(\w+)\s*\)", text)
    if not m:
        log("warning: could not find love.conf() in conf.lua; "
            "external storage NOT enabled")
        return
    var = m.group(1)
    eol = "\r\n" if "\r\n" in text else "\n"
    insert = (f"{eol}\t{var}.externalstorage = true "
              f"-- [MLI] put save dir (and Mods/) on shared storage{eol}")
    pos = m.end()
    # skip to end of the signature line
    nl = text.find("\n", pos)
    pos = len(text) if nl == -1 else nl + 1
    text = text[:pos] + insert.lstrip("\r\n") + text[pos:]
    entries["conf.lua"] = text.encode("utf-8")
    log(f"enabled {var}.externalstorage = true in conf.lua")


def transform_game(entries, root_prefix, external_storage=True):
    """entries: dict {name: bytes} of the game source (already stripped of the
    root_prefix, i.e. keys are game-relative like 'main.lua', 'game.lua').
    Mutates and returns the dict with the injector installed."""
    if "main.lua" not in entries:
        raise SystemExit("error: no main.lua in game source; cannot install")

    if "mli/main_original.lua" in entries:
        raise SystemExit(
            "error: this APK already has the injector installed "
            "(mli/main_original.lua exists). Use a clean APK.")

    shim, payload = collect_mli_payload()

    # Move original main aside, install shim + runtime.
    entries["mli/main_original.lua"] = entries["main.lua"]
    entries["main.lua"] = shim
    for path, data in payload.items():
        entries[path] = data

    if external_storage:
        patch_conf_externalstorage(entries)

    log(f"moved main.lua -> mli/main_original.lua")
    log(f"installed shim main.lua + {len(payload)} runtime file(s)")
    return entries


# ---------------------------------------------------------------------------
# Repackaging
# ---------------------------------------------------------------------------
def is_signature_entry(name):
    up = name.upper()
    return (up.startswith("META-INF/") and
            (up.endswith(".RSA") or up.endswith(".DSA") or up.endswith(".EC")
             or up.endswith(".SF") or up == "META-INF/MANIFEST.MF"))


def repackage(in_apk, out_apk, external_storage=True):
    with zipfile.ZipFile(in_apk, "r") as zin:
        names = zin.namelist()
        nested = find_nested_love(names)

        if nested:
            log(f"game is a nested archive: {nested}")
            love_bytes = zin.read(nested)
            new_love = transform_love_archive(love_bytes, external_storage)
            _write_apk(zin, out_apk, replace={nested: new_love}, add={})
        else:
            root = find_game_root(names)
            if root is None:
                raise SystemExit(
                    "error: could not find main.lua in the APK. Is this a "
                    "LÖVE/Balatro APK? Try --inspect.")
            log(f"game root inside APK: '{root or '(apk root)'}'")
            # Build game-relative entries dict for files under root.
            game = {}
            for n in names:
                if n.startswith(root) and not n.endswith("/"):
                    game[n[len(root):]] = zin.read(n)
            game = transform_game(game, root, external_storage)
            # Map back to full names; figure out which to replace/add.
            replace, add = {}, {}
            existing = set(names)
            for rel, data in game.items():
                full = root + rel
                if full in existing:
                    replace[full] = data
                else:
                    add[full] = data
            _write_apk(zin, out_apk, replace=replace, add=add)
    log(f"wrote repackaged APK: {out_apk}")


def transform_love_archive(love_bytes, external_storage=True):
    """Transform a nested .love zip's bytes and return new zip bytes."""
    with zipfile.ZipFile(io.BytesIO(love_bytes), "r") as z:
        names = z.namelist()
        root = find_game_root(names)
        if root is None:
            raise SystemExit("error: no main.lua inside the nested .love")
        game = {}
        for n in names:
            if n.startswith(root) and not n.endswith("/"):
                game[n[len(root):]] = z.read(n)
        game = transform_game(game, root, external_storage)
        # Preserve any non-game entries verbatim (unlikely but safe).
        passthrough = {n: z.read(n) for n in names
                       if not n.startswith(root) and not n.endswith("/")}
    out = io.BytesIO()
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as zo:
        for n, data in passthrough.items():
            zo.writestr(n, data)
        for rel, data in game.items():
            zo.writestr(root + rel, data)
    return out.getvalue()


def _write_apk(zin, out_apk, replace, add):
    """Copy zin to out_apk, replacing/adding given full-name entries and
    dropping old signature files."""
    handled = set(replace.keys())
    with zipfile.ZipFile(out_apk, "w", zipfile.ZIP_DEFLATED) as zout:
        for item in zin.infolist():
            if is_signature_entry(item.filename):
                continue
            if item.filename in replace:
                zout.writestr(_clone_info(item), replace[item.filename])
            else:
                zout.writestr(_clone_info(item), zin.read(item.filename))
        for name, data in add.items():
            zout.writestr(name, data)


def _clone_info(info):
    new = zipfile.ZipInfo(info.filename, date_time=info.date_time)
    new.compress_type = info.compress_type
    new.external_attr = info.external_attr
    return new


# ---------------------------------------------------------------------------
# Sign + align
# ---------------------------------------------------------------------------
def ensure_keystore(keystore, alias, storepass):
    if os.path.exists(keystore):
        return True
    keytool = which("keytool")
    if not keytool:
        log("keytool not found; cannot create a debug keystore.")
        return False
    log(f"creating debug keystore at {keystore}")
    subprocess.check_call([
        keytool, "-genkeypair", "-v", "-keystore", keystore,
        "-alias", alias, "-keyalg", "RSA", "-keysize", "2048",
        "-validity", "10000", "-storepass", storepass, "-keypass", storepass,
        "-dname", "CN=MLI Debug, OU=MLI, O=MLI, C=US",
    ])
    return True


def align_and_sign(apk, keystore, alias, storepass):
    zipalign = which("zipalign")
    aligned = apk
    if zipalign:
        aligned = apk + ".aligned"
        log("zipalign...")
        subprocess.check_call([zipalign, "-f", "-p", "4", apk, aligned])
        shutil.move(aligned, apk)
    else:
        log("zipalign not found; skipping alignment (apksigner can still sign).")

    apksigner = which("apksigner")
    if apksigner:
        if not ensure_keystore(keystore, alias, storepass):
            return False
        log("signing with apksigner (v1+v2+v3)...")
        subprocess.check_call([
            apksigner, "sign", "--ks", keystore, "--ks-key-alias", alias,
            "--ks-pass", f"pass:{storepass}", "--key-pass", f"pass:{storepass}",
            apk,
        ])
        return True

    jarsigner = which("jarsigner")
    if jarsigner:
        if not ensure_keystore(keystore, alias, storepass):
            return False
        log("apksigner not found; signing with jarsigner (v1 only). This may "
            "not install on newer Android; prefer apksigner.")
        subprocess.check_call([
            jarsigner, "-keystore", keystore, "-storepass", storepass,
            "-keypass", storepass, apk, alias,
        ])
        return True

    log("no apksigner/jarsigner found. The APK is repackaged but UNSIGNED.")
    log("Sign it with Android SDK build-tools, e.g.:")
    log("  apksigner sign --ks debug.keystore <apk>")
    log("or use uber-apk-signer (https://github.com/patrickfav/uber-apk-signer)")
    return False


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------
def inspect(apk):
    with zipfile.ZipFile(apk, "r") as z:
        names = z.namelist()
    nested = find_nested_love(names)
    root = find_game_root(names)
    print(f"entries: {len(names)}")
    print(f"nested .love: {nested}")
    print(f"detected game root: {root!r}")
    print("sample lua entries:")
    for n in names:
        if n.endswith(".lua"):
            print("  ", n)
            if names.index(n) > 0 and sum(1 for x in names if x.endswith('.lua')) > 30:
                pass
    return


def main():
    ap = argparse.ArgumentParser(description="Install Mobile Lovely Injector into a Balatro APK.")
    ap.add_argument("input", help="path to input .apk (or .love with --love)")
    ap.add_argument("-o", "--output", help="output .apk path (default: <input>-modded.apk)")
    ap.add_argument("--love", action="store_true", help="treat input/output as a .love archive (no signing)")
    ap.add_argument("--inspect", action="store_true", help="print APK structure and exit")
    ap.add_argument("--no-sign", action="store_true", help="repackage only, do not sign")
    ap.add_argument("--no-external-storage", action="store_true",
                    help="do not patch conf.lua to enable t.externalstorage")
    ap.add_argument("--keystore", default=os.path.join(HERE, "mli-debug.keystore"))
    ap.add_argument("--alias", default="mli")
    ap.add_argument("--storepass", default="mli-debug")
    args = ap.parse_args()

    if args.inspect:
        inspect(args.input)
        return

    if args.love:
        out = args.output or (os.path.splitext(args.input)[0] + "-modded.love")
        with open(args.input, "rb") as f:
            data = f.read()
        new = transform_love_archive(data, not args.no_external_storage)
        with open(out, "wb") as f:
            f.write(new)
        log(f"wrote {out}")
        return

    out = args.output or (os.path.splitext(args.input)[0] + "-modded.apk")
    repackage(args.input, out, not args.no_external_storage)

    if args.no_sign:
        log("skipping signing (--no-sign). APK will not install until signed.")
        return

    signed = align_and_sign(out, args.keystore, args.alias, args.storepass)
    if signed:
        log("done. Install with: adb install -r " + out)
    else:
        log("done (unsigned). Sign before installing.")


if __name__ == "__main__":
    main()
