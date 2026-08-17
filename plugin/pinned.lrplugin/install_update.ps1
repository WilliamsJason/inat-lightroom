<#
    install_update.ps1
    ------------------
    Verifies a downloaded plugin archive and unpacks it into the staging folder.

    Lua cannot hash a file or read a ZIP, and Lightroom's SDK offers neither, so
    the two steps that must not be got wrong happen here instead. They are in one
    script on purpose: verifying in one process and extracting in another leaves
    a window where the file that was checked is not the file that was opened.

    Nothing here touches the installed plugin. This only ever writes inside
    -Destination, which UpdateInstall.lua then applies as Lightroom shuts down.

    The hash is not a defence against a hostile GitHub -- the checksum ships from
    the same place as the archive, so anyone able to replace one can replace the
    other. TLS and GitHub's identity are the trust boundary. This catches the
    ordinary failure: a truncated or corrupted download being unpacked over a
    working plugin.

    Exit codes:
      0  verified and unpacked
      1  the archive is missing or unreadable
      2  the archive does not match the expected hash
      3  unpacking failed
      4  what came out of the archive is not a Lightroom plugin
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $Archive,

    [Parameter(Mandatory = $true)]
    [string] $ExpectedHash,

    [Parameter(Mandatory = $true)]
    [string] $Destination
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Exit codes are the whole interface between this script and UpdateInstall.lua,
# which turns each one into a sentence for the user. They have to survive.
#
# Write-Error cannot be used to report these: with $ErrorActionPreference set to
# Stop it raises a terminating error, PowerShell exits 1 on the spot, and every
# distinct failure below arrives in Lua as "exit 1" -- including the checksum
# mismatch, which is the one failure the user most needs described accurately.
function Fail {
    param([string] $Message, [int] $Code)
    [Console]::Error.WriteLine($Message)
    exit $Code
}

if (-not (Test-Path -LiteralPath $Archive -PathType Leaf)) {
    Fail "Archive not found: $Archive" 1
}

try {
    $actual = (Get-FileHash -LiteralPath $Archive -Algorithm SHA256).Hash
} catch {
    Fail "Could not hash the archive: $_" 1
}

if ($actual -ne $ExpectedHash.Trim().ToUpperInvariant()) {
    Fail "Hash mismatch: expected $ExpectedHash, got $actual" 2
}

# A staging folder left over from an interrupted attempt would otherwise merge
# with this one, producing a mixture of two versions.
if (Test-Path -LiteralPath $Destination) {
    try {
        Remove-Item -LiteralPath $Destination -Recurse -Force
    } catch {
        Fail "Could not clear the staging folder: $_" 3
    }
}

try {
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    Expand-Archive -LiteralPath $Archive -DestinationPath $Destination -Force
} catch {
    Fail "Could not unpack the archive: $_" 3
}

# The archive is built with one <name>.lrplugin folder at its root. The name is
# discovered rather than hardcoded: this script is the *installed* copy, one
# release older than the archive it is checking, so a literal name here is a
# name no later release could change without this rejecting it. Checking for
# the one file Lightroom cannot load a plugin without is what stops a wrongly
# shaped archive from ever reaching the installed copy.
$candidates = @(Get-ChildItem -LiteralPath $Destination -Directory -Filter '*.lrplugin' -ErrorAction SilentlyContinue |
    Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'Info.lua') -PathType Leaf })

if ($candidates.Count -ne 1) {
    # Leave nothing behind that a later run could mistake for a staged update.
    Remove-Item -LiteralPath $Destination -Recurse -Force -ErrorAction SilentlyContinue
    if ($candidates.Count -eq 0) {
        Fail "Unpacked archive has no *.lrplugin folder containing Info.lua" 4
    }
    Fail "Unpacked archive has $($candidates.Count) *.lrplugin folders; expected one" 4
}

exit 0
