# inat-lightroom

Exploratory work around [iNaturalist](https://www.inaturalist.org/) APIs, with the long-term goal of producing an Adobe Lightroom Classic plugin.

---

## Goals

### 1. Upload photos to iNaturalist

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

The plugin does the full round trip today: identify a photo, upload it as an
iNaturalist observation with the image attached, and sync the community
determination back as a taxonomic keyword tree. Verified end to end against the
live API — there is no iNaturalist sandbox, so every test writes to a real
account.

Everything happens in a floating **iNaturalist panel** (Library → Plug-in
Extras). It follows the filmstrip selection, asks iNaturalist's vision model
what the photo is, and turns the answer into an upload or an identification on
an observation you already have. A second window holds settings: credentials,
export options, and a sync of everything in the catalog that is linked.

Lightroom gives a plugin no docked surface that can hold a button — that was
checked against the shipped binaries, not assumed — so a floating window is as
close to a panel as a plugin gets. On Windows it is nudged into behaving like
one: a small helper hands the window to Lightroom so it stays above Lightroom,
and only Lightroom, instead of the whole desktop.

The **Metadata panel** carries an iNaturalist preset, but it is display only.
It shows what the observation says; it does not change it.

There was a Publish Service and an ordinary Export target. Both are gone. A
publish service gives you Lightroom's new/modified/published bookkeeping, but
it makes publishing the moment you identify a photo, and by then it is too late
to ask what the photo is. See [`docs/plugin-architecture.md`](docs/plugin-architecture.md)
for what that costs and why it was still worth it — and for what to do if you
have an existing published collection.

Authentication is currently a pasted API token, which expires daily. The
frictionless path needs an approved iNaturalist application, and since 2022
those are reviewed manually. See [`plugin/README.md`](plugin/README.md).

Rough edges worth knowing: an upload takes the whole selection into one
observation, but there is no way yet to group photos across separate uploads;
and the panel's suggestions list has not been through a full host round trip on
macOS.

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
│   ├── test_*_lua.py            # Tests over the plugin's actual Lua
│   └── mutate_*.py              # Breaks the plugin on purpose to check the
│                                #   tests would notice
│
└── plugin/                      # Adobe Lightroom Classic plugin (Lua)
    ├── README.md
    └── inat.lrplugin/
        ├── Info.lua             # Plugin identity, version, menu, tagsets, URL handler
        ├── ObservationPanelMenu.lua  # Plug-in Extras entry: opens the panel
        ├── ObservationPanel.lua # The panel's window: view and wiring
        ├── PanelCore.lua        # What its buttons do, minus the UI
        ├── RenderPhoto.lua      # Renders a JPEG without an export service
        ├── UploadCore.lua       # Creating and updating observations
        ├── SyncCore.lua         # Sync taxon data → Lightroom keywords
        ├── LinkObservation.lua  # Adopting an existing observation
        ├── SettingsMenu.lua     # Plug-in Extras entry: settings
        ├── SettingsDialog.lua   # The settings window
        ├── Settings.lua         # Reading, writing and validating settings
        ├── WindowFix.lua        # Keeps the panel above Lightroom, not the desktop
        ├── fix_window_z_order.ps1 # The Win32 helper it shells out to
        ├── InatAuth.lua         # Token acquisition and credential storage
        ├── InatAPI.lua          # HTTP client for the iNaturalist REST API
        ├── PluginUrls.lua       # Builds and parses lightroom:// plugin URLs
        ├── URLHandler.lua       # Receives those URLs and dispatches
        ├── TagsetInat.lua       # Metadata panel preset (display only)
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
