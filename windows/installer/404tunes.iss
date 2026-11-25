; Inno Setup script for the Windows installer. Built in CI (.github/workflows/release.yml):
;   iscc /DAppVersion=0.2.0 /DSourceDir=<build/windows/x64/runner/Release> windows\installer\404tunes.iss
#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif
#ifndef SourceDir
  #define SourceDir "..\..\build\windows\x64\runner\Release"
#endif

[Setup]
AppId={{6E1F5B0C-4D0A-4C57-9B52-404404404404}
AppName=404 Tunes
AppVersion={#AppVersion}
AppPublisher=404 Tunes
AppPublisherURL=https://github.com/aimansam/404tunes
DefaultDirName={autopf}\404 Tunes
DefaultGroupName=404 Tunes
DisableProgramGroupPage=yes
; Per-user install: no administrator prompt, no UAC.
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
OutputDir=..\..\dist
OutputBaseFilename=404tunes-windows-x64-setup
SetupIconFile=..\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\tunes404.exe
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
CloseApplications=yes

[Tasks]
Name: "desktopicon"; Description: "Create a &desktop shortcut"; GroupDescription: "Shortcuts:"; Flags: unchecked

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: recursesubdirs createallsubdirs ignoreversion

[Icons]
Name: "{group}\404 Tunes"; Filename: "{app}\tunes404.exe"
Name: "{autodesktop}\404 Tunes"; Filename: "{app}\tunes404.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\tunes404.exe"; Description: "Launch 404 Tunes"; Flags: nowait postinstall skipifsilent
; After an in-app update (setup.exe /SILENT /RELAUNCH=1, see lib/update/installer.dart) open the app again.
Filename: "{app}\tunes404.exe"; Flags: nowait; Check: RelaunchRequested

[Code]
function RelaunchRequested: Boolean;
begin
  Result := WizardSilent and (ExpandConstant('{param:RELAUNCH|0}') = '1');
end;
