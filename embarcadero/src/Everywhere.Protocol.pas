unit Everywhere.Protocol;

interface

// Pure protocol helpers: no process, filesystem or environment access.
function IsSafeProfile(const Value: string): Boolean;
function IsSafeCmdArgument(const Value: string): Boolean;
function QuoteWindowsArgument(const Value: string): string;
function QuoteCmdArgument(const Value: string): string;
function TryExtractHarnessUrl(const Line: string; out Url: string): Boolean;
function RedactLog(const Value: string): string;

implementation

uses
  System.SysUtils, System.StrUtils;

function IsSafeProfile(const Value: string): Boolean;
var
  C: Char;
begin
  Result := (Length(Value) > 0) and (Length(Value) <= 64);
  if not Result then Exit;
  for C in Value do
    if not CharInSet(C, ['a'..'z', 'A'..'Z', '0'..'9', '_', '-']) then
      Exit(False);
  Result := CharInSet(Value[1], ['a'..'z', 'A'..'Z', '0'..'9']);
end;

function IsSafeCmdArgument(const Value: string): Boolean;
var
  C: Char;
begin
  // Even quoted cmd arguments expand % and !. Never try to escape them.
  Result := False;
  for C in Value do
    if (Ord(C) < 32) or (Ord(C) = 127) or
      CharInSet(C, ['"', '%', '!', '^', '&', '|', '<', '>']) then Exit;
  Result := True;
end;

function QuoteCmdArgument(const Value: string): string;
begin
  if not IsSafeCmdArgument(Value) then
    raise EArgumentException.Create('Argumento inseguro para cmd.exe.');
  Result := '"' + Value + '"';
end;

function QuoteWindowsArgument(const Value: string): string;
var
  C: Char;
  Slashes: Integer;
begin
  // Inverse of Windows CRT argv quoting, including trailing backslashes.
  Result := '"';
  Slashes := 0;
  for C in Value do
    if C = '\' then
      Inc(Slashes)
    else
    begin
      if C = '"' then
        Result := Result + StringOfChar('\', Slashes * 2 + 1) + C
      else
        Result := Result + StringOfChar('\', Slashes) + C;
      Slashes := 0;
    end;
  Result := Result + StringOfChar('\', Slashes * 2) + '"';
end;

function TryExtractHarnessUrl(const Line: string; out Url: string): Boolean;
const
  Host = 'http://127.0.0.1:';
var
  S, PortText, Query, Suffix, Lan: string;
  I, Port: Integer;
  C: Char;
begin
  Result := False;
  Url := '';
  // Match an anchored announcement, not a URL inside arbitrary output.
  if StartsStr('ewh web: ', Line) or StartsStr('dsh web: ', Line) then
    S := Copy(Line, 10, MaxInt)
  else Exit;
  if (Length(S) > 4096) or not StartsStr(Host, S) then Exit;
  I := Pos(' ', S);
  if I > 0 then
  begin
    // CLI may append its LAN announcement. Never return or navigate that URL.
    // No arbitrary trailing text, nested parentheses or control characters.
    Suffix := Copy(S, I, MaxInt);
    if not StartsStr(' (LAN: ', Suffix) or not EndsStr(')', Suffix) then Exit;
    Lan := Copy(Suffix, 8, Length(Suffix) - 8);
    if not StartsStr('http://', Lan) and not StartsStr('https://', Lan) then Exit;
    for C in Lan do
      if (Ord(C) <= 32) or (Ord(C) >= 127) or
        CharInSet(C, ['(', ')', '"', '''', '<', '>', '\']) then Exit;
    S := Copy(S, 1, I - 1);
  end;
  I := Length(Host) + 1;
  while (I <= Length(S)) and CharInSet(S[I], ['0'..'9']) do Inc(I);
  PortText := Copy(S, Length(Host) + 1, I - Length(Host) - 1);
  if (Length(PortText) > 5) or not TryStrToInt(PortText, Port) or
    (Port < 1) or (Port > 65535) then Exit;
  if (I > Length(S)) or (S[I] <> '/') then Exit;
  Inc(I);
  if I <= Length(S) then
  begin
    if S[I] <> '?' then Exit;
    Query := Copy(S, I + 1, MaxInt);
    if not StartsStr('token=', Query) then Exit;
    Delete(Query, 1, 6);
    if Query = '' then Exit;
    // Opaque base64/base64url/hex token only. Reject redirects, fragments,
    // encoded controls, additional query parameters and alternate paths.
    for C in Query do
      if not CharInSet(C, ['a'..'z', 'A'..'Z', '0'..'9', '-', '_', '.', '~', '=', '+', '/']) then Exit;
  end;
  Url := S;
  Result := True;
end;

function RedactLog(const Value: string): string;
var
  S, Lower: string;
  I, J: Integer;
  C: Char;
begin
  S := '';
  I := 1;
  // Strip ANSI CSI/OSC sequences before matching secret markers.
  while I <= Length(Value) do
  begin
    C := Value[I];
    if C = #27 then
    begin
      Inc(I);
      if (I <= Length(Value)) and (Value[I] = '[') then
      begin
        Inc(I);
        while (I <= Length(Value)) and not CharInSet(Value[I], ['@'..'~']) do Inc(I);
      end
      else if (I <= Length(Value)) and (Value[I] = ']') then
      begin
        Inc(I);
        while (I <= Length(Value)) and (Value[I] <> #7) do
        begin
          if (Value[I] = #27) and (I < Length(Value)) and (Value[I + 1] = '\') then
          begin
            Inc(I);
            Break;
          end;
          Inc(I);
        end;
      end;
    end
    else if (Ord(C) >= 32) and (Ord(C) <> 127) then S := S + C;
    Inc(I);
  end;
  Lower := LowerCase(S);
  // Conservative: redact whole lines carrying credential labels. Avoid
  // leaking partially quoted/JSON values, Authorization or npm debug output.
  if (Pos('token', Lower) > 0) or (Pos('secret', Lower) > 0) or
    (Pos('password', Lower) > 0) or (Pos('passwd', Lower) > 0) or
    (Pos('key', Lower) > 0) or (Pos('apikey', Lower) > 0) or
    (Pos('api-key', Lower) > 0) or (Pos('authorization', Lower) > 0) or
    (Pos('bearer ', Lower) > 0) or (Pos('credential', Lower) > 0) then
    Exit('[conteudo sensivel omitido]');
  // Strip URL query/fragment from any host, not only accepted announcements.
  I := 1;
  while I <= Length(S) do
  begin
    if SameText(Copy(S, I, 7), 'http://') or SameText(Copy(S, I, 8), 'https://') then
    begin
      J := I;
      while (J <= Length(S)) and not CharInSet(S[J], [' ', '"', '''', '<', '>']) do Inc(J);
      // Userinfo and all URL suffixes may contain secrets; keep scheme/host
      // out of logs entirely rather than trusting a malformed authority.
      Delete(S, I, J - I);
      Insert('[URL omitida]', S, I);
      Inc(I, Length('[URL omitida]'));
    end
    else Inc(I);
  end;
  Result := Copy(S, 1, 2048);
end;

end.
