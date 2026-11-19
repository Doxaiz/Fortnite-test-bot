#Requires AutoHotkey v2.0
#NoTrayIcon
#Include ../tools/replay_f5.ahk

folder := A_Temp "\forma-replay-" ProcessExist() "-" A_TickCount
code := 0
try {
    DirCreate(folder)
    ReplayCheck(!UI.gui && !UI.hkKeys.Length && !ST.running, "включение не запускает FORMA")
    TestReplayBytes(folder)
    FileAppend("OK: BMP round-trip and rejected headers`n", "*", "UTF-8-RAW")
    TestReplayReport(folder)
    FileAppend("OK: F5 report parity, batch errors and isolation`n", "*", "UTF-8-RAW")
} catch as e {
    FileAppend("FAIL: " e.Message " (line " e.Line ")`n", "**", "UTF-8-RAW")
    code := 1
} finally {
    try DirDelete(folder, true)
}
ExitApp(code)

ReplayCheck(ok, description) {
    if !ok
        throw Error(description, -1)
}

ExpectBadBmp(path, description) {
    try ReadF5Bmp(path)
    catch ValueError
        return
    throw Error("Принят неверный BMP: " description)
}

WriteTestBytes(path, bytes, count) {
    file := FileOpen(path, "w", "UTF-8-RAW")
    try {
        ReplayCheck(file.RawWrite(bytes, count) = count, "файл фикстуры записан полностью")
    } finally {
        file.Close()
    }
}

TestReplayBytes(folder) {
    ; Разная ориентация строк, все каналы и ненулевой X-байт.
    valid := folder "\малый кадр.BMP", bad := folder "\bad.bmp"
    original := {w:3, h:2, stride:12, buf:Buffer(24)}
    NumPut("UInt", 0xFF010203, "UInt", 0xFF040506, "UInt", 0xFF070809
        , "UInt", 0x7F090807, "UInt", 0x7F060504, "UInt", 0x7F030201, original.buf)
    WriteCalibrationBmp(original, valid)
    shot := ReadF5Bmp(valid, 11)
    ReplayCheck(shot.w = 3 && shot.h = 2 && shot.captureId = 11 && shot.stride = 12
        && shot.buf.Size = 24 && !shot.hwnd && !shot.capturedAt, "пиксели локального файла не принадлежат окну")
    ReplayCheck(DllCall("msvcrt\memcmp", "Ptr", shot.buf, "Ptr", original.buf, "UPtr", 24, "CDecl Int") = 0
        , "строки и BGRX не преобразованы")
    for change in [[0, "UShort", 0, "сигнатура"], [2, "UInt", 0, "длина файла"]
        , [10, "UInt", 5, "смещение"], [14, "UInt", 124, "не тот DIB"]
        , [18, "Int", 8193, "большая ширина"], [18, "Int", -3, "отрицательная ширина"]
        , [22, "Int", 2, "снизу вверх"], [22, "Int", -2147483648, "переполнение высоты"]
        , [26, "UShort", 0, "плоскости"], [28, "UShort", 24, "24 bpp"]
        , [30, "UInt", 3, "маски каналов"], [34, "UInt", 48, "длина пикселей"]] {
        bytes := FileRead(valid, "RAW")
        NumPut(change[2], change[3], bytes, change[1])
        WriteTestBytes(bad, bytes, bytes.Size)
        ExpectBadBmp(bad, change[4])
    }
    bytes := FileRead(valid, "RAW")
    for size in [53, bytes.Size - 1] {
        WriteTestBytes(bad, bytes, size)
        ExpectBadBmp(bad, "обрезанный файл (" size " байт)")
    }
    ExpectBadBmp(folder "\readme.png", "не BMP")
}

TestReplayReport(folder) {
    global CFG, ST, UI
    ; Наполненный кадр на обычном размере: сравнить все строки диагностики
    ; с тем же буфером до экспорта, не только строку о фигуре.
    name := "кадр с пробелом.bmp", path := folder "\" name
    shot := {w:480, h:288, stride:1920, buf:Buffer(480 * 288 * 4, 0x45)
        , captureId:2, hwnd:0, capturedAt:0, x:0, y:0, source:"сохранённый BMP (без захвата)"}
    Loop 18 {
        base := (258 + A_Index) * shot.stride
        Loop 80
            NumPut("UInt", 0x002ABA31, shot.buf, base + (24 + A_Index) * 4)
    }
    WriteCalibrationBmp(shot, path)
    saved := FileRead(path, "RAW"), before := ST.Clone()
    stdout := folder "\stdout.txt", stderr := folder "\stderr.txt"
    expected := BuildCalibrationReport(shot)
    ; Битый кадр не запрещает обработать следующий; вызов возвращает отказ.
    ReplayCheck(ReplayF5([folder "\bad.bmp", path], stdout, stderr) = 1, "частичная ошибка не скрыта")
    actual := StrReplace(FileRead(stdout, "UTF-8"), "`r`n", "`n")
    report := ""
    for line in expected.lines
        report .= line "`n"
    start := InStr(actual, expected.lines[1] "`n")
    ReplayCheck(InStr(actual, name) && !InStr(actual, folder) && start > 0 && SubStr(actual, start) == report
        , "реплей печатает тот же F5, без полного пути")
    ReplayCheck(InStr(FileRead(stderr, "UTF-8"), "BMP #1 (bad.bmp)"), "отказ в stderr с именем файла")
    ReplayCheck(ReplayF5([], stdout, stderr) = 2, "пустой список — ошибка использования")
    tooMany := []
    Loop 33
        tooMany.Push(path)
    ReplayCheck(ReplayF5(tooMany, stdout, stderr) = 2 && StrReplace(FileRead(stdout, "UTF-8"), "`r`n", "`n") = actual
        , "лимит проверяется до чтения")
    after := FileRead(path, "RAW")
    ReplayCheck(after.Size = saved.Size && DllCall("msvcrt\memcmp", "Ptr", after, "Ptr", saved, "UPtr", saved.Size, "CDecl Int") = 0
        , "входной BMP не меняется")
    for key, value in before.OwnProps()
        ReplayCheck(ST.%key% = value, "реплей не публикует состояние: " key)
    ReplayCheck(CFG.dryRun && !UI.gui && !UI.hkKeys.Length && !ST.running, "захват, хоткеи и рабочий цикл не запускались")
}
