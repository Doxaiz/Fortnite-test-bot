#Requires AutoHotkey v2.0
#NoTrayIcon
#Include ../tools/evaluate_vision.ahk
#SingleInstance Off

; Интеграционный тест: отдельный процесс рисует HWND и считает WM_KEYDOWN/UP.
; Init() не вызывается; ввод разрешается только для двух известных тестовых окон.
if (A_Args.Length = 2 && A_Args[1] = "--receiver") {
    ServeReceiver(A_Args[2])
    return
}
ExitApp(RunWindowTests())

RunWindowTests() {
    global CFG, ST
    stem := A_Temp "\forma-window-test-" ProcessExist() "-" A_TickCount
    CFG.logFile := stem ".log", CFG.iniFile := stem ".ini"
    CFG.winTitle := "ahk_class FORMA_NoSuchWindow_ForTest"
    CFG.winExe := "ahk_exe FORMA_NoSuchProcess_ForTest.exe"
    CFG.cloudGaming := false, CFG.smartRestore := false, CFG.bgMode := true, CFG.dryRun := true
    CFG.botMode := "auto", CFG.keepAwake := false, CFG.audioAlert := false
    CFG.webhookStop := false, CFG.webhookRound := false
    for name in ["featCombat", "featLoot", "featMove", "featWeaponPick", "featReward", "featToken"
        , "featPlayAgain", "featAutoQueue", "featParkour", "featSound", "featFightBack", "featHeal", "featProStyle"
        , "featFirstSlot", "featReload", "featHarvest", "squadAutoLeave", "sprint"]
        CFG.%name% := false
    CFG.featChest := true, CFG.teamSafe := false
    CFG.promptScanMs := 0, CFG.promptEcooldownMs := 0
    CFG.fwdMinMs := 8000, CFG.fwdMaxMs := 8000
    tag := "FORMA fixture " ProcessExist() " " A_TickCount
    pid := 0, code := 0
    try {
        Check(!UI.gui && !ST.running, "#Include не запускает рабочий интерфейс")
        SetDpiAware()
        SetWinDelay(0)
        Run('"' A_AhkPath '" /ErrorStdOut=UTF-8 "' A_ScriptFullPath '" --receiver "' tag '"', , , &pid)
        a := WinWait(tag " A ahk_pid " pid, , 6)
        b := WinWait(tag " B ahk_pid " pid, , 6)
        Check(a && b && a != b, "два окна отдельного процесса")
        ST.running := true, ST.state := "GAME", ST.phase := "roam", ST.matchStarted := true
        ST.matchStartT := A_TickCount
        SelectFixture(a)
        Check(!WinActive("ahk_id " a) && !WinActive("ahk_id " b), "приёмники неактивны")
        CFG.dryRun := false
        for test in [TestPromptRoundTrip, TestMinimizedMove, TestWindowHandoff, TestActualFocus, TestCapturedBody
            , TestSavedWindowFrame, TestPatrolLease, TestGuidedRecovery, TestChestFallback, TestCombatRetreat
            , TestResultBlink, TestReturnOnlyResults, TestRepeatedPrompt, TestStaticFallback, TestSlowChestRoundTrip
            , TestGuidedLaneBypass, TestGuidedLipHop, TestGuidedRecoveryRecheck, TestPatrolHudLease, TestChestSoundLease] {
            test(a, b)
            FileAppend("OK: " test.Name "`n", "*", "UTF-8")
        }
    } catch as e {
        FileAppend("FAIL: " e.Message " (line " e.Line ")`n", "**", "UTF-8")
        code := 1
    } finally {
        ST.running := false
        try ReleaseKeysSafe()
        if pid
            try ProcessClose(pid)
        for ext in [".log", ".ini"]
            try FileDelete(stem ext)
    }
    return code
}

TestPromptRoundTrip(a, b) {
    global ST, SC
    SetFixtureFrame(a, 1)
    first := TickFixture(a)
    Check(ReadInteractPrompt(first) && ST.promptConfirm.hits = 1 && !ST.promptN, "первая плашка: доставлять E рано")
    ExpectKey(a, SC.e, 0, 0)
    second := TickFixture(a)
    Check(second.captureId > first.captureId && ST.promptN = 1 && ST.held.Has(SC.e)
        && ST.held[SC.e].target = a, "вторая плашка запустила E")
    ExpectKey(a, SC.e, 1, 0)
    ExpectKey(a, SC.e, 1, 1, 2000)
    ExpectKey(b, SC.e, 0, 0)
    Check(!ST.held.Has(SC.e) && !ST.chests, "отпускание не считается открытием сундука")
    Check(ST.tickProfile.capture = second.captureTiming && second.captureTiming.attempts.Length >= 1
        && InStr(TickProfileText(ST.tickProfile), second.captureTiming.attempts[1].method), "замер захвата относится к тику")
    stats := CaptureHistoryLines(a)
    Check(stats.Length = 1 && InStr(stats[1], "480x288") && InStr(stats[1], "/ фон · n=2 frame=2")
        && !CaptureHistoryLines(b).Length, "оба завершённых захвата учтены только для выбранного HWND")
    FileAppend("  захват 480×288: " second.source "`n", "*", "UTF-8")
}

TestMinimizedMove(a, b) {
    global CFG, ST, SC
    CFG.featChest := false, CFG.featMove := true
    SetFixtureFrame(a, 0)
    shot := TickFixture(a)
    ExpectKey(a, SC.w, 1, 0)
    Check(ST.held.Has(SC.w) && ST.held[SC.w].target = a && ST.segUntil > A_TickCount, "W удерживается до сворачивания")
    untilWalk := ST.segUntil, epoch := ST.inputEpoch, started := ST.matchStartT
    WinMinimize("ahk_id " a)
    minimizeBy := A_TickCount + 1000
    while (WinGetMinMax("ahk_id " a) != -1) {
        Check(A_TickCount < minimizeBy, "тестовое окно не свернулось")
        Sleep(10)
    }
    Tick()
    Check(A_TickCount < untilWalk && !ST.held.Count && !ST.segUntil && !WorldFrameCurrent(shot)
        , "сворачивание прервало W до конца отрезка")
    Check(ST.state = "GAME" && ST.matchStartT = started && ST.inputEpoch = epoch + 1
        , "сменилось поколение ввода, не матч")
    Check(!KeyDown(SC.w), "новое W запрещено, пока окно свёрнуто")
    ExpectKey(a, SC.w, 1, 1)
    ExpectKey(b, SC.w, 0, 0)
    Tick()
    Check(ST.inputEpoch = epoch + 1 && !ST.held.Count, "нет повторного сброса без кадра")
    CFG.featMove := false
    ; SW_SHOWNOACTIVATE: WinRestore может заодно активировать окно.
    DllCall("user32\ShowWindow", "Ptr", a, "Int", 4)
    SetFixtureFrame(a, 0)
    TickFixture(a)
    Check(!ST.playInputSuspended, "получен новый кадр после восстановления")
}

TestWindowHandoff(a, b) {
    global CFG, ST, SC
    CFG.featChest := true, CFG.chestHoldMs := 1100
    SetFixtureFrame(a, 1)
    TickFirstPrompt(a)
    old := TickFixture(a)
    Check(ST.tgt && ST.held.Has(SC.e), "E удерживается в A перед сменой окна")
    deadline := ST.tgt.until
    ExpectKey(a, SC.e, 2, 1)

    SelectFixture(b)
    CFG.chestHoldMs := 2000
    SetFixtureFrame(b, 1)
    fresh := TickFirstPrompt(b)
    Check(A_TickCount < deadline && fresh.inputEpochAtCapture > old.inputEpochAtCapture
        && !WorldFrameCurrent(old), "смена HWND до дедлайна отменила старое удержание и кадр")
    ExpectKey(a, SC.e, 2, 2)
    ExpectKey(b, SC.e, 0, 0)
    TickFixture(b)
    ExpectKey(b, SC.e, 1, 0)
    holdB := ST.held[SC.e]
    Check(holdB.target = b && ST.tgt.until > deadline + 250, "новое E принадлежит B и имеет более поздний дедлайн")
    Sleep(Max(0, deadline + 120 - A_TickCount))
    Check(ST.held.Has(SC.e) && ST.held[SC.e] = holdB, "дедлайн A не оборвал удержание B")
    ExpectKey(b, SC.e, 1, 0)
    ExpectKey(b, SC.e, 1, 1, 2400)
    ExpectKey(a, SC.e, 2, 2)
}

TestActualFocus(a, b) {
    global CFG, ST, SC
    SelectFixture(a)
    SetFixtureFrame(a, 1)
    TickFirstPrompt(a)
    TickFixture(a)
    ExpectKey(a, SC.e, 3, 2)
    deadline := ST.tgt.until, epoch := ST.inputEpoch, lastE := ST.lastPromptE
    ; Меняем реальный фокус, но новых системных down тест не делает.
    CFG.dryRun := true
    for h in [a, b]
        WinSetExStyle("-0x08000000", "ahk_id " h)
    FocusFixture(a)
    before := TickFirstPrompt(a)
    Check(A_TickCount < deadline && ST.inputEpoch = epoch + 1, "переход фон → фокус снял старое E")
    ExpectKey(a, SC.e, 3, 3)

    CFG.bgMode := false
    FocusFixture(b)
    TickFixture(a)
    Check(!WorldFrameCurrent(before) && !ST.promptConfirm.hits && ST.playInputSuspended
        , "реальная потеря фокуса сбросила первый кадр подсказки")
    Check(ST.lastPromptE = lastE && ST.state = "GAME" && ST.promptAttempts.Length = 4
        , "сцена, счётчик и ограничение новых попыток E сохранены")
    FocusFixture(a)
    TickFirstPrompt(a)
    Check(ST.lastPromptE = lastE, "первый кадр после возврата не разрешает E")
    TickFixture(a)
    Check(InStr(ST.lastAction, "DryRun: E") && ST.promptN = 4, "второй кадр разрешает только DryRun")
    ExpectKey(a, SC.e, 3, 3)
    ExpectKey(b, SC.e, 1, 1)
}

TestCapturedBody(a, b) {
    global CFG, ST, VIS
    Check(CFG.dryRun && WinActive("ahk_id " a), "бой тестируется только в DryRun")
    CFG.featChest := false, CFG.featCombat := true, CFG.featMotionEnemy := true
    CFG.enemyFastMs := 0, CFG.aimReactMs := 0, CFG.skinWideMs := 60000
    ResetCaches()
    ST.scanWideAt := A_TickCount, ST.stepBoost := 0
    SetFixtureFrame(a, 2)
    TickFixture(a)
    ; Переход из прошлого сценария может дать движение. Проверяем сводку
    ; только по следующим четырём измеренным кадрам, без прогрева.
    ST.capHistory := 0
    shot := TickFixture(a)
    Check(!shot.enemyReading && !ST.enemySeenSeq && !ST.shots && !ST.leftDown
        && shot.combatTrace.status = "negative", "два кадра с опорой и красным прицелом без фигуры не запускают бой")
    BuildVisionGui() ; проверяем подпись и отрисовку, не показывая окно поверх приёмника
    try {
        SetFixtureFrame(a, 3)
        shot := TickFixture(a)
        Check(shot.enemyReading && shot.enemyReading.src = "движение" && !ST.enemySeenSeq && !ST.shots
            && shot.combatTrace.status = "candidate" && shot.combatTrace.attempt.hits = 1
            && shot.combatTrace.attempt.raw = shot.enemyReading && shot.combatTrace.pass = "fast"
            , "захваченный первый кандидат виден, но ещё не подтверждён")
        DrawVisionFrame()
        Check(VIS.lastId = shot.captureId && InStr(VIS.txt.Value, "первый: движение"), "F3 показывает первый замер на этом кадре")
        SetFixtureFrame(a, 4)
        shot := TickFixture(a)
        Check(ST.enemySeenSeq = shot.captureId && ST.enemySrc = "движение" && ST.shots = 1
            && shot.combatTrace.status = "confirmed" && shot.combatTrace.attempt.hits = 2
            && !ST.leftDown && !ST.adsOn && !ST.held.Count
            , "тот же цвет прицела, второй кадр фигуры → виртуальная очередь без мыши")
        DrawVisionFrame()
        Check(VIS.lastId = shot.captureId && InStr(VIS.txt.Value, "повтор: движение"), "F3 показывает подтверждение")
        SetFixtureFrame(a, 2)
        shot := TickFixture(a)
        Check(!shot.enemyReading && ST.enemySeenSeq != shot.captureId && ST.shots = 1
            , "пустое место под тем же прицелом не подтверждает фигуру")
        DrawVisionFrame()
        Check(InStr(VIS.txt.Value, "кандидата нет"), "F3 не переносит рамку на кадр с одной опорой")
        report := BuildCalibrationReport(shot)
        reasonShown := false
        for line in report.lines
            if InStr(line, "фигура: нет: плотное тёплое пятно, рамка растянута фоном")
                reasonShown := true
        Check(reasonShown, "F5 отвергает опору на том же захваченном кадре и объясняет причину")
    } finally {
        VisionHide()
        VIS.gui.Destroy()
        VIS.gui := 0
    }
}

TestSavedWindowFrame(a, b) {
    global CFG, ST, SC
    Check(CFG.dryRun && GetGameWindow() = a, "экспорт проверяется на выбранном тестовом окне")
    SetFixtureFrame(a, 1)
    live := ST.lastShot, epoch := ST.inputEpoch, lastTiming := ST.tickProfile.capture
    history := ST.capHistory, next := history.next, stats := CaptureHistoryLines(a)
    scanLine := stats.Length >= 2 ? stats[2] : "нет строки"
    Check(stats.Length = 2 && InStr(stats[1], "[capture-stats] 480x288") && InStr(scanLine, "[scan-stats] 480x288")
        && InStr(scanLine, "DryRun / фокус · n=4 attempted=4") && InStr(scanLine, "negative=2")
        && InStr(scanLine, "candidate=1") && InStr(scanLine, "confirmed=1")
        , "сканы четырёх кадров тестового HWND до снимков F7 и Ctrl+F5: " scanLine)
    ready := ST.dryPair
    pair := SnapshotDryPair(&why := "")
    Check(pair && pair.current = live && pair.previous.captureId < live.captureId
        && pair.tick = ST.tickProfile.gen && pair.gap >= 0 && ST.tickProfile.combatTrace = live.combatTrace
        && InStr(TickProfileText(ST.tickProfile), CombatTraceText(live.combatTrace))
        , "снимок берёт два соседних тика и их собственные замеры без захвата: " why)
    SelectFixture(b)
    Check(!SnapshotDryPair(&why) && InStr(why, "изменились"), "снимок прежнего окна не выдаётся")
    SelectFixture(a)
    seq := ST.captureSeq
    shot := CaptureCalibrationFrame()
    Check(shot && shot.hwnd = a && shot.captureId > live.captureId && shot.source != ""
        && shot.captureTiming != lastTiming && ST.tickProfile.capture = lastTiming && live.captureTiming = lastTiming
        , "отдельный захват экспорта не переписывает время рабочего кадра")
    folder := A_Temp "\forma-window-export-" ProcessExist() "-" A_TickCount
    try {
        saved := SaveCalibrationPair(shot, folder)
        report := FileRead(saved.txt, "UTF-8")
        Check(FileGetSize(saved.bmp) = 54 + shot.buf.Size && InStr(report, "плашка E: кандидат")
            && InStr(report, "кадр #" shot.captureId) && InStr(report, "источник: " shot.source)
            && InStr(report, CaptureTimingText(shot.captureTiming))
            , "на диске кадр GDI, его замер захвата и отчёт о плашке")
        OnCheckCapture()
        ToolTip()
        logText := FileRead(CFG.logFile, "UTF-8")
        for line in stats
            Check(InStr(logText, line), "F7 выводит статистику тиков в журнал")
        Check(ST.capHistory = history && history.next = next && InStr(logText, "[capture] " lastTiming.w "×" lastTiming.h)
            , "снимки F7 и Ctrl+F5 не добавляются к статистике цикла")
        Check(ST.dryPair = ready && ST.captureSeq = seq + 2, "только одиночные пробные захваты увеличили captureId")
        TestDryPairBundle(pair, folder)
        Check(ST.dryPair = ready && ST.lastShot = live && ST.inputEpoch = epoch && !ST.held.Count
            && ST.captureSeq = seq + 2, "пара и одиночный кадр не подменяют рабочий снимок и не дают ввода")
        ExpectKey(a, SC.e, 3, 3)
        ExpectKey(b, SC.e, 1, 1)
    } finally {
        try DirDelete(folder, true)
    }
}

TestDryPairBundle(pair, root) {
    saved := SaveDryPair(pair, root)
    for item in [["previous", pair.previous], ["current", pair.current]] {
        frame := ReadF5Bmp(saved.folder "\" item[1] ".bmp"), original := item[2]
        Check(frame.w = original.w && frame.h = original.h && frame.buf.Size = original.buf.Size
            && !DllCall("msvcrt\memcmp", "Ptr", frame.buf, "Ptr", original.buf, "UPtr", frame.buf.Size, "CDecl Int")
            , item[1] " состоит из исходных пикселей рабочего кадра")
    }
    report := FileRead(saved.folder "\report.txt", "UTF-8")
    Check(InStr(report, "Тик #" pair.tick) && InStr(report, "previous.bmp · кадр #" pair.previous.captureId)
        && InStr(report, "current.bmp · кадр #" pair.current.captureId) && InStr(report, "Возраст current при запросе: " pair.age)
        && InStr(report, CaptureTimingText(pair.current.captureTiming)) && !InStr(report, root)
        && InStr(report, CombatTraceText(pair.previous.combatTrace)) && InStr(report, CombatTraceText(pair.current.combatTrace))
        && InStr(report, "золотая группа кольца: нет замера на этом кадре")
        , "отчёт цитирует замеры кадров и не пересканирует звук при экспорте")
    manifest := saved.folder "\vision.tsv", raw := FileRead(manifest, "UTF-8")
    unlabelled := false
    try ReadVisionSet(manifest)
    catch ValueError
        unlabelled := true
    Check(unlabelled && InStr(raw, "`tcurrent.bmp`tprevious.bmp`t?"), "разметка не подставляется за пользователя")
    duplicate := false
    try SaveDryPair(pair, root)
    catch as e
        duplicate := InStr(e.Message, "Не удалось опубликовать")
    Check(duplicate && !DirExist(saved.folder ".partial") && FileRead(manifest, "UTF-8") == raw
        , "конечный каталог не заменяется; временный убран при отказе")
    label := saved.folder "\labelled.tsv"
    FileAppend(StrReplace(raw, "`t?", "`tnone"), label, "UTF-8")
    batch := ReadVisionSet(label), result := ReadVisionCase(batch.dir, batch.rows[1], false)
    Check(result.pair && result.w = pair.current.w && result.h = pair.current.h, "после разметки файлы подходят офлайн-оценщику")
}

TestPatrolLease(a, b) {
    global CFG, ST, SC
    FocusFixture(a), SelectFixture(b)
    CFG.bgMode := true, CFG.dryRun := false, CFG.featMove := true
    CFG.featCombat := false, CFG.featChest := false, CFG.featParkour := true, CFG.sprint := true
    CFG.navScanMs := 0, CFG.patrolHoldMs := 1200
    ResetNavigation()
    SetFixtureFrame(b, 0)
    TickFixture(b)
    ExpectKey(b, SC.w, 1, 0)
    ExpectKey(b, SC.shift, 0, 0)
    TickFixture(b)
    Check(ST.sprintOn && ST.navInfo.hits = 2, "два открытых кадра ускоряют наземный шаг")
    ExpectKey(b, SC.shift, 1, 0)

    SetFixtureFrame(b, 5)
    TickFixture(b)
    Check(!ST.sprintOn && ST.navInfo.kind = "lip" && ST.navInfo.hits = 1
        , "при первом крае убираем спринт, но ещё не прыгаем")
    ExpectKey(b, SC.shift, 1, 1)
    ExpectKey(b, SC.space, 0, 0)
    TickFixture(b)
    Check(ST.navInfo.jumped && ST.held.Has(SC.w), "прыжок подтверждён, прямая ходьба не рвётся")
    ExpectKey(b, SC.space, 1, 0)
    ExpectKey(b, SC.space, 1, 1, 600)
    TickFixture(b)
    ExpectKey(b, SC.space, 1, 1)
    stepEnds := ST.segUntil
    ; Больше нет тиков: отпускание не зависит от распознавания и нового кадра.
    ExpectKey(b, SC.w, 1, 1, 2200)
    Check(A_TickCount < stepEnds && !ST.held.Count, "W отпущена таймером раньше конца отрезка")
    SetFixtureFrame(b, 0)
    TickFixture(b)
    ExpectKey(b, SC.w, 2, 1)
    ExpectKey(b, SC.shift, 1, 1)
    beforePause := TickFixture(b)
    ExpectKey(b, SC.shift, 2, 1)
    OnPause()
    Check(ST.paused && !WorldFrameCurrent(beforePause) && !ST.held.Count, "пауза снимает новый W/Shift и старый кадр")
    ExpectKey(b, SC.w, 2, 2)
    ExpectKey(b, SC.shift, 2, 2)
    OnPause()
    Check(!ST.paused && !WorldFrameCurrent(beforePause), "снятие паузы требует нового кадра")
    ExpectKey(a, SC.w, 1, 1)
    ExpectKey(a, SC.shift, 0, 0)
    ExpectKey(a, SC.space, 0, 0)
}

TestGuidedRecovery(a, b) {
    global CFG, ST, SC
    CFG.featChest := true, CFG.featParkour := false, CFG.sprint := false, CFG.scanLootMs := 0
    CFG.stuckSampleMs := 150, CFG.stuckMs := 260, CFG.stuckRecoveryMs := 900
    ResetCaches()
    ST.navTurnSign := 1
    SetFixtureFrame(b, 6)
    TickFixture(b)
    Check(ST.walkTarget && ST.walkTarget.samples.hits = 1, "на кадре видно свечение")
    ExpectKey(b, SC.w, 2, 2)
    TickFixture(b)
    Check(ST.lastAction = "объект у прицела: жду подсказку", "свечение у прицела не запускает E")
    TickFixture(b)
    Check(ST.guidedUntil && !ST.segUntil && ST.held.Has(SC.w), "повтор цели запускает короткий направленный шаг")
    ExpectKey(b, SC.w, 3, 2)
    Loop 10 {
        TickFixture(b)
        if ST.stuckRecoverUntil
            break
        Sleep(70)
    }
    Check(ST.stuckRecoverKey = SC.d && ST.held.Has(SC.d) && !ST.held.Has(SC.w)
        && ST.guidedUntil > ST.stuckRecoverUntil
        , "на обходе W отпущена; после шага оставляем время на новый замер цели")
    ExpectKey(b, SC.w, 3, 3)
    ExpectKey(b, SC.d, 1, 0)
    TickFixture(b)
    ExpectKey(b, SC.w, 3, 3)
    SetFixtureFrame(b, 1)
    TickFixture(b)
    Check(ST.promptConfirm.hits = 1 && !ST.stuckRecoverUntil, "появилась подсказка: обход прерывается")
    ExpectKey(b, SC.d, 1, 1)
    ExpectKey(b, SC.e, 1, 1)
}

TestChestFallback(a, b) {
    global CFG, ST, SC
    CFG.dryRun := true, CFG.featChest := true
    ResetCaches()
    SetFixtureFrame(b, 9)
    shot := TickFixture(b)
    Check(ST.chestCacheSeq = shot.captureId && ST.chest.x < shot.w * 0.6 && ST.walkTarget.samples.hits = 1
        , "на первом реальном кадре выбирается яркое свечение у центра")
    ST.walkTarget.at := A_TickCount - 8001
    TickFixture(b)
    Check(ST.chestSkips.Length = 1 && !ST.walkTarget, "срок подхода исключает только этот центр")
    shot := TickFixture(b)
    Check(ST.chestCacheSeq = shot.captureId && ST.chest.x > shot.w * 0.6 && ST.walkTarget.samples.hits = 1
        , "на следующем захвате того же вида читается другой кандидат")
    TickFixture(b)
    Check(ST.walkTarget.samples.hits = 2 && ST.lastAction = "к свечению сундука" && !ST.tgt && !ST.held.Count
        , "сосед подтверждён независимо; DryRun не нажимает E и не двигает мышь")
    ExpectKey(b, SC.w, 3, 3)
    ExpectKey(b, SC.e, 1, 1)
}

TestCombatRetreat(a, b) {
    global CFG, ST, SC
    Check(CFG.dryRun && CFG.bgMode && GetGameWindow() = b && !WinActive("ahk_id " b)
        , "боевое решение только в DryRun; позднее A только в тестовом фоне")
    CFG.featCombat := true, CFG.featProStyle := true, CFG.featChest := false, CFG.featMove := true
    CFG.featMotionEnemy := true, CFG.enemyFastMs := 0, CFG.skinWideMs := 60000, CFG.aimReactMs := 0
    ; На кадре 480 px реальная полоса <42% короче общего порога 70 px.
    hudRun := CFG.hudDetectRun, CFG.hudDetectRun := 26
    CFG.navScanMs := 0, CFG.proRetreatMs := 600
    ResetCaches()
    ResetNavigation()
    ST.hpPrev := -1, ST.damagedAt := 0, ST.retreatAt := 0, ST.prevShot := 0
    ST.phase := "roam", ST.queuePending := false, ST.cancelHold := false
    ST.scanWideAt := A_TickCount, ST.cameraAt := 0, ST.stepBoost := 0
    shots := ST.shots
    try {
        SetFixtureFrame(b, 13)
        TickFixture(b)
        Check(ST.hpPercent = 100 && ST.navInfo.side = -1 && !ST.navInfo.sideStable && !ST.retreat
            , "полная полоса HP и первая оценка боковых полос в окне")
        SetFixtureFrame(b, 14)
        first := TickFixture(b)
        Check(first.enemyReading && ST.enemySeenSeq != first.captureId && ST.damagedAt = first.capturedAt
            && ST.hpPercent >= 0 && ST.hpPercent < CFG.proRetreatHp && !ST.retreat && ST.shots = shots
            , "падение HP и первый замер фигуры ещё не разрешают шаг или очередь")
        SetFixtureFrame(b, 15)
        second := TickFixture(b)
        Check(ST.enemySeenSeq = second.captureId && ST.navInfo.sideStable && ST.navInfo.seq = second.captureId
            && ST.retreat.key = SC.a && !ST.retreat.hold && ST.shots = shots && !ST.leftDown && !ST.held.Count
            , "на повторе выбираем только боковой шаг в DryRun")
        step := ST.retreat, deadline := step.until
        newer := TickFixture(b)
        Check(ST.retreat = step && step.until = deadline && !newer.HasOwnProp("enemyReading") && ST.shots = shots
            , "ещё один тик захватил кадр, не блокировался и не продлил удержание")
        ExpectKey(b, SC.a, 0, 0)

        ; Проверяем отдельно исполнитель ограниченного шага. Ни наведение,
        ; ни стрельба в живом режиме в этом тесте не вызываются.
        CancelRetreatStep()
        CFG.dryRun := false
        Check(!WinActive("ahk_id " b) && StartCombatRetreatStep(newer, -1)
            && ST.retreat.hold.target = b, "реальная клавиша A уходит только в заданный приёмник")
        ExpectKey(b, SC.a, 1, 0)
        ExpectKey(b, SC.a, 1, 1, 1600)
        Check(!ST.held.Count && !ContinueRetreatStep(newer) && !ST.retreat, "таймер отпустил A без следующего тика")
        ExpectKey(a, SC.a, 0, 0)
        ExpectKey(b, SC.d, 1, 1)
        ExpectKey(b, SC.w, 3, 3)
    } finally {
        CancelRetreatStep()
        CFG.dryRun := true, CFG.featCombat := false, CFG.featProStyle := false, CFG.hudDetectRun := hudRun
    }
}

TestResultBlink(a, b) {
    global CFG, ST
    CFG.dryRun := true, CFG.featPlayAgain := true, CFG.featChest := false, CFG.endAction := "play_again"
    CFG.clickRetries := 1, CFG.verifyMs := 5000, CFG.retryAfterMs := 6000, CFG.endReturnAfterMs := 6000
    CFG.sceneHoldMs := 0, CFG.stateConfirmFrames := 1, CFG.scanMenuMs := 0
    ResetEndHandoff()
    ST.queuePending := false, ST.cancelHold := false, ST.roundActive := true, ST.roundCounted := false
    ST.inMatchT := 0, ST.lastLobbyAt := 0, ST.mmEnterAt := 0
    clicks := ST.clickAgain, rounds := ST.rounds
    SetFixtureFrame(b, 7)
    TickFixture(b, false)
    Check(ST.state = "END_SCREEN" && ST.endRetry = 1 && ST.clickAgain = clicks + 1 && ST.rounds = rounds + 1
        , "первый реальный кадр итогов, клик только DryRun")
    SetFixtureFrame(b, 8)
    TickFixture(b, false)
    Check(ST.state = "UNKNOWN" && ST.endRetry = 1 && ST.endClickAt, "загрузка не сбрасывает лимит повтора")
    SetFixtureFrame(b, 7)
    TickFixture(b, false)
    Check(ST.state = "END_SCREEN" && ST.endRetry = 1 && !ST.endReturnRetry && ST.clickAgain = clicks + 1
        , "вид грубой сцены сменился обратно, повтор не отправляется заново")
    ST.endClickAt := A_TickCount - CFG.retryAfterMs, ST.endFirstSeen := A_TickCount - CFG.endReturnAfterMs
    TickFixture(b, false)
    Check(ST.endRetry = 1 && ST.endReturnRetry = 1 && ST.clickAgain = clicks + 2 && ST.rounds = rounds + 1
        && !ST.lobbyRequeue && !ST.held.Count, "после паузы переходим к резервному выходу, раунд не дублируется")
}

TestReturnOnlyResults(a, b) {
    global CFG, ST, SC
    CFG.dryRun := true, CFG.featPlayAgain := true, CFG.featAutoQueue := true, CFG.endAction := "lobby_only"
    CFG.stateConfirmFrames := 2, CFG.scanMenuMs := 0, CFG.sceneHoldMs := 0
    CFG.lobbyDelaySec := 2, CFG.lobbyStableMs := 400, CFG.playConfirmMs := 400, CFG.maxActionsPerMin := 0
    CFG.waitSquadOnDeath := false, CFG.deathEscMs := 45000
    ResetSceneEvidence()
    ST.state := "UNKNOWN", ST.roundActive := false, ST.roundCounted := false, ST.lobbyRequeue := false
    ST.queuePending := false, ST.cancelHold := false, ST.lobbyCooldownUntil := 0
    clicks := ST.clickAgain, queues := ST.clickQueue, rounds := ST.rounds
    SetFixtureFrame(b, 10)
    TickFixture(b, true, true)
    TickFixture(b)
    Check(ST.state = "DEATH" && ST.endContext.kind = "death", "устранение подтверждено кадрами окна")

    SetFixtureFrame(b, 11)
    first := TickFixture(b, false, true)
    Check(!first.endReturnAction && ST.clickAgain = clicks && FrameDarkRatio(first) < CFG.endDarkRatio
        , "на светлых итогах один замер не разрешает возврат")
    TickFixture(b, false, true)
    TickFixture(b, false)
    Check(ST.state = "END_SCREEN" && ST.endReturnObs.hits = 2 && ST.clickAgain = clicks
        , "светлые итоги без жёлтой плашки приняты после повторов; выдерживаем паузу")
    ST.endFirstSeen := A_TickCount - 2300
    TickFixture(b, false)
    Check(!ST.endRetry && ST.endReturnRetry = 1 && ST.clickAgain = clicks + 1 && ST.rounds = rounds
        && !ST.lobbyRequeue && ST.clickQueue = queues, "попытка возврата не засчитывает раунд и не ставит очередь")

    SetFixtureFrame(b, 12)
    TickFixture(b, false, true)
    TickFixture(b, false)
    Check(ST.state = "MENU" && ST.lobbyRequeue && ST.lobbyCooldownUntil > A_TickCount && ST.rounds = rounds + 1
        && ST.clickQueue = queues && !ST.endContext, "новая плашка лобби подтверждает единственный раунд и запускает задержку")
    ST.lobbyCooldownUntil := A_TickCount, ST.playSeenAt := A_TickCount - 500
    TickFixture(b, false)
    Check(ST.clickQueue = queues + 1 && !ST.lobbyRequeue && ST.rounds = rounds + 1 && !ST.held.Count
        , "после задержки отправляется ровно один запрос поиска в DryRun")
    ExpectKey(b, SC.w, 3, 3)
    ExpectKey(b, SC.e, 1, 1)
}

TestRepeatedPrompt(a, b) {
    global CFG, ST, SC
    FocusFixture(a), SelectFixture(b)
    CFG.bgMode := true, CFG.dryRun := false, CFG.featChest := true, CFG.featMove := true
    CFG.featCombat := false, CFG.sprint := false, CFG.featParkour := false
    CFG.chestHoldMs := 260, CFG.promptScanMs := 0, CFG.promptEcooldownMs := 0
    CFG.scanLootMs := 0, CFG.pauseChance := 0, CFG.stuckMs := 2400
    ResetSceneEvidence()
    ResetNavigation()
    ResetCaches()
    ST.state := "GAME", ST.phase := "roam", ST.phaseAt := A_TickCount, ST.matchStarted := true
    ST.queuePending := false, ST.cancelHold := false, ST.promptAttempts := [], ST.lastPromptE := 0
    baseline := ST.promptN
    SetFixtureFrame(b, 1)
    Loop 2 {
        attempt := A_Index
        TickFirstPrompt(b)
        ExpectKey(b, SC.e, attempt, attempt)
        TickFixture(b)
        p := ST.tgt
        Check(p && p.keyHold = ST.held.Get(SC.e, 0) && p.keyHold.target = b && ST.promptN = baseline + attempt
            , "E доставляем только в B")
        ExpectKey(b, SC.e, attempt + 1, attempt)
        ExpectKey(b, SC.e, attempt + 1, attempt + 1, 1300)
        Check(p.keyHold.HasOwnProp("releasedAt") && !ST.held.Has(SC.e), "таймер отметил отпускание своего E")
        doneAt := Max(p.until, p.keyHold.releasedAt)
        Sleep(Max(0, doneAt + 25 - A_TickCount))
        SetFixtureFrame(b, 0)
        missing := TickFixture(b)
        Check(ST.tgt = p && p.absentHits = 1 && p.postSeq = missing.captureId && !ST.held.Count
            , "мигание после отпускания E не снимает проверку и не запускает W")
        SetFixtureFrame(b, 1)
        CFG.promptScanMs := 60000
        deferred := TickFixture(b)
        Check(ST.tgt = p && p.absentHits = 1 && ST.promptSeq != deferred.captureId && !ST.held.Count
            , "на отложенном кадре нет ни второго промаха, ни хода вперёд")
        CFG.promptScanMs := 0
        ExpectKey(b, SC.w, 3, 3)
        ExpectKey(b, SC.e, attempt + 1, attempt + 1)
        TickFixture(b)
        Check(ST.tgt = p && p.sameHits = 1 && !p.absentHits, "плашка вернулась после мигания, пока проверяется та же попытка")
        Sleep(Max(0, doneAt + CFG.interactVerifyMs + 25 - A_TickCount))
        TickFixture(b)
        Check(!ST.tgt && p.sameHits = 2 && ST.promptMemory[1].repeats = attempt, "оба подтверждения после E")
    }
    Check(ST.held.Has(SC.w) && ST.held[SC.w].target = b, "плашка больше не мешает начать ходьбу")
    ExpectKey(b, SC.w, 4, 3)
    TickFixture(b)
    ExpectKey(b, SC.w, 4, 3)
    ExpectKey(b, SC.e, 3, 3)

    SetFixtureFrame(b, 16)
    TickFirstPrompt(b)
    Check(ST.promptMemory.Length = 1 && ST.promptMemory[1].repeats = 2, "другая строка не снимает пропуск старой")
    ExpectKey(b, SC.w, 4, 4)
    ExpectKey(b, SC.e, 3, 3)
    TickFixture(b)
    ExpectKey(b, SC.e, 4, 4, 1300)
    Check(ST.promptN = baseline + 3 && !ST.chests && !ST.held.Count, "новая плашка работает после своей пары; открытия не засчитаны")
    ExpectKey(a, SC.e, 3, 3)
    ExpectKey(a, SC.w, 1, 1)
}

TestStaticFallback(a, b) {
    global CFG, ST, SC
    CFG.dryRun := true, CFG.featMove := false, CFG.featChest := false
    FocusFixture(a), SelectFixture(a)
    CFG.featCombat := true, CFG.featMotionEnemy := false, CFG.enemyFastMs := 0
    CFG.aimReactMs := 0, CFG.skinWideMs := 60000, CFG.featFirstSlot := false
    ResetCaches()
    ST.scanWideAt := A_TickCount, ST.stepBoost := 0, ST.reloadUntil := 0
    shots := ST.shots
    for i, scene in [17, 18, 19, 19, 17] {
        SetFixtureFrame(a, scene)
        shot := TickFixture(a)
        Check(shot.HasOwnProp("enemyReading") && !ST.held.Count && !ST.leftDown && !ST.adsOn
            , "захват настоящего окна, без мыши в DryRun")
        if (i = 1 || i = 5) {
            Check(!shot.enemyReading && !ST.enemyCache && ST.shots = shots + (i = 5)
                , "без фигуры декорация не забирает бой")
        } else if (i <= 3) {
            Check(shot.enemyReading && shot.enemyReading.isolated && ST.enemyConfirm.hits = 1
                && !ST.enemyCache && ST.shots = shots, "другой центр не получает старое подтверждение")
        } else {
            Check(ST.enemySeenSeq = shot.captureId && ST.enemyCache.isolated && ST.shots = shots + 1
                , "пара одинаковых кадров: виртуальная очередь в фигуру рядом с яркой опорой")
            report := BuildCalibrationReport(shot), indicated := false
            for line in report.lines
                if InStr(line, "отдельная тёплая группа")
                    indicated := true
            Check(indicated, "F5 объясняет найденную отдельную фигуру на том же захвате")
        }
    }
    ExpectKey(a, SC.e, 3, 3)
    ExpectKey(a, SC.w, 1, 1)
    ExpectKey(b, SC.e, 4, 4)
    ExpectKey(b, SC.w, 4, 4)
}

TestSlowChestRoundTrip(a, b) {
    global CFG, ST, SC
    FocusFixture(a), SelectFixture(b)
    CFG.bgMode := true, CFG.dryRun := false, CFG.featMove := false
    CFG.featCombat := false, CFG.featChest := true, CFG.chestHoldMs := 580
    CFG.featSound := false, CFG.featParkour := false, CFG.sprint := false
    ApplyPerfProfile("low_cpu")
    ; Изолируем срок W от совпадения интервалов меню и масок: полный скан
    ; меню в отдельном прогревочном тике, затем обычный бюджет low_cpu.
    CFG.scanMenuMs := 60000
    ResetSceneEvidence()
    ResetNavigation()
    ResetCaches()
    ST.state := "GAME", ST.phase := "roam", ST.phaseAt := A_TickCount, ST.matchStarted := true
    ST.promptAttempts := [], ST.lastPromptE := 0
    attempts := ST.promptN, chests := ST.chests
    SetFixtureFrame(b, 6)
    TickFixture(b)
    CFG.featMove := true
    Loop 3 {
        if (A_Index > 1)
            WaitForLootScan()
        shot := TickFixture(b)
        Check(ST.chestCacheSeq = shot.captureId && ST.walkTarget && !ST.tgt
            , "свечение измерено, но не разрешает E")
        if (A_Index < 3)
            ExpectKey(b, SC.w, 4, 4)
    }
    hold := ST.held.Get(SC.w, 0), firstDeadline := ST.guidedUntil
    Check(hold && hold.target = b && firstDeadline >= ST.lootMasksAt + CFG.scanLootMs + CFG.loopMs
        , "удержание W у прицела должно покрыть интервал масок и следующий тик экономного профиля")
    ExpectKey(b, SC.w, 5, 4)
    ExpectKey(b, SC.e, 4, 4)

    deferred := TickFixture(b)
    Check(ST.chestCacheSeq != deferred.captureId && ST.guidedUntil = firstDeadline && ST.held.Get(SC.w, 0) = hold
        , "отложенная маска не продлевает W и не переключает на патруль")
    WaitForLootScan()
    fresh := TickFixture(b)
    Check(ST.chestCacheSeq = fresh.captureId && ST.guidedUntil > firstDeadline && ST.held.Get(SC.w, 0) = hold
        , "повторное измерение продлевает то же W без рывка")
    Sleep(Max(0, firstDeadline + 25 - A_TickCount))
    ExpectKey(b, SC.w, 5, 4)
    ExpectKey(b, SC.w, 5, 5, 1300)
    Check(!ST.held.Has(SC.w), "без свежих кадров даже продлённый шаг отпускается сам")

    TickFixture(b)
    ExpectKey(b, SC.w, 6, 5)
    SetFixtureFrame(b, 1)
    TickFirstPrompt(b)
    ExpectKey(b, SC.w, 6, 6)
    ExpectKey(b, SC.e, 4, 4)
    TickFixture(b)
    p := ST.tgt
    Check(p && p.keyHold = ST.held.Get(SC.e, 0) && p.keyHold.target = b && ST.promptN = attempts + 1
        , "только вторая плашка запускает удержание E, в том же окне")
    ExpectKey(b, SC.e, 5, 4)
    ExpectKey(b, SC.e, 5, 5, 1500)
    Sleep(Max(20, Max(p.until, p.keyHold.releasedAt) + 20 - A_TickCount))
    SetFixtureFrame(b, 0)
    TickFixture(b)
    Check(ST.tgt = p && p.absentHits = 1, "первый пустой кадр не возвращает патруль")
    ExpectKey(b, SC.w, 6, 6)
    TickFixture(b)
    Check(!ST.tgt && ST.chests = chests && InStr(ST.lastAction, "результат E неизвестен")
        , "два замера без плашки завершают проверку, открытие не засчитано")
    TickFixture(b)
    Check(ST.segUntil && !ST.guidedUntil, "после попытки самостоятельно возобновляется патруль")
    ExpectKey(b, SC.w, 7, 6)
    HaltMatchMovement()
    ExpectKey(b, SC.w, 7, 7)
    ExpectKey(a, SC.w, 1, 1)
    ExpectKey(a, SC.e, 3, 3)
}

WaitForLootScan() {
    global CFG, ST
    Sleep(Max(0, ST.lootMasksAt + CFG.scanLootMs + 16 - A_TickCount))
}

TestGuidedLaneBypass(a, b) {
    global CFG, ST, SC
    FocusFixture(a), SelectFixture(b)
    CFG.bgMode := true, CFG.dryRun := false, CFG.featMove := true
    CFG.featCombat := false, CFG.featChest := true, CFG.featSound := false
    ApplyPerfProfile("fast")
    CFG.scanLootMs := 0, CFG.navScanMs := 0
    CFG.stuckSampleMs := 150, CFG.stuckMs := 8000, CFG.stuckRecoveryMs := 480
    ResetNavigation()
    ResetCaches()
    ST.navTurnSign := -1, ST.cameraAt := 0  ; исходное предпочтение противоположно свободной полосе
    SetFixtureFrame(b, 20)
    Loop 4
        TickFixture(b)
    hold := ST.held.Get(SC.w, 0)
    Check(hold && ST.stuckShot && ST.navInfo.kind = "busy" && ST.navInfo.turnStable && ST.navInfo.turn = 1
        , "у свечения плотный центр, два скана показывают менее плотную правую полосу")
    ExpectKey(b, SC.w, 8, 7)
    Loop 7 {
        SetFixtureFrame(b, Mod(A_Index, 2) ? 21 : 20)
        Sleep(175)
        TickFixture(b)
        Check(ST.held.Get(SC.w, 0) = hold && !ST.stuckStillSamples && !ST.stuckRecoverUntil
            , "плотные края сами по себе не прерывают направленное движение")
    }
    Check(ST.stuckMotionN >= 3, "разные кадры мира были измерены")
    Loop 12 {
        Sleep(175)
        TickFixture(b)
        if ST.stuckRecoverUntil
            break
    }
    Check(ST.stuckRecoverN = 1 && ST.stuckRecoverKey = SC.d && ST.held.Has(SC.d) && !ST.held.Has(SC.w)
        && ST.guidedUntil > ST.stuckRecoverUntil, "не дожидаясь обычного срока, пробуем ограниченный шаг в согласованную сторону")
    ExpectKey(b, SC.w, 8, 8)
    ExpectKey(b, SC.d, 2, 1)
    ExpectKey(b, SC.d, 2, 2, 1200)
    Check(!ST.held.Count && !ST.tgt, "без нового тика обход сам заканчивается, E не нажималась")
    ExpectKey(b, SC.a, 1, 1)
    ExpectKey(b, SC.e, 5, 5)
    ExpectKey(a, SC.d, 0, 0)
}

TestGuidedLipHop(a, b) {
    global CFG, ST, SC
    FocusFixture(a), SelectFixture(b)
    CFG.bgMode := true, CFG.dryRun := false, CFG.featMove := true
    CFG.featCombat := false, CFG.featSound := false, CFG.featChest := true, CFG.featParkour := true
    CFG.scanLootMs := 0, CFG.navScanMs := 0
    CFG.stuckSampleMs := 150, CFG.stuckMs := 8000
    ResetNavigation()
    ResetCaches()
    ST.lastJumpT := 0, ST.cameraAt := 0
    SetFixtureFrame(b, 22)
    Loop 4
        TickFixture(b)
    forward := ST.held.Get(SC.w, 0)
    Check(forward && ST.guidedUntil && ST.chest && !ST.segUntil
        && ST.navInfo.kind = "lip" && ST.navInfo.hits = 2 && !ST.navHop
        , "локальный край не вызывает прыжок без признаков застревания: " ST.lastAction
            . " / цель " (ST.chest ? "да" : "нет") " / " (ST.navInfo ? ST.navInfo.kind " " ST.navInfo.hits : "без оценки"))
    ExpectKey(b, SC.w, 9, 8)
    Loop 7 {
        SetFixtureFrame(b, Mod(A_Index, 2) ? 23 : 22)
        Sleep(175)
        TickFixture(b)
        Check(ST.held.Get(SC.w, 0) = forward && !ST.stuckStillSamples && !ST.navHop
            , "через визуально меняющийся участок продолжаем идти без прыжка")
    }
    Check(ST.stuckMotionN >= 3, "разница мира измерялась на подходе к уступу")
    ExpectKey(b, SC.space, 1, 1)
    Loop 12 {
        Sleep(175)
        TickFixture(b)
        if ST.navHop
            break
    }
    hop := ST.navHop
    Check(hop && hop.forward = forward && hop.hold.target = b && ST.navInfo.jumped && !ST.stuckRecoverUntil
        , "без видимого продвижения локальный край даёт одну попытку прыжка, W не нажимается заново")
    deadline := hop.until
    TickFixture(b)
    Check(ST.navHop = hop && hop.until = deadline && ST.held.Get(SC.w, 0) = forward
        , "следующий кадр сохраняет ход и не продлевает защиту прыжка")
    ExpectKey(b, SC.space, 2, 2, 650)
    ExpectKey(b, SC.w, 9, 8)
    SetFixtureFrame(b, 1)
    TickFirstPrompt(b)
    Check(!ST.navHop && !ST.held.Count, "первая плашка останавливает прыжок/шаг, но ещё не нажимает E")
    ExpectKey(b, SC.w, 9, 9)
    ExpectKey(b, SC.space, 2, 2)
    ExpectKey(b, SC.e, 5, 5)
    TickFixture(b)
    ExpectKey(b, SC.e, 6, 5)
    ExpectKey(b, SC.e, 6, 6, 1500)
    ExpectKey(a, SC.space, 0, 0)
    ExpectKey(a, SC.e, 3, 3)
}

TestGuidedRecoveryRecheck(a, b) {
    global CFG, ST, SC
    FocusFixture(a), SelectFixture(b)
    CFG.bgMode := true, CFG.dryRun := false, CFG.featMove := true
    CFG.featCombat := false, CFG.featChest := true, CFG.featSound := false, CFG.featParkour := false
    ApplyPerfProfile("fast")
    CFG.scanLootMs := 0, CFG.navScanMs := 0
    CFG.stuckSampleMs := 550, CFG.stuckMs := 8000, CFG.stuckRecoveryMs := 480
    HaltMatchMovement()
    ResetNavigation()
    ResetCaches()
    ST.cameraAt := 0
    w := FixtureKeyCounts(b, SC.w), d := FixtureKeyCounts(b, SC.d), e := FixtureKeyCounts(b, SC.e)
    otherD := FixtureKeyCounts(a, SC.d)
    attempts := ST.promptN, chests := ST.chests
    SetFixtureFrame(b, 24)
    Loop 4
        goal := TickFixture(b)
    approach := ST.walkTarget, forward := ST.held.Get(SC.w, 0)
    Check(approach && forward && ST.navInfo.kind = "busy" && ST.navInfo.turn = 1 && ST.navInfo.hits = 2
        , "свечение на фоне плотного прохода подтверждено, W доставлена")
    ExpectKey(b, SC.w, w[1] + 1, w[2])
    at := approach.at
    PrimeGuidedStill(goal)
    SetFixtureFrame(b, 25)
    lost := TickFixture(b)
    diff := WorldMotionDiff(goal, lost)
    Check(diff >= 0 && diff < CFG.stuckDiffThreshold, "в сцене исчезло свечение, а замер мира по-прежнему считает проход неподвижным")
    Check(!ST.stuckRecoverUntil && !ST.held.Count && ST.walkTarget = approach && approach.missSeq = lost.captureId
        && ST.chestCacheSeq = lost.captureId && !ST.chest, "потеря цели на пороге обхода должна остановить W, а не начать шаг D")
    ExpectKey(b, SC.w, w[1] + 1, w[2] + 1)
    ExpectKey(b, SC.d, d*)

    SetFixtureFrame(b, 24)
    TickFixture(b)
    Check(ST.walkTarget = approach && approach.at = at && approach.samples.hits = 1 && !ST.held.Count
        , "первый замер после мерцания только возвращает кандидата, не продлевает весь подход")
    goal := TickFixture(b)
    forward := ST.held.Get(SC.w, 0), lease := ST.guidedUntil
    Check(forward && approach.samples.hits = 2, "второй замер возвращает W")
    ExpectKey(b, SC.w, w[1] + 2, w[2] + 1)
    for changed in [true, false] {
        hits := approach.samples.hits
        PrimeGuidedStill(goal)
        CFG.scanLootMs := 60000
        deferred := TickFixture(b)
        Check(ST.lootMasksSeq != deferred.captureId && ST.held.Get(SC.w, 0) = forward && ST.guidedUntil = lease
            && ST.stuckShot = deferred && approach.samples.hits = hits && !ST.stuckRecoverUntil
            , "отложенный скан не начинает обход, не продлевает W и не считается потерей")
        ExpectKey(b, SC.d, d*)
        CFG.scanLootMs := 360, ST.lootMasksAt := 0
        SetFixtureFrame(b, changed ? 26 : 24)
        next := TickFixture(b)
        if !changed
            break
        Check(next.capturedAt - deferred.capturedAt < CFG.stuckSampleMs
            && WorldMotionDiff(deferred, next) >= CFG.stuckDiffThreshold && ST.chestCacheSeq = next.captureId
            && ST.held.Get(SC.w, 0) = forward && !ST.stuckStillSamples && !ST.stuckRecoverUntil
            , "перед вводом свежий изменившийся кадр отменяет вывод о неподвижности, даже вне интервала замера")
        ExpectKey(b, SC.d, d*)
        CFG.scanLootMs := 0
        SetFixtureFrame(b, 24)
        goal := TickFixture(b), lease := ST.guidedUntil
    }
    Check(ST.chestCacheSeq = next.captureId && ST.stuckRecoverUntil && ST.held.Has(SC.d)
        && !ST.held.Has(SC.w) && !approach.samples.hits && approach.at = at
        , "новый замер той же цели разрешает один обход и снимает старое подтверждение, не обнуляя срок")
    anchor := {x:approach.samples.x, y:approach.samples.y}
    ExpectKey(b, SC.w, w[1] + 2, w[2] + 2)
    ExpectKey(b, SC.d, d[1] + 1, d[2])
    SetFixtureFrame(b, 29) ; к отпусканию D осталось только соседнее пятно
    ExpectKey(b, SC.d, d[1] + 1, d[2] + 1, 1200)
    CFG.scanLootMs := 60000
    Loop 2
        deferred := TickFixture(b)
    Check(ST.lootMasksSeq != deferred.captureId && !ST.stuckRecoverUntil && ST.walkTarget = approach
        && !approach.samples.hits && !ST.held.Count && !ST.segUntil, "после отпускания D и отложенного скана патруль не перехватывает W")
    ExpectKey(b, SC.w, w[1] + 2, w[2] + 2)
    CFG.scanLootMs := 360, ST.lootMasksAt := 0
    neighbor := TickFixture(b)
    Check(ST.chestCacheSeq = neighbor.captureId && ST.chest && ST.chest.x > neighbor.w * 0.6
        && !CandidateNear(anchor, ST.chest.x, ST.chest.y, neighbor.w, neighbor.h) && ST.walkTarget = approach
        && approach.missSeq = neighbor.captureId && !approach.samples.hits && !ST.held.Count && !ST.segUntil
        , "первый скан после D видит только соседа: это потеря прежней цели, а не продолжение W")
    ExpectKey(b, SC.w, w[1] + 2, w[2] + 2)

    SetFixtureFrame(b, 28) ; прежнее пятно вернулось со сдвигом, сосед всё ещё ярче
    ST.lootMasksAt := 0
    shifted := TickFixture(b), strongest := FindChest(shifted, ST.lootMasks)
    Check(ST.chestCacheSeq = shifted.captureId && ST.chest && strongest && strongest.x > shifted.w * 0.6
        && strongest.score > ST.chest.score && ST.chest.x < anchor.x
        && CandidateNear(anchor, ST.chest.x, ST.chest.y, shifted.w, shifted.h)
        && ST.walkTarget = approach && approach.at = at && approach.samples.hits = 1 && !ST.held.Count
        , "смещённый близкий центр, а не более яркий сосед, получает первое подтверждение в том же подходе")
    ExpectKey(b, SC.w, w[1] + 2, w[2] + 2)
    ST.lootMasksAt := 0
    TickFixture(b)
    Check(ST.held.Has(SC.w) && !ST.segUntil && ST.walkTarget = approach && approach.at = at && approach.samples.hits = 2
        && ST.promptN = attempts && ST.chests = chests && !ST.tgt, "только повтор после обхода восстанавливает визуальный шаг, но не разрешает E")
    ExpectKey(b, SC.w, w[1] + 3, w[2] + 2)
    HaltMatchMovement()
    ExpectKey(b, SC.w, w[1] + 3, w[2] + 3)
    ExpectKey(b, SC.d, d[1] + 1, d[2] + 1)
    ExpectKey(b, SC.e, e*)
    ExpectKey(a, SC.d, otherD*)
}

TestPatrolHudLease(a, b) {
    global CFG, ST, SC
    FocusFixture(a), SelectFixture(b)
    CFG.bgMode := true, CFG.dryRun := false, CFG.featMove := true, CFG.sprint := true
    CFG.featCombat := false, CFG.featChest := false, CFG.featSound := false, CFG.featParkour := false
    ApplyPerfProfile("fast")
    CFG.navScanMs := 0, CFG.patrolHoldMs := 600, CFG.pauseChance := 0
    HaltMatchMovement()
    ResetNavigation()
    ResetSceneEvidence()
    ResetCaches()
    ST.state := "GAME", ST.phase := "roam", ST.phaseAt := A_TickCount, ST.matchStarted := true
    ST.pauseUntil := 0, ST.cameraAt := 0
    w := FixtureKeyCounts(b, SC.w), sprint := FixtureKeyCounts(b, SC.shift)
    otherW := FixtureKeyCounts(a, SC.w), otherSprint := FixtureKeyCounts(a, SC.shift)
    SetFixtureFrame(b, 0)
    Loop 2
        TickFixture(b)
    forward := ST.held.Get(SC.w, 0), shift := ST.held.Get(SC.shift, 0)
    Check(forward && shift && ST.segUntil && ST.hudLastT, "с HUD два кадра дали удержание W/Shift")
    ExpectKey(b, SC.w, w[1] + 1, w[2])
    ExpectKey(b, SC.shift, sprint[1] + 1, sprint[2])
    leaseAt := ST.patrolLeaseAt, hudAt := ST.hudLastT, segment := ST.segUntil
    wId := forward.releaseId, shiftId := shift.releaseId
    Sleep(Max(0, leaseAt + CFG.patrolHoldMs // 3 + 20 - A_TickCount))
    SetFixtureFrame(b, 27)
    lost := TickFixture(b, false)
    Check(!FrameHasMatchHud(lost) && lost.HasOwnProp("hudEvidence") && !lost.hudEvidence.bar
        && ST.state = "GAME" && ST.hudLastT = hudAt, "кадр без HUD, а GAME удерживается памятью")
    Check(ST.held.Get(SC.w, 0) = forward && ST.held.Get(SC.shift, 0) = shift && ST.segUntil = segment
        && ST.patrolLeaseAt = leaseAt && forward.releaseId = wId && shift.releaseId = shiftId
        && ST.lastAction = "патруль: жду подтверждение HUD"
        , "память GAME не должна продлевать W/Shift на свежем кадре без HUD")

    SetFixtureFrame(b, 0)
    budget := CFG.scanPerTickMax, CFG.scanPerTickMax := 0
    try deferred := TickFixture(b, false)
    finally CFG.scanPerTickMax := budget
    Check(deferred.HasOwnProp("healthDeferred") && deferred.hudEvidence.bar && !FrameHasMatchHud(deferred)
        && ST.state = "GAME" && ST.hudLastT = hudAt, "HUD виден, но замер HP отложен бюджетом")
    Check(ST.patrolLeaseAt = leaseAt && forward.releaseId = wId && shift.releaseId = shiftId
        && ST.lastAction = "патруль: замер HP отложен", "отложенный замер тоже не продлевает W/Shift")

    good := TickFixture(b)
    Check(ST.hudLastT = good.capturedAt && ST.held.Get(SC.w, 0) = forward && ST.held.Get(SC.shift, 0) = shift
        && forward.releaseId > wId && shift.releaseId > shiftId, "быстрый возврат HUD продлевает те же клавиши без нового down")
    ExpectKey(b, SC.w, w[1] + 1, w[2])
    ExpectKey(b, SC.shift, sprint[1] + 1, sprint[2])

    SetFixtureFrame(b, 27)
    ; Нет нового тика до отпускания: его должны сделать старые таймеры.
    ExpectKey(b, SC.w, w[1] + 1, w[2] + 1, 1300)
    ExpectKey(b, SC.shift, sprint[1] + 1, sprint[2] + 1, 1300)
    stillMissing := TickFixture(b, false)
    Check(!FrameHasMatchHud(stillMissing) && ST.lastAction = "патруль: жду подтверждение HUD"
        && ST.state = "GAME" && ST.hudLastT = good.capturedAt && !ST.held.Count
        , "клавиши отпустились таймером и не стартуют заново на ещё одном кадре без HUD")
    ExpectKey(b, SC.w, w[1] + 1, w[2] + 1)
    ExpectKey(b, SC.shift, sprint[1] + 1, sprint[2] + 1)
    SetFixtureFrame(b, 0)
    TickFixture(b)
    Check(ST.held.Has(SC.w) && ST.held[SC.w] != forward, "после истечения старого удержания новый HUD возвращает ходьбу")
    ExpectKey(b, SC.w, w[1] + 2, w[2] + 1)
    HaltMatchMovement()
    ExpectKey(b, SC.w, w[1] + 2, w[2] + 2)
    ExpectKey(a, SC.w, otherW*)
    ExpectKey(a, SC.shift, otherSprint*)
}

TestChestSoundLease(a, b) {
    global CFG, ST, SC
    FocusFixture(a), SelectFixture(b)
    CFG.bgMode := true, CFG.dryRun := false, CFG.featMove := true, CFG.sprint := false
    CFG.featChest := true, CFG.featSound := true, CFG.scanSoundMs := 0
    HaltMatchMovement()
    ResetNavigation()
    ResetSceneEvidence()
    ResetCaches()
    ST.state := "GAME", ST.phase := "roam", ST.phaseAt := A_TickCount, ST.matchStarted := true
    ST.pauseUntil := 0, ST.lastSound := 0
    w := FixtureKeyCounts(b, SC.w), e := FixtureKeyCounts(b, SC.e), otherW := FixtureKeyCounts(a, SC.w)
    SetFixtureFrame(b, 30)
    first := TickFixture(b)
    Check(ST.soundCacheSeq = first.captureId && ST.soundRing.chest && Abs(ST.soundRing.chest.angleDeg) <= 14
        && !ST.held.Has(SC.w), "первая метка с HUD впереди есть, но не даёт W")
    ExpectKey(b, SC.w, w*)

    SetFixtureFrame(b, 31)
    lost := TickFixture(b, false)
    Check(!FrameHasMatchHud(lost) && ST.state = "GAME" && ST.soundCacheSeq = lost.captureId
        && ST.soundRing.chest && !ST.held.Has(SC.w), "золото без свежего HUD не может начать W")
    ExpectKey(b, SC.w, w*)

    SetFixtureFrame(b, 30)
    TickFixture(b)
    ExpectKey(b, SC.w, w*)
    good := TickFixture(b)
    forward := ST.held.Get(SC.w, 0)
    Check(forward && forward.target = b && ST.lastAction = "короткий шаг по метке звука"
        , "два новых кадра дают короткий W только выбранному окну")
    lease := forward.releaseId, deadline := ST.guidedUntil
    Check(WorldFrameCurrent(good) && !SeekChestBySound(good, A_TickCount) && forward.releaseId = lease
        , "дубликат не переносит реальное отпускание W")
    ExpectKey(b, SC.w, w[1] + 1, w[2])

    ; Если исходная клавиша уже успела отпуститься, не смешиваем эту
    ; проверку направленного W с новым обычным отрезком патруля.
    ST.pauseUntil := A_TickCount + 1500
    SetFixtureFrame(b, 32)
    mixed := TickFixture(b)
    Check(ST.soundCacheSeq = mixed.captureId && ST.soundRing.goldCount = 2 && ST.soundRing.goldAmbiguous
        && Abs(ST.soundRing.chest.angleDeg) <= 14 && forward.releaseId = lease && ST.guidedUntil = deadline
        , "крупнейшая метка всё ещё впереди, но конфликт не продлевает удержание W")

    SetFixtureFrame(b, 31)
    stillGold := TickFixture(b, false)
    Check(!FrameHasMatchHud(stillGold) && forward.releaseId = lease && ST.guidedUntil = deadline
        , "при пропаже HUD шаг не продлевается, даже если метка осталась")
    ExpectKey(b, SC.w, w[1] + 1, w[2] + 1, 1500)
    Check(!ST.held.Has(SC.w), "W отпущена без следующего тика")
    ExpectKey(a, SC.w, otherW*)
    ExpectKey(b, SC.e, e*)
}

PrimeGuidedStill(shot) {
    global CFG, ST
    ; Подводим счётчики к границе, чтобы потеря/пропуск пришлись на нужный тик.
    ; Сравнение пикселей на этом тике и все события клавиш остаются настоящими.
    ST.stuckShot := shot, ST.stuckSampleAt := A_TickCount - CFG.stuckSampleMs
    ST.stuckStillSamples := 2, ST.stuckStillMs := Max(1100, 2 * CFG.stuckSampleMs)
}

SelectFixture(h) {
    global CFG
    CFG.winTitle := "ahk_id " h
    Check(GetGameWindow() = h, "выбрано именно тестовое окно")
}

FocusFixture(h) {
    WinActivate("ahk_id " h)
    Check(WinWaitActive("ahk_id " h, , 1), "не удалось активировать тестовое окно")
}

TickFixture(h, requireHud := true, allowSceneWait := false) {
    global CFG, ST
    Check(GetGameWindow() = h && (CFG.dryRun || (CFG.bgMode && !WinActive("ahk_id " h)))
        , "без DryRun допустим только фоновый ввод в выбранный приёмник")
    seq := ST.captureSeq
    Tick()
    shot := ST.lastShot
    Check(shot && shot.captureId > seq && shot.hwnd = h && shot.w = 480 && shot.h = 288
        && (!requireHud || FrameHasMatchHud(shot)), "нет нового тестового кадра; исход: " ST.tickProfile.outcome)
    outcome := ST.tickProfile.outcome
    Check(outcome = "завершён" || (allowSceneWait && outcome = "выдержка сцены")
        , "ошибка цикла: " TickProfileText(ST.tickProfile))
    return shot
}

TickFirstPrompt(h) {
    global ST, SC
    shot := TickFixture(h)
    Check(ST.promptConfirm.hits = 1 && !ST.held.Has(SC.e) && !ST.tgt, "нужен второй кадр из этого окна и вида")
    return shot
}

Check(ok, description) {
    if !ok
        throw Error(description, -1)
}

SetFixtureFrame(h, scene) {
    Check(SendMessage(0x8020, scene, 0, , "ahk_id " h, , , , 1000) = 1, "приёмник не сменил сцену")
}

FixtureKeyCounts(h, scanCode) {
    vk := VkFromScan(scanCode)
    Check(vk, "неизвестная клавиша " scanCode)
    count := SendMessage(0x8021, vk, 0, , "ahk_id " h, , , , 1000)
    return [count & 0xFFFF, count >> 16]
}

ExpectKey(h, scanCode, downs, ups, waitMs := 250) {
    deadline := A_TickCount + waitMs
    loop {
        counts := FixtureKeyCounts(h, scanCode), d := counts[1], u := counts[2]
        if (d = downs && u = ups)
            return
        if (d > downs || u > ups || A_TickCount >= deadline)
            throw Error(WinGetTitle("ahk_id " h) " · " scanCode ": down/up = " d "/" u
                . ", ожидалось " downs "/" ups, -1)
        Sleep(10)
    }
}

ServeReceiver(tag) {
    global rx := Map(), fixtureFrames := []
    SetDpiAware()
    Loop 33
        fixtureFrames.Push(BuildFixtureFrame(A_Index - 1))
    OnMessage(0x000F, ReceiverPaint)     ; WM_PAINT (DC окна)
    OnMessage(0x0317, ReceiverPrint)     ; WM_PRINT
    OnMessage(0x0318, ReceiverPrint)     ; WM_PRINTCLIENT
    OnMessage(0x0100, ReceiverKey)       ; WM_KEYDOWN
    OnMessage(0x0101, ReceiverKey)       ; WM_KEYUP
    OnMessage(0x8020, ReceiverFrame)
    OnMessage(0x8021, ReceiverCounts)
    for label in ["A", "B"] {
        win := Gui("+ToolWindow -Caption -DPIScale +E0x08000000", tag " " label)
        rx[win.Hwnd] := {gui:win, scene:0, counts:Map()}
        win.Show("NA x" (label = "A" ? 16 : 512) " y40 w480 h288")
    }
    SetTimer(ExitApp, -30000)
}

ReceiverFrame(w, l, msg, h) {
    global rx, fixtureFrames
    if (!rx.Has(h) || w < 0 || w >= fixtureFrames.Length)
        return 0
    rx[h].scene := w
    DllCall("user32\RedrawWindow", "Ptr", h, "Ptr", 0, "Ptr", 0, "UInt", 0x0101)
    return 1
}

ReceiverPrint(dc, l, msg, h) {
    global rx, fixtureFrames
    if rx.Has(h) {
        DrawFixture(dc, fixtureFrames[rx[h].scene + 1])
        return 1
    }
}

ReceiverPaint(w, l, msg, h) {
    global rx, fixtureFrames
    if !rx.Has(h)
        return
    ps := Buffer(A_PtrSize = 8 ? 72 : 64, 0)
    dc := DllCall("user32\BeginPaint", "Ptr", h, "Ptr", ps, "Ptr")
    if dc {
        try DrawFixture(dc, fixtureFrames[rx[h].scene + 1])
        finally DllCall("user32\EndPaint", "Ptr", h, "Ptr", ps)
    }
    return 0
}

DrawFixture(dc, f) {
    DllCall("gdi32\StretchDIBits", "Ptr", dc, "Int", 0, "Int", 0, "Int", f.w, "Int", f.h
        , "Int", 0, "Int", 0, "Int", f.w, "Int", f.h, "Ptr", f.buf, "Ptr", f.info
        , "UInt", 0, "UInt", 0x00CC0020, "Int")
}

ReceiverKey(vk, l, msg, h) {
    global rx
    if rx.Has(h) {
        counts := rx[h].counts
        counts[vk] := counts.Get(vk, 0) + (msg = 0x0100 ? 1 : 0x10000)
    }
}

ReceiverCounts(vk, l, msg, h) {
    global rx
    return rx.Has(h) ? rx[h].counts.Get(vk, 0) : -1
}

BuildFixtureFrame(scene) {
    w := 480, h := 288, buf := Buffer(w * h * 4)
    ; Текстура, а не заливка: защита захвата от однотонного кадра остаётся включена.
    light := (scene = 21 || scene = 23 || scene = 26) ? 28 : 0
    Loop 24 {
        row := A_Index - 1
        Loop 24 {
            col := A_Index - 1, shade := 63 + Mod(col + row * 3, 42) + light
            PaintFixture(buf, w, col * 20, row * 12, 20, 12, shade * 0x010101)
        }
    }
    ; 27 — открытый проход без HUD, 31 — та же метка звука, что 30, но без HUD.
    if (scene < 7 || scene = 9 || scene = 10 || (scene >= 13 && scene != 27 && scene != 31)) {
        PaintFixture(buf, w, 24, 256, (scene = 14 || scene = 15) ? 28 : 80, 20, 0x2ABA31) ; HUD HP
        PaintFixture(buf, w, 416, 270, 8, 8, 0xEEEEEE)       ; слот, в том числе при красном прицеле
        PaintFixture(buf, w, 233, 142, 7, 5, 0xFFFFFF)        ; прицел
    }
    if (scene = 1 || scene = 16) {
        wide := scene = 16, left := wide ? 234 : 242
        PaintFixture(buf, w, left, 134, wide ? 74 : 58, 21, 0x282828)
        PaintFixture(buf, w, left + 3, 142, 3, 4, 0xEEEEEE)
        Loop (wide ? 13 : 9)
            PaintFixture(buf, w, left + 15 + 4 * (A_Index - 1), 142, 2, 4, 0xEEEEEE)
    }
    if (scene >= 2 && scene <= 4) {
        ; Неизменная оранжевая опора и отдельная полоса продолжали её рамку в v11.0.8.
        PaintFixture(buf, w, 96, 40, 24, 72, 0xDA8848)
        PaintFixture(buf, w, 120, 103, 9, 9, 0xCF7C39)
        PaintFixture(buf, w, 379, 111, 15, 30, 0xC78343)
        if (scene >= 3)
            PaintFixture(buf, w, 233, 124, 16, 32, scene = 3 ? 0xDDDDDD : 0x202020)
        PaintFixture(buf, w, 236, 140, 9, 9, 0xEE2727)     ; один и тот же цвет на трёх сценах
    }
    if (scene = 5 || scene = 22 || scene = 23)
        PaintFixture(buf, w, 184, 166, 111, 45, 0xC2C2C2) ; локальный край поперёк центра
    if (scene = 22 || scene = 23)
        PaintFixture(buf, w, 222, 108, 36, 33, 0xFFAA20) ; ядро заполняет ячейки выше края без перекрытия прицела
    if (scene = 20 || scene = 21 || (scene >= 24 && scene <= 29 && scene != 27)) {
        ; Плотные полосы слева и в центре; правая полоса остаётся открытой.
        ; Вариант с другой яркостью меняет кадр мира, но не оценку коридора.
        for bounds in [[0.15, 0.34], [0.39, 0.61]] {
            Loop 17 {
                col := A_Index - 1, x := Round(w * (bounds[1] + (bounds[2] - bounds[1]) * col / 16))
                shade := (Mod(col, 2) ? 52 : 156) + light
                PaintFixture(buf, w, x, 117, 2, 88, shade * 0x010101)
            }
        }
        Loop 17 {
            col := A_Index - 1, x := Round(w * (0.66 + 0.19 * col / 16))
            shade := 66 + col * 3 + light
            PaintFixture(buf, w, x, 117, 2, 88, shade * 0x010101)
        }
    }
    if (scene = 6 || scene = 20 || scene = 21)
        PaintFixture(buf, w, 227, 148, 30, 24, 0xFFAA20)
    if (scene = 24 || scene = 26)
        PaintFixture(buf, w, 222, 162, 36, 34, 0xFFAA20) ; ниже сетки сравнения мира, в сцене 25 его нет
    if (scene = 28)
        PaintFixture(buf, w, 210, 162, 36, 34, 0xC28E24) ; смещение влево на 12 px после D
    if (scene = 28 || scene = 29)
        PaintFixture(buf, w, 324, 162, 36, 34, 0xFFCB18) ; яркий, но геометрически отдельный сосед
    if (scene = 9) {
        PaintFixture(buf, w, 216, 144, 36, 36, 0xFFCB18)
        PaintFixture(buf, w, 324, 144, 36, 36, 0xB58030)
    }
    if (scene = 7) {
        PaintFixture(buf, w, 288, 96, 112, 22, 0xCBCB00)
        PaintFixture(buf, w, 335, 104, 20, 8, 0x010101)
    }
    if (scene = 7 || scene = 11) {
        PaintFixture(buf, w, 310, 212, 136, 55, 0x252533)
        PaintFixture(buf, w, 322, 226, 112, 22, 0xEEEEEE)
        PaintFixture(buf, w, 350, 234, 26, 7, 0x202020)
    }
    if (scene = 10)
        PaintFixture(buf, w, 156, 253, 104, 24, 0xF1F1F1) ; экран устранения поверх HUD
    if (scene = 12)
        PaintFixture(buf, w, 16, 224, 112, 32, 0xCBCB00) ; «Играть» в лобби
    if (scene >= 13 && scene <= 15) {
        ; Те же колонки, что в навигации: слева плавный перепад, справа плотные края.
        Loop 17 {
            col := A_Index - 1
            x := Round(w * (0.15 + (0.34 - 0.15) * col / 16))
            PaintFixture(buf, w, x, 117, 2, 88, (64 + col * 3) * 0x010101)
            x := Round(w * (0.66 + (0.85 - 0.66) * col / 16))
            PaintFixture(buf, w, x, 117, 2, 88, (Mod(col, 2) ? 52 : 206) * 0x010101)
        }
        if (scene >= 14)
            PaintFixture(buf, w, 233, 124, 16, 32, scene = 14 ? 0xDDDDDD : 0x202020)
        PaintFixture(buf, w, 236, 140, 9, 9, 0xEE2727) ; прицел не меняется
    }
    if (scene >= 17 && scene <= 19) {
        PaintFixture(buf, w, 336, 63, 86, 98, 0xDA8848) ; доминирующая, но невалидная область
        if (scene >= 18) {
            cx := scene = 18 ? 208 : 240, k := w / 1280 * 1.9
            for spec in [[-7, 0, 14, 36], [-20, 35, 40, 21], [-12, 56, 24, 14], [-14, 70, 10, 24], [4, 70, 10, 24]]
                PaintFixture(buf, w, cx + Round(spec[1] * k), 126 + Round(spec[2] * k)
                    , Round(spec[3] * k), Round(spec[4] * k), 0xD08048)
        }
    }
    if (scene >= 30 && scene <= 32) {
        ; Две золотые части выше прицела дают крупную метку впереди.
        ; До зоны свечения в мире не доходят.
        PaintFixture(buf, w, 226, 40, 14, 15, 0xE89028)
        PaintFixture(buf, w, 240, 55, 14, 14, 0xE89028)
    }
    if (scene = 32) {
        ; Ещё одно направление, но группа меньше фронтальной при любом
        ; штатном шаге скана. Фон остаётся прежним, HUD на месте.
        PaintFixture(buf, w, 165, 46, 11, 12, 0xE89028)
        PaintFixture(buf, w, 176, 58, 11, 12, 0xE89028)
    }
    info := Buffer(40, 0)
    NumPut("UInt", 40, "Int", w, "Int", -h, "UShort", 1, "UShort", 32, info)
    return {w:w, h:h, buf:buf, info:info}
}

PaintFixture(buf, stride, x, y, w, h, color) {
    Loop h {
        offset := ((y + A_Index - 1) * stride + x) * 4
        Loop w
            NumPut("UInt", color, buf, offset + (A_Index - 1) * 4)
    }
}
