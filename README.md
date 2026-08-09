# inat-lightroom

Exploratory work around [iNaturalist](https://www.inaturalist.org/) APIs, with the long-term goal of producing an Adobe Lightroom Classic plugin.

---

## Goals

### 1. Upload photos to iNaturalist

- **iNat-specific crop** – choose a crop used only for the iNaturalist upload, independent of the main Lightroom crop.
- **Multi-photo observations** – select multiple photos of the same species and associate them with a single iNaturalist observation record.
- **Native resolution** – export at iNaturalist's recommended maximum (2048 px on the long edge) so Lightroom never has to upscale or over-downscale.
- **Two-way link** – write the iNaturalist observation ID back to the Lightroom photo as custom metadata so the two records stay connected.
- **Rich metadata at upload time** – choose from AI species recommendations, add the observation to a project, and optionally override the location or timestamp before submitting.

### 2. Sync iNaturalist data back to Lightroom

Using the stored observation ID, pull the latest community determination from iNaturalist and write the full taxonomic tree (kingdom → species) into the photo's keywords/metadata so that searching for any taxonomic rank returns the correct photos.

### 3. Future ideas

Any other useful functionality identified as the project matures.

---

## Status

The plugin does the full round trip today: publish a photo from Lightroom, have
it become an iNaturalist observation with the image attached, and sync the
community determination back as a taxonomic keyword tree. Verified end to end
against the live API — there is no iNaturalist sandbox, so every test writes to
a real account.

It lives in the **Publish Services** panel, so Lightroom tracks what is new,
modified and published. Republishing an edited photo pushes its current details
to the existing observation and replaces the uploaded image rather than
creating a duplicate, and removing a photo from the collection detaches it on
iNaturalist.

There is also a floating **iNaturalist panel** (Library → Plug-in Extras) that
follows the filmstrip selection and carries the per-photo actions. Lightroom
gives a plugin no docked surface that can hold a button — that was checked
against the shipped binaries, not assumed — so a floating window is as close to
a panel as a plugin gets. On Windows it is nudged into behaving like one: a
small helper hands the window to Lightroom so it stays above Lightroom, and
only Lightroom, instead of the whole desktop.

Authentication is currently a pasted API token, which expires daily. The
frictionless path needs an approved iNaturalist application, and since 2022
those are reviewed manually. See [`plugin/README.md`](plugin/README.md).

Rough edges worth knowing: one photo is one observation so far (grouping several
photos into a single observation is next), the iNat crop is stored but not yet
applied at upload, and the AI species suggestions are prototyped in Python but
not in the plugin.

---

## Repository layout

```
inat-lightroom/
├── docs/                        # Notes, API reference, architecture decisions
│   ├── inat-api-notes.md        # iNaturalist REST API traps, verified live
│   ├── lightroom-sdk-notes.md   # Lightroom SDK traps, found the hard way
│   └── plugin-architecture.md   # Lightroom plugin design
│
├── explore/                     # Python exploration + the Lua test harness
│   ├── README.md
│   ├── inat_api.py              # Direct API client; the Lua mirrors this
│   ├── feasibility_test.py      # Full round trip against the live API
│   ├── suggest_species.py       # Computer-vision species suggestions
│   ├── lua_harness.py           # Runs the plugin's Lua outside Lightroom
│   ├── check_lua.py             # Parses the plugin under Lua 5.1
│   └── test_*_lua.py            # Tests over the plugin's actual Lua
│
└── plugin/                      # Adobe Lightroom Classic plugin (Lua)
    ├── README.md
    └── inat.lrplugin/
        ├── Info.lua             # Plugin identity, version, menu, tagsets, URL handler
        ├── ObservationPanelMenu.lua  # Plug-in Extras entry: opens the panel
        ├── ObservationPanel.lua # Floating panel that follows the selection
        ├── WindowFix.lua        # Keeps the panel above Lightroom, not the desktop
        ├── fix_window_z_order.ps1 # The Win32 helper it shells out to
        ├── CredentialsMenu.lua   # Plug-in Extras entry: credentials
        ├── CredentialsDialog.lua # The credentials dialog itself
        ├── LinkObservation.lua  # Adopting an existing observation
        ├── InatAuth.lua         # Token acquisition and credential storage
        ├── InatAPI.lua          # HTTP client for the iNaturalist REST API
        ├── ExportServiceProvider.lua  # Publish service (upload to iNaturalist)
        ├── SyncCore.lua         # Sync taxon data → Lightroom keywords
        ├── PluginUrls.lua       # Builds and parses lightroom:// plugin URLs
        ├── URLHandler.lua       # Receives those URLs and dispatches
        ├── TagsetInat.lua       # Metadata panel preset
        ├── CustomMetadata.lua   # Custom metadata schema
        ├── Log.lua              # Shared logger
        └── json.lua             # Bundled JSON encoder/decoder
```

---

## Quick start (Python exploration)

```powershell
cd explore
python -m venv .venv
.\.venv\Scripts\python.exe -m pip install -r requirements.txt
```

Put an API token from <https://www.inaturalist.org/users/api_token> in `.env`
as `INAT_API_TOKEN`, then:

```powershell
# Species suggestions for a photo
.\.venv\Scripts\python.exe suggest_species.py --photo C:\path\to\photo.jpg

# Full upload/update/sync round trip -- creates a real observation
.\.venv\Scripts\python.exe feasibility_test.py --photo C:\path\to\photo.jpg
```

See [`explore/README.md`](explore/README.md) for full details.

---

## Quick start (Lightroom plugin)

See [`plugin/README.md`](plugin/README.md) for installation and development instructions.

---

## Contributing

This is currently a personal exploratory project. If you have ideas or want to collaborate, open an issue to start the conversation.

---

## License

MIT – see [LICENSE](LICENSE).
