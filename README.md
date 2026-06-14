# Mobile Lovely Injector (MLI)

A pure-Lua, on-device replacement for the [Lovely injector][lovely] that lets
you run Balatro mods inside the **Android APK** build of the game (the kind
produced by [balatro-mobile-maker]).

Lovely is a native (Rust) program that hooks the LÖVE/LuaJIT runtime from
outside the process. That technique doesn't exist on Android, which is why the
usual answer has been "run the game on a PC with Lovely, then copy the
pre-patched `dump/` files onto your phone." That works but is painful: you need
a PC every time you add or update a mod.

**MLI does the patching on the phone instead.** It reimplements Lovely's
`lovely.toml` patch system in plain Lua and runs it every time the game starts,
so mods are drop-in: copy a mod folder onto the device and launch.

## How it works (one paragraph)

The installer rewrites the APK's `main.lua` into a tiny shim and moves the
original aside. Because LÖVE runs `main.lua` first, the shim is our earliest
entry point. It boots the injector, which:

1. scans your `Mods/` folder for `lovely.toml` / `lovely/*.toml` patch files,
2. registers any `module` patches into `package.preload`,
3. hooks `love.filesystem.load` and adds a `require` searcher so that **every
   game file is patched as it is loaded**, then
4. loads, patches, and runs the original `main.lua` — and the game starts.

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the full picture.

## Quick start

```sh
# 1. Patch your APK (adds the injector). Requires Android SDK build-tools for
#    signing (apksigner + zipalign), or sign separately afterwards.
python3 tools/install.py path/to/Balatro.apk -o Balatro-modded.apk

# 2. Install it
adb install -r Balatro-modded.apk

# 3. Put your mods where the app can read them. Either:
#    - the save dir:  .../files/save/game/Mods/MyMod/   (needs adb/root on
#      locked-down devices), or
#    - a PUBLIC folder you can reach with any file manager (recommended on
#      Samsung / Android 13+):  Download/BalatroMods.zip  containing your mod
#      folders at its root, or  Download/BalatroMods/  (LÖVE 12+).
```

On launch the game shows a status popup reporting which mods loaded and where
the log was written — handy since the save directory is often unreadable on
modern Android.

Before touching the device, you can dry-run your mods against the extracted
game source on your PC — it applies every patch and compile-checks the results:

```sh
lua tools/smoke_test.lua path/to/extracted-game-src path/to/Mods
```

Full instructions, including how to find the save directory and how to sign the
APK if you don't have build-tools, are in [docs/INSTALL.md](docs/INSTALL.md).

## What's supported

| Lovely patch type | Status |
|---|---|
| `module` (inject a Lua module) | ✅ full |
| `copy`   (append/prepend files) | ✅ full |
| `pattern` (wildcard line match, before/after/at) | ✅ full |
| `regex`  | ⚠️ best-effort — a useful subset of PCRE is translated to Lua patterns; unsupported constructs are skipped with a warning |
| `vars` / `{{lovely:...}}` interpolation | ✅ |
| manifest `priority` ordering | ✅ |

This is enough to load Steamodded (SMODS) and many mods built on it. The regex
limitation is the main caveat — see [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md#known-limitations).

## Repo layout

```
mli/            the runtime injector (copied into the APK at install time)
  injector.lua    entry point: init() hooks loaders, run() boots the game
  mod_loader.lua  discovers mods, parses patches, sorts by priority
  patch_engine.lua applies pattern/copy/regex patches to source text
  toml.lua        minimal TOML parser for lovely.toml
  glob.lua        lovely wildcard (*, ?) matching
  log.lua         logging (writes mli/log.txt in the save dir)
shim/main.lua   the replacement main.lua the installer drops into the APK
tools/install.py  the APK/.love patcher + signer
tests/          lua5.1 test suite (in-memory fs + fake love)
examples/       a sample mod
docs/           install guide, mod-writing guide, architecture
```

## Running the tests

```sh
lua5.1 tests/run_tests.lua    # or `lua` — needs Lua 5.1 / LuaJIT semantics
```

## Status & credit

This injector is validated with an in-memory test harness (TOML → mod loader →
patch engine → loader hooks → boot). It has **not** yet been verified against a
real device/APK end-to-end — see the limitations doc and please report results.

Patch format and concepts come from [ethangreen-dev/lovely-injector][lovely].
Mobile packaging context from [balatro-mobile-maker]. Balatro is by LocalThunk.

[lovely]: https://github.com/ethangreen-dev/lovely-injector
[balatro-mobile-maker]: https://github.com/blake502/balatro-mobile-maker
