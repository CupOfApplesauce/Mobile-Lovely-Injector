# Installing & using Mobile Lovely Injector

This guide covers patching your APK, signing it, installing it, and adding
mods.

## 0. Prerequisites

- An APK of Balatro built for Android (e.g. via
  [balatro-mobile-maker](https://github.com/blake502/balatro-mobile-maker)).
  **Use a clean, un-modded APK** — the installer refuses to double-install.
- Python 3 (for `tools/install.py`).
- To sign the patched APK (required to install on Android), one of:
  - Android SDK **build-tools** (`apksigner` + `zipalign`) — recommended, or
  - [`uber-apk-signer`](https://github.com/patrickfav/uber-apk-signer), or
  - a JDK's `jarsigner` (older v1 signatures only; may not install on newer
    Android).
- `adb` to push the APK and mods to the device (or do it via the device's file
  manager).

## 1. Patch the APK

```sh
python3 tools/install.py path/to/Balatro.apk -o Balatro-modded.apk
```

What happens:
- The tool finds the LÖVE game source inside the APK (loose `.lua` files, or a
  nested `*.love` archive — both are handled automatically).
- It moves the game's `main.lua` to `mli/main_original.lua`, drops in the shim
  `main.lua`, and copies the `mli/` runtime alongside the game.
- It strips the old signature and, if `zipalign`/`apksigner` are on your PATH,
  aligns and signs the result with an auto-generated debug key.

Useful flags:
- `--inspect` — print the APK's structure and the detected game root, then exit.
- `--no-sign` — repackage only; you sign it yourself afterwards.
- `--keystore / --alias / --storepass` — use your own signing key.
- `--love` — operate on a `.love` file instead of an APK (handy for testing the
  transform; no signing).

## 2. Sign it (if the tool couldn't)

If you saw "the APK is repackaged but UNSIGNED", sign it before installing:

```sh
# with Android build-tools
zipalign -f -p 4 Balatro-modded.apk Balatro-aligned.apk
apksigner sign --ks debug.keystore Balatro-aligned.apk

# or, simplest, with uber-apk-signer
java -jar uber-apk-signer.jar --apks Balatro-modded.apk
```

> If you previously had the un-modded APK installed, you must **uninstall** it
> first — a different signing key means Android won't update it in place.

## 3. Install

```sh
adb install -r Balatro-modded.apk
```

Launch the game once. It should start exactly as before (no mods yet). If it
doesn't start, see Troubleshooting below.

## 4. Add mods

Mods live in a `Mods/` folder inside the game's **save directory**.

### Finding the save directory

The save directory is where the game keeps `settings.jkr` and your save files.
With balatro-mobile-maker's external-storage option it is typically:

```
/sdcard/Android/data/<package-name>/files/save/<identity>/
```

where `<package-name>` is often `com.unofficial.balatro` and `<identity>` is the
LÖVE identity the build uses (commonly `Balatro` or `game`). The reliable way to
find it: launch the modded game once, then look for the log file MLI writes:

```
.../files/save/<identity>/mli/log.txt
```

The folder that contains `mli/log.txt` is the save directory.

### Installing a mod

Create `Mods/` in the save directory and drop the mod folder in:

```
.../save/<identity>/Mods/
  Steamodded/        <- a mod with lovely/*.toml and src/
  MyOtherMod/
    lovely.toml
    ...
```

```sh
adb push Steamodded/ /sdcard/Android/data/com.unofficial.balatro/files/save/Balatro/Mods/Steamodded/
```

Relaunch the game. MLI applies the patches on startup — **no PC dump step**.

### Steamodded specifically

Steamodded ships its patches as `lovely/*.toml` and bundles `nativefs.lua` /
`json.lua` as `module` patches, which MLI supports. Drop the whole SMODS folder
into `Mods/`. Mods that depend on SMODS go in `Mods/` next to it. See
[WRITING_MODS.md](WRITING_MODS.md) for the patch format and current caveats
(notably regex patches).

## 5. (Recommended) Dry-run your mods on the PC first

Extract the game source from the APK/`.love` (any unzip tool), then:

```sh
lua tools/smoke_test.lua path/to/extracted-game path/to/Mods
```

For every mod patch it reports whether it applied, flags pattern/regex patches
that matched **zero** times (usually a game-version mismatch or an anchor that
mobile-maker modified), and verifies every patched file still compiles. Fix
failures before pushing mods to the device — it turns "black screen on my
phone" into a readable error on your PC. Requires a Lua 5.1 interpreter
(`lua5.1` or LuaJIT).

## Troubleshooting

- **Game won't install:** it's unsigned or signed with a different key than the
  copy already on the device. Uninstall the old one and re-sign.
- **Game starts but mods don't load:** check `mli/log.txt` in the save dir. It
  lists discovered mods, patch counts, and any patch/compile errors. If it says
  "discovered 0 mods", your `Mods/` folder is in the wrong place — confirm via
  the `mli/log.txt` location trick above.
- **Game crashes on launch after adding a mod:** the shim falls back to running
  the game unmodified if the *injector* itself errors, but a bad *patch* that
  produces invalid Lua will surface as a normal LÖVE error. Read `log.txt` for
  the offending target file, remove that mod, and report it.
- **A specific mod misbehaves:** it may rely on a `regex` patch MLI couldn't
  translate (logged as "skipping regex patch"). See the architecture doc.
