unit Everywhere.Settings;

interface

uses
  System.SysUtils;

type
  THarnessSettings = record
    Executable: string;
    Profile: string;
    Port: Integer;
    AutoStart: Boolean;
    class function Load: THarnessSettings; static;
    procedure Save;
    procedure Validate;
  end;

function SettingsDirectory: string;
function EditSettings(var Settings: THarnessSettings): Boolean;

implementation

uses
  System.Classes, System.IniFiles, System.IOUtils,
  Vcl.Forms, Vcl.Controls, Vcl.StdCtrls, Everywhere.Protocol;

function SettingsDirectory: string;
begin
  Result := GetEnvironmentVariable('LOCALAPPDATA');
  if Result = '' then
    raise Exception.Create('LOCALAPPDATA indisponivel.');
  Result := TPath.Combine(Result, 'Everywhere\RADStudio');
  if not ForceDirectories(Result) then
    raise Exception.Create('Nao foi possivel criar a pasta de configuracao.');
end;

class function THarnessSettings.Load: THarnessSettings;
var
  Ini: TMemIniFile;
begin
  Ini := TMemIniFile.Create(TPath.Combine(SettingsDirectory, 'settings.ini'), TEncoding.UTF8);
  try
    Result.Executable := Ini.ReadString('runtime', 'executable', '');
    Result.Profile := Ini.ReadString('runtime', 'profile', 'web');
    Result.Port := Ini.ReadInteger('runtime', 'port', 0);
    Result.AutoStart := Ini.ReadBool('runtime', 'autoStart', False);
    // Validate on save/start, so a moved executable never locks users out of settings.
  finally
    Ini.Free;
  end;
end;

procedure THarnessSettings.Validate;
begin
  if (Port < 0) or (Port > 65535) then
    raise EArgumentException.Create('Porta deve estar entre 0 e 65535.');
  if not IsSafeProfile(Profile) then
    raise EArgumentException.Create('Perfil: 1 a 64 letras ASCII, numeros, _ ou -; inicie com letra ou numero.');
  if (Executable <> '') and not FileExists(Executable) then
    raise EArgumentException.Create('O executavel personalizado nao existe.');
end;

procedure THarnessSettings.Save;
var
  Ini: TMemIniFile;
begin
  Validate;
  Ini := TMemIniFile.Create(TPath.Combine(SettingsDirectory, 'settings.ini'), TEncoding.UTF8);
  try
    Ini.WriteString('runtime', 'executable', Executable);
    Ini.WriteString('runtime', 'profile', Profile);
    Ini.WriteInteger('runtime', 'port', Port);
    Ini.WriteBool('runtime', 'autoStart', AutoStart);
    Ini.UpdateFile;
  finally
    Ini.Free;
  end;
end;

function EditSettings(var Settings: THarnessSettings): Boolean;
var
  Dialog: TForm;
  ExecutableEdit, ProfileEdit, PortEdit: TEdit;
  AutoStartCheck: TCheckBox;
  Button: TButton;
  Candidate: THarnessSettings;
  function AddEdit(const Caption, Value: string; Top: Integer): TEdit;
  var
    LabelControl: TLabel;
  begin
    LabelControl := TLabel.Create(Dialog);
    LabelControl.Parent := Dialog;
    LabelControl.SetBounds(16, Top, 580, 20);
    LabelControl.Caption := Caption;
    Result := TEdit.Create(Dialog);
    Result.Parent := Dialog;
    Result.SetBounds(16, Top + 24, 580, 25);
    Result.Text := Value;
  end;
begin
  Dialog := TForm.CreateNew(nil);
  try
    Dialog.Caption := 'EveryWhere - Configuracoes (sem credenciais)';
    Dialog.BorderStyle := bsDialog;
    Dialog.Position := poScreenCenter;
    Dialog.ClientWidth := 612;
    Dialog.ClientHeight := 290;
    ExecutableEdit := AddEdit('Executavel ewh/dsh (vazio: descoberta no PATH/npm)', Settings.Executable, 16);
    ProfileEdit := AddEdit('Perfil (deve oferecer interface web; padrao: web)', Settings.Profile, 80);
    PortEdit := AddEdit('Porta (0: padrao do runtime; nao garante porta aleatoria)', IntToStr(Settings.Port), 144);
    AutoStartCheck := TCheckBox.Create(Dialog);
    AutoStartCheck.Parent := Dialog;
    AutoStartCheck.SetBounds(16, 208, 580, 24);
    AutoStartCheck.Caption := 'Iniciar ao abrir a janela (somente com projeto salvo ativo)';
    AutoStartCheck.Checked := Settings.AutoStart;
    Button := TButton.Create(Dialog);
    Button.Parent := Dialog;
    Button.SetBounds(400, 248, 90, 28);
    Button.Caption := 'Salvar';
    Button.Default := True;
    Button.ModalResult := mrOk;
    Button := TButton.Create(Dialog);
    Button.Parent := Dialog;
    Button.SetBounds(500, 248, 90, 28);
    Button.Caption := 'Cancelar';
    Button.Cancel := True;
    Button.ModalResult := mrCancel;
    Result := Dialog.ShowModal = mrOk;
    if Result then
    begin
      Candidate := Settings;
      Candidate.Executable := Trim(ExecutableEdit.Text);
      Candidate.Profile := Trim(ProfileEdit.Text);
      if not TryStrToInt(Trim(PortEdit.Text), Candidate.Port) then
        raise EArgumentException.Create('Porta deve ser um numero inteiro.');
      Candidate.AutoStart := AutoStartCheck.Checked;
      Candidate.Save;
      Settings := Candidate;
    end;
  finally
    Dialog.Free;
  end;
end;

end.
