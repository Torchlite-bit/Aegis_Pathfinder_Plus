#!/usr/bin/env python3
"""Convert the professions reference document into TurtleGuide guides.

    python3 Tools/convert_professions.py [--check]

Reads Tools/data/Professions_Reference.docx and writes Guides/Professions/.
With --check it parses and validates but writes nothing.

Output is QuestShell+ (structured Lua tables), not the pipe-delimited DSL:
these guides are generated, and a generated corpus wants a format that diffs
and validates cleanly. QuestShellPlusParser turns the tables into the tag
strings the core parser consumes.

The converter refuses to invent anything. Where the document is silent -- a
skill range it has no recipe for, a trainer it does not name -- that silence is
carried through into the guide as a note, rather than filled in with a guess.
"""

import argparse
import os
import re
import sys
import zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DOCX = os.path.join(ROOT, "Tools", "data", "Professions_Reference.docx")
OUTDIR = os.path.join(ROOT, "Guides", "Professions")

# Professions the concept's Professions tab lists but the document has no route
# for. They ship as visibly-unauthored templates rather than being dropped, so
# the tab matches the concept and nobody mistakes an empty guide for a real one.
UNSOURCED = [
    ("Engineering", "crafting"),
    ("Herbalism", "gathering"),
    ("Skinning", "gathering"),
    ("Fishing", "gathering"),
]

MAX_SKILL = 300


# --------------------------------------------------------------------------
# Document reading
# --------------------------------------------------------------------------

def docx_paragraphs(path):
    """Yield (style, text) for every non-empty paragraph."""
    with zipfile.ZipFile(path) as z:
        xml = z.read("word/document.xml").decode("utf-8")
    for para in re.findall(r"<w:p[ >].*?</w:p>", xml, re.S):
        text = "".join(re.findall(r"<w:t[^>]*>(.*?)</w:t>", para, re.S))
        text = (text.replace("&amp;", "&").replace("&lt;", "<")
                    .replace("&gt;", ">").replace("&quot;", '"')
                    .replace("&#39;", "'"))
        style = re.search(r'w:pStyle w:val="([^"]+)"', para)
        if text.strip():
            yield (style.group(1) if style else ""), text.strip()


# The document uses an en dash in ranges and an arrow in skill transitions.
DASH = "–"
ARROW = "→"

# Most sections are titled "<Name> Leveling Planner (1-300)", but Enchanting is
# "Leveling Guide" and several headings carry emoji. Both variants are the
# document's, not typos to normalise away, so the patterns accept both.
RE_PLANNER = re.compile(r"^(.+?)\s+Leveling (?:Planner|Guide)\s+\(1[%s-]300\)(.*)$" % DASH)
RE_CRAFTS = re.compile(r"~(\d+)\s+total crafts")
RE_SHOP_ITEM = re.compile(r"^(\d+)x\s+(.+?)$")
RE_TRAINER_TIER = re.compile(r"^(.+?)\s*\(([\d%s]+)\):\s*(.+)$" % DASH)
RE_TRAINER_ENTRY = re.compile(r"^(.+?)\s*\(([^)]+)\)$")
RE_STEP_RANGE = re.compile(r"^(\d+)\s*%s\s*(\d+)$" % ARROW)
RE_TRAIN_HDR = re.compile(r"^\[([\d%s]+)\]\s+(.+)$" % DASH)
RE_CRAFT = re.compile(r"^Craft:\s*(\d+)x\s+(.+)$")
RE_METHOD = re.compile(r"^Method:\s*(.+)$")
RE_REAGENTS = re.compile(r"^Reagents:\s*(.+)$")
RE_SOURCE = re.compile(r"^Source:\s*(.+)$")
RE_ALTS = re.compile(r"^Alternatives:\s*(.+)$")
RE_NOTE = re.compile(r"^Note:\s*(.+)$")
RE_REAGENT = re.compile(r"^(.+?)\s+x(\d+)$")

SECTION_SHOPPING = "shopping"
SECTION_TRAINERS = "trainers"
SECTION_ROUTE = "route"


def parse(path):
    professions = []
    cur = None
    section = None
    faction = None
    step = None

    def flush_step():
        nonlocal step
        if step and cur:
            cur["steps"].append(step)
        step = None

    def heading(text):
        """Section headings vary: some carry a leading emoji and a space."""
        return re.sub(r"^[^\w\[]+", "", text).strip()

    for _, raw in docx_paragraphs(path):
        text = heading(raw)
        m = RE_PLANNER.match(text)
        if m:
            # Some headings are glued to the intro paragraph that follows.
            flush_step()
            name, trailing = m.group(1).strip(), m.group(2)
            cur = {
                "name": name, "crafts": None, "shopping": [], "shoppingNote": None,
                "trainers": {"Alliance": [], "Horde": []}, "steps": [],
            }
            crafts = RE_CRAFTS.search(trailing)
            if crafts:
                cur["crafts"] = int(crafts.group(1))
            professions.append(cur)
            section = None
            faction = None
            continue

        if cur is None:
            continue

        if RE_CRAFTS.search(text) and cur["crafts"] is None:
            cur["crafts"] = int(RE_CRAFTS.search(text).group(1))
            continue

        if text.startswith("Shopping List"):
            flush_step()
            section = SECTION_SHOPPING
            continue
        if text.startswith("Step-by-Step Leveling Route"):
            flush_step()
            section = SECTION_ROUTE
            continue
        if re.match(r"^(Alliance|Horde) Trainers?( Locations)?$", text):
            flush_step()
            section = SECTION_TRAINERS
            faction = text.split()[0]
            continue
        if text == "Trainer Locations":
            flush_step()
            section = SECTION_TRAINERS
            continue

        if section == SECTION_SHOPPING:
            m = RE_SHOP_ITEM.match(text)
            if m:
                qty, item = int(m.group(1)), m.group(2)
                note = None
                paren = re.match(r"^(.+?)\s+\((.+)\)$", item)
                if paren:
                    item, note = paren.group(1).strip(), paren.group(2).strip()
                cur["shopping"].append({"qty": qty, "item": item, "note": note})
            elif text.startswith("Note:"):
                cur["shoppingNote"] = RE_NOTE.match(text).group(1)
            # Anything else here is a category header (Survival groups its list);
            # the totals are what matter, so headers are not carried through.
            continue

        if section == SECTION_TRAINERS:
            m = RE_TRAINER_TIER.match(text)
            if m and faction:
                tier, rng, who = m.group(1).strip(), m.group(2), m.group(3)
                entries = []
                for part in who.split(","):
                    part = part.strip()
                    em = RE_TRAINER_ENTRY.match(part)
                    if em:
                        entries.append({"name": em.group(1).strip(),
                                        "zone": em.group(2).strip()})
                    elif part:
                        entries.append({"name": part, "zone": None})
                cur["trainers"][faction].append(
                    {"tier": tier, "range": rng.replace(DASH, "-"), "entries": entries})
            continue

        if section == SECTION_ROUTE:
            m = RE_TRAIN_HDR.match(text)
            if m:
                flush_step()
                cur["steps"].append({
                    "kind": "train", "at": m.group(1).replace(DASH, "-"),
                    "label": m.group(2).strip(),
                })
                continue

            m = RE_STEP_RANGE.match(text)
            if m:
                flush_step()
                step = {"kind": None, "from": int(m.group(1)), "to": int(m.group(2)),
                        "reagents": [], "alternatives": [], "note": None,
                        "source": None, "count": None, "item": None, "method": None}
                continue

            if step is None:
                continue

            m = RE_CRAFT.match(text)
            if m:
                step["kind"] = "craft"
                step["count"] = int(m.group(1))
                step["item"] = m.group(2).strip()
                continue
            m = RE_METHOD.match(text)
            if m:
                step["kind"] = "method"
                step["method"] = m.group(1).strip()
                continue
            m = RE_REAGENTS.match(text)
            if m:
                for part in m.group(1).split(","):
                    part = part.strip()
                    rm = RE_REAGENT.match(part)
                    if rm:
                        step["reagents"].append({"item": rm.group(1).strip(),
                                                 "qty": int(rm.group(2))})
                    elif part:
                        step["reagents"].append({"item": part, "qty": 1})
                continue
            m = RE_SOURCE.match(text)
            if m:
                # "Source: Recipe: Recipe: X" appears in the document; collapse it.
                src = m.group(1).strip()
                src = re.sub(r"^(Recipe:\s*)+", "Recipe: ", src)
                step["source"] = src
                continue
            m = RE_ALTS.match(text)
            if m:
                alts = m.group(1).strip()
                if alts.lower() != "none":
                    step["alternatives"] = [a.strip() for a in alts.split(",") if a.strip()]
                continue
            m = RE_NOTE.match(text)
            if m:
                step["note"] = m.group(1).strip()
                continue

    flush_step()
    return professions


# --------------------------------------------------------------------------
# Validation
# --------------------------------------------------------------------------

def validate(professions):
    """Report inconsistencies in the source document. Never silently repairs."""
    problems = []

    for p in professions:
        name = p["name"]
        ranges = [s for s in p["steps"] if s["kind"] in ("craft", "method")]

        if not ranges:
            problems.append("%s: no skill ranges parsed" % name)
            continue

        # Contiguity: each range must start where the previous one ended.
        cursor = ranges[0]["from"]
        if cursor != 1:
            problems.append("%s: route starts at %d, not 1" % (name, cursor))
        for s in ranges:
            if s["from"] != cursor:
                problems.append("%s: gap/overlap at %d%s%d (previous ended %d)"
                                % (name, s["from"], DASH, s["to"], cursor))
            if s["to"] <= s["from"]:
                problems.append("%s: non-advancing range %d%s%d"
                                % (name, s["from"], DASH, s["to"]))
            cursor = s["to"]
        if cursor != MAX_SKILL:
            problems.append("%s: route ends at %d, not %d" % (name, cursor, MAX_SKILL))

        # Every reagent a step calls for should appear in the shopping list.
        listed = {i["item"].lower() for i in p["shopping"]}
        # Intermediates are crafted mid-route from listed materials.
        crafted = {s["item"].lower() for s in ranges if s.get("item")}
        for s in ranges:
            for r in s["reagents"]:
                key = r["item"].lower()
                if key not in listed and key not in crafted:
                    problems.append("%s: reagent '%s' (%d%s%d) is in no shopping list"
                                    % (name, r["item"], s["from"], DASH, s["to"]))

        # A craft step with no reagents cannot be shopped for.
        for s in ranges:
            if s["kind"] == "craft" and not s["reagents"]:
                problems.append("%s: craft '%s' lists no reagents" % (name, s["item"]))

        if not p["trainers"]["Alliance"] and not p["trainers"]["Horde"]:
            problems.append("%s: no trainers parsed" % name)

    return problems


# --------------------------------------------------------------------------
# Lua emission
# --------------------------------------------------------------------------

def lua_str(s):
    return '"%s"' % s.replace("\\", "\\\\").replace('"', '\\"')


def lua_list(items):
    return "{ " + ", ".join(lua_str(i) for i in items) + " }"


def emit_steps(p):
    """Turn a parsed profession into QuestShell+ step tables."""
    name = p["name"]
    out = []

    intro = ("A low-cost 1-300 route. Craft counts are estimates"
             + (" (about %d crafts in total)." % p["crafts"] if p["crafts"] else "."))
    out.append({"type": "NOTE", "title": "%s (1-300)" % name, "note": intro})

    if p["shoppingNote"]:
        out.append({"type": "NOTE", "title": "Before you start",
                    "note": p["shoppingNote"]})

    # Trainers, filtered to the player's own faction.
    for fac in ("Alliance", "Horde"):
        for tier in p["trainers"][fac]:
            who = ", ".join(
                e["name"] + (" (%s)" % e["zone"] if e["zone"] else "")
                for e in tier["entries"])
            out.append({
                "type": "TRAIN",
                "title": "%s %s (%s)" % (tier["tier"], name, tier["range"]),
                "note": who,
                "faction": fac,
                "optional": True,
            })

    for s in p["steps"]:
        if s["kind"] == "train":
            out.append({"type": "TRAIN", "title": s["label"],
                        "note": "Skill %s" % s["at"]})
        elif s["kind"] == "craft":
            step = {
                "type": "USE",
                "title": "Craft %dx %s" % (s["count"], s["item"]),
                "skill": {"profession": name, "from": s["from"], "to": s["to"]},
                "craft": {"item": s["item"], "count": s["count"]},
                "reagents": s["reagents"],
            }
            if s["source"]:
                step["source"] = s["source"]
            if s["alternatives"]:
                step["alternatives"] = s["alternatives"]
            note = "Takes you from %d to %d." % (s["from"], s["to"])
            if s["note"]:
                note += " " + s["note"]
            step["note"] = note
            out.append(step)
        elif s["kind"] == "method":
            step = {
                "type": "GRIND",
                "title": s["method"],
                "skill": {"profession": name, "from": s["from"], "to": s["to"]},
                "note": "Takes you from %d to %d." % (s["from"], s["to"]),
            }
            if s["note"]:
                step["note"] += " " + s["note"]
            out.append(step)

    out.append({"type": "NOTE", "title": "Guide Complete",
                "note": "%s is maxed at %d." % (name, MAX_SKILL)})
    return out


def step_to_lua(step, indent="\t\t"):
    parts = ['type = %s' % lua_str(step["type"])]
    if "title" in step:
        parts.append("title = %s" % lua_str(step["title"]))
    if step.get("note"):
        parts.append("note = %s" % lua_str(step["note"]))
    if step.get("faction"):
        parts.append("faction = %s" % lua_str(step["faction"]))
    if step.get("optional"):
        parts.append("optional = true")
    if step.get("skill"):
        sk = step["skill"]
        parts.append("skill = { profession = %s, from = %d, to = %d }"
                     % (lua_str(sk["profession"]), sk["from"], sk["to"]))
    if step.get("craft"):
        c = step["craft"]
        parts.append("craft = { item = %s, count = %d }" % (lua_str(c["item"]), c["count"]))
    if step.get("reagents"):
        inner = ", ".join("{ item = %s, qty = %d }" % (lua_str(r["item"]), r["qty"])
                          for r in step["reagents"])
        parts.append("reagents = { %s }" % inner)
    if step.get("source"):
        parts.append("source = %s" % lua_str(step["source"]))
    if step.get("alternatives"):
        parts.append("alternatives = %s" % lua_list(step["alternatives"]))

    body = (",\n" + indent + "\t").join(parts)
    return "%s{\n%s\t%s,\n%s}" % (indent, indent, body, indent)


HEADER = """-- %(name)s (1-300)
--
-- GENERATED FILE -- do not edit by hand.
-- Source:    Tools/data/Professions_Reference.docx
-- Generator: Tools/convert_professions.py
--
-- Regenerate with:  python3 Tools/convert_professions.py
"""


def emit_guide(p):
    steps = emit_steps(p)
    lua = [HEADER % {"name": p["name"]}, ""]
    lua.append('TurtleGuide:RegisterQuestShellPlusGuide("%s (1-300)", {' % p["name"])
    lua.append('\tfaction = "Both",')
    lua.append('\tcategory = "Profession",')
    lua.append("\tsteps = {")
    for s in steps:
        lua.append(step_to_lua(s) + ",")
    lua.append("\t},")
    lua.append("})")
    lua.append("")
    return "\n".join(lua)


TEMPLATE_HEADER = """-- %(name)s (1-300) -- NOT YET AUTHORED
--
-- GENERATED FILE -- do not edit by hand.
-- Generator: Tools/convert_professions.py
--
-- The professions reference this addon's guides were built from does not cover
-- %(name)s, so there is no route to convert. This placeholder exists so the
-- Professions list matches the design concept and so an unauthored guide is
-- obviously unauthored rather than silently missing.
--
-- %(shape)s
"""

SHAPE = {
    "crafting": ("Authoring this needs a craft-by-craft route: skill ranges, what to "
                 "make in each, and the reagents. Follow the pattern in any generated "
                 "profession guide in this folder."),
    "gathering": ("This is a gathering profession, so it does not level by crafting. "
                  "It needs a different step shape from the generated guides here: "
                  "where to gather at each skill band, not what to craft."),
}


def emit_template(name, kind):
    lua = [TEMPLATE_HEADER % {"name": name, "shape": SHAPE[kind]}, ""]
    lua.append('TurtleGuide:RegisterQuestShellPlusGuide("%s (1-300)", {' % name)
    lua.append('\tfaction = "Both",')
    lua.append('\tcategory = "Profession",')
    lua.append("\ttemplate = true,")
    lua.append("\tsteps = {")
    lua.append(step_to_lua({
        "type": "NOTE",
        "title": "%s -- not yet authored" % name,
        "note": ("This guide is a placeholder. No route for %s exists in the "
                 "reference this addon's profession guides were built from." % name),
    }) + ",")
    lua.append(step_to_lua({
        "type": "TRAIN",
        "title": "Learn %s" % name,
        "note": "Train with any %s trainer." % name,
    }) + ",")
    lua.append("\t},")
    lua.append("})")
    lua.append("")
    return "\n".join(lua)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true",
                    help="parse and validate without writing")
    args = ap.parse_args()

    if not os.path.exists(DOCX):
        print("missing source document: %s" % DOCX)
        return 1

    professions = parse(DOCX)
    print("Parsed %d professions from %s\n" % (len(professions), os.path.basename(DOCX)))

    for p in professions:
        ranges = [s for s in p["steps"] if s["kind"] in ("craft", "method")]
        print("  %-16s %2d ranges  %3d shopping items  %d/%d trainer tiers  ~%s crafts"
              % (p["name"], len(ranges), len(p["shopping"]),
                 len(p["trainers"]["Alliance"]), len(p["trainers"]["Horde"]),
                 p["crafts"] if p["crafts"] else "?"))

    problems = validate(professions)
    print("")
    if problems:
        print("%d consistency issue(s) in the source document:" % len(problems))
        for msg in problems:
            print("  ! " + msg)
        print("\nThese are reported, not repaired -- the document is the authority.")
    else:
        print("Source document is internally consistent.")

    if args.check:
        return 0

    os.makedirs(OUTDIR, exist_ok=True)
    written = []
    for p in professions:
        fn = re.sub(r"[^A-Za-z0-9]+", "_", p["name"]) + ".lua"
        with open(os.path.join(OUTDIR, fn), "w", encoding="utf-8") as fh:
            fh.write(emit_guide(p))
        written.append(fn)

    for name, kind in UNSOURCED:
        fn = re.sub(r"[^A-Za-z0-9]+", "_", name) + ".lua"
        with open(os.path.join(OUTDIR, fn), "w", encoding="utf-8") as fh:
            fh.write(emit_template(name, kind))
        written.append(fn)

    with open(os.path.join(OUTDIR, "Guides.xml"), "w", encoding="utf-8") as fh:
        fh.write('<Ui xmlns="http://www.blizzard.com/wow/ui/">\n')
        for fn in sorted(written):
            fh.write('\t<Script file="%s"/>\n' % fn)
        fh.write("</Ui>\n")

    print("\nWrote %d guides (+ Guides.xml) to %s"
          % (len(written), os.path.relpath(OUTDIR, ROOT)))
    print("  authored: %d    templates: %d" % (len(professions), len(UNSOURCED)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
