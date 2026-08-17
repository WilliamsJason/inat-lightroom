<#
    fix_window_z_order.ps1
    ----------------------
    Makes the plugin's floating panel behave like a panel instead of a
    system-wide overlay.

    Lightroom creates SDK floating windows with WS_EX_TOPMOST and no owner
    window. Measured with GetWindowLongPtrW against a live Lightroom:

        panel        class AgWinFrame      ex-style 0x108   owner 0
        Lightroom    class AgWinMainFrame  ex-style 0x100   owner 0

    So the panel floats above every application on the desktop, not just above
    Lightroom, and because it has no owner it does not minimise or restore with
    Lightroom either.

    None of that is reachable from Lua. `_topmost` is a real property of the
    underlying window object, but the SDK's window builder in ui.dll never reads
    the key -- passing `_topmost = false` through presentFloatingDialog was
    tested in the host and the window still came up 0x108.

    What we want instead is an ordinary owned window: it stays above its owner
    and nothing else, and it minimises and restores with it. That is two Win32
    calls, which Lua cannot make, hence this script.

    Deliberately safe about what it touches: it only ever modifies a window that
    is in a process named Lightroom, has class AgWinFrame, has the exact title
    it was given, and whose process also owns an AgWinMainFrame to be re-parented
    to. Anything else is left alone.

    Exit codes:
      0  a window was found and fixed, or was already correct
      1  no matching window appeared before the timeout
      2  the fix-up was attempted and did not take
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $Title,

    # The panel is fixed up from a task that runs alongside the one blocked in
    # presentFloatingDialog, so the window may not exist yet when we start.
    [int] $TimeoutSeconds = 10
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

public static class InatWindows
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
    private static extern IntPtr GetWindowLongPtrW(IntPtr hwnd, int index);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern IntPtr SetWindowLongPtrW(IntPtr hwnd, int index, IntPtr value);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool SetWindowPos(IntPtr hwnd, IntPtr insertAfter,
                                            int x, int y, int cx, int cy, uint flags);

    [DllImport("user32.dll")]
    private static extern IntPtr GetWindow(IntPtr hwnd, uint command);

    [DllImport("user32.dll")]
    private static extern bool IsWindowVisible(IntPtr hwnd);

    private const int GWL_EXSTYLE      = -20;
    private const int GWLP_HWNDPARENT  = -8;
    private const uint GW_OWNER        = 4;
    private const long WS_EX_TOPMOST   = 0x8;

    private static readonly IntPtr HWND_NOTOPMOST = new IntPtr(-2);
    private const uint SWP_NOSIZE     = 0x1;
    private const uint SWP_NOMOVE     = 0x2;
    private const uint SWP_NOACTIVATE = 0x10;

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

    public static bool IsTopmost(IntPtr hwnd)
    {
        return (GetWindowLongPtrW(hwnd, GWL_EXSTYLE).ToInt64() & WS_EX_TOPMOST) != 0;
    }

    public static IntPtr OwnerOf(IntPtr hwnd)
    {
        return GetWindow(hwnd, GW_OWNER);
    }

    public static void Adopt(IntPtr panel, IntPtr owner)
    {
        // Order matters. Giving the window an owner first puts it in the
        // owner's z-order band; clearing topmost afterwards is what stops it
        // floating over other applications. Doing it the other way round lets
        // the owner's state reassert topmost.
        SetWindowLongPtrW(panel, GWLP_HWNDPARENT, owner);
        SetWindowPos(panel, HWND_NOTOPMOST, 0, 0, 0, 0,
                     SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
    }
}
'@

# Only ever consider windows belonging to Lightroom itself.
function Get-LightroomProcessIds {
    @(Get-Process -Name 'Lightroom' -ErrorAction SilentlyContinue |
        ForEach-Object { [uint32] $_.Id })
}

$deadline = (Get-Date).AddSeconds($TimeoutSeconds)

while ($true) {
    # @() again on assignment: PowerShell unrolls a single-element array on the
    # way out of a function, which would leave a bare uint32 here.
    $lightroomPids = @(Get-LightroomProcessIds)

    if ($lightroomPids.Count -gt 0) {
        $windows = @([InatWindows]::Visible() |
            Where-Object { $lightroomPids -contains $_.ProcessId })

        $panel = $windows |
            Where-Object { $_.ClassName -eq 'AgWinFrame' -and $_.Title -eq $Title } |
            Select-Object -First 1

        if ($null -ne $panel) {
            # Re-parent to the main window of the same process, never another's.
            $main = $windows |
                Where-Object { $_.ClassName -eq 'AgWinMainFrame' -and
                               $_.ProcessId -eq $panel.ProcessId } |
                Select-Object -First 1

            if ($null -ne $main) {
                $alreadyOwned = [InatWindows]::OwnerOf($panel.Handle) -eq $main.Handle
                if ($alreadyOwned -and -not [InatWindows]::IsTopmost($panel.Handle)) {
                    Write-Verbose 'Panel is already owned and not topmost.'
                    exit 0
                }

                [InatWindows]::Adopt($panel.Handle, $main.Handle)

                $stillTopmost = [InatWindows]::IsTopmost($panel.Handle)
                $owned        = [InatWindows]::OwnerOf($panel.Handle) -eq $main.Handle
                if ($owned -and -not $stillTopmost) { exit 0 }

                Write-Error ("Fix-up did not take: owned={0} topmost={1}" -f $owned, $stillTopmost)
                exit 2
            }
        }
    }

    if ((Get-Date) -ge $deadline) {
        Write-Error "No Lightroom window titled '$Title' appeared within $TimeoutSeconds seconds."
        exit 1
    }
    Start-Sleep -Milliseconds 250
}
