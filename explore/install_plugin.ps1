<#
.SYNOPSIS
  Copy the plugin from a working tree into the folder Lightroom loads it from.

.DESCRIPTION
  Lightroom remembers an installed plugin by path, so pointing it straight at a
  git working tree means re-adding the plugin in the Plug-in Manager every time
  you switch branch or worktree -- and it means the plugin's own updater, when
  it swaps a new version in on shutdown, would overwrite tracked files and
  delete anything the release does not contain.

  So Lightroom points at one fixed folder outside the repository, forever, and
  this script copies a working tree into it. Switching branches becomes: check
  out, run this, click Reload Plug-in.

  The source is taken from wherever this script lives, so running it from a
  worktree installs that worktree without being told which one.

.PARAMETER Destination
  The folder Lightroom is pointed at. Defaults to
  ~\Documents\LrPlugins\inat.lrplugin.

.PARAMETER KeepStaged
  Keep any update the installed copy has already staged.

  By default a staged update is cleared, because it would otherwise be applied
  on the next quit and silently overwrite the copy just installed -- which
  looks exactly like the install having failed. Pass this when deliberately
  testing the staging and swap path.

.EXAMPLE
  .\install_plugin.ps1

.EXAMPLE
  .\install_plugin.ps1 -Destination D:\LrPlugins\inat.lrplugin
#>

[CmdletBinding()]
param(
  [string] $Destination = (Join-Path $HOME "Documents\LrPlugins\inat.lrplugin"),
  [switch] $KeepStaged
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# The plugin sits beside this script's parent: <repo>/explore/.. /plugin/...
$repoRoot = Split-Path -Parent $PSScriptRoot
$source   = Join-Path $repoRoot "plugin\inat.lrplugin"

if (-not (Test-Path (Join-Path $source "Info.lua"))) {
  [Console]::Error.WriteLine("No plugin found at $source")
  exit 1
}

$staging = Join-Path $Destination ".update-staging"
$hadStaged = Test-Path $staging

New-Item -ItemType Directory -Force -Path $Destination | Out-Null

# /MIR so that a file deleted in the working tree also disappears here; an
# installed copy that still has last week's modules in it is worse than no copy.
#
# .update-staging is excluded from the mirror rather than deleted by it, so that
# a deliberate staging test survives the sync and is cleared below only when it
# should be.
$robocopyArgs = @(
  $source, $Destination,
  "/MIR",
  "/XD", $staging, (Join-Path $source ".update-staging"),
  "/NFL", "/NDL", "/NJH", "/NJS", "/NP"
)

& robocopy @robocopyArgs | Out-Null

# Robocopy does not use 0 for success. Anything under 8 is some combination of
# "copied", "extra files removed" and "nothing to do"; 8 and above is a real
# failure. Treating a non-zero exit as failure here would report every
# successful copy as broken.
$robocopyExit = $LASTEXITCODE
if ($robocopyExit -ge 8) {
  [Console]::Error.WriteLine("robocopy failed with exit code $robocopyExit")
  exit 1
}

if ($hadStaged -and -not $KeepStaged) {
  Remove-Item -Recurse -Force $staging
}

$files = (Get-ChildItem $Destination -Recurse -File |
  Where-Object { $_.FullName -notlike "$staging*" }).Count

$version = (Select-String -Path (Join-Path $Destination "Info.lua") `
  -Pattern 'display\s*=\s*"([^"]+)"').Matches[0].Groups[1].Value

Write-Output "Installed $version ($files files)"
Write-Output "  from  $source"
Write-Output "  to    $Destination"

if ($hadStaged) {
  if ($KeepStaged) {
    Write-Output "  kept the staged update; it will be applied when Lightroom quits"
  } else {
    Write-Output "  cleared a staged update that would have overwritten this copy"
  }
}

if (Get-Process -Name "Lightroom" -ErrorAction SilentlyContinue) {
  Write-Output ""
  Write-Output "Lightroom is running: click Reload Plug-in in the Plug-in Manager."
  Write-Output "Changes to Info.lua need a full restart -- Lightroom reads it before"
  Write-Output "any plugin code runs."
}
