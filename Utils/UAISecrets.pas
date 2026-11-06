unit UAISecrets;

interface

function ProtectSecret(const AValue: string): string;
function UnprotectSecret(const AValue: string): string;

implementation

uses Winapi.Windows, System.SysUtils, System.NetEncoding;

type
  PSecretBlob = ^TSecretBlob;
  TSecretBlob = record
    cbData: DWORD;
    pbData: PByte;
  end;

function CryptProtectData(pDataIn: PSecretBlob; szDataDescr: PWideChar; pOptionalEntropy,
  pvReserved, pPromptStruct: Pointer; dwFlags: DWORD; pDataOut: PSecretBlob): BOOL; stdcall;
  external 'crypt32.dll' name 'CryptProtectData';
function CryptUnprotectData(pDataIn: PSecretBlob; ppszDataDescr, pOptionalEntropy,
  pvReserved, pPromptStruct: Pointer; dwFlags: DWORD; pDataOut: PSecretBlob): BOOL; stdcall;
  external 'crypt32.dll' name 'CryptUnprotectData';

const
  CSecretPrefix = 'dpapi:v1:';
  CNoUI = 1; // CRYPTPROTECT_UI_FORBIDDEN; current-user scope (not LOCAL_MACHINE).

function ProtectSecret(const AValue: string): string;
var
  LIn, LOut: TSecretBlob;
  LBytes, LEncrypted: TBytes;
begin
  Result := '';
  if AValue = '' then Exit;
  LBytes := TEncoding.UTF8.GetBytes(AValue);
  LIn.cbData := Length(LBytes);
  LIn.pbData := @LBytes[0];
  FillChar(LOut, SizeOf(LOut), 0);
  try
    if not CryptProtectData(@LIn, nil, nil, nil, nil, CNoUI, @LOut) then RaiseLastOSError;
    SetLength(LEncrypted, LOut.cbData);
    if LOut.cbData > 0 then Move(LOut.pbData^, LEncrypted[0], LOut.cbData);
    Result := CSecretPrefix + TNetEncoding.Base64.EncodeBytesToString(LEncrypted);
  finally
    if Length(LBytes) > 0 then FillChar(LBytes[0], Length(LBytes), 0);
    if Assigned(LOut.pbData) then LocalFree(HLOCAL(LOut.pbData));
  end;
end;

function UnprotectSecret(const AValue: string): string;
var
  LIn, LOut: TSecretBlob;
  LBytes, LPlain: TBytes;
begin
  // Legacy plaintext is accepted on read and protected the next time settings are saved.
  Result := AValue;
  if not AValue.StartsWith(CSecretPrefix) then Exit;
  LBytes := TNetEncoding.Base64.DecodeStringToBytes(Copy(AValue, Length(CSecretPrefix) + 1, MaxInt));
  if Length(LBytes) = 0 then raise Exception.Create('Invalid protected FusionAI secret.');
  LIn.cbData := Length(LBytes);
  LIn.pbData := @LBytes[0];
  FillChar(LOut, SizeOf(LOut), 0);
  try
    if not CryptUnprotectData(@LIn, nil, nil, nil, nil, CNoUI, @LOut) then
      raise Exception.Create('FusionAI could not decrypt a saved key with this Windows user profile.');
    SetLength(LPlain, LOut.cbData);
    if LOut.cbData > 0 then Move(LOut.pbData^, LPlain[0], LOut.cbData);
    Result := TEncoding.UTF8.GetString(LPlain);
  finally
    if Length(LPlain) > 0 then FillChar(LPlain[0], Length(LPlain), 0);
    if Assigned(LOut.pbData) then
    begin
      FillChar(LOut.pbData^, LOut.cbData, 0);
      LocalFree(HLOCAL(LOut.pbData));
    end;
  end;
end;

end.
