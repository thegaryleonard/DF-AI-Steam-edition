Watch Dwarf Fortress play itself!

Plugin for DFHack.

> **This branch is an unofficial port to Dwarf Fortress 53.16 / DFHack 53.16-r3** (the Steam-era game).
> See [INSTALL-WINDOWS.md](INSTALL-WINDOWS.md) for installing and what is and isn't automated yet.
> Windows builds are produced by the GitHub Actions workflow in `.github/workflows/build-windows.yml`
> (Actions tab → *Build df-ai for Windows* → download the artifact).

Embark yourself, then run `enable df-ai` in the DFHack console. Run `help ai` for a list of [console commands](https://github.com/BenLubar/df-ai/wiki/Console-Commands).

Does not handle already started forts, but can resume from df-ai saves and handle fresh embarks. Check `dfhack-config/df-ai.json` for settings.

## Building

df-ai is built as an external DFHack plugin: put this folder at `plugins/external/df-ai` in a DFHack source tree checked out at the matching release tag, add `add_subdirectory(df-ai)` to `plugins/external/CMakeLists.txt`, configure DFHack, and build the `df-ai` target. On Windows this must be MSVC (Visual Studio 2022), like DFHack itself.

[![xkcd 1223](https://imgs.xkcd.com/comics/dwarf_fortress.png "I may be the kind of person who wastes a year implementing a Turing-complete computer in Dwarf Fortress, but that makes you the kind of person who wastes ten more getting that computer to run Minecraft.")](https://xkcd.com/1223/)

See the [df-ai wiki](https://github.com/BenLubar/df-ai/wiki) for more information.
