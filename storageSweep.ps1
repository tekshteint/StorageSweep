#------------------------------ Config ------------------------------

function Write-Log {
  param([string]$Message)
  if (!(Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
  $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
  $line = "[$stamp] $Message"
  Write-Host $line 
  #if ($verbose) { Write-Host $line }
  Add-Content -Path $LogFile -Value $line
}

# Log rotation
$LogDir  = 'C:\Logs'
if (!(Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$LogFile   = Join-Path $LogDir "StorageMaintenance_$timestamp.log"
$logs = Get-ChildItem -Path $LogDir -Filter "StorageMaintenance_*.log" | Sort-Object LastWriteTime -Descending
if ($logs.Count -gt 5) { $logs | Select-Object -Skip 5 | Remove-Item -Force }

function Load-DotEnv {
  param([string]$Path = ".env")
  if (!(Test-Path $Path)) { Write-Log "WARNING: .env file not found at $Path"; return @{} }
  $vars = @{}
  foreach ($line in Get-Content $Path) {
    if ($line -match '^\s*#') { continue }
    if (-not $line.Contains('=')) { continue }
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

# Safety
$DryRun = $false
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

$MinAgeSeconds = 600

# Accept folder names like 2025-10-24, 20251024, 2025_10_24, 2025.10.24
function Get-FolderDateFromName {
  param([Parameter(Mandatory)][string]$Name)
  $patterns = @(
    '^(?<y>\d{4})[-_\.]?(?<m>\d{2})[-_\.]?(?<d>\d{2})$'  # 2025-10-24 / 20251024 / 2025_10_24 / 2025.10.24
  )
  foreach ($p in $patterns) {
    $m = [regex]::Match($Name, $p)
    if ($m.Success) {
      try {
        return [datetime]::new([int]$m.Groups['y'].Value, [int]$m.Groups['m'].Value, [int]$m.Groups['d'].Value)
      } catch {
        # fall through
      }
    }
  }
  return $null
}

function Should-SkipByDate {
  param([Parameter(Mandatory)][System.IO.FileSystemInfo]$Item)
  if (-not $Item.PSIsContainer) { return $false }

  $folderDate = Get-FolderDateFromName -Name $Item.Name
  if ($null -eq $folderDate) { return $false }

  $today    = (Get-Date).Date
  $tomorrow = $today.AddDays(1)

  if ($folderDate.Date -eq $today -or $folderDate.Date -eq $tomorrow) {
    return $true
  }

  return $false
}

function Test-InUse {
  param([Parameter(Mandatory)][string]$Path)
  try {
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    $item = Get-Item -LiteralPath $Path -Force
    if ($item.PSIsContainer) { return $false }  
    $fs = [System.IO.FileStream]::new(
      $item.FullName,
      [System.IO.FileMode]::Open,
      [System.IO.FileAccess]::ReadWrite,
      [System.IO.FileShare]::None
    )
    $fs.Close()
    return $false
  } catch {
    return $true
  }
}

function Test-ItemReady {
  param([Parameter(Mandatory)][System.IO.FileSystemInfo]$Item)
  # 1) age gate
  $ageSec = [int]((Get-Date) - $Item.LastWriteTime).TotalSeconds
  if ($ageSec -lt $MinAgeSeconds) { return $false }

  # 2) lock gate for files
  if (-not $Item.PSIsContainer) {
    return -not (Test-InUse -Path $Item.FullName)
  }

  $recentChild = Get-ChildItem -LiteralPath $Item.FullName -File -Recurse -Force -ErrorAction SilentlyContinue |
                 Where-Object { ((Get-Date) - $_.LastWriteTime).TotalSeconds -lt $MinAgeSeconds } |
                 Select-Object -First 1
  if ($recentChild) { return $false }

  return $true
}
function Test-HasContent {
  param([Parameter(Mandatory)][string]$Path)
  if (-not (Test-Path -LiteralPath $Path)) { return $false }
  $items = Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue |
           Where-Object { $_.Name -ne $IgnoreName }
  return ($items.Count -gt 0)
}


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

function Send-HA-Notification {
  param([Parameter(Mandatory)][string]$Title,[Parameter(Mandatory)][string]$Message)
  Write-Log "Entering Send-HA-Notification (DryRun=$DryRun, Enabled=$($HA.Enabled))"
  if (-not $HA.Enabled) { Write-Log "HA disabled, skipping notification."; return }
  if ([string]::IsNullOrWhiteSpace($HA.Token) -or [string]::IsNullOrWhiteSpace($HA.BaseUrl) -or [string]::IsNullOrWhiteSpace($HA.NotifySvc)) {
    Write-Log "WARNING: HA notify enabled but BaseUrl, Token, or NotifySvc is not set."; return
  }
  $svcPath = $HA.NotifySvc -replace '^\s*notify\.', 'notify/'
  $url = "$($HA.BaseUrl.TrimEnd('/'))/api/services/$svcPath"
  $headers = @{ Authorization = "Bearer $($HA.Token)" }
  $body = @{ title = $Title; message = $Message } | ConvertTo-Json
  try {
    if ($DryRun) { Write-Log "[DryRun] (Notification still sent) HA notify POST $url body=$body" } else { Write-Log "HA notify POST $url body=$body" }
    Invoke-RestMethod -Method Post -Uri $url -Headers $headers -Body $body -ContentType 'application/json' | Out-Null
    Write-Log "Sent HA notification."
  } catch { Write-Log "ERROR: HA notification failed. $_" }
}

function Purge-LogFiles {
  param([Parameter(Mandatory)][string]$Root,[string]$Filter = '*.log')
  if (!(Test-Path $Root)) { Write-Log "INFO: Log path not found, skipping: $Root"; return }
  $files = Get-ChildItem -LiteralPath $Root -Filter $Filter -File -Recurse -Force -ErrorAction SilentlyContinue
  if (-not $files) { Write-Log "INFO: No log files matched at $Root"; return }
  $count = 0; $bytes = 0
  foreach ($f in $files) {
    $bytes += $f.Length
    if ($DryRun) { Write-Log "[DryRun] Delete $($f.FullName)" }
    else {
      try { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop; $count++ }
      catch { Write-Log "ERROR: Delete failed for $($f.FullName). $_" }
    }
  }
  if ($DryRun) { Write-Log "[DryRun] Would delete $($files.Count) files, size $([math]::Round($bytes/1MB,2)) MB from $Root" }
  else { Write-Log "Deleted $count files, freed approx $([math]::Round($bytes/1MB,2)) MB from $Root" }
}

function Wipe-TargetDir {
  param([Parameter(Mandatory)][string]$TargetDir)
  if (!(Test-Path $TargetDir)) { Write-Log "INFO: Target dir missing, nothing to wipe: $TargetDir"; return }
  $items = Get-ChildItem -LiteralPath $TargetDir -Force -ErrorAction SilentlyContinue
  foreach ($it in $items) {
    if ($DryRun) { Write-Log "[DryRun] Remove '$($it.FullName)'" }
    else {
      try { Remove-Item -LiteralPath $it.FullName -Recurse -Force -ErrorAction Stop; Write-Log "Removed: '$($it.FullName)'" }
      catch { Write-Log "ERROR: Remove '$($it.FullName)' failed. $_" }
    }
  }
}


function Move-IntoDriveUntilCap {
  param(
    [Parameter(Mandatory)][string]$SourceDir,
    [Parameter(Mandatory)][string]$DestDir,
    [Parameter(Mandatory)][char]$DestDrive,
    [int]$CapUsedPercent = 90
  )
  $movedAny = $false
  $iterations = 0
  while ($true) {
    $iterations++
    $free = Get-FreePercent $DestDrive
    $used = 100 - $free
    if ($used -ge $CapUsedPercent) {
      Write-Log "Dest $DestDrive`: is at/over $CapUsedPercent% used (free=$free%). Stop moving into $DestDir."
      break
    }
    if (!(Test-Path $SourceDir)) { Write-Log "Source empty/missing: $SourceDir"; break }

    $batch = Get-ChildItem -LiteralPath $SourceDir -Force -ErrorAction SilentlyContinue |
             Where-Object { $_.Name -ne $IgnoreName } |
             Sort-Object LastWriteTime |
             Select-Object -First 50
    if (-not $batch -or $batch.Count -le 1) { Write-Log "No more items in $SourceDir"; break }

    Ensure-Dir $DestDir

        foreach ($it in $batch) {

      # Skip date-named dirs for today or tomorrow
      if ($it.PSIsContainer -and (Should-SkipByDate -Item $it)) {
        Write-Log "SKIP (today/tomorrow dir): '$($it.FullName)'"
        continue
      }

      # Skip items still being written or locked
      if (-not (Test-ItemReady -Item $it)) {
        Write-Log "SKIP (busy/new): '$($it.FullName)' (LastWrite=$($it.LastWriteTime))"
        continue
      }

      if ($DryRun) {
        if ($it.PSIsContainer) {
          $destRoot = Join-Path $DestDir $it.Name
          Write-Log "[DryRun] Dir -> '$($it.FullName)'  ==> DestRoot '$destRoot'"
        } else {
          $destPath = Join-Path $DestDir $it.Name
          Write-Log "[DryRun] File -> '$($it.FullName)'  ==> '$destPath'"
        }
      } else {
        try {
          Move-Item -LiteralPath $it.FullName -Destination $DestDir -Force -ErrorAction Stop
          Write-Log "Moved: '$($it.FullName)' -> '$DestDir'"
        } catch {
          $msg = $_.Exception.Message
          if ($msg -match 'being used by another process' -or $_.Exception -is [System.IO.IOException]) {
            Write-Log "SKIP (in use): '$($it.FullName)' - $msg"
          } else {
            Write-Log "ERROR: Move '$($it.FullName)' -> '$DestDir' failed. $msg"
          }
          continue
        }
      }

      $movedAny = $true
    }


    # IMPORTANT: in DryRun nothing changes on disk, so bail after one batch to avoid infinite loops.
    if ($DryRun) {
      Write-Log "[DryRun] Completed one batch for $SourceDir -> $DestDir. Breaking to avoid infinite loop."
      break
    }
  }
  return $movedAny
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

# Assess E/F/D
$freeE = Get-FreePercent 'E'; $usedE = 100 - $freeE
$freeF = Get-FreePercent 'F'; $usedF = 100 - $freeF
$freeD = Get-FreePercent 'D'; $usedD = 100 - $freeD
Write-Log "E: free=$freeE% (used=$usedE%), F: free=$freeF% (used=$usedF%), D: free=$freeD% (used=$usedD%)"

# Trigger only when E is at/over 90% used
if ($usedE -ge 90) {
  Send-HA-Notification -Title $HA.Title -Message "E >= 90% used (E used=$usedE%). Starting balancing across F and D."

  # Build F destinations with same leaf names as E sources
  $FFrontDst = Join-Path $Paths.FRoot (Split-Path $Paths.EFrontSrc -Leaf)
  $FBackDst  = Join-Path $Paths.FRoot (Split-Path $Paths.EBackSrc  -Leaf)

  if ($usedF -lt 90) {
    Write-Log "F < 90% used. Moving from E -> F until F reaches 90%, then spill to D."

    # E -> F (until F hits 90%)
    $m1 = Move-IntoDriveUntilCap -SourceDir $Paths.EFrontSrc -DestDir $FFrontDst -DestDrive 'F' -CapUsedPercent 90
    $m2 = Move-IntoDriveUntilCap -SourceDir $Paths.EBackSrc  -DestDir $FBackDst  -DestDrive 'F' -CapUsedPercent 90

    if ($DryRun) {
        Write-Log "[DryRun] 2 iterations of the dry run are done. Exiting Script."
        Write-Log "---- StorageSweep complete ----"
        exit
    }

    # Re-evaluate E remaining; spill to D if any left
    $remainingFront = (Test-Path $Paths.EFrontSrc) -and (Get-ChildItem -LiteralPath $Paths.EFrontSrc -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne $IgnoreName }).Count -gt 0
    $remainingBack  = (Test-Path $Paths.EBackSrc)  -and (Get-ChildItem -LiteralPath $Paths.EBackSrc  -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne $IgnoreName }).Count -gt 0

    if ($remainingFront -or $remainingBack) {
      Write-Log "Spillover from E -> D (stop if D hits 90% used; wipe D targets and continue if needed)."

      # Loop: move from E to D until E empties; if D hits 90%, wipe D target dirs and continue
      while ($true) {
        $freeD = Get-FreePercent 'D'; $usedD = 100 - $freeD
        if ($usedD -ge 90) {
          Write-Log "D reached 90% used. Wiping only D targets, then continuing."
          Wipe-TargetDir -TargetDir $Paths.DFrontDst
          Wipe-TargetDir -TargetDir $Paths.DBackDst
          # Continue loop, capacity will be freed
        }

        $movedFront = Move-IntoDriveUntilCap -SourceDir $Paths.EFrontSrc -DestDir $Paths.DFrontDst -DestDrive 'D' -CapUsedPercent 90
        $movedBack  = Move-IntoDriveUntilCap -SourceDir $Paths.EBackSrc  -DestDir $Paths.DBackDst  -DestDrive 'D' -CapUsedPercent 90

        $remainingFront = Test-Path $Paths.EFrontSrc -and (Get-ChildItem -LiteralPath $Paths.EFrontSrc -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne $IgnoreName }).Count -gt 0
        $remainingBack  = Test-Path $Paths.EBackSrc  -and (Get-ChildItem -LiteralPath $Paths.EBackSrc  -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne $IgnoreName }).Count -gt 0

        if (-not ($remainingFront -or $remainingBack)) { break }
        # If still remaining but D not freed enough by previous wipe, the loop continues
      }
    }

  } else {
    Write-Log "F >= 90% used. Move F -> D (two dirs), wiping D targets if/when D hits 90%, then move E -> D similarly."

    # Step 1: F -> D (only two dirs)
    while ($true) {
      $freeD = Get-FreePercent 'D'; $usedD = 100 - $freeD
      if ($usedD -ge 90) {
        Write-Log "D reached 90% used. Wiping only D targets before continuing F -> D."
        Wipe-TargetDir -TargetDir $Paths.DFrontDst
        Wipe-TargetDir -TargetDir $Paths.DBackDst
      }

      $movedF1 = Move-IntoDriveUntilCap -SourceDir $FFrontDst -DestDir $Paths.DFrontDst -DestDrive 'D' -CapUsedPercent 90
      $movedF2 = Move-IntoDriveUntilCap -SourceDir $FBackDst  -DestDir $Paths.DBackDst  -DestDrive 'D' -CapUsedPercent 90

      $remainingF1 = Test-Path $FFrontDst -and (Get-ChildItem -LiteralPath $FFrontDst -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne $IgnoreName }).Count -gt 0
      $remainingF2 = Test-Path $FBackDst  -and (Get-ChildItem -LiteralPath $FBackDst  -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne $IgnoreName }).Count -gt 0

      if (-not ($remainingF1 -or $remainingF2)) { break }
    }

    # Step 2: E -> D (two dirs), with same D-wipe-on-90% behavior
    while ($true) {
      $freeD = Get-FreePercent 'D'; $usedD = 100 - $freeD
      if ($usedD -ge 90) {
        Write-Log "D reached 90% used. Wiping only D targets before continuing E -> D."
        Wipe-TargetDir -TargetDir $Paths.DFrontDst
        Wipe-TargetDir -TargetDir $Paths.DBackDst
      }

      $movedE1 = Move-IntoDriveUntilCap -SourceDir $Paths.EFrontSrc -DestDir $Paths.DFrontDst -DestDrive 'D' -CapUsedPercent 90
      $movedE2 = Move-IntoDriveUntilCap -SourceDir $Paths.EBackSrc  -DestDir $Paths.DBackDst  -DestDrive 'D' -CapUsedPercent 90

      $remainingE1 = Test-Path $Paths.EFrontSrc -and (Get-ChildItem -LiteralPath $Paths.EFrontSrc -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne $IgnoreName }).Count -gt 0
      $remainingE2 = Test-Path $Paths.EBackSrc  -and (Get-ChildItem -LiteralPath $Paths.EBackSrc  -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne $IgnoreName }).Count -gt 0

      if (-not ($remainingE1 -or $remainingE2)) { break }
    }
  }
} else {
  Write-Log "E < 90% used. No balancing required."
  if ($DryRun) {
    Send-HA-Notification -Title "Storage Dry Run" -Message "No action. E used=$usedE%, F used=$usedF%, D used=$usedD%."
  }
}

Write-Log "---- StorageSweep complete ----"
