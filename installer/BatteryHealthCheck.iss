; Inno Setup script for Battery Health Check
; Build with:  "%LOCALAPPDATA%\Programs\Inno Setup 7\ISCC.exe" BatteryHealthCheck.iss
; The finished installer is written to the folder above this one.

#define AppName "Battery Health Check"
#define AppVersion "1.1"
; Single-quoted so the doubled quotes reach the [Icons]/[Run] sections intact
#define PsArgs '-NoProfile -ExecutionPolicy Bypass -File ""{app}\BatteryHealthCheck.ps1"" -Interactive'

[Setup]
AppId={{6F3B2C1E-8D4A-4E7B-9C21-B7A5E3D19F42}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion}
DefaultDirName={autopf}\{#AppName}
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
DisableDirPage=yes
; No administrator rights needed: installs just for the person running it.
; (Can still be installed for all users from the command line with /ALLUSERS.)
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=commandline
OutputDir=..
OutputBaseFilename=BatteryHealthCheck-Setup
SetupIconFile=battery.ico
UninstallDisplayIcon={app}\battery.ico
UninstallDisplayName={#AppName}
WizardStyle=modern
Compression=lzma2
SolidCompression=yes
MinVersion=10.0
ArchitecturesInstallIn64BitMode=x64compatible

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "Put a shortcut on the desktop"; GroupDescription: "Shortcuts:"

[Files]
Source: "..\BatteryHealthCheck.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\README.md"; DestDir: "{app}"; Flags: ignoreversion
Source: "battery.ico"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{group}\{#AppName}"; Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "{#PsArgs}"; WorkingDir: "{app}"; IconFilename: "{app}\battery.ico"; Comment: "Check your laptop battery's health in plain English"
Name: "{group}\Saved battery reports"; Filename: "{userdocs}\Battery Health Reports"; Comment: "Open the folder where your battery summaries are saved"
Name: "{group}\Uninstall {#AppName}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#AppName}"; Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "{#PsArgs}"; WorkingDir: "{app}"; IconFilename: "{app}\battery.ico"; Comment: "Check your laptop battery's health in plain English"; Tasks: desktopicon

[Dirs]
Name: "{userdocs}\Battery Health Reports"; Flags: uninsneveruninstall

[Run]
Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "{#PsArgs}"; WorkingDir: "{app}"; Description: "Check my battery now"; Flags: postinstall nowait skipifsilent
