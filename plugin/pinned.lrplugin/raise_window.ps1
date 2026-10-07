<#
    raise_window.ps1
    ----------------
    Brings one of the plugin's floating windows to the front by its exact
    title.

    This exists for the single taxonomy window. Pressing Taxonomy… while that
    window is already open refills it rather than opening a second one, and a
    button that appears to do nothing is the worst possible answer -- the
    window may well be behind Lightroom, or behind the observation panel that
    owns it. The SDK has no raise: `presentFloatingDialog` raises a window it
    recognises by id, but calling it again would also block a second task for
    as long as the window is up, so the raise is done from outside instead.

    Deliberately as narrow as close_window.ps1, which it is modelled on: it
    will only ever touch a window that is in a process named Lightroom, has
    class AgWinFrame, and has the exact title it was given.

    Restore before activate, because a minimised window cannot be brought to
    the front -- SetForegroundWindow on one succeeds and leaves it minimised,
    which looks exactly like the button doing nothing. SW_RESTORE is used
    rather than SW_SHOW so that a window which is merely behind something else
    is not resized or un-maximised by being raised.

    AttachThreadInput is not used. Windows refuses SetForegroundWindow from a
    process that does not own the foreground window, and the usual way round
    that is to attach to the foreground thread -- but this script runs because
    Lightroom is in the middle of handling a click, so Lightroom *is* the
    foreground process and the call is allowed. BringWindowToTop follows as the
    fallback for the case where it is not: it reorders the window without
    activating it, which is still better than nothing happening.

    Exit codes:
      0  a matching window was found and raised
      1  no matching window was open
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $Title
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

public static class InatRaiseWindow
{
    private delegate bool EnumProc(IntPtr hwnd, IntPtr lParam);

    [DllImport("user32.dll")]
    private static extern bool EnumWindows(EnumProc callback, IntPtr lParam);

    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetClassNameW(IntPtr hwnd, StringBuilder buffer, int max);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetWindowTextW(IntPtr hwnd, StringBuilder buffer, int max);

    [DllImport("user32.dll")]
    private static extern bool IsWindowVisible(IntPtr hwnd);

    [DllImport("user32.dll")]
    private static extern bool IsIconic(IntPtr hwnd);

    [DllImport("user32.dll")]
    private static extern bool ShowWindow(IntPtr hwnd, int command);

    [DllImport("user32.dll")]
    private static extern bool SetForegroundWindow(IntPtr hwnd);

    [DllImport("user32.dll")]
    private static extern bool BringWindowToTop(IntPtr hwnd);

    private const int SW_RESTORE = 9;

    public class Win
    {
        public IntPtr Handle;
        public uint ProcessId;
        public string ClassName;
        public string Title;
    }

    // StringBuilder marshals as ANSI unless the DllImport says otherwise, which
    // silently returns only the first character of every name. Hence the
    // explicit CharSet.Unicode above.
    private static string Text(Func<StringBuilder, int, int> read)
    {
        var buffer = new StringBuilder(512);
        read(buffer, buffer.Capacity);
        return buffer.ToString();
    }

    public static List<Win> Visible()
    {
        var found = new List<Win>();
        EnumWindows(delegate(IntPtr hwnd, IntPtr lParam)
        {
            if (!IsWindowVisible(hwnd)) return true;
            uint pid;
            GetWindowThreadProcessId(hwnd, out pid);
            found.Add(new Win {
                Handle    = hwnd,
                ProcessId = pid,
                ClassName = Text((b, n) => GetClassNameW(hwnd, b, n)),
                Title     = Text((b, n) => GetWindowTextW(hwnd, b, n)),
            });
            return true;
        }, IntPtr.Zero);
        return found;
    }

    public static void Raise(IntPtr hwnd)
    {
        if (IsIconic(hwnd)) ShowWindow(hwnd, SW_RESTORE);
        if (!SetForegroundWindow(hwnd)) BringWindowToTop(hwnd);
    }
}
'@

# Only ever consider windows belonging to Lightroom itself.
# @() on assignment as well as inside: PowerShell unrolls a single-element
# array on the way out of a pipeline, which would leave a bare uint32 here.
$lightroomPids = @(@(Get-Process -Name 'Lightroom' -ErrorAction SilentlyContinue) |
    ForEach-Object { [uint32] $_.Id })

if ($lightroomPids.Count -eq 0) {
    Write-Error 'Lightroom is not running.'
    exit 1
}

$window = @([InatRaiseWindow]::Visible()) |
    Where-Object { $lightroomPids -contains $_.ProcessId -and
                   $_.ClassName -eq 'AgWinFrame' -and
                   $_.Title -eq $Title } |
    Select-Object -First 1

if ($null -eq $window) {
    Write-Error "No Lightroom window titled '$Title' is open."
    exit 1
}

[InatRaiseWindow]::Raise($window.Handle)
exit 0
