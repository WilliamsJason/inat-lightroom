"""Prove the PanelCore and panel tests actually catch the bugs they claim to.

Each mutation is a plausible way of getting the code wrong -- most are things
that were got wrong at some point, or that a reasonable person would write. A
mutation no test notices means the suite is decoration, not verification.
"""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path

PLUGIN = Path(__file__).parent.parent / "plugin" / "pinned.lrplugin"
TARGETS = {
    "PanelCore": PLUGIN / "PanelCore.lua",
    "ObservationPanel": PLUGIN / "ObservationPanel.lua",
    "CustomMetadata": PLUGIN / "CustomMetadata.lua",
    "TagsetInat": PLUGIN / "TagsetInat.lua",
    "UploadCore": PLUGIN / "UploadCore.lua",
    "SyncCore": PLUGIN / "SyncCore.lua",
    "InatAPI": PLUGIN / "InatAPI.lua",
}

TESTS = ["test_panel_core_lua.py", "test_observation_panel_lua.py",
         "test_plugin_surface_lua.py", "test_upload_core_lua.py",
         "test_sync_observation_lua.py", "test_inat_api_lua.py"]

MUTATIONS = [
    # --- the identification trap, the whole reason for this rewrite ----------
    (
        "PanelCore",
        "a chosen suggestion is sent as free text instead of an identification",
        "  if taxonId then\n    local _, identifyErr = api:addIdentification",
        "  if false then\n    local _, identifyErr = api:addIdentification",
    ),
    (
        "PanelCore",
        "an identification is posted even when no taxon was chosen",
        "  if taxonId then\n    local _, identifyErr = api:addIdentification",
        "  if true then\n    local _, identifyErr = api:addIdentification",
    ),
    (
        "PanelCore",
        "the update detaches every photo on the observation",
        "      species_guess = guess or \"\",\n    }, true)",
        "      species_guess = guess or \"\",\n    }, false)",
    ),
    (
        "PanelCore",
        "an unlinked photo is allowed to post an identification",
        "  if not observationId then\n    return false, \"That photo has not been uploaded",
        "  if false then\n    return false, \"That photo has not been uploaded",
    ),
    (
        "PanelCore",
        "a rejected identification is reported as success",
        "  if err then\n    return false, err\n  end",
        "",
    ),
    (
        "PanelCore",
        "the guess lands only on the first photo of the selection",
        "    for _, photo in ipairs(photos) do\n      photo:setPropertyForPlugin(_PLUGIN, \"inat_species_guess\"",
        "    for _, photo in ipairs({ photos[1] }) do\n      photo:setPropertyForPlugin(_PLUGIN, \"inat_species_guess\"",
    ),

    # --- suggestions ---------------------------------------------------------
    (
        "PanelCore",
        "an uploaded photo is re-rendered instead of scored on the server",
        "  local obsId = UploadCore.pluginField(photo, \"inat_observation_id\")\n  if obsId then",
        "  local obsId = UploadCore.pluginField(photo, \"inat_observation_id\")\n  if false then",
    ),
    (
        "PanelCore",
        "location and date are left off the vision request",
        "    payload, err = api:scoreImage(path, latitude, longitude,\n      UploadCore.observedOnFor(photo))",
        "    payload, err = api:scoreImage(path)",
    ),
    (
        "PanelCore",
        "the temporary render is never deleted",
        "    RenderPhoto.cleanUp(folder)\n  end",
        "  end",
    ),
    (
        "PanelCore",
        "a failed render is scored anyway",
        "    if not path then\n      return nil, renderErr\n    end",
        "",
    ),
    (
        "PanelCore",
        "the suggestion list is not capped",
        "    if i > PanelCore.SUGGESTION_LIMIT then break end",
        "",
    ),
    (
        "PanelCore",
        "list items are keyed by taxon id, which can be nil",
        "      value = i,",
        "      value = row.taxon_id,",
    ),
    (
        "PanelCore",
        "a suggestion with no score claims zero percent",
        "  local score = tonumber(row.combined_score)\n  if score then",
        "  local score = tonumber(row.combined_score) or 0\n  if score then",
    ),
    (
        "PanelCore",
        "the scientific name is dropped from the list",
        "    name = name .. \" (\" .. row.name .. \")\"",
        "    name = name",
    ),

    # --- uploading -----------------------------------------------------------
    (
        "PanelCore",
        "each photo becomes its own observation",
        "  local seen = {}\n  local observationId, uuid, resolveErr =\n    UploadCore.resolveObservation(api, settings, photos[1], seen, errors)",
        "  local seen = {}\n  local observationId, uuid, resolveErr\n  for _, photo in ipairs(photos) do\n    observationId, uuid, resolveErr =\n      UploadCore.resolveObservation(api, settings, photo, {}, errors)\n  end",
    ),
    (
        "PanelCore",
        "an observation with no photo attached is recorded as a success",
        "  if attached == 0 then",
        "  if false then",
    ),
    (
        "PanelCore",
        "the observation is created before anything has rendered",
        "  if #rendered == 0 then\n    RenderPhoto.cleanUp(folder)",
        "  if false then\n    RenderPhoto.cleanUp(folder)",
    ),
    (
        "PanelCore",
        "the rendered files are left behind after the upload",
        "  RenderPhoto.cleanUp(folder)\n\n  if attached == 0 then",
        "  if attached == 0 then",
    ),
    (
        "PanelCore",
        "an empty selection is uploaded anyway",
        "  if not photos or #photos == 0 then\n    return nil, nil, { \"Select at least one photo first.\" }\n  end",
        "",
    ),
    (
        "PanelCore",
        "a project failure fails the whole upload",
        "      errors[#errors + 1] = \"Could not add it to the project: \" .. tostring(projectErr)",
        "      return nil, nil, { tostring(projectErr) }",
    ),
    (
        "PanelCore",
        "the project is used even when none is configured",
        "  if settings.inat_project_id and settings.inat_project_id ~= \"\" then",
        "  if settings.inat_project_id then",
    ),

    # --- keywords, the point of the plugin -----------------------------------
    (
        "PanelCore",
        "an upload never syncs the taxonomy back",
        "  if settings.inat_sync_after_upload ~= false then\n    onEvent(\"Syncing…\")\n    PanelCore.syncBack(catalog, api, photos, errors)\n  end",
        "",
    ),
    (
        "PanelCore",
        "the sync-after-upload preference is ignored",
        "  if settings.inat_sync_after_upload ~= false then",
        "  if true then",
    ),
    (
        "PanelCore",
        "changing the identification does not refresh the keywords",
        "  local errors = {}\n  PanelCore.syncBack(catalog, api, photos, errors)\n\n  return true, errors[1]",
        "  return true, nil",
    ),
    (
        "PanelCore",
        "a failed sync-back is swallowed silently",
        "      if errors then errors[#errors + 1] = err end",
        "",
    ),
    (
        "PanelCore",
        "unlinking silently does nothing",
        "  return UploadCore.unlink(catalog, photos)",
        "  return 0",
    ),

    # --- the panel itself ----------------------------------------------------
    (
        "ObservationPanel",
        "the action button always says Upload, even for a linked photo",
        "    uploadTitle   = linked and ObservationPanel.UPDATE_TITLE\n                           or ObservationPanel.UPLOAD_TITLE,",
        "    uploadTitle   = ObservationPanel.UPLOAD_TITLE,",
    ),
    (
        "ObservationPanel",
        "choosing a suggestion fills the name but forgets the taxon",
        "  props.suggestionTaxonId = row.taxon_id",
        "  props.suggestionTaxonId = nil",
    ),
    (
        "ObservationPanel",
        "a suggestion that is not there leaves the previous taxon armed",
        "  if not row then\n    props.suggestionTaxonId = nil",
        "  if not row then\n    props.suggestionTaxonId = row",
    ),
    (
        "ObservationPanel",
        "choosing a suggestion fills in the common name, which is ambiguous",
        "  props.speciesGuess      = row.name or row.common_name or \"\"",
        "  props.speciesGuess      = row.common_name or row.name or \"\"",
    ),
    (
        "ObservationPanel",
        "unlinking happens without asking",
        "  if answer ~= \"ok\" then return 0 end",
        "",
    ),
    (
        "ObservationPanel",
        "the confirmation does not say the keywords are kept",
        "    .. \"Nothing on iNaturalist is changed or deleted, and the taxonomy \"\n    .. \"keywords already applied are kept.\",",
        "    .. \"This cannot be undone.\",",
    ),
    (
        "ObservationPanel",
        "the Save button comes back",
        "        title   = \"Get Suggestions\",",
        "        title   = \"Save\",",
    ),
    (
        "ObservationPanel",
        "the Unlink button is dropped",
        "      f:push_button {\n        title   = \"Unlink\",",
        "      f:spacer {\n        title   = \"nothing\",",
    ),
    (
        "ObservationPanel",
        "stale suggestions survive a change of selection",
        "      props.suggestions       = {}\n      props.suggestionItems   = {}",
        "      props.suggestions       = props.suggestions or {}\n      props.suggestionItems   = props.suggestionItems or {}",
    ),

    (
        "ObservationPanel",
        "a list selection is used as a row number, so clicking a suggestion does nothing",
        "  local index = PanelCore.selectedIndex(selection)",
        "  local index = selection",
    ),
    (
        "PanelCore",
        "deselecting everything falls back to the first row",
        "  return tonumber(value.value)",
        "  return tonumber(value.value) or 1",
    ),
    (
        "PanelCore",
        "only the bare-number selection shape is handled",
        '  if type(value) ~= "table" then return nil end',
        '  if type(value) ~= "table" then return nil end\n  do return nil end',
    ),

    # --- the metadata panel, which is now display only -----------------------
    (
        "CustomMetadata",
        "the species guess is editable again, and edits go nowhere",
        '      title       = LOC "$$$/iNatLightroom/Meta/SpeciesGuess=Species Guess",\n      dataType    = "string",\n      searchable  = true,\n      browsable   = false,\n      readOnly    = true,',
        '      title       = LOC "$$$/iNatLightroom/Meta/SpeciesGuess=Species Guess",\n      dataType    = "string",\n      searchable  = true,\n      browsable   = false,\n      readOnly    = false,',
    ),
    (
        "CustomMetadata",
        "the observation ID is editable again",
        '      title       = LOC "$$$/iNatLightroom/Meta/ObsId=Observation ID",\n      dataType    = "string",\n      searchable  = true,\n      browsable   = false,\n      readOnly    = true,',
        '      title       = LOC "$$$/iNatLightroom/Meta/ObsId=Observation ID",\n      dataType    = "string",\n      searchable  = true,\n      browsable   = false,\n      readOnly    = false,',
    ),
    (
        "CustomMetadata",
        "the schema version is not bumped with the field changes",
        "  schemaVersion = 5,",
        "  schemaVersion = 4,",
    ),
    (
        "CustomMetadata",
        "the migration hook is dropped",
        "  updateFromEarlierSchemaVersion = function(_catalog, _previousSchemaVersion, _progressScope)",
        "  _unusedMigration = function(_catalog, _previousSchemaVersion, _progressScope)",
    ),
    (
        "TagsetInat",
        "the hint telling people where the controls are is dropped",
        '    {\n      formatter = "com.adobe.label",',
        '    --[[ {\n      formatter = "com.adobe.label",',
    ),
    (
        "TagsetInat",
        "a field is defined but never shown, so its data is invisible",
        '    prefix .. "inat_taxon_id",',
        "",
    ),
    (
        "TagsetInat",
        "a field name loses its plugin namespace and resolves to nothing",
        '    prefix .. "inat_quality_grade",',
        '    "inat_quality_grade",',
    ),

    # --- location, the thing that decides whether an observation counts ------
    (
        "UploadCore",
        "half a location is treated as a location",
        "  if gps and gps.latitude and gps.longitude then",
        "  if gps then",
    ),
    (
        "UploadCore",
        "a photo is always reported as having no location",
        "  local gps = photo:getRawMetadata(\"gps\")",
        "  local gps = nil",
    ),
    (
        "PanelCore",
        "the missing-location warning never fires",
        "  local latitude = UploadCore.locationOf(photos[1])\n  if latitude then return nil end",
        "  local latitude = UploadCore.locationOf(photos[1])\n  if true then return nil end",
    ),
    (
        "PanelCore",
        "the warning nags even when the user turned location off",
        "  if not settings.inat_upload_location then return nil end",
        "",
    ),
    (
        "PanelCore",
        "the warning judges a photo other than the one being uploaded",
        "  local latitude = UploadCore.locationOf(photos[1])",
        "  local latitude = UploadCore.locationOf(photos[#photos])",
    ),
    (
        "PanelCore",
        "a missing location is described without saying what it costs",
        'local NO_LOCATION = "None - iNaturalist will mark this casual"',
        'local NO_LOCATION = "None"',
    ),
    (
        "PanelCore",
        "no photo selected is reported as a missing location",
        "  if not photo then return \"\" end\n\n  local latitude, longitude = UploadCore.locationOf(photo)",
        "  local latitude, longitude\n  if photo then latitude, longitude = UploadCore.locationOf(photo) end",
    ),
    (
        "ObservationPanel",
        "the confirmation is asked and then ignored",
        '    if answer ~= "ok" then',
        '    if false then',
    ),
    (
        "ObservationPanel",
        "the Map button goes to a module that does not exist",
        'LrApplicationView.switchToModule("map")',
        'LrApplicationView.switchToModule("location")',
    ),
    (
        "ObservationPanel",
        "the location row is dropped from the window",
        '      f:static_text { title = "Location:", width = LABEL, alignment = "right" },',
        "",
    ),
    # --- how precise the location claims to be --------------------------------
    (
        "PanelCore",
        "a fractional accuracy is sent as-is",
        'return string.format("%d", math.floor(metres + 0.5))',
        "return tostring(metres)",
    ),
    (
        "PanelCore",
        "a nonsense accuracy is passed through instead of treated as unset",
        "if not metres or metres <= 0 then return \"\" end",
        "if not metres then return raw end",
    ),
    (
        "PanelCore",
        "a synced accuracy gets no item, so the popup renders blank",
        "  if value then\n    items[#items + 1] = {\n      value = value,",
        "  if false then\n    items[#items + 1] = {\n      value = value,",
    ),
    (
        "PanelCore",
        "the stored value is duplicated when it is already a preset",
        "if preset.value == value then value = nil end",
        "",
    ),
    (
        "PanelCore",
        "the accuracy lands only on the first photo of the selection",
        '    for _, photo in ipairs(photos) do\n      photo:setPropertyForPlugin(_PLUGIN, "inat_positional_accuracy"',
        '    for _, photo in ipairs({ photos[1] }) do\n      photo:setPropertyForPlugin(_PLUGIN, "inat_positional_accuracy"',
    ),
    (
        "PanelCore",
        "the accuracy update detaches every photo on the observation",
        "    positional_accuracy = tonumber(value),\n  }, true)",
        "    positional_accuracy = tonumber(value),\n  }, false)",
    ),
    (
        "PanelCore",
        "an unset accuracy is PUT anyway, overwriting what iNaturalist knows",
        '  local value = PanelCore.accuracyValue(accuracy)\n  if value == "" then return true, nil end',
        "  local value = PanelCore.accuracyValue(accuracy)",
    ),
    (
        "PanelCore",
        "an unlinked photo tries to update an observation it does not have",
        "  local observationId = UploadCore.pluginField(photos[1], \"inat_observation_id\")\n  if not observationId then return true, nil end",
        '  local observationId = UploadCore.pluginField(photos[1], "inat_observation_id")',
    ),
    (
        "UploadCore",
        "the accuracy is sent without any coordinates to describe",
        "positional_accuracy",
        "PositionalAccuracy",
    ),

    # --- bringing the location home ------------------------------------------
    (
        "SyncCore",
        "an obscured observation's randomised coordinates are taken as real",
        "if obs.obscured then return nil, nil, nil end",
        "",
    ),
    (
        "SyncCore",
        "the owner's true position is ignored in favour of the public one",
        "  local point = obs.private_location",
        "  local point = nil",
    ),
    (
        "SyncCore",
        "a half-written location string is parsed as a coordinate",
        'string.match(point, "^%s*(-?[%d%.]+)%s*,%s*(-?[%d%.]+)%s*$")',
        'string.match(point, "^%s*(-?[%d%.]*)%s*,?%s*(-?[%d%.]*)")',
    ),
    (
        "SyncCore",
        "the sync moves a photo the user already placed",
        "if latitude and not UploadCore.locationOf(photo) then",
        "if latitude then",
    ),
    (
        "SyncCore",
        "the derived obscured accuracy is stored as the real one",
        "local accuracy = tonumber(obs.positional_accuracy)",
        "local accuracy = tonumber(obs.public_positional_accuracy or obs.positional_accuracy)",
    ),
    # --- coming in at a rank you can defend -----------------------------------
    (
        "InatAPI",
        "the common ancestor is dropped, leaving nothing to fall back to",
        "  local ancestor = payload and payload.common_ancestor\n  return rows, ancestor and ancestor.taxon or nil",
        "  return rows, nil",
    ),
    (
        "InatAPI",
        "the common ancestor envelope is returned instead of the taxon inside it",
        "return rows, ancestor and ancestor.taxon or nil",
        "return rows, ancestor",
    ),
    (
        "PanelCore",
        "a fallback is offered even when the top answer is confident",
        "  if tonumber(topScore) and tonumber(topScore) >= PanelCore.CONFIDENT_SCORE then\n    return {}\n  end",
        "",
    ),
    (
        "PanelCore",
        "the ladder is built coarsest-first, burying the useful option",
        "  for i = #chain, 1, -1 do\n    local taxon = chain[i]",
        "  for i = 1, #chain do\n    local taxon = chain[i]",
    ),
    (
        "PanelCore",
        "every intermediate rank is offered, turning a choice into a lecture",
        'PanelCore.FALLBACK_RANKS = { "order", "family", "genus" }',
        'PanelCore.FALLBACK_RANKS = { "order", "family", "genus", "suborder", "superfamily", "tribe" }',
    ),
    (
        "PanelCore",
        "a fallback row is given an invented confidence score",
        "        note        = taxon.rank",
        "        combined_score = 100, note = taxon.rank",
    ),
    (
        "PanelCore",
        "the fallbacks are appended below the species instead of above",
        "  local combined = {}\n  for _, row in ipairs(fallbacks) do combined[#combined + 1] = row end\n  for _, row in ipairs(rows) do combined[#combined + 1] = row end",
        "  local combined = {}\n  for _, row in ipairs(rows) do combined[#combined + 1] = row end\n  for _, row in ipairs(fallbacks) do combined[#combined + 1] = row end",
    ),
    (
        "PanelCore",
        "the lineage is fetched even for a confident list",
        "  if topScore and topScore >= PanelCore.CONFIDENT_SCORE then return rows end",
        "",
    ),
    (
        "PanelCore",
        "the fallback rows never reach the list",
        "    SyncCore.withAncestors(api, commonAncestor), topScore)",
        "    nil, topScore)",
    ),

    # --- arguing before a weak species claim ----------------------------------
    (
        "PanelCore",
        "a weak species claim is waved through",
        "  if not score or score >= PanelCore.CONFIDENT_SCORE then return nil end",
        "  if true then return nil end",
    ),
    (
        "PanelCore",
        "a careful genus choice is interrogated like a species claim",
        "  if not PanelCore.SPECIES_RANKS[row.rank] then return nil end",
        "",
    ),
    (
        "PanelCore",
        "a subspecies escapes the warning a species gets",
        "PanelCore.SPECIES_RANKS = { species = true, subspecies = true, variety = true }",
        "PanelCore.SPECIES_RANKS = { species = true }",
    ),
    (
        "PanelCore",
        "the warning never names the alternative, so it is just a nag",
        '"again and pick the genus or family instead -- a coarser record that is " ..',
        '"again. " ..',
    ),
    (
        "ObservationPanel",
        "the confirmation is asked and then ignored",
        '    local answer = LrDialogs.confirm("Identify as a species?", doubt,\n      "Identify Anyway", "Cancel")\n    if answer ~= "ok" then',
        '    local answer = LrDialogs.confirm("Identify as a species?", doubt,\n      "Identify Anyway", "Cancel")\n    if false then',
    ),
    (
        "ObservationPanel",
        "the weak-species question is asked only on the upload path",
        "  local doubt = PanelCore.confidenceWarning({",
        "  local doubt = UploadCore.pluginField(photos[1], \"inat_observation_id\") and nil or PanelCore.confidenceWarning({",
    ),

    # --- filing a name without publishing it ----------------------------------
    (
        "PanelCore",
        "a local apply proceeds without a chosen suggestion",
        '  if not taxonId then\n    return false, "Pick a suggestion first, then apply it."\n  end',
        "",
    ),
    (
        "PanelCore",
        "a failed taxon fetch still writes half a taxonomy",
        '  if not taxon then\n    return false, err or "Could not fetch that taxon."\n  end',
        "",
    ),
    (
        "PanelCore",
        "the local apply lands only on the first photo of the selection",
        "    for _, photo in ipairs(photos) do\n      SyncCore.applyTaxon(catalog, photo, taxon)",
        "    for _, photo in ipairs({ photos[1] }) do\n      SyncCore.applyTaxon(catalog, photo, taxon)",
    ),
    (
        "PanelCore",
        "the local apply writes no species guess, so an upload later sends none",
        '      photo:setPropertyForPlugin(_PLUGIN, "inat_species_guess", taxon.name or "")',
        "",
    ),
    (
        "PanelCore",
        "a taxon URL is built from an id that is not a number",
        "  local id = tonumber(taxonId)\n  if not id then return nil end",
        "  local id = taxonId",
    ),
    (
        "PanelCore",
        "a large taxon id is formatted into scientific notation",
        'return "https://www.inaturalist.org/taxa/" .. string.format("%d", id)',
        'return "https://www.inaturalist.org/taxa/" .. tostring(id)',
    ),
    (
        "SyncCore",
        "applyTaxon writes the fields but never the keyword",
        "  local leafKw = ensureKeywordPath(catalog, buildKeywordPath(taxon))\n  if leafKw then\n    photo:addKeyword(leafKw)\n  end",
        "",
    ),
    (
        "SyncCore",
        "a taxon that arrived without ancestors is used as-is",
        "  local full, err = api:getTaxon(taxon.id)\n  if full then return full end",
        "",
    ),
    (
        "ObservationPanel",
        "the local-apply button is dropped from the window",
        '        title   = "Sync guess to Metadata tags",',
        '        title   = "",',
    ),
    (
        "ObservationPanel",
        "the two new buttons are enabled without a chosen suggestion",
        '        enabled = LrView.bind("hasSuggestion"),\n        action  = actions.applyLocally,',
        '        enabled = LrView.bind("hasPhoto"),\n        action  = actions.applyLocally,',
    ),
    (
        "ObservationPanel",
        "a deselected suggestion leaves the buttons live against a stale taxon",
        "    props.hasSuggestion     = false\n    return nil",
        "    return nil",
    ),
    (
        "ObservationPanel",
        "the chosen rank and score are never recorded, so nothing can be warned about",
        "  props.suggestionRank    = row.rank\n  props.suggestionScore   = row.combined_score",
        "",
    ),
]


def main() -> int:
    backups = {name: path.read_text(encoding="utf-8") for name, path in TARGETS.items()}
    survivors = []

    try:
        for name, description, old, new in MUTATIONS:
            path = TARGETS[name]
            source = backups[name]

            if old not in source:
                print(f"SKIP  {description}\n      (anchor not found -- fix the script)")
                survivors.append(description)
                continue

            path.write_text(source.replace(old, new, 1), encoding="utf-8")

            result = subprocess.run(
                [sys.executable, "-m", "pytest", *TESTS, "-q",
                 "--no-header", "-x", "--tb=no", "-p", "no:cacheprovider"],
                cwd=Path(__file__).parent,
                capture_output=True,
                text=True,
            )

            if result.returncode == 0:
                print(f"SURVIVED  {description}")
                survivors.append(description)
            else:
                print(f"caught    {description}")
    finally:
        for name, path in TARGETS.items():
            path.write_text(backups[name], encoding="utf-8")

    print()
    if survivors:
        print(f"{len(survivors)} of {len(MUTATIONS)} mutations survived:")
        for s in survivors:
            print(f"  - {s}")
        return 1

    print(f"All {len(MUTATIONS)} mutations caught.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
