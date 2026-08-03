# Lightroom Plugin – Architecture

## Overview

The plugin is an **Adobe Lightroom Classic** plugin written in Lua using the [Lightroom SDK](https://www.adobe.io/apis/creativecloud/lightroomsdk.html). It consists of two main capabilities:

1. **Publish / Upload** – export selected photos directly to iNaturalist as observations.
2. **Sync** – pull the latest community identification from iNaturalist and write the full taxonomic tree into Lightroom keywords.

---

## Plugin files

```
inat.lrplugin/
├── Info.lua                   # Plugin identity, SDK version, menu, tagsets, URL handler
├── CredentialsMenu.lua        # Menu script: opens the credentials dialog
├── CredentialsDialog.lua      # The credentials dialog itself
├── SyncCore.lua               # Sync logic, callable from any entry point
├── ExportServiceProvider.lua  # Publish service (upload to iNaturalist)
├── PluginUrls.lua             # Builds and parses lightroom:// plugin URLs
├── URLHandler.lua             # Receives those URLs and dispatches
├── TagsetInat.lua             # Metadata panel preset: the plugin's fields
├── InatAPI.lua                # HTTP helpers wrapping iNaturalist REST API (LrHttp)
└── CustomMetadata.lua         # Custom metadata schema definition
```

There is one menu script and it is deliberately thin. Lightroom executes a
menu-item file top to bottom when the item is clicked, so a file registered as a
menu item cannot be required from anywhere else without performing its action as
a side effect. `CredentialsMenu.lua` only opens `CredentialsDialog.lua`.

`Library > Plug-in Extras` holds a single item, **Set Up Credentials…**.
Everything else lives in the publish service. Credentials stayed in the menu
because you need them before a publish service is any use, and because they are
the one thing you want to reach without first creating a connection.

---

## Where the plugin lives in the UI

Lightroom Classic has **no SDK hook for adding a panel to the Library right
panel stack**. This was checked against the shipped binaries, not assumed — see
[lightroom-sdk-notes.md](lightroom-sdk-notes.md). Third-party products that
appear to have one are companion applications drawing their own window over the
panel column.

So the plugin occupies two native surfaces instead.

### The Publish Services panel — where the actions are

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

The panel holds **no actions**. It briefly did: a field of `dataType = "url"`
renders as a clickable row, and two such fields held
`lightroom://com.github.inat-lightroom/...` links that reached `URLHandler.lua`.
That worked, but the row is not really a button. Lightroom derives its label
from the field declaration and hardcodes "Go to URL"; the plugin cannot rename
it, cannot supply an action, and the arrow fires even when the field is empty
(on Windows that opens Explorer). Custom fields also have no default, so the
rows only existed on photos the plugin had already touched — the one photo that
most needed *Link to Observation…* was the one photo that could not offer it.

`PluginUrls.lua` and `URLHandler.lua` stay, because OAuth needs the same
mechanism to receive its `lightroom://com.github.inat-lightroom/authorization-redirect`
callback.

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
  POST /observations   GET /observations?uuid=…  (reuse, or recreate if gone)
  store .uuid and .id back onto the photo
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
(optional) sync taxa back for everything just published
```

Removing a photo from the published collection detaches its
`observation_photo`; when the last photo of an observation goes, the
observation goes with it.

### iNat-specific crop

Lightroom does not expose per-export crop to Lua directly. The approach:

1. In the export dialog, show a **"Set iNat Crop…"** button.
2. This opens a floating window (using `LrDialogs`) that lets the user drag a crop rectangle over a preview.
3. The crop rectangle (as `x, y, w, h` fractions of the original) is stored in `CustomMetadata`.
4. At export time, `ExportServiceProvider.processRenderedPhotos` reads the stored crop, uses `LrPhoto:requestJpegThumbnail` or a secondary export task to produce a cropped JPEG, and uploads that instead of the main export.

> **Alternative (simpler):** Use a Lightroom virtual copy with a different crop and export the virtual copy. The plugin can create the virtual copy automatically.

---

## Sync workflow

```
User selects photos with inat_observation_id set
        │
        ▼
SyncCore.lua reads inat_observation_id from each photo
        │
        ▼
GET /observations/{id}  →  returns observation + community_taxon + ancestors
        │
        ▼
Build keyword hierarchy:
  Animalia > Arthropoda > Insecta > Lepidoptera > … > Quercus robur
        │
        ▼
LrCatalog:withWriteAccessDo → LrPhoto:addKeyword for each ancestor
        │
        ▼
Update CustomMetadata fields:
  inat_taxon_id, inat_taxon_name, inat_common_name,
  inat_quality_grade, inat_last_synced
```

---

## Authentication

The plugin stores the iNaturalist `access_token` in **Lightroom's encrypted password store** (`LrPasswords`). On first run (or when the token is missing), the plugin opens a dialog asking the user for their OAuth credentials.

For the interactive OAuth flow (required for public App Store distribution), Lightroom can open the system browser via `LrHttp.openUrlInBrowser` and listen for the redirect on a local port using `LrSocket`. For personal/development use, the resource-owner password grant is simpler.

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

## Export size recommendation

iNaturalist resizes uploaded images to a maximum of **2048 px** on the long edge for display but retains the original. For plugin uploads, exporting at 2048 px is a good default because:

- It matches iNaturalist's display resolution exactly (no server-side downscaling artefacts for the displayed version).
- It keeps upload times reasonable.
- Users can override in the export dialog if they prefer the original resolution.

---

## Future ideas

- **Batch sync** – sync all photos with an `inat_observation_id` in one click.
- **Smart collections** – auto-populate smart collections based on taxonomic keyword hierarchy.
- **Map view integration** – open the observation in the iNaturalist web map.
- **Identification alerts** – notify the user when a new ID is added to their observation.
