#Requires -RunAsAdministrator
param()

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Windows.Forms

$ErrorActionPreference = 'Continue'

$Root      = Join-Path $env:USERPROFILE 'PerfTweaker'
$BackupDir = Join-Path $Root 'Backups'
$ToolsDir  = Join-Path $Root 'tools'
$StateFile = Join-Path $Root 'state.json'
$LogFile   = Join-Path $Root 'log.txt'
$NpiPath   = Join-Path $ToolsDir 'nvidiaProfileInspector.exe'
New-Item -ItemType Directory -Force -Path $BackupDir | Out-Null
New-Item -ItemType Directory -Force -Path $ToolsDir  | Out-Null

function Log($m){ "$((Get-Date).ToString('s'))  $m" | Out-File -FilePath $LogFile -Append -Encoding utf8 }

function Ensure-Key($p){ if(-not(Test-Path $p)){ New-Item -Path $p -Force | Out-Null } }
function Get-Reg($p,$n){ try{ (Get-ItemProperty -Path $p -Name $n -ErrorAction Stop).$n }catch{ $null } }
function Set-Reg($p,$n,$v,$t='DWord'){ Ensure-Key $p; Set-ItemProperty -Path $p -Name $n -Value $v -Type $t -Force }
function Del-Reg($p,$n){ try{ Remove-ItemProperty -Path $p -Name $n -Force -ErrorAction Stop }catch{} }

function Snap-Reg($p,$n){
    $existed = $true
    try{ $v = (Get-ItemProperty -Path $p -Name $n -ErrorAction Stop).$n }catch{ $existed=$false; $v=$null }
    @{ Kind='reg'; Path=$p; Name=$n; Value=$v; Existed=$existed }
}
function Restore-RegSnap($s){
    if($s.Existed){
        $t = if($s.Value -is [string]){ 'String' } else { 'DWord' }
        Set-Reg $s.Path $s.Name $s.Value $t
    } else { Del-Reg $s.Path $s.Name }
}

function Snap-Svc($n){
    $svc = Get-Service -Name $n -ErrorAction SilentlyContinue
    if(-not $svc){ return @{ Kind='svc'; Name=$n; Missing=$true } }
    @{ Kind='svc'; Name=$n; StartType="$($svc.StartType)"; Status="$($svc.Status)"; Missing=$false }
}
function Set-Svc($n,$start,$stop=$true){
    $svc = Get-Service -Name $n -ErrorAction SilentlyContinue
    if(-not $svc){ return }
    try{ Set-Service -Name $n -StartupType $start -ErrorAction Stop }catch{ Log "svc $n setstart failed: $_" }
    if($stop -and $start -eq 'Disabled' -and $svc.Status -eq 'Running'){
        try{ Stop-Service -Name $n -Force -ErrorAction Stop }catch{ Log "svc $n stop failed: $_" }
    }
}
function Restore-SvcSnap($s){
    if($s.Missing){ return }
    try{ Set-Service -Name $s.Name -StartupType $s.StartType -ErrorAction Stop }catch{ Log "svc restore $($s.Name) failed: $_" }
}

$KnownGames = @(
    'cs2','csgo','FortniteClient-Win64-Shipping','FortniteLauncher','VALORANT-Win64-Shipping','VALORANT',
    'RainbowSix','RainbowSix_Vulkan','r6','r6s','apex_legends','Overwatch','Destiny2',
    'TslGame','PUBG','GTA5','RDR2','LeagueofLegends','League of Legends','dota2','EscapeFromTarkov'
)
function Get-RunningGame{
    foreach($p in Get-Process -ErrorAction SilentlyContinue){
        if($KnownGames -contains $p.Name){ return $p.Name }
    }
    return $null
}

function New-Backup{
    $ts = Get-Date -Format 'yyyyMMdd-HHmmss'
    $h1 = Join-Path $BackupDir "HKCU-$ts.reg"
    $h2 = Join-Path $BackupDir "HKLM-Software-Microsoft-Windows-$ts.reg"
    $h3 = Join-Path $BackupDir "HKLM-System-CurrentControlSet-$ts.reg"
    $pw = Join-Path $BackupDir "PowerScheme-$ts.pow"
    & reg.exe export HKCU $h1 /y | Out-Null
    & reg.exe export "HKLM\SOFTWARE\Microsoft\Windows" $h2 /y | Out-Null
    & reg.exe export "HKLM\SYSTEM\CurrentControlSet" $h3 /y | Out-Null
    try{
        $act=((powercfg /getactivescheme) -join '')
        $m=[regex]::Match($act,'GUID: ([a-f0-9-]+)')
        if($m.Success){ powercfg /export $pw $m.Groups[1].Value 2>$null | Out-Null }
    }catch{}
    $rpOK = $true
    try{
        Enable-ComputerRestore -Drive "$env:SystemDrive" -ErrorAction SilentlyContinue
        Checkpoint-Computer -Description "PerfTweaker $ts" -RestorePointType MODIFY_SETTINGS -ErrorAction Stop
    }catch{ $rpOK = $false; Log "restore point failed: $_" }
    @{ Timestamp=$ts; RegFiles=@($h1,$h2,$h3); PowerExport=$pw; RestorePoint=$rpOK }
}

# ---------- tweaks ----------
$Tweaks = @()
function Add-Tweak($id,$tab,$title,$desc,$apply){
    $script:Tweaks += [pscustomobject]@{ Id=$id; Tab=$tab; Title=$title; Desc=$desc; Apply=$apply }
}

# ===== POWER & CPU =====
Add-Tweak 'power_ultimate' 'Power & CPU' 'Ultimate Performance power plan' 'Activates Ultimate Performance scheme.' {
    $before = ((powercfg /getactivescheme) -join '')
    $m = [regex]::Match($before,'GUID: ([a-f0-9-]+)'); $beforeGuid = if($m.Success){$m.Groups[1].Value}else{$null}
    $dup = powercfg -duplicatescheme e9a42b02-d5df-448d-aa00-03f14749eb61 2>$null
    $m2 = [regex]::Match(($dup -join ''),'GUID: ([a-f0-9-]+)'); $newGuid = if($m2.Success){$m2.Groups[1].Value}else{$null}
    if($newGuid){ powercfg /setactive $newGuid | Out-Null }
    ,@(@{ Kind='power'; BeforeGuid=$beforeGuid; NewGuid=$newGuid })
}
Add-Tweak 'hibernation_off' 'Power & CPU' 'Disable Hibernation' 'Frees hiberfil.sys disk space.' {
    & powercfg /h off 2>$null | Out-Null
    ,@(@{ Kind='powercfg_h'; WasOn=$true })
}
Add-Tweak 'prio_separation' 'Power & CPU' 'Win32PrioritySeparation = 26 (foreground boost)' '' {
    $s=@(); $p='HKLM:\SYSTEM\CurrentControlSet\Control\PriorityControl'
    $s += Snap-Reg $p 'Win32PrioritySeparation'
    Set-Reg $p 'Win32PrioritySeparation' 0x26
    ,$s
}
Add-Tweak 'drivers_in_ram' 'Power & CPU' 'DisablePagingExecutive = 1 (kernel stays in RAM)' '' {
    $s=@(); $p='HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management'
    $s += Snap-Reg $p 'DisablePagingExecutive'
    Set-Reg $p 'DisablePagingExecutive' 1
    ,$s
}
Add-Tweak 'power_throttling_off' 'Power & CPU' 'PowerThrottlingOff = 1' '' {
    $s=@(); $p='HKLM:\SYSTEM\CurrentControlSet\Control\Power\PowerThrottling'
    $s += Snap-Reg $p 'PowerThrottlingOff'
    Set-Reg $p 'PowerThrottlingOff' 1
    ,$s
}
Add-Tweak 'sys_responsiveness' 'Power & CPU' 'SystemResponsiveness = 10' '' {
    $s=@(); $p='HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile'
    $s += Snap-Reg $p 'SystemResponsiveness'
    Set-Reg $p 'SystemResponsiveness' 10
    ,$s
}
Add-Tweak 'core_parking_off' 'Power & CPU' 'Disable CPU core parking (all cores active)' '' {
    powercfg /setacvalueindex scheme_current sub_processor CPMINCORES 100 2>$null | Out-Null
    powercfg /setdcvalueindex scheme_current sub_processor CPMINCORES 100 2>$null | Out-Null
    powercfg /setactive scheme_current 2>$null | Out-Null
    ,@(@{ Kind='powercfg_set'; Setting='CPMINCORES' })
}
Add-Tweak 'cpu_min_100' 'Power & CPU' 'Minimum processor state = 100% (AC)' '' {
    powercfg /setacvalueindex scheme_current sub_processor PROCTHROTTLEMIN 100 2>$null | Out-Null
    powercfg /setactive scheme_current 2>$null | Out-Null
    ,@(@{ Kind='powercfg_set'; Setting='PROCTHROTTLEMIN' })
}
Add-Tweak 'cpu_max_100' 'Power & CPU' 'Maximum processor state = 100% (AC)' '' {
    powercfg /setacvalueindex scheme_current sub_processor PROCTHROTTLEMAX 100 2>$null | Out-Null
    powercfg /setactive scheme_current 2>$null | Out-Null
    ,@(@{ Kind='powercfg_set'; Setting='PROCTHROTTLEMAX' })
}
Add-Tweak 'usb_suspend_off' 'Power & CPU' 'Disable USB selective suspend' '' {
    powercfg /setacvalueindex scheme_current 2a737441-1930-4402-8d77-b2bebba308a3 48e6b7a6-50f5-4782-a5d4-53bb8f07e226 0 2>$null | Out-Null
    powercfg /setactive scheme_current 2>$null | Out-Null
    ,@(@{ Kind='powercfg_set'; Setting='USBSUSPEND' })
}

# ===== GPU & DISPLAY =====
Add-Tweak 'hwsch_on' 'GPU & Display' 'Hardware-accelerated GPU Scheduling ON' 'Reboot required.' {
    $s=@()
    $s += Snap-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' 'HwSchMode'
    Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' 'HwSchMode' 2
    ,$s
}
Add-Tweak 'tdr_delay' 'GPU & Display' 'TdrDelay = 10 (GPU timeout grace)' 'Prevents false-positive GPU hangs under heavy load.' {
    $s=@(); $p='HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers'
    $s += Snap-Reg $p 'TdrDelay'
    Set-Reg $p 'TdrDelay' 10
    ,$s
}
Add-Tweak 'tdr_ddi_delay' 'GPU & Display' 'TdrDdiDelay = 10' '' {
    $s=@(); $p='HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers'
    $s += Snap-Reg $p 'TdrDdiDelay'
    Set-Reg $p 'TdrDdiDelay' 10
    ,$s
}

# ===== NETWORK =====
Add-Tweak 'nagle_off' 'Network' 'Disable Nagle on all NICs' 'TcpAckFrequency + TCPNoDelay.' {
    $s=@()
    foreach($k in Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces' -ErrorAction SilentlyContinue){
        $p = $k.PSPath
        $s += Snap-Reg $p 'TcpAckFrequency'; $s += Snap-Reg $p 'TCPNoDelay'
        Set-Reg $p 'TcpAckFrequency' 1; Set-Reg $p 'TCPNoDelay' 1
    }
    ,$s
}
Add-Tweak 'net_throttle_off' 'Network' 'NetworkThrottlingIndex = FFFFFFFF' '' {
    $s=@(); $p='HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile'
    $s += Snap-Reg $p 'NetworkThrottlingIndex'
    Set-Reg $p 'NetworkThrottlingIndex' 0xFFFFFFFF
    ,$s
}
Add-Tweak 'llmnr_off' 'Network' 'Disable LLMNR' '' {
    $s=@(); $p='HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\DNSClient'
    $s += Snap-Reg $p 'EnableMulticast'
    Set-Reg $p 'EnableMulticast' 0
    ,$s
}
Add-Tweak 'cloudflare_dns' 'Network' 'Set DNS to Cloudflare 1.1.1.1 / 1.0.0.1 on active NICs' 'Faster DNS resolution.' {
    $s=@()
    $adapters = Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object Status -eq 'Up'
    foreach($a in $adapters){
        $prev = (Get-DnsClientServerAddress -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).ServerAddresses
        $s += @{ Kind='dns'; IfIndex=$a.ifIndex; Prev=$prev }
        try{ Set-DnsClientServerAddress -InterfaceIndex $a.ifIndex -ServerAddresses @('1.1.1.1','1.0.0.1') -ErrorAction Stop }catch{ Log "dns set fail: $_" }
    }
    ,$s
}
Add-Tweak 'netbios_off' 'Network' 'Disable NetBIOS over TCP/IP' '' {
    $s=@()
    foreach($k in Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Services\NetBT\Parameters\Interfaces' -ErrorAction SilentlyContinue){
        $p=$k.PSPath
        $s += Snap-Reg $p 'NetbiosOptions'
        Set-Reg $p 'NetbiosOptions' 2
    }
    ,$s
}
Add-Tweak 'teredo_off' 'Network' 'Disable Teredo IPv6 transition' '' {
    & netsh interface teredo set state disabled 2>$null | Out-Null
    ,@(@{ Kind='netsh_teredo'; PrevState='default' })
}
Add-Tweak 'max_user_port' 'Network' 'MaxUserPort = 65534 (more ephemeral ports)' '' {
    $s=@(); $p='HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters'
    $s += Snap-Reg $p 'MaxUserPort'
    Set-Reg $p 'MaxUserPort' 65534
    ,$s
}

# ===== GAMING =====
Add-Tweak 'disable_gamebar' 'Gaming' 'Disable Xbox Game Bar / Game DVR' '' {
    $s=@()
    $s += Snap-Reg 'HKCU:\Software\Microsoft\GameBar' 'UseNexusForGameBarEnabled'
    $s += Snap-Reg 'HKCU:\System\GameConfigStore' 'GameDVR_Enabled'
    $s += Snap-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR' 'AllowGameDVR'
    Set-Reg 'HKCU:\Software\Microsoft\GameBar' 'UseNexusForGameBarEnabled' 0
    Set-Reg 'HKCU:\System\GameConfigStore' 'GameDVR_Enabled' 0
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR' 'AllowGameDVR' 0
    ,$s
}
Add-Tweak 'mouse_accel' 'Gaming' 'Disable mouse acceleration' 'Raw 1:1 input.' {
    $s=@()
    $s += Snap-Reg 'HKCU:\Control Panel\Mouse' 'MouseSpeed'
    $s += Snap-Reg 'HKCU:\Control Panel\Mouse' 'MouseThreshold1'
    $s += Snap-Reg 'HKCU:\Control Panel\Mouse' 'MouseThreshold2'
    Set-Reg 'HKCU:\Control Panel\Mouse' 'MouseSpeed' '0' 'String'
    Set-Reg 'HKCU:\Control Panel\Mouse' 'MouseThreshold1' '0' 'String'
    Set-Reg 'HKCU:\Control Panel\Mouse' 'MouseThreshold2' '0' 'String'
    ,$s
}
Add-Tweak 'mmcss_games_prio' 'Gaming' 'MMCSS Games task: GPU Prio 8 / Prio 6 / High' '' {
    $s=@(); $p='HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games'
    $s += Snap-Reg $p 'GPU Priority'; $s += Snap-Reg $p 'Priority'
    $s += Snap-Reg $p 'Scheduling Category'; $s += Snap-Reg $p 'SFIO Priority'
    Set-Reg $p 'GPU Priority' 8
    Set-Reg $p 'Priority' 6
    Set-Reg $p 'Scheduling Category' 'High' 'String'
    Set-Reg $p 'SFIO Priority' 'High' 'String'
    ,$s
}
Add-Tweak 'fse_true_fullscreen' 'Gaming' 'GameDVR FSE: true fullscreen exclusive' '' {
    $s=@(); $p='HKCU:\System\GameConfigStore'
    $s += Snap-Reg $p 'GameDVR_FSEBehaviorMode'
    $s += Snap-Reg $p 'GameDVR_HonorUserFSEBehaviorMode'
    $s += Snap-Reg $p 'GameDVR_DXGIHonorFSEWindowsCompatible'
    Set-Reg $p 'GameDVR_FSEBehaviorMode' 2
    Set-Reg $p 'GameDVR_HonorUserFSEBehaviorMode' 1
    Set-Reg $p 'GameDVR_DXGIHonorFSEWindowsCompatible' 1
    ,$s
}
Add-Tweak 'game_mode_on' 'Gaming' 'Enable Windows Game Mode' '' {
    $s=@(); $p='HKCU:\Software\Microsoft\GameBar'
    $s += Snap-Reg $p 'AllowAutoGameMode'; $s += Snap-Reg $p 'AutoGameModeEnabled'
    Set-Reg $p 'AllowAutoGameMode' 1
    Set-Reg $p 'AutoGameModeEnabled' 1
    ,$s
}
Add-Tweak 'audio_comm_none' 'Gaming' 'Audio: Communications activity = Do nothing (no ducking)' '' {
    $s=@(); $p='HKCU:\Software\Microsoft\Multimedia\Audio'
    $s += Snap-Reg $p 'UserDuckingPreference'
    Set-Reg $p 'UserDuckingPreference' 3
    ,$s
}

# ===== SERVICES =====
Add-Tweak 'sysmain_off' 'Services' 'Disable SysMain / SuperFetch (SSD)' '' {
    $snap = Snap-Svc 'SysMain'; Set-Svc 'SysMain' 'Disabled'; ,@($snap)
}
Add-Tweak 'wsearch_off' 'Services' 'Disable Windows Search (drive indexing)' '' {
    $snap = Snap-Svc 'WSearch'; Set-Svc 'WSearch' 'Disabled'; ,@($snap)
}
Add-Tweak 'diagtrack_off' 'Services' 'Disable DiagTrack telemetry' '' {
    $snap = Snap-Svc 'DiagTrack'; Set-Svc 'DiagTrack' 'Disabled'; ,@($snap)
}
Add-Tweak 'wer_off' 'Services' 'Disable Windows Error Reporting (WerSvc)' '' {
    $snap = Snap-Svc 'WerSvc'; Set-Svc 'WerSvc' 'Disabled'; ,@($snap)
}
Add-Tweak 'delivery_opt_off' 'Services' 'Delivery Optimization -> Manual' '' {
    $snap = Snap-Svc 'DoSvc'; Set-Svc 'DoSvc' 'Manual'; ,@($snap)
}
Add-Tweak 'cdp_off' 'Services' 'Connected Devices Platform -> Manual' '' {
    $snap = Snap-Svc 'CDPSvc'; Set-Svc 'CDPSvc' 'Manual'; ,@($snap)
}
Add-Tweak 'remote_reg_off' 'Services' 'Disable Remote Registry' '' {
    $snap = Snap-Svc 'RemoteRegistry'; Set-Svc 'RemoteRegistry' 'Disabled'; ,@($snap)
}
Add-Tweak 'xbox_services_off' 'Services' 'Xbox Live background services -> Manual' '' {
    $out=@()
    foreach($n in 'XblAuthManager','XblGameSave','XboxNetApiSvc','XboxGipSvc'){
        $out += Snap-Svc $n; Set-Svc $n 'Manual'
    }
    ,$out
}
Add-Tweak 'mapsbroker_off' 'Services' 'Disable MapsBroker (offline maps)' '' {
    $snap = Snap-Svc 'MapsBroker'; Set-Svc 'MapsBroker' 'Disabled'; ,@($snap)
}
Add-Tweak 'geolocation_off' 'Services' 'Disable Geolocation service (lfsvc)' '' {
    $snap = Snap-Svc 'lfsvc'; Set-Svc 'lfsvc' 'Disabled'; ,@($snap)
}
Add-Tweak 'retaildemo_off' 'Services' 'Disable Retail Demo service' '' {
    $snap = Snap-Svc 'RetailDemo'; Set-Svc 'RetailDemo' 'Disabled'; ,@($snap)
}
Add-Tweak 'pca_off' 'Services' 'Program Compatibility Assistant -> Manual' '' {
    $snap = Snap-Svc 'PcaSvc'; Set-Svc 'PcaSvc' 'Manual'; ,@($snap)
}
Add-Tweak 'tablet_input_off' 'Services' 'Touch Keyboard / Handwriting Panel -> Manual' '' {
    $snap = Snap-Svc 'TabletInputService'; Set-Svc 'TabletInputService' 'Manual'; ,@($snap)
}
Add-Tweak 'fax_off' 'Services' 'Disable Fax service' '' {
    $snap = Snap-Svc 'Fax'; Set-Svc 'Fax' 'Disabled'; ,@($snap)
}

# ===== PRIVACY =====
Add-Tweak 'telemetry_basic' 'Privacy' 'Reduce telemetry to minimum' '' {
    $s=@()
    $s += Snap-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' 'AllowTelemetry'
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' 'AllowTelemetry' 0
    ,$s
}
Add-Tweak 'cortana_off' 'Privacy' 'Disable Cortana' '' {
    $s=@(); $p='HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search'
    $s += Snap-Reg $p 'AllowCortana'
    Set-Reg $p 'AllowCortana' 0
    ,$s
}
Add-Tweak 'tips_ads_off' 'Privacy' 'Disable Tips / Suggestions / Ads' '' {
    $s=@(); $p='HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
    foreach($n in 'SubscribedContent-338388Enabled','SubscribedContent-338389Enabled','SubscribedContent-353694Enabled','SubscribedContent-353696Enabled','SystemPaneSuggestionsEnabled','SilentInstalledAppsEnabled'){
        $s += Snap-Reg $p $n; Set-Reg $p $n 0
    }
    ,$s
}
Add-Tweak 'activity_history_off' 'Privacy' 'Disable Activity History' '' {
    $s=@(); $p='HKLM:\SOFTWARE\Policies\Microsoft\Windows\System'
    foreach($n in 'PublishUserActivities','UploadUserActivities','EnableActivityFeed'){
        $s += Snap-Reg $p $n; Set-Reg $p $n 0
    }
    ,$s
}
Add-Tweak 'lockscreen_ads_off' 'Privacy' 'Disable lock-screen Spotlight / ads' '' {
    $s=@(); $p='HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
    foreach($n in 'RotatingLockScreenEnabled','RotatingLockScreenOverlayEnabled','SubscribedContent-338387Enabled'){
        $s += Snap-Reg $p $n; Set-Reg $p $n 0
    }
    ,$s
}
Add-Tweak 'advertising_id_off' 'Privacy' 'Disable Advertising ID' '' {
    $s=@(); $p='HKCU:\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo'
    $s += Snap-Reg $p 'Enabled'
    Set-Reg $p 'Enabled' 0
    ,$s
}
Add-Tweak 'app_launch_track_off' 'Privacy' 'Disable app-launch tracking' '' {
    $s=@(); $p='HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
    $s += Snap-Reg $p 'Start_TrackProgs'
    Set-Reg $p 'Start_TrackProgs' 0
    ,$s
}
Add-Tweak 'speech_rec_off' 'Privacy' 'Disable online speech recognition' '' {
    $s=@(); $p='HKCU:\Software\Microsoft\Speech_OneCore\Settings\OnlineSpeechPrivacy'
    $s += Snap-Reg $p 'HasAccepted'
    Set-Reg $p 'HasAccepted' 0
    ,$s
}
Add-Tweak 'typing_pers_off' 'Privacy' 'Disable inking / typing personalization' '' {
    $s=@()
    $p1='HKCU:\Software\Microsoft\InputPersonalization'
    $s += Snap-Reg $p1 'RestrictImplicitInkCollection'; $s += Snap-Reg $p1 'RestrictImplicitTextCollection'
    Set-Reg $p1 'RestrictImplicitInkCollection' 1; Set-Reg $p1 'RestrictImplicitTextCollection' 1
    $p2='HKCU:\Software\Microsoft\Personalization\Settings'
    $s += Snap-Reg $p2 'AcceptedPrivacyPolicy'
    Set-Reg $p2 'AcceptedPrivacyPolicy' 0
    ,$s
}

# ===== VISUAL & STARTUP =====
Add-Tweak 'visual_fx_perf' 'Visual & Startup' 'Visual effects: best performance' '' {
    $s=@()
    $s += Snap-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects' 'VisualFXSetting'
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects' 'VisualFXSetting' 2
    ,$s
}
Add-Tweak 'transparency_off' 'Visual & Startup' 'Disable transparency effects' '' {
    $s=@(); $p='HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'
    $s += Snap-Reg $p 'EnableTransparency'
    Set-Reg $p 'EnableTransparency' 0
    ,$s
}
Add-Tweak 'animations_off' 'Visual & Startup' 'Disable window animations' '' {
    $s=@()
    $s += Snap-Reg 'HKCU:\Control Panel\Desktop\WindowMetrics' 'MinAnimate'
    Set-Reg 'HKCU:\Control Panel\Desktop\WindowMetrics' 'MinAnimate' '0' 'String'
    ,$s
}
Add-Tweak 'widgets_off' 'Visual & Startup' 'Disable Widgets (taskbar)' '' {
    $s=@(); $p='HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
    $s += Snap-Reg $p 'TaskbarDa'
    Set-Reg $p 'TaskbarDa' 0
    ,$s
}
Add-Tweak 'show_file_ext' 'Visual & Startup' 'Show file extensions in Explorer' '' {
    $s=@(); $p='HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
    $s += Snap-Reg $p 'HideFileExt'
    Set-Reg $p 'HideFileExt' 0
    ,$s
}
Add-Tweak 'startup_bloat' 'Visual & Startup' 'Disable common startup bloat' 'OneDrive / Teams / Spotify / Skype / Edge autolaunch.' {
    $s=@()
    foreach($n in 'OneDrive','OneDriveSetup','com.squirrel.Teams.Teams','MicrosoftEdgeAutoLaunch','Skype','Spotify','SpotifyWebHelper'){
        $s += Snap-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' $n
        Del-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' $n
    }
    ,$s
}
Add-Tweak 'bg_apps_off' 'Visual & Startup' 'Disable background UWP apps' '' {
    $s=@(); $p='HKCU:\Software\Microsoft\Windows\CurrentVersion\BackgroundAccessApplications'
    $s += Snap-Reg $p 'GlobalUserDisabled'
    Set-Reg $p 'GlobalUserDisabled' 1
    ,$s
}
Add-Tweak 'onedrive_autostart_off' 'Visual & Startup' 'Disable OneDrive autostart' '' {
    $s=@()
    $s += Snap-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' 'OneDrive'
    Del-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' 'OneDrive'
    ,$s
}
Add-Tweak 'teams_autostart_off' 'Visual & Startup' 'Disable Teams autostart' '' {
    $s=@()
    foreach($n in 'com.squirrel.Teams.Teams','MSTeams'){
        $s += Snap-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' $n
        Del-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' $n
    }
    ,$s
}

# ===== CLEANUP =====
Add-Tweak 'clear_temp' 'Cleanup' 'Clear %TEMP% folder' '' {
    $removed = 0
    Get-ChildItem -Path $env:TEMP -Force -ErrorAction SilentlyContinue | ForEach-Object {
        try{ Remove-Item $_.FullName -Recurse -Force -ErrorAction Stop; $removed++ }catch{}
    }
    ,@(@{ Kind='info'; Removed=$removed })
}
Add-Tweak 'clear_wu_cache' 'Cleanup' 'Clear Windows Update download cache' '' {
    try{ Stop-Service wuauserv -Force -ErrorAction SilentlyContinue }catch{}
    $wu = 'C:\Windows\SoftwareDistribution\Download'
    if(Test-Path $wu){ Get-ChildItem $wu -Force -ErrorAction SilentlyContinue | ForEach-Object { try{ Remove-Item $_.FullName -Recurse -Force -ErrorAction Stop }catch{} } }
    try{ Start-Service wuauserv -ErrorAction SilentlyContinue }catch{}
    ,@(@{ Kind='info'; Cleared='WU cache' })
}
Add-Tweak 'flush_dns' 'Cleanup' 'Flush DNS resolver cache' '' {
    & ipconfig /flushdns 2>$null | Out-Null
    ,@(@{ Kind='info'; Cleared='DNS cache' })
}
Add-Tweak 'clear_font_cache' 'Cleanup' 'Clear font cache' '' {
    try{ Stop-Service FontCache -Force -ErrorAction SilentlyContinue }catch{}
    $fc='C:\Windows\ServiceProfiles\LocalService\AppData\Local\FontCache'
    if(Test-Path $fc){ Get-ChildItem $fc -Force -ErrorAction SilentlyContinue | ForEach-Object { try{ Remove-Item $_.FullName -Recurse -Force -ErrorAction Stop }catch{} } }
    try{ Start-Service FontCache -ErrorAction SilentlyContinue }catch{}
    ,@(@{ Kind='info'; Cleared='Font cache' })
}
Add-Tweak 'pause_updates_7d' 'Cleanup' 'Pause Windows Update 7 days' '' {
    $s=@(); $p='HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings'
    $now = Get-Date
    $start = $now.ToString('yyyy-MM-ddTHH:mm:ssZ')
    $end   = $now.AddDays(7).ToString('yyyy-MM-ddTHH:mm:ssZ')
    foreach($n in 'PauseUpdatesStartTime','PauseUpdatesExpiryTime','PauseFeatureUpdatesStartTime','PauseFeatureUpdatesEndTime','PauseQualityUpdatesStartTime','PauseQualityUpdatesEndTime'){
        $s += Snap-Reg $p $n
    }
    Set-Reg $p 'PauseUpdatesStartTime'        $start 'String'
    Set-Reg $p 'PauseUpdatesExpiryTime'       $end   'String'
    Set-Reg $p 'PauseFeatureUpdatesStartTime' $start 'String'
    Set-Reg $p 'PauseFeatureUpdatesEndTime'   $end   'String'
    Set-Reg $p 'PauseQualityUpdatesStartTime' $start 'String'
    Set-Reg $p 'PauseQualityUpdatesEndTime'   $end   'String'
    ,$s
}

# ---------- NVIDIA + PER-GAME ----------
function Test-NvidiaPresent {
    $gpu = Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue | Where-Object { $_.Name -like '*NVIDIA*' }
    return ($null -ne $gpu)
}
function Ensure-Npi([System.Windows.Window]$owner){
    if(Test-Path $NpiPath){ return $true }
    $r = [System.Windows.MessageBox]::Show($owner, "NVIDIA Profile Inspector is required for NVIDIA per-game tweaks.`nDownload from official GitHub now?","NVIDIA tool",'YesNo','Question')
    if($r -ne 'Yes'){ return $false }
    $zip = Join-Path $ToolsDir 'npi.zip'
    try{
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri 'https://github.com/Orbmu2k/nvidiaProfileInspector/releases/latest/download/nvidiaProfileInspector.zip' -OutFile $zip -UseBasicParsing -ErrorAction Stop
        Expand-Archive -Path $zip -DestinationPath $ToolsDir -Force
        Remove-Item $zip -Force -ErrorAction SilentlyContinue
    }catch{ [System.Windows.MessageBox]::Show($owner,"Download failed: $_","NVIDIA tool",'OK','Error') | Out-Null; return $false }
    return (Test-Path $NpiPath)
}
function Apply-NvidiaPerGame($exePath){
    $profileName = 'PerfTweaker-' + ([System.IO.Path]::GetFileNameWithoutExtension($exePath))
    & $NpiPath -createProfile "$profileName" 2>$null | Out-Null
    & $NpiPath -addApplication "$profileName" "$exePath" 2>$null | Out-Null
    & $NpiPath -setProfileSetting "$profileName" 0x10D000 0x00000001 2>$null | Out-Null
    & $NpiPath -setProfileSetting "$profileName" 0x10835000 0x00000002 2>$null | Out-Null
    & $NpiPath -setProfileSetting "$profileName" 0x20C1221E 0x00000001 2>$null | Out-Null
    & $NpiPath -setProfileSetting "$profileName" 0x00198FFF 0xFFFFFFFF 2>$null | Out-Null
    & $NpiPath -setProfileSetting "$profileName" 0x00738E8F 0x00000000 2>$null | Out-Null
    return $profileName
}
function Undo-NvidiaPerGame($profileName){
    if(-not (Test-Path $NpiPath)){ return }
    & $NpiPath -removeProfile "$profileName" 2>$null | Out-Null
}
function Apply-PerGame($exePath,[bool]$gpuPref,[bool]$fso,[bool]$shortcut,[bool]$nvidia){
    $snaps = @()
    if($gpuPref){
        $p='HKCU:\Software\Microsoft\DirectX\UserGpuPreferences'
        $snaps += Snap-Reg $p $exePath
        Set-Reg $p $exePath 'GpuPreference=2;' 'String'
    }
    if($fso){
        $p='HKCU:\Software\Microsoft\Windows NT\CurrentVersion\AppCompatFlags\Layers'
        $snaps += Snap-Reg $p $exePath
        Set-Reg $p $exePath '~ DISABLEDXMAXIMIZEDWINDOWEDMODE' 'String'
    }
    if($shortcut){
        $desk=[Environment]::GetFolderPath('Desktop')
        $name=[System.IO.Path]::GetFileNameWithoutExtension($exePath)
        $lnk=Join-Path $desk "$name (High Priority).lnk"
        $wsh=New-Object -ComObject WScript.Shell
        $sc=$wsh.CreateShortcut($lnk)
        $sc.TargetPath = $env:ComSpec
        $sc.Arguments = "/c start `"$name`" /high `"$exePath`""
        $sc.WorkingDirectory = Split-Path $exePath
        try{ $sc.IconLocation = "$exePath,0" }catch{}
        $sc.Save()
        $snaps += @{ Kind='shortcut'; Path=$lnk }
    }
    if($nvidia){
        $profileName = Apply-NvidiaPerGame $exePath
        $snaps += @{ Kind='nvprofile'; Profile=$profileName }
    }
    return ,$snaps
}

# ---------- state ----------
function ConvertTo-Hashtable($obj){
    if($null -eq $obj){ return $null }
    if($obj -is [System.Collections.IDictionary]){ return $obj }
    if($obj -is [pscustomobject]){
        $h = @{}; foreach($p in $obj.PSObject.Properties){ $h[$p.Name] = ConvertTo-Hashtable $p.Value }
        return $h
    }
    if($obj -is [array]){ return @($obj | ForEach-Object { ConvertTo-Hashtable $_ }) }
    return $obj
}
function Load-State{
    if(Test-Path $StateFile){
        try{ return ConvertTo-Hashtable (Get-Content $StateFile -Raw | ConvertFrom-Json) }catch{}
    }
    @{}
}
function Save-State($state){
    $state | ConvertTo-Json -Depth 10 | Out-File -FilePath $StateFile -Encoding utf8 -Force
}

# ---------- apply / undo ----------
function Invoke-Apply($sysIds,$perGame,$owner){
    $game = Get-RunningGame
    if($game){
        [System.Windows.MessageBox]::Show($owner,"Cannot apply: `"$game`" is running. Close the game first.","PerfTweaker",'OK','Warning') | Out-Null
        return $false
    }
    $backup = New-Backup
    $state = Load-State
    if(-not $state.Applied){ $state.Applied = @{} }
    $state.LastBackup = $backup
    $log = @()
    foreach($t in $Tweaks){
        if($sysIds -notcontains $t.Id){ continue }
        if($state.Applied[$t.Id]){ $log += "skip: $($t.Title)"; continue }
        try{
            $snaps = & $t.Apply
            $state.Applied[$t.Id] = @{ Title=$t.Title; Snapshots=$snaps; AppliedAt=(Get-Date).ToString('s') }
            $log += "applied: $($t.Title)"
        }catch{ $log += "FAILED: $($t.Title) -> $_"; Log "FAIL $($t.Id): $_" }
    }
    if($perGame -and $perGame.Exe){
        try{
            $snaps = Apply-PerGame $perGame.Exe $perGame.GpuPref $perGame.Fso $perGame.Shortcut $perGame.Nvidia
            $key = 'pergame_' + [System.IO.Path]::GetFileName($perGame.Exe)
            $state.Applied[$key] = @{ Title="Per-game: $($perGame.Exe)"; Snapshots=$snaps; AppliedAt=(Get-Date).ToString('s') }
            $log += "applied per-game: $($perGame.Exe)"
        }catch{ $log += "FAILED per-game: $_" }
    }
    Save-State $state
    $msg = "Backup: $($backup.Timestamp)`nRestore point: $(if($backup.RestorePoint){'OK'}else{'SKIPPED'})`n`n" + ($log -join "`n") + "`n`nReboot recommended."
    [System.Windows.MessageBox]::Show($owner,$msg,"PerfTweaker - Done",'OK','Information') | Out-Null
    return $true
}
function Invoke-UndoAll($owner){
    $state = Load-State
    if(-not $state.Applied -or $state.Applied.Count -eq 0){
        [System.Windows.MessageBox]::Show($owner,"Nothing to undo.","PerfTweaker",'OK','Information') | Out-Null; return
    }
    $log=@()
    foreach($id in @($state.Applied.Keys)){
        $entry = $state.Applied[$id]
        foreach($snap in $entry.Snapshots){
            try{
                switch($snap.Kind){
                    'reg'       { Restore-RegSnap $snap }
                    'svc'       { Restore-SvcSnap $snap }
                    'power'     {
                        if($snap.BeforeGuid){ powercfg /setactive $snap.BeforeGuid | Out-Null }
                        if($snap.NewGuid){ powercfg /delete $snap.NewGuid 2>$null | Out-Null }
                    }
                    'powercfg_h'{ & powercfg /h on 2>$null | Out-Null }
                    'powercfg_set' { }
                    'netsh_teredo' { & netsh interface teredo set state default 2>$null | Out-Null }
                    'dns' {
                        try{
                            if($snap.Prev -and $snap.Prev.Count -gt 0){
                                Set-DnsClientServerAddress -InterfaceIndex $snap.IfIndex -ServerAddresses $snap.Prev -ErrorAction Stop
                            } else {
                                Set-DnsClientServerAddress -InterfaceIndex $snap.IfIndex -ResetServerAddresses -ErrorAction Stop
                            }
                        }catch{ Log "dns restore fail: $_" }
                    }
                    'shortcut'  { if(Test-Path $snap.Path){ Remove-Item $snap.Path -Force -ErrorAction SilentlyContinue } }
                    'nvprofile' { Undo-NvidiaPerGame $snap.Profile }
                    'info'      { }
                }
            }catch{ Log "undo fail ${id}: $_" }
        }
        $log += "reverted: $($entry.Title)"
        $state.Applied.Remove($id)
    }
    # try to reimport the power scheme from last backup
    if($state.LastBackup -and $state.LastBackup.PowerExport -and (Test-Path $state.LastBackup.PowerExport)){
        try{ powercfg /import "$($state.LastBackup.PowerExport)" 2>$null | Out-Null }catch{}
    }
    Save-State $state
    [System.Windows.MessageBox]::Show($owner,($log -join "`n"),"PerfTweaker - Undo",'OK','Information') | Out-Null
}

# ---------- WPF UI ----------
[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="PerfTweaker" Height="820" Width="960"
        WindowStartupLocation="CenterScreen" Background="#0F0F14"
        FontFamily="Segoe UI" FontSize="13" Foreground="#E5E7EB">
  <Window.Resources>
    <SolidColorBrush x:Key="Accent" Color="#8B5CF6"/>
    <SolidColorBrush x:Key="Danger" Color="#EF4444"/>
    <SolidColorBrush x:Key="PanelBg" Color="#181820"/>
    <SolidColorBrush x:Key="PanelBg2" Color="#1F1F2A"/>
    <SolidColorBrush x:Key="Muted" Color="#9CA3AF"/>
    <Style TargetType="CheckBox">
      <Setter Property="Foreground" Value="#E5E7EB"/>
      <Setter Property="Margin" Value="4,6,4,6"/>
      <Setter Property="Padding" Value="8,0,0,0"/>
      <Setter Property="VerticalContentAlignment" Value="Center"/>
    </Style>
    <Style TargetType="Button">
      <Setter Property="Foreground" Value="White"/>
      <Setter Property="Background" Value="#2A2A38"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Padding" Value="14,8"/>
      <Setter Property="Margin" Value="4,0"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bd" Background="{TemplateBinding Background}" CornerRadius="8" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bd" Property="Opacity" Value="0.85"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="TabItem">
      <Setter Property="Foreground" Value="#D1D5DB"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Padding" Value="14,7"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TabItem">
            <Border x:Name="bd" Background="{TemplateBinding Background}" CornerRadius="8,8,0,0" Padding="{TemplateBinding Padding}" Margin="2,0">
              <ContentPresenter ContentSource="Header" HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsSelected" Value="True">
                <Setter TargetName="bd" Property="Background" Value="#1F1F2A"/>
                <Setter Property="Foreground" Value="White"/>
              </Trigger>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bd" Property="Background" Value="#1A1A22"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="TabControl">
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="BorderThickness" Value="0"/>
    </Style>
  </Window.Resources>

  <Grid>
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>

    <Border Grid.Row="0" Background="#13131A" Padding="28,20">
      <StackPanel>
        <TextBlock Text="PerfTweaker" FontSize="26" FontWeight="Bold" Foreground="White"/>
        <TextBlock Text="Windows 11 FPS &amp; latency tuner . 63 tweaks organized into 9 tabs . per-game profiles + NVIDIA"
                   Foreground="{StaticResource Muted}" FontSize="12" Margin="0,4,0,0"/>
        <TextBlock Text="Anticheat-safe (VAC / EAC / BattlEye / Vanguard). Restore point + registry backup before Apply."
                   Foreground="#6EE7B7" FontSize="11" Margin="0,4,0,0"/>
      </StackPanel>
    </Border>

    <TabControl Grid.Row="1" Margin="16,10,16,0" x:Name="MainTabs">
      <TabItem Header="Power &amp; CPU"><Border Background="{StaticResource PanelBg}" CornerRadius="0,8,8,8" Padding="8"><ScrollViewer VerticalScrollBarVisibility="Auto"><StackPanel x:Name="T_Power" Margin="12"/></ScrollViewer></Border></TabItem>
      <TabItem Header="GPU &amp; Display"><Border Background="{StaticResource PanelBg}" CornerRadius="0,8,8,8" Padding="8"><ScrollViewer VerticalScrollBarVisibility="Auto"><StackPanel x:Name="T_Gpu" Margin="12"/></ScrollViewer></Border></TabItem>
      <TabItem Header="Network"><Border Background="{StaticResource PanelBg}" CornerRadius="0,8,8,8" Padding="8"><ScrollViewer VerticalScrollBarVisibility="Auto"><StackPanel x:Name="T_Net" Margin="12"/></ScrollViewer></Border></TabItem>
      <TabItem Header="Gaming"><Border Background="{StaticResource PanelBg}" CornerRadius="0,8,8,8" Padding="8"><ScrollViewer VerticalScrollBarVisibility="Auto"><StackPanel x:Name="T_Gaming" Margin="12"/></ScrollViewer></Border></TabItem>
      <TabItem Header="Services"><Border Background="{StaticResource PanelBg}" CornerRadius="0,8,8,8" Padding="8"><ScrollViewer VerticalScrollBarVisibility="Auto"><StackPanel x:Name="T_Svc" Margin="12"/></ScrollViewer></Border></TabItem>
      <TabItem Header="Privacy"><Border Background="{StaticResource PanelBg}" CornerRadius="0,8,8,8" Padding="8"><ScrollViewer VerticalScrollBarVisibility="Auto"><StackPanel x:Name="T_Priv" Margin="12"/></ScrollViewer></Border></TabItem>
      <TabItem Header="Visual &amp; Startup"><Border Background="{StaticResource PanelBg}" CornerRadius="0,8,8,8" Padding="8"><ScrollViewer VerticalScrollBarVisibility="Auto"><StackPanel x:Name="T_Vis" Margin="12"/></ScrollViewer></Border></TabItem>
      <TabItem Header="Cleanup"><Border Background="{StaticResource PanelBg}" CornerRadius="0,8,8,8" Padding="8"><ScrollViewer VerticalScrollBarVisibility="Auto"><StackPanel x:Name="T_Clean" Margin="12"/></ScrollViewer></Border></TabItem>
      <TabItem Header="Per-Game + NVIDIA">
        <Border Background="{StaticResource PanelBg}" CornerRadius="0,8,8,8" Padding="24">
          <StackPanel>
            <TextBlock Text="Select a game .exe and choose per-game optimizations." Foreground="{StaticResource Muted}" Margin="0,0,0,14"/>
            <StackPanel Orientation="Horizontal" Margin="0,0,0,10">
              <Button x:Name="BtnPickExe" Content="Browse game .exe..." Background="{StaticResource Accent}" Padding="18,10"/>
              <TextBlock x:Name="TxtExePath" Text="(no game selected)" Foreground="{StaticResource Muted}" VerticalAlignment="Center" Margin="14,0,0,0"/>
            </StackPanel>
            <Border Background="{StaticResource PanelBg2}" CornerRadius="10" Padding="18" Margin="0,8,0,0">
              <StackPanel>
                <CheckBox x:Name="CbGpuPref" Content="Set Windows GPU preference: High Performance" IsChecked="True"/>
                <CheckBox x:Name="CbFso" Content="Disable Fullscreen Optimizations for this .exe" IsChecked="True"/>
                <CheckBox x:Name="CbShortcut" Content="Create 'High Priority' launch shortcut on Desktop" IsChecked="True"/>
                <CheckBox x:Name="CbNvidia" Content="Apply NVIDIA per-game profile (Max Perf, Low Latency Ultra, Threaded Opt, Shader Cache)" IsChecked="True"/>
                <TextBlock x:Name="TxtNvStatus" Foreground="{StaticResource Muted}" FontSize="11" Margin="28,4,0,0"/>
              </StackPanel>
            </Border>
          </StackPanel>
        </Border>
      </TabItem>
    </TabControl>

    <Border Grid.Row="2" Background="#13131A" Padding="20,14">
      <Grid>
        <StackPanel Orientation="Horizontal" HorizontalAlignment="Left">
          <Button x:Name="BtnAll" Content="Select All"/>
          <Button x:Name="BtnNone" Content="Select None"/>
        </StackPanel>
        <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
          <Button x:Name="BtnUndo" Content="Undo All" Background="{StaticResource Danger}"/>
          <Button x:Name="BtnApply" Content="Apply Selected" Background="{StaticResource Accent}" Padding="22,10"/>
        </StackPanel>
      </Grid>
    </Border>
  </Grid>
</Window>
'@

function Show-UI{
    $reader = New-Object System.Xml.XmlNodeReader $xaml
    $win = [Windows.Markup.XamlReader]::Load($reader)

    $tabMap = @{
        'Power & CPU'       = $win.FindName('T_Power')
        'GPU & Display'     = $win.FindName('T_Gpu')
        'Network'           = $win.FindName('T_Net')
        'Gaming'            = $win.FindName('T_Gaming')
        'Services'          = $win.FindName('T_Svc')
        'Privacy'           = $win.FindName('T_Priv')
        'Visual & Startup'  = $win.FindName('T_Vis')
        'Cleanup'           = $win.FindName('T_Clean')
    }

    $BtnPickExe = $win.FindName('BtnPickExe')
    $TxtExePath = $win.FindName('TxtExePath')
    $CbGpuPref  = $win.FindName('CbGpuPref')
    $CbFso      = $win.FindName('CbFso')
    $CbShortcut = $win.FindName('CbShortcut')
    $CbNvidia   = $win.FindName('CbNvidia')
    $TxtNvStat  = $win.FindName('TxtNvStatus')
    $BtnAll     = $win.FindName('BtnAll')
    $BtnNone    = $win.FindName('BtnNone')
    $BtnApply   = $win.FindName('BtnApply')
    $BtnUndo    = $win.FindName('BtnUndo')

    if(Test-NvidiaPresent){
        $TxtNvStat.Text = "NVIDIA GPU detected. Profile Inspector downloads from official GitHub on first use."
    } else {
        $CbNvidia.IsEnabled = $false; $CbNvidia.IsChecked = $false
        $TxtNvStat.Text = "No NVIDIA GPU detected - NVIDIA profile tweak disabled."
    }

    $state = Load-State
    $boxes = @{}
    foreach($t in $Tweaks){
        $panel = $tabMap[$t.Tab]
        if(-not $panel){ continue }
        $cb = New-Object System.Windows.Controls.CheckBox
        $applied = $state.Applied -and $state.Applied[$t.Id]
        $cb.Content = if($applied){ "$($t.Title)   [applied]" } else { $t.Title }
        $cb.IsChecked = (-not $applied)
        $cb.IsEnabled = (-not $applied)
        if($t.Desc){ $cb.ToolTip = $t.Desc }
        $panel.Children.Add($cb) | Out-Null
        $boxes[$t.Id] = $cb
    }

    $selectedExe = [ref]$null

    $BtnPickExe.Add_Click({
        $dlg = New-Object System.Windows.Forms.OpenFileDialog
        $dlg.Filter = 'Game executables (*.exe)|*.exe'
        $dlg.Title = 'Select game executable'
        if($dlg.ShowDialog() -eq 'OK'){
            $selectedExe.Value = $dlg.FileName
            $TxtExePath.Text = $dlg.FileName
        }
    })
    $BtnAll.Add_Click({ foreach($k in $boxes.Keys){ if($boxes[$k].IsEnabled){ $boxes[$k].IsChecked=$true } } })
    $BtnNone.Add_Click({ foreach($k in $boxes.Keys){ $boxes[$k].IsChecked=$false } })

    $BtnApply.Add_Click({
        $sel = @(); foreach($k in $boxes.Keys){ if($boxes[$k].IsChecked -and $boxes[$k].IsEnabled){ $sel += $k } }
        $perGame = $null
        if($selectedExe.Value){
            if($CbNvidia.IsChecked -and (Test-NvidiaPresent)){
                if(-not (Ensure-Npi $win)){ $CbNvidia.IsChecked = $false }
            }
            $perGame = @{
                Exe      = $selectedExe.Value
                GpuPref  = [bool]$CbGpuPref.IsChecked
                Fso      = [bool]$CbFso.IsChecked
                Shortcut = [bool]$CbShortcut.IsChecked
                Nvidia   = [bool]($CbNvidia.IsChecked -and (Test-NvidiaPresent) -and (Test-Path $NpiPath))
            }
        }
        if($sel.Count -eq 0 -and -not $perGame){
            [System.Windows.MessageBox]::Show($win,"Nothing selected.","PerfTweaker",'OK','Information') | Out-Null; return
        }
        $summary = "$($sel.Count) system tweaks"
        if($perGame){ $summary += " + per-game ($([System.IO.Path]::GetFileName($perGame.Exe)))" }
        $confirm = [System.Windows.MessageBox]::Show($win,"Apply: $summary ?`nRestore point + registry backup run first.","Confirm Apply",'YesNo','Question')
        if($confirm -ne 'Yes'){ return }
        if(Invoke-Apply $sel $perGame $win){ $win.Close() }
    })
    $BtnUndo.Add_Click({
        $c = [System.Windows.MessageBox]::Show($win,"Revert every change PerfTweaker applied?","Confirm Undo",'YesNo','Warning')
        if($c -eq 'Yes'){ Invoke-UndoAll $win; $win.Close() }
    })

    [void]$win.ShowDialog()
}

Show-UI
