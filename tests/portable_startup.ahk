#Requires AutoHotkey v2.0
#NoTrayIcon
#SingleInstance Off

; Run copies of the packaged files, never in the user's own folder.
if (A_Args.Length < 1 || A_Args.Length > 2 || (A_Args.Length = 2 && A_Args[2] != "--require-rust") || !FileExist(A_Args[1])) {
    FileAppend("Usage: AutoHotkey64.exe tests/portable_startup.ahk <path-to-FORMA.exe> [--require-rust]`n", "**", "UTF-8-RAW")
    ExitApp(2)
}
SplitPath(A_Args[1], , &sourceDir)
dll := (sourceDir != "" ? sourceDir : ".") "\forma_pixels.dll"
dll := FileExist(dll) ? dll : ""
if (!dll && A_Args.Length = 2) {
    FileAppend("FAIL: forma_pixels.dll is missing from the extracted package`n", "**", "UTF-8-RAW")
    ExitApp(1)
}
SetTitleMatchMode(3)
scenarios := dll ? ["clean", "upgrade", "exe-only", "invalid-dll"] : ["clean", "upgrade"]
for scenario in scenarios {
    code := TestPortableExe(A_Args[1], scenario, dll)
    if code
        ExitApp(code)
}
ExitApp(0)

TestPortableExe(source, scenario, dll) {
    pid := 0, code := 0
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
        backend := ""
        if dll {
            if (scenario = "clean" || scenario = "upgrade") {
                FileCopy(dll, folder "\forma_pixels.dll")
                backend := "Rust DLL (ABI 1)"
            } else {
                ; An unrelated working directory may contain even a valid DLL.
                ; FORMA must ignore it and keep working with just the EXE.
                FileCopy(dll, launchDir "\forma_pixels.dll")
                if (scenario = "invalid-dll")
                    FileAppend("Not a Windows DLL", folder "\forma_pixels.dll", "UTF-8-RAW")
                backend := "AutoHotkey (резерв)"
            }
        }
        legacy := scenario = "upgrade" ? SeedLegacyProfile(folder, ini, logPath) : 0
        savedLog := legacy ? legacy.log : ""
        ; Даже при ином рабочем каталоге данные должны оставаться рядом с EXE.
        Run('"' exe '" /ErrorStdOut=UTF-8', launchDir, , &pid)
        hwnd := WinWait("FORMA v" version[1] " — панель управления ahk_pid " pid, , 20)
        if !hwnd
            throw Error("Основное окно EXE не появилось")
        text := WaitForPortableLog(logPath, "Готов к работе: проверка окна и HUD", savedLog)
        for required in ["=== Запуск: FORMA v" version[1] " · EXE «FORMA.exe»", "DryRun (без нажатий)", "горячие клавиши:"]
            PortableCheck(InStr(text, required), "Нет записи в свежей части run.log: " required)
        CheckPortableLog(text)
        if backend
            PortableCheck(InStr(text, "Пиксельные сканы: " backend), "Бэкенд не подтверждён в журнале: " backend)
        if (backend && A_Args.Length = 2)
            PortableCheck(InStr(text, "Боевой скан: " backend), "Бэкенд боевого скана не подтверждён: " backend)

        win := "ahk_id " hwnd
        if legacy
            CheckLoadedLegacyProfile(win, text)
        ; Только кнопки тестового процесса. Игровые и глобальные клавиши не отправляются.
        ClickPortableButton(win, "Светлая")
        deadline := A_TickCount + 4000
        while (A_TickCount < deadline && IniRead(ini, "ui", "theme", "") != "light")
            Sleep(80)
        PortableCheck(IniRead(ini, "ui", "theme", "") = "light", "EXE не сохранил тему рядом с собой")

        ClickPortableButton(win, "Проверка запуска")
        report := WaitForPortableText(win, "Окно Fortnite:")
        for required in ["EXE · 64 бит", "DryRun: включён", "Сеанс: СТОП", "аварийный Esc: да", "run.log: найден", "forma.ini: найден"]
            PortableCheck(InStr(report, required), "Нет значения в сводке запуска: " required)
        if legacy
            PortableCheck(InStr(report, "Режим: AFK-очередь"), "Не загружен прежний режим в сводку")
        if backend
            PortableCheck(InStr(report, "Пиксельные сканы: " backend), "Бэкенд не указан в сводке: " backend)
        if (backend && A_Args.Length = 2)
            PortableCheck(InStr(report, "Боевой скан: " backend), "Бэкенд боевого скана не подтверждён: " backend)

        ClosePortableExe(pid)
        pid := 0
        text := FileRead(logPath, "UTF-8")
        CheckPortableLog(SubStr(text, StrLen(savedLog) + 1))
        PortableCheck(!FileExist(launchDir "\run.log") && !FileExist(launchDir "\forma.ini")
            , "Данные созданы в рабочем каталоге вместо папки EXE")
        if legacy {
            PortableCheck(SubStr(text, 1, StrLen(savedLog)) == savedLog, "Прежний журнал перезаписан")
            for path, data in legacy.files
                PortableCheck(FileExist(path) && FileGetSize(path) = data.size && FileRead(path, "UTF-8") == data.text
                    , "Прежний файл изменился или исчез: " data.name)
            for setting in legacy.ini {
                actual := IniRead(ini, setting[1], setting[2], "<missing>")
                PortableCheck(actual == setting[3], "Не сохранён раздел [" setting[1] "] " setting[2])
            }
            FileAppend("OK: FORMA " version[1] " EXE x64 upgrade · режим, таймеры, клавиши, статистика и прежние файлы"
                . (backend ? " · " backend : "") "`n", "*", "UTF-8-RAW")
        } else {
            FileAppend("OK: FORMA " version[1] " EXE x64 " scenario " · DryRun, сводка, локальные run.log и forma.ini"
                . (backend ? " · " backend : "") "`n", "*", "UTF-8-RAW")
        }
    } catch as e {
        FileAppend("FAIL (" scenario "): " e.Message " (line " e.Line ")`n" e.Stack "`n", "**", "UTF-8-RAW")
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

SeedLegacyProfile(folder, ini, logPath) {
    ; Синтетический профиль формата v11.0.11, без [ui], URL и флага автозапуска.
    settings := [["mode", "botMode", "queue"], ["mode", "dryRun", "1"], ["mode", "cloudGaming", "0"]
        , ["keys", "start", "F10"], ["keys", "dry", "^F9"], ["keys", "menu", "^F1"]
        , ["afk", "matchMaxMin", "17.25"], ["afk", "lobbyDelaySec", "37"], ["afk", "stopAfterMin", "77.5"]
        , ["afk", "maxRounds", "13"], ["afk", "macroInQueue", "0"]
        , ["stats", "totalRounds", "43"], ["stats", "totalRuntimeSec", "90061"], ["stats", "totalTokens", "7"]
        , ["stats", "totalChests", "121"], ["legacy", "keep", "forma-upgrade-fixture"]]
    for setting in settings
        IniWrite(setting[3], ini, setting[1], setting[2])
    FileAppend("=== Запуск: FORMA v11.0.11 (тестовый журнал) ===`nГотов к работе: проверка окна и HUD`n", logPath, "UTF-8")
    files := Map()
    for fixture in [["run.log.prev", "Предыдущий журнал FORMA (тест)`n"]
        , ["ЖЕТОН_НАЙДЕН.txt", "Старая находка FORMA (тест)`n"], ["macro.txt", "# FORMA-MACRO v1`n30|mv|1|0`n"]] {
        path := folder "\" fixture[1]
        FileAppend(fixture[2], path, "UTF-8")
        files[path] := {name:fixture[1], text:FileRead(path, "UTF-8"), size:FileGetSize(path)}
    }
    return {ini:settings, log:FileRead(logPath, "UTF-8"), files:files}
}

CheckLoadedLegacyProfile(win, text) {
    for required in ["режим: AFK-очередь (цикл матчей)", "старт/стоп F10 · DryRun ^F9", "меню ^F1 ·"
        , "Накопительная статистика: раундов 43 · наработка 1 д 1 ч 1 м · жетонов 7 · [E] 121 ("
        , "Загружен пользовательский маршрут macro.txt: 1 шагов"]
        PortableCheck(InStr(text, required), "Прежние данные не загружены: " required)
    ClickPortableButton(win, "Настройки")
    for value in ["17.25", "37", "77.5", "13"]
        WaitForPortableText(win, value, true)
    ClickPortableButton(win, "Находки")
    WaitForPortableText(win, "Всего: 7", true)
    WaitForPortableText(win, "Старая находка FORMA (тест)")
}

WaitForPortableLog(path, marker, savedLog) {
    deadline := A_TickCount + 8000
    while (A_TickCount < deadline) {
        if FileExist(path) {
            text := FileRead(path, "UTF-8")
            PortableCheck(SubStr(text, 1, StrLen(savedLog)) == savedLog, "Прежний журнал перезаписан при запуске")
            current := SubStr(text, StrLen(savedLog) + 1)
            if InStr(current, marker)
                return current
        }
        Sleep(80)
    }
    throw Error("Нет новой записи о готовности в run.log")
}

CheckPortableLog(text) {
    for unexpected in ["Не удалось открыть основную панель", "подготовка запуска", "[!!] ОШИБКА"
        , "НЕ назначены:", "Esc не назначен:"]
        PortableCheck(!InStr(text, unexpected), "Неожиданная запись: " unexpected)
}

ClickPortableButton(win, caption) {
    WinActivate(win)
    button := ControlGetHwnd(caption, win)
    SendMessage(0xF5, 0, 0, , "ahk_id " button) ; BM_CLICK
}

WaitForPortableText(win, expected, exact := false) {
    deadline := A_TickCount + 4000
    while (A_TickCount < deadline) {
        for control in WinGetControlsHwnd(win) {
            if !DllCall("user32\IsWindowVisible", "Ptr", control, "Int")
                continue
            text := ControlGetText(control)
            if (exact ? text == expected : InStr(text, expected))
                return text
        }
        Sleep(80)
    }
    throw Error("Нет текста в открытой панели: " expected)
}

ClosePortableExe(pid) {
    ; WM_CLOSE скрытого главного окна AHK вызывает OnExit, в отличие от
    ; закрытия видимой панели (она уходит в трей) и принудительного ProcessClose.
    hidden := DetectHiddenWindows(true)
    try {
        hwnd := WinExist("ahk_class AutoHotkey ahk_pid " pid)
        PortableCheck(hwnd, "Не найдено главное окно процесса для штатного выхода")
        PostMessage(0x10, 0, 0, , "ahk_id " hwnd)
    } finally DetectHiddenWindows(hidden)
    PortableCheck(!ProcessWaitClose(pid, 8), "Процесс не завершился штатно")
}

PortableCheck(ok, message) {
    if !ok
        throw Error(message, -1)
}
