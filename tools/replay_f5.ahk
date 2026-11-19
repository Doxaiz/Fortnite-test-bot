#Requires AutoHotkey v2.0
#NoTrayIcon
#Include ../fortnite_bot.ahk

; Только сохранённые BMP Ctrl+F5. Не запускает Init() и не читает forma.ini.
if (A_LineFile = A_ScriptFullPath)
    ExitApp(ReplayF5(A_Args))

ReplayF5(paths, stdout := "*", stderr := "**") {
    global FORMA_VERSION
    if (paths.Length < 1 || paths.Length > 32) {
        FileAppend("Укажите от 1 до 32 BMP из Ctrl+F5.`n", stderr, "UTF-8-RAW")
        return 2
    }
    failed := false
    for index, path in paths {
        SplitPath(path, &name)
        try {
            report := BuildCalibrationReport(ReadF5Bmp(path, index))
            text := "FORMA v" FORMA_VERSION " · F5 по сохранённому BMP · " name "`n"
                . "Настройки сборки по умолчанию, без замера движения и без ввода.`n"
            for line in report.lines
                text .= line "`n"
            FileAppend(text, stdout, "UTF-8-RAW")
        } catch as e {
            FileAppend("BMP #" index " (" name "): " e.Message "`n", stderr, "UTF-8-RAW")
            failed := true
        }
    }
    return failed ? 1 : 0
}

ReadF5Bmp(path, id := 1) {
    ; Узкий формат WriteCalibrationBmp: BITMAPINFOHEADER, 32-bit BI_RGB,
    ; top-down BGRX, без палитры и без дополнительных секций.
    if !RegExMatch(path, "i)\.bmp$")
        throw ValueError("нужен BMP, сохранённый Ctrl+F5")
    maxBytes := 128 * 1024 * 1024, header := Buffer(54)
    file := FileOpen(path, "r", "UTF-8-RAW")
    try {
        length := file.Length
        if (length < header.Size || length > header.Size + maxBytes || file.RawRead(header) != header.Size)
            throw ValueError("некорректный размер BMP")
        if (NumGet(header, 0, "UShort") != 0x4D42 || NumGet(header, 2, "UInt") != length
            || NumGet(header, 6, "UInt") != 0 || NumGet(header, 10, "UInt") != header.Size
            || NumGet(header, 14, "UInt") != 40 || NumGet(header, 26, "UShort") != 1
            || NumGet(header, 28, "UShort") != 32 || NumGet(header, 30, "UInt") != 0)
            throw ValueError("неподдерживаемый заголовок BMP; нужен 32-bit BI_RGB из Ctrl+F5")
        w := NumGet(header, 18, "Int"), h := -NumGet(header, 22, "Int")
        if (w < 2 || h < 2 || w > 8192 || h > 8192)
            throw ValueError("нужен BMP сверху вниз, размер от 2 до 8192 по каждой стороне")
        stride := w * 4, bytes := stride * h
        if (bytes > maxBytes || NumGet(header, 34, "UInt") != bytes || length != header.Size + bytes)
            throw ValueError("размер пикселей не совпадает с заголовком BMP")
        buf := Buffer(bytes)
        if (file.RawRead(buf) != bytes || file.Length != length)
            throw ValueError("неполные данные пикселей BMP")
    } finally {
        file.Close()
    }
    ; Файл не привязывается к окну, часам захвата или состоянию игрового цикла.
    return {w:w, h:h, stride:stride, buf:buf, captureId:id, hwnd:0, capturedAt:0, x:0, y:0
        , source:"сохранённый BMP (без захвата)"}
}
