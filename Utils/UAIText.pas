unit UAIText;

interface

uses System.SysUtils;

// Preserve byte/character positions and line breaks while masking comments and strings.
function MaskPascalText(const AText: string): string;
function CountPascalKeyword(const AText, AKeyword: string): Integer;

implementation

function MaskPascalText(const AText: string): string;
var
  I, LState: Integer;
begin
  Result := AText;
  LState := 0; // 0 code, 1 string, 2 line comment, 3 brace comment, 4 paren comment
  I := 1;
  while I <= Length(AText) do
  begin
    if CharInSet(AText[I], [#10, #13]) then
    begin
      if LState = 2 then LState := 0;
      Inc(I);
      Continue;
    end;
    case LState of
      0:
        if AText[I] = '''' then
        begin
          Result[I] := ' ';
          LState := 1;
        end
        else if AText[I] = '{' then
        begin
          Result[I] := ' ';
          LState := 3;
        end
        else if (I < Length(AText)) and
          (((AText[I] = '/') and (AText[I + 1] = '/')) or
           ((AText[I] = '(') and (AText[I + 1] = '*'))) then
        begin
          if AText[I] = '/' then LState := 2 else LState := 4;
          Result[I] := ' ';
          Inc(I);
          Result[I] := ' ';
        end;
      1:
        begin
          Result[I] := ' ';
          if AText[I] = '''' then
          begin
            if (I < Length(AText)) and (AText[I + 1] = '''') then
            begin
              Inc(I);
              Result[I] := ' ';
            end
            else LState := 0;
          end;
        end;
      2: Result[I] := ' ';
      3:
        begin
          Result[I] := ' ';
          if AText[I] = '}' then LState := 0;
        end;
      4:
        begin
          Result[I] := ' ';
          if (AText[I] = '*') and (I < Length(AText)) and (AText[I + 1] = ')') then
          begin
            Inc(I);
            Result[I] := ' ';
            LState := 0;
          end;
        end;
    end;
    Inc(I);
  end;
end;

function CountPascalKeyword(const AText, AKeyword: string): Integer;
var
  I, LStart: Integer;
  LWord: string;
begin
  Result := 0;
  I := 1;
  while I <= Length(AText) do
  begin
    if CharInSet(AText[I], ['A'..'Z', 'a'..'z', '_']) then
    begin
      LStart := I;
      repeat
        Inc(I);
      until (I > Length(AText)) or not CharInSet(AText[I], ['A'..'Z', 'a'..'z', '0'..'9', '_']);
      LWord := Copy(AText, LStart, I - LStart);
      if SameText(LWord, AKeyword) then Inc(Result);
    end
    else Inc(I);
  end;
end;

end.
