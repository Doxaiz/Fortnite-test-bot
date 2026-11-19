#Requires AutoHotkey v2.0
#Include ../fortnite_bot.ahk

; The EXE loads code from a resource, so A_LineFile is not the EXE path.
; Keep the normal #Include behavior for diagnostics and use an explicit EXE entry.
if A_IsCompiled
    Init()
else
    throw Error("Compile this entry with tools/build-portable.ps1 or run fortnite_bot.ahk.")
