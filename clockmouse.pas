program clockmouse;
{$mode objfpc}{$H+}
uses
  AThreads, SysUtils, exec, amigados, Dos, Classes, Types, syncobjs,
  dateutils;
const
  VERSION = '$VER: clockmouse 0.1 (25.08.2018)';

const
  {$ifndef HASAMIGA}
  CMD_NONSTD = 0;
  {$endif}

  DEFAULTDEVICENAME = 'serial.device';
  DEFAULTUNITNUMBER = 0;
  DEFAULTBAUDRATE = 300;
  //
  SDCMD_QUERY = CMD_NONSTD;     // $09
  SDCMD_BREAK = CMD_NONSTD + 1; // $0A
  SDCMD_SETPARAMS = CMD_NONSTD + 2; // $0B

  SERB_XDISABLED = 7;     // xOn-xOff feature disabled bit
  SERF_XDISABLED = 1 shl 7; // xOn-xOff feature disabled mask
  SERB_EOFMODE = 6;         // EOF mode enabled bit
  SERF_EOFMODE = 1 shl 6;   // EOF mode enabled mask
  SERB_PARTY_ON = 0;      // parity-enabled bit
  SERF_PARTY_ON = 1 shl 0;  // parity-enabled mask

type
  TIOTArray = record
    TermArray0: LongWord;
    TermArray1: LongWord;
  end;

  {$ifdef HASAMIGA}
  TIOExtSer = record
    IOSer: TIOStdReq;
    io_CtlChar: LongWord;    // control characters */
    io_RBufLen: LongWord;    //;    /* length in bytes of serial read buffer */
    io_ExtFlags: LongWord;    //;   /* additional serial flags */
    io_Baud: LongWord;    //;       /* baud rate */
    io_BrkTime: LongWord;    //;    /* duration of break in microseconds */
    io_TermArray: TiOTArray;  //* termination character array */
    io_ReadLen: Byte;    //;    /* number of bits per read character */
    io_WriteLen: Byte;    //;   /* number of bits per write character */
    io_StopBits: Byte;    //;   /* number of stopbits for read */
    io_SerFlags: Byte;    //;   /* serial device flags */
    io_Status: Word;    //;     /* status of serial port and lines */
  end;
  PIOExtSer = ^TIOExtSer;
  {$endif}

  { TSerThread }

  TSerThread = class(TThread)
  public
    {$ifdef HASAMIGA}
    mp: PMsgPort;
    io: PIOExtSer;
    iod: PIORequest;
    {$endif}
    DeviceName: string;
    UnitNumber: Integer;
    BaudRate: Integer;
    DevOpen: Boolean;
    IORunning: Boolean;
    Crit: TCriticalSection;
  protected
    procedure InitSerial;
    procedure FinishSerial;
    procedure ParseMessage(Msg: string);
    procedure Execute; override;
  public
    InitDone: Boolean;
    GotDate: TDateTime;
    ValidTime: Boolean;
    SummerTime: Boolean;
    BattLow: Boolean;
    ThreadDone: Boolean;
    CurTime: TDateTime;
    Diff: Integer;
    constructor Create(ADeviceName: string; AUnitNumber: Integer; ABaudRate: Integer); reintroduce;
    destructor Destroy; override;
    procedure TerminateIt;
  end;

var
  SetTheTime: Boolean = False;

procedure DebugOut(Msg: String);
begin
  {$ifdef HASAMIGA}
  sysdebugln(Msg);
  {$else}
  writeln(Msg);
  {$endif}
end;

{$ifdef HASAMIGA}
function CreateExtIO(const Mp: PMsgPort; Size: Integer): PIORequest;
begin
  Result := nil;
  if not Assigned(mp) then
    Exit;
  Result := System.AllocMem(Size);
  if Assigned(Result) then
  begin
    Result^.io_Message.mn_Node.ln_Type := NT_REPLYMSG;
    Result^.io_Message.mn_ReplyPort := Mp;
    Result^.io_Message.mn_Length := Size;
  end;
end;

procedure DeleteExtIO(ioReq: PIORequest);
begin
  if Assigned(ioReq) then
  begin
    ioReq^.io_Message.mn_Node.ln_Type := Byte(-1);
    ioReq^.io_Device := Pointer(-1);
    ioReq^.io_Unit := Pointer(-1);
    System.FreeMem(ioReq);
  end;
end;
{$endif}

procedure TSerThread.InitSerial;
var
  Res: Integer;
begin
  InitDone := False;
  {$ifdef HASAMIGA}
  mp := nil;
  io := nil;
  iod := nil;
  DevOpen := False;
  IORunning := False;

  mp := CreateMsgPort;
  if not Assigned(Mp) then
  begin
    DebugOut('Error open MessagePort');
    Exit;
  end;
  //
  io := PIOExtSer(CreateExtIO(mp, sizeof(TIOExtSer)));
  if not assigned(io) then
  begin
    DebugOut('cannot alloc io');
    Exit;
  end;
  iod := Pointer(io);
  Res := OpenDevice(PChar(DeviceName), UnitNumber, iod,0);
  if Res <> 0 then
  begin
    DebugOut('unable to open device ' +  IntToStr(Res));
    Exit;
  end;
  DevOpen := True;

  io^.io_SerFlags := (io^.io_SerFlags or SERF_XDISABLED) and (not SERF_PARTY_ON) and (not SERF_EOFMODE);
  io^.io_Baud := BaudRate;
  io^.io_BrkTime := 20000000; // 2 second
  //io^.io_TermArray.TermArray0 := TERMINATORA;
  //io^.io_TermArray.TermArray1 := TERMINATORB;
  io^.IOSer.io_Command := SDCMD_SETPARAMS;
  Res := DoIO(iod);
  if Res <> 0 then
  begin
    DebugOut('Error set params ' + IntToStr(Res));
    Exit;
  end;
  {$endif}
  InitDone := True;
end;

procedure TSerThread.FinishSerial;
begin
  {$ifdef HASAMIGA}
  if Assigned(iod) then
  begin
    if IORunning then
    begin
      AbortIO(iod);
      WaitIO(iod);
    end;
    if DevOpen  then
      CloseDevice(iod);
  end;
  if Assigned(io) then
    DeleteExtIO(PIORequest(io));
  if Assigned(Mp) then
    DeleteMsgPort(Mp);
  InitDone := False;
  {$endif}
end;

// ------------ serthread.execute ----------------
procedure TSerThread.Execute;
var
  Buffer: array[0..256] of Char;
  i: Integer;
  ADKCON: PWord;
  ParB: PByte;
  SL: TStringList;
  Res: string;
begin
  // initial serial connection
  InitSerial;
  // cannot open serial -> break
  if not InitDone then
  begin
    Terminate;
    Exit;
  end;
  // result string
  Res := '';
  SL := TStringList.Create;
  // some hardware registers
  ADKCON := Pointer($DFF09E); // for reseting DTR/RTS
  ParB := Pointer($BFD000);   // for forcing TxD to break (device only send in this case)
  try
    repeat
      ParB^ := Byte(-1); // reset serial lines
      ADKCON^ := (1 shl 15) or (1 shl 11); // set UARTBRK
      //
      FillChar(Buffer[0], 257, #0);
      //
      io^.IOSer.io_Length := 16;
      io^.IOSer.io_Data := @Buffer[0];
      io^.IOSer.io_Command := CMD_READ;
      IORunning := True;
      SendIO(iod);
      //
      while CheckIO(iod) = nil do
      begin
        Sleep(10);
        if Terminated then
          Break;
      end;
      IORunning := False;
      WaitIO(iod);
      for i := 0 to 16 do
      begin
        //write(' ' + IntToStr(Ord(Buffer[i])));
        if Buffer[i] = #13 then
          Buffer[i] := #10;
      end;
      Res := Res + AnsiString(Buffer);
      //writeln(' - Buffer: "' + Buffer+ '"');
    until Terminated or (Length(Res) >= (3 * 16));
    ParB^ := Byte(-1) and not (1 shl 6) and not (1 shl 7); // reset DTR/RTS
    ADKCON^ := 1 shl 11; // // set UARTBRK
    SL.Text := Res;
    //Writeln('Get result: ');
    for i := SL.Count - 1 downto 0 do
    begin
      if Length(SL[i]) = 15 then
      begin
        ParseMessage(SL[i]);
        Break;
      end;
    end;
    //
    Terminate;
  except
    on E:Exception do
      DebugOut('Exception in SerialTask: ' + E.Message);
  end;
  ThreadDone := True;
  SL.Free;
  FinishSerial;
end;

// ------------ serthread.TerminateIt ----------------
// Terminate the thread with killing the running io request
procedure TSerThread.TerminateIt;
begin
  if InitDone then
    AbortIO(iod);
  Terminate;
end;

const
  S1_Is_MEZ = 1 shl 2;
  S1_Is_MESZ = 1 shl 1;
  S2_BatLow = 1 shl 3;
  S2_Err = 1 shl 2;
  S2_LastOK = 1 shl 1;
  S2_Valid = 1 shl 0;

// ------------ serthread.ParseMessage ----------------
procedure TSerThread.ParseMessage(Msg: string);
var
  Status1, Status2: Byte;
  day, month, year, hour, min, sec: LongInt;
begin
  if Length(Msg) <> 15 then
    Exit;
  CurTime := Now();
  Status1 := Ord(Msg[14]);
  Status2 := Ord(Msg[15]);
  ValidTime := (Status2 and S2_Valid) <> 0;
  SummerTime := ((Status1 and S1_Is_MESZ) <> 0);
  BattLow := (Status2 and S2_BatLow) <> 0;
  if not ValidTime then
    Exit;
  Hour := StrToIntDef(Copy(Msg, 1, 2), -1);
  Min := StrToIntDef(Copy(Msg,  3, 2), -1);
  Sec := StrToIntDef(Copy(Msg,  5, 2), -1);
  if (Hour < 0) or (Min < 0) and (Sec < 0) then
  begin
    ValidTime := False;
    Exit;
  end;
  // hour
  Day := StrToIntDef(Copy(Msg, 8, 2), -1);
  Month := StrToIntDef(Copy(Msg, 10, 2), -1);
  Year := StrToIntDef(Copy(Msg, 12, 2), -1);
  if (Day <= 0) or (Month <= 0) and (Year <= 0) then
  begin
    ValidTime := False;
    Exit;
  end;
  Year := Year + 2000;
  ValidTime := TryEncodeDateTime(Year, Month, Day, Hour, Min, Sec, 0, GotDate);
  //
  if ValidTime then
  begin
    Diff := Round((GotDate - CurTime) * 24 * 60 * 60);
    if SetTheTime then
    begin
      SetDate(Year, Month, day);
      SetTime(Hour, Min, Sec, 0);
    end;
  end;
end;

// ------------ serthread.create ----------------
constructor TSerThread.Create(ADeviceName: string; AUnitNumber: Integer; ABaudRate: Integer);
begin
  DebugOut('Create serial with Device: ' + ADevicename + ' Unit: ' + IntToStr(AUnitNumber) + ' BaudRate: ' + IntToStr(ABaudRate));
  ThreadDone := False;
  Diff := 0;
  Crit := TCriticalSection.Create;
  DeviceName := ADeviceName;
  UnitNumber := AUnitNumber;
  BaudRate := ABaudRate;
  inherited Create(True);
  Start;
end;

// ------------ serthread.destroy ----------------
destructor TSerThread.Destroy;
begin
  Crit.Free;
  inherited Destroy;
end;

// ############## MAIN ROUTINE ################
var
  s: TSerThread;
  StartTime: LongWord;
  i: Integer;
begin
  SetTheTime := False;
  for i := 1 to ParamCount do
  begin
    if ParamStr(i) = '-s' then
      SetTheTime := True;
  end;
  s := TSerThread.Create('serial.device', 0, 300);
  writeln('clockmouse 0.1');
  writeln('==============');
  writeln('Wait for time from device (max. 10 s) ...');
  StartTime := GetTickCount;
  repeat
    Sleep(100);
  until (GetTickCount - StartTime > 10000) or s.ThreadDone;
  if not s.ThreadDone then
    writeln('No response from DCF-77 clock mouse.');
  s.TerminateIt;
  s.WaitFor;
  //
  writeln('Got valid time: ', s.ValidTime);
  if s.ValidTime then
  begin
    writeln('  Time: ', DateTimeToStr(s.GotDate));
    if s.SummerTime then
      writeln('  Time zone: MESZ')
    else
      writeln('  Time zone: MEZ');
    if s.BattLow then
      writeln('  Battery: Low!')
    else
      writeln('  Battery: OK');
    writeln('  Diff to system time: ', s.Diff, ' seconds');
    if (Abs(s.Diff) > 10) and not SetTheTime then
      writeln('  use ', ParamStr(0), ' -s to set the system time.');
    if SetTheTime then
      writeln('  System time set.');
  end;


  S.Free;
end.
