# Lightroom Plugin – Architecture

## Overview

The plugin is an **Adobe Lightroom Classic** plugin written in Lua using the [Lightroom SDK](https://www.adobe.io/apis/creativecloud/lightroomsdk.html). It consists of two main capabilities:

1. **Publish** – a Publish Service that turns photos into iNaturalist observations and keeps them in step with them.
2. **Sync** – pull the latest community identification from iNaturalist and write the full taxonomic tree into Lightroom keywords.

---

## Plugin files

```
inat.lrplugin/
├── Info.lua                   # Plugin identity, SDK version, menu, tagsets, URL handler
├── ObservationPanelMenu.lua   # Menu script: opens the floating panel
├── ObservationPanel.lua       # The floating panel itself
├── WindowFix.lua              # Fixes the panel's z-order (Windows only)
├── fix_window_z_order.ps1     # The Win32 helper WindowFix shells out to
├── CredentialsMenu.lua        # Menu script: opens the credentials dialog
├── CredentialsDialog.lua      # The credentials dialog itself
├── LinkObservation.lua        # Adopting an observation that already exists
├── SyncCore.lua               # Sync logic, callable from any entry point
├── ExportServiceProvider.lua  # Publish service (upload to iNaturalist)
├── PluginUrls.lua             # Builds and parses lightroom:// plugin URLs
├── URLHandler.lua             # Receives those URLs and dispatches
├── TagsetInat.lua             # Metadata panel preset: the plugin's fields
├── InatAPI.lua                # HTTP helpers wrapping iNaturalist REST API (LrHttp)
└── CustomMetadata.lua         # Custom metadata schema definition
```

Menu scripts are deliberately thin. Lightroom executes a menu-item file top to
bottom when the item is clicked, so a file registered as a menu item cannot be
required from anywhere else without performing its action as a side effect. Each
one is a single line that calls into a real module.

`Library > Plug-in Extras` holds two items, and both of them only *open*
something: **iNaturalist Panel** and **Set Up Credentials…**. That is the test
for whether something belongs in the menu — features live where the user is
already looking, and a menu is somewhere you have to go.

---

## Where the plugin lives in the UI

Lightroom Classic gives a plugin **no docked surface that can hold a control**.
This was checked against the shipped binaries rather than assumed — the full
survey is in [lightroom-sdk-notes.md](lightroom-sdk-notes.md), and the short
version is:

| Surface | Docked? | Can hold buttons? |
| --- | --- | --- |
| Metadata panel fields | yes | no — `string`/`enum`/`url` text only |
| Publish service entry | yes | no — fixed row |
| Comments panel | yes | no — fixed |
| Floating window | **no** | **yes** |
| Modal / export dialogs | no | yes |

Nothing is both. Third-party products that appear to have a real panel are
companion applications drawing their own window over the panel column.

So the plugin spreads across three surfaces, each doing the part it can.

### The Publish Services panel — publishing

`ExportServiceProvider.lua` sets `supportsIncrementalPublish = "only"`, which
turns the export target into a publish service. There is no `LrPublishService`
manifest key; Adobe's own `Flickr.lrplugin` registers under
`LrExportServiceProvider` and becomes a publish service the same way.

That buys a left-panel entry, a real **Publish** button, Lightroom's own
New/Modified/Published bookkeeping, and a settings dialog whose buttons can run
code — which is where **Sync selected photos now** lives.

Because the settings belong to the *connection* rather than to a batch,
everything specific to one observation comes off the photo: species guess, date
(`dateTimeOriginal`), GPS, description. The connection keeps only genuine
preferences — default taxon, geoprivacy, project, and the two toggles.

### The Metadata panel — data only

A preset named `iNaturalist` in the Metadata panel dropdown shows this plugin's
fields and the file name, and nothing else.

A preset *replaces* the panel's contents rather than adding to it, so selecting
`iNaturalist` costs the user their ordinary metadata view. An earlier version
shipped a second `iNaturalist + Default` preset to avoid that. It was dropped:
Default is one dropdown away, and a copy of Default is a second thing to keep
in step with Lightroom for no real gain.

The panel holds **no actions**, and cannot: `LibraryToolkit.dll` validates a
custom field's `dataType` down to `string`, `enum` or `url` and rejects anything
else. It briefly held fake ones — a `url` field renders as a clickable row, and
two such fields held `lightroom://com.github.inat-lightroom/...` links that
reached `URLHandler.lua`. That worked, but the row is not really a button.
Lightroom derives its label from the field declaration and hardcodes "Go to
URL"; the plugin cannot rename it, cannot supply an action, and the arrow fires
even when the field is empty (on Windows that opens Explorer). Custom fields
also have no default, so the rows only existed on photos the plugin had already
touched — the one photo that most needed *Link to Observation…* was the one
photo that could not offer it.

`PluginUrls.lua` and `URLHandler.lua` stay, because OAuth needs the same
mechanism to receive its `lightroom://com.github.inat-lightroom/authorization-redirect`
callback.

### The floating panel — data and actions together

`ObservationPanel.lua` is the answer to wanting one place that has the photo's
iNaturalist state *and* the buttons that act on it. It is the only surface that
can hold both, at the cost of floating rather than docking.

`LrDialogs.presentFloatingDialog(_PLUGIN, {...})` opens a non-modal window that
stays up while the user works. Two arguments make it behave like a panel instead
of a dialog:

- `selectionChangeObserver` fires when the filmstrip selection changes, and
  `sourceChangeObserver` when the folder or collection does. The panel refreshes
  its bound property table in place, so it always describes what is selected.
  Rebuilding the window instead would also work, but reopening a floating window
  steals focus on Windows, and doing that on every arrow-key press would make
  the plugin unusable.
- `save_frame` (with `id`) persists position and size across sessions.

`blockTask = true` is load-bearing rather than cosmetic: the window's bindings
belong to a property table owned by the calling task's function context, and
without it that task ends immediately, the context dies, and every binding is
pointing at a dead object.

**The observers do not run in a task, and the refresh has to.** Reading plugin
metadata yields, so doing it straight from the observer raises *"We can only
wait from within a task"* — or, when the observer is reached through a
metamethod, *"Yielding is not allowed within a C or metamethod call"*. Lightroom
swallows both. The symptom is not an error but a panel that quietly ignores the
filmstrip while the observers fire perfectly, which is exactly how this
presented. `refresh` therefore hands its catalog reads to
`LrTasks.startAsyncTask`.

That makes refreshes concurrent, so each one carries a generation number and
only the newest may write. Two things need it: arrow-keying down the filmstrip
fires the observer faster than the reads finish, and a folder change reports the
whole folder selected before settling on one photo — the host log showed
`1 → 104 → 104 → 1` target photos for a single click. Without the guard a
refresh that started earlier and finished later can leave the panel on the wrong
photo, and there is nothing to correct it until the next click.

The panel shows the selection, what the observation currently is, its quality
grade and last sync, an editable **Species guess**, and buttons for **Sync**,
**Link to Observation…** and **View on iNaturalist**. Everything below the
heading describes the *first* selected photo and the heading says so — but
saving a species guess deliberately applies to the whole selection, because one
name across the six frames of the same animal is the common case.

One rough edge Lightroom leaves us: the window is created `WS_EX_TOPMOST` with
no owner, so out of the box it floats above every application and does not
minimise with Lightroom. Nothing in the SDK controls that — passing
`_topmost = false` was tested in the host and ignored — so `WindowFix.lua`
shells out to `fix_window_z_order.ps1`, which gives the window Lightroom's main
window as its owner and clears topmost. The result is an ordinary owned window:
above Lightroom, above nothing else, minimising with it. That shell-out is the
only place the plugin leaves Lua, it is Windows-only, and on macOS it is a
no-op because the behaviour there has never been measured. See
`docs/lightroom-sdk-notes.md` for the before-and-after window flags.

`LinkObservation.lua` exists because two entry points need it — the panel's
button and the `lightroom://` URL. It used to be a local function inside
`URLHandler.lua`, which meant the panel could only reach it by pretending to be
a URL.

---

## Custom metadata schema (`CustomMetadata.lua`)

| Field ID | Type | Access | Description |
|---|---|---|---|
| `inat_observation_id` | `string` | editable | iNaturalist observation ID |
| `inat_observation_uuid` | `string` | read-only | Observation UUID; the grouping key at publish time |
| `inat_observation_url` | `url` | read-only | Direct URL to the observation |
| `inat_taxon_id` | `string` | read-only | Taxon ID of the community determination |
| `inat_taxon_name` | `string` | read-only | Scientific name of the taxon |
| `inat_common_name` | `string` | read-only | Vernacular/common name |
| `inat_quality_grade` | `string` | read-only | `casual`, `needs_id`, or `research` |
| `inat_last_synced` | `string` | read-only | ISO 8601 timestamp of last sync |
| `inat_species_guess` | `string` | editable | What to upload this photo as |
| `inat_crop` | `string` | editable | iNat-specific crop, `x,y,w,h` |

Everything mirroring iNaturalist state is read-only: an edit would be silently
overwritten by the next sync, which is worse than not being editable. The
observation ID stays editable on purpose — pasting one is how a photo adopts an
observation that already exists.

`inat_species_guess` is deliberately separate from `inat_taxon_name`. One says
what to upload, the other says what the community decided; merging them would
let a sync quietly change what the next publish sends.

`inat_observation_url` is the only `url` field the preset shows, because it is
the only one that is either filled in or hidden.

These fields appear in Lightroom's **Metadata** panel under the iNaturalist
preset.

---

## Publish workflow

One photo is one observation, unless photos share an `inat_observation_uuid`,
in which case they publish into the same one.

```
User drags photos into the iNaturalist publish collection, clicks Publish
        │
        ▼
Lightroom renders each JPEG at 2048 px long edge (sRGB, q90)
        │
        ▼
For each rendition:
  photo has inat_observation_uuid?
        │              │
        │ no           │ yes
        ▼              ▼
  POST /observations   GET /observations?uuid=…
  store .uuid and      found: PUT /observations/{id} with the photo's current
  .id onto the photo   details (ignore_photos, or every photo is detached)
                       gone:  POST /observations reusing the same uuid
        │
        ▼
  POST /observation_photos           → recordPublishedPhotoId
        │
        ▼
  republish? DELETE the previous observation_photo — only after the new
  upload has succeeded, so a failure can never leave an observation with
  zero photos (that drops it to casual grade permanently)
        │
        ▼
(optional) POST /project_observations
        │
        ▼
(optional) sync taxa back for the photos just published
```

The connection's default taxon is a fallback, not an override: it is sent only
when the photo has no species guess of its own, and never on an update. By
republish time the observation may carry other people's identifications, and
iNaturalist prefers `taxon_id` over `species_guess` — so sending it regardless
would first discard what the user typed, then argue with the community.

Removing a photo from the published collection detaches its
`observation_photo`; when the last photo of an observation goes, the
observation goes with it.

### iNat-specific crop — stored, not yet applied

`inat_crop` holds `x,y,w,h` as fractions of the original. Nothing reads it yet;
applying it at upload is Phase 2.

The obvious design — drag a rectangle over a preview — is **not possible in
pure Lua**. `LrView` has no canvas, no drawing primitives and no mouse
coordinates, which was checked against the shipped binaries rather than
assumed. See [lightroom-sdk-notes.md](lightroom-sdk-notes.md). What is
available is sliders bound to the four numbers with a preview that redraws as
they move, in a floating dialog.

At upload time `processRenderedPhotos` would read the stored crop and produce a
cropped JPEG rather than sending the rendition as-is.

> **Alternative (simpler):** use a Lightroom virtual copy with a different crop
> and publish that. The plugin could create the virtual copy automatically, and
> Lightroom does the cropping.

---

## Sync workflow

Started from the publish service's settings dialog (the selected photos), from
a `lightroom://` URL, or automatically after a publish (the photos that were
just published — not the selection, which by then is usually something else).

```
SyncCore.lua reads inat_observation_id from each photo
        │
        ▼
GET /observations/{id}  →  observation + community_taxon + ancestors
        │
        ├── taxon present ──▶ build keyword hierarchy:
        │                       Animalia > Arthropoda > … > Quercus robur
        │                     LrCatalog:withWriteAccessDo → addKeyword
        │                     write inat_taxon_id / _taxon_name / _common_name
        │
        └── no taxon yet ───▶ nothing to file under; no keywords
        │
        ▼
Either way, write:
  inat_quality_grade, inat_observation_url,
  inat_observation_uuid, inat_last_synced
```

**"No taxon yet" is not an error.** Nobody has identified an observation the
moment it is created, so with sync-on-publish enabled it is the outcome of
almost every first publish. It is counted separately (`Not identified yet`) and
reported as information.

The write happens either way for a reason: the UUID is what stops the next
publish creating a duplicate observation, and a photo linked by pasting the ID
of something unidentified is exactly the case that needs it. An early return
would drop it precisely when it mattered.

---

## Authentication

The plugin stores the iNaturalist token in **Lightroom's encrypted password
store** (`LrPasswords`), which is backed by the OS credential vault. Today that
token is pasted by hand from
<https://www.inaturalist.org/users/api_token> and expires after 24 hours.

The replacement is OAuth with PKCE, which was checked against iNaturalist's
live endpoints: they run Doorkeeper 5.6.6 with S256 PKCE enabled, and an
application registered with **Confidential unchecked** is a public client — so
there is **no client secret to ship**, which is the thing that usually makes
OAuth impossible for a distributed plugin.

The redirect comes back through the same `lightroom://` mechanism the plugin
already uses:
`lightroom://com.github.inat-lightroom/authorization-redirect?code=…`, handled
by `URLHandler.lua`. No `LrSocket` listener and no local port.

That needs an approved iNaturalist application, and since 2022 those are
reviewed by hand: the account must be two months old with ten or more improving
identifications for other people in the past month. Registration is in
progress; revisit around October 2026.

---

## LrHttp notes

The Lightroom SDK provides `LrHttp` for HTTP requests. Key points:

- `LrHttp.get(url, headers)` – simple GET, returns body string
- `LrHttp.post(url, body, headers, method, contentType)` – POST/PUT
- Multipart form data (for photo upload) requires manually building the MIME boundary string.
- SSL is supported but certificate errors will surface as empty responses; ensure the iNaturalist API certificate chain is valid on the user's machine.

A thin `InatAPI.lua` module wraps these calls and handles JSON encode/decode (via a bundled `json.lua`).

---

## Keyword hierarchy approach

Lightroom keywords are hierarchical. The sync step creates/reuses:

```
iNaturalist
└── <kingdom>
    └── <phylum>
        └── <class>
            └── <order>
                └── <family>
                    └── <genus>
                        └── <species binomial>
                            └── <common name>   (synonyms/alias keyword)
```

Using `LrCatalog:createKeyword(name, synonyms, includeOnExport, parent, skipIfAlreadyExists)`.

---

## Export size

iNaturalist displays at most **2048 px** on the long edge and rejects uploads
over roughly 20 MB. The publish service therefore locks JPEG / 2048 px long
edge / sRGB / quality 90 in `updateExportSettings` rather than offering it as a
default: a full-resolution raw conversion would fail the upload for an image
nobody would ever see at that size.

---

## What comes next

**Phase 2 — the floating panel.** Started: `ObservationPanel.lua` follows the
selection and carries the actions. Still to come, in it:

- A **crop preview** and sliders bound to `inat_crop`. `f:catalog_photo` shows a
  live catalog photo but applies Lightroom's own crop and cannot show a custom
  region; overlays go on with `f:view { place = "overlapping" }` and `f:picture`.
  Draggable handles are impossible — `LrView` has no canvas and no mouse
  coordinates. It is not yet known whether `catalog_photo`'s `photo` property can
  be re-bound to follow the selection, or whether the window has to be rebuilt.
- A **Publish** button.
- **Group into observation**, for the several-frames-of-one-animal case. This is
  the one thing that needs a client-side UUID generator, since it has to invent
  an ID before any observation exists.

**Phase 3 — OAuth**, once the iNaturalist application is approved.

**Phase 4 — the Comments panel.** A publish service can fill in Lightroom's own
Comments panel through `getCommentsFromPublishedCollection`,
`canAddCommentsToService` and `addCommentToPublishedPhoto`. iNaturalist
identifications and comments map onto it directly, and
`getRatingsFromPublishedCollection` + `titleForPhotoRating` could carry the
faves count. This is the panel the whole design started out trying to sit next
to; a publish service does not get a panel beside it, it fills it in.

Smaller ideas:

- **Capture time in `observed_on_string`** — the plugin has it and sends only
  the date. Better data for iNaturalist.
- **Smart collections** driven by the taxonomic keyword hierarchy.
- **Identification alerts** when somebody adds an ID to an observation.
- **`presentWebViewDialog`** is the only unexplored surface left, and the only
  one that could give real mouse events — and therefore a draggable crop
  rectangle. Its `AgWebView` has `runScript` and strings implying JavaScript can
  call back into Lua. On Windows it is the legacy MSHTML control and no known
  plugin uses it, so this is a research spike, not a plan.
