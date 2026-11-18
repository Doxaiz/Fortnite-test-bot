#Requires AutoHotkey v2.0
#NoTrayIcon
#Include ../fortnite_bot.ahk

; Самостоятельный тест. Не запускает Init(), Fortnite или модель.
exitCode := 0
try {
    Check(!UI.gui && !ST.running && !UI.hkKeys.Length, "при #Include интерфейс и хоткеи не запускаются")
    CFG.logFile := A_Temp "\forma-test-" ProcessExist() "-" A_TickCount ".log"
    ; Никогда не искать реальное игровое окно, даже если оно запущено.
    CFG.winTitle := "ahk_class FORMA_NoSuchWindow_ForTest"
    CFG.winTitleAlt := CFG.winTitle
    CFG.winExe := "ahk_exe FORMA_NoSuchProcess_ForTest.exe"
    for test in [TestBuildAndRestart, TestTickOutcomes, TestSkippedScanStages, TestInputGuards, TestPixelRatios
        , TestHudBelongsToCapture, TestDeferredAndInterruptedEvidence, TestMenuFromCurrentPixels
        , TestQueueOutcome, TestCalibrationIsolation] {
        test()
        FileAppend("OK: " test.Name "`n", "*", "UTF-8")
    }
} catch as e {
    FileAppend("FAIL: " e.Message " (line " e.Line ")`n", "**", "UTF-8")
    exitCode := 1
} finally {
    if InStr(CFG.logFile, A_Temp "\forma-test-") = 1
        try FileDelete(CFG.logFile)
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
    ST.tickProfile := {}, ST.lastTickMs := 820, ST.tickMs := 820
    ST.fastTicks := 5, ST.slowTicks := 2, ST.cancelHold := true
    LogThrMap["[focus]"] := 2000, LogThrMap["[tickperf]"] := 2000, LogThrMap["other"] := 2000
    ResetRunDiagnostics()
    Check(!ST.focusLostAt && !ST.focusBackAt && !ST.focusNoteAt && !ST.bgWarned, "старая потеря фокуса не переносится")
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
        Tick()
        Check(ST.tickProfile.outcome = "нет окна игры", "не найденное окно не считается кадром")
    } finally {
        ST.running := false, ST.paused := false
    }
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
    w := 480, h := 288, stride := w * 4
    shot := {captureId:id, capturedAt:at, hwnd:hwnd, w:w, h:h, stride:stride
        , x:0, y:0, buf:Buffer(stride * h, 0x60)}
    switch kind {
        case "hud", "falseHp":
            FixtureRect(shot, kind = "hud" ? 24 : 64, 256, 80, 20, 0x2ABA31)
            FixtureRect(shot, 236, 142, 9, 5, 0xFFFFFF)
        case "play", "cancel":
            FixtureRect(shot, 16, 224, 112, 32, kind = "play" ? 0xCBCB00 : 0xFFE9B4)
        case "results":
            FixtureRect(shot, 288, 96, 112, 32, 0xCBCB00)
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
    CFG.featReward := false
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
    held := SceneFixture(3, t + CFG.hudHoldMs - 1)
    Check(DetectState(held, 0, held.capturedAt) = "GAME" && !held.hudEvidence.confirmed, "память удерживает только принятый матч")
    Check(ST.hudLastT = t && ST.hudFoundSeq = held.captureId && !ST.hudFound, "кадр без полосы не обновляет время HUD и рамку")
    late := SceneFixture(4, t + CFG.hudHoldMs)
    ST.scanWork := 0
    Check(DetectState(late, 0, late.capturedAt) = "UNKNOWN", "память HUD истекает с момента захвата")
    Check(SettleScene("UNKNOWN", late.capturedAt) = "GAME", "антидребезг сцены отдельно от замера HUD")
    Check(SettleScene("UNKNOWN", t + Max(CFG.hudLostMs, CFG.hudHoldMs + CFG.sceneHoldMs)) = "UNKNOWN"
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
    before := ST.scanSkipped
    gone := SceneFixture(21, 30100)
    Check(DetectState(gone, 0, gone.capturedAt) = "UNKNOWN" && !FrameActionButton(gone, "END_SCREEN")
        , "кнопка итогов исчезла: старый результат не получает действие")
    Check(!FrameMenu(gone).results.Length && ST.scanSkipped = before + 1, "отложенный скан оставляет только проверенные по пикселям подсказки")
    similar := SceneFixture(22, 30200, "results")
    Check(DetectState(similar, 0, similar.capturedAt) = "END_SCREEN" && !FrameActionButton(similar, "END_SCREEN")
        , "цвет на старом месте итогов ещё не даёт координат для клика")
    game := SceneFixture(23, 30300, "hud")
    FixtureRect(game, 288, 96, 112, 32, 0xCBCB00)
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
    for key, value in before.OwnProps()
        Check(ST.%key% = value, "F5 не переписывает состояние цикла: " key)
}
