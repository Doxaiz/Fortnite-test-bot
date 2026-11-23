#Requires AutoHotkey v2.0
#NoTrayIcon
#Include ../fortnite_bot.ahk

; Require the real packaged DLL, and compare its raw observations to the AHK
; reference on the exact same Buffer. No game window, Init, timers, or input.
try {
    backend := PixelBackend()
    RequirePixelTest(backend && backend.warm && backend.motion && backend.warmPeak && !UI.gui && !ST.running
        , "Rust backend (including the peak export) required without Init()")
    for test in [TestMasks, TestRows, TestRatios, TestWarmGrid, TestMotionCells, TestCombatLayouts
        , TestCapacityFallback, TestNativeInterrupt] {
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

TestWarmGrid(backend) {
    shot := NewPixelFixture(145, 109), buf := shot.buf
    palette := [0x78675E, 0x78685E, 0x82635E, 0x82645E, 0x78655F, 0x77665D, 0xE8E8E1, 0xD08048]
    for i, rgb in palette
        PixelTestRect(shot, 4 + (i - 1) * 17, 10 + Mod(i, 3) * 18, 13, 19, rgb)
    for cell in [3, 8, 17] {
        for step in [1, 4, 9, 12] {
            geo := {x:3, y:5, w:138, h:101, cell:cell, step:step, cw:138 // cell + 2, ch:101 // cell + 2}
            expected := SkinGridAhk(buf, shot.stride, geo)
            geo.cnt := expected.cnt, geo.totalSkin := expected.totalSkin
            peak := FindWarmPeakAhk(geo)
            for optedIn in [false, true] {
                entry := optedIn ? backend.warmPeak : backend.warm
                native := PixelNativeWarmGrid(entry, shot, buf, geo, optedIn)
                label := "warm grid " cell "/" step " peak=" optedIn
                RequirePixelTest(native && native.totalSkin = expected.totalSkin && native.totalSkin > 0
                    && native.cnt.Length = expected.cnt.Length && !!native.peak = optedIn, label ": population, length and ABI")
                for i, n in expected.cnt
                    RequirePixelTest(native.cnt[i] = n, label " cell " i)
                if optedIn {
                    for key in ["col", "row", "score"]
                        RequirePixelTest(native.peak.%key% = peak.%key%, label ": " key)
                }
            }
        }
    }
    empty := NewPixelFixture(16, 16)
    geo := {x:0, y:0, w:16, h:16, cell:8, step:1, cw:4, ch:4}
    native := PixelNativeWarmGrid(backend.warmPeak, empty, empty.buf, geo, true)
    RequirePixelTest(native && !native.totalSkin && !native.peak.col && !native.peak.row && !native.peak.score
        , "empty mask is a successful zero peak")
    PixelTestRect(empty, 0, 0, 2, 2, 0xD08048)
    geo.w := 2, geo.h := 2, geo.cw := 2, geo.ch := 2
    native := PixelNativeWarmGrid(backend.warmPeak, empty, empty.buf, geo, true)
    RequirePixelTest(native && native.totalSkin = 4 && native.cnt[1] = 4 && !native.peak.score
        , "grid too small for a full window still reports its warm samples")
}

CompareMotionCells(backend, shot, prev, r, step, wantChanges) {
    cols := (r.x2 - r.x1 + 2 * step - 1) // (2 * step)
    native := PixelNativeMotion(backend.motion, shot, prev, r, step, cols)
    expected := MotionGridAhk(shot, prev, r, step, cols)
    label := "motion grid step " step
    RequirePixelTest(native && !!native.hits = wantChanges && native.hits = expected.hits
        && native.cells.Count = expected.cells.Count, label ": population and length")
    for key, cell in expected.cells {
        RequirePixelTest(native.cells.Has(key), label ": key " key)
        for prop in ["x1", "y1", "x2", "y2", "n"]
            RequirePixelTest(native.cells[key].%prop% = cell.%prop%, label " cell " key " " prop)
    }
}

TestMotionCells(backend) {
    shot := NewPixelFixture(145, 109), prev := NewPixelFixture(145, 109)
    r := {x1:3, y1:5, x2:143, y2:107}
    PixelTestRect(shot, 9, 14, 30, 45, 0x303030) ; X only
    CompareMotionCells(backend, shot, prev, r, 1, false)
    PixelTestRect(shot, 7, 17, 25, 22, 0x7D3030) ; RGB L1 distance 77
    PixelTestRect(shot, 35, 18, 23, 22, 0x7E3030) ; distance 78
    PixelTestRect(shot, 53, 77, 34, 28, 0xDEDEDE) ; own zone, not a hit
    PixelTestRect(shot, 123, 90, 21, 18, 0xDEDEDE) ; clipped by ROI
    for step in [1, 3, 7, 12]
        CompareMotionCells(backend, shot, prev, r, step, true)
    PixelTestRect(shot, 0, 0, shot.w, shot.h, 0xDEDEDE)
    CompareMotionCells(backend, shot, prev, r, 3, false) ; widespread change
}

TestCombatLayouts(backend) {
    shot := NewPixelFixture(801, 359), prev := NewPixelFixture(801, 359)
    ; Rejection of the sample limit comes from the DLL, not the AHK layout check.
    geo := {x:0, y:0, w:shot.w, h:shot.h, cell:8, step:1, cw:shot.w // 8 + 2, ch:shot.h // 8 + 2}
    RequirePixelTest(!PixelNativeWarmGrid(backend.warm, shot, shot.buf, geo), "warm sample limit")
    RequirePixelTest(!PixelNativeWarmGrid(backend.warmPeak, shot, shot.buf, geo, true), "peak uses the same sample limit")
    r := {x1:0, y1:0, x2:shot.w, y2:shot.h}
    RequirePixelTest(!PixelNativeMotion(backend.motion, shot, prev, r, 1, (shot.w + 1) // 2)
        , "motion sample limit")
    prev.stride -= 1
    RequirePixelTest(!PixelNativeMotion(backend.motion, shot, prev, r, 8, (shot.w + 15) // 16)
        , "previous frame stride must match")
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

        ST.tickAbort := false, ST.tickAborted := false, caught := false
        previous := NewPixelFixture(15, 15), callback := CallbackCreate(AbortDuringCall, "Fast", 10)
        try PixelNativeMotion(callback, shot, previous, r, 2, 4)
        catch TickInterrupted
            caught := true
        finally CallbackFree(callback)
        RequirePixelTest(caught && ST.tickAborted, "motion abort cannot publish a reading")
    } finally {
        ST.tickBusy := false, ST.running := false, ST.tickAbort := false, ST.tickAborted := false
    }
}

AbortDuringCall(*) {
    global ST
    ST.tickAbort := true
    return 0
}
