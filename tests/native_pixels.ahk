#Requires AutoHotkey v2.0
#NoTrayIcon
#Include ../fortnite_bot.ahk

; Require the real packaged DLL, and compare its raw observations to the AHK
; reference on the exact same Buffer. No game window, Init, timers, or input.
try {
    backend := PixelBackend()
    RequirePixelTest(backend && !UI.gui && !ST.running, "Rust backend required without Init()")
    for test in [TestMasks, TestRows, TestRatios, TestCapacityFallback, TestNativeInterrupt] {
        test(backend)
        FileAppend("OK: " test.Name " · " PixelBackendName() "`n", "*", "UTF-8")
    }
} catch as e {
    FileAppend("FAIL: " e.Message " (line " e.Line ")`n" e.Stack "`n", "**", "UTF-8")
    ExitApp(1)
}
ExitApp(0)

RequirePixelTest(ok, label) {
    if !ok
        throw Error(label, -1)
}

NewPixelFixture(w, h) {
    stride := w * 4 + 7 ; uneven padding, plus nonzero X in the pixels
    return {w:w, h:h, stride:stride, buf:Buffer(stride * h, 0x30)}
}

PixelTestRect(shot, x, y, w, h, rgb) {
    Loop h {
        offset := (y + A_Index - 1) * shot.stride + x * 4
        Loop w
            NumPut("UInt", 0xA3000000 | rgb, shot.buf, offset + (A_Index - 1) * 4)
    }
}

CompareMasks(actual, reference, label) {
    RequirePixelTest(actual && actual.Count = reference.Count, label ": modes")
    for mode, expected in reference {
        RequirePixelTest(actual.Has(mode) && actual[mode].Length = expected.Length, label ": " mode " length")
        for i, hit in expected {
            for field in ["x", "y", "w", "h", "cx", "cy", "n", "area", "fill", "cells"]
                RequirePixelTest(actual[mode][i].%field% = hit.%field%, label ": " mode " #" i " " field)
        }
    }
}

TestMasks(backend) {
    global CFG
    names := ["chestGold", "chestRare", "gold", "cream", "green", "blue", "purple", "red", "white", "pure", "yellow"]
    palette := [0x96553E, 0x62A0DA, 0x8C5032, 0xC8BE96, 0x507850, 0x55788C, 0x694691, 0x6E4141, 0xD7D7CD, 0xF5F5EE, 0x9B9B64]
    shot := NewPixelFixture(145, 109), roi := [0.02, 0.03, 0.97, 0.98]
    for i, color in palette {
        ; Several separated hits in each mode; two touch on a cell diagonal.
        x := 4 + Mod(i - 1, 4) * 34, y := 5 + ((i - 1) // 4) * 31
        PixelTestRect(shot, x, y, 8, 8, color)
        PixelTestRect(shot, x + 8, y + 8, 8, 8, color)
        PixelTestRect(shot, x + 21, y, 6, 8, color)
    }
    r := RegionToPixels(shot, roi), buf := shot.buf
    original := CFG.yBMax
    try {
        for blueLimit in [original, CFG.creamBMin] {
            CFG.yBMax := blueLimit
            for modes in [names, ["gold", "cream"], ["yellow", "cream"], ["cream"], ["pure"], ["chestGold", "chestRare"]] {
                for grid in [[4, 1, 1], [6, 3, 2], [14, 4, 2], [18, 7, 1]] {
                    cell := grid[1], step := grid[2], minCells := grid[3]
                    native := PixelNativeClusters(backend.clusters, shot, r, buf, modes, cell, step, minCells)
                    reference := MaskClustersMultiAhk(buf, shot.stride, r, modes, cell, step, minCells)
                    CompareMasks(native, reference, "Rust clusters " blueLimit "/" cell "/" step)
                }
            }
        }
    } finally CFG.yBMax := original
}

TestRows(backend) {
    global CFG
    shot := NewPixelFixture(145, 231), buf := shot.buf, stride := shot.stride
    r := {x1:3, y1:5, x2:143, y2:230}
    for strip in [[5, 53, 0xCBCB00], [65, 27, 0xBCBCE0], [101, 49, 0x969EDE], [161, 68, 0xAE525C]] {
        PixelTestRect(shot, 3, strip[1], 16, strip[2], strip[3])
        PixelTestRect(shot, 43, strip[1], 16, strip[2], strip[3])
    }
    yellow := [CFG.yRMin, CFG.yGMin, CFG.yBMax, CFG.yRGDelta]
    for mode in [0, 1, 2, 3] {
        sx := mode = 0 ? 2 : 3, sy := sx
        reference := mode = 0 ? LobbyRowsAhk(buf, stride, r, yellow)
            : mode = 3 ? RedMenuRowsAhk(buf, stride, r, sx, sy)
            : LightPlateRowsAhk(buf, stride, r, sx, sy, mode = 2)
        actual := PixelNativeRows(backend.rows, shot, r, buf, sx, sy, mode, "test rows", yellow)
        RequirePixelTest(actual && actual.rows.Length = reference.rows.Length && actual.bestRun = reference.bestRun
            && actual.bestRun > 0, "row count and maximum for mode " mode)
        for i, row in reference.rows {
            run := actual.rows[i]
            RequirePixelTest(run.y = row.y && run.run = row.run && run.cx = row.cx, "row parity " mode "/" i)
        }
        if (mode = 0)
            RequirePixelTest(actual.rows[1].cx = 11, "first equal yellow run wins")
    }
}

TestRatios(backend) {
    shot := NewPixelFixture(83, 271), buf := shot.buf, stride := shot.stride
    PixelTestRect(shot, 0, 7, 83, 72, 0x272828) ; dark sum 119
    PixelTestRect(shot, 0, 80, 83, 59, 0x282828) ; dark sum 120
    PixelTestRect(shot, 0, 141, 83, 50, 0xA4A5A6) ; integer luma 164
    PixelTestRect(shot, 0, 196, 83, 60, 0xA5A5A5)
    for roi in [[0, 0, 1, 1], [0.03, 0.04, 0.97, 0.99], [0.97, 0.99, 1, 1]] {
        r := RegionToPixels(shot, roi)
        for threshold in [-1, 0, 164, 165, 166, 256]
            RequirePixelTest(PixelNativeRatio(backend.ratio, shot, r, buf, 0, threshold) = BrightRatioAhk(buf, stride, r, threshold)
                , "bright ratio at " threshold)
        RequirePixelTest(PixelNativeRatio(backend.ratio, shot, r, buf, 1, 0) = DarkRatioAhk(buf, stride, r), "dark ratio")
    }
}

TestCapacityFallback(backend) {
    ; A cluster count above output capacity must never publish a partial list.
    shot := NewPixelFixture(133, 133), buf := shot.buf
    Loop 67 {
        offset := (A_Index - 1) * 2 * shot.stride
        Loop 67
            NumPut("UInt", 0xC9FFFFFF, buf, offset + (A_Index - 1) * 8)
    }
    roi := [0, 0, 1, 1], r := RegionToPixels(shot, roi), modes := ["white"]
    RequirePixelTest(!PixelNativeClusters(backend.clusters, shot, r, buf, modes, 1, 1, 1), "capacity rejected")
    full := MaskClustersMulti(shot, roi, modes, 1, 1, 1)["white"]
    RequirePixelTest(full.Length = 67 * 67 && full[-1].cx = 132 && full[-1].cy = 132, "no partial masks from native error")
    shot.buf := Buffer(12, 0)
    RequirePixelTest(PixelNativeRatio(backend.ratio, shot, r, shot.buf, 0, 0) = -1, "short buffer rejected")
}

TestNativeInterrupt(backend) {
    global ST
    shot := NewPixelFixture(15, 15), r := RegionToPixels(shot, [0, 0, 1, 1]), buf := shot.buf
    ST.tickBusy := true, ST.running := true, ST.tickAbort := true
    try {
        caught := false
        try PixelNativeClusters(backend.clusters, shot, r, buf, ["white"], 4, 2, 1)
        catch TickInterrupted
            caught := true
        RequirePixelTest(caught && ST.tickAborted, "watchdog checked before DLL")

        ; Simulate an abort becoming visible during the synchronous call.
        ; Test the shared call wrapper, without a real game or race on a timer.
        ST.tickAbort := false, ST.tickAborted := false, caught := false
        callback := CallbackCreate(AbortDuringCall, "Fast", 6)
        try PixelNativeRatio(callback, shot, r, buf, 0, 0)
        catch TickInterrupted
            caught := true
        finally CallbackFree(callback)
        RequirePixelTest(caught && ST.tickAborted, "watchdog checked before returning results")
    } finally {
        ST.tickBusy := false, ST.running := false, ST.tickAbort := false, ST.tickAborted := false
    }
}

AbortDuringCall(*) {
    global ST
    ST.tickAbort := true
    return 0
}
