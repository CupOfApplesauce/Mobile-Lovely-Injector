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

- It patches `conf.lua` to set `t.externalstorage = true`, so the save
  directory (and your `Mods/` folder) is on shared storage you can actually
  reach. See "Finding the save directory" below.

Useful flags:
- `--inspect` — print the APK's structure and the detected game root, then exit.
- `--no-sign` — repackage only; you sign it yourself afterwards.
- `--no-external-storage` — don't touch `conf.lua` (Mods/ will likely be
  unreachable without root).
- `--keystore / --alias / --storepass` — use your own signing key.
- `--love` — operate on a `.love` file instead of an APK (handy for testing the
  transform; no signing).

### Alternative: APKToolM round-trip (no PC Android tooling needed)

If you already use **APKToolM** (or apktool) to unpack your APK, you can patch
just the inner game archive and let your usual tool handle repack + sign:

1. Unpack the APK and pull out the `game.love` (often under `assets/`).
2. `python3 tools/install.py --love game.love -o game-modded.love`
3. Rename `game-modded.love` back, put it where the original was, then repack
   and sign with APKToolM as you normally do.

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
Balatro's `conf.lua` sets no LÖVE identity, so on Android it defaults to
`game`, making the path:

```
/sdcard/Android/data/<package-name>/files/save/game/
```

where `<package-name>` is often `com.unofficial.balatro`.

This path is on *shared* storage only because the installer patches `conf.lua`
to set `t.externalstorage = true` (mobile-maker doesn't always enable this).
Without it the save directory sits in internal app storage
(`/data/data/...`), which you can't reach without root — if you need that
behavior anyway, pass `--no-external-storage`. Note that enabling external
storage moves the save location, so do it before you've accumulated progress
you care about (or copy your save across).

To confirm the path: launch the modded game once, then look for the log file
MLI writes at `.../files/save/game/mli/log.txt`. The folder containing
`mli/log.txt` is the save directory.

### Required on Android 11+: grant "All files access"

Modern Android (11+, and strictly enforced on Samsung One UI) sandboxes shared
storage: an app may create and re-read *its own* files in `Download/`, but it
**cannot read a file another app placed there** (e.g. a zip you copied in with a
file manager) via a normal file path. The injector hits exactly this — the
status popup will show your `BalatroMods.zip` as `Permission denied` (the file
exists, it just can't be read).

Once **All-files-access** (below) is granted, MLI reads mods straight from a
real folder — no zipping. The preferred layout is a single organized folder:

```
/storage/emulated/0/Download/Mods/
├── Steamodded/
├── HelloMod/
└── (more mods...)
```

It also accepts `Download/Mods.zip`, and the older `BalatroMods` names, and it
checks `Documents/` too. The folder is read via LuaJIT FFI (Balatro is always
LuaJIT), so it works regardless of LÖVE version. Add or remove mod folders and
relaunch — that's it.

The fix is the **All-files-access** permission. Two one-time steps:

**1. Add the permission to the APK manifest.** This needs a tool that decodes
the binary `AndroidManifest.xml` (APKToolM / apktool — which you already use to
get at `game.love`). After decoding, add this line inside the `<manifest>` tag,
alongside the other `<uses-permission>` lines:

```xml
<uses-permission android:name="android.permission.MANAGE_EXTERNAL_STORAGE"/>
```

Then rebuild and sign as usual.

**2. Grant it on the device** (it is NOT a normal pop-up permission):
- Settings → search **"All files access"** (or: Settings → Apps → ⋮ → Special
  access → All files access), find **Balatro**, and set it to **Allowed**.
- Relaunch. The popup's "mods source probe" should now show `[READ OK]` for the
  zip, and mods will load.

Until this is granted, mods can only be read from the (root-only) save
directory; the public-folder method below depends on this permission.

### On locked-down devices (Samsung / Android 13+): use a public folder

If your file manager can't open `/sdcard/Android/data/...` ("Access denied"),
you can't put mods in the save-directory `Mods/` folder. MLI handles this by
loading mods from a **public** folder you *can* reach. On launch it looks for,
in order:

1. a folder `Download/BalatroMods/` (mounted directly, on LÖVE 12+), then
2. a single archive `Download/BalatroMods.zip` (works on LÖVE 11+),

and also checks `Documents/`. Whatever it finds is mounted as the `Mods/`
folder, so everything below about mod layout still applies.

**Recommended: a real folder.** Create `Download/Mods/` and drop each mod's
folder inside it (`Download/Mods/Steamodded/`, `Download/Mods/HelloMod/`, ...).
Add or remove mods by editing that folder — no rezipping. The launch popup
tells you which source was loaded and how many mods it found.

**Alternative: a zip.** If you prefer a single file, put your mod folders at the
**root** of `Download/Mods.zip` (or `BalatroMods.zip`):

```
Mods.zip
├── HelloMod/
│   └── lovely.toml
└── Steamodded/
    └── ...
```

To update, replace the zip. The folder is tried first; the zip is the fallback.

### Installing a mod (save-directory method)

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
