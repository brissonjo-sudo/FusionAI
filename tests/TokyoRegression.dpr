program TokyoRegression;

{$APPTYPE CONSOLE}
{$ASSERTIONS ON}
{$BOOLEVAL OFF}
{$RANGECHECKS ON}

uses
  System.SysUtils, System.Classes, System.JSON,
  UAICommon in '..\Utils\UAICommon.pas',
  UAIProtocol in '..\Utils\UAIProtocol.pas',
  UAIText in '..\Utils\UAIText.pas',
  UAISecrets in '..\Utils\UAISecrets.pas';

procedure Check(ACondition: Boolean; const AMessage: string);
begin
  if not ACondition then raise Exception.Create(AMessage);
end;

procedure TestRequests;
var
  LRequest: TProviderRequest;
  LSettings: TAIProviderSetting;
  LJSON: TJSONObject;
  LClone: TAIProviderSetting;
begin
  LRequest := TProviderRequest.Create;
  LSettings := TAIProviderSetting.Create;
  try
    LRequest.QuestionText := 'Explain this code.';
    LRequest.MaxTokens := 2048;
    LRequest.Temperature := 0;
    LSettings.TopP := 1;
    LRequest.ModelId := 'gpt-4o-mini';
    LJSON := BuildOpenAIRequest(LRequest, LSettings);
    try
      Check(Assigned(LJSON.Values['max_tokens']), 'Classic OpenAI token field missing');
      Check(Assigned(LJSON.Values['temperature']), 'Classic temperature missing');
      Check(Pos('Delphi 10.2', LJSON.ToJSON) > 0, 'Compiler constraint missing');
    finally LJSON.Free end;
    LRequest.ModelId := 'o3';
    LJSON := BuildOpenAIRequest(LRequest, LSettings);
    try
      Check(Assigned(LJSON.Values['max_completion_tokens']), 'Reasoning token field missing');
      Check(not Assigned(LJSON.Values['temperature']), 'Reasoning sampling must be omitted');
      Check(not Assigned(LJSON.Values['top_p']), 'Reasoning top_p must be omitted');
      Check(not Assigned(LJSON.Values['max_tokens']), 'Legacy token field must be omitted');
    finally LJSON.Free end;
    LJSON := BuildClaudeRequest(LRequest);
    try
      Check(not Assigned(LJSON.Values['temperature']), 'Claude temperature must be omitted');
      Check(not Assigned(LJSON.Values['top_p']), 'Claude top_p must be omitted');
    finally LJSON.Free end;
    LSettings.ProxySetting.Active := True;
    LSettings.ProxySetting.ProxyHost := 'proxy.test';
    LSettings.TimeoutSeconds := 60;
    LClone := LSettings.Clone;
    try
      LSettings.ProxySetting.ProxyHost := 'changed.test';
      Check(LClone.ProxySetting.ProxyHost = 'proxy.test', 'Proxy clone must be independent');
      Check(LClone.TimeoutSeconds = 60, 'Timeout lost during clone');
    finally LClone.Free end;
    Check(not LRequest.IsCancelled, 'New request already cancelled');
    LRequest.Cancel;
    Check(LRequest.IsCancelled, 'Cancellation flag missing');
  finally
    LRequest.Free;
    LSettings.Free;
  end;
end;

procedure TestResponses;
var
  LJSON: TJSONObject;
  LRaised: Boolean;
begin
  LJSON := TJSONObject.ParseJSONValue('{"content":[{"type":"thinking","thinking":"hidden"},' +
    '{"type":"text","text":"first "},{"type":"text","text":"second"}]}') as TJSONObject;
  try
    Check(ExtractClaudeText(LJSON) = 'first second', 'Claude text blocks were lost');
  finally LJSON.Free end;
  LRaised := False;
  try CheckCompletion('MAX_TOKENS', 'partial');
  except on E: Exception do LRaised := Pos('partial', E.Message) > 0 end;
  Check(LRaised, 'Truncation must not be reported as success');
  CheckCompletion('stop', 'complete');
end;

procedure TestPascalText;
var
  LSource, LMasked: string;
  LLines: TStringList;
  I: Integer;
begin
  LSource := 'begin WriteLn(''end; don''''t try''); // case' + sLineBreak +
    'Somebegin := 1; { try } (* end *) end;';
  LMasked := MaskPascalText(LSource);
  Check(Length(LMasked) = Length(LSource), 'Mask changed source positions');
  Check(CountPascalKeyword(LMasked, 'begin') = 1, 'Identifier confused with begin');
  Check(CountPascalKeyword(LMasked, 'end') = 1, 'Comment/string confused with end');
  Check(CountPascalKeyword(LMasked, 'try') = 0, 'String/comment confused with try');
  LLines := TStringList.Create;
  try
    LLines.Text := AsLineComments('} dangerous(); {$IFDEF X}' + sLineBreak + '(* text *)', 'Test');
    for I := 0 to LLines.Count - 1 do
      if Trim(LLines[I]) <> '' then
        Check(Copy(LLines[I], 1, 2) = '//', 'Generated text escaped its line comment');
  finally LLines.Free end;
end;

procedure TestSecrets;
var
  LProtected, LSecret: string;
begin
  LSecret := 'test-only-secret-' + WideChar($00E9);
  LProtected := ProtectSecret(LSecret);
  Check(LProtected <> LSecret, 'Secret stored as plaintext');
  Check(UnprotectSecret(LProtected) = LSecret, 'DPAPI round trip failed');
  Check(UnprotectSecret('legacy-test') = 'legacy-test', 'Legacy migration input broken');
  Check(ProtectSecret('') = '', 'Empty secret should remain empty');
end;

begin
  try
    TestRequests;
    TestResponses;
    TestPascalText;
    TestSecrets;
    Writeln('PASS: requests, responses, Pascal masking, comments and Windows DPAPI');
  except
    on E: Exception do
    begin
      Writeln('FAIL: ', E.ClassName, ': ', E.Message);
      ExitCode := 1;
    end;
  end;
end.
