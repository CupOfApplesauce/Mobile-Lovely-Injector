# Architecture

## The problem with Lovely on Android

[Lovely][lovely] is a native injector. On desktop it is loaded into the game
process (via `LD_PRELOAD` / DLL injection / dylib insertion) and **detours the
LuaJIT C API** — it intercepts `luaL_loadbuffer`/`lua_load` so that whenever the
game compiles a Lua chunk, Lovely rewrites the source first according to the
`lovely.toml` patches it found.

On Android there's no supported way to inject a native library into another
app's process or detour its functions. So we can't do what Lovely does from the
outside. But we have something Lovely has to work hard for: we can edit the
game's files directly, because the Lua source ships inside the APK.

## The idea: patch from the inside, in Lua

LÖVE always runs `main.lua` first. If *our* code is `main.lua`, we run before
any game code and can install the same kind of interception Lovely does —
except in pure Lua, against LÖVE's own loader instead of the C API.

```
LÖVE boot
   └─ runs main.lua  ── (our shim) ──▶ require("mli.injector").boot()
                                          │
                                          ├─ init():
                                          │    • scan Mods/ for lovely patches
                                          │    • register module patches into
                                          │      package.preload
                                          │    • wrap love.filesystem.load
                                          │    • add a require() searcher
                                          │
                                          └─ run():
                                               • read mli/main_original.lua
                                               • apply "main.lua" patches
                                               • compile + execute it
                                                    │
                                                    ▼
                                    the real game runs; every file it
                                    require()s or love.filesystem.load()s
                                    is patched on the way in
```

### Why two hooks (load + searcher)?

Balatro loads code two ways:

1. **`love.filesystem.load(path)`** — used directly in many places. We replace
   `love.filesystem.load` with a wrapper that, for any target with patches,
   reads the source via `love.filesystem.read`, applies the patches, compiles
   the result with `loadstring`, and returns that chunk. Files with no patches
   pass straight through to the original loader.

2. **`require "some/module"`** — goes through `package.loaders`. Depending on
   the LÖVE version, its built-in filesystem searcher may have captured a
   *private* reference to `love.filesystem.load` before we wrapped it, which
   would bypass us. To be safe we insert our own searcher at position 2 (after
   `package.preload`) that resolves the module to a path and routes it through
   our wrapped `love.filesystem.load`. `require` caches in `package.loaded`, so
   there's no double execution.

### Why move `main.lua` aside instead of prepending to it?

`main.lua` is the one file already executing when our code runs, so we can't
"patch it as it loads." Instead the installer renames the original to
`mli/main_original.lua` (a path LÖVE does **not** auto-run) and puts our shim at
`main.lua`. The injector then loads `main_original.lua` itself, applies any
patches authored against `main.lua`, and runs it. This means even `main.lua`
patches — including Steamodded's `copy`-append of `src/core.lua` — work at
runtime, with no install-time mod knowledge required.

If the injector throws during boot, the shim falls back to running
`mli/main_original.lua` untouched, so a broken injector can't brick the game.

## The patch engine

`patch_engine.lua` transforms source **text** before compilation, mirroring
lovely semantics:

- **pattern**: split into lines; for each line matching the wildcard `pattern`
  (`*` = any run, `?` = one char), insert the payload `before`/`after` it or
  replace it (`at`). `match_indent` copies the matched line's leading
  whitespace onto each payload line. `times` caps the number of matches.
- **copy**: read each file in `sources` (relative to the owning mod), join with
  the inline `payload`, and `append`/`prepend` to the target.
- **regex**: best-effort — see limitations.
- **module**: not a text transform; `injector.lua` reads the module source and
  installs a `package.preload[name]` loader so `require(name)` returns it.

Variables (`[vars]`) are interpolated into payloads as `{{lovely:name}}`.
Patches are applied in ascending manifest `priority`, then discovery order —
the same ordering Lovely uses.

## Known limitations

- **Regex patches are best-effort.** Lua has no PCRE. `patch_engine.regex_to_lua`
  translates a useful subset — escapes (`\t \s \d \w` …), character classes,
  `. * + ?`, anchors, and named capture groups `(?<name>...)` referenced as
  `$name` in payloads — to Lua patterns. Constructs it can't translate
  faithfully (alternation `|`, lookaround, non-capturing groups, backreferences)
  are **skipped with a warning** rather than applied incorrectly. A mod that
  relies on such a patch will be missing that one change. If you hit this, the
  fallbacks are: rewrite the patch as a `pattern` patch, or pre-bake just that
  file with desktop Lovely's `dump/`.
- **`main.lua` patches** are applied to the original main body we load
  ourselves. `copy`/`pattern`/`regex` all work; this has been exercised in the
  test suite with a Steamodded-style append.
- **Not yet device-tested.** The pipeline is validated by `tests/run_tests.lua`
  (in-memory filesystem + a fake `love`), but has not been run against a real
  APK on hardware. Treat as beta.
- **Mod file access.** Mods are read through `love.filesystem`, which can see
  the game's fused source and the save directory. Placing mods under
  `Mods/` in the save directory is therefore readable without `nativefs`. Mods
  that themselves use `nativefs` still work because SMODS ships it as a `module`
  patch.

[lovely]: https://github.com/ethangreen-dev/lovely-injector
