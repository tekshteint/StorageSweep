# StorageSweep – Automated Storage Management & Notifications

This PowerShell script automates disk space management across multiple drives for my IP cameras, purges old IIS FTP logs, and sends notifications to Home Assistant when thresholds are met. It is designed to run automatically each night via Windows Task Scheduler.

---

## Features
- **Checks drive free space**:
  - `C:` – if free space < 10%, deletes IIS FTP log files under `C:\inetpub\logs\LogFiles\FTPSVC2`.
  - `E:` – if free space < 10%, moves configured camera folders to `D:`.
  - `D:` – if free space < 10% after receiving files, attempts migration to `F:`, or wipes D and reimports from `E:`.
- **Skips files/folders** named `DVRWorkDirectory` for Amcrest FTP functionality.
- **DryRun mode** (`$DryRun = $true`): logs intended actions without making changes, but still sends Home Assistant notifications.
- **Log rotation**: keeps the 5 most recent log files in `C:\Logs`.
- **Home Assistant push notifications** using Long-Lived Access Tokens stored in a `.env` file.

---

## Requirements
- Windows PC with PowerShell 5.1 or later.
- Administrative privileges (required for file operations).
- Home Assistant instance with:
  - Mobile app integration enabled (e.g. `notify.mobile_app_yourdevice`).
  - A Long-Lived Access Token generated in your HA profile.
- `.env` file containing HA credentials.

---

## Setup

### 1. Create `.env` file
Create a file named `.env` in the same folder as `StorageSweep.ps1`. Example contents:

```env
HA_URL=http://X.X.X.X:8123
HA_TOKEN=YOUR_TOKEN_HERE
CAM_ONE=E:\FTP\PATH\TO\CAMERA1
CAM_TWO=E:\FTP\PATH\TO\CAMERA2
DEST_ONE=D:\PATH\TO\CAMERA1
DEST_TWO=D:\PATH\TO\CAMERA2
```

- `HA_URL`: Base URL of your HA instance (IP or hostname).
- `HA_TOKEN`: Long-Lived Access Token from Home Assistant.
- The rest are paths to where your IP camera storage is and will be.

### 2. Test manually
Open PowerShell as Administrator and run:

```powershell
cd C:\Scripts
.\StorageSweep.ps1
```

- If `$DryRun = $true`, no files will move/delete, but you’ll see logs and HA notifications.
- Logs are written to `C:\Logs\StorageMaintenance_YYYYMMDD_HHMMSS.log`.

---

## Scheduling with Task Scheduler

### 1. Open Task Scheduler
- Press **Win + R**, type `taskschd.msc`, press Enter.

### 2. Create a new task
- In the right panel, click **Create Task** (not "Basic Task").

### 3. General tab
- **Name**: `StorageSweep`
- **Run with highest privileges**:  (important for file moves/deletes)
- **Configure for**: your version of Windows

### 4. Triggers tab
- Click **New…**
- Set **Begin the task** to: *On a schedule*
- Set schedule: *Daily*, **Start** at `11:59:00 PM`
- Click OK.

### 5. Actions tab
- Click **New…**
- **Action**: *Start a program*
- **Program/script**:
  ```
  powershell.exe
  ```
- **Add arguments**:
  ```
  -NoProfile -ExecutionPolicy Bypass -File "C:\Scripts\StorageSweep.ps1"
  ```


### 6. Conditions / Settings
  - Check *“Run task as soon as possible after a scheduled start is missed.”*

### 7. Save
- Enter admin credentials if prompted.
- Task is now scheduled.

---

## Logs & Verification
- Logs: `C:\Logs\StorageMaintenance_YYYYMMDD_HHMMSS.log`
- Keeps 5 most recent logs, automatically deletes older ones.
- Example log entries:
  ```
  [2025-09-27 23:59:01] ---- StorageSweep start ----
  [2025-09-27 23:59:01] C: free = 8.5%
  [2025-09-27 23:59:01] C: free < 10%. Purging IIS FTP logs at C:\inetpub\logs\LogFiles\FTPSVC2
  [2025-09-27 23:59:01] Deleted 25 files, freed approx 150 MB from C:\inetpub\logs\LogFiles\FTPSVC2
  ...
  [2025-09-27 23:59:01] Sent HA notification.
  [2025-09-27 23:59:01] ---- StorageSweep complete ----
  ```

