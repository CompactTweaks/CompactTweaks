<#
    Compact Tweaks  -  Stay Compact, Stay Fast.

    Run:  irm https://raw.githubusercontent.com/CompactTweaks/CompactTweaks/main/CompactTweaks.ps1 | iex

    Rules this tool follows
      1. Every change is snapshotted first, so Undo restores the exact previous state
         (and removes registry keys the tweak had to create).
      2. Nothing is deleted from the system except temp files and the Recycle Bin (marked one-time).
      3. A System Restore point is offered before every batch.
      4. Tweaks with weak or no evidence are labelled Unproven, kept out of Select recommended,
         and say why. High-risk ones ask for a second confirmation.

    Keep this file ASCII-only so Windows PowerShell 5.1 reads it correctly.
#>

$script:Version = '0.9.0'
$script:RawUrl  = 'https://raw.githubusercontent.com/CompactTweaks/CompactTweaks/main/CompactTweaks.ps1'

# ----------------------------------------------------------------------------
# Guards: Windows only, administrator, STA thread
# ----------------------------------------------------------------------------
if ($PSVersionTable.PSEdition -eq 'Core' -and -not $IsWindows) {
    Write-Host 'Compact Tweaks only runs on Windows.' -ForegroundColor Red
    return
}

$principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host 'Compact Tweaks needs administrator rights. Asking Windows to restart it elevated...' -ForegroundColor Yellow
    try {
        $exe = (Get-Process -Id $PID).Path
        if ($PSCommandPath) {
            $relaunch = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $PSCommandPath))
        } else {
            $relaunch = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', "irm '$($script:RawUrl)' | iex")
        }
        Start-Process -FilePath $exe -ArgumentList $relaunch -Verb RunAs
    } catch {
        Write-Host 'Elevation was cancelled or failed. Open PowerShell as administrator and run the command again.' -ForegroundColor Red
    }
    return
}

if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    Write-Host 'This needs an STA PowerShell window. Run it from a normal powershell.exe or pwsh.exe console.' -ForegroundColor Red
    return
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

# ----------------------------------------------------------------------------
# Native helpers: performance counters (language-neutral), memory, window title bar colours
# ----------------------------------------------------------------------------
$nativeSrc = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

namespace CT {
  public class PdhItem { public string Name; public double Value; }

  public class PdhQuery : IDisposable {
    [StructLayout(LayoutKind.Explicit, Size = 16)]
    struct CounterValue {
      [FieldOffset(0)] public uint Status;
      [FieldOffset(8)] public double Value;
    }
    [DllImport("pdh.dll", CharSet = CharSet.Unicode)] static extern uint PdhOpenQueryW(string source, IntPtr user, out IntPtr query);
    [DllImport("pdh.dll", CharSet = CharSet.Unicode)] static extern uint PdhAddEnglishCounterW(IntPtr query, string path, IntPtr user, out IntPtr counter);
    [DllImport("pdh.dll")] static extern uint PdhCollectQueryData(IntPtr query);
    [DllImport("pdh.dll")] static extern uint PdhGetFormattedCounterValue(IntPtr counter, uint format, IntPtr type, out CounterValue value);
    [DllImport("pdh.dll", CharSet = CharSet.Unicode)] static extern uint PdhGetFormattedCounterArrayW(IntPtr counter, uint format, ref uint size, out uint count, IntPtr buffer);
    [DllImport("pdh.dll")] static extern uint PdhCloseQuery(IntPtr query);

    const uint FmtDouble = 0x200, FmtNoCap100 = 0x8000, MoreData = 0x800007D2;
    IntPtr query = IntPtr.Zero;
    Dictionary<string, IntPtr> counters = new Dictionary<string, IntPtr>(StringComparer.OrdinalIgnoreCase);

    public PdhQuery() {
      uint rc = PdhOpenQueryW(null, IntPtr.Zero, out query);
      if (rc != 0) throw new InvalidOperationException("Performance counters are not available (0x" + rc.ToString("X8") + ")");
    }
    public bool Add(string key, string englishPath) {
      IntPtr h;
      uint rc = PdhAddEnglishCounterW(query, englishPath, IntPtr.Zero, out h);
      if (rc != 0) return false;
      counters[key] = h;
      return true;
    }
    public bool Collect() { return PdhCollectQueryData(query) == 0; }
    public double Value(string key, bool noCap) {
      IntPtr h;
      if (!counters.TryGetValue(key, out h)) return double.NaN;
      CounterValue v;
      uint fmt = FmtDouble | (noCap ? FmtNoCap100 : 0u);
      if (PdhGetFormattedCounterValue(h, fmt, IntPtr.Zero, out v) != 0) return double.NaN;
      if (v.Status != 0 && v.Status != 1) return double.NaN;
      return v.Value;
    }
    public List<PdhItem> Items(string key, bool noCap) {
      List<PdhItem> list = new List<PdhItem>();
      IntPtr h;
      if (!counters.TryGetValue(key, out h)) return list;
      if (IntPtr.Size != 8) return list;
      uint fmt = FmtDouble | (noCap ? FmtNoCap100 : 0u);
      uint size = 0, count = 0;
      uint rc = PdhGetFormattedCounterArrayW(h, fmt, ref size, out count, IntPtr.Zero);
      if (rc != MoreData || size == 0) return list;
      IntPtr buf = Marshal.AllocHGlobal((int)size);
      try {
        rc = PdhGetFormattedCounterArrayW(h, fmt, ref size, out count, buf);
        if (rc != 0) return list;
        for (int i = 0; i < count; i++) {
          IntPtr item = new IntPtr(buf.ToInt64() + (long)i * 24);
          IntPtr namePtr = Marshal.ReadIntPtr(item, 0);
          uint status = (uint)Marshal.ReadInt32(item, 8);
          double val = BitConverter.Int64BitsToDouble(Marshal.ReadInt64(item, 16));
          PdhItem it = new PdhItem();
          it.Name = namePtr == IntPtr.Zero ? "" : Marshal.PtrToStringUni(namePtr);
          it.Value = (status == 0 || status == 1) ? val : double.NaN;
          list.Add(it);
        }
      } finally { Marshal.FreeHGlobal(buf); }
      return list;
    }
    public void Dispose() {
      if (query != IntPtr.Zero) { PdhCloseQuery(query); query = IntPtr.Zero; }
    }
  }

  public static class Sys {
    [StructLayout(LayoutKind.Sequential)]
    public class MemStatus {
      public uint Length = 64;
      public uint Load;
      public ulong TotalPhys;
      public ulong AvailPhys;
      public ulong TotalPageFile;
      public ulong AvailPageFile;
      public ulong TotalVirtual;
      public ulong AvailVirtual;
      public ulong AvailExtVirtual;
    }
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool GlobalMemoryStatusEx([In, Out] MemStatus s);
    public static MemStatus Memory() {
      MemStatus m = new MemStatus();
      return GlobalMemoryStatusEx(m) ? m : null;
    }
    [DllImport("dwmapi.dll")] static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);
    public static int SetDwm(IntPtr hwnd, int attr, int value) { return DwmSetWindowAttribute(hwnd, attr, ref value, 4); }

    [DllImport("ntdll.dll")] static extern int NtSetSystemInformation(int infoClass, ref int info, int length);
    public static bool PurgeStandbyList() {
        // SystemMemoryListInformation = 80, MemoryPurgeStandbyList = 4 (matches RAMMap / EmptyStandbyList).
        int cmd = 4;
        int status = NtSetSystemInformation(80, ref cmd, 4);
        return status == 0;
    }
  }
}
'@
$script:NativeOk = $true
if (-not ('CT.PdhQuery' -as [type])) {
    try { Add-Type -TypeDefinition $nativeSrc -ErrorAction Stop } catch { $script:NativeOk = $false; $script:NativeError = $_.Exception.Message }
}

# ----------------------------------------------------------------------------
# Paths, logging, state
# ----------------------------------------------------------------------------
$script:DataDir   = Join-Path $env:ProgramData 'CompactTweaks'
$script:StateFile = Join-Path $script:DataDir 'state.json'
$script:LogFile   = Join-Path $script:DataDir 'compacttweaks.log'
if (-not (Test-Path -LiteralPath $script:DataDir)) { New-Item -ItemType Directory -Path $script:DataDir -Force | Out-Null }

$script:Window      = $null
$script:Ui          = @{}
$script:Rows        = @{}
$script:States      = @{}
$script:Pages       = @{}
$script:NavButtons  = @{}
$script:NavIndex    = @{}
$script:NeedRestart = $false
$script:CurrentTab  = 'home'

function Update-UI {
    if ($script:Window) {
        $script:Window.Dispatcher.Invoke([Action]{}, [System.Windows.Threading.DispatcherPriority]::Background)
    }
}

function Write-Log {
    param([string]$Message, [ValidateSet('Info', 'Ok', 'Warn', 'Error')][string]$Level = 'Info')
    $line = '{0}  [{1}] {2}' -f (Get-Date -Format 'HH:mm:ss'), $Level.ToUpper(), $Message
    try { Add-Content -LiteralPath $script:LogFile -Value $line -Encoding UTF8 } catch { }
    if ($script:Ui.LogBox) {
        $script:Ui.LogBox.AppendText($line + "`r`n")
        $script:Ui.LogBox.ScrollToEnd()
        Update-UI
    }
}

function Import-State {
    $s = @{}
    if (Test-Path -LiteralPath $script:StateFile) {
        try {
            $o = Get-Content -LiteralPath $script:StateFile -Raw | ConvertFrom-Json
            foreach ($p in $o.PSObject.Properties) { $s[$p.Name] = $p.Value }
        } catch {
            Write-Log 'The saved undo file could not be read; undo data from earlier sessions is unavailable.' 'Warn'
        }
    }
    return $s
}

function Save-State {
    $script:State | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $script:StateFile -Encoding UTF8
}

$script:State = Import-State

# ----------------------------------------------------------------------------
# Registry / service / network / power helpers
# ----------------------------------------------------------------------------
function Get-WinBuild {
    try { return [int](Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop).CurrentBuildNumber }
    catch { return 0 }
}

function New-RegEntry {
    param([string]$Path, [string]$Name, [string]$Type, $Value)
    return @{ Path = $Path; Name = $Name; Type = $Type; Value = $Value }
}

function Get-FirstMissingKey {
    param([string]$Path)
    $missing = $null
    $cur = $Path
    while ($cur -and -not (Test-Path -LiteralPath $cur)) {
        $missing = $cur
        $cur = Split-Path -Path $cur -Parent
    }
    return $missing
}

function Remove-EmptyKeysUpTo {
    param([string]$From, [string]$Stop)
    $cur = $From
    while ($cur) {
        $k = Get-Item -LiteralPath $cur -ErrorAction SilentlyContinue
        if (-not $k) {
            if ($cur -eq $Stop) { break }
            $cur = Split-Path -Path $cur -Parent
            continue
        }
        if ($k.ValueCount -ne 0 -or $k.SubKeyCount -ne 0) { break }
        Remove-Item -LiteralPath $cur -Force -ErrorAction SilentlyContinue
        if ($cur -eq $Stop) { break }
        $cur = Split-Path -Path $cur -Parent
    }
}

function Get-RegSnapshot {
    param([string]$Path, [string]$Name)
    $snap = @{ Path = $Path; Name = $Name; Existed = $false; Kind = $null; Value = $null; FirstMissing = (Get-FirstMissingKey $Path) }
    try {
        $key = Get-Item -LiteralPath $Path -ErrorAction Stop
        if ($key.GetValueNames() -contains $Name) {
            $snap.Existed = $true
            $snap.Kind    = [string]$key.GetValueKind($Name)
            $snap.Value   = $key.GetValue($Name, $null, 'DoNotExpandEnvironmentNames')
        }
    } catch { }
    return $snap
}

function Set-RegValue {
    param([string]$Path, [string]$Name, [string]$Type, $Value)
    if (-not (Test-Path -LiteralPath $Path)) { New-Item -Path $Path -Force | Out-Null }
    if ($Type -eq 'DWord') { $Value = [int]$Value }
    New-ItemProperty -LiteralPath $Path -Name $Name -Value $Value -PropertyType $Type -Force | Out-Null
}

function Restore-RegSnapshot {
    param($Snap)
    if ($Snap.Existed) {
        Set-RegValue -Path $Snap.Path -Name $Snap.Name -Type $Snap.Kind -Value $Snap.Value
    } else {
        Remove-ItemProperty -LiteralPath $Snap.Path -Name $Snap.Name -ErrorAction SilentlyContinue
        if ($Snap.FirstMissing) { Remove-EmptyKeysUpTo -From $Snap.Path -Stop $Snap.FirstMissing }
    }
}

function Get-SvcSnapshot {
    param([string]$Name)
    $s = Get-CimInstance Win32_Service -Filter "Name='$Name'" -ErrorAction SilentlyContinue
    if (-not $s) { return @{ Name = $Name; Exists = $false } }
    return @{
        Name       = $Name
        Exists     = $true
        Mode       = [string]$s.StartMode
        Delayed    = [bool]$s.DelayedAutoStart
        WasRunning = ($s.State -eq 'Running')
    }
}

function Set-SvcStart {
    param([string]$Name, [string]$Mode, [bool]$Delayed = $false)
    switch ($Mode) {
        'Auto'     { if ($Delayed) { $val = 'delayed-auto' } else { $val = 'auto' } }
        'Manual'   { $val = 'demand' }
        'Disabled' { $val = 'disabled' }
        default    { throw "Unknown service start mode '$Mode'" }
    }
    & sc.exe config $Name start= $val | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "sc.exe could not set $Name to $val (exit $LASTEXITCODE)" }
}

function Get-ActiveSchemeGuid {
    $out = (& powercfg.exe /getactivescheme 2>&1 | Out-String)
    if ($out -match '([0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12})') { return $Matches[1] }
    return $null
}

function Get-ActiveTcpInterfaceKeys {
    $base = 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces'
    $out = @()
    foreach ($k in @(Get-ChildItem -LiteralPath $base -ErrorAction SilentlyContinue)) {
        $p = Get-ItemProperty -LiteralPath $k.PSPath -ErrorAction SilentlyContinue
        if (-not $p) { continue }
        $ips = @(@($p.IPAddress) + @($p.DhcpIPAddress) | Where-Object { $_ -and $_ -ne '0.0.0.0' })
        if ($ips.Count -gt 0) { $out += ($k.Name -replace '^HKEY_LOCAL_MACHINE', 'HKLM:') }
    }
    return $out
}

function New-RestorePoint {
    Write-Log 'Creating a restore point (this can take a few seconds)...'
    Update-UI
    try {
        $cmd = "Enable-ComputerRestore -Drive '$env:SystemDrive\' -ErrorAction SilentlyContinue; " +
               "Checkpoint-Computer -Description 'Compact Tweaks' -RestorePointType MODIFY_SETTINGS -ErrorAction Stop"
        $out = (& powershell.exe -NoProfile -ExecutionPolicy Bypass -Command $cmd 2>&1 | Out-String).Trim()
        if ($LASTEXITCODE -eq 0) {
            if ($out) {
                Write-Log ('Restore point step finished. Windows said: ' + $out) 'Warn'
                Write-Log 'Windows normally allows only one restore point per 24 hours, so it may have skipped a new one.'
            } else {
                Write-Log 'Restore point created.' 'Ok'
            }
            return $true
        }
        Write-Log ('Restore point was NOT created: ' + $out) 'Warn'
    } catch {
        Write-Log ('Restore point failed: ' + $_.Exception.Message) 'Warn'
    }
    return $false
}

function Get-NativeResolution {
    # True pixel size of the primary display (WMI reports real pixels, WPF would report scaled units).
    try {
        foreach ($v in @(Get-CimInstance Win32_VideoController -ErrorAction Stop)) {
            if ($v.CurrentHorizontalResolution -and $v.CurrentVerticalResolution) {
                return @{ W = [int]$v.CurrentHorizontalResolution; H = [int]$v.CurrentVerticalResolution }
            }
        }
    } catch { }
    return @{ W = 1920; H = 1080 }
}

# ----------------------------------------------------------------------------
# Text / INI helpers (used by the Fortnite tweaks)
# ----------------------------------------------------------------------------
function Read-TextFile {
    param([string]$Path)
    $bytes = [IO.File]::ReadAllBytes($Path)
    $bom = $null
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        $bom = 'utf8'; $text = [Text.Encoding]::UTF8.GetString($bytes, 3, $bytes.Length - 3)
    } elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) {
        $bom = 'utf16le'; $text = [Text.Encoding]::Unicode.GetString($bytes, 2, $bytes.Length - 2)
    } elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF) {
        $bom = 'utf16be'; $text = [Text.Encoding]::BigEndianUnicode.GetString($bytes, 2, $bytes.Length - 2)
    } else {
        $text = (New-Object System.Text.UTF8Encoding($false)).GetString($bytes)
    }
    if ($text.Contains("`r`n")) { $nl = "`r`n" } elseif ($text.Contains("`n")) { $nl = "`n" } else { $nl = "`r`n" }
    return @{ Text = $text; Bom = $bom; NewLine = $nl }
}

function Write-TextFile {
    param([string]$Path, [string]$Text, [string]$Bom)
    switch ($Bom) {
        'utf8'    { $enc = New-Object System.Text.UTF8Encoding($true) }
        'utf16le' { $enc = New-Object System.Text.UnicodeEncoding($false, $true) }
        'utf16be' { $enc = New-Object System.Text.UnicodeEncoding($true, $true) }
        default   { $enc = New-Object System.Text.UTF8Encoding($false) }
    }
    $body = $enc.GetBytes($Text)
    $pre = $enc.GetPreamble()
    $all = New-Object 'byte[]' ($pre.Length + $body.Length)
    [Array]::Copy($pre, 0, $all, 0, $pre.Length)
    [Array]::Copy($body, 0, $all, $pre.Length, $body.Length)
    [IO.File]::WriteAllBytes($Path, $all)
}

function ConvertTo-IniLines {
    param([string]$Text)
    return [System.Collections.Generic.List[string]]([string[]]($Text -split "\r?\n"))
}

function Get-IniValue {
    param($Lines, [string]$Section, [string]$Key)
    $cur = ''
    $val = $null
    foreach ($line in $Lines) {
        $sm = [regex]::Match($line, '^\s*\[(.+?)\]\s*$')
        if ($sm.Success) { $cur = $sm.Groups[1].Value; continue }
        if ($cur -ne $Section) { continue }
        $km = [regex]::Match($line, '^\s*([^=;\[\s][^=]*?)\s*=\s*(.*?)\s*$')
        if ($km.Success -and $km.Groups[1].Value -ieq $Key) { $val = $km.Groups[2].Value }
    }
    return $val
}

function Set-IniKey {
    # Key-level merge. Sets every occurrence (Unreal keeps the last duplicate). Returns Status/Old.
    param([System.Collections.Generic.List[string]]$Lines, [string]$Section, [string]$Key, [string]$Value, [switch]$AddIfMissing, [switch]$AnySection)
    $cur = ''
    $found = $false
    $changed = $false
    $old = $null
    $lastInSection = -1
    $sectionSeen = $false
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        $line = $Lines[$i]
        $sm = [regex]::Match($line, '^\s*\[(.+?)\]\s*$')
        if ($sm.Success) {
            $cur = $sm.Groups[1].Value
            if ($cur -eq $Section) { $sectionSeen = $true; $lastInSection = $i }
            continue
        }
        if ($cur -eq $Section -and $line.Trim().Length -gt 0) { $lastInSection = $i }
        $km = [regex]::Match($line, '^\s*([^=;\[\s][^=]*?)\s*=\s*(.*?)\s*$')
        if ($km.Success -and $km.Groups[1].Value -ieq $Key -and ($AnySection -or $cur -eq $Section)) {
            $found = $true
            if ($null -eq $old) { $old = $km.Groups[2].Value }
            if ($km.Groups[2].Value -cne $Value) {
                $Lines[$i] = $km.Groups[1].Value + '=' + $Value
                $changed = $true
            }
        }
    }
    if ($found) {
        if ($changed) { return @{ Status = 'changed'; Old = $old } }
        return @{ Status = 'same'; Old = $old }
    }
    if (-not $AddIfMissing) { return @{ Status = 'missing'; Old = $null } }
    if ($sectionSeen) {
        $Lines.Insert($lastInSection + 1, ($Key + '=' + $Value))
    } else {
        if ($Lines.Count -gt 0 -and $Lines[$Lines.Count - 1].Trim().Length -gt 0) { $Lines.Add('') }
        $Lines.Add('[' + $Section + ']')
        $Lines.Add($Key + '=' + $Value)
    }
    return @{ Status = 'added'; Old = $null }
}

function Remove-IniKey {
    param([System.Collections.Generic.List[string]]$Lines, [string]$Section, [string]$Key)
    $cur = ''
    $out = New-Object 'System.Collections.Generic.List[string]'
    foreach ($line in $Lines) {
        $sm = [regex]::Match($line, '^\s*\[(.+?)\]\s*$')
        if ($sm.Success) { $cur = $sm.Groups[1].Value; $out.Add($line); continue }
        $km = [regex]::Match($line, '^\s*([^=;\[\s][^=]*?)\s*=')
        if ($cur -eq $Section -and $km.Success -and $km.Groups[1].Value -ieq $Key) { continue }
        $out.Add($line)
    }
    $Lines.Clear()
    foreach ($l in $out) { $Lines.Add($l) }
}

function Find-IniKeys {
    # Every key (any section) whose name matches the regex.
    param($Lines, [string]$Pattern)
    $cur = ''
    $res = @()
    foreach ($line in $Lines) {
        $sm = [regex]::Match($line, '^\s*\[(.+?)\]\s*$')
        if ($sm.Success) { $cur = $sm.Groups[1].Value; continue }
        $km = [regex]::Match($line, '^\s*([^=;\[\s][^=]*?)\s*=\s*(.*?)\s*$')
        if ($km.Success -and $km.Groups[1].Value -match $Pattern) {
            $res += @{ Section = $cur; Key = $km.Groups[1].Value; Value = $km.Groups[2].Value }
        }
    }
    return $res
}

function Backup-FileSafe {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $orig = $Path + '.compacttweaks.original'
    if (-not (Test-Path -LiteralPath $orig)) { Copy-Item -LiteralPath $Path -Destination $orig -Force }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $bak = $Path + '.compacttweaks.bak-' + $stamp
    Copy-Item -LiteralPath $Path -Destination $bak -Force
    Write-Log ('Backup written: ' + $bak)
    $dir = Split-Path -Path $Path -Parent
    $leaf = Split-Path -Path $Path -Leaf
    $old = @(Get-ChildItem -LiteralPath $dir -Filter ($leaf + '.compacttweaks.bak-*') -File -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -Skip 5)
    foreach ($f in $old) { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue }
    return $bak
}

function Save-IniLines {
    param([string]$Path, $Lines, $FileInfo)
    $text = ($Lines -join $FileInfo.NewLine)
    $attr = [IO.File]::GetAttributes($Path)
    $wasRo = (($attr -band [IO.FileAttributes]::ReadOnly) -ne 0)
    if ($wasRo) { [IO.File]::SetAttributes($Path, ($attr -band (-bnot [IO.FileAttributes]::ReadOnly))) }
    try { Write-TextFile -Path $Path -Text $text -Bom $FileInfo.Bom }
    finally { if ($wasRo) { [IO.File]::SetAttributes($Path, $attr) } }
}

# ----------------------------------------------------------------------------
# Epic launcher + Fortnite helpers
# ----------------------------------------------------------------------------
$script:FnItemId = '4fe75bbc5a674f4f9b356b5c90567da5'

function Get-EpicLauncherIni {
    $cfg = Join-Path $env:LOCALAPPDATA 'EpicGamesLauncher\Saved\Config'
    $c = @((Join-Path $cfg 'WindowsEditor\GameUserSettings.ini'), (Join-Path $cfg 'Windows\GameUserSettings.ini')) | Where-Object { Test-Path -LiteralPath $_ }
    if (-not $c) { return $null }
    return [string](@($c | Sort-Object { (Get-Item -LiteralPath $_).LastWriteTime } -Descending)[0])
}

function Get-EpicAccountId {
    param([string]$IniText)
    try {
        $id = (Get-ItemProperty -LiteralPath 'HKCU:\Software\Epic Games\Unreal Engine\Identifiers' -Name AccountId -ErrorAction Stop).AccountId
        if ($id) { return [string]$id }
    } catch { }
    if ($IniText) {
        $m = [regex]::Match($IniText, '(?m)^\[([0-9a-fA-F]{32})_(Settings|General)\]')
        if ($m.Success) { return $m.Groups[1].Value }
    }
    return $null
}

function Get-FortniteArgPrefix {
    param([string]$IniText)
    $m = [regex]::Match($IniText, '(?im)^(fn:[0-9a-f]{32}:Fortnite)_AdditionalCommands')
    if ($m.Success) { return $m.Groups[1].Value }
    return ('fn:' + $script:FnItemId + ':Fortnite')
}

function Get-FnFlagToken {
    param([string]$Flag)
    switch ($Flag) {
        'NOSPLASH'    { return @('-NOSPLASH') }
        'HIGH_D3D11'  { return @('-high', '-d3d11') }
        'FEATURELEVEL' { return @('-FeatureLevelES31') }
        default { return @() }
    }
}

function Get-FnFlagState {
    # Reads which of the three launch-argument flags are currently on, from the raw token string.
    param([string]$CmdLine)
    $t = " $CmdLine "
    return @{
        NOSPLASH     = [bool]($t -match '(?i)\s-NOSPLASH\s')
        HIGH_D3D11   = [bool]($t -match '(?i)\s-high\s' -and $t -match '(?i)\s-d3d11\s')
        FEATURELEVEL = [bool]($t -match '(?i)\s-FeatureLevelES31\s')
    }
}

function Build-FnCommandLine {
    # Always the same fixed order, regardless of which flag was toggled last: -NOSPLASH -high -d3d11 -FeatureLevelES31
    param($State, [string]$ExistingCmd)
    $known = @()
    foreach ($f in @('NOSPLASH', 'HIGH_D3D11', 'FEATURELEVEL')) { $known += (Get-FnFlagToken $f) }
    $extra = @()
    if ($ExistingCmd) {
        foreach ($tok in @($ExistingCmd -split '\s+' | Where-Object { $_ })) {
            if (-not @($known | Where-Object { $_ -ieq $tok })) { $extra += $tok }
        }
    }
    $out = @()
    if ($State.NOSPLASH)     { $out += (Get-FnFlagToken 'NOSPLASH') }
    if ($State.HIGH_D3D11)   { $out += (Get-FnFlagToken 'HIGH_D3D11') }
    if ($State.FEATURELEVEL) { $out += (Get-FnFlagToken 'FEATURELEVEL') }
    return (($out + $extra) -join ' ').Trim()
}

function Set-FnLaunchArg {
    # Turns one flag on or off while keeping the other two flags and any of the user's own
    # arguments untouched, and always rewrites the line in the fixed order above.
    param([string]$Flag, [bool]$On)
    $ini = Get-EpicLauncherIni
    if (-not $ini) { throw 'The Epic Games Launcher settings file was not found. Open the launcher once, signed in, then try again.' }
    $wasOpen = Stop-EpicLauncher
    try {
        $f = Read-TextFile $ini
        $acct = Get-EpicAccountId $f.Text
        if (-not $acct) { throw 'Could not read your Epic account id. Open the Epic Games Launcher once and try again.' }
        $sec = $acct + '_Settings'
        $prefix = Get-FortniteArgPrefix $f.Text
        $lines = ConvertTo-IniLines $f.Text
        $prevCmd = Get-IniValue $lines $sec ($prefix + '_AdditionalCommands')
        $prevEn  = Get-IniValue $lines $sec ($prefix + '_AdditionalCommandsEnabled')
        $state = Get-FnFlagState ([string]$prevCmd)
        $state[$Flag] = $On
        $newCmd = Build-FnCommandLine $state ([string]$prevCmd)
        [void](Backup-FileSafe $ini)
        [void](Set-IniKey -Lines $lines -Section $sec -Key ($prefix + '_AdditionalCommands') -Value $newCmd -AddIfMissing)
        [void](Set-IniKey -Lines $lines -Section $sec -Key ($prefix + '_AdditionalCommandsEnabled') -Value 'True' -AddIfMissing)
        Save-IniLines $ini $lines $f
        Write-Log ('Fortnite launch arguments now: ' + $newCmd) 'Ok'
        return @{ File = $ini; Section = $sec; Prefix = $prefix; PrevCmd = $prevCmd; PrevEnabled = $prevEn }
    } finally {
        if ($wasOpen) { Start-EpicLauncher }
    }
}

function Test-FnLaunchArg {
    param([string]$Flag)
    $ini = Get-EpicLauncherIni
    if (-not $ini) { return $false }
    $f = Read-TextFile $ini
    $acct = Get-EpicAccountId $f.Text
    if (-not $acct) { return $false }
    $lines = ConvertTo-IniLines $f.Text
    $prefix = Get-FortniteArgPrefix $f.Text
    $cmd = Get-IniValue $lines ($acct + '_Settings') ($prefix + '_AdditionalCommands')
    $en  = Get-IniValue $lines ($acct + '_Settings') ($prefix + '_AdditionalCommandsEnabled')
    if (-not $en -or $en -ine 'True') { return $false }
    $st = Get-FnFlagState ([string]$cmd)
    return [bool]$st[$Flag]
}

function Stop-EpicLauncher {
    # Returns $true when the main launcher was open, so the caller can start it again afterwards.
    $names = @('EpicGamesLauncher', 'EpicWebHelper', 'EpicOnlineServicesUserHelper')
    $wasOpen = [bool](Get-Process -Name 'EpicGamesLauncher' -ErrorAction SilentlyContinue)
    $running = @(Get-Process -Name $names -ErrorAction SilentlyContinue)
    if ($running.Count -eq 0) { return $false }
    Write-Log 'Closing the Epic Games Launcher (it rewrites its settings file when it exits)'
    $running | Stop-Process -Force -ErrorAction SilentlyContinue
    $deadline = (Get-Date).AddSeconds(15)
    while ((Get-Date) -lt $deadline -and (Get-Process -Name $names -ErrorAction SilentlyContinue)) { Start-Sleep -Milliseconds 300 }
    if (Get-Process -Name $names -ErrorAction SilentlyContinue) {
        throw 'The Epic Games Launcher is still running after 15 seconds. Close it yourself (tray icon, Exit) and try again, otherwise it would overwrite the change.'
    }
    Start-Sleep -Milliseconds 800
    return $wasOpen
}

function Start-EpicLauncher {
    # Started through explorer.exe so the launcher (and every game launched from it) keeps normal rights,
    # not this tool's administrator token.
    foreach ($exe in @("${env:ProgramFiles(x86)}\Epic Games\Launcher\Portal\Binaries\Win64\EpicGamesLauncher.exe", "${env:ProgramFiles(x86)}\Epic Games\Launcher\Portal\Binaries\Win32\EpicGamesLauncher.exe")) {
        if (Test-Path -LiteralPath $exe) {
            try {
                Start-Process -FilePath 'explorer.exe' -ArgumentList ('"' + $exe + '"') -ErrorAction Stop
                Write-Log 'Epic Games Launcher started again (with normal user rights)'
            } catch { Write-Log ('Could not restart the Epic Games Launcher: ' + $_.Exception.Message + '. Start it yourself.') 'Warn' }
            return
        }
    }
    Write-Log 'Epic Games Launcher executable not found; start it yourself' 'Warn'
}

function Get-FortniteGameIni {
    return (Join-Path $env:LOCALAPPDATA 'FortniteGame\Saved\Config\WindowsClient\GameUserSettings.ini')
}

function Invoke-IniSet {
    param($Lines, $Changes, [string]$Section, [string]$Key, [string]$Value, [bool]$Add = $true, [bool]$Any = $false)
    $r = Set-IniKey -Lines $Lines -Section $Section -Key $Key -Value $Value -AddIfMissing:$Add -AnySection:$Any
    switch ($r.Status) {
        'changed' { [void]$Changes.Add(('{0} = {1}    (was {2})' -f $Key, $Value, $r.Old)) }
        'added'   { [void]$Changes.Add(('{0} = {1}    (added)' -f $Key, $Value)) }
        'same'    { [void]$Changes.Add(('{0} = {1}    (already set)' -f $Key, $Value)) }
        'missing' { [void]$Changes.Add(('{0}    (not in your file, skipped)' -f $Key)) }
    }
}

function Get-FortniteIniPlan {
    # Builds the edited lines and a human-readable change list. Writes nothing.
    param([string]$Text, $Opt)
    $lines = ConvertTo-IniLines $Text
    $changes = New-Object 'System.Collections.Generic.List[string]'
    $sec = '/Script/FortniteGame.FortGameUserSettings'

    foreach ($k in @('ResolutionSizeX', 'LastUserConfirmedResolutionSizeX', 'DesiredScreenWidth', 'LastUserConfirmedDesiredScreenWidth')) {
        Invoke-IniSet $lines $changes $sec $k ([string]$Opt.Width)
    }
    foreach ($k in @('ResolutionSizeY', 'LastUserConfirmedResolutionSizeY', 'DesiredScreenHeight', 'LastUserConfirmedDesiredScreenHeight')) {
        Invoke-IniSet $lines $changes $sec $k ([string]$Opt.Height)
    }
    Invoke-IniSet $lines $changes $sec 'FrameRateLimit' ('{0}.000000' -f [int]$Opt.Fps)
    Invoke-IniSet $lines $changes $sec 'bUseVSync' 'False'
    if ($Opt.LobbyFps) { Invoke-IniSet $lines $changes $sec 'FrontendFrameRateLimit' '120.000000' }

    if ($Opt.LowGraphics) {
        $view = '0'
        if ($Opt.KeepView) { $view = '3' }
        Invoke-IniSet $lines $changes 'ScalabilityGroups' 'sg.ResolutionQuality' '100.000000' $true $true
        Invoke-IniSet $lines $changes 'ScalabilityGroups' 'sg.ViewDistanceQuality' $view $true $true
        foreach ($q in @('AntiAliasing', 'Shadow', 'GlobalIllumination', 'Reflection', 'PostProcess', 'Texture', 'Effects', 'Foliage', 'Shading')) {
            Invoke-IniSet $lines $changes 'ScalabilityGroups' ('sg.' + $q + 'Quality') '0' $true $true
        }
        Invoke-IniSet $lines $changes $sec 'bMotionBlur' 'False' $false $true
    }
    if ($Opt.NoReplays) {
        foreach ($m in @(Find-IniKeys $lines 'Replay')) {
            if ($m.Value -notmatch '^(?i:true|false)$') { continue }
            if ($m.Key -match 'Disable') { $v = 'True' } elseif ($m.Key -match 'Record|Enable|Allow|Auto|Save|Use') { $v = 'False' } else { continue }
            Invoke-IniSet $lines $changes $m.Section $m.Key $v $false $false
        }
        if (@(Find-IniKeys $lines 'Replay').Count -eq 0) { [void]$changes.Add('Replays    (no replay setting found in your file, skipped)') }
    }
    if ($Opt.NoSleep) {
        $found = 0
        foreach ($m in @(Find-IniKeys $lines 'Sleep')) {
            if ($m.Value -match '^(?i:true|false)$') {
                if ($m.Key -match 'Disable') { $v = 'True' } else { $v = 'False' }
            } elseif ($m.Value -match '^-?[0-9.]+$') { $v = '0' } else { continue }
            $found++
            Invoke-IniSet $lines $changes $m.Section $m.Key $v $false $false
        }
        if ($found -eq 0) { [void]$changes.Add('Sleep timer    (no sleep setting found in your file, skipped)') }
    }
    if ($Opt.Hud75) {
        $hud = @(Find-IniKeys $lines '^HUDScale$')
        if ($hud.Count -gt 0) {
            foreach ($m in $hud) { Invoke-IniSet $lines $changes $m.Section $m.Key '0.690000' $false $false }
        } else {
            Invoke-IniSet $lines $changes $sec 'HUDScale' '0.690000'
            [void]$changes.Add('Note: HUDScale was not in your file. It was added, but if the HUD size does not change, send me your file so I can match the exact key.')
        }
    }
    return @{ Lines = $lines; Changes = $changes }
}

# ----------------------------------------------------------------------------
# Process lists for "lower background priority"
# ----------------------------------------------------------------------------
$script:NeverLower = @(
    'System', 'Idle', 'Registry', 'smss', 'csrss', 'wininit', 'winlogon', 'services', 'lsass', 'svchost', 'dwm', 'fontdrvhost',
    'sihost', 'taskhostw', 'RuntimeBroker', 'ctfmon', 'explorer', 'ShellExperienceHost', 'StartMenuExperienceHost', 'SearchHost',
    'SearchApp', 'TextInputHost', 'ApplicationFrameHost', 'LockApp', 'SystemSettings', 'Taskmgr', 'conhost', 'WindowsTerminal',
    'WmiPrvSE', 'dllhost', 'audiodg', 'spoolsv', 'SecurityHealthService', 'SecurityHealthSystray', 'MsMpEng', 'NisSrv',
    'NVDisplay.Container', 'nvcontainer', 'atieclxx', 'atiesrxx', 'AMDRSServ', 'RtkAudUService64', 'vgc', 'vgtray',
    'EasyAntiCheat', 'EasyAntiCheat_EOS', 'BEService', 'BEDaisy', 'powershell', 'pwsh', 'cmd'
)
$script:KeepNormal = @(
    'Discord', 'DiscordPTB', 'DiscordCanary', 'obs64', 'obs32', 'StreamlabsOBS', 'Medal', 'TeamSpeak', 'ts3client_win64', 'Mumble',
    'FortniteClient-Win64-Shipping', 'FortniteLauncher', 'EpicGamesLauncher', 'EpicWebHelper'
)

# ----------------------------------------------------------------------------
# v0.4 helpers: GPU detection, NVIDIA driver, detected apps, input devices
# ----------------------------------------------------------------------------
$script:GpuCache = $null
$script:PickerValues = @{}

function Get-GpuList {
    if ($null -ne $script:GpuCache) { return $script:GpuCache }
    $list = @()
    try {
        foreach ($v in @(Get-CimInstance Win32_VideoController -ErrorAction Stop)) {
            $n = [string]$v.Name
            if (-not $n -or $n -match 'Microsoft|Remote|Virtual|Basic Render|Parsec|Citrix|Mirage|DisplayLink') { continue }
            $list += @{ Name = $n; PnpId = [string]$v.PNPDeviceID; Driver = [string]$v.DriverVersion }
        }
    } catch { }
    $script:GpuCache = $list
    return $list
}

function Get-PrimaryGpu {
    # Prefer a dedicated card over an integrated one (a Ryzen G-series PC often lists both).
    $all = @(Get-GpuList)
    foreach ($g in $all) { if ($g.Name -match 'NVIDIA|GeForce|RTX|GTX|Radeon RX|Radeon Pro|Arc') { return $g } }
    if ($all.Count -gt 0) { return $all[0] }
    return $null
}

function Test-HasGpuVendor {
    param([string]$Vendor)
    foreach ($g in @(Get-GpuList)) {
        if ($Vendor -eq 'NVIDIA' -and $g.Name -match 'NVIDIA|GeForce') { return $true }
        if ($Vendor -eq 'AMD' -and $g.Name -match 'Radeon|AMD') { return $true }
    }
    return $false
}

function Get-GpuTier {
    # 1 = entry level ... 6 = top end. Unknown cards count as 1 (the safest value for the mouse queue).
    param([string]$Name)
    $n = $Name.ToUpper()
    $nv = @{ 2050 = 1; 2060 = 1; 2070 = 2; 2080 = 2; 3050 = 1; 3060 = 2; 3070 = 3; 3080 = 4; 3090 = 5; 4050 = 1; 4060 = 2; 4070 = 4; 4080 = 5; 4090 = 6; 5050 = 2; 5060 = 3; 5070 = 4; 5080 = 5; 5090 = 6 }
    $m = [regex]::Match($n, '(?:RTX|GTX|GT)\s*(\d{3,4})\s*(TI|SUPER)?')
    if ($m.Success) {
        $num = [int]$m.Groups[1].Value
        if ($num -lt 2000) { return 1 }
        $base = 1
        if ($nv.ContainsKey($num)) { $base = $nv[$num] }
        if ($m.Groups[2].Success -and $base -lt 5) { $base++ }
        return [math]::Min(6, $base)
    }
    $amd = @{ 5500 = 1; 5600 = 2; 5700 = 3; 6400 = 1; 6500 = 1; 6600 = 2; 6650 = 2; 6700 = 3; 6750 = 3; 6800 = 4; 6900 = 5; 6950 = 5; 7600 = 2; 7700 = 3; 7800 = 4; 7900 = 5; 9060 = 3; 9070 = 5 }
    $m = [regex]::Match($n, 'RX\s*(\d{4})\s*(XTX|XT|GRE)?')
    if ($m.Success) {
        $num = [int]$m.Groups[1].Value
        $base = 1
        if ($amd.ContainsKey($num)) { $base = $amd[$num] }
        if ($m.Groups[2].Success -and $base -lt 5) { $base++ }
        return [math]::Min(6, $base)
    }
    $m = [regex]::Match($n, 'ARC\s*A(\d{3})')
    if ($m.Success) {
        $num = [int]$m.Groups[1].Value
        if ($num -ge 770) { return 3 }
        if ($num -ge 580) { return 2 }
        return 1
    }
    return 1
}

function Get-BestGpuTier {
    $best = 1
    $name = 'no dedicated graphics card detected'
    foreach ($g in @(Get-GpuList)) {
        $t = Get-GpuTier $g.Name
        if ($t -ge $best) { $best = $t; $name = $g.Name }
    }
    return @{ Tier = $best; Name = $name }
}

function Get-FortniteExe {
    $rel = 'FortniteGame\Binaries\Win64\FortniteClient-Win64-Shipping.exe'
    try {
        $dat = Join-Path $env:ProgramData 'Epic\UnrealEngineLauncher\LauncherInstalled.dat'
        if (Test-Path -LiteralPath $dat) {
            $j = Get-Content -LiteralPath $dat -Raw | ConvertFrom-Json
            foreach ($i in @($j.InstallationList)) {
                if ($i.AppName -eq 'Fortnite' -and $i.InstallLocation) {
                    $p = Join-Path $i.InstallLocation $rel
                    if (Test-Path -LiteralPath $p) { return $p }
                }
            }
        }
    } catch { }
    foreach ($base in @((Join-Path $env:ProgramFiles 'Epic Games\Fortnite'), (Join-Path ${env:ProgramFiles(x86)} 'Epic Games\Fortnite'))) {
        $p = Join-Path $base $rel
        if (Test-Path -LiteralPath $p) { return $p }
    }
    return $null
}

function Suspend-BitLockerForBoot {
    try {
        $v = Get-BitLockerVolume -MountPoint $env:SystemDrive -ErrorAction Stop
        if ([string]$v.ProtectionStatus -eq 'On' -or [int]$v.ProtectionStatus -eq 1) {
            Suspend-BitLocker -MountPoint $env:SystemDrive -RebootCount 1 -ErrorAction Stop | Out-Null
            Write-Log 'BitLocker was suspended for one restart so this boot change does not trigger a recovery-key prompt' 'Warn'
            return $true
        }
    } catch { }
    return $false
}

function Get-BcdFlag {
    param([string]$Name)
    $out = (& bcdedit.exe /enum '{current}' 2>&1 | Out-String)
    $m = [regex]::Match($out, '(?im)^\s*' + [regex]::Escape($Name) + '\s+(\S+)')
    if ($m.Success) { return $m.Groups[1].Value }
    return $null
}

# ---- NVIDIA driver ----
function Get-NvidiaSeries {
    param([string]$Name)
    $m = [regex]::Match($Name, '(?i)(?:RTX|GTX|GT|TITAN)\s*(\d{3,4})')
    if (-not $m.Success) { return 0 }
    $n = [int]$m.Groups[1].Value
    if ($n -ge 5000) { return 50 }
    if ($n -ge 4000) { return 40 }
    if ($n -ge 3000) { return 30 }
    if ($n -ge 2000) { return 20 }
    if ($n -ge 1600) { return 16 }
    if ($n -ge 1000) { return 10 }
    return 0
}

function Get-NvidiaPlan {
    $g = $null
    foreach ($x in @(Get-GpuList)) { if ($x.Name -match 'NVIDIA|GeForce') { $g = $x; break } }
    if (-not $g) { return $null }
    $series = Get-NvidiaSeries $g.Name
    # Your scheme. GTX 16-series is Turing like the 20-series, so it shares that driver.
    $map = @{ 10 = '552.22'; 16 = '566.36'; 20 = '566.36'; 30 = '591.86'; 40 = '591.86'; 50 = '595.71' }
    $ver = $null
    if ($map.ContainsKey($series)) { $ver = $map[$series] }
    $inst = $null
    $parts = ([string]$g.Driver).Split('.')
    if ($parts.Count -ge 4) {
        $s = ($parts[2] + $parts[3])
        if ($s.Length -ge 5) { $s = $s.Substring($s.Length - 5); $inst = $s.Substring(0, 3) + '.' + $s.Substring(3) }
    }
    $laptop = [bool]($g.Name -match 'Laptop|Max-Q|Notebook')
    return @{ Name = $g.Name; Series = $series; Version = $ver; Installed = $inst; Laptop = $laptop }
}

function Invoke-Download {
    param([string]$Url, [string]$Dest)
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    if (Get-Command Start-BitsTransfer -ErrorAction SilentlyContinue) {
        $job = Start-BitsTransfer -Source $Url -Destination $Dest -Asynchronous -DisplayName 'Compact Tweaks driver' -ErrorAction Stop
        $lastPct = -10
        $errors = 0
        while ($true) {
            Start-Sleep -Milliseconds 400
            Update-UI
            $job = Get-BitsTransfer -JobId $job.JobId -ErrorAction Stop
            $st = [string]$job.JobState
            if ($st -eq 'Transferred') { Complete-BitsTransfer -BitsJob $job; break }
            if ($st -eq 'Error' -or $st -eq 'Cancelled') { Remove-BitsTransfer -BitsJob $job -ErrorAction SilentlyContinue; throw 'The download failed. Check your connection and try again.' }
            if ($st -eq 'TransientError') { $errors++; if ($errors -gt 150) { Remove-BitsTransfer -BitsJob $job -ErrorAction SilentlyContinue; throw 'The download kept failing. Check your connection and try again.' } }
            if ($job.BytesTotal -gt 0) {
                $pct = [int]([double]$job.BytesTransferred / [double]$job.BytesTotal * 100)
                if ($pct -ge $lastPct + 10) { $lastPct = $pct; Write-Log ('Downloading driver... {0}%' -f $pct) }
            }
        }
    } else {
        Write-Log 'Downloading driver (no progress display on this PC)...'
        (New-Object System.Net.WebClient).DownloadFile($Url, $Dest)
    }
}

function Install-NvidiaDriver {
    $plan = Get-NvidiaPlan
    if (-not $plan) { throw 'No NVIDIA graphics card was found.' }
    if (-not $plan.Version) { throw ('There is no driver mapped for {0}. The scheme covers the GTX 10, 16/20, 30, 40 and 50 series.' -f $plan.Name) }
    $ver = $plan.Version
    if ($plan.Installed -eq $ver) { Write-Log ('NVIDIA driver {0} is already installed' -f $ver) 'Ok'; return }
    $kind = 'desktop'
    if ($plan.Laptop -or (Get-IsLaptop)) { $kind = 'notebook' }
    $file = ('{0}-{1}-win10-win11-64bit-international-dch-whql.exe' -f $ver, $kind)
    $url = 'https://us.download.nvidia.com/Windows/{0}/{1}' -f $ver, $file
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Write-Log ('Checking that NVIDIA hosts {0}...' -f $file)
    try { $r = Invoke-WebRequest -Uri $url -Method Head -UseBasicParsing -TimeoutSec 25 -ErrorAction Stop }
    catch { throw ('NVIDIA did not answer for {0} ({1}). Nothing was changed.' -f $file, $_.Exception.Message) }
    $free = (Get-PSDrive -Name ($env:SystemDrive.TrimEnd(':'))).Free
    if ($free -lt 4GB) { throw 'You need at least 4 GB free on the system drive for the driver download and install.' }
    $dir = Join-Path $script:DataDir 'drivers'
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $dest = Join-Path $dir $file
    if (Test-Path -LiteralPath $dest) { Remove-Item -LiteralPath $dest -Force -ErrorAction SilentlyContinue }
    Write-Log ('Downloading NVIDIA {0} for {1}...' -f $ver, $plan.Name)
    Invoke-Download $url $dest
    $sig = Get-AuthenticodeSignature -FilePath $dest
    if ($sig.Status -ne 'Valid' -or [string]$sig.SignerCertificate.Subject -notmatch 'NVIDIA') {
        Remove-Item -LiteralPath $dest -Force -ErrorAction SilentlyContinue
        throw 'The downloaded file did not have a valid NVIDIA signature, so it was deleted and NOT installed.'
    }
    Write-Log 'Signature check passed (signed by NVIDIA Corporation). Installing, this takes several minutes and the screen may flicker...' 'Ok'
    $p = Start-Process -FilePath $dest -ArgumentList @('-s', '-noreboot', '-noeula', '-clean') -PassThru
    while (-not $p.HasExited) { Update-UI; Start-Sleep -Milliseconds 400 }
    if ($p.ExitCode -ne 0 -and $p.ExitCode -ne 1) { throw ('The NVIDIA installer finished with code {0}. Your previous driver was not removed unless Windows says otherwise; check Device Manager.' -f $p.ExitCode) }
    $script:NeedRestart = $true
    $script:GpuCache = $null
    Write-Log ('NVIDIA driver {0} installed. Restart Windows to finish.' -f $ver) 'Ok'
}

# ---- Detected apps: hardware acceleration and cache ----
function Get-AppCatalog {
    $ad = $env:APPDATA
    $la = $env:LOCALAPPDATA
    return @(
        @{ Id = 'discord'; Name = 'Discord'; Kind = 'discord'; Proc = @('Discord'); Config = (Join-Path $ad 'discord\settings.json')
           Caches = @((Join-Path $ad 'discord\Cache'), (Join-Path $ad 'discord\Code Cache'), (Join-Path $ad 'discord\GPUCache')) },
        @{ Id = 'chrome'; Name = 'Google Chrome'; Kind = 'chromium'; Proc = @('chrome'); Config = (Join-Path $la 'Google\Chrome\User Data\Local State')
           Caches = @((Join-Path $la 'Google\Chrome\User Data\Default\Cache'), (Join-Path $la 'Google\Chrome\User Data\Default\Code Cache'), (Join-Path $la 'Google\Chrome\User Data\Default\GPUCache')) },
        @{ Id = 'edge'; Name = 'Microsoft Edge'; Kind = 'chromium'; Proc = @('msedge'); Config = (Join-Path $la 'Microsoft\Edge\User Data\Local State')
           Caches = @((Join-Path $la 'Microsoft\Edge\User Data\Default\Cache'), (Join-Path $la 'Microsoft\Edge\User Data\Default\Code Cache'), (Join-Path $la 'Microsoft\Edge\User Data\Default\GPUCache')) },
        @{ Id = 'spotify'; Name = 'Spotify'; Kind = 'spotify'; Proc = @('Spotify'); Config = (Join-Path $ad 'Spotify\prefs')
           Caches = @((Join-Path $la 'Spotify\Data'), (Join-Path $la 'Spotify\Browser')) },
        @{ Id = 'vscode'; Name = 'Visual Studio Code'; Kind = 'vscode'; Proc = @('Code'); Config = (Join-Path $ad 'Code\argv.json')
           Caches = @((Join-Path $la 'Code\Cache'), (Join-Path $la 'Code\CachedData'), (Join-Path $la 'Code\GPUCache')) }
    )
}

function Get-AppHwAccel {
    # $true = on, $false = off, $null = could not read.
    param([string]$Kind, [string]$Path)
    try {
        if (-not (Test-Path -LiteralPath $Path)) { return $null }
        switch ($Kind) {
            'discord' {
                $o = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
                if ($o.PSObject.Properties['enableHardwareAcceleration']) { return [bool]$o.enableHardwareAcceleration }
                return $true
            }
            'chromium' {
                Add-Type -AssemblyName System.Web.Extensions
                $js = New-Object System.Web.Script.Serialization.JavaScriptSerializer
                $js.MaxJsonLength = [int]::MaxValue
                $obj = $js.DeserializeObject((Get-Content -LiteralPath $Path -Raw))
                if ($obj.ContainsKey('hardware_acceleration_mode')) {
                    $h = $obj['hardware_acceleration_mode']
                    if ($h.ContainsKey('enabled')) { return [bool]$h['enabled'] }
                }
                return $true
            }
            'spotify' {
                $f = Read-TextFile $Path
                $lines = ConvertTo-IniLines $f.Text
                foreach ($l in $lines) {
                    if ($l -match '^\s*ui\.hardware_acceleration\s*=\s*(\S+)') { return ($Matches[1] -ne 'false') }
                }
                return $true
            }
            'vscode' {
                $text = Get-Content -LiteralPath $Path -Raw
                $m = [regex]::Match($text, '"disable-hardware-acceleration"\s*:\s*(true|false)')
                if ($m.Success) { return ($m.Groups[1].Value -ne 'true') }
                return $true
            }
        }
    } catch { }
    return $null
}

function Set-AppHwAccel {
    param([string]$Kind, [string]$Path, [bool]$Enabled)
    $noBom = New-Object System.Text.UTF8Encoding($false)
    switch ($Kind) {
        'discord' {
            $o = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
            $o | Add-Member -NotePropertyName 'enableHardwareAcceleration' -NotePropertyValue $Enabled -Force
            [IO.File]::WriteAllText($Path, ($o | ConvertTo-Json -Depth 20), $noBom)
        }
        'chromium' {
            Add-Type -AssemblyName System.Web.Extensions
            $js = New-Object System.Web.Script.Serialization.JavaScriptSerializer
            $js.MaxJsonLength = [int]::MaxValue
            $js.RecursionLimit = 200
            $obj = $js.DeserializeObject((Get-Content -LiteralPath $Path -Raw))
            $d = New-Object 'System.Collections.Generic.Dictionary[string,object]'
            $d['enabled'] = $Enabled
            $obj['hardware_acceleration_mode'] = $d
            [IO.File]::WriteAllText($Path, $js.Serialize($obj), $noBom)
        }
        'spotify' {
            $f = Read-TextFile $Path
            $lines = ConvertTo-IniLines $f.Text
            $val = 'false'
            if ($Enabled) { $val = 'true' }
            $done = $false
            for ($i = 0; $i -lt $lines.Count; $i++) {
                if ($lines[$i] -match '^\s*ui\.hardware_acceleration\s*=') { $lines[$i] = 'ui.hardware_acceleration=' + $val; $done = $true }
            }
            if (-not $done) { $lines.Add('ui.hardware_acceleration=' + $val) }
            Write-TextFile -Path $Path -Text ($lines -join $f.NewLine) -Bom $f.Bom
        }
        'vscode' {
            $f = Read-TextFile $Path
            $flag = 'false'
            if (-not $Enabled) { $flag = 'true' }
            $text = $f.Text
            if ($text -match '"disable-hardware-acceleration"\s*:\s*(true|false)') {
                $text = [regex]::Replace($text, '("disable-hardware-acceleration"\s*:\s*)(true|false)', ('${1}' + $flag))
            } else {
                $text = [regex]::Replace($text, '\{', ('{' + "`r`n" + '    "disable-hardware-acceleration": ' + $flag + ','), 1)
            }
            Write-TextFile -Path $Path -Text $text -Bom $f.Bom
        }
    }
}

function Get-AppOptimizerTweaks {
    $out = @()
    foreach ($a in @(Get-AppCatalog)) {
        if (-not (Test-Path -LiteralPath $a.Config)) { continue }
        $app = $a
        $hwApply = {
            if (Get-Process -Name $app.Proc -ErrorAction SilentlyContinue) { throw ('Close {0} completely first (quit it from the tray icon), then try again.' -f $app.Name) }
            $b = Backup-FileSafe $app.Config
            Set-AppHwAccel $app.Kind $app.Config $false
            Write-Log ('{0}: hardware acceleration turned off (backup: {1})' -f $app.Name, $b) 'Ok'
            return @{ Config = $app.Config; Backup = $b }
        }.GetNewClosure()
        $hwUndo = {
            param($D)
            if (Get-Process -Name $app.Proc -ErrorAction SilentlyContinue) { throw ('Close {0} completely first, then try again.' -f $app.Name) }
            Set-AppHwAccel $app.Kind $app.Config $true
        }.GetNewClosure()
        $hwTest = { return ((Get-AppHwAccel $app.Kind $app.Config) -eq $false) }.GetNewClosure()
        $out += @{ Id = ('app-' + $a.Id + '-hw'); Category = 'apps'; Group = $a.Name; Name = ($a.Name + ': turn off hardware acceleration'); Risk = 'Low'; Recommended = $false
                   Desc = 'Hardware acceleration makes the app use your GPU. Turning it off frees GPU time for your game, at the cost of the app itself being slightly less smooth. Close the app first; a backup of its settings file is made.'
                   Apply = $hwApply; Undo = $hwUndo; Test = $hwTest }
        $cacheApply = {
            if (Get-Process -Name $app.Proc -ErrorAction SilentlyContinue) { throw ('Close {0} completely first (quit it from the tray icon), then try again.' -f $app.Name) }
            $freed = 0.0
            foreach ($d in $app.Caches) {
                if (Test-Path -LiteralPath $d) {
                    $size = (Get-ChildItem -LiteralPath $d -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
                    if ($size) { $freed += [double]$size }
                    Get-ChildItem -LiteralPath $d -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
                }
            }
            Write-Log ('{0}: cache cleared, about {1} MB freed' -f $app.Name, [math]::Round($freed / 1MB)) 'Ok'
        }.GetNewClosure()
        $out += @{ Id = ('app-' + $a.Id + '-cache'); Category = 'apps'; Group = $a.Name; Name = ($a.Name + ': clear cache'); Risk = 'Low'; Recommended = $false; OneShot = $true
                   Desc = 'Deletes the temporary cache files the app rebuilds by itself. It may load a little slower the first time you open it afterwards. Close the app first. This cannot be undone, but nothing personal is deleted.'
                   Apply = $cacheApply }
    }
    if ($out.Count -gt 1) {
        $catalog = @(Get-AppCatalog | Where-Object { Test-Path -LiteralPath $_.Config })
        $names = ($catalog | ForEach-Object { $_.Name }) -join ', '
        $bulkApply = {
            $running = @($catalog | Where-Object { Get-Process -Name $_.Proc -ErrorAction SilentlyContinue })
            if ($running.Count -gt 0) { throw ('Close these apps first: ' + (($running | ForEach-Object { $_.Name }) -join ', ')) }
            $done = @()
            foreach ($app in $catalog) {
                try { $b = Backup-FileSafe $app.Config; Set-AppHwAccel $app.Kind $app.Config $false; $done += @{ Kind = $app.Kind; Config = $app.Config; Backup = $b; Name = $app.Name } }
                catch { Write-Log ($app.Name + ': ' + $_.Exception.Message) 'Warn' }
            }
            Write-Log ('Hardware acceleration turned off for: ' + (($done | ForEach-Object { $_.Name }) -join ', ')) 'Ok'
            return @{ Apps = $done }
        }.GetNewClosure()
        $bulkUndo = {
            param($D)
            foreach ($x in @($D.Apps)) { try { Set-AppHwAccel $x.Kind $x.Config $true } catch { } }
        }.GetNewClosure()
        $bulkTest = {
            foreach ($app in $catalog) { if ((Get-AppHwAccel $app.Kind $app.Config) -ne $false) { return $false } }
            return $true
        }.GetNewClosure()
        $out += @{ Id = 'apps-hw-off-all'; Category = 'apps'; Group = 'All detected apps'; Name = 'Turn off hardware acceleration for every detected app'; Risk = 'Low'; Recommended = $false
                   Desc = ('Applies the same hardware-acceleration-off change above to every app Compact Tweaks found on this PC in one step: ' + $names + '. Close all of them first. Undo turns it back on for all of them.')
                   Apply = $bulkApply; Undo = $bulkUndo; Test = $bulkTest }
    }
    return $out
}

function Get-InputDeviceSummary {
    $map = @{ '046D' = 'Logitech (G HUB)'; '1532' = 'Razer (Razer Synapse)'; '1038' = 'SteelSeries (SteelSeries GG)'; '1B1C' = 'Corsair (iCUE)'; '1E7D' = 'ROCCAT (Swarm)'; '0951' = 'HyperX (HyperX NGENUITY)'; '0B05' = 'ASUS (Armoury Crate)' }
    $found = @{}
    try {
        foreach ($cls in @('Mouse', 'Keyboard')) {
            foreach ($d in @(Get-PnpDevice -Class $cls -PresentOnly -ErrorAction SilentlyContinue)) {
                $m = [regex]::Match([string]$d.InstanceId, 'VID_([0-9A-Fa-f]{4})')
                if (-not $m.Success) { continue }
                $vid = $m.Groups[1].Value.ToUpper()
                if ($map.ContainsKey($vid)) { $label = $map[$vid] } else { $label = ('vendor ID ' + $vid) }
                $found[($cls + ': ' + $label)] = $true
            }
        }
    } catch { }
    return @($found.Keys | Sort-Object)
}

# Values used by catalog entries below
$script:GpuBest = Get-BestGpuTier
$script:MouseQueueMap = @{ 1 = 32; 2 = 23; 3 = 22; 4 = 21; 5 = 20; 6 = 19 }
$script:PickerValues['mouseq'] = [int]$script:MouseQueueMap[[int]$script:GpuBest.Tier]
$script:NvPlan = Get-NvidiaPlan

function Get-NvDriverDesc {
    $p = $script:NvPlan
    if (-not $p) { return 'No NVIDIA graphics card was detected, so this tweak has nothing to do here.' }
    if (-not $p.Version) { return ('{0} is not covered by the driver picks below yet.' -f $p.Name) }
    return ('Downloads a driver picked for your card ({0}), checks that it is genuinely signed by NVIDIA, then installs it quietly as a clean install. You choose when to restart afterwards. Two things to expect: your FPS may dip for the first few matches while game shaders rebuild for the new driver, and the Epic Games Launcher may warn that your driver is "too old" before Fortnite starts, just click No and the game opens fine. A restore point is made first.' -f $p.Name)
}

function Get-NvDriverConfirm {
    $p = $script:NvPlan
    $v = '?'
    $n = 'your NVIDIA card'
    if ($p) { $n = $p.Name; if ($p.Version) { $v = $p.Version } }
    return ("Install NVIDIA driver {0} for {1}?`n`nCompact Tweaks downloads it from NVIDIA (about 0.9 GB), checks NVIDIA's digital signature, then runs the NVIDIA installer silently as a clean install. The screen may flicker, it takes several minutes, and a restart is needed afterwards.`n`nAfter changing driver expect:`n - Lower FPS at first, because game shaders are rebuilt after a new driver. It settles after a few matches.`n - Before launching Fortnite, the Epic Games Launcher may warn that your driver is too old and ask you to update. Always press No and the game will launch.`n`nContinue?" -f $v, $n)
}

function Get-MouseQueueDesc {
    return ('Sets MouseDataQueueSize, how many mouse movements Windows buffers before handing them to a game. A smaller buffer can reduce input lag on a strong PC but can drop mouse events if it is too small, so the safe range here is 0x13 to 0x20 (the Windows default is 0x64). Scheme: the weaker your graphics card, the higher the value. 0x20 for a GTX 10-series up to an RTX 3050, about 0x17 for an RTX 3060, then lower for faster cards, down to 0x13 at the very top. Suggested for your PC ({0}): 0x{1:X}. The benefit is small; if the mouse ever feels off, raise the number or undo. Needs a restart.' -f $script:GpuBest.Name, [int]$script:PickerValues['mouseq'])
}

# ----------------------------------------------------------------------------
# ----------------------------------------------------------------------------
# v0.5 helpers: service/startup trimming, scheduled tasks, network binding/adapter
# properties, NTFS/fsutil, drive optimization, generic diagnostic-command runner
# ----------------------------------------------------------------------------
function Test-IsMicrosoftSigned {
    param([string]$Path)
    try {
        if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return $false }
        $sig = Get-AuthenticodeSignature -FilePath $Path -ErrorAction Stop
        return [bool]($sig.Status -eq 'Valid' -and [string]$sig.SignerCertificate.Subject -match 'Microsoft')
    } catch { return $false }
}

function Get-ServiceBinaryPath {
    param($Svc)
    $p = [string]$Svc.PathName
    $m = [regex]::Match($p, '^"([^"]+)"|^(\S+)')
    if ($m.Success) { if ($m.Groups[1].Success) { return $m.Groups[1].Value } else { return $m.Groups[2].Value } }
    return $p
}

function Get-ThirdPartyUpdaterServices {
    # Non-Microsoft services whose name/description looks like an updater or elevation helper.
    # Logitech's G HUB updater is explicitly kept alone because disabling it breaks the app.
    $out = @()
    foreach ($s in @(Get-CimInstance Win32_Service -ErrorAction SilentlyContinue)) {
        if ($s.StartMode -eq 'Disabled') { continue }
        $bin = Get-ServiceBinaryPath $s
        if (Test-IsMicrosoftSigned $bin) { continue }
        $text = $s.Name + ' ' + $s.DisplayName
        if ($text -match '(?i)logitech|g ?hub') { continue }
        if ($text -match '(?i)updat|elevat') { $out += $s }
    }
    return $out
}

function Get-StartupApprovedPaths {
    return @(
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run'
    )
}

function Get-RunKeyEntries {
    # Every Run/RunOnce value name across HKCU and HKLM, with its command, skipping cmd.exe entries.
    $out = @()
    foreach ($root in @('HKCU:', 'HKLM:', 'HKLM:\SOFTWARE\WOW6432Node')) {
        foreach ($sub in @('\Software\Microsoft\Windows\CurrentVersion\Run', '\Software\Microsoft\Windows\CurrentVersion\RunOnce')) {
            $path = $root + $sub
            $k = Get-Item -LiteralPath $path -ErrorAction SilentlyContinue
            if (-not $k) { continue }
            foreach ($name in @($k.GetValueNames())) {
                if (-not $name) { continue }
                $val = [string]$k.GetValue($name)
                if ($val -match '(?i)cmd\.exe') { continue }
                $approvedPath = ($root + '\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\' + (Split-Path $sub -Leaf))
                $out += @{ Root = $root; RunPath = $path; ApprovedPath = $approvedPath; Name = $name }
            }
        }
    }
    return $out
}

function Set-StartupApprovedDisabled {
    param([string]$Path, [string]$Name, [bool]$Disabled)
    if (-not (Test-Path -LiteralPath $Path)) { New-Item -Path $Path -Force | Out-Null }
    $bytes = New-Object byte[] 12
    if ($Disabled) { $bytes[0] = 3 } else { $bytes[0] = 2 }
    New-ItemProperty -LiteralPath $Path -Name $Name -Value $bytes -PropertyType Binary -Force | Out-Null
}

$script:SafeToDisableServices = @(
    @{ Name = 'Fax'; Label = 'Fax' },
    @{ Name = 'RemoteRegistry'; Label = 'Remote Registry' },
    @{ Name = 'MapsBroker'; Label = 'Downloaded Maps Manager' },
    @{ Name = 'RetailDemo'; Label = 'Retail Demo' },
    @{ Name = 'WMPNetworkSvc'; Label = 'Windows Media Player Network Sharing' },
    @{ Name = 'WalletService'; Label = 'Wallet Service' },
    @{ Name = 'PhoneSvc'; Label = 'Phone Service' },
    @{ Name = 'TabletInputService'; Label = 'Touch Keyboard and Handwriting Panel' }
)

$script:CleanupScheduledTasks = @(
    '\Microsoft\Windows\Application Experience\Microsoft Compatibility Appraiser',
    '\Microsoft\Windows\Application Experience\ProgramDataUpdater',
    '\Microsoft\Windows\Autochk\Proxy',
    '\Microsoft\Windows\Customer Experience Improvement Program\Consolidator',
    '\Microsoft\Windows\Customer Experience Improvement Program\KernelCeipTask',
    '\Microsoft\Windows\Customer Experience Improvement Program\UsbCeip',
    '\Microsoft\Windows\DiskDiagnostic\Microsoft-Windows-DiskDiagnosticDataCollector',
    '\Microsoft\Windows\Feedback\Siuf\DmClient',
    '\Microsoft\Windows\Feedback\Siuf\DmClientOnScenarioDownload',
    '\Microsoft\Windows\Power Efficiency Diagnostics\AnalyzeSystem'
)

function Disable-ScheduledTaskList {
    param($Paths)
    $touched = @()
    foreach ($p in $Paths) {
        $folder = Split-Path -Path $p -Parent
        $name = Split-Path -Path $p -Leaf
        try {
            $t = Get-ScheduledTask -TaskName $name -TaskPath ($folder + '\') -ErrorAction Stop
            if ($t.State -eq 'Disabled') { continue }
            Disable-ScheduledTask -TaskName $name -TaskPath ($folder + '\') -ErrorAction Stop | Out-Null
            $touched += $p
        } catch { }
    }
    return $touched
}

function Enable-ScheduledTaskList {
    param($Paths)
    foreach ($p in $Paths) {
        $folder = Split-Path -Path $p -Parent
        $name = Split-Path -Path $p -Leaf
        try { Enable-ScheduledTask -TaskName $name -TaskPath ($folder + '\') -ErrorAction Stop | Out-Null } catch { }
    }
}

$script:OptionalAppPackages = @(
    'Microsoft.XboxApp', 'Microsoft.XboxGamingOverlay', 'Microsoft.Xbox.TCUI', 'Microsoft.XboxSpeechToTextOverlay',
    'Microsoft.XboxIdentityProvider', 'Microsoft.GamingApp', 'Microsoft.3DViewer', 'Microsoft.MixedReality.Portal',
    'Microsoft.BingWeather', 'Microsoft.BingNews', 'Microsoft.MicrosoftSolitaireCollection', 'Microsoft.ZuneMusic',
    'Microsoft.ZuneVideo', 'Microsoft.People', 'Microsoft.YourPhone', 'Microsoft.GetHelp', 'Microsoft.Getstarted',
    'Microsoft.Microsoft3DViewer', 'MicrosoftCorporationII.MicrosoftFamily', 'Microsoft.WindowsFeedbackHub',
    'Microsoft.MicrosoftOfficeHub', 'Clipchamp.Clipchamp', 'MicrosoftTeams'
)

function Get-BootDriveIsSsd {
    try {
        $letter = $env:SystemDrive.TrimEnd(':')
        $part = Get-Partition -DriveLetter $letter -ErrorAction Stop
        $disk = Get-PhysicalDisk -ErrorAction Stop | Where-Object { $_.DeviceId -eq $part.DiskNumber }
        if ($disk) { return [bool]($disk[0].MediaType -eq 'SSD') }
    } catch { }
    return $true
}

function Invoke-DiagCommand {
    param([string]$Title, [string]$FilePath, [string[]]$Arguments)
    Write-Log ('Running: ' + $Title)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FilePath
    $psi.Arguments = ($Arguments -join ' ')
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    [void]$proc.Start()
    while (-not $proc.StandardOutput.EndOfStream) {
        $line = $proc.StandardOutput.ReadLine()
        if ($line -and $line.Trim()) { Write-Log $line }
        Update-UI
    }
    $err = $proc.StandardError.ReadToEnd()
    $proc.WaitForExit()
    if ($err -and $err.Trim()) { Write-Log $err.Trim() 'Warn' }
    Write-Log ($Title + ' finished (exit code ' + $proc.ExitCode + ').') 'Ok'
}

# Tweak catalog
#   Category : tab id (cpu, gpu, kbm, aim, debloat, net, apps, extra)   Group : heading inside the tab
#   Registry / Services : snapshotted automatically.   Apply/Undo/Test : scriptblocks for anything else.
#   OneShot : action with no undo.   Guard : hidden when it returns $false.
#   Risk    : Low | Medium | High (High asks for an extra confirmation).
#   Unproven groups: kept out of Select recommended and labelled, because the reference research
#   little or no measurable effect.
# ----------------------------------------------------------------------------
$ifeo = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\FortniteClient-Win64-Shipping.exe\PerfOptions'
$mm   = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile'
$cdm  = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
$explorerAdv = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
$classicMenuKey = 'HKCU:\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}'
$memMgmt = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management'

# ----------------------------------------------------------------------------
# v0.8 performance expansion
# Adds granular, reversible controls instead of hiding a giant all-in-one preset.
# The extras are intentionally NOT selected by default: several are situational and
# can disable Windows features you may actually use. Read each description first.
# ----------------------------------------------------------------------------
function Get-NicAdvancedByKeyword {
    param([string]$Keyword)
    $out = @()
    if (-not (Get-Command Get-NetAdapterAdvancedProperty -ErrorAction SilentlyContinue)) { return $out }
    foreach ($a in @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue)) {
        try {
            $p = Get-NetAdapterAdvancedProperty -Name $a.Name -RegistryKeyword $Keyword -AllProperties -ErrorAction Stop
            if ($p) { $out += @($p) }
        } catch { }
    }
    return $out
}

function Clear-CacheDirectorySafe {
    param([string]$Path, [string]$Label)
    if (-not (Test-Path -LiteralPath $Path)) { throw ($Label + ' cache was not found on this PC.') }
    $before = 0L
    try { $before = [int64]((Get-ChildItem -LiteralPath $Path -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum) } catch { }
    Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    Write-Log ('{0}: cleared about {1} MB of cache' -f $Label, [math]::Round($before / 1MB)) 'Ok'
}

function Get-ExtraPerformanceTweaks {
    $out = @()

    # 24 registry-backed controls. Most trim UI/background work rather than promising magic FPS.
    $reg = @(
        @{ Id='perf-visualfx-best'; Category='windows'; Group='Visual performance'; Name='Visual effects: Best performance preset'; Risk='Medium'; Restart='sign-out'; Path='HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects'; ValueName='VisualFXSetting'; Type='DWord'; Value=2; Desc='Uses Windows built-in Best performance visual-effects preset. It can make the desktop look plainer, but it reduces animation, shadow and composition work. This is mainly useful on weaker PCs; modern gaming PCs may see no measurable FPS change.' },
        @{ Id='perf-dragfull-off'; Category='windows'; Group='Visual performance'; Name='Do not draw full window while dragging'; Risk='Low'; Restart='sign-out'; Path='HKCU:\Control Panel\Desktop'; ValueName='DragFullWindows'; Type='String'; Value='0'; Desc='Shows only an outline while a window is being dragged. This reduces desktop redraw work during window movement; it does not change in-game rendering.' },
        @{ Id='perf-listview-alpha-off'; Category='windows'; Group='Visual performance'; Name='Disable translucent Explorer selection rectangles'; Risk='Low'; Restart='sign-out'; Path=$explorerAdv; ValueName='ListviewAlphaSelect'; Type='DWord'; Value=0; Desc='Turns off the translucent selection rectangle in File Explorer. Tiny UI/GPU saving only; included as a granular visual-performance option.' },
        @{ Id='perf-listview-shadow-off'; Category='windows'; Group='Visual performance'; Name='Disable icon-label shadows'; Risk='Low'; Restart='sign-out'; Path=$explorerAdv; ValueName='ListviewShadow'; Type='DWord'; Value=0; Desc='Turns off drop shadows under desktop icon labels. Cosmetic only, with a tiny reduction in desktop effects.' },
        @{ Id='perf-peek-off'; Category='windows'; Group='Visual performance'; Name='Disable desktop Peek preview'; Risk='Low'; Restart='sign-out'; Path=$explorerAdv; ValueName='DisablePreviewDesktop'; Type='DWord'; Value=1; Desc='Stops the taskbar desktop Peek preview from rendering when you hover the far-right edge of the taskbar. No direct game FPS gain.' },
        @{ Id='perf-icons-only'; Category='windows'; Group='Visual performance'; Name='Explorer: icons instead of thumbnails'; Risk='Medium'; Restart='sign-out'; Path=$explorerAdv; ValueName='IconsOnly'; Type='DWord'; Value=1; Desc='Stops File Explorer generating image/video thumbnails and shows file icons instead. This can reduce Explorer CPU/disk work on folders with lots of media, but you lose thumbnail previews.' },
        @{ Id='bg-consumer-features-off'; Category='debloat'; Group='Background content'; Name='Disable Windows consumer features'; Risk='Low'; Path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent'; ValueName='DisableWindowsConsumerFeatures'; Type='DWord'; Value=1; Desc='Blocks Microsoft consumer-content suggestions and automatic promotional app experiences. This trims background content delivery; it is not a direct FPS tweak.' },
        @{ Id='bg-cloud-optimized-off'; Category='debloat'; Group='Background content'; Name='Disable cloud-optimized Windows content'; Risk='Low'; Path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent'; ValueName='DisableCloudOptimizedContent'; Type='DWord'; Value=1; Desc='Stops Windows from tailoring parts of the shell with cloud-delivered optimized content. Mainly a background/privacy trim.' },
        @{ Id='bg-spotlight-all-off'; Category='debloat'; Group='Background content'; Name='Disable Windows Spotlight features'; Risk='Low'; Path='HKCU:\SOFTWARE\Policies\Microsoft\Windows\CloudContent'; ValueName='DisableWindowsSpotlightFeatures'; Type='DWord'; Value=1; Desc='Turns off Windows Spotlight content such as rotating suggestions and promotional imagery. Reduces background content fetches.' },
        @{ Id='bg-spotlight-action-off'; Category='debloat'; Group='Background content'; Name='Disable Spotlight in Action Center'; Risk='Low'; Path='HKCU:\SOFTWARE\Policies\Microsoft\Windows\CloudContent'; ValueName='DisableWindowsSpotlightOnActionCenter'; Type='DWord'; Value=1; Desc='Prevents Spotlight suggestions from appearing in notifications/Action Center. Small background-content reduction.' },
        @{ Id='bg-spotlight-settings-off'; Category='debloat'; Group='Background content'; Name='Disable Spotlight suggestions in Settings'; Risk='Low'; Path='HKCU:\SOFTWARE\Policies\Microsoft\Windows\CloudContent'; ValueName='DisableWindowsSpotlightOnSettings'; Type='DWord'; Value=1; Desc='Stops Settings from showing cloud-delivered Spotlight suggestions and recommendations.' },
        @{ Id='bg-spotlight-lock-off'; Category='debloat'; Group='Background content'; Name='Disable Spotlight on lock screen'; Risk='Low'; Path='HKCU:\SOFTWARE\Policies\Microsoft\Windows\CloudContent'; ValueName='DisableWindowsSpotlightOnLockScreen'; Type='DWord'; Value=1; Desc='Stops Windows Spotlight from downloading rotating lock-screen content. Your normal static lock-screen image still works.' },
        @{ Id='bg-feedback-notifications-off'; Category='debloat'; Group='Telemetry'; Name='Disable Windows feedback notifications'; Risk='Low'; Path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection'; ValueName='DoNotShowFeedbackNotifications'; Type='DWord'; Value=1; Desc='Stops Windows from prompting you for feedback. This only removes feedback prompts; it does not disable core diagnostics by itself.' },
        @{ Id='bg-feedback-frequency-off'; Category='debloat'; Group='Telemetry'; Name='Set feedback prompt frequency to never'; Risk='Low'; Path='HKCU:\Software\Microsoft\Siuf\Rules'; ValueName='NumberOfSIUFInPeriod'; Type='DWord'; Value=0; Desc='Sets the per-user feedback prompt frequency to zero. Small background/UI cleanup.' },
        @{ Id='bg-app-launch-track-off'; Category='windows'; Group='Background tracking'; Name='Disable Start app-launch tracking'; Risk='Low'; Restart='sign-out'; Path=$explorerAdv; ValueName='Start_TrackProgs'; Type='DWord'; Value=0; Desc='Stops Start from tracking which programs you launch to build frequently-used app lists. This trims a small amount of shell bookkeeping.' },
        @{ Id='bg-start-recommendations-off'; Category='windows'; Group='Background tracking'; Name='Disable Start recommendations feed'; Risk='Low'; Restart='sign-out'; Path=$explorerAdv; ValueName='Start_IrisRecommendations'; Type='DWord'; Value=0; Desc='Turns off the Windows 11 Start recommendations feed where supported. This is a shell/background-content tweak, not a guaranteed FPS increase.' },
        @{ Id='bg-lockscreen-notifications-off'; Category='windows'; Group='Background tracking'; Name='Disable lock-screen app notifications'; Risk='Low'; Path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\System'; ValueName='DisableLockScreenAppNotifications'; Type='DWord'; Value=1; Desc='Stops apps from surfacing notifications on the lock screen, reducing one small background notification path.' },
        @{ Id='bg-cortana-off'; Category='debloat'; Group='Search and assistant'; Name='Disable Cortana policy'; Risk='Low'; Path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search'; ValueName='AllowCortana'; Type='DWord'; Value=0; Desc='Disables Cortana where that legacy policy is still honored. Newer Windows builds may already have Cortana removed, in which case this does nothing.' },
        @{ Id='bg-search-highlights-off'; Category='debloat'; Group='Search and assistant'; Name='Disable Search highlights'; Risk='Low'; Path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search'; ValueName='EnableDynamicContentInWSB'; Type='DWord'; Value=0; Desc='Stops dynamic web content and Search highlights from being injected into the Windows search box where supported.' },
        @{ Id='bg-search-location-off'; Category='debloat'; Group='Search and assistant'; Name='Stop Windows Search using location'; Risk='Low'; Path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search'; ValueName='AllowSearchToUseLocation'; Type='DWord'; Value=0; Desc='Prevents Windows Search from using location data for local suggestions. Small privacy/background trim.' },
        @{ Id='gamebar-controller-off'; Category='gpu'; Group='Game features'; Name='Disable controller shortcut for Xbox Game Bar'; Risk='Low'; Path='HKCU:\Software\Microsoft\GameBar'; ValueName='UseNexusForGameBarEnabled'; Type='DWord'; Value=0; Desc='Stops the controller guide/Xbox button from opening Game Bar. Useful if you never use Game Bar and want to avoid accidental overlay activation.' },
        @{ Id='gamebar-startup-off'; Category='gpu'; Group='Game features'; Name='Disable Game Bar startup panel'; Risk='Low'; Path='HKCU:\Software\Microsoft\GameBar'; ValueName='ShowStartupPanel'; Type='DWord'; Value=0; Desc='Stops Game Bar startup tips/panels from appearing. Complements the existing Game DVR toggle without changing your actual game graphics settings.' },
        @{ Id='apps-location-off'; Category='debloat'; Group='Background permissions'; Name='Block Store apps from using location'; Risk='Medium'; Path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy'; ValueName='LetAppsAccessLocation'; Type='DWord'; Value=2; Desc='Blocks Microsoft Store apps from using location in the background. This can reduce background activity, but location-dependent apps will stop working correctly.' },
        @{ Id='apps-motion-off'; Category='debloat'; Group='Background permissions'; Name='Block Store apps from motion sensors'; Risk='Medium'; Path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy'; ValueName='LetAppsAccessMotion'; Type='DWord'; Value=2; Desc='Blocks Store apps from accessing motion sensors. Mostly useful on desktops; apps that need motion data will lose that feature.' }
    )
    foreach ($x in $reg) {
        $t = @{ Id=$x.Id; Category=$x.Category; Group=$x.Group; Name=$x.Name; Risk=$x.Risk; Recommended=$false; Desc=$x.Desc; Registry=@((New-RegEntry $x.Path $x.ValueName $x.Type $x.Value)) }
        if ($x.Restart) { $t.Restart = $x.Restart }
        $out += $t
    }

    # 40 granular service trims. These overlap the bulk debloat button on purpose so advanced
    # users can disable only the exact service they do not use. Every one is hidden if absent.
    $svc = @(
        @{ Id='svc-ajrouter'; Service='AJRouter'; Name='Disable AllJoyn Router'; Desc='Turns off the AllJoyn Router service used by some IoT/device-discovery software. Skip it if you use software that relies on AllJoyn.' },
        @{ Id='svc-appvclient'; Service='AppVClient'; Name='Disable Microsoft App-V Client'; Desc='Turns off Microsoft Application Virtualization client support. Normally only useful in managed/enterprise environments.' },
        @{ Id='svc-assignedaccess'; Service='AssignedAccessManagerSvc'; Name='Disable Assigned Access / kiosk service'; Desc='Turns off Windows Assigned Access kiosk-mode management. Do not use this on a kiosk or managed shared device.' },
        @{ Id='svc-cdpsvc'; Service='CDPSvc'; Name='Disable Connected Devices Platform'; Desc='Stops Connected Devices Platform features such as some cross-device discovery and shared experiences. Can reduce background device chatter.' },
        @{ Id='svc-dusmsvc'; Service='DusmSvc'; Name='Disable Data Usage service'; Desc='Stops Windows network data-usage accounting. You lose the Settings data-usage statistics.' },
        @{ Id='svc-fax'; Service='Fax'; Name='Disable Fax service'; Desc='Turns off Windows fax support. Safe if you never send or receive faxes from this PC.' },
        @{ Id='svc-frameserver'; Service='FrameServer'; Name='Disable Windows Camera Frame Server'; Desc='Stops the shared camera frame service. Do not apply if you use a webcam, Windows Hello camera, OBS camera sources or video-call apps.' },
        @{ Id='svc-frameservermonitor'; Service='FrameServerMonitor'; Name='Disable Camera Frame Server Monitor'; Desc='Stops the camera frame monitor service. Skip if you use webcams or camera-based Windows features.' },
        @{ Id='svc-icssvc'; Service='icssvc'; Name='Disable Windows Mobile Hotspot service'; Desc='Turns off Mobile Hotspot support. Your normal Ethernet/Wi-Fi internet still works, but the PC cannot share its connection as a hotspot.' },
        @{ Id='svc-lfsvc'; Service='lfsvc'; Name='Disable Geolocation service'; Desc='Stops Windows geolocation. Apps and websites can no longer request Windows location services.' },
        @{ Id='svc-mapsbroker'; Service='MapsBroker'; Name='Disable Downloaded Maps Manager'; Desc='Stops offline-map download/update management. Skip if you use Windows offline maps.' },
        @{ Id='svc-mixedreality'; Service='MixedRealityOpenXRSvc'; Name='Disable Mixed Reality OpenXR service'; Desc='Turns off Windows Mixed Reality OpenXR support. Do not use if you play VR/Mixed Reality titles through this service.' },
        @{ Id='svc-nettcpportsharing'; Service='NetTcpPortSharing'; Name='Disable Net.Tcp Port Sharing'; Desc='Turns off WCF Net.Tcp port sharing, mainly used by some business/server applications. Normal gaming and web traffic do not need it.' },
        @{ Id='svc-phonesvc'; Service='PhoneSvc'; Name='Disable Phone Service'; Desc='Stops phone/telephony integration features. Skip if you use Windows phone-linking features that depend on it.' },
        @{ Id='svc-remoteaccess'; Service='RemoteAccess'; Name='Disable Routing and Remote Access'; Desc='Turns off Windows routing/RRAS server functionality. Normal client internet works; do not use this if the PC acts as a VPN/router server.' },
        @{ Id='svc-remoteregistry'; Service='RemoteRegistry'; Name='Disable Remote Registry'; Desc='Stops other computers from editing this PC registry remotely. Usually unnecessary on a gaming PC.' },
        @{ Id='svc-retaildemo'; Service='RetailDemo'; Name='Disable Retail Demo service'; Desc='Turns off the store-display Retail Demo service. Normal home PCs do not need it.' },
        @{ Id='svc-scardsvr'; Service='SCardSvr'; Name='Disable Smart Card service'; Desc='Stops smart-card authentication/support. Do not apply if you use smart cards for work, certificates or sign-in.' },
        @{ Id='svc-scdeviceenum'; Service='ScDeviceEnum'; Name='Disable Smart Card Device Enumeration'; Desc='Stops smart-card device discovery. Skip if you use smart cards.' },
        @{ Id='svc-sensordata'; Service='SensorDataService'; Name='Disable Sensor Data service'; Desc='Stops sensor data delivery used by some tablets/convertibles. Desktop gaming PCs usually do not need it.' },
        @{ Id='svc-sensorservice'; Service='SensorService'; Name='Disable Sensor service'; Desc='Stops automatic sensor features such as orientation on supported devices. Skip on tablets/convertibles.' },
        @{ Id='svc-sensrsvc'; Service='SensrSvc'; Name='Disable Sensor Monitoring service'; Desc='Stops sensor monitoring used for features such as ambient light/orientation on supported hardware.' },
        @{ Id='svc-sharedaccess'; Service='SharedAccess'; Name='Disable Internet Connection Sharing'; Desc='Turns off Internet Connection Sharing. Your own internet connection still works, but you cannot share it to other devices through Windows ICS.' },
        @{ Id='svc-smsrouter'; Service='SmsRouter'; Name='Disable SMS Router service'; Desc='Stops Windows SMS routing support used mainly by cellular-capable PCs. Typical desktops do not need it.' },
        @{ Id='svc-ssdpsrv'; Service='SSDPSRV'; Name='Disable SSDP Discovery'; Desc='Stops UPnP/SSDP device discovery. Some smart-TV, media and network-device discovery features may stop appearing automatically.' },
        @{ Id='svc-tapisrv'; Service='TapiSrv'; Name='Disable Telephony service'; Desc='Turns off Windows Telephony API support. Skip if you use dial-up, PBX/telephony software or related enterprise tools.' },
        @{ Id='svc-tabletinput'; Service='TabletInputService'; Name='Disable Touch Keyboard and Handwriting'; Desc='Turns off touch keyboard/handwriting services. Good for a desktop with only mouse and keyboard; do not use on touch/pen devices.' },
        @{ Id='svc-trkwks'; Service='TrkWks'; Name='Disable Distributed Link Tracking Client'; Desc='Stops tracking links to files across NTFS/network moves. Mostly useful in managed networks; typical gaming PCs rarely need it.' },
        @{ Id='svc-upnphost'; Service='upnphost'; Name='Disable UPnP Device Host'; Desc='Stops hosting/control of UPnP devices. This can affect some media/network-device features, but not normal internet connectivity.' },
        @{ Id='svc-wallet'; Service='WalletService'; Name='Disable Wallet Service'; Desc='Turns off Windows Wallet functionality. Safe if you never use Wallet/payment features.' },
        @{ Id='svc-wbiosrvc'; Service='WbioSrvc'; Name='Disable Windows Biometric Service'; Desc='Stops fingerprint/face biometric support. Do not apply if you sign in with Windows Hello biometrics.' },
        @{ Id='svc-wersvc'; Service='WerSvc'; Name='Disable Windows Error Reporting service'; Desc='Stops Windows Error Reporting from collecting and submitting crash reports in the background. You lose Microsoft crash-report submission.' },
        @{ Id='svc-wisvc'; Service='wisvc'; Name='Disable Windows Insider service'; Desc='Stops Windows Insider infrastructure. Appropriate for a stable gaming PC that is not enrolled in Insider builds.' },
        @{ Id='svc-wmpnetwork'; Service='WMPNetworkSvc'; Name='Disable Media Player Network Sharing'; Desc='Turns off Windows Media Player network sharing/DLNA service. Local media playback still works.' },
        @{ Id='svc-wpcmonsvc'; Service='WpcMonSvc'; Name='Disable Parental Controls service'; Desc='Turns off the legacy Windows parental-controls monitoring service. Do not apply on a PC where those controls are intentionally used.' },
        @{ Id='svc-wsearch'; Service='WSearch'; Name='Disable Windows Search indexing'; Desc='Stops background file indexing. This can reduce disk/CPU activity on some PCs, but Start/File Explorer searches become slower and less complete.' },
        @{ Id='svc-xblauth'; Service='XblAuthManager'; Name='Disable Xbox Live Auth Manager'; Desc='Turns off Xbox Live authentication. Do not apply if you use Xbox/Game Pass/Microsoft Store games that require Xbox services.' },
        @{ Id='svc-xblgamesave'; Service='XblGameSave'; Name='Disable Xbox Live Game Save'; Desc='Turns off Xbox cloud game-save support. Skip for Xbox/Game Pass games that sync saves.' },
        @{ Id='svc-xboxgip'; Service='XboxGipSvc'; Name='Disable Xbox Accessory Management'; Desc='Stops Xbox accessory management. Do not apply if you use Xbox controllers/accessories that depend on this service.' },
        @{ Id='svc-xboxnetapi'; Service='XboxNetApiSvc'; Name='Disable Xbox Live Networking'; Desc='Turns off Xbox Live networking support. Skip for Game Pass/Xbox titles or Xbox party/network features.' }
    )
    foreach ($x in $svc) {
        $svcName = [string]$x.Service
        $guard = { return [bool](Get-CimInstance Win32_Service -Filter ("Name='" + $svcName.Replace("'", "''") + "'") -ErrorAction SilentlyContinue) }.GetNewClosure()
        $out += @{ Id=$x.Id; Category='debloat'; Group='Individual background services'; Name=$x.Name; Risk='Medium'; Recommended=$false; Desc=($x.Desc + ' Windows service start mode is snapshotted and Undo restores it exactly.'); Guard=$guard; Services=@(@{ Name=$svcName; Mode='Disabled' }) }
    }

    # 16 scheduled-task trims, all individually reversible and hidden when absent.
    $tasks = @(
        @{ Id='task-compat-appraiser'; Path='\Microsoft\Windows\Application Experience\Microsoft Compatibility Appraiser'; Name='Disable Compatibility Appraiser task'; Desc='Stops the scheduled compatibility inventory scan. Windows Update compatibility checks may have less background telemetry/inventory data.' },
        @{ Id='task-programdata-updater'; Path='\Microsoft\Windows\Application Experience\ProgramDataUpdater'; Name='Disable ProgramDataUpdater task'; Desc='Stops a scheduled application-compatibility inventory update task.' },
        @{ Id='task-startup-app'; Path='\Microsoft\Windows\Application Experience\StartupAppTask'; Name='Disable StartupAppTask'; Desc='Stops a scheduled task that scans startup applications for compatibility/experience data.' },
        @{ Id='task-autochk-proxy'; Path='\Microsoft\Windows\Autochk\Proxy'; Name='Disable Autochk Proxy telemetry task'; Desc='Stops the Autochk proxy scheduled task used for compatibility/telemetry processing. It does not disable CHKDSK itself.' },
        @{ Id='task-ceip-consolidator'; Path='\Microsoft\Windows\Customer Experience Improvement Program\Consolidator'; Name='Disable CEIP Consolidator task'; Desc='Stops a Customer Experience Improvement Program aggregation task.' },
        @{ Id='task-ceip-kernel'; Path='\Microsoft\Windows\Customer Experience Improvement Program\KernelCeipTask'; Name='Disable Kernel CEIP task'; Desc='Stops the kernel CEIP scheduled reporting task where present.' },
        @{ Id='task-ceip-usb'; Path='\Microsoft\Windows\Customer Experience Improvement Program\UsbCeip'; Name='Disable USB CEIP task'; Desc='Stops scheduled USB usage/compatibility reporting where present.' },
        @{ Id='task-diskdiagnostic-data'; Path='\Microsoft\Windows\DiskDiagnostic\Microsoft-Windows-DiskDiagnosticDataCollector'; Name='Disable Disk Diagnostic data collector'; Desc='Stops the scheduled disk diagnostic telemetry collector. This does not disable SMART or manual disk checks.' },
        @{ Id='task-feedback-dmclient'; Path='\Microsoft\Windows\Feedback\Siuf\DmClient'; Name='Disable Feedback DmClient task'; Desc='Stops a Windows feedback/diagnostic scheduled task.' },
        @{ Id='task-feedback-scenario'; Path='\Microsoft\Windows\Feedback\Siuf\DmClientOnScenarioDownload'; Name='Disable Feedback scenario-download task'; Desc='Stops the feedback scenario download scheduled task.' },
        @{ Id='task-power-analyze'; Path='\Microsoft\Windows\Power Efficiency Diagnostics\AnalyzeSystem'; Name='Disable Power Efficiency AnalyzeSystem task'; Desc='Stops the scheduled power-efficiency analysis pass. Manual powercfg diagnostics still work.' },
        @{ Id='task-maps-update'; Path='\Microsoft\Windows\Maps\MapsUpdateTask'; Name='Disable Maps update task'; Desc='Stops automatic offline Maps updates. Skip if you use Windows offline maps.' },
        @{ Id='task-maps-toast'; Path='\Microsoft\Windows\Maps\MapsToastTask'; Name='Disable Maps notification task'; Desc='Stops the offline Maps notification/toast task.' },
        @{ Id='task-wer-queue'; Path='\Microsoft\Windows\Windows Error Reporting\QueueReporting'; Name='Disable queued error-report task'; Desc='Stops scheduled submission of queued Windows Error Reporting data.' },
        @{ Id='task-family-monitor'; Path='\Microsoft\Windows\Shell\FamilySafetyMonitor'; Name='Disable Family Safety monitor task'; Desc='Stops the Family Safety monitor task. Do not apply when Microsoft Family Safety is intentionally used on this PC.' },
        @{ Id='task-family-refresh'; Path='\Microsoft\Windows\Shell\FamilySafetyRefreshTask'; Name='Disable Family Safety refresh task'; Desc='Stops the Family Safety refresh task. Skip when Family Safety controls are in use.' }
    )
    foreach ($x in $tasks) {
        $taskPath = [string]$x.Path
        $folder = Split-Path -Path $taskPath -Parent
        $taskName = Split-Path -Path $taskPath -Leaf
        $taskFolder = $folder.TrimEnd('\') + '\'
        $guard = { return [bool](Get-ScheduledTask -TaskName $taskName -TaskPath $taskFolder -ErrorAction SilentlyContinue) }.GetNewClosure()
        $apply = {
            $touched = Disable-ScheduledTaskList @($taskPath)
            if (@($touched).Count -eq 0) { throw 'The task is already disabled or Windows did not allow it to be changed.' }
            return @{ Tasks=@($touched) }
        }.GetNewClosure()
        $undo = { param($D) Enable-ScheduledTaskList @($D.Tasks) }.GetNewClosure()
        $test = {
            $t = Get-ScheduledTask -TaskName $taskName -TaskPath $taskFolder -ErrorAction SilentlyContinue
            return [bool]($t -and $t.State -eq 'Disabled')
        }.GetNewClosure()
        $out += @{ Id=$x.Id; Category='debloat'; Group='Individual scheduled tasks'; Name=$x.Name; Risk='Low'; Recommended=$false; Desc=($x.Desc + ' Undo re-enables it only if Compact Tweaks disabled it.'); Guard=$guard; Apply=$apply; Undo=$undo; Test=$test }
    }

    # 6 NIC advanced-property options. These appear only when the active hardware exposes
    # the standard registry keyword. Applying/undoing restarts the affected adapter briefly.
    $nic = @(
        @{ Id='nic-eee-off-v08'; Keyword='*EEE'; Name='Disable Energy Efficient Ethernet (EEE)'; Desc='Stops supported Ethernet adapters entering low-power idle link states. It can help consistency on some adapters, at the cost of slightly higher power use.' },
        @{ Id='nic-arp-offload-off'; Keyword='*PMARPOffload'; Name='Disable ARP offload'; Desc='Stops the NIC from answering ARP while the system is in low-power states. Mainly a power-management feature; disabling it can simplify adapter behavior on a gaming desktop.' },
        @{ Id='nic-ns-offload-off'; Keyword='*PMNSOffload'; Name='Disable NS offload'; Desc='Stops IPv6 Neighbor Solicitation offload used for low-power states. Mainly a power-management tweak rather than a throughput tweak.' },
        @{ Id='nic-packet-coalescing-off'; Keyword='*PacketCoalescing'; Name='Disable NIC packet coalescing'; Desc='Stops supported adapters from batching packets for power savings. This can reduce batching latency on hardware that exposes the option, with higher CPU/power use.' },
        @{ Id='nic-tcp-checksum-v4-off'; Keyword='*TCPChecksumOffloadIPv4'; Name='Disable TCP checksum offload (IPv4)'; Desc='Moves TCP checksum work back to the CPU instead of the NIC. This may reduce driver/offload quirks but can also increase CPU use, so benchmark before keeping it.' },
        @{ Id='nic-udp-checksum-v4-off'; Keyword='*UDPChecksumOffloadIPv4'; Name='Disable UDP checksum offload (IPv4)'; Desc='Moves UDP checksum work back to the CPU. Some users test this for latency consistency; on many systems leaving offload enabled is faster. Benchmark both.' }
    )
    foreach ($x in $nic) {
        $kw = [string]$x.Keyword
        $guard = { return (@(Get-NicAdvancedByKeyword $kw).Count -gt 0) }.GetNewClosure()
        $apply = {
            $props = @(Get-NicAdvancedByKeyword $kw)
            if ($props.Count -eq 0) { throw ('No adapter exposes ' + $kw) }
            $saved = @(); $restart = @()
            foreach ($p in $props) {
                $saved += @{ Name=[string]$p.Name; Keyword=$kw; Value=@($p.RegistryValue) }
                Set-NetAdapterAdvancedProperty -Name $p.Name -RegistryKeyword $kw -RegistryValue 0 -NoRestart -ErrorAction Stop
                $restart += [string]$p.Name
            }
            foreach ($n in @($restart | Select-Object -Unique)) { Restart-NetAdapter -Name $n -Confirm:$false -ErrorAction SilentlyContinue }
            return @{ Items=$saved }
        }.GetNewClosure()
        $undo = {
            param($D)
            $restart = @()
            foreach ($p in @($D.Items)) {
                Set-NetAdapterAdvancedProperty -Name ([string]$p.Name) -RegistryKeyword ([string]$p.Keyword) -RegistryValue @($p.Value) -NoRestart -ErrorAction SilentlyContinue
                $restart += [string]$p.Name
            }
            foreach ($n in @($restart | Select-Object -Unique)) { Restart-NetAdapter -Name $n -Confirm:$false -ErrorAction SilentlyContinue }
        }.GetNewClosure()
        $test = {
            $props = @(Get-NicAdvancedByKeyword $kw)
            if ($props.Count -eq 0) { return $false }
            foreach ($p in $props) { if ([string](@($p.RegistryValue)[0]) -ne '0') { return $false } }
            return $true
        }.GetNewClosure()
        $out += @{ Id=$x.Id; Category='net'; Group='Adapter advanced properties'; Name=$x.Name; Risk='Medium'; Recommended=$false; Desc=($x.Desc + ' The network adapter restarts briefly when this is applied or undone.'); Guard=$guard; Apply=$apply; Undo=$undo; Test=$test }
    }

    # 8 one-time cache/repair actions. These are troubleshooting tools, not permanent magic-FPS settings.
    $out += @{ Id='cache-epic-web'; Category='extra'; Group='Game and driver caches'; Name='Clear Epic Games Launcher web cache'; Risk='Low'; Recommended=$false; OneShot=$true; Desc='Clears Epic Games Launcher webcache folders. Useful when the launcher is laggy or corrupted; it will rebuild the cache next launch.'; Apply={
        $base = Join-Path $env:LOCALAPPDATA 'EpicGamesLauncher\Saved'
        $found = @(Get-ChildItem -LiteralPath $base -Directory -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -like 'webcache*' })
        if ($found.Count -eq 0) { throw 'No Epic Games Launcher web cache was found.' }
        foreach ($d in $found) { Clear-CacheDirectorySafe $d.FullName ('Epic ' + $d.Name) }
    } }
    $out += @{ Id='cache-dx-shaders'; Category='extra'; Group='Game and driver caches'; Name='Clear DirectX shader cache'; Risk='Medium'; Recommended=$false; OneShot=$true; Desc='Clears the DirectX shader cache. This can fix corrupted/stale shader cache issues after driver or game changes, but the first matches afterwards may stutter more while shaders rebuild.'; Apply={ Clear-CacheDirectorySafe (Join-Path $env:LOCALAPPDATA 'D3DSCache') 'DirectX shader' } }
    $out += @{ Id='cache-nv-dx'; Category='vendor'; Group='NVIDIA maintenance'; Name='Clear NVIDIA DXCache'; Risk='Medium'; Recommended=$false; OneShot=$true; Guard={ Test-HasGpuVendor 'NVIDIA' }; Desc='Clears NVIDIA DirectX shader cache files. Use for troubleshooting driver/game stutter; the cache rebuild can temporarily make the next launches less smooth.'; Apply={ Clear-CacheDirectorySafe (Join-Path $env:LOCALAPPDATA 'NVIDIA\DXCache') 'NVIDIA DXCache' } }
    $out += @{ Id='cache-nv-gl'; Category='vendor'; Group='NVIDIA maintenance'; Name='Clear NVIDIA GLCache'; Risk='Low'; Recommended=$false; OneShot=$true; Guard={ Test-HasGpuVendor 'NVIDIA' }; Desc='Clears NVIDIA OpenGL shader cache files. Mainly a troubleshooting action for OpenGL games/apps.'; Apply={ Clear-CacheDirectorySafe (Join-Path $env:LOCALAPPDATA 'NVIDIA\GLCache') 'NVIDIA GLCache' } }
    $out += @{ Id='cache-amd-dx'; Category='vendor'; Group='AMD maintenance'; Name='Clear AMD DxCache'; Risk='Medium'; Recommended=$false; OneShot=$true; Guard={ Test-HasGpuVendor 'AMD' }; Desc='Clears AMD DirectX shader cache files. Use for troubleshooting after driver/game changes; shaders rebuild afterwards.'; Apply={ Clear-CacheDirectorySafe (Join-Path $env:LOCALAPPDATA 'AMD\DxCache') 'AMD DxCache' } }
    $out += @{ Id='cache-amd-gl'; Category='vendor'; Group='AMD maintenance'; Name='Clear AMD GLCache'; Risk='Low'; Recommended=$false; OneShot=$true; Guard={ Test-HasGpuVendor 'AMD' }; Desc='Clears AMD OpenGL cache files where present. Mainly a troubleshooting action.'; Apply={ Clear-CacheDirectorySafe (Join-Path $env:LOCALAPPDATA 'AMD\GLCache') 'AMD GLCache' } }
    $out += @{ Id='cache-thumbnails'; Category='extra'; Group='Game and driver caches'; Name='Clear Windows thumbnail cache'; Risk='Low'; Recommended=$false; OneShot=$true; Desc='Deletes stale Explorer thumbnail-cache databases where Windows allows it. Thumbnails rebuild automatically.'; Apply={
        $dir = Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Explorer'
        $files = @(Get-ChildItem -LiteralPath $dir -Filter 'thumbcache_*.db' -File -Force -ErrorAction SilentlyContinue)
        if ($files.Count -eq 0) { throw 'No thumbnail cache files were found.' }
        $size = ($files | Measure-Object -Property Length -Sum).Sum
        $files | Remove-Item -Force -ErrorAction SilentlyContinue
        Write-Log ('Thumbnail cache cleanup targeted about {0} MB' -f [math]::Round(([double]$size)/1MB)) 'Ok'
    } }
    $out += @{ Id='cache-delivery-opt'; Category='extra'; Group='Game and driver caches'; Name='Clear Delivery Optimization cache'; Risk='Low'; Recommended=$false; OneShot=$true; Guard={ [bool](Get-Command Delete-DeliveryOptimizationCache -ErrorAction SilentlyContinue) }; Desc='Deletes cached Windows Update Delivery Optimization files. This only frees/cleans cache; Windows downloads anything it still needs later.'; Apply={ Delete-DeliveryOptimizationCache -Force -ErrorAction Stop; Write-Log 'Delivery Optimization cache cleared.' 'Ok' } }

    return $out
}


# ----------------------------------------------------------------------------
# v0.9 CPU/GPU helpers
# ----------------------------------------------------------------------------
function Get-PowerCfgSettingSnapshot {
    param([string]$SubGroup, [string]$Setting)

    $scheme = Get-ActiveSchemeGuid
    if (-not $scheme) { throw 'Could not read the active power plan.' }

    $q = (& powercfg.exe /q $scheme $SubGroup $Setting 2>&1 | Out-String)
    if ($LASTEXITCODE -ne 0) { throw ("Power setting {0}/{1} is not supported on this PC." -f $SubGroup, $Setting) }

    $ac = [regex]::Match($q, '(?m)Current AC Power Setting Index:\s*0x([0-9a-fA-F]+)')
    $dc = [regex]::Match($q, '(?m)Current DC Power Setting Index:\s*0x([0-9a-fA-F]+)')
    if (-not $ac.Success) { throw ("Could not read power setting {0}/{1}." -f $SubGroup, $Setting) }

    $acValue = [Convert]::ToInt32($ac.Groups[1].Value, 16)
    $dcValue = $acValue
    if ($dc.Success) { $dcValue = [Convert]::ToInt32($dc.Groups[1].Value, 16) }

    return @{
        Scheme   = $scheme
        SubGroup = $SubGroup
        Setting  = $Setting
        PrevAc   = $acValue
        PrevDc   = $dcValue
    }
}

function Set-ActivePowerCfgAcValue {
    param([string]$SubGroup, [string]$Setting, [int]$Value)

    $snap = Get-PowerCfgSettingSnapshot $SubGroup $Setting
    $msg = (& powercfg.exe /setacvalueindex $snap.Scheme $SubGroup $Setting $Value 2>&1 | Out-String)
    if ($LASTEXITCODE -ne 0) { throw ("powercfg could not set {0}: {1}" -f $Setting, $msg.Trim()) }

    & powercfg.exe /setactive $snap.Scheme | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'powercfg could not reactivate the current power plan.' }

    return $snap
}

function Restore-PowerCfgAcValue {
    param($Data)
    if (-not $Data) { return }

    & powercfg.exe /setacvalueindex ([string]$Data.Scheme) ([string]$Data.SubGroup) ([string]$Data.Setting) ([string][int]$Data.PrevAc) | Out-Null
    if ((Get-ActiveSchemeGuid) -eq [string]$Data.Scheme) {
        & powercfg.exe /setactive ([string]$Data.Scheme) | Out-Null
    }
}

function Test-PowerCfgAcValue {
    param([string]$SubGroup, [string]$Setting, [int]$Value)
    try {
        $s = Get-PowerCfgSettingSnapshot $SubGroup $Setting
        return ([int]$s.PrevAc -eq $Value)
    } catch { return $false }
}

function Test-PowerCfgSettingAvailable {
    param([string]$SubGroup, [string]$Setting)
    try {
        [void](Get-PowerCfgSettingSnapshot $SubGroup $Setting)
        return $true
    } catch { return $false }
}

function Get-MinecraftJavaExecutables {
    $found = @()

    # Running Java games/clients.
    foreach ($p in @(Get-Process -Name 'javaw' -ErrorAction SilentlyContinue)) {
        try {
            if ($p.Path -and (Test-Path -LiteralPath $p.Path)) { $found += $p.Path }
        } catch { }
    }

    # Minecraft Launcher runtime and Lunar Client runtimes.
    $roots = @(
        (Join-Path $env:APPDATA '.minecraft\runtime'),
        (Join-Path $env:USERPROFILE '.lunarclient\jre')
    )

    foreach ($root in $roots) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        try {
            $found += @(Get-ChildItem -LiteralPath $root -Filter 'javaw.exe' -File -Recurse -ErrorAction SilentlyContinue |
                Select-Object -First 24 -ExpandProperty FullName)
        } catch { }
    }

    return @($found | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -Unique)
}

function Set-HighPerformanceGpuPreference {
    param([string[]]$Paths)

    $paths2 = @($Paths | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -Unique)
    if ($paths2.Count -eq 0) { throw 'No matching game executable was found.' }

    $reg = 'HKCU:\Software\Microsoft\DirectX\UserGpuPreferences'
    $saved = @()

    foreach ($exe in $paths2) {
        $snap = Get-RegSnapshot $reg $exe
        Set-RegValue -Path $reg -Name $exe -Type 'String' -Value 'GpuPreference=2;'
        $saved += $snap
    }

    return @{ Saved = $saved; Paths = $paths2 }
}

function Test-HighPerformanceGpuPreference {
    param([string[]]$Paths)

    $paths2 = @($Paths | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -Unique)
    if ($paths2.Count -eq 0) { return $false }

    $reg = 'HKCU:\Software\Microsoft\DirectX\UserGpuPreferences'
    foreach ($exe in $paths2) {
        $s = Get-RegSnapshot $reg $exe
        if (-not $s.Existed -or ([string]$s.Value) -notmatch 'GpuPreference=2;') { return $false }
    }
    return $true
}

$script:Tweaks = @(

    # ================================ CPU OPTIMIZATIONS ================================
    @{ Id = 'powerplan'; Category = 'cpu'; Group = 'Power'; Name = 'Compact Free Power Plan'; Risk = 'Medium'; Recommended = $false
       Desc = 'Optimized for multiple tasks. A copy of Windows Ultimate Performance (or High Performance if Ultimate is unavailable) that never throttles the CPU, good for gaming alongside Discord, OBS, a browser and so on running at the same time. Windows only keeps ONE power plan active at a time, so if you also apply Compact Focus Power Plan below, whichever you activate last is the one your PC actually uses. Undo switches back to your previous plan and deletes this one.'
       Apply = {
           $prev = Get-ActiveSchemeGuid
           $new  = $null
           foreach ($src in @('e9a42b02-d5df-448d-aa00-03f14749eb61', '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c')) {
               $out = (& powercfg.exe -duplicatescheme $src 2>&1 | Out-String)
               if ($LASTEXITCODE -eq 0 -and $out -match '([0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12})') { $new = $Matches[1]; break }
           }
           if (-not $new) { throw 'This PC does not allow a high-performance power scheme to be created.' }
           & powercfg.exe /changename $new 'Compact Free Power Plan' 'Optimized for multiple tasks' | Out-Null
           & powercfg.exe /setactive $new | Out-Null
           if ($LASTEXITCODE -ne 0) { throw 'powercfg could not activate the new power scheme.' }
           return @{ Previous = $prev; Created = $new }
       }
       Undo = {
           param($Data)
           if ($Data.Previous) { & powercfg.exe /setactive $Data.Previous | Out-Null }
           if ($Data.Created)  { & powercfg.exe /delete $Data.Created | Out-Null }
       }
       Test = {
           $st = $script:State['powerplan']
           return [bool]($st -and $st.Custom -and ((Get-ActiveSchemeGuid) -eq $st.Custom.Created))
       } },

    @{ Id = 'powerplan-focus'; Category = 'cpu'; Group = 'Power'; Name = 'Compact Focus Power Plan'; Risk = 'Medium'; Recommended = $false
       Desc = 'Optimized to focus only on the main tasks. Same base as Compact Free Power Plan, plus the minimum processor state forced to 100 percent so the CPU never idles down, best when one demanding game or app is all that matters. Windows only keeps ONE power plan active at a time, so if you also apply Compact Free Power Plan, whichever you activate last is the one your PC actually uses. Uses more power and runs hotter at idle than Compact Free. Undo switches back to your previous plan and deletes this one.'
       Apply = {
           $prev = Get-ActiveSchemeGuid
           $new  = $null
           foreach ($src in @('e9a42b02-d5df-448d-aa00-03f14749eb61', '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c')) {
               $out = (& powercfg.exe -duplicatescheme $src 2>&1 | Out-String)
               if ($LASTEXITCODE -eq 0 -and $out -match '([0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12})') { $new = $Matches[1]; break }
           }
           if (-not $new) { throw 'This PC does not allow a high-performance power scheme to be created.' }
           & powercfg.exe /changename $new 'Compact Focus Power Plan' 'Optimized to focus only on the main tasks.' | Out-Null
           & powercfg.exe /setacvalueindex $new SUB_PROCESSOR PROCTHROTTLEMIN 100 | Out-Null
           & powercfg.exe /setdcvalueindex $new SUB_PROCESSOR PROCTHROTTLEMIN 100 | Out-Null
           & powercfg.exe /setactive $new | Out-Null
           if ($LASTEXITCODE -ne 0) { throw 'powercfg could not activate the new power scheme.' }
           return @{ Previous = $prev; Created = $new }
       }
       Undo = {
           param($Data)
           if ($Data.Previous) { & powercfg.exe /setactive $Data.Previous | Out-Null }
           if ($Data.Created)  { & powercfg.exe /delete $Data.Created | Out-Null }
       }
       Test = {
           $st = $script:State['powerplan-focus']
           return [bool]($st -and $st.Custom -and ((Get-ActiveSchemeGuid) -eq $st.Custom.Created))
       } },

    @{ Id = 'perfboost-policy'; Category = 'cpu'; Group = 'Power'; Name = 'Aggressive processor performance boost policy'; Risk = 'Medium'; Recommended = $false
       Desc = 'Sets the active power plan processor boost policy (PERFBOOSTPOL) to its most aggressive value, so the CPU is quicker to jump to a higher clock under load. This applies to whichever power plan is active right now, so apply it after choosing your plan. Undo restores the previous value.'
       Apply = {
           $scheme = Get-ActiveSchemeGuid
           if (-not $scheme) { throw 'Could not read the active power plan.' }
           $ac = (& powercfg.exe /q $scheme SUB_PROCESSOR PERFBOOSTPOL | Out-String)
           $prevAc = 0; $m = [regex]::Match($ac, '(?m)Current AC Power Setting Index:\s*0x([0-9a-fA-F]+)'); if ($m.Success) { $prevAc = [Convert]::ToInt32($m.Groups[1].Value, 16) }
           $prevDc = 0; $m2 = [regex]::Match($ac, '(?m)Current DC Power Setting Index:\s*0x([0-9a-fA-F]+)'); if ($m2.Success) { $prevDc = [Convert]::ToInt32($m2.Groups[1].Value, 16) }
           & powercfg.exe /setacvalueindex $scheme SUB_PROCESSOR PERFBOOSTPOL 100 | Out-Null
           & powercfg.exe /setdcvalueindex $scheme SUB_PROCESSOR PERFBOOSTPOL 100 | Out-Null
           & powercfg.exe /setactive $scheme | Out-Null
           return @{ Scheme = $scheme; PrevAc = $prevAc; PrevDc = $prevDc }
       }
       Undo = {
           param($D)
           & powercfg.exe /setacvalueindex ([string]$D.Scheme) SUB_PROCESSOR PERFBOOSTPOL ([string][int]$D.PrevAc) | Out-Null
           & powercfg.exe /setdcvalueindex ([string]$D.Scheme) SUB_PROCESSOR PERFBOOSTPOL ([string][int]$D.PrevDc) | Out-Null
           & powercfg.exe /setactive ([string]$D.Scheme) | Out-Null
       }
       Test = {
           $scheme = Get-ActiveSchemeGuid
           if (-not $scheme) { return $false }
           $out = (& powercfg.exe /q $scheme SUB_PROCESSOR PERFBOOSTPOL | Out-String)
           $m = [regex]::Match($out, '(?m)Current AC Power Setting Index:\s*0x([0-9a-fA-F]+)')
           return [bool]($m.Success -and [Convert]::ToInt32($m.Groups[1].Value, 16) -eq 100)
       } },

    @{ Id = 'power-throttling'; Category = 'cpu'; Group = 'Power'; Name = 'Turn off power throttling'; Risk = 'Medium'; Recommended = $false
       Desc = 'Stops Windows from slowing background processes to save power. No real effect on a desktop; on a laptop it reduces battery life.'
       Restart = 'restart'
       Registry = @( (New-RegEntry 'HKLM:\SYSTEM\CurrentControlSet\Control\Power\PowerThrottling' 'PowerThrottlingOff' 'DWord' 1) ) },

    @{ Id = 'game-priority'; IsLaptopSafe = $true; Category = 'cpu'; Group = 'Game priority'; Name = 'Fortnite priority: Above Normal'; Risk = 'Low'; Recommended = $true
       Desc = 'Starts Fortnite at Above Normal CPU priority using the built-in Windows per-program setting (Image File Execution Options). Nothing touches the game itself, and it is never set to High or Realtime. The reference research found no ban evidence with Easy Anti-Cheat. Only Fortnite is covered.'
       Restart = 'restart'
       Registry = @( (New-RegEntry $ifeo 'CpuPriorityClass' 'DWord' 6) ) },

    @{ Id = 'game-io'; IsLaptopSafe = $true; Category = 'cpu'; Group = 'Game priority'; Name = 'Fortnite disk priority boost (I/O)'; Risk = 'Low'; Recommended = $false
       Desc = 'Gives Fortnite High disk (I/O) priority so loading and streaming are not held up by background disk work such as updates and scans. Same per-program Windows setting as above. The gain is mostly on slower drives.'
       Restart = 'restart'
       Registry = @( (New-RegEntry $ifeo 'IoPriority' 'DWord' 3) ) },

    @{ Id = 'proc-lower'; IsLaptopSafe = $true; Category = 'cpu'; Group = 'Background processes'; Name = 'Lower background process priority'; Risk = 'Low'; Recommended = $false
       Desc = 'Sets your background apps (browsers, updaters, launchers) to Below Normal priority so your game gets the CPU first. System processes, anti-cheat, voice chat, recording apps, Fortnite and Epic are never touched. Windows forgets the change when an app restarts, so run it right before you play. Undo puts them back to Normal.'
       Apply = {
           $me = [System.Diagnostics.Process]::GetCurrentProcess()
           $lowered = @()
           foreach ($p in [System.Diagnostics.Process]::GetProcesses()) {
               try {
                   if ($p.SessionId -ne $me.SessionId -or $p.Id -eq $me.Id) { continue }
                   $n = $p.ProcessName
                   if (($script:NeverLower -contains $n) -or ($script:KeepNormal -contains $n)) { continue }
                   if ($p.PriorityClass -ne [System.Diagnostics.ProcessPriorityClass]::Normal) { continue }
                   $p.PriorityClass = [System.Diagnostics.ProcessPriorityClass]::BelowNormal
                   $lowered += @{ Id = $p.Id; Name = $n; Start = $p.StartTime.ToFileTimeUtc() }
               } catch { } finally { $p.Dispose() }
           }
           if ($lowered.Count -eq 0) { throw 'No background processes could be lowered (nothing eligible was running).' }
           Write-Log ('Lowered the priority of {0} background process(es)' -f $lowered.Count) 'Ok'
           return @{ Lowered = $lowered }
       }
       Undo = {
           param($Data)
           $back = 0
           foreach ($x in @($Data.Lowered)) {
               $p = Get-Process -Id $x.Id -ErrorAction SilentlyContinue
               if ($p) {
                   try { if ($p.StartTime.ToFileTimeUtc() -eq [int64]$x.Start) { $p.PriorityClass = [System.Diagnostics.ProcessPriorityClass]::Normal; $back++ } } catch { }
               }
           }
           Write-Log ('Put {0} process(es) back to Normal priority' -f $back)
       }
       Test = { return $script:State.ContainsKey('proc-lower') } },

    @{ Id = 'last-access'; IsLaptopSafe = $true; Category = 'cpu'; Group = 'Storage (I/O)'; Name = 'Faster file access (no last-access timestamps)'; Risk = 'Low'; Recommended = $true
       Desc = 'Stops NTFS from writing a last-accessed time every time a file is read. Fewer small disk writes; almost nothing depends on that timestamp.'
       Restart = 'restart'
       Registry = @( (New-RegEntry 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' 'NtfsDisableLastAccessUpdate' 'DWord' 1) ) },

    @{ Id = 'timer-res'; Category = 'cpu'; Group = 'Latency and kernel'; Name = 'Global timer resolution (Windows 11)'; Risk = 'Low'; Recommended = $false
       Desc = 'Sets GlobalTimerResolutionRequests so one program asking for a fine timer applies system-wide again. Windows 11 only. The author of the reference tool for this key says it is for debugging, so expect little or no change in games; it can slightly raise idle power use.'
       Restart = 'restart'
       Guard = { (Get-WinBuild) -ge 22000 }
       Registry = @( (New-RegEntry 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\kernel' 'GlobalTimerResolutionRequests' 'DWord' 1) ) },

    @{ Id = 'mmcss'; Category = 'cpu'; Group = 'Little or no effect'; Name = 'Optimize MMCSS (multimedia scheduler)'; Risk = 'Low'; Recommended = $false; Unproven = $true
       Desc = 'Sets SystemResponsiveness = 10 and raises the Games scheduling class. Microsoft documents GPU Priority and SFIO Priority as unused by modern schedulers, values below 10 are clamped, and Fortnite does not register with this scheduler at all, so expect no change. Fully reversible.'
       Restart = 'restart'
       Registry = @(
           (New-RegEntry $mm 'SystemResponsiveness' 'DWord' 10),
           (New-RegEntry "$mm\Tasks\Games" 'GPU Priority' 'DWord' 8),
           (New-RegEntry "$mm\Tasks\Games" 'Priority' 'DWord' 6),
           (New-RegEntry "$mm\Tasks\Games" 'Scheduling Category' 'String' 'High'),
           (New-RegEntry "$mm\Tasks\Games" 'SFIO Priority' 'String' 'High'),
           (New-RegEntry "$mm\Tasks\Games" 'Latency Sensitive' 'String' 'True')
       ) },

    @{ Id = 'prio-sep'; Category = 'cpu'; Group = 'Little or no effect'; Name = 'Foreground priority boost (Win32PrioritySeparation)'; Risk = 'Low'; Recommended = $false; Unproven = $true
       Desc = 'Sets Win32PrioritySeparation to 0x26. This is already the client default on most Windows installs, so expect no change.'
       Restart = 'restart'
       Registry = @( (New-RegEntry 'HKLM:\SYSTEM\CurrentControlSet\Control\PriorityControl' 'Win32PrioritySeparation' 'DWord' 38) ) },

    @{ Id = 'paging-exec'; Category = 'cpu'; Group = 'Little or no effect'; Name = 'Keep kernel and drivers in RAM (DisablePagingExecutive)'; Risk = 'Medium'; Recommended = $false; Unproven = $true
       Desc = 'An old NT-era key with no effect on modern kernels. It is harmless with 16 GB of RAM or more but can add memory pressure on 8 GB.'
       Restart = 'restart'
       Registry = @( (New-RegEntry $memMgmt 'DisablePagingExecutive' 'DWord' 1) ) },

    @{ Id = 'mitigations'; Category = 'cpu'; Group = 'Security trade-offs'; Name = 'Turn off CPU vulnerability mitigations (Spectre / Meltdown)'; Risk = 'High'; Recommended = $false
       Desc = 'Uses a Microsoft documented switch (FeatureSettingsOverride) to turn off the Spectre variant 2 and Meltdown workarounds. The measured gain is roughly zero on modern CPUs, the security loss is real, and some anti-cheats refuse to run with it off. Most people should leave this off (the default). It does NOT touch DEP, ASLR or Exploit Protection.'
       Restart = 'restart'
       Registry = @(
           (New-RegEntry $memMgmt 'FeatureSettingsOverride' 'DWord' 3),
           (New-RegEntry $memMgmt 'FeatureSettingsOverrideMask' 'DWord' 3)
       ) },

    @{ Id = 'hvci'; Category = 'cpu'; Group = 'Security trade-offs'; Name = 'Turn off Memory Integrity (core isolation)'; Risk = 'High'; Recommended = $false
       Desc = 'Turns off Memory Integrity (Core isolation). This is the one item here with a real, measured gain: about 5 percent on average and up to 10 percent or more in CPU-bound games. The cost is losing a strong protection against malicious drivers. Anti-cheat rules can change, so if a game stops launching afterwards, turn it back on first.'
       Restart = 'restart'
       Registry = @( (New-RegEntry 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity' 'Enabled' 'DWord' 0) ) },

    @{ Id = 'sysmain-off'; IsLaptopSafe = $true; Category = 'cpu'; Group = 'Storage (I/O)'; Name = 'Turn off SysMain (Superfetch)'; Risk = 'Low'; Recommended = $false
       Desc = 'Stops SysMain, the service that pre-loads your most used apps into RAM. On an SSD with plenty of RAM it does little and costs some background disk and CPU work. On a hard drive, apps can open more slowly without it. Undo restores the original start mode.'
       Services = @( @{ Name = 'SysMain'; Mode = 'Disabled' } ) },

    @{ Id = 'dyntick'; Category = 'cpu'; Group = 'Latency and kernel'; Name = 'Turn off dynamic timer tick (bcdedit)'; Risk = 'Medium'; Recommended = $false
       Desc = 'Runs bcdedit /set disabledynamictick yes, so Windows stops skipping timer ticks while idle. Microsoft describes this as a debugging option; in practice the effect on games is small to none and idle power use goes up. If BitLocker is on, protection is suspended for one restart so Windows does not ask for your recovery key. Undo restores the original boot setting.'
       Restart = 'restart'
       Apply = {
           $prev = Get-BcdFlag 'disabledynamictick'
           $susp = Suspend-BitLockerForBoot
           & bcdedit.exe /set disabledynamictick yes | Out-Null
           if ($LASTEXITCODE -ne 0) { throw 'bcdedit could not change the boot setting. A policy or Secure Boot configuration may be blocking it.' }
           return @{ Prev = $prev; Suspended = $susp }
       }
       Undo = {
           param($D)
           [void](Suspend-BitLockerForBoot)
           if ($null -ne $D.Prev -and [string]$D.Prev -ne '') { & bcdedit.exe /set disabledynamictick ([string]$D.Prev) | Out-Null }
           else { & bcdedit.exe /deletevalue disabledynamictick | Out-Null }
       }
       Test = {
           $f = Get-BcdFlag 'disabledynamictick'
           return [bool]($f -and ($f -match '^(?i:yes|true)$'))
       } },


    # ============================ NEW v0.9: CPU PERFORMANCE ============================
    @{ Id = 'cpu-epp-maxperf'; Category = 'cpu'; Group = 'Processor response'; Name = 'CPU energy preference: Maximum performance'; Risk = 'Medium'; Recommended = $false
       Guard = { Test-PowerCfgSettingAvailable 'SUB_PROCESSOR' 'PERFEPP' }
       Desc = 'Sets the active power plan AC processor Energy Performance Preference (EPP) to 0, which tells modern CPPC/HWP-capable CPUs to favor performance instead of efficiency. This can make boost response more aggressive, but increases idle/low-load power and heat. Plugged-in setting only; battery behavior is left untouched.'
       Apply = { Set-ActivePowerCfgAcValue 'SUB_PROCESSOR' 'PERFEPP' 0 }
       Undo = { param($D) Restore-PowerCfgAcValue $D }
       Test = { Test-PowerCfgAcValue 'SUB_PROCESSOR' 'PERFEPP' 0 } },

    @{ Id = 'cpu-minstate-100-ac'; Category = 'cpu'; Group = 'Processor response'; Name = 'Minimum processor state: 100% (AC)'; Risk = 'Medium'; Recommended = $false
       Guard = { Test-PowerCfgSettingAvailable 'SUB_PROCESSOR' 'PROCTHROTTLEMIN' }
       Desc = 'Sets the active power plan minimum processor performance state to 100% while plugged in. It reduces frequency down-clocking requested by the Windows power plan and can improve consistency on some CPU-bound workloads, but usually raises idle temperature and power use. This does not overclock the CPU.'
       Apply = { Set-ActivePowerCfgAcValue 'SUB_PROCESSOR' 'PROCTHROTTLEMIN' 100 }
       Undo = { param($D) Restore-PowerCfgAcValue $D }
       Test = { Test-PowerCfgAcValue 'SUB_PROCESSOR' 'PROCTHROTTLEMIN' 100 } },

    @{ Id = 'cpu-maxstate-100-ac'; IsLaptopSafe = $true; Category = 'cpu'; Group = 'Processor response'; Name = 'Maximum processor state: 100% (AC)'; Risk = 'Low'; Recommended = $false
       Guard = { Test-PowerCfgSettingAvailable 'SUB_PROCESSOR' 'PROCTHROTTLEMAX' }
       Desc = 'Makes sure the active power plan is not capping the CPU below its full performance state while plugged in. This is normally already 100%, but some battery-saving or custom plans lower it. It does not raise clocks beyond the CPU firmware limits.'
       Apply = { Set-ActivePowerCfgAcValue 'SUB_PROCESSOR' 'PROCTHROTTLEMAX' 100 }
       Undo = { param($D) Restore-PowerCfgAcValue $D }
       Test = { Test-PowerCfgAcValue 'SUB_PROCESSOR' 'PROCTHROTTLEMAX' 100 } },

    @{ Id = 'cpu-boostmode-aggressive'; Category = 'cpu'; Group = 'Processor boost'; Name = 'Processor boost mode: Aggressive'; Risk = 'Medium'; Recommended = $false
       Guard = { Test-PowerCfgSettingAvailable 'SUB_PROCESSOR' 'PERFBOOSTMODE' }
       Desc = 'Sets Windows Processor Performance Boost Mode to Aggressive (index 2) on AC power. On supported non-autonomous CPPC/P-state systems this asks for stronger boost behavior; on some autonomous CPPC systems the hardware may treat it the same as normal boost. More boost can mean more heat and fan noise.'
       Apply = { Set-ActivePowerCfgAcValue 'SUB_PROCESSOR' 'PERFBOOSTMODE' 2 }
       Undo = { param($D) Restore-PowerCfgAcValue $D }
       Test = { Test-PowerCfgAcValue 'SUB_PROCESSOR' 'PERFBOOSTMODE' 2 } },

    @{ Id = 'cpu-autonomous-window-fast'; Category = 'cpu'; Group = 'Processor response'; Name = 'CPPC autonomous activity window: Fast response'; Risk = 'Medium'; Recommended = $false
       Guard = { Test-PowerCfgSettingAvailable 'SUB_PROCESSOR' 'PERFAUTONOMOUSWINDOW' }
       Desc = 'Sets the CPPC autonomous activity window to 0 microseconds on AC power. Windows documents longer windows as making the platform less sensitive to short CPU-load spikes, so this uses the shortest value for maximum responsiveness. Only affects CPUs/platforms that support CPPC v2 autonomous mode; unsupported systems ignore or hide it.'
       Apply = { Set-ActivePowerCfgAcValue 'SUB_PROCESSOR' 'PERFAUTONOMOUSWINDOW' 0 }
       Undo = { param($D) Restore-PowerCfgAcValue $D }
       Test = { Test-PowerCfgAcValue 'SUB_PROCESSOR' 'PERFAUTONOMOUSWINDOW' 0 } },

    # ================================ GPU OPTIMIZATIONS ================================

    # ============================ NEW v0.9: GPU PERFORMANCE ============================
    @{ Id = 'gpu-minecraft-highperf'; IsLaptopSafe = $true; Category = 'gpu'; Group = 'Per-game GPU preference'; Name = 'Minecraft / Lunar: use the high-performance GPU'; Risk = 'Low'; Recommended = $false
       Guard = { (@(Get-MinecraftJavaExecutables).Count -gt 0) }
       Desc = 'Sets detected Minecraft Java runtimes, including common Minecraft Launcher and Lunar Client runtimes, to High performance in Windows Graphics preferences. This is useful on systems with both integrated and dedicated graphics; on a single-GPU desktop it is usually a no-op.'
       Apply = { Set-HighPerformanceGpuPreference (Get-MinecraftJavaExecutables) }
       Undo = { param($D) foreach ($s in @($D.Saved)) { if ($s) { Restore-RegSnapshot $s } } }
       Test = { Test-HighPerformanceGpuPreference (Get-MinecraftJavaExecutables) } },

    @{ Id = 'gpu-autohdr-off'; IsLaptopSafe = $true; Category = 'gpu'; Group = 'Graphics features'; Name = 'Disable Auto HDR for games'; Risk = 'Low'; Recommended = $false
       Desc = 'Turns off Windows Auto HDR in the DirectX global graphics settings while preserving the other values in that setting. This can remove HDR conversion work and avoid HDR-related presentation issues if you do not use Auto HDR. It is not a guaranteed FPS increase.'
       Apply = {
           $path = 'HKCU:\Software\Microsoft\DirectX\UserGpuPreferences'
           $name = 'DirectXUserGlobalSettings'
           $snap = Get-RegSnapshot $path $name
           $cur = ''; if ($snap.Existed) { $cur = [string]$snap.Value }
           if ($cur -match 'AutoHDREnable=\d;') { $new = $cur -replace 'AutoHDREnable=\d;', 'AutoHDREnable=0;' }
           else { $new = $cur + 'AutoHDREnable=0;' }
           Set-RegValue -Path $path -Name $name -Type 'String' -Value $new
           return @{ Saved = @($snap) }
       }
       Undo = { param($D) foreach ($s in @($D.Saved)) { if ($s) { Restore-RegSnapshot $s } } }
       Test = {
           $s = Get-RegSnapshot 'HKCU:\Software\Microsoft\DirectX\UserGpuPreferences' 'DirectXUserGlobalSettings'
           return [bool]($s.Existed -and ([string]$s.Value) -match 'AutoHDREnable=0;')
       } },

    @{ Id = 'gpu-mpo-off'; Category = 'gpu'; Group = 'Stutter troubleshooting'; Name = 'Disable Multi-Plane Overlay (MPO)'; Risk = 'Medium'; Recommended = $false; Unproven = $true
       Desc = 'Applies the NVIDIA-documented Windows MPO workaround (OverlayTestMode=5). It can fix flicker, black-screen or presentation stutter on affected systems, but MPO normally exists to improve composition performance and latency, so do not treat this as a universal FPS boost. Restart required; Undo removes/restores the exact previous registry value.'
       Restart = 'restart'
       Registry = @( (New-RegEntry 'HKLM:\SOFTWARE\Microsoft\Windows\Dwm' 'OverlayTestMode' 'DWord' 5) ) },

    @{ Id = 'nv-frameview-off'; Category = 'vendor'; Group = 'NVIDIA debloat'; Name = 'Disable NVIDIA FrameView SDK service'; Risk = 'Low'; Recommended = $false
       Guard = { (Test-HasGpuVendor 'NVIDIA') -and [bool](Get-Service -Name 'FvSvc' -ErrorAction SilentlyContinue) }
       Desc = 'Disables the NVIDIA FrameView SDK service when it is installed. The service supports performance/telemetry overlays and is not the display driver itself. This only removes a small background process; if you use FrameView or an overlay that depends on it, leave this off.'
       Services = @( @{ Name = 'FvSvc'; Mode = 'Disabled' } ) },

    @{ Id = 'game-mode'; IsLaptopSafe = $true; Category = 'gpu'; Group = 'Game features'; Name = 'Enable Game Mode'; Risk = 'Low'; Recommended = $true
       Desc = 'Tells Windows to prioritise the game you are playing and hold back background updates and driver installs while it runs. Results vary, but the default is on and it is safe.'
       Registry = @(
           (New-RegEntry 'HKCU:\Software\Microsoft\GameBar' 'AutoGameModeEnabled' 'DWord' 1),
           (New-RegEntry 'HKCU:\Software\Microsoft\GameBar' 'AllowAutoGameMode' 'DWord' 1)
       ) },

    @{ Id = 'game-dvr'; IsLaptopSafe = $true; Category = 'gpu'; Group = 'Game features'; Name = 'Disable Game DVR'; Risk = 'Low'; Recommended = $true
       Desc = 'Turns off Xbox Game Bar background capture (Game DVR) for you and by policy. Background capture is a real video-encode pipeline, so this removes a small performance and stutter cost. You can still record with other tools.'
       Registry = @(
           (New-RegEntry 'HKCU:\System\GameConfigStore' 'GameDVR_Enabled' 'DWord' 0),
           (New-RegEntry 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR' 'AppCaptureEnabled' 'DWord' 0),
           (New-RegEntry 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR' 'AllowGameDVR' 'DWord' 0)
       ) },

    @{ Id = 'hags'; Category = 'gpu'; Group = 'Graphics tweaks'; Name = 'Hardware-accelerated GPU scheduling'; Risk = 'Medium'; Recommended = $false
       Desc = 'Lets the GPU manage its own memory scheduling. Measured FPS change is about zero on average; the real reasons to turn it on are DLSS Frame Generation and newer flip-queue features. It can raise VRAM use on small cards, so test it and undo if games get worse.'
       Restart = 'restart'
       Registry = @( (New-RegEntry 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' 'HwSchMode' 'DWord' 2) ) },

    @{ Id = 'fso-off'; Category = 'gpu'; Group = 'Fullscreen tweaks'; Name = 'Turn off fullscreen optimizations (DirectX 9 and 11 games)'; Risk = 'Low'; Recommended = $false
       Desc = 'Windows ignores this for DirectX 12 games, so it only matters for older DX9 and DX11 titles, and for Fortnite when it is launched with -d3d11. It loses some Auto HDR and variable refresh paths.'
       Registry = @(
           (New-RegEntry 'HKCU:\System\GameConfigStore' 'GameDVR_FSEBehaviorMode' 'DWord' 2),
           (New-RegEntry 'HKCU:\System\GameConfigStore' 'GameDVR_HonorUserFSEBehaviorMode' 'DWord' 1),
           (New-RegEntry 'HKCU:\System\GameConfigStore' 'GameDVR_DXGIHonorFSEWindowsCompatible' 'DWord' 1),
           (New-RegEntry 'HKCU:\System\GameConfigStore' 'GameDVR_EFSEFeatureFlags' 'DWord' 0)
       ) },

    @{ Id = 'msi-gpu'; IsLaptopSafe = $true; Category = 'gpu'; Group = 'Graphics tweaks'; Name = 'Message Signaled Interrupts (MSI) on the GPU'; Risk = 'Medium'; Recommended = $false
       Desc = 'Makes your graphics card signal Windows with message-signaled interrupts, which are cheaper than the old line-based kind. Current NVIDIA and AMD drivers usually turn this on already, in which case this shows Already set. It edits the device entry of every PCI graphics card and needs a restart. Undo restores the previous values and removes the keys it created.'
       Restart = 'restart'
       Apply = {
           $saved = @()
           $n = 0
           foreach ($g in @(Get-GpuList)) {
               if ($g.PnpId -notlike 'PCI\*') { continue }
               $key = 'HKLM:\SYSTEM\CurrentControlSet\Enum\' + $g.PnpId + '\Device Parameters\Interrupt Management\MessageSignaledInterruptProperties'
               try {
                   $snap = Get-RegSnapshot $key 'MSISupported'
                   Set-RegValue -Path $key -Name 'MSISupported' -Type 'DWord' -Value 1
                   $saved += $snap
                   $n++
               } catch { Write-Log ('MSI: could not change {0}: {1}' -f $g.Name, $_.Exception.Message) 'Warn' }
           }
           if ($n -eq 0) { throw 'No PCI graphics card could be changed.' }
           return @{ Saved = $saved }
       }
       Undo = { param($D) foreach ($s in @($D.Saved)) { if ($s) { Restore-RegSnapshot $s } } }
       Test = {
           $any = $false
           foreach ($g in @(Get-GpuList)) {
               if ($g.PnpId -notlike 'PCI\*') { continue }
               $key = 'HKLM:\SYSTEM\CurrentControlSet\Enum\' + $g.PnpId + '\Device Parameters\Interrupt Management\MessageSignaledInterruptProperties'
               $c = Get-RegSnapshot $key 'MSISupported'
               $any = $true
               if (-not $c.Existed -or [int]$c.Value -ne 1) { return $false }
           }
           return $any
       } },

    @{ Id = 'dx-windowed'; IsLaptopSafe = $true; Category = 'gpu'; Group = 'DirectX tweaks'; Name = 'Optimizations for windowed games'; Risk = 'Low'; Recommended = $true
       Desc = 'Turns on the Windows setting Optimizations for windowed games. DirectX 10 and 11 games running windowed or borderless are upgraded to the modern flip presentation model, which lowers latency and lets them use variable refresh rate. It does nothing for exclusive fullscreen or DirectX 12 games.'
       Apply = {
           $path = 'HKCU:\Software\Microsoft\DirectX\UserGpuPreferences'
           $name = 'DirectXUserGlobalSettings'
           $snap = Get-RegSnapshot $path $name
           $cur = ''
           if ($snap.Existed) { $cur = [string]$snap.Value }
           if ($cur -match 'SwapEffectUpgradeEnable=\d;') { $new = $cur -replace 'SwapEffectUpgradeEnable=\d;', 'SwapEffectUpgradeEnable=1;' } else { $new = $cur + 'SwapEffectUpgradeEnable=1;' }
           Set-RegValue -Path $path -Name $name -Type 'String' -Value $new
           return @{ Saved = @($snap) }
       }
       Undo = { param($D) foreach ($s in @($D.Saved)) { if ($s) { Restore-RegSnapshot $s } } }
       Test = {
           $c = Get-RegSnapshot 'HKCU:\Software\Microsoft\DirectX\UserGpuPreferences' 'DirectXUserGlobalSettings'
           return [bool]($c.Existed -and ([string]$c.Value) -match 'SwapEffectUpgradeEnable=1;')
       } },

    @{ Id = 'gpu-pref-fn'; IsLaptopSafe = $true; Category = 'gpu'; Group = 'DirectX tweaks'; Name = 'Fortnite: use the high-performance GPU'; Risk = 'Low'; Recommended = $true
       Desc = 'Sets Fortnite to the High performance GPU in Windows Graphics settings. This matters on PCs with two graphics processors, such as a Ryzen G-series chip plus a graphics card, where Windows can otherwise pick the slow integrated one. Needs Fortnite installed through the Epic Games Launcher.'
       Apply = {
           $exe = Get-FortniteExe
           if (-not $exe) { throw 'Fortnite was not found. Install it through the Epic Games Launcher first.' }
           $path = 'HKCU:\Software\Microsoft\DirectX\UserGpuPreferences'
           $snap = Get-RegSnapshot $path $exe
           Set-RegValue -Path $path -Name $exe -Type 'String' -Value 'GpuPreference=2;'
           return @{ Saved = @($snap) }
       }
       Undo = { param($D) foreach ($s in @($D.Saved)) { if ($s) { Restore-RegSnapshot $s } } }
       Test = {
           $exe = Get-FortniteExe
           if (-not $exe) { return $false }
           $c = Get-RegSnapshot 'HKCU:\Software\Microsoft\DirectX\UserGpuPreferences' $exe
           return [bool]($c.Existed -and ([string]$c.Value) -match 'GpuPreference=2;')
       } },

    @{ Id = 'fso-fn'; IsLaptopSafe = $true; Category = 'gpu'; Group = 'Fullscreen tweaks'; Name = 'Fortnite: turn off fullscreen optimizations'; Risk = 'Low'; Recommended = $false
       Desc = 'Ticks Disable fullscreen optimizations on the Fortnite program itself. Windows ignores this for DirectX 12, so it only helps when Fortnite runs in DirectX 11 (for example with the -d3d11 launch command). Needs Fortnite installed through the Epic Games Launcher.'
       Apply = {
           $exe = Get-FortniteExe
           if (-not $exe) { throw 'Fortnite was not found. Install it through the Epic Games Launcher first.' }
           $path = 'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\AppCompatFlags\Layers'
           $snap = Get-RegSnapshot $path $exe
           $cur = ''
           if ($snap.Existed) { $cur = [string]$snap.Value }
           if ($cur -match 'DISABLEDXMAXIMIZEDWINDOWEDMODE') { $new = $cur }
           elseif ($cur) { $new = $cur.TrimEnd() + ' DISABLEDXMAXIMIZEDWINDOWEDMODE' }
           else { $new = '~ DISABLEDXMAXIMIZEDWINDOWEDMODE' }
           Set-RegValue -Path $path -Name $exe -Type 'String' -Value $new
           return @{ Saved = @($snap) }
       }
       Undo = { param($D) foreach ($s in @($D.Saved)) { if ($s) { Restore-RegSnapshot $s } } }
       Test = {
           $exe = Get-FortniteExe
           if (-not $exe) { return $false }
           $c = Get-RegSnapshot 'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\AppCompatFlags\Layers' $exe
           return [bool]($c.Existed -and ([string]$c.Value) -match 'DISABLEDXMAXIMIZEDWINDOWEDMODE')
       } },

    # ================================ KBM OPTIMIZATIONS ================================
    @{ Id = 'sticky-keys'; IsLaptopSafe = $true; Category = 'kbm'; Group = 'Keyboard'; Name = 'Disable Sticky Keys and Filter Keys popups'; Risk = 'Low'; Recommended = $true
       Desc = 'Stops the popup that appears when you press Shift five times or hold Shift, which can minimize your game mid-fight. The accessibility features themselves stay available in Settings.'
       Registry = @(
           (New-RegEntry 'HKCU:\Control Panel\Accessibility\StickyKeys' 'Flags' 'String' '506'),
           (New-RegEntry 'HKCU:\Control Panel\Accessibility\Keyboard Response' 'Flags' 'String' '122'),
           (New-RegEntry 'HKCU:\Control Panel\Accessibility\ToggleKeys' 'Flags' 'String' '58')
       ) },

    @{ Id = 'kb-speed'; IsLaptopSafe = $true; Category = 'kbm'; Group = 'Keyboard'; Name = 'Fastest keyboard repeat rate'; Risk = 'Low'; Recommended = $false
       Desc = 'Shortest delay before a held key repeats and the fastest repeat speed, the same as moving both sliders in Keyboard settings to the maximum.'
       Restart = 'sign-out'
       Registry = @(
           (New-RegEntry 'HKCU:\Control Panel\Keyboard' 'KeyboardDelay' 'String' '0'),
           (New-RegEntry 'HKCU:\Control Panel\Keyboard' 'KeyboardSpeed' 'String' '31')
       ) },

    @{ Id = 'usb-suspend'; Category = 'kbm'; Group = 'USB tweaks'; Name = 'Turn off USB selective suspend'; Risk = 'Low'; Recommended = $false
       Desc = 'Stops Windows from putting USB devices to sleep to save power, which can cause a short delay or a missed input when a mouse or keyboard wakes up. Applies to the power plan that is active now, so apply it after you choose your plan. Undo restores the previous values.'
       Apply = {
           $scheme = Get-ActiveSchemeGuid
           if (-not $scheme) { throw 'Could not read the active power plan.' }
           $sub = '2a737441-1930-4402-8d77-b2bebba308a3'
           $set = '48e6b7a6-50f5-4782-a5d4-53bb8f07e226'
           $rk = 'HKLM:\SYSTEM\CurrentControlSet\Control\Power\User\PowerSchemes\' + $scheme + '\' + $sub + '\' + $set
           $ac = Get-RegSnapshot $rk 'ACSettingIndex'
           $dc = Get-RegSnapshot $rk 'DCSettingIndex'
           $prevAc = 1; if ($ac.Existed) { $prevAc = [int]$ac.Value }
           $prevDc = 1; if ($dc.Existed) { $prevDc = [int]$dc.Value }
           & powercfg.exe /setacvalueindex $scheme $sub $set 0 | Out-Null
           & powercfg.exe /setdcvalueindex $scheme $sub $set 0 | Out-Null
           & powercfg.exe /setactive $scheme | Out-Null
           return @{ Scheme = $scheme; PrevAc = $prevAc; PrevDc = $prevDc }
       }
       Undo = {
           param($D)
           $sub = '2a737441-1930-4402-8d77-b2bebba308a3'
           $set = '48e6b7a6-50f5-4782-a5d4-53bb8f07e226'
           & powercfg.exe /setacvalueindex ([string]$D.Scheme) $sub $set ([string][int]$D.PrevAc) | Out-Null
           & powercfg.exe /setdcvalueindex ([string]$D.Scheme) $sub $set ([string][int]$D.PrevDc) | Out-Null
           & powercfg.exe /setactive ([string]$D.Scheme) | Out-Null
       }
       Test = {
           $scheme = Get-ActiveSchemeGuid
           if (-not $scheme) { return $false }
           $rk = 'HKLM:\SYSTEM\CurrentControlSet\Control\Power\User\PowerSchemes\' + $scheme + '\2a737441-1930-4402-8d77-b2bebba308a3\48e6b7a6-50f5-4782-a5d4-53bb8f07e226'
           $ac = Get-RegSnapshot $rk 'ACSettingIndex'
           return [bool]($ac.Existed -and [int]$ac.Value -eq 0)
       } },

    # ================================ AIM OPTIMIZATIONS ================================
    @{ Id = 'mouse-accel'; Category = 'aim'; Group = 'Mouse'; Name = 'Turn off Enhance pointer precision (mouse acceleration)'; Risk = 'Low'; Recommended = $true
       Desc = 'Disables Enhance pointer precision so mouse movement is 1:1 and consistent, which is what most aim training wants. Your desktop mouse will feel different for a day or two.'
       Restart = 'sign-out'
       Registry = @(
           (New-RegEntry 'HKCU:\Control Panel\Mouse' 'MouseSpeed' 'String' '0'),
           (New-RegEntry 'HKCU:\Control Panel\Mouse' 'MouseThreshold1' 'String' '0'),
           (New-RegEntry 'HKCU:\Control Panel\Mouse' 'MouseThreshold2' 'String' '0')
       ) },

    @{ Id = 'fn-rawinput'; IsLaptopSafe = $true; Category = 'aim'; Group = 'Mouse'; Name = 'Raw Input on (Fortnite)'; Risk = 'Low'; Recommended = $false
       Desc = 'Turns on raw mouse input and turns off the game mouse acceleration setting in your Fortnite settings file, so the game reads your mouse directly. The exact setting names are matched against your own file, so start Fortnite once first. Close Fortnite before applying. A backup is made and Undo restores it.'
       Apply = {
           $ini = Get-FortniteGameIni
           if (-not (Test-Path -LiteralPath $ini)) { throw 'Fortnite settings file not found. Start Fortnite once, reach the lobby, close it, then try again.' }
           if (Get-Process -Name @('FortniteClient-Win64-Shipping', 'FortniteLauncher') -ErrorAction SilentlyContinue) { throw 'Close Fortnite first. It rewrites this file when you exit.' }
           $f = Read-TextFile $ini
           $lines = ConvertTo-IniLines $f.Text
           $changes = New-Object 'System.Collections.Generic.List[string]'
           $hit = 0
           foreach ($m in @(Find-IniKeys $lines 'RawInput|RawMouse|DisableMouseAcceleration')) {
               if ($m.Value -notmatch '^(?i:true|false)$') { continue }
               Invoke-IniSet $lines $changes $m.Section $m.Key 'True' $false $false
               $hit++
           }
           if ($hit -eq 0) { throw 'No raw input or mouse acceleration setting was found in your Fortnite file. Open Fortnite once, look under Settings > Input, close it and try again.' }
           $bak = Backup-FileSafe $ini
           Save-IniLines $ini $lines $f
           foreach ($c in $changes) { Write-Log ('Fortnite input: ' + $c) }
           return @{ File = $ini; Backup = $bak }
       }
       Undo = {
           param($D)
           if (Get-Process -Name @('FortniteClient-Win64-Shipping', 'FortniteLauncher') -ErrorAction SilentlyContinue) { throw 'Close Fortnite first.' }
           if (-not $D.Backup -or -not (Test-Path -LiteralPath ([string]$D.Backup))) { throw 'The backup file is missing, so nothing was restored.' }
           $attr = [IO.File]::GetAttributes([string]$D.File)
           if (($attr -band [IO.FileAttributes]::ReadOnly) -ne 0) { [IO.File]::SetAttributes([string]$D.File, ($attr -band (-bnot [IO.FileAttributes]::ReadOnly))) }
           Copy-Item -LiteralPath ([string]$D.Backup) -Destination ([string]$D.File) -Force
       }
       Test = {
           $ini = Get-FortniteGameIni
           if (-not (Test-Path -LiteralPath $ini)) { return $false }
           $f = Read-TextFile $ini
           $lines = ConvertTo-IniLines $f.Text
           $n = 0
           foreach ($m in @(Find-IniKeys $lines 'RawInput|RawMouse|DisableMouseAcceleration')) {
               if ($m.Value -notmatch '^(?i:true|false)$') { continue }
               $n++
               if ($m.Value -ine 'True') { return $false }
           }
           return ($n -gt 0)
       } },

    @{ Id = 'mouse-queue'; Category = 'aim'; Group = 'Mouse'; Name = 'Mouse data queue size (MouseDataQueueSize)'; Risk = 'Medium'; Recommended = $false
       Desc = (Get-MouseQueueDesc)
       Restart = 'restart'
       Picker = @{ Key = 'mouseq'; Min = 19; Max = 32; Label = 'Queue size' }
       Apply = {
           $path = 'HKLM:\SYSTEM\CurrentControlSet\Services\mouclass\Parameters'
           $val = [int]$script:PickerValues['mouseq']
           if ($val -lt 19 -or $val -gt 32) { throw 'Pick a value between 0x13 and 0x20.' }
           $saved = $null
           if ($script:State.ContainsKey('mouse-queue')) { $old = $script:State['mouse-queue']; if ($old.Custom -and $old.Custom.Saved) { $saved = @($old.Custom.Saved) } }
           if (-not $saved) { $saved = @(Get-RegSnapshot $path 'MouseDataQueueSize') }
           Set-RegValue -Path $path -Name 'MouseDataQueueSize' -Type 'DWord' -Value $val
           return @{ Saved = $saved }
       }
       Undo = { param($D) foreach ($s in @($D.Saved)) { if ($s) { Restore-RegSnapshot $s } } }
       Test = {
           $c = Get-RegSnapshot 'HKLM:\SYSTEM\CurrentControlSet\Services\mouclass\Parameters' 'MouseDataQueueSize'
           return [bool]($c.Existed -and [int]$c.Value -eq [int]$script:PickerValues['mouseq'])
       } },

    # ================================ DEBLOATING ================================
    @{ Id = 'widgets'; IsLaptopSafe = $true; Category = 'debloat'; Group = 'Useless features'; Name = 'Turn off Widgets and news feeds'; Risk = 'Low'; Recommended = $false
       Desc = 'Disables the Windows 11 Widgets board and the Windows 10 news and interests feed, including their background processes.'
       Restart = 'sign-out'
       Registry = @(
           (New-RegEntry 'HKLM:\SOFTWARE\Policies\Microsoft\Dsh' 'AllowNewsAndInterests' 'DWord' 0),
           (New-RegEntry 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Feeds' 'EnableFeeds' 'DWord' 0)
       ) },

    @{ Id = 'edge-bg'; IsLaptopSafe = $true; Category = 'debloat'; Group = 'Useless features'; Name = 'Stop Edge running in the background'; Risk = 'Low'; Recommended = $true
       Desc = 'Turns off Edge startup boost and background mode so it does not keep processes alive after you close it. Edge itself still works.'
       Registry = @(
           (New-RegEntry 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' 'StartupBoostEnabled' 'DWord' 0),
           (New-RegEntry 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' 'BackgroundModeEnabled' 'DWord' 0)
       ) },

    @{ Id = 'error-report'; Category = 'debloat'; Group = 'Useless features'; Name = 'Turn off Windows Error Reporting'; Risk = 'Low'; Recommended = $false
       Desc = 'Stops Windows from collecting and sending crash reports after an app crashes. You lose the crash-report prompts and Microsoft loses the data.'
       Registry = @( (New-RegEntry 'HKLM:\SOFTWARE\Microsoft\Windows\Windows Error Reporting' 'Disabled' 'DWord' 1) ) },

    @{ Id = 'remote-assist'; Category = 'debloat'; Group = 'Useless features'; Name = 'Turn off Remote Assistance'; Risk = 'Low'; Recommended = $true
       Desc = 'Disables the Remote Assistance feature that lets someone connect to help you. Most people never use it, and turning it off closes an unneeded way in.'
       Registry = @(
           (New-RegEntry 'HKLM:\SYSTEM\CurrentControlSet\Control\Remote Assistance' 'fAllowToGetHelp' 'DWord' 0),
           (New-RegEntry 'HKLM:\SYSTEM\CurrentControlSet\Control\Remote Assistance' 'fAllowFullControl' 'DWord' 0)
       ) },

    @{ Id = 'activity-history'; IsLaptopSafe = $true; Category = 'debloat'; Group = 'Useless features'; Name = 'Turn off activity history'; Risk = 'Low'; Recommended = $true
       Desc = 'Stops Windows from recording and uploading the apps and files you open (the Timeline feature).'
       Registry = @(
           (New-RegEntry 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' 'EnableActivityFeed' 'DWord' 0),
           (New-RegEntry 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' 'PublishUserActivities' 'DWord' 0),
           (New-RegEntry 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' 'UploadUserActivities' 'DWord' 0)
       ) },

    @{ Id = 'win-tips'; IsLaptopSafe = $true; Category = 'debloat'; Group = 'Useless features'; Name = 'Turn off Windows tips and welcome screens'; Risk = 'Low'; Recommended = $true
       Desc = 'Stops the tips, tricks and finish-setting-up-your-device prompts that pop up after updates.'
       Registry = @(
           (New-RegEntry $cdm 'SubscribedContent-310093Enabled' 'DWord' 0),
           (New-RegEntry $cdm 'SubscribedContent-338387Enabled' 'DWord' 0),
           (New-RegEntry $cdm 'SubscribedContent-338393Enabled' 'DWord' 0),
           (New-RegEntry $cdm 'SubscribedContent-353698Enabled' 'DWord' 0),
           (New-RegEntry $cdm 'SoftLandingEnabled' 'DWord' 0),
           (New-RegEntry 'HKCU:\Software\Microsoft\Windows\CurrentVersion\UserProfileEngagement' 'ScoobeSystemSettingEnabled' 'DWord' 0)
       ) },

    @{ Id = 'suggestions'; IsLaptopSafe = $true; Category = 'debloat'; Group = 'Ads and suggestions'; Name = 'Remove Start menu suggestions and promoted apps'; Risk = 'Low'; Recommended = $true
       Desc = 'Stops Windows from suggesting apps and silently installing promoted ones (the pre-installed game and app spam).'
       Registry = @(
           (New-RegEntry $cdm 'SubscribedContent-338388Enabled' 'DWord' 0),
           (New-RegEntry $cdm 'SubscribedContent-338389Enabled' 'DWord' 0),
           (New-RegEntry $cdm 'SubscribedContent-353694Enabled' 'DWord' 0),
           (New-RegEntry $cdm 'SubscribedContent-353696Enabled' 'DWord' 0),
           (New-RegEntry $cdm 'SystemPaneSuggestionsEnabled' 'DWord' 0),
           (New-RegEntry $cdm 'SilentInstalledAppsEnabled' 'DWord' 0)
       ) },

    @{ Id = 'ad-id'; IsLaptopSafe = $true; Category = 'debloat'; Group = 'Ads and suggestions'; Name = 'Turn off advertising ID'; Risk = 'Low'; Recommended = $true
       Desc = 'Stops apps from using a per-user ID to show you targeted ads.'
       Registry = @( (New-RegEntry 'HKCU:\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo' 'Enabled' 'DWord' 0) ) },

    @{ Id = 'tailored'; IsLaptopSafe = $true; Category = 'debloat'; Group = 'Ads and suggestions'; Name = 'Turn off tailored experiences'; Risk = 'Low'; Recommended = $true
       Desc = 'Stops Windows from using your diagnostic data to personalise tips, ads and recommendations.'
       Registry = @( (New-RegEntry 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Privacy' 'TailoredExperiencesWithDiagnosticDataEnabled' 'DWord' 0) ) },

    @{ Id = 'bing-search'; IsLaptopSafe = $true; Category = 'debloat'; Group = 'Ads and suggestions'; Name = 'Turn off web results in Start search'; Risk = 'Low'; Recommended = $true
       Desc = 'Start search stays local (apps, files, settings) and stops sending what you type to Bing.'
       Restart = 'sign-out'
       Registry = @( (New-RegEntry 'HKCU:\Software\Policies\Microsoft\Windows\Explorer' 'DisableSearchBoxSuggestions' 'DWord' 1) ) },

    @{ Id = 'telemetry-policy'; IsLaptopSafe = $true; Category = 'debloat'; Group = 'Telemetry'; Name = 'Set diagnostic data to the minimum'; Risk = 'Low'; Recommended = $true
       Desc = 'Sets the telemetry policy to its lowest level. On Windows Home and Pro the floor is Required data; only Enterprise and Education can go fully to zero.'
       Registry = @( (New-RegEntry 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' 'AllowTelemetry' 'DWord' 0) ) },

    @{ Id = 'diagtrack'; Category = 'debloat'; Group = 'Telemetry'; Name = 'Disable the telemetry service (DiagTrack)'; Risk = 'Medium'; Recommended = $false
       Desc = 'Stops and disables Connected User Experiences and Telemetry. Some Windows feedback and diagnostic features stop reporting. Undo restores the original start mode.'
       Services = @( @{ Name = 'DiagTrack'; Mode = 'Disabled' } ) },

    # ================================ NETWORK OPTIMIZATIONS ================================
    @{ Id = 'rss'; IsLaptopSafe = $true; Category = 'net'; Group = 'Network processing'; Name = 'Enable multi-core network processing (RSS)'; Risk = 'Low'; Recommended = $true
       Desc = 'Turns on Receive Side Scaling on your connected network adapters so incoming traffic is processed across several CPU cores instead of one. Most adapters already have it on. Your connection may drop for a moment while the adapter restarts. Adapters that do not support RSS are skipped.'
       Apply = {
           $prior = @()
           foreach ($a in @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' })) {
               $rss = Get-NetAdapterRss -Name $a.Name -ErrorAction SilentlyContinue
               if (-not $rss) { continue }
               $prior += @{ Name = [string]$a.Name; Enabled = [bool]$rss.Enabled }
               if (-not $rss.Enabled) { Enable-NetAdapterRss -Name $a.Name -ErrorAction Stop }
           }
           if ($prior.Count -eq 0) { throw 'None of your connected network adapters supports RSS.' }
           return @{ Adapters = $prior }
       }
       Undo = {
           param($Data)
           foreach ($a in @($Data.Adapters)) {
               if ($a -and -not $a.Enabled) { Disable-NetAdapterRss -Name $a.Name -ErrorAction SilentlyContinue }
           }
       }
       Test = {
           $any = $false
           foreach ($a in @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' })) {
               $rss = Get-NetAdapterRss -Name $a.Name -ErrorAction SilentlyContinue
               if (-not $rss) { continue }
               $any = $true
               if (-not $rss.Enabled) { return $false }
           }
           return $any
       } },

    @{ Id = 'delivery-opt'; IsLaptopSafe = $true; Category = 'net'; Group = 'Network processing'; Name = 'Stop sharing Windows updates with other PCs'; Risk = 'Low'; Recommended = $true
       Desc = 'Delivery Optimization can upload Windows updates to other PCs over your internet connection. This sets it to download from Microsoft only, which saves upload bandwidth (good for online games).'
       Registry = @( (New-RegEntry 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization' 'DODownloadMode' 'DWord' 0) ) },

    @{ Id = 'net-throttle'; Category = 'net'; Group = 'Little or no effect'; Name = 'Remove network throttling and limits'; Risk = 'Low'; Recommended = $false; Unproven = $true
       Desc = 'Possibly slightly worse than leaving it alone. Sets NetworkThrottlingIndex to off and removes the QoS reserved-bandwidth limit. The throttle only limits non-multimedia traffic far above what a game sends, and independent testing has found network driver latency going up when it is removed. Fully reversible.'
       Restart = 'restart'
       Registry = @(
           (New-RegEntry $mm 'NetworkThrottlingIndex' 'DWord' -1),
           (New-RegEntry 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Psched' 'NonBestEffortLimit' 'DWord' 0)
       ) },

    @{ Id = 'nagle'; IsLaptopSafe = $true; Category = 'net'; Group = 'Little or no effect'; Name = "Disable Nagle's algorithm"; Risk = 'Low'; Recommended = $false; Unproven = $true
       Desc = 'Sets TcpAckFrequency and TCPNoDelay on your active connections. This only affects TCP, and Fortnite and VALORANT gameplay traffic is UDP, so expect no change in those. It can help some TCP-based games and apps. Undo restores each connection exactly as it was.'
       Restart = 'restart'
       Apply = {
           $keys = @(Get-ActiveTcpInterfaceKeys)
           if ($keys.Count -eq 0) { throw 'No active network connection with an IPv4 address was found.' }
           $saved = @()
           foreach ($k in $keys) {
               foreach ($n in @('TcpAckFrequency', 'TCPNoDelay')) {
                   $saved += (Get-RegSnapshot $k $n)
                   Set-RegValue -Path $k -Name $n -Type 'DWord' -Value 1
               }
           }
           return @{ Saved = $saved }
       }
       Undo = {
           param($Data)
           foreach ($s in @($Data.Saved)) { if ($s) { Restore-RegSnapshot $s } }
       }
       Test = {
           $keys = @(Get-ActiveTcpInterfaceKeys)
           if ($keys.Count -eq 0) { return $false }
           foreach ($k in $keys) {
               foreach ($n in @('TcpAckFrequency', 'TCPNoDelay')) {
                   $c = Get-RegSnapshot $k $n
                   if (-not $c.Existed -or "$($c.Value)" -ne '1') { return $false }
               }
           }
           return $true
       } },

    @{ Id = 'nv-driver'; Category = 'vendor'; Group = 'NVIDIA driver'; Name = 'Optimized Driver'; Risk = 'Medium'; Recommended = $false; OneShot = $true; NeedsRestorePoint = $true
       Guard = { Test-HasGpuVendor 'NVIDIA' }
       Desc = (Get-NvDriverDesc)
       ConfirmText = (Get-NvDriverConfirm)
       Apply = { Install-NvidiaDriver } },

    @{ Id = 'nvcp-best'; Category = 'vendor'; Group = 'NVIDIA settings'; Name = 'Best Nvidia Control Panel Settings (guided)'; Risk = 'Low'; Recommended = $false; OneShot = $true
       Guard = { Test-HasGpuVendor 'NVIDIA' }
       Desc = 'Guided for now: opens the NVIDIA Control Panel so you can set the values listed further down this page. Changing these driver profile settings automatically needs NVIDIA setting ids that have not been verified across every driver version, so this stays guided rather than risk writing the wrong value into your driver.'
       Apply = {
           $opened = $false
           foreach ($opener in @({ Start-Process 'shell:AppsFolder\NVIDIACorp.NVIDIAControlPanel_56jybvy8sckqj!NVIDIACorp.NVIDIAControlPanel' }, { Start-Process (Join-Path $env:ProgramFiles 'NVIDIA Corporation\Control Panel Client\nvcplui.exe') })) {
               try { & $opener; $opened = $true; break } catch { }
           }
           if ($opened) { Write-Log 'NVIDIA Control Panel opened. Set the values listed on the Nvidia and AMD page.' }
           else { Write-Log 'Could not open the NVIDIA Control Panel automatically. Right-click the desktop and choose NVIDIA Control Panel.' 'Warn' }
       } },

    @{ Id = 'amd-best'; Category = 'vendor'; Group = 'AMD settings'; Name = 'Best AMD Adrenalin Software Settings (guided)'; Risk = 'Low'; Recommended = $false; OneShot = $true
       Guard = { Test-HasGpuVendor 'AMD' }
       Desc = 'Guided for now: opens AMD Software Adrenalin Edition so you can set the values listed further down this page. Adrenalin stores its settings in undocumented, driver-version-specific places, so writing them blindly could corrupt your profile.'
       Apply = {
           $opened = $false
           foreach ($p in @((Join-Path $env:ProgramFiles 'AMD\CNext\CNext\RadeonSoftware.exe'), (Join-Path ${env:ProgramFiles(x86)} 'AMD\CNext\CNext\RadeonSoftware.exe'))) {
               if (Test-Path -LiteralPath $p) { try { Start-Process -FilePath $p; $opened = $true; break } catch { } }
           }
           if ($opened) { Write-Log 'AMD Software opened. Set the values listed on the Nvidia and AMD page.' }
           else { Write-Log 'Could not find AMD Software. Right-click the desktop and choose AMD Software.' 'Warn' }
       } },

    # ================================ APP OPTIMIZER ================================
    @{ Id = 'chrome-default'; IsLaptopSafe = $true; Category = 'apps'; Group = 'Browser'; Name = 'Make Chrome your default browser'; Risk = 'Low'; Recommended = $false; OneShot = $true
       Desc = 'Windows does not let programs change the default browser silently (it is protected to stop hijacking). This checks that Chrome is installed and opens the exact Settings page, where you confirm with one click. If Chrome is missing, it opens the download page.'
       Apply = {
           $chrome = $null
           foreach ($p in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\chrome.exe', 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\chrome.exe')) {
               $v = (Get-ItemProperty -LiteralPath $p -ErrorAction SilentlyContinue).'(default)'
               if ($v -and (Test-Path -LiteralPath $v)) { $chrome = $v; break }
           }
           if (-not $chrome) {
               Write-Log 'Chrome is not installed. Opening the Chrome download page.' 'Warn'
               Start-Process 'https://www.google.com/chrome/'
               return
           }
           Write-Log 'Chrome found. Opening Windows default-apps settings: click Set default for Chrome there.'
           Start-Process 'ms-settings:defaultapps?registeredAppUser=Google%20Chrome'
       } },

    @{ Id = 'bg-apps'; Category = 'apps'; Group = 'Background apps'; Name = 'Stop Store apps running in the background'; Risk = 'Medium'; Recommended = $false
       Desc = 'Stops Microsoft Store apps from running when you are not using them. Store apps such as Mail and Calendar stop syncing and notifying while closed. Normal programs like Steam and Discord are not affected.'
       Registry = @( (New-RegEntry 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy' 'LetAppsRunInBackground' 'DWord' 2) ) },

    # ================================ EXTRA TWEAKS ================================
    @{ Id = 'fn-nosplash'; IsLaptopSafe = $true; Category = 'extra'; Group = 'Fortnite'; Name = '-NOSPLASH: skip the intro splash screen'; Risk = 'Low'; Recommended = $false
       Desc = 'Skips the intro splash screen so the game starts a few seconds faster.'
       Apply = { Set-FnLaunchArg 'NOSPLASH' $true }
       Undo = { Set-FnLaunchArg 'NOSPLASH' $false }
       Test = { return (Test-FnLaunchArg 'NOSPLASH') } },

    @{ Id = 'fn-high-d3d11'; IsLaptopSafe = $true; Category = 'extra'; Group = 'Fortnite'; Name = '-high -d3d11: Legacy Performance Mode'; Risk = 'Low'; Recommended = $false
       Desc = 'Brings back the Legacy Performance Mode and drastically improves FPS and steadies frame times on many systems. On a very new graphics card, current DirectX 12 Performance Mode can be faster, so test both.'
       Apply = { Set-FnLaunchArg 'HIGH_D3D11' $true }
       Undo = { Set-FnLaunchArg 'HIGH_D3D11' $false }
       Test = { return (Test-FnLaunchArg 'HIGH_D3D11') } },

    @{ Id = 'fn-featurelevel'; IsLaptopSafe = $true; Category = 'extra'; Group = 'Fortnite'; Name = '-FeatureLevelES31: force Performance Mode'; Risk = 'Low'; Recommended = $false
       Desc = 'Forces the game to prefer launching in Performance Mode.'
       Apply = { Set-FnLaunchArg 'FEATURELEVEL' $true }
       Undo = { Set-FnLaunchArg 'FEATURELEVEL' $false }
       Test = { return (Test-FnLaunchArg 'FEATURELEVEL') } },

    @{ Id = 'startup-delay'; IsLaptopSafe = $true; Category = 'windows'; Group = 'Startup and shutdown'; Name = 'Remove startup app delay'; Risk = 'Low'; Recommended = $true
       Desc = 'Windows waits several seconds after sign-in before launching your startup apps. This removes the wait so the desktop is ready sooner.'
       Restart = 'sign-out'
       Registry = @( (New-RegEntry 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Serialize' 'StartupDelayInMSec' 'DWord' 0) ) },

    @{ Id = 'fast-startup'; IsLaptopSafe = $true; Category = 'windows'; Group = 'Startup and shutdown'; Name = 'Turn off Fast Startup'; Risk = 'Low'; Recommended = $true
       Desc = 'Makes Shut down a real shutdown, so drivers and the kernel start clean every boot instead of resuming a saved session. Fixes odd driver and update problems; cold boot can be a couple of seconds slower. Hibernation itself stays available.'
       Restart = 'restart'
       Registry = @( (New-RegEntry 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' 'HiberbootEnabled' 'DWord' 0) ) },

    @{ Id = 'animations'; IsLaptopSafe = $true; Category = 'windows'; Group = 'Visual effects'; Name = 'Reduce window animations'; Risk = 'Low'; Recommended = $false
       Desc = 'Turns off minimize/maximize and taskbar animations. Cosmetic, but it can feel faster on older hardware.'
       Restart = 'sign-out'
       Registry = @(
           (New-RegEntry 'HKCU:\Control Panel\Desktop\WindowMetrics' 'MinAnimate' 'String' '0'),
           (New-RegEntry $explorerAdv 'TaskbarAnimations' 'DWord' 0)
       ) },

    @{ Id = 'transparency'; IsLaptopSafe = $true; Category = 'windows'; Group = 'Visual effects'; Name = 'Turn off transparency effects'; Risk = 'Low'; Recommended = $false
       Desc = 'Disables the blur and transparency on the taskbar, Start and windows. Saves a little GPU work, mostly on weak graphics.'
       Registry = @( (New-RegEntry 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' 'EnableTransparency' 'DWord' 0) ) },

    @{ Id = 'menu-delay'; IsLaptopSafe = $true; Category = 'windows'; Group = 'Startup and shutdown'; Name = 'Instant menu popups'; Risk = 'Low'; Recommended = $true
       Desc = 'Sets the delay before menus open to zero, so right-click and submenus feel snappier.'
       Restart = 'sign-out'
       Registry = @( (New-RegEntry 'HKCU:\Control Panel\Desktop' 'MenuShowDelay' 'String' '0') ) },

    @{ Id = 'faster-shutdown'; IsLaptopSafe = $true; Category = 'windows'; Group = 'Startup and shutdown'; Name = 'Faster app shutdown (kill time)'; Risk = 'Medium'; Recommended = $false
       Desc = 'Shortens how long Windows waits for apps to close before forcing them to 2 seconds. Apps that are slow to save may lose unsaved data on shutdown. Affects shutdown speed only, not FPS.'
       Restart = 'sign-out'
       Registry = @(
           (New-RegEntry 'HKCU:\Control Panel\Desktop' 'WaitToKillAppTimeout' 'String' '2000'),
           (New-RegEntry 'HKCU:\Control Panel\Desktop' 'HungAppTimeout' 'String' '2000')
       ) },

    @{ Id = 'kill-service'; IsLaptopSafe = $true; Category = 'windows'; Group = 'Startup and shutdown'; Name = 'Faster service shutdown (kill time)'; Risk = 'Medium'; Recommended = $false
       Desc = 'Shortens how long Windows waits for background services to stop at shutdown to 2 seconds. Services that need longer to save (databases, some backup tools) may be cut off. Affects shutdown speed only.'
       Restart = 'restart'
       Registry = @( (New-RegEntry 'HKLM:\SYSTEM\CurrentControlSet\Control' 'WaitToKillServiceTimeout' 'String' '2000') ) },

    @{ Id = 'file-ext'; IsLaptopSafe = $true; Category = 'extra'; Group = 'Explorer'; Name = 'Show file extensions'; Risk = 'Low'; Recommended = $true
       Desc = 'Always shows .exe, .png, .txt and so on. Helpful for spotting disguised files such as photo.jpg.exe.'
       Registry = @( (New-RegEntry $explorerAdv 'HideFileExt' 'DWord' 0) ) },

    @{ Id = 'this-pc'; IsLaptopSafe = $true; Category = 'extra'; Group = 'Explorer'; Name = 'Open File Explorer to This PC'; Risk = 'Low'; Recommended = $false
       Desc = 'File Explorer opens on your drives instead of Home / Quick access.'
       Registry = @( (New-RegEntry $explorerAdv 'LaunchTo' 'DWord' 1) ) },

    @{ Id = 'no-recent'; IsLaptopSafe = $true; Category = 'extra'; Group = 'Explorer'; Name = 'Hide recent and frequent files in Quick access'; Risk = 'Low'; Recommended = $false
       Desc = 'File Explorer stops listing recently opened files and frequently used folders. Cleaner, and a small privacy gain.'
       Registry = @(
           (New-RegEntry 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer' 'ShowRecent' 'DWord' 0),
           (New-RegEntry 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer' 'ShowFrequent' 'DWord' 0)
       ) },

    @{ Id = 'classic-menu'; IsLaptopSafe = $true; Category = 'extra'; Group = 'Explorer'; Name = 'Classic right-click menu (Windows 11)'; Risk = 'Low'; Recommended = $false
       Desc = 'Brings back the full right-click menu without having to click Show more options every time.'
       Restart = 'sign-out'
       Guard = { (Get-WinBuild) -ge 22000 }
       Apply = {
           $key = $classicMenuKey + '\InprocServer32'
           New-Item -Path $key -Force | Out-Null
           Set-ItemProperty -LiteralPath $key -Name '(default)' -Value ''
           return @{ Created = $true }
       }
       Undo = {
           param($Data)
           Remove-Item -LiteralPath $classicMenuKey -Recurse -Force -ErrorAction SilentlyContinue
       }
       Test = { return (Test-Path -LiteralPath ($classicMenuKey + '\InprocServer32')) } },

    @{ Id = 'clean-temp'; Category = 'extra'; Group = 'Miscellaneous tweaks'; Name = 'Delete old temporary files'; Risk = 'Low'; Recommended = $false; OneShot = $true
       Desc = 'Removes files older than 2 days from your Temp folder and Windows\Temp. Files in use are skipped. This cannot be undone.'
       Apply = {
           $drive  = Get-PSDrive -Name ($env:SystemDrive.TrimEnd(':'))
           $before = $drive.Free
           $cutoff = (Get-Date).AddDays(-2)
           foreach ($dir in @($env:TEMP, (Join-Path $env:WINDIR 'Temp'))) {
               if (-not (Test-Path -LiteralPath $dir)) { continue }
               Get-ChildItem -LiteralPath $dir -Force -ErrorAction SilentlyContinue |
                   Where-Object { $_.LastWriteTime -lt $cutoff } |
                   Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
           }
           $after = (Get-PSDrive -Name ($env:SystemDrive.TrimEnd(':'))).Free
           $freed = [math]::Max(0, ($after - $before))
           Write-Log ('Temp cleanup freed about {0} MB' -f [math]::Round($freed / 1MB)) 'Ok'
       } },

    @{ Id = 'clean-recycle'; Category = 'extra'; Group = 'Miscellaneous tweaks'; Name = 'Empty the Recycle Bin'; Risk = 'Low'; Recommended = $false; OneShot = $true
       Desc = 'Permanently empties the Recycle Bin on all drives. This cannot be undone.'
       Apply = {
           try { Clear-RecycleBin -Force -ErrorAction Stop; Write-Log 'Recycle Bin emptied' 'Ok' }
           catch { Write-Log ('Recycle Bin: ' + $_.Exception.Message) 'Warn' }
       } },
    # ============================ NEW: WINDOWS TWEAKS ============================
    @{ Id = 'uac-off'; Category = 'windows'; Group = 'System settings'; Name = 'Disable UAC (User Account Control)'; Risk = 'High'; Recommended = $false
       Desc = 'Turns off the Yes/No prompt Windows shows before a program can make system-wide changes. Faster to click through, but any program (including malware) can then change your system silently. Only for a PC you trust completely. Undo restores the prompt.'
       Registry = @( (New-RegEntry 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' 'EnableLUA' 'DWord' 0) )
       Restart = 'restart' },

    @{ Id = 'insider-off'; IsLaptopSafe = $true; Category = 'windows'; Group = 'System settings'; Name = 'Disable Windows Insider Program'; Risk = 'Low'; Recommended = $true
       Desc = 'Stops this PC from being able to enrol in Windows Insider preview builds, so you never get an early, less stable Windows update by mistake.'
       Registry = @( (New-RegEntry 'HKLM:\SOFTWARE\Policies\Microsoft\WindowsInsider' 'AllowInsiderInstalls' 'DWord' 0) ) },

    @{ Id = 'hibernation-off'; Category = 'windows'; Group = 'System settings'; Name = 'Disable Hibernation'; Risk = 'Medium'; Recommended = $false
       Desc = 'Turns off hibernation and deletes hiberfil.sys, freeing disk space equal to your RAM size. This also turns off Fast Startup, since Fast Startup depends on hibernation. Skip this if you rely on hibernating instead of shutting down, especially on a laptop.'
       Apply = {
           $out = (& powercfg.exe /hibernate off 2>&1 | Out-String)
           if ($LASTEXITCODE -ne 0) { throw ('powercfg could not turn off hibernation: ' + $out) }
       }
       Undo = { & powercfg.exe /hibernate on 2>&1 | Out-Null }
       Test = { return -not (Test-Path -LiteralPath (Join-Path $env:SystemDrive 'hiberfil.sys')) } },

    @{ Id = 'svchost-split'; IsLaptopSafe = $true; Category = 'windows'; Group = 'Memory and cache'; Name = 'Raise the svchost.exe process-splitting threshold'; Risk = 'Low'; Recommended = $false
       Desc = 'Windows 10 and 11 give each service its own svchost.exe process once you have more than about 3.5 GB of RAM, which uses more memory but isolates crashes. Raising this threshold lets more services share fewer svchost.exe processes again, similar to older Windows, trading a little isolation for a lower process count. Needs a restart.'
       Restart = 'restart'
       Apply = {
           $ram = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1KB)
           $snap = Get-RegSnapshot 'HKLM:\SYSTEM\CurrentControlSet\Control' 'SvcHostSplitThresholdInKB'
           Set-RegValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Control' -Name 'SvcHostSplitThresholdInKB' -Type 'DWord' -Value $ram
           return @{ Saved = @($snap) }
       }
       Undo = { param($D) foreach ($s in @($D.Saved)) { if ($s) { Restore-RegSnapshot $s } } }
       Test = {
           $c = Get-RegSnapshot 'HKLM:\SYSTEM\CurrentControlSet\Control' 'SvcHostSplitThresholdInKB'
           return [bool]($c.Existed -and [int64]$c.Value -gt 3800000)
       } },

    @{ Id = 'prefetch-tune'; IsLaptopSafe = $true; Category = 'windows'; Group = 'Memory and cache'; Name = 'Tune Prefetch for your boot drive'; Risk = 'Low'; Recommended = $false
       Desc = 'Prefetch pre-loads apps you use often. On an SSD it mostly just adds disk writes for no benefit, so this turns it off if your boot drive is an SSD, or turns on full prefetching if it is a hard drive. Detected on this PC: this is decided automatically each time you apply it.'
       Apply = {
           $ssd = Get-BootDriveIsSsd
           $path = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management\PrefetchParameters'
           $val = 3; if ($ssd) { $val = 0 }
           $snap = Get-RegSnapshot $path 'EnablePrefetcher'
           Set-RegValue -Path $path -Name 'EnablePrefetcher' -Type 'DWord' -Value $val
           Write-Log ('Boot drive detected as {0}, EnablePrefetcher set to {1}' -f $(if ($ssd) { 'SSD' } else { 'HDD' }), $val)
           return @{ Saved = @($snap) }
       }
       Undo = { param($D) foreach ($s in @($D.Saved)) { if ($s) { Restore-RegSnapshot $s } } }
       Test = {
           $ssd = Get-BootDriveIsSsd
           $c = Get-RegSnapshot 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management\PrefetchParameters' 'EnablePrefetcher'
           if (-not $c.Existed) { return $false }
           if ($ssd) { return [int]$c.Value -eq 0 }
           return [int]$c.Value -eq 3
       } },

    @{ Id = 'coalescing-off'; Category = 'windows'; Group = 'Latency'; Name = 'Disable timer coalescing (CoalescingTimerInterval)'; Risk = 'Medium'; Recommended = $false
       Desc = 'Stops Windows grouping small background timers together to save power (timer coalescing). Can very slightly reduce background latency at the cost of a bit more idle power use. Undo restores the previous value.'
       Restart = 'restart'
       Registry = @( (New-RegEntry 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\kernel' 'DistributeTimers' 'DWord' 0) ) },

    @{ Id = 'energy-telemetry-off'; IsLaptopSafe = $true; Category = 'windows'; Group = 'Telemetry and diagnostics'; Name = 'Disable energy estimation and power telemetry'; Risk = 'Low'; Recommended = $false
       Desc = 'Turns off the scheduled task that runs Windows Power Efficiency Diagnostics in the background and estimates per-app energy use. Purely diagnostic; turning it off does not change how your PC actually uses power, it just stops Windows from measuring and logging it. Undo turns the task back on.'
       Apply = {
           $touched = Disable-ScheduledTaskList @('\Microsoft\Windows\Power Efficiency Diagnostics\AnalyzeSystem')
           return @{ Tasks = $touched }
       }
       Undo = { param($D) Enable-ScheduledTaskList @($D.Tasks) }
       Test = {
           try { $t = Get-ScheduledTask -TaskName 'AnalyzeSystem' -TaskPath '\Microsoft\Windows\Power Efficiency Diagnostics\' -ErrorAction Stop; return $t.State -eq 'Disabled' }
           catch { return $false }
       } },

    @{ Id = 'idle-power-off'; Category = 'cpu'; Group = 'Power'; Name = 'Disable processor idle power management'; Risk = 'High'; Recommended = $false
       Desc = 'Stops the CPU from dropping into deeper idle (C-state) power-saving modes on the active power plan, so it responds faster coming out of idle. Raises idle temperature and power use noticeably, and does the opposite of what you want on a laptop. Desktops only.'
       Apply = {
           $scheme = Get-ActiveSchemeGuid
           if (-not $scheme) { throw 'Could not read the active power plan.' }
           & powercfg.exe /setacvalueindex $scheme SUB_PROCESSOR IDLEDISABLE 1 | Out-Null
           & powercfg.exe /setactive $scheme | Out-Null
           return @{ Scheme = $scheme }
       }
       Undo = {
           param($D)
           & powercfg.exe /setacvalueindex ([string]$D.Scheme) SUB_PROCESSOR IDLEDISABLE 0 | Out-Null
           & powercfg.exe /setactive ([string]$D.Scheme) | Out-Null
       }
       Test = {
           $scheme = Get-ActiveSchemeGuid
           if (-not $scheme) { return $false }
           $out = (& powercfg.exe /q $scheme SUB_PROCESSOR IDLEDISABLE | Out-String)
           $m = [regex]::Match($out, '(?m)Current AC Power Setting Index:\s*0x([0-9a-fA-F]+)')
           return [bool]($m.Success -and [Convert]::ToInt32($m.Groups[1].Value, 16) -eq 1)
       } },

    @{ Id = 'sehop-off'; Category = 'cpu'; Group = 'Security trade-offs'; Name = 'Disable SEHOP'; Risk = 'High'; Recommended = $false
       Desc = 'Turns off Structured Exception Handling Overwrite Protection, a Microsoft-documented exploit mitigation, separate from the Spectre/Meltdown tweak above. Essentially no measurable performance gain on modern CPUs, so it is here for completeness rather than as a recommendation.'
       Restart = 'restart'
       Registry = @( (New-RegEntry 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\kernel' 'DisableExceptionChainValidation' 'DWord' 1) ) },

    # ============================ NEW: DEBLOATING (process/startup trimming) ============================
    @{ Id = 'trim-updaters'; IsLaptopSafe = $true; Category = 'debloat'; Group = 'Trim background services and startup'; Name = 'Turn off third-party updater and elevation services'; Risk = 'Medium'; Recommended = $false
       Desc = 'The same idea as unticking non-Microsoft updater services in System Configuration (msconfig): finds non-Microsoft services whose name looks like an updater or elevation helper and sets them to Manual (not Disabled), so they stop starting automatically but nothing is removed. Logitech G HUB''s updater is always left alone because turning it off breaks G HUB. Undo restores each service''s original start mode.'
       Apply = {
           $found = @(Get-ThirdPartyUpdaterServices)
           if ($found.Count -eq 0) { throw 'No matching third-party updater or elevation services were found.' }
           $saved = @()
           foreach ($s in $found) {
               $saved += (Get-SvcSnapshot $s.Name)
               try { Set-SvcStart -Name $s.Name -Mode 'Manual' } catch { }
           }
           Write-Log ('Set {0} third-party updater service(s) to Manual: {1}' -f $found.Count, (($found | ForEach-Object { $_.Name }) -join ', ')) 'Ok'
           return @{ Saved = $saved }
       }
       Undo = {
           param($D)
           foreach ($s in @($D.Saved)) {
               if ($s -and $s.Exists) { try { Set-SvcStart -Name $s.Name -Mode $s.Mode -Delayed ([bool]$s.Delayed) } catch { } }
           }
       }
       Test = { return $script:State.ContainsKey('trim-updaters') } },

    @{ Id = 'trim-startup'; IsLaptopSafe = $true; Category = 'debloat'; Group = 'Trim background services and startup'; Name = 'Disable third-party sign-in startup entries'; Risk = 'Medium'; Recommended = $false
       Desc = 'The same idea as Autoruns''s Logon tab: goes through your Run/RunOnce startup entries and disables every one except entries that launch cmd.exe, using the same StartupApproved flag Task Manager''s Startup tab uses, so disabled apps show as Disabled there too and nothing is deleted. Undo re-enables everything this turned off.'
       Apply = {
           $entries = @(Get-RunKeyEntries)
           if ($entries.Count -eq 0) { throw 'No startup entries were found to disable.' }
           $touched = @()
           foreach ($e in $entries) {
               $prevBytes = $null
               try { $prevBytes = (Get-ItemProperty -LiteralPath $e.ApprovedPath -Name $e.Name -ErrorAction Stop).($e.Name) } catch { }
               if ($prevBytes -and $prevBytes.Length -gt 0 -and $prevBytes[0] -eq 3) { continue }
               Set-StartupApprovedDisabled -Path $e.ApprovedPath -Name $e.Name -Disabled $true
               $touched += @{ ApprovedPath = $e.ApprovedPath; Name = $e.Name; PrevBytes = $prevBytes }
           }
           if ($touched.Count -eq 0) { throw 'Every startup entry was already disabled.' }
           Write-Log ('Disabled {0} startup entr{1}: {2}' -f $touched.Count, $(if ($touched.Count -eq 1) { 'y' } else { 'ies' }), (($touched | ForEach-Object { $_.Name }) -join ', ')) 'Ok'
           return @{ Touched = $touched }
       }
       Undo = {
           param($D)
           foreach ($t in @($D.Touched)) {
               if (-not $t) { continue }
               if ($t.PrevBytes) { New-ItemProperty -LiteralPath $t.ApprovedPath -Name $t.Name -Value $t.PrevBytes -PropertyType Binary -Force | Out-Null }
               else { Set-StartupApprovedDisabled -Path $t.ApprovedPath -Name $t.Name -Disabled $false }
           }
       }
       Test = { return $script:State.ContainsKey('trim-startup') } },

    @{ Id = 'trim-services'; Category = 'debloat'; Group = 'Trim background services and startup'; Name = 'Disable a curated list of unused Windows services'; Risk = 'Medium'; Recommended = $false
       Desc = 'Disables Fax, Remote Registry, Downloaded Maps Manager, Retail Demo, Windows Media Player Network Sharing, Wallet Service, Phone Service and the touch-keyboard/handwriting service, only for the ones you actually have. Skip this if you use a stylus, a touchscreen keyboard, or a phone-link feature. Undo restores every one to its original start mode.'
       Apply = {
           $saved = @()
           foreach ($x in $script:SafeToDisableServices) {
               $cur = Get-SvcSnapshot $x.Name
               if (-not $cur.Exists) { continue }
               $saved += $cur
               try { Set-SvcStart -Name $x.Name -Mode 'Disabled'; Stop-Service -Name $x.Name -Force -ErrorAction SilentlyContinue } catch { }
           }
           if ($saved.Count -eq 0) { throw 'None of these services exist on this PC.' }
           return @{ Saved = $saved }
       }
       Undo = {
           param($D)
           foreach ($s in @($D.Saved)) { if ($s -and $s.Exists) { try { Set-SvcStart -Name $s.Name -Mode $s.Mode -Delayed ([bool]$s.Delayed); if ($s.WasRunning) { Start-Service -Name $s.Name -ErrorAction SilentlyContinue } } catch { } } }
       }
       Test = { return $script:State.ContainsKey('trim-services') } },

    @{ Id = 'trim-tasks'; IsLaptopSafe = $true; Category = 'debloat'; Group = 'Trim background services and startup'; Name = 'Disable a curated list of background scheduled tasks'; Risk = 'Low'; Recommended = $false
       Desc = 'Disables well-known low-value background tasks: compatibility and CEIP data collection, disk diagnostics data collection, and Windows Feedback prompts. These only report data to Microsoft; nothing you use daily depends on them. Undo turns each task back on.'
       Apply = {
           $touched = Disable-ScheduledTaskList $script:CleanupScheduledTasks
           if ($touched.Count -eq 0) { throw 'These tasks were already disabled or not found.' }
           return @{ Tasks = $touched }
       }
       Undo = { param($D) Enable-ScheduledTaskList @($D.Tasks) }
       Test = { return $script:State.ContainsKey('trim-tasks') } },

    @{ Id = 'store-off'; IsLaptopSafe = $true; Category = 'debloat'; Group = 'Optional apps and services'; Name = 'Disable Microsoft Store'; Risk = 'Medium'; Recommended = $false
       Desc = 'Blocks the Microsoft Store app from opening. Any app already installed from the Store keeps working; you just cannot install or update Store apps until you undo this.'
       Registry = @( (New-RegEntry 'HKLM:\SOFTWARE\Policies\Microsoft\WindowsStore' 'RemoveWindowsStore' 'DWord' 1) ) },

    @{ Id = 'printer-off'; Category = 'debloat'; Group = 'Optional apps and services'; Name = 'Disable the Print Spooler service'; Risk = 'Medium'; Recommended = $false
       Desc = 'Turns off printing entirely on this PC. Only apply this if you never print. Undo restores the service to Automatic and starts it again.'
       Services = @( @{ Name = 'Spooler'; Mode = 'Disabled' } ) },

    @{ Id = 'remove-optional-apps'; IsLaptopSafe = $true; Category = 'debloat'; Group = 'Optional apps and services'; Name = 'Remove optional pre-installed apps'; Risk = 'Medium'; Recommended = $false; OneShot = $true
       Desc = 'Uninstalls the Xbox apps, 3D Viewer, Mixed Reality Portal, Bing Weather/News, Solitaire, Zune Music/Video, People, Phone Link, Get Help, Get Started, Family Safety, Feedback Hub, the Office hub tile, Clipchamp and Teams (consumer). Calculator, Photos, Notepad, Snipping Tool, the Store and security apps are never touched. This only removes them for your account and cannot be undone from here, but Store apps can always be reinstalled later from the Microsoft Store.'
       Apply = {
           $removed = @()
           foreach ($name in $script:OptionalAppPackages) {
               $pkgs = @(Get-AppxPackage -Name $name -ErrorAction SilentlyContinue)
               foreach ($p in $pkgs) {
                   try { Remove-AppxPackage -Package $p.PackageFullName -ErrorAction Stop; $removed += $p.Name } catch { }
               }
           }
           if ($removed.Count -eq 0) { Write-Log 'None of the optional apps on the list were installed.' }
           else { Write-Log ('Removed: ' + ($removed | Select-Object -Unique -join ', ')) 'Ok' }
       } },

    # ============================ NEW: STORAGE TWEAKS TAB ============================
    @{ Id = 'fsutil-8dot3'; IsLaptopSafe = $true; Category = 'storage'; Group = 'NTFS (fsutil)'; Name = 'Disable 8.3 short filename creation'; Risk = 'Low'; Recommended = $true
       Desc = 'Stops NTFS creating an old-style 8-character short name (like RUNGAM~1.EXE) for every file, which very old software needed and almost nothing does today. Slightly faster file creation on folders with many files. Undo restores the previous setting; existing short names are not removed by either direction.'
       Apply = {
           $prev = (& fsutil.exe 8dot3name query $env:SystemDrive 2>&1 | Out-String)
           $prevVal = 0
           $m = [regex]::Match($prev, '(?i)are (disabled|enabled)')
           if ($m.Success -and $m.Groups[1].Value -ieq 'enabled') { $prevVal = 0 } else { $prevVal = 1 }
           & fsutil.exe 8dot3name set 1 | Out-Null
           if ($LASTEXITCODE -ne 0) { throw 'fsutil could not change the 8.3 name setting.' }
           return @{ Prev = $prevVal }
       }
       Undo = { param($D) & fsutil.exe 8dot3name set ([int]$D.Prev) | Out-Null }
       Test = {
           $out = (& fsutil.exe 8dot3name query $env:SystemDrive 2>&1 | Out-String)
           return [bool]($out -match '(?i)disabled')
       } },

    @{ Id = 'fsutil-memusage'; IsLaptopSafe = $true; Category = 'storage'; Group = 'NTFS (fsutil)'; Name = 'Raise NTFS metadata memory usage (fsutil memoryusage 2)'; Risk = 'Low'; Recommended = $false
       Desc = 'Runs fsutil behavior set memoryusage 2, which lets NTFS keep more file-system metadata (like the master file table) cached in memory. Helps most with folders containing very large numbers of files. Safe on any PC with a reasonable amount of RAM. Needs a restart.'
       Restart = 'restart'
       Apply = {
           $prev = (& fsutil.exe behavior query memoryusage 2>&1 | Out-String)
           $prevVal = 1
           $m = [regex]::Match($prev, '(\d+)')
           if ($m.Success) { $prevVal = [int]$m.Groups[1].Value }
           & fsutil.exe behavior set memoryusage 2 | Out-Null
           if ($LASTEXITCODE -ne 0) { throw 'fsutil could not change the memory usage setting.' }
           return @{ Prev = $prevVal }
       }
       Undo = { param($D) & fsutil.exe behavior set memoryusage ([int]$D.Prev) | Out-Null }
       Test = {
           $out = (& fsutil.exe behavior query memoryusage 2>&1 | Out-String)
           return [bool]($out -match '2')
       } },

    @{ Id = 'optimize-drives'; IsLaptopSafe = $true; Category = 'storage'; Group = 'Drive optimization'; Name = 'Optimize all drives (defrag HDDs, retrim SSDs)'; Risk = 'Low'; Recommended = $false; OneShot = $true
       Desc = 'Runs the same engine as the built-in Optimize Drives tool on every fixed drive: a full defragmentation pass on hard drives, and a TRIM pass on SSDs (never a defrag, which would just wear out an SSD for no benefit). Can take a while on a large or very fragmented hard drive.'
       Apply = {
           $vols = @(Get-Volume -ErrorAction SilentlyContinue | Where-Object { $_.DriveType -eq 'Fixed' -and $_.DriveLetter })
           if ($vols.Count -eq 0) { throw 'No fixed drives were found.' }
           foreach ($v in $vols) {
               $letter = [string]$v.DriveLetter
               try {
                   $isSsd = $false
                   try { $isSsd = [bool]((Get-PhysicalDisk -ErrorAction Stop | Where-Object { ($_ | Get-Disk -ErrorAction SilentlyContinue) }).MediaType -contains 'SSD') } catch { }
                   $part = Get-Partition -DriveLetter $letter -ErrorAction Stop
                   $disk = Get-PhysicalDisk -ErrorAction Stop | Where-Object { $_.DeviceId -eq $part.DiskNumber }
                   $ssd = [bool]($disk -and $disk[0].MediaType -eq 'SSD')
                   if ($ssd) { Write-Log ($letter + ': running TRIM (retrim)'); Optimize-Volume -DriveLetter $letter -ReTrim -ErrorAction Stop }
                   else { Write-Log ($letter + ': running defragmentation'); Optimize-Volume -DriveLetter $letter -Defrag -ErrorAction Stop }
                   Update-UI
                   Write-Log ($letter + ' finished') 'Ok'
               } catch { Write-Log ($letter + ': ' + $_.Exception.Message) 'Warn' }
           }
       } },

    # ============================ NEW: NETWORK ============================
    @{ Id = 'afd-tweak'; IsLaptopSafe = $true; Category = 'net'; Group = 'Network stack'; Name = 'AFD.sys buffer tweak (DefaultReceiveWindow / DefaultSendWindow)'; Risk = 'Low'; Recommended = $false
       Desc = 'Raises the default send and receive buffer sizes for the Ancillary Function Driver (AFD.sys), the low-level driver every Windows socket connection runs through. A common gaming-guide tweak; on a modern broadband connection the effect is usually small. Needs a restart.'
       Restart = 'restart'
       Registry = @(
           (New-RegEntry 'HKLM:\SYSTEM\CurrentControlSet\Services\AFD\Parameters' 'DefaultReceiveWindow' 'DWord' 64240),
           (New-RegEntry 'HKLM:\SYSTEM\CurrentControlSet\Services\AFD\Parameters' 'DefaultSendWindow' 'DWord' 64240)
       ) },

    @{ Id = 'dns-smart-off'; IsLaptopSafe = $true; Category = 'net'; Group = 'Network stack'; Name = 'Turn off smart multi-homed name resolution'; Risk = 'Low'; Recommended = $false
       Desc = 'Stops Windows from racing a DNS lookup across every network adapter at once and using whichever answers first. On a PC with one active connection (which is most gaming PCs) this does nothing; on a PC with several adapters it can make DNS lookups very slightly more predictable.'
       Registry = @( (New-RegEntry 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\DNSClient' 'DisableSmartNameResolution' 'DWord' 1) ) },

    @{ Id = 'qos-unbind'; IsLaptopSafe = $true; Category = 'net'; Group = 'Network stack'; Name = 'Unbind QoS Packet Scheduler from your network adapter'; Risk = 'Low'; Recommended = $false
       Desc = 'Removes the QoS Packet Scheduler binding from your active network adapter. This is a Windows component, not your router or ISP, and unbinding it is a common (if debated) gaming tweak. Undo re-binds it.'
       Apply = {
           $ad = @(Get-NetAdapter -Physical -ErrorAction Stop | Where-Object { $_.Status -eq 'Up' })
           if ($ad.Count -eq 0) { throw 'No active network adapter was found.' }
           $touched = @()
           foreach ($a in $ad) {
               $b = Get-NetAdapterBinding -Name $a.Name -ComponentID 'ms_pacer' -ErrorAction SilentlyContinue
               if ($b -and $b.Enabled) { Disable-NetAdapterBinding -Name $a.Name -ComponentID 'ms_pacer' -ErrorAction SilentlyContinue; $touched += $a.Name }
           }
           if ($touched.Count -eq 0) { throw 'QoS Packet Scheduler was already off, or not present, on your adapters.' }
           return @{ Adapters = $touched }
       }
       Undo = { param($D) foreach ($n in @($D.Adapters)) { Enable-NetAdapterBinding -Name $n -ComponentID 'ms_pacer' -ErrorAction SilentlyContinue } }
       Test = {
           $any = $false
           foreach ($a in @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' })) {
               $b = Get-NetAdapterBinding -Name $a.Name -ComponentID 'ms_pacer' -ErrorAction SilentlyContinue
               if (-not $b) { continue }
               $any = $true
               if ($b.Enabled) { return $false }
           }
           return $any
       } },

    @{ Id = 'icmp-off'; IsLaptopSafe = $true; Category = 'net'; Group = 'Network stack'; Name = 'Turn off ICMP echo replies (block ping)'; Risk = 'Medium'; Recommended = $false
       Desc = 'Stops this PC from replying to ping (ICMP Echo). A small security-through-obscurity gain, at the cost that ping-based tools, and some game or NAT diagnostics that rely on ICMP, stop working. Undo re-enables the built-in firewall rules.'
       Apply = {
           & netsh.exe advfirewall firewall set rule name="File and Printer Sharing (Echo Request - ICMPv4-In)" new enable=no | Out-Null
           & netsh.exe advfirewall firewall set rule name="File and Printer Sharing (Echo Request - ICMPv6-In)" new enable=no | Out-Null
       }
       Undo = {
           & netsh.exe advfirewall firewall set rule name="File and Printer Sharing (Echo Request - ICMPv4-In)" new enable=yes | Out-Null
           & netsh.exe advfirewall firewall set rule name="File and Printer Sharing (Echo Request - ICMPv6-In)" new enable=yes | Out-Null
       }
       Test = {
           $out = (& netsh.exe advfirewall firewall show rule name="File and Printer Sharing (Echo Request - ICMPv4-In)" 2>&1 | Out-String)
           return [bool]($out -match '(?im)^Enabled:\s*No')
       } },

    @{ Id = 'irq8-priority'; IsLaptopSafe = $true; Category = 'net'; Group = 'Priority'; Name = 'IRQ8 (system clock) priority tweak'; Risk = 'Low'; Recommended = $false
       Desc = 'An old registry tweak (IRQ8Priority) that raises the priority Windows gives the real-time clock interrupt. Common in older tweak guides; on current Windows builds and hardware the measurable effect is close to none, but it is harmless and fully reversible.'
       Restart = 'restart'
       Registry = @( (New-RegEntry 'HKLM:\SYSTEM\CurrentControlSet\Control\PriorityControl' 'IRQ8Priority' 'DWord' 1) ) },

    # ============================ NEW: NVIDIA ============================
    @{ Id = 'nv-powermizer'; Category = 'vendor'; Group = 'NVIDIA registry tweaks'; Name = 'Force PowerMizer to prefer maximum performance'; Risk = 'Medium'; Recommended = $false
       Guard = { Test-HasGpuVendor 'NVIDIA' }
       Desc = 'Sets your NVIDIA driver''s PowerMizer to Prefer Maximum Performance at the driver level, the same effect as the NVIDIA Control Panel setting further down this page, but applied directly. Stops the GPU clocking down between frames. On a laptop this uses noticeably more power and heat, so it is not recommended there. A restore point is made first; undo restores the previous values.'
       Restart = 'restart'
       Apply = {
           $gpus = @(Get-GpuList | Where-Object { $_.Name -match 'NVIDIA|GeForce' })
           if ($gpus.Count -eq 0) { throw 'No NVIDIA graphics card was found.' }
           $base = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}'
           $saved = @()
           $n = 0
           foreach ($sub in @(Get-ChildItem -LiteralPath $base -ErrorAction SilentlyContinue)) {
               $p = Get-ItemProperty -LiteralPath $sub.PSPath -ErrorAction SilentlyContinue
               if (-not $p -or [string]$p.DriverDesc -notmatch 'NVIDIA|GeForce') { continue }
               $key = $sub.PSPath
               foreach ($name in @('PowerMizerEnable', 'PowerMizerLevel', 'PowerMizerLevelAC')) {
                   $saved += (Get-RegSnapshot $key $name)
                   Set-RegValue -Path $key -Name $name -Type 'DWord' -Value 1
               }
               $n++
           }
           if ($n -eq 0) { throw 'Could not find the NVIDIA driver''s registry entry to change.' }
           return @{ Saved = $saved }
       }
       Undo = { param($D) foreach ($s in @($D.Saved)) { if ($s) { Restore-RegSnapshot $s } } }
       Test = {
           $base = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}'
           $any = $false
           foreach ($sub in @(Get-ChildItem -LiteralPath $base -ErrorAction SilentlyContinue)) {
               $p = Get-ItemProperty -LiteralPath $sub.PSPath -ErrorAction SilentlyContinue
               if (-not $p -or [string]$p.DriverDesc -notmatch 'NVIDIA|GeForce') { continue }
               $any = $true
               $c = Get-RegSnapshot $sub.PSPath 'PowerMizerLevelAC'
               if (-not $c.Existed -or [int]$c.Value -ne 1) { return $false }
           }
           return $any
       } },

    # ============================ NEW: DISC ERROR TAB ============================
    @{ Id = 'diag-sfc'; IsLaptopSafe = $true; Category = 'diskerror'; Group = 'Repair commands'; Name = 'SFC /scannow'; Risk = 'Low'; Recommended = $false; OneShot = $true
       Desc = 'Repairs protected Windows system files. Can take 10 to 20 minutes. The result appears in the log below when it finishes.'
       Apply = { Invoke-DiagCommand 'SFC /scannow' 'sfc.exe' @('/scannow') } },

    @{ Id = 'diag-dism-check'; IsLaptopSafe = $true; Category = 'diskerror'; Group = 'Repair commands'; Name = 'DISM CheckHealth'; Risk = 'Low'; Recommended = $false; OneShot = $true
       Desc = 'A quick check for corruption in the Windows component store. Takes a few seconds.'
       Apply = { Invoke-DiagCommand 'DISM CheckHealth' 'dism.exe' @('/Online', '/Cleanup-Image', '/CheckHealth') } },

    @{ Id = 'diag-dism-scan'; IsLaptopSafe = $true; Category = 'diskerror'; Group = 'Repair commands'; Name = 'DISM ScanHealth'; Risk = 'Low'; Recommended = $false; OneShot = $true
       Desc = 'A deeper scan of the Windows component store for corruption. Takes several minutes.'
       Apply = { Invoke-DiagCommand 'DISM ScanHealth' 'dism.exe' @('/Online', '/Cleanup-Image', '/ScanHealth') } },

    @{ Id = 'diag-dism-restore'; IsLaptopSafe = $true; Category = 'diskerror'; Group = 'Repair commands'; Name = 'DISM RestoreHealth'; Risk = 'Low'; Recommended = $false; OneShot = $true
       Desc = 'Repairs the Windows component store, downloading replacement files from Windows Update if needed. Needs an internet connection and can take a while.'
       Apply = { Invoke-DiagCommand 'DISM RestoreHealth' 'dism.exe' @('/Online', '/Cleanup-Image', '/RestoreHealth') } },

    @{ Id = 'diag-chkdsk-scan'; IsLaptopSafe = $true; Category = 'diskerror'; Group = 'Repair commands'; Name = 'CHKDSK /scan (system drive)'; Risk = 'Low'; Recommended = $false; OneShot = $true
       Desc = 'Checks the file system on your system drive for errors while Windows keeps running (an online scan). Does not fix anything by itself.'
       Apply = { Invoke-DiagCommand 'CHKDSK /scan' 'chkdsk.exe' @($env:SystemDrive, '/scan') } },

    @{ Id = 'diag-chkdsk-fix'; IsLaptopSafe = $true; Category = 'diskerror'; Group = 'Repair commands'; Name = 'CHKDSK /f (system drive)'; Risk = 'Medium'; Recommended = $false; OneShot = $true
       Desc = 'Fixes file-system errors on your system drive. Windows cannot lock its own boot drive while running, so this schedules the check for your next restart; you will need to restart the PC yourself afterwards.'
       Apply = {
           $out = (& chkdsk.exe $env:SystemDrive /f 2>&1 | Out-String)
           foreach ($line in ($out -split "`r?`n")) { if ($line.Trim()) { Write-Log $line } }
           Write-Log 'If Windows scheduled the check, restart your PC to let it run before Windows loads.' 'Warn'
       } },

    @{ Id = 'diag-component-cleanup'; IsLaptopSafe = $true; Category = 'diskerror'; Group = 'Repair commands'; Name = 'Component Cleanup'; Risk = 'Low'; Recommended = $false; OneShot = $true
       Desc = 'Removes superseded versions of Windows components that Windows Update leaves behind, freeing disk space. Cannot be undone, but nothing currently in use is removed.'
       Apply = { Invoke-DiagCommand 'Component Cleanup' 'dism.exe' @('/Online', '/Cleanup-Image', '/StartComponentCleanup') } },
    # ============================ NEW v0.6: NETWORK (latency-focused) ============================
    @{ Id = 'netbios-off'; Category = 'net'; Group = 'Network stack'; Name = 'Disable NetBIOS over TCP/IP'; Risk = 'Low'; Recommended = $false
       Desc = 'Turns off the old NetBIOS-over-TCP/IP name resolution on your active adapters. Almost nothing modern uses it (DNS replaced it years ago); only very old LAN file-sharing setups need it. Undo restores each adapter to Default (get the setting from DHCP).'
       Apply = {
           $touched = @()
           foreach ($c in @(Get-CimInstance Win32_NetworkAdapterConfiguration -Filter 'IPEnabled=True' -ErrorAction Stop)) {
               $prev = [int]$c.TcpipNetbiosOptions
               $r = Invoke-CimMethod -InputObject $c -MethodName SetTcpipNetbios -Arguments @{ TcpipNetbiosOptions = 2 }
               if ($r.ReturnValue -eq 0) { $touched += @{ Index = $c.Index; Prev = $prev } }
           }
           if ($touched.Count -eq 0) { throw 'No active network adapter could be changed.' }
           return @{ Touched = $touched }
       }
       Undo = {
           param($D)
           foreach ($t in @($D.Touched)) {
               $c = Get-CimInstance Win32_NetworkAdapterConfiguration -Filter ('Index=' + [int]$t.Index) -ErrorAction SilentlyContinue
               if ($c) { Invoke-CimMethod -InputObject $c -MethodName SetTcpipNetbios -Arguments @{ TcpipNetbiosOptions = [int]$t.Prev } | Out-Null }
           }
       }
       Test = {
           $any = $false
           foreach ($c in @(Get-CimInstance Win32_NetworkAdapterConfiguration -Filter 'IPEnabled=True' -ErrorAction SilentlyContinue)) {
               $any = $true
               if ([int]$c.TcpipNetbiosOptions -ne 2) { return $false }
           }
           return $any
       } },

    @{ Id = 'tcp-ecn-off'; Category = 'net'; Group = 'TCP stack'; Name = 'Turn off ECN (Explicit Congestion Notification)'; Risk = 'Low'; Recommended = $false
       Desc = 'Some home routers handle ECN poorly and drop or mishandle marked packets, which shows up as occasional stalls. Turning it off avoids that specific problem; on a router that handles ECN correctly, ECN can actually reduce packet loss under load, so this is a trade-off, not a guaranteed win.'
       Apply = {
           $prev = (& netsh.exe int tcp show global | Out-String)
           $prevVal = 'default'
           $m = [regex]::Match($prev, '(?im)^ECN Capability\\s*:\\s*(\\S+)')
           if ($m.Success) { $prevVal = $m.Groups[1].Value }
           & netsh.exe int tcp set global ecncapability=disabled | Out-Null
           return @{ Prev = $prevVal }
       }
       Undo = { param($D) & netsh.exe int tcp set global ecncapability=([string]$D.Prev) | Out-Null }
       Test = {
           $out = (& netsh.exe int tcp show global | Out-String)
           return [bool]($out -match '(?im)^ECN Capability\\s*:\\s*disabled')
       } },

    @{ Id = 'tcp-autotuning-normal'; Category = 'net'; Group = 'TCP stack'; Name = 'Reset TCP auto-tuning to Normal'; Risk = 'Low'; Recommended = $true
       Desc = 'Older tweak guides recommend disabling TCP window auto-tuning, but that advice is now outdated and can hurt throughput on modern connections. This makes sure auto-tuning is set to Normal (the healthy default) in case something set it to Disabled in the past.'
       Apply = {
           $prev = 'normal'
           $out = (& netsh.exe int tcp show global | Out-String)
           $m = [regex]::Match($out, '(?im)^Receive Window Auto-Tuning Level\\s*:\\s*(\\S+)')
           if ($m.Success) { $prev = $m.Groups[1].Value }
           & netsh.exe int tcp set global autotuninglevel=normal | Out-Null
           return @{ Prev = $prev }
       }
       Undo = { param($D) & netsh.exe int tcp set global autotuninglevel=([string]$D.Prev) | Out-Null }
       Test = {
           $out = (& netsh.exe int tcp show global | Out-String)
           return [bool]($out -match '(?im)^Receive Window Auto-Tuning Level\\s*:\\s*normal')
       } },

    @{ Id = 'tcp-timestamps-off'; Category = 'net'; Group = 'TCP stack'; Name = 'Turn off TCP timestamps'; Risk = 'Low'; Recommended = $false
       Desc = 'Removes a small timestamp field from TCP packet headers. Saves a handful of bytes per packet; the practical effect on latency or FPS is negligible, included because it is a common request in gaming tweak guides.'
       Apply = {
           $prev = 'default'
           $out = (& netsh.exe int tcp show global | Out-String)
           $m = [regex]::Match($out, '(?im)^RFC 1323 Timestamps\\s*:\\s*(\\S+)')
           if ($m.Success) { $prev = $m.Groups[1].Value }
           & netsh.exe int tcp set global timestamps=disabled | Out-Null
           return @{ Prev = $prev }
       }
       Undo = { param($D) & netsh.exe int tcp set global timestamps=([string]$D.Prev) | Out-Null }
       Test = {
           $out = (& netsh.exe int tcp show global | Out-String)
           return [bool]($out -match '(?im)^RFC 1323 Timestamps\\s*:\\s*disabled')
       } },

    @{ Id = 'nic-power-off'; Category = 'net'; Group = 'Adapter power and offload'; Name = 'Stop Windows powering down your network adapter'; Risk = 'Low'; Recommended = $true
       Desc = 'Unticks "Allow the computer to turn off this device to save power" on your active network adapters, the classic fix for random micro-disconnects and ping spikes. Undo turns power management back on.'
       Apply = {
           $ad = @(Get-NetAdapter -Physical -ErrorAction Stop | Where-Object { $_.Status -eq 'Up' })
           if ($ad.Count -eq 0) { throw 'No active network adapter was found.' }
           $saved = @()
           foreach ($a in $ad) {
               $pm = Get-NetAdapterPowerManagement -Name $a.Name -ErrorAction SilentlyContinue
               if (-not $pm) { continue }
               $saved += @{ Name = $a.Name; Prev = [bool]$pm.AllowComputerToTurnOffDevice }
               try { Set-NetAdapterPowerManagement -Name $a.Name -AllowComputerToTurnOffDevice $false -ErrorAction Stop } catch { }
           }
           if ($saved.Count -eq 0) { throw 'Your adapter does not expose a power-management setting to change.' }
           return @{ Saved = $saved }
       }
       Undo = { param($D) foreach ($s in @($D.Saved)) { try { Set-NetAdapterPowerManagement -Name $s.Name -AllowComputerToTurnOffDevice $s.Prev -ErrorAction Stop } catch { } } }
       Test = {
           $any = $false
           foreach ($a in @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' })) {
               $pm = Get-NetAdapterPowerManagement -Name $a.Name -ErrorAction SilentlyContinue
               if (-not $pm) { continue }
               $any = $true
               if ($pm.AllowComputerToTurnOffDevice) { return $false }
           }
           return $any
       } },

    @{ Id = 'nic-interrupt-mod-off'; Category = 'net'; Group = 'Adapter power and offload'; Name = 'Disable network interrupt moderation'; Risk = 'Low'; Recommended = $false
       Desc = 'Interrupt moderation batches incoming network interrupts to save CPU. Turning it off makes the adapter interrupt the CPU for every packet, which can lower latency slightly at the cost of more CPU use under heavy traffic. Only changes adapters that expose this setting.'
       Apply = {
           $saved = @()
           foreach ($a in @(Get-NetAdapter -Physical -ErrorAction Stop | Where-Object { $_.Status -eq 'Up' })) {
               foreach ($propName in @('*InterruptModeration', 'Interrupt Moderation')) {
                   $p = Get-NetAdapterAdvancedProperty -Name $a.Name -RegistryKeyword $propName -ErrorAction SilentlyContinue
                   if (-not $p) { $p = Get-NetAdapterAdvancedProperty -Name $a.Name -DisplayName $propName -ErrorAction SilentlyContinue }
                   if ($p) { $saved += @{ Adapter = $a.Name; Keyword = $p.RegistryKeyword; Prev = $p.RegistryValue[0] }; Set-NetAdapterAdvancedProperty -Name $a.Name -RegistryKeyword $p.RegistryKeyword -RegistryValue 0 -ErrorAction SilentlyContinue; break }
               }
           }
           if ($saved.Count -eq 0) { throw 'Your network adapter does not expose an interrupt moderation setting.' }
           return @{ Saved = $saved }
       }
       Undo = { param($D) foreach ($s in @($D.Saved)) { try { Set-NetAdapterAdvancedProperty -Name $s.Adapter -RegistryKeyword $s.Keyword -RegistryValue $s.Prev -ErrorAction Stop } catch { } } }
       Test = { return $script:State.ContainsKey('nic-interrupt-mod-off') } },

    @{ Id = 'nic-flow-control-off'; Category = 'net'; Group = 'Adapter power and offload'; Name = 'Disable network adapter Flow Control'; Risk = 'Low'; Recommended = $false
       Desc = 'Turns off Ethernet flow control, which some gaming guides link to steadier ping under load. On a network with a weaker switch or router, turning it off can occasionally cause more dropped packets, so watch for that after applying. Only changes adapters that expose this setting.'
       Apply = {
           $saved = @()
           foreach ($a in @(Get-NetAdapter -Physical -ErrorAction Stop | Where-Object { $_.Status -eq 'Up' })) {
               $p = Get-NetAdapterAdvancedProperty -Name $a.Name -DisplayName 'Flow Control' -ErrorAction SilentlyContinue
               if ($p) { $saved += @{ Adapter = $a.Name; Keyword = $p.RegistryKeyword; Prev = $p.RegistryValue[0] }; Set-NetAdapterAdvancedProperty -Name $a.Name -RegistryKeyword $p.RegistryKeyword -RegistryValue 0 -ErrorAction SilentlyContinue }
           }
           if ($saved.Count -eq 0) { throw 'Your network adapter does not expose a Flow Control setting.' }
           return @{ Saved = $saved }
       }
       Undo = { param($D) foreach ($s in @($D.Saved)) { try { Set-NetAdapterAdvancedProperty -Name $s.Adapter -RegistryKeyword $s.Keyword -RegistryValue $s.Prev -ErrorAction Stop } catch { } } }
       Test = { return $script:State.ContainsKey('nic-flow-control-off') } },

    @{ Id = 'nic-lso-off'; Category = 'net'; Group = 'Adapter power and offload'; Name = 'Disable Large Send Offload'; Risk = 'Low'; Recommended = $false
       Desc = 'Large Send Offload lets the network card assemble big outgoing packets itself, which is great for file-transfer throughput but can add a small, occasional delay spike some players notice in-game. Turning it off trades a little large-transfer speed for steadier small-packet timing.'
       Apply = {
           $saved = @()
           foreach ($a in @(Get-NetAdapter -Physical -ErrorAction Stop | Where-Object { $_.Status -eq 'Up' })) {
               foreach ($p in @(Get-NetAdapterAdvancedProperty -Name $a.Name -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -match '(?i)Large Send Offload' })) {
                   $saved += @{ Adapter = $a.Name; Keyword = $p.RegistryKeyword; Prev = $p.RegistryValue[0] }
                   Set-NetAdapterAdvancedProperty -Name $a.Name -RegistryKeyword $p.RegistryKeyword -RegistryValue 0 -ErrorAction SilentlyContinue
               }
           }
           if ($saved.Count -eq 0) { throw 'Your network adapter does not expose a Large Send Offload setting.' }
           return @{ Saved = $saved }
       }
       Undo = { param($D) foreach ($s in @($D.Saved)) { try { Set-NetAdapterAdvancedProperty -Name $s.Adapter -RegistryKeyword $s.Keyword -RegistryValue $s.Prev -ErrorAction Stop } catch { } } }
       Test = { return $script:State.ContainsKey('nic-lso-off') } },

    @{ Id = 'nic-wol-off'; Category = 'net'; Group = 'Adapter power and offload'; Name = 'Disable Wake-on-LAN'; Risk = 'Low'; Recommended = $false
       Desc = 'Turns off Wake on Magic Packet and pattern-match wake on your active adapters. Only matters if you do not use remote wake-up; harmless either way for gaming performance, included for completeness.'
       Apply = {
           $saved = @()
           foreach ($a in @(Get-NetAdapter -Physical -ErrorAction Stop | Where-Object { $_.Status -eq 'Up' })) {
               foreach ($p in @(Get-NetAdapterAdvancedProperty -Name $a.Name -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -match '(?i)Wake on' })) {
                   $saved += @{ Adapter = $a.Name; Keyword = $p.RegistryKeyword; Prev = $p.RegistryValue[0] }
                   Set-NetAdapterAdvancedProperty -Name $a.Name -RegistryKeyword $p.RegistryKeyword -RegistryValue 0 -ErrorAction SilentlyContinue
               }
           }
           if ($saved.Count -eq 0) { throw 'Your network adapter does not expose a Wake-on-LAN setting.' }
           return @{ Saved = $saved }
       }
       Undo = { param($D) foreach ($s in @($D.Saved)) { try { Set-NetAdapterAdvancedProperty -Name $s.Adapter -RegistryKeyword $s.Keyword -RegistryValue $s.Prev -ErrorAction Stop } catch { } } }
       Test = { return $script:State.ContainsKey('nic-wol-off') } },

    # ============================ NEW v0.6: WINDOWS TWEAKS ============================
    @{ Id = 'cloud-sync-off'; Category = 'windows'; Group = 'Cloud and sync'; Name = 'Turn off Windows settings sync'; Risk = 'Low'; Recommended = $false
       Desc = 'Stops Windows syncing your settings (theme, passwords, language, and so on) to your Microsoft account across devices. Purely a background service, no effect on FPS.'
       Registry = @( (New-RegEntry 'HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows\\SettingSync' 'DisableSettingSync' 'DWord' 2) ) },

    @{ Id = 'experimentation-lock'; Category = 'windows'; Group = 'System settings'; Name = 'Lock Windows experimentation features off'; Risk = 'Low'; Recommended = $true
       Desc = 'Blocks Microsoft''s internal "experimentation" system that can silently turn on or off small Windows features for some users to test them. Keeps your Windows behaving the same way every time, which is worth having on a gaming PC.'
       Registry = @( (New-RegEntry 'HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows\\PreviewBuilds' 'AllowExperimentation' 'DWord' 0) ) },

    @{ Id = 'media-tracking-off'; Category = 'windows'; Group = 'Cloud and sync'; Name = 'Turn off Windows Media Player usage tracking'; Risk = 'Low'; Recommended = $false
       Desc = 'Stops Windows Media Player from tracking what you play and reporting player usage statistics.'
       Registry = @(
           (New-RegEntry 'HKCU:\\Software\\Microsoft\\MediaPlayer\\Preferences' 'UsageTracking' 'DWord' 0)
       ) },

    @{ Id = 'nudge-blocker'; Category = 'windows'; Group = 'Ads and suggestions'; Name = 'Turn off Windows "suggested action" nudges'; Risk = 'Low'; Recommended = $true
       Desc = 'Turns off the small popup suggestions Windows shows near the clock and in File Explorer (things like "connect a Bluetooth device" or "try this feature"). Uses the same content IDs Windows itself uses for these prompts.'
       Registry = @(
           (New-RegEntry $cdm 'SubscribedContent-88000326Enabled' 'DWord' 0),
           (New-RegEntry $cdm 'SubscribedContent-88000175Enabled' 'DWord' 0)
       ) },

    @{ Id = 'proximity-off'; Category = 'windows'; Group = 'System settings'; Name = 'Turn off Nearby Sharing (proximity device discovery)'; Risk = 'Low'; Recommended = $false
       Desc = 'Stops Windows using Bluetooth to discover nearby devices for Nearby Sharing. Saves a small amount of background CPU/radio use; no effect on gaming performance.'
       Registry = @(
           (New-RegEntry 'HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\CDP' 'NearShareChannelUserAuthzPolicy' 'DWord' 0),
           (New-RegEntry 'HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\CDP' 'CdpSessionUserAuthzPolicy' 'DWord' 0)
       ) },

    @{ Id = 'search-cloud-off'; Category = 'windows'; Group = 'Ads and suggestions'; Name = 'Turn off cloud and OneDrive results in Windows Search'; Risk = 'Low'; Recommended = $true
       Desc = 'Goes further than the existing web-search tweak: stops Windows Search from including OneDrive and other cloud content in results at all, so search stays fully local and a little faster to respond.'
       Registry = @(
           (New-RegEntry 'HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows\\Windows Search' 'AllowCloudSearch' 'DWord' 0),
           (New-RegEntry 'HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows\\Windows Search' 'ConnectedSearchUseWeb' 'DWord' 0)
       ) },

    @{ Id = 'voice-activation-off'; Category = 'windows'; Group = 'System settings'; Name = 'Block apps from activating with voice'; Risk = 'Low'; Recommended = $false
       Desc = 'Stops apps from being able to wake themselves up using voice activation (for example a voice assistant listening in the background), which is one less background process listening for audio.'
       Registry = @( (New-RegEntry 'HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows\\AppPrivacy' 'LetAppsActivateWithVoice' 'DWord' 2) ) },

    @{ Id = 'whql-only'; Category = 'windows'; Group = 'System settings'; Name = 'Only allow WHQL-signed drivers'; Risk = 'Medium'; Recommended = $false
       Desc = 'Uses the legacy but still-honoured Windows Driver Signing policy to block installing any driver that has not passed Microsoft''s WHQL certification. Most drivers today are already WHQL-signed, so you likely will not notice a difference day to day, but it can get in the way if you ever need a beta or unsigned driver.'
       Apply = {
           $path = 'HKLM:\\SOFTWARE\\Microsoft\\Driver Signing'
           $snap = Get-RegSnapshot $path 'Policy'
           Set-RegValue -Path $path -Name 'Policy' -Type 'Binary' -Value ([byte[]](2, 0, 0, 0))
           return @{ Saved = @($snap) }
       }
       Undo = { param($D) foreach ($s in @($D.Saved)) { if ($s) { Restore-RegSnapshot $s } } }
       Test = {
           $c = Get-RegSnapshot 'HKLM:\\SOFTWARE\\Microsoft\\Driver Signing' 'Policy'
           return [bool]($c.Existed -and $c.Value -and $c.Value.Length -gt 0 -and $c.Value[0] -eq 2)
       } },

    @{ Id = 'windows-update-defer'; Category = 'windows'; Group = 'System settings'; Name = 'Defer Windows feature and quality updates'; Risk = 'Medium'; Recommended = $false
       Desc = 'Delays new Windows feature updates by up to a year and quality (security) updates by a few days, so a fresh, occasionally buggy update does not land on your PC the moment it ships. This defers updates, it does NOT turn off Windows Update entirely: security patches still arrive, just a little later. Deferring is the safer choice; fully disabling Windows Update is not offered here.'
       Registry = @(
           (New-RegEntry 'HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows\\WindowsUpdate' 'DeferFeatureUpdatesPeriodInDays' 'DWord' 180),
           (New-RegEntry 'HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows\\WindowsUpdate' 'DeferQualityUpdatesPeriodInDays' 'DWord' 4)
       ) },

    @{ Id = 'windows-ai-off'; Category = 'windows'; Group = 'System settings'; Name = 'Turn off Windows Copilot and AI data analysis'; Risk = 'Low'; Recommended = $false
       Desc = 'Blocks Windows Copilot and the newer AI features (like Recall''s screen analysis, on the Windows versions that have it) at the policy level. Frees a bit of background CPU/NPU/RAM these features would otherwise reserve.'
       Registry = @(
           (New-RegEntry 'HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows\\WindowsCopilot' 'TurnOffWindowsCopilot' 'DWord' 1),
           (New-RegEntry 'HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows\\WindowsAI' 'DisableAIDataAnalysis' 'DWord' 1)
       ) },

    @{ Id = 'taskbar-jumplist-off'; Category = 'windows'; Group = 'Visual effects'; Name = 'Stop tracking recently opened files (jump lists)'; Risk = 'Low'; Recommended = $false
       Desc = 'Stops Windows recording which files and apps you opened recently, used to build taskbar jump lists and the Start menu recent list. A small reduction in background disk activity and a privacy gain; you lose the jump-list shortcuts to recent files.'
       Registry = @( (New-RegEntry $explorerAdv 'Start_TrackDocs' 'DWord' 0) ) },

    @{ Id = 'alt-tab-classic'; Category = 'windows'; Group = 'Visual effects'; Name = 'Classic Alt+Tab (desktop apps only)'; Risk = 'Low'; Recommended = $false
       Desc = 'Switches Alt+Tab back to the classic style that only cycles through open desktop app windows, skipping the modern browser-tab thumbnails, which can feel snappier with lots of tabs open.'
       Restart = 'sign-out'
       Registry = @( (New-RegEntry $explorerAdv 'AltTabSettings' 'DWord' 1) ) },

    @{ Id = 'explorer-onedrive-nag-off'; Category = 'windows'; Group = 'Visual effects'; Name = 'Turn off OneDrive sync notifications in Explorer'; Risk = 'Low'; Recommended = $false
       Desc = 'Stops the little OneDrive sync popups and badges inside File Explorer. OneDrive itself keeps syncing; you just stop seeing the notifications about it.'
       Registry = @( (New-RegEntry $explorerAdv 'ShowSyncProviderNotifications' 'DWord' 0) ) },

    @{ Id = 'audio-ducking-off'; Category = 'windows'; Group = 'Latency'; Name = 'Stop Windows lowering other sounds during calls (audio ducking)'; Risk = 'Low'; Recommended = $false
       Desc = 'Sets Sound settings, Communications to "Do nothing" so Windows never automatically quietens your game or music when it thinks you are on a call. Purely a convenience setting, not a performance tweak.'
       Registry = @( (New-RegEntry 'HKCU:\\Software\\Microsoft\\Multimedia\\Audio' 'UserDuckingPreference' 'DWord' 3) ) },

    @{ Id = 'bcdedit-bootux-off'; Category = 'windows'; Group = 'Boot (BCDEdit)'; Name = 'Skip the Windows boot animation'; Risk = 'Low'; Recommended = $false
       Desc = 'Runs bcdedit /set bootux disabled so Windows skips its spinning-dots boot animation. Shaves a small amount of perceived boot time; does not affect anything once Windows is running. If BitLocker is on, protection is suspended for one restart so this does not trigger a recovery-key prompt.'
       Restart = 'restart'
       Apply = {
           $susp = Suspend-BitLockerForBoot
           & bcdedit.exe /set '{current}' bootux disabled | Out-Null
           if ($LASTEXITCODE -ne 0) { throw 'bcdedit could not change the boot animation setting.' }
           return @{ Suspended = $susp }
       }
       Undo = {
           [void](Suspend-BitLockerForBoot)
           & bcdedit.exe /set '{current}' bootux standard | Out-Null
       }
       Test = {
           $out = (& bcdedit.exe /enum '{current}' 2>&1 | Out-String)
           return [bool]($out -match '(?im)^\\s*bootux\\s+disabled')
       } },

    # ============================ NEW v0.6: CPU ============================
    @{ Id = 'core-parking-off'; Category = 'cpu'; Group = 'Power'; Name = 'Disable CPU core parking'; Risk = 'Medium'; Recommended = $false
       Desc = 'Windows "parks" (idles) CPU cores it thinks you do not need to save power, then has to unpark them when load spikes, which takes a moment. This forces all cores to stay unparked and ready on the active power plan. Applies to whichever plan is active, so apply it after choosing your power plan.'
       Apply = {
           $scheme = Get-ActiveSchemeGuid
           if (-not $scheme) { throw 'Could not read the active power plan.' }
           $out = (& powercfg.exe /q $scheme SUB_PROCESSOR CPMINCORES | Out-String)
           $prev = 0; $m = [regex]::Match($out, '(?m)Current AC Power Setting Index:\\s*0x([0-9a-fA-F]+)'); if ($m.Success) { $prev = [Convert]::ToInt32($m.Groups[1].Value, 16) }
           & powercfg.exe /setacvalueindex $scheme SUB_PROCESSOR CPMINCORES 100 | Out-Null
           & powercfg.exe /setdcvalueindex $scheme SUB_PROCESSOR CPMINCORES 100 | Out-Null
           & powercfg.exe /setactive $scheme | Out-Null
           return @{ Scheme = $scheme; Prev = $prev }
       }
       Undo = {
           param($D)
           & powercfg.exe /setacvalueindex ([string]$D.Scheme) SUB_PROCESSOR CPMINCORES ([string][int]$D.Prev) | Out-Null
           & powercfg.exe /setdcvalueindex ([string]$D.Scheme) SUB_PROCESSOR CPMINCORES ([string][int]$D.Prev) | Out-Null
           & powercfg.exe /setactive ([string]$D.Scheme) | Out-Null
       }
       Test = {
           $scheme = Get-ActiveSchemeGuid
           if (-not $scheme) { return $false }
           $out = (& powercfg.exe /q $scheme SUB_PROCESSOR CPMINCORES | Out-String)
           $m = [regex]::Match($out, '(?m)Current AC Power Setting Index:\\s*0x([0-9a-fA-F]+)')
           return [bool]($m.Success -and [Convert]::ToInt32($m.Groups[1].Value, 16) -eq 100)
       } },

    @{ Id = 'pcie-aspm-off'; Category = 'cpu'; Group = 'Power'; Name = 'Turn off PCIe Link State Power Management'; Risk = 'Medium'; Recommended = $false
       Desc = 'Stops PCIe devices (your GPU, NVMe SSD, network card) from dropping into low-power link states between bursts of activity. Some systems see steadier frame times and fewer micro-stutters; on a laptop this raises power use and heat noticeably.'
       Apply = {
           $scheme = Get-ActiveSchemeGuid
           if (-not $scheme) { throw 'Could not read the active power plan.' }
           & powercfg.exe /setacvalueindex $scheme SUB_PCIEXPRESS ASPM 0 | Out-Null
           & powercfg.exe /setactive $scheme | Out-Null
           return @{ Scheme = $scheme }
       }
       Undo = {
           param($D)
           & powercfg.exe /setacvalueindex ([string]$D.Scheme) SUB_PCIEXPRESS ASPM 1 | Out-Null
           & powercfg.exe /setactive ([string]$D.Scheme) | Out-Null
       }
       Test = {
           $scheme = Get-ActiveSchemeGuid
           if (-not $scheme) { return $false }
           $out = (& powercfg.exe /q $scheme SUB_PCIEXPRESS ASPM | Out-String)
           $m = [regex]::Match($out, '(?m)Current AC Power Setting Index:\\s*0x([0-9a-fA-F]+)')
           return [bool]($m.Success -and [Convert]::ToInt32($m.Groups[1].Value, 16) -eq 0)
       } },

    @{ Id = 'mem-compression-off'; Category = 'cpu'; Group = 'Memory'; Name = 'Turn off Memory Compression'; Risk = 'Medium'; Recommended = $false
       Desc = 'Windows compresses inactive memory pages instead of paging them to disk, which normally helps low-RAM PCs. With 16 GB or more this compression work is mostly wasted CPU time. Microsoft generally recommends leaving it on; only turn this off if you have plenty of RAM to spare.'
       Apply = {
           $prev = (Get-MMAgent).MemoryCompression
           Disable-MMAgent -MemoryCompression -ErrorAction Stop
           return @{ Prev = [bool]$prev }
       }
       Undo = { param($D) if ($D.Prev) { Enable-MMAgent -MemoryCompression -ErrorAction SilentlyContinue } }
       Test = { try { return -not (Get-MMAgent).MemoryCompression } catch { return $false } } },

    @{ Id = 'page-combining-off'; Category = 'cpu'; Group = 'Memory'; Name = 'Turn off Page Combining'; Risk = 'Low'; Recommended = $false
       Desc = 'Windows periodically scans RAM for identical pages across processes and merges them to save memory, which uses a little background CPU. Turning it off trades a bit of RAM efficiency for slightly less background scanning.'
       Apply = {
           $prev = (Get-MMAgent).PageCombining
           Disable-MMAgent -PageCombining -ErrorAction Stop
           return @{ Prev = [bool]$prev }
       }
       Undo = { param($D) if ($D.Prev) { Enable-MMAgent -PageCombining -ErrorAction SilentlyContinue } }
       Test = { try { return -not (Get-MMAgent).PageCombining } catch { return $false } } },

    @{ Id = 'hpet-off'; Category = 'cpu'; Group = 'Latency and kernel'; Name = 'Force the platform clock off (HPET)'; Risk = 'Medium'; Recommended = $false
       Desc = 'Tells Windows not to use the High Precision Event Timer as its main clock source. Reported results are genuinely mixed: some motherboards see fewer micro-stutters, others see no change or slightly worse. Test it in your own games and undo if it does not help. BitLocker is suspended for one restart if it is on.'
       Restart = 'restart'
       Apply = {
           $susp = Suspend-BitLockerForBoot
           $prev = Get-BcdFlag 'useplatformclock'
           & bcdedit.exe /set '{current}' useplatformclock false | Out-Null
           if ($LASTEXITCODE -ne 0) { throw 'bcdedit could not change useplatformclock.' }
           return @{ Prev = $prev; Suspended = $susp }
       }
       Undo = {
           param($D)
           [void](Suspend-BitLockerForBoot)
           if ($D.Prev) { & bcdedit.exe /set '{current}' useplatformclock ([string]$D.Prev) | Out-Null }
           else { & bcdedit.exe /deletevalue '{current}' useplatformclock | Out-Null }
       }
       Test = {
           $f = Get-BcdFlag 'useplatformclock'
           return [bool]($f -and $f -match '^(?i:false|no)$')
       } },

    @{ Id = 'standby-cleaner'; Category = 'cpu'; Group = 'Memory'; Name = 'Clear the Standby memory list'; Risk = 'Low'; Recommended = $false; OneShot = $true
       Desc = 'Uses the same technique as Sysinternals RAMMap and the well-known EmptyStandbyList tool to purge cached-but-unused memory back to Free, which can help right after closing a memory-heavy app. Windows will refill the cache naturally as you keep using the PC; nothing is lost.'
       Apply = {
           if (-not $script:NativeOk) { throw 'The native helper is unavailable, so this cannot run.' }
           $before = [CT.Sys]::Memory()
           $ok = [CT.Sys]::PurgeStandbyList()
           if (-not $ok) { throw 'Windows refused the request (it needs to run elevated, which Compact Tweaks already is, so this is unexpected).' }
           Start-Sleep -Milliseconds 300
           $after = [CT.Sys]::Memory()
           if ($before -and $after) {
               $freed = ([double]$after.AvailPhys - [double]$before.AvailPhys) / 1MB
               Write-Log ('Standby list cleared, about {0} MB now free' -f [math]::Max(0, [math]::Round($freed))) 'Ok'
           } else { Write-Log 'Standby list cleared.' 'Ok' }
       } },

    # ============================ NEW v0.6: NVIDIA ============================
    @{ Id = 'nv-telemetry-off'; Category = 'vendor'; Group = 'NVIDIA debloat'; Name = 'Disable the NVIDIA Telemetry Container'; Risk = 'Low'; Recommended = $false
       Guard = { Test-HasGpuVendor 'NVIDIA' }
       Desc = 'Disables the NvTelemetryContainer service, which reports GeForce Experience usage data back to NVIDIA in the background. Your graphics driver keeps working exactly the same; you only lose that telemetry reporting. Undo restores its original start mode.'
       Services = @( @{ Name = 'NvTelemetryContainer'; Mode = 'Disabled' } ) },

    @{ Id = 'nv-overlay-off'; Category = 'vendor'; Group = 'NVIDIA debloat'; Name = 'Disable the GeForce Experience overlay service'; Risk = 'Medium'; Recommended = $false
       Guard = { Test-HasGpuVendor 'NVIDIA' }
       Desc = 'Disables NVIDIA Container (NvContainerLocalSystem), which runs the ShadowPlay/Instant Replay overlay, in-game recording, and GeForce Experience''s driver-update notifications. Your actual graphics driver and games are unaffected; you lose the overlay, recording and update pop-ups from GeForce Experience specifically. Some players find this also removes an occasional source of overlay-related stutter.'
       Services = @( @{ Name = 'NvContainerLocalSystem'; Mode = 'Disabled' } ) },

    # ============================ NEW v0.6: DEBLOATING ============================
    @{ Id = 'chrome-debloat'; Category = 'debloat'; Group = 'Browser debloat'; Name = 'Debloat Chrome (background mode and silent auto-update checks)'; Risk = 'Low'; Recommended = $false
       Desc = 'Turns off Chrome''s background mode (so it cannot keep running after you close the last window) and disables its two scheduled background update-check tasks. You can still update Chrome manually any time from its own menu; this only stops the silent background checks.'
       Registry = @( (New-RegEntry 'HKLM:\\SOFTWARE\\Policies\\Google\\Chrome' 'BackgroundModeEnabled' 'DWord' 0) )
       Apply = {
           $touched = Disable-ScheduledTaskList @('\\GoogleUpdateTaskMachineCore', '\\GoogleUpdateTaskMachineUA')
           return @{ Tasks = $touched }
       }
       Undo = { param($D) Enable-ScheduledTaskList @($D.Tasks) } },

    @{ Id = 'trim-force-on'; Category = 'storage'; Group = 'NTFS (fsutil)'; Name = 'Make sure TRIM is enabled'; Risk = 'Low'; Recommended = $true
       Desc = 'Confirms fsutil behavior set disabledeletenotify is 0, meaning Windows is allowed to send TRIM commands to your SSD so it can reuse deleted space efficiently. This is on by default; this tweak simply forces it back on if something ever turned it off, keeping your SSD healthy and fast long-term.'
       Apply = {
           $prev = (& fsutil.exe behavior query disabledeletenotify 2>&1 | Out-String)
           $prevVal = 0
           $m = [regex]::Match($prev, '(\d+)')
           if ($m.Success) { $prevVal = [int]$m.Groups[1].Value }
           & fsutil.exe behavior set disabledeletenotify 0 | Out-Null
           return @{ Prev = $prevVal }
       }
       Undo = { param($D) & fsutil.exe behavior set disabledeletenotify ([int]$D.Prev) | Out-Null }
       Test = {
           $out = (& fsutil.exe behavior query disabledeletenotify 2>&1 | Out-String)
           return [bool]($out -match '=\s*0')
       } },

    @{ Id = 'tcp-rsc-off'; Category = 'net'; Group = 'TCP stack'; Name = 'Disable Receive Segment Coalescing (RSC)'; Risk = 'Low'; Recommended = $false
       Desc = 'RSC merges several incoming TCP segments into one before handing them to the CPU, which helps throughput but can add a small delay. Turning it off processes packets as they arrive instead of batching them, trading a little throughput for steadier timing. Global setting; applies system-wide.'
       Apply = {
           $prev = 'enabled'
           $out = (& netsh.exe int tcp show global | Out-String)
           $m = [regex]::Match($out, '(?im)^Receive Segment Coalescing State\s*:\s*(\S+)')
           if ($m.Success) { $prev = $m.Groups[1].Value }
           & netsh.exe int tcp set global rsc=disabled | Out-Null
           return @{ Prev = $prev }
       }
       Undo = { param($D) & netsh.exe int tcp set global rsc=([string]$D.Prev) | Out-Null }
       Test = {
           $out = (& netsh.exe int tcp show global | Out-String)
           return [bool]($out -match '(?im)^Receive Segment Coalescing State\s*:\s*disabled')
       } },

    @{ Id = 'tcp-chimney-off'; Category = 'net'; Group = 'TCP stack'; Name = 'Disable TCP Chimney Offload'; Risk = 'Low'; Recommended = $false
       Desc = 'An older offload feature that hands entire TCP connections to the network card. Windows 10/11 mostly ignore it already on modern hardware, so this is usually a no-op, but it is a common item in gaming tweak lists so it is included for completeness.'
       Apply = { & netsh.exe int tcp set global chimney=disabled | Out-Null }
       Undo = { & netsh.exe int tcp set global chimney=automatic | Out-Null }
       Test = {
           $out = (& netsh.exe int tcp show global | Out-String)
           return [bool]($out -match '(?im)^Chimney Offload State\s*:\s*disabled')
       } },

    @{ Id = 'nv-crashreport-tasks-off'; Category = 'vendor'; Group = 'NVIDIA debloat'; Name = 'Disable NVIDIA crash-report scheduled tasks'; Risk = 'Low'; Recommended = $false
       Guard = { Test-HasGpuVendor 'NVIDIA' }
       Desc = 'Turns off the NvTmRep_CrashReport scheduled tasks GeForce Experience creates to send crash reports to NVIDIA in the background. No effect on the driver or your games; only stops that reporting.'
       Apply = {
           $found = @(Get-ScheduledTask -TaskName 'NvTmRep_CrashReport*' -ErrorAction SilentlyContinue | ForEach-Object { $_.TaskPath.TrimEnd('\\') + '\\' + $_.TaskName })
           if ($found.Count -eq 0) { throw 'No NVIDIA crash-report tasks were found on this PC.' }
           $touched = Disable-ScheduledTaskList $found
           return @{ Tasks = $touched }
       }
       Undo = { param($D) Enable-ScheduledTaskList @($D.Tasks) }
       Test = { return $script:State.ContainsKey('nv-crashreport-tasks-off') } }
)

$script:Tweaks = @($script:Tweaks) + @(Get-ExtraPerformanceTweaks)

# Hide tweaks that do not apply to this PC (for example Windows 11 only ones on Windows 10).
$script:Tweaks = @($script:Tweaks | Where-Object { (-not $_.Guard) -or [bool](& $_.Guard) })
$script:Tweaks = @($script:Tweaks) + @(Get-AppOptimizerTweaks)

# ----------------------------------------------------------------------------
# Engine: status, apply, undo
# ----------------------------------------------------------------------------
function Test-TweakMatches {
    param($T)
    if ($T.OneShot) { return $false }
    try {
        if ($T.Test) { return [bool](& $T.Test) }
        foreach ($r in @($T.Registry)) {
            if (-not $r) { continue }
            $cur = Get-RegSnapshot $r.Path $r.Name
            if (-not $cur.Existed) { return $false }
            if ("$($cur.Value)" -ne "$($r.Value)") { return $false }
        }
        foreach ($s in @($T.Services)) {
            if (-not $s) { continue }
            $cur = Get-SvcSnapshot $s.Name
            if ($cur.Exists -and $cur.Mode -ne $s.Mode) { return $false }
        }
        return $true
    } catch { return $false }
}

function Get-TweakState {
    # Applied    = Compact Tweaks changed it (undo data exists) and the values still match
    # AlreadySet = values match, but Compact Tweaks did not set them
    # NotApplied = values do not match      OneShot = cleanup / launcher action
    param($T)
    if ($T.OneShot) { return 'OneShot' }
    $isSet   = Test-TweakMatches $T
    $hasSnap = $script:State.ContainsKey($T.Id)
    if ($isSet -and $hasSnap) { return 'Applied' }
    if ($isSet) { return 'AlreadySet' }
    return 'NotApplied'
}

function Restore-Snapshot {
    param($Snap, $T)
    foreach ($r in @($Snap.Registry)) { if ($r) { Restore-RegSnapshot $r } }
    foreach ($s in @($Snap.Services)) {
        if ($s -and $s.Exists) {
            Set-SvcStart -Name $s.Name -Mode $s.Mode -Delayed ([bool]$s.Delayed)
            if ($s.WasRunning) { Start-Service -Name $s.Name -ErrorAction SilentlyContinue }
        }
    }
    if ($T.Undo -and $null -ne $Snap.Custom) { & $T.Undo $Snap.Custom }
}

function Invoke-TweakApply {
    param($T)

    if ($T.OneShot) {
        Write-Log ('Running: ' + $T.Name)
        try { & $T.Apply | Out-Null } catch { Write-Log ("{0} failed: {1}" -f $T.Name, $_.Exception.Message) 'Error' }
        return
    }

    $tweakState = Get-TweakState $T
    if ($tweakState -eq 'Applied') { Write-Log ('Already applied: ' + $T.Name); return }
    if ($tweakState -eq 'AlreadySet') {
        Write-Log ('{0}: this PC already has these settings (set by Windows or another tool), nothing to change.' -f $T.Name)
        return
    }

    Write-Log ('Applying: ' + $T.Name)
    $snap = @{ Time = (Get-Date).ToString('s'); Registry = @(); Services = @(); Custom = $null }
    try {
        foreach ($r in @($T.Registry)) { if ($r) { $snap.Registry += (Get-RegSnapshot $r.Path $r.Name) } }
        foreach ($s in @($T.Services)) { if ($s) { $snap.Services += (Get-SvcSnapshot $s.Name) } }

        foreach ($r in @($T.Registry)) { if ($r) { Set-RegValue -Path $r.Path -Name $r.Name -Type $r.Type -Value $r.Value } }
        foreach ($s in @($T.Services)) {
            if (-not $s) { continue }
            $cur = Get-SvcSnapshot $s.Name
            if (-not $cur.Exists) { Write-Log ("Service {0} does not exist on this PC, skipped" -f $s.Name) 'Warn'; continue }
            Set-SvcStart -Name $s.Name -Mode $s.Mode
            if ($s.Mode -eq 'Disabled') { Stop-Service -Name $s.Name -Force -ErrorAction SilentlyContinue }
        }
        if ($T.Apply) { $snap.Custom = & $T.Apply }

        $script:State[$T.Id] = $snap
        Save-State
        Write-Log ('Applied: ' + $T.Name) 'Ok'
        if ($T.Restart) { $script:NeedRestart = $true }
    } catch {
        Write-Log ("{0} failed: {1}. Rolling back." -f $T.Name, $_.Exception.Message) 'Error'
        try { Restore-Snapshot $snap $T } catch { Write-Log ('Rollback problem: ' + $_.Exception.Message) 'Error' }
    }
}

function Invoke-TweakUndo {
    param($T)
    if ($T.OneShot) { Write-Log ($T.Name + ': one-time action, nothing to undo.'); return }
    if (-not $script:State.ContainsKey($T.Id)) {
        Write-Log ($T.Name + ': no saved snapshot from this tool, nothing to undo.') 'Warn'
        return
    }
    Write-Log ('Undoing: ' + $T.Name)
    try {
        Restore-Snapshot $script:State[$T.Id] $T
        $script:State.Remove($T.Id)
        Save-State
        Write-Log ('Restored: ' + $T.Name) 'Ok'
        if ($T.Restart) { $script:NeedRestart = $true }
    } catch {
        Write-Log ("Undo of {0} failed: {1}" -f $T.Name, $_.Exception.Message) 'Error'
    }
}

# ----------------------------------------------------------------------------
# Icons and tabs
# ----------------------------------------------------------------------------
$script:IconData = @{
    home    = 'M3,11 L12,3 L21,11 M5,10 V20 H10 V14 H14 V20 H19 V10'
    oc      = 'M4.5,18 A9,9 0 1 1 19.5,18 M12,13 L16,8'
    gpu     = 'M4,7 H20 Q22,7 22,9 V15 Q22,17 20,17 H4 Q2,17 2,15 V9 Q2,7 4,7 Z M9,9.5 A2.5,2.5 0 1 1 9,14.5 A2.5,2.5 0 1 1 9,9.5 Z M15,10 H19 M15,14 H19 M5,17 V19 M9,17 V19'
    cpu     = 'M8,6 H16 Q18,6 18,8 V16 Q18,18 16,18 H8 Q6,18 6,16 V8 Q6,6 8,6 Z M9.5,9.5 H14.5 V14.5 H9.5 Z M9,2 V5 M15,2 V5 M9,19 V22 M15,19 V22 M2,9 H5 M2,15 H5 M19,9 H22 M19,15 H22'
    kbm     = 'M4,6 H20 Q22,6 22,8 V16 Q22,18 20,18 H4 Q2,18 2,16 V8 Q2,6 4,6 Z M6,10 H6.5 M10,10 H10.5 M14,10 H14.5 M18,10 H18.5 M7.5,14 H16.5'
    aim     = 'M12,4 A8,8 0 1 1 12,20 A8,8 0 1 1 12,4 Z M12,2 V7 M12,17 V22 M2,12 H7 M17,12 H22'
    vendor  = 'M12,3 L21,8 L12,13 L3,8 Z M3,13 L12,18 L21,13'
    debloat = 'M4,7 H20 M9,7 V4 H15 V7 M6,7 L7,20 H17 L18,7 M10,11 V17 M14,11 V17'
    net     = 'M12,3 A9,9 0 1 1 12,21 A9,9 0 1 1 12,3 Z M3,12 H21 M12,3 C15,6 15,18 12,21 M12,3 C9,6 9,18 12,21'
    laptop  = 'M6.5,5 H17.5 Q19,5 19,6.5 V15 H5 V6.5 Q5,5 6.5,5 Z M2,19 H22'
    apps    = 'M3,3 H10 V10 H3 Z M14,3 H21 V10 H14 Z M3,14 H10 V21 H3 Z M14,14 H21 V21 H14 Z'
    extra   = 'M12,3 L13.8,8.2 L19,10 L13.8,11.8 L12,17 L10.2,11.8 L5,10 L10.2,8.2 Z M19,16 V20 M17,18 H21'
    bios    = 'M6,4 H18 Q20,4 20,6 V18 Q20,20 18,20 H6 Q4,20 4,18 V6 Q4,4 6,4 Z M8,9 H12 M8,12 H16 M8,15 H14'
    mem     = 'M2,8 H22 V16 H2 Z M6,8 V16 M10,8 V16 M14,8 V16 M18,8 V16'
    disk    = 'M4,5 H20 V19 H4 Z M8,10 A2,2 0 1 1 8,14 A2,2 0 1 1 8,10 Z M14,10 H18 M14,14 H18'
    info    = 'M12,3 A9,9 0 1 1 12,21 A9,9 0 1 1 12,3 Z M12,11 V16 M12,8 H12.1'
    discord = 'M5,7 Q12,3 19,7 L20,17 Q17,20 14.5,19 L13.5,17.5 H10.5 L9.5,19 Q7,20 4,17 Z M9,11.5 H9.1 M15,11.5 H15.1'
    windows = 'M3,5.5 L11,4.3 V11.5 H3 Z M12,4.15 L21,3 V11.5 H12 Z M3,12.5 H11 V19.7 L3,18.5 Z M12,12.5 H21 V21 L12,19.85 Z'
    stackicon = 'M4,7 H20 V17 H4 Z M4,7 L12,3 L20,7 M4,17 L12,21 L20,17 M8,10 H16 M8,14 H16'
}
$script:Icons = @{}
foreach ($k in @($script:IconData.Keys)) {
    try { $script:Icons[$k] = [System.Windows.Media.Geometry]::Parse($script:IconData[$k]) }
    catch { $script:Icons[$k] = [System.Windows.Media.Geometry]::Empty }
}

# ----------------------------------------------------------------------------
# Tweak tags: small emoji shown bottom-left of a tweak's description, each with
# a tooltip explaining what it means. A tweak can carry several tags at once.
# ----------------------------------------------------------------------------
$script:TagDefs = @{
    perf     = @{ Emoji = '(rocket)'; Tip = 'Performance: improves overall speed and responsiveness.' }
    systune  = @{ Emoji = '(gear)'; Tip = 'System tuning: adjusts how Windows itself behaves.' }
    boost    = @{ Emoji = '(chart)'; Tip = 'Performance boost: aims to raise FPS or throughput directly.' }
    aim      = @{ Emoji = '(target)'; Tip = 'Aim / input: changes how your mouse or keyboard feels in-game.' }
    systweak = @{ Emoji = '(wrench)'; Tip = 'System tweak: a lower-level change under the hood.' }
    config   = @{ Emoji = '(screwdriver)'; Tip = 'Configuration: sets up an app or driver option for you.' }
    latency  = @{ Emoji = '(stopwatch)'; Tip = 'Latency: aims to cut delay between an action and its result.' }
    cleanup  = @{ Emoji = '(broom)'; Tip = 'Cleanup: removes clutter, bloat or temporary files.' }
    laptop   = @{ Emoji = '(laptop)'; Tip = 'Laptop-safe: checked as reasonable to use on a laptop.' }
    qol      = @{ Emoji = '(battery)'; Tip = 'Quality of life: a small everyday convenience.' }
    disk     = @{ Emoji = '(disk)'; Tip = 'Disk health: scans the system for errors and repairs common issues.' }
    net      = @{ Emoji = '(globe)'; Tip = 'Network tuning: changes how your PC talks to the internet.' }
    oc       = @{ Emoji = 'OC'; Tip = 'Overclocking: pushes hardware beyond its stock settings for more performance.'; UseIcon = 'oc' }
    security = @{ Emoji = '(lock)'; Tip = 'Security trade-off: turns off a protection in exchange for speed.' }
    nvidia   = @{ Emoji = 'GPU'; Tip = 'NVIDIA-specific tweak.'; UseIcon = 'vendor' }
    amd      = @{ Emoji = 'GPU'; Tip = 'AMD-specific tweak.'; UseIcon = 'vendor' }
    ram      = @{ Emoji = 'RAM'; Tip = 'Memory (RAM) tweak.'; UseIcon = 'mem' }
    oneshot  = @{ Emoji = '(bolt)'; Tip = 'One-time action: cannot be undone from here.' }
}
# The literal glyphs (kept out of the table above so the file stays readable; PowerShell 5.1 needs
# these as real Unicode characters, which [char]::ConvertFromUtf32 builds portably from code points).
function New-Emoji { param([int[]]$Points) return -join ($Points | ForEach-Object { [char]::ConvertFromUtf32($_) }) }
$script:TagDefs['perf'].Emoji     = New-Emoji @(0x1F680)          # rocket
$script:TagDefs['systune'].Emoji  = New-Emoji @(0x2699, 0xFE0F)   # gear
$script:TagDefs['boost'].Emoji    = New-Emoji @(0x1F4C8)          # chart increasing
$script:TagDefs['aim'].Emoji      = New-Emoji @(0x1F3AF)          # target
$script:TagDefs['systweak'].Emoji = New-Emoji @(0x1F6E0, 0xFE0F)  # hammer and wrench
$script:TagDefs['config'].Emoji   = New-Emoji @(0x1F527)          # wrench
$script:TagDefs['latency'].Emoji  = New-Emoji @(0x23F1, 0xFE0F)   # stopwatch
$script:TagDefs['cleanup'].Emoji  = New-Emoji @(0x1F9F9)          # broom
$script:TagDefs['laptop'].Emoji   = New-Emoji @(0x1F4BB)          # laptop
$script:TagDefs['qol'].Emoji      = New-Emoji @(0x1F50B)          # battery
$script:TagDefs['disk'].Emoji     = New-Emoji @(0x1F4BE)          # floppy disk
$script:TagDefs['net'].Emoji      = New-Emoji @(0x1F310)          # globe
$script:TagDefs['security'].Emoji = New-Emoji @(0x1F512)          # lock
$script:TagDefs['oneshot'].Emoji  = New-Emoji @(0x26A1)           # bolt

function Get-AutoTags {
    # Every tweak gets at least one tag automatically from its tab and traits, on top of
    # anything it explicitly lists in its own Tags field.
    param($T)
    $tags = @()
    if ($T.Tags) { $tags += @($T.Tags) }
    switch ($T.Category) {
        'oc'      { $tags += 'oc' }
        'gpu'     { $tags += @('perf', 'config') }
        'cpu'     { $tags += @('systune', 'perf') }
        'kbm'     { $tags += @('aim', 'config') }
        'aim'     { $tags += 'aim' }
        'vendor'  { $tags += 'config' }
        'debloat' { $tags += 'cleanup' }
        'net'     { $tags += 'net' }
        'laptop'  { $tags += 'laptop' }
        'apps'    { $tags += 'config' }
        'extra'   { $tags += 'systweak' }
        'windows' { $tags += 'systweak' }
        'storage' { $tags += 'disk' }
        'diskerror' { $tags += 'disk' }
        default   { $tags += 'systweak' }
    }
    $n = $T.Name + ' ' + $T.Group
    if ($n -match '(?i)latency|timer|responsiv') { $tags += 'latency' }
    if ($n -match '(?i)priority|boost|throttl|performance|fps|clock') { $tags += 'boost' }
    if ($n -match '(?i)mem|ram|cache|prefetch') { $tags += 'ram' }
    if ($n -match '(?i)cleanup|temp|recycle|remove|uninstall|debloat') { $tags += 'cleanup' }
    if ($n -match '(?i)nvidia') { $tags += 'nvidia' }
    if ($n -match '(?i)\bamd\b|radeon') { $tags += 'amd' }
    if ($T.Risk -eq 'High') { $tags += 'security' }
    if ($T.OneShot) { $tags += 'oneshot' }
    if ($T.IsLaptopSafe) { $tags += 'laptop' }
    $seen = @{}
    $out = @()
    foreach ($t in $tags) { if ($script:TagDefs.ContainsKey($t) -and -not $seen.ContainsKey($t)) { $seen[$t] = $true; $out += $t } }
    return $out
}

function New-TagRow {
    param($T)
    $tags = @(Get-AutoTags $T)
    if ($tags.Count -eq 0) { return $null }
    $row = New-Object System.Windows.Controls.StackPanel
    $row.Orientation = 'Horizontal'
    $row.Margin = [System.Windows.Thickness]::new(0, 8, 0, 0)
    foreach ($key in $tags) {
        $def = $script:TagDefs[$key]
        $chip = New-Object System.Windows.Controls.Border
        $chip.Width = 24; $chip.Height = 24
        $chip.CornerRadius = [System.Windows.CornerRadius]::new(7)
        $chip.Background = New-Brush '#1FFFFFFF'
        $chip.Margin = [System.Windows.Thickness]::new(0, 0, 6, 0)
        if ($def.UseIcon) {
            $ic = New-Icon $def.UseIcon 13 '#FFFFFF'
            $ic.HorizontalAlignment = 'Center'; $ic.VerticalAlignment = 'Center'
            $chip.Child = $ic
        } else {
            $t = New-Text $def.Emoji 13 700
            $t.HorizontalAlignment = 'Center'; $t.VerticalAlignment = 'Center'
            $chip.Child = $t
        }
        $tip = New-Object System.Windows.Controls.ToolTip
        $tip.Content = [string]$def.Tip
        [System.Windows.Controls.ToolTipService]::SetToolTip($chip, $tip)
        [System.Windows.Controls.ToolTipService]::SetInitialShowDelay($chip, 150)
        [void]$row.Children.Add($chip)
    }
    return $row
}

$script:OcSections = @(
    @{ Title = 'Before you touch anything'; Steps = @(
        @{ Name = 'Install monitoring and test tools'; Desc = 'Install HWiNFO64 to watch temperatures, clocks and voltages. Then pick one stress test per part: OCCT or Cinebench for the CPU, 3DMark or Unigine Superposition for the GPU, and TestMem5 or MemTest86 for RAM. Write down your stock temperatures and clocks first so you know what changed.' },
        @{ Name = 'Change one thing at a time'; Desc = 'Raise one setting by a small step, test for at least 15 to 30 minutes, note the result, and only then go further. If you change three things and it crashes, you will not know which one caused it.' },
        @{ Name = 'Know your safe limits'; Desc = 'While stress testing, keep CPU temperatures under about 85 C and GPU temperatures under about 80 C. Never raise voltage beyond what your CPU, RAM kit or motherboard maker documents. If you are unsure, leave voltage alone: most of the gain comes without it.' },
        @{ Name = 'Have a way back'; Desc = 'Learn how to clear the CMOS (a button or jumper on the motherboard, or the battery method in the manual) in case the PC will not boot. Create a restore point in Compact Tweaks first. Overclocking can void warranties and shorten the life of parts if you push voltage or heat too far.' }
    ) },
    @{ Title = 'GPU with MSI Afterburner'; Steps = @(
        @{ Name = 'Install MSI Afterburner'; Desc = 'Download it from msi.com. It works with NVIDIA and AMD cards. Install the RivaTuner component too if you want an on-screen overlay. Do not turn on Apply overclocking at system startup until the very end.' },
        @{ Name = 'Raise the power and temperature limits'; Desc = 'Drag Power Limit and Temp Limit to their maximum and click the tick. This gives the card room to boost and does not raise voltage by itself.' },
        @{ Name = 'Add core clock in small steps'; Desc = 'Increase Core Clock by 15 MHz, click the tick, and run a 10 minute loop of a GPU test such as Unigine Superposition. If there is no crash, flicker, sparkle or driver reset, add another 15 MHz. When something fails, go back 30 MHz and stop there.' },
        @{ Name = 'Then the memory clock'; Desc = 'Do the same with Memory Clock in steps of 100 MHz. Memory pushed too far can look stable while lowering your score through error correction, so compare your benchmark score after every step and keep the last step that improved it.' },
        @{ Name = 'Set a fan curve'; Desc = 'Use the Fan tab so the fans ramp up before about 70 C. That helps the card hold its boost clock. Louder is fine; hot is not.' },
        @{ Name = 'Save it and test in real games'; Desc = 'Save the settings to a profile slot and play your normal games for an hour or two. Only when it is stable, turn on Apply overclocking at system startup. On AMD cards you can use Adrenalin under Performance, Tuning instead of Afterburner.' }
    ) },
    @{ Title = 'CPU'; Steps = @(
        @{ Name = 'Update the BIOS and turn on XMP or EXPO first'; Desc = 'A current BIOS fixes boost and stability problems, and the memory profile (see the RAM section) is a bigger, safer gain than any CPU clock change.' },
        @{ Name = 'AMD Ryzen: use PBO with Curve Optimizer'; Desc = 'A fixed all-core overclock usually loses to the built-in boost on Ryzen. In the BIOS enable Precision Boost Overdrive, then set Curve Optimizer to All Cores, Negative, starting at 5. This lowers voltage at the same clocks, so the CPU boosts higher and runs cooler.' },
        @{ Name = 'Step it down slowly and test'; Desc = 'Test with OCCT or Cinebench loops, and also leave the PC idle or lightly loaded for a while, because Curve Optimizer instability often shows up at low load. If it is stable go to 10, then 15. When you see a crash or a WHEA error, go back 3 to 5 steps and stop.' },
        @{ Name = 'Intel K-series CPUs'; Desc = 'Raise the multiplier by 1 (100 MHz), keep core voltage on Auto or a small adaptive offset, and stress test. Stop when package temperature reaches about 90 C or the system becomes unstable, and do not push voltage beyond what Intel documents for your chip.' },
        @{ Name = 'Cooling matters more than settings'; Desc = 'A better cooler gains more headroom than any BIOS option. If temperatures climb toward the limit, step back one notch instead of adding voltage.' }
    ) },
    @{ Title = 'RAM'; Steps = @(
        @{ Name = 'Enable XMP or EXPO'; Desc = 'In the BIOS switch on the memory profile printed on your kit. Then check Task Manager, Performance, Memory: the Speed should match the kit rating. This alone is usually the largest RAM gain.' },
        @{ Name = 'Check that you run dual channel'; Desc = 'Make sure two sticks sit in the slots your motherboard manual recommends (usually slots 2 and 4). Single channel costs a lot of performance.' },
        @{ Name = 'AMD AM4: match memory and Infinity Fabric'; Desc = 'On Ryzen 5000 the sweet spot is DDR4-3600 with FCLK at 1800 MHz (1:1). Going above what FCLK can follow makes things slower, not faster.' },
        @{ Name = 'Tighten timings one at a time (advanced)'; Desc = 'Lower one primary timing (CL, tRCD, tRP or tRAS) by 1, then run TestMem5 or MemTest86 for several passes. Keep each change you can prove stable and undo the last change the moment you see errors.' },
        @{ Name = 'Respect voltage limits'; Desc = 'Stay at or below your kit rated voltage. For daily DDR4 that is normally 1.35 to 1.45 V, and SoC voltage on AM4 should stay at or below about 1.2 V. If the PC fails to boot, clear the CMOS and return to the XMP or EXPO profile.' }
    ) }
)

$script:BiosSections = @(
    @{ Title = 'Checklist'; Steps = @(
        @{ Name = 'Enable XMP or EXPO'; Desc = 'Makes your RAM run at its rated speed instead of a slow default. This is often the biggest free performance gain on a new build.' },
        @{ Name = 'Enable Resizable BAR (Smart Access Memory on AMD)'; Desc = 'Lets the CPU access all of your graphics memory at once. Needs a supporting CPU and GPU.' },
        @{ Name = 'Update your BIOS'; Desc = 'Newer versions fix stability and boost-behaviour problems. Only update from your motherboard maker, and do not interrupt it.' },
        @{ Name = 'Check that Precision Boost is enabled'; Desc = 'On Ryzen CPUs this lets the chip raise its clocks when there is thermal room. It is on by default unless something turned it off.' }
    ) }
)

$script:TabDefs = @(
    @{ Id = 'home';    Label = 'Home';                 Icon = 'home' },
    @{ Id = 'oc';      Label = 'OC';                   Sub = 'Overclocking'; Icon = 'oc'; Title = 'Overclocking'; Desc = 'Coming soon.'; ComingSoon = $true },
    @{ Id = 'gpu';     Label = 'GPU Optimizations';    Icon = 'gpu';     Title = 'GPU Optimizations';     Desc = 'Game capture, GPU scheduling, DirectX and fullscreen behaviour.' },
    @{ Id = 'cpu';     Label = 'CPU Optimizations';    Icon = 'cpu';     Title = 'CPU Optimizations';     Desc = 'Power, priority, background processes, kernel and security trade-offs.' },
    @{ Id = 'kbm';     Label = 'KBM Optimizations';    Icon = 'kbm';     Title = 'Keyboard and mouse';    Desc = 'Input behaviour, USB power saving and polling rate.' },
    @{ Id = 'aim';     Label = 'Aim Optimizations';    Icon = 'aim';     Title = 'Aim Optimizations';     Desc = 'Settings that make your aim steadier and more consistent.' },
    @{ Id = 'vendor';  Label = 'Nvidia & AMD';         Icon = 'vendor';  Title = 'Nvidia and AMD';        Desc = 'Driver and control panel settings that match the graphics card in your PC.' },
    @{ Id = 'windows'; Label = 'Windows Tweaks';       Icon = 'windows'; Title = 'Windows Tweaks';        Desc = 'Core Windows behaviour: startup, shutdown, visual effects and system settings.' },
    @{ Id = 'debloat'; Label = 'Debloating';           Icon = 'debloat'; Title = 'Debloating';            Desc = 'Turn off the extras Windows adds that you never asked for, and trim what runs at startup.' },
    @{ Id = 'net';     Label = 'Network Optimizations'; Icon = 'net';    Title = 'Network Optimizations'; Desc = 'Steadier connections for online games.' },
    @{ Id = 'storage'; Label = 'Storage Tweaks';        Icon = 'disk';   Title = 'Storage Tweaks';        Desc = 'Filesystem tuning and drive optimization for SSDs and hard drives.' },
    @{ Id = 'laptop';  Label = 'Laptop Optimizations'; Icon = 'laptop';  Title = 'Laptop Optimizations';  Desc = 'Balance speed, heat and battery life on a laptop.' },
    @{ Id = 'apps';    Label = 'App Optimizer';        Icon = 'apps';    Title = 'App Optimizer';         Desc = 'Detects your apps and lets you turn off hardware acceleration and clear their cache.' },
    @{ Id = 'extra';   Label = 'Extra Tweaks';         Icon = 'extra';   Title = 'Extra Tweaks';          Desc = 'Fortnite launch settings, Explorer tweaks and one-time cleanup.' },
    @{ Id = 'bios';    Label = 'BIOS Optimizations';   Icon = 'bios';    Title = 'BIOS Optimizations';    Desc = 'A checklist of settings worth checking in your BIOS.'; Sections = $script:BiosSections; Note = 'Windows cannot change BIOS settings, so this tab is a checklist. Click a step to mark it done. Exact menu names differ by motherboard.' },
    @{ Id = 'diskerror'; Label = 'Disc Error';         Icon = 'stackicon'; Title = 'Disc Error';          Desc = 'Built-in Windows repair commands for common file, disk and update problems.' },
    @{ Id = 'discord'; Label = 'Discord';              Icon = 'discord'; Title = 'Discord';               Desc = 'Join the community for updates, help and tweak requests.' }
)

# ----------------------------------------------------------------------------
# Window (XAML)
# ----------------------------------------------------------------------------
$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Compact Tweaks" Width="1200" Height="860" MinWidth="1000" MinHeight="660"
        WindowStartupLocation="CenterScreen" Background="#0B0304" Foreground="White"
        UseLayoutRounding="True" SnapsToDevicePixels="True">
  <Window.Resources>
    <SolidColorBrush x:Key="Glass" Color="#1AFFFFFF"/>
    <SolidColorBrush x:Key="Line" Color="#38FFFFFF"/>
    <SolidColorBrush x:Key="Muted" Color="#C7FFFFFF"/>
    <SolidColorBrush x:Key="Faint" Color="#8FFFFFFF"/>

    <Style x:Key="GhostButton" TargetType="Button">
      <Setter Property="Foreground" Value="White"/>
      <Setter Property="Background" Value="#1FFFFFFF"/>
      <Setter Property="BorderBrush" Value="#38FFFFFF"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="16,9"/>
      <Setter Property="FontWeight" Value="Bold"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bd" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="11" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="bd" Property="Background" Value="#38FFFFFF"/></Trigger>
              <Trigger Property="IsPressed" Value="True"><Setter TargetName="bd" Property="Opacity" Value="0.75"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter TargetName="bd" Property="Opacity" Value="0.4"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="PrimaryButton" TargetType="Button">
      <Setter Property="Foreground" Value="#A10D18"/>
      <Setter Property="Background" Value="White"/>
      <Setter Property="BorderBrush" Value="White"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="18,9"/>
      <Setter Property="FontWeight" Value="ExtraBold"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bd" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="11" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="bd" Property="Background" Value="#FFE9EA"/></Trigger>
              <Trigger Property="IsPressed" Value="True"><Setter TargetName="bd" Property="Opacity" Value="0.8"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter TargetName="bd" Property="Opacity" Value="0.45"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="NavButton" TargetType="Button">
      <Setter Property="Foreground" Value="#C7FFFFFF"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Height" Value="42"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FontSize" Value="14"/>
      <Setter Property="FontWeight" Value="Bold"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bd" Background="{TemplateBinding Background}" CornerRadius="12" Padding="16,0,10,0">
              <ContentPresenter VerticalAlignment="Center" HorizontalAlignment="Left"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="bd" Property="Background" Value="#14FFFFFF"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="Switch" TargetType="CheckBox">
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="CheckBox">
            <Grid Width="48" Height="28" Background="Transparent">
              <Border x:Name="Track" CornerRadius="14" Background="#38FFFFFF" BorderBrush="#66FFFFFF" BorderThickness="1"/>
              <Ellipse x:Name="Knob" Width="20" Height="20" HorizontalAlignment="Left" Margin="4,0,0,0" Fill="White">
                <Ellipse.RenderTransform>
                  <TranslateTransform x:Name="KnobT" X="0"/>
                </Ellipse.RenderTransform>
              </Ellipse>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsChecked" Value="True">
                <Trigger.EnterActions>
                  <BeginStoryboard>
                    <Storyboard>
                      <DoubleAnimation Storyboard.TargetName="KnobT" Storyboard.TargetProperty="X" To="20" Duration="0:0:0.30">
                        <DoubleAnimation.EasingFunction>
                          <BackEase EasingMode="EaseOut" Amplitude="0.6"/>
                        </DoubleAnimation.EasingFunction>
                      </DoubleAnimation>
                    </Storyboard>
                  </BeginStoryboard>
                </Trigger.EnterActions>
                <Trigger.ExitActions>
                  <BeginStoryboard>
                    <Storyboard>
                      <DoubleAnimation Storyboard.TargetName="KnobT" Storyboard.TargetProperty="X" To="0" Duration="0:0:0.22">
                        <DoubleAnimation.EasingFunction>
                          <CubicEase EasingMode="EaseOut"/>
                        </DoubleAnimation.EasingFunction>
                      </DoubleAnimation>
                    </Storyboard>
                  </BeginStoryboard>
                </Trigger.ExitActions>
                <Setter TargetName="Track" Property="Background" Value="White"/>
                <Setter TargetName="Knob" Property="Fill" Value="#A10D18"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="Field" TargetType="TextBox">
      <Setter Property="Foreground" Value="White"/>
      <Setter Property="CaretBrush" Value="White"/>
      <Setter Property="Background" Value="#66000000"/>
      <Setter Property="BorderBrush" Value="#55FFFFFF"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="10,7"/>
      <Setter Property="FontWeight" Value="Bold"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TextBox">
            <Border Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="10">
              <ScrollViewer x:Name="PART_ContentHost" Padding="{TemplateBinding Padding}" HorizontalScrollBarVisibility="{TemplateBinding HorizontalScrollBarVisibility}" VerticalScrollBarVisibility="{TemplateBinding VerticalScrollBarVisibility}"/>
            </Border>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style TargetType="ScrollBar">
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ScrollBar">
            <Grid Background="Transparent" Width="10">
              <Track x:Name="PART_Track" IsDirectionReversed="True">
                <Track.DecreaseRepeatButton>
                  <RepeatButton Command="ScrollBar.PageUpCommand">
                    <RepeatButton.Template>
                      <ControlTemplate TargetType="RepeatButton"><Border Background="Transparent"/></ControlTemplate>
                    </RepeatButton.Template>
                  </RepeatButton>
                </Track.DecreaseRepeatButton>
                <Track.IncreaseRepeatButton>
                  <RepeatButton Command="ScrollBar.PageDownCommand">
                    <RepeatButton.Template>
                      <ControlTemplate TargetType="RepeatButton"><Border Background="Transparent"/></ControlTemplate>
                    </RepeatButton.Template>
                  </RepeatButton>
                </Track.IncreaseRepeatButton>
                <Track.Thumb>
                  <Thumb>
                    <Thumb.Template>
                      <ControlTemplate TargetType="Thumb"><Border CornerRadius="4" Background="#66FFFFFF" Margin="2,0,2,0"/></ControlTemplate>
                    </Thumb.Template>
                  </Thumb>
                </Track.Thumb>
              </Track>
            </Grid>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>

  <Grid>
    <Grid.Background>
      <LinearGradientBrush StartPoint="0,0" EndPoint="1,1">
        <GradientStop Color="#7E0C16" Offset="0"/>
        <GradientStop Color="#4C0810" Offset="0.36"/>
        <GradientStop Color="#22050A" Offset="0.68"/>
        <GradientStop Color="#0B0304" Offset="1"/>
      </LinearGradientBrush>
    </Grid.Background>

    <Grid IsHitTestVisible="False" ClipToBounds="True">
      <Ellipse x:Name="GlowA" Width="640" Height="640" HorizontalAlignment="Left" VerticalAlignment="Top" Margin="120,-220,0,0">
        <Ellipse.Fill>
          <RadialGradientBrush>
            <GradientStop Color="#40FF5A5A" Offset="0"/>
            <GradientStop Color="#00FF5A5A" Offset="1"/>
          </RadialGradientBrush>
        </Ellipse.Fill>
        <Ellipse.RenderTransform><TranslateTransform/></Ellipse.RenderTransform>
      </Ellipse>
      <Ellipse x:Name="GlowB" Width="560" Height="560" HorizontalAlignment="Right" VerticalAlignment="Bottom" Margin="0,0,-120,-200">
        <Ellipse.Fill>
          <RadialGradientBrush>
            <GradientStop Color="#2EFF2A3A" Offset="0"/>
            <GradientStop Color="#00FF2A3A" Offset="1"/>
          </RadialGradientBrush>
        </Ellipse.Fill>
        <Ellipse.RenderTransform><TranslateTransform/></Ellipse.RenderTransform>
      </Ellipse>
    </Grid>

    <Grid>
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="268"/>
        <ColumnDefinition Width="*"/>
      </Grid.ColumnDefinitions>

      <!-- Sidebar -->
      <Border Grid.Column="0" Background="Transparent" BorderBrush="#26FFFFFF" BorderThickness="0,0,1,0" ClipToBounds="True">
        <Grid Background="Transparent">
          <!-- The image is the entire sidebar background. Nothing opaque is drawn over it. -->
          <Image x:Name="SidebarBackground"
                 Stretch="UniformToFill"
                 HorizontalAlignment="Right"
                 VerticalAlignment="Center"
                 Opacity="1"
                 Panel.ZIndex="0"
                 IsHitTestVisible="False"/>

          <!-- Extremely subtle overlay only for readability; still transparent enough to show the image. -->
          <Border Background="#12000000" Panel.ZIndex="1" IsHitTestVisible="False"/>

          <!-- Navigation is on top of the image, filling the full left side. -->
          <Grid Panel.ZIndex="2" Background="Transparent">
            <Grid.RowDefinitions>
              <RowDefinition Height="*"/>
              <RowDefinition Height="Auto"/>
            </Grid.RowDefinitions>

            <ScrollViewer Grid.Row="0" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled"
                          Margin="12,18,6,8" Background="Transparent">
              <Grid Margin="0,0,6,0" Background="Transparent">
                <Border x:Name="NavPill" Height="42" VerticalAlignment="Top" CornerRadius="12"
                        Background="#3DFFFFFF" BorderBrush="#66FFFFFF" BorderThickness="1">
                  <Border.RenderTransform><TranslateTransform/></Border.RenderTransform>
                  <Border Width="3" Height="18" HorizontalAlignment="Left" Margin="7,0,0,0"
                          CornerRadius="2" Background="White"/>
                </Border>
                <StackPanel x:Name="NavList" Background="Transparent"/>
              </Grid>
            </ScrollViewer>

            <StackPanel Grid.Row="1" Margin="20,8,20,18">
              <StackPanel Orientation="Horizontal">
                <Ellipse Width="8" Height="8" Fill="White" VerticalAlignment="Center"/>
                <TextBlock Text="Running as administrator" Margin="10,0,0,0" FontSize="12.5"
                           FontWeight="SemiBold" Foreground="{StaticResource Muted}"/>
              </StackPanel>
              <TextBlock x:Name="SideNote" Text="" Margin="18,6,0,0" FontSize="12"
                         FontWeight="SemiBold" Foreground="{StaticResource Faint}" TextWrapping="Wrap"/>
            </StackPanel>
          </Grid>
        </Grid>
      </Border>

      <!-- Main area -->
      <Grid Grid.Column="1">
        <Grid.Background>
          <LinearGradientBrush StartPoint="0,0" EndPoint="0.65,1">
            <GradientStop Color="#860B18" Offset="0"/>
            <GradientStop Color="#610A14" Offset="0.48"/>
            <GradientStop Color="#31070C" Offset="1"/>
          </LinearGradientBrush>
        </Grid.Background>
        <Grid.RowDefinitions>
          <RowDefinition Height="*"/>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <Grid x:Name="PageHost" Grid.Row="0">
          <ScrollViewer x:Name="HomePage" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
            <StackPanel Margin="34,28,34,34">
              <StackPanel Orientation="Horizontal">
                <Border x:Name="HeroMark" Width="78" Height="78" CornerRadius="24" Background="White" RenderTransformOrigin="0.5,0.5">
                  <Border.RenderTransform><ScaleTransform ScaleX="1" ScaleY="1"/></Border.RenderTransform>
                  <Viewbox Width="38" Height="38">
                    <Canvas Width="24" Height="24"><Path Data="M13,2 L4,14 H10 L9,22 L18,10 H12 Z" Fill="#A10D18"/></Canvas>
                  </Viewbox>
                </Border>
                <StackPanel Margin="22,0,0,0" VerticalAlignment="Center">
                  <StackPanel x:Name="TitleLetters" Orientation="Horizontal"/>
                  <TextBlock x:Name="Slogan" Text="Stay Compact, Stay Fast." FontSize="22" FontWeight="Bold" Margin="0,6,0,0">
                    <TextBlock.RenderTransform><TranslateTransform/></TextBlock.RenderTransform>
                  </TextBlock>
                </StackPanel>
              </StackPanel>
              <TextBlock x:Name="SysLine" Margin="0,16,0,0" Foreground="{StaticResource Muted}" FontSize="13" FontWeight="SemiBold" TextWrapping="Wrap"/>
              <StackPanel Orientation="Horizontal" Margin="0,18,0,0">
                <Button x:Name="BtnHomeRestore" Style="{StaticResource PrimaryButton}" Content="Create restore point" Margin="0,0,10,0"/>
                <Button x:Name="BtnHomeApplyAll" Style="{StaticResource GhostButton}" Content="Apply All" Margin="0,0,10,0"/>
                <Button x:Name="BtnHomeBrowse" Style="{StaticResource GhostButton}" Content="Browse tweaks"/>
              </StackPanel>
              <Border Margin="0,16,0,0" Padding="16,12,16,12" CornerRadius="14" Background="#33000000" BorderBrush="#55FFFFFF" BorderThickness="1" HorizontalAlignment="Left" MaxWidth="720">
                <TextBlock TextWrapping="Wrap" FontSize="12.5" FontWeight="SemiBold" Foreground="#D9FFFFFF" Text="Make a restore point before changing anything, even if a tweak looks small. Results may vary based on your own hardware, drivers and Windows version, so watch the status column and undo anything that does not help."/>
              </Border>

              <Grid Margin="0,24,0,0">
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="*"/>
                  <ColumnDefinition Width="*"/>
                  <ColumnDefinition Width="*"/>
                </Grid.ColumnDefinitions>
                <Grid.RowDefinitions>
                  <RowDefinition Height="Auto"/>
                  <RowDefinition Height="Auto"/>
                </Grid.RowDefinitions>

                <!-- CPU -->
                <Border x:Name="TileCpu" Grid.Row="0" Grid.Column="0" Grid.ColumnSpan="2" Margin="0,0,8,16" Padding="20" CornerRadius="22" Background="{StaticResource Glass}" BorderBrush="{StaticResource Line}" BorderThickness="1">
                  <StackPanel>
                    <StackPanel Orientation="Horizontal">
                      <Border x:Name="IconCpu" Width="34" Height="34" CornerRadius="10" Background="#29FFFFFF"/>
                      <StackPanel Margin="10,0,0,0" VerticalAlignment="Center">
                        <TextBlock Text="CPU" FontSize="15" FontWeight="ExtraBold"/>
                        <TextBlock x:Name="CpuName" Text="" FontSize="12" FontWeight="SemiBold" Foreground="{StaticResource Faint}"/>
                      </StackPanel>
                    </StackPanel>
                    <Grid Margin="0,14,0,0">
                      <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="Auto"/>
                        <ColumnDefinition Width="*"/>
                      </Grid.ColumnDefinitions>
                      <StackPanel Orientation="Horizontal" VerticalAlignment="Bottom">
                        <TextBlock x:Name="CpuVal" Text="0" FontSize="46" FontWeight="Black"/>
                        <TextBlock Text="%" FontSize="18" FontWeight="ExtraBold" Foreground="{StaticResource Muted}" VerticalAlignment="Bottom" Margin="2,0,0,6"/>
                      </StackPanel>
                      <UniformGrid Grid.Column="1" Columns="4" HorizontalAlignment="Right" VerticalAlignment="Bottom" Margin="24,0,0,0">
                        <StackPanel Margin="0,0,22,0"><TextBlock Text="Speed" FontSize="12" FontWeight="SemiBold" Foreground="{StaticResource Faint}"/><TextBlock x:Name="CpuSpeed" Text="-" FontSize="15" FontWeight="Bold"/></StackPanel>
                        <StackPanel Margin="0,0,22,0"><TextBlock Text="Processes" FontSize="12" FontWeight="SemiBold" Foreground="{StaticResource Faint}"/><TextBlock x:Name="CpuProc" Text="-" FontSize="15" FontWeight="Bold"/></StackPanel>
                        <StackPanel Margin="0,0,22,0"><TextBlock Text="Logical CPUs" FontSize="12" FontWeight="SemiBold" Foreground="{StaticResource Faint}"/><TextBlock x:Name="CpuLogical" Text="-" FontSize="15" FontWeight="Bold"/></StackPanel>
                        <StackPanel><TextBlock Text="Up time" FontSize="12" FontWeight="SemiBold" Foreground="{StaticResource Faint}"/><TextBlock x:Name="CpuUp" Text="-" FontSize="15" FontWeight="Bold"/></StackPanel>
                      </UniformGrid>
                    </Grid>
                    <Border Height="86" Margin="0,12,0,0" ClipToBounds="True"><Canvas x:Name="CpuSpark" ClipToBounds="True"/></Border>
                    <UniformGrid x:Name="ThreadBars" Height="46" Margin="0,14,0,0"/>
                    <TextBlock Text="Each bar is one logical CPU" FontSize="12" FontWeight="SemiBold" Foreground="{StaticResource Faint}" Margin="0,6,0,0"/>
                  </StackPanel>
                </Border>

                <!-- Memory -->
                <Border x:Name="TileMem" Grid.Row="0" Grid.Column="2" Margin="8,0,0,16" Padding="20" CornerRadius="22" Background="{StaticResource Glass}" BorderBrush="{StaticResource Line}" BorderThickness="1">
                  <StackPanel>
                    <StackPanel Orientation="Horizontal">
                      <Border x:Name="IconMem" Width="34" Height="34" CornerRadius="10" Background="#29FFFFFF"/>
                      <StackPanel Margin="10,0,0,0" VerticalAlignment="Center">
                        <TextBlock Text="Memory" FontSize="15" FontWeight="ExtraBold"/>
                        <TextBlock x:Name="MemTotal" Text="" FontSize="12" FontWeight="SemiBold" Foreground="{StaticResource Faint}"/>
                      </StackPanel>
                    </StackPanel>
                    <StackPanel Orientation="Horizontal" Margin="0,14,0,0">
                      <TextBlock x:Name="MemVal" Text="0" FontSize="46" FontWeight="Black"/>
                      <TextBlock Text="GB" FontSize="18" FontWeight="ExtraBold" Foreground="{StaticResource Muted}" VerticalAlignment="Bottom" Margin="4,0,0,6"/>
                    </StackPanel>
                    <TextBlock x:Name="MemSub" Text="" FontSize="12.5" FontWeight="SemiBold" Foreground="{StaticResource Muted}" Margin="0,4,0,0"/>
                    <Border Height="16" CornerRadius="8" Background="#29FFFFFF" Margin="0,16,0,0" ClipToBounds="True">
                      <Grid x:Name="MemBar">
                        <Grid.ColumnDefinitions>
                          <ColumnDefinition Width="0*"/>
                          <ColumnDefinition Width="1*"/>
                        </Grid.ColumnDefinitions>
                        <Border Background="White" CornerRadius="8"/>
                      </Grid>
                    </Border>
                    <Grid Margin="0,12,0,0">
                      <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                      <StackPanel><TextBlock Text="In use" FontSize="12" FontWeight="SemiBold" Foreground="{StaticResource Faint}"/><TextBlock x:Name="MemUsedText" Text="-" FontSize="15" FontWeight="Bold"/></StackPanel>
                      <StackPanel Grid.Column="1"><TextBlock Text="Available" FontSize="12" FontWeight="SemiBold" Foreground="{StaticResource Faint}"/><TextBlock x:Name="MemFreeText" Text="-" FontSize="15" FontWeight="Bold"/></StackPanel>
                    </Grid>
                  </StackPanel>
                </Border>

                <!-- GPU -->
                <Border x:Name="TileGpu" Grid.Row="1" Grid.Column="0" Margin="0,0,8,0" Padding="20" CornerRadius="22" Background="{StaticResource Glass}" BorderBrush="{StaticResource Line}" BorderThickness="1">
                  <StackPanel>
                    <StackPanel Orientation="Horizontal">
                      <Border x:Name="IconGpu" Width="34" Height="34" CornerRadius="10" Background="#29FFFFFF"/>
                      <StackPanel Margin="10,0,0,0" VerticalAlignment="Center">
                        <TextBlock Text="GPU" FontSize="15" FontWeight="ExtraBold"/>
                        <TextBlock x:Name="GpuName" Text="" FontSize="12" FontWeight="SemiBold" Foreground="{StaticResource Faint}" MaxWidth="190" TextTrimming="CharacterEllipsis"/>
                      </StackPanel>
                    </StackPanel>
                    <Grid Margin="0,14,0,0">
                      <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                      <Grid Width="118" Height="118">
                        <Ellipse Width="108" Height="108" Stroke="#29FFFFFF" StrokeThickness="10"/>
                        <Ellipse x:Name="GpuRing" Width="108" Height="108" Stroke="White" StrokeThickness="10" StrokeDashCap="Round" RenderTransformOrigin="0.5,0.5">
                          <Ellipse.RenderTransform><RotateTransform Angle="-90"/></Ellipse.RenderTransform>
                        </Ellipse>
                        <TextBlock x:Name="GpuVal" Text="0%" FontSize="26" FontWeight="Black" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                      </Grid>
                      <StackPanel Grid.Column="1" VerticalAlignment="Center" Margin="16,0,0,0">
                        <TextBlock Text="Video memory" FontSize="12" FontWeight="SemiBold" Foreground="{StaticResource Faint}"/>
                        <TextBlock x:Name="GpuVram" Text="-" FontSize="15" FontWeight="Bold" Margin="0,0,0,10"/>
                        <TextBlock Text="Busiest engine" FontSize="12" FontWeight="SemiBold" Foreground="{StaticResource Faint}"/>
                        <TextBlock x:Name="GpuEngine" Text="-" FontSize="15" FontWeight="Bold"/>
                      </StackPanel>
                    </Grid>
                  </StackPanel>
                </Border>

                <!-- Disk -->
                <Border x:Name="TileDisk" Grid.Row="1" Grid.Column="1" Margin="8,0,8,0" Padding="20" CornerRadius="22" Background="{StaticResource Glass}" BorderBrush="{StaticResource Line}" BorderThickness="1">
                  <StackPanel>
                    <StackPanel Orientation="Horizontal">
                      <Border x:Name="IconDisk" Width="34" Height="34" CornerRadius="10" Background="#29FFFFFF"/>
                      <StackPanel Margin="10,0,0,0" VerticalAlignment="Center">
                        <TextBlock Text="Disk" FontSize="15" FontWeight="ExtraBold"/>
                        <TextBlock Text="All drives, active time" FontSize="12" FontWeight="SemiBold" Foreground="{StaticResource Faint}"/>
                      </StackPanel>
                    </StackPanel>
                    <StackPanel Orientation="Horizontal" Margin="0,14,0,0">
                      <TextBlock x:Name="DiskVal" Text="0" FontSize="46" FontWeight="Black"/>
                      <TextBlock Text="%" FontSize="18" FontWeight="ExtraBold" Foreground="{StaticResource Muted}" VerticalAlignment="Bottom" Margin="2,0,0,6"/>
                    </StackPanel>
                    <Border Height="60" Margin="0,8,0,0" ClipToBounds="True"><Canvas x:Name="DiskSpark" ClipToBounds="True"/></Border>
                    <Grid Margin="0,12,0,0">
                      <Grid.ColumnDefinitions><ColumnDefinition Width="52"/><ColumnDefinition Width="*"/><ColumnDefinition Width="82"/></Grid.ColumnDefinitions>
                      <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
                      <TextBlock Grid.Row="0" Grid.Column="0" Text="Read" FontSize="12.5" FontWeight="SemiBold" Foreground="{StaticResource Muted}" VerticalAlignment="Center"/>
                      <Border Grid.Row="0" Grid.Column="1" Height="8" CornerRadius="4" Background="#29FFFFFF" ClipToBounds="True" VerticalAlignment="Center">
                        <Grid x:Name="DiskReadBar"><Grid.ColumnDefinitions><ColumnDefinition Width="0*"/><ColumnDefinition Width="1*"/></Grid.ColumnDefinitions><Border Background="White" CornerRadius="4"/></Grid>
                      </Border>
                      <TextBlock Grid.Row="0" Grid.Column="2" x:Name="DiskRead" Text="-" FontSize="12.5" FontWeight="Bold" TextAlignment="Right" VerticalAlignment="Center"/>
                      <TextBlock Grid.Row="1" Grid.Column="0" Text="Write" FontSize="12.5" FontWeight="SemiBold" Foreground="{StaticResource Muted}" VerticalAlignment="Center" Margin="0,8,0,0"/>
                      <Border Grid.Row="1" Grid.Column="1" Height="8" CornerRadius="4" Background="#29FFFFFF" ClipToBounds="True" VerticalAlignment="Center" Margin="0,8,0,0">
                        <Grid x:Name="DiskWriteBar"><Grid.ColumnDefinitions><ColumnDefinition Width="0*"/><ColumnDefinition Width="1*"/></Grid.ColumnDefinitions><Border Background="White" CornerRadius="4"/></Grid>
                      </Border>
                      <TextBlock Grid.Row="1" Grid.Column="2" x:Name="DiskWrite" Text="-" FontSize="12.5" FontWeight="Bold" TextAlignment="Right" VerticalAlignment="Center" Margin="0,8,0,0"/>
                    </Grid>
                  </StackPanel>
                </Border>

                <!-- Network -->
                <Border x:Name="TileNet" Grid.Row="1" Grid.Column="2" Margin="8,0,0,0" Padding="20" CornerRadius="22" Background="{StaticResource Glass}" BorderBrush="{StaticResource Line}" BorderThickness="1">
                  <StackPanel>
                    <StackPanel Orientation="Horizontal">
                      <Border x:Name="IconNet" Width="34" Height="34" CornerRadius="10" Background="#29FFFFFF"/>
                      <StackPanel Margin="10,0,0,0" VerticalAlignment="Center">
                        <TextBlock Text="Network" FontSize="15" FontWeight="ExtraBold"/>
                        <TextBlock x:Name="NetName" Text="" FontSize="12" FontWeight="SemiBold" Foreground="{StaticResource Faint}"/>
                      </StackPanel>
                    </StackPanel>
                    <Grid Margin="0,14,0,0">
                      <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                      <StackPanel><TextBlock Text="Download" FontSize="12" FontWeight="SemiBold" Foreground="{StaticResource Faint}"/><StackPanel Orientation="Horizontal"><TextBlock x:Name="NetDown" Text="0" FontSize="32" FontWeight="Black"/><TextBlock Text="Mbps" FontSize="13" FontWeight="ExtraBold" Foreground="{StaticResource Muted}" VerticalAlignment="Bottom" Margin="4,0,0,5"/></StackPanel></StackPanel>
                      <StackPanel Grid.Column="1"><TextBlock Text="Upload" FontSize="12" FontWeight="SemiBold" Foreground="{StaticResource Faint}"/><StackPanel Orientation="Horizontal"><TextBlock x:Name="NetUp" Text="0" FontSize="32" FontWeight="Black"/><TextBlock Text="Mbps" FontSize="13" FontWeight="ExtraBold" Foreground="{StaticResource Muted}" VerticalAlignment="Bottom" Margin="4,0,0,5"/></StackPanel></StackPanel>
                    </Grid>
                    <Border Height="86" Margin="0,12,0,0" ClipToBounds="True"><Canvas x:Name="NetSpark" ClipToBounds="True"/></Border>
                  </StackPanel>
                </Border>
              </Grid>

              <StackPanel Orientation="Horizontal" Margin="0,20,0,0">
                <Border CornerRadius="10" Background="{StaticResource Glass}" BorderBrush="{StaticResource Line}" BorderThickness="1" Padding="14,8">
                  <TextBlock x:Name="ChipApplied" Text="0 tweaks applied" FontSize="13" FontWeight="Bold"/>
                </Border>
              </StackPanel>
              <TextBlock x:Name="MonitorNote" Text="" Margin="0,12,0,0" FontSize="12.5" FontWeight="SemiBold" Foreground="{StaticResource Faint}" TextWrapping="Wrap"/>
            </StackPanel>
          </ScrollViewer>
        </Grid>

        <Border x:Name="Toast" Grid.Row="0" HorizontalAlignment="Center" VerticalAlignment="Bottom" Margin="0,0,0,26" Background="White" CornerRadius="14" Padding="20,12" Opacity="0" IsHitTestVisible="False" MaxWidth="700">
          <TextBlock x:Name="ToastText" Foreground="#A10D18" FontWeight="ExtraBold" FontSize="14" TextWrapping="Wrap" TextAlignment="Center"/>
        </Border>

        <Border x:Name="LogPanel" Grid.Row="1" Visibility="Collapsed" Height="150" Background="#D9000000" BorderBrush="#33FFFFFF" BorderThickness="0,1,0,0">
          <TextBox x:Name="LogBox" IsReadOnly="True" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled" TextWrapping="Wrap"
                   Background="Transparent" Foreground="#D0FFFFFF" FontFamily="Consolas" FontSize="12" BorderThickness="0" Padding="34,10,34,10"/>
        </Border>

        <Border x:Name="Bar" Grid.Row="2" Background="#CC000000" BorderBrush="#33FFFFFF" BorderThickness="0,1,0,0" Padding="34,14,34,14" Visibility="Collapsed">
          <Grid>
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="*"/>
              <ColumnDefinition Width="Auto"/>
              <ColumnDefinition Width="Auto"/>
              <ColumnDefinition Width="Auto"/>
              <ColumnDefinition Width="Auto"/>
              <ColumnDefinition Width="Auto"/>
              <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            <TextBlock x:Name="CountText" Grid.Column="0" Text="0 selected" FontWeight="Bold" FontSize="14" VerticalAlignment="Center"/>
            <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center" Margin="0,0,18,0">
              <CheckBox x:Name="ChkRestore" Style="{StaticResource Switch}" IsChecked="True"/>
              <TextBlock Text="Create a restore point first" Margin="10,0,0,0" Foreground="{StaticResource Muted}" FontWeight="SemiBold" VerticalAlignment="Center"/>
            </StackPanel>
            <Button x:Name="BtnLog" Grid.Column="2" Style="{StaticResource GhostButton}" Content="Log" Margin="0,0,8,0"/>
            <Button x:Name="BtnRec" Grid.Column="3" Style="{StaticResource GhostButton}" Content="Select recommended" Margin="0,0,8,0"/>
            <Button x:Name="BtnClear" Grid.Column="4" Style="{StaticResource GhostButton}" Content="Clear" Margin="0,0,8,0"/>
            <Button x:Name="BtnUndo" Grid.Column="5" Style="{StaticResource GhostButton}" Content="Undo selected" Margin="0,0,8,0"/>
            <Button x:Name="BtnApply" Grid.Column="6" Style="{StaticResource PrimaryButton}" Content="Apply selected"/>
          </Grid>
        </Border>
      </Grid>
    </Grid>

    <Border x:Name="Splash" Background="#0B0304" Panel.ZIndex="999">
      <Border.Effect>
        <DropShadowEffect BlurRadius="0" Opacity="0"/>
      </Border.Effect>
      <StackPanel HorizontalAlignment="Center" VerticalAlignment="Center">
        <Border x:Name="SplashMark" Width="78" Height="78" CornerRadius="24" Background="White" HorizontalAlignment="Center" RenderTransformOrigin="0.5,0.5">
          <Border.RenderTransform><ScaleTransform ScaleX="1" ScaleY="1"/></Border.RenderTransform>
          <Viewbox Width="38" Height="38">
            <Canvas Width="24" Height="24"><Path Data="M13,2 L4,14 H10 L9,22 L18,10 H12 Z" Fill="#A10D18"/></Canvas>
          </Viewbox>
        </Border>
        <TextBlock Text="Compact Tweaks" FontSize="24" FontWeight="ExtraBold" Foreground="White" HorizontalAlignment="Center" Margin="0,18,0,0"/>
        <Grid Width="34" Height="34" Margin="0,20,0,0" HorizontalAlignment="Center">
          <Ellipse Width="34" Height="34" Stroke="#33FFFFFF" StrokeThickness="3"/>
          <Ellipse x:Name="SplashRing" Width="34" Height="34" Stroke="White" StrokeThickness="3" StrokeStartLineCap="Round" StrokeDashArray="22 100" RenderTransformOrigin="0.5,0.5">
            <Ellipse.RenderTransform><RotateTransform Angle="0"/></Ellipse.RenderTransform>
          </Ellipse>
        </Grid>
        <TextBlock x:Name="SplashText" Text="Loading..." FontSize="13" FontWeight="SemiBold" Foreground="#B3FFFFFF" HorizontalAlignment="Center" Margin="0,12,0,0"/>
      </StackPanel>
    </Border>
  </Grid>
</Window>
'@

# Embedded sidebar background image (user-selected dark red blurred reference). It is placed behind the navigation and loaded before the window is shown.
$script:SidebarBackgroundBase64 = @'
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
'@

$script:Window = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader ([xml]$xaml)))
$uiNames = @(
    'NavPill', 'NavList', 'SidebarBackground', 'SideNote', 'PageHost', 'HomePage', 'HeroMark', 'TitleLetters', 'Slogan', 'SysLine',
    'BtnHomeRestore', 'BtnHomeApplyAll', 'BtnHomeBrowse', 'TileCpu', 'IconCpu', 'CpuName', 'CpuVal', 'CpuSpeed', 'CpuProc', 'CpuLogical', 'CpuUp',
    'CpuSpark', 'ThreadBars', 'TileMem', 'IconMem', 'MemTotal', 'MemVal', 'MemSub', 'MemBar', 'MemUsedText', 'MemFreeText',
    'TileGpu', 'IconGpu', 'GpuName', 'GpuRing', 'GpuVal', 'GpuVram', 'GpuEngine', 'TileDisk', 'IconDisk', 'DiskVal', 'DiskSpark',
    'DiskReadBar', 'DiskRead', 'DiskWriteBar', 'DiskWrite', 'TileNet', 'IconNet', 'NetName', 'NetDown', 'NetUp', 'NetSpark',
    'ChipApplied', 'MonitorNote', 'Toast', 'ToastText', 'LogPanel', 'LogBox', 'Bar', 'CountText', 'ChkRestore',
    'BtnLog', 'BtnRec', 'BtnClear', 'BtnUndo', 'BtnApply', 'GlowA', 'GlowB', 'Splash', 'SplashMark', 'SplashRing', 'SplashText'
)
foreach ($n in $uiNames) { $script:Ui[$n] = $script:Window.FindName($n) }

# Load the embedded sidebar image before showing the window.
try {
    $bytes = [Convert]::FromBase64String(($script:SidebarBackgroundBase64 -replace '\s',''))
    $ms = New-Object System.IO.MemoryStream(,$bytes)
    try {
        $bmp = New-Object System.Windows.Media.Imaging.BitmapImage
        $bmp.BeginInit()
        $bmp.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
        $bmp.StreamSource = $ms
        $bmp.EndInit()
        $bmp.Freeze()
        $script:Ui.SidebarBackground.Source = $bmp
    } finally {
        $ms.Dispose()
    }
} catch {
    Write-Log ('Sidebar background image failed to load: ' + $_.Exception.Message) 'Warn'
}

# Font: SF Pro or Inter if installed, otherwise Segoe UI Variable / Segoe UI.
$fontPick = 'Segoe UI'
try {
    $installed = @([System.Windows.Media.Fonts]::SystemFontFamilies | ForEach-Object { $_.Source })
    foreach ($cand in @('SF Pro Display', 'Inter', 'Segoe UI Variable Display', 'Segoe UI')) {
        if ($installed -contains $cand) { $fontPick = $cand; break }
    }
} catch { }
$script:Window.FontFamily = New-Object System.Windows.Media.FontFamily($fontPick)
$script:FontPick = $fontPick

# ----------------------------------------------------------------------------
# UI helpers
# ----------------------------------------------------------------------------
$script:Conv = New-Object System.Windows.Media.BrushConverter
$script:BrushCache = @{}
function New-Brush {
    param([string]$Hex)
    if (-not $script:BrushCache.ContainsKey($Hex)) { $script:BrushCache[$Hex] = $script:Conv.ConvertFromString($Hex) }
    return $script:BrushCache[$Hex]
}

function New-Text {
    param([string]$Text, [double]$Size = 13, [int]$Weight = 700, [string]$Color = '#FFFFFF', [bool]$Wrap = $false)
    $t = New-Object System.Windows.Controls.TextBlock
    $t.Text = $Text
    $t.FontSize = $Size
    $t.FontWeight = [System.Windows.FontWeight]::FromOpenTypeWeight($Weight)
    $t.Foreground = New-Brush $Color
    if ($Wrap) { $t.TextWrapping = [System.Windows.TextWrapping]::Wrap }
    return $t
}

function New-Icon {
    param([string]$Name, [double]$Size = 20, [string]$Color = '#FFFFFF')
    $vb = New-Object System.Windows.Controls.Viewbox
    $vb.Width = $Size; $vb.Height = $Size
    $cv = New-Object System.Windows.Controls.Canvas
    $cv.Width = 24; $cv.Height = 24
    $p = New-Object System.Windows.Shapes.Path
    $p.Data = $script:Icons[$Name]
    $p.Stroke = New-Brush $Color
    $p.StrokeThickness = 1.3
    $p.StrokeLineJoin = [System.Windows.Media.PenLineJoin]::Round
    $p.StrokeStartLineCap = [System.Windows.Media.PenLineCap]::Round
    $p.StrokeEndLineCap = [System.Windows.Media.PenLineCap]::Round
    [void]$cv.Children.Add($p)
    $vb.Child = $cv
    return $vb
}

function New-Anim {
    param([double]$To, [int]$Ms = 300, [string]$Ease = 'Cubic', [Nullable[double]]$From = $null, [int]$DelayMs = 0)
    $a = New-Object System.Windows.Media.Animation.DoubleAnimation
    if ($null -ne $From) { $a.From = $From }
    $a.To = $To
    $a.Duration = [TimeSpan]::FromMilliseconds($Ms)
    if ($DelayMs -gt 0) { $a.BeginTime = [TimeSpan]::FromMilliseconds($DelayMs) }
    switch ($Ease) {
        'Back'  { $e = New-Object System.Windows.Media.Animation.BackEase; $e.EasingMode = 'EaseOut'; $e.Amplitude = 0.45; $a.EasingFunction = $e }
        'Cubic' { $e = New-Object System.Windows.Media.Animation.CubicEase; $e.EasingMode = 'EaseOut'; $a.EasingFunction = $e }
        default { }
    }
    return $a
}

$script:ToastTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:ToastTimer.Interval = [TimeSpan]::FromMilliseconds(3000)
$script:ToastTimer.Add_Tick({
    $script:ToastTimer.Stop()
    $script:Ui.Toast.BeginAnimation([System.Windows.UIElement]::OpacityProperty, (New-Anim -To 0 -Ms 350))
})
function Show-Toast {
    param([string]$Message)
    $script:Ui.ToastText.Text = $Message
    $script:Ui.Toast.BeginAnimation([System.Windows.UIElement]::OpacityProperty, (New-Anim -To 1 -Ms 220))
    $script:ToastTimer.Stop()
    $script:ToastTimer.Start()
}

function Get-IsLaptop {
    try { return [bool](Get-CimInstance Win32_Battery -ErrorAction Stop) } catch { return $false }
}

function Get-SystemSummary {
    try {
        $os  = ((Get-CimInstance Win32_OperatingSystem).Caption) -replace 'Microsoft ', ''
        $cpu = ((Get-CimInstance Win32_Processor | Select-Object -First 1).Name).Trim()
        $ram = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB)
        $gpu = 'No graphics card found'
        $g = Get-PrimaryGpu
        if ($g) { $gpu = [string]$g.Name }
        if (Get-IsLaptop) { $kind = 'Laptop' } else { $kind = 'Desktop' }
        return ('{0}     {1}     {2}     {3} GB RAM     {4}' -f $os, $cpu, $gpu, $ram, $kind)
    } catch { return 'Windows' }
}

# ----------------------------------------------------------------------------
# Tweak rows and pages
# ----------------------------------------------------------------------------
$script:TabHasRows = @{}

function Update-Count {
    $n = 0
    foreach ($t in $script:Tweaks) {
        $r = $script:Rows[$t.Id]
        if ($r -and $r.Check.IsChecked -eq $true) { $n++ }
    }
    $script:Ui.CountText.Text = ('{0} selected' -f $n)
}

function New-PageShell {
    $sv = New-Object System.Windows.Controls.ScrollViewer
    $sv.VerticalScrollBarVisibility = [System.Windows.Controls.ScrollBarVisibility]::Auto
    $sv.HorizontalScrollBarVisibility = [System.Windows.Controls.ScrollBarVisibility]::Disabled
    $sv.Visibility = [System.Windows.Visibility]::Collapsed
    $sv.RenderTransform = New-Object System.Windows.Media.TranslateTransform
    $sp = New-Object System.Windows.Controls.StackPanel
    $sp.Margin = [System.Windows.Thickness]::new(34, 28, 34, 34)
    $sv.Content = $sp
    return @{ Scroll = $sv; Stack = $sp }
}

function New-PageHeader {
    param($Tab)
    $g = New-Object System.Windows.Controls.Grid
    $c1 = New-Object System.Windows.Controls.ColumnDefinition; $c1.Width = [System.Windows.GridLength]::Auto
    $c2 = New-Object System.Windows.Controls.ColumnDefinition; $c2.Width = [System.Windows.GridLength]::new(1, [System.Windows.GridUnitType]::Star)
    [void]$g.ColumnDefinitions.Add($c1); [void]$g.ColumnDefinitions.Add($c2)
    $ib = New-Object System.Windows.Controls.Border
    $ib.Width = 56; $ib.Height = 56
    $ib.CornerRadius = [System.Windows.CornerRadius]::new(18)
    $ib.Background = New-Brush '#FFFFFF'
    $ib.Child = (New-Icon $Tab.Icon 28 '#A10D18')
    $ib.HorizontalAlignment = 'Center'
    $ib.Child.HorizontalAlignment = 'Center'; $ib.Child.VerticalAlignment = 'Center'
    [void]$g.Children.Add($ib)
    $sp = New-Object System.Windows.Controls.StackPanel
    $sp.Margin = [System.Windows.Thickness]::new(16, 0, 0, 0)
    $sp.VerticalAlignment = 'Center'
    [void]$sp.Children.Add((New-Text $Tab.Title 30 900))
    $d = New-Text $Tab.Desc 14 600 '#C7FFFFFF' $true
    $d.Margin = [System.Windows.Thickness]::new(0, 3, 0, 0)
    [void]$sp.Children.Add($d)
    [System.Windows.Controls.Grid]::SetColumn($sp, 1)
    [void]$g.Children.Add($sp)
    return $g
}

function New-ListCard {
    $b = New-Object System.Windows.Controls.Border
    $b.Background = New-Brush '#1AFFFFFF'
    $b.BorderBrush = New-Brush '#38FFFFFF'
    $b.BorderThickness = [System.Windows.Thickness]::new(1)
    $b.CornerRadius = [System.Windows.CornerRadius]::new(18)
    $b.ClipToBounds = $true
    $sp = New-Object System.Windows.Controls.StackPanel
    $b.Child = $sp
    return @{ Card = $b; Stack = $sp }
}

function New-GroupHeading {
    param([string]$Text)
    $t = New-Text $Text 13 800 '#C7FFFFFF'
    $t.Margin = [System.Windows.Thickness]::new(6, 24, 0, 9)
    return $t
}

function New-NoteBox {
    param([string]$Text)
    $b = New-Object System.Windows.Controls.Border
    $b.Margin = [System.Windows.Thickness]::new(0, 18, 0, 0)
    $b.Padding = [System.Windows.Thickness]::new(16, 12, 16, 12)
    $b.CornerRadius = [System.Windows.CornerRadius]::new(14)
    $b.Background = New-Brush '#33000000'
    $b.BorderBrush = New-Brush '#55FFFFFF'
    $b.BorderThickness = [System.Windows.Thickness]::new(1)
    $b.Child = (New-Text $Text 13 600 '#D9FFFFFF' $true)
    return $b
}

function New-TweakRow {
    param($T, [bool]$IsLast)
    $border = New-Object System.Windows.Controls.Border
    $border.Padding = [System.Windows.Thickness]::new(20, 15, 20, 15)
    $border.Background = New-Brush '#00FFFFFF'
    $border.BorderBrush = New-Brush '#26FFFFFF'
    if ($IsLast) { $border.BorderThickness = [System.Windows.Thickness]::new(0) } else { $border.BorderThickness = [System.Windows.Thickness]::new(0, 0, 0, 1) }

    $grid = New-Object System.Windows.Controls.Grid
    $c1 = New-Object System.Windows.Controls.ColumnDefinition; $c1.Width = [System.Windows.GridLength]::new(1, [System.Windows.GridUnitType]::Star)
    $c2 = New-Object System.Windows.Controls.ColumnDefinition; $c2.Width = [System.Windows.GridLength]::Auto
    $c3 = New-Object System.Windows.Controls.ColumnDefinition; $c3.Width = [System.Windows.GridLength]::Auto
    [void]$grid.ColumnDefinitions.Add($c1); [void]$grid.ColumnDefinitions.Add($c2); [void]$grid.ColumnDefinitions.Add($c3)

    $left = New-Object System.Windows.Controls.StackPanel
    $left.VerticalAlignment = 'Center'
    $left.Margin = [System.Windows.Thickness]::new(0, 0, 18, 0)
    [void]$left.Children.Add((New-Text $T.Name 15 800 '#FFFFFF' $true))
    $desc = New-Text $T.Desc 12.5 600 '#C7FFFFFF' $true
    $desc.Margin = [System.Windows.Thickness]::new(0, 3, 0, 0)
    $desc.MaxWidth = 660
    $desc.HorizontalAlignment = 'Left'
    [void]$left.Children.Add($desc)
    if ($T.Restart -eq 'restart') { $rn = New-Text 'Needs a restart.' 12 700 '#8FFFFFFF'; $rn.Margin = [System.Windows.Thickness]::new(0, 4, 0, 0); [void]$left.Children.Add($rn) }
    if ($T.Restart -eq 'sign-out') { $rn = New-Text 'Fully applies after you sign out and back in.' 12 700 '#8FFFFFFF'; $rn.Margin = [System.Windows.Thickness]::new(0, 4, 0, 0); [void]$left.Children.Add($rn) }
    $tagRow = New-TagRow $T
    if ($tagRow) { [void]$left.Children.Add($tagRow) }
    if ($T.Picker) {
        $pk = $T.Picker
        $pvals = $script:PickerValues
        $pkey = [string]$pk.Key
        $pmin = [int]$pk.Min
        $pmax = [int]$pk.Max
        $prow = New-Object System.Windows.Controls.StackPanel
        $prow.Orientation = 'Horizontal'
        $prow.Margin = [System.Windows.Thickness]::new(0, 10, 0, 0)
        $lbl = New-Text ([string]$pk.Label) 13 700 '#C7FFFFFF'
        $lbl.VerticalAlignment = 'Center'
        $lbl.Margin = [System.Windows.Thickness]::new(0, 0, 12, 0)
        $vt = New-Text ('0x{0:X}  ({0})' -f [int]$pvals[$pkey]) 15 800
        $vt.VerticalAlignment = 'Center'
        $vt.Width = 92
        $vt.TextAlignment = 'Center'
        $bm = New-Object System.Windows.Controls.Button
        $bm.Style = $script:Window.FindResource('GhostButton')
        $bm.Content = '-'
        $bm.Padding = [System.Windows.Thickness]::new(15, 3, 15, 3)
        $bm.Margin = [System.Windows.Thickness]::new(0)
        $bp = New-Object System.Windows.Controls.Button
        $bp.Style = $script:Window.FindResource('GhostButton')
        $bp.Content = '+'
        $bp.Padding = [System.Windows.Thickness]::new(15, 3, 15, 3)
        $bp.Margin = [System.Windows.Thickness]::new(0)
        $dec = { $pvals[$pkey] = [math]::Max($pmin, [int]$pvals[$pkey] - 1); $vt.Text = ('0x{0:X}  ({0})' -f [int]$pvals[$pkey]) }.GetNewClosure()
        $inc = { $pvals[$pkey] = [math]::Min($pmax, [int]$pvals[$pkey] + 1); $vt.Text = ('0x{0:X}  ({0})' -f [int]$pvals[$pkey]) }.GetNewClosure()
        $bm.Add_Click($dec)
        $bp.Add_Click($inc)
        [void]$prow.Children.Add($lbl)
        [void]$prow.Children.Add($bm)
        [void]$prow.Children.Add($vt)
        [void]$prow.Children.Add($bp)
        [void]$left.Children.Add($prow)
    }
    [void]$grid.Children.Add($left)

    $pill = New-Object System.Windows.Controls.Border
    $pill.CornerRadius = [System.Windows.CornerRadius]::new(10)
    $pill.Padding = [System.Windows.Thickness]::new(12, 5, 12, 5)
    $pill.Margin = [System.Windows.Thickness]::new(0, 0, 16, 0)
    $pill.VerticalAlignment = 'Center'
    $pill.Background = New-Brush '#1FFFFFFF'
    $statusText = New-Text 'Not applied' 12 800 '#B3FFFFFF'
    $pill.Child = $statusText
    [System.Windows.Controls.Grid]::SetColumn($pill, 1)
    [void]$grid.Children.Add($pill)

    $cb = New-Object System.Windows.Controls.CheckBox
    $cb.Style = $script:Window.FindResource('Switch')
    $cb.VerticalAlignment = 'Center'
    [System.Windows.Controls.Grid]::SetColumn($cb, 2)
    [void]$grid.Children.Add($cb)
    $cb.Add_Checked({ Update-Count })
    $cb.Add_Unchecked({ Update-Count })

    $border.Child = $grid
    $hover = New-Brush '#14FFFFFF'
    $clear = New-Brush '#00FFFFFF'
    $enter = { $border.Background = $hover }.GetNewClosure()
    $leave = { $border.Background = $clear }.GetNewClosure()
    $click = { $cb.IsChecked = (-not [bool]$cb.IsChecked) }.GetNewClosure()
    $border.Add_MouseEnter($enter)
    $border.Add_MouseLeave($leave)
    $border.Add_MouseLeftButtonUp($click)

    $script:Rows[$T.Id] = @{ Check = $cb; StatusText = $statusText; Pill = $pill }
    return $border
}

function New-GuideRow {
    param([int]$Index, $Step, [bool]$IsLast)
    $border = New-Object System.Windows.Controls.Border
    $border.Padding = [System.Windows.Thickness]::new(20, 16, 20, 16)
    $border.Background = New-Brush '#00FFFFFF'
    $border.BorderBrush = New-Brush '#26FFFFFF'
    if ($IsLast) { $border.BorderThickness = [System.Windows.Thickness]::new(0) } else { $border.BorderThickness = [System.Windows.Thickness]::new(0, 0, 0, 1) }
    $grid = New-Object System.Windows.Controls.Grid
    $c1 = New-Object System.Windows.Controls.ColumnDefinition; $c1.Width = [System.Windows.GridLength]::Auto
    $c2 = New-Object System.Windows.Controls.ColumnDefinition; $c2.Width = [System.Windows.GridLength]::new(1, [System.Windows.GridUnitType]::Star)
    [void]$grid.ColumnDefinitions.Add($c1); [void]$grid.ColumnDefinitions.Add($c2)
    $num = New-Object System.Windows.Controls.Border
    $num.Width = 34; $num.Height = 34
    $num.CornerRadius = [System.Windows.CornerRadius]::new(17)
    $num.BorderBrush = New-Brush '#88FFFFFF'
    $num.BorderThickness = [System.Windows.Thickness]::new(2)
    $num.VerticalAlignment = 'Top'
    $numText = New-Text ([string]($Index + 1)) 14 900
    $numText.HorizontalAlignment = 'Center'; $numText.VerticalAlignment = 'Center'
    $num.Child = $numText
    [void]$grid.Children.Add($num)
    $sp = New-Object System.Windows.Controls.StackPanel
    $sp.Margin = [System.Windows.Thickness]::new(16, 0, 0, 0)
    [void]$sp.Children.Add((New-Text $Step.Name 15 800 '#FFFFFF' $true))
    $d = New-Text $Step.Desc 12.5 600 '#C7FFFFFF' $true
    $d.Margin = [System.Windows.Thickness]::new(0, 3, 0, 0)
    [void]$sp.Children.Add($d)
    [System.Windows.Controls.Grid]::SetColumn($sp, 1)
    [void]$grid.Children.Add($sp)
    $border.Child = $grid
    $green = New-Brush '#22C55E'; $none = New-Brush '#00FFFFFF'; $ring = New-Brush '#88FFFFFF'; $wt = New-Brush '#FFFFFF'
    $state = @{ Done = $false }
    $click = {
        $state.Done = -not $state.Done
        if ($state.Done) { $num.Background = $green; $numText.Foreground = $wt; $num.BorderBrush = $green }
        else { $num.Background = $none; $numText.Foreground = $wt; $num.BorderBrush = $ring }
    }.GetNewClosure()
    $border.Add_MouseLeftButtonUp($click)
    return $border
}

function New-EmptyState {
    param($Tab, [string]$Extra)
    $b = New-Object System.Windows.Controls.Border
    $b.Margin = [System.Windows.Thickness]::new(0, 26, 0, 0)
    $b.Padding = [System.Windows.Thickness]::new(28, 34, 28, 34)
    $b.CornerRadius = [System.Windows.CornerRadius]::new(20)
    $b.Background = New-Brush '#1AFFFFFF'
    $b.BorderBrush = New-Brush '#38FFFFFF'
    $b.BorderThickness = [System.Windows.Thickness]::new(1)
    $sp = New-Object System.Windows.Controls.StackPanel
    $sp.HorizontalAlignment = 'Center'
    [void]$sp.Children.Add((New-Text 'No tweaks here yet' 20 800))
    $t = New-Text ('Tell me which tweaks belong on the {0} tab and I will add them.' -f $Tab.Label) 13.5 600 '#C7FFFFFF' $true
    $t.Margin = [System.Windows.Thickness]::new(0, 6, 0, 0); $t.TextAlignment = 'Center'
    [void]$sp.Children.Add($t)
    if ($Extra) {
        $e = New-Text $Extra 13 700 '#FFFFFF' $true
        $e.Margin = [System.Windows.Thickness]::new(0, 14, 0, 0); $e.TextAlignment = 'Center'
        [void]$sp.Children.Add($e)
    }
    $b.Child = $sp
    return $b
}

# ----------------------------------------------------------------------------
# Fortnite GameUserSettings.ini panel (Extra Tweaks)
# ----------------------------------------------------------------------------
$script:Fn = @{}

function New-OptionRow {
    param([string]$Label, [string]$Sub, [bool]$Checked)
    $g = New-Object System.Windows.Controls.Grid
    $g.Margin = [System.Windows.Thickness]::new(0, 8, 0, 8)
    $c1 = New-Object System.Windows.Controls.ColumnDefinition; $c1.Width = [System.Windows.GridLength]::new(1, [System.Windows.GridUnitType]::Star)
    $c2 = New-Object System.Windows.Controls.ColumnDefinition; $c2.Width = [System.Windows.GridLength]::Auto
    [void]$g.ColumnDefinitions.Add($c1); [void]$g.ColumnDefinitions.Add($c2)
    $sp = New-Object System.Windows.Controls.StackPanel
    $sp.Margin = [System.Windows.Thickness]::new(0, 0, 16, 0)
    [void]$sp.Children.Add((New-Text $Label 14 700 '#FFFFFF' $true))
    if ($Sub) {
        $s = New-Text $Sub 12.5 600 '#C7FFFFFF' $true
        $s.Margin = [System.Windows.Thickness]::new(0, 2, 0, 0)
        [void]$sp.Children.Add($s)
    }
    [void]$g.Children.Add($sp)
    $cb = New-Object System.Windows.Controls.CheckBox
    $cb.Style = $script:Window.FindResource('Switch')
    $cb.IsChecked = $Checked
    $cb.VerticalAlignment = 'Center'
    [System.Windows.Controls.Grid]::SetColumn($cb, 1)
    [void]$g.Children.Add($cb)
    return @{ Panel = $g; Check = $cb }
}

function New-FieldBox {
    param([string]$Text, [double]$Width)
    $tb = New-Object System.Windows.Controls.TextBox
    $tb.Style = $script:Window.FindResource('Field')
    $tb.Text = $Text
    $tb.Width = $Width
    $tb.VerticalAlignment = 'Center'
    $tb.TextAlignment = 'Center'
    return $tb
}

function Update-FnStatus {
    if (-not $script:Fn.Status) { return }
    if ($script:State.ContainsKey('fn-ini')) {
        $s = $script:State['fn-ini']
        $script:Fn.Applied.Text = ('Applied on ' + [string]$s.Time + '. Your original file is backed up next to it.')
    } else {
        $script:Fn.Applied.Text = 'Not applied by Compact Tweaks yet.'
    }
}

function Get-FnOptions {
    $w = 0; $h = 0; $fps = 0
    if (-not [int]::TryParse($script:Fn.W.Text.Trim(), [ref]$w) -or $w -lt 640 -or $w -gt 7680) { throw 'Enter a resolution width between 640 and 7680.' }
    if (-not [int]::TryParse($script:Fn.H.Text.Trim(), [ref]$h) -or $h -lt 480 -or $h -gt 4320) { throw 'Enter a resolution height between 480 and 4320.' }
    if (-not [int]::TryParse($script:Fn.Fps.Text.Trim(), [ref]$fps) -or $fps -lt 30 -or $fps -gt 1000) { throw 'Enter an FPS limit between 30 and 1000.' }
    return @{
        Width = $w; Height = $h; Fps = $fps
        LowGraphics = [bool]$script:Fn.Low.Check.IsChecked
        KeepView    = [bool]$script:Fn.KeepView.Check.IsChecked
        NoReplays   = [bool]$script:Fn.Replay.Check.IsChecked
        NoSleep     = [bool]$script:Fn.Sleep.Check.IsChecked
        Hud75       = [bool]$script:Fn.Hud.Check.IsChecked
        LobbyFps    = [bool]$script:Fn.Lobby.Check.IsChecked
    }
}

function Invoke-FnPreview {
    try {
        $opt = Get-FnOptions
        $ini = Get-FortniteGameIni
        if (-not (Test-Path -LiteralPath $ini)) { throw 'Fortnite settings file not found. Start Fortnite once, reach the lobby, close it, then try again.' }
        $f = Read-TextFile $ini
        $plan = Get-FortniteIniPlan $f.Text $opt
        $script:Fn.Preview.Text = ($plan.Changes -join "`r`n")
        $script:Fn.Status.Text = 'Preview only. Nothing was written.'
    } catch { $script:Fn.Status.Text = $_.Exception.Message }
}

function Invoke-FnApply {
    try {
        $opt = Get-FnOptions
        $ini = Get-FortniteGameIni
        if (-not (Test-Path -LiteralPath $ini)) { throw 'Fortnite settings file not found. Start Fortnite once, reach the lobby, close it, then try again.' }
        if (Get-Process -Name @('FortniteClient-Win64-Shipping', 'FortniteLauncher') -ErrorAction SilentlyContinue) { throw 'Close Fortnite first. It rewrites this file when you exit and would undo the changes.' }
        $ask = [System.Windows.MessageBox]::Show('Write these settings to your Fortnite GameUserSettings.ini? A backup of the current file is made first, and you can restore it here.', 'Compact Tweaks', 'YesNo', 'Question')
        if ($ask -ne 'Yes') { return }
        $f = Read-TextFile $ini
        $plan = Get-FortniteIniPlan $f.Text $opt
        $bak = Backup-FileSafe $ini
        Save-IniLines $ini $plan.Lines $f
        $script:State['fn-ini'] = @{ Time = (Get-Date).ToString('s'); File = $ini; Backup = $bak }
        Save-State
        $script:Fn.Preview.Text = ($plan.Changes -join "`r`n")
        $script:Fn.Status.Text = 'Done. Settings written.'
        Write-Log ('Fortnite GameUserSettings.ini updated ({0}x{1}, {2} FPS limit)' -f $opt.Width, $opt.Height, $opt.Fps) 'Ok'
        Show-Toast 'Fortnite settings written. Your backup is saved next to the file.'
        Update-FnStatus
        Update-HomeChips
    } catch {
        $script:Fn.Status.Text = $_.Exception.Message
        Write-Log ('Fortnite settings: ' + $_.Exception.Message) 'Warn'
    }
}

function Invoke-FnRestore {
    try {
        $ini = Get-FortniteGameIni
        $bak = $null
        if ($script:State.ContainsKey('fn-ini')) {
            $b = [string]$script:State['fn-ini'].Backup
            if ($b -and (Test-Path -LiteralPath $b)) { $bak = $b }
        }
        if (-not $bak) {
            $dir = Split-Path -Path $ini -Parent
            $leaf = Split-Path -Path $ini -Leaf
            $newest = @(Get-ChildItem -LiteralPath $dir -Filter ($leaf + '.compacttweaks.bak-*') -File -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1)
            if ($newest.Count -gt 0) { $bak = $newest[0].FullName }
        }
        if (-not $bak) { throw 'No backup was found to restore.' }
        if (Get-Process -Name @('FortniteClient-Win64-Shipping', 'FortniteLauncher') -ErrorAction SilentlyContinue) { throw 'Close Fortnite first.' }
        $attr = [IO.File]::GetAttributes($ini)
        if (($attr -band [IO.FileAttributes]::ReadOnly) -ne 0) { [IO.File]::SetAttributes($ini, ($attr -band (-bnot [IO.FileAttributes]::ReadOnly))) }
        Copy-Item -LiteralPath $bak -Destination $ini -Force
        if ($script:State.ContainsKey('fn-ini')) { $script:State.Remove('fn-ini'); Save-State }
        $script:Fn.Status.Text = 'Restored from backup.'
        Write-Log ('Fortnite GameUserSettings.ini restored from ' + $bak) 'Ok'
        Show-Toast 'Fortnite settings restored from backup.'
        Update-FnStatus
        Update-HomeChips
    } catch { $script:Fn.Status.Text = $_.Exception.Message }
}

function New-FortniteCard {
    $card = New-Object System.Windows.Controls.Border
    $card.Margin = [System.Windows.Thickness]::new(0, 14, 0, 0)
    $card.Padding = [System.Windows.Thickness]::new(22, 20, 22, 20)
    $card.CornerRadius = [System.Windows.CornerRadius]::new(18)
    $card.Background = New-Brush '#1AFFFFFF'
    $card.BorderBrush = New-Brush '#38FFFFFF'
    $card.BorderThickness = [System.Windows.Thickness]::new(1)
    $sp = New-Object System.Windows.Controls.StackPanel
    $card.Child = $sp

    [void]$sp.Children.Add((New-Text 'The Best Game Performance Settings' 17 800))
    $d = New-Text 'Edits only the keys below inside your existing Fortnite settings file, makes a backup first, and shows you exactly what changes before anything is written. Close Fortnite before applying.' 13 600 '#C7FFFFFF' $true
    $d.Margin = [System.Windows.Thickness]::new(0, 4, 0, 14)
    [void]$sp.Children.Add($d)

    $res = New-Native-Resolution-Row
    [void]$sp.Children.Add($res)

    $script:Fn.Low      = New-OptionRow 'Lowest graphics, everything off' 'Sets every quality group to Low and turns VSync and motion blur off. 3D resolution stays at 100 percent so the picture is not blurry.' $true
    $script:Fn.KeepView = New-OptionRow 'Keep view distance high' 'Recommended for competitive play: low view distance can hide enemies who are far away.' $false
    $script:Fn.Replay   = New-OptionRow 'Replays off' 'Turns off replay recording if a replay setting exists in your file.' $true
    $script:Fn.Sleep    = New-OptionRow 'Sleep timer: never and off' 'Turns off the sleep timer if one exists in your file.' $true
    $script:Fn.Hud      = New-OptionRow 'HUD scale 69 percent' 'Makes the on-screen interface smaller.' $true
    $script:Fn.Lobby    = New-OptionRow 'Lobby FPS cap 120' 'Caps the menu and lobby at 120 FPS (the hidden FrontendFrameRateLimit setting); the lobby does not need as high a limit as a match does.' $true
    foreach ($k in @('Low', 'KeepView', 'Replay', 'Sleep', 'Hud', 'Lobby')) { [void]$sp.Children.Add($script:Fn[$k].Panel) }

    $btns = New-Object System.Windows.Controls.StackPanel
    $btns.Orientation = 'Horizontal'
    $btns.Margin = [System.Windows.Thickness]::new(0, 14, 0, 0)
    $bp = New-Object System.Windows.Controls.Button; $bp.Style = $script:Window.FindResource('GhostButton'); $bp.Content = 'Preview changes'; $bp.Margin = [System.Windows.Thickness]::new(0, 0, 10, 0)
    $ba = New-Object System.Windows.Controls.Button; $ba.Style = $script:Window.FindResource('PrimaryButton'); $ba.Content = 'Apply to Fortnite'; $ba.Margin = [System.Windows.Thickness]::new(0, 0, 10, 0)
    $br = New-Object System.Windows.Controls.Button; $br.Style = $script:Window.FindResource('GhostButton'); $br.Content = 'Restore backup'
    $bp.Add_Click({ Invoke-FnPreview })
    $ba.Add_Click({ Invoke-FnApply })
    $br.Add_Click({ Invoke-FnRestore })
    [void]$btns.Children.Add($bp); [void]$btns.Children.Add($ba); [void]$btns.Children.Add($br)
    [void]$sp.Children.Add($btns)

    $script:Fn.Status = New-Text '' 13 700 '#FFFFFF' $true
    $script:Fn.Status.Margin = [System.Windows.Thickness]::new(0, 12, 0, 0)
    [void]$sp.Children.Add($script:Fn.Status)
    $script:Fn.Applied = New-Text '' 12.5 600 '#C7FFFFFF' $true
    $script:Fn.Applied.Margin = [System.Windows.Thickness]::new(0, 4, 0, 0)
    [void]$sp.Children.Add($script:Fn.Applied)

    $pv = New-Object System.Windows.Controls.TextBox
    $pv.Style = $script:Window.FindResource('Field')
    $pv.IsReadOnly = $true
    $pv.FontFamily = New-Object System.Windows.Media.FontFamily('Consolas')
    $pv.FontSize = 12
    $pv.TextWrapping = [System.Windows.TextWrapping]::NoWrap
    $pv.VerticalScrollBarVisibility = [System.Windows.Controls.ScrollBarVisibility]::Auto
    $pv.HorizontalScrollBarVisibility = [System.Windows.Controls.ScrollBarVisibility]::Auto
    $pv.Height = 170
    $pv.Margin = [System.Windows.Thickness]::new(0, 12, 0, 0)
    $pv.Text = 'Press Preview changes to see what would be written.'
    $script:Fn.Preview = $pv
    [void]$sp.Children.Add($pv)
    Update-FnStatus
    return $card
}

function New-Native-Resolution-Row {
    $res = Get-NativeResolution
    $row = New-Object System.Windows.Controls.WrapPanel
    $row.Margin = [System.Windows.Thickness]::new(0, 0, 0, 6)
    $lab = New-Text 'Resolution' 14 700
    $lab.VerticalAlignment = 'Center'; $lab.Margin = [System.Windows.Thickness]::new(0, 0, 12, 0)
    [void]$row.Children.Add($lab)
    $script:Fn.W = New-FieldBox ([string]$res.W) 86
    $x = New-Text 'x' 14 700; $x.VerticalAlignment = 'Center'; $x.Margin = [System.Windows.Thickness]::new(8, 0, 8, 0)
    $script:Fn.H = New-FieldBox ([string]$res.H) 86
    [void]$row.Children.Add($script:Fn.W); [void]$row.Children.Add($x); [void]$row.Children.Add($script:Fn.H)
    $det = New-Object System.Windows.Controls.Button
    $det.Style = $script:Window.FindResource('GhostButton'); $det.Content = 'Detect'; $det.Margin = [System.Windows.Thickness]::new(12, 0, 0, 0); $det.Padding = [System.Windows.Thickness]::new(14, 7, 14, 7)
    $det.Add_Click({ $r = Get-NativeResolution; $script:Fn.W.Text = [string]$r.W; $script:Fn.H.Text = [string]$r.H })
    [void]$row.Children.Add($det)
    $lab2 = New-Text 'FPS limit' 14 700
    $lab2.VerticalAlignment = 'Center'; $lab2.Margin = [System.Windows.Thickness]::new(28, 0, 12, 0)
    [void]$row.Children.Add($lab2)
    $script:Fn.Fps = New-FieldBox '360' 70
    [void]$row.Children.Add($script:Fn.Fps)
    return $row
}

function New-GuideSection {
    param($Stack, [string]$Title, $Steps)
    [void]$Stack.Children.Add((New-GroupHeading $Title))
    $card = New-ListCard
    for ($i = 0; $i -lt $Steps.Count; $i++) {
        [void]$card.Stack.Children.Add((New-GuideRow $i $Steps[$i] ($i -eq $Steps.Count - 1)))
    }
    [void]$Stack.Children.Add($card.Card)
}

function Get-PollingSections {
    $dev = @(Get-InputDeviceSummary)
    if ($dev.Count -gt 0) { $devText = ($dev -join '; ') } else { $devText = 'No branded gaming devices were detected (generic devices do not report a brand).' }
    return @(
        @{ Title = 'Polling rate: mouse and keyboard at the maximum'; Steps = @(
            @{ Name = 'Your detected devices'; Desc = $devText },
            @{ Name = 'Why Windows cannot set this'; Desc = 'The polling rate (how often the device reports to the PC) is stored inside the mouse or keyboard itself. Windows and Compact Tweaks cannot change it. Only the maker software or buttons on the device can.' },
            @{ Name = 'Set it to the maximum in the maker software'; Desc = 'Open Logitech G HUB, Razer Synapse, SteelSeries GG, Corsair iCUE, HyperX NGENUITY or ASUS Armoury Crate, pick your mouse and set Report Rate or Polling Rate to the highest value: 1000 Hz on most devices, 2000 to 8000 Hz on newer ones. Many keyboards have the same option, and some mice cycle it with a button underneath.' },
            @{ Name = 'Plug it in the right place'; Desc = 'Use a USB port directly on the back of the motherboard, not a hub or a front-panel port. For wired models use the cable that came with the device.' },
            @{ Name = 'Check that it took effect'; Desc = 'Move the mouse in circles on a mouse polling rate test website and confirm the number matches your setting.' },
            @{ Name = 'Watch the 4000 and 8000 Hz trade-off'; Desc = 'Very high polling rates use noticeably more CPU. If your FPS drops or the game stutters, go back to 1000 Hz. Rates above 1000 Hz mostly help at high mouse speeds on high refresh rate monitors.' }
        ) }
    )
}

function Get-VendorSections {
    $out = @()
    if (Test-HasGpuVendor 'NVIDIA') {
        $out += @{ Title = 'Best Nvidia Control Panel settings'; Steps = @(
            @{ Name = 'Power management mode'; Desc = 'Prefer maximum performance' },
            @{ Name = 'Low Latency Mode'; Desc = 'Off (use the NVIDIA Reflex setting inside Fortnite instead)' },
            @{ Name = 'Texture filtering - Quality'; Desc = 'High performance' },
            @{ Name = 'Shader Cache Size'; Desc = 'Driver Default / Unlimited' },
            @{ Name = 'Threaded optimization'; Desc = 'Auto' },
            @{ Name = 'Vertical sync'; Desc = 'Off' },
            @{ Name = 'Triple buffering'; Desc = 'Off' },
            @{ Name = 'Preferred refresh rate'; Desc = 'Highest available' },
            @{ Name = 'Background Application Max Frame Rate'; Desc = 'Off' },
            @{ Name = 'Max Frame Rate'; Desc = 'Off' },
            @{ Name = 'CUDA - GPUs'; Desc = 'All' },
            @{ Name = 'OpenGL rendering GPU'; Desc = 'Your NVIDIA GPU' },
            @{ Name = 'Antialiasing - Mode'; Desc = 'Application-controlled' },
            @{ Name = 'MFAA'; Desc = 'Off' },
            @{ Name = 'DSR - Factors'; Desc = 'Off' },
            @{ Name = 'Image Scaling'; Desc = 'Off' }
        ) }
    }
    if (Test-HasGpuVendor 'AMD') {
        $out += @{ Title = 'Best AMD Adrenalin settings'; Steps = @(
            @{ Name = 'Radeon Anti-Lag'; Desc = 'On' },
            @{ Name = 'Radeon Chill'; Desc = 'Off' },
            @{ Name = 'Radeon Boost'; Desc = 'Off (unless you intentionally use it)' },
            @{ Name = 'Enhanced Sync'; Desc = 'Off' },
            @{ Name = 'Wait for Vertical Refresh'; Desc = 'Always Off' },
            @{ Name = 'Frame Rate Target Control'; Desc = 'Disabled' },
            @{ Name = 'Radeon Image Sharpening'; Desc = 'Off (optional, your preference)' },
            @{ Name = 'Surface Format Optimization'; Desc = 'On' },
            @{ Name = 'Shader Cache'; Desc = 'AMD Optimized' },
            @{ Name = 'Texture Filtering Quality'; Desc = 'Performance' },
            @{ Name = 'Tessellation Mode'; Desc = 'AMD Optimized' },
            @{ Name = 'Morphological Anti-Aliasing'; Desc = 'Off' },
            @{ Name = 'Virtual Super Resolution'; Desc = 'Off' }
        ) }
    }
    return $out
}

function New-DiscordCard {
    $card = New-Object System.Windows.Controls.Border
    $card.Margin = [System.Windows.Thickness]::new(0, 26, 0, 0)
    $card.Padding = [System.Windows.Thickness]::new(30, 30, 30, 30)
    $card.CornerRadius = [System.Windows.CornerRadius]::new(22)
    $card.Background = New-Brush '#1AFFFFFF'
    $card.BorderBrush = New-Brush '#38FFFFFF'
    $card.BorderThickness = [System.Windows.Thickness]::new(1)
    $sp = New-Object System.Windows.Controls.StackPanel
    $sp.HorizontalAlignment = 'Left'
    [void]$sp.Children.Add((New-Text 'Join the Compact Tweaks Discord' 24 900))
    $d = New-Text 'Get updates, share feedback, and tell us which tweaks you want next.' 14 600 '#C7FFFFFF' $true
    $d.Margin = [System.Windows.Thickness]::new(0, 6, 0, 0)
    $d.MaxWidth = 560
    [void]$sp.Children.Add($d)
    $btn = New-Object System.Windows.Controls.Button
    $btn.Style = $script:Window.FindResource('PrimaryButton')
    $btn.Content = 'Join our Discord'
    $btn.Padding = [System.Windows.Thickness]::new(30, 13, 30, 13)
    $btn.FontSize = 15
    $btn.HorizontalAlignment = 'Left'
    $btn.Margin = [System.Windows.Thickness]::new(0, 20, 0, 0)
    $btn.Add_Click({
        try { Start-Process 'https://discord.gg/VmmxtGMSWD' }
        catch { Show-Toast 'Could not open your browser. Copy this link: discord.gg/VmmxtGMSWD' }
    })
    [void]$sp.Children.Add($btn)
    $l = New-Text 'discord.gg/VmmxtGMSWD' 12.5 700 '#8FFFFFFF'
    $l.Margin = [System.Windows.Thickness]::new(0, 10, 0, 0)
    [void]$sp.Children.Add($l)
    $card.Child = $sp
    return $card
}

function New-LaptopLinkRow {
    param($T, [bool]$IsLast)
    $tabLabel = 'its own tab'
    foreach ($td in $script:TabDefs) { if ($td.Id -eq $T.Category) { $tabLabel = $td.Label; break } }
    $border = New-Object System.Windows.Controls.Border
    $border.Padding = [System.Windows.Thickness]::new(20, 15, 20, 15)
    $border.BorderBrush = New-Brush '#26FFFFFF'
    if ($IsLast) { $border.BorderThickness = [System.Windows.Thickness]::new(0) } else { $border.BorderThickness = [System.Windows.Thickness]::new(0, 0, 0, 1) }
    $grid = New-Object System.Windows.Controls.Grid
    $c1 = New-Object System.Windows.Controls.ColumnDefinition; $c1.Width = [System.Windows.GridLength]::new(1, [System.Windows.GridUnitType]::Star)
    $c2 = New-Object System.Windows.Controls.ColumnDefinition; $c2.Width = [System.Windows.GridLength]::Auto
    [void]$grid.ColumnDefinitions.Add($c1); [void]$grid.ColumnDefinitions.Add($c2)
    $left = New-Object System.Windows.Controls.StackPanel
    $left.Margin = [System.Windows.Thickness]::new(0, 0, 18, 0)
    [void]$left.Children.Add((New-Text $T.Name 15 800 '#FFFFFF' $true))
    $d = New-Text $T.Desc 12.5 600 '#C7FFFFFF' $true
    $d.Margin = [System.Windows.Thickness]::new(0, 3, 0, 0)
    $d.MaxWidth = 620
    [void]$left.Children.Add($d)
    $tagRow = New-TagRow $T
    if ($tagRow) { [void]$left.Children.Add($tagRow) }
    [void]$grid.Children.Add($left)
    $btn = New-Object System.Windows.Controls.Button
    $btn.Style = $script:Window.FindResource('GhostButton')
    $btn.Content = ('Open in ' + $tabLabel)
    $btn.VerticalAlignment = 'Center'
    $btn.Padding = [System.Windows.Thickness]::new(14, 7, 14, 7)
    $cat = [string]$T.Category
    $btn.Add_Click({ Show-Page $cat }.GetNewClosure())
    [System.Windows.Controls.Grid]::SetColumn($btn, 1)
    [void]$grid.Children.Add($btn)
    $border.Child = $grid
    return $border
}

function New-TabPage {
    param($Tab)
    $shell = New-PageShell
    $stack = $shell.Stack
    [void]$stack.Children.Add((New-PageHeader $Tab))

    if ($Tab.Id -eq 'discord') {
        [void]$stack.Children.Add((New-DiscordCard))
        $script:TabHasRows[$Tab.Id] = $false
        return $shell.Scroll
    }

    if ($Tab.ComingSoon) {
        $script:TabHasRows[$Tab.Id] = $false
        [void]$stack.Children.Add((New-EmptyState $Tab 'Overclocking is being redesigned so it does not use a checklist. Check back in a future update.'))
        return $shell.Scroll
    }

    if ($Tab.Id -eq 'laptop') {
        $script:TabHasRows[$Tab.Id] = $false
        $safe = @($script:Tweaks | Where-Object { $_.IsLaptopSafe -eq $true })
        [void]$stack.Children.Add((New-NoteBox 'These tweaks are safe to use on a laptop, based on public guidance and the fact that they do not meaningfully affect battery life or heat. Each one lives on its own tab; use the button to jump there and apply it, so nothing is applied twice from two places.'))
        if ($safe.Count -gt 0) {
            $groups = @($safe | ForEach-Object { $_.Category } | Select-Object -Unique)
            foreach ($catId in $groups) {
                $label = $catId
                foreach ($td in $script:TabDefs) { if ($td.Id -eq $catId) { $label = $td.Label; break } }
                [void]$stack.Children.Add((New-GroupHeading $label))
                $card = New-ListCard
                $rows = @($safe | Where-Object { $_.Category -eq $catId })
                for ($i = 0; $i -lt $rows.Count; $i++) { [void]$card.Stack.Children.Add((New-LaptopLinkRow $rows[$i] ($i -eq $rows.Count - 1))) }
                [void]$stack.Children.Add($card.Card)
            }
        }
        return $shell.Scroll
    }

    $tweaks = @($script:Tweaks | Where-Object { $_.Category -eq $Tab.Id })
    $script:TabHasRows[$Tab.Id] = ($tweaks.Count -gt 0)
    if ($Tab.Note) { [void]$stack.Children.Add((New-NoteBox $Tab.Note)) }

    if ($tweaks.Count -gt 0) {
        $groups = @($tweaks | ForEach-Object { $_.Group } | Select-Object -Unique)
        foreach ($g in $groups) {
            [void]$stack.Children.Add((New-GroupHeading $g))
            $card = New-ListCard
            $rows = @($tweaks | Where-Object { $_.Group -eq $g })
            for ($i = 0; $i -lt $rows.Count; $i++) {
                [void]$card.Stack.Children.Add((New-TweakRow $rows[$i] ($i -eq $rows.Count - 1)))
            }
            [void]$stack.Children.Add($card.Card)
            if ($Tab.Id -eq 'extra' -and $g -eq 'Fortnite') { [void]$stack.Children.Add((New-FortniteCard)) }
        }
    }

    $sections = @()
    if ($Tab.Sections) { $sections += @($Tab.Sections) }
    if ($Tab.Id -eq 'kbm') { $sections += @(Get-PollingSections) }
    if ($Tab.Id -eq 'vendor') { $sections += @(Get-VendorSections) }
    foreach ($s in $sections) { New-GuideSection $stack ([string]$s.Title) @($s.Steps) }

    if ($tweaks.Count -eq 0 -and $sections.Count -eq 0) {
        $x = ''
        if ($Tab.Id -eq 'vendor') {
            $names = @()
            foreach ($g in @(Get-GpuList)) { $names += $g.Name }
            if ($names.Count -gt 0) { $x = 'Detected graphics: ' + ($names -join ', ') } else { $x = 'No graphics card was detected.' }
        }
        [void]$stack.Children.Add((New-EmptyState $Tab $x))
    }
    return $shell.Scroll
}

# ----------------------------------------------------------------------------
# Navigation
# ----------------------------------------------------------------------------
function Build-Nav {
    $list = $script:Ui.NavList
    $i = 0
    foreach ($t in $script:TabDefs) {
        $btn = New-Object System.Windows.Controls.Button
        $btn.Style = $script:Window.FindResource('NavButton')
        $btn.Margin = [System.Windows.Thickness]::new(0, 0, 0, 4)
        $btn.Tag = $t.Id
        $sp = New-Object System.Windows.Controls.StackPanel
        $sp.Orientation = 'Horizontal'
        [void]$sp.Children.Add((New-Icon $t.Icon 20 '#FFFFFF'))
        $tb = New-Text $t.Label 14 700 '#FFFFFF'
        $tb.Margin = [System.Windows.Thickness]::new(12, 0, 0, 0); $tb.VerticalAlignment = 'Center'
        [void]$sp.Children.Add($tb)
        if ($t.Sub) {
            $sub = New-Text $t.Sub 12 600 '#8FFFFFFF'
            $sub.Margin = [System.Windows.Thickness]::new(8, 0, 0, 0); $sub.VerticalAlignment = 'Center'
            [void]$sp.Children.Add($sub)
        }
        $btn.Content = $sp
        $btn.Add_Click({ param($s, $e) Show-Page ([string]$s.Tag) })
        [void]$list.Children.Add($btn)
        $script:NavButtons[$t.Id] = $btn
        $script:NavIndex[$t.Id] = $i
        $i++
    }
}

function Show-Page {
    param([string]$Id)
    if (-not $script:Pages.ContainsKey($Id)) { return }
    $script:CurrentTab = $Id
    foreach ($k in @($script:Pages.Keys)) { $script:Pages[$k].Visibility = [System.Windows.Visibility]::Collapsed }
    $p = $script:Pages[$Id]
    $p.Visibility = [System.Windows.Visibility]::Visible
    $p.BeginAnimation([System.Windows.UIElement]::OpacityProperty, (New-Anim -To 1 -Ms 260 -Ease 'None' -From 0))
    $p.RenderTransform.BeginAnimation([System.Windows.Media.TranslateTransform]::YProperty, (New-Anim -To 0 -Ms 340 -Ease 'Cubic' -From 14))

    foreach ($k in @($script:NavButtons.Keys)) {
        if ($k -eq $Id) { $script:NavButtons[$k].Foreground = New-Brush '#FFFFFF' } else { $script:NavButtons[$k].Foreground = New-Brush '#C7FFFFFF' }
    }
    $y = [double]($script:NavIndex[$Id] * 46)
    $script:Ui.NavPill.RenderTransform.BeginAnimation([System.Windows.Media.TranslateTransform]::YProperty, (New-Anim -To $y -Ms 460 -Ease 'Back'))

    if ($Id -eq 'discord') { $script:Ui.Bar.Visibility = [System.Windows.Visibility]::Collapsed }
    else { $script:Ui.Bar.Visibility = [System.Windows.Visibility]::Visible }
    Update-Count
}

function Build-Pages {
    $homePage = $script:Ui.HomePage
    $homePage.RenderTransform = New-Object System.Windows.Media.TranslateTransform
    $homePage.Visibility = [System.Windows.Visibility]::Collapsed
    $script:Pages['home'] = $homePage
    foreach ($tab in $script:TabDefs) {
        if ($tab.Id -eq 'home') { continue }
        try {
            $pg = New-TabPage $tab
            $script:Pages[$tab.Id] = $pg
            [void]$script:Ui.PageHost.Children.Add($pg)
        } catch {
            Write-Log ('Could not build the {0} page: {1}' -f $tab.Label, $_.Exception.Message) 'Error'
        }
    }
}

# ----------------------------------------------------------------------------
# Status, batch apply / undo
# ----------------------------------------------------------------------------
function Update-HomeChips {
    $n = 0
    foreach ($v in $script:States.Values) { if ($v -eq 'Applied') { $n++ } }
    if ($script:State.ContainsKey('fn-ini')) { $n++ }
    if ($n -eq 1) { $script:Ui.ChipApplied.Text = '1 tweak applied' } else { $script:Ui.ChipApplied.Text = ('{0} tweaks applied' -f $n) }
}

function Update-Statuses {
    foreach ($t in $script:Tweaks) {
        $row = $script:Rows[$t.Id]
        if (-not $row) { continue }
        $st = Get-TweakState $t
        $script:States[$t.Id] = $st
        switch ($st) {
            'OneShot'    { $row.StatusText.Text = 'One-time';    $row.StatusText.Foreground = New-Brush '#C7FFFFFF'; $row.Pill.Background = New-Brush '#1FFFFFFF' }
            'Applied'    { $row.StatusText.Text = 'Applied';     $row.StatusText.Foreground = New-Brush '#A10D18';   $row.Pill.Background = New-Brush '#FFFFFF' }
            'AlreadySet' { $row.StatusText.Text = 'Already set'; $row.StatusText.Foreground = New-Brush '#FFFFFF';   $row.Pill.Background = New-Brush '#4DFFFFFF' }
            default      { $row.StatusText.Text = 'Not applied'; $row.StatusText.Foreground = New-Brush '#B3FFFFFF'; $row.Pill.Background = New-Brush '#1FFFFFFF' }
        }
    }
    Update-HomeChips
    Update-FnStatus
    Update-UI
}

function Get-SelectedTweaks {
    $out = @()
    foreach ($t in $script:Tweaks) {
        $r = $script:Rows[$t.Id]
        if ($r -and $r.Check.IsChecked -eq $true) { $out += $t }
    }
    return $out
}

function Set-Busy {
    param([bool]$Busy)
    foreach ($b in @($script:Ui.BtnClear, $script:Ui.BtnUndo, $script:Ui.BtnApply)) { $b.IsEnabled = -not $Busy }
    if ($Busy) { $script:Window.Cursor = [System.Windows.Input.Cursors]::Wait } else { $script:Window.Cursor = $null }
    Update-UI
}

function Invoke-Batch {
    param([ValidateSet('Apply', 'Undo')][string]$Mode)
    $sel = @(Get-SelectedTweaks)
    if ($sel.Count -eq 0) { Show-Toast 'Switch on at least one tweak first.'; return }
    if ($Mode -eq 'Apply') {
        $ask = [System.Windows.MessageBox]::Show(("Apply {0} tweak(s)?" -f $sel.Count), 'Compact Tweaks', 'YesNo', 'Question')
        if ($ask -ne 'Yes') { return }
        $high = @($sel | Where-Object { $_.Risk -eq 'High' -and $script:States[$_.Id] -eq 'NotApplied' })
        if ($high.Count -gt 0) {
            $names = (@($high | ForEach-Object { ' - ' + $_.Name }) -join "`n")
            $msg = "These tweaks LOWER your PC's security:`n`n$names`n`nThey are meant for a gaming PC you trust and keep up to date. You can undo them here, but the PC is less protected while they are on.`n`nContinue?"
            $ask2 = [System.Windows.MessageBox]::Show($msg, 'Compact Tweaks - security warning', 'YesNo', 'Warning', 'No')
            if ($ask2 -ne 'Yes') { return }
        }
        foreach ($ct in @($sel | Where-Object { $_.ConfirmText -and $script:States[$_.Id] -ne 'Applied' })) {
            $ans = [System.Windows.MessageBox]::Show([string]$ct.ConfirmText, 'Compact Tweaks', 'YesNo', 'Warning', 'No')
            if ($ans -ne 'Yes') { $sel = @($sel | Where-Object { $_.Id -ne $ct.Id }) }
        }
        if ($sel.Count -eq 0) { return }
    }
    Set-Busy $true
    $script:NeedRestart = $false
    $doneCount = $sel.Count
    try {
        if ($Mode -eq 'Apply') {
            $reversible = @($sel | Where-Object { (-not $_.OneShot) -or $_.NeedsRestorePoint })
            if ($reversible.Count -gt 0 -and $script:Ui.ChkRestore.IsChecked -eq $true) { [void](New-RestorePoint) }
            foreach ($t in $sel) { Invoke-TweakApply $t; Update-UI }
        } else {
            foreach ($t in $sel) { Invoke-TweakUndo $t; Update-UI }
        }
        if ($script:NeedRestart) { Write-Log 'Some changes need a restart or a sign-out to fully take effect.' 'Warn' }
    } catch {
        Write-Log ('Unexpected error: ' + $_.Exception.Message) 'Error'
    } finally {
        Set-Busy $false
        Update-Statuses
    }
    $verb = 'applied'
    if ($Mode -eq 'Undo') { $verb = 'undone' }
    if ($script:NeedRestart) { Show-Toast ("{0} tweak(s) {1}. Restart or sign out to finish." -f $doneCount, $verb) }
    else { Show-Toast ("{0} tweak(s) {1}. See the log for details." -f $doneCount, $verb) }
}

# ----------------------------------------------------------------------------
# Live monitor (Task Manager style): language-neutral performance counters, sampled once a second
# ----------------------------------------------------------------------------
$script:NPts = 61
function New-Series {
    $l = New-Object 'System.Collections.Generic.List[double]'
    for ($i = 0; $i -lt $script:NPts; $i++) { $l.Add(0.0) }
    return , $l
}
$script:H = @{ cpu = (New-Series); disk = (New-Series); rx = (New-Series); tx = (New-Series) }
$script:L = @{ cpu = 0.0; mem = 0.0; memUsed = 0.0; memTotal = 0.0; gpu = 0.0; vram = 0.0; disk = 0.0; rd = 0.0; wr = 0.0; rx = 0.0; tx = 0.0; mhz = 0.0 }
$script:D = @{ cpu = 0.0; mem = 0.0; gpu = 0.0; disk = 0.0; rd = 0.0; wr = 0.0; rx = 0.0; tx = 0.0 }
$script:Mon = @{ Q = $null; MaxMhz = 0.0; Boot = $null; Bars = @(); PerCpu = @(); Tick = 0; LastNet = $null; NetTime = $null; Procs = 0; NetName = ''; GpuEngine = '-'; Err = $false }
$script:NetVirtual = 'Virtual|VMware|VirtualBox|Hyper-V|vEthernet|WAN Miniport|Bluetooth|Npcap|WinPcap|TAP-|Wintun|WireGuard|Loopback|ISATAP|Teredo|Pseudo|Kernel Debug|Wi-Fi Direct|Miniport|Tunnel|Tailscale|ZeroTier|Radmin|Hamachi'

$script:AreaBrush = New-Object System.Windows.Media.LinearGradientBrush
$script:AreaBrush.StartPoint = [System.Windows.Point]::new(0, 0)
$script:AreaBrush.EndPoint = [System.Windows.Point]::new(0, 1)
[void]$script:AreaBrush.GradientStops.Add([System.Windows.Media.GradientStop]::new([System.Windows.Media.Color]::FromArgb(84, 255, 255, 255), 0.0))
[void]$script:AreaBrush.GradientStops.Add([System.Windows.Media.GradientStop]::new([System.Windows.Media.Color]::FromArgb(0, 255, 255, 255), 1.0))

function Initialize-Monitor {
    if (-not $script:NativeOk) { $script:Ui.MonitorNote.Text = 'Live usage is unavailable because the native helper could not load.'; return }
    try { $q = New-Object CT.PdhQuery } catch { $script:Ui.MonitorNote.Text = 'Live usage is unavailable: ' + $_.Exception.Message; return }
    $script:Mon.Q = $q
    [void]$q.Add('cpuUtil', '\Processor Information(_Total)\% Processor Utility')
    [void]$q.Add('cpuTime', '\Processor(_Total)\% Processor Time')
    [void]$q.Add('cpuThreads', '\Processor(*)\% Processor Time')
    [void]$q.Add('cpuPerf', '\Processor Information(_Total)\% Processor Performance')
    [void]$q.Add('diskIdle', '\PhysicalDisk(_Total)\% Idle Time')
    [void]$q.Add('diskRd', '\PhysicalDisk(_Total)\Disk Read Bytes/sec')
    [void]$q.Add('diskWr', '\PhysicalDisk(_Total)\Disk Write Bytes/sec')
    [void]$q.Add('gpuEng', '\GPU Engine(*)\Utilization Percentage')
    [void]$q.Add('gpuMem', '\GPU Adapter Memory(*)\Dedicated Usage')
    [void]$q.Collect()
    try { $script:Mon.MaxMhz = [double](Get-CimInstance Win32_Processor | Select-Object -First 1).MaxClockSpeed } catch { }
    try { $script:Mon.Boot = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime } catch { }
    $n = [Math]::Min([Environment]::ProcessorCount, 32)
    $grid = $script:Ui.ThreadBars
    $grid.Columns = $n
    $bars = @()
    for ($i = 0; $i -lt $n; $i++) {
        $track = New-Object System.Windows.Controls.Border
        $track.CornerRadius = [System.Windows.CornerRadius]::new(5)
        $track.Background = New-Brush '#29FFFFFF'
        $track.Margin = [System.Windows.Thickness]::new(1.5, 0, 1.5, 0)
        $track.ClipToBounds = $true
        $bar = New-Object System.Windows.Controls.Border
        $bar.CornerRadius = [System.Windows.CornerRadius]::new(5)
        $bar.Background = New-Brush '#FFFFFF'
        $bar.VerticalAlignment = 'Bottom'
        $bar.Height = 3
        $track.Child = $bar
        [void]$grid.Children.Add($track)
        $bars += $bar
    }
    $script:Mon.Bars = $bars
    $script:Ui.CpuLogical.Text = [string][Environment]::ProcessorCount
}

function Update-Spark {
    param($Canvas, $Series, [double]$Max)
    $w = $Canvas.ActualWidth
    $h = $Canvas.ActualHeight
    if ($w -lt 20 -or $h -lt 10) { return }
    $n = $Series[0].Count
    $dx = $w / ($n - 2)
    $Canvas.Children.Clear()
    foreach ($f in @(0.25, 0.5, 0.75)) {
        $ln = New-Object System.Windows.Shapes.Line
        $ln.X1 = 0; $ln.X2 = $w; $ln.Y1 = $h * $f; $ln.Y2 = $h * $f
        $ln.Stroke = New-Brush '#24FFFFFF'
        $ln.StrokeThickness = 1
        [void]$Canvas.Children.Add($ln)
    }
    $layer = New-Object System.Windows.Controls.Canvas
    $tt = New-Object System.Windows.Media.TranslateTransform
    $layer.RenderTransform = $tt
    [void]$Canvas.Children.Add($layer)
    for ($si = 0; $si -lt $Series.Count; $si++) {
        $s = $Series[$si]
        $pts = New-Object System.Windows.Media.PointCollection
        for ($i = 0; $i -lt $n; $i++) {
            $v = [math]::Min(1.0, [math]::Max(0.0, $s[$i] / $Max))
            $pts.Add([System.Windows.Point]::new(($i * $dx), ($h - 3 - $v * ($h - 8))))
        }
        if ($si -eq 0) {
            $apts = New-Object System.Windows.Media.PointCollection
            foreach ($p in $pts) { $apts.Add($p) }
            $apts.Add([System.Windows.Point]::new((($n - 1) * $dx), $h))
            $apts.Add([System.Windows.Point]::new(0, $h))
            $poly = New-Object System.Windows.Shapes.Polygon
            $poly.Points = $apts
            $poly.Fill = $script:AreaBrush
            [void]$layer.Children.Add($poly)
        }
        $pl = New-Object System.Windows.Shapes.Polyline
        $pl.Points = $pts
        $pl.StrokeThickness = 2.2
        $pl.StrokeLineJoin = [System.Windows.Media.PenLineJoin]::Round
        if ($si -eq 0) {
            $pl.Stroke = New-Brush '#FFFFFF'
        } else {
            $pl.Stroke = New-Brush '#A6FFFFFF'
            $da = New-Object System.Windows.Media.DoubleCollection
            $da.Add(4); $da.Add(3)
            $pl.StrokeDashArray = $da
        }
        [void]$layer.Children.Add($pl)
    }
    $tt.BeginAnimation([System.Windows.Media.TranslateTransform]::XProperty, (New-Anim -To (-$dx) -Ms 1000 -Ease 'None' -From 0))
}

function Update-ThreadBars {
    $bars = $script:Mon.Bars
    for ($i = 0; $i -lt $bars.Count; $i++) {
        $v = 0.0
        if ($i -lt $script:Mon.PerCpu.Count) { $v = [double]$script:Mon.PerCpu[$i] }
        $target = [math]::Max(3.0, [math]::Min(46.0, $v / 100.0 * 46.0))
        $bars[$i].BeginAnimation([System.Windows.FrameworkElement]::HeightProperty, (New-Anim -To $target -Ms 850 -Ease 'Cubic'))
    }
}

function Push-Series {
    param($List, [double]$Value)
    $List.Add($Value)
    $List.RemoveAt(0)
}

function Invoke-MonitorTick {
    $m = $script:Mon
    if (-not $m.Q) { return }
    $q = $m.Q
    [void]$q.Collect()
    $m.Tick++

    $cpu = $q.Value('cpuUtil', $false)
    if ([double]::IsNaN($cpu)) { $cpu = $q.Value('cpuTime', $false) }
    if ([double]::IsNaN($cpu)) { $cpu = 0.0 }
    $script:L.cpu = [math]::Min(100.0, [math]::Max(0.0, $cpu))
    $per = @{}
    foreach ($it in $q.Items('cpuThreads', $false)) {
        if ($it.Name -match '^\d+$' -and -not [double]::IsNaN($it.Value)) { $per[[int]$it.Name] = $it.Value }
    }
    $arr = @()
    for ($i = 0; $i -lt $m.Bars.Count; $i++) { if ($per.ContainsKey($i)) { $arr += [double]$per[$i] } else { $arr += 0.0 } }
    $m.PerCpu = $arr
    $perf = $q.Value('cpuPerf', $true)
    if (-not [double]::IsNaN($perf) -and $m.MaxMhz -gt 0) { $script:L.mhz = $m.MaxMhz * $perf / 100.0 } elseif ($m.MaxMhz -gt 0) { $script:L.mhz = $m.MaxMhz }

    $mem = [CT.Sys]::Memory()
    if ($mem) {
        $total = [double]$mem.TotalPhys
        $used = $total - [double]$mem.AvailPhys
        $script:L.memTotal = $total / 1GB
        $script:L.memUsed = $used / 1GB
        $script:L.mem = $used / 1GB
    }

    $engines = @{}
    foreach ($it in $q.Items('gpuEng', $true)) {
        if ([double]::IsNaN($it.Value)) { continue }
        $mm2 = [regex]::Match($it.Name, 'luid_(\S+?)_phys_\d+_eng_(\d+)_engtype_(\S+)$')
        if (-not $mm2.Success) { continue }
        $key = $mm2.Groups[1].Value + '|' + $mm2.Groups[2].Value + '|' + $mm2.Groups[3].Value
        if ($engines.ContainsKey($key)) { $engines[$key] += $it.Value } else { $engines[$key] = $it.Value }
    }
    $best = 0.0; $bestName = '-'
    foreach ($k in @($engines.Keys)) {
        if ($engines[$k] -gt $best) { $best = $engines[$k]; $bestName = ($k -split '\|')[2] }
    }
    $script:L.gpu = [math]::Min(100.0, $best)
    $m.GpuEngine = $bestName
    $vram = 0.0
    foreach ($it in $q.Items('gpuMem', $true)) { if (-not [double]::IsNaN($it.Value)) { $vram += $it.Value } }
    $script:L.vram = $vram / 1GB

    $idle = $q.Value('diskIdle', $true)
    if ([double]::IsNaN($idle)) { $idle = 100.0 }
    $script:L.disk = [math]::Min(100.0, [math]::Max(0.0, 100.0 - $idle))
    $rd = $q.Value('diskRd', $true); $wr = $q.Value('diskWr', $true)
    if ([double]::IsNaN($rd)) { $rd = 0.0 }; if ([double]::IsNaN($wr)) { $wr = 0.0 }
    $script:L.rd = $rd / 1MB
    $script:L.wr = $wr / 1MB

    $now = [DateTime]::UtcNow
    $cur = @{}
    $name = ''
    foreach ($nic in [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
        if ($nic.OperationalStatus -ne 'Up') { continue }
        $type = [string]$nic.NetworkInterfaceType
        if ($type -eq 'Loopback' -or $type -eq 'Tunnel' -or $type -eq 'Ppp') { continue }
        if ($nic.Description -match $script:NetVirtual) { continue }
        try {
            $st = $nic.GetIPStatistics()
            $cur[$nic.Id] = @{ Rx = [int64]$st.BytesReceived; Tx = [int64]$st.BytesSent }
            if (-not $name) { $name = $nic.Name }
        } catch { }
    }
    if ($m.LastNet -and $m.NetTime) {
        $dt = ($now - $m.NetTime).TotalSeconds
        if ($dt -gt 0.2) {
            $rx = 0.0; $tx = 0.0
            foreach ($id in @($cur.Keys)) {
                if ($m.LastNet.ContainsKey($id)) {
                    $d1 = $cur[$id].Rx - $m.LastNet[$id].Rx; if ($d1 -gt 0) { $rx += $d1 }
                    $d2 = $cur[$id].Tx - $m.LastNet[$id].Tx; if ($d2 -gt 0) { $tx += $d2 }
                }
            }
            $script:L.rx = $rx * 8.0 / 1000000.0 / $dt
            $script:L.tx = $tx * 8.0 / 1000000.0 / $dt
        }
    }
    $m.LastNet = $cur
    $m.NetTime = $now
    $m.NetName = $name

    if ($m.Tick % 5 -eq 1) { $m.Procs = @([System.Diagnostics.Process]::GetProcesses()).Count }

    Push-Series $script:H.cpu $script:L.cpu
    Push-Series $script:H.disk $script:L.disk
    Push-Series $script:H.rx $script:L.rx
    Push-Series $script:H.tx $script:L.tx

    if ($script:CurrentTab -eq 'home') {
        Update-ThreadBars
        Update-Spark $script:Ui.CpuSpark (, $script:H.cpu) 100.0
        Update-Spark $script:Ui.DiskSpark (, $script:H.disk) 100.0
        $peak = 5.0
        foreach ($v in $script:H.rx) { if ($v -gt $peak) { $peak = $v } }
        foreach ($v in $script:H.tx) { if ($v -gt $peak) { $peak = $v } }
        Update-Spark $script:Ui.NetSpark @($script:H.rx, $script:H.tx) ($peak * 1.1)
    }
}

function Set-StarBar {
    param($Grid, [double]$Pct)
    $p = [math]::Min(100.0, [math]::Max(0.0, $Pct))
    $Grid.ColumnDefinitions[0].Width = [System.Windows.GridLength]::new($p, [System.Windows.GridUnitType]::Star)
    $Grid.ColumnDefinitions[1].Width = [System.Windows.GridLength]::new((100.0 - $p), [System.Windows.GridUnitType]::Star)
}

function Update-MonitorNumbers {
    if ($script:CurrentTab -ne 'home') { return }
    $k = 0.3
    foreach ($key in @($script:D.Keys)) { $script:D[$key] += ($script:L[$key] - $script:D[$key]) * $k }
    $u = $script:Ui
    $D = $script:D
    $u.CpuVal.Text = [string][math]::Round($D.cpu)
    if ($script:L.mhz -gt 0) { $u.CpuSpeed.Text = ('{0:N2} GHz' -f ($script:L.mhz / 1000.0)) }
    $u.CpuProc.Text = [string]$script:Mon.Procs
    if ($script:Mon.Boot) {
        $up = (Get-Date) - $script:Mon.Boot
        $u.CpuUp.Text = ('{0}:{1:00}:{2:00}:{3:00}' -f [int][math]::Floor($up.TotalDays), $up.Hours, $up.Minutes, $up.Seconds)
    }
    $u.MemVal.Text = ('{0:N1}' -f $D.mem)
    if ($script:L.memTotal -gt 0) {
        $pct = $script:L.memUsed / $script:L.memTotal * 100.0
        $u.MemSub.Text = ('{0}% of {1:N0} GB in use' -f [int][math]::Round($pct), $script:L.memTotal)
        Set-StarBar $u.MemBar $pct
        $u.MemUsedText.Text = ('{0:N1} GB' -f $script:L.memUsed)
        $u.MemFreeText.Text = ('{0:N1} GB' -f ($script:L.memTotal - $script:L.memUsed))
    }
    $u.GpuVal.Text = ('{0}%' -f [int][math]::Round($D.gpu))
    $thick = 10.0
    $circ = [math]::PI * (108.0 - $thick) / $thick
    $len = [math]::Max(0.001, $D.gpu / 100.0 * $circ)
    $da = New-Object System.Windows.Media.DoubleCollection
    $da.Add($len); $da.Add($circ * 2.0)
    $u.GpuRing.StrokeDashArray = $da
    $u.GpuVram.Text = ('{0:N1} GB in use' -f $script:L.vram)
    $u.GpuEngine.Text = [string]$script:Mon.GpuEngine
    $u.DiskVal.Text = [string][int][math]::Round($D.disk)
    $u.DiskRead.Text = ('{0:N1} MB/s' -f $D.rd)
    $u.DiskWrite.Text = ('{0:N1} MB/s' -f $D.wr)
    Set-StarBar $u.DiskReadBar ($D.rd / 2.0)
    Set-StarBar $u.DiskWriteBar ($D.wr / 2.0)
    $u.NetDown.Text = ('{0:N1}' -f $D.rx)
    $u.NetUp.Text = ('{0:N1}' -f $D.tx)
    if ($script:Mon.NetName) { $u.NetName.Text = $script:Mon.NetName }
}

# ----------------------------------------------------------------------------
# Home entrance animation
# ----------------------------------------------------------------------------
$script:HomeSeen = $false
function Start-HomeEntrance {
    $quick = $script:HomeSeen
    $script:HomeSeen = $true
    $panel = $script:Ui.TitleLetters
    $panel.Children.Clear()
    $i = 0
    foreach ($ch in 'Compact Tweaks'.ToCharArray()) {
        $tb = New-Object System.Windows.Controls.TextBlock
        $tb.Text = [string]$ch
        $tb.FontSize = 52
        $tb.FontWeight = [System.Windows.FontWeight]::FromOpenTypeWeight(900)
        $tb.Foreground = New-Brush '#FFFFFF'
        $tt = New-Object System.Windows.Media.TranslateTransform
        $tt.Y = 34
        $tb.RenderTransform = $tt
        $tb.Opacity = 0
        [void]$panel.Children.Add($tb)
        if ($quick) { $delay = 20 * $i } else { $delay = 200 + 38 * $i }
        $tb.BeginAnimation([System.Windows.UIElement]::OpacityProperty, (New-Anim -To 1 -Ms 450 -Ease 'None' -DelayMs $delay))
        $tt.BeginAnimation([System.Windows.Media.TranslateTransform]::YProperty, (New-Anim -To 0 -Ms 650 -Ease 'Back' -DelayMs $delay))
        $i++
    }
    if ($quick) { $sd = 250 } else { $sd = 1000 }
    $script:Ui.Slogan.Opacity = 0
    $script:Ui.Slogan.BeginAnimation([System.Windows.UIElement]::OpacityProperty, (New-Anim -To 1 -Ms 600 -Ease 'None' -DelayMs $sd))
    $script:Ui.Slogan.RenderTransform.BeginAnimation([System.Windows.Media.TranslateTransform]::XProperty, (New-Anim -To 0 -Ms 700 -Ease 'Cubic' -From -18 -DelayMs $sd))
    $st = $script:Ui.HeroMark.RenderTransform
    $st.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleXProperty, (New-Anim -To 1 -Ms 700 -Ease 'Back' -From 0.4))
    $st.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleYProperty, (New-Anim -To 1 -Ms 700 -Ease 'Back' -From 0.4))
    $tiles = @($script:Ui.TileCpu, $script:Ui.TileMem, $script:Ui.TileGpu, $script:Ui.TileDisk, $script:Ui.TileNet)
    $j = 0
    foreach ($t in $tiles) {
        if (-not ($t.RenderTransform -is [System.Windows.Media.TranslateTransform])) { $t.RenderTransform = New-Object System.Windows.Media.TranslateTransform }
        $t.Opacity = 0
        if ($quick) { $d = 60 * $j } else { $d = 1500 + 90 * $j }
        $t.BeginAnimation([System.Windows.UIElement]::OpacityProperty, (New-Anim -To 1 -Ms 500 -Ease 'None' -From 0 -DelayMs $d))
        $t.RenderTransform.BeginAnimation([System.Windows.Media.TranslateTransform]::YProperty, (New-Anim -To 0 -Ms 650 -Ease 'Cubic' -From 26 -DelayMs $d))
        $j++
    }
}

# ----------------------------------------------------------------------------
# Wire up and start
# ----------------------------------------------------------------------------
$script:Ui.SysLine.Text = Get-SystemSummary
try {
    $script:Ui.IconCpu.Child = (New-Icon 'cpu' 19)
    $script:Ui.IconMem.Child = (New-Icon 'mem' 19)
    $script:Ui.IconGpu.Child = (New-Icon 'gpu' 19)
    $script:Ui.IconDisk.Child = (New-Icon 'disk' 19)
    $script:Ui.IconNet.Child = (New-Icon 'net' 19)
    foreach ($ic in @($script:Ui.IconCpu, $script:Ui.IconMem, $script:Ui.IconGpu, $script:Ui.IconDisk, $script:Ui.IconNet)) {
        $ic.Child.HorizontalAlignment = 'Center'; $ic.Child.VerticalAlignment = 'Center'
    }
    $script:Ui.CpuName.Text = ((Get-CimInstance Win32_Processor | Select-Object -First 1).Name).Trim()
    $pg = Get-PrimaryGpu
    if ($pg) { $script:Ui.GpuName.Text = [string]$pg.Name }
    $script:Ui.MemTotal.Text = ('{0} GB installed' -f [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB))
} catch { }

$script:Ui.BtnHomeRestore.Add_Click({
    $ok = New-RestorePoint
    if ($ok) { Show-Toast 'Restore point step finished. See the log for details.' } else { Show-Toast 'Could not create a restore point. See the log.' }
})
$script:Ui.BtnHomeBrowse.Add_Click({
    $choices = @($script:TabDefs | Where-Object { $_.Id -ne 'home' } | ForEach-Object { $_.Id })
    if ($choices.Count -gt 0) { Show-Page ($choices | Get-Random) }
})
$script:Ui.BtnHomeApplyAll.Add_Click({
    if (Get-IsLaptop) {
        [void][System.Windows.MessageBox]::Show('This PC is a laptop. To keep battery life and heat reasonable, Apply All only runs on desktops. The tweaks picked and checked as safe for a laptop are on the Laptop Optimizations tab; open it and apply from there.', 'Compact Tweaks', 'OK', 'Information')
        Show-Page 'laptop'
        return
    }
    $eligible = @($script:Tweaks | Where-Object { -not $_.OneShot -and $_.Risk -ne 'High' -and $_.Category -ne 'oc' })
    if ($eligible.Count -eq 0) { Show-Toast 'Nothing eligible to apply.'; return }
    foreach ($t in $script:Tweaks) { $r = $script:Rows[$t.Id]; if ($r) { $r.Check.IsChecked = $false } }
    foreach ($t in $eligible) { $r = $script:Rows[$t.Id]; if ($r) { $r.Check.IsChecked = $true } }
    Update-Count
    Write-Log ('Apply All selected {0} automatic, reversible tweak(s). High-risk security trade-offs and one-time actions were left out on purpose.' -f $eligible.Count)
    Invoke-Batch -Mode 'Apply'
})
$script:Ui.BtnRec.Add_Click({
    foreach ($t in $script:Tweaks) {
        $r = $script:Rows[$t.Id]
        if ($r -and $t.Category -eq $script:CurrentTab) { $r.Check.IsChecked = [bool]$t.Recommended }
    }
    Update-Count
})
$script:Ui.BtnClear.Add_Click({
    foreach ($t in $script:Tweaks) { $r = $script:Rows[$t.Id]; if ($r) { $r.Check.IsChecked = $false } }
    Update-Count
})
$script:Ui.BtnApply.Add_Click({ Invoke-Batch -Mode 'Apply' })
$script:Ui.BtnUndo.Add_Click({ Invoke-Batch -Mode 'Undo' })
$script:Ui.BtnLog.Add_Click({
    if ($script:Ui.LogPanel.Visibility -eq [System.Windows.Visibility]::Visible) { $script:Ui.LogPanel.Visibility = [System.Windows.Visibility]::Collapsed }
    else { $script:Ui.LogPanel.Visibility = [System.Windows.Visibility]::Visible; $script:Ui.LogBox.ScrollToEnd() }
})

# Title bar: dark, and black/red on Windows 11.
$script:Window.Add_SourceInitialized({
    try {
        if ($script:NativeOk) {
            $h = (New-Object System.Windows.Interop.WindowInteropHelper($script:Window)).Handle
            [void][CT.Sys]::SetDwm($h, 20, 1)
            if ((Get-WinBuild) -ge 22000) {
                [void][CT.Sys]::SetDwm($h, 35, 0x0004030B)
                [void][CT.Sys]::SetDwm($h, 36, 0x00FFFFFF)
                [void][CT.Sys]::SetDwm($h, 34, 0x0004030B)
            }
        }
    } catch { }
})

$script:Ui.Bar.Visibility = [System.Windows.Visibility]::Collapsed
$script:Started = $false

# Spin the splash ring right away; this costs almost nothing and the window paints it immediately.
$spin = New-Object System.Windows.Media.Animation.DoubleAnimation
$spin.From = 0; $spin.To = 360; $spin.Duration = [TimeSpan]::FromMilliseconds(900)
$spin.RepeatBehavior = [System.Windows.Media.Animation.RepeatBehavior]::Forever
$script:Ui.SplashRing.RenderTransform.BeginAnimation([System.Windows.Media.RotateTransform]::AngleProperty, $spin)

function Hide-Splash {
    $fade = New-Anim -To 0 -Ms 380 -Ease 'None'
    $fade.Add_Completed({ $script:Ui.Splash.Visibility = [System.Windows.Visibility]::Collapsed })
    $script:Ui.Splash.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $fade)
}

function Initialize-CompactTweaksApp {
    # Runs after the window (with the splash on top of it) has already painted, so the app feels
    # like it opens immediately instead of sitting blank while all of this builds.
    Build-Nav
    Build-Pages
    Update-Statuses
    Initialize-Monitor

    foreach ($glow in @($script:Ui.GlowA, $script:Ui.GlowB)) {
        $ax = New-Anim -To 70 -Ms 24000 -Ease 'None'
        $ax.AutoReverse = $true
        $ax.RepeatBehavior = [System.Windows.Media.Animation.RepeatBehavior]::Forever
        $ay = New-Anim -To 40 -Ms 31000 -Ease 'None'
        $ay.AutoReverse = $true
        $ay.RepeatBehavior = [System.Windows.Media.Animation.RepeatBehavior]::Forever
        $glow.RenderTransform.BeginAnimation([System.Windows.Media.TranslateTransform]::XProperty, $ax)
        $glow.RenderTransform.BeginAnimation([System.Windows.Media.TranslateTransform]::YProperty, $ay)
    }

    $script:MonTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:MonTimer.Interval = [TimeSpan]::FromMilliseconds(1000)
    $script:MonTimer.Add_Tick({
        try { Invoke-MonitorTick } catch { if (-not $script:Mon.Err) { $script:Mon.Err = $true; Write-Log ('Monitor: ' + $_.Exception.Message) 'Warn' } }
    })
    $script:NumTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:NumTimer.Interval = [TimeSpan]::FromMilliseconds(100)
    $script:NumTimer.Add_Tick({
        try { Update-MonitorNumbers } catch { if (-not $script:Mon.Err) { $script:Mon.Err = $true; Write-Log ('Monitor: ' + $_.Exception.Message) 'Warn' } }
    })
    $script:Window.Add_Closing({
        try {
            $script:MonTimer.Stop(); $script:NumTimer.Stop()
            if ($script:Mon.Q) { $script:Mon.Q.Dispose() }
        } catch { }
    })

    Show-Page 'home'
    Start-HomeEntrance
    $script:MonTimer.Start()
    $script:NumTimer.Start()
    Hide-Splash

    Write-Log ("Compact Tweaks v{0} ready. Undo data and log: {1}" -f $script:Version, $script:DataDir)
    $nApplied = @($script:States.Values | Where-Object { $_ -eq 'Applied' }).Count
    $nAlready = @($script:States.Values | Where-Object { $_ -eq 'AlreadySet' }).Count
    Write-Log ("Status: {0} applied by Compact Tweaks earlier, {1} already set on this PC by Windows or another tool." -f $nApplied, $nAlready)
    Write-Log ('Font in use: ' + $script:FontPick + '. For the closest match to the design, install Inter or SF Pro.')
    if (-not $script:NativeOk) { Write-Log ('Native helper failed to compile: ' + $script:NativeError) 'Warn' }
    try {
        $consoleUser = (Get-CimInstance Win32_ComputerSystem).UserName
        if ($consoleUser -and (($consoleUser -split '\\')[-1] -ne $env:USERNAME)) {
            Write-Log ("You are signed in as {0} but running as {1}. Per-user tweaks (HKCU) would change the ADMIN account, not yours. Re-run from the account you actually use." -f $consoleUser, $env:USERNAME) 'Warn'
        }
    } catch { }
}

$script:Window.Add_ContentRendered({
    if (-not $script:Started) {
        $script:Started = $true
        $script:Window.Dispatcher.BeginInvoke([System.Action]{ Initialize-CompactTweaksApp }, [System.Windows.Threading.DispatcherPriority]::Background) | Out-Null
    }
})

[void]$script:Window.ShowDialog()
