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

Its menu items appear under **File › Plug-in Extras**. Each writes its results to
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

Seven row shapes, a width ladder, and two full-length lists, spread across
**four short windows shown one after another** — each built the way the panel
builds its own: floating rather than modal, titles bound and filled only once
the window is up, and the string shapes `describeSuggestion` produces.

| Window | Blocks | Question |
|---|---|---|
| 1 — widths | A `width=330, truncation="tail"` (the panel today), then the same long name at 440, 560, 680 | how wide does it have to be? |
| 2 — shapes | B `height_in_lines=2` no truncation · C the same plus `truncation="tail"` · D no `width` · G `selectable=true` · F inside an undersized `scrolled_view` | can a name show its whole self where it is? |
| 3 — ten plain rows | H, all ten as the panel draws them | do all ten fit? |
| 4 — ten wrapped rows | I, all ten at `height_in_lines=2` | does wrapping make the list too tall? |

Four windows rather than one because the first version came out taller than the
screen: the last block sat below the bottom edge, the title bar was out of
reach, and the questionnaire behind it could not be got to at all. A probe
nobody can finish measures nothing. So each window stays short, the button that
advances sits at the **top** and closes the window through
`closeFloatingDialogsForPlugin` rather than trusting a title bar that may not be
reachable, and the questionnaire lives inside a `scrolled_view` so it cannot
outgrow the screen either.

**Whether a floating window can be moved or resized at all is one of the
measurements**, and it is made by comparison rather than by opinion.
`presentFloatingDialog`'s key list in `ui.dll` reads `onShow save_frame
blockTask background_color closable maximizable minimizable borderless skin
margin position …` — `resizable` is *not* in it, though `AgViewWin32Window` one
chunk away does read `resizable`, with `horizontally` and `vertically` beside
it. So window 1 asks for every frame key including `resizable = true`, window 2
asks for none (exactly as the real panel does), and window 4 asks for
`resizable = "horizontally"`. Whatever the answers are, the difference between
them is the finding — and if none of the three can be resized, then the panel
can never be widened either, and "let the name column grow with the window" is
dead rather than merely unproven.

G is not only about readability: `selectable` may swallow the click that picks a
suggestion, so every block's name carries the same `mouse_down` and the report
prints clicks per block. If `selectable` eats the click, G's count stays at zero
while the others rise — a number, not an impression.

Two further questions ask about the **real panel**, which is the only window
carrying the saved frame the user lives with, so have it open with suggestions
loaded before starting. If ten rows do not fit there, "add a scroll bar" was
literally right and wrapping is the wrong first fix, because it makes the list
taller still.

Nothing in the SDK reports layout back — there is no way to ask a view how wide
it ended up or how many lines it drew — so the questionnaire at the end is the
instrument, the same way the scrolled-view probe measures "press Escape when it
is usable" against the user.

**What it answered.** A floating dialog honours `resizable = true` and ignores
`resizable = "horizontally"`; one given no frame keys cannot be dragged at all;
`maximizable` produced no Maximize. Resizing gained nothing, because the extra
width went to the margin and every control kept its declared width — a column
cannot grow with its window. `height_in_lines` did not wrap a bound title, at
either truncation setting or across ten rows. `selectable = true` made the text
genuinely copyable and the click counter for that block stayed at zero while
its neighbours rose. Ten rows fitted; the complaint was never vertical.

One block misled us and is worth the warning: F scrolled horizontally with its
contents still clickable, but scrolling right did **not** reveal the rest of the
name, because the row inside it was the panel's own `width = 330,
truncation = "tail"` row and had already truncated itself before the scroller
saw it. Whether a width-less row inside a scroller sizes to its text is still
unknown — block D says a width-less row collapses outside one.


## iNat Probe: Export Presets

Whether the plugin can offer the user's own export presets instead of its
hardcoded render settings — and whether a preset's **named watermark** survives
into `LrExportSession`, which is the one claim the binaries cannot settle.

Dumping the binaries answered everything else: `Export.lrmodule` names the
folder (`templateType = "Export", templateDirectoryName = "Export Presets"`),
`ui.dll` resolves it against `getStandardFilePath ... appData` and moves it
beside the catalog when `AgTemplateBrowser_storePresetsWithCatalog` is on, and
`LibraryToolkit.dll` loads an `.lrtemplate` with `loadstring` / `setfenv` /
`ZSTR` / `pcall`. What is left is behaviour:

| Step | Question |
|---|---|
| 0 | Can a plugin read an `.lrtemplate` at all? Everything else depends on it, so it is asked first — and asked of every strategy, not just the first one that works |
| 1 | What `getStandardFilePath("appData")` returns, which of the two preset roots exist, and every file in them |
| 2 | What each export preset parses to — `type`, `id`, title, `exportServiceProvider` — with failures verbatim |
| 3 | The named watermark presets, and their GUID ids |
| 4 | Renders of one selected photo, by byte size and duration |

Run 1 measured **`setfenv` is nil inside a plugin sandbox**, which is how
`LibraryToolkit.dll` loads these files and which killed every parse in steps 2
and 3. So the probe now carries three readers and reports each one separately:

| Strategy | How |
|---|---|
| `loadstring` + `setfenv` | What the host does. Known to fail; kept so the next run says so in its own words |
| `loadstring` + globals | An `.lrtemplate` assigns to a global `s`, so no environment is needed — define `ZSTR` as a global, run the chunk, read `s`, and put both globals back |
| patterns, no execution | A real little table-literal reader that runs no code. Handles nesting, because a watermark's `items` is a list of tables and a line-by-line match reads the inner keys as outer ones |

Step 4 is still the point. Cases **(a)** no watermark, **(b)**
`<simpleCopyrightWatermark>`, **(c)** a named watermark's GUID and **(d)** a
GUID matching no preset hold the photo, the pixel dimensions and the JPEG
quality constant, so a difference in bytes can only be the watermark. Case
**(e)** is a whole user preset with the plugin's overrides applied; it changes
everything at once by design and is reported separately, never compared.

Run 1 returned **557475 bytes for (a), (b) and (d) alike** — so an unresolvable
id silently skips rather than raising, and the built-in copyright watermark drew
nothing. That has two very different explanations, and the plugin currently
ships a checkbox for it, so case **(b2)** settles which: the probe reports the
photo's copyright, and if it has none it writes one, renders again, and
restores the original value. The write is disclosed in the output.

The probe prints a conclusion rather than a column of numbers: whether (b) drew
and whether (b2) explains it, whether (c) differs from (a) — the named watermark
drew at all — whether it differs from (b) — it was *that* watermark and not the
built-in one — and what (d) did with an unresolvable id.

**Select one photo in the Library grid before running it.** Steps 0–3 work
without a selection and say so; step 4 cannot. Case (e) is only worth much if
you have saved at least one export preset of your own, since Lightroom's four
shipped ones are not what the feature is for — two of them are not even file
exports.

## What they answered

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
