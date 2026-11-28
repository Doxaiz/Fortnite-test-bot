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
        for test in [TestPanelNavigation, TestPanelJournal, TestPanelTheme, TestPanelSettings, TestPanelCoordinates
            , TestPanelClock, TestPanelAutoStop, TestPanelFinds, TestPanelActions, TestPanelStartupReport, TestPanelFallback] {
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
    global CFG, ST, UI
    p := UI.panel
    PanelCheck(UI.visible && p.view = "home" && PanelIsVisible(UI.ddMode), "главный обзор")
    PanelCheck(UI.ddMode.Value = 2 && UI.cbDry.Value && UI.cbTeam.Value && p.keys[1].Value = "F10"
        , "режим, тест, защита команды и переназначенная клавиша из старого INI")
    PanelCheck(!PanelIsVisible(UI.logEdit) && !PanelIsVisible(UI.findingsEdit) && !PanelIsVisible(UI.btnCheck)
        && UI.btnStart.Text = "Старт · F10", "на обзоре только основные действия и актуальная клавиша")
    WinGetClientPos(, , &w, &h, "ahk_id " UI.gui.Hwnd)
    PanelCheck(Abs(w - Round(p.w * p.scale)) <= 1 && Abs(h - Round(p.h * p.scale)) <= 1, "размер клиента соответствует DPI")
    WinGetPos(, , &outerW, &outerH, "ahk_id " UI.gui.Hwnd)
    MonitorGetWorkArea(MonitorGetPrimary(), &l, &t, &r, &b)
    PanelCheck(outerW <= r-l && outerH <= b-t, "панель помещается на рабочем столе")
    CheckPanelSessionRow([UI.btnStart, UI.btnPause, UI.btnStop, UI.btnCont, p.detail, UI.btnBypass], w, h)
    CheckPanelSessionRow([UI.ddMode, UI.cbDry, p.homeCheck], w, h)
    ini := FileRead(CFG.iniFile), log := FileExist(CFG.logFile) ? FileRead(CFG.logFile) : ""
    PanelCheck(PanelIsVisible(p.homeCheck) && InStr(p.inputLabel.Value, "БЕЗ ВВОДА"), "проверка запуска и состояние DryRun на обзоре")
    PanelClick(p.homeCheck)
    PanelCheck(p.view = "startup" && PanelIsVisible(p.startupReport) && !PanelIsVisible(p.homeCheck)
        && !ST.running && !ST.hwnd && !ST.captureSeq && !ST.held.Count && FileRead(CFG.iniFile) == ini
        && (FileExist(CFG.logFile) ? FileRead(CFG.logFile) : "") == log, "переход к сводке не запускает сеанс, ввод или захват")
    PanelSelectView("home")

    Log("запись вне превью")
    Log("пробная запись панели")
    Log("средняя строка & детали`nпродолжение многострочного события")
    Log("последняя строка обзора")
    UpdateUiStatus()
    PanelCheck(UI.logEdit.Value = "" && InStr(p.homeLogRows[1].Value, "последняя строка")
        && InStr(p.homeLogRows[2].Value, "строка & детали …") && !InStr(p.homeLogRows[2].Value, "продолжение")
        && InStr(p.homeLogRows[3].Value, "пробная запись"), "три последних события в обзоре, скрытый журнал не рисуется")
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
    PanelSelectView("home")
    PanelCheck(p.homeLogRows[1].Value = "Новых событий пока нет." && p.homeLogRows[2].Value = "" && p.homeLogRows[3].Value = ""
        , "очистка журнала также освобождает предпросмотр обзора")
    PanelSelectView("log")
    Log("событие после очистки")
    UpdateUiStatus()
    PanelCheck(InStr(UI.logEdit.Value, "событие после очистки") && !InStr(UI.logEdit.Value, "пробная запись")
        , "после очистки новые события продолжают поступать")
}

CheckPanelSessionRow(row, clientW, clientH) {
    ; Фактические координаты Win32 после масштабирования, а не копия сетки.
    right := 0
    for ctrl in row {
        ctrl.GetPos(&x, &y, &w, &h)
        PanelCheck(PanelIsVisible(ctrl) && x >= right && y >= 0 && x + w <= clientW && y + h <= clientH
            , "кнопки и режим помещаются на обзоре без перекрытия по X")
        right := x + w
    }
}

TestPanelJournal() {
    global CFG, ST, UI, LogBuf
    PanelSelectView("log")
    p := UI.panel, ini := FileRead(CFG.iniFile)
    PanelClick(UI.gui["ClearView"])
    PanelCheck(p.logLive.Value && !p.logReset.Enabled && p.logScope.Value = "Показано: 0 из 0"
        && UI.logEdit.Value = "Новых событий пока нет.", "журнал открывается с живым обновлением и без фильтра")
    Log("[input] Ожидание окна`nПодробности [ПРОВЕРКА+1]")
    Log("[perf] Время захвата")
    UpdateUiStatus()
    first := LogBuf[1], disk := FileRead(CFG.logFile, "UTF-8")
    PanelType(p.logSearch, SubStr(first, 1, 8))
    PanelCheck(InStr(UI.logEdit.Value, first), "поиск находит отображаемое время события")
    PanelType(p.logSearch, "  [проверка+1]  ")
    PanelCheck(p.logScope.Value = "Показано: 1 из 2" && p.logReset.Enabled
        , "поиск не зависит от регистра кириллицы и пробелов по краям: " p.logScope.Value)
    PanelCheck(UI.logEdit.Value == first "`n", "поиск сохраняет многострочное событие целиком")
    PanelType(p.logSearch, ".*")
    PanelCheck(UI.logEdit.Value = "По запросу ничего не найдено." && p.logScope.Value = "Показано: 0 из 2"
        && FileRead(CFG.logFile, "UTF-8") == disk && LogBuf.Length = 2, "запрос буквальный, фильтр ничего не записывает")

    PanelType(p.logSearch, "проверка+1")
    SendMessage(0xB1, 2, 11, UI.logEdit) ; EM_SETSEL
    Log("[perf] Новое событие без совпадения")
    UpdateUiStatus()
    PanelCheck(UI.logEdit.Value == first "`n" && p.logScope.Value = "Показано: 1 из 3"
        && SendMessage(0xB0, 0, 0, UI.logEdit) = (11 << 16 | 2), "несовпадающая запись не сбрасывает выделение")
    Log("[input] Живое совпадение: проверка+1")
    UpdateUiStatus()
    PanelCheck(InStr(UI.logEdit.Value, "Живое совпадение") && p.logScope.Value = "Показано: 2 из 4"
        , "новые совпадения появляются в открытом фильтре")

    PanelPress(p.logLive, 0x20)
    frozen := UI.logEdit.Value
    Log("[input] После фиксации: проверка+1")
    UpdateUiStatus()
    disk := FileRead(CFG.logFile, "UTF-8")
    PanelCheck(!p.logLive.Value && UI.logEdit.Value == frozen && InStr(p.logScope.Value, "2 из 4")
        && InStr(p.logScope.Value, "Просмотр зафиксирован") && InStr(disk, "После фиксации")
        , "пауза с клавиатуры удерживает список и не останавливает журнал на диске")
    PanelSelectView("home")
    PanelCheck(InStr(p.homeLogRows[1].Value, "После фиксации"), "обзор по-прежнему показывает новое событие")
    PanelSelectView("log")
    HideGui()
    ShowGui()
    PanelCheck(!p.logLive.Value && p.logSearch.Value = "проверка+1" && UI.logEdit.Value == frozen
        && PanelIsVisible(UI.btnEmergency), "пауза и запрос сохраняются при переходах между разделами и скрытии окна")
    PanelClick(p.logReset)
    PanelCheck(p.logSearch.Focused && p.logSearch.Value = "" && !p.logReset.Enabled
        && InStr(UI.logEdit.Value, "Время захвата") && !InStr(UI.logEdit.Value, "После фиксации")
        && InStr(p.logScope.Value, "4 из 4"), "сброс только запроса показывает весь зафиксированный список")
    PanelClick(p.logLive)
    PanelCheck(p.logLive.Value && InStr(UI.logEdit.Value, "После фиксации") && p.logScope.Value = "Показано: 5 из 5"
        && FileRead(CFG.logFile, "UTF-8") == disk && FileRead(CFG.iniFile) == ini && !ST.running && !ST.paused
        , "возврат к живому списку не меняет профиль, журнал или состояние сеанса")

    Loop 300
        Log("Тест предела журнала " A_Index)
    UpdateUiStatus()
    PanelType(p.logSearch, "После фиксации")
    PanelCheck(p.logScope.Value = "Показано: 0 из 300" && LogBuf.Length = 300
        && InStr(FileRead(CFG.logFile, "UTF-8"), "После фиксации"), "поиск ограничен буфером, а не файлом run.log")
    PanelClick(p.logLive)
    disk := FileRead(CFG.logFile, "UTF-8")
    PanelClick(UI.gui["ClearView"])
    PanelCheck(!p.logLive.Value && p.logSearch.Value = "После фиксации" && UI.logEdit.Value = "Новых событий пока нет."
        && InStr(p.logScope.Value, "0 из 0") && !LogBuf.Length && FileRead(CFG.logFile, "UTF-8") == disk
        , "очистка экрана очищает и зафиксированный список, но не запрос и не файл")
    PanelClick(p.logReset)
    PanelClick(p.logLive)
    Log("Событие после очистки зафиксированного списка")
    UpdateUiStatus()
    PanelCheck(p.logScope.Value = "Показано: 1 из 1" && InStr(UI.logEdit.Value, "Событие после очистки зафиксированного списка")
        , "после очистки новые записи снова видны")
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

TestPanelCoordinates() {
    global CFG, ST, UI
    PanelSelectView("settings")
    p := UI.panel, ini := FileRead(CFG.iniFile), log := FileRead(CFG.logFile, "UTF-8"), before := CFG.Clone()
    PanelChooseCombo(p.coordPick, 7)
    PanelCheck(InStr(p.coordHint.Value, "показана база"), "пустой свой размер не считается рассчитанным")
    for value in ["1600x900", " 1600 X 900 ", "1600 × 900", "1600 х 900"] {
        PanelType(p.coordSize, value)
        PanelClick(p.coordCalc)
        PanelCheck(p.coordPick.Value = 7 && p.coordSize.Value = "1600 × 900"
            && InStr(p.coordHint.Value, "1600 × 900") && !p.coordError.Value, "свой размер: " value)
        for i, point in [[CFG.playNormX, CFG.playNormY], [CFG.optNormX, CFG.optNormY], [CFG.leaveNormX, CFG.leaveNormY]]
            PanelCheck(p.coordValues[i].Value = Round(point[1] * 1600) "  /  " Round(point[2] * 900), "пересчитана точка " i)
    }
    for value in ["", "0x900", "-1x900", "1.5x900", "900", "20000x900", "1600x900 тест"] {
        PanelType(p.coordSize, value)
        PanelClick(p.coordCalc)
        PanelCheck(InStr(p.coordError.Value, "Введите") && p.coordPick.Value = 7 && InStr(p.coordHint.Value, "1600 × 900")
            , "неверный размер не меняет предыдущий расчёт: " value)
    }
    PanelClick(p.coordDesktop)
    size := A_ScreenWidth " × " A_ScreenHeight
    PanelCheck(p.coordPick.Value = 5 && p.coordSize.Value = size && InStr(p.coordHint.Value, size) && !p.coordError.Value
        , "кнопка использует реальный размер экрана")
    PanelChooseCombo(p.coordPick, 7)
    PanelCheck(p.coordSize.Value = "1600 × 900" && InStr(p.coordHint.Value, "1600 × 900"), "свой размер восстанавливается в поле")
    for key, value in before.OwnProps()
        PanelCheck(CFG.%key% == value, "предпросмотр не меняет CFG." key)
    PanelCheck(FileRead(CFG.iniFile) == ini && FileRead(CFG.logFile, "UTF-8") == log && !ST.hwnd && !ST.captureSeq
        , "подгонка не сохраняет профиль, не захватывает игру и не пишет журнал")
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

TestPanelAutoStop() {
    global CFG, ST, UI
    PanelSelectView("home")
    p := UI.panel, saved := CFG.stopAfterMin, elapsed := ST.sessionActiveSec
    try {
        CFG.stopAfterMin := 0
        UpdateUiStatus()
        PanelCheck(p.stopTime.Value = "Без лимита", "отключённый автостоп")
        CFG.stopAfterMin := 2.5
        UpdateUiStatus()
        PanelCheck(p.stopTime.Value = "02:30" && InStr(p.stopNote.Value, "после старта"), "лимит до запуска")
        ST.running := true, ST.sessionActiveSec := 60
        UpdateUiStatus()
        PanelCheck(p.stopTime.Value = "01:30" && p.elapsed.Value = "00:01:00", "отсчёт от активного времени движка")
        ST.paused := true
        UpdateUiStatus()
        PanelCheck(p.stopTime.Value = "01:30" && InStr(p.stopNote.Value, "на паузе"), "на паузе отсчёт отмечен как замороженный")
        ST.paused := false, ST.sessionActiveSec := 151
        UpdateUiStatus()
        PanelCheck(p.stopTime.Value = "00:00" && InStr(p.stopNote.Value, "достигнут"), "отсчёт не уходит в минус")
        ST.finishMatchArmed := true
        UpdateUiStatus()
        PanelCheck(p.stopTime.Value = "Доигрываю" && InStr(p.stopNote.Value, "после матча"), "видна отложенная остановка")
    } finally {
        CFG.stopAfterMin := saved, ST.sessionActiveSec := elapsed
        ST.running := false, ST.paused := false, ST.finishMatchArmed := false
        UpdateUiStatus()
    }
}

TestPanelFinds() {
    global CFG, ST, UI
    PanelSelectView("home")
    p := UI.panel, filters := p.findingsButtons, shortcuts := p.homeFindingsButtons
    PanelCheck(shortcuts["token"].control.Text = "Жетоны · 0" && InStr(p.homeFindingsHint.Value, "80 СТРОК")
        && !FileExist(CFG.tokenFile), "на обзоре пустая история не создаёт файл")
    PanelSelectView("finds")
    PanelCheck(p.view = "finds" && InStr(UI.findingsEdit.Value, "Записей пока нет") && filters["all"].control.Text = "Все · 0"
        && !FileExist(CFG.tokenFile), "пустая история не создаёт файл")
    a := "2026-11-18 12:30:15  Жетон пиратского магазина (0.5, 0.4) (сессия: 1, всего: 8)"
    b := "2026-11-18 13:00:50  Баннер редкой находки (скин/машина/жетон) (сессия: 2, всего: 9)"
    FileAppend(a "`r`n" b "`r`n", CFG.tokenFile, "UTF-8")
    ST.tokensFound := 2, CFG.totalTokens := 9
    UpdateUiStatus()
    PanelCheck(UI.findingsEdit.Value == b "`n" a && UI.findingsSession.Value = "За сеанс: 2"
        && UI.findingsTotal.Value = "Всего: 9", "BOM, кириллица, порядок и отдельные счётчики")
    for kind, expected in Map("all", "Все · 2", "token", "Жетоны · 1", "banner", "Редкие баннеры · 1", "other", "Прочие записи · 0")
        PanelCheck(filters[kind].control.Text == expected, "количество в хвосте: " kind)
    ini := FileRead(CFG.iniFile)
    PanelClick(filters["other"].control)
    PanelCheck(InStr(UI.findingsEdit.Value, "В выбранной категории нет записей") && InStr(p.findingsScope.Value, "0 из 2")
        , "пустая категория отличается от пустого файла")
    PanelClick(filters["banner"].control)
    PanelCheck(UI.findingsEdit.Value == b && InStr(p.findingsScope.Value, "1 из 2"), "баннер не смешивается с жетоном")
    c := "2026-11-18 13:10:50  Ещё одна тестовая находка"
    d := "2026-11-18 13:20:50  Жетон пиратского магазина (без координат) (сессия: 9, всего: 99)"
    FileAppend(c "`n" d "`n", CFG.tokenFile, "UTF-8-RAW")
    UpdateUiStatus()
    PanelCheck(UI.findingsEdit.Value == b && p.findingsFilter = "banner" && InStr(p.findingsScope.Value, "1 из 4")
        , "новые записи обновляют выборку без сброса текущего фильтра")
    history := FileRead(CFG.tokenFile, "UTF-8")
    PanelClick(filters["other"].control)
    PanelCheck(UI.findingsEdit.Value == d "`n" c, "неизвестная и неполная записи остаются в истории")
    PanelClick(filters["token"].control)
    PanelCheck(UI.findingsEdit.Value == a, "видны только штатные сигналы о жетоне")
    PanelSelectView("home")
    PanelSelectView("finds")
    PanelCheck(UI.findingsEdit.Value == a && p.findingsFilter = "token", "выбор сохраняется при переходе между вкладками")
    PanelClick(filters["all"].control)
    PanelCheck(UI.findingsEdit.Value == d "`n" c "`n" b "`n" a && FileRead(CFG.tokenFile, "UTF-8") == history
        && FileRead(CFG.iniFile) == ini && ST.tokensFound = 2 && CFG.totalTokens = 9
        , "фильтры не меняют историю, профиль или общие счётчики")

    PanelSelectView("home")
    for kind, item in shortcuts
        PanelCheck(item.control.Text == filters[kind].control.Text, "на обзоре то же количество недавних записей: " kind)
    PanelPress(shortcuts["banner"].control, 0x20)
    PanelCheck(p.view = "finds" && p.findingsFilter = "banner" && UI.findingsEdit.Value == b && PanelIsVisible(UI.btnEmergency)
        , "быстрая кнопка открывает историю на нужной категории, в том числе с клавиатуры")
    PanelSelectView("home")
    at := p.findingsOverviewAt
    e := "2026-11-18 13:30:50  Жетон пиратского магазина (0, 1) (сессия: 3, всего: 10)"
    FileAppend(e "`n", CFG.tokenFile, "UTF-8-RAW")
    PanelRefreshHomeFindings(at + 1199)
    PanelCheck(shortcuts["token"].control.Text = "Жетоны · 1", "обзор не читает хвост при каждом обновлении панели")
    PanelRefreshHomeFindings(at + 1200)
    PanelCheck(shortcuts["token"].control.Text = "Жетоны · 2" && p.homeTotal.Value = "9", "новая запись видна отдельно от общих счётчиков")
    PanelClick(shortcuts["token"].control)
    PanelCheck(p.view = "finds" && p.findingsFilter = "token" && UI.findingsEdit.Value == e "`n" a
        , "открытая категория показывает тот же хвост в порядке от новых к старым")
    PanelSelectView("home")
    PanelClick(p.homeFindingsHistory)
    PanelCheck(p.view = "finds" && p.findingsFilter = "all" && UI.findingsEdit.Value == e "`n" d "`n" c "`n" b "`n" a
        && FileRead(CFG.tokenFile, "UTF-8") == history e "`n" && FileRead(CFG.iniFile) == ini
        , "«История» открывает все записи, быстрые переходы ничего не записывают")
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
        && filters["other"].control.Text = "Прочие записи · 80" && InStr(p.findingsScope.Value, "80 из 80")
        && FileRead(CFG.tokenFile, "UTF-8") == payload, "большой журнал: до 80 последних строк без изменения файла")
    original := CFG.tokenFile
    CFG.tokenFile := A_Temp ; Каталог нельзя открыть как файл.
    PanelClick(UI.gui["FindRefresh"])
    PanelCheck(InStr(UI.findingsEdit.Value, "Не удалось прочитать") && filters["all"].control.Text = "Все · —"
        && UI.findingsTotal.Value = "Всего: 9", "ошибка файла не выдаёт устаревшие числа и не меняет счётчик")
    PanelSelectView("home")
    PanelCheck(shortcuts["other"].control.Text = "Прочие записи · —" && p.homeFindingsHint.Value = "ИСТОРИЯ НЕДОСТУПНА"
        , "обзор тоже отличает ошибку чтения от нуля записей")
    CFG.tokenFile := original
    PanelSelectView("finds")
    PanelSelectView("home")
    PanelCheck(p.homeFound.Value = "2" && p.homeTotal.Value = "9" && p.resetFinds.Enabled
        , "лента обзора показывает те же реальные счётчики")
    CFG.totalRounds := 13, ST.rounds := 3
    PanelClickReset(p.resetFinds, 7) ; IDNO
    PanelCheck(CFG.totalTokens = 9 && ST.tokensFound = 2, "сброс можно отменить")
    PanelClickReset(p.resetFinds, 6) ; IDYES
    PanelCheck(!CFG.totalTokens && !ST.tokensFound && CFG.totalRounds = 13 && ST.rounds = 3
        && IniRead(CFG.iniFile, "stats", "totalTokens") = "0" && FileRead(CFG.tokenFile, "UTF-8") == payload
        && p.homeTotal.Value = "0" && !p.resetFinds.Enabled, "сброс только счётчиков находок, история и раунды сохранены")
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
    PanelCheck(!CFG.dryRun && ST.paused && UI.panel.inputLabel.Value = "РЕАЛЬНЫЙ ВВОД"
        , "смена DryRun видна на обзоре и требует ручного продолжения, как прежде")
    PanelClick(UI.cbDry)
    PanelCheck(CFG.dryRun && ST.paused && InStr(UI.panel.inputLabel.Value, "БЕЗ ВВОДА"), "DryRun восстановлен; пауза не снялась")
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
        for control in [UI.btnCheck, UI.btnCal, UI.btnVision, UI.btnHud, UI.btnHelp, UI.btnEmergency]
            PanelCheck(PanelIsVisible(control), "диагностика и аварийный стоп доступны в проверке запуска")
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
