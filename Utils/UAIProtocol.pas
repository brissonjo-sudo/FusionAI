unit UAIProtocol;

interface

uses
  System.SysUtils, System.Classes, System.JSON, System.StrUtils, UAICommon;

const
  // OpenAI reasoning models count reasoning in max_completion_tokens; OpenAI advises
  // reserving at least 25,000 tokens. Applied on the official endpoint, only when the
  // shared limit still has its historical default (an explicit choice is kept).
  CReasoningMinOutputTokens = 25000;
  CLegacyDefaultMaxTokens = 2048; // UConsts.DefaultMaxToken, not used here to keep this unit standalone
  // Claude requires max_tokens. This is a ceiling, not a target; with the plugin's HTTP
  // timeout (60 s by default, 120 s max) a very long answer can still time out first.
  CClaudeDefaultMaxTokens = 16000;

function DelphiPrompt(const AText: string): string;
function BuildOpenAIRequest(const ARequest: TProviderRequest; const ASettings: TAIProviderSetting): TJSONObject;
function BuildClaudeRequest(const ARequest: TProviderRequest): TJSONObject;
function ExtractClaudeText(ARoot: TJSONObject): string;
procedure CheckCompletion(const AReason, APartialText: string);
function AsLineComments(const AText, ACaption: string): string;

implementation

function DelphiPrompt(const AText: string): string;
begin
  Result := 'Target compiler: Delphi 10.2 Tokyo (Object Pascal). ' +
    'Keep generated Delphi code compatible with this compiler; do not use inline variable declarations ' +
    'or syntax and RTL APIs introduced after Delphi 10.2. State any uncertain compatibility.' + sLineBreak + sLineBreak + AText;
end;

function BuildOpenAIRequest(const ARequest: TProviderRequest; const ASettings: TAIProviderSetting): TJSONObject;
var
  LMessages: TJSONArray;
  LClassicModel: Boolean;
begin
  Result := TJSONObject.Create;
  try
    LMessages := TJSONArray.Create;
    Result.AddPair('messages', LMessages);
    LMessages.AddElement(TJSONObject.Create.AddPair('role', 'user').AddPair('content', DelphiPrompt(ARequest.QuestionText)));
    Result.AddPair('model', ARequest.ModelId);
    LClassicModel := StartsText('gpt-3.5', ARequest.ModelId) or StartsText('gpt-4', ARequest.ModelId) or
      StartsText('chatgpt-4o', ARequest.ModelId);
    if ARequest.MaxTokens > 0 then
    begin
      if LClassicModel then
        Result.AddPair('max_tokens', TJSONNumber.Create(ARequest.MaxTokens))
      else if (ARequest.MaxTokens = CLegacyDefaultMaxTokens) and
        ((ASettings.BaseURL = '') or ContainsText(ASettings.BaseURL, 'api.openai.com')) and
        not ContainsText(ARequest.ModelId, '-chat') then
        // The untouched default would be spent on reasoning before any visible text.
        // '-chat' models are not reasoning models and have a lower output limit.
        // Custom OpenAI-compatible servers may reject a cap above their model limit.
        Result.AddPair('max_completion_tokens', TJSONNumber.Create(CReasoningMinOutputTokens))
      else
        Result.AddPair('max_completion_tokens', TJSONNumber.Create(ARequest.MaxTokens));
    end;
    // Reasoning models default to reasoning on. Omit sampling parameters for them,
    // including unrecognised future model IDs, rather than guessing by generation.
    if LClassicModel then
    begin
      if ARequest.Temperature >= 0 then
        Result.AddPair('temperature', TJSONNumber.Create(ARequest.Temperature));
      if ASettings.TopP > 0 then
        Result.AddPair('top_p', TJSONNumber.Create(ASettings.TopP));
    end;
  except
    Result.Free;
    raise;
  end;
end;

function BuildClaudeRequest(const ARequest: TProviderRequest): TJSONObject;
var
  LMessages: TJSONArray;
  LMaxTokens: Integer;
begin
  Result := TJSONObject.Create;
  try
    LMessages := TJSONArray.Create;
    Result.AddPair('messages', LMessages);
    LMessages.AddElement(TJSONObject.Create.AddPair('role', 'user').AddPair('content', DelphiPrompt(ARequest.QuestionText)));
    Result.AddPair('model', ARequest.ModelId);
    LMaxTokens := ARequest.MaxTokens;
    if LMaxTokens <= 0 then
      LMaxTokens := CClaudeDefaultMaxTokens // no Claude-specific limit configured
    else if LMaxTokens < 128 then
      LMaxTokens := 128;
    Result.AddPair('max_tokens', TJSONNumber.Create(LMaxTokens));
    // Sampling fields are deliberately absent: current Claude models reject them.
  except
    Result.Free;
    raise;
  end;
end;

function ExtractClaudeText(ARoot: TJSONObject): string;
var
  LContent: TJSONValue;
  LBlock: TJSONValue;
  LObject: TJSONObject;
  I: Integer;
begin
  Result := '';
  if not Assigned(ARoot) then
    Exit;
  LContent := ARoot.Values['content'];
  if not (LContent is TJSONArray) then
    Exit;
  for I := 0 to TJSONArray(LContent).Count - 1 do
  begin
    LBlock := TJSONArray(LContent).Items[I];
    if LBlock is TJSONObject then
    begin
      LObject := TJSONObject(LBlock);
      if LObject.GetValue<string>('type', '') = 'text' then
        Result := Result + LObject.GetValue<string>('text', '');
    end;
  end;
  Result := Trim(Result);
end;

procedure CheckCompletion(const AReason, APartialText: string);
begin
  if SameText(AReason, 'length') or SameText(AReason, 'max_tokens') or
     SameText(AReason, 'model_context_window_exceeded') then
    raise Exception.Create('Incomplete response: output or context limit reached. Review the partial text ' +
      'and increase the token limit if appropriate.' + sLineBreak + APartialText);
  if SameText(AReason, 'refusal') or SameText(AReason, 'content_filter') or SameText(AReason, 'SAFETY') or
     SameText(AReason, 'RECITATION') or SameText(AReason, 'BLOCKLIST') or SameText(AReason, 'PROHIBITED_CONTENT') then
    raise Exception.Create('The provider did not return an unrestricted text response (' + AReason + ').');
end;

function AsLineComments(const AText, ACaption: string): string;
var
  LLines: TStringList;
  I: Integer;
begin
  Result := sLineBreak + '// FusionAI: ' + ACaption + sLineBreak;
  LLines := TStringList.Create;
  try
    LLines.Text := AText;
    for I := 0 to LLines.Count - 1 do
      Result := Result + '// ' + LLines[I] + sLineBreak;
  finally
    LLines.Free;
  end;
end;

end.
