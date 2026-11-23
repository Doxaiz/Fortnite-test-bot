#Requires AutoHotkey v2.0
#NoTrayIcon
#Include ../fortnite_bot.ahk

; Самостоятельный тест на синтетических кадрах. Не запускает Init() или Fortnite.
exitCode := 0
try {
    Check(!UI.gui && !ST.running && !UI.hkKeys.Length, "при #Include интерфейс и хоткеи не запускаются")
    tempStem := A_Temp "\forma-test-" ProcessExist() "-" A_TickCount
    CFG.logFile := tempStem ".log", CFG.iniFile := tempStem ".ini"
    CFG.keepAwake := false, CFG.audioAlert := false
    CFG.webhookStop := false, CFG.webhookRound := false, CFG.cloudGaming := false
    ; Никогда не искать реальное игровое окно, даже если оно запущено.
    CFG.winTitle := "ahk_class FORMA_NoSuchWindow_ForTest"
    CFG.winTitleAlt := CFG.winTitle
    CFG.winExe := "ahk_exe FORMA_NoSuchProcess_ForTest.exe"
    if (A_Args.Length = 1 && A_Args[1] = "--bench-menu") {
        BenchmarkFrameMenu()
    } else if (A_Args.Length = 1 && A_Args[1] = "--bench-prompt") {
        BenchmarkPromptReader()
    } else if (A_Args.Length = 1 && A_Args[1] = "--bench-combat") {
        BenchmarkCombatScan()
    } else {
        for test in [TestBuildAndRestart, TestTickOutcomes, TestSkippedScanStages, TestCaptureHistory, TestInputGuards, TestPixelRatios
            , TestHudBelongsToCapture, TestDeferredAndInterruptedEvidence, TestMenuFromCurrentPixels, TestLobbyPlatePass
            , TestQueueOutcome, TestEndHandoff, TestReturnEvidence, TestEndStopGuards, TestCalibrationIsolation
            , TestNavigationState, TestMotionUsesSameWindow
            , TestModeScenes, TestLeaveSequence, TestLeaveCancellation, TestChestApproach, TestChestSelection
            , TestPromptPixels, TestPromptScanFreshness, TestPromptAttempts, TestPromptGeometry, TestUnchangedPrompt
            , TestEnemyEvidence, TestCombatPreemption, TestCombatAimCorrection, TestCombatRetreat
            , TestCombatScanFreshness, TestCombatPixels, TestProjectedScenery
            , TestAlternativeFigure, TestEnemySwitch, TestLocalMotion, TestFireGate, TestSoundFrames
            , TestRoamPriority, TestHoldOwnership, TestDryPairGuards, TestCalibrationExport] {
            test()
            FileAppend("OK: " test.Name "`n", "*", "UTF-8")
        }
    }
} catch as e {
    FileAppend("FAIL: " e.Message " (line " e.Line ")`n", "**", "UTF-8")
    exitCode := 1
} finally {
    if IsSet(tempStem) {
        try FileDelete(tempStem ".log")
        try FileDelete(tempStem ".ini")
    }
}
ExitApp(exitCode)

Check(ok, description) {
    if !ok
        throw Error(description, -1)
}

TestBuildAndRestart() {
    global CFG, ST, LogThrMap, FORMA_VERSION
    info := FormaBuildInfo()
    Check(InStr(info, "FORMA v" FORMA_VERSION) && InStr(info, A_AhkVersion), "версия сборки и AHK")
    Check(InStr(info, A_ScriptName) && !InStr(info, A_ScriptDir), "имя запущенного файла без полного пути")

    ST.focusLostAt := 1000, ST.focusBackAt := 1500, ST.focusNoteAt := 2000, ST.bgWarned := true
    ST.playInputSuspended := true, ST.playFocused := 0
    ST.tickProfile := {}, ST.lastTickMs := 820, ST.tickMs := 820
    ST.fastTicks := 5, ST.slowTicks := 2, ST.cancelHold := true
    LogThrMap["[focus]"] := 2000, LogThrMap["[tickperf]"] := 2000, LogThrMap["other"] := 2000
    ResetRunDiagnostics()
    Check(!ST.focusLostAt && !ST.focusBackAt && !ST.focusNoteAt && !ST.bgWarned
        && !ST.playInputSuspended && ST.playFocused = -1, "старая потеря фокуса не переносится")
    Check(!ST.tickProfile && !ST.lastTickMs && !ST.tickMs, "предыдущий тик не переносится")
    Check(!ST.fastTicks && !ST.slowTicks && ST.cancelHold, "диагностика не меняет защёлку поиска")
    Check(!LogThrMap.Has("[focus]") && !LogThrMap.Has("[tickperf]") && LogThrMap.Has("other"), "сбрасываются только нужные троттлы")
    ST.cancelHold := false

    ST.stepBoost := CFG.stepBoostMax - 1, ST.slowTicks := 2
    TuneScanStep(700)
    Check(ST.stepBoost = CFG.stepBoostMax, "прибавка +2 не превышает максимальный шаг")
}

TestTickOutcomes() {
    global ST
    ST.tickBusy := true, ST.tickDeadline := A_TickCount - 1000
    try {
        for expected in ["стоп", "тест мыши F6", "запрос сторожа", "бюджет"] {
            ST.running := expected != "стоп"
            ST.mouseCalActive := expected = "тест мыши F6"
            ST.tickAbort := expected != "бюджет"
            ST.tickAborted := false
            caught := false
            try TickCheck("скан окна")
            catch TickInterrupted as e {
                caught := true
                Check(e.Message = expected && e.Extra = "скан окна", "различаются причины прерывания: " expected)
            }
            Check(caught && ST.tickAborted, "прерывание не превращается в продолжение тика")
        }
        Check(!(Error("бюджет") is TickInterrupted), "обычная ошибка не становится служебным прерыванием")
    } finally {
        ST.tickBusy := false, ST.tickDeadline := 0, ST.running := false
        ST.tickAbort := false, ST.tickAborted := false, ST.mouseCalActive := false
    }
}

TestSkippedScanStages() {
    global ST
    profile := {gen:1, at:100, stage:"подготовка", parts:Map(), frame:"1280×720"}
    TickStage(profile, "захват", 109)
    TickStage(profile, "сцена/HUD", 125)
    TickStage(profile, "", 160)
    profile.totalMs := 60, profile.step := "скан", profile.outcome := "бюджет"
    profile.scene := "GAME", profile.skipped := 2
    text := TickProfileText(profile)
    for fragment in ["60 мс", "захват 16 мс", "сцена/HUD 35 мс", "сканов отложено +2", "исход: бюджет"]
        Check(InStr(text, fragment), "профиль содержит: " fragment)
    Check(!InStr(text, "действия"), "не существовавший этап не попадает в профиль")

    ST.running := true, ST.paused := true
    previous := ST.fastTicks
    try {
        Tick()
        result := ST.tickProfile
        Check(result.outcome = "пауза" && result.parts.Count = 1, "пауза профилируется без захвата")
        Check(ST.fastTicks = previous && !ST.tickBusy && !ST.tickLiveCount, "пауза не влияет на шаг сканов и не оставляет тик живым")
        ST.paused := false
        epoch := ST.inputEpoch, scene := ST.state
        Tick()
        Check(ST.tickProfile.outcome = "нет окна игры", "не найденное окно не считается кадром")
        Check(ST.playInputSuspended && ST.inputEpoch = epoch + 1 && ST.state = scene
            , "один сброс ввода при пропаже окна, без смены сцены")
        Tick()
        Check(ST.inputEpoch = epoch + 1 && !ST.lastShot, "ожидание окна не увеличивает поколение каждый тик")
    } finally {
        ST.running := false, ST.paused := false
        ST.playInputSuspended := false, ST.playFocused := -1
    }
}

TestCaptureHistory() {
    global ST
    a := 901234, b := 901235
    ST.capHistory := 0
    try {
        old := CaptureHistoryFixture(a, 12, "frame")
        old.gen -= 1
        RememberTickCapture(old)
        unknown := CaptureHistoryFixture(a, 12, "failed")
        unknown.capture.w := 0
        RememberTickCapture(unknown)
        Check(!ST.capHistory && !CaptureHistoryLines(a).Length, "нет выборки без размера или от старого тика")

        front := CaptureHistoryFixture(a, 20, "frame")
        front.capture.attempts.Push({method:"PrintWindow", ms:10, outcome:"изображение"})
        fallback := CaptureHistoryFixture(a, 260, "late")
        fallback.capture.attempts.Push({method:"PrintWindow", ms:248, outcome:"одноцветный кадр"}
            , {method:"DC окна", ms:10, outcome:"изображение"})
        failed := CaptureHistoryFixture(a, 14, "failed", false)
        failed.capture.attempts.Push({method:"PrintWindow", ms:8, outcome:"ошибка GDI"}
            , {method:"DC окна", ms:4, outcome:"одноцветный кадр"})
        aborted := CaptureHistoryFixture(a, 300, "", false)
        aborted.capture.attempts.Push({method:"PrintWindow", ms:298, outcome:"прервано: бюджет"})
        for profile in [front, fallback, failed, aborted]
            RememberTickCapture(profile)
        lines := CaptureHistoryLines(a)
        Check(lines.Length = 2 && !CaptureHistoryLines(b).Length, "разные фокус и окно не смешиваются")
        Check(InStr(lines[1], "[capture-stats] 800x450") && !InStr(lines[1], a)
            && InStr(lines[1], "DryRun / фокус · n=2 frame=2 over250=1 failed=0 aborted=0 fallback=1")
            && InStr(lines[1], "всего median=140.00 p95=260.00")
            && InStr(lines[1], "PrintWindow n=2 image=1 empty=1 other=0 median=129.00 p95=248.00")
            && InStr(lines[1], "BitBlt n=1 image=1 empty=0 other=0 median=10.00 p95=10.00")
            , "резерв не удваивает кадры, просрочка входит в полученные, методы измеряются отдельно")
        Check(InStr(lines[2], "DryRun / фон · n=2 frame=0 over250=0 failed=1 aborted=1 fallback=1")
            && InStr(lines[2], "PrintWindow n=2 image=0 empty=0 other=2")
            && InStr(lines[2], "BitBlt n=1 image=0 empty=1 other=0"), "отказы и прерывания в фоне не смешиваются с кадрами")

        ; Первый замер другого размера сбрасывает группу. После 121 замера
        ; остаются только 2..121, среднее двух центральных; p95 — ранг 114.
        Loop 121
            RememberTickCapture(CaptureHistoryFixture(a, A_Index, "frame", true, 480))
        line := CaptureHistoryLines(a)[1]
        Check(ST.capHistory.samples.Length = 120 && CaptureHistoryLines(a).Length = 1
            && InStr(line, "480x450") && InStr(line, "n=120 frame=120 over250=0")
            && InStr(line, "всего median=61.50 p95=115.00"), "ограниченное кольцо вытесняет старые замеры, размер не смешивается")
        changed := CaptureHistoryFixture(a, 1, "frame", true, 480)
        changed.captureContext.dry := false
        RememberTickCapture(changed)
        Check(ST.capHistory.samples.Length = 1 && InStr(CaptureHistoryLines(a)[1], "без DryRun"), "смена DryRun начинает новую группу")
        RememberTickCapture(CaptureHistoryFixture(b, 2, "frame"))
        Check(!CaptureHistoryLines(a).Length && ST.capHistory.hwnd = b
            && ST.capHistory.samples.Length = 1, "смена окна начинает новую группу")
        ResetRunDiagnostics()
        Check(!ST.capHistory && !CaptureHistoryLines(b).Length, "новая сессия не наследует статистику")
    } finally ST.capHistory := 0
}

CaptureHistoryFixture(hwnd, ms, result, focused := true, w := 800) {
    global ST
    profile := {gen:ST.tickGen, captureContext:{hwnd:hwnd, focused:focused, dry:true, mode:"auto"}
        , capture:{w:w, h:450, ms:ms, attempts:[]}}
    if (result != "")
        profile.captureResult := result
    return profile
}

TestInputGuards() {
    global CFG, ST, SC
    ST.running := true, ST.hwnd := 0
    CFG.dryRun := true, CFG.bgMode := false
    ; Даже при регрессии игровой ввод невозможен: нет окна и отклика.
    ST.respOk := false, ST.respAt := A_TickCount
    epoch := ST.inputEpoch
    seq := ST.cameraSeq
    try {
        Check(!InputDownAllowed(epoch), "DryRun запрещает начало ввода")
        Check(!KeyDown(SC.w) && !TapKey(SC.space), "DryRun не создаёт удержаний клавиатуры")
        Check(!MouseDown() && !AdsSet(true) && !MoveCursorHuman(1, 1), "DryRun не нажимает и не двигает мышь")
        Check(!MouseRel(10) && ST.cameraSeq = seq, "DryRun не отправляет поворот камеры")
        Check(!ST.held.Count && !ST.leftDown && !ST.adsOn, "не сохраняются фиктивные удержания")
        Check(!MouseUp() && !AdsSet(false), "без удержания бота нечего отпускать")
        Check(!ZeroNetSmoothStep(10, 0).ok && ST.cameraSeq = seq, "AFK XP проходит тот же шлюз DryRun")
        CFG.dryRun := false
        Check(InputDownAllowed(epoch) && !InputDownAllowed(epoch - 1), "правильное поколение только в рабочем режиме")
        Check(!KeyDown(SC.w) && !ST.held.Count, "без целевого окна нет системного ввода")
    } finally {
        ST.running := false, CFG.dryRun := true
    }
}

TestPixelRatios() {
    w := 19, h := 13, stride := (w + 3) * 4
    shot := {w:w, h:h, stride:stride, buf:Buffer(stride * h, 0xFF)}
    Loop h {
        y := A_Index - 1
        Loop w {
            x := A_Index - 1
            v := x * 17 + y * 23
            b := Mod(v, 256), g := Mod(v * 3, 256), r := Mod(v * 5, 256)
            NumPut("UChar", b, "UChar", g, "UChar", r, shot.buf, y * stride + x * 4)
        }
    }
    ; Порог тёмного — строго <120, яркого — включительно >=40. Четвёртый
    ; байт намеренно отличен от нуля, в яркость он не входит.
    NumPut("UInt", 0xFF282827, shot.buf, 0)
    NumPut("UInt", 0xFF282828, shot.buf, 16)
    Check(DarkRatio(shot, [0, 0, 0.30, 0.10]) = 0.5, "точная граница тёмного пикселя")
    Check(BrightRatio(shot, [0, 0, 0.30, 0.10], 40) = 0.5, "точная граница яркого пикселя")
    for region in [[0, 0, 1, 1], [0.13, 0.07, 0.89, 0.85], [0.67, 0.68, 1, 1]] {
        Check(DarkRatio(shot, region) = ByteRatio(shot, region, true), "DarkRatio: совпадают выборка и формула")
        for threshold in [0, 40, 165, 170, 255]
            Check(BrightRatio(shot, region, threshold) = ByteRatio(shot, region, false, threshold), "BrightRatio: совпадают выборка и формула")
    }
}

; Эталон старого чтения по одному байту на канал.
ByteRatio(shot, region, dark, threshold := 0) {
    rect := RegionToPixels(shot, region)
    hits := 0, total := 0, y := rect.y1
    while (y < rect.y2) {
        x := rect.x1
        while (x < rect.x2) {
            offset := y * shot.stride + x * 4
            b := NumGet(shot.buf, offset, "UChar"), g := NumGet(shot.buf, offset + 1, "UChar")
            r := NumGet(shot.buf, offset + 2, "UChar")
            if (dark ? r + g + b < 120 : (299 * r + 587 * g + 114 * b) // 1000 >= threshold)
                hits += 1
            total += 1, x += 4
        }
        y += 4
    }
    return total ? hits / total : 0.0
}

; Синтетические BGRX-кадры одного размера. Обычный серый фон не даёт
; затемнения итогов, совпадений по кнопкам или полосам. Метаданные не
; указывают на настоящее окно, а тесты не вызывают захват или ввод.
SceneFixture(id, at, kind := "blank", hwnd := 100) {
    global ST
    w := 480, h := 288, stride := w * 4
    shot := {captureId:id, capturedAt:at, hwnd:hwnd, w:w, h:h, stride:stride
        , x:0, y:0, buf:Buffer(stride * h, 0x60)
        , inputEpochAtCapture:ST.inputEpoch, cameraSeqAtCapture:ST.cameraSeq}
    switch kind {
        case "hud", "falseHp":
            FixtureRect(shot, kind = "hud" ? 24 : 64, 256, 80, 20, 0x2ABA31)
            FixtureRect(shot, 236, 142, 9, 5, 0xFFFFFF)
        case "play", "cancel":
            FixtureRect(shot, 16, 224, 112, 32, kind = "play" ? 0xCBCB00 : 0xFFE9B4)
        case "results":
            ; Плашка с тёмными буквами попадает в фильтры геометрии v11.
            FixtureRect(shot, 288, 96, 112, 22, 0xCBCB00)
            FixtureRect(shot, 335, 104, 20, 8, 0x010101)
        case "leave":
            FixtureRect(shot, 340, 34, 94, 24, 0xD62F30)
        case "confirm", "ambiguousConfirm":
            FixtureRect(shot, 138, 137, 220, 95, 0x262639)
            FixtureRect(shot, 186, 170, 104, 24, kind = "confirm" ? 0xD62F30 : 0xCBCB00)
            if (kind = "ambiguousConfirm")
                FixtureRect(shot, 222, 176, 23, 7, 0x010101)
    }
    return shot
}

FixtureRect(shot, x, y, w, h, color) {
    Loop h {
        offset := (y + A_Index - 1) * shot.stride + x * 4
        Loop w
            NumPut("UInt", color, shot.buf, offset + (A_Index - 1) * 4)
    }
}

ResetSceneFixture() {
    global CFG, ST
    ResetSceneEvidence()
    ST.state := "UNKNOWN", ST.pendingState := "", ST.pendingCount := 0, ST.pendingSince := 0
    ST.queuePending := false, ST.queueSeen := false, ST.cancelHold := false
    ST.mmEnterAt := 0, ST.mmSince := 0, ST.lastFlipAt := 0, ST.lastQueueT := 0
    ST.matchStarted := false, ST.matchFromQueue := false
    ST.stepBoost := 0, ST.scanWork := 0, CFG.dryRun := true
    CFG.featReward := false, CFG.botMode := "auto"
}

TestHudBelongsToCapture() {
    global CFG, ST
    ResetSceneFixture()
    t := 10000
    first := SceneFixture(1, t, "hud")
    Check(DetectState(first, 0, t + 80) = "GAME", "полоса HP и прицел подтверждают матч")
    work := ST.scanWork, evidence := first.hudEvidence
    Check(evidence.confirmed && FrameHealth(first, true).hp.run = 80, "HUD использует измерение на том же кадре")
    Check(FrameHudEvidence(first, true) = evidence && ST.scanWork = work, "повторный запрос не расходует бюджет")
    Check(ST.hudLastT = t && ST.hudFoundSeq = first.captureId, "память хранит время захвата, а не время детектора")

    second := SceneFixture(2, t + 100, "falseHp")
    ST.scanWork := 0
    Check(DetectState(second, 0, t + 100) = "UNKNOWN", "старый HUD не начинает новый матч")
    Check(second.hudEvidence.score >= 3 && !second.hudEvidence.confirmed, "сильные признаки без валидного HP не подтверждают HUD")
    Check(FrameHealth(second, true).hp.pct = -1 && ST.hudLastT = t, "HP прежнего кадра не подставляется вместо неизвестного")

    ST.state := "GAME", ST.scanWork := 0
    held := SceneFixture(3, t + CFG.hpSeenWindowMs - 1)
    Check(DetectState(held, 0, held.capturedAt) = "GAME" && !held.hudEvidence.confirmed, "память удерживает только принятый матч")
    Check(ST.hudLastT = t && ST.hudFoundSeq = held.captureId && !ST.hudFound, "кадр без полосы не обновляет время HUD и рамку")
    late := SceneFixture(4, t + CFG.hpSeenWindowMs)
    ST.scanWork := 0
    Check(DetectState(late, 0, late.capturedAt) = "UNKNOWN", "память HUD истекает с момента захвата")
    Check(SettleScene("UNKNOWN", late.capturedAt) = "GAME", "антидребезг сцены отдельно от замера HUD")
    Check(SettleScene("UNKNOWN", t + Max(CFG.hudLostMs, CFG.hpSeenWindowMs + CFG.sceneHoldMs)) = "UNKNOWN"
        , "матч не удерживается бесконечно без HUD")
    ST.phase := "bus", ST.phaseAt := t, ST.busAt := t, ST.busJumped := true
    Check(MatchPhase(held, held.capturedAt) && ST.phase = "bus", "память HUD не подтверждает приземление")
    ST.scanWork := 0
    landed := SceneFixture(5, t + 2700, "hud")
    Check(DetectState(landed, 0, landed.capturedAt) = "GAME" && !MatchPhase(landed, landed.capturedAt)
        && ST.phase = "loot", "HUD этого кадра позволяет завершить фазу полёта")

    ST.cancelHold := true, ST.lastShot := first
    ResetSceneEvidence()
    Check(!ST.menuCache && !ST.hudLastT && !ST.hudFoundSeq && !ST.lastShot && ST.cancelHold
        , "новый сеанс забывает кадры, но сброс снимков не снимает ручную паузу")
}

TestDeferredAndInterruptedEvidence() {
    global CFG, ST
    ResetSceneFixture()
    good := SceneFixture(10, 10000, "hud")
    Check(DetectState(good, 0, 10000) = "GAME", "есть ранее проверенный HUD")
    oldMenu := ST.menuCache, oldHud := ST.hudFoundSeq

    ST.scanWork := CFG.scanPerTickMax
    deferred := SceneFixture(11, 10050, "hud")
    skipped := ST.scanSkipped
    evidence := FrameHudEvidence(deferred, true)
    Check(evidence.score >= 3 && !evidence.confirmed && !deferred.HasOwnProp("healthReading")
        , "отложенный HP не выдаётся за измерение и не подтверждает HUD")
    Check(!FrameHealth(deferred, true) && ST.scanSkipped = skipped + 1, "отсрочка учитывается один раз на кадр")

    shot := SceneFixture(12, 10100, "hud")
    ST.scanWork := 0
    ExpectScanInterrupt(shot, FrameHudEvidence)
    Check(!shot.HasOwnProp("hudEvidence") && ST.hudFoundSeq = oldHud && ST.hudLastT = good.capturedAt
        , "прерывание после поиска полосы не публикует частичный HUD")
    ExpectScanInterrupt(shot, FrameHealth)
    Check(!shot.HasOwnProp("healthReading"), "прерванный замер HP/щита не запоминается")
    ST.scanMenuAt := A_TickCount - CFG.scanMenuMs - 1
    menuAt := ST.scanMenuAt
    ExpectScanInterrupt(shot, FrameMenu)
    Check(!shot.HasOwnProp("menuEvidence") && ST.menuCache = oldMenu && ST.scanMenuAt = menuAt
        , "прерванный скан не помечает меню обновлённым")
    ST.scanWork := 0
    Check(DetectState(shot, 0, shot.capturedAt) = "GAME" && ST.hudFoundSeq = shot.captureId
        , "после прерывания повторный полный анализ выполняется")
}

ExpectScanInterrupt(shot, scan) {
    global ST
    buf := shot.buf, probe := {reads:0}
    shot.DefineProp("buf", {Get: InterruptOnSecondRead.Bind(buf, probe)})
    ST.running := true, ST.tickBusy := true, ST.tickDeadline := 0
    ST.tickAbort := false, ST.tickAborted := false
    try {
        caught := false
        try scan(shot)
        catch TickInterrupted as e {
            caught := true
            Check(e.Message = "запрос сторожа", "сработала штатная контрольная точка")
        }
        Check(caught && probe.reads >= 2 && ST.tickAborted, "прерывание на втором проходе: " scan.Name)
    } finally {
        shot.DefineProp("buf", {Value:buf})
        ST.running := false, ST.tickBusy := false, ST.tickAbort := false, ST.tickAborted := false
    }
}

InterruptOnSecondRead(buf, probe, *) {
    global ST
    probe.reads += 1
    if (probe.reads = 2)
        ST.tickAbort := true
    return buf
}

TestMenuFromCurrentPixels() {
    global CFG, ST
    ResetSceneFixture()
    results := SceneFixture(20, 30000, "results")
    Check(DetectState(results, 0, results.capturedAt) = "END_SCREEN" && FrameActionButton(results, "END_SCREEN")
        , "результаты с кнопкой полного скана")
    menu := FrameMenu(results)
    ResetCaches()
    work := ST.scanWork
    Check(FrameMenu(results) = menu && ST.scanWork = work, "смена сцены не повторяет скан того же буфера")

    ST.scanWork := CFG.scanPerTickMax
    ST.scanMenuAt := A_TickCount - CFG.scanMenuMs - 1
    before := ST.scanSkipped
    gone := SceneFixture(21, 30100)
    Check(DetectState(gone, 0, gone.capturedAt) = "UNKNOWN" && !FrameActionButton(gone, "END_SCREEN")
        , "кнопка итогов исчезла: старый результат не получает действие")
    Check(!FrameMenu(gone).results.Length && ST.scanSkipped = before + 1, "отложенный скан оставляет только проверенные по пикселям подсказки")
    similar := SceneFixture(22, 30200, "results")
    Check(DetectState(similar, 0, similar.capturedAt) = "END_SCREEN" && !FrameActionButton(similar, "END_SCREEN")
        , "цвет на старом месте итогов ещё не даёт координат для клика")
    game := SceneFixture(23, 30300, "results")
    FixtureRect(game, 24, 256, 80, 20, 0x2ABA31)
    FixtureRect(game, 236, 142, 9, 5, 0xFFFFFF)
    ST.scanWork := CFG.scanPerTickMax - 1   ; HP влезает, новый скан плашек нет
    Check(DetectState(game, 0, game.capturedAt) = "GAME" && FrameMenu(game).results.Length
        && !FrameActionButton(game, "END_SCREEN"), "старый контур итогов не перебивает HUD текущего кадра")

    ResetSceneFixture()
    play := SceneFixture(24, 40000, "play")
    Check(DetectState(play, 0, play.capturedAt) = "MENU" && FrameActionButton(play, "MENU"), "цвет и контур текущей кнопки Играть")
    ST.scanWork := CFG.scanPerTickMax
    similar := SceneFixture(25, 40100, "play")
    Check(DetectState(similar, 0, similar.capturedAt) = "MENU" && !FrameActionButton(similar, "MENU")
        , "старый контур лобби не разрешает клик даже при совпадении цвета")
    cancel := SceneFixture(26, 40200, "cancel")
    Check(DetectState(cancel, 0, cancel.capturedAt) = "MATCHMAKING" && FrameMenu(cancel).blocksGame
        && !FrameActionButton(cancel, "MENU") && !ST.playSeenAt, "Играть сменилось на Отменить, пока полный скан отложен")

    moved := SceneFixture(27, 40300, "play", 101)
    Check(FrameMenu(moved).kind = "?" && !FrameMenu(moved).fresh, "бокс не переносится на другое окно тех же размеров")
    ResetSceneFixture()
    cancel := SceneFixture(28, 41000, "cancel")
    Check(DetectState(cancel, 0, cancel.capturedAt) = "MATCHMAKING" && FrameMenu(cancel).cream && FrameMenu(cancel).blocksGame
        , "кремовый скан блокирует игровые действия и без старого жёлтого бокса")
}

; Сравнение общего прохода с двумя независимыми на одинаковых пикселях.
; В кадрах есть и положительные примеры разных раскладок, и объекты-обманки.
MenuFixture(w, h, kind) {
    stride := (w + 3) * 4
    shot := {captureId:1, hwnd:100, w:w, h:h, stride:stride, buf:Buffer(stride * h, 0x60)}
    if (kind = "wide")
        MenuFixturePlate(shot, 0.12, 0.51, 0.21, 0.11, 0xCBCB00, false)
    if (kind = "play")
        MenuFixturePlate(shot, 0.06, 0.78, 0.09, 0.065, 0xCBCB00, true)
    if (kind = "mixed")
        MenuFixturePlate(shot, 0.06, 0.73, 0.18, 0.088, 0xCBCB00, true)
    if (kind = "mixed" || kind = "cancel")
        MenuFixturePlate(shot, 0.045, 0.85, 0.158, 0.09, 0xFFE9B4, true)
    if (kind = "results" || kind = "mixed") {
        ; На малом кадре оставляем целую пустую строку ячеек между кнопками.
        rh := Round(h * 0.08 / 16) * 16 / h
        for i, y in [0.33, 0.45]
            MenuFixturePlate(shot, 0.65, Round(h * y / 16) * 16 / h, 0.25, rh
                , i = 1 ? 0xF7FE19 : 0xCBCB00, true)
    }
    if (kind = "clutter") {
        MenuFixturePlate(shot, 0.02, 0.84, 0.029, 0.075, 0xFFE9B4, false)
        MenuFixturePlate(shot, 0.61, 0.72, 0.31, 0.052, 0xCBCB00, false)
    }
    return shot
}

MenuFixturePlate(shot, x, y, w, h, color, text) {
    x := Round(shot.w * x), y := Round(shot.h * y)
    w := Round(shot.w * w), h := Round(shot.h * h)
    FixtureRect(shot, x, y, w, h, 0xA3000000 | color) ; ненулевой X-байт BGRX
    if text
        FixtureRect(shot, x + Round(w * 0.40), y + Round(h * 0.27)
            , Max(2, Round(w * 0.20)), Max(2, Round(h * 0.46)), 0x12010101)
}

CheckMenuBox(actual, expected, label) {
    Check(!!actual = !!expected, label ": наличие")
    if !expected
        return
    for prop in ["x", "y", "w", "h", "cx", "cy", "n", "area", "fill", "cells"]
        Check(actual.%prop% = expected.%prop%, label ": поле " prop)
}

CheckLobbyPlates(shot, label) {
    global CFG
    plates := ScanLobbyPlates(shot)
    yellow := FindYellowButtons(shot, CFG.regLobbyBtn), cream := FindCreamButton(shot)
    Check(plates.yellow.Length = yellow.Length, label ": число жёлтых плашек")
    for i, box in yellow
        CheckMenuBox(plates.yellow[i], box, label ": жёлтая №" i)
    CheckMenuBox(plates.cream, cream, label ": кремовая")
    return plates
}

TestLobbyPlatePass() {
    global CFG, ST
    ResetSceneFixture()
    for size in [[480, 288], [1365, 767], [1920, 1080], [2560, 1080]] {
        w := size[1], h := size[2], label := w "x" h
        mixed := MenuFixture(w, h, "mixed")
        plates := CheckLobbyPlates(mixed, label " две плашки")
        Check(plates.yellow.Length = 1 && plates.cream, label ": оба цвета в одной области")
        ST.menuCache := 0, ST.scanWork := 0
        m := FrameMenu(mixed)
        Check(m.fresh && m.kind = "play" && m.cream && m.blocksGame && ST.scanWork = 2
            , label ": полный скан различает обе плашки, не меняя расход бюджета")
        Check(m.results.Length = 2 && m.results[1].y < m.results[2].y
            && PickResultPlayAgain(mixed, m.results) = m.results[2], label ": порядок кнопок итогов не меняется")
        mixed.capturedAt := A_TickCount
        Check(DetectState(mixed, 0, mixed.capturedAt) = "MATCHMAKING"
            && !FrameActionButton(mixed, "MENU") && !FrameActionButton(mixed, "END_SCREEN")
            , label ": «Отменить» имеет приоритет даже при жёлтой плашке и кнопках итогов")
    }

    ; Левая кнопка выше узкой ROI и без штрихов: она видна только в широком скане.
    wide := MenuFixture(1365, 767, "wide")
    Check(!CheckLobbyPlates(wide, "верхняя раскладка").yellow.Length, "узкая область не содержит верхнюю кнопку")
    ST.menuCache := 0, ST.scanWork := 0
    m := FrameMenu(wide)
    Check(m.fresh && m.kind = "play" && m.box && !m.cream, "плотный поиск сохранён для верхней раскладки")
    ST.menuCache := 0, ST.scanWork := 0
    m := FrameMenu(MenuFixture(1365, 767, "play"))
    Check(m.fresh && m.kind = "play" && !ST.menuCache.lobby && ST.menuCache.lobbyY.Length = 1
        && m.box = ST.menuCache.lobbyY[1], "слишком узкая для плотного скана кнопка остаётся в кластерах")
    for kind in ["blank", "clutter"] {
        ST.menuCache := 0, ST.scanWork := 0
        shot := MenuFixture(1365, 767, kind)
        CheckLobbyPlates(shot, kind)
        m := FrameMenu(shot)
        Check(m.fresh && !m.box && !m.cream && !m.results.Length && !m.blocksGame
            , kind ": фон, маленькое светлое пятно и полоса без текста не дают действий")
    }

    ; Проверка именно равной границы: один пиксель теперь подходит обеим
    ; маскам, этот опыт не должен отнять кандидата у одного из цветов.
    blueMax := CFG.yBMax
    try {
        CFG.yBMax := CFG.creamBMin
        shot := MenuFixture(1365, 767, "blank")
        MenuFixturePlate(shot, 0.045, 0.80, 0.19, 0.11, 0xFFE900 | CFG.creamBMin, true)
        plates := CheckLobbyPlates(shot, "пересечение масок")
        Check(plates.yellow.Length = 1 && plates.cream, "при пересечении сохраняются обе независимые маски")
    } finally {
        CFG.yBMax := blueMax
        ResetSceneFixture()
    }
}

BenchmarkFrameMenu() {
    global ST, CFG, FORMA_VERSION
    ResetSceneFixture()
    DllCall("QueryPerformanceFrequency", "Int64*", &freq := 0)
    FileAppend("FORMA v" FORMA_VERSION " / AHK " A_AhkVersion " / " PixelBackendName() " / FrameMenu (ms)`n", "*", "UTF-8")
    ST.running := true, ST.tickBusy := true, ST.tickDeadline := 0
    try {
        for size in [[1280, 720], [1920, 1080]] {
            for kind in ["blank", "mixed"] {
                fixture := MenuFixture(size[1], size[2], kind), samples := ""
                Loop 13 {
                    shot := fixture.Clone(), shot.captureId := A_Index
                    ST.scanWork := 0, ST.scanMenuAt := A_TickCount - CFG.scanMenuMs
                    DllCall("QueryPerformanceCounter", "Int64*", &start := 0)
                    m := FrameMenu(shot)
                    DllCall("QueryPerformanceCounter", "Int64*", &stop := 0)
                    Check(m.fresh && ST.scanWork = 2, "benchmark: полный скан, без переиспользования результата")
                    if (A_Index > 2)
                        samples .= Format("{:.3f}", (stop - start) * 1000.0 / freq) "`n"
                }
                times := StrSplit(Sort(RTrim(samples, "`n"), "N"), "`n")
                FileAppend(size[1] "x" size[2] " " kind ": median=" times[6]
                    . " min=" times[1] " max=" times[-1] " (n=11)`n", "*", "UTF-8")
            }
        }
    } finally {
        ST.running := false, ST.tickBusy := false
    }
}

TestQueueOutcome() {
    global CFG, ST
    ResetSceneFixture()
    t := 50000
    search := SceneFixture(30, t, "cancel")
    raw := DetectState(search, 0, t)
    Check(raw = "MATCHMAKING" && SceneDuringQueue(raw, raw, search) = raw && ST.queuePending
        , "увидели поиск — ждём исход")

    ST.state := "GAME"   ; антидребезг может временно держать предыдущую сцену
    ST.hudWindow := search.hwnd, ST.hudLastT := t
    ST.mmEnterAt := 0, ST.scanWork := 0
    hold := SceneFixture(31, t + 80)
    raw := DetectState(hold, 0, hold.capturedAt)
    Check(raw = "GAME" && SceneDuringQueue(raw, raw, hold) = "UNKNOWN" && ST.queuePending
        , "удержанная память матча не завершает очередь")

    ST.state := "UNKNOWN", ST.pendingSince := t, ST.scanWork := 0
    first := SceneFixture(32, t + 3000, "hud")
    raw := DetectState(first, 0, first.capturedAt)
    Check(SceneDuringQueue(SettleScene(raw, first.capturedAt), raw, first) = "UNKNOWN", "первый кадр HUD проходит выдержку сцены")
    later := SceneFixture(33, first.capturedAt + CFG.sceneHoldMs, "hud")
    ST.scanWork := 0
    raw := DetectState(later, 0, later.capturedAt)
    candidate := SceneDuringQueue(SettleScene(raw, later.capturedAt), raw, later)
    Check(candidate = "GAME" && !ConfirmScene(candidate, later.capturedAt) && ST.queuePending
        , "даже после таймаута одиночный HUD не подтверждает принятую сцену")
    next := SceneFixture(34, later.capturedAt + 100, "hud")
    ST.scanWork := 0
    raw := DetectState(next, 0, next.capturedAt)
    candidate := SceneDuringQueue(SettleScene(raw, next.capturedAt), raw, next)
    Check(candidate = "GAME" && ConfirmScene(candidate, next.capturedAt) && ResolveQueueScene(candidate, next.capturedAt)
        && !ST.queuePending && !ST.cancelHold, "два подтверждённых кадра разрешают выход из ожидания в матч")

    ST.queuePending := true, ST.state := "UNKNOWN"
    Check(!ResolveQueueScene("END_SCREEN", t) && ST.queuePending, "затемнение итогов не подтверждает исход поиска")
    Check(ResolveQueueScene("MENU", t) && ST.cancelHold && ST.queuePending
        , "возврат через неизвестную сцену в лобби по-прежнему ставит паузу отмены")
    Check(!ResolveQueueScene("GAME", t) && ST.cancelHold && ST.queuePending, "сценой нельзя снять паузу игрока")
}

TestEndHandoff() {
    WithGroundFixture(CheckEndHandoff)
}

FixtureEnd(id, showAgain := true, showReturn := true, shiftX := 0) {
    shot := SceneFixture(id, A_TickCount, showAgain ? "results" : "blank")
    if showReturn
        PaintReturnFixture(shot, shiftX)
    shot.capturedAt := A_TickCount
    return shot
}

PaintReturnFixture(shot, shiftX := 0) {
    FixtureRect(shot, 310 + shiftX, 212, 136, 55, 0x252533)
    FixtureRect(shot, 322 + shiftX, 226, 112, 22, 0xEEEEEE)
    FixtureRect(shot, 350 + shiftX, 234, 26, 7, 0x202020)
}

CheckEndHandoff() {
    global CFG, ST
    CFG.featPlayAgain := true, CFG.featAutoQueue := true, CFG.endAction := "play_again"
    CFG.clickRetries := 2, CFG.verifyMs := 400, CFG.retryAfterMs := 600, CFG.endReturnAfterMs := 1200
    CFG.scanMenuMs := 0, CFG.lobbyDelaySec := 2, CFG.stopAfterMin := 0, CFG.maxRounds := 0
    CFG.lobbyStableMs := 400, CFG.playConfirmMs := 400, CFG.maxActionsPerMin := 0
    ResetEndHandoff()
    ST.lastClickT := 0, ST.state := "END_SCREEN", ST.roundActive := true, ST.roundCounted := false
    ST.queuePending := false, ST.cancelHold := false, ST.tokenShown := false, ST.tokenFoundMatch := false
    ST.tokenStopArmed := false, ST.finishMatchArmed := false, ST.lobbyRequeue := false, ST.lobbyCooldownUntil := 0
    ST.playSeenAt := 0, ST.inMatchT := 0, ST.mmEnterAt := 0, ST.menuCache := 0
    t := A_TickCount, rounds := ST.rounds, again := ST.clickAgain, queues := ST.clickQueue
    first := FixtureEnd(200), ST.scanWork := 0
    Check(DetectState(first, 0, t) = "END_SCREEN" && FrameActionButton(first, "END_SCREEN"), "вижу плашку итогов")
    for latch in ["cancelHold", "queuePending", "paused"] {
        ST.%latch% := true
        HandleEndScreen(first, t)
        Check(!ST.endRetry && ST.clickAgain = again && ST.rounds = rounds, "плашка не обходит блокировку " latch)
        ST.%latch% := false
    }
    stale := first.Clone(), stale.capturedAt -= CFG.tickBudgetMs + 1
    HandleEndScreen(stale, t)
    Check(!ST.endRetry && ST.rounds = rounds, "не используем распознанную плашку из просроченного кадра")
    HandleEndScreen(first, t)
    HandleEndScreen(first, t + 1000)
    Check(ST.endRetry = 1 && ST.clickAgain = again + 1 && ST.rounds = rounds + 1 && !ST.lobbyRequeue
        , "один кадр итогов не отправляет два клика и учитывает матч один раз")
    second := FixtureEnd(201), ST.scanWork := 0
    DetectState(second, 0, t + 400)
    HandleEndScreen(second, t + 400)
    early := FixtureEnd(202), ST.scanWork := 0
    DetectState(early, 0, t + 800)
    HandleEndScreen(early, t + 800)
    Check(ST.endRetry = 2 && !ST.endReturnRetry && ST.clickAgain = again + 2
        , "после лимита повтор не кликается, резерв ждёт паузу")
    fallback := FixtureEnd(203), ST.scanWork := 0
    DetectState(fallback, 0, t + 1200)
    HandleEndScreen(fallback, t + 1200)
    Check(ST.endRetry = 2 && ST.endReturnRetry = 1 && ST.clickAgain = again + 3 && !ST.lobbyRequeue
        && ST.rounds = rounds + 1 && !ST.held.Count, "резервная кнопка при всё ещё видимом повтора; сухой клик не доказывает лобби")

    ; Пустой экран и старый контур не разрешают новый поиск.
    ST.state := "MENU"
    HandleMenu(SceneFixture(204, A_TickCount), t + 1300)
    Check(!ST.lobbyRequeue && ST.clickQueue = queues, "одна принятая сцена не подтверждает возврат")
    lobby := SceneFixture(205, A_TickCount, "play"), ST.scanWork := 0
    Check(DetectState(lobby, 0, t + 1400) = "MENU", "свежая плашка лобби")
    stale := lobby.Clone(), stale.inputEpochAtCapture -= 1
    HandleMenu(stale, t + 1400)
    Check(!ST.lobbyRequeue && !ST.lobbyCooldownUntil && ST.roundActive && ST.clickQueue = queues
        , "старое поколение ввода не подтверждает возврат")
    HandleMenu(lobby, t + 1400)
    Check(ST.lobbyRequeue && !ST.roundActive && ST.lobbyCooldownUntil = t + 3400 && ST.clickQueue = queues
        && ST.rounds = rounds + 1 && !ST.endRetry && !ST.endReturnRetry && !ST.endClickAt
        , "подтверждаем возврат один раз и выдерживаем паузу перед очередью")
    lobby := SceneFixture(206, A_TickCount, "play"), ST.scanWork := 0
    DetectState(lobby, 0, t + 3400)
    HandleMenu(lobby, t + 3400)
    Check(!ST.lobbyRequeue && ST.clickQueue = queues + 1 && !ST.held.Count, "следующий матч запрашивается через лобби только в DryRun")

    CFG.endAction := "lobby_only", ST.state := "END_SCREEN", ST.roundCounted := false
    ResetEndHandoff()
    ST.roundActive := true, ST.lastClickT := 0, ST.endFirstSeen := t, ST.lobbyRequeue := false
    ST.state := "DEATH", ST.deadSince := t, ST.lastLobbyAt := 0
    CFG.waitSquadOnDeath := false, CFG.deathEscMs := 45000
    death := WorldFixture(207), death.hudEvidence := {confirmed:true}
    HandleDeath(death, t + 3000)
    lone := FixtureEnd(208, false), ST.scanWork := 0
    Check(DetectState(lone, 0, t + 3400) = "UNKNOWN" && !lone.endReturnAction, "один светлый кандидат ещё не итоги")
    lobbyOnly := FixtureEnd(209, false), ST.scanWork := 0
    Check(DetectState(lobbyOnly, 0, t + 3500) = "END_SCREEN" && lobbyOnly.endReturnAction
        && !FrameActionButton(lobbyOnly, "END_SCREEN"), "после устранения светлые итоги без повтора")
    HandleEndScreen(lobbyOnly, t + 3500)
    Check(!ST.endRetry && ST.endReturnRetry = 1 && ST.rounds = rounds + 1 && !ST.lobbyRequeue
        , "при выходе вместо повтора запись матча ждёт реального лобби, а не клика")

    for i, elapsed in [3900, 4500] {
        same := FixtureEnd(209 + i, false), ST.scanWork := 0
        DetectState(same, 0, t + elapsed)
        HandleEndScreen(same, t + elapsed)
    }
    Check(ST.endReturnRetry = 2 && ST.clickAgain = again + 5 && !ST.lobbyRequeue
        , "резервный выход также ограничен и не ставит очередь по клику")

    CFG.waitSquadOnDeath := false, CFG.deathEscMs := 1, ST.state := "DEATH", ST.deadSince := t
    HandleDeath(WorldFixture(212), t + 4600)
    Check(!ST.leaveActive, "без HUD наблюдения не начинаем выход вслепую")
    death := WorldFixture(213), death.hudEvidence := {confirmed:true}
    HandleDeath(death, t + 4700)
    Check(ST.leaveActive && ST.leaveStep = 1 && !ST.held.Count, "Авто-игра начинает тот же проверяемый выход после наблюдения")
    LeaveCancel()
}

TestReturnEvidence() {
    WithGroundFixture(CheckReturnEvidence)
}

CheckReturnEvidence() {
    global CFG, ST
    ResetSceneEvidence()
    CFG.featPlayAgain := true, CFG.endAction := "lobby_only", CFG.scanMenuMs := 0
    CFG.stopAfterMin := 0, CFG.maxRounds := 0, CFG.waitSquadOnDeath := true
    ST.state := "UNKNOWN", ST.queuePending := false, ST.cancelHold := false
    ST.roundActive := true, ST.roundCounted := false, ST.mmEnterAt := 0, ST.mmSince := 0
    ST.tokenStopArmed := false, ST.tokenShown := false, ST.finishMatchArmed := false
    t := A_TickCount, clicks := ST.clickAgain, rounds := ST.rounds
    unsupported := FixtureEnd(400, false), light := FindResultReturnButton(unsupported)
    Check(light && FrameDarkRatio(unsupported) < CFG.endDarkRatio, "светлая геометрия в исходно неопознанном кадре")
    Check(!FindResultReturnButton(unsupported, light), "перекрывающийся бокс не становится отдельным выходом")
    Check(DetectState(unsupported, 0, t) = "UNKNOWN" && !unsupported.endReturnAction
        , "даже подходящая геометрия не заменяет контекст результата")
    dark := FixtureEnd(401, false, false), ST.scanWork := 0
    dark.buf := Buffer(dark.stride * dark.h, 0x22)
    PaintReturnFixture(dark)
    Check(FindResultReturnButton(dark) && DetectState(dark, 0, t + 50) = "END_SCREEN" && !dark.endReturnAction
        , "даже на тёмной сцене предположение об итогах не даёт координат")
    HandleEndScreen(dark, t + 10000)
    HandleEndScreen(dark, t + 15000)
    Check(ST.clickAgain = clicks && !ST.endFirstSeen && ST.rounds = rounds, "без контекста не стартует таймер кликов")

    death := WorldFixture(402), death.hudEvidence := {confirmed:true}, ST.deadSince := t
    ST.spectateSquadAt := A_TickCount, ST.spectateAlive := 1
    HandleDeath(death, t)
    watched := FixtureEnd(403, false), ST.scanWork := 0
    Check(ST.endContext.kind = "death" && DetectState(watched, 0, t + 100) = "UNKNOWN" && !ST.endReturnObs
        , "одна светлая кнопка не отменяет ожидание живого отряда")
    ST.spectateAlive := 0
    first := FixtureEnd(404, false), ST.scanWork := 0
    Check(DetectState(first, 0, t + 200) = "UNKNOWN" && ST.endReturnObs.hits = 1 && !first.endReturnAction
        , "первый кадр возврата не даёт ни сцены итогов, ни клика")
    DetectState(first, 0, t + 350)
    Check(ST.endReturnObs.hits = 1 && !first.endReturnAction, "повтор того же снимка не подтверждает кнопку")
    budget := CFG.scanPerTickMax, CFG.scanPerTickMax := 2, ST.scanWork := 0
    deferredHud := FixtureEnd(405)
    FixtureRect(deferredHud, 24, 256, 80, 20, 0x2ABA31)
    FixtureRect(deferredHud, 236, 142, 9, 5, 0xFFFFFF)
    Check(DetectState(deferredHud, 0, t + 400) = "UNKNOWN" && deferredHud.HasOwnProp("healthDeferred")
        && ST.endReturnObs.hits = 1 && !deferredHud.endReturnAction && !FrameActionButton(deferredHud, "END_SCREEN")
        , "при отложенном HUD нет разрешения на клик и нет отрицательного скана возврата")
    CFG.scanPerTickMax := budget
    moved := FixtureEnd(406, false, true, 20), ST.scanWork := 0
    Check(DetectState(moved, 0, t + 500) = "UNKNOWN" && ST.endReturnObs.hits = 1
        , "смещение геометрии требует повторного наблюдения")
    current := FixtureEnd(407, false, true, 20), ST.scanWork := 0
    Check(DetectState(current, 0, t + 650) = "END_SCREEN" && current.endReturnAction
        , "два согласованных снимка подтверждают сцену без жёлтого повтора")

    ST.endFirstSeen := t - 3000
    for latch in ["tokenShown", "tokenStopArmed", "queuePending", "cancelHold"] {
        ST.%latch% := true
        HandleEndScreen(current, t + 700)
        Check(ST.clickAgain = clicks && !ST.endReturnRetry, "выход не обходит блокировку " latch)
        ST.%latch% := false
    }
    CFG.scanPerTickMax := 4, CFG.featToken := true, ST.scanWork := 0
    ST.scanTokenAt := A_TickCount - CFG.scanTokenMs
    lowCpu := FixtureEnd(408, false, true, 20)
    Check(DetectState(lowCpu, 0, t + 750) = "END_SCREEN" && !lowCpu.endReturnAction && ST.scanWork = 2
        && ST.endReturnObs.seq = current.captureId, "в экономном профиле ждём следующий скан возврата, оставив бюджет жетону")
    Check(!CheckToken(lowCpu, A_TickCount, false) && ST.scanWork = 4 && ST.scanTokenAt >= lowCpu.capturedAt
        , "скан жетона получил две оставленные единицы бюджета")
    CFG.scanPerTickMax := budget
    CFG.scanMenuMs := 60000, ST.scanWork := 0
    deferred := FixtureEnd(409, false, false)
    Check(DetectState(deferred, 0, t + 800) = "END_SCREEN" && !deferred.endReturnAction
        , "отложенный скан удерживает сцену, но не координаты")
    HandleEndScreen(deferred, t + 800)
    stale := current.Clone(), stale.capturedAt -= CFG.tickBudgetMs + 1
    HandleEndScreen(stale, t + 900)
    Check(ST.clickAgain = clicks && ST.rounds = rounds, "по старому кадру и памяти нет клика или раунда")
    CFG.scanMenuMs := 0, ST.scanWork := 0
    miss := FixtureEnd(410, false, false)
    Check(DetectState(miss, 0, t + 950) = "UNKNOWN" && !ST.endReturnObs.hits && !miss.endReturnAction
        , "полный отрицательный скан снимает поддержку")

    ST.scanWork := 0
    active := FixtureEnd(411)
    FixtureRect(active, 24, 256, 80, 20, 0x2ABA31)
    FixtureRect(active, 236, 142, 9, 5, 0xFFFFFF)
    Check(DetectState(active, 0, t + 1000) = "GAME" && FrameHasMatchHud(active) && !active.endReturnAction
        && !FrameActionButton(active, "END_SCREEN") && !ST.endContext
        , "текущий HUD важнее даже свежих жёлтой и светлой плашек")

    death := WorldFixture(412), death.hudEvidence := {confirmed:true}
    ST.deadSince := t
    HandleDeath(death, t + 1100)
    prior := ST.endContext, prior.at := death.capturedAt - CFG.endContextMs - 1
    late := FixtureEnd(413, false), ST.scanWork := 0
    Check(DetectState(late, 0, t + 1150) = "UNKNOWN" && !ST.endReturnObs, "контекст устранения имеет срок жизни")
    prior.at := death.capturedAt
    ST.inputEpoch += 1, ST.scanWork := 0, ST.state := "UNKNOWN"
    afterPause := FixtureEnd(414, false)
    Check(DetectState(afterPause, 0, t + 1200) = "UNKNOWN" && !ST.endReturnObs && !afterPause.endReturnAction
        , "контекст старого поколения не переносится на свежий кадр")

    ; Старый жёлтый запасной поиск мог нажать этот же повтор как «В лобби».
    for id in [415, 416] {
        lowReplay := FixtureEnd(id, false, false), ST.scanWork := 0
        FixtureRect(lowReplay, 318, 210, 112, 22, 0xCBCB00)
        FixtureRect(lowReplay, 346, 215, 26, 7, 0x202020)
        Check(FindYellowButtons(lowReplay, CFG.regReturnBtn).Length && !FindResultReturnButton(lowReplay)
            , "жёлтая кнопка в зоне возврата не считается выходом")
        Check(DetectState(lowReplay, 0, t + 1300) = "END_SCREEN" && FrameActionButton(lowReplay, "END_SCREEN")
            && !lowReplay.endReturnAction, "жёлтый бокс остаётся только кандидатом на повтор")
        HandleEndScreen(lowReplay, t + 1300)
    }
    Check(ST.clickAgain = clicks && !ST.endRetry && !ST.endReturnRetry && !ST.held.Count
        , "lobby_only не отправляет ни повтора, ни фиктивного возврата")
}

TestEndStopGuards() {
    for reason in ["token", "rounds", "finish"]
        WithGroundFixture(CheckEndStopGuard.Bind(reason))
}

CheckEndStopGuard(reason) {
    global CFG, ST
    CFG.featPlayAgain := true, CFG.endAction := "play_again", CFG.scanMenuMs := 0
    CFG.stopAfterMin := 0, CFG.maxRounds := reason = "rounds" ? ST.rounds + 1 : 0
    CFG.stopAction := "none"
    ResetEndHandoff()
    ST.state := "END_SCREEN", ST.roundActive := true, ST.roundCounted := reason = "token"
    ST.cancelHold := false, ST.queuePending := false, ST.tokenStopArmed := reason = "token"
    ST.tokenShown := false, ST.finishMatchArmed := reason = "finish"
    clicks := ST.clickAgain, shot := FixtureEnd(212), now := shot.capturedAt
    Check(DetectState(shot, 0, now) = "END_SCREEN" && FrameActionButton(shot, "END_SCREEN"), "есть кнопка на итогах")
    HandleEndScreen(shot, now)
    Check(!ST.running && ST.clickAgain = clicks && !ST.held.Count
        , "приоритет остановки выше повтора матча: " reason)
}

TestCalibrationIsolation() {
    global CFG, ST
    ResetSceneFixture()
    live := SceneFixture(40, 60000, "hud")
    Check(DetectState(live, 0, live.capturedAt) = "GAME", "есть живая оценка до F5")
    ST.state := "GAME", ST.lastShot := live, ST.queuePending := true
    ST.lootMasks := EmptyLootMasks(), ST.lootMasksAt := A_TickCount - CFG.scanLootMs - 1
    ST.scanWork := 2, ST.enemySkinPct := 35
    before := ST.Clone()
    blank := SceneFixture(41, 60100)
    DescribeCalibrationFrame(blank)
    Check(!blank.hudEvidence.confirmed && blank.healthReading.hp.pct = -1, "отчёт F5 не подставляет удержанный HUD")
    active := SceneFixture(42, 60200, "hud")
    DescribeCalibrationFrame(active)
    Check(active.hudEvidence.confirmed, "F5 находит HUD на собственном снимке")
    ret := FixtureEnd(43, false)
    shown := false
    for line in BuildCalibrationReport(ret).lines
        if InStr(line, "светлая «В лобби» кандидат")
            shown := true
    Check(shown && !ret.HasOwnProp("endReturnAction"), "F5 выводит геометрию возврата без подтверждения и действия")
    for key, value in before.OwnProps()
        Check(ST.%key% = value, "F5 не переписывает состояние цикла: " key)
}

NavFixture(id, kind, w := 480, h := 288) {
    shot := WorldFixture(id), shot.w := w, shot.h := h, shot.stride := (w + 3) * 4
    shot.buf := Buffer(shot.stride * h, 0x60)
    for lane, bounds in [[0.15, 0.34], [0.39, 0.61], [0.66, 0.85]] {
        Loop 17 {
            col := A_Index - 1, x := Round(w * (bounds[1] + (bounds[2] - bounds[1]) * col / 16))
            Loop 12 {
                row := A_Index, y := Round(h * (0.42 + (row - 1) * 0.024))
                shade := 64 + col * 3
                if (kind = "flat")
                    shade := 96
                else if (kind = "busy" && lane >= 2)
                    shade := Mod(col, 2) ? 48 : 202
                else if (row >= 8 && (kind = "horizon" || (kind = "lip" && lane = 2 && col >= 2 && col <= 14)))
                    shade += 60
                NumPut("UInt", 0xD4000000 | shade * 0x010101, shot.buf, y * shot.stride + x * 4)
            }
        }
    }
    shot.capturedAt := A_TickCount
    return shot
}

TestNavigationState() {
    WithGroundFixture(CheckNavigation)
}

CheckNavigation() {
    global CFG, ST
    CFG.featParkour := true, CFG.sprint := true, CFG.navScanMs := 0
    for w, h in Map(480, 288, 1365, 767, 1920, 1080) {
        for kind, expected in Map("flat", "unknown", "clear", "clear", "busy", "busy", "lip", "lip", "horizon", "busy") {
            n := ScanNavCorridors(NavFixture(50, kind, w, h))
            Check(n.kind = expected, w "×" h " · классификация коридора " kind " → " n.kind)
            if (kind = "busy")
                Check(n.turn = -1, "плотная текстура справа не выбирается как свободный путь")
        }
    }
    first := NavFixture(52, "clear")
    Check(!SteerOpenSpace(first, first.capturedAt) && StartSegment(first) && ST.moveMode = "иду шагом"
        , "один открытый кадр начинает ходьбу, а не спринт")
    Check(!RefreshNavigation(first) && ST.navInfo.hits = 1, "повтор того же кадра не повышает подтверждение")
    next := NavFixture(53, "clear")
    Check(!SteerOpenSpace(next, next.capturedAt) && KeepPatrolMoving(next) && ST.moveMode = "бегу" && !ST.held.Count
        , "два открытых кадра разрешают спринт только в DryRun")

    lip := NavFixture(54, "lip")
    Check(!SteerOpenSpace(lip, lip.capturedAt) && !ST.lastObsJump && ST.navInfo.hits = 1, "один уступ не разрешает прыжок")
    ST.cameraSeq += 1
    late := NavFixture(55, "lip"), late.capturedAt -= 251
    Check(!SteerOpenSpace(late, A_TickCount) && ST.navInfo.seq = 54, "старый кадр не меняет проверку уступа")
    turned := NavFixture(56, "lip")
    Check(!SteerOpenSpace(turned, turned.capturedAt) && ST.navInfo.hits = 1, "после поворота снова нужен второй кадр")
    ST.lastJumpT := 0
    repeat := NavFixture(57, "lip")
    Check(SteerOpenSpace(repeat, repeat.capturedAt) && ST.navInfo.jumped && ST.lastObsJump = repeat.capturedAt
        && !ST.navSteerAt && !ST.held.Count, "два кадра локального уступа: ровно одна попытка прыжка без поворота")
    later := NavFixture(58, "lip")
    SteerOpenSpace(later, later.capturedAt)
    Check(ST.lastObsJump = repeat.capturedAt, "не прыгать повторно на той же серии краёв")

    ResetNavigation()
    first := NavFixture(60, "busy")
    Check(!SteerOpenSpace(first, first.capturedAt), "первый плотный кадр: ни прыжка, ни разворота")
    second := NavFixture(61, "busy")
    Check(SteerOpenSpace(second, second.capturedAt) && ST.navSteerAt && ST.navTurnSign = -1
        && !ST.segUntil && !ST.lastObsJump, "плотная преграда: освобождаем W и выбираем боковой обзор вместо прыжка")
    outdated := NavFixture(62, "lip"), buf := outdated.buf, changes := {count:0}, prior := ST.navInfo
    outdated.DefineProp("buf", {Get: ChangeDuringPixelScan.Bind(outdated, buf, changes, "age")})
    Check(!RefreshNavigation(outdated) && changes.count && ST.navInfo = prior
        , "если кадр устарел во время скана, оценка и подтверждение не обновляются")
    ResetNavigation()
    Check(!ST.lastObsJump && !ST.navInfo && !ST.patrolLeaseAt, "у нового матча чистая навигация")
}

TestMotionUsesSameWindow() {
    global ST
    t := 90000, cameraAt := ST.cameraAt
    prev := SceneFixture(60, t), next := SceneFixture(61, t + 50)
    FixtureRect(next, 316, 110, 32, 52, 0xDEDEDE)
    ST.prevShot := prev, ST.cameraAt := 0
    try {
        Check(FindEnemyMotion(next), "детектор движения до первого поворота не падает")
        ST.cameraAt := t + 20
        Check(!FindEnemyMotion(next), "используется время существующей команды камеры")
        ST.cameraAt := 0
        prev.cameraSeqAtCapture -= 1
        Check(!FindEnemyMotion(next), "кадры по разные стороны поворота не сравниваются")
        prev.cameraSeqAtCapture := next.cameraSeqAtCapture
        prev.hwnd += 1
        Check(!FindEnemyMotion(next), "кадр другого окна тех же размеров не используется")
        prev.hwnd := next.hwnd, prev.inputEpochAtCapture -= 1
        Check(!FindEnemyMotion(next), "кадр предыдущего поколения не используется")
    } finally {
        ST.cameraAt := cameraAt, ST.prevShot := 0
    }
}

TestModeScenes() {
    global CFG, ST
    ResetSceneFixture()
    CFG.botMode := "xp"
    shot := SceneFixture(70, 100000)
    Check(DetectState(shot, 0, shot.capturedAt) = "GAME" && !FrameHasMatchHud(shot)
        && !shot.HasOwnProp("menuEvidence"), "в XP HUD необязателен, меню не сканируется")
    CFG.botMode := "antiafk"
    ST.state := "GAME", ST.hudLastT := shot.capturedAt
    next := SceneFixture(71, 100100)
    Check(DetectState(next, 0, next.capturedAt) = "UNKNOWN" && !next.HasOwnProp("menuEvidence")
        , "Анти-АФК требует текущий HUD без поиска меню")
    ST.scanWork := 0
    active := SceneFixture(72, 100200, "hud")
    Check(DetectState(active, 0, active.capturedAt) = "GAME" && FrameHasMatchHud(active)
        , "Анти-АФК принимает HUD нового кадра")
    CFG.botMode := "queue"
    ST.scanWork := 0
    death := SceneFixture(73, 100300, "hud")
    FixtureRect(death, 156, 253, 104, 24, 0xF1F1F1)
    Check(DetectState(death, 0, death.capturedAt) = "DEATH" && FrameHasMatchHud(death)
        , "режим очереди отличает экран устранения от матча")
    ResetSceneFixture()
}

LeaveFixtureStart() {
    global CFG, ST
    ResetSceneFixture()
    ST.running := true, ST.paused := false, ST.tickAbort := false
    ST.roundCounted := false, ST.roundActive := true, ST.lobbyRequeue := false
    ST.tokenShown := false, ST.tokenFoundMatch := false
    ST.state := "GAME"
    CFG.dryRun := false
    LeaveBegin(100, "тест", A_TickCount)
}

LeaveFixtureStep(id, kind, sender, hwnd := 100) {
    global ST
    now := Max(A_TickCount, ST.leaveNextAt)
    shot := SceneFixture(id, now, kind, hwnd)
    ST.scanWork := 0
    LeaveStep(shot, now, sender)
    return shot
}

FakeLeaveInput(calls, shot, epoch, step, label, box) {
    global ST
    Check(epoch = ST.inputEpoch && shot.hwnd = ST.leaveHwnd, "отправитель получает ожидаемые поколение и окно")
    calls.Push({step:step, label:label, box:box, id:shot.captureId})
    return true
}

TestLeaveSequence() {
    global CFG, ST
    LeaveFixtureStart()
    rounds := ST.rounds, calls := [], sender := FakeLeaveInput.Bind(calls)
    try {
        escShot := LeaveFixtureStep(80, "hud", sender)
        Check(calls.Length = 1 && calls[1].label = "Esc" && ST.leaveStep = 2, "отправка Esc завершает только первый шаг")
        LeaveStep(escShot, ST.leaveNextAt, sender)
        Check(calls.Length = 1 && ST.leaveStep = 2, "тот же кадр не даёт следующий шаг")
        LeaveFixtureStep(81, "hud", sender)
        Check(calls.Length = 1 && ST.leaveStep = 2, "HUD после Esc не разрешает координатный клик")
        LeaveFixtureStep(82, "blank", sender)
        Check(calls.Length = 2 && InStr(calls[2].label, "вкладка") && ST.leaveStep = 3, "единственный координатный шаг — вкладка")
        LeaveFixtureStep(83, "blank", sender)
        Check(calls.Length = 2 && ST.leaveStep = 3, "отсутствие красной кнопки не разрешает слепой клик выхода")
        LeaveFixtureStep(84, "leave", sender)
        Check(calls.Length = 3 && calls[3].label = "В лобби" && ST.leaveStep = 4, "красная кнопка распознана на новом кадре")
        ambiguous := LeaveFixtureStep(85, "ambiguousConfirm", sender)
        Check(FindYellowButtons(ambiguous, CFG.regConfirmBtn).Length, "неоднозначная жёлтая плашка видна в зоне подтверждения")
        Check(calls.Length = 3 && ST.leaveStep = 4 && ST.rounds = rounds, "не подтверждать диалог по любой жёлтой кнопке")
        LeaveFixtureStep(86, "confirm", sender)
        Check(calls.Length = 4 && calls[4].label = "подтверждение выхода" && ST.leaveStep = 5 && ST.rounds = rounds
            , "даже отправленный клик подтверждения ещё не засчитывает раунд")
        LeaveFixtureStep(87, "blank", sender)
        LeaveFixtureStep(88, "cancel", sender)
        Check(ST.leaveActive && ST.rounds = rounds && calls.Length = 4, "загрузка и кремовая плашка не считаются лобби")
        ; Прогретый старый контур не может завершить выход.
        lobby := SceneFixture(89, Max(A_TickCount, ST.leaveNextAt), "play")
        ST.scanMenuAt := 0, ST.scanWork := 0
        Check(FrameMenu(lobby).fresh && FrameMenu(lobby).kind = "play", "фиксируем контур лобби для проверки отсрочки")
        stale := SceneFixture(90, lobby.capturedAt + 80, "play")
        ST.scanWork := CFG.scanPerTickMax
        LeaveStep(stale, stale.capturedAt, sender)
        Check(ST.leaveActive && ST.rounds = rounds, "старый контур даже с тем же цветом не засчитывает лобби")
        proved := SceneFixture(91, stale.capturedAt + 80, "play")
        ST.scanMenuAt := 0, ST.scanWork := 0
        LeaveStep(proved, proved.capturedAt, sender)
        Check(!ST.leaveActive && ST.rounds = rounds + 1 && ST.lobbyRequeue && calls.Length = 4
            , "новое подтверждённое лобби засчитывает раунд ровно один раз, без повторных кликов")
        Check(!LeaveStep(proved, proved.capturedAt, sender) && ST.rounds = rounds + 1, "после завершения действие не повторяется")
    } finally {
        LeaveCancel()
        ST.running := false, CFG.dryRun := true
    }
}

TestLeaveCancellation() {
    global CFG, ST, LogBuf
    try {
        rounds := ST.rounds
        LeaveFixtureStart()
        LeaveFixtureStep(100, "hud", (*) => false)
        Check(!ST.leaveActive && ST.paused && ST.rounds = rounds && !ST.leaveStep
            , "сбой Esc останавливает последовательность вместо перехода дальше")

        LeaveFixtureStart()
        LeaveFixtureStep(100, "hud", FakeLeaveInput.Bind([]))
        LeaveFixtureStep(101, "leave", (*) => false)
        Check(!ST.leaveActive && ST.paused && ST.rounds = rounds, "неуспешный клик выхода не запускает подтверждение")

        LeaveFixtureStart()
        LeaveFixtureStep(101, "blank", UnexpectedLeaveInput, 101)
        Check(!ST.leaveActive && ST.paused && ST.rounds = rounds, "другое окно отменяет выход до ввода")

        LeaveFixtureStart()
        ST.leaveStartedAt -= CFG.leaveTimeoutMs
        LeaveFixtureStep(102, "blank", UnexpectedLeaveInput)
        Check(!ST.leaveActive && ST.paused && ST.rounds = rounds, "по истечении срока нет повтора Esc и раунд не засчитан")

        LeaveFixtureStart()
        InputCancelDeferred()
        LeaveFixtureStep(103, "blank", UnexpectedLeaveInput)
        Check(!ST.leaveActive && ST.rounds = rounds, "смена поколения ввода отменяет все шаги")

        LeaveFixtureStart()
        LeaveFixtureStep(104, "hud", FakeLeaveInput.Bind([]))
        ; Прямой вызов обработчика аварийного Esc во время клика, без клавиатуры.
        LeaveFixtureStep(105, "leave", StopDuringLeave)
        Check(!ST.leaveActive && !ST.running && !ST.leaveStep && ST.rounds = rounds, "аварийный Stop между шагами не возобновляет выход")
        foundStop := false
        for line in LogBuf
            if InStr(line, "[leave] Отменено на шаге 2/5: Esc")
                foundStop := true
        Check(foundStop, "лог аварийного выхода содержит имя причины и ожидавшийся шаг")

        LeaveFixtureStart()
        LeaveCancel()
        ST.state := "DEATH", ST.hwnd := 100, CFG.dryRun := true
        RequestBypassMatch()
        wait := SceneFixture(106, A_TickCount)
        Check(HandleManualBypass(wait, "DEATH", "UNKNOWN") && ST.bypassRequested && !ST.leaveActive
            , "F4 ждёт текущего кадра, а не доверяет удержанному экрану смерти")
        death := SceneFixture(107, A_TickCount, "hud")
        FrameHudEvidence(death)
        Check(HandleManualBypass(death, "DEATH", "DEATH") && ST.leaveActive && !ST.bypassRequested
            , "F4 в DEATH проходит тот же обработчик, что и в GAME")
        LeaveFixtureStep(108, "hud", UnexpectedLeaveInput)
        Check(!ST.leaveActive && ST.rounds = rounds, "DryRun описывает выход без ввода и без раунда")
    } finally {
        LeaveCancel()
        ST.running := false, ST.paused := false, ST.tickAbort := false, ST.hwnd := 0
        CFG.dryRun := true
    }
}

UnexpectedLeaveInput(*) {
    throw Error("этот шаг не должен обращаться к исполнителю ввода")
}

StopDuringLeave(*) {
    OnStop("Esc")
    return true
}

; Пиксели реальные для детекторов, HWND вымышленный, боевой ввод не допускается.
; Имитируем время кадра после заполнения буфера, иначе измеряем время фикстуры.
WithGroundFixture(test) {
    global CFG, ST
    savedCfg := CFG, savedState := ST
    CFG := CFG.Clone(), ST := ST.Clone()
    CFG.dryRun := true, CFG.teamSafe := false, CFG.featCombat := true
    CFG.featChest := true, CFG.featLoot := true, CFG.featMove := true, CFG.featSound := true
    CFG.featProStyle := false, CFG.featCrouchFight := false, CFG.featWeaponPick := false
    CFG.featReload := false, CFG.featParkour := false, CFG.botMode := "auto"
    ST.held := Map(), ST.badSpots := [], ST.promptAttempts := [], ST.actionTimes := []
    ST.hwnd := 100, ST.running := true, ST.paused := false, ST.state := "GAME"
    ST.tickAbort := false, ST.prevShot := 0, ST.stepBoost := 0, ST.scanWork := 0
    ST.phase := "roam", ST.phaseAt := A_TickCount, ST.enemy := 0, ST.tgt := 0, ST.chest := 0
    ST.segUntil := 0, ST.pauseUntil := 0, ST.promptN := 0, ST.lastPromptE := 0
    ST.shots := 0, ST.reloadUntil := 0, ST.lastSound := 0, ST.cameraAt := 0
    ResetNavigation()
    ResetCaches()
    try test()
    finally {
        CFG := savedCfg, ST := savedState
    }
}

WorldFixture(id, kind := "blank", hwnd := 100) {
    shot := SceneFixture(id, A_TickCount, "blank", hwnd)
    switch kind {
        case "gold", "rare", "center":
            FixtureRect(shot, kind = "center" ? 227 : 308, 148, 30, 24, kind = "rare" ? 0x58CBFE : 0xFFAA20)
        case "damage":
            FixtureRect(shot, 253, 123, 14, 14, 0xFFFFFF)
        case "prompt", "redPrompt", "widePrompt":
            ; Две строки разной длины с одинаковым центром и значком слева.
            wide := kind = "widePrompt", left := wide ? 234 : 242
            FixtureRect(shot, left, 134, wide ? 74 : 58, 21, 0x282828)
            FixtureRect(shot, left + 3, 142, 3, 4, 0xEEEEEE)
            Loop (wide ? 13 : 9)
                FixtureRect(shot, left + 15 + 4 * (A_Index - 1), 142, 2, 4, 0xEEEEEE)
            if (kind = "redPrompt")
                FixtureRect(shot, 236, 140, 9, 9, 0xEE2727)
        case "red", "white", "cyan":
            FixtureRect(shot, 236, 140, 9, 9, kind = "red" ? 0xEE2727 : (kind = "white" ? 0xEEEEEE : 0x25DAEE))
        case "sound":
            FixtureRect(shot, 316, 128, 7, 12, 0xE89028)
            FixtureRect(shot, 323, 140, 8, 12, 0xE89028)
    }
    shot.capturedAt := A_TickCount
    return shot
}

TestChestApproach() {
    WithGroundFixture(CheckChestApproach)
}

CheckChestApproach() {
    global CFG, ST
    CFG.scanLootMs := 0
    for i, kind in ["gold", "rare"] {
        ResetCaches()
        ST.scanWork := 0, id := 102 + i * 10
        shot := WorldFixture(id, kind)
        chest := FindChest(shot, ScanLootMasks(shot))
        Check(chest && chest.kind = (kind = "gold" ? "chestGold" : "chestRare")
            && chest.x > chest.drawX && chest.y > chest.drawY, "детектор возвращает центр и рамку " kind)
        shot.capturedAt := A_TickCount
        Check(TryInteract(shot, shot.capturedAt) && ST.walkTarget.samples.hits = 1
            && ST.lastAction = "свечение: жду повторный кадр" && !ST.held.Count, "одиночное пятно не запускает подход " kind)
        Check(TryApproach(shot, A_TickCount) && ST.walkTarget.samples.hits = 1, "переиспользованный кадр не подтверждает пятно")
        next := WorldFixture(id + 1, kind), ST.scanWork := 0
        Check(TryInteract(next, next.capturedAt) && ST.lastAction = "к свечению сундука", "подход после двух замеров " kind)
        Check(ST.chestCacheSeq = next.captureId && ST.chest = ST.chestCache && !ST.promptN && !ST.tgt
            && !ST.promptAttempts.Length, "свечение не разрешает E и не подтверждает открытие")
    }
    ST.scanWork := CFG.scanPerTickMax
    deferred := WorldFixture(125)
    Check(!TryApproach(deferred, deferred.capturedAt) && ST.walkTarget.samples.hits = 2
        , "пропуск скана не считается исчезновением объекта")
    blank := WorldFixture(126), ST.scanWork := 0
    Check(TryApproach(blank, blank.capturedAt) && !ST.chest && !ST.loot && ST.walkTarget.missSeq = blank.captureId
        && !ST.walkTarget.samples.hits && ST.guidedUntil && !ST.held.Count
        , "один отрицательный скан останавливает W, но оставляет подсказку о месте свечения")
    Check(TryApproach(blank, blank.capturedAt) && ST.walkTarget.missSeq = blank.captureId
        , "переиспользование пустого кадра не считается потерей цели дважды")
    blank := WorldFixture(127), ST.scanWork := 0
    Check(!TryApproach(blank, blank.capturedAt) && !ST.walkTarget && !ST.guidedUntil
        , "два полных отрицательных скана завершают подход")
    shot.capturedAt := A_TickCount
    Check(WalkTo(chest.x, chest.y, shot) && !ST.held.Count, "DryRun планирует подход без удержаний")
    shot.capturedAt -= 251
    Check(!WalkTo(chest.x, chest.y, shot), "устаревший кадр не начинает подход")
    shifted := WorldFixture(128, "gold")
    shifted.cameraSeqAtCapture -= 1
    Check(!WalkTo(chest.x, chest.y, shifted), "нужен кадр после поворота")

    ResetCaches()
    for i, expected in ["свечение: жду повторный кадр", "объект у прицела: жду подсказку", "к свечению сундука"] {
        ST.scanWork := 0, near := WorldFixture(130 + i, "center")
        Check(TryApproach(near, near.capturedAt) && ST.lastAction = expected && !ST.segUntil && !ST.tgt && !ST.promptN
            , "приближение к центру не заменяет подсказку E: " expected)
    }
    oldAt := ST.walkTarget.at
    ST.cameraSeq += 1
    ST.scanWork := 0, near := WorldFixture(134, "center")
    Check(TryApproach(near, near.capturedAt) && ST.walkTarget.samples.hits = 1 && ST.walkTarget.at = oldAt
        , "после собственной коррекции зрения подтверждаем цель снова, не продлевая весь подход")
    near := WorldFixture(135, "center"), ST.scanWork := 0, ST.walkTarget.at := near.capturedAt - 8001
    Check(TryApproach(near, near.capturedAt) && !ST.walkTarget && ST.chestSkips.Length = 1 && !ST.guidedUntil
        , "вышло время подхода: не идём за одним свечением бесконечно")
    ResetCaches()
    late := WorldFixture(136, "gold"), buf := late.buf, changes := {count:0}, ST.scanWork := 0
    late.DefineProp("buf", {Get: ChangeDuringPixelScan.Bind(late, buf, changes, "age")})
    Check(!TryApproach(late, late.capturedAt) && changes.count && !ST.walkTarget && !ST.lootMasksSeq && !ST.chestCacheSeq
        , "маски, скан которых закончился после срока кадра, не запускают подход")
}

TwoChestFrame(id, w, h, brighterRight := false, showLeft := true) {
    shot := WorldFixture(id), shot.w := w, shot.h := h, shot.stride := (w + 3) * 4
    shot.buf := Buffer(shot.stride * h, 0x60)
    ; Оба пятна проходят одни и те же фильтры, меняется только яркость.
    ; Небольшие пятна на обоих размерах: с слишком большим пятном штраф
    ; за удаление от прицела перевешивает разницу яркости в старом выборе.
    bw := Clamp(Round(w * 0.075 / 18), 2, 4) * 18, bh := Clamp(Round(h * 0.125 / 18), 2, 3) * 18
    y := Round(h * 0.49 / 18) * 18, bright := 0xFFCB18, dim := 0xB58030
    if showLeft
        FixtureRect(shot, Round(w * 0.45 / 18) * 18, y, bw, bh, brighterRight ? dim : bright)
    FixtureRect(shot, Round(w * 0.675 / 18) * 18, y, bw, bh, brighterRight ? bright : dim)
    shot.capturedAt := A_TickCount
    return shot
}

TestChestSelection() {
    WithGroundFixture(CheckChestSelection)
}

CheckChestSelection() {
    global CFG, ST
    CFG.scanLootMs := 0
    for size in [[480, 288], [1365, 767]] {
        ResetCaches()
        w := size[1], h := size[2], label := w "×" h
        first := TwoChestFrame(350, w, h), ST.scanWork := 0
        Check(TryApproach(first, first.capturedAt) && ST.chest.x < w * 0.6 && ST.walkTarget.samples.hits = 1
            , label ": первичный выбор более заметной цели слева")
        second := TwoChestFrame(351, w, h, true), ST.scanWork := 0
        still := FindChest(second, ScanLootMasks(second)), second.capturedAt := A_TickCount
        Check(still && still.x > w * 0.6, label ": на одиночном кадре сосед справа действительно сильнее")
        Check(TryApproach(second, second.capturedAt) && ST.chest.x < w * 0.6 && ST.walkTarget.samples.hits = 2
            && ST.lastAction = "объект у прицела: жду подсказку", label ": живой выбор держит ближайшее совпадение")

        missed := TwoChestFrame(352, w, h, true, false), ST.scanWork := 0
        Check(TryApproach(missed, missed.capturedAt) && !ST.walkTarget.samples.hits && ST.chest.x > w * 0.6
            && ST.walkTarget.samples.x < w * 0.6 && ST.walkTarget.missSeq = missed.captureId
            , label ": краткая потеря: не берём ближайшего соседа сразу, помним прежний центр")
        next := TwoChestFrame(353, w, h, true), ST.scanWork := 0
        Check(TryApproach(next, next.capturedAt) && ST.chest.x < w * 0.6 && ST.walkTarget.samples.hits = 1
            && ST.lastAction = "свечение: жду повторный кадр", label ": после появления не идём по одному замеру")
        ST.walkTarget.at := A_TickCount - 8001
        expired := TwoChestFrame(354, w, h, true), ST.scanWork := 0
        Check(TryApproach(expired, expired.capturedAt) && ST.chestSkips.Length = 1 && !ST.walkTarget && !ST.guidedUntil
            && ST.chestAudioCooldown > A_TickCount, label ": предел подхода блокирует конкретное пятно, звук не перебивает паузу")
        again := TwoChestFrame(355, w, h), ST.scanWork := 0
        raw := FindChest(again, ScanLootMasks(again)), again.capturedAt := A_TickCount
        Check(raw && raw.x < w * 0.6, label ": одиночный отчёт не переносит исключение рабочего цикла")
        Check(TryApproach(again, again.capturedAt) && ST.chest.x > w * 0.6 && ST.walkTarget.samples.hits = 1
            && !ST.tgt && !ST.held.Count, label ": сосед доступен сразу, но ему нужен собственный повтор")
        Check(!ChestSpotSkipped(ActiveChestSkips(again), "chestRare", raw.x, raw.y), label ": другое свечение не заблокировано по одному цвету")

        ; Координаты экрана недействительны при любом изменении вида.
        for field in ["hwnd", "inputEpochAtCapture", "cameraSeqAtCapture", "w", "h"] {
            changed := again.Clone(), changed.%field% += 1
            Check(!ActiveChestSkips(changed).Length, label ": старый пропуск не переносится: " field)
        }
        ST.chestSkips[1].until := A_TickCount
        Check(!ActiveChestSkips(again).Length, label ": фильтр пятна не бессрочный")
    }
}

PromptPixels(w, h, kind) {
    ; Padding, ненулевой X-байт и нечётные размеры не меняют семантику BGRX.
    stride := (w + 3) * 4
    base := kind = "bright" ? 0xBB : 0x60
    shot := {w:w, h:h, stride:stride, buf:Buffer(stride * h, base)}
    if (kind = "prompt" || kind = "noIcon" || kind = "backdrop")
        DrawPromptPixels(shot, Round(w * 0.54), Round(h * 0.5), kind != "noIcon", kind = "backdrop")
    return shot
}

DrawPromptPixels(shot, x, y, icon := true, bright := false) {
    k := shot.w / 1280
    FixtureRect(shot, x - Round(45 * k), y - Round(21 * k), Round(156 * k), Round(45 * k)
        , bright ? 0xAEA7A7A7 : 0xAE252525)
    if icon
        FixtureRect(shot, x - Round(34 * k), y, Max(2, Round(7 * k)), Round(11 * k), 0x73EEEEEE)
    Loop 9
        FixtureRect(shot, x + Round((A_Index - 1) * 11 * k), y, Max(1, Round(6 * k)), Round(9 * k), 0x81EEEEEE)
}

TestPromptPixels() {
    ; Точные рамки и оценки v11.0.5 на одинаковых буферах. Здесь важна
    ; эквивалентность выборки, а не только «нашлось / не нашлось».
    for spec in [[480, 288, 259, 144, 35, 3, 276, 145, 77, 963]
        , [1280, 720, 692, 361, 94, 7, 738, 364, 89, 898]
        , [1365, 767, 738, 385, 100, 7, 787, 388, 86, 890]
        , [1920, 1080, 1038, 541, 141, 11, 1107, 546, 92, 847]
        , [2560, 1080, 1384, 542, 188, 13, 1476, 548, 89, 796]] {
        w := spec[1], h := spec[2], label := w "x" h
        p := ReadInteractPrompt(PromptPixels(w, h, "prompt"))
        Check(p && p.span = spec[5], label ": есть кандидат с прежней шириной")
        for i, prop in ["x", "y", "w", "h", "cx", "cy", "back", "score"]
            Check(p.%prop% = spec[i + 2], label ": та же оценка/геометрия, поле " prop)
        for kind in ["blank", "noIcon", "backdrop", "bright"]
            Check(!ReadInteractPrompt(PromptPixels(w, h, kind)), label ": отрицательный буфер " kind)
    }
}

TestPromptScanFreshness() {
    WithGroundFixture(CheckPromptScanFreshness)
}

CheckPromptScanFreshness() {
    global CFG, ST
    probe := {calls:[], ok:true}, sender := PromptProbe.Bind(probe)
    for i, change in ["age", "camera", "epoch", "interrupt"] {
        ST.tickBusy := true, ST.tickDeadline := 0, ST.tickAborted := false
        ResetCaches()
        ST.scanWork := 0, ST.lastPromptE := 0
        first := WorldFixture(190 + i * 3, "prompt")
        Check(TryInteract(first, first.capturedAt, false, sender) && ST.promptConfirm.hits = 1
            && ST.promptSeq = first.captureId, change ": первое свежее наблюдение")
        cache := ST.promptCache, at := A_TickCount - CFG.promptScanMs - 1
        ST.promptAt := at, ST.scanWork := 0
        late := WorldFixture(first.captureId + 1, "prompt")
        buf := late.buf, changes := {count:0}
        late.DefineProp("buf", {Get: ChangeDuringPixelScan.Bind(late, buf, changes, change)})
        segment := A_TickCount + 3000
        ST.segUntil := segment, ST.lastAction := "прямой ход"
        caught := false, selected := false
        try {
            try selected := TryInteract(late, late.capturedAt, false, sender)
            catch TickInterrupted as e {
                caught := true
                Check(e.Message = "запрос сторожа", "у скана есть контрольные точки прерывания")
            }
            Check(changes.count && caught = (change = "interrupt") && !selected
                && (change != "interrupt" || ST.tickAborted), change ": новый результат отклонён")
            Check(!late.HasOwnProp("promptReading") && !ST.promptAvailable && ST.promptCache = cache
                && ST.promptSeq = first.captureId && ST.promptAt = at && ST.promptConfirm.hits = 1
                && ST.promptConfirm.seq = first.captureId, change ": не заменяет измерение и не откладывает следующий скан")
            Check(ST.segUntil = segment && ST.lastAction = "прямой ход"
                && !ST.lastPromptE && !ST.tgt && !ST.promptN && !probe.calls.Length
                , change ": не трогает отрезок движения и не разрешает E")
        } finally {
            late.DefineProp("buf", {Value:buf})
            ST.tickBusy := false, ST.tickAbort := false, ST.tickAborted := false
        }
        ST.scanWork := 0
        next := WorldFixture(late.captureId + 1, "prompt")
        Check(TryInteract(next, next.capturedAt, false, sender) && next.promptReading && ST.promptSeq = next.captureId
            && !ST.held.Count && !probe.calls.Length, change ": следующий новый кадр анализируется без паузы")
        sameView := (change = "age" || change = "interrupt")
        Check(ST.promptConfirm.hits = (sameView ? 2 : 1)
            && !!InStr(ST.lastAction, "DryRun: E") = sameView
            , change ": подтверждение только по действительным наблюдениям одного вида")
    }

    ; Отказ от E не передаёт просроченный кадр следующей ветке Roam.
    ResetCaches()
    CFG.combatOverLoot := false, ST.scanWork := 0
    shot := WorldFixture(205, "prompt")
    ST.enemyCache := {src:"фигура"}, ST.enemyView := FrameView(shot)
    ST.enemySeenAt := shot.capturedAt, ST.enemySeenSeq := shot.captureId - 1
    segment := A_TickCount + 3000
    ST.segUntil := segment, ST.lastAction := "прямой ход"
    buf := shot.buf, changes := {count:0}
    shot.DefineProp("buf", {Get: ChangeDuringPixelScan.Bind(shot, buf, changes, "age")})
    try {
        RunFixtureRoam(shot)
        Check(changes.count && !WorldFrameCurrent(shot) && ST.segUntil = segment
            && ST.lastAction = "прямой ход" && !ST.enemy && !ST.shots
            && !shot.HasOwnProp("enemyReading"), "после просрочки E кадр не выбирает бой по старой фигуре")
    } finally {
        shot.DefineProp("buf", {Value:buf})
    }
}

ChangeDuringPixelScan(shot, buf, changes, change, *) {
    global ST
    changes.count += 1
    if (changes.count = 1) {
        switch change {
            case "age": shot.capturedAt := A_TickCount - 300
            case "camera": ST.cameraSeq += 1
            case "epoch": ST.inputEpoch += 1
            case "interrupt": ST.tickAbort := true
        }
    }
    return buf
}

BenchmarkPromptReader() {
    global ST, FORMA_VERSION
    DllCall("QueryPerformanceFrequency", "Int64*", &freq := 0)
    FileAppend("FORMA v" FORMA_VERSION " / AHK " A_AhkVersion " / ReadInteractPrompt (ms)`n", "*", "UTF-8")
    ST.running := true, ST.tickBusy := true, ST.tickDeadline := 0
    try {
        for size in [[1280, 720], [1920, 1080]] {
            for kind in ["blank", "prompt", "bright"] {
                shot := PromptPixels(size[1], size[2], kind), samples := ""
                Loop 13 {
                    DllCall("QueryPerformanceCounter", "Int64*", &start := 0)
                    p := ReadInteractPrompt(shot)
                    DllCall("QueryPerformanceCounter", "Int64*", &stop := 0)
                    Check(!!p = (kind = "prompt"), "bench: неверный результат " kind)
                    if (A_Index > 2)
                        samples .= Format("{:.3f}", (stop - start) * 1000.0 / freq) "`n"
                }
                times := StrSplit(Sort(RTrim(samples, "`n"), "N"), "`n")
                FileAppend(size[1] "x" size[2] " " kind ": median=" times[6]
                    . " min=" times[1] " max=" times[-1] " (n=11)`n", "*", "UTF-8")
            }
        }
    } finally {
        ST.running := false, ST.tickBusy := false
    }
}

TestPromptAttempts() {
    WithGroundFixture(CheckPromptAttempts)
}

PromptProbe(probe, shot, holdMs) {
    probe.calls.Push({id:shot.captureId, ms:holdMs})
    return probe.ok
}

CheckPromptAttempts() {
    global CFG, ST
    CFG.dryRun := false ; единственный разрешённый отправитель ниже — подставной
    archivedChests := CFG.totalChests
    probe := {calls:[], ok:true}, sender := PromptProbe.Bind(probe)
    shot := WorldFixture(110, "prompt")
    Check(TryInteract(shot, shot.capturedAt, false, sender) && ST.promptConfirm.hits = 1
        && !probe.calls.Length, "реальная маска: первый кадр останавливает движение, не жмёт E")
    Check(TryInteract(shot, shot.capturedAt, false, sender) && ST.promptConfirm.hits = 1
        && !probe.calls.Length, "повтор чтения того же снимка не подтверждает E")
    ST.promptAt := A_TickCount - CFG.promptScanMs - 1
    ST.scanWork := CFG.scanPerTickMax
    deferred := WorldFixture(111, "prompt")
    Check(TryInteract(deferred, deferred.capturedAt, false, sender) && deferred.promptDeferred
        && ST.promptConfirm.hits = 1 && !probe.calls.Length, "отсрочка — ожидание, не измерение")
    ST.scanWork := 0
    second := WorldFixture(112, "prompt")
    Check(TryInteract(second, second.capturedAt, false, sender) && probe.calls.Length = 1
        && probe.calls[1].id = second.captureId && probe.calls[1].ms = CFG.chestHoldMs
        && ST.promptN = 1 && ST.tgt, "по свежей паре удержание E даже без пятна сундука")
    Check(CFG.totalChests = archivedChests && !ST.chests, "отправка E не увеличивает счётчик открытий")
    third := WorldFixture(113, "prompt")
    Check(TryInteract(third, third.capturedAt, false, sender) && probe.calls.Length = 1, "пока идёт удержание, второго E нет")
    ST.tgt.until := A_TickCount - 15
    ST.promptAt := A_TickCount - CFG.promptScanMs - 1
    ST.scanWork := CFG.scanPerTickMax
    unknown := WorldFixture(114)
    Check(TryInteract(unknown, unknown.capturedAt, false, sender) && ST.tgt, "отложенный скан не объявляет исчезновение")
    ST.scanWork := 0
    gone := WorldFixture(115)
    Check(TryInteract(gone, gone.capturedAt, false, sender) && !ST.tgt
        && InStr(ST.lastAction, "результат E неизвестен") && probe.calls.Length = 1
        && CFG.totalChests = archivedChests, "свежий кадр без плашки не объявляет открытие и не жмёт вслепую")

    ; Режим только лута — короткое нажатие, неуспешная отправка не даёт счёт.
    ResetCaches()
    ST.lastPromptE := 0, ST.scanWork := 0, CFG.featChest := false, probe.ok := false
    shot := WorldFixture(116, "prompt")
    TryInteract(shot, shot.capturedAt, false, sender)
    ST.promptAt := 0
    shot := WorldFixture(117, "prompt")
    TryInteract(shot, shot.capturedAt, false, sender)
    Check(probe.calls.Length = 2 && probe.calls[2].ms = 80 && ST.promptN = 1 && !ST.tgt
        , "попытка подбора короче, сбой не даёт фиктивное E")
    CFG.dryRun := true, ST.lastPromptE := 0, ST.scanWork := 0, ST.promptAt := 0
    shot := WorldFixture(118, "prompt")
    Check(TryInteract(shot, shot.capturedAt, false, sender) && InStr(ST.lastAction, "DryRun: E на 80 мс")
        && probe.calls.Length = 2 && !ST.held.Count && !ST.tgt, "DryRun не вызывает отправитель и не заводит удержание")

    ; Лимит общий для разных плашек и не сбрасывается при потере фокуса.
    CFG.dryRun := false, CFG.promptEcooldownMs := 0, CFG.promptScanMs := 0
    Loop (CFG.promptWindowMax - ST.promptAttempts.Length)
        ST.promptAttempts.Push(A_TickCount)
    InvalidatePlayInput()
    ObservePromptFixture(119, "widePrompt", sender)
    limited := ObservePromptFixture(120, "widePrompt", sender)
    Check(!limited.used && limited.shot.promptReading && ST.promptConfirm.hits = 2
        && probe.calls.Length = 2 && ST.promptAttempts.Length = CFG.promptWindowMax && !ST.tgt
        , "подтверждённая новая плашка не обходит общий лимит E")
}

TestPromptGeometry() {
    WithGroundFixture(CheckPromptGeometry)
}

ObservePromptFixture(id, kind, sender) {
    global ST
    ST.scanWork := 0
    shot := WorldFixture(id, kind)
    return {shot:shot, used:TryInteract(shot, shot.capturedAt, false, sender)}
}

CheckPromptGeometry() {
    global CFG, ST
    CFG.dryRun := false, CFG.promptScanMs := 0, CFG.promptEcooldownMs := 0
    probe := {calls:[], ok:true}, sender := PromptProbe.Bind(probe)
    narrow := ObservePromptFixture(801, "prompt", sender).shot
    wide := ObservePromptFixture(802, "widePrompt", sender).shot
    a := narrow.promptReading, b := wide.promptReading
    Check(a && b && a.cx = b.cx && b.w > a.w && ST.promptConfirm.hits = 1 && !probe.calls.Length
        , "две строки у одного центра не наследуют подтверждение друг друга")
    pair := ObservePromptFixture(803, "widePrompt", sender)
    Check(pair.used && ST.tgt && ST.tgt.box.w = b.w && probe.calls.Length = 1
        , "новая геометрия после собственного повтора разрешает попытку")
    ST.tgt.until := A_TickCount - 20, CFG.interactVerifyMs := 0
    changed := ObservePromptFixture(804, "prompt", sender)
    Check(changed.used && !ST.tgt && !ST.promptMemory.Length && !ST.promptConfirm.hits
        && probe.calls.Length = 1, "плашка другой ширины после E не считается неизменившейся")
    Check(!TryInteract(changed.shot, changed.shot.capturedAt, false, sender) && !ST.promptConfirm.hits
        , "закрывающий кадр не переносит подтверждение на новую попытку")
    ObservePromptFixture(805, "prompt", sender)
    Check(ST.promptConfirm.hits = 1 && probe.calls.Length = 1, "для следующей E снова нужна пара")

    beforeTurn := ObservePromptFixture(806, "prompt", sender).shot, pending := ST.tgt
    Check(pending && probe.calls.Length = 2, "начата отдельная попытка")
    ST.cameraSeq += 1
    TryInteract(beforeTurn, A_TickCount, false, sender)
    Check(ST.tgt = pending && !ST.promptMemory.Length, "старый вид не публикует итог")
    ObservePromptFixture(807, "prompt", sender)
    Check(!ST.tgt && !ST.promptMemory.Length && ST.promptConfirm.hits = 1 && probe.calls.Length = 2
        , "свежий кадр после поворота отменяет проверку и подтверждается с нуля")
}

TestUnchangedPrompt() {
    WithGroundFixture(CheckUnchangedPrompt)
}

CheckUnchangedPrompt() {
    global CFG, ST
    CFG.dryRun := false, CFG.promptScanMs := 0, CFG.promptEcooldownMs := 0
    probe := {calls:[], ok:true}, sender := PromptProbe.Bind(probe)
    archived := CFG.totalChests, seq := 820
    Loop 2 {
        attempt := A_Index, CFG.interactVerifyMs := 1100
        seen := ObservePromptFixture(++seq, "prompt", sender)
        Check(seen.used && ST.promptConfirm.hits = 1 && probe.calls.Length = attempt - 1
            , "первая плашка перед попыткой " attempt)
        sent := ObservePromptFixture(++seq, "prompt", sender)
        Check(sent.used && probe.calls.Length = attempt && ST.tgt && !ST.promptConfirm.hits
            , "после попытки старые подтверждения сброшены")
        p := ST.tgt, p.until := A_TickCount - 40
        before := WorldFixture(++seq, "prompt"), before.capturedAt := p.until - 1, ST.scanWork := 0
        Check(TryInteract(before, A_TickCount, false, sender) && !p.sameHits
            , "кадр до планового отпускания не проверяет E")
        p.keyHold := {target:ST.hwnd, releasedAt:p.until + 15}
        before := WorldFixture(++seq, "prompt"), before.capturedAt := p.keyHold.releasedAt, ST.scanWork := 0
        Check(TryInteract(before, A_TickCount, false, sender) && !p.sameHits && p.postSeq = sent.shot.captureId
            , "при задержке таймера кадр должен быть строго новее фактического отпускания")
        first := ObservePromptFixture(++seq, "prompt", sender).shot
        Check(p.postSeq = first.captureId && p.sameHits = 1 && ST.promptMemory.Length = attempt - 1
            , "один после отпускания ещё не пара")
        Check(TryInteract(first, A_TickCount, false, sender) && p.sameHits = 1, "тот же кадр не учитывается второй раз")
        late := WorldFixture(++seq, "prompt"), late.capturedAt -= 251
        Check(TryInteract(late, A_TickCount, false, sender) && p.sameHits = 1, "просроченный кадр не проверяет E")
        deferred := WorldFixture(++seq, "prompt"), ST.scanWork := CFG.scanPerTickMax
        Check(TryInteract(deferred, A_TickCount, false, sender) && deferred.HasOwnProp("promptDeferred") && p.sameHits = 1
            , "отложенный скан не превращается в повтор или исчезновение")
        post := ObservePromptFixture(++seq, "prompt", sender)
        Check(post.used && ST.tgt = p && p.sameHits = 2, "до конца окна проверки не торопимся с выводом")
        CFG.interactVerifyMs := 0 ; дедлайн сдвинут для теста
        final := WorldFixture(++seq, "prompt"), ST.scanWork := CFG.scanPerTickMax
        used := TryInteract(final, final.capturedAt, false, sender)
        Check(used = (attempt = 1) && !ST.tgt && final.HasOwnProp("promptDeferred") && ST.promptMemory.Length = 1
            && ST.promptMemory[1].repeats = attempt, "недавняя измеренная пара: " (attempt = 1 ? "повтор" : "пропуск"))
    }
    record := ST.promptMemory[1], expiry := record.until, segment := A_TickCount + 3000, ST.segUntil := segment
    same := ObservePromptFixture(++seq, "prompt", sender)
    Check(!same.used && same.shot.promptReading && ST.segUntil = segment && !ST.promptConfirm.hits
        && record.until = expiry && probe.calls.Length = 2, "исключённая плашка не останавливает ход и не продлевает пропуск")

    ObservePromptFixture(++seq, "blank", sender)
    Check(ST.promptMemory.Length = 1 && !ObservePromptFixture(++seq, "prompt", sender).used
        , "одно мерцание не снимает исключение")
    other := ObservePromptFixture(++seq, "widePrompt", sender)
    Check(other.used && ST.promptConfirm.hits = 1 && ST.promptMemory.Length = 1 && probe.calls.Length = 2
        , "другая плашка видна даже пока прежняя исключена")
    Check(!ObservePromptFixture(++seq, "prompt", sender).used, "смена кандидата не снимает старое исключение")

    ObservePromptFixture(++seq, "blank", sender)
    missed := WorldFixture(++seq), ST.scanWork := CFG.scanPerTickMax
    TryInteract(missed, missed.capturedAt, false, sender)
    Check(ST.promptMemory.Length = 1, "отсрочка после одного пустого кадра не снимает память")
    ObservePromptFixture(++seq, "blank", sender)
    Check(!ST.promptMemory.Length, "два свежих пустых измерения снимают локальную память")
    restarted := ObservePromptFixture(++seq, "prompt", sender)
    Check(restarted.used && ST.promptConfirm.hits = 1 && probe.calls.Length = 2, "после исчезновения снова нужна пара")

    ; Тот же вид после истечения; новый размер/камера/окно/поколение тоже не наследуют запись.
    for reason in ["expiry", "camera", "window", "epoch", "size"] {
        rec := record.Clone(), rec.until := A_TickCount + CFG.promptRepeatMs
        rec.view := FrameView(WorldFixture(seq, "prompt", ST.hwnd)), ST.promptMemory := [rec]
        ST.promptConfirm := NewPromptTracker()
        switch reason {
            case "expiry": rec.until := A_TickCount - 1
            case "camera": ST.cameraSeq += 1
            case "window": ST.hwnd += 1
            case "epoch": ST.inputEpoch += 1
            case "size": rec.view.w += 1
        }
        ST.scanWork := 0, shot := WorldFixture(++seq, "prompt", ST.hwnd)
        Check(TryInteract(shot, shot.capturedAt, false, sender) && !ST.promptMemory.Length
            && ST.promptConfirm.hits = 1 && probe.calls.Length = 2, reason ": не наследуем исключение")
    }
    Check(ST.promptN = 2 && !ST.chests && CFG.totalChests = archived && !ST.held.Count
        , "неизменившаяся плашка не засчитывается ни как третье E, ни как открытие")
}

TestEnemyEvidence() {
    WithGroundFixture(CheckEnemyEvidence)
}

CheckEnemyEvidence() {
    global CFG, ST
    shot := WorldFixture(120, "damage")
    dmg := FindDamageNumber(shot)
    Check(dmg && !IsEnemyCandidate(dmg) && !FindEnemyMulti(shot), "цифра не попадает в объект врага")
    shot.capturedAt := A_TickCount
    Check(!CachedEnemy(shot) && ST.scanWork = 1 && !ST.scanDmgAt && !ST.enemySeenSeq
        , "один проход, нет повторного скана цифр до наводки")

    ; Белая цифра остаётся в обоих кадрах; меняется только продолговатая фигура.
    ST.prevShot := shot, ST.scanEnemyFastAt := 0
    move := WorldFixture(121, "damage")
    FixtureRect(move, 316, 110, 32, 52, 0xDEDEDE)
    move.capturedAt := A_TickCount
    body := FindEnemyMulti(move)
    Check(IsEnemyCandidate(body) && body.src = "движение", "цифра не затеняет детектор движения")
    tr := NewEnemyTracker()
    Check(!ConfirmEnemyObservation(tr, move, body) && tr.hits = 1, "первый кандидат только наблюдение")
    Check(!ConfirmEnemyObservation(tr, move, body) && tr.hits = 1, "тот же кадр не даёт второго наблюдения")
    next := WorldFixture(122)
    Check(ConfirmEnemyObservation(tr, next, body) = body && tr.hits = 2, "согласованные метаданные разрешают повтор")
    ST.hwnd := 101
    other := WorldFixture(123, "blank", 101)
    Check(!ConfirmEnemyObservation(tr, other, body) && tr.hits = 1, "смена HWND начинает счёт заново")
    ST.cameraSeq += 1
    turned := WorldFixture(124, "blank", 101)
    Check(!ConfirmEnemyObservation(tr, turned, body) && tr.hits = 1, "новое направление начинает счёт заново")
    Check(!ConfirmEnemyObservation(tr, other, body) && tr.seq = turned.captureId, "опоздавшее наблюдение не сбрасывает новое")
}

TestCombatPreemption() {
    WithGroundFixture(CheckCombatPreemption)
}

CheckCombatPreemption() {
    global CFG, ST
    CFG.featMotionEnemy := true, CFG.enemyFastMs := 0, CFG.skinWideMs := 60000, CFG.aimReactMs := 0
    CFG.combatOverLoot := true
    ST.scanWideAt := A_TickCount, ST.prevShot := WorldFixture(300)
    for i, color in [0xDDDDDD, 0x262626] {
        frame := WorldFixture(300 + i)
        FixtureRect(frame, 233, 124, 16, 32, color)
        frame.capturedAt := A_TickCount, ST.scanWork := 0
        if (i = 1) {
            pending := {view:FrameView(frame), until:A_TickCount + 5000, keyHold:0
                , box:0, postSeq:300, postAt:0, sameHits:0}
            ST.tgt := pending
        }
        RunFixtureRoam(frame)
        Check(i = 1 ? (ST.tgt = pending && !ST.shots && frame.enemyReading)
            : (!ST.tgt && ST.enemySeenSeq = frame.captureId && ST.enemyCache)
            , "проверка противника во время E: " i " · только повтор прерывает E")
        ST.prevShot := frame
    }
    cache := ST.enemyCache, shots := ST.shots
    pending := {view:FrameView(frame), until:A_TickCount + 5000, keyHold:0
        , box:0, postSeq:302, postAt:0, sameHits:0}, ST.tgt := pending
    defer := WorldFixture(303), ST.scanWork := CFG.scanPerTickMax
    RunFixtureRoam(defer)
    Check(ST.tgt = pending && ST.enemyCache = cache && ST.shots = shots && !defer.HasOwnProp("enemyReading")
        , "пропущенный скан с кандидатом в памяти не прерывает E")
    miss := frame.Clone(), miss.DeleteProp("enemyReading"), miss.captureId := 304, miss.capturedAt := A_TickCount
    ST.scanWork := 0
    RunFixtureRoam(miss)
    Check(miss.HasOwnProp("enemyReading") && !miss.enemyReading && !ST.enemyCache && ST.tgt = pending && ST.shots = shots
        , "свежий отрицательный скан освобождает взаимодействие, не подставляя старую цель")

    aim := WorldFixture(305)
    candidate := {src:"движение", cx:aim.w / 2 + 6, cy:aim.h / 2, w:16, h:32, dist:0}
    ST.enemyCache := candidate, ST.enemySeenSeq := aim.captureId, ST.enemySeenAt := aim.capturedAt
    ST.enemyView := FrameView(aim), aim.enemyReading := candidate
    ST.enemyVelX := -100, ST.lastFire := 0
    Check(Combat(aim, aim.capturedAt) && ST.shots = shots && !ST.held.Count
        , "одного прогнозируемого попадания в прицел недостаточно для очереди")
}

TestCombatAimCorrection() {
    WithGroundFixture(CheckCombatAimCorrection)
}

CheckCombatAimCorrection() {
    global CFG, ST
    CFG.aimReactMs := 0, CFG.aimLeadMs := 85
    CFG.featFirstSlot := false, CFG.featAds := false, CFG.combatStrafe := false
    ST.lastFire := 0
    ; The detector/confirmation has already published this candidate. Check
    ; the aim decision only, with a synthetic HWND and no real mouse input.
    ; Measured offset X/Y, velocity X/Y, expected correction X/Y.
    for i, test in [[6,0,-100,0,6,0], [0,-6,0,100,0,-6], [3,0,100,0,7,0], [0,0,0,0,0,0]] {
        frame := WorldFixture(310 + i)
        item := {src:"движение", cx:frame.w / 2 + test[1], cy:frame.h / 2 + test[2], w:16, h:32, dist:Abs(test[1])}
        ST.enemyCache := item, ST.enemySeenSeq := frame.captureId, ST.enemySeenAt := frame.capturedAt
        ST.enemyView := FrameView(frame), frame.enemyReading := item
        ST.enemyVelX := test[3], ST.enemyVelY := test[4]
        ST.aimPrevDx := 0, ST.aimPrevDy := 0, ST.aimLastDx := 0, ST.aimDamp := 1.0, ST.lastAimT := 0
        aim := !!(test[5] || test[6]), shots := ST.shots, camera := ST.cameraSeq
        Check(Combat(frame, frame.capturedAt) && !!ST.lastAimT = aim && ST.aimPrevDx = test[5] && ST.aimPrevDy = test[6]
            , "наведение: прогноз и измерение не оставляют неподвижное расхождение, случай " i)
        Check(ST.shots = shots + !aim && !ST.held.Count && !ST.leftDown && ST.cameraSeq = camera
            , "виртуальная очередь только при двух точках в допуске, случай " i)
    }
}

TestCombatRetreat() {
    WithGroundFixture(CheckCombatRetreat)
}

RetreatFixture(id, hp := 32, passage := "busy") {
    global ST
    shot := NavFixture(id, passage)
    shot.hudEvidence := {confirmed:true}, shot.healthReading := {hp:{pct:hp}}
    ; В этой проверке подаём уже подтверждённую цель. Пиксели пути
    ; читаются реально; полный захват, HUD и бой проверяются на HWND.
    enemy := {src:"движение", cx:shot.w / 2, cy:shot.h / 2, w:16, h:32, dist:0}
    ST.enemy := enemy, ST.enemyCache := enemy, ST.enemySeenSeq := id, ST.enemySeenAt := shot.capturedAt
    ST.enemyView := FrameView(shot), shot.enemyReading := enemy
    return shot
}

CheckCombatRetreat() {
    global CFG, ST, SC
    CFG.featProStyle := true, CFG.navScanMs := 0, CFG.aimReactMs := 0
    ST.enemyFirstAt := A_TickCount, ST.retreatAt := 0
    ST.queuePending := false, ST.cancelHold := false, ST.leaveActive := false
    id := 501, damage := A_TickCount
    ST.damagedAt := damage
    healthy := RetreatFixture(++id, 80)
    Check(!TryCombatRetreat(healthy, healthy.capturedAt) && !ST.navInfo, "при достаточном HP не перебиваем бой")
    unknown := RetreatFixture(++id, -1), ST.hpPercent := 25
    Check(!TryCombatRetreat(unknown, unknown.capturedAt) && !ST.navInfo, "старый HP не заменяет чтение на кадре")
    hudless := RetreatFixture(++id), hudless.hudEvidence := {confirmed:false}
    Check(!TryCombatRetreat(hudless, hudless.capturedAt) && !ST.navInfo, "без подтверждения HUD не отходим")
    dropOnly := RetreatFixture(++id), ST.enemySeenSeq -= 1
    Check(!TryCombatRetreat(dropOnly, dropOnly.capturedAt) && !ST.navInfo, "падение HP и старая цель не дают отход")
    ST.damagedAt := damage - 3001
    low := RetreatFixture(++id)
    Check(!TryCombatRetreat(low, low.capturedAt) && !ST.navInfo, "низкий HP без свежего события не отменяет бой")
    ST.damagedAt := damage
    Loop 2 {
        flat := RetreatFixture(++id, 32, "flat")
        Check(!TryCombatRetreat(flat, flat.capturedAt) && !ST.navInfo.side, "без видимого бокового прохода не шагаем вслепую")
    }
    first := RetreatFixture(++id)
    Check(!TryCombatRetreat(first, first.capturedAt) && ST.navInfo.side = -1 && !ST.navInfo.sideStable
        && !TryCombatRetreat(first, first.capturedAt), "одного кадра слева недостаточно, повтор чтения не считается")
    ST.cameraSeq += 1
    turned := RetreatFixture(++id)
    Check(!TryCombatRetreat(turned, turned.capturedAt) && !ST.navInfo.sideStable, "после поворота нужен новый повтор прохода")
    late := RetreatFixture(++id), late.capturedAt := A_TickCount - 251
    Check(!TryCombatRetreat(late, A_TickCount) && ST.navInfo.seq = turned.captureId, "старый кадр не подтверждает проход")

    current := RetreatFixture(++id)
    CFG.teamSafe := true
    Check(!TryCombatRetreat(current, current.capturedAt), "в Команде нет автоматического отхода")
    CFG.teamSafe := false, CFG.featMove := false
    Check(!TryCombatRetreat(current, current.capturedAt), "без ходьбы нет бокового шага")
    CFG.featMove := true
    ST.segUntil := A_TickCount + 3000
    shots := ST.shots, camera := ST.cameraSeq
    Check(Combat(current, current.capturedAt) && ST.retreat && ST.retreat.key = SC.a
        && ST.navInfo.sideStable && ST.shots = shots && ST.cameraSeq = camera
        && !ST.segUntil && !ST.held.Count, "две оценки дали короткий шаг вместо очереди, поворота и патруля")
    step := ST.retreat, deadline := step.until, triedAt := ST.retreatAt
    prompt := WorldFixture(++id, "prompt")
    RunFixtureRoam(prompt)
    Check(ST.retreat = step && step.until = deadline && !prompt.HasOwnProp("promptReading") && ST.shots = shots
        , "короткий шаг не продлевается и не совмещается с E или боем")
    noHud := WorldFixture(++id)
    Check(!ContinueRetreatStep(noHud) && !ST.retreat && ST.retreatAt = triedAt, "при потере HUD шаг отменяется, пауза сохраняется")
    next := RetreatFixture(++id)
    Check(!TryCombatRetreat(next, next.capturedAt) && !ST.retreat && ST.retreatAt = triedAt, "не начинаем новую попытку подряд")

    ST.retreatAt := 0, ST.damagedAt := 0, ST.enemyFirstAt := A_TickCount - CFG.proFightMaxMs - 1
    next := RetreatFixture(++id)
    Check(TryCombatRetreat(next, next.capturedAt) && ST.retreat, "затянувшийся бой с низким HP тоже разрешает шаг")
    ST.inputEpoch += 1
    renewed := RetreatFixture(++id)
    Check(!ContinueRetreatStep(renewed) && !ST.retreat && !ST.held.Count
        , "новое поколение кадра не продолжает старый шаг")
}

TestCombatScanFreshness() {
    WithGroundFixture(CheckCombatScanFreshness)
}

CheckCombatScanFreshness() {
    global CFG, ST
    CFG.featMotionEnemy := true, CFG.combatOverLoot := true
    ST.bursts := 0
    for i, change in ["age", "camera", "epoch", "interrupt"] {
        ResetCaches()
        ST.tickBusy := true, ST.tickDeadline := 0, ST.tickAborted := false
        wide := Mod(i, 2)
        base := 210 + i * 5
        ST.prevShot := WorldFixture(base)
        ST.scanWideAt := wide ? 0 : A_TickCount
        cache := 0
        for j, color in [0xDDDDDD, 0x262626] {
            frame := WorldFixture(base + j)
            FixtureRect(frame, 234, 128, 13, 25, color)
            frame.capturedAt := A_TickCount
            ST.scanWork := 0, ST.scanEnemyFastAt := 0
            cache := CachedEnemy(frame)
            ST.prevShot := frame
        }
        tracker := wide ? ST.enemyWideConfirm : ST.enemyConfirm
        Check(cache && cache.src = "движение" && tracker.hits = 2 && tracker.seq = base + 2
            , change ": два реальных замера движения уже в кэше")
        view := ST.enemyView, seenAt := ST.enemySeenAt
        fastAt := A_TickCount - CFG.enemyFastMs - 1, wideAt := A_TickCount - CFG.skinWideMs - 1
        ST.scanEnemyFastAt := fastAt, ST.scanWideAt := wideAt, ST.scanWork := 0
        late := WorldFixture(base + 3, change = "age" ? "prompt" : "blank")
        segment := A_TickCount + 2000
        pending := {view:FrameView(late), until:A_TickCount + 400, keyHold:0
            , box:0, postSeq:base + 2, postAt:0, sameHits:0}
        ST.segUntil := segment, ST.tgt := pending, ST.lastAction := "прямой ход"
        combatAt := ST.combatAt
        buf := late.buf, changes := {count:0}
        late.DefineProp("buf", {Get: ChangeDuringPixelScan.Bind(late, buf, changes, change)})
        late.capturedAt := A_TickCount
        caught := false, selected := false
        try {
            try {
                if (change = "age") {
                    ; Приоритетный бой не должен пропустить старый кадр и к E.
                    RunFixtureRoam(late)
                    selected := !!ST.enemy
                } else
                    selected := Combat(late, late.capturedAt)
            } catch TickInterrupted as e {
                caught := true
                Check(e.Message = "запрос сторожа", "в скане боя работают контрольные точки")
            }
            Check(changes.count && caught = (change = "interrupt") && !selected
                && (change != "interrupt" || ST.tickAborted), change ": результат боевого скана отклонён")
            Check(!late.HasOwnProp("enemyReading") && ST.enemyCache = cache && ST.enemySeenSeq = base + 2
                && ST.enemySeenAt = seenAt && ST.enemyView = view && tracker.hits = 2 && tracker.seq = base + 2
                && ST.scanEnemyFastAt = fastAt && ST.scanWideAt = wideAt && ST.scanWork = 1
                , change ": нет нового замера, подтверждения или нового интервала скана")
            Check(ST.segUntil = segment && ST.lastAction = "прямой ход" && ST.tgt = pending
                && ST.combatAt = combatAt && !ST.shots && !ST.bursts && !ST.lastPromptE && !ST.held.Count
                , change ": скан не отнимает движение, не сбрасывает ожидание после E и не разрешает ввод")
            Check(change != "age" || (ST.tickStep = "бой: скан цели" && !late.HasOwnProp("promptReading"))
                , "после просрочки боя Roam не передаёт кадр ветке E")
        } finally {
            late.DefineProp("buf", {Value:buf})
            ST.tickBusy := false, ST.tickAbort := false, ST.tickAborted := false
        }
        same := (change = "age" || change = "interrupt")
        if same {
            deferred := WorldFixture(base + 4)
            ST.scanWork := CFG.scanPerTickMax
            Check(CachedEnemy(deferred) = cache && !deferred.HasOwnProp("enemyReading") && tracker.hits = 2
                && !CanFireOnFrame(deferred, cache, true, false), "на свежем кадре отсрочка не портит кэш и не даёт очередь")
        } else
            ST.prevShot := WorldFixture(base + 3) ; движение между двумя кадрами уже нового вида
        ST.scanWork := 0
        next := WorldFixture(base + 5)
        FixtureRect(next, 234, 128, 13, 25, 0xDDDDDD)
        next.capturedAt := A_TickCount
        confirmed := CachedEnemy(next)
        active := SameFrameView(ST.enemyWideConfirm.view, next) ? ST.enemyWideConfirm : ST.enemyConfirm
        Check(next.HasOwnProp("enemyReading") && IsEnemyCandidate(next.enemyReading) && ST.scanWork = 1
            && active.seq = next.captureId && active.hits = (same ? 3 : 1) && !!confirmed = same
            , change ": следующий свежий кадр сканируется сразу; новый вид подтверждается заново")
    }
}

CombatPixelPair(w, h, kind) {
    global ST
    ; Дополнительные байты в конце строки и ненулевой X в BGRX.
    stride := (w + 3) * 4
    frame := {w:w, h:h, stride:stride, hwnd:100, captureId:2, capturedAt:10040
        , cameraSeqAtCapture:ST.cameraSeq, inputEpochAtCapture:ST.inputEpoch}
    prev := frame.Clone(), prev.captureId := 1, prev.capturedAt := 10000
    prev.buf := Buffer(h * stride, 0x60)
    frame.buf := Buffer(h * stride, kind = "broad" ? 0xDE : kind = "changed" ? 0x64 : 0x60)
    if (kind = "motion") {
        FixtureRect(frame, Round(w * 0.55), Round(h * 0.39), Round(w * 0.022), Round(h * 0.072), 0xA2DEDEDE)
    } else if (kind = "figure" || kind = "teammate") {
        DrawCombatFigure(frame, Round(w * 0.578), Round(h * 0.32))
        if (kind = "teammate") {
            k := w / 1280
            FixtureRect(frame, Round(w * 0.578 - 23*k), Round(h * 0.32 - 20*k)
                , Max(4, Round(50*k)), Max(4, Round(10*k)), 0x0FD8FF)
        }
        prev.buf := frame.buf ; фиксированная фигура, нет изменения между кадрами
    } else if (kind = "xbyte") {
        FixtureRect(frame, Round(w * 0.53), Round(h * 0.39), Round(w * 0.022), Round(h * 0.072), 0xA4606060)
    }
    return {prev:prev, shot:frame}
}

DrawCombatFigure(shot, cx, y, size := 1) {
    k := shot.w / 1280 * size
    for spec in [[-7, 0, 14, 36], [-20, 35, 40, 21], [-12, 56, 24, 14], [-14, 70, 10, 24], [4, 70, 10, 24]]
        FixtureRect(shot, cx + Round(spec[1]*k), y + Round(spec[2]*k), Max(1, Round(spec[3]*k))
            , Max(1, Round(spec[4]*k)), 0xAAD08048)
}

TestCombatPixels() {
    WithGroundFixture(CheckCombatPixels)
}

CheckCombatPixels() {
    global CFG, ST
    CFG.featMotionEnemy := true, CFG.featTeammateGuard := true
    ; Геометрия, центр и плотность фигуры, и геометрия движения — из v11.0.6.
    for spec in [[1280, 720, [722,230,40,96,742,283,58], [704,284,28,49,718,309]]
        , [1365, 767, [767,245,45,99,789,299,59], [751,299,35,56,768,327]]
        , [1920, 1080, [1082,346,60,144,1112,425,63], [1061,425,44,77,1083,464]]
        , [2560, 1080, [1443,338,80,208,1483,452,52], [1408,432,56,70,1436,467]]] {
        label := spec[1] "x" spec[2]
        for i, kind in ["figure", "motion", "teammate", "static", "xbyte", "changed"] {
            pair := CombatPixelPair(spec[1], spec[2], kind), ST.prevShot := pair.prev
            item := FindEnemyMulti(pair.shot)
            if (i > 2) {
                Check(!item, label ": отрицательная пара " kind)
                if (kind = "teammate") {
                    diag := {}
                    Check(FindEnemySkin(pair.shot, SkinGrid(pair.shot)) && !ReadStaticFigure(pair.shot, 0, 0, diag)
                        && diag.figureReject = "похоже на метку союзника", label ": F5 и бой применяют один фильтр метки")
                }
                continue
            }
            Check(item && item.src = (i = 1 ? "фигура" : "движение"), label ": прежний канал " kind)
            expected := spec[i + 2]
            for j, prop in ["x", "y", "w", "h", "cx", "cy"]
                Check(item.%prop% = expected[j], label ": прежнее поле " kind "." prop)
            if (i = 1)
                Check(item.skin = expected[7], label ": прежняя плотность пикселей в боксе")
        }
    }
    ; Полуоткрытые границы сетки, в том числе обрезанный последний столбец
    ; и шаг крупнее ячейки. Сверяем формулу с непосредственным перебором.
    for cell in [3, 8, 12] {
        for step in [1, 5, 9, 14] {
            for len in [17, 24, 29] {
                cols := len // cell + 2
                Loop cols {
                    first := A_Index
                    Loop cols - first + 1 {
                        last := first + A_Index - 1, x := 0, count := 0
                        while (x < len) {
                            c := x // cell + 1
                            count += c >= first && c <= last
                            x += step
                        }
                        Check(SamplesInGridCells(first, last, len, cell, step) = count, "пробы в ячейках: ось/шаг/граница")
                    }
                }
            }
        }
    }
}

DrawProjectedScenery(shot) {
    ; Продолжение той же глобальной проекции строк, но вне столбцов опоры.
    k := shot.w / 1280, x := Round(shot.w * 0.199), y := Round(shot.h * 0.14)
    FixtureRect(shot, x, y, Round(64*k), Round(192*k), 0x99DA8848)
    FixtureRect(shot, x + Round(63*k), y + Round(168*k), Round(25*k), Round(24*k), 0xAACF7C39)
    FixtureRect(shot, Round(shot.w * 0.79), y + Round(189*k), Round(40*k), Round(81*k), 0xDDC78343)
}

DrawCombatDecoy(shot) {
    FixtureRect(shot, Round(shot.w * 0.70), Round(shot.h * 0.22)
        , Round(shot.w * 0.18), Round(shot.h * 0.34), 0xDA8848)
}

TestAlternativeFigure() {
    WithGroundFixture(CheckAlternativeFigure)
}

CheckAlternativeFigure() {
    global CFG, ST
    CFG.featMotionEnemy := false, CFG.featTeammateGuard := true
    for spec in [[480, 288, 0, 1.9], [480, 288, 0.92, 1.9], [1280, 720, 0.92, 1]
        , [1365, 767, 0, 1], [1920, 1080, 0, 1], [1920, 1080, 0.92, 1]] {
        w := spec[1], h := spec[2], frac := spec[3], step := frac ? CFG.skinStepWide : 0
        label := w "×" h " / " (frac ? "широкий" : "быстрый")
        shot := CombatPixelPair(w, h, "static").shot
        DrawCombatDecoy(shot)
        Check(!FindEnemyMulti(shot, frac, step), label ": одна декорация не даёт фигуру")
        DrawCombatFigure(shot, w // 2, Round(h / 2 - 25 * w / 1280 * spec[4]), spec[4])
        primary := FindEnemySkin(shot, SkinGrid(shot, frac, step)), diag := {}
        Check(!primary || StaticFigureReject(shot, primary) != "", label ": прежний максимум скрывал фигуру")
        item := FindEnemyMulti(shot, frac, step, diag)
        Check(item && item.src = "фигура" && item.HasOwnProp("isolated") && item.isolated
            && Abs(item.cx - w / 2) <= Max(4, w * 0.01) && diag.skinPct = item.skin && diag.figureReject = ""
            , label ": неподвижная фигура из отдельной группы на той же сетке")
        FixtureRect(shot, item.x, item.y - 17, item.w, 10, 0x0FD8FF)
        Check(HasTeammateMarkerAbove(shot, item.x, item.y, item.w, item.h) && !FindEnemyMulti(shot, frac, step)
            , label ": альтернативная фигура проходит ту же проверку союзника")
    }
}

TestEnemySwitch() {
    WithGroundFixture(CheckEnemySwitch)
}

CheckEnemySwitch() {
    global CFG, ST
    CFG.featMotionEnemy := false, CFG.enemyFastMs := 0, CFG.skinWideMs := 60000, CFG.aimReactMs := 0
    CFG.featFirstSlot := false, CFG.featAds := false, CFG.combatStrafe := false
    ST.scanWideAt := A_TickCount, id := 1700
    for i, cx in [208, 240, 240, 0] {
        shot := WorldFixture(++id, "red"), ST.scanWork := 0
        DrawCombatDecoy(shot)
        if cx
            DrawCombatFigure(shot, cx, 126, 1.9)
        shot.capturedAt := A_TickCount
        RunFixtureRoam(shot)
        tr := ST.enemyConfirm
        Check(shot.HasOwnProp("enemyReading") && ST.scanWork >= 1 && !ST.leftDown && !ST.held.Count
            , "один реальный замер боя на кадре, без ввода в DryRun")
        if (i = 1 || i = 2) {
            Check(shot.enemyReading && shot.enemyReading.isolated && tr.hits = 1 && !ST.enemyCache && !ST.shots
                , "новая фигура внутри 10% ширины не наследует первый замер: кадр " i)
            if (i = 1)
                Check(!CachedEnemy(shot) && tr.hits = 1, "дубликат кадра не считается повтором")
        } else if (i = 3) {
            Check(tr.hits = 2 && EnemyOnFrame(shot, shot.enemyReading) && ST.shots = 1
                , "второе чтение новой фигуры под прицелом разрешает виртуальную очередь")
        } else
            Check(!shot.enemyReading && !tr.hits && !ST.enemyCache && ST.shots = 1
                , "после исчезновения фигуры декорация не поддерживает стрельбу")
    }

    ; Разные каналы/масштабы в одном центре не подтверждают друг друга.
    tr := NewEnemyTracker(), box := {src:"фигура", cx:240, cy:144, w:16, h:32}
    Check(!ConfirmEnemyObservation(tr, WorldFixture(++id), box), "геометрия: первый замер")
    other := box.Clone(), other.src := "движение"
    Check(!ConfirmEnemyObservation(tr, WorldFixture(++id), other) && tr.hits = 1, "смена канала не даёт второй замер")
    big := other.Clone(), big.w *= 2, big.h *= 2
    Check(!ConfirmEnemyObservation(tr, WorldFixture(++id), big) && tr.hits = 1, "смена масштаба не даёт второй замер")
}

TestProjectedScenery() {
    WithGroundFixture(CheckProjectedScenery)
}

CheckProjectedScenery() {
    global CFG, ST
    CFG.featMotionEnemy := true
    for spec in [[1280,720,0,0,0,true], [1280,720,0.92,CFG.skinStepWide,0,true]
        , [1365,767,0.92,CFG.skinStepWide,0,true], [1920,1080,0,0,0,true]
        , [1920,1080,0,0,4,false], [1280,720,0.92,CFG.skinStepWide,6,false]] {
        w := spec[1], h := spec[2], label := w "x" h " · " spec[3] " · +" spec[5]
        pair := CombatPixelPair(w, h, "motion"), ST.prevShot := pair.prev, ST.stepBoost := spec[5]
        for frame in [pair.prev, pair.shot]
            FixtureRect(frame, w // 2 - 4, h // 2 - 4, 9, 9, 0xEE2727)
        expect := FindEnemyMotion(pair.shot)
        Check(expect, label ": контрольная серая фигура без опоры")
        for frame in [pair.prev, pair.shot]
            DrawProjectedScenery(frame)
        empty := pair.shot.Clone(), empty.buf := pair.prev.buf, diag := {skinPct:0}
        Check(!FindEnemyMulti(empty, spec[3], spec[4], diag), label ": неподвижная опора не цель")
        if spec[6]
            Check(InStr(diag.figureReject, "рамка растянута фоном") && diag.skinPct <= CFG.enemySkinMaxPct
                , label ": прежняя плотность прошла, локальная — нет")
        motion := FindEnemyMulti(pair.shot, spec[3], spec[4])
        Check(motion && motion.src = "движение", label ": опора больше не скрывает движение")
        for key in ["x", "y", "w", "h", "cx", "cy"]
            Check(motion.%key% = expect.%key%, label ": геометрия по движению " key)
    }

    ST.stepBoost := 0, ST.prevShot := 0
    for row in [[252, 254], [583, 582]] {
        ; Вторая фигура обрезана краем ROI. Обе рамки — из v11.0.8.
        frame := CombatPixelPair(1280, 720, "static").shot
        DrawCombatFigure(frame, 736, row[1], 0.8)
        FixtureRect(frame, 1024, 504, 102, 43, 0xF4FFFF)
        for opt in [[0,0,722,80,56], [0.92,CFG.skinStepWide,723,72,58]] {
            item := ReadStaticFigure(frame, opt[1], opt[2])
            Check(item && item.x = opt[3] && item.y = row[2] && item.w = 32 && item.h = opt[4]
                && item.skin = opt[5], "маленькая тёплая фигура сохраняет рамку рядом со вспышкой и краем ROI")
        }
    }
    self := CombatPixelPair(1280, 720, "static").shot
    for rect in [[589,324,45,95], [512,407,180,47], [544,454,115,150]]
        FixtureRect(self, rect[1], rect[2], rect[3], rect[4], 0xAAD08048)
    Check(!ReadStaticFigure(self), "сохраняется отсечка крупной фигуры в зоне своего персонажа")
    CheckSceneryKeepsPrompt()
}

CheckSceneryKeepsPrompt() {
    global CFG, ST
    ResetCaches(), ST.prevShot := 0, ST.scanWideAt := A_TickCount
    CFG.skinWideMs := 60000, CFG.enemyFastMs := 0, CFG.promptScanMs := 0, CFG.combatOverLoot := true
    Loop 4 {
        shot := WorldFixture(1900 + A_Index, A_Index < 3 ? "red" : "redPrompt")
        DrawProjectedScenery(shot)
        shot.capturedAt := A_TickCount, ST.scanWork := 0
        if (A_Index < 3) {
            Check(!Combat(shot, shot.capturedAt) && shot.HasOwnProp("enemyReading") && !shot.enemyReading
                , "постоянная опора не становится боевым кандидатом")
        } else
            RunFixtureRoam(shot)
        ST.prevShot := shot
    }
    Check(!ST.enemyCache && !ST.shots && !ST.held.Count && !ST.leftDown
        && shot.promptReading && ST.promptConfirm.hits = 2 && InStr(ST.lastAction, "DryRun: E")
        , "опора и статичный красный прицел не отбирают два кадра плашки E")
}

BenchmarkCombatScan() {
    WithGroundFixture(MeasureCombatScan)
}

MeasureCombatScan() {
    global CFG, ST, FORMA_VERSION
    CFG.featMotionEnemy := true, ST.tickBusy := true, ST.tickDeadline := 0
    DllCall("QueryPerformanceFrequency", "Int64*", &freq := 0)
    FileAppend("FORMA v" FORMA_VERSION " / AHK " A_AhkVersion " / " PixelCombatBackendName()
        . " / FindEnemyMulti (ms)`n", "*", "UTF-8")
    for size in [[1280, 720], [1920, 1080]] {
        w := size[1], h := size[2]
        for kind in ["static", "figure", "isolated", "motion", "changed", "broad"] {
            pair := CombatPixelPair(w, h, kind), ST.prevShot := pair.prev, samples := ""
            frac := 0, step := 0
            if (kind = "isolated") {
                DrawCombatDecoy(pair.shot)
                DrawCombatFigure(pair.shot, w // 2, Round(h / 2 - 25 * w / 1280))
                pair.prev.buf := pair.shot.buf
                frac := 0.92, step := CFG.skinStepWide
            }
            want := (kind = "figure" || kind = "isolated") ? "фигура" : (kind = "motion" ? "движение" : "-")
            Loop 13 {
                DllCall("QueryPerformanceCounter", "Int64*", &start := 0)
                item := FindEnemyMulti(pair.shot, frac, step)
                DllCall("QueryPerformanceCounter", "Int64*", &stop := 0)
                Check((item ? item.src : "-") = want && (kind != "isolated" || item.HasOwnProp("isolated"))
                    , "bench: неверный результат " w "x" h " " kind)
                if (A_Index > 2)
                    samples .= Format("{:.3f}", (stop - start) * 1000.0 / freq) "`n"
            }
            times := StrSplit(Sort(RTrim(samples, "`n"), "N"), "`n")
            FileAppend(size[1] "x" size[2] " " kind ": median=" times[6]
                . " min=" times[1] " max=" times[-1] " (n=11)`n", "*", "UTF-8")
        }
    }
}

TestLocalMotion() {
    WithGroundFixture(CheckLocalMotion)
}

CheckLocalMotion() {
    global CFG, ST
    CFG.featMotionEnemy := true
    pair := CombatPixelPair(1280, 720, "motion"), ST.prevShot := pair.prev
    expected := FindEnemyMotion(pair.shot)
    Check(expected && expected.src = "движение", "движение холодного/серого объекта без признака кожи")
    FixtureRect(pair.shot, 1020, 378, 18, 18, 0xFFFFFF)
    other := FindEnemyMulti(pair.shot)
    Check(other && other.src = "движение" && other.x = expected.x && other.y = expected.y
        && other.w = expected.w && other.h = expected.h, "дальняя вспышка не объединяется с фигурой")

    ; Уход объекта не даёт рамку по пустому месту старого кадра.
    back := pair.prev.Clone(), back.captureId := 3, back.capturedAt := pair.shot.capturedAt + 40
    ST.prevShot := pair.shot
    Check(!FindEnemyMotion(back), "нет кандидата на однородном фоне после исчезновения")

    broad := CombatPixelPair(1280, 720, "motion"), ST.prevShot := broad.prev
    for y in [147, 300, 450] {
        for x in [195, 427, 890]
            FixtureRect(broad.shot, x, y, 110, 65, 0xCCCCCC)
    }
    Check(!FindEnemyMotion(broad.shot), "широкие изменения фона не дают локальную цель")
    ST.prevShot := pair.prev
    pair.prev.capturedAt := pair.shot.capturedAt - CFG.enemyHoldMs - 1
    Check(!FindEnemyMotion(pair.shot), "давний кадр того же вида не сравнивается")
}

TestFireGate() {
    WithGroundFixture(CheckFireGate)
}

CheckFireGate() {
    global CFG, ST
    CFG.featMotionEnemy := true, CFG.enemyFastMs := 0, CFG.aimReactMs := 300
    id := 1010
    for kind in ["red", "white", "cyan"] {
        ResetCaches(), ST.prevShot := 0
        Loop 2 {
            sightOnly := WorldFixture(++id, kind)
            ST.scanWork := 0
            Check(!Combat(sightOnly, sightOnly.capturedAt) && !ST.enemySeenSeq && !ST.shots && !ST.held.Count
                , kind ": постоянный прицел не является целью даже на двух кадрах")
            ST.prevShot := sightOnly
        }
    }
    ; Один и тот же белый прицел на всех кадрах. Меняются только пиксели фигуры.
    ResetCaches()
    ST.prevShot := WorldFixture(++id, "white"), ST.shots := 0
    for i, color in [0xDDDDDD, 0x262626, 0xDDDDDD] {
        bodyFrame := WorldFixture(++id, "white")
        FixtureRect(bodyFrame, 233, 124, 16, 32, color)
        FixtureRect(bodyFrame, 236, 140, 9, 9, 0xEEEEEE)
        bodyFrame.capturedAt := A_TickCount
        ST.scanWork := 0
        Combat(bodyFrame, bodyFrame.capturedAt)
        if (i = 1)
            Check(bodyFrame.enemyReading && !ST.enemySeenSeq && !ST.shots && SubStr(VisionOverlayKey(bodyFrame), 3, 1) = "1"
                , "первый кандидат только виден в диагностике на своём кадре")
        if (i = 2) {
            Check(ST.enemySeenSeq = bodyFrame.captureId && ST.enemySrc = "движение" && SubStr(VisionOverlayKey(bodyFrame), 3, 1) = "2"
                , "второй свежий замер подтверждает; рамка меняет статус")
            Check(!ST.shots, "не пропускаем время реакции")
            ST.enemyFirstAt := A_TickCount - CFG.aimReactMs - 1
        }
        ST.prevShot := bodyFrame
    }
    Check(ST.shots = 1 && !ST.held.Count && !ST.leftDown, "центр фигуры: очередь только в DryRun")
    enemy := ST.enemyCache
    Check(CanFireOnFrame(bodyFrame, enemy, true, false), "валидный кадр, цель в допуске")
    Check(!CanFireOnFrame(bodyFrame, enemy, true, true) && !CanFireOnFrame(bodyFrame, enemy, false, false)
        , "после поворота или вне допуска очередь запрещена")
    later := WorldFixture(++id, "white")
    Check(!CanFireOnFrame(later, enemy, true, false), "старый кандидат не переезжает на другой кадр")
    bodyFrame.capturedAt := A_TickCount - 251
    Check(!FireBurst(bodyFrame, enemy, true, false), "старый кадр: нет очереди")
    bodyFrame.capturedAt := A_TickCount + 100
    Check(!CanFireOnFrame(bodyFrame, enemy, true, false), "время кадра из будущего не принимается")
    bodyFrame.capturedAt := A_TickCount
    ST.inputEpoch += 1
    Check(!CanFireOnFrame(bodyFrame, enemy, true, false), "старое поколение ввода не даёт очередь")
    ST.inputEpoch -= 1, ST.cameraSeq += 1
    Check(!CanFireOnFrame(bodyFrame, enemy, true, false), "поворот после захвата отменяет очередь")
    ST.cameraSeq -= 1, ST.hwnd := 102
    Check(!CanFireOnFrame(bodyFrame, enemy, true, false), "кадр другого окна не даёт очередь")
    ST.hwnd := bodyFrame.hwnd, CFG.teamSafe := true
    Check(!CanFireOnFrame(bodyFrame, enemy, true, false), "командная защита сохраняется")
}

TestSoundFrames() {
    WithGroundFixture(CheckSoundFrames)
}

CheckSoundFrames() {
    global CFG, ST
    empty := WorldFixture(140)
    Check(!SeekChestBySound(empty, empty.capturedAt) && ST.soundCacheSeq = empty.captureId
        && !ST.soundRing.chest, "пустой скан не запускает подход")
    ST.scanSoundAt := 0, ST.scanWork := 0
    next := WorldFixture(141, "sound")
    Check(SeekChestBySound(next, next.capturedAt) && ST.soundCacheSeq = next.captureId
        && ST.soundRing.chest && !ST.tgt && !ST.enemy, "следующий кадр может увидеть метку после пустого")
    work := ST.scanWork
    CachedSound(next)
    Check(ST.scanWork = work, "реакция и подход делят один замер звука")
    blank := WorldFixture(142)
    ST.scanSoundAt := A_TickCount
    Check(!SeekChestBySound(blank, blank.capturedAt) && !SoundReact(blank, blank.capturedAt)
        , "старая метка не разрешает поворот, когда скан ещё не назначен")
    ST.scanSoundAt := 0, ST.scanWork := CFG.scanPerTickMax
    before := ST.scanSkipped
    Check(!SeekChestBySound(blank, blank.capturedAt) && !SoundReact(blank, blank.capturedAt)
        && ST.scanSkipped = before + 1, "пропуск скана не повторяется и не превращает метку в действие")
    ST.scanWork := 0
    fresh := WorldFixture(143)
    Check(!SeekChestBySound(fresh, fresh.capturedAt) && ST.soundCacheSeq = fresh.captureId
        && !ST.soundRing.chest && !ST.chestAudioAt, "актуальный пустой кадр заканчивает аудиоподход")
}

RunFixtureRoam(shot) {
    shot.hudEvidence := {confirmed:true}
    Roam(shot, shot.capturedAt)
}

TestRoamPriority() {
    WithGroundFixture(CheckRoamPriority)
}

CheckRoamPriority() {
    global CFG, ST
    shot := WorldFixture(150, "prompt")
    ST.camPitch := 90, ST.segUntil := 0
    CFG.featParkour := true
    ; В low_cpu после HUD/меню может остаться ровно один слот. Сначала E.
    ST.scanWork := CFG.scanPerTickMax - 1
    RunFixtureRoam(shot)
    Check(ST.promptSeq = shot.captureId && ST.promptConfirm.hits = 1 && !ST.lastObsJump && !ST.navSteerAt
        && !ST.segUntil && !ST.scanSoundAt && !shot.HasOwnProp("enemyReading"), "подсказка раньше скана фигуры, звука и навигации")
    ST.scanWork := 0, ST.promptAt := 0
    red := WorldFixture(151, "redPrompt")
    Check(ReadInteractPrompt(red), "кадр содержит и плашку, и красный прицел")
    RunFixtureRoam(red)
    Check(!ST.shots && red.promptReading && ST.promptConfirm.hits = 2 && !red.HasOwnProp("enemyReading")
        && !ST.segUntil && !ST.navInfo && !ST.lastObsJump, "цвет прицела не перебивает подсказку E")

    ResetCaches()
    CFG.combatOverLoot := true, CFG.featMotionEnemy := true, CFG.enemyFastMs := 0
    ST.prevShot := WorldFixture(152, "prompt")
    for i, color in [0xDDDDDD, 0x242424, 0xDDDDDD] {
        both := WorldFixture(152 + i, "prompt")
        FixtureRect(both, 316, 110, 29, 55, color)
        both.capturedAt := A_TickCount, ST.scanWork := 0
        if (i < 3)
            CachedEnemy(both)
        else
            RunFixtureRoam(both)
        ST.prevShot := both
    }
    Check(ST.enemySeenSeq = both.captureId && ST.enemySrc = "движение" && !both.HasOwnProp("promptReading")
        && !ST.segUntil && !ST.held.Count, "подтверждённая фигура сохраняет настроенный приоритет над E")

    CFG.featChest := false, CFG.featLoot := false, CFG.featCombat := false, CFG.featSound := false
    ResetNavigation()
    ST.camPitch := 0, ST.scanWork := 0, ST.segUntil := 0
    open := WorldFixture(156)
    RunFixtureRoam(open)
    segmentEnd := ST.segUntil
    Check(segmentEnd > A_TickCount && ST.lastAction = "прямой ход", "без целей начинается обычный отрезок")
    open := WorldFixture(157)
    ST.scanWork := 0
    RunFixtureRoam(open)
    Check(ST.segUntil = segmentEnd && !ST.held.Count, "отрезок не перезапускается каждый кадр; DryRun без удержаний")
    ST.segUntil := 0
    Check(ForwardStep(open, 430), "начат короткий направленный шаг")
    ST.scanWork := 0
    later := WorldFixture(158)
    RunFixtureRoam(later)
    Check(!ST.segUntil && A_TickCount < ST.guidedUntil, "в паузе скана патруль не перехватывает короткий шаг")
    ST.hudLastT := A_TickCount - 851
    noHud := WorldFixture(159)
    Roam(noHud, noHud.capturedAt)
    Check(!ST.guidedUntil && !ST.segUntil && InStr(ST.lastAction, "жду подтверждение HUD")
        , "память сцены не даёт двигаться на земле без недавнего HUD")
}

TestHoldOwnership() {
    WithGroundFixture(CheckHoldOwnership)
}

CheckHoldOwnership() {
    global SC, ST
    ; Не отправляем даже key-up: каждый здесь должен быть отклонён до WinAPI.
    key := SC.a, origin := {target:0}, replacement := {target:0}, epoch := ST.inputEpoch
    ST.held[key] := origin
    first := RenewKeyHold(origin), next := RenewKeyHold(origin)
    Check(!InputReleaseRun(epoch, "key", key, origin, first) && ST.held[key] = origin
        , "старый дедлайн не обрывает продлённый шаг/стрейф")
    Check(!InputReleaseRun(epoch - 1, "key", key, origin, next), "таймер старого поколения ничего не отпускает")
    ST.held[key] := replacement
    Check(!InputReleaseRun(epoch, "key", key, origin, next) && ST.held[key] = replacement
        && !ST.inputReleasesLive, "старый A-up не обрывает новое нажатие A")
    ST.held.Delete(key)
    Check(!InputReleaseLater("key", key, 200), "без нажатия нет таймера отпускания")
}


TestDryPairGuards() {
    WithGroundFixture(CheckDryPairGuards)
}

CheckDryPairGuards() {
    global CFG, ST
    ST.tickGen := 10, ST.dryPair := 0, ST.playInputSuspended := false
    ctx := {dry:true, focused:true, mode:CFG.botMode}
    at := A_TickCount - 400
    prev := SceneFixture(1, at), current := SceneFixture(3, at + 40)
    CollectDryPair({gen:10, captureContext:{dry:false}}, prev)
    Check(!prev.HasOwnProp("drySample"), "кадр, начатый без DryRun, не помечается поздним переключением")
    first := {gen:10, captureContext:ctx}
    CollectDryPair(first, prev)
    Check(prev.HasOwnProp("drySample") && !first.HasOwnProp("dryPair"), "одного кадра недостаточно")
    ST.tickGen := 11, ST.lastShot := prev, ST.prevShot := prev
    for prop, value in Map("hwnd", 101, "cameraSeqAtCapture", current.cameraSeqAtCapture + 1
        , "inputEpochAtCapture", current.inputEpochAtCapture + 1, "captureId", prev.captureId
        , "w", current.w + 1, "stride", current.stride + 4, "x", current.x + 1
        , "capturedAt", prev.capturedAt + CFG.enemyHoldMs + 1) {
        bad := current.Clone(), bad.%prop% := value
        profile := {gen:11, captureContext:ctx}
        CollectDryPair(profile, bad)
        Check(!profile.HasOwnProp("dryPair"), "несовместимый кадр отклонён: " prop)
    }
    for mismatch in [{dry:true, focused:false, mode:ctx.mode}, {dry:true, focused:true, mode:"queue"}] {
        previousMode := CFG.botMode, CFG.botMode := mismatch.mode
        profile := {gen:11, captureContext:mismatch}
        CollectDryPair(profile, current)
        CFG.botMode := previousMode
        Check(!profile.HasOwnProp("dryPair"), "не смешиваем фокус и режим")
    }
    skipped := {gen:12, captureContext:ctx}
    ST.tickGen := 12
    CollectDryPair(skipped, current)
    Check(!skipped.HasOwnProp("dryPair"), "после пропуска тика нужна новая пара")
    ST.tickGen := 11
    profile := {gen:11, captureContext:ctx, scene:"GAME", outcome:"завершён", totalMs:180}
    CollectDryPair(profile, current)
    Check(profile.HasOwnProp("dryPair"), "отдельный диагностический captureId не разрывает соседние тики")
    ST.lastShot := current, ST.prevShot := current
    PublishDryPair(profile)
    ready := ST.dryPair
    Check(ready && ready.previous = prev && ready.current = current && ready.gap = 40
        && !profile.HasOwnProp("dryPair") && !WorldFrameCurrent(current), "запоздавший кадр остаётся только диагностическим")
    PublishDryPair({gen:10})
    Check(ST.dryPair = ready, "чужой тик не очищает последнюю пару")
    current.capturedAt := A_TickCount - 2100
    Check(!SnapshotDryPair(&why := "") && InStr(why, "старше 2 с"), "старый снимок не доходит до чтения окна")
    InputCancelDeferred()
    Check(!ST.dryPair && !SnapshotDryPair(&why), "новое поколение теряет пару без записи")
}

TestCalibrationExport() {
    global ST
    folder := A_Temp "\форма-снимок-" ProcessExist() "-" A_TickCount
    try {
        shot := WorldFixture(181, "prompt")
        shot.source := "DC окна (тест)"
        FixtureRect(shot, 24, 256, 80, 20, 0x2ABA31)
        FixtureRect(shot, 0, 0, 1, 1, 0x123456)
        FixtureRect(shot, 0, shot.h - 1, 1, 1, 0xBA9876)
        before := ST.Clone()
        saved := SaveCalibrationPair(shot, folder)
        bmp := FileRead(saved.bmp, "RAW"), txt := FileRead(saved.txt, "UTF-8")
        Check(bmp.Size = 54 + shot.buf.Size && NumGet(bmp, 0, "UShort") = 0x4D42
            && NumGet(bmp, 2, "UInt") = bmp.Size && NumGet(bmp, 10, "UInt") = 54
            && NumGet(bmp, 14, "UInt") = 40, "BMP: корректные размер и смещение пикселей")
        Check(NumGet(bmp, 18, "Int") = shot.w && NumGet(bmp, 22, "Int") = -shot.h
            && NumGet(bmp, 28, "UShort") = 32 && NumGet(bmp, 30, "UInt") = 0
            && NumGet(bmp, 54, "UInt") = 0x123456
            && NumGet(bmp, 54 + (shot.h - 1) * shot.stride, "UInt") = 0xBA9876
            , "BMP: 32-битный BGRX сверху вниз, без переворота или смены RGB")
        Check(DllCall("msvcrt\memcmp", "Ptr", bmp.Ptr + 54, "Ptr", shot.buf, "UPtr", shot.buf.Size, "CDecl Int") = 0
            , "сохранён тот же пиксельный буфер, что передан детекторам")
        Check(InStr(txt, saved.name ".bmp") && InStr(txt, FormaTitle()) && InStr(txt, "кадр #181")
            && InStr(txt, "источник: " shot.source) && InStr(txt, "плашка E: кандидат")
            && InStr(txt, "цвет прицела не участвует") && InStr(txt, "движение не измерялось")
            && !InStr(txt, A_ScriptDir), "отчёт связывает кадр и признаки, не пишет локальный путь")
        for key, value in before.OwnProps()
            Check(ST.%key% = value, "экспорт не переписывает состояние цикла: " key)

        wrong := shot.Clone(), wrong.stride += 4
        rejected := false
        try SaveCalibrationPair(wrong, folder "\invalid")
        catch ValueError
            rejected := true
        Check(rejected && !DirExist(folder "\invalid"), "некорректный буфер отклонён без файлов")
    } finally {
        try DirDelete(folder, true)
    }
}
