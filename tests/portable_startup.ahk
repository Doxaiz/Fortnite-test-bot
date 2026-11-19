#Requires AutoHotkey v2.0
#NoTrayIcon
#SingleInstance Off

; Проверяет именно EXE. Копия запускается без скрипта, настроек и ресурсов рядом.
ExitApp(TestPortableExe())

TestPortableExe() {
    if (A_Args.Length != 1 || !FileExist(A_Args[1])) {
        FileAppend("Usage: AutoHotkey64.exe tests/portable_startup.ahk <path-to-FORMA.exe>`n", "**", "UTF-8-RAW")
        return 2
    }
    source := A_Args[1], pid := 0, code := 0
    folder := A_Temp "\FORMA тест EXE " ProcessExist() "-" A_TickCount
    logPath := folder "\run.log", ini := folder "\forma.ini"
    try {
        if !RegExMatch(FileGetVersion(source), "^(\d+\.\d+\.\d+)\.0$", &version)
            throw Error("У FORMA.exe нет ожидаемой версии файла")
        DirCreate(folder)
        exe := folder "\FORMA.exe"
        FileCopy(source, exe)
        Run('"' exe '" /ErrorStdOut=UTF-8', folder, , &pid)
        target := "FORMA v" version[1] " — панель управления ahk_pid " pid
        hwnd := WinWait(target, , 15)
        if !hwnd
            throw Error("Основное окно EXE не появилось")
        deadline := A_TickCount + 8000, text := ""
        while (A_TickCount < deadline) {
            if FileExist(logPath)
                text := FileRead(logPath, "UTF-8")
            if InStr(text, "Готов к работе: проверка окна и HUD")
                break
            Sleep(80)
        }
        for required in ["EXE «FORMA.exe»", "DryRun (без нажатий)", "горячие клавиши:", "Готов к работе: проверка окна и HUD"] {
            if !InStr(text, required)
                throw Error("Нет записи в run.log: " required)
        }
        for unexpected in ["Не удалось открыть основную панель", "подготовка запуска", "[FATAL]"] {
            if InStr(text, unexpected)
                throw Error("Неожиданная запись: " unexpected)
        }
        ; Только кнопка оформления нашего процесса. Никаких игровых клавиш.
        win := "ahk_id " hwnd
        button := ControlGetHwnd("Светлая", win)
        WinActivate(win)
        SendMessage(0xF5, 0, 0, , "ahk_id " button) ; BM_CLICK
        deadline := A_TickCount + 4000
        while (A_TickCount < deadline && IniRead(ini, "ui", "theme", "") != "light")
            Sleep(80)
        if (IniRead(ini, "ui", "theme", "") != "light")
            throw Error("EXE не сохранил настройки рядом с собой")
        FileAppend("OK: FORMA " version[1] " EXE · DryRun · панель · локальные run.log и forma.ini`n", "*", "UTF-8-RAW")
    } catch as e {
        FileAppend("FAIL: " e.Message " (line " e.Line ")`n" e.Stack "`n", "**", "UTF-8-RAW")
        code := 1
    } finally {
        if pid && ProcessExist(pid) {
            try ProcessClose(pid)
            try ProcessWaitClose(pid, 5)
        }
        try DirDelete(folder, true)
    }
    return code
}
