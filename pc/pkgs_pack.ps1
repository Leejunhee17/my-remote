<#
[접근 PC · 관리자 전용] GPU 서버 화면에서 쓰는 기초 프로그램(tmux, nvtop, rsync 등) 묶음(pack_pkgs\gpu-pkgs.tar)을 만든다.
서버에 인터넷이 없어서, Ubuntu 24.04(noble) 저장소에서 .deb 파일을 의존 패키지까지 모두 받아 묶는다.
서버에서는 pkgs_install.sh 가 이 .deb 들로 임시 apt 저장소를 만들어 없는 것만 설치한다.
점검 → 목록 읽기 → 받기 → 묶기까지 한 번에 한다. 끊기면 다시 실행하면 이어서 한다.

  powershell -ExecutionPolicy Bypass -File .\pc\pkgs_pack.ps1
#>
param(
    [int]$MaxTries = 20
)
$here = $PSScriptRoot
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $here 'gpu_common.ps1')
$out = Join-Path $root 'pack_pkgs'
$T = 4
New-Item -ItemType Directory -Force $out | Out-Null
Start-Log (Join-Path $out 'build.log')
Stop-Sleep
Write-Host "[접근 PC] 서버 기초 프로그램 묶음 만들기  ($(Get-Date -Format 'yyyy-MM-dd HH:mm'))"

$UbuBase = 'http://archive.ubuntu.com/ubuntu'
$Code    = 'noble'   # Ubuntu 24.04. 서버 OS 가 바뀌면 여기와 docs/1_처음_설치.md 를 같이 고친다
# 서버 화면(컨테이너 밖)에서 쓰는 프로그램. docs/1_처음_설치.md 의 "서버 기초 프로그램" 목록, server/check.sh 와 같게 둔다(tests/run.sh 가 확인)
$Pkgs = @(
    'tmux', 'screen', 'vim', 'nano', 'micro', 'less', 'htop', 'btop', 'nvtop', 'iotop', 'sysstat', 'lsof', 'strace', 'tree', 'ncdu', 'jq', 'bc', 'file',
    'rsync', 'zip', 'unzip', 'p7zip-full', 'pigz', 'zstd', 'xz-utils', 'pv',
    'git', 'git-lfs', 'curl', 'wget', 'python3', 'perl', 'gawk',
    'iperf3', 'ethtool', 'perftest', 'infiniband-diags', 'ibverbs-utils'
)

function Write-Lf($path, $lines) {
    [IO.File]::WriteAllText($path, (($lines -join "`n") + "`n"), (New-Object Text.UTF8Encoding $false))
}

# apt 저장소의 Packages.gz 를 읽어 패키지마다 원래 글(Text)과 필요한 칸을 $Idx 에 넣는다.
# 먼저 읽은 목록이 이긴다(noble-updates 를 먼저 읽어 보안·버그 수정판을 쓴다). 다른 패키지가 대신하는 이름(Provides)은 $Prov 에
function Read-AptIndex($url, $Idx, $Prov) {
    $tmp = [IO.Path]::GetTempFileName()
    try {
        if (-not (Get-File $url $tmp $null $MaxTries)) { return $false }
        $fs = [IO.File]::OpenRead($tmp)
        try {
            $gz = New-Object IO.Compression.GZipStream($fs, [IO.Compression.CompressionMode]::Decompress)
            $text = (New-Object IO.StreamReader($gz)).ReadToEnd()
        } finally { $fs.Close() }
    } finally { Remove-Item -Force -ErrorAction SilentlyContinue $tmp }
    foreach ($block in ($text -replace "`r", '') -split "`n`n") {
        if (-not ($block -match '(?m)^Package: (\S+)')) { continue }
        $p = $Matches[1]
        if ($Idx.ContainsKey($p)) { continue }
        $Idx[$p] = $block.Trim("`n")
        if ($block -match '(?m)^Provides: (.+)$') {
            foreach ($v in $Matches[1] -split ',') {
                $v = ($v -replace '\(.*?\)', '').Trim()
                if (-not $v) { continue }
                if (-not $Prov.ContainsKey($v)) { $Prov[$v] = New-Object Collections.ArrayList }
                [void]$Prov[$v].Add($p)
            }
        }
    }
    return $true
}

function Get-Field($block, $name) {
    if ($block -match "(?m)^$([regex]::Escape($name)): (.+)$") { return $Matches[1].Trim() }
    return ''
}

# "a (>= 1) | b:any [amd64] <!nocheck>" 같은 의존 칸 하나 → 이름 목록 @('a', 'b')
function Split-Alts($clause) {
    return @($clause -split '\|' | ForEach-Object {
        (($_ -replace '\(.*?\)', '' -replace '\[.*?\]', '' -replace '<.*?>', '').Trim() -replace ':(any|native)$', '') } | Where-Object { $_ })
}

# ------------------------------------------------------------------ 1. 점검
Write-Step 1 $T '점검'
if (Get-Command 'tar.exe' -ErrorAction SilentlyContinue) { Write-Ok 'tar.exe' }
else { Write-Bad '없는 프로그램: tar.exe (윈도우 10 1803 이후에는 기본으로 들어 있어요)' }
if (Get-Command 'curl.exe' -ErrorAction SilentlyContinue) { Write-Ok 'curl.exe' }
else { Write-Bad '없는 프로그램: curl.exe (윈도우 10 1803 이후에는 기본으로 들어 있어요)' }
if (-not (Test-Path (Join-Path $root 'server\pkgs_install.sh'))) { Write-Bad '없는 파일: server\pkgs_install.sh (git pull로 저장소를 최신으로 받으세요)' }
Test-Site 'Ubuntu 패키지 저장소' "$UbuBase/dists/$Code/Release" | Out-Null
if ($script:Fails) {
    Stop-Run '필요한 프로그램·파일이 없거나 접속되지 않는 사이트가 있어요' ('위 [문제] 줄과 그 아래 설명대로 고친 뒤 다시 실행하세요. ' +
        '브라우저에서는 열린다면 사내 IT에 프록시 주소를 물어 .env 에 HTTPS_PROXY=http://프록시주소:포트 를 적고 다시 실행하세요.')
}
$free = Get-FreeGB $out
if ($free -lt 2) { Stop-Run "남은 공간이 $free GB예요(2 GB 이상 필요해요)" '공간을 비우고 다시 실행하세요.' }
Write-Ok "남은 공간 $free GB"

# ------------------------------------------------------------------ 2. 목록 읽고 의존 패키지 찾기
Write-Step 2 $T "Ubuntu $Code 목록 읽고 의존 패키지 찾기"
$idx = @{}
$prov = @{}
foreach ($pocket in "$Code-updates", $Code) {
    foreach ($comp in 'main', 'universe', 'multiverse') {   # nvtop 은 multiverse 에 있어요
        Write-Info "목록 읽는 중: $pocket/$comp"
        if (-not (Read-AptIndex "$UbuBase/dists/$pocket/$comp/binary-amd64/Packages.gz" $idx $prov)) {
            Stop-Run "Ubuntu $pocket/$comp 목록을 받지 못했어요" '인터넷 연결을 확인하고 다시 실행하세요.'
        }
    }
}
Write-Ok "패키지 $($idx.Count)개의 목록을 읽었어요"

$missing = @($Pkgs | Where-Object { -not $idx.ContainsKey($_) })
if ($missing.Count) { Stop-Run "Ubuntu $Code 목록에 없는 패키지: $($missing -join ', ')" 'pc\pkgs_pack.ps1 의 $Pkgs 목록을 확인하세요.' }

# 받을 패키지 = 목록 + Depends·Pre-Depends 를 끝까지 따라간 것(Recommends 는 빼요. 서버에서도 --no-install-recommends).
# 서버에 이미 있는 기본 패키지도 넣어요. 새 프로그램이 더 새 버전을 요구하면 apt 가 그것만 올려요. 없는 것만 고르는 일은 서버의 apt 가 해요
$chosen = [ordered]@{}
$why = @{}
$queue = New-Object Collections.Queue
foreach ($p in $Pkgs) { $chosen[$p] = $true; $queue.Enqueue($p) }
$noDep = @()
while ($queue.Count) {
    $p = $queue.Dequeue()
    $b = $idx[$p]
    foreach ($field in 'Pre-Depends', 'Depends') {
        $dep = Get-Field $b $field
        if (-not $dep) { continue }
        foreach ($clause in $dep -split ',') {
            $alts = Split-Alts $clause
            if (-not $alts.Count) { continue }
            # 이미 고른 것 → 진짜 패키지 → 대신하는 패키지(Provides) 순서로 고른다
            $pick = $alts | Where-Object { $chosen.Contains($_) } | Select-Object -First 1
            if (-not $pick) {
                foreach ($a in $alts) {
                    if ($prov.ContainsKey($a)) { $pick = $prov[$a] | Where-Object { $chosen.Contains($_) } | Select-Object -First 1; if ($pick) { break } }
                }
            }
            if (-not $pick) { $pick = $alts | Where-Object { $idx.ContainsKey($_) } | Select-Object -First 1 }
            if (-not $pick) {
                foreach ($a in $alts) { if ($prov.ContainsKey($a)) { $pick = $prov[$a][0]; break } }
            }
            if (-not $pick) { $noDep += "$p → $($clause.Trim())"; continue }
            if (-not $chosen.Contains($pick)) { $chosen[$pick] = $true; $why[$pick] = $p; $queue.Enqueue($pick) }
        }
    }
}
if ($noDep.Count) {
    $noDep | Select-Object -First 10 | ForEach-Object { Write-Warn "목록에서 찾지 못한 의존 패키지: $_" }
    Stop-Run "의존 패키지 $($noDep.Count)개를 찾지 못했어요" '아래 기록 파일을 담당자에게 보내 주세요.'
}
$plan = @()
$total = [int64]0
foreach ($p in $chosen.Keys) {
    $b = $idx[$p]
    $fn = Get-Field $b 'Filename'
    $sha = Get-Field $b 'SHA256'
    if (-not $fn -or -not $sha) { Stop-Run "목록에 파일 정보가 없는 패키지: $p" '아래 기록 파일을 담당자에게 보내 주세요.' }
    $sz = [int64](Get-Field $b 'Size')
    $total += $sz
    $plan += [pscustomobject]@{ Pkg = $p; Url = "$UbuBase/$fn"; Name = (Split-Path -Leaf $fn); Sha = $sha; Block = $b }
}
Write-Ok "목록 $($Pkgs.Count)개 + 의존 패키지 $($plan.Count - $Pkgs.Count)개 = $($plan.Count)개 ($(Format-Size $total))"

# ------------------------------------------------------------------ 3. 받기
Write-Step 3 $T "받기 ($($plan.Count)개)"
$debDir = Join-Path $out 'debs'
New-Item -ItemType Directory -Force $debDir | Out-Null
$n = 0
foreach ($it in $plan) {
    $n++
    if ($n % 20 -eq 1 -or $n -eq $plan.Count) { Write-Info "($n/$($plan.Count)) $($it.Name)" }
    if (-not (Get-File $it.Url (Join-Path $debDir $it.Name) $null $MaxTries $it.Sha)) {
        Stop-Run "받지 못한 파일: $($it.Name)" '인터넷 연결을 확인하고 다시 실행하세요. 받은 것은 건너뛰어요.'
    }
}
# 지난번에 받았지만 이번 목록에 없는 예전 버전은 지운다
$names = @($plan | ForEach-Object { $_.Name })
Get-ChildItem $debDir -File | Where-Object { $names -notcontains $_.Name } | Remove-Item -Force
Write-Ok "$($plan.Count)개를 받고 체크섬을 확인했어요"

# ------------------------------------------------------------------ 4. 묶기
Write-Step 4 $T '묶기'
# 서버의 임시 apt 저장소 목록(debs/Packages). 원래 글 그대로 두고 파일 위치만 debs 폴더 안으로 바꾼다(apt 가 SHA256 으로 한 번 더 확인해요)
Write-Lf (Join-Path $debDir 'Packages') ($plan | ForEach-Object { ($_.Block -replace '(?m)^Filename: .*$', "Filename: ./$($_.Name)") + "`n" })
$sh = [IO.File]::ReadAllText((Join-Path $root 'server\pkgs_install.sh')) -replace "`r", ''
[IO.File]::WriteAllText((Join-Path $out 'pkgs_install.sh'), $sh, (New-Object Text.UTF8Encoding $false))
Write-Lf (Join-Path $out 'pkgs_info.txt') @("made=$(Get-Date -Format 'yyyy-MM-dd HH:mm')", "ubuntu=$Code", "pkgs=$($Pkgs -join ' ')", "debs=$($plan.Count)")
$files = @($names | ForEach-Object { "debs/$_" }) + 'debs/Packages'
$all = $files + 'pkgs_info.txt'
Write-Lf (Join-Path $out 'MANIFEST_pkgs.sha256') ($all | ForEach-Object {
    "$((Get-FileHash (Join-Path $out $_) -Algorithm SHA256).Hash.ToLower())  $_" })
$tar = Join-Path $out 'gpu-pkgs.tar'
Remove-Item -Force -ErrorAction SilentlyContinue $tar
Push-Location $out
& tar.exe -cf gpu-pkgs.tar MANIFEST_pkgs.sha256 pkgs_install.sh pkgs_info.txt @files
$rc = $LASTEXITCODE
Pop-Location
if ($rc -ne 0) { Stop-Run 'tar로 묶지 못했어요' '남은 공간을 확인하고 다시 실행하세요.' }
Write-Ok "묶었어요($(Format-Size (Get-Item $tar).Length))"

Allow-Sleep
Write-Host ''
Write-Host '############################ 완료 ############################' -ForegroundColor Green
Write-Host " 묶은 것: Ubuntu $Code 기초 프로그램 $($Pkgs.Count)개(의존 패키지 포함 .deb $($plan.Count)개)"
Write-Host ''
Write-Host ' 접근 PC에서 할 일은 끝났어요. GPU 서버에 올릴 파일(하나):' -ForegroundColor Green
Write-Host "   $tar"
Write-Host ''
Save-Fingerprint 'gpu-pkgs.tar' (Get-Fingerprint @($tar))
Write-Host ''
Write-Host ' 1) 공용 계정의 FileZilla로 GPU 서버의 /app/upload 에 올리세요.' -ForegroundColor Green
Write-Host ' 2) root(PuTTY)로 /app/inbox 에 복사하고, 나온 지문이 위 지문과 같은지 보세요. 다르면 실행하지 마세요.' -ForegroundColor Green
Write-Host '   /app/admin/bin/gpu fetch gpu-pkgs.tar'
Write-Host ' 3) 같으면 풀어서 실행하세요. admin_setup.sh 를 먼저 실행해 둬야 해요.' -ForegroundColor Green
Write-Host '   cd /app/inbox && tar xf gpu-pkgs.tar && bash pkgs_install.sh'
Write-Host ' 자세한 순서: docs\1_처음_설치.md 의 1-1단계'
Write-Host '##############################################################' -ForegroundColor Green
Stop-Transcript | Out-Null
