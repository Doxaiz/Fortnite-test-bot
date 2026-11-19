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
    scratch := A_Temp "\FORMA тест EXE " ProcessExist() "-" A_TickCount
    folder := scratch "\portable", launchDir := scratch "\working-dir"
    logPath := folder "\run.log", ini := folder "\forma.ini"
    try {
        if !RegExMatch(FileGetVersion(source), "^(\d+\.\d+\.\d+)\.0$", &version)
            throw Error("У FORMA.exe нет ожидаемой версии файла")
        DirCreate(folder)
        DirCreate(launchDir)
        exe := folder "\FORMA.exe"
        FileCopy(source, exe)
        ; Даже при ином рабочем каталоге данные должны оставаться рядом с EXE.
        Run('"' exe '" /ErrorStdOut=UTF-8', launchDir, , &pid)
        target := "FORMA v" version[1] " — панель управления ahk_pid " pid
        hwnd := WinWait(target, , 20)
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
        for unexpected in ["Не удалось открыть основную панель", "подготовка запуска", "[!!] ОШИБКА"
            , "НЕ назначены:", "Esc не назначен:"] {
            if InStr(text, unexpected)
                throw Error("Неожиданная запись: " unexpected)
        }
        ; Только кнопки нашего процесса. Никаких игровых клавиш.
        win := "ahk_id " hwnd
        button := ControlGetHwnd("Светлая", win)
        WinActivate(win)
        SendMessage(0xF5, 0, 0, , "ahk_id " button) ; BM_CLICK
        deadline := A_TickCount + 4000
        while (A_TickCount < deadline && IniRead(ini, "ui", "theme", "") != "light")
            Sleep(80)
        if (IniRead(ini, "ui", "theme", "") != "light")
            throw Error("EXE не сохранил настройки рядом с собой")
        button := ControlGetHwnd("Проверка запуска", win)
        SendMessage(0xF5, 0, 0, , "ahk_id " button)
        deadline := A_TickCount + 4000, report := ""
        while (A_TickCount < deadline && report = "") {
            for control in WinGetControlsHwnd(win) {
                if !DllCall("user32\IsWindowVisible", "Ptr", control, "Int")
                    continue
                value := ControlGetText(control)
                if InStr(value, "Окно Fortnite:") {
                    report := value
                    break
                }
            }
            if (report = "")
                Sleep(80)
        }
        for required in ["EXE · 64 бит", "DryRun: включён", "Сеанс: СТОП", "аварийный Esc: да", "run.log: найден", "forma.ini: найден"] {
            if !InStr(report, required)
                throw Error("Нет значения в сводке запуска: " required)
        }
        if (FileExist(launchDir "\run.log") || FileExist(launchDir "\forma.ini"))
            throw Error("Данные созданы в рабочем каталоге вместо папки EXE")
        if InStr(FileRead(logPath, "UTF-8"), "[!!] ОШИБКА")
            throw Error("Ошибка при открытии сводки запуска")
        FileAppend("OK: FORMA " version[1] " EXE x64 · DryRun · сводка · локальные run.log и forma.ini`n", "*", "UTF-8-RAW")
    } catch as e {
        FileAppend("FAIL: " e.Message " (line " e.Line ")`n" e.Stack "`n", "**", "UTF-8-RAW")
        ; Выводим только ошибки запуска из изолированного журнала теста.
        try {
            for line in StrSplit(FileRead(logPath, "UTF-8"), "`n", "`r") {
                if RegExMatch(line, "Не удалось открыть основную панель|\[!!\] ОШИБКА|НЕ назначены:|Esc не назначен:")
                    FileAppend(line "`n", "**", "UTF-8-RAW")
            }
        }
        code := 1
    } finally {
        if pid && ProcessExist(pid) {
            try ProcessClose(pid)
            try ProcessWaitClose(pid, 5)
        }
        try DirDelete(scratch, true)
    }
    return code
}
