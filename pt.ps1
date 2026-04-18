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
function Set-Reg($p,$n,$v,$t='DWord'){
    try{ Ensure-Key $p }catch{ Log "Ensure-Key failed $p : $_"; return $false }
    try{
        Set-ItemProperty -Path $p -Name $n -Value $v -Type $t -Force -ErrorAction Stop
        return $true
    }catch{
        Log "Set-Reg denied $p\$n : $_"
        try{
            $hive,$sub = if($p -match '^HKCU:\\(.*)$'){ 'HKCU',$Matches[1] }
                         elseif($p -match '^HKLM:\\(.*)$'){ 'HKLM',$Matches[1] }
                         elseif($p -match '^HKCR:\\(.*)$'){ 'HKCR',$Matches[1] }
                         else { $null,$null }
            if($hive){
                $typeArg = switch($t){ 'DWord'{'REG_DWORD'} 'QWord'{'REG_QWORD'} 'String'{'REG_SZ'} 'ExpandString'{'REG_EXPAND_SZ'} 'MultiString'{'REG_MULTI_SZ'} 'Binary'{'REG_BINARY'} default {'REG_SZ'} }
                & reg.exe add "$hive\$sub" /v $n /t $typeArg /d "$v" /f 2>&1 | Out-Null
                if($LASTEXITCODE -eq 0){ return $true }
            }
        }catch{ Log "reg.exe fallback failed $p\$n : $_" }
        return $false
    }
}
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

# ===== POWER & CPU (extras) =====
Add-Tweak 'fast_startup_off' 'Power & CPU' 'Disable Fast Startup (hybrid boot)' 'Cleaner cold boot. Slightly longer boot but fewer wake-from-hibernation driver quirks.' {
    $s=@(); $p='HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power'
    $s += Snap-Reg $p 'HiberbootEnabled'
    Set-Reg $p 'HiberbootEnabled' 0
    ,$s
}
Add-Tweak 'monitor_never_ac' 'Power & CPU' 'Display: never turn off on AC' 'Prevents display blanking during long loads, cutscenes, streams.' {
    powercfg /setacvalueindex scheme_current sub_video videoidle 0 2>$null | Out-Null
    powercfg /setactive scheme_current 2>$null | Out-Null
    ,@(@{ Kind='powercfg_set'; Setting='VIDEOIDLE' })
}
Add-Tweak 'sleep_never_ac' 'Power & CPU' 'Sleep: never on AC' 'PC stays awake during big downloads/shader compiles.' {
    powercfg /setacvalueindex scheme_current sub_sleep standbyidle 0 2>$null | Out-Null
    powercfg /setactive scheme_current 2>$null | Out-Null
    ,@(@{ Kind='powercfg_set'; Setting='STANDBYIDLE' })
}
Add-Tweak 'distribute_timers' 'Power & CPU' 'DistributeTimers = 1 (spread timers across CPUs)' 'Reduces timer contention on a single core when many processes set timers.' {
    $s=@(); $p='HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\kernel'
    $s += Snap-Reg $p 'DistributeTimers'
    Set-Reg $p 'DistributeTimers' 1
    ,$s
}
Add-Tweak 'global_timer_res' 'Power & CPU' 'GlobalTimerResolutionRequests = 1' 'Lets any app request high-resolution timers system-wide (Win11 per-process default otherwise).' {
    $s=@(); $p='HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\kernel'
    $s += Snap-Reg $p 'GlobalTimerResolutionRequests'
    Set-Reg $p 'GlobalTimerResolutionRequests' 1
    ,$s
}
Add-Tweak 'perfboost_aggressive' 'Power & CPU' 'Processor Performance Boost Mode = Aggressive' 'Turbo/boost engages faster and more often under load.' {
    powercfg /setacvalueindex scheme_current sub_processor PERFBOOSTMODE 2 2>$null | Out-Null
    powercfg /setactive scheme_current 2>$null | Out-Null
    ,@(@{ Kind='powercfg_set'; Setting='PERFBOOSTMODE' })
}

# ===== GPU & DISPLAY (extras) =====
Add-Tweak 'mpo_off' 'GPU & Display' 'Disable Multi-Plane Overlay (MPO)' 'Fixes stutter/flicker on many GPUs, especially Chrome/DWM compositing bugs.' {
    $s=@(); $p='HKLM:\SOFTWARE\Microsoft\Windows\Dwm'
    $s += Snap-Reg $p 'OverlayTestMode'
    Set-Reg $p 'OverlayTestMode' 5
    ,$s
}
Add-Tweak 'vrr_windowed_on' 'GPU & Display' 'Enable VRR for windowed games' 'G-Sync / FreeSync works in borderless-window mode, not just exclusive fullscreen.' {
    $s=@(); $p='HKCU:\Software\Microsoft\DirectX\UserGpuPreferences'
    $s += Snap-Reg $p 'DirectXUserGlobalSettings'
    Set-Reg $p 'DirectXUserGlobalSettings' 'VRROptimizeEnable=1;' 'String'
    ,$s
}
Add-Tweak 'fse_legacy_off' 'GPU & Display' 'Disable legacy GameDVR FSE feature flags' 'Complements the true-fullscreen tweak by clearing old FSE enforcement bits.' {
    $s=@(); $p='HKCU:\System\GameConfigStore'
    $s += Snap-Reg $p 'GameDVR_EFSEFeatureFlags'
    Set-Reg $p 'GameDVR_EFSEFeatureFlags' 0
    ,$s
}
Add-Tweak 'mmcss_dx_priority' 'GPU & Display' 'MMCSS DirectX task: GPU Prio 8 / Prio 6' 'Raises Direct3D scheduling priority alongside the Games task.' {
    $s=@(); $p='HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\DirectX'
    $s += Snap-Reg $p 'GPU Priority'
    $s += Snap-Reg $p 'Priority'
    Set-Reg $p 'GPU Priority' 8
    Set-Reg $p 'Priority' 6
    ,$s
}

# ===== NETWORK (extras) =====
Add-Tweak 'default_ttl_64' 'Network' 'DefaultTTL = 64' 'Standard Linux-style TTL; avoids some older NAT bugs.' {
    $s=@(); $p='HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters'
    $s += Snap-Reg $p 'DefaultTTL'
    Set-Reg $p 'DefaultTTL' 64
    ,$s
}
Add-Tweak 'tcp1323opts_on' 'Network' 'Tcp1323Opts = 1 (window scaling + timestamps)' 'Enables large TCP window scaling; essential on gigabit.' {
    $s=@(); $p='HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters'
    $s += Snap-Reg $p 'Tcp1323Opts'
    Set-Reg $p 'Tcp1323Opts' 1
    ,$s
}
Add-Tweak 'tcp_retrans_3' 'Network' 'TcpMaxDataRetransmissions = 3' 'Faster connection teardown on dropped links instead of hanging.' {
    $s=@(); $p='HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters'
    $s += Snap-Reg $p 'TcpMaxDataRetransmissions'
    Set-Reg $p 'TcpMaxDataRetransmissions' 3
    ,$s
}
Add-Tweak 'tcp_timedwait_30' 'Network' 'TcpTimedWaitDelay = 30s' 'Recycles ephemeral ports quicker after connection close.' {
    $s=@(); $p='HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters'
    $s += Snap-Reg $p 'TcpTimedWaitDelay'
    Set-Reg $p 'TcpTimedWaitDelay' 30
    ,$s
}
Add-Tweak 'ie_max_connections' 'Network' 'Max HTTP connections per server = 10' 'Faster Steam/Epic/browser parallel downloads.' {
    $s=@(); $p='HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
    $s += Snap-Reg $p 'MaxConnectionsPer1_0Server'
    $s += Snap-Reg $p 'MaxConnectionsPerServer'
    Set-Reg $p 'MaxConnectionsPer1_0Server' 10
    Set-Reg $p 'MaxConnectionsPerServer' 10
    ,$s
}
Add-Tweak 'prefer_ipv4' 'Network' 'Prefer IPv4 over IPv6' 'Avoids IPv6 resolution lag for games that only use IPv4. IPv6 still works.' {
    $s=@(); $p='HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip6\Parameters'
    $s += Snap-Reg $p 'DisabledComponents'
    Set-Reg $p 'DisabledComponents' 0x20
    ,$s
}
Add-Tweak 'rss_on' 'Network' 'Enable Receive Side Scaling (RSS)' 'Spreads NIC interrupts across CPU cores; reduces packet-processing bottleneck.' {
    & netsh int tcp set global rss=enabled 2>$null | Out-Null
    ,@(@{ Kind='netsh_rss'; Prev='default' })
}
Add-Tweak 'autotuning_normal' 'Network' 'TCP autotuning level = normal' 'Restores default dynamic window scaling if a previous tool disabled it.' {
    & netsh int tcp set global autotuninglevel=normal 2>$null | Out-Null
    ,@(@{ Kind='netsh_autotune'; Prev='default' })
}

# ===== GAMING (extras) =====
Add-Tweak 'kb_delay_min' 'Gaming' 'Keyboard repeat delay = shortest' 'Faster key-repeat kick-in (e.g. chat spam, menus).' {
    $s=@(); $p='HKCU:\Control Panel\Keyboard'
    $s += Snap-Reg $p 'KeyboardDelay'
    Set-Reg $p 'KeyboardDelay' '0' 'String'
    ,$s
}
Add-Tweak 'kb_speed_max' 'Gaming' 'Keyboard repeat rate = fastest' 'Max KeyboardSpeed once repeating.' {
    $s=@(); $p='HKCU:\Control Panel\Keyboard'
    $s += Snap-Reg $p 'KeyboardSpeed'
    Set-Reg $p 'KeyboardSpeed' '31' 'String'
    ,$s
}
Add-Tweak 'sticky_keys_prompt_off' 'Gaming' 'Disable Sticky Keys shortcut prompt' 'No popup when tapping Shift 5 times during a match.' {
    $s=@(); $p='HKCU:\Control Panel\Accessibility\StickyKeys'
    $s += Snap-Reg $p 'Flags'
    Set-Reg $p 'Flags' '506' 'String'
    ,$s
}
Add-Tweak 'filter_keys_prompt_off' 'Gaming' 'Disable Filter Keys shortcut prompt' 'No popup when holding Right-Shift.' {
    $s=@(); $p='HKCU:\Control Panel\Accessibility\Keyboard Response'
    $s += Snap-Reg $p 'Flags'
    Set-Reg $p 'Flags' '122' 'String'
    ,$s
}
Add-Tweak 'xbox_historical_capture_off' 'Gaming' 'Disable background Xbox game capture' 'Stops silent DVR buffering (CPU + disk savings).' {
    $s=@(); $p='HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR'
    $s += Snap-Reg $p 'HistoricalCaptureEnabled'
    Set-Reg $p 'HistoricalCaptureEnabled' 0
    ,$s
}

# ===== SERVICES (extras) =====
Add-Tweak 'bits_manual' 'Services' 'BITS (Background Intelligent Transfer) -> Manual' 'Windows Update/Store still work; stops idle background transfers.' {
    $snap = Snap-Svc 'BITS'; Set-Svc 'BITS' 'Manual'; ,@($snap)
}
Add-Tweak 'wisvc_off' 'Services' 'Windows Insider Service -> Disabled' 'Only used by the Insider Program. Safe off for most users.' {
    $snap = Snap-Svc 'wisvc'; Set-Svc 'wisvc' 'Disabled'; ,@($snap)
}
Add-Tweak 'cscservice_manual' 'Services' 'Offline Files (CscService) -> Manual' 'Only used by Domain-joined PCs with Offline Files. Manual lets it start on demand.' {
    $snap = Snap-Svc 'CscService'; Set-Svc 'CscService' 'Manual'; ,@($snap)
}
Add-Tweak 'phonesvc_manual' 'Services' 'Phone Service -> Manual' 'Legacy cellular API. Manual is safe even on cellular laptops.' {
    $snap = Snap-Svc 'PhoneSvc'; Set-Svc 'PhoneSvc' 'Manual'; ,@($snap)
}
Add-Tweak 'wallet_manual' 'Services' 'WalletService -> Manual' 'Only invoked by Microsoft Wallet / UWP payments.' {
    $snap = Snap-Svc 'WalletService'; Set-Svc 'WalletService' 'Manual'; ,@($snap)
}
Add-Tweak 'wia_manual' 'Services' 'Windows Image Acquisition (stisvc) -> Manual' 'Still starts on demand when scanning; idle saved otherwise.' {
    $snap = Snap-Svc 'stisvc'; Set-Svc 'stisvc' 'Manual'; ,@($snap)
}
Add-Tweak 'dps_manual' 'Services' 'Diagnostic Policy Service -> Manual' 'Troubleshooters still launch on demand; stops idle polling.' {
    $snap = Snap-Svc 'DPS'; Set-Svc 'DPS' 'Manual'; ,@($snap)
}

# ===== PRIVACY (extras) =====
Add-Tweak 'location_sensor_off' 'Privacy' 'Disable system-wide Location access' 'Blocks all apps from reading GPS / IP location.' {
    $s=@(); $p='HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Sensor\Overrides\{BFA794E4-F964-4FDB-90F6-51056BFE4B44}'
    $s += Snap-Reg $p 'SensorPermissionState'
    Set-Reg $p 'SensorPermissionState' 0
    ,$s
}
Add-Tweak 'find_my_device_off' 'Privacy' 'Disable Find My Device' 'Stops periodic location reporting to Microsoft.' {
    $s=@(); $p='HKLM:\SOFTWARE\Microsoft\Settings\FindMyDevice'
    $s += Snap-Reg $p 'LocationSyncEnabled'
    Set-Reg $p 'LocationSyncEnabled' 0
    ,$s
}
Add-Tweak 'feedback_freq_off' 'Privacy' 'Stop Windows feedback prompts' 'No more "How satisfied are you with Windows" toasts.' {
    $s=@(); $p='HKCU:\Software\Microsoft\Siuf\Rules'
    $s += Snap-Reg $p 'NumberOfSIUFInPeriod'
    $s += Snap-Reg $p 'PeriodInNanoSeconds'
    Set-Reg $p 'NumberOfSIUFInPeriod' 0
    Set-Reg $p 'PeriodInNanoSeconds' 0
    ,$s
}
Add-Tweak 'bing_start_search_off' 'Privacy' 'Disable Bing / web results in Start search' 'Start menu searches stay local. Faster typing response.' {
    $s=@(); $p='HKCU:\Software\Microsoft\Windows\CurrentVersion\Search'
    $s += Snap-Reg $p 'BingSearchEnabled'
    $s += Snap-Reg $p 'CortanaConsent'
    Set-Reg $p 'BingSearchEnabled' 0
    Set-Reg $p 'CortanaConsent' 0
    ,$s
}
Add-Tweak 'wifi_sense_off' 'Privacy' 'Disable Wi-Fi Sense auto-connect' 'Stops auto-joining open/crowdsourced hotspots.' {
    $s=@(); $p='HKLM:\SOFTWARE\Microsoft\WcmSvc\wifinetworkmanager\config'
    $s += Snap-Reg $p 'AutoConnectAllowedOEM'
    Set-Reg $p 'AutoConnectAllowedOEM' 0
    ,$s
}
Add-Tweak 'ceip_off' 'Privacy' 'Disable Customer Experience Improvement Program' 'Stops anonymous usage-stat uploads (SQM).' {
    $s=@(); $p='HKLM:\SOFTWARE\Microsoft\SQMClient\Windows'
    $s += Snap-Reg $p 'CEIPEnable'
    Set-Reg $p 'CEIPEnable' 0
    ,$s
}

# ===== VISUAL & STARTUP (extras) =====
Add-Tweak 'taskbar_search_off' 'Visual & Startup' 'Taskbar search box: hidden' 'Reclaims taskbar space. Win+S still opens search.' {
    $s=@(); $p='HKCU:\Software\Microsoft\Windows\CurrentVersion\Search'
    $s += Snap-Reg $p 'SearchboxTaskbarMode'
    Set-Reg $p 'SearchboxTaskbarMode' 0
    ,$s
}
Add-Tweak 'taskbar_align_left' 'Visual & Startup' 'Taskbar alignment: left' 'Classic Windows alignment instead of centered.' {
    $s=@(); $p='HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
    $s += Snap-Reg $p 'TaskbarAl'
    Set-Reg $p 'TaskbarAl' 0
    ,$s
}
Add-Tweak 'taskbar_chat_off' 'Visual & Startup' 'Hide Taskbar Chat icon' 'Removes Teams Consumer chat button.' {
    $s=@(); $p='HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
    $s += Snap-Reg $p 'TaskbarMn'
    Set-Reg $p 'TaskbarMn' 0
    ,$s
}
Add-Tweak 'task_view_btn_off' 'Visual & Startup' 'Hide Task View button' 'Win+Tab keyboard shortcut still works.' {
    $s=@(); $p='HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
    $s += Snap-Reg $p 'ShowTaskViewButton'
    Set-Reg $p 'ShowTaskViewButton' 0
    ,$s
}
Add-Tweak 'quick_access_recent_off' 'Visual & Startup' 'Hide recent/frequent files in Quick Access' 'Privacy + cleaner Explorer home.' {
    $s=@(); $p='HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer'
    $s += Snap-Reg $p 'ShowRecent'
    $s += Snap-Reg $p 'ShowFrequent'
    Set-Reg $p 'ShowRecent' 0
    Set-Reg $p 'ShowFrequent' 0
    ,$s
}
Add-Tweak 'explorer_launch_this_pc' 'Visual & Startup' 'Explorer opens to This PC' 'Instead of Home/Quick Access tab.' {
    $s=@(); $p='HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
    $s += Snap-Reg $p 'LaunchTo'
    Set-Reg $p 'LaunchTo' 1
    ,$s
}
Add-Tweak 'copilot_btn_off' 'Visual & Startup' 'Hide Copilot taskbar button' 'Copilot app still launchable from Start.' {
    $s=@(); $p='HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
    $s += Snap-Reg $p 'ShowCopilotButton'
    Set-Reg $p 'ShowCopilotButton' 0
    ,$s
}
Add-Tweak 'menu_show_fast' 'Visual & Startup' 'MenuShowDelay = 0 (instant menus)' 'Start menu / context menus open instantly.' {
    $s=@(); $p='HKCU:\Control Panel\Desktop'
    $s += Snap-Reg $p 'MenuShowDelay'
    Set-Reg $p 'MenuShowDelay' '0' 'String'
    ,$s
}
Add-Tweak 'hung_app_fast' 'Visual & Startup' 'Shorter hung-app timeout on shutdown' 'Windows flags frozen apps faster on logoff/shutdown.' {
    $s=@(); $p='HKCU:\Control Panel\Desktop'
    $s += Snap-Reg $p 'HungAppTimeout'
    $s += Snap-Reg $p 'WaitToKillAppTimeout'
    Set-Reg $p 'HungAppTimeout' '1000' 'String'
    Set-Reg $p 'WaitToKillAppTimeout' '2000' 'String'
    ,$s
}

# ===== CLEANUP (extras) =====
Add-Tweak 'clear_prefetch' 'Cleanup' 'Clear Prefetch folder' 'Windows regenerates entries on next run; clears stale data.' {
    $removed = 0
    if(Test-Path 'C:\Windows\Prefetch'){
        Get-ChildItem 'C:\Windows\Prefetch' -Filter '*.pf' -Force -ErrorAction SilentlyContinue | ForEach-Object {
            try{ Remove-Item $_.FullName -Force -ErrorAction Stop; $removed++ }catch{}
        }
    }
    ,@(@{ Kind='info'; Removed=$removed })
}
Add-Tweak 'clear_thumb_cache' 'Cleanup' 'Clear Explorer thumbnail cache' 'Rebuilds on browse; fixes stale/corrupt icons.' {
    $removed = 0
    $path = Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Explorer'
    if(Test-Path $path){
        Get-ChildItem $path -Filter 'thumbcache_*.db' -Force -ErrorAction SilentlyContinue | ForEach-Object {
            try{ Remove-Item $_.FullName -Force -ErrorAction Stop; $removed++ }catch{}
        }
    }
    ,@(@{ Kind='info'; Removed=$removed })
}
Add-Tweak 'clear_do_cache' 'Cleanup' 'Clear Delivery Optimization cache' 'Frees GBs if Windows has been seeding updates to other PCs.' {
    $removed = 0
    $path = 'C:\Windows\SoftwareDistribution\DeliveryOptimization\Cache'
    if(Test-Path $path){
        Get-ChildItem $path -Force -ErrorAction SilentlyContinue | ForEach-Object {
            try{ Remove-Item $_.FullName -Recurse -Force -ErrorAction Stop; $removed++ }catch{}
        }
    }
    ,@(@{ Kind='info'; Removed=$removed })
}
Add-Tweak 'clear_wer_reports' 'Cleanup' 'Clear Windows Error Report queue' 'Deletes old queued crash dumps.' {
    $removed = 0
    foreach($path in 'C:\ProgramData\Microsoft\Windows\WER\ReportQueue','C:\ProgramData\Microsoft\Windows\WER\ReportArchive'){
        if(Test-Path $path){
            Get-ChildItem $path -Force -ErrorAction SilentlyContinue | ForEach-Object {
                try{ Remove-Item $_.FullName -Recurse -Force -ErrorAction Stop; $removed++ }catch{}
            }
        }
    }
    ,@(@{ Kind='info'; Removed=$removed })
}
# ---------- descriptions fallback (for tweaks whose inline Desc is empty) ----------
$Descs = @{
    'prio_separation'            = 'Boosts foreground window (your game) over background processes.'
    'drivers_in_ram'             = 'Keeps kernel/drivers resident in RAM instead of pagefile. Recommended 16 GB+.'
    'power_throttling_off'       = 'Prevents Windows from throttling foreground apps to save battery.'
    'sys_responsiveness'         = 'Reserves 10% CPU for multimedia/games (default 20%).'
    'core_parking_off'           = 'All CPU cores stay active; no park latency.'
    'cpu_min_100'                = 'Minimum processor state = 100% on AC power.'
    'cpu_max_100'                = 'Maximum processor state capped at 100% (no artificial limit).'
    'usb_suspend_off'            = 'Stops Windows suspending USB devices. Prevents mouse/controller drop-outs.'
    'tdr_ddi_delay'              = 'Extra GPU DDI timeout grace period; avoids false hangs under heavy load.'
    'net_throttle_off'           = 'Removes Windows multimedia network throttle (helps online games on 1G+ lines).'
    'llmnr_off'                  = 'Disables Link-Local Multicast Name Resolution (rarely used, slight latency win).'
    'netbios_off'                = 'Disables NetBIOS over TCP/IP on all NICs (legacy LAN name service).'
    'teredo_off'                 = 'Disables Teredo IPv6 tunneling (not used by modern games).'
    'max_user_port'              = 'Raises ephemeral port range; avoids exhaustion with many concurrent connections.'
    'disable_gamebar'            = 'Turns off Xbox Game Bar overlay and Game DVR background recording.'
    'mmcss_games_prio'           = 'Elevates MMCSS Games task scheduling (GPU Priority 8, High I/O).'
    'fse_true_fullscreen'        = 'Forces true exclusive fullscreen for D3D games (bypasses DWM compositor).'
    'game_mode_on'               = 'Enables Windows Game Mode (foreground priority + reduced updates during play).'
    'audio_comm_none'            = 'Prevents Windows from ducking game audio when a voice call starts.'
    'sysmain_off'                = 'Disables SuperFetch/SysMain. Recommended on SSDs.'
    'wsearch_off'                = 'Disables Windows Search indexing service. Start menu search still works.'
    'diagtrack_off'              = 'Disables Connected User Experiences and Telemetry service.'
    'wer_off'                    = 'Disables Windows Error Reporting upload service.'
    'delivery_opt_off'           = 'Delivery Optimization to Manual. Windows Update still works directly.'
    'cdp_off'                    = 'Connected Devices Platform to Manual. Cross-device sharing paused.'
    'remote_reg_off'             = 'Disables Remote Registry service. Reduces attack surface.'
    'xbox_services_off'          = 'Xbox Live background services to Manual. Launch games normally.'
    'mapsbroker_off'             = 'Disables offline Maps download service.'
    'geolocation_off'            = 'Disables Geolocation service (IP-based location).'
    'retaildemo_off'             = 'Disables Retail Demo service (store display mode).'
    'pca_off'                    = 'Program Compatibility Assistant to Manual. Compat dialogs still appear on demand.'
    'tablet_input_off'           = 'Touch Keyboard / Handwriting to Manual. Only matters on touch devices.'
    'fax_off'                    = 'Disables Fax service. Almost nobody uses it.'
    'telemetry_basic'            = 'Sets AllowTelemetry=0 (minimum). Security-essential telemetry still works.'
    'cortana_off'                = 'Disables Cortana via policy.'
    'tips_ads_off'               = 'Turns off Tips, Suggestions, and Start/Settings ads.'
    'activity_history_off'       = 'Stops Windows Timeline / Activity Feed.'
    'lockscreen_ads_off'         = 'Disables Windows Spotlight / rotating ads on the lock screen.'
    'advertising_id_off'         = 'Disables per-user Advertising ID.'
    'app_launch_track_off'       = 'Stops Explorer tracking which apps you launch most.'
    'speech_rec_off'             = 'Disables online speech recognition (sending voice to MS).'
    'typing_pers_off'            = 'Disables Inking & Typing Personalization (keystroke harvesting).'
    'visual_fx_perf'             = 'Sets Visual Effects to "Best performance" (no animations/shadows).'
    'transparency_off'           = 'Disables Start/Taskbar transparency.'
    'animations_off'             = 'Disables minimize/maximize window animations.'
    'widgets_off'                = 'Hides the Widgets taskbar button and disables the pane.'
    'show_file_ext'              = 'Shows file extensions in Explorer (.exe, .ps1, etc).'
    'bg_apps_off'                = 'Disables background UWP/Store apps from running when closed.'
    'onedrive_autostart_off'     = 'Removes OneDrive from HKCU Run autostart.'
    'teams_autostart_off'        = 'Removes Teams (classic + new MSTeams) from HKCU Run autostart.'
    'clear_temp'                 = 'Deletes everything in %TEMP% that isn''t locked by a running process.'
    'clear_wu_cache'             = 'Clears Windows Update download cache (safe; WU re-downloads needed bits).'
    'flush_dns'                  = 'Flushes DNS resolver cache (ipconfig /flushdns).'
    'clear_font_cache'           = 'Clears font cache; Windows rebuilds on next login.'
    'pause_updates_7d'           = 'Sets all 6 PauseUpdates keys for 7 days (Win11 24H2-compatible).'
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
                    'netsh_teredo'   { & netsh interface teredo set state default 2>$null | Out-Null }
                    'netsh_rss'      { & netsh int tcp set global rss=default 2>$null | Out-Null }
                    'netsh_autotune' { & netsh int tcp set global autotuninglevel=normal 2>$null | Out-Null }
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
        <TextBlock Text="Windows 11 FPS &amp; latency tuner . 112 tweaks organized into 9 tabs . per-game profiles"
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
    $BtnAll     = $win.FindName('BtnAll')
    $BtnNone    = $win.FindName('BtnNone')
    $BtnApply   = $win.FindName('BtnApply')
    $BtnUndo    = $win.FindName('BtnUndo')

    $state = Load-State
    $boxes = @{}
    $bc = New-Object System.Windows.Media.BrushConverter
    $hintBg = $bc.ConvertFrom('#2A2A38')
    $hintFg = $bc.ConvertFrom('#C4B5FD')
    foreach($t in $Tweaks){
        $panel = $tabMap[$t.Tab]
        if(-not $panel){ continue }

        $row = New-Object System.Windows.Controls.StackPanel
        $row.Orientation = 'Horizontal'
        $row.Margin = (New-Object System.Windows.Thickness(0,3,0,3))

        $cb = New-Object System.Windows.Controls.CheckBox
        $applied = $state.Applied -and $state.Applied[$t.Id]
        $cb.Content = if($applied){ "$($t.Title)   [applied]" } else { $t.Title }
        $cb.IsChecked = (-not $applied)
        $cb.IsEnabled = (-not $applied)
        $cb.VerticalAlignment = 'Center'
        $row.Children.Add($cb) | Out-Null

        $desc = $t.Desc
        if([string]::IsNullOrWhiteSpace($desc) -and $Descs.ContainsKey($t.Id)){ $desc = $Descs[$t.Id] }
        if([string]::IsNullOrWhiteSpace($desc)){ $desc = $t.Title }

        $hint = New-Object System.Windows.Controls.Border
        $hint.Width = 18
        $hint.Height = 18
        $hint.CornerRadius = New-Object System.Windows.CornerRadius(9)
        $hint.Background = $hintBg
        $hint.Margin = (New-Object System.Windows.Thickness(10,0,0,0))
        $hint.VerticalAlignment = 'Center'
        $hint.Cursor = [System.Windows.Input.Cursors]::Help

        $tt = New-Object System.Windows.Controls.ToolTip
        $tt.Background = $bc.ConvertFrom('#1F1F2A')
        $tt.Foreground = $bc.ConvertFrom('#E5E7EB')
        $tt.BorderBrush = $bc.ConvertFrom('#8B5CF6')
        $tt.BorderThickness = New-Object System.Windows.Thickness(1)
        $tt.Padding = New-Object System.Windows.Thickness(10,8,10,8)
        $ttText = New-Object System.Windows.Controls.TextBlock
        $ttText.Text = $desc
        $ttText.TextWrapping = 'Wrap'
        $ttText.MaxWidth = 360
        $tt.Content = $ttText
        $hint.ToolTip = $tt
        [System.Windows.Controls.ToolTipService]::SetInitialShowDelay($hint, 150)
        [System.Windows.Controls.ToolTipService]::SetShowDuration($hint, 20000)

        $q = New-Object System.Windows.Controls.TextBlock
        $q.Text = '?'
        $q.Foreground = $hintFg
        $q.FontWeight = 'Bold'
        $q.FontSize = 12
        $q.HorizontalAlignment = 'Center'
        $q.VerticalAlignment = 'Center'
        $hint.Child = $q

        $row.Children.Add($hint) | Out-Null
        $panel.Children.Add($row) | Out-Null
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
            $perGame = @{
                Exe      = $selectedExe.Value
                GpuPref  = [bool]$CbGpuPref.IsChecked
                Fso      = [bool]$CbFso.IsChecked
                Shortcut = [bool]$CbShortcut.IsChecked
                Nvidia   = $false
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
