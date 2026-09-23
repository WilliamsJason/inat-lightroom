# SDK probes

Throwaway plugins that answer questions about the Lightroom SDK which cannot be
answered anywhere else.

Most SDK questions in this repo are settled by dumping the shipped binaries —
see [../../docs/lightroom-sdk-notes.md](../../docs/lightroom-sdk-notes.md). That
works for "does this API exist" and "what values does it accept", because both
are strings in `LibraryToolkit.dll` or `ui.dll`. It cannot answer "how slow is
it", which needs a real catalog and a real window.

`sdkprobe.lrplugin` is a separate plugin, not a menu item added to
`pinned.lrplugin`. It has its own `LrToolkitIdentifier`, so both can be installed
at once, and nothing it does can ship by accident.

## Installing

Plug-in Manager → Add → point it at `explore/probes/sdkprobe.lrplugin`.

Its items appear under **File › Plug-in Extras**. Each writes its results to
`inat-sdk-probe.txt` on the Desktop, appending, so several runs can be compared.

## iNat Probe: Catalog APIs

Reverse Sync has to build an index of the catalog before it can match anything.
This probe measures whether that is affordable, and answers:

- Are `findPhotos`, `batchGetRawMetadata` and `batchGetPropertyForPlugin`
  reachable from a plugin? (All three are in `LibraryToolkit.dll`'s
  `SdkLrCatalogQueries` set, which is the plugin-facing one.)
- Which `searchDesc` shape does `findPhotos` accept for a capture-time range —
  the flat criteria table, or the smart-collection array with a `combine` key?
  Four shapes are tried and each is reported separately.
- How much faster is one `batchGetRawMetadata` than a `getRawMetadata` loop over
  the same 500 photos? This is the entire performance case for indexing the
  catalog in one pass, so it deserves a number rather than a belief.

`findPhotos` asserts it was called from within an `LrTask` — the assertion
string is in the binary — which is why everything runs inside one.

## iNat Probe: Scrolled View

How many rows a review list can hold before the dialog stops being worth
opening.

`ui.dll`'s `osFactory` exports exactly one list control a plugin can use,
`simple_list`, and its items are strings rather than rows of checkboxes — but it
is a native `table_view` inside a `scroll_view` underneath (see
[../../docs/lightroom-sdk-notes.md](../../docs/lightroom-sdk-notes.md)), so it
may well draw only the rows on screen. A `scrolled_view` full of hand-built rows
certainly does not: those are built eagerly, with no virtualisation.

The probe measures both, because the answer decides the design. Hand-built rows
at 50, 100, 250, 500 and 1000 — the real row shape, with a bound checkbox, three
text columns and optionally a `catalog_photo` thumbnail — and a `simple_list` at
500 and 5000, where the multiple selection *is* the answer (everything selected
gets linked, and "selected by default" means pre-filling the value with every
index). It also reports what the selection looks like coming back, since that
value is a table even for a single row and getting it wrong fails silently.

Three costs, separated because they have different fixes:

| Cost | What it is | How it is measured |
|---|---|---|
| `props` | filling a property table with one key per row | timed directly |
| `build` | Lua time constructing the view tree | timed directly |
| `open+dismiss` | the wait before the window is usable | against the user — press Escape the instant it is |

Nothing in the SDK reports the last one, so it includes human reaction time
(~0.3 s). It is there to separate "instant" from "unusable", not to be precise.

Run it once with thumbnails and once without: the difference is the cost of
`catalog_photo`, which is the part most likely to make a long list unusable.

## iNat Probe: Suggestion Rows

Why the Observation panel loses the end of a suggestion name, and which fix the
host will accept.

The panel builds ten rows of `f:static_text` with **empty** titles pointed at
bindings, because the window outlives any one photo selection and a presented
view tree cannot grow rows. Sized before it has text, filled afterwards — that
combination is where the surprises are. `ui.dll` says the keys exist
(`AgViewWinStaticText` reads `selectable`, `height_in_lines` and
`resize_to_fit_text_height`; `scroll_view` reads `vertical_scroller` and
`horizontal_scroller`), but "the binary accepts this key" has never been the
same as "this displays".

Seven variants of the same four rows, plus two full-length ones, in a floating
window built the way the panel builds its own:

| | Row shape | Question |
|---|---|---|
| A | `width=330, truncation="tail"` | control — the panel as it ships |
| B | `width=330, height_in_lines=2`, no truncation | does a *bound* title wrap? |
| C | as B plus `truncation="tail"` | does truncation defeat wrapping? |
| D | no `width`, `fill_horizontal` only | the known zero-width collapse |
| E | `width=330, height_in_lines=2` | is `width` a floor the window can stretch, or fixed? |
| F | the rows inside a deliberately undersized `scrolled_view` | which scrollers does the host draw? |
| G | `selectable=true` | can the text be selected — and does `mouse_down` still fire? |
| H | A, ten rows deep | do all ten rows fit, or is the complaint vertical after all? |
| I | B, ten rows deep | does wrapping make the list too tall to fit? |

G is not only about readability: `selectable` may swallow the click that picks a
suggestion, so the probe counts clicks per variant and reports them.

H and I are the question the user's own words asked for. Four rows fit anything,
so nothing else here can say whether ten do — and if they do not, "add a scroll
bar" was literally right and wrapping is the wrong first fix, because it makes
the list taller still. Two more questions ask the same thing of the real panel,
which is the only window with the saved frame the user lives with, so have it
open with suggestions loaded before running the probe.

Drag the window much wider before closing it — that is the measurement E and A
exist for. Closing it opens a questionnaire, one question per variant, and the
answers go into the Desktop log with the rest. Nothing in the SDK reports layout
back: there is no way to ask a view how wide it ended up or how many lines it
drew, so the person watching is the instrument.



Measured against a 6,591 photo catalog on Lightroom Classic, Windows. The
findings are written up properly in
[../../docs/lightroom-sdk-notes.md](../../docs/lightroom-sdk-notes.md); this is
the short version, and the reason the probes can be left alone now.

| Question | Answer |
|---|---|
| Narrow `captureTime` window query | **1.7 ms** average — ~17 s per 10,000 lookups |
| Does `captureTime` honour seconds? | Yes: ±2 s returned 2 where the whole day returned 5 |
| Value format | `%Y-%m-%dT%H:%M:%S`. `timeToW3CDate` matches **nothing**, silently |
| `batchGetRawMetadata` vs loop | 107 ms for 8 keys vs 377 ms for 2 — ~10× per key |
| Bad metadata key | Fails the *entire* call (`Unknown key: "fileName"`) |
| `batchGetPropertyForPlugin` | `(photos, pluginId, { keys })` — 36 ms for 500 photos |
| Review list | `simple_list` at 5000 beats hand-built rows at 1000, twice over |

Two of those cost a hang rather than an error to discover: `operation = ">="`
and passing `_PLUGIN` where a plugin id belongs. Neither raises. If a probe
stops producing output, read the last line of the log — it names the call that
did not come back — and suspect the arguments rather than the catalog size.

The consequence for Reverse Sync: **never walk the catalog.** A window query
per observation costs the number of observations, which is five digits at
worst, while indexing costs the number of photos, which is not bounded at all.
