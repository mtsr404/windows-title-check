# Windows: can a normal process read the title of a window owned by another process?
# Only windows of the processes started by this script are read. Other windows are skipped
# by process id before their text is requested. Titles are never written to the log.
param([switch]$Target)

$ExpectedTitle = 'title-check-7f3a'

if ($Target) {
    Add-Type -AssemblyName System.Windows.Forms
    $first = New-Object System.Windows.Forms.Form
    $first.Text = $ExpectedTitle
    $second = New-Object System.Windows.Forms.Form
    $second.Text = $ExpectedTitle
    $second.Show()
    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 1000
    $script:showFirst = $true
    $timer.add_Tick({
        if ($script:showFirst) { $first.Activate() } else { $second.Activate() }
        $script:showFirst = -not $script:showFirst
    })
    $timer.Start()
    $close = New-Object System.Windows.Forms.Timer
    $close.Interval = 30000
    $close.add_Tick({ [System.Windows.Forms.Application]::Exit() })
    $close.Start()
    $first.Show()
    [System.Windows.Forms.Application]::Run()
    exit 0
}

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

public static class TitleCheck {
    delegate bool EnumProc(IntPtr hwnd, IntPtr param);
    delegate void WinEventProc(IntPtr hook, uint eventType, IntPtr hwnd, int obj, int child, uint thread, uint time);

    [StructLayout(LayoutKind.Sequential)]
    struct LastInputInfo { public uint Size; public uint Time; }
    [StructLayout(LayoutKind.Sequential)]
    struct Msg { public IntPtr Hwnd; public uint Message; public IntPtr WParam; public IntPtr LParam; public uint Time; public int X; public int Y; }

    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc proc, IntPtr param);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr hwnd);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr hwnd, StringBuilder text, int max);
    [DllImport("user32.dll")] static extern bool GetLastInputInfo(ref LastInputInfo info);
    [DllImport("user32.dll")] static extern IntPtr SetWinEventHook(uint min, uint max, IntPtr module, WinEventProc proc, uint pid, uint thread, uint flags);
    [DllImport("user32.dll")] static extern bool UnhookWinEvent(IntPtr hook);
    [DllImport("user32.dll")] static extern bool PeekMessage(out Msg msg, IntPtr hwnd, uint min, uint max, uint remove);
    [DllImport("user32.dll")] static extern bool TranslateMessage(ref Msg msg);
    [DllImport("user32.dll")] static extern IntPtr DispatchMessage(ref Msg msg);

    const uint EventSystemForeground = 3;
    const uint WinEventOutOfContext = 0;

    static WinEventProc callback;
    static int foregroundEvents;
    static volatile bool counting;
    static Thread countingThread;

    public static string Compare(int pid, string expected) {
        bool sawTitle = false;
        bool matched = false;
        EnumWindows(delegate (IntPtr hwnd, IntPtr param) {
            uint owner;
            GetWindowThreadProcessId(hwnd, out owner);
            if (owner != (uint)pid || !IsWindowVisible(hwnd)) { return true; }
            StringBuilder text = new StringBuilder(512);
            if (GetWindowText(hwnd, text, 512) > 0) {
                sawTitle = true;
                if (text.ToString() == expected) { matched = true; }
            }
            return true;
        }, IntPtr.Zero);
        if (matched) { return "match"; }
        return sawTitle ? "mismatch" : "unreadable";
    }

    public static bool CanReadLastInput() {
        LastInputInfo info = new LastInputInfo();
        info.Size = (uint)Marshal.SizeOf(info);
        return GetLastInputInfo(ref info);
    }

    public static void StartCountingForeground() {
        counting = true;
        callback = delegate (IntPtr hook, uint eventType, IntPtr hwnd, int obj, int child, uint thread, uint time) {
            Interlocked.Increment(ref foregroundEvents);
        };
        countingThread = new Thread(delegate () {
            IntPtr hook = SetWinEventHook(EventSystemForeground, EventSystemForeground, IntPtr.Zero, callback, 0, 0, WinEventOutOfContext);
            Msg msg;
            while (counting) {
                while (PeekMessage(out msg, IntPtr.Zero, 0, 0, 1)) {
                    TranslateMessage(ref msg);
                    DispatchMessage(ref msg);
                }
                Thread.Sleep(20);
            }
            UnhookWinEvent(hook);
        });
        countingThread.Start();
    }

    public static int StopCountingForeground() {
        counting = false;
        countingThread.Join();
        return foregroundEvents;
    }
}
'@

[TitleCheck]::StartCountingForeground()
$target = Start-Process powershell -PassThru -WindowStyle Hidden -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath, '-Target')
$noWindow = Start-Process powershell -PassThru -WindowStyle Hidden -ArgumentList @('-NoProfile', '-Command', 'Start-Sleep -Seconds 25')

$outcome = 'unreadable'
$deadline = (Get-Date).AddSeconds(20)
while ((Get-Date) -lt $deadline) {
    $outcome = [TitleCheck]::Compare($target.Id, $ExpectedTitle)
    if ($outcome -eq 'match') { break }
    Start-Sleep -Milliseconds 250
}
Start-Sleep -Seconds 5

$wrongTitle = [TitleCheck]::Compare($target.Id, 'title-check-wrong')
$windowless = [TitleCheck]::Compare($noWindow.Id, $ExpectedTitle)
$foreground = [TitleCheck]::StopCountingForeground()
$lastInput = [TitleCheck]::CanReadLastInput()
$elevated = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$session = (Get-Process -Id $PID).SessionId

Stop-Process -Id $target.Id -Force -ErrorAction SilentlyContinue
Stop-Process -Id $noWindow.Id -Force -ErrorAction SilentlyContinue

Write-Output "title=$outcome"
Write-Output "control_wrong_title=$wrongTitle"
Write-Output "control_process_without_window=$windowless"
Write-Output "foreground_events=$foreground"
Write-Output "last_input_readable=$lastInput"
Write-Output "session_id=$session"
Write-Output "interactive=$([Environment]::UserInteractive)"
Write-Output "elevated=$elevated"
Write-Output "os=$([Environment]::OSVersion.VersionString)"

if ($outcome -ne 'match') { exit 1 }
