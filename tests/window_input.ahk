#Requires AutoHotkey v2.0
#NoTrayIcon
#Include ../fortnite_bot.ahk
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
            , TestResultBlink, TestReturnOnlyResults, TestRepeatedPrompt, TestStaticFallback] {
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
    shot := TickFixture(a)
    Check(!shot.enemyReading && !ST.enemySeenSeq && !ST.shots && !ST.leftDown
        , "два кадра с опорой и красным прицелом без фигуры не запускают бой")
    BuildVisionGui() ; проверяем подпись и отрисовку, не показывая окно поверх приёмника
    try {
        SetFixtureFrame(a, 3)
        shot := TickFixture(a)
        Check(shot.enemyReading && shot.enemyReading.src = "движение" && !ST.enemySeenSeq && !ST.shots
            , "захваченный первый кандидат виден, но ещё не подтверждён")
        DrawVisionFrame()
        Check(VIS.lastId = shot.captureId && InStr(VIS.txt.Value, "первый: движение"), "F3 показывает первый замер на этом кадре")
        SetFixtureFrame(a, 4)
        shot := TickFixture(a)
        Check(ST.enemySeenSeq = shot.captureId && ST.enemySrc = "движение" && ST.shots = 1
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
    Check(stats.Length > 0, "есть выборка до диагностических снимков")
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
        Check(ST.lastShot = live && ST.inputEpoch = epoch && !ST.held.Count
            , "диагностические кадры не подменяют рабочий и не дают ввода")
        ExpectKey(a, SC.e, 3, 3)
        ExpectKey(b, SC.e, 1, 1)
    } finally {
        try DirDelete(folder, true)
    }
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
    Check(ST.stuckRecoverKey = SC.d && !ST.guidedUntil && ST.held.Has(SC.d)
        , "подтверждённая цель не заставляет всё время идти в стену: переключаемся на обход")
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
        TickFixture(b)
        Check(ST.tgt = p && p.sameHits = 1, "первый замер после таймерного отпускания")
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

ExpectKey(h, scanCode, downs, ups, waitMs := 250) {
    vk := VkFromScan(scanCode), deadline := A_TickCount + waitMs
    Check(vk, "неизвестная клавиша " scanCode)
    loop {
        count := SendMessage(0x8021, vk, 0, , "ahk_id " h, , , , 1000)
        d := count & 0xFFFF, u := count >> 16
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
    Loop 20
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
    Loop 24 {
        row := A_Index - 1
        Loop 24 {
            col := A_Index - 1, shade := 63 + Mod(col + row * 3, 42)
            PaintFixture(buf, w, col * 20, row * 12, 20, 12, shade * 0x010101)
        }
    }
    if (scene < 7 || scene = 9 || scene = 10 || scene >= 13) {
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
    if (scene = 5)
        PaintFixture(buf, w, 184, 166, 111, 45, 0xC2C2C2) ; локальный край поперёк центра
    if (scene = 6)
        PaintFixture(buf, w, 227, 148, 30, 24, 0xFFAA20)
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
    if (scene >= 17) {
        PaintFixture(buf, w, 336, 63, 86, 98, 0xDA8848) ; доминирующая, но невалидная область
        if (scene >= 18) {
            cx := scene = 18 ? 208 : 240, k := w / 1280 * 1.9
            for spec in [[-7, 0, 14, 36], [-20, 35, 40, 21], [-12, 56, 24, 14], [-14, 70, 10, 24], [4, 70, 10, 24]]
                PaintFixture(buf, w, cx + Round(spec[1] * k), 126 + Round(spec[2] * k)
                    , Round(spec[3] * k), Round(spec[4] * k), 0xD08048)
        }
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
