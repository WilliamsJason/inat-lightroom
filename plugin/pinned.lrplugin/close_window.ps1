<#
    close_window.ps1
    ----------------
    Closes one of the plugin's floating windows by its exact title.

    The Lightroom SDK has no per-window close. `LrDialogs` exposes exactly one
    programmatic close -- `closeFloatingDialogsForPlugin` -- and it is
    plugin-wide, so a Close button built on it would take the observation panel
    down with the taxonomy window it was asked to close. That is not a Close
    button, it is a trapdoor.

    What the window's own close box does is send it WM_CLOSE, and nothing stops
    us sending the same message. So this is the title-bar button, wired to a
    button in the contents where people look for it.

    Deliberately as narrow as fix_window_z_order.ps1, which it is modelled on:
    it will only ever touch a window that is in a process named Lightroom, has
    class AgWinFrame, and has the exact title it was given. Anything else is
    left alone. WM_CLOSE is a request, not a kill -- the window closes the way
    it would have anyway, and whatever Lightroom does on close still happens.

    Posted rather than sent: SendMessage would block this process until
    Lightroom finished tearing the window down, and Lightroom is at that moment
    inside the call that is waiting for us.

    Exit codes:
      0  a matching window was found and asked to close
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

public static class InatCloseWindow
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

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool PostMessageW(IntPtr hwnd, uint msg, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll")]
    private static extern bool IsWindowVisible(IntPtr hwnd);

    private const uint WM_CLOSE = 0x0010;

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

    public static bool Close(IntPtr hwnd)
    {
        return PostMessageW(hwnd, WM_CLOSE, IntPtr.Zero, IntPtr.Zero);
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

$window = @([InatCloseWindow]::Visible()) |
    Where-Object { $lightroomPids -contains $_.ProcessId -and
                   $_.ClassName -eq 'AgWinFrame' -and
                   $_.Title -eq $Title } |
    Select-Object -First 1

if ($null -eq $window) {
    Write-Error "No Lightroom window titled '$Title' is open."
    exit 1
}

[void] [InatCloseWindow]::Close($window.Handle)
exit 0
