#Requires AutoHotkey v2.0
#NoTrayIcon
#Include ../fortnite_bot.ahk
#SingleInstance Off

; Dedicated GDI fixture, no Init, game window, game input or profile files.
SetDpiAware()
SetWinDelay(0)
if (A_Args.Length = 3 && A_Args[1] = "--receiver") {
    ServeCaptureFixture(A_Args[2], A_Args[3] = "framed")
    return
}
ExitApp(RunCaptureFixtures(A_Args.Length = 1 && A_Args[1] = "--bench"))

CaptureCheck(ok, label) {
    if !ok
        throw Error(label, -1)
}

RunCaptureFixtures(bench) {
    global CFG, ST, UI
    CFG.logFile := A_Temp "\forma-capture-test-" ProcessExist() "-" A_TickCount ".log"
    try {
        CaptureCheck(!ST.running && !UI.gui && !UI.hkKeys.Length, "no Init or input hooks")
        MonitorGetWorkArea(MonitorGetPrimary(), &left, &top, &right, &bottom)
        work := {x:left, y:top, w:right-left, h:bottom-top}
        TestCaptureBlankRgb()
        for framed in [false, true] {
            pid := 0
            tag := "FORMA capture " ProcessExist() "-" A_TickCount
            style := framed ? "framed" : "bare"
            try {
                Run('"' A_AhkPath '" /ErrorStdOut=UTF-8 "' A_ScriptFullPath '" --receiver "' tag '" ' style, , , &pid)
                hwnd := WinWait(tag " ahk_pid " pid, , 6)
                CaptureCheck(hwnd && WinGetPID("ahk_id " hwnd) = pid, "dedicated receiver")
                area := ShowCaptureFixture(hwnd, work, 480, 288)
                WinGetPos(, , &ww, &wh, "ahk_id " hwnd)
                CaptureCheck(framed = (ww > area.w || wh > area.h), "window frame/crop setup")
                TestCaptureMethods(hwnd, area, style)
                if !framed {
                    TestCaptureFallback(hwnd)
                    TestCaptureGeometry(hwnd, work, area)
                    if bench
                        BenchmarkWindowCapture(hwnd, work)
                }
            } finally {
                if pid && ProcessExist(pid) {
                    ProcessClose(pid)
                    ProcessWaitClose(pid, 2)
                }
            }
        }
    } catch as e {
        FileAppend("FAIL: " e.Message " (line " e.Line ")`n" e.Stack "`n", "**", "UTF-8")
        return 1
    } finally {
        try FileDelete(CFG.logFile)
    }
    return 0
}

TestCaptureBlankRgb() {
    buf := Buffer(50 * 50 * 4, 0)
    Loop 25
        NumPut("UInt", A_Index << 24, buf, (A_Index - 1) * 8)
    CaptureCheck(IsBlankPixels(buf, 50, 50), "25 different X bytes do not make a black image nonblank")
    Loop 25
        NumPut("UInt", A_Index, buf, (A_Index - 1) * 8)
    CaptureCheck(!IsBlankPixels(buf, 50, 50), "25 RGB values make a nonblank image")
    FileAppend("OK: blank gate ignores X in BGRX`n", "*", "UTF-8")
}

ShowCaptureFixture(hwnd, work, w, h) {
    win := "ahk_id " hwnd
    old := GetClientArea(hwnd, true)
    WinGetPos(, , &ww, &wh, win)
    outerW := w + ww - old.w, outerH := h + wh - old.h
    CaptureCheck(outerW <= work.w && outerH <= work.h, "needs a visible test desktop")
    WinMove(work.x, work.y, outerW, outerH, win)
    SetCaptureFixture(hwnd, false)
    area := GetClientArea(hwnd, true)
    CaptureCheck(area && area.w = w && area.h = h, "fixture has the requested client size")
    return area
}

SetCaptureFixture(hwnd, blank) {
    CaptureCheck(SendMessage(0x8023, blank, 0, , "ahk_id " hwnd, , , , 1000) = 1, "fixture repaint")
    DllCall("dwmapi\DwmFlush", "Int")
}

TestCaptureMethods(hwnd, area, style) {
    for viaDc in [false, true] {
        attempts := [], shot := CaptureAttempt(hwnd, area, viaDc, attempts)
        CaptureCheck(CaptureFixtureMatches(shot, area), style " " attempts[1].method " has the expected client RGB")
        CaptureCheck(attempts[1].outcome = "изображение" && attempts[1].gdiMs >= 0
            && attempts[1].ms >= attempts[1].gdiMs, "time measures the correct attempt")
    }
    shot := CaptureClient(hwnd, &trace := 0)
    CaptureCheck(CaptureFixtureMatches(shot, area) && shot.captureTiming = trace && trace.attempts[1].method = "PrintWindow"
        && trace.ms >= trace.attempts[1].ms && trace.outcome = "кадр #" shot.captureId, "owned per-frame timings")
    FileAppend("OK: " style " client crop, top-down BGRX and both GDI methods`n", "*", "UTF-8")
}

TestCaptureFallback(hwnd) {
    global ST
    seq := ST.captureSeq
    SetCaptureFixture(hwnd, true)
    CaptureCheck(!CaptureClient(hwnd, &failed := 0) && ST.captureSeq = seq && failed.attempts.Length = 2
        && failed.outcome = "нет изображения", "uniform window in both methods publishes no frame")
    a := failed.attempts[1], b := failed.attempts[2]
    CaptureCheck(a.method = "PrintWindow" && b.method = "DC окна" && a.outcome = "одноцветный кадр"
        && b.outcome = "одноцветный кадр" && failed.ms >= a.ms + b.ms, "both failed timings are retained in order")
    SetCaptureFixture(hwnd, false)
    ST.capNoPrintT := A_TickCount + 10000
    try {
        ready := CaptureClient(hwnd, &trace := 0)
        CaptureCheck(ready && trace != failed && trace.attempts.Length = 1 && trace.attempts[1].method = "DC окна"
            && ready.captureId = seq + 1 && failed.attempts.Length = 2, "DC-first uses a new sample, not the previous trace")
    } finally ST.capNoPrintT := 0
    FileAppend("OK: empty PrintWindow and DC, ordered attempt timings, then DC-first recovery`n", "*", "UTF-8")
}

TestCaptureGeometry(hwnd, work, old) {
    global ST
    area := ShowCaptureFixture(hwnd, work, 353, 227), attempts := []
    CaptureCheck(!CaptureAreaCurrent(hwnd, old), "old client geometry invalid after resize")
    CaptureCheck(!CaptureAttempt(hwnd, old, false, attempts) && attempts[1].gdiMs < 0
        && attempts[1].outcome = "границы клиента", "old crop is rejected before PrintWindow or copying")
    fresh := CaptureClient(hwnd)
    CaptureCheck(CaptureFixtureMatches(fresh, area), "resized client is recaptured at the new dimensions")
    WinMinimize("ahk_id " hwnd)
    try {
        deadline := A_TickCount + 1000
        while !DllCall("user32\IsIconic", "Ptr", hwnd, "Int") {
            CaptureCheck(A_TickCount < deadline, "fixture did not minimize")
            Sleep(10)
        }
        seq := ST.captureSeq
        CaptureCheck(!CaptureAreaCurrent(hwnd, area) && !CaptureClient(hwnd, &mini := 0)
            && !mini.attempts.Length && mini.outcome = "окно свёрнуто" && ST.captureSeq = seq, "minimized: no attempt and no capture id")
    } finally WinRestore("ahk_id " hwnd)
    FileAppend("OK: resize invalidates old crop, next capture matches; minimized skips GDI`n", "*", "UTF-8")
}

BenchmarkWindowCapture(hwnd, work) {
    FileAppend("CaptureAttempt (QPC ms), visible work area " work.w "x" work.h "`n", "*", "UTF-8")
    for size in [[480, 288], [800, 450], [1280, 720], [1920, 1080]] {
        w := size[1], h := size[2]
        if (w > work.w || h > work.h) {
            FileAppend("SKIP capture " w "x" h ": does not fit the visible work area`n", "*", "UTF-8")
            continue
        }
        area := ShowCaptureFixture(hwnd, work, w, h)
        for viaDc in [false, true] {
            samples := "", empty := 0, wrong := 0, rejected := 0, late := 0
            Loop 23 {
                attempts := [], at := A_TickCount
                shot := CaptureAttempt(hwnd, area, viaDc, attempts)
                age := A_TickCount - at
                entry := attempts[1]
                if (A_Index <= 2)
                    continue
                samples .= Format("{:.3f}", entry.ms) "`n"
                if shot {
                    late += age > 250
                    wrong += !CaptureFixtureMatches(shot, area)
                } else if (entry.outcome = "одноцветный кадр") {
                    empty += 1
                } else
                    rejected += 1
            }
            times := StrSplit(Sort(RTrim(samples, "`n"), "N"), "`n")
            FileAppend("CAPTURE " w "x" h " " (viaDc ? "BitBlt" : "PrintWindow") ": median=" times[11] " p95=" times[20]
                . " empty=" empty " wrong=" wrong " rejected=" rejected " over250=" late " (n=21)`n", "*", "UTF-8")
        }
    }
}

CaptureFixtureMatches(shot, area) {
    if (!shot || shot.x != area.x || shot.y != area.y || shot.w != area.w || shot.h != area.h
        || shot.stride != area.w * 4 || shot.buf.Size != shot.stride * shot.h)
        return false
    ; Sample the centres of 48 distinct cells and both end rows: orientation,
    ; stride, client offset and stale content, ignoring the X-byte.
    Loop 6 {
        row := A_Index - 1, y := (2*row + 1) * shot.h // 12
        Loop 8 {
            col := A_Index - 1, x := (2*col + 1) * shot.w // 16
            if (CaptureFixtureRgb(shot, x, y) != CaptureFixtureColor(col, row))
                return false
        }
    }
    return CaptureFixtureRgb(shot, 0, 0) = CaptureFixtureColor(0, 0)
        && CaptureFixtureRgb(shot, shot.w - 1, shot.h - 1) = CaptureFixtureColor(7, 5)
}

CaptureFixtureRgb(shot, x, y) {
    return NumGet(shot.buf, y * shot.stride + 4*x, "UInt") & 0xFFFFFF
}

CaptureFixtureColor(col, row) {
    return ((32 + col * 24) << 16) | ((24 + row * 28) << 8) | (30 + Mod(col * 19 + row * 43, 180))
}

ServeCaptureFixture(tag, framed) {
    global captureFixture := {blank:false, buf:Buffer(8 * 6 * 4, 0), black:Buffer(8 * 6 * 4, 0), info:Buffer(40, 0)}
    Loop 48 {
        i := A_Index - 1
        NumPut("UInt", CaptureFixtureColor(Mod(i, 8), i // 8), captureFixture.buf, 4*i)
    }
    NumPut("UInt", 40, "Int", 8, "Int", -6, "UShort", 1, "UShort", 32, captureFixture.info)
    receiver := Gui("+ToolWindow +AlwaysOnTop -DPIScale +E0x08000000 " (framed ? "+Caption +Border" : "-Caption"), tag)
    captureFixture.gui := receiver, captureFixture.hwnd := receiver.Hwnd
    OnMessage(0x000F, CaptureFixturePaint)
    OnMessage(0x0317, CaptureFixturePrint)
    OnMessage(0x0318, CaptureFixturePrint)
    OnMessage(0x8023, RepaintCaptureFixture)
    receiver.Show("NA x20 y20 w480 h288")
    SetTimer(ExitApp, -45000)
}

RepaintCaptureFixture(wParam, lParam, msg, hwnd) {
    global captureFixture
    if (hwnd != captureFixture.hwnd)
        return 0
    captureFixture.blank := !!wParam
    dc := DllCall("user32\GetDC", "Ptr", hwnd, "Ptr")
    if !dc
        return 0
    try PaintCaptureFixture(hwnd, dc, false)
    finally DllCall("user32\ReleaseDC", "Ptr", hwnd, "Ptr", dc)
    return 1
}

CaptureFixturePaint(wParam, lParam, msg, hwnd) {
    global captureFixture
    if (hwnd != captureFixture.hwnd)
        return
    ps := Buffer(A_PtrSize = 8 ? 72 : 64, 0)
    dc := DllCall("user32\BeginPaint", "Ptr", hwnd, "Ptr", ps, "Ptr")
    if dc {
        try PaintCaptureFixture(hwnd, dc, false)
        finally DllCall("user32\EndPaint", "Ptr", hwnd, "Ptr", ps)
    }
    return 0
}

CaptureFixturePrint(dc, lParam, msg, hwnd) {
    global captureFixture
    if (hwnd = captureFixture.hwnd) {
        PaintCaptureFixture(hwnd, dc, msg = 0x0317)
        return 1
    }
}

PaintCaptureFixture(hwnd, dc, whole) {
    global captureFixture
    area := GetClientArea(hwnd, true), x := 0, y := 0
    if !area
        return
    if whole {
        WinGetPos(&wx, &wy, , , "ahk_id " hwnd)
        x := area.x - wx, y := area.y - wy
    }
    DllCall("gdi32\SetStretchBltMode", "Ptr", dc, "Int", 3, "Int")
    DllCall("gdi32\StretchDIBits", "Ptr", dc, "Int", x, "Int", y, "Int", area.w, "Int", area.h
        , "Int", 0, "Int", 0, "Int", 8, "Int", 6, "Ptr", (captureFixture.blank ? captureFixture.black : captureFixture.buf)
        , "Ptr", captureFixture.info, "UInt", 0, "UInt", 0x00CC0020, "Int")
    DllCall("gdi32\GdiFlush", "Int")
}
