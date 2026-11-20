# Battery Health Check

A small Windows app that runs the built-in battery report (`powercfg /batteryreport`) and turns it into an easy-to-read page for people who aren't technical.

## How to install it (easiest)

1. Double-click **BatteryHealthCheck-Setup.exe** and follow the steps. You don't need administrator rights.
2. If Windows says **"Windows protected your PC"**, click **More info**, then **Run anyway**. This appears because the installer isn't digitally signed, not because anything is wrong.
3. Open **Battery Health Check** from the Start menu (or the desktop shortcut).

To remove it, go to **Settings > Apps > Installed apps**, find **Battery Health Check** and choose **Uninstall**. Your saved summaries stay in your Documents folder.

## How to use it without installing

1. Double-click **Check My Battery.cmd**. It must be in the same folder as **BatteryHealthCheck.ps1**. If you received a zip file, choose **Extract All** first.
2. Wait a few seconds while Windows creates its report.
3. Your summary opens in your web browser.

Each summary is saved in **Documents\Battery Health Reports**, with a date and time in its name. Windows' own technical report is saved next to it, and the summary links to it at the bottom.

You don't need administrator rights, and you don't need to install anything. The app uses PowerShell, which comes with Windows.

## What the summary covers

| Section in the summary | Section in the Windows report |
|---|---|
| Battery health: how much charge it can still hold | Installed batteries (design capacity compared with full charge capacity) |
| What your laptop has been doing lately | Recent usage |
| How fast the battery goes down when unplugged | Battery usage |
| How you use your laptop over time | Usage history |
| How the battery has worn over time | Battery capacity history |
| How long a full charge lasts | Battery life estimates |
| Looking after your battery | Advice based on the figures above, plus general good habits |

The summary ends with a jargon buster that explains terms like *design capacity*, *mWh* and *charge cycle*.

## Advanced options

Run from PowerShell:

```powershell
# Explain a report that was saved earlier, for example one copied from another laptop
.\BatteryHealthCheck.ps1 -XmlPath "C:\path\to\battery-report.xml"

# Save the summary somewhere else, and don't open it automatically
.\BatteryHealthCheck.ps1 -OutputFolder "D:\Reports" -NoOpen
```

To make an XML report on another laptop, run `powercfg /batteryreport /xml` there. The HTML version of the report can't be read by this app.

## Rebuilding the installer

The `installer` folder holds everything needed to rebuild `BatteryHealthCheck-Setup.exe` after you change the app:

- `BatteryHealthCheck.iss` is the [Inno Setup](https://jrsoftware.org/isinfo.php) script.
- `battery.ico` is the app icon. `make-icon.ps1` redraws it.

To rebuild, open PowerShell in the `installer` folder and run:

```powershell
& "$env:LOCALAPPDATA\Programs\Inno Setup 7\ISCC.exe" "/O$env:TEMP\bhc-build" BatteryHealthCheck.iss
Copy-Item "$env:TEMP\bhc-build\BatteryHealthCheck-Setup.exe" .. -Force
```

The installer is built in a temporary folder and then copied back, because building it directly inside a OneDrive folder fails while OneDrive is syncing. If you change the app, also raise `AppVersion` in the `.iss` file so the new installer upgrades the old one.
