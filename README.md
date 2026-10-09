# Stash or Trash

A **World of Warcraft: Forever** and **Classic Era / Hardcore** addon that tells
you, right on the item tooltip, whether your professions can use an item — now
or later — so you know what to keep and what to sell.

```
Peacebloom
  [Alchemy]    2 known · 8 learnable
  [First Aid]  1 learnable
  [Herbalism]  1 learnable
  Hold Shift to list recipes

Copper Bar
  Not used by your professions
  Used in Blacksmithing, Engineering, Leatherworking, Mining
```

- **Your professions**: one line per profession that uses the item, with how many
  of those recipes you already **know**, can **learn** at your current skill, and
  can learn **later**.
- **Recipes** (hold Shift, or set to always/never): each recipe that uses the
  item, colored like the trade skill window, with how many you need
  (`Elixir of Minor Defense`, `Peace Tea x2`, `req. 40` …).
- **Alts**: professions of your other characters on the same realm and faction
  (`Tailoring  Stitchy (180)`). Log in once on each alt so Stash or Trash can see them.
- **Not used**: when nothing you have uses the item, it says so, and names the
  professions that do (handy for the auction house).
- **Planned professions**: tick a profession you intend to pick up and its
  materials count as yours.
- **Ignore gray recipes** (off by default): stop flagging materials you only
  need for recipes you've out-leveled.
- **Hardcore aware**: dead Hardcore characters stop counting as alts, and a
  Self-Found character (no trading, no mail) only considers its own professions.

Covers every profession: Alchemy, Blacksmithing, Enchanting, Engineering,
Leatherworking, Tailoring, Mining (smelting), Cooking, First Aid and rogue
Poisons — plus, on Forever, Herbalism / Skinning / Fishing camping crafts.

## Install

The same `StashOrTrash` folder works in both games; each client picks its own `.toc`:

| Game | AddOns folder | Loads | Recipe data |
| --- | --- | --- | --- |
| WoW Forever (beta) | `World of Warcraft\_classic_beta_\Interface\AddOns\` | `StashOrTrash.toc` | `Data/Recipes_Forever.lua` |
| Classic Era / Hardcore / Self-Found | `World of Warcraft\_classic_era_\Interface\AddOns\` | `StashOrTrash_Vanilla.toc` | `Data/Recipes_Era.lua` |

Download the latest `stash-or-trash-<version>.zip` from
[Releases](https://github.com/travisneids/stash-or-trash/releases) and extract
it into that folder; you should end up with `AddOns\StashOrTrash\`. (GitHub's
green *Code → Download ZIP* button gives you the whole repository instead, which
won't load as-is.)

From a checkout, copy the `StashOrTrash` folder (not the repository root). From
WSL, a symlink isn't followed by the Windows client, so copy instead:

```sh
cp -r StashOrTrash "/mnt/c/Program Files (x86)/World of Warcraft/_classic_era_/Interface/AddOns/"
cp -r StashOrTrash "/mnt/c/Program Files (x86)/World of Warcraft/_classic_beta_/Interface/AddOns/"
```

If the game lists Stash or Trash as *out of date*, check the client's interface
number with `/dump select(4, GetBuildInfo())` and update `## Interface:` in
the matching `.toc` (`16001` for the Forever 1.60.1 beta, `11509` for Classic
Era 1.15.9), or tick *Load out of date AddOns*. If the wrong `.toc` is ever
picked up, Stash or Trash prints a warning at login.

## Usage

- Options: **Esc → Options → AddOns → Stash or Trash**, the addon compartment button
  on the minimap, or `/sot` (long form: `/stashortrash`).
- `/sot status`: detected professions, skill, known recipes and tracked alts.
- `/sot scan`: re-detect professions and known recipes.
- `/sot item <itemID or shift-clicked link>`: print what the tooltip would say.
- `/sot forget <Name - Realm>`: stop tracking a deleted alt.

**Open each profession window once per character.** That gives Stash or Trash
the exact skill level and the list of recipes you know (on Classic Era that
includes the separate Enchanting window). On Forever it also picks up recipes
that Blizzard added in a beta patch after the bundled data was built, and saves
them.

## Recipe data

The files in `StashOrTrash/Data/` are generated from each client's own data tables
(via [wago.tools](https://wago.tools) DB2 exports), not hand-maintained lists:

- **Forever**: includes Forever-only recipes. The client also still ships
  Season of Discovery recipes and placeholder entries; those are filtered out
  using Forever's recipe categories.
- **Classic Era**: the 1.12 recipes. Season of Discovery recipes, which the
  Era client also ships, are dropped (they all have spell IDs of 400000 and
  up), as are the three vanilla recipes that were never obtainable (Elixir
  of Tongues, Cowardly Flight Potion, Charged Scale of Onyxia).

To rebuild after a patch:

```sh
python3 tools/build_data.py                      # both, from the newest builds
python3 tools/build_data.py --flavor era
python3 tools/build_data.py --flavor forever --build 1.60.1.70291
# when Forever launches as its own product on wago.tools:
python3 tools/build_data.py --flavor forever --product <product>
```

Downloaded tables are cached in `.db2cache/` (git-ignored). The script prints
recipe counts per profession and how many entries it filtered out.

## Tests

The suite runs the real addon files on Lua 5.1 against a mocked WoW API and
the real generated data:

```sh
lua5.1 tests/run.lua                  # if you have Lua 5.1
python3 -m pip install lupa && python3 tests/run_tests.py   # otherwise
```

## Caveats

These were checked against Blizzard's UI source for each client (Forever
1.60.1.70245, Classic Era 1.15.9.70003) but not yet in a live client:

- **Forever**: profession slots come from `GetProfessions()` (prof1, prof2,
  First Aid, Fishing, Cooking). Rogue Poisons is detected from its skill
  line, or the first time you open its window.
- **Classic Era**: professions are read from the Skills list by name
  (localized names included). Collapsed headers there are briefly expanded and
  then collapsed again.
- Known recipes come from `C_SpellBook.IsSpellKnown` at login. If that misses
  any, opening the profession window fills them in.
- If a tooltip ever looks wrong, `/sot debug` prints any errors Stash or Trash
  hits while building the tooltip.

GitHub Actions runs the suite on every push to `main` and on pull requests.

## Releasing

1. Add a section for the new version at the top of `StashOrTrash/CHANGELOG.md`.
2. Tag and push:
   ```sh
   git tag v0.2.0
   git push origin v0.2.0
   ```

The Release workflow runs the tests, then the
[BigWigs packager](https://github.com/BigWigsMods/packager) builds
`stash-or-trash-v0.2.0.zip` with only the `StashOrTrash` folder (configured in
`.pkgmeta`), stamps the tag into `## Version:` in both `.toc` files, and
publishes it as a GitHub Release with the changelog as its notes.

## License

MIT — see [LICENSE](LICENSE).
