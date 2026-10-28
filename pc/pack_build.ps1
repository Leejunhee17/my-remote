<#
[접근 PC] 공용 휠 + 기초 프로그램 묶음(pack\b200-pack.tar)을 만든다.
점검 → 받기 → 묶기 → 검사까지 한 번에 한다. 끊기면 다시 실행하면 이어서 한다.

  powershell -ExecutionPolicy Bypass -File .\pc\pack_build.ps1              # B200 서버 Ubuntu 22.04 이상 (glibc 2.35)
  powershell -ExecutionPolicy Bypass -File .\pc\pack_build.ps1 -Glibc 2.31  # 서버 glibc 가 더 낮을 때만(check_server.sh 가 알려 준다)
#>
param(
    [string]$Glibc = '2.35',
    [string]$Cuda  = '13.0',
    [int]$MaxTries = 20      # 받은 양이 늘지 않은 채 연속으로 끊긴 횟수가 이만큼이면 포기
)
$here = $PSScriptRoot
$root = Split-Path $PSScriptRoot -Parent   # 저장소 맨 위(D:\b200). 결과 폴더와 uv.exe 는 여기
. (Join-Path $here 'b200_common.ps1')
$out   = Join-Path $root 'pack'
$torch = 'https://download.pytorch.org/whl/cu130'
$ml    = 'manylinux_' + ($Glibc -replace '\.', '_')   # 예: manylinux_2_34
# pip download 는 낮은 manylinux 를 알아서 넣지 않으므로 서버 glibc 이하를 모두 적는다
$plats = @()
for ($m = [int]$Glibc.Split('.')[1]; $m -ge 5; $m--) { $plats += '--platform', "manylinux_2_${m}_x86_64" }
$plats += '--platform', 'manylinux2014_x86_64', '--platform', 'manylinux2010_x86_64', '--platform', 'manylinux1_x86_64'
$T = 6
New-Item -ItemType Directory -Force $out | Out-Null
Start-Log (Join-Path $out 'build.log')
Stop-Sleep
Write-Host "[접근 PC] 공용 휠·기초 프로그램 묶음 만들기  ($(Get-Date -Format 'yyyy-MM-dd HH:mm'), B200 서버 glibc $Glibc, CUDA $Cuda)"

# 줄 끝을 LF 로 써야 서버(리눅스)에서 문제가 없다
function Write-Lf($path, $lines) {
    [IO.File]::WriteAllText($path, (($lines -join "`n") + "`n"), (New-Object Text.UTF8Encoding $false))
}

# ------------------------------------------------------------------ 1. 점검
Write-Step 1 $T '점검'
$uv = Find-Exe 'uv' $root
$mm = Find-Exe 'micromamba' $root
if ($uv) { Write-Ok "uv : $uv" } else { Write-Bad 'uv 가 없다' }
if ($mm) { Write-Ok "micromamba : $mm" } else { Write-Bad 'micromamba 가 없다' }
foreach ($e in 'curl.exe', 'tar.exe') {
    if (Get-Command $e -ErrorAction SilentlyContinue) { Write-Ok $e } else { Write-Bad "$e 가 없다(윈도우 10 1803 이후에 기본으로 있다)" }
}
if ($script:Fails) {
    Stop-Run '필요한 프로그램이 없다' 'uv, micromamba 를 설치하고 PowerShell 창을 새로 연다. 또는 uv.exe, micromamba.exe 를 이 폴더에 넣는다.'
}
$scripts = @('pack_install.sh', 'move_shared.sh', 'check_server.sh', 'check_network.sh', 'admin_setup.sh', 'bin/b200', 'bin/docker', 'bin/nvidia-smi')   # 묶음에 같이 넣는 서버 파일
foreach ($f in @('lists\tools.txt', 'lists\wheels.txt') + @($scripts | ForEach-Object { 'server\' + ($_ -replace '/', '\') })) {
    if (-not (Test-Path (Join-Path $root $f))) { Stop-Run "$f 가 없다" 'git pull 로 저장소를 최신으로 받는다.' }
}
Write-Ok '목록 파일(tools.txt, wheels.txt) 있음'

$free = Get-FreeGB $out
if ($free -lt 30) { Stop-Run "남은 공간이 $free GB 다(30 GB 이상 필요)" '공간이 넉넉한 드라이브로 저장소를 옮겨 다시 실행한다.' }
Write-Ok "남은 공간 $free GB"

$sites = [ordered]@{
    'conda-forge (기초 프로그램)' = 'https://conda.anaconda.org/conda-forge/noarch/repodata.json'
    'PyPI (휠)'                   = 'https://pypi.org/simple/pip/'
    'PyPI 파일 서버'              = 'https://files.pythonhosted.org/'
    'PyTorch (CUDA 휠)'           = "$torch/torch/"
    'GitHub (서버용 micromamba)'  = 'https://github.com/'
}
foreach ($k in $sites.Keys) {
    Test-Site $k $sites[$k] | Out-Null
}
if ($script:Fails) {
    Stop-Run '인터넷 접속이 안 되는 곳이 있다' ('위 [문제] 줄 아래의 curl 오류와 설명을 본다. 브라우저로는 열리면 ' +
        '사내 IT에 프록시 주소를 물어 $env:HTTPS_PROXY = "http://프록시주소:포트" 를 넣고 다시 실행한다. ' +
        '그래도 안 되면 담당자에게 build.log 를 보내 준다.')
}

# ------------------------------------------------------------------ 2. 기초 프로그램 목록
Write-Step 2 $T '기초 프로그램 버전 정하기 (B200 서버 linux-64 기준)'
$env:CONDA_OVERRIDE_GLIBC = $Glibc
$env:CONDA_OVERRIDE_CUDA  = $Cuda
$tools = (Get-Content (Join-Path $root 'lists\tools.txt')) -split '\s+' | Where-Object { $_ }
Write-Info "목록 $($tools.Count)개를 conda-forge 에서 푸는 중 (1~3분)"
# 지난 실행에서 망 문제로 잘못 받은 목록 캐시를 쓰지 않도록 매번 지운다
$mmroot = Join-Path $out 'mmroot'
Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $mmroot
# --no-rc : 이 PC의 .condarc/.mambarc(회사 미러, offline 등)를 무시한다
# 채널은 전체 주소로 적어 channel_alias 설정에도 흔들리지 않게 한다
$cf = 'https://conda.anaconda.org/conda-forge'
$json = & $mm create --no-rc -n plan -r $mmroot --platform linux-64 -c $cf `
    --override-channels --dry-run --json -y @tools | Out-String
if ($LASTEXITCODE -ne 0) {
    Write-Host $json
    if ($json -match 'does not exist') {
        Write-Bad 'conda-forge 의 linux-64 목록을 받지 못해 모든 패키지가 "없다" 로 나왔다'
        $r = Invoke-Probe "$cf/linux-64/repodata.json"
        if ($r.Code -eq 0) { Write-Info '    curl 로는 목록 주소에 접속된다. micromamba 만 막힌 경우다(프록시나 인증서).' }
        else { Write-Info "    curl 로도 목록 주소에 접속 안 된다: 오류 $($r.Code) $($r.Msg)" }
        Write-Info "    micromamba 버전: $(& $mm --version)"
        Stop-Run 'micromamba 가 conda-forge 목록을 받지 못했다' ('위 [문제] 아래 줄과, 이 창의 빨간/노란 경고(Could not, SSL, proxy 등)를 ' +
            '담당자에게 보내 준다. 회사 프록시 망이면 $env:HTTPS_PROXY = "http://프록시주소:포트" 를 넣고 다시 실행한다.')
    }
    Stop-Run 'micromamba 가 목록을 풀지 못했다' '위 메시지에 나온 패키지 이름이 conda-forge 에 있는지 본다. 인터넷이 끊겼으면 다시 실행한다.'
}
try { $plan = $json | ConvertFrom-Json } catch { Write-Host $json; Stop-Run 'micromamba 결과를 읽지 못했다' 'build.log 를 담당자에게 보내 준다.' }
$pkgs = @($plan.actions.LINK | Where-Object { $_.url })
if (-not $pkgs.Count) { $pkgs = @($plan.actions.FETCH | Where-Object { $_.url }) }
if (-not $pkgs.Count) { Write-Host $json; Stop-Run 'micromamba 결과에 받을 패키지가 없다' 'build.log 를 담당자에게 보내 준다.' }
Write-Lf (Join-Path $out 'explicit.txt') (@('@EXPLICIT') + ($pkgs | ForEach-Object {
    if ($_.md5) { "$($_.url)#$($_.md5)" } else { $_.url } }))
$py = $pkgs | Where-Object { $_.name -eq 'python' } | Select-Object -First 1
Write-Ok "패키지 $($pkgs.Count)개로 정함 (python $($py.version))"

# ------------------------------------------------------------------ 3. 기초 프로그램 받기
Write-Step 3 $T '기초 프로그램 받기'
$pdir = Join-Path $out 'pkgs'
New-Item -ItemType Directory -Force $pdir | Out-Null
$n = 0
foreach ($p in $pkgs) {
    $n++
    $fn = if ($p.fn) { $p.fn } else { Split-Path -Leaf $p.url }
    Write-Progress -Activity '기초 프로그램 받기' -Status "$n/$($pkgs.Count) $fn" -PercentComplete (100 * $n / $pkgs.Count)
    if (-not (Get-File $p.url (Join-Path $pdir $fn) $p.md5 $MaxTries)) {
        Stop-Run "받지 못했다: $fn" '인터넷을 확인하고 다시 실행한다. 받은 것은 건너뛴다.'
    }
}
Write-Progress -Activity '기초 프로그램 받기' -Completed
# 지난 실행에서 남은, 이번 목록에 없는 파일은 지운다
$want = @($pkgs | ForEach-Object { if ($_.fn) { $_.fn } else { Split-Path -Leaf $_.url } })
Get-ChildItem $pdir -File | Where-Object { $want -notcontains $_.Name } | Remove-Item -Force
Write-Ok "$($pkgs.Count)개 받음, 체크섬 확인함"
Remove-Item -Force -ErrorAction SilentlyContinue (Join-Path $out 'micromamba')   # 새 버전에 이어붙지 않게 매번 새로
if (-not (Get-File 'https://github.com/mamba-org/micromamba-releases/releases/latest/download/micromamba-linux-64' `
        (Join-Path $out 'micromamba') $null $MaxTries)) {
    Stop-Run '서버용 micromamba 를 받지 못했다' 'github.com 접속을 확인하고 다시 실행한다.'
}
Write-Ok '서버용 micromamba 받음'

# ------------------------------------------------------------------ 4. 휠 버전
Write-Step 4 $T "공용 휠 버전 정하기 (Python 3.12, $ml)"
$lock = Join-Path $out 'lock.txt'
& $uv pip compile (Join-Path $root 'lists\wheels.txt') -o $lock --generate-hashes --no-header `
    --python-version 3.12 --python-platform "x86_64-$ml" `
    --extra-index-url $torch --index-strategy unsafe-best-match
if ($LASTEXITCODE -ne 0) {
    Stop-Run 'uv pip compile 실패' '위 빨간 메시지에 나온 패키지를 본다. 인터넷이 끊겼으면 다시 실행한다. 모르겠으면 build.log 를 담당자에게 보내 준다.'
}
$pins = @(Get-Content $lock | Where-Object { $_ -match '^[A-Za-z0-9].*==' })
$torchPin = ($pins | Where-Object { $_ -match '^torch==' }) -replace ' .*', ''
Write-Ok "휠 $($pins.Count)개로 정함 ($torchPin)"

# ------------------------------------------------------------------ 5. 휠 받기
Write-Step 5 $T "공용 휠 받기 ($($pins.Count)개, 수 GB)"
$wdir = Join-Path $out 'wheels'
New-Item -ItemType Directory -Force $wdir | Out-Null
# 지난 실행(예: 레드햇용 glibc 2.34 기준)에서 남은, 이번 lock.txt 에 없는 휠은 지운다.
# 잘못 지운 것이 있어도 바로 아래 pip download 가 다시 받는다
$keep = @{}
foreach ($p in $pins) {
    $nv = ($p -replace ' .*', '') -split '=='
    $keep["$($nv[0].ToLower() -replace '[-_.]+', '_')-$($nv[1].ToLower())"] = 1
}
$old = @(Get-ChildItem $wdir -File | Where-Object {
    $n = [uri]::UnescapeDataString($_.Name).ToLower()
    if ($n -like '*.whl') { $f = $n.Split('-'); $k = "$($f[0] -replace '[-_.]+', '_')-$($f[1])" }
    else {
        $b = $n -replace '\.(tar\.gz|zip)$', ''; $i = $b.LastIndexOf('-')
        $k = if ($i -gt 0) { "$($b.Substring(0, $i) -replace '[-_.]+', '_')-$($b.Substring($i + 1))" } else { '' }
    }
    $k -and -not $keep.ContainsKey($k)
})
if ($old.Count) { $old | Remove-Item -Force; Write-Info "이번 목록에 없는 예전 휠 $($old.Count)개 지움" }
$ok = $false
$stall = 0
while ($stall -lt $MaxTries) {
    # 이미 받은 파일은 건너뛴다. 해시가 안 맞으면 다시 받는다.
    $before = Get-Size $wdir
    & $uv tool run --from pip pip download -r $lock --no-deps -d $wdir --progress-bar on `
        @plats --python-version 3.12 --implementation cp `
        --extra-index-url $torch --retries 10 --timeout 60
    if ($LASTEXITCODE -eq 0) { $ok = $true; break }
    $stall = Step-Retry $stall $before (Get-Size $wdir) $MaxTries 'pip download'
}
if (-not $ok) { Stop-Run '휠을 다 받지 못했다' '인터넷을 확인하고 다시 실행한다. 받은 것은 건너뛴다.' }
$wcount = @(Get-ChildItem $wdir -File).Count
if ($wcount -lt $pins.Count) { Stop-Run "휠이 $wcount 개뿐이다($($pins.Count)개 필요)" '다시 실행한다.' }
$sdist = @(Get-ChildItem $wdir -File | Where-Object { $_.Name -notlike '*.whl' })
if ($sdist.Count) {
    # 휠(미리 만든 설치 파일)이 PyPI에 없어 소스 묶음으로 받은 것. 예: antlr4-python3-runtime(hydra-core, omegaconf 가 씀)
    # 순수 Python 이면 B200 서버가 설치할 때 공용 휠의 setuptools 로 몇 초 만에 휠을 만들어 인터넷 없이 설치된다
    Write-Info "휠 없이 소스로 받은 것 $($sdist.Count)개: $($sdist.Name -join ', ')"
    Write-Info '    PyPI에 휠이 없는 패키지다. B200 서버가 설치할 때 직접 만들어 설치하니 그대로 두면 된다.'
}
Write-Ok "$wcount 개 받음, 해시 확인함"

# ------------------------------------------------------------------ 6. 묶기 + 검사
Write-Step 6 $T '묶기와 검사'
New-Item -ItemType Directory -Force (Join-Path $out 'bin') | Out-Null
foreach ($f in $scripts) {
    $sh = [IO.File]::ReadAllText((Join-Path $root "server\$f")) -replace "`r", ''
    [IO.File]::WriteAllText((Join-Path $out $f), $sh, (New-Object Text.UTF8Encoding $false))
}
Write-Lf (Join-Path $out 'pack_info.txt') @(
    "made=$(Get-Date -Format 'yyyy-MM-dd HH:mm')", "glibc=$Glibc", "cuda=$Cuda",
    "tools=$($pkgs.Count)", "wheels=$($pins.Count)", "torch=$torchPin")

Write-Info '체크섬 목록 만드는 중'
$files = @('micromamba', 'explicit.txt', 'lock.txt', 'pack_info.txt') + $scripts +
    @(Get-ChildItem $pdir -File | ForEach-Object { "pkgs/$($_.Name)" }) +
    @(Get-ChildItem $wdir -File | ForEach-Object { "wheels/$($_.Name)" })
Write-Lf (Join-Path $out 'MANIFEST.sha256') ($files | ForEach-Object {
    "$((Get-FileHash (Join-Path $out $_) -Algorithm SHA256).Hash.ToLower())  $_" })

Write-Info 'tar 로 묶는 중'
$tar = Join-Path $out 'b200-pack.tar'
Remove-Item -Force -ErrorAction SilentlyContinue $tar
Push-Location $out
& tar.exe -cf b200-pack.tar MANIFEST.sha256 micromamba explicit.txt lock.txt pack_info.txt @scripts pkgs wheels
$code = $LASTEXITCODE
$listed = @(& tar.exe -tf b200-pack.tar | Where-Object { $_ -notmatch '/$' }).Count
Pop-Location
if ($code -ne 0) { Stop-Run 'tar 로 묶지 못했다' '남은 공간을 확인하고 다시 실행한다.' }
if ($listed -ne $files.Count + 1) { Stop-Run "묶음 안 파일 수가 다르다($listed / $($files.Count + 1))" '다시 실행한다.' }
Write-Ok "묶음 안 파일 $listed 개 확인"

$size = Format-Size (Get-Item $tar).Length
Allow-Sleep
Write-Host ''
Write-Host '############################ 완료 ############################' -ForegroundColor Green
Write-Host " 기초 프로그램 $($pkgs.Count)개, 휠 $($pins.Count)개 ($torchPin)"
Write-Host ''
Write-Host ' 접근 PC에서 할 일은 끝. B200 서버에 올릴 것 (이 파일 하나):' -ForegroundColor Green
Write-Host "   $tar  ($size)"
Write-Host ''
Write-Host ' 회사 프로그램으로 B200 서버 /app/inbox 에 올린 뒤, B200 서버 터미널에서:' -ForegroundColor Green
Write-Host '   cd /app/inbox && tar xf b200-pack.tar && bash pack_install.sh /app/shared'
Write-Host '##############################################################' -ForegroundColor Green
Stop-Transcript | Out-Null
