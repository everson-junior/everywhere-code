program ProtocolTests;

{$APPTYPE CONSOLE}
{$ASSERTIONS ON}

uses
  System.SysUtils,
  Everywhere.Protocol in '..\src\Everywhere.Protocol.pas';

procedure TestProfiles;
begin
  Assert(IsSafeProfile('web'));
  Assert(IsSafeProfile('team-1_dev'));
  Assert(not IsSafeProfile(''));
  Assert(not IsSafeProfile('-web'));
  Assert(not IsSafeProfile('web --port 1234'));
  Assert(not IsSafeProfile('web&calc'));
  Assert(not IsSafeProfile('%PATH%'));
  Assert(not IsSafeProfile('web' + #10));
  Assert(not IsSafeProfile(StringOfChar('a', 65)));
end;

procedure AcceptUrl(const Line, Expected: string);
var
  Url: string;
begin
  Assert(TryExtractHarnessUrl(Line, Url), 'Expected a valid announcement');
  Assert(Url = Expected, 'URL must remain byte-for-byte unchanged in memory');
end;

procedure RejectUrl(const Line: string);
var
  Url: string;
begin
  Url := 'previous-value';
  Assert(not TryExtractHarnessUrl(Line, Url), 'Expected rejection');
  Assert(Url = '', 'Never retain a previous URL on rejection');
end;

procedure TestUrls;
begin
  AcceptUrl('ewh web: http://127.0.0.1:3210/?token=abc_123-Z',
    'http://127.0.0.1:3210/?token=abc_123-Z');
  AcceptUrl('dsh web: http://127.0.0.1:65535/', 'http://127.0.0.1:65535/');
  AcceptUrl('ewh web: http://127.0.0.1:1/?token=a+b/==',
    'http://127.0.0.1:1/?token=a+b/==');
  AcceptUrl('ewh web: http://127.0.0.1:4567/?token=local (LAN: http://192.168.1.5:4567/?token=lan)',
    'http://127.0.0.1:4567/?token=local');
  AcceptUrl('dsh web: http://127.0.0.1:4567/ (LAN: http://192.168.1.5:4567/)',
    'http://127.0.0.1:4567/');
  RejectUrl('ewh web: http://127.0.0.1:4567/ (LAN: http://192.168.1.5:4567/) extra');
  RejectUrl('ewh web: http://127.0.0.1:4567/ (LAN: javascript:evil)');
  RejectUrl('ewh web: http://127.0.0.1:4567/ (LAN: http://192.168.1.5:4567/ extra)');
  RejectUrl('ewh web: http://127.0.0.1:4567/ (LAN: http://192.168.1.5:4567/' + #10 + ')');
  RejectUrl('http://127.0.0.1:3000/?token=abc');
  RejectUrl('prefix ewh web: http://127.0.0.1:3000/');
  RejectUrl('ewh web: http://localhost:3000/');
  RejectUrl('ewh web: http://[::1]:3000/');
  RejectUrl('ewh web: https://127.0.0.1:3000/');
  RejectUrl('ewh web: http://127.0.0.1.evil:3000/');
  RejectUrl('ewh web: http://127.0.0.1@evil:3000/');
  RejectUrl('ewh web: http://evil@127.0.0.1:3000/');
  RejectUrl('ewh web: http://127.0.0.1:0/');
  RejectUrl('ewh web: http://127.0.0.1:65536/');
  RejectUrl('ewh web: http://127.0.0.1:-1/');
  RejectUrl('ewh web: http://127.0.0.1:+80/');
  RejectUrl('ewh web: http://127.0.0.1:123456789012345/');
  RejectUrl('ewh web: http://127.0.0.1:/');
  RejectUrl('ewh web: http://127.0.0.1:3000');
  RejectUrl('ewh web: http://127.0.0.1:3000/admin');
  RejectUrl('ewh web: http://127.0.0.1:3000/?');
  RejectUrl('ewh web: http://127.0.0.1:3000/?abc');
  RejectUrl('ewh web: http://127.0.0.1:3000/?token=');
  RejectUrl('ewh web: http://127.0.0.1:3000/?token=abc&redirect=evil');
  RejectUrl('ewh web: http://127.0.0.1:3000/?token=abc#fragment');
  RejectUrl('ewh web: http://127.0.0.1:3000/?token=%0D%0A');
  RejectUrl('ewh web: http://127.0.0.1:3000/\evil');
  RejectUrl('ewh web: http://127.0.0.1:3000/ extra');
  RejectUrl('ewh web: http://127.0.0.1:3000/' + #13#10);
  RejectUrl('ewh web: http://127.0.0.1:3000/?token=ab' + #0 + 'cd');
  RejectUrl('ewh web: http://127.0.0.1:3000/?token=' + StringOfChar('a', 4096));
end;

procedure TestQuoting;
var
  C: Char;
  Raised: Boolean;
begin
  Assert(QuoteWindowsArgument('') = '""');
  Assert(QuoteWindowsArgument('hello world') = '"hello world"');
  Assert(QuoteWindowsArgument('C:\folder\') = '"C:\folder\\"');
  Assert(QuoteWindowsArgument('a"b') = '"a\"b"');
  Assert(QuoteWindowsArgument('a\"b') = '"a\\\"b"');
  Assert(QuoteCmdArgument('C:\Program Files (x86)\npm\ewh.cmd') =
    '"C:\Program Files (x86)\npm\ewh.cmd"');
  Assert(QuoteCmdArgument('') = '""');
  for C in '%!^&|<>"' do
  begin
    Assert(not IsSafeCmdArgument('before' + C + 'after'));
    Raised := False;
    try
      QuoteCmdArgument('before' + C + 'after');
    except
      on E: EArgumentException do Raised := True;
    end;
    Assert(Raised, 'Unsafe shell metacharacter must be rejected, not escaped');
  end;
  Assert(not IsSafeCmdArgument('a' + #0));
  Assert(not IsSafeCmdArgument('a' + #10));
  Assert(not IsSafeCmdArgument('a' + #13));
  Assert(not IsSafeCmdArgument('a' + #9));
end;

procedure TestRedaction;
var
  S: string;
begin
  Assert(RedactLog('ordinary startup message') = 'ordinary startup message');
  Assert(Pos('private-value', RedactLog('API_KEY=private-value')) = 0);
  Assert(Pos('private-value', RedactLog('Authorization: Bearer private-value')) = 0);
  Assert(Pos('private-value', RedactLog('{"password": "private-value"}')) = 0);
  Assert(Pos('private-value', RedactLog('token: private-value')) = 0);
  Assert(Pos('private-value', RedactLog('client_secret=private-value')) = 0);
  Assert(Pos('private-value', RedactLog('key=private-value')) = 0);
  Assert(Pos('private-value', RedactLog('ewh web: http://127.0.0.1:1234/?token=private-value')) = 0);
  Assert(Pos('private-value', RedactLog('http://evil.example/?private-value')) = 0);
  Assert(Pos('private-value', RedactLog('https://private-value@evil.example/path')) = 0);
  Assert(Pos('private-value', RedactLog('http://localhost:1234/#private-value')) = 0);
  Assert(RedactLog(#27 + '[31mhello' + #27 + '[0m') = 'hello');
  Assert(Pos('private-value', RedactLog('to' + #27 + '[31mken=private-value')) = 0);
  Assert(RedactLog('a' + #0#10#13 + 'b') = 'ab');
  Assert(RedactLog(#27 + ']0;window-secret' + #7 + 'hello') = 'hello');
  S := RedactLog(StringOfChar('x', 5000));
  Assert(Length(S) <= 2048);
end;

begin
  try
    TestProfiles;
    TestUrls;
    TestQuoting;
    TestRedaction;
    Writeln('ProtocolTests: todos os testes passaram.');
  except
    on E: Exception do
    begin
      Writeln(E.ClassName + ': ' + E.Message);
      ExitCode := 1;
    end;
  end;
end.
