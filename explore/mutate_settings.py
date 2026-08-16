"""Prove the Settings / SettingsDialog tests catch what they claim to."""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path

PLUGIN = Path(__file__).parent.parent / "plugin" / "inat.lrplugin"
TARGETS = {
    "Settings": PLUGIN / "Settings.lua",
    "SettingsDialog": PLUGIN / "SettingsDialog.lua",
}

MUTATIONS = [
    (
        "Settings",
        "an unset preference reads as nil instead of its default",
        "  local value = prefs[key]\n  if value == nil then\n    return Settings.DEFAULTS[key]\n  end\n  return value",
        "  return prefs[key]",
    ),
    (
        "Settings",
        "a preference turned off falls back to its default",
        "  if value == nil then",
        "  if not value then",
    ),
    (
        "Settings",
        "location is stripped from the upload by default",
        "  render_remove_location = false,",
        "  render_remove_location = true,",
    ),
    (
        "Settings",
        "GPS is withheld from observations by default",
        "  inat_upload_location = true,",
        "  inat_upload_location = false,",
    ),
    (
        "SettingsDialog",
        "saving copies the whole property table into prefs, token included",
        "  for key in pairs(Settings.DEFAULTS) do\n    local value = props[key]",
        "  for key in pairs(props) do\n    local value = props[key]",
    ),
    (
        "SettingsDialog",
        "a preference set to false is skipped when saving",
        "    if value ~= nil then",
        "    if value then",
    ),
    (
        "SettingsDialog",
        "the OAuth password-grant form comes back into the Account tab",
        "      f:static_text { title = \"Option 2: Sign in with iNaturalist\", font = \"<system/bold>\" },",
        "      f:static_text { title = \"Option 2\", font = \"<system/bold>\" },\n      f:password_field { value = LrView.bind(\"app_secret\"), width = 380 },",
    ),
    (
        "SettingsDialog",
        "Sync All trusts the catalog index and syncs unlinked photos too",
        "    local id = photo:getPropertyForPlugin(_PLUGIN, \"inat_observation_id\")\n    if id and id ~= \"\" then",
        "    local id = photo:getPropertyForPlugin(_PLUGIN, \"inat_observation_id\")\n    if true then",
    ),
    (
        "SettingsDialog",
        "Sync All syncs the filmstrip selection instead of the catalog",
        "  local candidates = catalog:findPhotosWithProperty(\n    _PLUGIN.id, \"inat_observation_id\") or {}",
        "  local candidates = catalog:getTargetPhotos() or {}",
    ),
    (
        "SettingsDialog",
        "Sync All is silent when nothing is linked",
        "  if #photos == 0 then\n    LrDialogs.message(\"iNaturalist Sync\",\n      \"No photos in this catalog are linked to an observation yet.\", \"info\")\n    return 0\n  end",
        "  if #photos == 0 then\n    return 0\n  end",
    ),
    (
        "SettingsDialog",
        "two tabs share an identifier, which ui.dll refuses to build",
        '    identifier = "observations",',
        '    identifier = "account",',
    ),
    (
        "SettingsDialog",
        "a tab carries no identifier at all",
        '    identifier = "image",',
        "    identifier = nil,",
    ),
    (
        "SettingsDialog",
        "a tab has no title, so there is nothing to click",
        '    title      = "Image",',
        '    title      = nil,',
    ),
    (
        "SettingsDialog",
        "the account tab is buried behind the others",
        "    accountTab(f, props),\n    observationsTab(f, props, actions),",
        "    observationsTab(f, props, actions),\n    accountTab(f, props),",
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
                [sys.executable, "-m", "pytest", "test_settings_dialog_lua.py", "-q",
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
