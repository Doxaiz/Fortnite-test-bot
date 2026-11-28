#Requires AutoHotkey v2.0
#NoTrayIcon
#Include %A_LineFile%\..\replay_f5.ahk

; Размеченные локальные BMP. Ни Init, ни захвата, ни игрового ввода.
if (A_LineFile = A_ScriptFullPath)
    ExitApp(EvaluateVision(A_Args))

EvaluateVision(args, stdout := "*", stderr := "**") {
    global FORMA_VERSION
    if !(args.Length = 1 || (args.Length = 2 && args[2] = "--wide")) {
        FileAppend("Использование: evaluate_vision.ahk набор.tsv [--wide]`n", stderr, "UTF-8-RAW")
        return 2
    }
    try batch := ReadVisionSet(args[1])
    catch as e {
        FileAppend("Набор TSV: " e.Message "`n", stderr, "UTF-8-RAW")
        return 2
    }
    wide := args.Length = 2
    FileAppend("FORMA v" FORMA_VERSION " · офлайн, настройки по умолчанию · " PixelCombatBackendName()
        . " · pass=" (wide ? "wide" : "fast") " · IoU>=0.50 · без проверки допуска действий`n", stdout, "UTF-8-RAW")
    totals := {n:0, pairs:0, tp:0, fp:0, fn:0, tn:0, errors:0}
    for row in batch.rows {
        try result := ReadVisionCase(batch.dir, row, wide)
        catch as e {
            totals.errors += 1
            FileAppend("CASE " row.id " (строка " row.line "): " e.Message "`n", stderr, "UTF-8-RAW")
            continue
        }
        totals.pairs += result.pair
        grade := GradeVisionBox(row.box, result.box, totals)
        msg := "CASE " row.id " " result.w "x" result.h " pair=" (result.pair ? "yes" : "no")
            . " result=" grade.kind " expected=" VisionBoxText(row.box) " found=" VisionBoxText(result.box)
            . " iou=" (row.box ? Format("{:.3f}", grade.iou) : "-") " channel=" result.channel
            . (result.reject != "" ? " · статическая фигура: " result.reject : "")
        FileAppend(msg "`n", stdout, "UTF-8-RAW")
    }
    FileAppend("TOTAL n=" totals.n " pairs=" totals.pairs " tp=" totals.tp " fp=" totals.fp " fn=" totals.fn
        . " tn=" totals.tn " errors=" totals.errors " precision=" VisionRate(totals.tp, totals.tp + totals.fp)
        . " recall=" VisionRate(totals.tp, totals.tp + totals.fn) "`n", stdout, "UTF-8-RAW")
    return totals.errors ? 1 : 0
}

ReadVisionSet(path) {
    if !RegExMatch(path, "i)\.tsv\z")
        throw ValueError("ожидался файл .tsv")
    try file := FileOpen(path, "r", "UTF-8")
    catch OSError
        throw ValueError("не удалось открыть файл")
    try {
        bytes := file.Length
        if (bytes < 1 || bytes > 65536)
            throw ValueError("размер файла должен быть 1..65536 байт")
        text := file.Read(bytes)
        if (file.Length != bytes || !file.AtEOF)
            throw ValueError("файл изменился при чтении")
    } finally file.Close()

    lines := StrSplit(text, "`n", "`r"), rows := [], ids := Map()
    ids.CaseSense := "Off"
    if !(lines[1] == "id`tcurrent`tprevious`texpected")
        throw ValueError("заголовок: id, current, previous, expected через табуляцию")
    for i, line in lines {
        if (i = 1 || line = "")
            continue
        if (rows.Length >= 64)
            throw ValueError("в наборе допускается не более 64 строк данных")
        fields := StrSplit(line, "`t")
        if (fields.Length != 4 || !RegExMatch(fields[1], "^[A-Za-z0-9_-]{1,40}\z") || ids.Has(fields[1]))
            throw ValueError("строка " i ": нужны четыре поля и уникальный id (A-Z, 0-9, _ или -)")
        id := fields[1], current := fields[2], previous := fields[3], mark := fields[4]
        if (!VisionBmpName(current) || (previous != "-" && !VisionBmpName(previous)))
            throw ValueError("строка " i ": нужны имена BMP без каталогов; для одиночного кадра previous = -")
        box := 0
        if (mark != "none") {
            if !RegExMatch(mark, "^([0-9]{1,4}),([0-9]{1,4}),([0-9]{1,4}),([0-9]{1,4})\z", &m)
                throw ValueError("строка " i ": expected — none или x,y,w,h")
            box := {x:Integer(m[1]), y:Integer(m[2]), w:Integer(m[3]), h:Integer(m[4])}
        }
        ids[id] := true
        rows.Push({id:id, line:i, current:current, previous:previous, box:box})
    }
    if !rows.Length
        throw ValueError("нет размеченных строк")
    SplitPath(path, , &dir)
    return {dir:(dir = "" ? "." : dir), rows:rows}
}

VisionBmpName(name) {
    return StrLen(name) <= 160 && name == Trim(name) && RegExMatch(name, "i)^.+\.bmp\z")
        && !RegExMatch(name, '[\\/:*?"<>|\x00-\x1F]')
        && !RegExMatch(name, "i)^(?:CON|PRN|AUX|NUL|CONIN\$|CONOUT\$|COM[1-9¹²³]|LPT[1-9¹²³]) *\.")
}

ReadVisionCase(dir, row, wide) {
    global CFG
    try shot := ReadF5Bmp(dir "\" row.current)
    catch OSError
        throw ValueError("не удалось прочитать current BMP")
    want := row.box
    if (want && (!want.w || !want.h || want.x + want.w > shot.w || want.y + want.h > shot.h))
        throw ValueError("ожидаемая рамка не помещается в current BMP")
    prev := 0
    if (row.previous != "-") {
        try prev := ReadF5Bmp(dir "\" row.previous)
        catch OSError
            throw ValueError("не удалось прочитать previous BMP")
        if (prev.w != shot.w || prev.h != shot.h || prev.stride != shot.stride)
            throw ValueError("размеры current и previous BMP должны совпадать")
    }
    diagnostic := {}
    ; Та же последовательность, что в FindEnemyMulti. Не подделываем HWND,
    ; A_TickCount или ST.prevShot: сравнение файлов не является свежим кадром.
    box := ReadStaticFigure(shot, wide ? 0.92 : CFG.enemyFastFrac, wide ? CFG.skinStepWide : 0, diagnostic)
    if (!box && prev && CFG.featMotionEnemy)
        box := ReadEnemyMotionPair(shot, prev)
    channel := box ? (box.src = "движение" ? "motion" : (box.HasOwnProp("isolated") ? "isolated" : "figure")) : "-"
    return {box:box, channel:channel, pair:!!prev, w:shot.w, h:shot.h, reject:diagnostic.figureReject}
}

GradeVisionBox(want, found, totals) {
    totals.n += 1, iou := 0
    if (want && found) {
        iw := Max(0, Min(want.x + want.w, found.x + found.w) - Max(want.x, found.x))
        ih := Max(0, Min(want.y + want.h, found.y + found.h) - Max(want.y, found.y))
        common := iw * ih
        iou := common / (want.w * want.h + found.w * found.h - common)
        if (iou >= 0.5) {
            totals.tp += 1
            return {kind:"match", iou:iou}
        }
    }
    if want
        totals.fn += 1
    if found
        totals.fp += 1
    if (!want && !found)
        totals.tn += 1
    return {kind:(want ? (found ? "wrong-box" : "miss") : (found ? "false" : "negative")), iou:iou}
}

VisionBoxText(box) {
    return box ? box.x "," box.y "," box.w "," box.h : "none"
}

VisionRate(n, denom) {
    return denom ? Format("{:.3f}", n / denom) : "n/a"
}
