unit UAIRequestCoordinator;

interface

uses
  Winapi.Windows,
  Winapi.Messages,
  System.Classes,
  System.Math,
  System.SysUtils,
  System.Generics.Collections,
  Vcl.ExtCtrls,
  UAICommon,
  UAIProviders,
  UChatGPTSetting,
  UConsts;

type
  TProviderExecutionThread = class(TThread)
  private
    FProvider: IAIProvider;
    FRequest: TProviderRequest;
    FSettings: TAIProviderSetting;
    FLastResponse: TProviderResponse;
    function BuildFailedResponse(const AMessage: string): TProviderResponse;
  protected
    procedure Execute; override;
  public
    // Takes ownership of ARequest and ASettings; the worker never calls the UI.
    constructor Create(const AProvider: IAIProvider; const ARequest: TProviderRequest;
      const ASettings: TAIProviderSetting);
    destructor Destroy; override;

    property LastResponse: TProviderResponse read FLastResponse;
    property Request: TProviderRequest read FRequest;
  end;

  TAIRequestCoordinator = class(TComponent)
  private
    FTargetHandle: HWND;
    FThreads: TObjectDictionary<string, TProviderExecutionThread>;
    FCurrentBatchId: string;
    FSignalBatchCompleted: Boolean;
    FPollTimer: TTimer;
    procedure PollThreads(Sender: TObject);
    procedure PostBatchCompleted(const ABatchId: string);
    function NewId: string;
    function BuildRequest(const AProviderId, APrompt, AQuestionLabel: string): TProviderRequest;
    function GetProviderIdsForPrompt(const AActiveProviderId: string): TArray<string>;
  public
    constructor Create(AOwner: TComponent; ATargetHandle: HWND); reintroduce;
    destructor Destroy; override;

    procedure StartPromptBatch(const APrompt, AQuestionLabel, AActiveProviderId: string);
    procedure StartSingleProvider(const AProviderId, APrompt, AQuestionLabel: string; ASignalBatchCompleted: Boolean = True);
    procedure CancelAll;
    function PendingCount: Integer;
    function HasPendingRequests: Boolean;
    property CurrentBatchId: string read FCurrentBatchId;
    property TargetHandle: HWND read FTargetHandle write FTargetHandle;
end;

implementation

function TProviderExecutionThread.BuildFailedResponse(const AMessage: string): TProviderResponse;
begin
  Result := TProviderResponse.Create;
  Result.RequestId := FRequest.RequestId;
  Result.BatchId := FRequest.BatchId;
  Result.ProviderId := FRequest.ProviderId;
  if Assigned(FProvider) then
    Result.ProviderDisplayName := FProvider.GetDisplayName
  else
    Result.ProviderDisplayName := FRequest.ProviderId;
  Result.ModelId := FRequest.ModelId;
  Result.QuestionText := FRequest.QuestionText;
  Result.QuestionLabel := FRequest.QuestionLabel;
  Result.Status := prsFailed;
  Result.ErrorText := AMessage;
  Result.StartedAt := Now;
  Result.FinishedAt := Result.StartedAt;
  Result.DurationMs := 0;
end;

constructor TProviderExecutionThread.Create(const AProvider: IAIProvider; const ARequest: TProviderRequest;
  const ASettings: TAIProviderSetting);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FProvider := AProvider;
  FRequest := ARequest;
  FSettings := ASettings; // ownership transferred by caller
end;

destructor TProviderExecutionThread.Destroy;
begin
  FLastResponse.Free;
  FRequest.Free;
  FSettings.Free;
  inherited;
end;

procedure TProviderExecutionThread.Execute;
begin
  inherited;
  try
    if Terminated then
      Exit;

    if not Assigned(FProvider) then
      FLastResponse := BuildFailedResponse(CProviderUnavailableMessage)
    else
      FLastResponse := FProvider.Execute(FRequest, FSettings);

    if not Assigned(FLastResponse) then
      FLastResponse := BuildFailedResponse(CProgressFailed);

    if Terminated and Assigned(FLastResponse) then
    begin
      FLastResponse.Status := prsCancelled;
      if FLastResponse.ErrorText = '' then
        FLastResponse.ErrorText := CProgressCancelled;
      FLastResponse.FinishedAt := Now;
    end;
  except
    on E: Exception do
    begin
      FreeAndNil(FLastResponse);
      FLastResponse := BuildFailedResponse(E.Message);
    end;
  end;

  // Result is read by the main-thread poller only after the OS thread has exited.
end;

function TAIRequestCoordinator.BuildRequest(const AProviderId, APrompt, AQuestionLabel: string): TProviderRequest;
var
  LSettings: TSingletonSettingObj;
  LProviderSetting: TAIProviderSetting;
begin
  LSettings := TSingletonSettingObj.Instance;
  Result := TProviderRequest.Create;
  Result.RequestId := NewId;
  Result.BatchId := FCurrentBatchId;
  Result.ProviderId := AProviderId;
  Result.QuestionText := APrompt;
  Result.QuestionLabel := AQuestionLabel;
  if LSettings.TimeOut > 0 then
    Result.TimeoutSeconds := EnsureRange(LSettings.TimeOut, CMinRequestTimeoutSeconds, CMaxRequestTimeoutSeconds)
  else
    Result.TimeoutSeconds := CDefaultRequestTimeoutSeconds;
  Result.Animated := LSettings.AnimatedLetters;
  Result.LogEnabled := LSettings.EnableFileLog;
  Result.LogDirectory := LSettings.LogDirectory;
  Result.ProxySetting.Assign(LSettings.ProxySetting);
  LProviderSetting := LSettings.GetProviderSetting(AProviderId);
  try
    Result.ModelId := LSettings.GetEffectiveModel(AProviderId);
    if LProviderSetting.MaxTokens > 0 then
      Result.MaxTokens := LProviderSetting.MaxTokens
    else
      Result.MaxTokens := LSettings.MaxToken;

    if LProviderSetting.Temperature >= 0 then
      Result.Temperature := LProviderSetting.Temperature
    else
      Result.Temperature := -1;
  finally
    LProviderSetting.Free;
  end;
end;

procedure TAIRequestCoordinator.CancelAll;
var
  LThread: TProviderExecutionThread;
begin
  if not Assigned(FThreads) then Exit;
  for LThread in FThreads.Values do
  begin
    LThread.Request.Cancel;
    LThread.Terminate;
  end;
  FCurrentBatchId := ''; // cancelled workers stay owned until actually finished
end;

constructor TAIRequestCoordinator.Create(AOwner: TComponent; ATargetHandle: HWND);
begin
  inherited Create(AOwner);
  FTargetHandle := ATargetHandle;
  FThreads := TObjectDictionary<string, TProviderExecutionThread>.Create([doOwnsValues]);
  FPollTimer := TTimer.Create(Self);
  FPollTimer.Enabled := False;
  FPollTimer.Interval := 100;
  FPollTimer.OnTimer := PollThreads;
end;

destructor TAIRequestCoordinator.Destroy;
var
  LThread: TProviderExecutionThread;
begin
  if Assigned(FPollTimer) then FPollTimer.Enabled := False;
  FTargetHandle := 0;
  CancelAll;
  // Workers never Synchronize or call OnTerminate into the UI. Joining cannot
  // depend on this component. Before HTTP headers, Tokyo may wait for timeout.
  if Assigned(FThreads) then
    for LThread in FThreads.Values do
      LThread.WaitFor;
  FThreads.Free;
  inherited;
end;

function TAIRequestCoordinator.GetProviderIdsForPrompt(const AActiveProviderId: string): TArray<string>;
var
  LSettings: TSingletonSettingObj;
begin
  LSettings := TSingletonSettingObj.Instance;
  Result := LSettings.GetEnabledProviderIds;

  if Length(Result) <= 1 then
  begin
    if (Length(Result) = 0) and (AActiveProviderId <> '') then
    begin
      SetLength(Result, 1);
      Result[0] := AActiveProviderId;
    end;
    Exit;
  end;
end;

function TAIRequestCoordinator.HasPendingRequests: Boolean;
begin
  Result := PendingCount > 0;
end;

function TAIRequestCoordinator.NewId: string;
var
  LGUID: TGUID;
begin
  CreateGUID(LGUID);
  Result := GUIDToString(LGUID);
end;

function TAIRequestCoordinator.PendingCount: Integer;
var
  LThread: TProviderExecutionThread;
begin
  Result := 0;
  if FCurrentBatchId = '' then Exit;
  for LThread in FThreads.Values do
    if LThread.Request.BatchId = FCurrentBatchId then Inc(Result);
end;

procedure TAIRequestCoordinator.PostBatchCompleted(const ABatchId: string);
var
  LPayload: TProviderMessagePayload;
begin
  LPayload := TProviderMessagePayload.Create(pmBatchCompleted, ABatchId, '');
  if IsWindow(FTargetHandle) then
  begin
    SendMessage(FTargetHandle, WM_PROVIDER_MESSAGE, WPARAM(LPayload), 0);
  end
  else
    LPayload.Free;
end;

procedure TAIRequestCoordinator.StartPromptBatch(const APrompt, AQuestionLabel, AActiveProviderId: string);
var
  LRegistry: IAIProviderRegistry;
  LProviderIds: TArray<string>;
  LProviderId: string;
  LThread: TProviderExecutionThread;
  LPayload: TProviderMessagePayload;
begin
  CancelAll;
  PollThreads(nil);
  if FThreads.Count > 4 then
    raise Exception.Create('Cancelled requests are still finishing. Please wait before retrying.');
  FCurrentBatchId := NewId;
  FSignalBatchCompleted := True;
  LRegistry := TAIProviderRegistry.Instance;
  LProviderIds := GetProviderIdsForPrompt(AActiveProviderId);

  for LProviderId in LProviderIds do
  begin
    LThread := TProviderExecutionThread.Create(
      LRegistry.GetProvider(LProviderId),
      BuildRequest(LProviderId, APrompt, AQuestionLabel),
      TSingletonSettingObj.Instance.GetProviderSetting(LProviderId)
    );

    FThreads.Add(LThread.Request.RequestId, LThread);
    try
      LThread.Start;
    except
      FThreads.Remove(LThread.Request.RequestId);
      raise;
    end;
    LPayload := TProviderMessagePayload.Create(pmRequestStarted, FCurrentBatchId, LProviderId);
    if IsWindow(FTargetHandle) then
    begin
      SendMessage(FTargetHandle, WM_PROVIDER_MESSAGE, WPARAM(LPayload), 0);
    end
    else
      LPayload.Free;
    FPollTimer.Enabled := True;
  end;
end;

procedure TAIRequestCoordinator.StartSingleProvider(const AProviderId, APrompt, AQuestionLabel: string; ASignalBatchCompleted: Boolean);
var
  LThread: TProviderExecutionThread;
  LRegistry: IAIProviderRegistry;
  LPayload: TProviderMessagePayload;
begin
  CancelAll;
  PollThreads(nil);
  if FThreads.Count > 4 then
    raise Exception.Create('Cancelled requests are still finishing. Please wait before retrying.');
  FCurrentBatchId := NewId;
  FSignalBatchCompleted := ASignalBatchCompleted;
  LRegistry := TAIProviderRegistry.Instance;
  LThread := TProviderExecutionThread.Create(
    LRegistry.GetProvider(AProviderId),
    BuildRequest(AProviderId, APrompt, AQuestionLabel),
    TSingletonSettingObj.Instance.GetProviderSetting(AProviderId)
  );

  FThreads.Add(LThread.Request.RequestId, LThread);
  try
    LThread.Start;
  except
    FThreads.Remove(LThread.Request.RequestId);
    raise;
  end;
  LPayload := TProviderMessagePayload.Create(pmRequestStarted, FCurrentBatchId, AProviderId);
  if IsWindow(FTargetHandle) then
  begin
    SendMessage(FTargetHandle, WM_PROVIDER_MESSAGE, WPARAM(LPayload), 0);
  end
  else
    LPayload.Free;
  FPollTimer.Enabled := True;
end;

procedure TAIRequestCoordinator.PollThreads(Sender: TObject);
var
  LIds: TArray<string>;
  LId, LBatchId: string;
  LThread: TProviderExecutionThread;
  LResponse: TProviderResponse;
  LPayload: TProviderMessagePayload;
begin
  LIds := FThreads.Keys.ToArray;
  for LId in LIds do
    if FThreads.TryGetValue(LId, LThread) and
       (WaitForSingleObject(LThread.Handle, 0) = WAIT_OBJECT_0) then
    begin
      LResponse := nil;
      LBatchId := LThread.Request.BatchId;
      if (LBatchId = FCurrentBatchId) and Assigned(LThread.LastResponse) then
        LResponse := LThread.LastResponse.Clone;
      FThreads.Remove(LId); // owns and frees only a finished worker
      if Assigned(LResponse) then
      begin
        LPayload := TProviderMessagePayload.Create(pmRequestCompleted, LBatchId, LResponse.ProviderId, LResponse);
        // Main-thread synchronous delivery leaves no heap payload in a dead window queue.
        if IsWindow(FTargetHandle) then
          SendMessage(FTargetHandle, WM_PROVIDER_MESSAGE, WPARAM(LPayload), 0)
        else LPayload.Free;
      end;
    end;
  FPollTimer.Enabled := FThreads.Count > 0;
  if (FCurrentBatchId <> '') and FSignalBatchCompleted and (PendingCount = 0) then
  begin
    FSignalBatchCompleted := False;
    PostBatchCompleted(FCurrentBatchId);
  end;
end;

end.
