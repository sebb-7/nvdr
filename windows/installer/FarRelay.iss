; Inno Setup is used for its mature, standard Windows controls and silent
; deployment support. CI supplies AppVersion, Channel, and SourceDir.
#ifndef AppVersion
  #define AppVersion "0.1.0"
#endif
#ifndef Channel
  #define Channel "beta"
#endif
#ifndef SourceDir
  #define SourceDir "..\dist"
#endif

[Setup]
AppId={{B580B50E-CF99-4370-8558-9F36F57A87F4}
AppName=FarRelay
AppVersion={#AppVersion}
AppPublisher=FarRelay
DefaultDirName={autopf}\FarRelay
DefaultGroupName=FarRelay
DisableProgramGroupPage=yes
OutputDir=..\output
OutputBaseFilename=FarRelay-Setup-{#AppVersion}
Compression=lzma2
SolidCompression=yes
PrivilegesRequired=admin
ArchitecturesInstallIn64BitMode=x64compatible
WizardStyle=modern
UninstallDisplayName=FarRelay

[Files]
Source: "{#SourceDir}\farrelay.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourceDir}\farrelay-host.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourceDir}\farrelay-updater.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\..\farrelay-host\scripts\Install-FarRelayNvdaRecoveryTask.ps1"; DestDir: "{app}\scripts"; Flags: ignoreversion
Source: "Install-FarRelayUpdaterTask.ps1"; DestDir: "{app}\scripts"; Flags: ignoreversion
Source: "{#SourceDir}\FarRelayBridge-{#AppVersion}.nvda-addon"; DestDir: "{app}\addons"; Flags: ignoreversion

[Run]
Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\scripts\Install-FarRelayNvdaRecoveryTask.ps1"" -AllowMissingNvda"; Flags: runhidden waituntilterminated
Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\scripts\Install-FarRelayUpdaterTask.ps1"" -InstallDirectory ""{app}"""; Flags: runhidden waituntilterminated

[UninstallDelete]
Type: filesandordirs; Name: "{app}"

[Code]
function PathHasDirectory(Value, Directory: String): Boolean;
begin
  Result := Pos(';' + Uppercase(Directory) + ';', ';' + Uppercase(Value) + ';') > 0;
end;

procedure AddFarRelayToSystemPath;
var
  CurrentPath, UpdatedPath: String;
begin
  if RegQueryStringValue(HKLM, 'SYSTEM\CurrentControlSet\Control\Session Manager\Environment', 'Path', CurrentPath) then begin
    if not PathHasDirectory(CurrentPath, ExpandConstant('{app}')) then begin
      UpdatedPath := CurrentPath + ';' + ExpandConstant('{app}');
      RegWriteExpandStringValue(HKLM, 'SYSTEM\CurrentControlSet\Control\Session Manager\Environment', 'Path', UpdatedPath);
    end;
  end;
end;

procedure WriteInstallConfiguration;
var
  ConfigDir, ConfigPath, Content, ExistingContent, SelectedChannel, UpdateUrl, InstallPath: String;
begin
  ConfigDir := ExpandConstant('{commonappdata}\FarRelay');
  ForceDirectories(ConfigDir);
  ConfigPath := AddBackslash(ConfigDir) + 'install.json';
  SelectedChannel := '{#Channel}';
  { Preserve an explicitly installed tester channel during an upgrade. }
  if LoadStringFromFile(ConfigPath, ExistingContent) then begin
    if Pos('"channel":"stable"', ExistingContent) > 0 then SelectedChannel := 'stable';
    if Pos('"channel":"beta"', ExistingContent) > 0 then SelectedChannel := 'beta';
  end;
  InstallPath := ExpandConstant('{app}');
  StringChangeEx(InstallPath, '\', '/', True);
  UpdateUrl := 'https://github.com/sebb-7/nvdr/releases/download/farrelay-' + SelectedChannel + '/update-' + SelectedChannel + '.json';
  Content := '{"schema_version":1,"channel":"' + SelectedChannel + '","installed_version":"{#AppVersion}","install_dir":"' + InstallPath + '","manifest_url":"' + UpdateUrl + '"}';
  { ProgramData is retained by uninstall; a later installer updates only distribution metadata. }
  SaveStringToFile(ConfigPath, Content, False);
end;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  if CurStep = ssPostInstall then begin
    AddFarRelayToSystemPath;
    WriteInstallConfiguration;
  end;
end;
