; FORMA's optional read-only x64 pixel backend (native/pixels, ABI 1).
; No environment search, automatic download, or change of working directory.
PixelBackend() {
    static backend := -1
    if (backend != -1)
        return backend
    ; First use in Init, an included test, or offline BMP replay.
    dir := A_ScriptDir
    if !A_IsCompiled
        SplitPath(A_LineFile, , &dir)
    dll := dir "\forma_pixels.dll"
    module := 0, ready := 0
    if (A_PtrSize = 8) {
        try {
            ; Absolute path; resolve runtime dependencies only from System32.
            module := DllCall("kernel32\LoadLibraryExW", "WStr", dll, "Ptr", 0, "UInt", 0x800, "Ptr")
            if module {
                abi := DllCall("kernel32\GetProcAddress", "Ptr", module, "AStr", "forma_pixels_abi", "Ptr")
                if (abi && DllCall(abi, "UInt") = 1) {
                    clusters := DllCall("kernel32\GetProcAddress", "Ptr", module, "AStr", "forma_pixels_clusters", "Ptr")
                    rows := DllCall("kernel32\GetProcAddress", "Ptr", module, "AStr", "forma_pixels_rows", "Ptr")
                    ratio := DllCall("kernel32\GetProcAddress", "Ptr", module, "AStr", "forma_pixels_ratio_hits", "Ptr")
                    if (clusters && rows && ratio) {
                        ; Optional, additive exports. An older ABI-1 DLL still
                        ; accelerates menus and loot; combat stays on AHK.
                        warm := DllCall("kernel32\GetProcAddress", "Ptr", module, "AStr", "forma_pixels_warm_grid", "Ptr")
                        motion := DllCall("kernel32\GetProcAddress", "Ptr", module, "AStr", "forma_pixels_motion_cells", "Ptr")
                        if (!warm || !motion)
                            warm := 0, motion := 0
                        ready := {clusters:clusters, rows:rows, ratio:ratio, warm:warm, motion:motion}
                    }
                }
            }
        } catch {
            ; AHK scans still work if no compatible module can be loaded.
        }
        if (module && !ready)
            DllCall("kernel32\FreeLibrary", "Ptr", module)
        ; Keep a usable module loaded for the life of this process.
    }
    backend := ready
    return backend
}

PixelBackendName() {
    return PixelBackend() ? "Rust DLL (ABI 1)" : "AutoHotkey (резерв)"
}

PixelCombatBackendName() {
    p := PixelBackend()
    return p && p.warm ? "Rust DLL (ABI 1)" : "AutoHotkey (резерв)"
}

PixelFrameSupported(shot, buf) {
    return buf is Buffer && IsInteger(shot.w) && IsInteger(shot.h) && IsInteger(shot.stride)
        && shot.w >= 2 && shot.w <= 8192 && shot.h >= 2 && shot.h <= 8192
        && shot.stride >= shot.w * 4 && buf.Size <= 128 * 1024 * 1024 && shot.stride <= buf.Size // shot.h
}

PixelI32(values) {
    for v in values {
        if (!IsInteger(v) || v < -2147483648 || v > 2147483647)
            return false
    }
    return true
}

PixelRectPut(query, r) {
    NumPut("UInt", r.x1, "UInt", r.y1, "UInt", r.x2, "UInt", r.y2, query)
}

; The caller owns every Buffer. A rejected or interrupted call never
; contributes a partial observation. Do not catch TickInterrupted here.
PixelNativeCall(entry, shot, buf, query, where, out := 0, cap := 0, oldBuf := 0) {
    w := shot.w, h := shot.h, stride := shot.stride, size := buf.Size
    TickCheck(where)
    result := -1
    try {
        if oldBuf
            result := DllCall(entry, "Ptr", buf, "UPtr", size, "UInt", w, "UInt", h, "UPtr", stride
                , "Ptr", oldBuf, "UPtr", oldBuf.Size, "Ptr", query, "Ptr", out, "UPtr", cap, "Int")
        else if out
            result := DllCall(entry, "Ptr", buf, "UPtr", size, "UInt", w, "UInt", h, "UPtr", stride
                , "Ptr", query, "Ptr", out, "UPtr", cap, "Int")
        else
            result := DllCall(entry, "Ptr", buf, "UPtr", size, "UInt", w, "UInt", h, "UPtr", stride, "Ptr", query, "Int")
    } catch {
        ; Use the complete AHK scan, not the (possibly partial) native output.
    }
    TickCheck(where)
    return result
}

PixelNativeClusters(entry, shot, r, buf, modes, cell, step, minCells) {
    global CFG
    static names := ["chestGold", "chestRare", "gold", "cream", "green", "blue", "purple", "red", "white", "pure", "yellow"]
    if (!PixelFrameSupported(shot, buf) || !IsInteger(cell) || !IsInteger(step) || !IsInteger(minCells)
        || cell < 1 || cell > 8192 || step < 1 || step > 8192 || minCells < 1 || minCells > 0xFFFFFFFF)
        return 0
    flags := 0, masks := Map()
    for m in modes {
        mask := 0
        for i, name in names {
            if (name == m) {
                mask := 1 << (i - 1)
                break
            }
        }
        if !mask
            return 0
        flags |= mask, masks[m] := []
    }
    if !flags
        return 0
    yellow := [CFG.yRMin, CFG.yGMin, CFG.yBMax, CFG.yRGDelta]
    cream := [CFG.creamMin, CFG.creamBMin, CFG.creamBMax]
    if (!PixelI32(yellow) || !PixelI32(cream))
        return 0
    q := Buffer(60, 0)
    PixelRectPut(q, r)
    NumPut("UInt", cell, "UInt", step, "UInt", minCells, "UInt", flags, q, 16)
    for i, v in yellow
        NumPut("Int", v, q, 32 + (i - 1) * 4)
    for i, v in cream
        NumPut("Int", v, q, 48 + (i - 1) * 4)

    ; Max number of retained components is bounded by both the sample count
    ; and the number of usable cells. If it exceeds cap, retry wholly in AHK.
    nx := (r.x2 - r.x1 + step - 1) // step, ny := (r.y2 - r.y1 + step - 1) // step
    cap := Max(1, Min(4096, nx * ny // minCells))
    hits := Buffer(36 * cap, 0)
    n := PixelNativeCall(entry, shot, buf, q, "скан пикселей", hits, cap)
    if (n < 0 || n > cap)
        return 0
    Loop n {
        i := (A_Index - 1) * 36
        mode := names[NumGet(hits, i, "UInt") + 1]
        w := NumGet(hits, i + 12, "UInt"), h := NumGet(hits, i + 16, "UInt")
        count := NumGet(hits, i + 20, "UInt"), area := count * step * step
        masks[mode].Push({x:NumGet(hits, i + 4, "UInt"), y:NumGet(hits, i + 8, "UInt"), w:w, h:h
            , n:count, area:area, fill:area / Max(1, w * h), cx:NumGet(hits, i + 24, "UInt")
            , cy:NumGet(hits, i + 28, "UInt"), cells:NumGet(hits, i + 32, "UInt")})
    }
    TickCheck("скан пикселей")
    return masks
}

PixelNativeRows(entry, shot, r, buf, sx, sy, mode, where, yellow) {
    if (!PixelFrameSupported(shot, buf) || !PixelI32(yellow)
        || !IsInteger(sx) || !IsInteger(sy) || sx < 1 || sx > 8192 || sy < 1 || sy > 8192)
        return 0
    q := Buffer(44, 0)
    PixelRectPut(q, r)
    NumPut("UInt", sx, "UInt", sy, "UInt", mode, q, 16)
    for i, v in yellow
        NumPut("Int", v, q, 28 + (i - 1) * 4)

    count := (r.y2 - r.y1 + sy - 1) // sy
    ; No callbacks into AHK. Yield to the same watchdog between small bands,
    ; keeping the original sample origin even on an odd ROI/last row.
    cap := Min(32, count), out := Buffer(cap * 8, 0)
    rows := [], bestRun := 0, y := r.y1
    rows.Capacity := count
    while (y < r.y2) {
        y2 := Min(r.y2, y + cap * sy)
        NumPut("UInt", y, q, 4), NumPut("UInt", y2, q, 12)
        n := PixelNativeCall(entry, shot, buf, q, where, out, cap)
        if (n != (y2 - y + sy - 1) // sy)
            return 0
        Loop n {
            i := (A_Index - 1) * 8
            run := NumGet(out, i, "UInt"), cx := NumGet(out, i + 4, "UInt")
            rows.Push({y:y + (A_Index - 1) * sy, run:run, cx:cx})
            bestRun := Max(bestRun, run)
        }
        y := y2
    }
    TickCheck(where)
    return {rows:rows, bestRun:bestRun}
}

PixelNativeRatio(entry, shot, r, buf, mode, threshold) {
    if (!PixelFrameSupported(shot, buf) || !PixelI32([threshold]))
        return -1
    q := Buffer(24, 0)
    PixelRectPut(q, r)
    NumPut("UInt", mode, "Int", threshold, q, 16)
    cols := (r.x2 - r.x1 + 3) // 4, hits := 0, total := 0, y := r.y1
    while (y < r.y2) {
        y2 := Min(r.y2, y + 32 * 4)
        NumPut("UInt", y, q, 4), NumPut("UInt", y2, q, 12)
        n := PixelNativeCall(entry, shot, buf, q, "скан пикселей")
        band := cols * ((y2 - y + 3) // 4)
        if (n < 0 || n > band)
            return -1
        hits += n, total += band, y := y2
    }
    return total ? hits / total : 0.0
}

PixelNativeWarmGrid(entry, shot, buf, geo) {
    cap := geo.cw * geo.ch
    if (!PixelFrameSupported(shot, buf) || cap < 1 || cap > 131072)
        return 0
    q := Buffer(24, 0), out := Buffer(cap * 4, 0)
    NumPut("UInt", geo.x, "UInt", geo.y, "UInt", geo.x + geo.w, "UInt", geo.y + geo.h
        , "UInt", geo.cell, "UInt", geo.step, q)
    n := PixelNativeCall(entry, shot, buf, q, "скан фигуры врага", out, cap)
    if (n < 0 || n > 262144)
        return 0
    cnt := [], cnt.Capacity := cap
    Loop cap {
        if (Mod(A_Index, 512) = 0)
            TickCheck("чтение сетки фигуры")
        cnt.Push(NumGet(out, (A_Index - 1) * 4, "UInt"))
    }
    TickCheck("чтение сетки фигуры")
    return {cnt:cnt, totalSkin:n}
}

PixelNativeMotion(entry, shot, prev, r, step, cols) {
    ; Only the caller compares window/camera/epoch metadata. Neither buffer is copied.
    buf := shot.buf, oldBuf := prev.buf
    if (!PixelFrameSupported(shot, buf) || !PixelFrameSupported(prev, oldBuf)
        || shot.w != prev.w || shot.h != prev.h || shot.stride != prev.stride || step < 1)
        return 0
    cell := step * 2, cap := cols * ((r.y2 - r.y1 + cell - 1) // cell)
    if (cap < 1 || cap > 131072)
        return 0
    q := Buffer(20, 0), out := Buffer(20 * cap, 0)
    PixelRectPut(q, r), NumPut("UInt", step, q, 16)
    hits := PixelNativeCall(entry, shot, buf, q, "скан движения", out, cap, oldBuf)
    if (hits < 0 || hits > 262144)
        return 0
    cells := Map()
    if hits {
        Loop cap {
            if (Mod(A_Index, 512) = 0)
                TickCheck("чтение сетки движения")
            i := (A_Index - 1) * 20, n := NumGet(out, i + 16, "UInt")
            if n
                cells[A_Index - 1] := {x1:NumGet(out,i,"UInt"), y1:NumGet(out,i+4,"UInt")
                    , x2:NumGet(out,i+8,"UInt"), y2:NumGet(out,i+12,"UInt"), n:n}
        }
    }
    TickCheck("чтение сетки движения")
    return {cells:cells, hits:hits}
}
