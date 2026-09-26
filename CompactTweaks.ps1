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

$script:Version = '0.5.0'
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
           Caches = @((Join-Path $la 'Spotify\Data'), (Join-Path $la 'Spotify\Browser')) }
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
       Desc = 'Sets SystemResponsiveness = 10 and raises the Games scheduling class. Microsoft documents GPU Priority and SFIO Priority as unused by modern schedulers, values below 10 are clamped, and Fortnite does not register with this scheduler at all, so expect no change. Included because you asked; fully reversible.'
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
       Desc = 'Uses a Microsoft documented switch (FeatureSettingsOverride) to turn off the Spectre variant 2 and Meltdown workarounds. The measured gain is roughly zero on modern CPUs, the security loss is real, and some anti-cheats refuse to run with it off. I included it because you asked, but my recommendation is to skip it. It does NOT touch DEP, ASLR or Exploit Protection.'
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
       Desc = 'Possibly slightly worse than leaving it alone. Sets NetworkThrottlingIndex to off and removes the QoS reserved-bandwidth limit. The throttle only limits non-multimedia traffic far above what a game sends, and independent testing has found network driver latency going up when it is removed. Included because you asked; fully reversible.'
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
       Desc = 'Guided for now: opens the NVIDIA Control Panel so you can set the values listed further down this page. Changing these driver profile settings automatically needs NVIDIA setting ids that I could not verify without a test PC, and I did not want to guess and write wrong values into your driver.'
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
       Desc = 'Turns off Structured Exception Handling Overwrite Protection, a Microsoft-documented exploit mitigation, separate from the Spectre/Meltdown tweak above. Essentially no measurable performance gain on modern CPUs, so this is included for completeness rather than because I recommend it.'
       Restart = 'restart'
       Registry = @( (New-RegEntry 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\kernel' 'DisableExceptionChainValidation' 'DWord' 1) ) },

    # ============================ NEW: DEBLOATING (process/startup trimming) ============================
    @{ Id = 'trim-updaters'; IsLaptopSafe = $true; Category = 'debloat'; Group = 'Trim background services and startup'; Name = 'Turn off third-party updater and elevation services'; Risk = 'Medium'; Recommended = $false
       Desc = 'The same idea as unticking non-Microsoft updater services in System Configuration (msconfig): finds non-Microsoft services whose name looks like an updater or elevation helper and sets them to Manual (not Disabled), so they stop starting automatically but nothing is removed. Logitech G HUB'"'"'s updater is always left alone because turning it off breaks G HUB. Undo restores each service'"'"'s original start mode.'
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
       Desc = 'The same idea as Autoruns'"'"'s Logon tab: goes through your Run/RunOnce startup entries and disables every one except entries that launch cmd.exe, using the same StartupApproved flag Task Manager'"'"'s Startup tab uses, so disabled apps show as Disabled there too and nothing is deleted. Undo re-enables everything this turned off.'
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
       Desc = 'Sets your NVIDIA driver'"'"'s PowerMizer to Prefer Maximum Performance at the driver level, the same effect as the NVIDIA Control Panel setting further down this page, but applied directly. Stops the GPU clocking down between frames. On a laptop this uses noticeably more power and heat, so it is not recommended there. A restore point is made first; undo restores the previous values.'
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
           if ($n -eq 0) { throw 'Could not find the NVIDIA driver'"'"'s registry entry to change.' }
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
       Apply = { Invoke-DiagCommand 'Component Cleanup' 'dism.exe' @('/Online', '/Cleanup-Image', '/StartComponentCleanup') } }
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
    @{ Id = 'oc';      Label = 'OC';                   Sub = 'Overclocking'; Icon = 'oc'; Title = 'Overclocking'; Desc = 'Step-by-step, safe overclocking for your CPU, GPU and RAM.'; Sections = $script:OcSections; Note = 'These are general guides, not guarantees. Check your own CPU, GPU and RAM maker for exact limits, and stop the moment anything looks unstable or too hot.' },
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
        <GradientStop Color="#A50F1B" Offset="0"/>
        <GradientStop Color="#6A0A13" Offset="0.36"/>
        <GradientStop Color="#33070D" Offset="0.68"/>
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
      <Border Grid.Column="0" Background="#E8000000" BorderBrush="#26FFFFFF" BorderThickness="0,0,1,0">
        <Grid>
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
          </Grid.RowDefinitions>
          <StackPanel Grid.Row="0" Orientation="Horizontal" Margin="20,22,20,14">
            <Border Width="40" Height="40" CornerRadius="13" Background="White">
              <Viewbox Width="22" Height="22">
                <Canvas Width="24" Height="24"><Path Data="M13,2 L4,14 H10 L9,22 L18,10 H12 Z" Fill="#A10D18"/></Canvas>
              </Viewbox>
            </Border>
            <StackPanel Margin="12,0,0,0" VerticalAlignment="Center">
              <TextBlock Text="Compact Tweaks" FontSize="17" FontWeight="ExtraBold"/>
              <TextBlock x:Name="VersionText" Text="v0.4.0" FontSize="12" FontWeight="SemiBold" Foreground="{StaticResource Faint}"/>
            </StackPanel>
          </StackPanel>
          <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled" Margin="12,6,6,6">
            <Grid Margin="0,0,6,0">
              <Border x:Name="NavPill" Height="42" VerticalAlignment="Top" CornerRadius="12" Background="#3DFFFFFF" BorderBrush="#66FFFFFF" BorderThickness="1">
                <Border.RenderTransform><TranslateTransform/></Border.RenderTransform>
                <Border Width="3" Height="18" HorizontalAlignment="Left" Margin="7,0,0,0" CornerRadius="2" Background="White"/>
              </Border>
              <StackPanel x:Name="NavList"/>
            </Grid>
          </ScrollViewer>
          <StackPanel Grid.Row="2" Margin="20,12,20,18">
            <StackPanel Orientation="Horizontal">
              <Ellipse Width="8" Height="8" Fill="White" VerticalAlignment="Center"/>
              <TextBlock Text="Running as administrator" Margin="10,0,0,0" FontSize="12.5" FontWeight="SemiBold" Foreground="{StaticResource Muted}"/>
            </StackPanel>
            <TextBlock x:Name="SideNote" Text="" Margin="18,6,0,0" FontSize="12" FontWeight="SemiBold" Foreground="{StaticResource Faint}" TextWrapping="Wrap"/>
          </StackPanel>
        </Grid>
      </Border>

      <!-- Main area -->
      <Grid Grid.Column="1">
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
  </Grid>
</Window>
'@

$script:Window = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader ([xml]$xaml)))
$uiNames = @(
    'VersionText', 'NavPill', 'NavList', 'SideNote', 'PageHost', 'HomePage', 'HeroMark', 'TitleLetters', 'Slogan', 'SysLine',
    'BtnHomeRestore', 'BtnHomeBrowse', 'TileCpu', 'IconCpu', 'CpuName', 'CpuVal', 'CpuSpeed', 'CpuProc', 'CpuLogical', 'CpuUp',
    'CpuSpark', 'ThreadBars', 'TileMem', 'IconMem', 'MemTotal', 'MemVal', 'MemSub', 'MemBar', 'MemUsedText', 'MemFreeText',
    'TileGpu', 'IconGpu', 'GpuName', 'GpuRing', 'GpuVal', 'GpuVram', 'GpuEngine', 'TileDisk', 'IconDisk', 'DiskVal', 'DiskSpark',
    'DiskReadBar', 'DiskRead', 'DiskWriteBar', 'DiskWrite', 'TileNet', 'IconNet', 'NetName', 'NetDown', 'NetUp', 'NetSpark',
    'ChipApplied', 'MonitorNote', 'Toast', 'ToastText', 'LogPanel', 'LogBox', 'Bar', 'CountText', 'ChkRestore',
    'BtnLog', 'BtnRec', 'BtnClear', 'BtnUndo', 'BtnApply', 'GlowA', 'GlowB'
)
foreach ($n in $uiNames) { $script:Ui[$n] = $script:Window.FindName($n) }

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
    $p.StrokeThickness = 1.9
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

    if ($script:TabHasRows.ContainsKey($Id) -and $script:TabHasRows[$Id]) { $script:Ui.Bar.Visibility = [System.Windows.Visibility]::Visible }
    else { $script:Ui.Bar.Visibility = [System.Windows.Visibility]::Collapsed }
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
$script:Ui.VersionText.Text = 'v' + $script:Version
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

Build-Nav
Build-Pages
Update-Statuses
Initialize-Monitor

# Slow ambient glow in the background.
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

# Show Home last so the entrance animation plays on a fully built window.
$script:Window.Add_ContentRendered({
    if (-not $script:Started) {
        $script:Started = $true
        Show-Page 'home'
        Start-HomeEntrance
        $script:MonTimer.Start()
        $script:NumTimer.Start()
    }
})
$script:Started = $false
$script:Ui.Bar.Visibility = [System.Windows.Visibility]::Collapsed

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

[void]$script:Window.ShowDialog()
