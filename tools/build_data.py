#!/usr/bin/env python3
"""Generate Stash or Trash's recipe data from the game clients' own data tables.

Data comes from wago.tools DB2 CSV exports of each client build, so the recipe
database matches what the game actually ships, instead of a hand-maintained list.

Flavors:
    forever  WoW Forever           -> StashOrTrash/Data/Recipes_Forever.lua
    era      Classic Era/Hardcore  -> StashOrTrash/Data/Recipes_Era.lua

Usage:
    python3 tools/build_data.py                         # all flavors, newest builds
    python3 tools/build_data.py --flavor era
    python3 tools/build_data.py --flavor forever --build 1.60.1.70291
    python3 tools/build_data.py --offline               # reuse cached CSVs only

Only the Python standard library is used.
"""

import argparse
import csv
import io
import json
import os
import re
import sys
import urllib.request

WAGO = "https://wago.tools"
HEADERS = {"User-Agent": "StashOrTrash-addon-databuilder/1.0 (+https://github.com)"}

# Parent skill lines for every crafting / gathering profession. Forever also
# has child skill lines (e.g. 2937 "Alchemy" under 171); those are discovered
# from SkillLine.ParentSkillLineID and mapped back to the parent.
PROFESSIONS = {
    129: "First Aid",
    164: "Blacksmithing",
    165: "Leatherworking",
    171: "Alchemy",
    182: "Herbalism",
    185: "Cooking",
    186: "Mining",
    197: "Tailoring",
    202: "Engineering",
    333: "Enchanting",
    356: "Fishing",
    393: "Skinning",
    40: "Poisons",  # Rogue only
}

FLAVORS = {
    "forever": {
        "label": "WoW Forever",
        "product": "wow_classic_beta",  # becomes its own product at launch: pass --product
        "version_prefix": "1.60.",
        "out": "Recipes_Forever.lua",
        # Forever ships TradeSkillCategory; real recipes hang off a per-profession
        # category tree, leftovers (Season of Discovery, prototypes) do not.
        "use_categories": True,
        "max_spell": None,
        "exclude": set(),
    },
    "era": {
        "label": "Classic Era / Hardcore",
        "product": "wow_classic_era",
        "version_prefix": "1.15.",
        "out": "Recipes_Era.lua",
        # Era has no category table. The client also carries Season of Discovery
        # recipes, which all have spell IDs >= 400000; 1.12 recipes are < 31000.
        "use_categories": False,
        "max_spell": 400000,
        # Recipes in the 1.12 data that were never obtainable.
        "exclude": {
            2336,  # Elixir of Tongues
            6619,  # Cowardly Flight Potion
            22434,  # Charged Scale of Onyxia
        },
    },
}

BASE_TABLES = ["SkillLine", "SkillLineAbility", "SpellReagents", "SpellName", "ItemSparse"]

EXCLUDED_ROOT_CATEGORY = re.compile(r"SEASON OF DISCOVERY|PROTOTYPE|\bDNT\b|\bUNUSED\b|\bTEST\b", re.I)
# Placeholder/test markers in spell or item names. Case-sensitive on purpose so
# that real names like "Golden Scale Coif" are not caught by "OLD".
BAD_NAME = re.compile(r"\((?:OLD|TEST|DND|DNT|NYI|PH)\)|\[(?:DNT|PH|DND|TEST)\]|^zz|^OLD |Deprecated|^Monster - |\bTEST\b")
# Uncategorised recipes are only trusted when they are original-game spells
# (e.g. Basic Campfire). Newer uncategorised spells are unfinished content.
LEGACY_SPELL_MAX = 100000


def fetch(url):
    with urllib.request.urlopen(urllib.request.Request(url, headers=HEADERS), timeout=300) as r:
        return r.read().decode("utf-8", "replace")


def latest_build(product, version_prefix):
    builds = json.loads(fetch(f"{WAGO}/api/builds/latest"))
    info = builds.get(product)
    version = info.get("version") if isinstance(info, dict) else None
    if not version:
        sys.exit(f"wago.tools has no build for product {product!r}; pass --product or --build.")
    if not version.startswith(version_prefix):
        sys.exit(f"{product} is at {version}, expected {version_prefix}x; pass --product or --build.")
    return version


def load_table(name, build, cache, offline):
    path = os.path.join(cache, build, f"{name}.csv") if cache else None
    if path and os.path.exists(path):
        with open(path, encoding="utf-8") as f:
            text = f.read()
    else:
        if offline:
            sys.exit(f"--offline given but {path} is missing")
        print(f"  downloading {name} ...", file=sys.stderr)
        text = fetch(f"{WAGO}/db2/{name}/csv?build={build}")
        if path:
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path, "w", encoding="utf-8") as f:
                f.write(text)
    return list(csv.DictReader(io.StringIO(text)))


def lua_str(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n") + '"'


def as_int(row, key):
    return int(row.get(key) or 0)


def build(tables, flavor):
    skill_lines = {int(r["ID"]): r for r in tables["SkillLine"]}
    categories = {int(r["ID"]): r for r in tables.get("TradeSkillCategory", [])}
    spell_names = {int(r["ID"]): r["Name_lang"] for r in tables["SpellName"]}
    item_names = {int(r["ID"]): r["Display_lang"] for r in tables["ItemSparse"]}
    reagents_by_spell = {int(r["SpellID"]): r for r in tables["SpellReagents"]}

    children = {pid: [] for pid in PROFESSIONS}
    for sid, row in skill_lines.items():
        parent = as_int(row, "ParentSkillLineID")
        if parent in children:
            children[parent].append(sid)

    def category_ok(cat_id, spell_id):
        if cat_id == 0:
            return spell_id < LEGACY_SPELL_MAX
        root = None
        seen = set()
        while cat_id and cat_id in categories and cat_id not in seen:
            seen.add(cat_id)
            root = categories[cat_id]
            cat_id = as_int(root, "ParentTradeSkillCategoryID")
        if root is None:
            return False
        # Real profession categories hang off a per-profession root ("Alchemy",
        # "Cooking", ...). Orphan roots like "SEASON OF DISCOVERY" do not.
        return len(seen) >= 2 and not EXCLUDED_ROOT_CATEGORY.search(root["Name_lang"])

    recipes = {}  # spellID -> (prof, minSkill, yellowAt, grayAt, name, items)
    skipped = {"no_reagents": 0, "filtered": 0, "name": 0, "bad_item": 0}
    for row in tables["SkillLineAbility"]:
        prof = int(row["SkillLine"])
        if prof not in PROFESSIONS:
            continue
        spell = int(row["Spell"])
        rr = reagents_by_spell.get(spell)
        if not rr:
            skipped["no_reagents"] += 1
            continue
        if spell in flavor["exclude"] or (flavor["max_spell"] and spell >= flavor["max_spell"]):
            skipped["filtered"] += 1
            continue
        if flavor["use_categories"] and not category_ok(as_int(row, "TradeSkillCategoryID"), spell):
            skipped["filtered"] += 1
            continue
        name = spell_names.get(spell, "")
        if not name or BAD_NAME.search(name):
            skipped["name"] += 1
            continue
        items = []
        for i in range(8):
            item, count = as_int(rr, f"Reagent_{i}"), as_int(rr, f"ReagentCount_{i}")
            if item > 0 and count > 0:
                items.append((item, count))
        if not items or any(i not in item_names or BAD_NAME.search(item_names[i]) for i, _ in items):
            skipped["bad_item"] += 1
            continue
        min_skill = as_int(row, "MinSkillLineRank")
        yellow = as_int(row, "TrivialSkillLineRankLow")
        grey = as_int(row, "TrivialSkillLineRankHigh")
        prev = recipes.get(spell)
        if prev is None or min_skill < prev[1]:
            recipes[spell] = (prof, min_skill, yellow, grey, name, items)

    reagents = {}
    for spell, (prof, _, _, _, _, items) in recipes.items():
        for item, count in items:
            reagents.setdefault(item, []).append((spell, count))

    return children, skill_lines, recipes, reagents, skipped


def write_lua(out_path, flavor_key, build_id, children, skill_lines, recipes, reagents):
    flavor = FLAVORS[flavor_key]
    lines = [
        "-- GENERATED by tools/build_data.py -- do not edit by hand.",
        f"-- Source: wago.tools DB2 exports for {flavor['label']} build {build_id}",
        "local _, ns = ...",
        "",
        f"ns.DataFlavor = {lua_str(flavor_key)}",
        f"ns.DataBuild = {lua_str(build_id)}",
        "",
        "-- [parentSkillLineID] = { name = English name, icon = fileID, children = { child skill lines } }",
        "ns.Professions = {",
    ]
    for pid in sorted(PROFESSIONS):
        icon = as_int(skill_lines.get(pid, {}), "SpellIconFileID")
        kids = ", ".join(str(c) for c in sorted(children[pid]))
        lines.append(f"\t[{pid}] = {{ name = {lua_str(PROFESSIONS[pid])}, icon = {icon}, children = {{ {kids} }} }},")
    lines += [
        "}",
        "",
        "-- [recipeSpellID] = { professionSkillLineID, requiredSkill, yellowAt, grayAt, English name }",
        "-- yellowAt/grayAt are the skill levels where the recipe turns yellow/gray (0 = no skill-ups).",
        "ns.Recipes = {",
    ]
    for spell in sorted(recipes):
        prof, min_skill, yellow, grey, name, _ = recipes[spell]
        lines.append(f"\t[{spell}] = {{ {prof}, {min_skill}, {yellow}, {grey}, {lua_str(name)} }},")
    lines += [
        "}",
        "",
        "-- [reagentItemID] = { recipeSpellID, countRequired, recipeSpellID, countRequired, ... }",
        "ns.Reagents = {",
    ]
    for item in sorted(reagents):
        flat = ", ".join(f"{s}, {c}" for s, c in sorted(reagents[item]))
        lines.append(f"\t[{item}] = {{ {flat} }},")
    lines += ["}", ""]
    os.makedirs(os.path.dirname(out_path), exist_ok=True)
    with open(out_path, "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(lines))


def generate(flavor_key, args, out_dir):
    flavor = FLAVORS[flavor_key]
    build_id = args.build or latest_build(args.product or flavor["product"], flavor["version_prefix"])
    print(f"{flavor['label']}: building recipe data from build {build_id}", file=sys.stderr)
    names = BASE_TABLES + (["TradeSkillCategory"] if flavor["use_categories"] else [])
    tables = {t: load_table(t, build_id, args.cache, args.offline) for t in names}
    children, skill_lines, recipes, reagents, skipped = build(tables, flavor)
    out_path = os.path.normpath(os.path.join(out_dir, flavor["out"]))
    write_lua(out_path, flavor_key, build_id, children, skill_lines, recipes, reagents)

    per_prof = {}
    for prof, *_ in recipes.values():
        per_prof[PROFESSIONS[prof]] = per_prof.get(PROFESSIONS[prof], 0) + 1
    print(f"  wrote {len(recipes)} recipes using {len(reagents)} reagents -> {out_path}", file=sys.stderr)
    print("  per profession: " + ", ".join(f"{k} {v}" for k, v in sorted(per_prof.items())), file=sys.stderr)
    print("  skipped: " + ", ".join(f"{k} {v}" for k, v in skipped.items()), file=sys.stderr)


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--flavor", choices=sorted(FLAVORS) + ["all"], default="all")
    ap.add_argument("--build", help="exact client build (only with a single --flavor)")
    ap.add_argument("--product", help="wago.tools product to take the latest build from (only with a single --flavor)")
    ap.add_argument("--cache", default=os.path.join(here, "..", ".db2cache"), help="CSV cache dir ('' to disable)")
    ap.add_argument("--offline", action="store_true", help="only use cached CSVs (requires --build)")
    ap.add_argument("--out-dir", default=os.path.join(here, "..", "StashOrTrash", "Data"))
    args = ap.parse_args()

    flavors = sorted(FLAVORS) if args.flavor == "all" else [args.flavor]
    if (args.build or args.product) and len(flavors) > 1:
        ap.error("--build/--product need a single --flavor")
    if args.offline and not args.build:
        ap.error("--offline needs --build (the latest build can't be looked up offline)")
    for flavor_key in flavors:
        generate(flavor_key, args, args.out_dir)


if __name__ == "__main__":
    main()
