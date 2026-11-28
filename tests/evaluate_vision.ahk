#Requires AutoHotkey v2.0
#NoTrayIcon
#Include ../tools/evaluate_vision.ahk

folder := A_Temp "\forma-vision-set-" ProcessExist() "-" A_TickCount
code := 0
try {
    DirCreate(folder)
    VisionCheck(!UI.gui && !UI.hkKeys.Length && !ST.running && CFG.dryRun, "offline include did not start FORMA")
    TestVisionOverlap()
    TestVisionSetFormat(folder)
    FileAppend("OK: box scoring, TSV schema and limits`n", "*", "UTF-8-RAW")
    TestVisionBatch(folder)
    FileAppend("OK: fast/wide replay, motion pairs, partial errors, isolation · " PixelCombatBackendName() "`n", "*", "UTF-8-RAW")
} catch as e {
    FileAppend("FAIL: " e.Message " (line " e.Line ")`n" e.Stack "`n", "**", "UTF-8-RAW")
    code := 1
} finally {
    try DirDelete(folder, true)
}
ExitApp(code)

VisionCheck(ok, label) {
    if !ok
        throw Error(label, -1)
}

TestVisionOverlap() {
    totals := {n:0, tp:0, fp:0, fn:0, tn:0}
    a := {x:0, y:0, w:10, h:10}
    exactlyHalf := {x:0, y:0, w:5, h:10}
    overlap := {x:5, y:0, w:10, h:10}
    adjacent := {x:10, y:0, w:10, h:10}
    got := GradeVisionBox(a, exactlyHalf, totals)
    VisionCheck(got.kind = "match" && got.iou = 0.5, "IoU exactly 0.50 matches")
    got := GradeVisionBox(a, overlap, totals)
    VisionCheck(got.kind = "wrong-box" && Abs(got.iou - 1/3) < 0.0001, "IoU uses union, not expected area")
    VisionCheck(GradeVisionBox(a, adjacent, totals).iou = 0, "half-open boxes do not overlap at the edge")
    VisionCheck(totals.n = 3 && totals.tp = 1 && totals.fp = 2 && totals.fn = 2 && !totals.tn
        && VisionRate(0, 0) = "n/a", "one wrong box is both a false box and a missed expected box")
}

WriteVisionSet(path, rows) {
    f := FileOpen(path, "w", "UTF-8")
    try {
        f.Write("id`tcurrent`tprevious`texpected`r`n")
        for line in rows
            f.Write(line "`r`n")
    } finally f.Close()
}

ExpectInvalidVisionSet(path, label) {
    try ReadVisionSet(path)
    catch ValueError
        return
    throw Error("Accepted invalid set: " label, -1)
}

TestVisionSetFormat(folder) {
    path := folder "\validation.tsv"
    WriteVisionSet(path, ["warm_1`tтёплая фигура.BMP`t-`t0,2,31,44", "blank`tblank.bmp`t-`tnone"])
    batch := ReadVisionSet(path)
    VisionCheck(batch.dir = folder && batch.rows.Length = 2 && batch.rows[1].box.x = 0
        && batch.rows[1].box.h = 44 && batch.rows[1].current = "тёплая фигура.BMP" && !batch.rows[2].box
        , "UTF-8 BOM, CRLF, relative filenames and origin are accepted")
    for bad in [["blank`tblank.bmp`t-`tnone", "Blank`ta.bmp`t-`tnone"], ["too-few`tframe.bmp`t-"]
        , ["outside`t..\frame.bmp`t-`tnone"], ["ads`tframe.bmp:private.bmp`t-`tnone"]
        , ["device`tNUL.bmp`t-`tnone"], ["bad-type`tframe.png`t-`tnone"]
        , ["bad-prev`tframe.bmp`tC:\frame.bmp`tnone"], ["bad-box`tframe.bmp`t-`t0,1,-4,10"], []] {
        WriteVisionSet(path, bad)
        ExpectInvalidVisionSet(path, "schema or path")
    }
    many := []
    Loop 65
        many.Push("row" A_Index "`tframe.bmp`t-`tnone")
    WriteVisionSet(path, many)
    ExpectInvalidVisionSet(path, "65 rows")
    f := FileOpen(path, "w", "UTF-8-RAW")
    try f.RawWrite(Buffer(65537, 32))
    finally f.Close()
    ExpectInvalidVisionSet(path, "byte limit")
    VisionCheck(EvaluateVision([path], folder "\unused.txt", folder "\syntax-error.txt") = 2
        && !FileExist(folder "\unused.txt"), "bad manifest is rejected before scoring")
}

TestVisionBatch(folder) {
    global ST, UI, CFG
    warm := folder "\тёплая фигура.bmp"
    WriteVisionFixture(warm, "figure")
    WriteVisionFixture(folder "\local.bmp", "motion")
    WriteVisionFixture(folder "\blank.bmp", "blank")
    WriteVisionFixture(folder "\broad.bmp", "broad")
    WriteVisionFixture(folder "\smaller.bmp", "blank", 480, 288)
    FileAppend("not a BMP", folder "\broken.bmp", "UTF-8-RAW")
    path := folder "\сцены.tsv", errors := folder "\errors.txt"
    rows := ["standing`tтёплая фигура.bmp`t-`t720,230,40,94"
        , "local`tlocal.bmp`tblank.bmp`t704,281,28,52"
        , "cold_still`tlocal.bmp`t-`t704,281,28,52"
        , "blank`tblank.bmp`t-`tnone"
        , "broad_change`tbroad.bmp`tblank.bmp`tnone"
        , "false_mark`tтёплая фигура.bmp`t-`tnone"
        , "wrong_location`tтёплая фигура.bmp`t-`t500,250,30,80"]
    WriteVisionSet(path, rows)
    original := FileRead(warm, "RAW"), manifest := FileRead(path, "UTF-8"), before := ST.Clone()
    for passName in ["fast", "wide"] {
        report := folder "\" passName ".txt", args := passName = "wide" ? [path, "--wide"] : [path]
        VisionCheck(EvaluateVision(args, report, errors) = 0 && !FileExist(errors), "correct input completes even with misses")
        text := FileRead(report, "UTF-8")
        for fragment in ["pass=" passName, PixelCombatBackendName(), "CASE standing 1280x720 pair=no result=match"
            , "CASE local 1280x720 pair=yes result=match expected=704,281,28,52 found=704,284,28,49 iou=0.942 channel=motion"
            , "CASE cold_still 1280x720 pair=no result=miss", "CASE broad_change 1280x720 pair=yes result=negative"
            , "CASE false_mark 1280x720 pair=no result=false", "CASE wrong_location 1280x720 pair=no result=wrong-box"
            , "TOTAL n=7 pairs=2 tp=2 fp=2 fn=2 tn=2 errors=0 precision=0.500 recall=0.500"] {
            VisionCheck(InStr(text, fragment), "missing " fragment " in " passName ":`n" text)
        }
        VisionCheck(!InStr(text, folder) && !InStr(text, "тёплая фигура.bmp"), "report needs geometry and id, not file names")
    }
    same := FileRead(warm, "RAW")
    VisionCheck(same.Size = original.Size && !DllCall("msvcrt\memcmp", "Ptr", same, "Ptr", original, "UPtr", same.Size, "CDecl Int")
        && FileRead(path, "UTF-8") == manifest, "replay does not write to BMP or TSV")

    WriteVisionSet(path, ["missing`tmissing.bmp`t-`tnone", "corrupt`tbroken.bmp`t-`tnone"
        , "mismatch`tlocal.bmp`tsmaller.bmp`tnone", "out_of_frame`tblank.bmp`t-`t1279,719,2,2", rows[4]])
    report := folder "\partial.txt"
    VisionCheck(EvaluateVision([path], report, errors) = 1, "incomplete corpus reported as an error")
    err := FileRead(errors, "UTF-8")
    for id in ["missing", "corrupt", "mismatch", "out_of_frame"]
        VisionCheck(InStr(err, "CASE " id " "), "bad row reported: " id)
    VisionCheck(!InStr(err, folder) && InStr(FileRead(report, "UTF-8")
        , "TOTAL n=1 pairs=0 tp=0 fp=0 fn=0 tn=1 errors=4 precision=n/a recall=n/a"), "invalid rows are never counted as negatives")
    for key, value in before.OwnProps()
        VisionCheck(ST.%key% = value, "no publication of live state: " key)
    VisionCheck(!ST.captureSeq && !ST.running && !ST.held.Count && !UI.gui && !UI.hkKeys.Length && CFG.dryRun
        , "no capture, input or hotkeys")
}

WriteVisionFixture(path, kind, w := 1280, h := 720) {
    shot := {w:w, h:h, stride:w*4, buf:Buffer(w*h*4, kind = "broad" ? 0xDE : 0x60)}
    if (kind = "figure") {
        ; Staggered widths differentiate a warm shape from a solid column.
        for b in [[-7,0,14,36], [-20,35,40,21], [-12,56,24,14], [-14,70,10,24], [4,70,10,24]]
            FillVisionRect(shot, 740+b[1], 230+b[2], b[3], b[4], 0xAAD08048)
    } else if (kind = "motion")
        FillVisionRect(shot, 704, 281, 28, 52, 0xA2DEDEDE)
    WriteCalibrationBmp(shot, path)
}

FillVisionRect(shot, x, y, w, h, color) {
    Loop h {
        off := (y + A_Index - 1) * shot.stride + x * 4
        Loop w
            NumPut("UInt", color, shot.buf, off + (A_Index - 1) * 4)
    }
}
