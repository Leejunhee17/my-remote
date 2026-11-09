<#
[접근 PC] 접근 PC 를 한 번에 점검한다(GPU 서버의 check.sh 와 짝). 데이터셋·모델은 받지 않고 아무것도 고치지 않는다(사이트마다 앞 1 KB 만 요청한다).
보는 것: 윈도우·프로그램(tar, git, uv), 저장소(git), .env, 프록시, 시계, 받기 스크립트가 쓰는 사이트 전부(.NET 으로 실제 파일 앞부분까지),
받기 도구 aria2c 로 작은 파일 몇 개 받아 보기(임시 폴더에 받고 지운다), Hugging Face 토큰, WildScenes 링크, 디스크, 지금까지 받은 것과 지난번 멈춘 이유.
결과를 reports\pc_check_공유용_<날짜>.txt 에 남기고, 물어본 뒤 git 으로 올린다(담당자가 그 파일을 읽는다).
계정·PC 이름, 프록시 주소, 사내 IP, 토큰·키·서명은 가려서 적는다.

  powershell -ExecutionPolicy Bypass -File .\pc\check.ps1
  powershell -ExecutionPolicy Bypass -File .\pc\check.ps1 -NoPush     # 파일만 만들고 git 으로 올리지 않는다
#>
param(
    [switch]$NoPush
)
$here = $PSScriptRoot
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $here 'gpu_common.ps1')
$stamp = Get-Date -Format 'yyyyMMdd-HHmm'
$outFile = Join-Path $root "reports\pc_check_공유용_$stamp.txt"

# 화면에 찍는 줄을 모두 모아 둔다. gpu_common 의 Write-* 를 바꿔 끼워 Test-Site 가 찍는 줄도 모인다
$script:Lines = New-Object System.Collections.Generic.List[string]
$script:Todo  = New-Object System.Collections.Generic.List[string]
function Out-Line([string]$s, $color) {
    $script:Lines.Add($s)
    if ($color) { Write-Host $s -ForegroundColor $color } else { Write-Host $s }
}
function Write-Head($t)   { Out-Line ''; Out-Line "== $t ==" Cyan }
function Write-Ok($msg)   { Out-Line "  [정상] $msg" Green }
function Write-Warn($msg) { Out-Line "  [주의] $msg" Yellow }
function Write-Info($msg) { Out-Line "  $msg" }
function Write-Bad($msg, $fix) {
    Out-Line "  [문제] $msg" Red
    $script:Fails++
    $script:Todo.Add($(if ($fix) { $fix } else { $msg }))
}

# 점검은 빨리 끝나게 기다리는 시간을 줄인다(받기 스크립트는 40초)
function Invoke-Probe($url) {
    $r = Invoke-Http $url -Range '0-0' -Max 0 -TimeoutSec 20
    return [pscustomobject]@{ Code = $(if ($r.Ok) { 0 } else { 1 }); Kind = $r.Kind; Msg = $r.Error; Status = $r.Status; Headers = $r.Headers }
}
# 실제 받을 파일의 앞 1 KB 를 .NET(받기 스크립트의 크기 확인과 같은 방법)으로 요청한다
function Show-File($label, $url) {
    $r = Invoke-Http $url -Range '0-1023' -Max 1024 -TimeoutSec 30
    # 실제 파일을 다른 주소(CDN 등)에서 내려 주면 그 주소도 보여 준다(사내 IT에 허용을 요청할 주소)
    #   받기가 막혀도 보이게, 넘겨주는 주소(location)를 따로 물어본다
    $loc = [string](Invoke-Http $url -NoRedirect -Max 0 -TimeoutSec 20).Headers['location']
    if ($loc -match '^https?://([^/:?]+)' -and $Matches[1] -ne ([uri]$url).Host) { Write-Info "    실제 파일은 $($Matches[1]) 에서 내려와요" }
    if ($r.Ok -and $r.Status -lt 300) { Write-Ok "$($label): 실제 파일 앞부분이 받아져요 (HTTP $($r.Status))"; return }
    if ($r.Ok) {
        $why = switch ($r.Status) { 401 { '인증이 필요해요(401)' } 403 { '거절됐어요(403)' } 404 { '없는 주소예요(404). 사이트에서 파일을 옮겼을 수 있어요' } 407 { '프록시가 인증을 요구해요(407)' } default { "HTTP $($r.Status)" } }
        Write-Bad "$($label): 실제 파일 앞부분이 안 받아져요 - $why" "$($label): $why"
        $b = (($r.Body -replace '<[^>]+>', ' ') -replace '\s+', ' ').Trim()
        if ($b) { Write-Info "    응답 앞부분: $($b.Substring(0, [math]::Min(200, $b.Length)))" }
    } else {
        Write-Bad "$($label): 실제 파일 앞부분이 안 받아져요 ($($r.Kind))" "$($label) 파일 받기가 막혀 있어요. 사내 IT에 그 주소 허용을 요청하세요"
        Write-Info "    오류: $($r.Error)"
        $hint = Get-NetHint $r.Kind
        if ($hint) { Write-Info "    $hint" }
    }
}
# 받기 도구 aria2c 로 작은 파일 하나를 끝까지 받아 본다(임시 폴더에 받고 지운다). 실패하면 aria2c 기록의 오류 줄을 남긴다
function Test-Aria2File($label, $url) {
    $d = Join-Path ([IO.Path]::GetTempPath()) "gpu_check_$stamp"
    $f = Join-Path $d 'f'; $lf = Join-Path $d 'aria2.log'
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $d
    try {
        $code = Invoke-Aria2 $url $f @("--log=$lf", '--log-level=notice')
        $sz = if (Test-Path $f) { (Get-Item $f).Length } else { 0 }
        if ($code -eq 0) { Write-Ok "aria2c 로 받아져요: $label ($(Format-Size $sz))"; return }
        $why = switch ($code) { 3 { '없는 주소(404)' } 22 { '거절(403 등)' } 24 { '인증 실패(401)' } 99 { 'aria2c 없음' } default { '네트워크 문제' } }
        Write-Bad "aria2c 로 안 받아져요: $label (aria2c $code, $why)" "aria2c(받기 도구)로 $label 이 안 받아져요(aria2c $code). 그 아래 오류 줄을 보세요"
        if (Test-Path $lf) {
            [IO.File]::ReadAllLines($lf) | Where-Object { $_ -match '(?i)errorCode|status=|exception|SSL|TLS|certificate|ERROR' } | Select-Object -First 4 |
                ForEach-Object { Write-Info "    aria2c: $($_.Trim())" }
        }
    } finally { Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $d }
}
function Get-Ver($exe, [string[]]$a) {
    try { return ((& $exe @a 2>&1 | Select-Object -First 1) | Out-String).Trim() } catch { return '' }
}

Out-Line "접근 PC 점검  $(Get-Date -Format 'yyyy-MM-dd HH:mm')"
Write-Host '  사이트마다 앞부분만 요청하고, 작은 파일 몇 개만 임시 폴더에 받아 봐요. 막힌 사이트가 많으면 몇 분 걸려요.'

# ------------------------------------------------------------------ 윈도우·프로그램
Write-Head '윈도우·프로그램'
Write-Info "윈도우: $([Environment]::OSVersion.VersionString), PowerShell $($PSVersionTable.PSVersion), 64비트 $([Environment]::Is64BitOperatingSystem)"
Write-Info "저장소 위치: $root (경로 길이 $($root.Length)자)"
$lp = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' -ErrorAction SilentlyContinue).LongPathsEnabled
if ($lp -eq 1) { Write-Ok '긴 경로(260자 넘음)를 쓸 수 있어요' }
elseif ($root.Length -gt 20) { Write-Warn '긴 경로 설정이 꺼져 있고 저장소 경로가 길어요. 데이터셋 파일 경로가 260자를 넘으면 못 만들어요. 저장소를 D:\gpu 처럼 짧은 곳에 두세요' }
else { Write-Info '긴 경로 설정은 꺼져 있어요(저장소 경로가 짧아서 괜찮아요)' }
foreach ($e in @('tar.exe')) {
    $c = Get-Command $e -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($c) { Write-Ok "$($e): $(Get-Ver $c.Source @('--version'))" }
    else { Write-Bad "없는 프로그램: $e" '윈도우 10 1803 이후에는 tar.exe 가 기본으로 들어 있어요. 윈도우를 업데이트하세요' }
}
$git = Find-Exe 'git' $root
if ($git) { Write-Ok "git: $(Get-Ver $git @('--version'))" } else { Write-Bad 'git 이 없어요' 'Git for Windows 를 설치하고 PowerShell 창을 새로 여세요' }
$uv = Find-Exe 'uv' $root
if ($uv) { Write-Ok "uv: $(Get-Ver $uv @('--version'))" } else { Write-Bad 'uv가 없어요(데이터셋·모델 받기에 필요해요)' "uv를 설치하고 PowerShell 창을 새로 여세요. 또는 uv.exe 를 저장소 맨 위에 넣으세요" }
$aria = Join-Path $root 'tools\aria2\aria2c.exe'
if (Test-Path $aria) {
    if ((Get-FileHash $aria -Algorithm SHA256).Hash -eq $Aria2ExeSha.ToUpper()) { Write-Ok 'aria2c: tools\aria2\aria2c.exe (지문 맞음)' }
    else { Write-Warn 'aria2c: tools\aria2\aria2c.exe 의 지문이 달라요. 지우면 다음 받기 때 새로 받아요' }
} else { Write-Info 'aria2c: 아직 없어요(아래 인터넷 점검에서 준비해요. 받기 스크립트도 처음에 이렇게 해요)' }

# ------------------------------------------------------------------ 저장소(git)
Write-Head '저장소(git)'
if ($git) {
    Push-Location $root
    try {
        $br = (& $git rev-parse --abbrev-ref HEAD 2>$null)
        Write-Info "브랜치: $br, 마지막 커밋: $((& $git log -1 '--format=%h %cd %s' '--date=format:%Y-%m-%d %H:%M' 2>$null))"
        $hp = (& $git config core.hooksPath 2>$null)
        if ($hp -eq '.githooks') { Write-Ok '커밋 검사가 켜져 있어요(core.hooksPath=.githooks)' }
        else { Write-Bad '커밋 검사가 꺼져 있어요' '저장소 맨 위에서 git config core.hooksPath .githooks 를 한 번 실행하세요' }
        $bl = (& $git rev-parse --git-path info/gpu-blocklist.txt 2>$null)
        if ($bl -and (Test-Path $bl) -and (Get-Item $bl).Length -gt 0) { Write-Ok "가릴 낱말 목록: $(@(Get-Content $bl | Where-Object { $_.Trim() -and -not $_.Trim().StartsWith('#') }).Count)개" }
        else { Write-Warn '가릴 낱말 목록(.git\info\gpu-blocklist.txt)이 없어요. 서버·계정 이름이 커밋에 들어가도 못 막아요(docs\4_네트워크.md 의 "결과 가져오기")' }
        if (-not (& $git config user.name) -or -not (& $git config user.email)) { Write-Warn 'git 사용자 이름·메일이 없어서 커밋(결과 올리기)이 안 될 수 있어요: git config --global user.name "이름", user.email "메일"' }
        $dirty = @(& $git status --porcelain 2>$null | Where-Object { $_ -notmatch '^\?\? reports/' })
        if ($dirty.Count) { Write-Warn "고치고 커밋하지 않은 파일이 $($dirty.Count)개 있어요: $((@($dirty | Select-Object -First 5 | ForEach-Object { $_.Substring(3) })) -join ', ')" }
        $fo = & $git fetch -q origin 2>&1 | Out-String
        if ($LASTEXITCODE -eq 0) {
            Write-Ok 'git 으로 GitHub 에 접속돼요(결과를 올릴 수 있어요)'
            $behind = (& $git rev-list --count 'HEAD..@{u}' 2>$null)
            if ($behind -and [int]$behind -gt 0) { Write-Bad "저장소가 최신이 아니에요(새 커밋 $($behind)개)" '저장소 맨 위에서 git pull 을 하세요' }
            elseif ($behind) { Write-Ok '저장소가 최신이에요' }
        } else {
            Write-Bad 'git 으로 GitHub 에 접속되지 않아요(git pull, 결과 올리기가 안 돼요)' 'git 이 GitHub 에 접속되지 않아요. 아래 git 오류를 보세요(회사 프록시면 git config --global http.proxy, 인증서 폐기 확인이면 git config --global http.schannelCheckRevoke false)'
            $fo = ($fo -replace '\s+', ' ').Trim()
            Write-Info "    $($fo.Substring(0, [math]::Min(300, $fo.Length)))"
        }
    } finally { Pop-Location }
}

# ------------------------------------------------------------------ 접근 PC 설정(.env)
Write-Head '접근 PC 설정(.env)'
$envFile = Join-Path $root '.env'
$known = @([IO.File]::ReadAllLines((Join-Path $root '.env.example')) | ForEach-Object { if ($_ -match '^([A-Za-z_][A-Za-z0-9_]*)=') { $Matches[1] } })
if (Test-Path $envFile) {
    $names = @([IO.File]::ReadAllLines($envFile) | ForEach-Object { if ($_.Trim() -match '^(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$' -and $Matches[2].Trim()) { $Matches[1] } })
    Write-Ok ".env 가 있어요. 값을 적은 것: $(if ($names.Count) { $names -join ', ' } else { '없음' }) (값은 적지 않아요)"
    $odd = @($names | Where-Object { $known -notcontains $_ -and $_ -notmatch '^WILDSCENES_(S3_|ACCESS_KEY|SECRET_KEY)' })
    if ($odd.Count) { Write-Warn ".env 에 .env.example 에 없는 이름이 있어요(오타일 수 있어요): $($odd -join ', ')" }
} else {
    Write-Warn '.env 가 없어요. 토큰 같은 값은 실행 중에 물어봐요. 미리 적으려면: copy .env.example .env 한 뒤 notepad .env'
}
if ($env:GPU_RUN) {
    $bad = @($env:GPU_RUN -split '[,\s]+' | Where-Object { $_ -and @('setup', 'pkgs', 'docker', 'datasets', 'models') -notcontains $_.ToLower() })
    if ($bad.Count) { Write-Bad "GPU_RUN 에 모르는 작업이 있어요: $($bad -join ', ')" '.env 의 GPU_RUN 에는 setup, pkgs, docker, datasets, models 만 적어요' }
    else { Write-Ok "GPU_RUN: $env:GPU_RUN" }
}
if ($env:HF_TOKEN) {
    if ($env:HF_TOKEN.Trim() -match '^hf_[A-Za-z0-9]{30,}$') { Write-Ok 'HF_TOKEN 은 hf_ 로 시작하는 토큰 모양이에요' }
    else { Write-Bad 'HF_TOKEN 이 토큰 모양(hf_ 로 시작)이 아니에요' '.env 의 HF_TOKEN 을 https://huggingface.co/settings/tokens 에서 만든 Read 토큰으로 고치세요' }
} else { Write-Info 'HF_TOKEN 은 비어 있어요(승인이 필요한 모델은 받을 때 물어봐요)' }
$oldWs = @('WILDSCENES_S3_SERVER', 'WILDSCENES_S3_DIR', 'WILDSCENES_ACCESS_KEY', 'WILDSCENES_SECRET_KEY' | Where-Object { [Environment]::GetEnvironmentVariable($_) })
if ($oldWs.Count) { Write-Warn "예전 WildScenes S3 방식 설정이 남아 있어요(이제 안 써요. 키가 남지 않게 .env 에서 지우세요): $($oldWs -join ', ')" }
if (-not $env:WILDSCENES_LINKS) { Write-Info 'WILDSCENES_LINKS 는 비어 있어요(WildScenes 는 받지 않아요. docs\5_데이터셋.md 의 "WildScenes 링크 목록으로 받기")' }
$links = if ($env:WILDSCENES_LINKS) { [Environment]::ExpandEnvironmentVariables($env:WILDSCENES_LINKS) } else { '' }
$wsUrl = $null
if ($links) {
    if (-not (Test-Path -LiteralPath $links)) { Write-Bad 'WILDSCENES_LINKS 의 파일이 없어요' '.env 의 WILDSCENES_LINKS 를 포털에서 받은 링크 목록 .txt 의 경로로 고치세요' }
    else {
        $all = @([IO.File]::ReadAllLines($links) | ForEach-Object { [regex]::Match($_, 'https://\S+').Value.Trim('"') } | Where-Object { $_ })
        Write-Ok "WildScenes 링크 목록: 링크 $($all.Count)개, 파일 만든 시각 $((Get-Item -LiteralPath $links).LastWriteTime.ToString('yyyy-MM-dd HH:mm'))"
        $wsUrl = $all | Where-Object { [uri]::UnescapeDataString(($_ -split '\?')[0]) -match '(?i)/WildScenes_?2d/' } | Select-Object -First 1
        if (-not $wsUrl -and $all.Count) { $wsUrl = $all[0] }
        if ($wsUrl -match 'X-Amz-Date=(\d{8}T\d{6})Z' ) {
            $t0 = [DateTime]::ParseExact($Matches[1], 'yyyyMMddTHHmmss', [Globalization.CultureInfo]::InvariantCulture)
            $sec = if ($wsUrl -match 'X-Amz-Expires=(\d+)') { [int]$Matches[1] } else { 0 }
            if ($sec) {
                $left = ($t0.AddSeconds($sec) - [DateTime]::UtcNow).TotalHours
                $until = $t0.AddSeconds($sec).ToLocalTime().ToString('yyyy-MM-dd HH:mm')
                if ($left -le 0) { Write-Bad "WildScenes 링크가 만료됐어요($until)" 'WildScenes 포털에서 링크 목록을 새로 받아 WILDSCENES_LINKS 파일을 바꾸세요' }
                elseif ($left -lt 6) { Write-Warn "WildScenes 링크가 곧 만료돼요($until 까지, $([math]::Round($left, 1))시간 남음)" }
                else { Write-Ok "WildScenes 링크는 $until 까지 유효해요($([math]::Round($left))시간 남음)" }
            }
        }
    }
}

# ------------------------------------------------------------------ 프록시·망
Write-Head '프록시·망'
$wp = Get-WindowsProxy
$pac = (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction SilentlyContinue).AutoConfigURL
Write-Info ".env·창의 HTTPS_PROXY: $(Proxy-Label $env:HTTPS_PROXY), HTTP_PROXY: $(Proxy-Label $env:HTTP_PROXY)"
Write-Info "윈도우 프록시 설정: $(Proxy-Label $wp)"
Write-Info "자동 프록시 설정(PAC): $(if ($pac) { '있음' } else { '없음' })"
Write-Info '접속 확인은 .NET(브라우저처럼 위 프록시와 윈도우 로그인), 받기는 aria2c(.env 의 프록시, 없으면 브라우저 프록시. 윈도우 로그인 인증은 못 해요)로 해요'
foreach ($v in 'NO_PROXY', 'SSL_CERT_FILE', 'REQUESTS_CA_BUNDLE') { if ([Environment]::GetEnvironmentVariable($v)) { Write-Info "환경 변수 $v 가 있어요(uv·Python 접속에 영향을 줘요)" } }

# ------------------------------------------------------------------ 인터넷
# 받기 스크립트(setup·pkgs·docker·datasets·models)가 쓰는 주소. 받기 스크립트의 주소를 바꾸면 여기도 같이 고친다.
# Url: 첫 화면(받기 스크립트의 점검과 같다), File: 실제 받을 파일(앞 1 KB 만)
$Sites = @(
    @{ Use = '공통(uv 의 도구)';              Name = 'PyPI';                          Url = 'https://pypi.org/simple/pip/' }
    @{ Use = '공통(uv 의 도구)';              Name = 'PyPI 파일 서버';                Url = 'https://files.pythonhosted.org/' }
    @{ Use = '공통(uv 의 Python, aria2c), 도커(buildx·compose), 모델 코드'; Name = 'GitHub'; Url = 'https://github.com/'; File = $Aria2Url }
    @{ Use = '기초 프로그램·도커';           Name = 'Ubuntu 패키지 저장소';          Url = 'http://archive.ubuntu.com/ubuntu/dists/noble/Release' }
    @{ Use = '도커';                         Name = 'Docker 배포 서버';              Url = 'https://download.docker.com/linux/static/stable/x86_64/' }
    @{ Use = '도커';                         Name = 'NVIDIA 패키지 저장소';          Url = 'https://nvidia.github.io/libnvidia-container/stable/deb/amd64/Packages' }
    @{ Use = '모델';                         Name = 'Hugging Face';                  Url = 'https://huggingface.co/'; File = 'https://huggingface.co/openai-community/gpt2/resolve/main/model.safetensors' }
    @{ Use = '모델(큰 파일)';                Name = 'Hugging Face 파일 서버(xet)';   Url = 'https://cas-bridge.xethub.hf.co/' }
    @{ Use = '모델(큰 파일)';                Name = 'Hugging Face 파일 서버(lfs)';   Url = 'https://cdn-lfs.hf.co/' }
    @{ Use = '데이터셋 GOOSE';               Name = 'goose-dataset.de';              Url = 'https://goose-dataset.de/'; File = 'https://goose-dataset.de/storage/goose_2d_val.zip' }
    @{ Use = '데이터셋 RUGD';                Name = 'rugd.vision';                   Url = 'http://rugd.vision/'; File = 'http://rugd.vision/data/RUGD_annotations.zip' }
    @{ Use = '데이터셋 Freiburg Forest';     Name = 'deepscene.cs.uni-freiburg.de';  Url = 'https://deepscene.cs.uni-freiburg.de/'; File = 'https://deepscene.cs.uni-freiburg.de/static/datasets/freiburg_forest_annotated.tar.gz.part-aa' }
    @{ Use = '데이터셋 YCOR';                Name = 'Box(cmu.app.box.com)';          Url = 'https://cmu.app.box.com/'; File = 'https://cmu.app.box.com/index.php?rm=box_download_shared_file&shared_name=3fngoljhcwhqf2z5cbepufh331qtesxt&file_id=f_771170167866' }
    @{ Use = '데이터셋 CaSSeD';              Name = 'www.cavs.msstate.edu';          Url = 'https://www.cavs.msstate.edu/'; File = 'https://www.cavs.msstate.edu/resources/downloads/CaSSeD/CaSSeD.tar.gz' }
    @{ Use = '데이터셋 RELLIS-3D·TAS500·GO'; Name = 'Google Drive';                  Url = 'https://drive.google.com/' }
    @{ Use = '데이터셋 RELLIS-3D·TAS500·GO'; Name = 'Google Drive 파일 서버';        Url = 'https://drive.usercontent.google.com/' }
    @{ Use = '데이터셋 ORAD-3D';             Name = 'ModelScope';                    Url = 'https://www.modelscope.cn/'; File = 'https://www.modelscope.cn/api/v1/datasets/Georgehhhh/ORAD-3D/repo?Source=SDK&Revision=master&FilePath=training_zip/c2021_0228_1819.zip' }
    @{ Use = '데이터셋 WildScenes(포털)';    Name = 'CSIRO 포털';                    Url = 'https://data.csiro.au/' }
    @{ Use = '데이터셋 WildScenes(링크 목록의 파일)'; Name = 'CSIRO S3 저장소';         Url = 'https://s3.data.csiro.au/' }
)
Write-Head '인터넷(받기 스크립트가 쓰는 사이트)'
$siteOk = [ordered]@{}
$proxies = New-Object System.Collections.Generic.List[string]
foreach ($s in $Sites) {
    $bp = Get-BrowserProxy $s.Url
    if ($bp) { $proxies.Add($bp) }
    $f0 = $script:Fails
    $ok = Test-Site $s.Name $s.Url
    Write-Info "    쓰는 곳: $($s.Use)$(if ($bp -and $bp -ne $wp) { ', 브라우저는 이 주소에 다른 프록시를 써요(PAC)' })"
    if ($ok -and $s.File) { Show-File "$($s.Name) 파일" $s.File }
    $siteOk[$s.Name] = ($script:Fails -eq $f0)
}
if ($wsUrl) { Show-File 'WildScenes 링크 목록의 파일' $wsUrl }
if ($env:HF_TOKEN -and $siteOk['Hugging Face']) {
    $r = Invoke-Http 'https://huggingface.co/api/whoami-v2' -Max 0 -TimeoutSec 30 -Headers @{ Authorization = "Bearer $($env:HF_TOKEN.Trim())" }
    if ($r.Ok -and $r.Status -eq 200) { Write-Ok 'HF_TOKEN 으로 Hugging Face 에 로그인돼요' }
    elseif ($r.Status -eq 401) { Write-Bad 'HF_TOKEN 이 맞지 않아요(HTTP 401)' 'HF_TOKEN 이 틀렸거나 지워졌어요. https://huggingface.co/settings/tokens 에서 Read 토큰을 새로 만들어 .env 에 적으세요' }
    else { Write-Warn "HF_TOKEN 확인이 안 됐어요(HTTP $($r.Status) $($r.Kind))" }
}

# 받기 도구 aria2c: 받기 스크립트는 모두 aria2c 로 받는다. 작은 파일로 http·https·GitHub 넘겨주기·Hugging Face 를 받아 본다
Write-Head '받기 도구(aria2c)로 작은 파일 받아 보기'
if (Test-Aria2) {
    Test-Aria2File 'Ubuntu 저장소 목록(http)' 'http://archive.ubuntu.com/ubuntu/dists/noble/Release'
    Test-Aria2File 'Hugging Face 작은 파일(https)' 'https://huggingface.co/openai-community/gpt2/resolve/main/config.json'
    Test-Aria2File 'GitHub 배포 파일(넘겨주기)' $Aria2Url
    if ($wsUrl) {
        $wsSize = Get-RemoteSize $wsUrl
        if ($wsSize -and $wsSize -le 20MB) { Test-Aria2File 'WildScenes 링크 목록의 파일' $wsUrl }
        else { Write-Info 'WildScenes 링크 목록의 첫 파일은 크기를 몰라서(또는 커서) aria2c 로 받아 보지 않았어요. 자세히: .\pc\wildscenes_check.ps1' }
    }
    $ap = @(Get-Aria2Proxy 'https://huggingface.co/')
    Write-Info "aria2c 에 붙는 프록시: $(if ($ap.Count) { Proxy-Label ($ap[0] -replace '^--all-proxy=', '') } else { '없음(바로 접속)' })"
}

# 시계: 많이 틀리면 WildScenes(S3) 서명과 인증서 확인이 실패한다
Write-Head '시계'
$tu = 'https://huggingface.co/'
$tr = Invoke-Http $tu -Range '0-0' -Max 0 -TimeoutSec 20
if ($tr.Ok -and $tr.Headers['date']) {
    try {
        $st = [DateTime]::ParseExact($tr.Headers['date'], 'r', [Globalization.CultureInfo]::InvariantCulture)
        $skew = [math]::Round(([DateTime]::UtcNow - $st).TotalSeconds)
        if ([math]::Abs($skew) -gt 300) { Write-Bad "PC 시계가 $($skew)초 틀려요" 'PC 시계를 맞추세요(설정 → 시간 및 언어 → 지금 동기화). 5분 넘게 틀리면 WildScenes(S3) 서명과 인증서 확인이 실패해요' }
        elseif ([math]::Abs($skew) -gt 60) { Write-Warn "PC 시계가 $($skew)초 틀려요(설정 → 시간 및 언어 → 지금 동기화)" }
        else { Write-Ok "PC 시계가 맞아요(차이 $($skew)초)" }
    } catch { Write-Info '시계: 서버 시각을 읽지 못했어요' }
} else { Write-Info '시계: 서버 시각을 읽지 못했어요' }

# ------------------------------------------------------------------ 디스크
Write-Head '디스크'
try {
    $d = New-Object IO.DriveInfo((Split-Path -Qualifier $root))
    $freeGB = [math]::Round($d.AvailableFreeSpace / 1GB)
    Write-Info "저장소 드라이브 $($d.Name): $($d.DriveFormat), 전체 $([math]::Round($d.TotalSize / 1GB)) GB, 남은 공간 $freeGB GB"
    if ($d.DriveFormat -eq 'FAT32') { Write-Bad '저장소 드라이브가 FAT32 예요(4 GB 넘는 파일을 못 만들어요)' '저장소를 NTFS 나 exFAT 드라이브로 옮기세요' }
    if ($freeGB -lt 100) { Write-Warn '남은 공간이 100 GB 보다 적어요. 데이터셋은 전부 약 500 GB(ORAD-3D 350 GB 포함)예요. -Dest 로 다른 드라이브에 받을 수 있어요' }
    else { Write-Ok "남은 공간 $freeGB GB (데이터셋 전부 약 500 GB, ORAD-3D 350 GB 포함. 모델은 lists\models.txt 에 따라 달라요)" }
    $others = @([IO.DriveInfo]::GetDrives() | Where-Object { $_.IsReady -and $_.DriveType -eq 'Fixed' -and $_.Name -ne $d.Name } |
        ForEach-Object { "$($_.Name.TrimEnd('\')) $([math]::Round($_.AvailableFreeSpace / 1GB)) GB" })
    if ($others.Count) { Write-Info "다른 드라이브의 남은 공간: $($others -join ', ')" }
} catch { Write-Warn "디스크 정보를 읽지 못했어요: $($_.Exception.Message)" }

# ------------------------------------------------------------------ 받은 것
Write-Head '지금까지 받은 것'
foreach ($p in @(@('setup', 'setup\gpu-setup.tar'), @('pkgs', 'pack_pkgs\gpu-pkgs.tar'), @('docker', 'pack_docker\gpu-docker.tar'))) {
    $f = Join-Path $root $p[1]
    if (Test-Path $f) { $i = Get-Item $f; Write-Info "$($p[0]): $($p[1]) $(Format-Size $i.Length), $($i.LastWriteTime.ToString('yyyy-MM-dd HH:mm'))" }
    else { Write-Info "$($p[0]): 아직 없어요" }
}
$ds = Join-Path $root 'datasets'
if (Test-Path $ds) {
    $done = @(Get-ChildItem $ds -Recurse -Depth 1 -Filter '*.ok' -File -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName.Substring($ds.Length + 1) -replace '\.ok$', '' })
    Write-Info "datasets: 다 받은 것 $($done.Count)개$(if ($done.Count) { ' (' + ($done -join ', ') + ')' })"
    foreach ($sub in (Get-ChildItem $ds -Directory -ErrorAction SilentlyContinue)) { Write-Info "    $($sub.Name): $(Format-Size (Get-Size $sub.FullName))" }
} else { Write-Info 'datasets: 아직 없어요' }
$md = Join-Path $root 'models'
if (Test-Path $md) {
    $n = @(Get-ChildItem $md -Recurse -Depth 3 -Filter 'gpu_model.json' -File -ErrorAction SilentlyContinue).Count
    Write-Info "models: 다 받은 모델 $($n)개, 전체 $(Format-Size (Get-Size $md))"
} else { Write-Info 'models: 아직 없어요' }

# 지난 실행 기록: 마지막 실행이 끝났는지, 멈췄다면 왜인지, [문제] 줄
Write-Head '지난 실행 기록(마지막 실행)'
$Logs = [ordered]@{ setup = 'setup\build.log'; pkgs = 'pack_pkgs\build.log'; docker = 'pack_docker\build.log'; datasets = 'datasets\download.log'; models = 'models\download.log' }
foreach ($k in $Logs.Keys) {
    $f = Join-Path $root $Logs[$k]
    if (-not (Test-Path $f)) { Write-Info "$($k): 기록 없음"; continue }
    $all = [IO.File]::ReadAllLines($f)
    if (-not $all.Count) { Write-Info "$($k): 기록이 비어 있어요"; continue }
    $start = 0
    for ($j = $all.Count - 1; $j -ge 0; $j--) { if ($all[$j] -match '^\[접근 PC\]') { $start = $j; break } }
    $run = @($all[$start..($all.Count - 1)])
    $why = @($run | Where-Object { $_ -match '^멈춘 이유: ' } | Select-Object -Last 1)
    $state = if ($why.Count) { "멈춤 - $($why[0] -replace '^멈춘 이유: ', '')" } elseif ($run -match '#{5,} 완료 #{5,}') { '끝까지 했어요' } else { '끝나지 않았어요(창을 닫았거나 아직 실행 중)' }
    Write-Info "$($k): $($run[0].Trim()) → $state"
    foreach ($l in @($run | Where-Object { $_ -match '\[문제\]' } | Select-Object -Last 5)) { Write-Info "    $($l.Trim())" }
}

# ------------------------------------------------------------------ 요약
Write-Head '고칠 것'
if ($script:Todo.Count) { $n = 0; foreach ($t in $script:Todo) { $n++; Out-Line "  $n. $t" Red } }
else { Out-Line '  없어요. 모두 정상이에요.' Green }

# 가리기: 계정·PC 이름, 프록시 주소, 토큰·키 값, 그리고 Hide-Text(주소 뒤 값, 사내 IP, 서명)
$proxies.Add($env:HTTPS_PROXY); $proxies.Add($env:HTTP_PROXY); $proxies.Add($wp); $proxies.Add($pac)
$hide = @{}
foreach ($p in $proxies) {
    if (-not $p) { continue }
    $hide[$p] = '(프록시)'
    try { $h = ([uri]$p).Host; if ($h.Length -ge 4) { $hide[$h] = '(프록시)' } } catch { }
}
foreach ($v in 'HF_TOKEN', 'WILDSCENES_ACCESS_KEY', 'WILDSCENES_SECRET_KEY', 'WILDSCENES_S3_DIR') {
    $x = [Environment]::GetEnvironmentVariable($v); if ($x -and $x.Trim().Length -ge 4) { $hide[$x.Trim()] = '(가림)' }
}
if ($env:USERPROFILE) { $hide[$env:USERPROFILE] = '%USERPROFILE%' }
foreach ($v in 'COMPUTERNAME', 'USERNAME', 'USERDOMAIN') {
    $x = [Environment]::GetEnvironmentVariable($v); if ($x -and $x.Length -ge 3) { $hide[$x] = "(%$v%)" }
}
# 계정·PC 이름은 낱말일 때만 바꾼다(짧은 이름이 다른 낱말 안에 든 경우는 그대로)
$word = @{}
foreach ($v in 'COMPUTERNAME', 'USERNAME', 'USERDOMAIN') { $x = [Environment]::GetEnvironmentVariable($v); if ($x) { $word[$x] = 1 } }
$keys = @($hide.Keys | Sort-Object Length -Descending)   # 긴 것부터(프록시 주소 → 그 안의 이름)
$out = foreach ($l in $script:Lines) {
    foreach ($k in $keys) {
        $pat = if ($word.ContainsKey($k)) { '(?<![A-Za-z0-9_.-])' + [regex]::Escape($k) + '(?![A-Za-z0-9_-])' } else { [regex]::Escape($k) }
        $l = [regex]::Replace($l, $pat, $hide[$k].Replace('$', '$$'), 'IgnoreCase')
    }
    Hide-Text $l
}
Save-Report $out $outFile
Write-Host ''
Write-Host " 결과 파일: $outFile" -ForegroundColor Green
Write-Host ' 계정·PC 이름, 프록시 주소, 사내 IP, 토큰·키·서명은 가려 두었어요. 올리기 전에 한 번 열어 보세요.'
if (-not $NoPush) { Push-Report $outFile "접근 PC 점검 결과($stamp)" }
exit [int]($script:Todo.Count -gt 0)
