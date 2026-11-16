$ErrorActionPreference = 'Stop'
$base = Split-Path -Parent $PSScriptRoot
$train = Join-Path $PSScriptRoot 'train.py'
$source = Join-Path $base 'forma_model\runtime-v1\python'
$models = Join-Path $base 'forma_model'
$dest = Join-Path $models 'training-python-v1'
$bootstrap = Join-Path $PSScriptRoot 'get-pip.py'
$weights = Join-Path $PSScriptRoot 'yolov8n.pt'
$wheels = Join-Path $PSScriptRoot 'wheels'
$manifest = Join-Path $PSScriptRoot 'forma-locked-wheels.sha256'
$manifestSha = 'c63c76f0599ba8104f9204d17660f2c5f7a499913474847d02769d399797a71c'
$pipSha = '9655943313a94722b7774661c21049070f6bbb0a1516bf02f7c8d5d9201514cd'
$stage = $null
$lock = $null
$locked = $false
try {
    [Console]::OutputEncoding = [Text.UTF8Encoding]::new()
    $env:PYTHONUTF8='1'
    $env:PIP_DISABLE_PIP_VERSION_CHECK='1'
    $env:PIP_NO_INPUT='1'
    Write-Host 'FORMA — обучение отдельной нейросети по фото' -ForegroundColor Cyan
    Write-Host 'Результат не подключается к игре автоматически. Сначала остановите бота и игру.'
    if (!(Test-Path -LiteralPath (Join-Path $source 'python.exe'))) { throw 'Сначала нажмите «Установить модель» в FORMA и дождитесь окончания установки.' }
    if (!(Test-Path -LiteralPath $train) -or !(Test-Path -LiteralPath $bootstrap) -or !(Test-Path -LiteralPath $weights)) { throw 'Нет train.py, get-pip.py или yolov8n.pt. Сохраните их из прежнего полного комплекта.' }
    if ((Get-FileHash -LiteralPath $bootstrap -Algorithm SHA256).Hash -ne '356e0d0de21cdc348c3394084d90939b85e4246c4d14c76aee6ca4f46646ea98') { throw 'Не совпадает хэш get-pip.py.' }
    if ((Get-FileHash -LiteralPath $weights -Algorithm SHA256).Hash -ne 'f59b3d833e2ff32e194b5bb8e08d211dc7c5bdf144b90d2c8412c47ccfc83b36') { throw 'Не совпадает хэш исходных весов yolov8n.pt.' }
    New-Item -ItemType Directory -Path (Join-Path $base 'фото_для_модели') -Force | Out-Null
    & (Join-Path $source 'python.exe') $train --base $base --check
    if ($LASTEXITCODE -ne 0) { throw 'Проверка датасета не пройдена. Загрузка не запускалась.' }
    $hash = [Security.Cryptography.SHA256]::Create()
    try { $key = [BitConverter]::ToString($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes($base.ToUpperInvariant()))).Replace('-','').Substring(0,24) } finally { $hash.Dispose() }
    $lock = [Threading.Mutex]::new($false, ('Local\FORMA_PhotoTraining_' + $key))
    try { $locked = $lock.WaitOne(0) } catch [Threading.AbandonedMutexException] { $locked = $true }
    if (!$locked) { throw 'Обучение в этой папке уже запущено.' }
    if (!(Test-Path -LiteralPath $dest)) {
        Write-Host ''
        Write-Host 'Нужно отдельно установить PyTorch CPU, Ultralytics и ONNX в forma_model.'
        Write-Host 'Нужны пакеты wheels из прежнего полного комплекта и несколько ГБ на диске плюс место для копии датасета.'
        Write-Host 'Установка библиотек выполняется локально, без их загрузки из интернета.'
        Write-Host 'Снимки не отправляются для обучения в облако. Ултралайтикс: лицензия AGPL-3.0.'
        $answer = Read-Host 'Установить компоненты и начать? Введите ДА (или YES)'
        if ($answer -notin @('ДА','да','YES','yes')) { Write-Host 'Отменено.'; return }
        if (!(Test-Path -LiteralPath $manifest)) { throw 'Нет forma-locked-wheels.sha256 из обновления. Скопируйте этот файл рядом со start.ps1.' }
        # Читаем ограниченный снимок списка один раз. Проверяются и разбираются
        # одни и те же байты; на Windows открытие запрещает параллельную запись.
        $manifestStream = [IO.File]::Open($manifest, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        try {
            if ($manifestStream.Length -ne 4217) { throw 'Неверный хэш контрольного списка библиотек: размер не совпадает.' }
            $manifestBytes = New-Object byte[] 4217; $pos = 0
            while ($pos -lt $manifestBytes.Length) {
                $read = $manifestStream.Read($manifestBytes, $pos, $manifestBytes.Length - $pos)
                if ($read -eq 0) { throw 'Не удалось полностью прочитать контрольный список.' }
                $pos += $read
            }
        } finally { $manifestStream.Dispose() }
        $digest = [Security.Cryptography.SHA256]::Create()
        try { $actualManifestSha = [BitConverter]::ToString($digest.ComputeHash($manifestBytes)).Replace('-','') } finally { $digest.Dispose() }
        if ($actualManifestSha -ne $manifestSha) { throw 'Неверный хэш контрольного списка библиотек. Установку продолжать нельзя.' }
        Write-Host 'Проверяю зафиксированный список и хэши пакетов...'
        $lines = @(([Text.Encoding]::ASCII.GetString($manifestBytes) -split '\r?\n') | Where-Object { $_ -ne '' })
        if ($lines.Count -ne 41) { throw 'Контрольный список библиотек неполный.' }
        $requirements = [System.Collections.Generic.List[string]]::new()
        $seen = @{}
        foreach ($line in $lines) {
            if ($line -notmatch '^([0-9a-f]{64})  ([A-Za-z0-9_.+\-]+\.whl)$') { throw 'Некорректный контрольный список SHA256.' }
            $expected = $Matches[1]; $name = $Matches[2]
            if ($name -notmatch '^([A-Za-z0-9_.]+)-([A-Za-z0-9_.+!]+)-[A-Za-z0-9_.]+-[A-Za-z0-9_.]+-[A-Za-z0-9_.]+\.whl$') { throw ('Не удалось разобрать имя пакета: ' + $name) }
            $package = $Matches[1]; $version = $Matches[2]
            $keyName = ($package -replace '[-_.]+','-').ToLowerInvariant()
            if ($seen.ContainsKey($keyName)) { throw ('Дубликат пакета в контрольном списке: ' + $package) }
            $seen[$keyName] = $true
            $file = Join-Path $wheels $name
            if (!(Test-Path -LiteralPath $file -PathType Leaf) -or (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash -ne $expected) { throw ('Нет пакета или не совпадает хэш: ' + $file) }
            $requirements.Add($package + '==' + $version + ' --hash=sha256:' + $expected)
        }
        $stage = Join-Path $models ('training-stage-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $stage | Out-Null
        Copy-Item -Path (Join-Path $source '*') -Destination $stage -Recurse -Force
        $site=Join-Path $stage 'site-packages'
        if (Test-Path -LiteralPath $site) { Remove-Item -LiteralPath $site -Recurse -Force }
        New-Item -ItemType Directory -Path $site | Out-Null
        [IO.File]::WriteAllText((Join-Path $stage 'python312._pth'), "python312.zip`r`n.`r`nsite-packages`r`nimport site`r`n", [Text.Encoding]::ASCII)
        $py=Join-Path $stage 'python.exe'
        $lockedRequirements = Join-Path $stage 'forma-locked-requirements.txt'
        [IO.File]::WriteAllLines($lockedRequirements, $requirements.ToArray(), [Text.Encoding]::ASCII)
        # get-pip добавляет неприкреплённое требование pip, поэтому режим
        # --require-hashes для его bootstrap неприменим. Вместо каталога wheels
        # передаём только отдельную проверенную копию конкретного pip wheel.
        $bootstrapCopy = Join-Path $stage 'forma-get-pip.py'
        $pipCopy = Join-Path $stage 'pip-25.3-py3-none-any.whl'
        Copy-Item -LiteralPath $bootstrap -Destination $bootstrapCopy
        Copy-Item -LiteralPath (Join-Path $wheels 'pip-25.3-py3-none-any.whl') -Destination $pipCopy
        if ((Get-FileHash -LiteralPath $bootstrapCopy -Algorithm SHA256).Hash -ne '356e0d0de21cdc348c3394084d90939b85e4246c4d14c76aee6ca4f46646ea98' -or (Get-FileHash -LiteralPath $pipCopy -Algorithm SHA256).Hash -ne $pipSha) { throw 'Не совпадает хэш копии установщика pip.' }
        Write-Host 'Подготовка pip из проверенной копии...'
        & $py $bootstrapCopy --isolated --no-index --no-cache-dir --no-deps --no-warn-script-location $pipCopy
        if ($LASTEXITCODE -ne 0) { throw 'Не удалось установить pip.' }
        Write-Host 'Установка зафиксированных зависимостей с обязательной проверкой хэшей...'
        & $py -m pip --isolated install --no-index --no-cache-dir --only-binary=:all: --require-hashes --no-warn-script-location --find-links $wheels -r $lockedRequirements
        if ($LASTEXITCODE -ne 0) { throw 'Установка остановлена: пакет отсутствует, изменён или зависимости несовместимы.' }
        Remove-Item -LiteralPath $bootstrapCopy,$pipCopy,$lockedRequirements -Force
        # Запускаем файл, а не Python-код через -c: Windows PowerShell 5.1
        # может потерять вложенные кавычки при передаче строк процессу.
        $checkFile = Join-Path $stage 'verify_training.py'
        [IO.File]::WriteAllText($checkFile, "import torch, cv2, onnx, ultralytics`nprint(torch.__version__, ultralytics.__version__)`n", [Text.Encoding]::ASCII)
        & $py $checkFile
        if ($LASTEXITCODE -ne 0) { throw 'Проверка установленной среды не прошла.' }
        Remove-Item -LiteralPath $checkFile -Force
        [IO.File]::WriteAllText((Join-Path $stage 'ready.txt'), 'FORMA-TRAINING-V1', [Text.Encoding]::ASCII)
        [IO.Directory]::Move($stage,$dest)
        $stage=$null
    } else {
        if (!(Test-Path -LiteralPath (Join-Path $dest 'ready.txt'))) { throw 'Папка training-python-v1 неполная. Автоматически не перезаписываю её.' }
        $answer = Read-Host 'Начать обучение на CPU? Оно может идти много часов. Введите ДА (или YES)'
        if ($answer -notin @('ДА','да','YES','yes')) { Write-Host 'Отменено.'; return }
    }
    $env:OMP_NUM_THREADS='2'
    $env:OPENBLAS_NUM_THREADS='2'
    & (Join-Path $dest 'python.exe') $train --base $base
    if ($LASTEXITCODE -ne 0) { throw 'Обучение прервано или завершилось с ошибкой; см. сообщения выше.' }
} catch {
    Write-Host ("ОШИБКА: " + $_.Exception.Message) -ForegroundColor Red
} finally {
    if ($stage -and (Test-Path -LiteralPath $stage)) { Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue }
    if ($locked) { $lock.ReleaseMutex() }
    if ($lock) { $lock.Dispose() }
    Write-Host ''
    [void](Read-Host 'Нажмите Enter, чтобы закрыть окно')
}
