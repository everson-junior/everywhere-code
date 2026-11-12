unit Everywhere.Window;

interface

type
  TWorkspaceResolver = function: string;

procedure RegisterHarnessWindow(Resolver: TWorkspaceResolver);
procedure ShowHarnessWindow(Resolver: TWorkspaceResolver);
procedure UnregisterHarnessWindow;

implementation

uses
  System.SysUtils, System.Classes, System.IOUtils, System.IniFiles, System.Types,
  Winapi.Windows, Winapi.ShellAPI, Winapi.WebView2,
  ToolsAPI, DesignIntf, DockForm,
  Vcl.Forms, Vcl.Controls, Vcl.StdCtrls, Vcl.ExtCtrls, Vcl.Edge,
  Vcl.ActnList, Vcl.ImgList, Vcl.Menus, Vcl.ComCtrls,
  Everywhere.Runtime, Everywhere.Settings;

const
  // Windows SDK libloaderapi.h values; not exported by every Delphi RTL.
  // Keep dependency lookup restricted to the loader directory and System32.
  HarnessLoadLibrarySearchDllLoadDir: DWORD = $00000100;
  HarnessLoadLibrarySearchSystem32: DWORD = $00000800;
  BrowserDockSettleMs = 200;

type
  // Docking may recreate this HWND even if the frame/TEdgeBrowser objects survive.
  TDockAwareEdgeBrowser = class(TEdgeBrowser)
  private
    FHandleGeneration: Cardinal;
  protected
    procedure CreateWnd; override;
  public
    property HandleGeneration: Cardinal read FHandleGeneration;
  end;

  TBrowserHost = record
    Window, ParentWindow, RootWindow: HWND;
    Generation: Cardinal;
    ScreenBounds: TRect;
    Visible: Boolean;
  end;

  TBrowserState = (bsIdle, bsCreating, bsReady, bsNavigating, bsLoaded, bsFailed);

  THarnessFrame = class(TFrame)
  private
    FRuntime: THarnessRuntime;
    FSettings: THarnessSettings;
    FBrowser: TDockAwareEdgeBrowser;
    FBrowserHost: TBrowserHost;
    FHostObserved, FHostSyncPending, FHostSyncBlocked, FHostRecoveryUsed: Boolean;
    FHostChangedAt: UInt64;
    FCreatingWindow: HWND;
    FCreatingGeneration: Cardinal;
    FResettingBrowser: Boolean;
    FBrowserState: TBrowserState;
    FBrowserStartedAt: UInt64;
    FLogs: TStringList;
    FBrowserError: string;
    FToolbar: TToolBar;
    FActions: TActionList;
    FDiagnosticsButton: TToolButton;
    FStartAction, FStopAction, FRestartAction, FReloadAction: TAction;
    FBrowserAction, FSettingsAction, FInstallAction, FDiagnosticsAction: TAction;
    FTimer: TTimer;
    FLastUrl, FWorkspace: string;
    FAutoStartPending, FRecreateBrowser: Boolean;
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
    procedure NavigationCompleted(Sender: TCustomEdgeBrowser; IsSuccess: Boolean;
      WebErrorStatus: COREWEBVIEW2_WEB_ERROR_STATUS);
    procedure BrowserProcessFailed(Sender: TCustomEdgeBrowser;
      ProcessFailedKind: COREWEBVIEW2_PROCESS_FAILED_KIND);
    procedure ObserveBrowserHost;
    function BrowserHostReady: Boolean;
    procedure SyncBrowserHost;
    procedure EnsureBrowser;
    procedure NavigatePending;
    procedure BrowserError(const Detail: string);
    procedure UpdateStatus;
    procedure DiagnosticsClick(Sender: TObject);
    function StatusText: string;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    procedure ActivatePanel;
    procedure DeactivatePanel;
  end;

  // The IDE owns the dockable host and restores its desktop/docking layout.
  THarnessDock = class(TInterfacedObject, INTACustomDockableForm)
  private
    FHost: TForm;
    FPreviousClose: TCloseEvent;
    procedure HostClose(Sender: TObject; var Action: TCloseAction);
  public
    procedure AttachHost(Host: TCustomForm);
    procedure DetachHost;
    procedure FrameDestroyed(AFrame: THarnessFrame);
    function GetCaption: string;
    function GetIdentifier: string;
    function GetFrameClass: TCustomFrameClass;
    procedure FrameCreated(AFrame: TCustomFrame);
    function GetMenuActionList: TCustomActionList;
    function GetMenuImageList: TCustomImageList;
    procedure CustomizePopupMenu(PopupMenu: TPopupMenu);
    function GetToolBarActionList: TCustomActionList;
    function GetToolBarImageList: TCustomImageList;
    procedure CustomizeToolBar(ToolBar: TToolBar);
    procedure SaveWindowState(Desktop: TCustomIniFile; const Section: string; IsProject: Boolean);
    procedure LoadWindowState(Desktop: TCustomIniFile; const Section: string);
    function GetEditState: TEditState;
    function EditAction(Action: TEditAction): Boolean;
  end;

var
  HarnessDock: INTACustomDockableForm;
  HarnessFrame: THarnessFrame;
  WorkspaceResolver: TWorkspaceResolver;
  DockImplementation: THarnessDock;
  WebViewLoader: HMODULE;

{$R Everywhere.Window.dfm}

procedure TDockAwareEdgeBrowser.CreateWnd;
begin
  inherited;
  Inc(FHandleGeneration);
end;

function FindIDEImage(const Services: INTAServices;
  const Names: array of string): Integer;
var
  Name: string;
  I, Index: Integer;
  function ActionImage(Action: TBasicAction): Integer;
  var
    NativeAction: TCustomAction;
  begin
    Result := -1;
    if not (Action is TCustomAction) then Exit;
    NativeAction := TCustomAction(Action);
    if (NativeAction.Images = Services.ImageList) and (NativeAction.ImageIndex >= 0) and
      (NativeAction.ImageIndex < Services.ImageList.Count) then Result := NativeAction.ImageIndex;
  end;
  function MenuImage(Item: TMenuItem; const Name: string): Integer;
  var
    J: Integer;
  begin
    Result := -1;
    if SameText(Item.Name, Name) then Result := ActionImage(Item.Action);
    if Result >= 0 then Exit;
    for J := 0 to Item.Count - 1 do
    begin
      Result := MenuImage(Item.Items[J], Name);
      if Result >= 0 then Exit;
    end;
  end;
begin
  Result := -1;
  if (Services = nil) or (Services.ImageList = nil) then Exit;
  // Read native icon metadata only; never execute or rebind an IDE command.
  for Name in Names do
  begin
    if Services.ActionList <> nil then
      for I := 0 to Services.ActionList.ActionCount - 1 do
        if SameText(Services.ActionList.Actions[I].Name, Name) then
        begin
          Index := ActionImage(Services.ActionList.Actions[I]);
          if Index >= 0 then Exit(Index);
        end;
    if Services.MainMenu <> nil then
    begin
      Index := MenuImage(Services.MainMenu.Items, Name);
      if Index >= 0 then Exit(Index);
    end;
  end;
end;

constructor THarnessFrame.Create(AOwner: TComponent);
var
  Services: INTAServices;
  function AddAction(const Caption, Hint: string; Handler: TNotifyEvent;
    const NativeNames: array of string): TAction;
  var
    Button: TToolButton;
  begin
    Result := TAction.Create(Self);
    Result.ActionList := FActions;
    Result.Caption := Caption;
    Result.Hint := Hint;
    Result.OnExecute := Handler;
    Result.ImageIndex := FindIDEImage(Services, NativeNames);
    Button := TToolButton.Create(Self);
    Button.Left := FToolbar.ButtonCount * FToolbar.ButtonWidth;
    Button.Parent := FToolbar;
    Button.Action := Result;
    // Version-specific action names can change. Keep controls accessible if so.
    if Result.ImageIndex < 0 then Button.Style := tbsTextButton;
  end;
begin
  inherited Create(AOwner);
  Align := alClient;
  FLogs := TStringList.Create;
  FSettings := THarnessSettings.Load;
  Supports(BorlandIDEServices, INTAServices, Services);
  FActions := TActionList.Create(Self);
  FToolbar := TToolBar.Create(Self);
  FToolbar.Parent := Self;
  FToolbar.Align := alTop;
  FToolbar.AutoSize := True;
  FToolbar.Flat := True;
  FToolbar.EdgeBorders := [];
  FToolbar.ShowCaptions := False;
  FToolbar.AllowTextButtons := True;
  FToolbar.ShowHint := True;
  FToolbar.Wrapable := True;
  FToolbar.ButtonWidth := 28;
  FToolbar.ButtonHeight := 28;
  if Services <> nil then
  begin
    FActions.Images := Services.ImageList;
    FToolbar.Images := Services.ImageList;
  end;
  FStartAction := AddAction('Iniciar', 'Iniciar Harness no projeto ativo', StartClick,
    ['RunRunCommand', 'RunRunItem', 'RunRun', 'RunAction']);
  FStopAction := AddAction('Parar', 'Parar somente o Harness deste painel', StopClick,
    ['RunResetCommand', 'RunResetItem', 'RunReset', 'RunStopItem']);
  FRestartAction := AddAction('Reiniciar', 'Reiniciar Harness no projeto ativo', RestartClick,
    ['RunRestartCommand', 'RunRestartItem', 'RunRestart', 'RunRunCommand', 'RunRunItem']);
  FReloadAction := AddAction('Recarregar', 'Recarregar interface web', ReloadClick,
    ['ViewRefreshCommand', 'ViewRefreshItem', 'RefreshCommand', 'RefreshAction', 'ActionRefreshDevicesToolBar', 'refreshItem']);
  FBrowserAction := AddAction('Navegador', 'Abrir no navegador externo', BrowserClick,
    ['ViewWebBrowserCommand', 'ViewWebBrowserItem', 'HelpEmbarcaderoPageCommand', 'WebBrowserAction']);
  FSettingsAction := AddAction('Opcoes', 'Configuracoes do Harness', SettingsClick,
    ['ToolsOptionsCommand', 'ToolsOptionsItem', 'ToolsOptions']);
  FInstallAction := AddAction('Instalar', 'Instalar runtime explicitamente', InstallClick,
    ['ToolsGetItCommand', 'ToolsGetItItem', 'GetItPackageManagerCommand', 'GetItPackageManager']);
  FDiagnosticsAction := AddAction('Logs', 'Diagnosticos do Harness', DiagnosticsClick,
    ['ViewMessagesCommand', 'ViewMessagesItem', 'ViewMessages', 'ViewMessageViewCommand']);
  FDiagnosticsButton := FToolbar.Buttons[FToolbar.ButtonCount - 1];
  if FDiagnosticsAction.ImageIndex >= 0 then FDiagnosticsButton.Style := tbsCheck;
  FBrowser := TDockAwareEdgeBrowser.Create(Self);
  FBrowser.Parent := Self;
  FBrowser.Align := alClient;
  FBrowser.UserDataFolder := TPath.Combine(SettingsDirectory, 'WebView2');
  FBrowser.OnCreateWebViewCompleted := BrowserCreated;
  FBrowser.OnNavigationCompleted := NavigationCompleted;
  FBrowser.OnProcessFailed := BrowserProcessFailed;
  FRuntime := THarnessRuntime.Create;
  FRuntime.OnLog :=
    procedure(Text: string)
    begin
      AddLog(Text);
    end;
  FTimer := TTimer.Create(Self);
  FTimer.Enabled := False;
  FTimer.Interval := 100;
  FTimer.OnTimer := Tick;
  UpdateStatus;
end;

destructor THarnessFrame.Destroy;
begin
  if DockImplementation <> nil then DockImplementation.FrameDestroyed(Self);
  if HarnessFrame = Self then HarnessFrame := nil;
  if FTimer <> nil then FTimer.Enabled := False;
  if FBrowser <> nil then
  begin
    FBrowser.OnCreateWebViewCompleted := nil;
    FBrowser.OnNavigationCompleted := nil;
    FBrowser.OnProcessFailed := nil;
  end;
  if FRuntime <> nil then
  begin
    FRuntime.OnLog := nil;
    FreeAndNil(FRuntime);
  end;
  FreeAndNil(FLogs);
  inherited;
end;

procedure THarnessFrame.ActivatePanel;
begin
  FAutoStartPending := FSettings.AutoStart and (FRuntime.State = hsStopped);
  FTimer.Enabled := True;
end;

procedure THarnessFrame.DeactivatePanel;
begin
  FAutoStartPending := False;
  FTimer.Enabled := False;
  StopClick(nil);
end;

procedure THarnessFrame.AddLog(const Text: string);
begin
  while FLogs.Count >= 500 do FLogs.Delete(0);
  FLogs.Add(Text);
end;

function THarnessFrame.StatusText: string;
const
  RuntimeNames: array[THarnessState] of string =
    ('Parado', 'Iniciando', 'Em execucao', 'Instalando', 'Erro');
  BrowserNames: array[TBrowserState] of string =
    ('aguardando', 'criando WebView2', 'pronto', 'carregando pagina', 'pagina carregada', 'falha');
begin
  Result := 'Runtime: ' + RuntimeNames[FRuntime.State] +
    ' | Interface: ' + BrowserNames[FBrowserState];
  if FWorkspace <> '' then Result := Result + ' | Projeto: ' + FWorkspace;
  if FRuntime.LastError <> '' then Result := Result + ' | ' + FRuntime.LastError;
  if FBrowserError <> '' then Result := Result + ' | ' + FBrowserError;
end;

procedure THarnessFrame.UpdateStatus;
var
  Busy, HasUrl, HasError: Boolean;
begin
  Busy := FRuntime.State in [hsStarting, hsRunning, hsInstalling];
  HasUrl := FRuntime.ActiveUrl <> '';
  FStartAction.Enabled := not Busy;
  FStopAction.Enabled := Busy;
  FRestartAction.Enabled := FRuntime.State <> hsInstalling;
  FReloadAction.Enabled := HasUrl;
  FBrowserAction.Enabled := HasUrl;
  FInstallAction.Enabled := not Busy;
  HasError := (FRuntime.State = hsError) or (FBrowserState = bsFailed) or
    (FBrowserError <> '');
  FDiagnosticsAction.Checked := HasError;
  if HasError then
  begin
    FDiagnosticsAction.Caption := 'Logs !';
    FDiagnosticsAction.Hint := 'Erro - abrir diagnosticos|' + StatusText;
  end
  else
  begin
    FDiagnosticsAction.Caption := 'Logs';
    FDiagnosticsAction.Hint := 'Diagnosticos do Harness|' + StatusText;
  end;
end;

procedure THarnessFrame.DiagnosticsClick(Sender: TObject);
var
  Dialog: TForm;
  Memo: TMemo;
begin
  // Snapshot on demand: no permanent log/status pane consumes webview space.
  Dialog := TForm.CreateNew(Self);
  try
    Dialog.Caption := 'EveryWhere - Diagnosticos';
    Dialog.Position := poMainFormCenter;
    Dialog.Width := 800;
    Dialog.Height := 480;
    Memo := TMemo.Create(Dialog);
    Memo.Parent := Dialog;
    Memo.Align := alClient;
    Memo.ReadOnly := True;
    Memo.ScrollBars := ssBoth;
    Memo.WordWrap := False;
    Memo.Lines.Add(StatusText);
    Memo.Lines.Add('');
    Memo.Lines.AddStrings(FLogs);
    Dialog.ShowModal;
  finally
    Dialog.Free;
  end;
end;

procedure THarnessFrame.BrowserError(const Detail: string);
begin
  FBrowserState := bsFailed;
  FBrowserError := Detail + ' Use Navegador para testar o runtime; Recarregar tenta novamente. Verifique WebView2 Runtime e WebView2Loader da arquitetura da IDE.';
  AddLog(FBrowserError);
end;

procedure THarnessFrame.ObserveBrowserHost;
var
  Current: TBrowserHost;
  HostChanged: Boolean;
begin
  if csDestroying in ComponentState then Exit;
  // Sample on the UI timer, never rebuild inside VCL docking/resize callbacks.
  // The initial child HWND must exist before BrowserHostReady can become true.
  // Do not force creation for an invisible desktop tab or an unparented frame.
  if not FBrowser.HandleAllocated and HandleAllocated and Showing and
    IsWindowVisible(Handle) then FBrowser.HandleNeeded;
  FillChar(Current, SizeOf(Current), 0);
  Current.Generation := FBrowser.HandleGeneration;
  if FBrowser.HandleAllocated then
  begin
    Current.Window := FBrowser.Handle;
    Current.ParentWindow := Winapi.Windows.GetParent(Current.Window);
    Current.RootWindow := GetAncestor(Current.Window, GA_ROOT);
    GetWindowRect(Current.Window, Current.ScreenBounds);
    Current.Visible := IsWindowVisible(Current.Window) and
      not IsIconic(Current.RootWindow) and
      (FBrowser.ClientWidth > 0) and (FBrowser.ClientHeight > 0);
  end;
  HostChanged := not FHostObserved or
    (Current.Window <> FBrowserHost.Window) or
    (Current.ParentWindow <> FBrowserHost.ParentWindow) or
    (Current.RootWindow <> FBrowserHost.RootWindow) or
    (Current.Generation <> FBrowserHost.Generation);
  if HostChanged or (Current.Visible <> FBrowserHost.Visible) or
    not EqualRect(Current.ScreenBounds, FBrowserHost.ScreenBounds) then
  begin
    if HostChanged then
    begin
      FHostRecoveryUsed := False;
      FHostSyncBlocked := False;
    end;
    FBrowserHost := Current;
    FHostObserved := True;
    FHostSyncPending := True;
    FHostChangedAt := GetTickCount64;
  end;
end;

function THarnessFrame.BrowserHostReady: Boolean;
begin
  Result := not (csDestroying in ComponentState) and
    FHostObserved and not FHostSyncPending and not FHostSyncBlocked and
    FBrowserHost.Visible and FBrowser.HandleAllocated;
end;

procedure THarnessFrame.SyncBrowserHost;
var
  Controller: ICoreWebView2Controller;
  ParentWindow: wireHWND;
  ClientBounds: System.Types.TRect;
  Bounds: Winapi.WebView2.tagRECT;
  Code: HRESULT;
begin
  if (csDestroying in ComponentState) or not FHostSyncPending or FHostSyncBlocked or
    (GetTickCount64 - FHostChangedAt < BrowserDockSettleMs) then Exit;
  if not FBrowser.HandleAllocated then Exit;
  if (FBrowserState = bsCreating) and
    ((FCreatingWindow <> FBrowserHost.Window) or
     (FCreatingGeneration <> FBrowserHost.Generation)) then
  begin
    if FHostRecoveryUsed then
    begin
      FHostSyncBlocked := True;
      BrowserError('A janela mudou durante a criacao do navegador. Use Recarregar.');
      Exit;
    end;
    FHostRecoveryUsed := True;
    // A pending create for a dead HWND must not leave bsCreating stuck forever.
    // Close only after settling, outside the HWND destruction/COM callback stack.
    FResettingBrowser := True;
    try
      FBrowser.CloseWebView;
    finally
      FResettingBrowser := False;
    end;
    FBrowserState := bsIdle;
    FLastUrl := '';
    FHostChangedAt := GetTickCount64;
    Exit;
  end;
  Controller := FBrowser.ControllerInterface;
  if Controller = nil then
  begin
    FHostSyncPending := False;
    // A recreated HWND may have disposed the view without a process-failed event.
    // Keep genuine startup failures until explicit Reload; do not retry each tick.
    if FBrowserHost.Visible and
      (FBrowserState in [bsReady, bsNavigating, bsLoaded]) then
    begin
      FBrowserState := bsIdle;
      FLastUrl := '';
    end;
    Exit;
  end;
  Code := Controller.Get_ParentWindow(ParentWindow);
  if (Code >= 0) and (NativeUInt(ParentWindow) <> NativeUInt(FBrowserHost.Window)) then
    Code := Controller.Set_ParentWindow(wireHWND(FBrowserHost.Window));
  if Code >= 0 then
  begin
    ClientBounds := FBrowser.ClientRect;
    // WebView2's imported COM record is distinct from the VCL TRect type.
    Bounds.Left := ClientBounds.Left;
    Bounds.Top := ClientBounds.Top;
    Bounds.Right := ClientBounds.Right;
    Bounds.Bottom := ClientBounds.Bottom;
    Code := Controller.Set_Bounds(Bounds);
  end;
  if Code >= 0 then Code := Controller.Set_IsVisible(Ord(FBrowserHost.Visible));
  if Code >= 0 then Code := Controller.NotifyParentWindowPositionChanged;
  FHostSyncPending := False;
  if Code >= 0 then
  begin
    // Updating the controller preserves the page, input and runtime session.
    if FBrowserHost.Visible then FBrowser.Invalidate;
    Exit;
  end;
  if not FBrowserHost.Visible then Exit; // wait until the tab/host is visible again
  if not FHostRecoveryUsed and (FBrowserState <> bsCreating) then
  begin
    FHostRecoveryUsed := True;
    AddLog('Recriando somente a visualizacao apos mudanca de docking (HRESULT 0x' +
      IntToHex(Cardinal(Code), 8) + ').');
    FResettingBrowser := True;
    try
      FBrowser.CloseWebView;
    finally
      FResettingBrowser := False;
    end;
    FBrowserState := bsIdle;
    FLastUrl := '';
    // Tick starts the view again on the same ActiveUrl; no runtime Start/Stop.
  end
  else
  begin
    FHostSyncBlocked := True;
    BrowserError('Falha ao sincronizar docking (HRESULT 0x' + IntToHex(Cardinal(Code), 8) + ').');
  end;
end;

procedure THarnessFrame.EnsureBrowser;
var
  LoaderPath: string;
  ErrorCode: DWORD;
begin
  if (FBrowserState <> bsIdle) or not BrowserHostReady then Exit;
  FBrowserError := '';
  FBrowserState := bsCreating;
  FBrowserStartedAt := GetTickCount64;
  try
    // A plugin is not an EXE: Windows does not search beside its BPL by default.
    // Prefer an already loaded IDE loader. Never change PATH/SetDllDirectory or
    // overwrite another extension's choice. Only load from our installed BPL dir.
    if (GetModuleHandle('WebView2Loader.dll') = 0) and (WebViewLoader = 0) then
    begin
      LoaderPath := TPath.Combine(ExtractFilePath(GetModuleName(HInstance)), 'WebView2Loader.dll');
      if FileExists(LoaderPath) then
      begin
        WebViewLoader := LoadLibraryEx(PChar(LoaderPath), 0,
          HarnessLoadLibrarySearchDllLoadDir or HarnessLoadLibrarySearchSystem32);
        if WebViewLoader = 0 then
        begin
          ErrorCode := GetLastError;
          BrowserError('Falha ao carregar WebView2Loader junto da BPL (Win32 ' + IntToStr(ErrorCode) + ').');
          Exit;
        end;
      end;
    end;
    // Do not navigate or mark the URL consumed before async creation succeeds.
    FBrowser.HandleNeeded;
    FCreatingWindow := FBrowser.Handle;
    FCreatingGeneration := FBrowser.HandleGeneration;
    FBrowser.CreateWebView;
  except
    BrowserError('Nao foi possivel iniciar WebView2.');
  end;
end;

procedure THarnessFrame.NavigatePending;
begin
  if not BrowserHostReady or not FBrowser.WebViewCreated or
    not (FBrowserState in [bsReady, bsLoaded]) or (FRuntime.ActiveUrl = '') or
    (FRuntime.ActiveUrl = FLastUrl) then Exit;
  FBrowserState := bsNavigating;
  FBrowserStartedAt := GetTickCount64;
  if FBrowser.Navigate(FRuntime.ActiveUrl) then
    FLastUrl := FRuntime.ActiveUrl
  else
    BrowserError('WebView2 recusou a navegacao.');
end;

procedure THarnessFrame.Tick(Sender: TObject);
begin
  if csDestroying in ComponentState then Exit;
  FTimer.Enabled := False;
  try
    try
      if FAutoStartPending then
      begin
        FAutoStartPending := False;
        if Assigned(WorkspaceResolver) and (WorkspaceResolver() <> '') then StartClick(nil);
      end;
      FRuntime.Poll;
      ObserveBrowserHost;
      SyncBrowserHost;
      if FRuntime.ActiveUrl <> '' then
      begin
        EnsureBrowser;
        NavigatePending;
      end
      else if FLastUrl <> '' then
      begin
        FLastUrl := '';
        if FBrowser.WebViewCreated then FBrowser.Navigate('about:blank');
        FBrowserState := bsReady;
      end;
      if (FBrowserState in [bsCreating, bsNavigating]) and
        (GetTickCount64 - FBrowserStartedAt >= 30000) then
        BrowserError('Tempo limite do navegador excedido (30 segundos).');
      UpdateStatus;
    except
      BrowserError('Falha ao atualizar a interface.');
    end;
  finally
    FTimer.Enabled := True;
  end;
end;

procedure THarnessFrame.StartClick(Sender: TObject);
var
  Workspace: string;
begin
  if FRuntime.State in [hsStarting, hsRunning, hsInstalling] then Exit;
  Workspace := '';
  if Assigned(WorkspaceResolver) then Workspace := WorkspaceResolver();
  if (Workspace = '') or not DirectoryExists(Workspace) then
  begin
    FBrowserError := 'Abra e salve um projeto Delphi ou C++Builder antes de iniciar.';
    AddLog(FBrowserError);
    UpdateStatus;
    Exit;
  end;
  if (FBrowserState = bsFailed) and not FBrowser.WebViewCreated then
    FBrowserState := bsIdle;
  FBrowserError := '';
  FWorkspace := Workspace;
  FRuntime.Start(Workspace, FSettings.Executable, FSettings.Profile, FSettings.Port);
  UpdateStatus;
end;

procedure THarnessFrame.StopClick(Sender: TObject);
begin
  FRuntime.Stop;
  FBrowserError := '';
  FLastUrl := '';
  if FBrowser.WebViewCreated then
  begin
    FBrowserState := bsReady;
    FBrowser.Navigate('about:blank');
  end;
  UpdateStatus;
end;

procedure THarnessFrame.RestartClick(Sender: TObject);
begin
  StopClick(nil);
  StartClick(nil);
end;

procedure THarnessFrame.ReloadClick(Sender: TObject);
begin
  FBrowserError := '';
  FHostRecoveryUsed := False;
  FHostSyncBlocked := False;
  FHostSyncPending := True;
  FHostChangedAt := GetTickCount64;
  FLastUrl := '';
  if FRecreateBrowser then
  begin
    FBrowser.CloseWebView;
    FBrowserState := bsIdle;
    FRecreateBrowser := False;
  end;
  if FBrowser.WebViewCreated then FBrowserState := bsReady
  else if FBrowserState <> bsCreating then FBrowserState := bsIdle;
  EnsureBrowser;
  NavigatePending;
end;

procedure THarnessFrame.BrowserClick(Sender: TObject);
begin
  if FRuntime.ActiveUrl <> '' then
    if NativeInt(ShellExecute(Handle, 'open', PChar(FRuntime.ActiveUrl), nil, nil,
      SW_SHOWNORMAL)) <= 32 then AddLog('Nao foi possivel abrir o navegador padrao.');
end;

procedure THarnessFrame.SettingsClick(Sender: TObject);
begin
  if EditSettings(FSettings) then AddLog('Configuracoes salvas. Reinicie o runtime para aplica-las.');
end;

procedure THarnessFrame.InstallClick(Sender: TObject);
begin
  FRuntime.Install;
  UpdateStatus;
end;

procedure THarnessFrame.BrowserCreated(Sender: TCustomEdgeBrowser; AResult: HRESULT);
begin
  if (csDestroying in ComponentState) or FResettingBrowser then Exit;
  // Do not let late callbacks demote an already ready/navigating view.
  if FBrowserState <> bsCreating then Exit;
  if (AResult >= 0) and not FBrowser.WebViewCreated then Exit;
  if (Cardinal(AResult) = $80004004) and not FHostRecoveryUsed then
  begin
    // E_ABORT may be delivered synchronously while docking destroys the HWND.
    // Defer one retry to the timer; never create/close a controller in this callback.
    FHostRecoveryUsed := True;
    FBrowserState := bsIdle;
    FHostSyncPending := True;
    FHostChangedAt := GetTickCount64;
    AddLog('Criacao WebView2 interrompida; aguardando janela estabilizar.');
  end
  else if AResult < 0 then
    BrowserError('Falha ao criar WebView2 (HRESULT 0x' + IntToHex(Cardinal(AResult), 8) + ').')
  else
  begin
    FBrowserState := bsReady;
    // Creation can complete during a docking operation. Wait for the settled HWND.
    FHostSyncPending := True;
    FHostChangedAt := GetTickCount64;
  end;
  UpdateStatus;
end;

procedure THarnessFrame.NavigationCompleted(Sender: TCustomEdgeBrowser; IsSuccess: Boolean;
  WebErrorStatus: COREWEBVIEW2_WEB_ERROR_STATUS);
begin
  // Ignore known blank/cancelled completions. TEdgeBrowser's VCL event does not
  // expose NavigationId; rapid overlapping navigations still need IDE smoke tests.
  if (FRuntime.ActiveUrl = '') or (FBrowserState <> bsNavigating) or
    SameText(FBrowser.LocationURL, 'about:blank') then Exit;
  if (not IsSuccess) and (WebErrorStatus = COREWEBVIEW2_WEB_ERROR_STATUS_OPERATION_CANCELED) then Exit;
  if IsSuccess then
  begin
    FBrowserState := bsLoaded;
  end
  else
    BrowserError('Navegacao falhou (WebErrorStatus ' + IntToStr(Ord(WebErrorStatus)) + ').');
  UpdateStatus;
end;

procedure THarnessFrame.BrowserProcessFailed(Sender: TCustomEdgeBrowser;
  ProcessFailedKind: COREWEBVIEW2_PROCESS_FAILED_KIND);
begin
  FRecreateBrowser := True;
  BrowserError('Processo WebView2 falhou (tipo ' + IntToStr(Ord(ProcessFailedKind)) + ').');
  UpdateStatus;
end;

function THarnessDock.GetCaption: string;
begin
  Result := 'EveryWhere Harness';
end;

function THarnessDock.GetIdentifier: string;
begin
  Result := 'EverywhereHarnessDock';
end;

function THarnessDock.GetFrameClass: TCustomFrameClass;
begin
  Result := THarnessFrame;
end;

procedure THarnessDock.AttachHost(Host: TCustomForm);
begin
  if (Host is TForm) and (FHost <> Host) then
  begin
    FHost := TForm(Host);
    FPreviousClose := FHost.OnClose;
    FHost.OnClose := HostClose;
  end;
end;

procedure THarnessDock.FrameCreated(AFrame: TCustomFrame);
begin
  HarnessFrame := AFrame as THarnessFrame;
  AttachHost(GetParentForm(AFrame));
  HarnessFrame.ActivatePanel;
end;

procedure THarnessDock.HostClose(Sender: TObject; var Action: TCloseAction);
begin
  if Assigned(FPreviousClose) then FPreviousClose(Sender, Action);
  if Action = caNone then Exit;
  if HarnessFrame <> nil then HarnessFrame.DeactivatePanel;
  if Action = caFree then
  begin
    FHost := nil;
    FPreviousClose := nil;
  end;
end;

procedure THarnessDock.FrameDestroyed(AFrame: THarnessFrame);
begin
  if HarnessFrame = AFrame then
  begin
    // Host destruction does not necessarily raise OnClose (desktop/IDE exit).
    // Remove package callbacks while the parent is still alive, then forget it.
    if FHost <> nil then FHost.OnClose := FPreviousClose;
    FHost := nil;
    FPreviousClose := nil;
  end;
end;

procedure THarnessDock.DetachHost;
begin
  if FHost <> nil then FHost.OnClose := FPreviousClose;
end;

function THarnessDock.GetMenuActionList: TCustomActionList;
begin
  Result := nil;
end;

function THarnessDock.GetMenuImageList: TCustomImageList;
begin
  Result := nil;
end;

procedure THarnessDock.CustomizePopupMenu(PopupMenu: TPopupMenu);
begin
  // Preserve the IDE's native docking commands.
end;

function THarnessDock.GetToolBarActionList: TCustomActionList;
begin
  Result := nil;
end;

function THarnessDock.GetToolBarImageList: TCustomImageList;
begin
  Result := nil;
end;

procedure THarnessDock.CustomizeToolBar(ToolBar: TToolBar);
begin
end;

procedure THarnessDock.SaveWindowState(Desktop: TCustomIniFile; const Section: string; IsProject: Boolean);
begin
  // The host persists docking; never persist runtime URLs or credentials here.
end;

procedure THarnessDock.LoadWindowState(Desktop: TCustomIniFile; const Section: string);
begin
end;

function THarnessDock.GetEditState: TEditState;
begin
  Result := [];
end;

function THarnessDock.EditAction(Action: TEditAction): Boolean;
begin
  Result := False;
end;

procedure RegisterHarnessWindow(Resolver: TWorkspaceResolver);
var
  Services: INTAServices;
begin
  WorkspaceResolver := Resolver;
  if HarnessDock <> nil then Exit;
  if not Supports(BorlandIDEServices, INTAServices, Services) then
    raise Exception.Create('Servicos de docking da IDE indisponiveis.');
  DockImplementation := THarnessDock.Create;
  HarnessDock := DockImplementation;
  try
    Services.RegisterDockableForm(HarnessDock);
  except
    HarnessDock := nil;
    DockImplementation := nil;
    raise;
  end;
end;

procedure ShowHarnessWindow(Resolver: TWorkspaceResolver);
var
  Services: INTAServices;
  Host: TCustomForm;
begin
  RegisterHarnessWindow(Resolver);
  if not Supports(BorlandIDEServices, INTAServices, Services) then Exit;
  Host := nil;
  if HarnessFrame <> nil then Host := GetParentForm(HarnessFrame);
  if Host = nil then Host := Services.CreateDockableForm(HarnessDock);
  if Host = nil then Exit;
  DockImplementation.AttachHost(Host);
  // ForceShow correctly activates a hidden tab when already docked in the IDE.
  if Host is TDockableForm then TDockableForm(Host).ForceShow
  else Host.Show;
  if HarnessFrame <> nil then HarnessFrame.ActivatePanel;
end;

procedure UnregisterHarnessWindow;
var
  Services: INTAServices;
begin
  if HarnessFrame <> nil then HarnessFrame.DeactivatePanel;
  if DockImplementation <> nil then DockImplementation.DetachHost;
  if (HarnessDock <> nil) and Supports(BorlandIDEServices, INTAServices, Services) then
    Services.UnregisterDockableForm(HarnessDock);
  // Some IDE versions keep a hidden host after unregistering its descriptor.
  // Release any surviving frame only AFTER the IDE has finished unregistering.
  FreeAndNil(HarnessFrame);
  HarnessDock := nil;
  DockImplementation := nil;
  WorkspaceResolver := nil;
end;

initialization
  HarnessFrame := nil;

finalization
  UnregisterHarnessWindow;
  // Keep this process-wide loader mapped: vcledge/other IDE consumers may still
  // hold function pointers. Windows releases the module when the IDE exits.

end.
