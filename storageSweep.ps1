<# StorageSweep.ps1 —#>

#------------------------------ Config ------------------------------

function Write-Log {
  param([string]$Message)
  if (!(Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
  $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
  $line = "[$stamp] $Message"
  Write-Host $line
  Add-Content -Path $LogFile -Value $line
}

#log rotation
$LogDir  = 'C:\Logs'
if (!(Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }

#log file timestamps
$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$LogFile   = Join-Path $LogDir "StorageMaintenance_$timestamp.log"

# 5 most recent logs
$logs = Get-ChildItem -Path $LogDir -Filter "StorageMaintenance_*.log" | Sort-Object LastWriteTime -Descending
if ($logs.Count -gt 5) {
    $logs | Select-Object -Skip 5 | Remove-Item -Force
}

function Load-DotEnv {
    param([string]$Path = ".env")

    if (!(Test-Path $Path)) {
        Write-Log "WARNING: .env file not found at $Path"
        return @{}
    }

    $vars = @{}
    foreach ($line in Get-Content $Path) {
        if ($line -match '^\s*#') { continue }       # skip comments
        if (-not $line.Contains('=')) { continue }   # skip malformed
        $parts = $line.Split('=', 2)
        $name  = $parts[0].Trim()
        $value = $parts[1].Trim()
        $vars[$name] = $value
    }
    return $vars
}

$envVars = Load-DotEnv -Path (Join-Path $PSScriptRoot '.env')
foreach ($k in 'HA_URL','HA_TOKEN','CAM_ONE','CAM_TWO','DEST_ONE','DEST_TWO') {
  if (-not $envVars[$k]) { Write-Log "ERROR: .env missing $k"; exit 1 }
}


$Paths = @{
  EFrontSrc = $envVars['CAM_ONE']
  EBackSrc  = $envVars['CAM_TWO']
  DFrontDst = $envVars['DEST_ONE']
  DBackDst  = $envVars['DEST_TWO']
  DRoot     = 'D:\'
  ERoot     = 'E:\'
  FRoot     = 'F:\'
  CLogRoot  = 'C:\inetpub\logs\LogFiles\FTPSVC2'  
}
$IgnoreName = 'DVRWorkDirectory'




# safety
$DryRun = $true
$AbortIfNotAdmin = $true



# Home Assistant notify
$HA = @{
  Enabled     = $true
  BaseUrl     = $envVars['HA_URL']
  Token       = $envVars['HA_TOKEN']
  NotifySvc   = 'notify.mobile_app_tomgalaxy'     
  Title       = 'PC storage maintenance'
}

#---------------------------- Functions ----------------------------


function Assert-Admin {
  if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
    if ($AbortIfNotAdmin) { Write-Log "ERROR: Script must run as Administrator."; exit 1 }
    else { Write-Log "WARNING: Not running as Administrator, some operations may fail." }
  }
}

function Get-FreePercent {
  param([Parameter(Mandatory)][char]$Drive)
  try {
    $disk = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$($Drive):'"
    if (-not $disk) { throw "Drive $Drive`: not found." }
    if ($disk.Size -le 0) { return 0 }
    return [math]::Round(($disk.FreeSpace / $disk.Size) * 100, 2)
  } catch { Write-Log "ERROR: Get-FreePercent $Drive`: $_"; return 0 }
}

function Ensure-Dir { param([string]$Path) if (!(Test-Path $Path)) { if ($DryRun){Write-Log "[DryRun] Create directory $Path"} else {New-Item -ItemType Directory -Path $Path -Force | Out-Null} } }

function Move-ItemsIgnoringName {
  param([Parameter(Mandatory)][string]$Source,[Parameter(Mandatory)][string]$Destination,[string]$Ignore = $IgnoreName)
  if (!(Test-Path $Source)) { Write-Log "INFO: Source missing, skipping: $Source"; return }
  Ensure-Dir $Destination
  $items = Get-ChildItem -LiteralPath $Source -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne $Ignore }
  foreach ($it in $items) {
    if ($DryRun) { Write-Log "[DryRun] Move '$($it.FullName)' -> '$Destination'" }
    else {
      try { Move-Item -LiteralPath $it.FullName -Destination $Destination -Force -ErrorAction Stop; Write-Log "Moved: '$($it.FullName)' -> '$Destination'" }
      catch { Write-Log "ERROR: Move '$($it.FullName)' -> '$Destination' failed. $_" }
    }
  }
}

function Clear-DriveRoot {
  param([Parameter(Mandatory)][char]$Drive)
  $systemDrive = [System.IO.Path]::GetPathRoot($env:SystemRoot).TrimEnd('\').TrimEnd(':')
  if ($Drive.ToString().ToUpper() -eq $systemDrive.ToUpper()) { throw "Refusing to wipe the system drive $Drive`:" }
  $root = "$Drive`:\"
  if (!(Test-Path $root)) { throw "Drive $Drive`: not found" }
  $items = Get-ChildItem -LiteralPath $root -Force -ErrorAction SilentlyContinue
  foreach ($it in $items) {
    if ($DryRun) { Write-Log "[DryRun] Remove '$($it.FullName)'" }
    else {
      try { Remove-Item -LiteralPath $it.FullName -Recurse -Force -ErrorAction Stop; Write-Log "Removed: '$($it.FullName)'" }
      catch { Write-Log "ERROR: Remove '$($it.FullName)' failed. $_" }
    }
  }
}

function Move-AllFromTo {
  param([Parameter(Mandatory)][string]$FromRoot,[Parameter(Mandatory)][string]$ToRoot,[switch]$CreateSubdirWithTimestamp)
  if (!(Test-Path $FromRoot)) { throw "Source root not found: $FromRoot" }
  if (!(Test-Path $ToRoot))   { throw "Destination root not found: $ToRoot" }
  $dest = if ($CreateSubdirWithTimestamp){ $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'; $d = Join-Path $ToRoot ("_Migrated_" + $stamp); Ensure-Dir $d; $d } else { $ToRoot }
  $items = Get-ChildItem -LiteralPath $FromRoot -Force -ErrorAction SilentlyContinue
  foreach ($it in $items) {
    if ($CreateSubdirWithTimestamp -and ($it.FullName -eq $dest)) { continue }
    if ($DryRun) { Write-Log "[DryRun] Move '$($it.FullName)' -> '$dest'" }
    else {
      try { Move-Item -LiteralPath $it.FullName -Destination $dest -Force -ErrorAction Stop; Write-Log "Moved: '$($it.FullName)' -> '$dest'" }
      catch { Write-Log "ERROR: Move '$($it.FullName)' -> '$dest' failed. $_" }
    }
  }
}

function Send-HA-Notification {
  param([Parameter(Mandatory)][string]$Title,[Parameter(Mandatory)][string]$Message)
  Write-Log "Entering Send-HA-Notification (DryRun=$DryRun, Enabled=$($HA.Enabled))" 
  if (-not $HA.Enabled) { Write-Log "HA disabled, skipping notification."; return }
  if ([string]::IsNullOrWhiteSpace($HA.Token) -or [string]::IsNullOrWhiteSpace($HA.BaseUrl) -or [string]::IsNullOrWhiteSpace($HA.NotifySvc)) {
    Write-Log "WARNING: HA notify enabled but BaseUrl, Token, or NotifySvc is not set."; return
  }

  # convert notify.mobile_app_xxx -> notify/mobile_app_xxx
  $svcPath = $HA.NotifySvc -replace '^\s*notify\.', 'notify/'
  $url = "$($HA.BaseUrl.TrimEnd('/'))/api/services/$svcPath"
  $headers = @{ Authorization = "Bearer $($HA.Token)" }
  $body = @{ title = $Title; message = $Message } | ConvertTo-Json

  try {
    if ($DryRun) { Write-Log "[DryRun] (Notification still sent) HA notify POST $url body=$body" }
    else { Write-Log "HA notify POST $url body=$body" }

    # always send even in DryRun
    Invoke-RestMethod -Method Post -Uri $url -Headers $headers -Body $body -ContentType 'application/json' | Out-Null
    Write-Log "Sent HA notification."
  } catch {
    Write-Log "ERROR: HA notification failed. $_"
  }
}


# purge files helper
function Purge-LogFiles {
  param([Parameter(Mandatory)][string]$Root,[string]$Filter = '*.log')
  if (!(Test-Path $Root)) { Write-Log "INFO: Log path not found, skipping: $Root"; return }
  $files = Get-ChildItem -LiteralPath $Root -Filter $Filter -File -Recurse -Force -ErrorAction SilentlyContinue
  if (-not $files) { Write-Log "INFO: No log files matched at $Root"; return }
  $count = 0; $bytes = 0
  foreach ($f in $files) {
    $bytes += ($f.Length)
    if ($DryRun) { Write-Log "[DryRun] Delete $($f.FullName)" }
    else {
      try { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop; $count++ }
      catch { Write-Log "ERROR: Delete failed for $($f.FullName). $_" }
    }
  }
  if ($DryRun) { Write-Log "[DryRun] Would delete $($files.Count) files, size $([math]::Round($bytes/1MB,2)) MB from $Root" }
  else { Write-Log "Deleted $count files, freed approx $([math]::Round($bytes/1MB,2)) MB from $Root" }
}

#---------------------------- Main Logic ----------------------------
Assert-Admin
Write-Log "---- StorageSweep start ----"

# C: free space check and IIS FTP log purge
$freeC = Get-FreePercent 'C'
Write-Log "C: free = $freeC%"
if ($freeC -lt 10) {
  Write-Log "C: free < 10%. Purging IIS FTP logs at $($Paths.CLogRoot)"
  Purge-LogFiles -Root $Paths.CLogRoot -Filter '*.log'
}

# E: logic
$freeE = Get-FreePercent 'E'
Write-Log "E: free = $freeE%"

if ($freeE -lt 10) {
  Write-Log "Condition 2a met. E: free < 10%."
  Send-HA-Notification -Title $HA.Title -Message "E: free space is $freeE%. Starting folder moves to D:"

  Move-ItemsIgnoringName -Source $Paths.EFrontSrc -Destination $Paths.DFrontDst -Ignore $IgnoreName
  Move-ItemsIgnoringName -Source $Paths.EBackSrc  -Destination $Paths.DBackDst  -Ignore $IgnoreName

  $freeD = Get-FreePercent 'D'
  Write-Log "D: free after E->D moves = $freeD%"
  if ($freeD -lt 10) {
    Write-Log "D: free < 10%. Attempting D: -> F: migration."
    try {
      Move-AllFromTo -FromRoot $Paths.DRoot -ToRoot $Paths.FRoot -CreateSubdirWithTimestamp
      Write-Log "D: -> F: migration attempted."
    } catch {
      Write-Log "D: -> F: migration failed. $_"
      Write-Log "Wiping D:, then moving E: contents into D:."
      try { Clear-DriveRoot -Drive 'D' } catch { Write-Log "ERROR wiping D:: $_" }
      try { Move-AllFromTo -FromRoot $Paths.ERoot -ToRoot $Paths.DRoot; Write-Log "Moved all contents of E: -> D:" }
      catch { Write-Log "ERROR moving E: -> D: $_" }
    }
  } else {
    Write-Log "D: has sufficient free space, no cascade action required."
  }
} else {
  Write-Log "E: free >= 10%. No action."
  if ($DryRun) {
    Write-Log "DryRun = $DryRun sending HA notification anyways..."
    Send-HA-Notification -Title "Storage Dry Run" -Message "E: free space is $freeE%."
  }
}

Write-Log "---- StorageSweep complete ----"
