unit Everywhere.Runtime;

interface

uses
  Winapi.Windows, System.SysUtils;

type
  THarnessState = (hsStopped, hsStarting, hsRunning, hsInstalling, hsError);

  // All methods and callbacks belong to the UI thread. Call Poll from TTimer.
  // The runtime never persists credentials or ActiveUrl (which contains a token).
  THarnessRuntime = class
  private
    FState: THarnessState;
    FActiveUrl: string;
    FLastError: string;
    FOnLog: TProc<string>;
    FProcess, FJob, FReadPipe: THandle;
    FStartedAt: UInt64;
    FPending: TBytes;
    FDroppingLine, FPolling: Boolean;
    FLogCount: Integer;
    procedure ReleaseProcess;
    procedure Fail(const Message: string);
    procedure Log(const Message: string);
    procedure Consume(const Buffer; Count: Cardinal);
    procedure FinishLine;
    procedure Launch(const Executable, Arguments, Directory: string;
      NewState: THarnessState);
  public
    constructor Create;
    destructor Destroy; override;
    procedure Start(const Workspace, Executable, Profile: string; Port: Integer);
    procedure Stop;
    procedure Install;
    procedure Poll;
    property ActiveUrl: string read FActiveUrl;
    property State: THarnessState read FState;
    property LastError: string read FLastError;
    property OnLog: TProc<string> read FOnLog write FOnLog;
  end;

implementation

uses
  System.Classes, System.StrUtils, Everywhere.Protocol;

const
  StartupTimeoutMs = 60000;
  InstallTimeoutMs = 600000;
  MaxLineBytes = 8192;
  MaxLogLines = 1000;
  PollByteBudget = 65536;
  ExtendedStartupInfoPresent = $00080000;
  ProcThreadAttributeHandleList = $00020002;

type
  // Local declarations keep compatibility with Delphi Windows header versions.
  TStartupInfoExLocal = record
    StartupInfo: TStartupInfo;
    AttributeList: Pointer;
  end;

function InitAttributes(List: Pointer; Count, Flags: DWORD;
  var Size: NativeUInt): BOOL; stdcall;
  external kernel32 name 'InitializeProcThreadAttributeList';
function SetAttribute(List: Pointer; Flags: DWORD; Attribute: NativeUInt;
  Value: Pointer; Size: NativeUInt; PreviousValue, ReturnSize: Pointer): BOOL; stdcall;
  external kernel32 name 'UpdateProcThreadAttribute';
procedure FreeAttributes(List: Pointer); stdcall;
  external kernel32 name 'DeleteProcThreadAttributeList';

procedure CloseOwnedHandle(var Handle: THandle);
begin
  if (Handle <> 0) and (Handle <> INVALID_HANDLE_VALUE) then CloseHandle(Handle);
  Handle := 0;
end;

function IsAbsoluteLocalPath(const Value: string): Boolean;
begin
  // Explicit local paths only; no relative cwd, UNC or device namespaces.
  Result := (Length(Value) >= 3) and
    CharInSet(Value[1], ['a'..'z', 'A'..'Z']) and
    (Value[2] = ':') and CharInSet(Value[3], ['\', '/']);
end;

function ValidDirectory(const Value: string): string;
begin
  if not IsAbsoluteLocalPath(Value) or not DirectoryExists(Value) then
    raise EArgumentException.Create('Informe um diretorio local absoluto existente.');
  Result := ExpandFileName(Value);
end;

function ValidExecutable(const Value: string): string;
var
  Ext: string;
begin
  Result := '';
  if not IsAbsoluteLocalPath(Value) or not FileExists(Value) then Exit;
  Ext := LowerCase(ExtractFileExt(Value));
  if (Ext <> '.exe') and (Ext <> '.cmd') then Exit;
  if (Ext = '.cmd') and not IsSafeCmdArgument(Value) then Exit;
  Result := ExpandFileName(Value);
end;

function FindExecutable(const Name: string): string;
var
  Paths: TStringList;
  Directory, Candidate, Root: string;
begin
  Result := '';
  Paths := TStringList.Create;
  try
    // PATH is split explicitly: never search the workspace/current directory.
    Paths.StrictDelimiter := True;
    Paths.Delimiter := ';';
    Paths.QuoteChar := #0;
    Paths.DelimitedText := GetEnvironmentVariable('PATH');
    Root := GetEnvironmentVariable('APPDATA');
    if Root <> '' then Paths.Add(IncludeTrailingPathDelimiter(Root) + 'npm');
    Root := GetEnvironmentVariable('LOCALAPPDATA');
    if Root <> '' then
    begin
      Paths.Add(IncludeTrailingPathDelimiter(Root) + 'npm');
      Paths.Add(IncludeTrailingPathDelimiter(Root) + 'Programs\nodejs');
    end;
    Root := GetEnvironmentVariable('ProgramFiles');
    if Root <> '' then Paths.Add(IncludeTrailingPathDelimiter(Root) + 'nodejs');
    Root := GetEnvironmentVariable('NPM_CONFIG_PREFIX');
    if Root <> '' then Paths.Add(Root);
    for Directory in Paths do
    begin
      Candidate := Trim(Directory);
      if (Length(Candidate) >= 2) and (Candidate[1] = '"') and
        (Candidate[Length(Candidate)] = '"') then
        Candidate := Copy(Candidate, 2, Length(Candidate) - 2);
      if not IsAbsoluteLocalPath(Candidate) then Continue;
      Result := ValidExecutable(IncludeTrailingPathDelimiter(Candidate) + Name);
      if Result <> '' then Exit;
    end;
  finally
    Paths.Free;
  end;
end;

function FindHarness(const CustomPath: string): string;
begin
  if CustomPath <> '' then
  begin
    Result := ValidExecutable(CustomPath);
    if Result = '' then
      raise EArgumentException.Create('Executavel personalizado invalido; use caminho absoluto .exe ou .cmd.');
    Exit;
  end;
  Result := FindExecutable('ewh.cmd');
  if Result = '' then Result := FindExecutable('ewh.exe');
  if Result = '' then Result := FindExecutable('dsh.cmd');
  if Result = '' then Result := FindExecutable('dsh.exe');
  if Result = '' then
    raise EArgumentException.Create('CLI ewh/dsh nao encontrada no PATH/npm. Use Instalar explicitamente ou configure o executavel.');
end;

function SanitizeRuntimeLog(const Value: string): string;
const
  CredentialNames: array[0..7] of string = (
    'EVERYWHERE_API_KEY', 'DEEPSEEK_API_KEY', 'OPENAI_API_KEY',
    'ANTHROPIC_API_KEY', 'GEMINI_API_KEY', 'GOOGLE_API_KEY',
    'AZURE_OPENAI_API_KEY', 'NPM_TOKEN');
var
  Name, Secret, Safe: string;
begin
  Safe := Value;
  // Values are read only for redaction and are never retained in the object.
  for Name in CredentialNames do
  begin
    Secret := GetEnvironmentVariable(Name);
    if Secret <> '' then
      Safe := StringReplace(Safe, Secret, '[omitido]', [rfReplaceAll]);
    Secret := '';
  end;
  Result := RedactLog(Safe);
end;
constructor THarnessRuntime.Create;
begin
  inherited Create;
  FState := hsStopped;
end;

destructor THarnessRuntime.Destroy;
begin
  FOnLog := nil;
  ReleaseProcess;
  inherited Destroy;
end;

procedure THarnessRuntime.ReleaseProcess;
begin
  // Closing our private job kills only its assigned process tree.
  CloseOwnedHandle(FJob);
  CloseOwnedHandle(FProcess);
  CloseOwnedHandle(FReadPipe);
  FPending := nil;
  FDroppingLine := False;
  FActiveUrl := '';
end;

procedure THarnessRuntime.Stop;
begin
  ReleaseProcess;
  FState := hsStopped;
  FLastError := '';
end;

procedure THarnessRuntime.Log(const Message: string);
var
  Safe: string;
begin
  if FLogCount >= MaxLogLines then Exit;
  Inc(FLogCount);
  if FLogCount = MaxLogLines then Safe := '[limite de logs atingido]'
  else Safe := SanitizeRuntimeLog(Message);
  if Assigned(FOnLog) then
    try
      FOnLog(Safe);
    except
      // A UI log sink must not interrupt process cleanup or polling.
    end;
end;

procedure THarnessRuntime.Fail(const Message: string);
begin
  ReleaseProcess;
  FState := hsError;
  FLastError := SanitizeRuntimeLog(Message);
  Log(FLastError);
end;

procedure THarnessRuntime.Launch(const Executable, Arguments, Directory: string;
  NewState: THarnessState);
var
  SA: TSecurityAttributes;
  SI: TStartupInfoExLocal;
  PI: TProcessInformation;
  Limits: TJobObjectExtendedLimitInformation;
  WritePipe, NullInput: THandle;
  Handles: array[0..1] of THandle;
  AttributeSize: NativeUInt;
  AttributesReady, AssignedToJob: Boolean;
  Application, CommandLine: string;
  SystemPath: array[0..MAX_PATH] of Char;
  PathLength: UINT;
begin
  WritePipe := 0;
  NullInput := 0;
  AttributesReady := False;
  AssignedToJob := False;
  FillChar(SI, SizeOf(SI), 0);
  FillChar(PI, SizeOf(PI), 0);
  try
    FJob := CreateJobObject(nil, nil);
    if FJob = 0 then RaiseLastOSError;
    FillChar(Limits, SizeOf(Limits), 0);
    Limits.BasicLimitInformation.LimitFlags := JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
    if not SetInformationJobObject(FJob, JobObjectExtendedLimitInformation,
      @Limits, SizeOf(Limits)) then RaiseLastOSError;
    FillChar(SA, SizeOf(SA), 0);
    SA.nLength := SizeOf(SA);
    SA.bInheritHandle := True;
    if not CreatePipe(FReadPipe, WritePipe, @SA, 0) then RaiseLastOSError;
    if not SetHandleInformation(FReadPipe, HANDLE_FLAG_INHERIT, 0) then RaiseLastOSError;
    NullInput := CreateFile('NUL', GENERIC_READ, FILE_SHARE_READ or FILE_SHARE_WRITE,
      @SA, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, 0);
    if NullInput = INVALID_HANDLE_VALUE then RaiseLastOSError;

    // Restrict inheritance to our pipe/NUL, not unrelated IDE handles.
    AttributeSize := 0;
    InitAttributes(nil, 1, 0, AttributeSize);
    if AttributeSize = 0 then RaiseLastOSError;
    GetMem(SI.AttributeList, AttributeSize);
    if not InitAttributes(SI.AttributeList, 1, 0, AttributeSize) then RaiseLastOSError;
    AttributesReady := True;
    Handles[0] := WritePipe;
    Handles[1] := NullInput;
    if not SetAttribute(SI.AttributeList, 0, ProcThreadAttributeHandleList,
      @Handles[0], SizeOf(Handles), nil, nil) then RaiseLastOSError;
    SI.StartupInfo.cb := SizeOf(SI);
    SI.StartupInfo.dwFlags := STARTF_USESTDHANDLES;
    SI.StartupInfo.hStdInput := NullInput;
    SI.StartupInfo.hStdOutput := WritePipe;
    SI.StartupInfo.hStdError := WritePipe;

    Application := Executable;
    if SameText(ExtractFileExt(Executable), '.cmd') then
    begin
      PathLength := GetSystemDirectory(SystemPath, Length(SystemPath));
      if (PathLength = 0) or (PathLength >= UINT(Length(SystemPath))) then
        raise EArgumentException.Create('Nao foi possivel localizar cmd.exe do Windows.');
      SetString(Application, PChar(@SystemPath[0]), PathLength);
      Application := IncludeTrailingPathDelimiter(Application) + 'cmd.exe';
      // /D disables AutoRun; /V:OFF disables delayed expansion. The outer
      // quote pair is consumed by /S /C. Each inner argument is validated.
      CommandLine := QuoteWindowsArgument(Application) + ' /D /V:OFF /S /C "' +
        QuoteCmdArgument(Executable) + ' ' + Arguments + '"';
    end
    else CommandLine := QuoteWindowsArgument(Application) + ' ' + Arguments;
    UniqueString(CommandLine); // CreateProcessW may modify its command line.
    // nil environment inherits API keys; never read/write a credential file.
    if not CreateProcess(PChar(Application), PChar(CommandLine), nil, nil, True,
      CREATE_SUSPENDED or CREATE_NO_WINDOW or ExtendedStartupInfoPresent,
      nil, PChar(Directory), SI.StartupInfo, PI) then RaiseLastOSError;
    if not AssignProcessToJobObject(FJob, PI.hProcess) then RaiseLastOSError;
    AssignedToJob := True;
    if ResumeThread(PI.hThread) = DWORD(-1) then RaiseLastOSError;
    FProcess := PI.hProcess;
    PI.hProcess := 0;
    FStartedAt := GetTickCount64;
    FState := NewState;
  finally
    if PI.hProcess <> 0 then
    begin
      // A failed assignment must never leave the suspended child behind.
      // This handle belongs to the process created above, never a PID lookup.
      if not AssignedToJob then TerminateProcess(PI.hProcess, 1);
      CloseOwnedHandle(PI.hProcess);
    end;
    CloseOwnedHandle(PI.hThread);
    CloseOwnedHandle(WritePipe);
    CloseOwnedHandle(NullInput);
    if AttributesReady then FreeAttributes(SI.AttributeList);
    if SI.AttributeList <> nil then FreeMem(SI.AttributeList);
  end;
end;

procedure THarnessRuntime.Start(const Workspace, Executable, Profile: string; Port: Integer);
var
  Directory, Binary, Arguments: string;
begin
  if FPolling or (FState in [hsStarting, hsRunning, hsInstalling]) then Exit;
  Stop;
  FLogCount := 0;
  try
    Directory := ValidDirectory(Workspace);
    if not IsSafeProfile(Profile) then
      raise EArgumentException.Create('Perfil invalido: use letras, numeros, hifen ou sublinhado (maximo 64).');
    if (Port < 0) or (Port > 65535) then
      raise EArgumentException.Create('Porta invalida: use 0 (padrao do runtime) ou 1..65535.');
    Binary := FindHarness(Executable);
    // Profile contains only the validated ASCII allowlist for either launcher.
    Arguments := '--profile ' + Profile + ' --no-open';
    if Port <> 0 then Arguments := Arguments + ' --port ' + IntToStr(Port);
    Launch(Binary, Arguments, Directory, hsStarting);
    Log('Iniciando Harness no workspace selecionado.');
  except
    on E: Exception do Fail(E.Message);
  end;
end;

procedure THarnessRuntime.Install;
var
  Binary, Directory: string;
begin
  if FPolling or (FState in [hsStarting, hsRunning, hsInstalling]) then Exit;
  Stop;
  FLogCount := 0;
  try
    // Explicit global install, independent of Start and never in project cwd.
    Directory := ValidDirectory(GetEnvironmentVariable('TEMP'));
    Binary := FindExecutable('npm.cmd');
    if Binary = '' then Binary := FindExecutable('npm.exe');
    if Binary = '' then
      raise EArgumentException.Create('npm nao encontrado. Instale Node.js/npm e tente novamente.');
    Launch(Binary, 'install -g @everywhere-harness/ewh', Directory, hsInstalling);
    Log('Instalacao global solicitada: npm install -g @everywhere-harness/ewh');
  except
    on E: Exception do Fail(E.Message);
  end;
end;

procedure THarnessRuntime.FinishLine;
var
  Line, Url: string;
begin
  if FDroppingLine then
  begin
    FPending := nil;
    FDroppingLine := False;
    Log('[linha longa omitida]');
    Exit;
  end;
  Line := TEncoding.UTF8.GetString(FPending);
  FPending := nil;
  if (Length(Line) > 0) and (Line[Length(Line)] = #13) then
    Delete(Line, Length(Line), 1);
  if (FState = hsStarting) and TryExtractHarnessUrl(Line, Url) then
  begin
    FActiveUrl := Url;
    FState := hsRunning;
    Log('Harness pronto; URL autenticada nao sera exibida nos logs.');
  end
  else if Line <> '' then Log(Line);
end;

procedure THarnessRuntime.Consume(const Buffer; Count: Cardinal);
var
  Bytes: PByte;
  I, Size: Integer;
begin
  Bytes := @Buffer;
  for I := 0 to Integer(Count) - 1 do
  begin
    if Bytes[I] = 10 then FinishLine
    else if not FDroppingLine then
    begin
      Size := Length(FPending);
      if Size >= MaxLineBytes then
      begin
        FPending := nil;
        FDroppingLine := True;
      end
      else
      begin
        SetLength(FPending, Size + 1);
        FPending[Size] := Bytes[I];
      end;
    end;
    if FProcess = 0 then Exit; // OnLog may have called Stop.
  end;
end;

procedure THarnessRuntime.Poll;
var
  Buffer: array[0..4095] of Byte;
  Available, ReadCount, ToRead, Budget, ExitCode, ErrorCode: DWORD;
  WasInstalling: Boolean;
  WaitResult: DWORD;
begin
  if FPolling or (FProcess = 0) then Exit;
  FPolling := True;
  try
    // Check deadlines before draining: continuous output must not postpone them.
    if (FState = hsStarting) and (GetTickCount64 - FStartedAt >= StartupTimeoutMs) then
    begin
      Fail('Tempo limite de inicializacao excedido (60 segundos).');
      Exit;
    end;
    if (FState = hsInstalling) and (GetTickCount64 - FStartedAt >= InstallTimeoutMs) then
    begin
      Fail('Tempo limite de instalacao excedido (10 minutos).');
      Exit;
    end;
    Budget := PollByteBudget;
    while (FReadPipe <> 0) and (Budget > 0) do
    begin
      if not PeekNamedPipe(FReadPipe, nil, 0, nil, @Available, nil) then
      begin
        ErrorCode := GetLastError;
        if ErrorCode = ERROR_BROKEN_PIPE then Break;
        Fail('Falha ao consultar saida do processo (Win32 ' + IntToStr(ErrorCode) + ').');
        Exit;
      end;
      if Available = 0 then Break;
      ToRead := Available;
      if ToRead > SizeOf(Buffer) then ToRead := SizeOf(Buffer);
      if ToRead > Budget then ToRead := Budget;
      // Single UI reader: read only the bytes PeekNamedPipe already found.
      if not ReadFile(FReadPipe, Buffer, ToRead, ReadCount, nil) then
      begin
        Fail('Falha ao ler saida do processo.');
        Exit;
      end;
      if ReadCount = 0 then Break;
      Dec(Budget, ReadCount);
      Consume(Buffer, ReadCount);
      if FProcess = 0 then Exit;
    end;
    WaitResult := WaitForSingleObject(FProcess, 0);
    if WaitResult = WAIT_FAILED then
    begin
      Fail('Falha ao consultar o estado do processo.');
      Exit;
    end;
    if WaitResult = WAIT_OBJECT_0 then
    begin
      // Drain remaining bounded output in later ticks, without blocking UI.
      if Budget = 0 then Exit;
      if (Length(FPending) > 0) or FDroppingLine then FinishLine;
      if FProcess = 0 then Exit;
      if not GetExitCodeProcess(FProcess, ExitCode) then
      begin
        Fail('Nao foi possivel consultar o resultado do processo.');
        Exit;
      end;
      WasInstalling := FState = hsInstalling;
      if WasInstalling and (ExitCode = 0) then
      begin
        Stop;
        Log('Instalacao concluida. Inicie o Harness explicitamente.');
      end
      else Fail('Processo encerrado (codigo ' + IntToStr(ExitCode) + ').');
      Exit;
    end;

  finally
    FPolling := False;
  end;
end;

end.
