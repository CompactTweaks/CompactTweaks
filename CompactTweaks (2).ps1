<#
    Compact Tweaks  -  small, reversible Windows tweaks.

    Run:  irm https://raw.githubusercontent.com/CompactTweaks/CompactTweaks/main/CompactTweaks.ps1 | iex

    Design rules
      1. Every change is snapshotted first, so "Undo" restores the exact previous state.
      2. Nothing is deleted from the system except temp files / recycle bin (clearly marked "one-time").
      3. A System Restore point is offered before every batch.
      4. Only well-understood tweaks. No registry "cleaners", no service-disabling shotgun.

    Keep this file ASCII-only so Windows PowerShell 5.1 reads it correctly.
#>

$script:Version = '0.1.1'
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
# Paths, logging, state
# ----------------------------------------------------------------------------
$script:DataDir   = Join-Path $env:ProgramData 'CompactTweaks'
$script:StateFile = Join-Path $script:DataDir 'state.json'
$script:LogFile   = Join-Path $script:DataDir 'compacttweaks.log'
if (-not (Test-Path -LiteralPath $script:DataDir)) { New-Item -ItemType Directory -Path $script:DataDir -Force | Out-Null }

$script:Window      = $null
$script:Ui          = @{}
$script:Rows        = @{}
$script:NeedRestart = $false

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
    $script:State | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $script:StateFile -Encoding UTF8
}

$script:State = Import-State

# ----------------------------------------------------------------------------
# Registry / service / power helpers
# ----------------------------------------------------------------------------
function New-RegEntry {
    param([string]$Path, [string]$Name, [string]$Type, $Value)
    return @{ Path = $Path; Name = $Name; Type = $Type; Value = $Value }
}

function Get-RegSnapshot {
    param([string]$Path, [string]$Name)
    $snap = @{ Path = $Path; Name = $Name; Existed = $false; Kind = $null; Value = $null }
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
    }
}

function Get-SvcSnapshot {
    param([string]$Name)
    $s = Get-CimInstance Win32_Service -Filter "Name='$Name'" -ErrorAction SilentlyContinue
    if (-not $s) { return @{ Name = $Name; Exists = $false } }
    return @{
        Name       = $Name
        Exists     = $true
        Mode       = [string]$s.StartMode          # Auto | Manual | Disabled
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

# ----------------------------------------------------------------------------
# Tweak catalog
#   Registry : list of registry values to set (snapshotted automatically)
#   Services : list of @{Name; Mode} start-mode changes (snapshotted automatically)
#   Apply/Undo/Test : optional scriptblocks for things that are not plain registry values
#   OneShot  : action with no undo (cleanup)
# ----------------------------------------------------------------------------
$script:Tweaks = @(

    # ---------------- Performance ----------------
    @{ Id = 'startup-delay'; Category = 'Performance'; Name = 'Remove startup app delay'; Risk = 'Low'; Recommended = $true
       Desc = 'Windows waits several seconds after sign-in before launching your startup apps. This removes the wait so the desktop is ready sooner.'
       Restart = 'sign-out'
       Registry = @( (New-RegEntry 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Serialize' 'StartupDelayInMSec' 'DWord' 0) ) },

    @{ Id = 'menu-delay'; Category = 'Performance'; Name = 'Instant menu popups'; Risk = 'Low'; Recommended = $true
       Desc = 'Sets the delay before menus open to zero, so right-click and submenus feel snappier.'
       Restart = 'sign-out'
       Registry = @( (New-RegEntry 'HKCU:\Control Panel\Desktop' 'MenuShowDelay' 'String' '0') ) },

    @{ Id = 'animations'; Category = 'Performance'; Name = 'Reduce window animations'; Risk = 'Low'; Recommended = $false
       Desc = 'Turns off minimize/maximize and taskbar animations. Cosmetic, but it can feel faster on older hardware.'
       Restart = 'sign-out'
       Registry = @(
           (New-RegEntry 'HKCU:\Control Panel\Desktop\WindowMetrics' 'MinAnimate' 'String' '0'),
           (New-RegEntry 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'TaskbarAnimations' 'DWord' 0)
       ) },

    @{ Id = 'transparency'; Category = 'Performance'; Name = 'Turn off transparency effects'; Risk = 'Low'; Recommended = $false
       Desc = 'Disables the blur/transparency on the taskbar, Start and windows. Saves a little GPU work, mostly on weak graphics.'
       Registry = @( (New-RegEntry 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' 'EnableTransparency' 'DWord' 0) ) },

    @{ Id = 'faster-shutdown'; Category = 'Performance'; Name = 'Faster app shutdown'; Risk = 'Medium'; Recommended = $false
       Desc = 'Shortens how long Windows waits for apps to close before forcing them. Apps that are slow to save may lose unsaved data on shutdown.'
       Restart = 'sign-out'
       Registry = @(
           (New-RegEntry 'HKCU:\Control Panel\Desktop' 'WaitToKillAppTimeout' 'String' '2000'),
           (New-RegEntry 'HKCU:\Control Panel\Desktop' 'HungAppTimeout' 'String' '2000')
       ) },

    @{ Id = 'powerplan'; Category = 'Performance'; Name = 'Compact Ultimate Power Plan'; Risk = 'Medium'; Recommended = $false
       Desc = 'Creates and activates the Compact Ultimate Power Plan, a copy of Windows Ultimate Performance (High Performance if Ultimate is unavailable) that never throttles the CPU. Best on desktops; on a laptop it costs battery life and adds heat. Undo switches back to your previous plan and deletes the new one.'
       Apply = {
           $prev = Get-ActiveSchemeGuid
           $new  = $null
           foreach ($src in @('e9a42b02-d5df-448d-aa00-03f14749eb61', '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c')) {
               $out = (& powercfg.exe -duplicatescheme $src 2>&1 | Out-String)
               if ($LASTEXITCODE -eq 0 -and $out -match '([0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12})') { $new = $Matches[1]; break }
           }
           if (-not $new) { throw 'This PC does not allow a high-performance power scheme to be created.' }
           & powercfg.exe /changename $new 'Compact Ultimate Power Plan' 'Created by Compact Tweaks' | Out-Null
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

    # ---------------- Gaming ----------------
    @{ Id = 'game-mode'; Category = 'Gaming'; Name = 'Enable Game Mode'; Risk = 'Low'; Recommended = $true
       Desc = 'Tells Windows to prioritise the game you are playing and hold back background updates and driver installs while it runs.'
       Registry = @(
           (New-RegEntry 'HKCU:\Software\Microsoft\GameBar' 'AutoGameModeEnabled' 'DWord' 1),
           (New-RegEntry 'HKCU:\Software\Microsoft\GameBar' 'AllowAutoGameMode' 'DWord' 1)
       ) },

    @{ Id = 'game-dvr'; Category = 'Gaming'; Name = 'Turn off Xbox Game Bar background capture'; Risk = 'Low'; Recommended = $true
       Desc = 'Stops Game DVR from recording in the background. Removes a small performance and stutter cost; you can still capture manually with other tools.'
       Registry = @(
           (New-RegEntry 'HKCU:\System\GameConfigStore' 'GameDVR_Enabled' 'DWord' 0),
           (New-RegEntry 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR' 'AppCaptureEnabled' 'DWord' 0)
       ) },

    @{ Id = 'hags'; Category = 'Gaming'; Name = 'Hardware-accelerated GPU scheduling'; Risk = 'Medium'; Recommended = $false
       Desc = 'Lets the GPU manage its own memory scheduling. Helps some setups (and frame generation), hurts others, and needs a recent GPU and driver. Test it with your games and undo if anything gets worse.'
       Restart = 'restart'
       Registry = @( (New-RegEntry 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' 'HwSchMode' 'DWord' 2) ) },

    @{ Id = 'mouse-accel'; Category = 'Gaming'; Name = 'Turn off mouse acceleration'; Risk = 'Low'; Recommended = $false
       Desc = 'Disables "Enhance pointer precision" so mouse movement is 1:1 and consistent, which most shooters prefer. Your desktop mouse will feel different for a day or two.'
       Restart = 'sign-out'
       Registry = @(
           (New-RegEntry 'HKCU:\Control Panel\Mouse' 'MouseSpeed' 'String' '0'),
           (New-RegEntry 'HKCU:\Control Panel\Mouse' 'MouseThreshold1' 'String' '0'),
           (New-RegEntry 'HKCU:\Control Panel\Mouse' 'MouseThreshold2' 'String' '0')
       ) },

    # ---------------- Privacy ----------------
    @{ Id = 'ad-id'; Category = 'Privacy'; Name = 'Turn off advertising ID'; Risk = 'Low'; Recommended = $true
       Desc = 'Stops apps from using a per-user ID to show you targeted ads.'
       Registry = @( (New-RegEntry 'HKCU:\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo' 'Enabled' 'DWord' 0) ) },

    @{ Id = 'tailored'; Category = 'Privacy'; Name = 'Turn off tailored experiences'; Risk = 'Low'; Recommended = $true
       Desc = 'Stops Windows from using your diagnostic data to personalise tips, ads and recommendations.'
       Registry = @( (New-RegEntry 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Privacy' 'TailoredExperiencesWithDiagnosticDataEnabled' 'DWord' 0) ) },

    @{ Id = 'suggestions'; Category = 'Privacy'; Name = 'Remove Start menu suggestions and promoted apps'; Risk = 'Low'; Recommended = $true
       Desc = 'Stops Windows from suggesting apps and silently installing promoted ones (the pre-installed game and app spam).'
       Registry = @(
           (New-RegEntry 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SubscribedContent-338388Enabled' 'DWord' 0),
           (New-RegEntry 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SubscribedContent-338389Enabled' 'DWord' 0),
           (New-RegEntry 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SubscribedContent-353694Enabled' 'DWord' 0),
           (New-RegEntry 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SubscribedContent-353696Enabled' 'DWord' 0),
           (New-RegEntry 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SystemPaneSuggestionsEnabled' 'DWord' 0),
           (New-RegEntry 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SilentInstalledAppsEnabled' 'DWord' 0)
       ) },

    @{ Id = 'bing-search'; Category = 'Privacy'; Name = 'Turn off web results in Start search'; Risk = 'Low'; Recommended = $true
       Desc = 'Start search stays local (apps, files, settings) and stops sending what you type to Bing.'
       Restart = 'sign-out'
       Registry = @( (New-RegEntry 'HKCU:\Software\Policies\Microsoft\Windows\Explorer' 'DisableSearchBoxSuggestions' 'DWord' 1) ) },

    @{ Id = 'telemetry-policy'; Category = 'Privacy'; Name = 'Set diagnostic data to the minimum'; Risk = 'Low'; Recommended = $true
       Desc = 'Sets the telemetry policy to its lowest level. On Windows Home and Pro the floor is "Required" data; only Enterprise and Education can go fully to zero.'
       Registry = @( (New-RegEntry 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' 'AllowTelemetry' 'DWord' 0) ) },

    @{ Id = 'diagtrack'; Category = 'Privacy'; Name = 'Disable the telemetry service (DiagTrack)'; Risk = 'Medium'; Recommended = $false
       Desc = 'Stops and disables "Connected User Experiences and Telemetry". Some Windows feedback and diagnostic features stop reporting. Undo restores the original start mode.'
       Services = @( @{ Name = 'DiagTrack'; Mode = 'Disabled' } ) },

    # ---------------- Cleanup (one-time, no undo) ----------------
    @{ Id = 'clean-temp'; Category = 'Cleanup'; Name = 'Delete old temporary files'; Risk = 'Low'; Recommended = $false; OneShot = $true
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

    @{ Id = 'clean-recycle'; Category = 'Cleanup'; Name = 'Empty the Recycle Bin'; Risk = 'Low'; Recommended = $false; OneShot = $true
       Desc = 'Permanently empties the Recycle Bin on all drives. This cannot be undone.'
       Apply = {
           try { Clear-RecycleBin -Force -ErrorAction Stop; Write-Log 'Recycle Bin emptied' 'Ok' }
           catch { Write-Log ('Recycle Bin: ' + $_.Exception.Message) 'Warn' }
       } }
)

# ----------------------------------------------------------------------------
# Engine: status, apply, undo
# ----------------------------------------------------------------------------
function Test-TweakMatches {
    param($T)
    if ($T.OneShot) { return $null }
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
    # AlreadySet = values match, but Compact Tweaks did not set them (Windows default or another tool)
    # NotApplied = values do not match
    # OneShot    = cleanup action, no persistent state
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
# GUI
# ----------------------------------------------------------------------------
$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Compact Tweaks" Width="860" Height="720" MinWidth="720" MinHeight="580"
        WindowStartupLocation="CenterScreen" Background="#111318" Foreground="#E8EAED"
        FontFamily="Segoe UI" FontSize="13">
  <Window.Resources>
    <Style TargetType="Button">
      <Setter Property="Foreground" Value="#E8EAED"/>
      <Setter Property="Background" Value="#262B33"/>
      <Setter Property="Padding" Value="14,7"/>
      <Setter Property="Margin" Value="0,0,8,0"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bd" Background="{TemplateBinding Background}" CornerRadius="6" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="bd" Property="Opacity" Value="0.85"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter TargetName="bd" Property="Opacity" Value="0.4"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="Primary" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
      <Setter Property="Background" Value="#3B82F6"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
    </Style>
    <Style TargetType="CheckBox">
      <Setter Property="Foreground" Value="#E8EAED"/>
      <Setter Property="VerticalContentAlignment" Value="Center"/>
    </Style>
  </Window.Resources>

  <Grid Margin="18">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="120"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>

    <StackPanel Grid.Row="0" Margin="0,0,0,12">
      <TextBlock Text="Compact Tweaks" FontSize="24" FontWeight="Bold"/>
      <TextBlock x:Name="SysInfo" Foreground="#8B93A1" Margin="0,2,0,0" TextWrapping="Wrap"/>
    </StackPanel>

    <WrapPanel Grid.Row="1" Margin="0,0,0,10">
      <Button x:Name="BtnRecommended" Content="Select recommended"/>
      <Button x:Name="BtnNone" Content="Clear selection"/>
      <Button x:Name="BtnRestorePoint" Content="Create restore point"/>
      <CheckBox x:Name="ChkRestore" Content="Create a restore point before applying" IsChecked="True" Margin="8,0,0,0" VerticalAlignment="Center"/>
    </WrapPanel>

    <Border Grid.Row="2" Background="#171A20" CornerRadius="8">
      <ScrollViewer VerticalScrollBarVisibility="Auto">
        <StackPanel x:Name="TweakPanel" Margin="0,4,0,10"/>
      </ScrollViewer>
    </Border>

    <Border Grid.Row="3" Background="#171A20" CornerRadius="8" Padding="12,10" Margin="0,10,0,10" MinHeight="58">
      <TextBlock x:Name="DescText" TextWrapping="Wrap" Foreground="#B8C0CC" Text="Hover over a tweak to see what it does."/>
    </Border>

    <TextBox Grid.Row="4" x:Name="LogBox" IsReadOnly="True" VerticalScrollBarVisibility="Auto" TextWrapping="Wrap"
             Background="#0C0E12" Foreground="#B8C0CC" FontFamily="Consolas" FontSize="12" BorderThickness="0" Padding="8"/>

    <StackPanel Grid.Row="5" Orientation="Horizontal" Margin="0,12,0,0">
      <Button x:Name="BtnApply" Content="Apply selected" Style="{StaticResource Primary}"/>
      <Button x:Name="BtnUndo" Content="Undo selected"/>
      <Button x:Name="BtnLog" Content="Open log file"/>
    </StackPanel>
  </Grid>
</Window>
'@

$script:Window = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader ([xml]$xaml)))
foreach ($n in 'SysInfo', 'TweakPanel', 'DescText', 'LogBox', 'BtnRecommended', 'BtnNone', 'BtnRestorePoint', 'ChkRestore', 'BtnApply', 'BtnUndo', 'BtnLog') {
    $script:Ui[$n] = $script:Window.FindName($n)
}
$script:Buttons = @($script:Ui.BtnRecommended, $script:Ui.BtnNone, $script:Ui.BtnRestorePoint, $script:Ui.BtnApply, $script:Ui.BtnUndo)

$script:Conv = New-Object System.Windows.Media.BrushConverter
function New-Brush { param([string]$Hex) return $script:Conv.ConvertFromString($Hex) }

function Get-SystemSummary {
    try {
        $os     = ((Get-CimInstance Win32_OperatingSystem).Caption) -replace 'Microsoft ', ''
        $cpu    = ((Get-CimInstance Win32_Processor | Select-Object -First 1).Name).Trim()
        $ram    = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB)
        $laptop = [bool](Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue)
        if ($laptop) { $kind = 'Laptop' } else { $kind = 'Desktop' }
        return ('{0}   |   {1}   |   {2} GB RAM   |   {3}' -f $os, $cpu, $ram, $kind)
    } catch { return 'Windows' }
}

function Build-TweakList {
    $panel = $script:Ui.TweakPanel
    $desc  = $script:Ui.DescText
    $lastCategory = ''

    foreach ($t in $script:Tweaks) {
        if ($t.Category -ne $lastCategory) {
            $lastCategory = $t.Category
            $h = New-Object System.Windows.Controls.TextBlock
            $h.Text = $t.Category.ToUpper()
            $h.FontSize = 11
            $h.FontWeight = 'Bold'
            $h.Foreground = New-Brush '#8B93A1'
            $h.Margin = [System.Windows.Thickness]::new(14, 14, 0, 4)
            [void]$panel.Children.Add($h)
        }

        $dock = New-Object System.Windows.Controls.DockPanel
        $dock.Margin = [System.Windows.Thickness]::new(12, 3, 12, 3)
        $dock.LastChildFill = $true
        $dock.Background = [System.Windows.Media.Brushes]::Transparent

        $status = New-Object System.Windows.Controls.TextBlock
        $status.Width = 100
        $status.TextAlignment = 'Right'
        $status.VerticalAlignment = 'Center'
        [System.Windows.Controls.DockPanel]::SetDock($status, [System.Windows.Controls.Dock]::Right)

        $cb = New-Object System.Windows.Controls.CheckBox
        $cb.Content = $t.Name
        $cb.VerticalAlignment = 'Center'

        [void]$dock.Children.Add($status)
        [void]$dock.Children.Add($cb)

        $text = $t.Desc
        if ($t.Restart -eq 'restart') { $text += '  (Needs a restart.)' }
        if ($t.Restart -eq 'sign-out') { $text += '  (Fully applies after you sign out and back in.)' }
        $enter = { $desc.Text = $text }.GetNewClosure()
        $dock.Add_MouseEnter($enter)

        [void]$panel.Children.Add($dock)
        $script:Rows[$t.Id] = @{ Check = $cb; Status = $status }
    }
}

function Update-Statuses {
    foreach ($t in $script:Tweaks) {
        $row = $script:Rows[$t.Id]
        switch (Get-TweakState $t) {
            'OneShot'    { $row.Status.Text = 'One-time';    $row.Status.Foreground = New-Brush '#A78BFA' }
            'Applied'    { $row.Status.Text = 'Applied';     $row.Status.Foreground = New-Brush '#4ADE80' }
            'AlreadySet' { $row.Status.Text = 'Already set'; $row.Status.Foreground = New-Brush '#60A5FA' }
            default      { $row.Status.Text = 'Not applied'; $row.Status.Foreground = New-Brush '#6B7280' }
        }
    }
    Update-UI
}

function Get-SelectedTweaks {
    $out = @()
    foreach ($t in $script:Tweaks) { if ($script:Rows[$t.Id].Check.IsChecked -eq $true) { $out += $t } }
    return $out
}

function Set-Busy {
    param([bool]$Busy)
    foreach ($b in $script:Buttons) { $b.IsEnabled = -not $Busy }
    if ($Busy) { $script:Window.Cursor = [System.Windows.Input.Cursors]::Wait } else { $script:Window.Cursor = $null }
    Update-UI
}

function Invoke-Batch {
    param([ValidateSet('Apply', 'Undo')][string]$Mode)
    $sel = @(Get-SelectedTweaks)
    if ($sel.Count -eq 0) {
        [void][System.Windows.MessageBox]::Show('Tick at least one tweak first.', 'Compact Tweaks', 'OK', 'Information')
        return
    }
    if ($Mode -eq 'Apply') {
        $ask = [System.Windows.MessageBox]::Show(("Apply {0} tweak(s)?" -f $sel.Count), 'Compact Tweaks', 'YesNo', 'Question')
        if ($ask -ne 'Yes') { return }
    }

    Set-Busy $true
    $script:NeedRestart = $false
    try {
        if ($Mode -eq 'Apply') {
            $reversible = @($sel | Where-Object { -not $_.OneShot })
            if ($reversible.Count -gt 0 -and $script:Ui.ChkRestore.IsChecked -eq $true) { [void](New-RestorePoint) }
            foreach ($t in $sel) { Invoke-TweakApply $t }
        } else {
            foreach ($t in $sel) { Invoke-TweakUndo $t }
        }
        if ($script:NeedRestart) { Write-Log 'Some changes need a restart or a sign-out to fully take effect.' 'Warn' }
    } catch {
        Write-Log ('Unexpected error: ' + $_.Exception.Message) 'Error'
    } finally {
        Set-Busy $false
        Update-Statuses
    }
}

$script:Ui.BtnRecommended.Add_Click({
    foreach ($t in $script:Tweaks) { $script:Rows[$t.Id].Check.IsChecked = [bool]$t.Recommended }
})
$script:Ui.BtnNone.Add_Click({
    foreach ($t in $script:Tweaks) { $script:Rows[$t.Id].Check.IsChecked = $false }
})
$script:Ui.BtnRestorePoint.Add_Click({
    Set-Busy $true
    try { [void](New-RestorePoint) } finally { Set-Busy $false }
})
$script:Ui.BtnApply.Add_Click({ Invoke-Batch -Mode 'Apply' })
$script:Ui.BtnUndo.Add_Click({ Invoke-Batch -Mode 'Undo' })
$script:Ui.BtnLog.Add_Click({
    if (-not (Test-Path -LiteralPath $script:LogFile)) { New-Item -ItemType File -Path $script:LogFile -Force | Out-Null }
    Start-Process notepad.exe -ArgumentList ('"{0}"' -f $script:LogFile)
})

# ----------------------------------------------------------------------------
# Start
# ----------------------------------------------------------------------------
$script:Ui.SysInfo.Text = Get-SystemSummary
Build-TweakList
Update-Statuses

Write-Log ("Compact Tweaks v{0} ready. Undo data and log: {1}" -f $script:Version, $script:DataDir)
$nApplied = @($script:Tweaks | Where-Object { (Get-TweakState $_) -eq 'Applied' }).Count
$nAlready = @($script:Tweaks | Where-Object { (Get-TweakState $_) -eq 'AlreadySet' }).Count
Write-Log ("Status: {0} applied by Compact Tweaks earlier, {1} already set on this PC by Windows or another tool." -f $nApplied, $nAlready)
try {
    $consoleUser = (Get-CimInstance Win32_ComputerSystem).UserName
    if ($consoleUser -and (($consoleUser -split '\\')[-1] -ne $env:USERNAME)) {
        Write-Log ("You are signed in as {0} but running as {1}. Per-user tweaks (HKCU) would change the ADMIN account, not yours. Re-run from the account you actually use." -f $consoleUser, $env:USERNAME) 'Warn'
    }
} catch { }

[void]$script:Window.ShowDialog()
