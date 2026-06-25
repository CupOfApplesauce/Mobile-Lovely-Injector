# Writing / packaging mods for MLI

MLI reads the **same `lovely.toml` format** as desktop Lovely, so existing mods
generally work as-is. This page is a quick reference plus the mobile caveats.

## Layout

A mod is a folder inside `Mods/`. It contributes patches via either:

- a single `lovely.toml` at the mod root, and/or
- a `lovely/` directory containing one or more `*.toml` files (loaded in
  filename order).

```
Mods/
  MyMod/
    lovely.toml          # or lovely/*.toml
    src/                 # files referenced by copy patches
    libs/whatever.lua    # files referenced by module patches
```

## Manifest

```toml
[manifest]
version = "1.0.0"
priority = 0        # lower runs earlier; patches are applied in priority order
dump_lua = false    # set true to write patched files to mli/dump/ for debugging
```

## Variables

```toml
[vars]
greeting = "hello"
```

Reference them in any payload as `{{lovely:greeting}}`.

## Patch types

### module — inject a Lua module

```toml
[[patches]]
[patches.module]
source = "libs/nativefs.lua"   # path relative to the mod folder
name = "nativefs"              # require("nativefs") will return it
before = "main.lua"            # informational; MLI registers modules before boot
```

Fully supported.

### copy — append/prepend whole files

```toml
[[patches]]
[patches.copy]
target = "main.lua"
position = "append"            # or "prepend"
sources = ["src/core.lua"]     # files joined in order
payload = "-- optional inline code appended after the sources"
```

Fully supported. This is how Steamodded bootstraps itself onto `main.lua`.

### pattern — surgical line edits

```toml
[[patches]]
[patches.pattern]
target = "game.lua"
pattern = "self.SPEEDFACTOR = 1"   # literal; * = any run, ? = one char
position = "after"                 # "before" | "after" | "at" (replace the line)
match_indent = true                # copy the matched line's indentation
times = 1                          # optional: only the first N matches
payload = '''
SMODS.do_thing()
'''
```

Fully supported.

### regex — pattern with capture groups (best-effort on mobile)

```toml
[[patches]]
[patches.regex]
target = "tag.lua"
pattern = "(?<indent>[\t ]*)if (?<cond>condition)"
position = "at"
line_prepend = "$indent"
payload = '''if $cond and my_check()'''
times = 1
```

⚠️ **Mobile caveat:** Lua has no PCRE. MLI translates a useful subset (escapes,
character classes, `. * + ?`, anchors, named groups `(?<name>...)` used as
`$name`). It **skips** patterns it can't translate (alternation `|`, lookaround,
non-capturing groups, backreferences) and logs a warning. If your patch uses
those, prefer a `pattern` patch, or split the regex into translatable pieces.

## Debugging

- Set `dump_lua = true` in your manifest to have MLI write every patched file to
  `mli/dump/<target>` in the save directory — diff these against the originals
  to confirm your patch landed where you expected.
- `mli/log.txt` in the save directory reports discovered mods, per-target patch
  counts, patches that matched 0 lines, skipped regexes, and compile errors.
- Locally you can exercise the engine without a device — see
  `tests/run_tests.lua` for how to drive it with an in-memory filesystem.
