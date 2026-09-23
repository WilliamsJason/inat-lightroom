"""How long a suggestion title really gets, measured rather than reasoned.

Real iNaturalist taxa, through the real PanelCore formatter, in the real
ten-slot shape the panel draws. No fixture in the repo carries a suggestion
payload, so the data comes from the API the plugin itself calls -- and the
answer decides ObservationPanel's NAME_WIDTH, which is fixed, cannot wrap, and
cannot grow with its window, so every name lives or dies by it.

Run it when the formatter changes, or before moving that width again:

    python explore/measure_suggestion_widths.py 600

Talks to api.inaturalist.org unauthenticated, one page a second, and needs
lupa for the Lua side.
"""

from __future__ import annotations

import json
import os
import re
import statistics
import sys
import time
import urllib.parse
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from lua_harness import LuaPlugin

API = "https://api.inaturalist.org/v1/"
UA = {"User-Agent": "inat-lightroom-width-measurement/1.0"}


def get(path, **params):
    url = API + path + "?" + urllib.parse.urlencode(params)
    req = urllib.request.Request(url, headers=UA)
    for attempt in range(4):
        try:
            with urllib.request.urlopen(req, timeout=45) as r:
                return json.load(r)
        except Exception as exc:  # noqa: BLE001
            if attempt == 3:
                raise
            print(f"  retry {attempt + 1}: {exc}", file=sys.stderr)
            time.sleep(2 + attempt * 2)


def popular_species(wanted):
    """The species people photograph most -- the panel's realistic input."""
    out, page = [], 1
    while len(out) < wanted:
        data = get("observations/species_counts",
                   quality_grade="research", per_page=200, page=page)
        results = data.get("results") or []
        if not results:
            break
        for row in results:
            taxon = row.get("taxon") or {}
            if taxon.get("rank") == "species" and taxon.get("id"):
                out.append(taxon["id"])
        page += 1
        time.sleep(1)
    return out[:wanted]


def taxa_with_ancestors(ids):
    out = []
    for i in range(0, len(ids), 30):
        batch = ids[i:i + 30]
        data = get("taxa/" + ",".join(str(x) for x in batch), per_page=30)
        out.extend(data.get("results") or [])
        time.sleep(1)
    return out


def to_lua_text(value):
    """Hand Lua the UTF-8 *bytes*, which is what the real plugin gets.

    The harness runs lupa with a latin-1 encoding, so a Python str with a Greek
    or accented character cannot be pushed directly. Encoding to UTF-8 and
    reinterpreting as latin-1 pushes the same byte sequence Lightroom would
    hand PanelCore, and `from_lua_text` reads it back.
    """
    return value.encode("utf-8").decode("latin-1")


def from_lua_text(value):
    return value.encode("latin-1").decode("utf-8")


def deep(plugin, value):
    if isinstance(value, dict):
        return plugin.runtime.table_from(
            {k: deep(plugin, v) for k, v in value.items()})
    if isinstance(value, list):
        return plugin.runtime.table_from(
            {i + 1: deep(plugin, v) for i, v in enumerate(value)})
    if isinstance(value, str):
        return to_lua_text(value)
    return value


def ancestor_chain(taxon):
    return [
        {"id": a.get("id"), "name": a.get("name"), "rank": a.get("rank"),
         "preferred_common_name": a.get("preferred_common_name")}
        for a in (taxon.get("ancestors") or [])
        if a.get("id")
    ]


def main(sample_size=400):
    print(f"fetching the {sample_size} most-observed species ...")
    ids = popular_species(sample_size)
    print(f"  got {len(ids)} species ids")

    print("fetching each with its ancestors ...")
    taxa = taxa_with_ancestors(ids)
    print(f"  got {len(taxa)} taxa")

    plugin = LuaPlugin()
    core = plugin.require("PanelCore")

    titles = []
    for taxon in taxa:
        ancestors = ancestor_chain(taxon)
        top = {
            "id": taxon.get("id"),
            "name": taxon.get("name"),
            "rank": taxon.get("rank"),
            "preferred_common_name": taxon.get("preferred_common_name"),
            "ancestors": ancestors,
        }

        # The candidate rows the model would have scored. Only the top one is
        # needed to drive the coarser rows; the rest are measured as themselves.
        rows = [{
            "taxon_id": taxon.get("id"),
            "name": taxon.get("name"),
            "common_name": taxon.get("preferred_common_name"),
            "rank": "species",
            "combined_score": 87.4,
        }]

        # The coarsest thing every candidate agreed on. Put it high, so the
        # finer rungs take the longer "containing <name>" note rather than the
        # shorter agreed one -- this is a measurement of the top end.
        order = next((a for a in ancestors if a["rank"] == "order"), None)
        common_ancestor = deep(plugin, order) if order else None

        coarser = core["coarserRows"](deep(plugin, top), common_ancestor,
                                      deep(plugin, rows))

        combined = []
        i = 1
        while coarser[i] is not None:
            combined.append(coarser[i])
            i += 1
        combined.extend(deep(plugin, r) for r in rows)

        slots = core["suggestionSlots"](
            plugin.runtime.table_from({i + 1: v for i, v in enumerate(combined)}),
            1)

        for i in range(1, int(core["SUGGESTION_LIMIT"]) + 1):
            title = slots[i]["title"]
            if title:
                titles.append(from_lua_text(title))

    titles.sort(key=len)
    lengths = [len(t) for t in titles]

    print()
    print(f"formatted titles measured: {len(lengths)}")
    print(f"  max    {max(lengths)}")
    print(f"  p99    {lengths[int(len(lengths) * 0.99) - 1]}")
    print(f"  p90    {lengths[int(len(lengths) * 0.90) - 1]}")
    print(f"  median {statistics.median(lengths)}")
    print()
    print("the ten longest:")
    for t in titles[-10:]:
        print(f"  {len(t):3d}  {t}")

    report_widths(titles)


# Characters to pixels is the one number here that is NOT measured. A probe
# ladder showed 330pt drawing about 67 characters of a name before its ellipsis
# and 440pt drawing all 82 of its sample, which implies about 4.9pt a character
# -- but one string at two widths cannot pin down a proportional font. So three
# readings are carried through rather than one, and a width whose verdict
# changes between them is a width that rests on the guess.
PER_CHAR = (4.5, 4.93, 5.4)

WIDTHS = (330, 400, 440, 480, 500, 560, 680)


def report_widths(titles):
    scored = [t for t in titles if re.search(r"- \d+%$", t)]
    coarse = [t for t in titles if not re.search(r"- \d+%$", t)]

    def fits(sample, width, per_char):
        return 100 * sum(1 for t in sample if len(t) * per_char <= width) / len(sample)

    print()
    print("share of titles that fit, at three pixels-per-character readings")
    print(f"{'width':>6}  " + "  ".join(f"{p:>10}pt/ch" for p in PER_CHAR))
    for width in WIDTHS:
        cells = "  ".join(f"{fits(titles, width, p):11.1f}%" for p in PER_CHAR)
        print(f"{width:>6}  {cells}")

    print()
    print("by row kind -- the candidates were never the problem")
    for label, sample in (("scored species", scored), ("coarser ranks", coarse)):
        lengths = sorted(len(t) for t in sample)
        central = ", ".join(
            f"{w}: {fits(sample, w, 4.93):.0f}%" for w in (330, 480, 560))
        print(f"  {label:<15} n={len(sample):<5} median {lengths[len(lengths) // 2]:>3}"
              f"  max {lengths[-1]:>3}   fit {central}")


if __name__ == "__main__":
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    main(int(sys.argv[1]) if len(sys.argv) > 1 else 400)
