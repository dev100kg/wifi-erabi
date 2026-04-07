#define MyAppName "Wi-Fiえらび"
#define MyAppExeName "WiFiErabi.App.exe"
#define MyAppVersion "0.1.0"
#define MyAppPublisher "Wi-Fiえらび"
#define MyAppURL "https://github.com/dev100kg/wifi-erabi"
#define MyAppId "{{7D15CA90-5908-4F87-8F2F-A2E4C2B5A9C4}"

#ifndef MyAppPublishDir
  #define MyAppPublishDir "..\artifacts\publish\win-x64"
#endif

#ifndef MyInstallerOutputDir
  #define MyInstallerOutputDir "..\artifacts\installer"
#endif

[Setup]
AppId={#MyAppId}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL={#MyAppURL}
AppSupportURL={#MyAppURL}
AppUpdatesURL={#MyAppURL}
DefaultDirName={autopf}\{#MyAppName}
DefaultGroupName={#MyAppName}
UninstallDisplayIcon={app}\{#MyAppExeName}
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
DisableProgramGroupPage=yes
OutputDir={#MyInstallerOutputDir}
OutputBaseFilename=WiFiErabi-Setup
Compression=lzma
SolidCompression=yes
WizardStyle=modern

[Languages]
Name: "japanese"; MessagesFile: "compiler:Languages\Japanese.isl"

[Tasks]
Name: "desktopicon"; Description: "デスクトップにショートカットを作る"; GroupDescription: "追加の作業:"; Flags: unchecked

[Files]
Source: "{#MyAppPublishDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "{#MyAppName} を起動する"; Flags: nowait postinstall skipifsilent
