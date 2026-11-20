; Inno Setup script for Battery Butler
; Build with:  "%LOCALAPPDATA%\Programs\Inno Setup 7\ISCC.exe" BatteryButler.iss
; The finished installer is written to the folder above this one.

#define AppName "Battery Butler"
#define AppVersion "1.2"
; Single-quoted so the doubled quotes reach the [Icons]/[Run] sections intact
#define PsArgs '-NoProfile -ExecutionPolicy Bypass -File ""{app}\BatteryButler.ps1"" -Interactive'

[Setup]
; AppId must never change: it lets new versions upgrade earlier ones,
; including those released under the old name "Battery Health Check".
AppId={{6F3B2C1E-8D4A-4E7B-9C21-B7A5E3D19F42}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion}
AppPublisher=Barry Collins
AppCopyright=Copyright (c) 2026 Barry Collins
AppPublisherURL=https://github.com/bazzacollins/battery-butler
AppSupportURL=https://github.com/bazzacollins/battery-butler
DefaultDirName={autopf}\{#AppName}
DefaultGroupName={#AppName}
; Always use the new name, even when upgrading a version installed under the old name
UsePreviousAppDir=no
UsePreviousGroup=no
DisableProgramGroupPage=yes
DisableDirPage=yes
; No administrator rights needed: installs just for the person running it.
; (Can still be installed for all users from the command line with /ALLUSERS.)
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=commandline
OutputDir=..
OutputBaseFilename=BatteryButler-Setup
SetupIconFile=battery.ico
UninstallDisplayIcon={app}\battery.ico
UninstallDisplayName={#AppName}
VersionInfoDescription={#AppName} installer
WizardStyle=modern
Compression=lzma2
SolidCompression=yes
MinVersion=10.0
ArchitecturesInstallIn64BitMode=x64compatible

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "Put a shortcut on the desktop"; GroupDescription: "Shortcuts:"

[InstallDelete]
; Tidy up anything left by versions released under the old name "Battery Health Check"
Type: filesandordirs; Name: "{autoprograms}\Battery Health Check"
Type: files; Name: "{autodesktop}\Battery Health Check.lnk"
Type: filesandordirs; Name: "{autopf}\Battery Health Check"

[Files]
Source: "..\BatteryButler.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\README.md"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\LICENSE"; DestDir: "{app}"; Flags: ignoreversion
Source: "battery.ico"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{group}\{#AppName}"; Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "{#PsArgs}"; WorkingDir: "{app}"; IconFilename: "{app}\battery.ico"; Comment: "Your laptop battery, explained in plain English"
Name: "{group}\Saved battery reports"; Filename: "{userdocs}\Battery Butler Reports"; Comment: "Open the folder where your battery summaries are saved"
Name: "{group}\Uninstall {#AppName}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#AppName}"; Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "{#PsArgs}"; WorkingDir: "{app}"; IconFilename: "{app}\battery.ico"; Comment: "Your laptop battery, explained in plain English"; Tasks: desktopicon

[Dirs]
Name: "{userdocs}\Battery Butler Reports"; Flags: uninsneveruninstall

[Run]
Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "{#PsArgs}"; WorkingDir: "{app}"; Description: "Ask the Battery Butler to check my battery now"; Flags: postinstall nowait skipifsilent
