--[[
  TagsetInat.lua
  --------------
  Metadata panel preset showing only this plugin's fields.

  Lightroom will not let a plugin add its own panel to the Library right panel
  stack, so the Metadata panel's preset dropdown is where a plugin's data
  actually lives. Selecting "iNaturalist" there turns that panel into an
  iNaturalist panel -- the closest available equivalent of a section under
  Comments.

  Plugin fields are addressed as "<LrToolkitIdentifier>.<field id>". Built-in
  Lightroom fields use their "com.adobe.*" IDs.
--]]

local prefix = "com.github.inat-lightroom."

return {
  title = LOC "$$$/iNatLightroom/Tagset/Only=iNaturalist",
  id    = "inatOnly",

  items = {
    -- Enough identity to know which photo you are looking at; the panel
    -- header only shows the file name when a single photo is selected.
    "com.adobe.filename",
    "com.adobe.separator",

    prefix .. "inat_action_sync",
    prefix .. "inat_action_link",
    "com.adobe.separator",

    prefix .. "inat_observation_id",
    prefix .. "inat_observation_url",
    prefix .. "inat_quality_grade",
    prefix .. "inat_last_synced",
    "com.adobe.separator",

    prefix .. "inat_taxon_name",
    prefix .. "inat_common_name",
    prefix .. "inat_taxon_id",
    "com.adobe.separator",

    prefix .. "inat_crop",
  },
}
