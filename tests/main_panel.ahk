#Requires AutoHotkey v2.0
#NoTrayIcon
#Include ../fortnite_bot.ahk
#SingleInstance Off

; GUI integration only. No Init(), hotkeys, game ticks, or game window.
ExitApp(RunPanelTests())

RunPanelTests() {
    global CFG, ST, UI
    folder := A_Temp "\forma-panel-test-" ProcessExist() "-" A_TickCount
    code := 0
    try {
        PanelCheck(!UI.gui && !ST.running && !UI.hkKeys.Length, "#Include не запускает FORMA")
        DirCreate(folder)
        CFG.iniFile := folder "\forma.ini", CFG.logFile := folder "\run.log"
        CFG.tokenFile := folder "\ЖЕТОН_НАЙДЕН.txt"
        CFG.winTitle := "ahk_class FORMA_NoSuchWindow_ForPanelTest"
        CFG.winExe := "ahk_exe FORMA_NoSuchProcess_ForPanelTest.exe"
        CFG.hideFromCapture := false, CFG.cloudGaming := false, CFG.keepAwake := false
        CFG.webhookUrl := "", CFG.audioAlert := false
        CFG.webhookToken := false, CFG.webhookStop := false, CFG.webhookRound := false
        ; Старый INI без [ui] должен открываться с тёмной темой, не теряя параметры.
        IniWrite("queue", CFG.iniFile, "mode", "botMode")
        IniWrite(1, CFG.iniFile, "mode", "dryRun")
        IniWrite(1, CFG.iniFile, "mode", "teamSafe")
        IniWrite(17, CFG.iniFile, "afk", "matchMaxMin")
        IniWrite(25, CFG.iniFile, "afk", "lobbyDelaySec")
        IniWrite(75.5, CFG.iniFile, "afk", "stopAfterMin")
        IniWrite(7, CFG.iniFile, "afk", "maxRounds")
        IniWrite(43, CFG.iniFile, "afk", "squadGraceSec")
        IniWrite("F10", CFG.iniFile, "keys", "start")
        LoadSettings()
        SetDpiAware()
        SetWinDelay(0)
        BuildTrayMenu()
        BuildGui()
        ShowGui()
        FileAppend("DPI: " A_ScreenDPI " · scale: " UI.panel.scale "`n", "*", "UTF-8-RAW")
        for test in [TestPanelNavigation, TestPanelTheme, TestPanelSettings, TestPanelClock
            , TestPanelFinds, TestPanelActions, TestPanelStartupReport, TestPanelFallback] {
            test()
            FileAppend("OK: " test.Name "`n", "*", "UTF-8-RAW")
        }
        PanelCheck(!ST.running && !ST.held.Count && !UI.hkKeys.Length && !ST.captureSeq && !ST.hwnd
            , "панель не запустила ввод, захват или рабочие таймеры")
    } catch as e {
        FileAppend("FAIL: " e.Message " (line " e.Line ")`n" e.Stack "`n", "**", "UTF-8-RAW")
        code := 1
    } finally {
        try PanelRelease()
        for prop in ["afkGui", "keyGui", "extGui", "gui"] {
            try {
                if UI.%prop%
                    UI.%prop%.Destroy()
            }
        }
        try DirDelete(folder, true)
    }
    return code
}

PanelCheck(ok, description) {
    if !ok
        throw Error(description, -1)
}

PanelIsVisible(control) {
    return DllCall("user32\IsWindowVisible", "Ptr", control.Hwnd, "Int") != 0
}

PanelClick(control) {
    WinActivate("ahk_id " control.Gui.Hwnd)
    SendMessage(0xF5, 0, 0, control) ; BM_CLICK: только наш HWND
    Sleep(40)
}

PanelSelectView(name) {
    global UI
    PanelClick(UI.panel.nav[name])
    PanelCheck(UI.panel.view = name, "открыт раздел " name)
}

PanelPress(control, key) {
    WinActivate("ahk_id " control.Gui.Hwnd)
    control.Focus()
    SendMessage(0x100, key, 1, control)
    SendMessage(0x101, key, 0xC0000001, control)
    Sleep(40)
}

PanelType(control, value) {
    SendMessage(0xC, 0, StrPtr(value), control) ; WM_SETTEXT вызывает EN_CHANGE
    Sleep(40)
}

PanelChooseCombo(control, value) {
    control.Value := value
    id := DllCall("user32\GetDlgCtrlID", "Ptr", control.Hwnd, "Int")
    ; Choose/Value не генерирует событие. Шлём CBN_SELCHANGE, как при выборе.
    parent := DllCall("user32\GetParent", "Ptr", control.Hwnd, "Ptr")
    DllCall("user32\SendMessageW", "Ptr", parent, "UInt", 0x111, "UPtr", 0x10000 | id
        , "Ptr", control.Hwnd, "Ptr")
    Sleep(40)
}

TestPanelNavigation() {
    global CFG, UI
    p := UI.panel
    PanelCheck(UI.visible && p.view = "home" && PanelIsVisible(UI.ddMode), "главный обзор")
    PanelCheck(UI.ddMode.Value = 2 && UI.cbDry.Value && UI.cbTeam.Value && p.keys[1].Value = "F10"
        , "режим, тест, защита команды и переназначенная клавиша из старого INI")
    PanelCheck(!PanelIsVisible(UI.logEdit) && !PanelIsVisible(UI.findingsEdit), "другие страницы скрыты")
    WinGetClientPos(, , &w, &h, "ahk_id " UI.gui.Hwnd)
    PanelCheck(Abs(w - Round(p.w * p.scale)) <= 1 && Abs(h - Round(p.h * p.scale)) <= 1, "размер клиента соответствует DPI")
    WinGetPos(, , &outerW, &outerH, "ahk_id " UI.gui.Hwnd)
    MonitorGetWorkArea(MonitorGetPrimary(), &l, &t, &r, &b)
    PanelCheck(outerW <= r-l && outerH <= b-t, "панель помещается на рабочем столе")

    Log("пробная запись панели")
    UpdateUiStatus()
    PanelCheck(UI.logEdit.Value = "" && InStr(p.lastLog.Value, "пробная запись"), "скрытый журнал не рисуется, а обзор показывает последнее событие")
    PanelPress(p.nav["settings"], 0x20) ; Space: владелец рисует кнопку, но Win32 обрабатывает клавиши
    PanelCheck(p.view = "settings" && !PanelIsVisible(UI.ddMode) && PanelIsVisible(p.themes["dark"])
        && PanelIsVisible(UI.btnEmergency) && Number(p.timers[1].edit.Value) = CFG.matchMaxMin, "клавиатурный переход в настройки")
    for item in [[UI.btnAfk, "afkGui"], [UI.btnExt, "extGui"], [UI.btnKeys, "keyGui"]] {
        PanelClick(item[1])
        dialog := UI.%item[2]%
        PanelCheck(dialog && PanelIsVisible(dialog), "открывается существующий диалог " item[2])
        dialog.Hide()
    }
    PanelCheck(Number(UI.edMatchMin.Value) = CFG.matchMaxMin && UI.edStart.Value = CFG.hkStart, "диалоги читают текущую конфигурацию")
    PanelSelectView("home")
    PanelClick(p.detail)
    PanelCheck(UI.detailOpen && PanelIsVisible(UI.detailGui) && InStr(UI.status.Value, "СЕССИЯ"), "старая подробная сводка доступна")
    HidePanelStatus()
    PanelClick(p.openLog)
    PanelCheck(p.view = "log" && PanelIsVisible(UI.logEdit) && PanelIsVisible(UI.btnEmergency)
        && InStr(UI.logEdit.Value, "пробная запись панели"), "открытие журнала из обзора")
    Log("новое событие в открытом журнале")
    UpdateUiStatus()
    PanelCheck(InStr(UI.logEdit.Value, "новое событие"), "видимый журнал обновляется")
    PanelCheck(WinGetStyle("ahk_id " UI.logEdit.Hwnd) & 0x800, "журнал нельзя редактировать")
    disk := FileRead(CFG.logFile, "UTF-8")
    PanelClick(UI.gui["ClearView"])
    PanelCheck(InStr(UI.logEdit.Value, "Новых событий пока нет") && FileRead(CFG.logFile, "UTF-8") == disk
        , "очищается только экран, не run.log")
    Log("событие после очистки")
    UpdateUiStatus()
    PanelCheck(InStr(UI.logEdit.Value, "событие после очистки") && !InStr(UI.logEdit.Value, "пробная запись")
        , "после очистки новые события продолжают поступать")
}

TestPanelTheme() {
    global CFG, ST, UI
    PanelSelectView("settings")
    p := UI.panel
    PanelCheck(CFG.panelTheme = "dark" && UI.gui.BackColor = PanelPalette("dark").canvas, "без [ui] по умолчанию тёмная тема")
    ini := CFG.iniFile, mode := IniRead(ini, "mode"), keys := IniRead(ini, "keys"), afk := IniRead(ini, "afk")
    before := CFG.Clone(), state := ST.Clone(), window := UI.gui.Hwnd
    for theme in ["gray", "light", "dark", "gray"] {
        PanelClick(p.themes[theme])
        PanelCheck(CFG.panelTheme = theme && IniRead(ini, "ui", "theme") = theme
            && UI.gui.BackColor = PanelPalette(theme).canvas && UI.gui.Hwnd = window && p.view = "settings"
            , "тема меняется в текущем окне и сохраняется: " theme)
    }
    for key, value in before.OwnProps() {
        if (key != "panelTheme")
            PanelCheck(CFG.%key% = value, "тема не меняет CFG." key)
    }
    for key, value in state.OwnProps()
        PanelCheck(ST.%key% = value, "тема не меняет ST." key)
    PanelCheck(IniRead(ini, "mode") = mode && IniRead(ini, "keys") = keys && IniRead(ini, "afk") = afk
        , "сохраняется только оформление")
    CFG.iniFile := ini "\несуществующая папка\forma.ini"
    PanelClick(p.themes["light"])
    PanelCheck(CFG.panelTheme = "light" && InStr(UI.foot.Value, "не записалась")
        && IniRead(ini, "ui", "theme") = "gray", "при ошибке записи тема применяется, но не считается сохранённой")
    CFG.iniFile := ini
    PanelClick(p.themes["light"])
    PanelCheck(IniRead(ini, "ui", "theme") = "light" && !p.themeWarning, "выбор той же темы повторяет запись")
    UI.gui.Destroy()
    LoadSettings()
    BuildGui()
    ShowGui()
    PanelCheck(UI.gui.BackColor = PanelPalette("light").canvas, "новое окно читает сохранённую тему")
    IniWrite("invalid-theme", ini, "ui", "theme")
    LoadSettings()
    PanelCheck(CFG.panelTheme = "dark" && CFG.dryRun && CFG.botMode = "queue", "неизвестная тема не ломает старый INI")
    PanelClick(UI.panel.themes["gray"])
}

TestPanelSettings() {
    global CFG, ST, UI
    PanelSelectView("settings")
    p := UI.panel, ini := CFG.iniFile
    for i, value in [17, 25, 75.5, 7]
        PanelCheck(Number(p.timers[i].edit.Value) = value && p.timers[i].slider.Value = Round(value), "начальные значения таймера " i)
    configText := FileRead(ini)
    PanelType(p.timers[2].edit, "45")
    PanelCheck(p.timers[2].slider.Value = 45, "поле перемещает ползунок")
    PanelPress(p.timers[2].slider, 0x27) ; Right: изменение от самого trackbar
    PanelCheck(p.timers[2].edit.Value = 46 && CFG.lobbyDelaySec = 25 && FileRead(ini) == configText
        , "ползунок обновляет поле, но не применяет настройку без сохранения")
    PanelType(p.timers[1].edit, "?")
    PanelClick(p.saveTimers)
    PanelCheck(CFG.matchMaxMin = 17 && CFG.lobbyDelaySec = 25 && FileRead(ini) == configText
        && InStr(p.settingsNote.Value, "числа"), "ошибка значения отменяет все изменения")
    PanelType(p.timers[1].edit, "17,25")
    PanelType(p.timers[3].edit, "99.5")
    PanelType(p.timers[4].edit, "999")
    ST.running := true
    UpdateUiStatus()
    PanelCheck(!p.saveTimers.Enabled && !p.timers[1].slider.Enabled && !p.timers[3].edit.Enabled, "таймеры защищены во время сеанса")
    OnPanelSaveTimers()
    PanelCheck(FileRead(ini) == configText, "запрет записи работает и в обработчике")
    ST.running := false
    UpdateUiStatus()
    ShowAfkSettings()
    UI.edSquadGrace.Value := 52 ; черновик в другом диалоге
    HideAfkSettings()
    mode := IniRead(ini, "mode"), keys := IniRead(ini, "keys"), theme := IniRead(ini, "ui")
    PanelClick(p.saveTimers)
    PanelCheck(InStr(p.settingsNote.Value, "сохранены"), "подтверждение сохранения быстрых таймеров")
    for i, value in [17.25, 46, 99.5, 500] {
        timer := p.timers[i]
        PanelCheck(CFG.%timer.key% = value && Number(IniRead(ini, "afk", timer.key)) = value
            && Number(timer.edit.Value) = value && Number(UI.%timer.legacy%.Value) = value, "синхронизация таймера " timer.key)
    }
    PanelCheck(FileRead(ini) != configText && IniRead(ini, "mode") = mode && IniRead(ini, "keys") = keys
        && IniRead(ini, "ui") = theme && IniRead(ini, "afk", "squadGraceSec") = 43 && UI.edSquadGrace.Value = 52
        , "сохраняются только таймеры, черновик других настроек не перезаписывается")
    configText := FileRead(ini)
    PanelChooseCombo(p.coordPick, 3)
    PanelCheck(InStr(p.coordHint.Value, "2560 × 1440")
        && p.coordValues[1].Value = Round(CFG.playNormX*2560) "  /  " Round(CFG.playNormY*1440), "масштаб координат для пресета")
    PanelChooseCombo(p.coordPick, 5)
    PanelCheck(InStr(p.coordHint.Value, A_ScreenWidth " × " A_ScreenHeight), "масштаб для рабочего стола")
    PanelChooseCombo(p.coordPick, 6)
    PanelClick(p.refreshCoords)
    PanelCheck(InStr(p.coordHint.Value, "Нет окна") && p.coordValues[1].Value = Round(CFG.playNormX*CFG.coordRefW) "  /  " Round(CFG.playNormY*CFG.coordRefH)
        && FileRead(ini) == configText && !ST.hwnd, "без игры показана база, сам предпросмотр ничего не записывает")
    PanelChooseCombo(p.coordPick, 1)
}

TestPanelClock() {
    global CFG, ST, UI
    PanelSelectView("home")
    oldMode := CFG.botMode, oldLimit := CFG.matchMaxMin
    try {
        CFG.botMode := "queue", CFG.matchMaxMin := 2.5
        ST.running := false, ST.state := "MENU"
        UpdateUiStatus()
        PanelCheck(UI.panel.clockValue.Value = "02:30" && UI.panel.clockLabel.Value = "ЗАДАНО", "круг показывает заданный лимит, когда сеанс не начат")
        ST.running := true, ST.state := "GAME", ST.matchStartT := 500000
        clock := PanelMatchClock(575000)
        PanelCheck(clock.text = "01:15" && clock.percent = 50, "расчёт от ST.matchStartT по времени движка")
        clock := PanelMatchClock(650100)
        PanelCheck(clock.percent = 0 && clock.text = "00:00" && clock.label = "ЛИМИТ ИСТЁК", "нет отрицательного времени")
        ST.paused := true
        PanelCheck(PanelMatchClock(575000).text = "—", "не обещаем выход на паузе")
        ST.paused := false, ST.cancelHold := true
        PanelCheck(PanelMatchClock(575000).percent = 0, "задержка очереди")
        ST.cancelHold := false, ST.leaveActive := true
        PanelCheck(PanelMatchClock(575000).label = "ВЫХОД", "выход уже начался")
        ST.leaveActive := false
        CFG.matchMaxMin := 0
        PanelCheck(PanelMatchClock(575000).label = "БЕЗ ЛИМИТА", "0 не превращается в 12 минут")
        CFG.matchMaxMin := 2.5
        for mode in ["xp", "antiafk"] {
            CFG.botMode := mode
            PanelCheck(PanelMatchClock(575000).label = "НЕАКТИВЕН", "таймер матча не используется в " mode)
        }
    } finally {
        CFG.botMode := oldMode, CFG.matchMaxMin := oldLimit
        ST.running := false, ST.state := "UNKNOWN", ST.matchStartT := 0
        ST.paused := false, ST.cancelHold := false, ST.leaveActive := false
        UpdateUiStatus()
    }
}

TestPanelFinds() {
    global CFG, ST, UI
    PanelSelectView("finds")
    PanelCheck(UI.panel.view = "finds" && InStr(UI.findingsEdit.Value, "Записей пока нет")
        && !FileExist(CFG.tokenFile), "пустая история не создаёт файл")
    a := "2026-11-18 12:30:15  Жетон пиратского магазина (0.5, 0.4) (сессия: 1, всего: 8)"
    b := "2026-11-18 13:00:50  Баннер редкой находки (скин/машина/жетон) (сессия: 2, всего: 9)"
    FileAppend(a "`r`n" b "`r`n", CFG.tokenFile, "UTF-8")
    ST.tokensFound := 2, CFG.totalTokens := 9
    UpdateUiStatus()
    PanelCheck(UI.findingsEdit.Value == b "`n" a && UI.findingsSession.Value = "За сеанс: 2"
        && UI.findingsTotal.Value = "Всего: 9", "BOM, кириллица, порядок и отдельные счётчики")
    c := "2026-11-18 13:10:50  Ещё одна тестовая находка"
    FileAppend(c "`n", CFG.tokenFile, "UTF-8-RAW")
    UpdateUiStatus()
    PanelCheck(UI.findingsEdit.Value == c "`n" b "`n" a, "новая строка подхватывается и без смены счётчиков")
    FileDelete(CFG.tokenFile)
    payload := "", want := "", row := "  Жетон " Rep("я", 240)
    Loop 160 {
        payload .= Format("{:03}", A_Index) row "`n"
        if (A_Index > 80)
            want := Format("{:03}", A_Index) row "`n" want
    }
    FileAppend(payload, CFG.tokenFile, "UTF-8-RAW")
    PanelClick(UI.gui["FindRefresh"])
    PanelCheck(FileGetSize(CFG.tokenFile) > 48 * 1024 && UI.findingsEdit.Value == RTrim(want, "`n")
        && FileRead(CFG.tokenFile, "UTF-8") == payload, "большой журнал: до 80 последних строк без изменения файла")
    original := CFG.tokenFile
    CFG.tokenFile := A_Temp ; Каталог нельзя открыть как файл.
    PanelClick(UI.gui["FindRefresh"])
    PanelCheck(InStr(UI.findingsEdit.Value, "Не удалось прочитать"), "ошибка файла показана в панели")
    CFG.tokenFile := original
    PanelSelectView("home")
    p := UI.panel
    PanelCheck(p.homeFound.Value = "Сеанс: 2" && p.homeTotal.Value = "Всего: 9" && p.resetFinds.Enabled
        , "лента обзора показывает те же реальные счётчики")
    CFG.totalRounds := 13, ST.rounds := 3
    PanelClickReset(p.resetFinds, 7) ; IDNO
    PanelCheck(CFG.totalTokens = 9 && ST.tokensFound = 2, "сброс можно отменить")
    PanelClickReset(p.resetFinds, 6) ; IDYES
    PanelCheck(!CFG.totalTokens && !ST.tokensFound && CFG.totalRounds = 13 && ST.rounds = 3
        && IniRead(CFG.iniFile, "stats", "totalTokens") = "0" && FileRead(CFG.tokenFile, "UTF-8") == payload
        && p.homeTotal.Value = "Всего: 0" && !p.resetFinds.Enabled, "сброс только счётчиков находок, история и раунды сохранены")
}

PanelClickReset(control, answer) {
    reply := PanelAnswerReset.Bind(answer)
    SetTimer(reply, 90)
    PanelClick(control)
    Sleep(300)
    SetTimer(reply, 0)
}

PanelAnswerReset(answer) {
    dialog := WinExist("FORMA — сброс находок ahk_class #32770 ahk_pid " ProcessExist())
    if !dialog
        return
    button := DllCall("user32\GetDlgItem", "Ptr", dialog, "Int", answer, "Ptr")
    if button {
        ; Ответ штатной кнопкой MsgBox, не глобальной эмуляцией ввода.
        PostMessage(0xF5, 0, 0, , "ahk_id " button)
        SetTimer(, 0)
    }
}

TestPanelActions() {
    global CFG, ST, UI
    PanelSelectView("home")
    PanelChooseCombo(UI.ddMode, 4)
    PanelCheck(CFG.botMode = "xp" && IniRead(CFG.iniFile, "mode", "botMode") = "xp", "выбор режима дошёл до старого обработчика")
    PanelClick(UI.btnStart)
    PanelCheck(!ST.running && InStr(FileRead(CFG.logFile, "UTF-8"), "старт отменён: окно не найдено"), "Старт отказывает без игры")
    ST.running := true, ST.cancelHold := true
    UpdateUiStatus()
    PanelCheck(!UI.btnStart.Enabled && UI.btnStop.Enabled && UI.btnCont.Enabled, "состояние кнопок при ожидании очереди")
    PanelClick(UI.btnPause)
    PanelCheck(ST.paused && UI.btnPause.Text = "Снять паузу", "пауза общего сеанса")
    PanelClick(UI.btnPause)
    PanelCheck(!ST.paused && UI.btnPause.Text = "Пауза", "снятие паузы")
    PanelClick(UI.cbDry)
    PanelCheck(!CFG.dryRun && ST.paused, "смена DryRun требует ручного продолжения, как прежде")
    PanelClick(UI.cbDry)
    PanelCheck(CFG.dryRun && ST.paused, "DryRun восстановлен; пауза не снялась")
    PanelClick(UI.btnCont)
    PanelCheck(!ST.cancelHold && ST.paused, "возобновление очереди не снимает общую паузу")
    PanelClick(UI.btnPause)
    PanelSelectView("settings")
    PanelClick(UI.cbBg)
    PanelCheck(CFG.bgMode && ST.paused && CFG.dryRun, "смена фонового ввода по-прежнему ставит на паузу")
    PanelClick(UI.cbBg)
    PanelCheck(!CFG.bgMode && ST.paused, "отключение фонового ввода не снимает паузу")
    PanelClick(UI.cbTeam)
    PanelCheck(!CFG.teamSafe && CFG.dryRun && ST.paused, "переключатель команды на вкладке настроек")
    PanelClick(UI.cbTeam)
    PanelCheck(CFG.teamSafe, "защита команды восстановлена")
    PanelSelectView("log")
    PanelClick(UI.btnEmergency)
    PanelCheck(!ST.running && UI.btnEmergency.Enabled && InStr(UI.logEdit.Value, "СТОП (аварийный стоп)")
        , "аварийный стоп доступен и из журнала")
}

TestPanelStartupReport() {
    global CFG, ST, UI
    p := UI.panel, logPath := CFG.logFile, webhook := CFG.webhookUrl
    ; Сводка проверяет наличие файлов, но не читает историю и не копирует настройки.
    Log("ПРИВАТНЫЙ_МАРКЕР_В_ЖУРНАЛЕ")
    beforeLog := FileRead(logPath, "UTF-8"), beforeIni := FileRead(CFG.iniFile)
    CFG.webhookUrl := "TEST_PRIVATE_URL_NOT_FOR_REPORT"
    savedClipboard := ClipboardAll()
    try {
        PanelSelectView("startup")
        report := p.startupReport.Value
        for expected in [FormaTitle(), "AHK · " (A_PtrSize*8) " бит", "DryRun: включён", "Окно Fortnite: не найдено"
            , "run.log: найден", "forma.ini: найден", "аварийный Esc: нет"]
            PanelCheck(InStr(report, expected), "поле сводки: " expected)
        PanelCheck(PanelIsVisible(p.startupReport) && (WinGetStyle("ahk_id " p.startupReport.Hwnd) & 0x800)
            && !PanelIsVisible(UI.logEdit) && p.startupLog.Enabled, "сводка только для чтения, журнал доступен")
        for private in [logPath, CFG.iniFile, CFG.webhookUrl, "ПРИВАТНЫЙ_МАРКЕР_В_ЖУРНАЛЕ"]
            PanelCheck(!InStr(report, private), "сводка не захватывает пути, webhook или содержание журнала")
        PanelClick(UI.gui["StartupCopy"])
        PanelCheck(StrReplace(A_Clipboard, "`r") == StrReplace(report, "`r") && InStr(p.startupNote.Value, "скопирована")
            , "в буфере точно показанный текст")
        CFG.logFile := logPath ".missing"
        PanelClick(UI.gui["StartupRefresh"])
        PanelCheck(InStr(p.startupReport.Value, "run.log: не найден") && !p.startupLog.Enabled && !FileExist(CFG.logFile)
            , "обновление указывает на отсутствие файла и не создаёт его")
        PanelCheck(FileRead(logPath, "UTF-8") == beforeLog && FileRead(CFG.iniFile) == beforeIni
            && !ST.running && !ST.captureSeq && !ST.hwnd, "сводка не пишет настройки и не захватывает кадр")
    } finally {
        CFG.logFile := logPath, CFG.webhookUrl := webhook
        A_Clipboard := savedClipboard
    }
}

TestPanelFallback() {
    global UI, ST
    selected := UI.panel.view, win := UI.gui.Hwnd
    PostMessage(0x10, 0, 0, UI.gui) ; WM_CLOSE
    Sleep(50)
    PanelCheck(!UI.visible && !PanelIsVisible(UI.gui), "закрытие прячет панель")
    ToggleGui() ; Тот же обработчик, который используется клавишей меню и в трее.
    PanelCheck(UI.visible && UI.gui.Hwnd = win && UI.panel.view = selected, "возврат из трея сохраняет вкладку")
    BuildGuiFallback("тест недоступности основной панели")
    ShowGui()
    Log("проверка упрощённой панели")
    WinGetClientPos(, , &w, &h, "ahk_id " UI.gui.Hwnd)
    PanelCheck(UI.visible && !UI.panel && !ST.running && Abs(w - Round(444 * A_ScreenDPI / 96)) <= 1
        && Abs(h - Round(394 * A_ScreenDPI / 96)) <= 1 && InStr(UI.logEdit.Value, "упрощённой панели")
        , "резервное окно имеет собственный размер и рабочий журнал")
    ToggleGui()
    PanelCheck(!UI.visible, "упрощённую панель можно скрыть")
    ToggleGui()
    PanelCheck(UI.visible && PanelIsVisible(UI.gui), "упрощённая панель возвращается из трея")
}
