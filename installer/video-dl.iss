#ifndef MyAppVersion
  #define MyAppVersion "0.3.0"
#endif

[Setup]
AppId={{E8EE53B0-A51A-4C25-8BBF-63581C310B9E}
AppName=video-dl
AppVersion={#MyAppVersion}
AppPublisher=sillasHead
AppPublisherURL=https://github.com/sillasHead/video-dl
AppSupportURL=https://github.com/sillasHead/video-dl/issues
DefaultDirName={localappdata}\video-dl\app
DisableDirPage=yes
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
OutputDir=output
OutputBaseFilename=video-dl-setup
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible
Uninstallable=yes

[Files]
Source: "..\src\video-dl.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\src\pluto-dl.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\src\th-dl.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "video-dl.cmd"; DestDir: "{localappdata}\video-dl\bin"; Flags: ignoreversion
Source: "configure.ps1"; DestDir: "{tmp}"; Flags: deleteafterinstall

[Run]
Filename: "powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{tmp}\configure.ps1"""; Flags: runhidden waituntilterminated

[UninstallDelete]
Type: filesandordirs; Name: "{localappdata}\video-dl\app"
Type: files; Name: "{localappdata}\video-dl\bin\video-dl.cmd"

[Code]
procedure CurStepChanged(CurStep: TSetupStep);
begin
  if CurStep = ssPostInstall then
    Log('video-dl instalado. Configurações em %USERPROFILE%\.video-dl foram preservadas.');
end;
