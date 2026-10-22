unit UAIProviders;

interface

uses
  System.Classes,
  System.SysUtils,
  System.JSON,
  System.Generics.Collections,
  System.Net.HttpClient,
  System.Net.URLClient,
  System.IOUtils,
  System.DateUtils,
  System.Math,
  System.StrUtils,
  UAICommon,
  UConsts;

type
  IAIProvider = interface
    ['{79CA6A92-6DC0-4686-9ACF-B31D3AE0EE6D}']
    function GetId: string;
    function GetDisplayName: string;
    function GetCapabilities: TAIProviderCapabilities;
    function GetDefaultBaseURL: string;
    function GetDefaultModel: string;
    function ValidateSettings(const ASettings: TAIProviderSetting; out AError: string): Boolean;
    function Execute(const ARequest: TProviderRequest; const ASettings: TAIProviderSetting): TProviderResponse;
    function ListModels(const ASettings: TAIProviderSetting; out AModels: TModelDescriptorList; out AError: string): Boolean;
  end;

  IAIProviderRegistry = interface
    ['{F72C6413-BEB9-4554-B69A-8C2FDFDB4A15}']
    function GetProvider(const AProviderId: string): IAIProvider;
    function GetProviders: TArray<IAIProvider>;
    function GetOrderedProviderIds: TArray<string>;
  end;

  IModelCatalogService = interface
    ['{FB3633E5-2786-4953-9A6D-5181E0872A1A}']
    function GetCachedModels(const AProviderId: string): TModelDescriptorList;
    function RefreshModels(const AProvider: IAIProvider; const ASettings: TAIProviderSetting; out AError: string): TModelDescriptorList;
    function GetCacheFilePath: string;
  end;

  TAIProviderRegistry = class(TInterfacedObject, IAIProviderRegistry)
  private
    FProviders: TDictionary<string, IAIProvider>;
    class var FInstance: IAIProviderRegistry;
  public
    constructor Create;
    destructor Destroy; override;

    class function Instance: IAIProviderRegistry; static;

    function GetProvider(const AProviderId: string): IAIProvider;
    function GetProviders: TArray<IAIProvider>;
    function GetOrderedProviderIds: TArray<string>;
  end;

  TModelCatalogService = class(TInterfacedObject, IModelCatalogService)
  private
    class var FInstance: IModelCatalogService;
    function LoadCache: TJSONObject;
    procedure SaveCache(ARoot: TJSONObject);
    function GetProviderObject(ARoot: TJSONObject; const AProviderId: string; ACreate: Boolean): TJSONObject;
  public
    class function Instance: IModelCatalogService; static;

    function GetCachedModels(const AProviderId: string): TModelDescriptorList;
    function RefreshModels(const AProvider: IAIProvider; const ASettings: TAIProviderSetting; out AError: string): TModelDescriptorList;
    function GetCacheFilePath: string;
  end;

implementation

uses
  UEditorHelpers, UAIProtocol, Winapi.Windows;

function CacheString(AObject: TJSONObject; const AName: string): string;
begin
  Result := '';
  if Assigned(AObject) and (AObject.Values[AName] is TJSONString) then
    Result := AObject.Values[AName].Value;
end;

type
  TBaseAIProvider = class(TInterfacedObject, IAIProvider)
  protected
    function CreateClient(const ARequest: TProviderRequest): THTTPClient;
    function ExecuteGet(const AURL: string; const AHeaders: TNetHeaders; const ARequest: TProviderRequest): string;
    function ExecutePost(const AURL, ABody: string; const AHeaders: TNetHeaders; const ARequest: TProviderRequest): string;
    function NormalizeBaseURL(const AValue, ADefault: string): string;
    function JsonString(AObject: TJSONObject; const AName: string): string;
    function JsonArray(AObject: TJSONObject; const AName: string): TJSONArray;
    function JsonObject(AObject: TJSONObject; const AName: string): TJSONObject;
    function JsonValueText(AValue: TJSONValue): string;
    function ExtractErrorText(AValue: TJSONValue): string;
    procedure CheckHTTPResponse(const AResponse: IHTTPResponse; const ABody: string);
    procedure LogProviderTrace(const ARequest: TProviderRequest; const AMessage: string);
  public
    function GetId: string; virtual; abstract;
    function GetDisplayName: string; virtual; abstract;
    function GetCapabilities: TAIProviderCapabilities; virtual; abstract;
    function GetDefaultBaseURL: string; virtual; abstract;
    function GetDefaultModel: string; virtual; abstract;
    function ValidateSettings(const ASettings: TAIProviderSetting; out AError: string): Boolean; virtual;
    function Execute(const ARequest: TProviderRequest; const ASettings: TAIProviderSetting): TProviderResponse; virtual; abstract;
    function ListModels(const ASettings: TAIProviderSetting; out AModels: TModelDescriptorList; out AError: string): Boolean; virtual; abstract;
  end;

  TChatGPTProvider = class(TBaseAIProvider)
  private
    function NormalizeRootURL(const AValue: string): string;
  public
    function GetId: string; override;
    function GetDisplayName: string; override;
    function GetCapabilities: TAIProviderCapabilities; override;
    function GetDefaultBaseURL: string; override;
    function GetDefaultModel: string; override;
    function Execute(const ARequest: TProviderRequest; const ASettings: TAIProviderSetting): TProviderResponse; override;
    function ListModels(const ASettings: TAIProviderSetting; out AModels: TModelDescriptorList; out AError: string): Boolean; override;
  end;

  TGeminiProvider = class(TBaseAIProvider)
  private
    function NormalizeModelId(const AModelId: string): string;
  public
    function GetId: string; override;
    function GetDisplayName: string; override;
    function GetCapabilities: TAIProviderCapabilities; override;
    function GetDefaultBaseURL: string; override;
    function GetDefaultModel: string; override;
    function Execute(const ARequest: TProviderRequest; const ASettings: TAIProviderSetting): TProviderResponse; override;
    function ListModels(const ASettings: TAIProviderSetting; out AModels: TModelDescriptorList; out AError: string): Boolean; override;
  end;

  TClaudeProvider = class(TBaseAIProvider)
  public
    function GetId: string; override;
    function GetDisplayName: string; override;
    function GetCapabilities: TAIProviderCapabilities; override;
    function GetDefaultBaseURL: string; override;
    function GetDefaultModel: string; override;
    function Execute(const ARequest: TProviderRequest; const ASettings: TAIProviderSetting): TProviderResponse; override;
    function ListModels(const ASettings: TAIProviderSetting; out AModels: TModelDescriptorList; out AError: string): Boolean; override;
  end;

  TOllamaProvider = class(TBaseAIProvider)
  private
    function RootURL(const ASettings: TAIProviderSetting): string;
    function AuthHeaders(const ASettings: TAIProviderSetting): TNetHeaders;
  public
    function GetId: string; override;
    function GetDisplayName: string; override;
    function GetCapabilities: TAIProviderCapabilities; override;
    function GetDefaultBaseURL: string; override;
    function GetDefaultModel: string; override;
    function ValidateSettings(const ASettings: TAIProviderSetting; out AError: string): Boolean; override;
    function Execute(const ARequest: TProviderRequest; const ASettings: TAIProviderSetting): TProviderResponse; override;
    function ListModels(const ASettings: TAIProviderSetting; out AModels: TModelDescriptorList; out AError: string): Boolean; override;
  end;

function TBaseAIProvider.CreateClient(const ARequest: TProviderRequest): THTTPClient;
var
  LTimeoutSeconds: Integer;
begin
  if ARequest.IsCancelled then raise EAbort.Create(CProgressCancelled);
  Result := THTTPClient.Create;
  if ARequest.TimeoutSeconds > 0 then
    LTimeoutSeconds := Max(CMinRequestTimeoutSeconds, ARequest.TimeoutSeconds)
  else
    LTimeoutSeconds := CDefaultRequestTimeoutSeconds;

  LTimeoutSeconds := EnsureRange(LTimeoutSeconds, CMinRequestTimeoutSeconds, CMaxRequestTimeoutSeconds);
  Result.OnReceiveData := ARequest.ReceiveData;
  Result.ConnectionTimeout := Min(10, LTimeoutSeconds) * 1000;
  Result.ResponseTimeout := LTimeoutSeconds * 1000;

  if Assigned(ARequest.ProxySetting) and ARequest.ProxySetting.Active and (ARequest.ProxySetting.ProxyHost <> '') then
    Result.ProxySettings := TProxySettings.Create(
      ARequest.ProxySetting.ProxyHost,
      ARequest.ProxySetting.ProxyPort,
      ARequest.ProxySetting.ProxyUsername,
      ARequest.ProxySetting.ProxyPassword
    );
end;

function TBaseAIProvider.ExecuteGet(const AURL: string; const AHeaders: TNetHeaders; const ARequest: TProviderRequest): string;
var
  LClient: THTTPClient;
  LResponse: IHTTPResponse;
  I: Integer;
begin
  LClient := CreateClient(ARequest);
  try
    LogProviderTrace(ARequest, 'GET ' + AURL);
    for I := Low(AHeaders) to High(AHeaders) do
      LClient.CustomHeaders[AHeaders[I].Name] := AHeaders[I].Value;

    try
      LResponse := LClient.Get(AURL);
      Result := LResponse.ContentAsString(TEncoding.UTF8);
      if ARequest.IsCancelled then raise EAbort.Create(CProgressCancelled);
      CheckHTTPResponse(LResponse, Result);
      LogProviderTrace(ARequest, 'RESPONSE ' + IntToStr(LResponse.StatusCode) + sLineBreak + Result);
    except
      on E: Exception do
      begin
        LogProviderTrace(ARequest, 'REQUEST FAILED: ' + E.Message);
        raise;
      end;
    end;
  finally
    LClient.Free;
  end;
end;

function TBaseAIProvider.ExecutePost(const AURL, ABody: string; const AHeaders: TNetHeaders; const ARequest: TProviderRequest): string;
var
  LClient: THTTPClient;
  LResponse: IHTTPResponse;
  LBodyStream: TStringStream;
  I: Integer;
begin
  LClient := CreateClient(ARequest);
  LBodyStream := TStringStream.Create(ABody, TEncoding.UTF8);
  try
    LogProviderTrace(ARequest, 'POST ' + AURL + sLineBreak + ABody);
    for I := Low(AHeaders) to High(AHeaders) do
      LClient.CustomHeaders[AHeaders[I].Name] := AHeaders[I].Value;

    if LClient.CustomHeaders['Content-Type'] = '' then
      LClient.CustomHeaders['Content-Type'] := 'application/json';

    try
      LResponse := LClient.Post(AURL, LBodyStream);
      Result := LResponse.ContentAsString(TEncoding.UTF8);
      if ARequest.IsCancelled then raise EAbort.Create(CProgressCancelled);
      CheckHTTPResponse(LResponse, Result);
      LogProviderTrace(ARequest, 'RESPONSE ' + IntToStr(LResponse.StatusCode) + sLineBreak + Result);
    except
      on E: Exception do
      begin
        LogProviderTrace(ARequest, 'REQUEST FAILED: ' + E.Message);
        raise;
      end;
    end;
  finally
    LBodyStream.Free;
    LClient.Free;
  end;
end;

function TBaseAIProvider.JsonArray(AObject: TJSONObject; const AName: string): TJSONArray;
begin
  Result := nil;
  if Assigned(AObject) and Assigned(AObject.Values[AName]) and (AObject.Values[AName] is TJSONArray) then
    Result := TJSONArray(AObject.Values[AName]);
end;

function TBaseAIProvider.JsonObject(AObject: TJSONObject; const AName: string): TJSONObject;
begin
  Result := nil;
  if Assigned(AObject) and Assigned(AObject.Values[AName]) and (AObject.Values[AName] is TJSONObject) then
    Result := TJSONObject(AObject.Values[AName]);
end;

function TBaseAIProvider.JsonString(AObject: TJSONObject; const AName: string): string;
begin
  Result := '';
  if Assigned(AObject) and Assigned(AObject.Values[AName]) then
    Result := AObject.Values[AName].Value;
end;

function TBaseAIProvider.JsonValueText(AValue: TJSONValue): string;
var
  LArray: TJSONArray;
  LObject: TJSONObject;
  I: Integer;
  LPartText: string;
begin
  Result := '';
  if not Assigned(AValue) then
    Exit;

  if AValue is TJSONString then
    Exit(AValue.Value);

  if AValue is TJSONArray then
  begin
    LArray := TJSONArray(AValue);
    for I := 0 to LArray.Count - 1 do
    begin
      LPartText := JsonValueText(LArray.Items[I]);
      if LPartText <> '' then
      begin
        if Result <> '' then
          Result := Result + sLineBreak;
        Result := Result + LPartText;
      end;
    end;
    Exit(Result);
  end;

  if AValue is TJSONObject then
  begin
    LObject := TJSONObject(AValue);

    Result := JsonString(LObject, 'text');
    if Result <> '' then
      Exit;

    Result := JsonString(LObject, 'output_text');
    if Result <> '' then
      Exit;

    Result := JsonValueText(LObject.Values['content']);
    if Result <> '' then
      Exit;

    Result := JsonValueText(LObject.Values['message']);
    if Result <> '' then
      Exit;

    Result := JsonString(LObject, 'value');
    if Result <> '' then
      Exit;
  end;

  if not (AValue is TJSONNull) then
    Result := AValue.Value;
end;

function TBaseAIProvider.ExtractErrorText(AValue: TJSONValue): string;
var
  LObject: TJSONObject;
  LArray: TJSONArray;
  I: Integer;
begin
  Result := '';
  if not Assigned(AValue) then
    Exit;

  Result := JsonValueText(AValue);
  if Result <> '' then
    Exit;

  if AValue is TJSONObject then
  begin
    LObject := TJSONObject(AValue);
    Result := JsonString(LObject, 'message');
    if Result <> '' then
      Exit;

    Result := JsonString(LObject, 'error');
    if Result <> '' then
      Exit;

    Result := ExtractErrorText(LObject.Values['error']);
    if Result <> '' then
      Exit;

    Result := ExtractErrorText(LObject.Values['details']);
    if Result <> '' then
      Exit;

    Result := ExtractErrorText(LObject.Values['errors']);
    if Result <> '' then
      Exit;
  end;

  if AValue is TJSONArray then
  begin
    LArray := TJSONArray(AValue);
    for I := 0 to LArray.Count - 1 do
    begin
      Result := ExtractErrorText(LArray.Items[I]);
      if Result <> '' then
        Exit;
    end;
  end;
end;

procedure TBaseAIProvider.CheckHTTPResponse(const AResponse: IHTTPResponse; const ABody: string);
var
  LJSON: TJSONValue;
  LError: string;
begin
  if (AResponse.StatusCode >= 200) and (AResponse.StatusCode < 300) then Exit;
  LJSON := TJSONObject.ParseJSONValue(ABody);
  try
    LError := ExtractErrorText(LJSON);
  finally
    LJSON.Free;
  end;
  if LError = '' then LError := 'The endpoint returned no JSON error details.';
  raise Exception.CreateFmt('HTTP %d: %s', [AResponse.StatusCode, LError]);
end;

procedure TBaseAIProvider.LogProviderTrace(const ARequest: TProviderRequest; const AMessage: string);
begin
  if Assigned(ARequest) and ARequest.LogEnabled then
    AppendLogMessage(ARequest.LogDirectory, AMessage);
end;

function TBaseAIProvider.NormalizeBaseURL(const AValue, ADefault: string): string;
begin
  Result := Trim(AValue);
  if Result = '' then
    Result := ADefault;

  while Result.EndsWith('/') do
    Result := Result.Substring(0, Result.Length - 1);
end;

function TBaseAIProvider.ValidateSettings(const ASettings: TAIProviderSetting; out AError: string): Boolean;
begin
  Result := False;
  AError := '';
  if not Assigned(ASettings) then
  begin
    AError := 'Missing provider settings.';
    Exit;
  end;

  if not ASettings.Enabled then
  begin
    AError := 'Provider is disabled.';
    Exit;
  end;

  if Trim(ASettings.ApiKey) = '' then
  begin
    AError := 'Access key is required.';
    Exit;
  end;

  if Trim(ASettings.BaseURL) = '' then
  begin
    AError := 'Base URL is required.';
    Exit;
  end;

  if Trim(ASettings.DefaultModel) = '' then
  begin
    AError := 'Model is required.';
    Exit;
  end;

  Result := True;
end;

function TChatGPTProvider.Execute(const ARequest: TProviderRequest; const ASettings: TAIProviderSetting): TProviderResponse;
var
  LUrl: string;
  LBody: TJSONObject;
  LRoot: TJSONObject;
  LChoices: TJSONArray;
  LChoice: TJSONObject;
  LChoiceMessage: TJSONObject;
  LResponseText: string;
begin
  Result := TProviderResponse.Create;
  Result.RequestId := ARequest.RequestId;
  Result.BatchId := ARequest.BatchId;
  Result.ProviderId := GetId;
  Result.ProviderDisplayName := GetDisplayName;
  Result.ModelId := ARequest.ModelId;
  Result.QuestionText := ARequest.QuestionText;
  Result.QuestionLabel := ARequest.QuestionLabel;
  Result.StartedAt := Now;
  Result.Status := prsRunning;

  LBody := BuildOpenAIRequest(ARequest, ASettings);
  try
    LUrl := NormalizeRootURL(ASettings.BaseURL) + '/chat/completions';
    LRoot := TJSONObject.ParseJSONValue(ExecutePost(
      LUrl,
      LBody.ToJSON,
      [TNameValuePair.Create('Authorization', 'Bearer ' + ASettings.ApiKey)],
      ARequest
    )) as TJSONObject;
    try
      if not Assigned(LRoot) then
        raise Exception.Create('Invalid response from ChatGPT.');

      LChoices := JsonArray(LRoot, 'choices');
      if (not Assigned(LChoices)) or (LChoices.Count = 0) then
      begin
        LResponseText := ExtractErrorText(LRoot.Values['error']);
        if LResponseText = '' then
          LResponseText := ExtractErrorText(LRoot);
        if LResponseText <> '' then
          raise Exception.Create(LResponseText);

        LResponseText := JsonValueText(LRoot.Values['output_text']);
        if LResponseText = '' then
          LResponseText := JsonValueText(LRoot.Values['content']);
        if LResponseText = '' then
          raise Exception.Create('ChatGPT returned no choices.');

        Result.ResponseText := Trim(LResponseText);
      end
      else
      begin
        LChoice := LChoices.Items[0] as TJSONObject;
        LChoiceMessage := JsonObject(LChoice, 'message');
        if Assigned(LChoiceMessage) then
          LResponseText := JsonValueText(LChoiceMessage.Values['content'])
        else
          LResponseText := '';

        if LResponseText = '' then
          LResponseText := JsonValueText(LChoice.Values['text']);
        if LResponseText = '' then
          LResponseText := JsonValueText(LChoice.Values['message']);

        Result.ResponseText := Trim(LResponseText);
      end;

      if Result.ResponseText = '' then
        raise Exception.Create('ChatGPT returned an empty response.');

      if Assigned(LChoices) and (LChoices.Count > 0) then
        CheckCompletion(JsonString(LChoices.Items[0] as TJSONObject, 'finish_reason'), Result.ResponseText);
      Result.Status := prsSucceeded;
      Result.FinishedAt := Now;
      Result.DurationMs := MilliSecondsBetween(Result.FinishedAt, Result.StartedAt);
    finally
      LRoot.Free;
    end;
  except
    on E: Exception do
    begin
      Result.Status := prsFailed;
      Result.ErrorText := E.Message;
      Result.FinishedAt := Now;
      Result.DurationMs := MilliSecondsBetween(Result.FinishedAt, Result.StartedAt);
    end;
  end;
  LBody.Free;
end;

function TChatGPTProvider.GetCapabilities: TAIProviderCapabilities;
begin
  Result := [pcModelListing, pcCustomEndpoint];
end;

function TChatGPTProvider.GetDefaultBaseURL: string;
begin
  Result := DefaultChatGPTBaseURL;
end;

function TChatGPTProvider.GetDefaultModel: string;
begin
  Result := DefaultChatGPTModel;
end;

function TChatGPTProvider.GetDisplayName: string;
begin
  Result := 'ChatGPT';
end;

function TChatGPTProvider.GetId: string;
begin
  Result := ProviderChatGPT;
end;

function TChatGPTProvider.ListModels(const ASettings: TAIProviderSetting; out AModels: TModelDescriptorList; out AError: string): Boolean;
var
  LRoot: TJSONObject;
  LData: TJSONArray;
  I: Integer;
  LModel: TJSONObject;
  LId: string;
  LRequest: TProviderRequest;
  LDescriptor: TModelDescriptor;
begin
  Result := False;
  AError := '';
  AModels := TModelDescriptorList.Create(True);
  LRequest := TProviderRequest.Create;
  try
    LRequest.TimeoutSeconds := Min(20, Max(CMinRequestTimeoutSeconds, ASettings.TimeoutSeconds));
    LRequest.ProxySetting.Assign(ASettings.ProxySetting);
    LRoot := TJSONObject.ParseJSONValue(ExecuteGet(
      NormalizeRootURL(ASettings.BaseURL) + '/models',
      [TNameValuePair.Create('Authorization', 'Bearer ' + ASettings.ApiKey)],
      LRequest
    )) as TJSONObject;
    try
      if not Assigned(LRoot) then
        raise Exception.Create('Unable to read ChatGPT models.');

      LData := JsonArray(LRoot, 'data');
      if Assigned(LData) then
        for I := 0 to LData.Count - 1 do
        begin
          LModel := LData.Items[I] as TJSONObject;
          LId := JsonString(LModel, 'id');
          if (LId <> '') and (LId.StartsWith('gpt') or LId.StartsWith('o') or LId.StartsWith('chatgpt')) then
          begin
            LDescriptor := TModelDescriptor.Create;
            LDescriptor.ProviderId := GetId;
            LDescriptor.ModelId := LId;
            LDescriptor.DisplayName := LId;
            LDescriptor.FetchedAt := Now;
            AModels.Add(LDescriptor);
          end;
        end;

      Result := AModels.Count > 0;
      if not Result then
        AError := 'No ChatGPT models were returned.';
    finally
      LRoot.Free;
    end;
  except
    on E: Exception do
      AError := E.Message;
  end;
  LRequest.Free;

  if not Result then
    FreeAndNil(AModels);
end;

function TChatGPTProvider.NormalizeRootURL(const AValue: string): string;
begin
  Result := NormalizeBaseURL(AValue, GetDefaultBaseURL);
  if Result.EndsWith('/chat/completions') then
    Result := Result.Substring(0, Result.Length - Length('/chat/completions'));
end;

function TGeminiProvider.Execute(const ARequest: TProviderRequest; const ASettings: TAIProviderSetting): TProviderResponse;
var
  LBody: TJSONObject;
  LContents: TJSONArray;
  LContent: TJSONObject;
  LParts: TJSONArray;
  LRoot: TJSONObject;
  LCandidates: TJSONArray;
  LCandidate: TJSONObject;
  LResponseContent: TJSONObject;
  LResponseParts: TJSONArray;
  I: Integer;
begin
  Result := TProviderResponse.Create;
  Result.RequestId := ARequest.RequestId;
  Result.BatchId := ARequest.BatchId;
  Result.ProviderId := GetId;
  Result.ProviderDisplayName := GetDisplayName;
  Result.ModelId := ARequest.ModelId;
  Result.QuestionText := ARequest.QuestionText;
  Result.QuestionLabel := ARequest.QuestionLabel;
  Result.StartedAt := Now;
  Result.Status := prsRunning;

  LBody := TJSONObject.Create;
  try
    LContents := TJSONArray.Create;
    LContent := TJSONObject.Create;
    LParts := TJSONArray.Create;
    LParts.AddElement(TJSONObject.Create.AddPair('text', DelphiPrompt(ARequest.QuestionText)));
    LContent.AddPair('parts', LParts);
    LContents.AddElement(LContent);
    LBody.AddPair('contents', LContents);
    if (ARequest.MaxTokens > 0) or (ARequest.Temperature >= 0) or (ASettings.TopP >= 0) or (ASettings.TopK > 0) then
      LBody.AddPair('generationConfig', TJSONObject.Create);

    if Assigned(LBody.Values['generationConfig']) then
    begin
      if ARequest.MaxTokens > 0 then
        TJSONObject(LBody.Values['generationConfig']).AddPair('maxOutputTokens', TJSONNumber.Create(ARequest.MaxTokens));
      if ARequest.Temperature >= 0 then
        TJSONObject(LBody.Values['generationConfig']).AddPair('temperature', TJSONNumber.Create(ARequest.Temperature));
      if ASettings.TopP >= 0 then
        TJSONObject(LBody.Values['generationConfig']).AddPair('topP', TJSONNumber.Create(ASettings.TopP));
      if ASettings.TopK > 0 then
        TJSONObject(LBody.Values['generationConfig']).AddPair('topK', TJSONNumber.Create(ASettings.TopK));
    end;

    LRoot := TJSONObject.ParseJSONValue(ExecutePost(
      NormalizeBaseURL(ASettings.BaseURL, GetDefaultBaseURL) + '/' + NormalizeModelId(ARequest.ModelId) + ':generateContent',
      LBody.ToJSON,
      [TNameValuePair.Create('x-goog-api-key', ASettings.ApiKey)],
      ARequest
    )) as TJSONObject;
    try
      if not Assigned(LRoot) then
        raise Exception.Create('Invalid response from Gemini.');

      LCandidates := JsonArray(LRoot, 'candidates');
      if (not Assigned(LCandidates)) or (LCandidates.Count = 0) then
      begin
        Result.ErrorText := ExtractErrorText(LRoot);
        if Result.ErrorText = '' then
          Result.ErrorText := 'Gemini returned no candidates.';
        raise Exception.Create(Result.ErrorText);
      end;

      LCandidate := LCandidates.Items[0] as TJSONObject;
      LResponseContent := JsonObject(LCandidate, 'content');
      LResponseParts := JsonArray(LResponseContent, 'parts');
      if Assigned(LResponseParts) then
        for I := 0 to LResponseParts.Count - 1 do
          Result.ResponseText := Result.ResponseText + JsonString(LResponseParts.Items[I] as TJSONObject, 'text');

      CheckCompletion(JsonString(LCandidate, 'finishReason'), Result.ResponseText);
      if Trim(Result.ResponseText) = '' then
        raise Exception.Create('Gemini returned no text. Check finishReason or promptFeedback.');
      Result.Status := prsSucceeded;
      Result.FinishedAt := Now;
      Result.DurationMs := MilliSecondsBetween(Result.FinishedAt, Result.StartedAt);
    finally
      LRoot.Free;
    end;
  except
    on E: Exception do
    begin
      Result.Status := prsFailed;
      Result.ErrorText := E.Message;
      Result.FinishedAt := Now;
      Result.DurationMs := MilliSecondsBetween(Result.FinishedAt, Result.StartedAt);
    end;
  end;
  LBody.Free;
end;

function TGeminiProvider.GetCapabilities: TAIProviderCapabilities;
begin
  Result := [pcModelListing, pcCustomEndpoint];
end;

function TGeminiProvider.GetDefaultBaseURL: string;
begin
  Result := DefaultGeminiBaseURL;
end;

function TGeminiProvider.GetDefaultModel: string;
begin
  Result := DefaultGeminiModel;
end;

function TGeminiProvider.GetDisplayName: string;
begin
  Result := 'Gemini';
end;

function TGeminiProvider.GetId: string;
begin
  Result := ProviderGemini;
end;

function TGeminiProvider.NormalizeModelId(const AModelId: string): string;
begin
  Result := AModelId.Trim;
  if not Result.StartsWith('models/') then
    Result := 'models/' + Result;
end;

function TGeminiProvider.ListModels(const ASettings: TAIProviderSetting; out AModels: TModelDescriptorList; out AError: string): Boolean;
var
  LRoot: TJSONObject;
  LModels: TJSONArray;
  I, J: Integer;
  LItem: TJSONObject;
  LMethods: TJSONArray;
  LHasGenerateContent: Boolean;
  LDescriptor: TModelDescriptor;
  LRequest: TProviderRequest;
begin
  Result := False;
  AError := '';
  AModels := TModelDescriptorList.Create(True);
  LRequest := TProviderRequest.Create;
  try
    LRequest.TimeoutSeconds := Min(20, Max(CMinRequestTimeoutSeconds, ASettings.TimeoutSeconds));
    LRequest.ProxySetting.Assign(ASettings.ProxySetting);
    LRoot := TJSONObject.ParseJSONValue(ExecuteGet(
      NormalizeBaseURL(ASettings.BaseURL, GetDefaultBaseURL) + '/models',
      [TNameValuePair.Create('x-goog-api-key', ASettings.ApiKey)],
      LRequest
    )) as TJSONObject;
    try
      if not Assigned(LRoot) then
        raise Exception.Create('Unable to read Gemini models.');

      LModels := JsonArray(LRoot, 'models');
      if Assigned(LModels) then
        for I := 0 to LModels.Count - 1 do
        begin
          LItem := LModels.Items[I] as TJSONObject;
          LMethods := JsonArray(LItem, 'supportedGenerationMethods');
          LHasGenerateContent := False;
          if Assigned(LMethods) then
            for J := 0 to LMethods.Count - 1 do
              if SameText(LMethods.Items[J].Value, 'generateContent') then
              begin
                LHasGenerateContent := True;
                Break;
              end;

          if LHasGenerateContent then
          begin
            LDescriptor := TModelDescriptor.Create;
            LDescriptor.ProviderId := GetId;
            LDescriptor.ModelId := JsonString(LItem, 'baseModelId');
            if LDescriptor.ModelId = '' then
              LDescriptor.ModelId := JsonString(LItem, 'name').Replace('models/', '');
            LDescriptor.DisplayName := JsonString(LItem, 'displayName');
            if LDescriptor.DisplayName = '' then
              LDescriptor.DisplayName := LDescriptor.ModelId;
            LDescriptor.FetchedAt := Now;
            AModels.Add(LDescriptor);
          end;
        end;

      Result := AModels.Count > 0;
      if not Result then
        AError := 'No Gemini models were returned.';
    finally
      LRoot.Free;
    end;
  except
    on E: Exception do
      AError := E.Message;
  end;
  LRequest.Free;

  if not Result then
    FreeAndNil(AModels);
end;

function TClaudeProvider.Execute(const ARequest: TProviderRequest; const ASettings: TAIProviderSetting): TProviderResponse;
var
  LBody: TJSONObject;
  LRoot: TJSONObject;
begin
  Result := TProviderResponse.Create;
  Result.RequestId := ARequest.RequestId;
  Result.BatchId := ARequest.BatchId;
  Result.ProviderId := GetId;
  Result.ProviderDisplayName := GetDisplayName;
  Result.ModelId := ARequest.ModelId;
  Result.QuestionText := ARequest.QuestionText;
  Result.QuestionLabel := ARequest.QuestionLabel;
  Result.StartedAt := Now;
  Result.Status := prsRunning;

  LBody := BuildClaudeRequest(ARequest);
  try
    LRoot := TJSONObject.ParseJSONValue(ExecutePost(
      NormalizeBaseURL(ASettings.BaseURL, GetDefaultBaseURL) + '/v1/messages',
      LBody.ToJSON,
      [
        TNameValuePair.Create('x-api-key', ASettings.ApiKey),
        TNameValuePair.Create('anthropic-version', IfThen(Trim(ASettings.ApiVersion) <> '', ASettings.ApiVersion, AnthropicVersionHeader))
      ],
      ARequest
    )) as TJSONObject;
    try
      if not Assigned(LRoot) then
        raise Exception.Create('Invalid response from Claude.');

      Result.ResponseText := ExtractClaudeText(LRoot);
      CheckCompletion(JsonString(LRoot, 'stop_reason'), Result.ResponseText);
      if Result.ResponseText = '' then
        raise Exception.Create('Claude returned no text blocks. Check the model, response type and stop reason.');
      Result.Status := prsSucceeded;
      Result.FinishedAt := Now;
      Result.DurationMs := MilliSecondsBetween(Result.FinishedAt, Result.StartedAt);
    finally
      LRoot.Free;
    end;
  except
    on E: Exception do
    begin
      Result.Status := prsFailed;
      Result.ErrorText := E.Message;
      Result.FinishedAt := Now;
      Result.DurationMs := MilliSecondsBetween(Result.FinishedAt, Result.StartedAt);
    end;
  end;
  LBody.Free;
end;

function TClaudeProvider.GetCapabilities: TAIProviderCapabilities;
begin
  Result := [pcModelListing, pcCustomEndpoint];
end;

function TClaudeProvider.GetDefaultBaseURL: string;
begin
  Result := DefaultClaudeBaseURL;
end;

function TClaudeProvider.GetDefaultModel: string;
begin
  Result := DefaultClaudeModel;
end;

function TClaudeProvider.GetDisplayName: string;
begin
  Result := 'Claude';
end;

function TClaudeProvider.GetId: string;
begin
  Result := ProviderClaude;
end;

function TClaudeProvider.ListModels(const ASettings: TAIProviderSetting; out AModels: TModelDescriptorList; out AError: string): Boolean;
var
  LRoot: TJSONObject;
  LData: TJSONArray;
  I: Integer;
  LItem: TJSONObject;
  LRequest: TProviderRequest;
  LDescriptor: TModelDescriptor;
begin
  Result := False;
  AError := '';
  AModels := TModelDescriptorList.Create(True);
  LRequest := TProviderRequest.Create;
  try
    LRequest.TimeoutSeconds := Min(20, Max(CMinRequestTimeoutSeconds, ASettings.TimeoutSeconds));
    LRequest.ProxySetting.Assign(ASettings.ProxySetting);
    LRoot := TJSONObject.ParseJSONValue(ExecuteGet(
      NormalizeBaseURL(ASettings.BaseURL, GetDefaultBaseURL) + '/v1/models',
      [
        TNameValuePair.Create('x-api-key', ASettings.ApiKey),
        TNameValuePair.Create('anthropic-version', IfThen(Trim(ASettings.ApiVersion) <> '', ASettings.ApiVersion, AnthropicVersionHeader))
      ],
      LRequest
    )) as TJSONObject;
    try
      if not Assigned(LRoot) then
        raise Exception.Create('Unable to read Claude models.');

      LData := JsonArray(LRoot, 'data');
      if Assigned(LData) then
        for I := 0 to LData.Count - 1 do
        begin
          LItem := LData.Items[I] as TJSONObject;
          LDescriptor := TModelDescriptor.Create;
          LDescriptor.ProviderId := GetId;
          LDescriptor.ModelId := JsonString(LItem, 'id');
          LDescriptor.DisplayName := JsonString(LItem, 'display_name');
          if LDescriptor.DisplayName = '' then
            LDescriptor.DisplayName := LDescriptor.ModelId;
          LDescriptor.FetchedAt := Now;
          AModels.Add(LDescriptor);
        end;

      Result := AModels.Count > 0;
      if not Result then
        AError := 'No Claude models were returned.';
    finally
      LRoot.Free;
    end;
  except
    on E: Exception do
      AError := E.Message;
  end;
  LRequest.Free;

  if not Result then
    FreeAndNil(AModels);
end;

function TOllamaProvider.RootURL(const ASettings: TAIProviderSetting): string;
begin
  Result := NormalizeBaseURL(ASettings.BaseURL, GetDefaultBaseURL);
  if Result.EndsWith('/generate') then Delete(Result, Length(Result) - Length('/generate') + 1, MaxInt);
  if Result.EndsWith('/chat') then Delete(Result, Length(Result) - Length('/chat') + 1, MaxInt);
  if not Result.EndsWith('/api') then Result := Result + '/api';
end;

function TOllamaProvider.AuthHeaders(const ASettings: TAIProviderSetting): TNetHeaders;
begin
  SetLength(Result, 0);
  if Trim(ASettings.ApiKey) = '' then Exit;
  SetLength(Result, 1);
  Result[0] := TNameValuePair.Create('Authorization', 'Bearer ' + Trim(ASettings.ApiKey));
end;

function TOllamaProvider.Execute(const ARequest: TProviderRequest; const ASettings: TAIProviderSetting): TProviderResponse;
var
  LBody: TJSONObject;
  LRoot: TJSONObject;
begin
  Result := TProviderResponse.Create;
  Result.RequestId := ARequest.RequestId;
  Result.BatchId := ARequest.BatchId;
  Result.ProviderId := GetId;
  Result.ProviderDisplayName := GetDisplayName;
  Result.ModelId := ARequest.ModelId;
  Result.QuestionText := ARequest.QuestionText;
  Result.QuestionLabel := ARequest.QuestionLabel;
  Result.StartedAt := Now;
  Result.Status := prsRunning;

  LBody := TJSONObject.Create;
  try
    LBody.AddPair('model', ARequest.ModelId);
    LBody.AddPair('prompt', DelphiPrompt(ARequest.QuestionText));
    LBody.AddPair('stream', TJSONBool.Create(False));
    LBody.AddPair('options', TJSONObject.Create);
    if ARequest.MaxTokens > 0 then
      TJSONObject(LBody.Values['options']).AddPair('num_predict', TJSONNumber.Create(ARequest.MaxTokens));
    if ARequest.Temperature >= 0 then
      TJSONObject(LBody.Values['options']).AddPair('temperature', TJSONNumber.Create(ARequest.Temperature));
    if ASettings.TopP >= 0 then
      TJSONObject(LBody.Values['options']).AddPair('top_p', TJSONNumber.Create(ASettings.TopP));
    if ASettings.TopK > 0 then
      TJSONObject(LBody.Values['options']).AddPair('top_k', TJSONNumber.Create(ASettings.TopK));

    LRoot := TJSONObject.ParseJSONValue(ExecutePost(
      RootURL(ASettings) + '/generate',
      LBody.ToJSON,
      AuthHeaders(ASettings),
      ARequest
    )) as TJSONObject;
    try
      if not Assigned(LRoot) then
        raise Exception.Create('Invalid response from Ollama.');

      Result.ResponseText := JsonString(LRoot, 'response');
      if Result.ResponseText = '' then
      begin
        Result.ErrorText := ExtractErrorText(LRoot);
        if Result.ErrorText = '' then
          Result.ErrorText := 'Ollama returned no response.';
        raise Exception.Create(Result.ErrorText);
      end;
      CheckCompletion(JsonString(LRoot, 'done_reason'), Result.ResponseText);
      Result.Status := prsSucceeded;
      Result.FinishedAt := Now;
      Result.DurationMs := MilliSecondsBetween(Result.FinishedAt, Result.StartedAt);
    finally
      LRoot.Free;
    end;
  except
    on E: Exception do
    begin
      Result.Status := prsFailed;
      Result.ErrorText := E.Message;
      Result.FinishedAt := Now;
      Result.DurationMs := MilliSecondsBetween(Result.FinishedAt, Result.StartedAt);
    end;
  end;
  LBody.Free;
end;

function TOllamaProvider.GetCapabilities: TAIProviderCapabilities;
begin
  Result := [pcModelListing, pcCustomEndpoint, pcOffline];
end;

function TOllamaProvider.GetDefaultBaseURL: string;
begin
  Result := DefaultOllamaBaseURL;
end;

function TOllamaProvider.GetDefaultModel: string;
begin
  Result := DefaultOllamaModel;
end;

function TOllamaProvider.GetDisplayName: string;
begin
  Result := 'Ollama';
end;

function TOllamaProvider.GetId: string;
begin
  Result := ProviderOllama;
end;

function TOllamaProvider.ListModels(const ASettings: TAIProviderSetting; out AModels: TModelDescriptorList; out AError: string): Boolean;
var
  LRoot: TJSONObject;
  LModels: TJSONArray;
  I: Integer;
  LItem: TJSONObject;
  LRequest: TProviderRequest;
  LDescriptor: TModelDescriptor;
begin
  Result := False;
  AError := '';
  AModels := TModelDescriptorList.Create(True);
  LRequest := TProviderRequest.Create;
  try
    LRequest.TimeoutSeconds := Min(20, Max(CMinRequestTimeoutSeconds, ASettings.TimeoutSeconds));
    LRequest.ProxySetting.Assign(ASettings.ProxySetting);
    LRoot := TJSONObject.ParseJSONValue(ExecuteGet(
      RootURL(ASettings) + '/tags',
      AuthHeaders(ASettings),
      LRequest
    )) as TJSONObject;
    try
      if not Assigned(LRoot) then
        raise Exception.Create('Unable to read Ollama models.');

      LModels := JsonArray(LRoot, 'models');
      if Assigned(LModels) then
        for I := 0 to LModels.Count - 1 do
        begin
          LItem := LModels.Items[I] as TJSONObject;
          LDescriptor := TModelDescriptor.Create;
          LDescriptor.ProviderId := GetId;
          LDescriptor.ModelId := JsonString(LItem, 'model');
          if LDescriptor.ModelId = '' then
            LDescriptor.ModelId := JsonString(LItem, 'name');
          LDescriptor.DisplayName := JsonString(LItem, 'name');
          if LDescriptor.DisplayName = '' then
            LDescriptor.DisplayName := LDescriptor.ModelId;
          LDescriptor.FetchedAt := Now;
          AModels.Add(LDescriptor);
        end;

      Result := AModels.Count > 0;
      if not Result then
        AError := 'No Ollama models were returned.';
    finally
      LRoot.Free;
    end;
  except
    on E: Exception do
      AError := E.Message;
  end;
  LRequest.Free;

  if not Result then
    FreeAndNil(AModels);
end;

function TOllamaProvider.ValidateSettings(const ASettings: TAIProviderSetting; out AError: string): Boolean;
begin
  Result := False;
  AError := '';

  if not Assigned(ASettings) then
  begin
    AError := 'Missing provider settings.';
    Exit;
  end;

  if not ASettings.Enabled then
  begin
    AError := 'Provider is disabled.';
    Exit;
  end;

  if ASettings.BaseURL.Trim = '' then
  begin
    AError := 'Please enter the Ollama base URL.';
    Exit(False);
  end;

  if ASettings.DefaultModel.Trim = '' then
  begin
    AError := 'Please choose an Ollama model.';
    Exit(False);
  end;

  Result := True;
end;

constructor TAIProviderRegistry.Create;
begin
  inherited Create;
  FProviders := TDictionary<string, IAIProvider>.Create;
  FProviders.Add(ProviderGemini, TGeminiProvider.Create);
  FProviders.Add(ProviderClaude, TClaudeProvider.Create);
  FProviders.Add(ProviderOllama, TOllamaProvider.Create);
  FProviders.Add(ProviderChatGPT, TChatGPTProvider.Create);
end;

destructor TAIProviderRegistry.Destroy;
begin
  FProviders.Free;
  inherited;
end;

function TAIProviderRegistry.GetOrderedProviderIds: TArray<string>;
begin
  SetLength(Result, 4);
  Result[0] := ProviderGemini;
  Result[1] := ProviderClaude;
  Result[2] := ProviderOllama;
  Result[3] := ProviderChatGPT;
end;

function TAIProviderRegistry.GetProvider(const AProviderId: string): IAIProvider;
begin
  if not FProviders.TryGetValue(AProviderId, Result) then
    Result := nil;
end;

function TAIProviderRegistry.GetProviders: TArray<IAIProvider>;
var
  LIds: TArray<string>;
  I: Integer;
begin
  LIds := GetOrderedProviderIds;
  SetLength(Result, Length(LIds));
  for I := 0 to High(LIds) do
    Result[I] := GetProvider(LIds[I]);
end;

class function TAIProviderRegistry.Instance: IAIProviderRegistry;
begin
  if not Assigned(FInstance) then
    FInstance := TAIProviderRegistry.Create;
  Result := FInstance;
end;

function TModelCatalogService.GetCacheFilePath: string;
var
  LDir: string;
begin
  LDir := TPath.Combine(TPath.GetDocumentsPath, CPluginName);
  ForceDirectories(LDir);
  Result := TPath.Combine(LDir, 'ModelCache.json');
end;

function TModelCatalogService.GetCachedModels(const AProviderId: string): TModelDescriptorList;
var
  LRoot, LProvider: TJSONObject;
  LModels: TJSONArray;
  I: Integer;
  LItem: TJSONObject;
  LDescriptor: TModelDescriptor;
begin
  Result := TModelDescriptorList.Create(True);
  LRoot := LoadCache;
  try
    LProvider := GetProviderObject(LRoot, AProviderId, False);
    if not Assigned(LProvider) then
      Exit;

    if not (LProvider.Values['models'] is TJSONArray) then Exit;
    LModels := TJSONArray(LProvider.Values['models']);
    if not Assigned(LModels) then
      Exit;

    for I := 0 to LModels.Count - 1 do
    begin
      if not (LModels.Items[I] is TJSONObject) then Continue;
      LItem := TJSONObject(LModels.Items[I]);
      if CacheString(LItem, 'id') = '' then Continue;
      LDescriptor := TModelDescriptor.Create;
      LDescriptor.ProviderId := AProviderId;
      LDescriptor.ModelId := CacheString(LItem, 'id');
      LDescriptor.DisplayName := CacheString(LItem, 'display_name');
      if LDescriptor.DisplayName = '' then
        LDescriptor.DisplayName := LDescriptor.ModelId;
      try
        LDescriptor.FetchedAt := ISO8601ToDate(CacheString(LItem, 'fetched_at'));
      except
        LDescriptor.FetchedAt := Now;
      end;
      Result.Add(LDescriptor);
    end;
  finally
    LRoot.Free;
  end;
end;

function TModelCatalogService.GetProviderObject(ARoot: TJSONObject; const AProviderId: string; ACreate: Boolean): TJSONObject;
var
  LProviders: TJSONArray;
  I: Integer;
  LItem: TJSONObject;
begin
  Result := nil;
  if not Assigned(ARoot) then
    Exit;

  LProviders := nil;
  if ARoot.Values['providers'] is TJSONArray then
    LProviders := TJSONArray(ARoot.Values['providers']);
  if not Assigned(LProviders) then
  begin
    if not ACreate then
      Exit;

    ARoot.RemovePair('providers').Free;
    LProviders := TJSONArray.Create;
    ARoot.AddPair('providers', LProviders);
  end;

  for I := 0 to LProviders.Count - 1 do
  begin
    if not (LProviders.Items[I] is TJSONObject) then Continue;
    LItem := TJSONObject(LProviders.Items[I]);
    if SameText(CacheString(LItem, 'provider_id'), AProviderId) then
      Exit(LItem);
  end;

  if ACreate then
  begin
    Result := TJSONObject.Create;
    Result.AddPair('provider_id', AProviderId);
    Result.AddPair('models', TJSONArray.Create);
    LProviders.AddElement(Result);
  end;
end;

class function TModelCatalogService.Instance: IModelCatalogService;
begin
  if not Assigned(FInstance) then
    FInstance := TModelCatalogService.Create;
  Result := FInstance;
end;

function TModelCatalogService.LoadCache: TJSONObject;
var
  LPath: string;
  LValue: TJSONValue;
begin
  Result := nil;
  LValue := nil;
  try
    LPath := GetCacheFilePath;
    if FileExists(LPath) then
      LValue := TJSONObject.ParseJSONValue(TFile.ReadAllText(LPath, TEncoding.UTF8));
    if LValue is TJSONObject then
    begin
      Result := TJSONObject(LValue);
      LValue := nil;
    end;
  except
    // The cache is disposable; malformed/unreadable cache data must not block settings.
  end;
  LValue.Free;
  if not Assigned(Result) then Result := TJSONObject.Create;
end;

function TModelCatalogService.RefreshModels(const AProvider: IAIProvider; const ASettings: TAIProviderSetting; out AError: string): TModelDescriptorList;
var
  LRoot, LProvider: TJSONObject;
  LModels: TJSONArray;
  LOldModels: TJSONPair;
  LItem: TModelDescriptor;
begin
  Result := nil;
  if not AProvider.ListModels(ASettings, Result, AError) then
    Exit(nil);

  LRoot := LoadCache;
  try
    LProvider := GetProviderObject(LRoot, AProvider.GetId, True);
    LOldModels := LProvider.RemovePair('models');
    LOldModels.Free;
    LModels := TJSONArray.Create;
    LProvider.AddPair('models', LModels);
    for LItem in Result do
      LModels.AddElement(
        TJSONObject.Create
          .AddPair('id', LItem.ModelId)
          .AddPair('display_name', LItem.DisplayName)
          .AddPair('fetched_at', DateToISO8601(Now))
      );
    try
      SaveCache(LRoot);
    except
      // A disposable cache must not discard a successful network model listing.
      on E: Exception do AError := 'Models loaded, but the cache could not be saved: ' + E.Message;
    end;
  finally
    LRoot.Free;
  end;
end;

procedure TModelCatalogService.SaveCache(ARoot: TJSONObject);
var
  LPath, LTempPath: string;
  LGuid: TGUID;
begin
  LPath := GetCacheFilePath;
  CreateGUID(LGuid);
  LTempPath := LPath + '.' + GUIDToString(LGuid) + '.tmp';
  try
    TFile.WriteAllText(LTempPath, ARoot.ToJSON, TEncoding.UTF8);
    if not MoveFileEx(PChar(LTempPath), PChar(LPath), MOVEFILE_REPLACE_EXISTING or MOVEFILE_WRITE_THROUGH) then
      RaiseLastOSError;
  finally
    if FileExists(LTempPath) then System.SysUtils.DeleteFile(LTempPath);
  end;
end;

end.
