--[[
  TagsetInatCombined.lua
  ----------------------
  Metadata panel preset with the everyday Lightroom fields *and* this plugin's.

  TagsetInat.lua shows only iNaturalist data, which means selecting it costs
  the user their normal metadata view -- so in practice they switch back and
  forget. This preset is the one meant for daily use: the fields most people
  keep in "Default", then a separator, then iNaturalist. That is as close as
  the SDK allows to "an iNaturalist section below Comments".

  Every com.adobe.* ID below is one Lightroom's own built-in tagsets use. That
  matters more than it sounds: a tagset naming an ID Lightroom does not accept
  misbehaves without raising, and a string being present in the binary does not
  make it a valid *tagset item* -- "com.adobe.label" is a section-heading
  formatter, not the colour label, and the colour label is "com.adobe.colorLabels".
  The authority is the compiled AgMetadataTagsets.lua inside LibraryToolkit.dll;
  see docs/lightroom-sdk-notes.md for how to read it.

  There is deliberately no keywords row. No built-in tagset has one, and the
  Library panel already has both Keywording and Keyword List above this.
--]]

local prefix = "com.github.inat-lightroom."

return {
  title = LOC "$$$/iNatLightroom/Tagset/Combined=iNaturalist + Default",
  id    = "inatCombined",

  items = {
    "com.adobe.filename",
    "com.adobe.copyname",
    "com.adobe.folder",
    "com.adobe.separator",

    "com.adobe.rating",
    "com.adobe.colorLabels",
    "com.adobe.title",
    "com.adobe.caption",
    "com.adobe.separator",

    "com.adobe.dateTimeOriginal",
    "com.adobe.GPS",
    "com.adobe.location",
    "com.adobe.separator",

    -- iNaturalist. Actions first: they are the reason to look here.
    prefix .. "inat_action_sync",
    prefix .. "inat_action_link",
    prefix .. "inat_observation_id",
    prefix .. "inat_taxon_name",
    prefix .. "inat_common_name",
    prefix .. "inat_quality_grade",
    prefix .. "inat_last_synced",
  },
}
