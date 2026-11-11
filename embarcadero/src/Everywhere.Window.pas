unit Everywhere.Window;

interface

type
  TWorkspaceResolver = function: string;

procedure ShowHarnessWindow(Resolver: TWorkspaceResolver);

implementation

uses
  System.SysUtils, System.Classes, System.IOUtils, Winapi.Windows, Winapi.ShellAPI,
  Vcl.Forms, Vcl.Controls, Vcl.StdCtrls, Vcl.ExtCtrls, Vcl.Edge,
  Everywhere.Runtime, Everywhere.Settings;

type
  THarnessWindow = class(TForm)
  private
    FRuntime: THarnessRuntime;
    FSettings: THarnessSettings;
    FResolver: TWorkspaceResolver;
    FBrowser: TEdgeBrowser;
    FLog: TMemo;
    FStatus: TLabel;
    FTimer: TTimer;
    FLastUrl: string;
    FWorkspace: string;
    FAutoStartPending: Boolean;
    procedure AddLog(const Text: string);
    procedure Tick(Sender: TObject);
    procedure StartClick(Sender: TObject);
    procedure StopClick(Sender: TObject);
    procedure RestartClick(Sender: TObject);
    procedure ReloadClick(Sender: TObject);
    procedure BrowserClick(Sender: TObject);
    procedure SettingsClick(Sender: TObject);
    procedure InstallClick(Sender: TObject);
    procedure BrowserCreated(Sender: TCustomEdgeBrowser; AResult: HRESULT);
    procedure WindowClosed(Sender: TObject; var Action: TCloseAction);
    procedure UpdateStatus;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
  end;

var
  HarnessWindow: THarnessWindow;

constructor THarnessWindow.Create(AOwner: TComponent);
var
  Toolbar: TFlowPanel;
  procedure AddButton(const Text: string; Handler: TNotifyEvent);
  var
    Button: TButton;
  begin
    Button := TButton.Create(Self);
    Button.Parent := Toolbar;
    Button.Width := 110;
    Button.Height := 30;
    Button.Caption := Text;
    Button.OnClick := Handler;
  end;
begin
  inherited CreateNew(AOwner);
  Caption := 'EveryWhere Harness - RAD Studio (experimental)';
  Position := poScreenCenter;
  Width := 1100;
  Height := 760;
  OnClose := WindowClosed;
  FSettings := THarnessSettings.Load;
  Toolbar := TFlowPanel.Create(Self);
  Toolbar.Parent := Self;
  Toolbar.Align := alTop;
  Toolbar.Height := 68;
  Toolbar.BevelOuter := bvNone;
  AddButton('Iniciar', StartClick);
  AddButton('Parar', StopClick);
  AddButton('Reiniciar', RestartClick);
  AddButton('Recarregar', ReloadClick);
  AddButton('Navegador', BrowserClick);
  AddButton('Configuracoes', SettingsClick);
  AddButton('Instalar runtime', InstallClick);
  FStatus := TLabel.Create(Self);
  FStatus.Parent := Self;
  FStatus.Align := alBottom;
  FStatus.AutoSize := False;
  FStatus.Height := 40;
  FStatus.WordWrap := True;
  FLog := TMemo.Create(Self);
  FLog.Parent := Self;
  FLog.Align := alBottom;
  FLog.Height := 140;
  FLog.ReadOnly := True;
  FLog.ScrollBars := ssVertical;
  FBrowser := TEdgeBrowser.Create(Self);
  FBrowser.Parent := Self;
  FBrowser.Align := alClient;
  // Separate per-user WebView2 storage; no shared session/token JSON files.
  FBrowser.UserDataFolder := TPath.Combine(SettingsDirectory, 'WebView2');
  FBrowser.OnCreateWebViewCompleted := BrowserCreated;
  FRuntime := THarnessRuntime.Create;
  FRuntime.OnLog :=
    procedure(Text: string)
    begin
      AddLog(Text);
    end;
  FTimer := TTimer.Create(Self);
  FTimer.Interval := 100;
  FTimer.OnTimer := Tick;
  FAutoStartPending := FSettings.AutoStart;
  UpdateStatus;
end;

destructor THarnessWindow.Destroy;
begin
  if FTimer <> nil then
    FTimer.Enabled := False;
  if FRuntime <> nil then
  begin
    FRuntime.OnLog := nil;
    FreeAndNil(FRuntime);
  end;
  inherited;
end;

procedure THarnessWindow.AddLog(const Text: string);
begin
  // Runtime sanitizes output before it reaches the UI; bound its memory use too.
  while FLog.Lines.Count >= 500 do
    FLog.Lines.Delete(0);
  FLog.Lines.Add(Text);
end;

procedure THarnessWindow.UpdateStatus;
const
  Names: array[THarnessState] of string =
    ('Parado', 'Iniciando', 'Em execucao', 'Instalando', 'Erro');
begin
  FStatus.Caption := Names[FRuntime.State];
  if FWorkspace <> '' then
    FStatus.Caption := FStatus.Caption + ' | Projeto: ' + FWorkspace;
  if FRuntime.LastError <> '' then
    FStatus.Caption := FStatus.Caption + ' | ' + FRuntime.LastError;
end;

procedure THarnessWindow.Tick(Sender: TObject);
begin
  // Poll on the IDE thread, never block it waiting for child process output.
  FTimer.Enabled := False;
  try
    try
      if FAutoStartPending then
      begin
        FAutoStartPending := False;
        if Assigned(FResolver) and (FResolver() <> '') then
          StartClick(nil);
      end;
      FRuntime.Poll;
      if (FRuntime.ActiveUrl <> '') and (FRuntime.ActiveUrl <> FLastUrl) then
      begin
        FLastUrl := FRuntime.ActiveUrl;
        FBrowser.Navigate(FLastUrl);
      end
      else if (FRuntime.ActiveUrl = '') and (FLastUrl <> '') then
      begin
        FLastUrl := '';
        FBrowser.Navigate('about:blank');
      end;
      UpdateStatus;
    except
      // Do not emit arbitrary exceptions: browser/runtime errors can contain URLs.
      AddLog('Falha ao atualizar a janela. Pare o runtime e tente novamente.');
    end;
  finally
    FTimer.Enabled := True;
  end;
end;

procedure THarnessWindow.StartClick(Sender: TObject);
var
  Workspace: string;
begin
  if FRuntime.State in [hsStarting, hsRunning, hsInstalling] then
    Exit;
  Workspace := '';
  if Assigned(FResolver) then
    Workspace := FResolver();
  if (Workspace = '') or not DirectoryExists(Workspace) then
  begin
    AddLog('Abra e salve um projeto Delphi ou C++Builder antes de iniciar.');
    Exit;
  end;
  FWorkspace := Workspace;
  FRuntime.Start(Workspace, FSettings.Executable, FSettings.Profile, FSettings.Port);
  UpdateStatus;
end;

procedure THarnessWindow.StopClick(Sender: TObject);
begin
  FRuntime.Stop;
  FLastUrl := '';
  FBrowser.Navigate('about:blank');
  UpdateStatus;
end;

procedure THarnessWindow.RestartClick(Sender: TObject);
begin
  StopClick(nil);
  StartClick(nil);
end;

procedure THarnessWindow.ReloadClick(Sender: TObject);
begin
  if FRuntime.ActiveUrl <> '' then
    FBrowser.Navigate(FRuntime.ActiveUrl);
end;

procedure THarnessWindow.BrowserClick(Sender: TObject);
begin
  if FRuntime.ActiveUrl <> '' then
    if NativeInt(ShellExecute(Handle, 'open', PChar(FRuntime.ActiveUrl), nil, nil,
      SW_SHOWNORMAL)) <= 32 then
      AddLog('Nao foi possivel abrir o navegador padrao.');
end;

procedure THarnessWindow.SettingsClick(Sender: TObject);
begin
  if EditSettings(FSettings) then
    AddLog('Configuracoes salvas. Reinicie o runtime para aplica-las.');
end;

procedure THarnessWindow.InstallClick(Sender: TObject);
begin
  // Explicit user action; never install software merely by loading the package.
  FRuntime.Install;
  UpdateStatus;
end;

procedure THarnessWindow.BrowserCreated(Sender: TCustomEdgeBrowser; AResult: HRESULT);
begin
  if AResult < 0 then
    AddLog('WebView2 indisponivel. Verifique o Runtime e WebView2Loader da arquitetura da IDE; use Navegador como alternativa.');
end;

procedure THarnessWindow.WindowClosed(Sender: TObject; var Action: TCloseAction);
begin
  FAutoStartPending := False;
  FRuntime.Stop;
  FLastUrl := '';
  FBrowser.Navigate('about:blank');
  Action := caHide;
  UpdateStatus;
end;

procedure ShowHarnessWindow(Resolver: TWorkspaceResolver);
begin
  if HarnessWindow = nil then
    HarnessWindow := THarnessWindow.Create(nil);
  HarnessWindow.FResolver := Resolver;
  if not HarnessWindow.Visible then
    HarnessWindow.FAutoStartPending := HarnessWindow.FSettings.AutoStart;
  HarnessWindow.Show;
  HarnessWindow.BringToFront;
end;

finalization
  FreeAndNil(HarnessWindow);

end.
