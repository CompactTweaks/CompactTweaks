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

$script:Version = '0.7.0'
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
       Desc = 'Sets the active power plan processor boost policy (PERFBOOSTPOLICY) to its most aggressive value, so the CPU is quicker to jump to a higher clock under load. This applies to whichever power plan is active right now, so apply it after choosing your plan. Undo restores the previous value.'
       Apply = {
           $scheme = Get-ActiveSchemeGuid
           if (-not $scheme) { throw 'Could not read the active power plan.' }
           $ac = (& powercfg.exe /q $scheme SUB_PROCESSOR PERFBOOSTPOLICY | Out-String)
           $prevAc = 0; $m = [regex]::Match($ac, '(?m)Current AC Power Setting Index:\s*0x([0-9a-fA-F]+)'); if ($m.Success) { $prevAc = [Convert]::ToInt32($m.Groups[1].Value, 16) }
           $prevDc = 0; $m2 = [regex]::Match($ac, '(?m)Current DC Power Setting Index:\s*0x([0-9a-fA-F]+)'); if ($m2.Success) { $prevDc = [Convert]::ToInt32($m2.Groups[1].Value, 16) }
           & powercfg.exe /setacvalueindex $scheme SUB_PROCESSOR PERFBOOSTPOLICY 100 | Out-Null
           & powercfg.exe /setdcvalueindex $scheme SUB_PROCESSOR PERFBOOSTPOLICY 100 | Out-Null
           & powercfg.exe /setactive $scheme | Out-Null
           return @{ Scheme = $scheme; PrevAc = $prevAc; PrevDc = $prevDc }
       }
       Undo = {
           param($D)
           & powercfg.exe /setacvalueindex ([string]$D.Scheme) SUB_PROCESSOR PERFBOOSTPOLICY ([string][int]$D.PrevAc) | Out-Null
           & powercfg.exe /setdcvalueindex ([string]$D.Scheme) SUB_PROCESSOR PERFBOOSTPOLICY ([string][int]$D.PrevDc) | Out-Null
           & powercfg.exe /setactive ([string]$D.Scheme) | Out-Null
       }
       Test = {
           $scheme = Get-ActiveSchemeGuid
           if (-not $scheme) { return $false }
           $out = (& powercfg.exe /q $scheme SUB_PROCESSOR PERFBOOSTPOLICY | Out-String)
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

    # ================================ GPU OPTIMIZATIONS ================================
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
           $m = [regex]::Match($prev, '(\\d+)')
           if ($m.Success) { $prevVal = [int]$m.Groups[1].Value }
           & fsutil.exe behavior set disabledeletenotify 0 | Out-Null
           return @{ Prev = $prevVal }
       }
       Undo = { param($D) & fsutil.exe behavior set disabledeletenotify ([int]$D.Prev) | Out-Null }
       Test = {
           $out = (& fsutil.exe behavior query disabledeletenotify 2>&1 | Out-String)
           return [bool]($out -match '=\\s*0',
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
           $found = @(Get-ScheduledTask -TaskName 'NvTmRep_CrashReport*' -ErrorAction SilentlyContinue | ForEach-Object { $_.TaskPath.TrimEnd('\') + '\' + $_.TaskName })
           if ($found.Count -eq 0) { throw 'No NVIDIA crash-report tasks were found on this PC.' }
           $touched = Disable-ScheduledTaskList $found
           return @{ Tasks = $touched }
       }
       Undo = { param($D) Enable-ScheduledTaskList @($D.Tasks) }
       Test = { return $script:State.ContainsKey('nv-crashreport-tasks-off') } }
)
       } }
)

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
$script:CompactLogoBase64 = @'
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
'@

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
          <LinearGradientBrush StartPoint="0,0" EndPoint="0.75,1">
            <GradientStop Color="#900812" Offset="0"/>
            <GradientStop Color="#650710" Offset="0.38"/>
            <GradientStop Color="#36050A" Offset="0.72"/>
            <GradientStop Color="#0D0204" Offset="1"/>
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
                <Border x:Name="HeroMark" Width="92" Height="92" CornerRadius="22" Background="#16000000"
                        BorderBrush="#66FF1724" BorderThickness="1" ClipToBounds="True"
                        RenderTransformOrigin="0.5,0.5">
                  <Border.RenderTransform><ScaleTransform ScaleX="1" ScaleY="1"/></Border.RenderTransform>
                  <Image x:Name="HeroLogo" Stretch="UniformToFill"/>
                </Border>
                <StackPanel Margin="22,0,0,0" VerticalAlignment="Center">
                  <StackPanel x:Name="TitleLetters" Orientation="Horizontal"/>
                  <TextBlock x:Name="Slogan" Text="STAY COMPACT, STAY FAST" FontFamily="Bahnschrift SemiCondensed" FontSize="20" FontWeight="SemiBold" FontStyle="Italic" Margin="0,7,0,0">
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
    'NavPill', 'NavList', 'SidebarBackground', 'SideNote', 'PageHost', 'HomePage', 'HeroMark', 'HeroLogo', 'TitleLetters', 'Slogan', 'SysLine',
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

# Load Compact Tweaks branding image for the home mark and window/taskbar icon.
try {
    $logoBytes = [Convert]::FromBase64String(($script:CompactLogoBase64 -replace '\s',''))
    $logoMs = New-Object System.IO.MemoryStream(,$logoBytes)
    try {
        $logoBmp = New-Object System.Windows.Media.Imaging.BitmapImage
        $logoBmp.BeginInit()
        $logoBmp.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
        $logoBmp.StreamSource = $logoMs
        $logoBmp.EndInit()
        $logoBmp.Freeze()
        $script:Ui.HeroLogo.Source = $logoBmp
        $script:Window.Icon = $logoBmp
    } finally {
        $logoMs.Dispose()
    }
} catch {
    Write-Log ('Compact Tweaks logo failed to load: ' + $_.Exception.Message) 'Warn'
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
        $tb.FontFamily = New-Object System.Windows.Media.FontFamily('Bahnschrift SemiCondensed')
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
