# Windows: can a normal process read the title of a window owned by another process?
# Only windows of the processes started by this script are read. Other windows are skipped
# by process id before their text is requested. Titles are never written to the log.
# No personal files or history are read. Test documents are generated in a temporary folder
# and removed at the end. Browsers run with a temporary profile.
param([switch]$Target, [switch]$AllowElevated)

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
        return Check(pid, delegate (string title) { return title == expected; });
    }

    public static string CompareContains(int pid, string token) {
        return Check(pid, delegate (string title) { return title.Contains(token); });
    }

    static string Check(int pid, Func<string, bool> isExpected) {
        bool sawTitle = false;
        bool matched = false;
        EnumWindows(delegate (IntPtr hwnd, IntPtr param) {
            uint owner;
            GetWindowThreadProcessId(hwnd, out owner);
            if (owner != (uint)pid || !IsWindowVisible(hwnd)) { return true; }
            StringBuilder text = new StringBuilder(512);
            if (GetWindowText(hwnd, text, 512) > 0) {
                sawTitle = true;
                if (isExpected(text.ToString())) { matched = true; }
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

    [StructLayout(LayoutKind.Sequential)]
    struct MouseInput { public int Dx; public int Dy; public uint Data; public uint Flags; public uint Time; public IntPtr Extra; }
    [StructLayout(LayoutKind.Sequential)]
    struct Input { public uint Type; public MouseInput Mouse; }
    [DllImport("user32.dll")] static extern uint SendInput(uint count, Input[] inputs, int size);

    static uint ReadLastInputTick() {
        LastInputInfo info = new LastInputInfo();
        info.Size = (uint)Marshal.SizeOf(info);
        GetLastInputInfo(ref info);
        return info.Time;
    }

    // A zero-distance mouse move: the pointer does not move.
    public static bool LastInputChangesAfterSyntheticInput() {
        uint before = ReadLastInputTick();
        Thread.Sleep(1100);
        Input[] inputs = new Input[1];
        inputs[0].Type = 0;
        inputs[0].Mouse.Flags = 1;
        SendInput(1, inputs, Marshal.SizeOf(typeof(Input)));
        Thread.Sleep(200);
        return ReadLastInputTick() != before;
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

function Test-Elevated {
    return ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

$elevated = Test-Elevated
if ($elevated -and -not $AllowElevated) {
    Write-Output 'title=not_run_elevated'
    Write-Output 'TITLE-CHECK-DONE'
    exit 1
}

function Find-FirstExisting([string[]]$Paths) {
    foreach ($path in $Paths) {
        if ($path -and (Test-Path -LiteralPath $path)) { return $path }
    }
    return $null
}

function Find-ExcelExecutable {
    foreach ($root in @('HKLM:', 'HKCU:')) {
        $key = Get-Item -LiteralPath "$root\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\excel.exe" -ErrorAction SilentlyContinue
        if ($key) {
            $path = $key.GetValue('')
            if ($path -and (Test-Path -LiteralPath $path)) { return $path }
        }
    }
    return $null
}

# With a marker, only processes whose command line contains it are selected, so a browser the
# owner already has open is neither read nor closed. Without a marker (Excel, which is skipped
# when already running), processes that did not exist before the launch are selected.
function Get-CheckedProcessIds([string]$ProcessName, [int[]]$Existing, [string]$CommandLineMarker) {
    if ($CommandLineMarker) {
        return @(Get-CimInstance Win32_Process -Filter "Name='$ProcessName.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -and $_.CommandLine.Contains($CommandLineMarker) } |
            ForEach-Object { [int]$_.ProcessId })
    }
    return @(Get-Process -Name $ProcessName -ErrorAction SilentlyContinue |
        Where-Object { $Existing -notcontains $_.Id } |
        ForEach-Object { $_.Id })
}

function Test-RealApplication([string]$ProcessName, [string]$Executable, [string[]]$Arguments, [string]$Token, [string]$CommandLineMarker) {
    if (-not $Executable) { return 'not_installed' }
    $existing = @(Get-Process -Name $ProcessName -ErrorAction SilentlyContinue | ForEach-Object { $_.Id })
    try {
        Start-Process -FilePath $Executable -ArgumentList $Arguments | Out-Null
    } catch {
        return 'start_failed'
    }
    $result = 'unreadable'
    $until = (Get-Date).AddSeconds(25)
    while ((Get-Date) -lt $until) {
        foreach ($processId in (Get-CheckedProcessIds $ProcessName $existing $CommandLineMarker)) {
            $checked = [TitleCheck]::CompareContains($processId, $Token)
            if ($checked -eq 'match') { $result = 'match' }
            elseif ($checked -eq 'mismatch' -and $result -ne 'match') { $result = 'mismatch' }
        }
        if ($result -eq 'match') { break }
        Start-Sleep -Milliseconds 500
    }
    foreach ($processId in (Get-CheckedProcessIds $ProcessName $existing $CommandLineMarker)) {
        $process = Get-Process -Id $processId -ErrorAction SilentlyContinue
        if ($process) { [void]$process.CloseMainWindow() }
    }
    Start-Sleep -Seconds 2
    foreach ($processId in (Get-CheckedProcessIds $ProcessName $existing $CommandLineMarker)) {
        Stop-Process -Id $processId -Force -ErrorAction SilentlyContinue
    }
    Start-Sleep -Seconds 1
    return $result
}

function New-TestSpreadsheet([string]$Path) {
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $main = 'http://schemas.openxmlformats.org/spreadsheetml/2006/main'
    $package = 'http://schemas.openxmlformats.org/package/2006'
    $officeRelationships = 'http://schemas.openxmlformats.org/officeDocument/2006/relationships'
    $parts = [ordered]@{
        '[Content_Types].xml' = "<?xml version=`"1.0`" encoding=`"UTF-8`"?><Types xmlns=`"$package/content-types`"><Default Extension=`"rels`" ContentType=`"application/vnd.openxmlformats-package.relationships+xml`"/><Default Extension=`"xml`" ContentType=`"application/xml`"/><Override PartName=`"/xl/workbook.xml`" ContentType=`"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml`"/><Override PartName=`"/xl/worksheets/sheet1.xml`" ContentType=`"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml`"/></Types>"
        '_rels/.rels' = "<?xml version=`"1.0`" encoding=`"UTF-8`"?><Relationships xmlns=`"$package/relationships`"><Relationship Id=`"rId1`" Type=`"$officeRelationships/officeDocument`" Target=`"xl/workbook.xml`"/></Relationships>"
        'xl/workbook.xml' = "<?xml version=`"1.0`" encoding=`"UTF-8`"?><workbook xmlns=`"$main`" xmlns:r=`"$officeRelationships`"><sheets><sheet name=`"Sheet1`" sheetId=`"1`" r:id=`"rId1`"/></sheets></workbook>"
        'xl/_rels/workbook.xml.rels' = "<?xml version=`"1.0`" encoding=`"UTF-8`"?><Relationships xmlns=`"$package/relationships`"><Relationship Id=`"rId1`" Type=`"$officeRelationships/worksheet`" Target=`"worksheets/sheet1.xml`"/></Relationships>"
        'xl/worksheets/sheet1.xml' = "<?xml version=`"1.0`" encoding=`"UTF-8`"?><worksheet xmlns=`"$main`"><sheetData/></worksheet>"
    }
    $archive = [System.IO.Compression.ZipFile]::Open($Path, [System.IO.Compression.ZipArchiveMode]::Create)
    foreach ($name in $parts.Keys) {
        $entry = $archive.CreateEntry($name)
        $writer = New-Object System.IO.StreamWriter($entry.Open(), (New-Object System.Text.UTF8Encoding($false)))
        $writer.Write($parts[$name])
        $writer.Dispose()
    }
    $archive.Dispose()
}

[TitleCheck]::StartCountingForeground()
$targetProcess = Start-Process powershell -PassThru -WindowStyle Hidden -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"", '-Target')
$noWindow = Start-Process powershell -PassThru -WindowStyle Hidden -ArgumentList @('-NoProfile', '-Command', 'Start-Sleep -Seconds 25')

$outcome = 'unreadable'
$deadline = (Get-Date).AddSeconds(20)
while ((Get-Date) -lt $deadline) {
    $outcome = [TitleCheck]::Compare($targetProcess.Id, $ExpectedTitle)
    if ($outcome -eq 'match') { break }
    Start-Sleep -Milliseconds 250
}
Start-Sleep -Seconds 5

$wrongTitle = [TitleCheck]::Compare($targetProcess.Id, 'title-check-wrong')
$windowless = [TitleCheck]::Compare($noWindow.Id, $ExpectedTitle)
$foreground = [TitleCheck]::StopCountingForeground()
$lastInput = [TitleCheck]::CanReadLastInput()
$lastInputChanges = [TitleCheck]::LastInputChangesAfterSyntheticInput()
$session = (Get-Process -Id $PID).SessionId

Stop-Process -Id $targetProcess.Id -Force -ErrorAction SilentlyContinue
Stop-Process -Id $noWindow.Id -Force -ErrorAction SilentlyContinue

$workFolder = Join-Path $env:TEMP 'title-check-7f3a'
New-Item -ItemType Directory -Path $workFolder -Force | Out-Null

$browserResults = @{}
foreach ($browser in @(
    @{ Key = 'chrome'; Process = 'chrome'; Paths = @("$env:ProgramFiles\Google\Chrome\Application\chrome.exe", "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe", "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe") },
    @{ Key = 'edge'; Process = 'msedge'; Paths = @("${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe", "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe") }
)) {
    $token = "title-check-7f3a-$($browser.Key)"
    $document = Join-Path $workFolder "$token.html"
    Set-Content -LiteralPath $document -Encoding Ascii -Value "<!doctype html><title>$token</title><p>test document</p>"
    $browserProfile = Join-Path $workFolder "$($browser.Key)-profile"
    $browserArguments = @("--user-data-dir=`"$browserProfile`"", '--no-first-run', '--no-default-browser-check', '--new-window', ([Uri]$document).AbsoluteUri)
    $browserResults[$browser.Key] = Test-RealApplication $browser.Process (Find-FirstExisting $browser.Paths) $browserArguments $token 'title-check-7f3a'
}

if (Get-Process -Name 'EXCEL' -ErrorAction SilentlyContinue) {
    # Excel may share a process with the owner's documents, so do not touch it while running.
    $excelResult = 'skipped_running'
} else {
    $excelToken = 'title-check-7f3a-excel'
    $spreadsheet = Join-Path $workFolder "$excelToken.xlsx"
    New-TestSpreadsheet $spreadsheet
    $excelResult = Test-RealApplication 'EXCEL' (Find-ExcelExecutable) @("`"$spreadsheet`"") $excelToken ''
}

Start-Sleep -Seconds 2
Remove-Item -LiteralPath $workFolder -Recurse -Force -ErrorAction SilentlyContinue

Write-Output "title=$outcome"
Write-Output "control_wrong_title=$wrongTitle"
Write-Output "control_process_without_window=$windowless"
Write-Output "foreground_events=$foreground"
Write-Output "last_input_readable=$lastInput"
Write-Output "last_input_changes_after_synthetic_input=$lastInputChanges"
Write-Output "chrome=$($browserResults['chrome'])"
Write-Output "edge=$($browserResults['edge'])"
Write-Output "excel=$excelResult"
Write-Output "session_id=$session"
Write-Output "interactive=$([Environment]::UserInteractive)"
Write-Output "elevated=$elevated"
Write-Output "os=$([Environment]::OSVersion.VersionString)"

Write-Output 'TITLE-CHECK-DONE'

if (-not $AllowElevated) { Remove-Item -LiteralPath $PSCommandPath -Force -ErrorAction SilentlyContinue }
if ($outcome -ne 'match') { exit 1 }
