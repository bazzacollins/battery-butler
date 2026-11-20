# Battery Health Check

A small Windows app that runs the built-in battery report (`powercfg /batteryreport`) and turns it into an easy-to-read page for people who aren't technical.

It tells you how healthy your laptop battery is, how you've been using it, how long a full charge lasts, and what you can do to make the battery last longer. Everything is explained in plain English.

**[Download the latest version](https://github.com/bazzacollins/battery-health-check/releases/latest)**

## What you need

- A Windows 10 or Windows 11 laptop. On a desktop PC the app simply reports that there's no battery.
- Nothing else. The app uses tools that are built into Windows, and it doesn't need administrator rights.

## How to install it (easiest)

1. Go to the [latest release](https://github.com/bazzacollins/battery-health-check/releases/latest) and download **BatteryHealthCheck-Setup.exe**.
2. Double-click it and follow the steps.
3. If Windows says **"Windows protected your PC"**, click **More info**, then **Run anyway**. This appears because the installer isn't digitally signed, not because anything is wrong.
4. Open **Battery Health Check** from the Start menu (or the desktop shortcut).

To remove it, go to **Settings > Apps > Installed apps**, find **Battery Health Check** and choose **Uninstall**. Your saved summaries stay in your Documents folder.

## How to use it without installing

1. On this page, click the green **Code** button and choose **Download ZIP**.
2. Right-click the downloaded zip file and choose **Extract All**. The app won't work if you run it from inside the zip.
3. In the extracted folder, double-click **Check My Battery.cmd**. If Windows asks whether you want to run it, choose **Run**.
4. Wait a few seconds while Windows creates its report. Your summary opens in your web browser.

## Where your summaries are saved

Each summary is saved in **Documents\Battery Health Reports**, with a date and time in its name. Windows' own technical report is saved next to it, and the summary links to it at the bottom.

## Your privacy

Battery Health Check works entirely on your own PC. It doesn't connect to the internet, and it doesn't send your battery information anywhere.

The saved summary includes your computer's name and model, so think about that before you share it with anyone.

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

## Why the health figure can suddenly change

Your battery estimates how much charge it can hold, and it only checks that estimate properly when it goes from nearly empty to completely full. If you haven't done that for a long time, the health figure can jump (usually downwards) after the next full charge. The newer figure is normally the more accurate one. If your battery is nearly empty when you run the check, the summary warns you about this.

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

To rebuild, install Inno Setup 7, open PowerShell in the `installer` folder and run:

```powershell
& "$env:LOCALAPPDATA\Programs\Inno Setup 7\ISCC.exe" "/O$env:TEMP\bhc-build" BatteryHealthCheck.iss
Copy-Item "$env:TEMP\bhc-build\BatteryHealthCheck-Setup.exe" .. -Force
```

If you installed Inno Setup for all users, its path is `C:\Program Files\Inno Setup 7\ISCC.exe` instead.

The installer is built in a temporary folder and then copied back, because building it directly inside a folder synced by OneDrive can fail while OneDrive is syncing. If you change the app, also raise `AppVersion` in the `.iss` file so the new installer upgrades the old one.

## Licence

Battery Health Check is free to use, change and share under the [MIT licence](LICENSE).
