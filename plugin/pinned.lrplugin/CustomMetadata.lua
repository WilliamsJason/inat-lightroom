--[[
  CustomMetadata.lua
  ------------------
  Defines the custom metadata fields that appear in Lightroom's Metadata panel
  under the "Pinned" panel set.

  These fields store the two-way link between a Lightroom photo and its
  iNaturalist observation, as well as the latest synced taxon data.

  Field IDs must be unique and stable; changing them will break existing
  catalogs that already have values stored.

  Everything here is readOnly. The panel is the only way to change anything now,
  and a field you can type into is a promise that typing does something. Two of
  these used to be editable and both were traps:

    * inat_observation_id. Pasting one and syncing was how you adopted an
      existing observation, before there was a Link to Observation button to do
      it properly -- with a confirmation, and without the chance of pasting a
      stranger's ID onto forty photos in one go.
    * inat_species_guess. Editing it here wrote a string to the catalog and
      nothing else. iNaturalist ignores species_guess once an observation has a
      taxon, so a guess typed here was saved, uploaded and silently discarded.
      Identifying now means posting an identification, which needs a taxon id,
      which a text field cannot supply.
--]]

return {
  metadataFieldsForPhotos = {

    -- -----------------------------------------------------------------------
    -- Primary link to iNaturalist
    -- -----------------------------------------------------------------------
    {
      id          = "inat_observation_id",
      title       = LOC "$$$/iNatLightroom/Meta/ObsId=Observation ID",
      dataType    = "string",
      searchable  = true,
      browsable   = false,
      readOnly    = true,
    },

    -- The observation's UUID, and the reason it is stored rather than derived.
    --
    -- A publish service hands photos to the plugin one at a time, so "these
    -- three frames are one observation" cannot be expressed by the act of
    -- publishing them together the way an export batch could. It has to be
    -- recorded on the photos. Photos carrying the same UUID publish into the
    -- same observation; a photo with none gets a fresh observation, and
    -- iNaturalist's own response supplies the UUID we then store.
    --
    -- readOnly because a hand-edited UUID silently attaches a photo to a
    -- stranger's observation, or to nothing at all. Grouping gets a real
    -- button rather than a text field to mistype.
    {
      id          = "inat_observation_uuid",
      title       = LOC "$$$/iNatLightroom/Meta/ObsUuid=Observation UUID",
      dataType    = "string",
      searchable  = true,
      browsable   = false,
      readOnly    = true,
    },
    {
      id          = "inat_observation_url",
      title       = LOC "$$$/iNatLightroom/Meta/ObsUrl=Observation URL",
      dataType    = "url",
      searchable  = false,
      browsable   = false,
      readOnly    = true,
    },

    -- -----------------------------------------------------------------------
    -- Community-determined taxon
    -- -----------------------------------------------------------------------
    {
      id          = "inat_taxon_id",
      title       = LOC "$$$/iNatLightroom/Meta/TaxonId=Taxon ID",
      dataType    = "string",
      searchable  = true,
      browsable   = false,
      readOnly    = true,
    },
    {
      id          = "inat_taxon_name",
      title       = LOC "$$$/iNatLightroom/Meta/TaxonName=Taxon Name",
      dataType    = "string",
      searchable  = true,
      browsable   = true,
      readOnly    = true,
    },
    {
      id          = "inat_common_name",
      title       = LOC "$$$/iNatLightroom/Meta/CommonName=Common Name",
      dataType    = "string",
      searchable  = true,
      browsable   = true,
      readOnly    = true,
    },

    -- -----------------------------------------------------------------------
    -- Observation quality
    -- -----------------------------------------------------------------------
    {
      id          = "inat_quality_grade",
      title       = LOC "$$$/iNatLightroom/Meta/QualityGrade=Quality Grade",
      dataType    = "string",
      searchable  = true,
      browsable   = true,
      readOnly    = true,
    },

    -- -----------------------------------------------------------------------
    -- Sync housekeeping
    -- -----------------------------------------------------------------------
    {
      id          = "inat_last_synced",
      title       = LOC "$$$/iNatLightroom/Meta/LastSynced=Last Synced",
      dataType    = "string",
      searchable  = false,
      browsable   = false,
      readOnly    = true,
    },

    -- -----------------------------------------------------------------------
    -- What was sent as the guess
    --
    -- Kept apart from inat_taxon_name on purpose. That field holds what the
    -- iNaturalist community decided, and every sync overwrites it; if the same
    -- field also carried the user's intent, syncing a photo would quietly
    -- change what a later upload sends. This one is never written by a sync.
    -- -----------------------------------------------------------------------
    {
      id          = "inat_species_guess",
      title       = LOC "$$$/iNatLightroom/Meta/SpeciesGuess=Species Guess",
      dataType    = "string",
      searchable  = true,
      browsable   = false,
      readOnly    = true,
    },

    -- -----------------------------------------------------------------------
    -- How precise the coordinates are
    --
    -- Held in metres as a string, because metres are what iNaturalist takes.
    -- Storing a preset name instead would mean converting in both directions
    -- and, worse, having nowhere to put the number a sync brings back: the
    -- accuracy iNaturalist holds is rarely one of the panel's four presets.
    -- -----------------------------------------------------------------------
    {
      id          = "inat_positional_accuracy",
      title       = LOC "$$$/iNatLightroom/Meta/PositionalAccuracy=Location Accuracy (m)",
      dataType    = "string",
      searchable  = false,
      browsable   = false,
      readOnly    = true,
    },
  },

  -- Schema version; increment when adding/removing fields to allow migration.
  --
  -- v2 added two "url" fields holding lightroom:// links, because a url field
  -- renders as a clickable row and that was the only button the Metadata panel
  -- would give us. v3 removed them: the panel supplies its own "Go to URL"
  -- arrow that a plugin cannot relabel or retarget, and it fires even when the
  -- field is empty, which on Windows opens Explorer. v3 also added the
  -- observation UUID and the species guess.
  --
  -- v4 makes every field read-only and drops inat_crop. The crop was written by
  -- an Export dialog that no longer exists and read by nothing that ever did --
  -- an editable box inviting input that went nowhere. Read-only is the point of
  -- this version: the floating panel is the only way to change anything, so a
  -- field you can type into here is a promise the plugin cannot keep.
  -- v5 adds inat_positional_accuracy, so that a location can say how much it
  -- claims to know. iNaturalist stores accuracy per observation; Lightroom has
  -- nowhere to put it, so the plugin has to.
  --
  -- v6, v7 and v8 were three attempts at deleting the values v3 and v4 left
  -- behind, and it cannot be done. setPropertyForPlugin validates against the
  -- schema this file currently declares, so a removed field rejects the write
  -- that would clear it:
  --
  --   Attempt to access property "inat_action_sync" that's not declared in
  --   Info.lua
  --
  -- Three numbers rather than one because a migration that returns is recorded
  -- as done and never runs again -- so each failed attempt costs a version. Two
  -- of those failures were silent: v6 wrapped the pass in a plain pcall, inside
  -- which getAllPhotos returns an empty list instead of raising, so it read the
  -- catalog as empty and reported success. Instrumenting it was what ended the
  -- guessing, and is the only reason the real cause is known.
  --
  -- What this leaves: a removed field's values are permanent, and its spec is
  -- too. Removing a field is a one-way door. Everything a field has ever held
  -- stays in the catalog and keeps showing up in Lightroom's own "All Plug-in
  -- Metadata" preset, so it is worth being sure before adding one. See
  -- docs/lightroom-sdk-notes.md.
  schemaVersion = 8,

  -- Nothing to do. Adding a field needs no migration, Lightroom will not let a
  -- removed one be touched, and making a field read-only does not change what is
  -- stored in it. Kept as a declared no-op rather than deleted because the next
  -- schema change will want somewhere to put its migration.
  updateFromEarlierSchemaVersion = function(_catalog, _previousSchemaVersion, _progressScope)
  end,
}
