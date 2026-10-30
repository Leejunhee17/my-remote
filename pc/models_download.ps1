<#
[접근 PC] Hugging Face 사전학습 모델을 받는다. 목록은 lists\models.txt, 설명은 docs\7_모델.md.
점검 → 받기(끊기면 이어받기) → 크기·sha256 검사 → B200 서버에 올릴 목록 만들기까지 한 번에 한다.
끊기거나 실패하면 같은 명령을 다시 실행한다. 받은 것은 건너뛴다.

  powershell -ExecutionPolicy Bypass -File .\pc\models_download.ps1                    # models.txt 에서 # 없는 줄 전부
  powershell -ExecutionPolicy Bypass -File .\pc\models_download.ps1 -Only seg,vlm      # 그룹만
#>
param(
    [string]$Dest = (Join-Path (Split-Path $PSScriptRoot -Parent) 'models'),
    [string[]]$Only = @(),            # 이 그룹만 받는다(쉼표로 여러 개)
    [int]$MaxTries = 30               # 받은 양이 늘지 않은 채 연속으로 끊긴 횟수가 이만큼이면 그 모델은 포기(약 2시간)
)
$here = $PSScriptRoot
$root = Split-Path $PSScriptRoot -Parent   # 저장소 맨 위(D:\b200). 결과 폴더와 uv.exe 는 여기
. (Join-Path $here 'b200_common.ps1')
$Only  = @($Only | ForEach-Object { $_ -split ',' } | Where-Object { $_ })
$fetch = Join-Path $here 'hf_fetch.py'
$T = 4

# lists\models.txt : "그룹  저장소  [gated]  [code=GitHub 주소]" 한 줄에 하나. # 뒤는 무시
$listLines = Get-Content -Encoding UTF8 (Join-Path $root 'lists\models.txt')
$AllModels = @($listLines | ForEach-Object {
    $l = ($_ -replace '#.*', '').Trim()
    if ($l) {
        $f = $l -split '\s+'
        $cz = @($f | Where-Object { $_ -like 'code=*' }) -replace '^code=', ''
        [pscustomobject]@{ Group = $f[0]; Repo = $f[1]; Gated = ($f -contains 'gated'); Code = "$cz".TrimEnd('/') }
    }
})
$Models = @($AllModels | Where-Object { -not $Only.Count -or $Only -contains $_.Group })
# 앞에 # 을 붙여 둔 선택 모델까지 포함한, 목록에 적힌 모든 저장소 이름
$Listed = @($listLines | ForEach-Object { if ($_ -match '^\s*#?\s*[a-z]+\s+([\w.-]+/[\w.-]+)') { $Matches[1] } })

New-Item -ItemType Directory -Force $Dest | Out-Null
$Dest = (Resolve-Path $Dest).Path.TrimEnd('\')
Start-Log (Join-Path $Dest 'download.log')
Stop-Sleep
Write-Host "[접근 PC] Hugging Face 사전학습 모델 받기  ($(Get-Date -Format 'yyyy-MM-dd HH:mm'))"
Write-Host "받는 곳: $Dest"

function Invoke-Fetch($cmd, $repo, $dir) {
    $env:PYTHONIOENCODING = 'utf-8'
    & $uv run --no-project --python 3.12 --with huggingface_hub --with hf_xet --with truststore $fetch $cmd $repo $dir
}
function Get-Dir($repo) { return Join-Path $Dest ($repo -replace '/', '__') }
function Test-Zip($p) {
    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $z = [IO.Compression.ZipFile]::OpenRead($p); $n = $z.Entries.Count; $z.Dispose(); return $n -gt 0
    } catch { return $false }
}

# ------------------------------------------------------------------ 1. 점검
Write-Step 1 $T '점검'
$uv = Find-Exe 'uv' $root
if ($uv) { Write-Ok "uv : $uv" } else { Stop-Run 'uv가 없어요' "uv를 설치하고 PowerShell 창을 새로 여세요. 또는 uv.exe를 $root 폴더에 넣으세요." }
if (-not (Test-Path $fetch)) { Stop-Run '없는 파일: pc\hf_fetch.py' 'git pull로 저장소를 최신으로 받으세요.' }
if (-not (Test-Path (Join-Path $root 'server\models_install.sh'))) { Stop-Run '없는 파일: server\models_install.sh' 'git pull로 저장소를 최신으로 받으세요.' }
if (-not $Models.Count) {
    Stop-Run '받을 모델이 없어요' ("lists\models.txt 와 -Only 뒤에 적은 그룹 이름을 확인하세요. 있는 그룹: " +
        (@($AllModels | ForEach-Object { $_.Group } | Select-Object -Unique) -join ', '))
}
Write-Ok "받을 모델 $($Models.Count)개 ($(@($Models | ForEach-Object { $_.Group } | Select-Object -Unique) -join ', '))"

Test-Site 'Hugging Face' 'https://huggingface.co/' | Out-Null
Test-Site 'PyPI (받기 도구)' 'https://pypi.org/simple/pip/' | Out-Null
if (@($Models | Where-Object { $_.Code }).Count) { Test-Site 'GitHub (모델 코드)' 'https://github.com/' | Out-Null }
if ($script:Fails) {
    Stop-Run '접속되지 않는 사이트가 있어요' ('위 [문제] 줄 아래의 curl 오류와 설명을 보세요. 브라우저에서는 열린다면 ' +
        '사내 IT에 프록시 주소를 물어 $env:HTTPS_PROXY = "http://프록시주소:포트" 를 입력하고 다시 실행하세요.')
}
# 큰 파일은 이 주소들에서 내려온다. 막혀 있으면 받다가 실패한다
foreach ($h in 'https://cas-bridge.xethub.hf.co/', 'https://cdn-lfs.hf.co/') {
    $r = Invoke-Probe $h
    if ($r.Code -eq 0) { Write-Ok "인터넷: $h" } else { Write-Warn "인터넷: $h 접속 안 됨(curl $($r.Code)). 큰 가중치 파일을 받지 못할 수 있어요." }
}

Write-Info '받기 도구(huggingface_hub)를 준비하는 중이에요(처음 한 번만)'
& $uv python install 3.12 | Out-Host
if ($LASTEXITCODE -ne 0) { Stop-Run 'uv가 Python 3.12를 받지 못했어요' '인터넷(github.com) 접속을 확인하고 다시 실행하세요.' }

# 승인이 필요한 모델(gated)이 있으면 토큰을 받는다
$gated = @($Models | Where-Object { $_.Gated -and -not (Test-Path (Join-Path (Get-Dir $_.Repo) 'b200_model.json')) })
if ($gated.Count -and -not $env:HF_TOKEN) {
    Write-Host ''
    Write-Host "  승인이 필요한 모델이 $($gated.Count)개 있어요. 아래 모델 페이지에 로그인해 약관에 동의하세요:" -ForegroundColor Cyan
    $pages = @($gated | ForEach-Object { "https://huggingface.co/$($_.Repo)" }) + 'https://huggingface.co/settings/tokens'
    $gated | ForEach-Object { Write-Host "    https://huggingface.co/$($_.Repo)" }
    Write-Host '  토큰 만들기(Read 권한): https://huggingface.co/settings/tokens'
    $open = Read-Host '  위 페이지를 브라우저로 열까요? [Y/n]'
    if ($open -notmatch '^[nN]') { $pages | ForEach-Object { Start-Process $_ } }
    Write-Host '  약관에 동의한 계정의 토큰을 붙여 넣으세요.'
    Write-Host '  비워 두고 Enter를 누르면 이 모델들은 건너뛰어요. 토큰은 화면과 기록 파일에 남지 않아요.'
    $s = Read-Host '  HF 토큰' -AsSecureString
    $b = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($s)
    try { $tok = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($b) } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b) }
    if ($tok.Trim()) { $env:HF_TOKEN = $tok.Trim() }
}

Write-Info '받을 크기를 계산하는 중이에요'
$need = [int64]0
foreach ($m in $Models) {
    if ($m.Gated -and -not $env:HF_TOKEN) { continue }
    if (Test-Path (Join-Path (Get-Dir $m.Repo) 'b200_model.json')) { continue }
    $out = @(Invoke-Fetch plan $m.Repo (Get-Dir $m.Repo))
    if ($LASTEXITCODE -eq 0) { $need += [int64]($out[-1]) }
    else { Write-Warn "$($m.Repo): $($out -join ' ')" }
}
$needGB = [math]::Ceiling($need / 1GB)
$free = Get-FreeGB $Dest
if ($free -lt $needGB + 5) {
    Stop-Run "남은 공간이 $free GB예요(앞으로 약 $needGB GB가 필요해요)" '공간을 비우거나, -Dest E:\models 처럼 넉넉한 드라이브로 받는 곳을 바꾸거나, -Only로 그룹을 나눠 받으세요.'
}
Write-Ok "남은 공간 $free GB, 앞으로 받을 양 약 $needGB GB"

# ------------------------------------------------------------------ 2. 받기
Write-Step 2 $T '받기 (끊기면 이어받고, 파일마다 sha256을 검사해요)'
$result = [ordered]@{}
$n = 0
foreach ($m in $Models) {
    $n++
    $dir = Get-Dir $m.Repo
    $label = "[$($m.Group)] $($m.Repo)"
    if (Test-Path (Join-Path $dir 'b200_model.json')) { Write-Host "  ($n/$($Models.Count)) ${label}: 이미 받았어요"; $result[$label] = '받음'; continue }
    if ($m.Gated -and -not $env:HF_TOKEN) { $result[$label] = '건너뜀(승인 필요, 토큰 없음)'; continue }
    Write-Host ''
    Write-Host "  ($n/$($Models.Count)) $label 받는 중" -ForegroundColor Cyan
    $code = 1
    $stall = 0
    while ($stall -lt $MaxTries) {
        $before = Get-Size $dir
        Invoke-Fetch fetch $m.Repo $dir | Out-Host
        $code = $LASTEXITCODE
        if ($code -ne 1) { break }
        $stall = Step-Retry $stall $before (Get-Size $dir) $MaxTries 'Hugging Face'
    }
    switch ($code) {
        0 { Write-Ok "$label 받았어요"; $result[$label] = '받음' }
        3 { Write-Bad "${label}: 승인이 필요해요. 모델 페이지에서 약관에 동의했는지, 토큰이 맞는지 확인하세요"; $result[$label] = '실패(승인)' }
        4 { Write-Bad "${label}: 저장소를 찾지 못했어요. lists\models.txt 의 이름을 확인하세요"; $result[$label] = '실패(이름)' }
        default { Write-Bad "$label 받지 못했어요"; $result[$label] = '실패' }
    }
}
Remove-Item Env:HF_TOKEN -ErrorAction SilentlyContinue

# 모델 코드가 GitHub에만 있으면(code=) 코드 묶음도 모델 폴더에 code.zip 으로 받는다
foreach ($m in @($Models | Where-Object { $_.Code })) {
    $dir = Get-Dir $m.Repo
    $leaf = Split-Path -Leaf $dir
    $sums = Join-Path $dir '.b200_sha256'
    $label = "[$($m.Group)] $($m.Repo)"
    if (-not (Test-Path (Join-Path $dir 'b200_model.json'))) { continue }
    if ((Test-Path $sums) -and (Select-String -Quiet -SimpleMatch "  $leaf/code.zip" $sums)) { continue }
    Write-Host "  $label 코드 받는 중: $($m.Code)" -ForegroundColor Cyan
    $zip = Join-Path $dir 'code.zip'
    Remove-Item -Force -ErrorAction SilentlyContinue $zip   # GitHub 가 그때그때 만드는 파일이라 이어받지 않는다
    if ((Get-File "$($m.Code)/archive/HEAD.zip" $zip $null $MaxTries) -and (Test-Zip $zip)) {
        $h = (Get-FileHash $zip -Algorithm SHA256).Hash.ToLower()
        [IO.File]::AppendAllText($sums, "$h  $leaf/code.zip`n", (New-Object Text.UTF8Encoding $false))
        Write-Ok "$label 코드를 받았어요"
    } else {
        Write-Bad "$label 코드를 받지 못했어요. github.com 접속을 확인하고 같은 명령을 다시 실행하세요"
        $result[$label] = '실패(코드)'
    }
}

# ------------------------------------------------------------------ 3. B200 서버에 올릴 목록
Write-Step 3 $T 'B200 서버에서 확인할 체크섬 목록 만들기'
# 목록에서 빠진 예전 모델(예: 레드햇 때 받은 Cityscapes 모델)은 지우고,
# 앞에 # 을 붙여 둔 선택 모델은 남겨 두되 B200 서버에 올릴 목록에서 뺀다
$active = @($AllModels | ForEach-Object { Split-Path -Leaf (Get-Dir $_.Repo) })
$known  = @($Listed | ForEach-Object { Split-Path -Leaf (Get-Dir $_) })
foreach ($d in @(Get-ChildItem $Dest -Directory | Where-Object { $_.Name -like '*__*' })) {
    if ($known -notcontains $d.Name) {
        Remove-Item -Recurse -Force $d.FullName
        Write-Info "목록에서 빠진 예전 모델을 지웠어요: $($d.Name -replace '__', '/')"
    } elseif ($active -notcontains $d.Name -and (Test-Path (Join-Path $d.FullName 'b200_model.json'))) {
        Write-Info "선택 모델(앞에 #)이라 B200 서버에 올릴 목록에서 뺐어요: $($d.Name -replace '__', '/')"
    }
}
$lines = @(Get-ChildItem $Dest -Directory | Where-Object { $active -contains $_.Name } | ForEach-Object {
    $s = Join-Path $_.FullName '.b200_sha256'
    if ((Test-Path $s) -and (Test-Path (Join-Path $_.FullName 'b200_model.json'))) { (Get-Content -Encoding UTF8 $s) }
} | Where-Object { $_ })
[IO.File]::WriteAllText((Join-Path $Dest 'MANIFEST.sha256'), (($lines -join "`n") + "`n"), (New-Object Text.UTF8Encoding $false))
$sh = [IO.File]::ReadAllText((Join-Path $root 'server\models_install.sh')) -replace "`r", ''
[IO.File]::WriteAllText((Join-Path $Dest 'models_install.sh'), $sh, (New-Object Text.UTF8Encoding $false))
Write-Ok "파일 $($lines.Count)개를 체크섬 목록에 적고 models_install.sh를 넣었어요"

# ------------------------------------------------------------------ 4. 결과
Write-Step 4 $T '결과'
foreach ($k in $result.Keys) {
    $v = $result[$k]
    $c = if ($v -eq '받음') { 'Green' } elseif ($v -like '실패*') { 'Red' } else { 'Yellow' }
    Write-Host ('  {0,-60} {1}' -f $k, $v) -ForegroundColor $c
}
$total = (Get-ChildItem $Dest -Recurse -File | Measure-Object -Property Length -Sum).Sum
$failed = @($result.Keys | Where-Object { $result[$_] -like '실패*' })
$skipped = @($result.Keys | Where-Object { $result[$_] -like '건너뜀*' })
Allow-Sleep
Write-Host ''
if ($failed.Count) {
    Write-Host '################ 일부 못 받음 ################' -ForegroundColor Yellow
    Write-Host " 못 받은 것: $($failed -join ', ')"
    Write-Host ' 같은 명령을 다시 실행하면 못 받은 것만 이어서 받아요. 받은 것만 먼저 올려도 돼요.'
    Write-Host " 계속 안 되면 이 기록 파일을 담당자에게 보내 주세요: $script:LogPath"
} else {
    Write-Host '############################ 완료 ############################' -ForegroundColor Green
}
if ($skipped.Count) {
    Write-Host " 건너뛴 것 $($skipped.Count)개(승인 필요, 토큰 없음): 토큰을 준비해 같은 명령을 다시 실행하면 받아요." -ForegroundColor Yellow
    Write-Host '   방법: docs\7_모델.md 의 "승인이 필요한 모델(gated) 받기"'
}
Write-Host ''
Write-Host ' 접근 PC에서 할 일은 끝났어요. B200 서버에 올릴 폴더(통째로):' -ForegroundColor Green
Write-Host "   $Dest  ($(Format-Size $total))"
if ((Split-Path -Leaf $Dest) -ne 'models') { Write-Host '   폴더 이름이 models 가 아니면, 올리기 전에 models 로 바꾸세요(서버 명령이 이 이름만 받아요).' -ForegroundColor Yellow }
Write-Host ''
Save-Fingerprint 'models 폴더' (Get-Fingerprint @((Join-Path $Dest 'MANIFEST.sha256'), (Join-Path $Dest 'models_install.sh')))
Write-Host '   (MANIFEST.sha256과 models_install.sh를 이어 붙인 지문이에요. 나머지 파일은 설치 스크립트가 MANIFEST.sha256으로 하나하나 확인해요)'
Show-NotNeeded $Dest (Join-Path $Dest 'MANIFEST.sha256') @()
Write-Host ''
Write-Host ' 1) 공용 계정의 FileZilla로 B200 서버의 /app/upload 에 폴더째 올리세요.' -ForegroundColor Green
Write-Host ' 2) root(PuTTY)로 /app/inbox 에 새로 복사하세요. 링크가 섞였으면 멈추고, 아니면 지문을 보여 줘요. 위 지문과 다르면 실행하지 마세요.' -ForegroundColor Green
Write-Host '   /app/shared/bin/b200 fetch models'
Write-Host ' 3) 같으면 설치하세요. 다 끝나면 /app/upload/models 는 지워 공간을 비우세요(서버 2도 쓸 거면 먼저 NAS에 보관: docs\9_NAS.md).' -ForegroundColor Green
Write-Host '   bash /app/inbox/models/models_install.sh'
Write-Host ' 자세한 순서: docs\7_모델.md'
Write-Host '##############################################################'
Stop-Transcript | Out-Null
if ($failed.Count) { exit 1 }
