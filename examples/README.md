# Example & utility mods

These are small, self-contained mods that ship with Mobile Lovely Injector.
Each is a normal mod folder — drop it into your `Mods` folder (e.g.
`Download/Mods/<Name>`) alongside Steamodded and your other mods. Remove a
folder to disable it.

`HelloMod` is a learning example. The other three are **optional utilities**
that help big mods run on memory-tight devices and harden a couple of edge
cases. None of them modify Steamodded or any other mod on disk — they only
apply Lovely patches at load time, the same way any mod does.

| Mod | What it does | When to use it |
|---|---|---|
| **AtlasMemFix** | Frees the redundant CPU-side copy of every Steamodded atlas once its GPU texture is built. | Safe everywhere — no visual change. Recommended always. |
| **LowResTextures** | Forces 1× (half-resolution) textures for the whole game and all mods, cutting texture memory ~4×. | Memory-tight phones running large content mods. Trade-off: more pixelated sprites. |
| **SmodsColourGuard** | Guards a nil-colour lookup in Steamodded's tooltip renderer (`SMODS.localize_box`). | Safe everywhere — prevents a rare tooltip crash. |
| **HelloMod** | A minimal example showing the three patch kinds (module / copy / pattern). | Learning / verifying your setup. Not needed for normal play. |

## AtlasMemFix

Steamodded loads each atlas as **both** a CPU bitmap (`image_data`) and a GPU
texture, but never reads the CPU copy again. On a phone, where the GPU shares
system RAM, that's a full redundant copy of every atlas. AtlasMemFix releases
it right after the texture is created. No visual change; pure memory savings.
Fine to leave installed on any device.

## LowResTextures

Balatro defaults `texture_scaling` to `2` (high-resolution). On a phone the GPU
shares system RAM, so loading 2× atlases for the base game plus a large content
mod (e.g. Pokermon) can exhaust memory and force-close before the menu. This
forces `1×` everywhere (base game **and** mod atlases load from `assets/1x/`),
roughly a 4× reduction in texture memory.

Trade-off: sprites are lower-resolution / more pixelated — purely cosmetic,
gameplay is identical, and on a high-DPI phone screen the difference is small.
Remove the folder to return to full-resolution textures. Try **AtlasMemFix
alone first**; add this only if you still run out of memory.

## SmodsColourGuard

Steamodded's `localize_box` builds tooltip colours with
`part.control.V and args.vars.colours[tonumber(part.control.V)]`. If a string
uses a `{V:n}` colour-index code but the caller passes no `vars.colours`, that
indexes a nil value and crashes. (Some mods, e.g. Pokermon, used to guard this
in the base game's `misc_functions`, but newer Steamodded moved the code into
`localize_box`, stranding the old guard.) This re-adds the `args.vars.colours`
short-circuit in the new location. Safe everywhere, no visual change.

## HelloMod

A minimal example mod demonstrating all three fully-supported patch kinds:

- **module** — registers `require("hellomod.util")` for the whole game,
- **copy** — appends a bootstrap to the end of `main.lua`,
- **pattern** — adds a line after a known anchor in `game.lua`.

The bootstrap adds a small, customizable tag to the version string shown in the
corner of the main menu (edit `src/bootstrap.lua` to make it your own). It does
**not** draw over gameplay. Use it to learn the patch format or to confirm your
setup is loading mods; it isn't needed for normal play.
