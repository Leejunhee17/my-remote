<#
[접근 PC · 관리자 전용] GPU 서버에 설치할 rootless Docker 묶음(pack_docker\gpu-docker.tar)을 만든다.
점검 → 받기 → 검사 → 묶기까지 한 번에 한다. 끊기면 다시 실행하면 이어서 한다.
Ubuntu 버전이 정해지지 않아도 된다(22.04, 24.04 용 패키지를 모두 넣는다).

  powershell -ExecutionPolicy Bypass -File .\pc\docker_pack.ps1
#>
param(
    [int]$MaxTries = 5
)
$here = $PSScriptRoot
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $here 'gpu_common.ps1')
$out = Join-Path $root 'pack_docker'
$T = 5
New-Item -ItemType Directory -Force $out | Out-Null
Start-Log (Join-Path $out 'build.log')
Stop-Sleep
Write-Host "[접근 PC] rootless Docker 묶음 만들기  ($(Get-Date -Format 'yyyy-MM-dd HH:mm'))"

$DockerBase = 'https://download.docker.com/linux/static/stable/x86_64'
$NvBase     = 'https://nvidia.github.io/libnvidia-container/stable/deb/amd64'
$UbuBase    = 'http://archive.ubuntu.com/ubuntu'
# rootless Docker 에 필요한 Ubuntu 패키지(서버에 없을 때만 설치한다). glib 같은 기본 패키지는 빼고 적는다
$UbuPkgs = @{
    jammy = @('uidmap', 'slirp4netns', 'libslirp0')
    noble = @('uidmap', 'libsubid4', 'slirp4netns', 'libslirp0', 'passt')
}
$NvPkgs = @('nvidia-container-toolkit', 'nvidia-container-toolkit-base', 'libnvidia-container-tools', 'libnvidia-container1')

function Write-Lf($path, $lines) {
    [IO.File]::WriteAllText($path, (($lines -join "`n") + "`n"), (New-Object Text.UTF8Encoding $false))
}

# 웹 페이지나 목록 파일을 문자열로 받는다(작은 파일 전용)
function Get-Text($url) {
    $tmp = [IO.Path]::GetTempFileName()
    try {
        if (-not (Get-File $url $tmp $null $MaxTries)) { return $null }
        return [IO.File]::ReadAllText($tmp)
    } finally { Remove-Item -Force -ErrorAction SilentlyContinue $tmp }
}

# apt 저장소의 Packages(.gz) 목록을 읽어 패키지마다 {Version, Filename, SHA256} 을 돌려준다
function Get-AptIndex($url) {
    $tmp = [IO.Path]::GetTempFileName()
    try {
        if (-not (Get-File $url $tmp $null $MaxTries)) { return $null }
        if ($url -like '*.gz') {
            $fs = [IO.File]::OpenRead($tmp)
            try {
                $gz = New-Object IO.Compression.GZipStream($fs, [IO.Compression.CompressionMode]::Decompress)
                $text = (New-Object IO.StreamReader($gz)).ReadToEnd()
            } finally { $fs.Close() }
        } else { $text = [IO.File]::ReadAllText($tmp) }
    } finally { Remove-Item -Force -ErrorAction SilentlyContinue $tmp }
    $idx = @{}
    foreach ($block in ($text -replace "`r", '') -split "`n`n") {
        $f = @{}
        foreach ($line in $block -split "`n") { if ($line -match '^([A-Za-z0-9-]+): (.*)$') { $f[$Matches[1]] = $Matches[2] } }
        if ($f.Package) {
            if (-not $idx.ContainsKey($f.Package)) { $idx[$f.Package] = @() }
            $idx[$f.Package] += [pscustomobject]@{ Version = $f.Version; Filename = $f.Filename; SHA256 = $f.SHA256 }
        }
    }
    return $idx
}

# 1.17.8-1 같은 버전 번호에서 숫자 부분만 비교용으로 꺼낸다(1:4.13+dfsg1-4ubuntu3 도 대충 맞게)
function Get-VerKey($v) {
    $nums = [regex]::Matches(($v -replace '^\d+:', ''), '\d+') | Select-Object -First 6 | ForEach-Object { '{0:D8}' -f [int64]$_.Value }
    return ($nums -join '.')
}

# ------------------------------------------------------------------ 1. 점검
Write-Step 1 $T '점검'
if (Get-Command 'tar.exe' -ErrorAction SilentlyContinue) { Write-Ok 'tar.exe' } else { Write-Bad '없는 프로그램: tar.exe (윈도우 10 1803 이후에는 기본으로 들어 있어요)' }
Test-Aria2 | Out-Null
foreach ($f in 'server\docker_install.sh') {
    if (-not (Test-Path (Join-Path $root $f))) { Write-Bad "없는 파일: $f (git pull로 저장소를 최신으로 받으세요)" }
}
$sites = [ordered]@{
    'Docker 배포 서버'          = "$DockerBase/"
    'NVIDIA 패키지 저장소'      = "$NvBase/Packages"
    'Ubuntu 패키지 저장소'      = "$UbuBase/dists/noble/Release"
    'GitHub (buildx, compose)'  = 'https://github.com/'
}
foreach ($k in $sites.Keys) { Test-Site $k $sites[$k] | Out-Null }
if ($script:Fails) {
    Stop-Run '필요한 프로그램·파일이 없거나 접속되지 않는 사이트가 있어요' ('위 [문제] 줄과 그 아래 설명대로 고친 뒤 다시 실행하세요. ' +
        '브라우저에서는 열린다면 사내 IT에 프록시 주소를 물어 .env 에 HTTPS_PROXY=http://프록시주소:포트 를 적고 다시 실행하세요.')
}
$free = Get-FreeGB $out
if ($free -lt 3) { Stop-Run "남은 공간이 $free GB예요(3 GB 이상 필요해요)" '공간을 비우고 다시 실행하세요.' }
Write-Ok "남은 공간 $free GB"

# ------------------------------------------------------------------ 2. 버전 정하기
Write-Step 2 $T '받을 버전 정하기'
$listing = Get-Text "$DockerBase/"
if (-not $listing) { Stop-Run 'Docker 배포 목록을 받지 못했어요' '인터넷 연결을 확인하고 다시 실행하세요.' }
$vers = @([regex]::Matches($listing, 'docker-rootless-extras-(\d+\.\d+\.\d+)\.tgz') | ForEach-Object { $_.Groups[1].Value } |
    Where-Object { $listing -match "docker-$([regex]::Escape($_))\.tgz" } | Sort-Object { [version]$_ } -Unique)
if (-not $vers.Count) { Stop-Run 'Docker 버전을 찾지 못했어요' '아래 기록 파일을 담당자에게 보내 주세요.' }
$dv = $vers[-1]
Write-Ok "Docker $dv (설치 없이 바로 쓰는 실행 파일 + rootless 추가 파일)"

$nvIdx = Get-AptIndex "$NvBase/Packages"
if (-not $nvIdx) { Stop-Run 'NVIDIA 패키지 목록을 받지 못했어요' '인터넷 연결을 확인하고 다시 실행하세요.' }
$plan = @()
# 네 패키지를 같은 버전으로 맞춘다(서로 같은 버전을 요구한다)
$nvVers = @($nvIdx['nvidia-container-toolkit'] | Where-Object { $_.Version -match '^\d+(\.\d+)+-\d+$' } |
    Sort-Object { Get-VerKey $_.Version } | ForEach-Object { $_.Version })
if (-not $nvVers.Count) { Stop-Run 'NVIDIA Container Toolkit 버전을 찾지 못했어요' '아래 기록 파일을 담당자에게 보내 주세요.' }
$nv = $nvVers[-1]
foreach ($p in $NvPkgs) {
    $e = $nvIdx[$p] | Where-Object { $_.Version -eq $nv } | Select-Object -First 1
    if (-not $e) { Stop-Run "목록에서 찾지 못한 패키지: $p $nv" '아래 기록 파일을 담당자에게 보내 주세요.' }
    $plan += [pscustomobject]@{ Dir = 'debs/nvidia'; Url = "$NvBase/$($e.Filename -replace '^\./', '')"; Sha = $e.SHA256 }
}
Write-Ok "NVIDIA Container Toolkit $nv"

foreach ($code in 'jammy', 'noble') {
    # 보안 업데이트(-updates)에 더 새 버전이 있으면 그것을 쓴다
    $cands = @{}
    foreach ($pocket in $code, "$code-updates") {
        foreach ($comp in 'main', 'universe') {
            $i = Get-AptIndex "$UbuBase/dists/$pocket/$comp/binary-amd64/Packages.gz"
            if (-not $i) { Stop-Run "Ubuntu $pocket/$comp 목록을 받지 못했어요" '인터넷 연결을 확인하고 다시 실행하세요.' }
            foreach ($p in $UbuPkgs[$code]) { if ($i[$p]) { $cands[$p] = @($cands[$p]) + $i[$p] | Where-Object { $_ } } }
        }
    }
    foreach ($p in $UbuPkgs[$code]) {
        $e = $cands[$p] | Sort-Object { Get-VerKey $_.Version } | Select-Object -Last 1
        if (-not $e) { Stop-Run "Ubuntu $code 목록에서 찾지 못한 패키지: $p" '아래 기록 파일을 담당자에게 보내 주세요.' }
        $plan += [pscustomobject]@{ Dir = "debs/$code"; Url = "$UbuBase/$($e.Filename)"; Sha = $e.SHA256 }
    }
    Write-Ok "Ubuntu ${code}용 패키지 $($UbuPkgs[$code].Count)개 ($($UbuPkgs[$code] -join ', '))"
}

# docker buildx(빌드), compose 는 GitHub 최신 버전. 받을 수 없으면 빼고 진행한다(없어도 docker 는 된다)
foreach ($plug in @(
        @{ Repo = 'docker/buildx';  Name = 'docker-buildx';  File = { param($t) "buildx-$t.linux-amd64" } },
        @{ Repo = 'docker/compose'; Name = 'docker-compose'; File = { param($t) 'docker-compose-linux-x86_64' } })) {
    # releases/latest 가 넘겨주는 주소(…/tag/v1.2.3)에서 버전을 읽는다
    $loc = [string](Invoke-Http "https://github.com/$($plug.Repo)/releases/latest" -NoRedirect -Max 0).Headers['location']
    if ($loc -match '/tag/(v[\d.]+)$') {
        $t = $Matches[1]
        $fn = & $plug.File $t
        # 파일 이름이 버전과 상관없이 같으므로, 공식 체크섬으로 확인한다(없으면 매번 새로 받아 예전 파일에 이어 붙지 않게)
        $sha = $null
        $sr = Invoke-Http "https://github.com/$($plug.Repo)/releases/download/$t/checksums.txt" -Max 1048576
        if ($sr.Ok -and $sr.Status -eq 200) {
            foreach ($l in ($sr.Body -split "`r?`n")) { if ($l -match "^([0-9a-f]{64})\s+\*?$([regex]::Escape($fn))\s*$") { $sha = $Matches[1] } }
        }
        $plan += [pscustomobject]@{ Dir = 'plugins'; Url = "https://github.com/$($plug.Repo)/releases/download/$t/$fn"; Sha = $sha; Name = $plug.Name; Fresh = (-not $sha) }
        if ($sha) { Write-Ok "$($plug.Name) $t" } else { Write-Warn "$($plug.Name) ${t}: 공식 체크섬을 찾지 못해서, 받아 둔 파일이 있어도 새로 받아요(받은 뒤 맞는지 확인은 못 해요)" }
    } else { Write-Warn "최신 버전을 찾지 못해 묶음에서 뺐어요: $($plug.Name) (없어도 docker는 돼요)" }
}
$plan += [pscustomobject]@{ Dir = '.'; Url = "$DockerBase/docker-$dv.tgz"; Sha = $null }
$plan += [pscustomobject]@{ Dir = '.'; Url = "$DockerBase/docker-rootless-extras-$dv.tgz"; Sha = $null }

# ------------------------------------------------------------------ 3. 받기
Write-Step 3 $T "받기 ($($plan.Count)개)"
$files = @()
$n = 0
foreach ($it in $plan) {
    $n++
    $name = if ($it.Name) { $it.Name } else { [uri]::UnescapeDataString((Split-Path -Leaf ([uri]$it.Url).AbsolutePath)) }
    $dir = Join-Path $out $it.Dir
    New-Item -ItemType Directory -Force $dir | Out-Null
    $dest = Join-Path $dir $name
    Write-Host "  ($n/$($plan.Count)) $($it.Dir)/$name"
    if ($it.Fresh) { Remove-Item -Force -ErrorAction SilentlyContinue $dest }
    if (-not (Get-File $it.Url $dest $null $MaxTries $it.Sha)) { Stop-Run "받지 못한 파일: $name" '인터넷 연결을 확인하고 다시 실행하세요. 받은 것은 건너뛰어요.' }
    $files += (($it.Dir -replace '^\.$', '') + '/' + $name).TrimStart('/')
}
# 지난번에 받았지만 이번 목록에 없는 예전 버전은 지운다
Get-ChildItem $out -Recurse -File | Where-Object {
    $rel = $_.FullName.Substring($out.Length + 1) -replace '\\', '/'
    ($rel -like '*.deb' -or $rel -like '*.tgz' -or $rel -like 'plugins/*') -and $files -notcontains $rel
} | Remove-Item -Force
Write-Ok "$($files.Count)개를 받고 체크섬을 확인했어요"

# ------------------------------------------------------------------ 4. 검사
Write-Step 4 $T '검사'
foreach ($t in @("docker-$dv.tgz", "docker-rootless-extras-$dv.tgz")) {
    $list = & tar.exe -tzf (Join-Path $out $t) 2>&1
    if ($LASTEXITCODE -ne 0) { Remove-Item -Force (Join-Path $out $t); Stop-Run "깨진 파일: $t" '다시 실행하세요. 깨진 파일은 지웠으니 새로 받아요.' }
    Write-Ok "${t}: 이상 없어요(들어 있는 파일 $(@($list).Count)개)"
}

# ------------------------------------------------------------------ 5. 묶기
Write-Step 5 $T '묶기'
$sh = [IO.File]::ReadAllText((Join-Path $root 'server\docker_install.sh')) -replace "`r", ''
[IO.File]::WriteAllText((Join-Path $out 'docker_install.sh'), $sh, (New-Object Text.UTF8Encoding $false))
Write-Lf (Join-Path $out 'docker_info.txt') @("made=$(Get-Date -Format 'yyyy-MM-dd HH:mm')", "docker=$dv", "nvidia_toolkit=$nv")
$all = @($files) + 'docker_info.txt'
Write-Lf (Join-Path $out 'MANIFEST_docker.sha256') ($all | ForEach-Object {
    "$((Get-FileHash (Join-Path $out $_) -Algorithm SHA256).Hash.ToLower())  $_" })
$tar = Join-Path $out 'gpu-docker.tar'
Remove-Item -Force -ErrorAction SilentlyContinue $tar
Push-Location $out
& tar.exe -cf gpu-docker.tar MANIFEST_docker.sha256 docker_install.sh docker_info.txt @files
$code = $LASTEXITCODE
Pop-Location
if ($code -ne 0) { Stop-Run 'tar로 묶지 못했어요' '남은 공간을 확인하고 다시 실행하세요.' }
Write-Ok "묶었어요($(Format-Size (Get-Item $tar).Length))"

Allow-Sleep
Write-Host ''
Write-Host '############################ 완료 ############################' -ForegroundColor Green
Write-Host " 묶은 버전: Docker $dv, NVIDIA Container Toolkit $nv"
Write-Host ''
Write-Host ' 접근 PC에서 할 일은 끝났어요. GPU 서버에 올릴 파일(하나):' -ForegroundColor Green
Write-Host "   $tar"
Write-Host ''
Save-Fingerprint 'gpu-docker.tar' (Get-Fingerprint @($tar))
Write-Host ''
Write-Host ' 1) 공용 계정의 FileZilla로 NAS 의 /data/autonomy_sw/inbox 에 올리세요(다른 파일이 있어도 괜찮아요).' -ForegroundColor Green
Write-Host ' 2) root(PuTTY)로 /app/inbox 에 복사하고, 나온 지문이 위 지문과 같은지 보세요. 다르면 실행하지 마세요.' -ForegroundColor Green
Write-Host '   /app/admin/bin/gpu fetch gpu-docker.tar'
Write-Host ' 3) 같으면 풀어서 실행하세요. 1단계 준비(prepare.sh)를 먼저 해 둬야 해요.' -ForegroundColor Green
Write-Host '   cd /app/inbox && tar xf gpu-docker.tar && bash docker_install.sh'
Write-Host ' 자세한 순서: docs\1_처음_설치.md 의 3단계'
Write-Host '##############################################################' -ForegroundColor Green
Stop-Transcript | Out-Null
