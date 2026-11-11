unit Everywhere.Register;

interface

procedure Register;

implementation

uses
  System.SysUtils, ToolsAPI, Everywhere.Window;

type
  TEverywhereWizard = class(TNotifierObject, IOTAWizard, IOTAMenuWizard)
  public
    function GetIDString: string;
    function GetName: string;
    function GetState: TWizardState;
    function GetMenuText: string;
    procedure Execute;
  end;

function ActiveWorkspace: string;
var
  Project: IOTAProject;
begin
  Result := '';
  Project := GetActiveProject;
  // Never silently run an agent in the IDE installation or an unrelated cwd.
  if (Project <> nil) and (Project.FileName <> '') and FileExists(Project.FileName) then
    Result := ExtractFilePath(ExpandFileName(Project.FileName));
end;

function TEverywhereWizard.GetIDString: string;
begin
  Result := 'com.everywhere.harness.radstudio';
end;

function TEverywhereWizard.GetName: string;
begin
  Result := 'EveryWhere Harness';
end;

function TEverywhereWizard.GetState: TWizardState;
begin
  Result := [wsEnabled];
end;

function TEverywhereWizard.GetMenuText: string;
begin
  Result := 'EveryWhere Harness';
end;

procedure TEverywhereWizard.Execute;
begin
  ShowHarnessWindow(@ActiveWorkspace);
end;

procedure Register;
begin
  RegisterPackageWizard(TEverywhereWizard.Create);
end;

end.
