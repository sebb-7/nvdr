; FarRelay tester installer. Distribution authorization is handled by the
; authenticated tester gateway; no GitHub credential is embedded in the app.
#ifndef AppVersion
  #define AppVersion "0.1.0"
#endif
#ifndef Channel
  #define Channel "beta"
#endif
#ifndef GatewayUrl
  #define GatewayUrl "https://invalid.example"
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
Source: "..\release\Test-FarRelayTravelReadiness.ps1"; DestDir: "{app}\scripts"; Flags: ignoreversion
Source: "..\release\Prepare-FarRelayTravel.ps1"; DestDir: "{app}\scripts"; Flags: ignoreversion
Source: "..\release\Start-FarRelayControlCenter.ps1"; DestDir: "{app}\scripts"; Flags: ignoreversion
Source: "..\release\FarRelay.Setup.Core.psm1"; DestDir: "{app}\scripts"; Flags: ignoreversion
Source: "..\release\Start-FarRelaySetupWizard.ps1"; DestDir: "{app}\scripts"; Flags: ignoreversion
Source: "Install-FarRelayUpdaterTask.ps1"; DestDir: "{app}\scripts"; Flags: ignoreversion
Source: "Install-FarRelayShellLinks.ps1"; DestDir: "{app}\scripts"; Flags: ignoreversion
Source: "{#SourceDir}\FarRelayBridge-{#AppVersion}.nvda-addon"; DestDir: "{app}\addons"; Flags: ignoreversion

[Run]
Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\scripts\Install-FarRelayNvdaRecoveryTask.ps1"" -AllowMissingNvda"; Flags: runhidden waituntilterminated
Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\scripts\Install-FarRelayUpdaterTask.ps1"" -InstallDirectory ""{app}"""; Flags: runhidden waituntilterminated
Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\scripts\Install-FarRelayShellLinks.ps1"" -InstallDirectory ""{app}"""; Flags: runhidden waituntilterminated
Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""{app}\scripts\Start-FarRelaySetupWizard.ps1"""; Description: "Open FarRelay Setup Wizard"; Flags: postinstall nowait skipifsilent runasoriginaluser

[UninstallDelete]
Type: filesandordirs; Name: "{app}"
Type: files; Name: "{commonappdata}\FarRelay\device.credential"

[Code]
var
  TesterCodePage: TInputQueryWizardPage;

function RemoveDirectoryFromPath(Value, Directory: String): String;
var
  Remaining, Segment, NormalizedDirectory: String;
  SeparatorPos: Integer;
begin
  Result := '';
  Remaining := Value;
  NormalizedDirectory := Uppercase(Trim(Directory));

  while Length(Remaining) > 0 do begin
    SeparatorPos := Pos(';', Remaining);
    if SeparatorPos = 0 then begin
      Segment := Remaining;
      Remaining := '';
    end else begin
      Segment := Copy(Remaining, 1, SeparatorPos - 1);
      Delete(Remaining, 1, SeparatorPos);
    end;

    Segment := Trim(Segment);
    if (Length(Segment) > 0) and (Uppercase(Segment) <> NormalizedDirectory) then begin
      if Length(Result) > 0 then Result := Result + ';';
      Result := Result + Segment;
    end;
  end;
end;

function IsExistingActivatedInstallation: Boolean;
begin
  Result :=
    FileExists(ExpandConstant('{commonappdata}\FarRelay\device.credential')) and
    FileExists(ExpandConstant('{commonappdata}\FarRelay\install.json'));
end;

function IsSafeActivationCode(Value: String): Boolean;
var
  I: Integer;
  C: Char;
begin
  Value := Uppercase(Trim(Value));
  Result := Length(Value) >= 12;
  if not Result then Exit;
  for I := 1 to Length(Value) do begin
    C := Value[I];
    if not (((C >= 'A') and (C <= 'Z')) or ((C >= '0') and (C <= '9')) or (C = '-')) then begin
      Result := False;
      Exit;
    end;
  end;
end;

procedure InitializeWizard;
begin
  TesterCodePage := CreateInputQueryPage(
    wpSelectDir,
    'FarRelay tester access',
    'Enter your tester activation code',
    'FarRelay beta and stable builds are invite-only. Enter the code supplied by the FarRelay developer.'
  );
  TesterCodePage.Add('Activation code:', False);
end;

function ShouldSkipPage(PageID: Integer): Boolean;
begin
  Result := (PageID = TesterCodePage.ID) and IsExistingActivatedInstallation;
end;

function NextButtonClick(CurPageID: Integer): Boolean;
begin
  Result := True;
  if (CurPageID = TesterCodePage.ID) and (not IsExistingActivatedInstallation) then begin
    if not IsSafeActivationCode(TesterCodePage.Values[0]) then begin
      MsgBox('Enter a valid FarRelay tester activation code.', mbError, MB_OK);
      Result := False;
    end;
  end;
end;

procedure AddFarRelayToSystemPath;
var
  CurrentPath, CleanedPath, InstallDirectory, UpdatedPath: String;
begin
  InstallDirectory := ExpandConstant('{app}');
  if RegQueryStringValue(HKLM, 'SYSTEM\CurrentControlSet\Control\Session Manager\Environment', 'Path', CurrentPath) then begin
    CleanedPath := RemoveDirectoryFromPath(CurrentPath, InstallDirectory);
    UpdatedPath := InstallDirectory;
    if Length(CleanedPath) > 0 then UpdatedPath := UpdatedPath + ';' + CleanedPath;
    RegWriteExpandStringValue(HKLM, 'SYSTEM\CurrentControlSet\Control\Session Manager\Environment', 'Path', UpdatedPath);
  end else begin
    RegWriteExpandStringValue(HKLM, 'SYSTEM\CurrentControlSet\Control\Session Manager\Environment', 'Path', InstallDirectory);
  end;
end;

procedure WriteInstallConfiguration;
var
  ConfigDir, ConfigPath, Content, ExistingContent, SelectedChannel, UpdateUrl, InstallPath: String;
  ExistingContentUtf8, ContentUtf8: AnsiString;
begin
  ConfigDir := ExpandConstant('{commonappdata}\FarRelay');
  ForceDirectories(ConfigDir);
  ConfigPath := AddBackslash(ConfigDir) + 'install.json';
  SelectedChannel := '{#Channel}';
  if LoadStringFromFile(ConfigPath, ExistingContentUtf8) then begin
    ExistingContent := Utf8Decode(ExistingContentUtf8);
    if Pos('"channel":"stable"', ExistingContent) > 0 then SelectedChannel := 'stable';
    if Pos('"channel":"beta"', ExistingContent) > 0 then SelectedChannel := 'beta';
  end;
  InstallPath := ExpandConstant('{app}');
  StringChangeEx(InstallPath, '\', '/', True);
  UpdateUrl := '{#GatewayUrl}';
  while (Length(UpdateUrl) > 0) and (UpdateUrl[Length(UpdateUrl)] = '/') do
    Delete(UpdateUrl, Length(UpdateUrl), 1);
  UpdateUrl := UpdateUrl + '/v1/manifest';
  Content := '{"schema_version":1,"channel":"' + SelectedChannel + '","installed_version":"{#AppVersion}","install_dir":"' + InstallPath + '","manifest_url":"' + UpdateUrl + '"}';
  ContentUtf8 := Utf8Encode(Content);
  if not SaveStringToFile(ConfigPath, ContentUtf8, False) then
    RaiseException('Unable to write FarRelay install configuration.');
end;

procedure ActivateTester;
var
  ResultCode: Integer;
  Code, Params: String;
begin
  if IsExistingActivatedInstallation then Exit;
  Code := Uppercase(Trim(TesterCodePage.Values[0]));
  if not IsSafeActivationCode(Code) then
    RaiseException('A valid FarRelay tester activation code is required.');
  Params := 'activate "' + Code + '"';
  if (not Exec(ExpandConstant('{app}\farrelay-updater.exe'), Params, '', SW_HIDE, ewWaitUntilTerminated, ResultCode)) or (ResultCode <> 0) then
    RaiseException('FarRelay tester activation failed. Confirm the code is current and this computer is online.');
end;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  if CurStep = ssPostInstall then begin
    AddFarRelayToSystemPath;
    WriteInstallConfiguration;
    ActivateTester;
  end;
end;
