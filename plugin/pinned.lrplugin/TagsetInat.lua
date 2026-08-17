--[[
  TagsetInat.lua
  --------------
  The plugin's preset in the Metadata panel.

  Lightroom will not let a plugin add its own panel to the Library right panel
  stack, so the Metadata panel's preset dropdown is where a plugin's data
  actually lives. Selecting "Pinned" there turns that panel into an
  iNaturalist panel -- the closest available equivalent of a section under
  Comments.

  Read-only, all of it. Every field here mirrors something that lives on
  iNaturalist or was sent there, and the floating panel is where any of it gets
  changed. There were two clickable "url" rows here that acted as buttons; they
  are gone, because Lightroom owns that row entirely -- it labels the arrow "Go
  to URL", shows the raw URL as the value, and fires on an empty field.

  The heading rows are `com.adobe.label` items, which is how Adobe's own IPTC
  preset draws "Contact" and "Description". Confirmed in LibraryToolkit.dll: the
  formatter table maps com.adobe.separator to `separator` and com.adobe.label to
  `label`, and the shipped IPTC tagset uses exactly this shape.

  Plugin fields are addressed as "<LrToolkitIdentifier>.<field id>". Built-in
  Lightroom fields use their "com.adobe.*" IDs, and only IDs that Lightroom's
  own built-in tagsets use are safe -- see docs/lightroom-sdk-notes.md.
--]]

local prefix = "com.github.inat-lightroom."

return {
  -- The title is what the Metadata panel's preset dropdown shows, alongside
  -- Lightroom's own Default / EXIF / IPTC entries. Those are all descriptions
  -- of what the preset contains, so a bare product name in that list says
  -- nothing about what selecting it would do -- hence the full name here, even
  -- though the window and the menu items get away with just "Pinned".
  --
  -- The id is not shown anywhere; it is how Lightroom remembers which preset
  -- was selected, and it shares a namespace with every other installed
  -- plugin's tagsets. It was "iNaturalist", which is the name another plugin
  -- for this site would reach for first. Renaming it costs one reselect of the
  -- preset -- do not rename it again once anyone else is installing this. The
  -- title above is free to change at any time; only the id is not.
  title = LOC "$$$/iNatLightroom/Tagset/Only=Pinned for iNaturalist",
  id    = "pinnedForInaturalist",

  items = {
    -- Enough identity to know which photo you are looking at; the panel
    -- header only shows the file name when a single photo is selected.
    "com.adobe.filename",
    "com.adobe.separator",

    -- Nothing on this panel can be edited, and a panel of greyed-out fields
    -- with no explanation reads as broken rather than deliberate. This says
    -- where the controls actually are.
    {
      formatter = "com.adobe.label",
      label     = LOC "$$$/iNatLightroom/Tagset/Hint=Edit in File > Plug-in Extras > Pinned Panel",
    },

    prefix .. "inat_species_guess",
    "com.adobe.separator",

    prefix .. "inat_observation_id",
    prefix .. "inat_observation_url",
    prefix .. "inat_observation_uuid",
    prefix .. "inat_quality_grade",
    prefix .. "inat_positional_accuracy",
    prefix .. "inat_last_synced",
    "com.adobe.separator",

    prefix .. "inat_taxon_name",
    prefix .. "inat_common_name",
    prefix .. "inat_taxon_id",
  },
}
