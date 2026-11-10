# pc 폴더의 스크립트(setup_pack.ps1, datasets_download.ps1 등)가 같이 쓰는 함수. 직접 실행하지 않는다.

$script:Fails = 0

# uv 등이 내는 UTF-8 출력을 깨지지 않게 읽는다(한국어 윈도우 기본은 CP949)
try {
    [Console]::OutputEncoding = New-Object Text.UTF8Encoding $false
    $OutputEncoding = [Console]::OutputEncoding
} catch { }

function Write-Step($n, $total, $title) {
    Write-Host ''
    Write-Host "==== [$n/$total] $title ====" -ForegroundColor Cyan
}
function Write-Ok($msg)   { Write-Host "  [정상] $msg" -ForegroundColor Green }
function Write-Warn($msg) { Write-Host "  [주의] $msg" -ForegroundColor Yellow }
function Write-Bad($msg)  { Write-Host "  [문제] $msg" -ForegroundColor Red; $script:Fails++ }
function Write-Info($msg) { Write-Host "  $msg" }

# 저장소 맨 위의 .env(접근 PC 설정, 예시는 .env.example)를 읽어 이 창의 환경 변수로 둔다.
# 이미 정해 둔 환경 변수가 이긴다. 값은 화면과 기록 파일에 남기지 않고 이름만 알려 준다.
function Import-DotEnv($path) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return }
    $read = @(); $n = 0
    foreach ($line in [IO.File]::ReadAllLines($path)) {
        $n++
        $l = $line.Trim()
        if (-not $l -or $l.StartsWith('#')) { continue }
        if (-not ($l -match '^(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$')) {
            Write-Warn ".env $($n)번째 줄을 읽지 못했어요(이름=값 모양이 아니에요). 이 줄은 건너뛰어요"
            continue
        }
        $k = $Matches[1]; $v = $Matches[2]
        if ($v -match '^"([^"]*)"' -or $v -match "^'([^']*)'") { $v = $Matches[1] }   # 따옴표 안은 그대로(# 도 값)
        else { $v = ($v -replace '\s+#.*$', '').Trim() }                                # 따옴표 없으면 뒤의 # 설명은 뺀다
        if (-not $v -or [Environment]::GetEnvironmentVariable($k)) { continue }
        [Environment]::SetEnvironmentVariable($k, $v)   # 이 창(프로세스)에서만. 윈도우 설정에는 남지 않는다
        $read += $k
    }
    if ($env:HTTPS_PROXY -and -not $env:HTTP_PROXY) { $env:HTTP_PROXY = $env:HTTPS_PROXY }   # http:// 주소(rugd.vision)도 같은 프록시로
    if ($read.Count) { Write-Info ".env 에서 읽은 설정: $($read -join ', ')" }
}
$GpuRoot = Split-Path $PSScriptRoot -Parent   # 저장소 맨 위(D:\gpu)
Import-DotEnv (Join-Path $GpuRoot '.env')

# 같은 받기를 두 곳에서 동시에 돌리지 않게 잠근다(직접 실행한 창과 자동 받기가 겹치는 경우 등).
# 겹치면 같은 파일을 둘이 받아 꼬이고, 기록 파일(download.log)도 "다른 프로세스가 사용 중" 이라 열리지 않는다.
# 잠금 파일을 이 실행이 끝날 때까지 혼자 열어 둔다(창이 닫히거나 PC가 꺼지면 윈도우가 저절로 푼다). 이미 누가 열었으면 $false
function Enter-SingleRun($dir) {
    try {
        $script:RunLock = [IO.File]::Open((Join-Path $dir '.running.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
        return $true
    } catch { }
    # 같은 PowerShell 창에서 전에 돌다 멈춘(Ctrl+C) 실행이 남긴 잠금이면, 버려진 것을 치운 뒤 한 번 더 해 본다
    [GC]::Collect(); [GC]::WaitForPendingFinalizers()
    try {
        $script:RunLock = [IO.File]::Open((Join-Path $dir '.running.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
        return $true
    } catch { return $false }
}

# 실행을 마칠 때(정상, 멈춤, Ctrl+C 모두): 기록을 닫고 잠금을 푼다. 안 하면 같은 PowerShell 창이 기록 파일을 계속 잡고 있어서
# 다음 실행이나 admin\pc\check.ps1 이 "다른 프로세스에서 사용 중" 으로 기록 파일을 열지 못한다
function Exit-Run {
    try { Stop-Transcript -ErrorAction Stop | Out-Null } catch { }
    if ($script:RunLock) { $script:RunLock.Dispose(); $script:RunLock = $null }
}

function Start-Log($path) {
    try { Stop-Transcript -ErrorAction Stop | Out-Null } catch { }   # 이 창에서 전에 멈춘 실행의 기록이 아직 열려 있으면 닫는다
    $script:LogPath = $path
    New-Item -ItemType Directory -Force (Split-Path $path) | Out-Null
    Start-Transcript -Append $path | Out-Null
}

# 멈추고 할 일을 알려 준다
function Stop-Run($what, $fix) {
    Write-Host ''
    Write-Host '################ 멈춤 ################' -ForegroundColor Red
    Write-Host "멈춘 이유: $what" -ForegroundColor Red
    Write-Host "할 일: $fix"
    Write-Host '할 일을 한 뒤 같은 명령을 다시 실행하세요. 끝난 것은 건너뛰고 이어서 해요.'
    Write-Host "해결되지 않으면 이 기록 파일을 담당자에게 보내 주세요: $script:LogPath"
    Write-Host '접근 PC 문제 같으면 .\admin\pc\check.ps1 로 점검 결과를 올려 주세요(담당자가 읽어요).'
    Stop-Transcript | Out-Null
    [GPU.Power]::SetThreadExecutionState([uint32]2147483648) | Out-Null
    exit 1
}

# 실제 exe 경로를 찾는다. PowerShell 별칭·함수는 건너뛴다
function Find-Exe($name, $root) {
    $c = Get-Command $name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($c) { return $c.Source }
    $cand = @((Join-Path $root "$name.exe"))
    if ($name -eq 'uv') {
        $cand += Join-Path $env:USERPROFILE '.local\bin\uv.exe'              # 공식 설치 스크립트 기본 위치
        $cand += Join-Path $env:USERPROFILE '.cargo\bin\uv.exe'
    }
    foreach ($p in $cand) { if ($p -and (Test-Path $p)) { return $p } }
    return $null
}

# 인터넷 요청은 두 가지로 한다(curl 은 쓰지 않는다).
#  - 접속 확인·크기 확인·작은 파일·진단: .NET(Invoke-Http). 브라우저처럼 윈도우 시스템 프록시(PAC 포함)와 윈도우 로그인 인증을 쓰고,
#    인증서 폐기 확인 서버에 닿지 않아도 브라우저처럼 넘어간다(회사망에서 윈도우 curl 이 CRYPT_E_NO_REVOCATION_CHECK 로 끊기던 문제).
#  - 받기: aria2c(Invoke-Aria2). 이어받기, 다시 시도, 여러 파일 동시 받기. 윈도우판은 인증서를 검증하면서 "폐기 확인 정보 없음"만 넘어간다.
$env:UV_NATIVE_TLS = '1'   # uv 가 윈도우 인증서 저장소를 쓰게 한다(회사 보안 장비 인증서 포함)
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }

# 브라우저가 이 주소에 쓰는 프록시를 윈도우에 묻는다(자동 프록시 설정 PAC 포함). 바로 가면 $null
function Get-BrowserProxy($url) {
    try {
        $wp = [System.Net.WebRequest]::GetSystemWebProxy()
        $u = [uri]$url
        if ($wp.IsBypassed($u)) { return $null }
        $r = $wp.GetProxy($u)
        if ($r -and $r.AbsoluteUri -ne $u.AbsoluteUri) { return $r.AbsoluteUri.TrimEnd('/') }
    } catch { }
    return $null
}

function Get-WindowsProxy {
    $s = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction SilentlyContinue
    if (-not $s -or $s.ProxyEnable -ne 1 -or -not $s.ProxyServer) { return $null }
    $p = $s.ProxyServer
    if ($p -match 'https=([^;]+)') { $p = $Matches[1] } elseif ($p -match 'http=([^;]+)') { $p = $Matches[1] }
    if ($p -notmatch '://') { $p = "http://$p" }
    return $p
}

# .env 의 프록시: http:// 주소는 HTTP_PROXY, https:// 주소는 HTTPS_PROXY(.env 를 읽을 때 HTTP_PROXY 가 없으면 HTTPS_PROXY 와 같게 둔다)
function Get-EnvProxy($url) { if ($url -like 'http://*') { return $env:HTTP_PROXY } return $env:HTTPS_PROXY }

# .NET 으로 요청 하나. .env 의 HTTPS_PROXY 가 있으면 그것을, 없으면 브라우저와 같은 시스템 프록시를 쓰고, 프록시에는 윈도우 로그인을 보낸다.
#   -Range '0-0'    앞부분만      -Max 바이트   본문을 이만큼만 읽는다(기본 64 KB)    -NoRedirect   넘겨주기를 따라가지 않는다
#   -Cookies        CookieContainer(여러 요청에 걸쳐 쿠키 유지)      -Head 머리글만(HEAD)     -Headers @{ 이름 = 값 }
# 돌려주는 것: Ok(HTTP 응답을 받았으면 $true. 4xx·5xx 도 응답은 받은 것), Status, Url(마지막 주소), Headers(소문자 이름), Body(글자), Error, Kind
#   Kind: http(응답 받음) / dns / connect / timeout / tls / proxy / reset / other
function Invoke-Http($url, [string]$Range = '', [int]$Max = 65536, [switch]$NoRedirect, $Cookies = $null, [switch]$Head, [hashtable]$Headers = @{}, [int]$TimeoutSec = 60) {
    $r = [pscustomobject]@{ Ok = $false; Status = 0; Url = $url; Headers = @{}; Body = ''; Error = ''; Kind = 'other' }
    $res = $null
    try {
        $req = [Net.HttpWebRequest]::Create($url)
        $ep = Get-EnvProxy $url
        if ($ep) { $req.Proxy = New-Object Net.WebProxy($ep) } else { $req.Proxy = [Net.WebRequest]::GetSystemWebProxy() }
        if ($req.Proxy) { $req.Proxy.Credentials = [Net.CredentialCache]::DefaultNetworkCredentials }
        $req.Timeout = $TimeoutSec * 1000; $req.ReadWriteTimeout = $TimeoutSec * 1000
        $req.AllowAutoRedirect = -not $NoRedirect
        $req.UserAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) gpu-setup'
        if ($Cookies) { $req.CookieContainer = $Cookies }
        if ($Head) { $req.Method = 'HEAD' }
        if ($Range -match '^(\d+)-(\d*)$') { if ($Matches[2]) { $req.AddRange([int64]$Matches[1], [int64]$Matches[2]) } else { $req.AddRange([int64]$Matches[1]) } }
        foreach ($k in $Headers.Keys) { $req.Headers[$k] = $Headers[$k] }
        try { $res = $req.GetResponse() } catch [Net.WebException] { $res = $_.Exception.Response; if (-not $res) { throw } }
        $r.Ok = $true; $r.Kind = 'http'; $r.Status = [int]$res.StatusCode; $r.Url = $res.ResponseUri.AbsoluteUri
        foreach ($k in $res.Headers.AllKeys) { $r.Headers[$k.ToLower()] = $res.Headers[$k] }
        if (-not $Head -and $Max -gt 0) {
            $st = $res.GetResponseStream(); $ms = New-Object IO.MemoryStream; $buf = New-Object byte[] 8192
            while ($ms.Length -lt $Max) { $n = $st.Read($buf, 0, [math]::Min($buf.Length, $Max - $ms.Length)); if ($n -le 0) { break }; $ms.Write($buf, 0, $n) }
            $r.Body = [Text.Encoding]::UTF8.GetString($ms.ToArray())
        }
    } catch {
        $ex = $_.Exception; while ($ex.InnerException -and -not ($ex -is [Net.WebException])) { $ex = $ex.InnerException }
        $r.Error = $ex.Message
        if ($ex -is [Net.WebException]) {
            switch ($ex.Status.ToString()) {
                'NameResolutionFailure'      { $r.Kind = 'dns' }
                'ProxyNameResolutionFailure' { $r.Kind = 'proxy' }
                'ConnectFailure'             { $r.Kind = 'connect' }
                'Timeout'                    { $r.Kind = 'timeout' }
                'TrustFailure'               { $r.Kind = 'tls' }
                'SecureChannelFailure'       { $r.Kind = 'tls' }
                'ConnectionClosed'           { $r.Kind = 'reset' }
                'ReceiveFailure'             { $r.Kind = 'reset' }
                'SendFailure'                { $r.Kind = 'reset' }
                default                      { $r.Kind = 'other' }
            }
        }
    } finally { if ($res) { $res.Close() } }
    return $r
}

# 받을 파일 크기(바이트). 앞 1바이트를 요청해 Content-Range 의 전체 크기를 읽는다(없으면 Content-Length). 모르면 $null
function Get-RemoteSize($url) {
    $r = Invoke-Http $url -Range '0-0' -Max 0
    if (-not $r.Ok -or $r.Status -ge 400) { return $null }
    if ($r.Headers['content-range'] -match '/(\d+)$') { return [int64]$Matches[1] }
    if ($r.Status -eq 200 -and $r.Headers['content-length'] -match '^\d+$') { return [int64]$r.Headers['content-length'] }
    return $null
}

function Invoke-Probe($url) {
    # 접속되는지만 본다(HTTP 코드는 상관없다). HEAD 를 막는 장비가 있어 GET 으로 1바이트만 받는다
    $r = Invoke-Http $url -Range '0-0' -Max 0 -TimeoutSec 40
    return [pscustomobject]@{ Code = $(if ($r.Ok) { 0 } else { 1 }); Kind = $r.Kind; Msg = $r.Error; Status = $r.Status; Headers = $r.Headers }
}

function Get-NetHint($kind) {
    switch ($kind) {
        'dns'     { return '주소를 찾지 못했어요(DNS). 사내 IT에 이 주소를 물어보세요.' }
        'proxy'   { return '프록시 주소를 찾지 못했어요. .env 의 HTTPS_PROXY 나 윈도우 프록시 설정을 확인하세요.' }
        'connect' { return '연결이 거부됐어요. 방화벽이 막았거나, 프록시를 거쳐야 하는 망일 수 있어요.' }
        'timeout' { return '응답이 없어 기다리다 멈췄어요. 방화벽이 차단 화면 없이 조용히 막는 주소일 수 있어요.' }
        'tls'     { return '보안 연결(TLS)에 실패했어요. 회사 보안 장비가 막았거나, 인증서를 중간에서 바꿔 끼우는 망일 수 있어요.' }
        'reset'   { return '연결은 됐지만 중간에 끊겼어요. 대부분 회사 프록시나 방화벽이 이 주소를 막은 경우예요.' }
        default   { return '' }
    }
}

# 사이트에 접속되는지 보고 [정상]/[문제] 를 찍는다. HTTP 코드는 상관없다(브라우저와 같은 방법으로 접속해 본다)
function Test-Site($name, $url) {
    $first = Invoke-Probe $url
    if ($first.Code -eq 0) {
        Write-Ok "인터넷: $name"
        # 프록시가 거절하면 응답은 오지만 프록시가 보낸 것이다(407 은 프록시 인증 실패)
        if ($first.Status -eq 407) { Write-Warn "    $name : 프록시가 인증을 요구해요(407). 윈도우 로그인으로는 인증되지 않는 프록시예요. 사내 IT에 문의하세요." }
        return $true
    }
    $site = ([uri]$url).Host
    Write-Bad "인터넷: $name 접속 안 됨 ($url)"
    Write-Info "    오류: $($first.Msg)"
    $hint = Get-NetHint $first.Kind
    if ($hint) { Write-Info "    $hint" }
    Write-Info "    사내 IT에 $site (포트 443) 접속 허용을 요청하세요."
    Write-Info "    확인: 브라우저에서 https://$site/ 를 열어 보세요. XML 오류 문구라도 뜨면 브라우저로는 연결되는 거고, '연결할 수 없음'이 뜨면 브라우저도 막힌 거예요."
    $pac = (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction SilentlyContinue).AutoConfigURL
    if ($pac) { Write-Info "    이 PC 브라우저는 자동 프록시 설정(PAC)을 써요: $pac" }
    $bp = Get-BrowserProxy $url
    Write-Info "    브라우저가 이 주소에 쓰는 프록시: $(if ($bp) { $bp } else { '없음(바로 접속)' })"
    return $false
}

function Get-FreeGB($dir) {
    return [math]::Round((Get-Item $dir).PSDrive.Free / 1GB)
}

function Format-Size($bytes) {
    if ($bytes -ge 1GB) { return '{0:N1} GB' -f ($bytes / 1GB) }
    return '{0:N0} MB' -f ($bytes / 1MB)
}

# 파일이면 크기, 폴더면 안의 파일 크기 합(없으면 0)
function Get-Size($path) {
    if (Test-Path -LiteralPath $path -PathType Leaf) { return (Get-Item -LiteralPath $path).Length }
    if (Test-Path -LiteralPath $path) {
        $s = (Get-ChildItem -LiteralPath $path -Recurse -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
        if ($s) { return [int64]$s }
    }
    return [int64]0
}

# 끊긴 뒤 기다리기. 받은 양이 늘었으면 진전이 있는 것이라 센 횟수를 0으로 되돌리고 10초만 쉰다.
# 진전 없이 끊긴 횟수만 세고, 기다리는 시간을 30초씩 늘린다(최대 2분). 마지막 번에는 기다리지 않는다. 새 횟수를 돌려준다.
function Step-Retry($stall, $before, $after, $max, $what) {
    if ($after -gt $before) {
        Write-Warn "$what 연결이 끊겼어요. 받은 데까지($(Format-Size $after)) 이어서 받아요"
        Start-Sleep 10
        return 0
    }
    $stall++
    if ($stall -ge $max) { Write-Warn "$what 연결이 끊겼고 더 받지 못했어요($stall/$max). 이번에는 여기까지 해요"; return $stall }
    $wait = [math]::Min(120, 30 * $stall)
    Write-Warn "$what 연결이 끊겼고 더 받지 못했어요. ${wait}초 뒤 다시 해요($stall/$max)"
    Start-Sleep $wait
    return $stall
}

# 받은 파일이 알려 준 체크섬과 맞는지 본다. 체크섬을 안 주면 맞는 것으로 친다
function Test-Sum($file, $md5, $sha256) {
    if ($sha256) { return (Get-FileHash $file -Algorithm SHA256).Hash -eq $sha256.ToUpper() }
    if ($md5)    { return (Get-FileHash $file -Algorithm MD5).Hash -eq $md5.ToUpper() }
    return $true
}

# aria2c(받기 도구). 공식 윈도우판을 받아 지문을 확인하고 저장소의 tools\aria2 에 둔다(git 에는 안 올라간다).
# 윈도우판은 인증서를 검증하면서 "폐기 확인 정보 없음"(CRYPT_E_NO_REVOCATION_CHECK)만 넘어가서(SCH_CRED_IGNORE_NO_REVOCATION_CHECK),
# 폐기 확인 서버에 닿지 않는 회사망에서도 보안 확인을 끄지 않고 받아진다. aria2c 자체는 .NET 으로 받는다
$Aria2Url    = 'https://github.com/aria2/aria2/releases/download/release-1.37.0/aria2-1.37.0-win-64bit-build1.zip'
$Aria2ZipSha = '67d015301eef0b612191212d564c5bb0a14b5b9c4796b76454276a4d28d9b288'
$Aria2ExeSha = 'be2099c214f63a3cb4954b09a0becd6e2e34660b886d4c898d260febfe9d70c2'
$script:Aria2Path = $null
function Get-Aria2 {
    if ($script:Aria2Path) { return $script:Aria2Path }
    if ($env:GPU_ARIA2) { $script:Aria2Path = $env:GPU_ARIA2; return $env:GPU_ARIA2 }   # 시험할 때만(tests, 리눅스)
    $dir = Join-Path $GpuRoot 'tools\aria2'
    $exe = Join-Path $dir 'aria2c.exe'
    if ((Test-Path $exe) -and (Get-FileHash $exe -Algorithm SHA256).Hash -eq $Aria2ExeSha.ToUpper()) { $script:Aria2Path = $exe; return $exe }
    New-Item -ItemType Directory -Force $dir | Out-Null
    $zip = Join-Path $dir 'aria2.zip'
    try {
        if (-not ((Test-Path $zip) -and (Get-FileHash $zip -Algorithm SHA256).Hash -eq $Aria2ZipSha.ToUpper())) {
            Write-Info '받기 도구 aria2c 를 받는 중이에요(처음 한 번만, 2.5 MB)'
            $wc = New-Object Net.WebClient
            if ($env:HTTPS_PROXY) { $wc.Proxy = New-Object Net.WebProxy($env:HTTPS_PROXY) } else { $wc.Proxy = [Net.WebRequest]::GetSystemWebProxy() }
            if ($wc.Proxy) { $wc.Proxy.Credentials = [Net.CredentialCache]::DefaultNetworkCredentials }
            $wc.DownloadFile($Aria2Url, $zip)
        }
        if ((Get-FileHash $zip -Algorithm SHA256).Hash -ne $Aria2ZipSha.ToUpper()) { Remove-Item -Force $zip; Write-Warn '받은 aria2c 압축 파일의 지문이 맞지 않아 지웠어요'; return $null }
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $z = [IO.Compression.ZipFile]::OpenRead($zip)
        try {
            $e = $z.Entries | Where-Object { $_.Name -eq 'aria2c.exe' } | Select-Object -First 1
            [IO.Compression.ZipFileExtensions]::ExtractToFile($e, $exe, $true)
        } finally { $z.Dispose() }
        if ((Get-FileHash $exe -Algorithm SHA256).Hash -ne $Aria2ExeSha.ToUpper()) { Remove-Item -Force $exe; Write-Warn 'aria2c.exe 의 지문이 맞지 않아 지웠어요'; return $null }
        $script:Aria2Path = $exe
        return $exe
    } catch {
        Write-Warn "aria2c 를 받지 못했어요(github.com 접속을 확인하세요): $($_.Exception.Message)"
        return $null
    }
}

# 점검 단계용: aria2c 가 없으면 [문제]
function Test-Aria2 {
    $a = Get-Aria2
    if ($a) { Write-Ok "aria2c ($a)"; return $true }
    Write-Bad 'aria2c 를 준비하지 못했어요. github.com 접속을 확인하거나, 브라우저로 아래 파일을 받아 저장소의 tools\aria2 폴더에 aria2.zip 이라는 이름으로 넣고 다시 실행하세요'
    Write-Info "    $Aria2Url"
    return $false
}

# aria2c 에 붙일 프록시: .env 의 프록시(Get-EnvProxy), 없으면 브라우저가 이 주소에 쓰는 프록시(PAC 포함). aria2c 는 윈도우 로그인 인증을 못 한다
function Get-Aria2Proxy($url) {
    $p = Get-EnvProxy $url
    if (-not $p) { $p = Get-BrowserProxy $url }
    if ($p) { return @("--all-proxy=$p") }
    return @()
}

# aria2c 로 파일 하나를 받는다(이어받기 -c). $conn 은 동시 연결 수. 종료 코드를 돌려준다(aria2c 를 못 구하면 99)
#   0 받음, 3 없는 주소(404), 22 거절(403 등), 24 인증 실패(401), 8 이어받기 안 됨, 13 받은 파일이 있는데 이어받기를 못 함, 그 밖은 네트워크 문제
function Invoke-Aria2($url, $file, [string[]]$extra = @(), [int]$conn = 1) {
    $a = Get-Aria2
    if (-not $a) { return 99 }
    $dir = Split-Path $file; $name = Split-Path -Leaf $file
    New-Item -ItemType Directory -Force $dir | Out-Null
    # 빈 파일(임시 파일 등)이 있으면 지운다. 이어받기를 못 하는 서버에서는 aria2c 가 덮어쓰지 않으려고 멈춘다(13)
    if ((Test-Path $file) -and (Get-Item $file).Length -eq 0 -and -not (Test-Path "$file.aria2")) { Remove-Item -Force $file }
    $px = @(Get-Aria2Proxy $url)
    & $a -c -d $dir -o $name -x $conn -s $conn --auto-file-renaming=false --file-allocation=none `
        --max-tries=2 --retry-wait=10 --connect-timeout=30 --timeout=120 `
        --summary-interval=0 --console-log-level=warn --download-result=hide @px @extra $url | Out-Host   # 화면에만(결과값에 섞이지 않게)
    return $LASTEXITCODE
}

# 이어받기 + 다시 시도(aria2c). md5 나 sha256 을 주면 받은 뒤 맞는지 본다. 성공하면 $true.
# 받은 양이 늘고 있는 동안은 몇 번 끊겨도 계속하고, 진전 없이 $tries 번 끊기면 포기한다.
function Get-File($url, $file, $md5, $tries, $sha256) {
    if ((Test-Path $file) -and -not (Test-Path "$file.aria2") -and ($md5 -or $sha256) -and (Test-Sum $file $md5 $sha256)) { return $true }
    $stall = 0
    while ($stall -lt $tries) {
        $before = Get-Size $file
        $code = Invoke-Aria2 $url $file
        if ($code -eq 99) { return $false }
        if ($code -eq 0) {
            if (Test-Sum $file $md5 $sha256) { return $true }
            Write-Warn "체크섬이 맞지 않아 다시 받아요: $(Split-Path -Leaf $file)"
            Remove-Item -Force $file
            $stall++
            continue
        }
        if ($code -in 3, 8, 13, 22, 24) {
            Remove-Item -Force -ErrorAction SilentlyContinue $file, "$file.aria2"   # 거절됐거나 이어받기가 안 되면 처음부터
        }
        $stall = Step-Retry $stall $before (Get-Size $file) $tries "$(Split-Path -Leaf $file) (aria2c $code)"
    }
    return $false
}

# 받다 만 파일이 아주 작으면(1 MB 미만) 지우고 처음부터 받게 한다. 성공하면 $true.
# 사이트가 파일 대신 안내 페이지(2 KB 남짓)를 보냈을 때 남은 이어받기 기록(.aria2)에는 전체 크기가 그 페이지 크기로 적혀서,
# 다음에 진짜 파일을 받으려 하면 aria2c 가 "Total length mismatch"(errorCode=1)로 계속 멈춘다. 1 MB 미만이면 다시 받아도 손해가 없다
function Reset-SmallPart($file) {
    if (-not (Test-Path $file) -or (Get-Item $file).Length -ge 1MB) { return $false }
    Remove-Item -Force -ErrorAction SilentlyContinue $file, "$file.aria2"
    Write-Warn "받다 만 파일이 아주 작아서(안내 페이지였을 수 있어요) 지우고 처음부터 받아요: $(Split-Path -Leaf $file)"
    return $true
}

# 지문은 업로드가 끝난 뒤(몇 시간 뒤, 다른 날, NAS를 거친 서버 2)에 맞춰 보므로 화면에만 두지 않고 저장소 맨 위에 쌓아 둔다
function Save-Fingerprint($what, $fp) {
    $f = Join-Path $root '지문_기록.txt'
    Add-Content -Encoding UTF8 -Path $f -Value ('{0}  {1}  {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm'), $what, $fp)
    Write-Host " 지문(sha256): $fp" -ForegroundColor Cyan
    Write-Host "   (이 값은 $f 에도 적어 뒀어요)"
}

# 올릴 폴더 안에서 GPU 서버가 쓰지 않는 큰 파일(받다 만 파일, 목록에서 뺀 모델 등)을 알려 준다. HIWARE로 올리는 시간을 아낀다
function Show-NotNeeded($dest, $manifest, [string[]]$keepPrefix) {
    $base = (Resolve-Path $dest).Path.TrimEnd('\')
    $keep = @{}
    foreach ($l in (Get-Content -Encoding UTF8 $manifest)) { if ($l -match '^[0-9a-f]{64}  (.+)$') { $keep[$Matches[1]] = 1 } }
    $extra = @(Get-ChildItem $base -Recurse -File | Where-Object {
        $rel = $_.FullName.Substring($base.Length + 1) -replace '\\', '/'
        $inPrefix = $false
        foreach ($p in $keepPrefix) { if ($p -and $rel.StartsWith($p)) { $inPrefix = $true } }
        $_.Length -ge 10MB -and -not $keep.ContainsKey($rel) -and -not $inPrefix
    })
    if (-not $extra.Count) { return }
    $sum = ($extra | Measure-Object -Property Length -Sum).Sum
    Write-Host " 이 폴더 안에서 GPU 서버가 쓰지 않는 큰 파일이 $($extra.Count)개($(Format-Size $sum)) 있어요. 체크섬 목록(MANIFEST.sha256)에 없는 파일이라 올려도 서버가 쓰지 않아요. 올릴 때 빼면 시간을 아껴요:" -ForegroundColor Yellow
    $extra | Sort-Object Length -Descending | Select-Object -First 8 | ForEach-Object {
        $rel = $_.FullName.Substring($base.Length + 1)
        $top = ($rel -split '\\')[0]
        # 왜 목록에 없는지: 받다 만 파일(이어받기 중, 미뤘거나 실패), 아직 다 받지 않은 폴더(ORAD-3D, 모델), 그 밖(예전에 받았거나 목록에서 뺀 것)
        $why = if ($_.Name -match '\.(download|aria2|incomplete|join|part)$|\.part-[a-z]{2}$|\._____temp') { '받다 만 파일. 다 받으면 목록에 들어가요' }
               elseif ((Test-Path -LiteralPath (Join-Path $base $top) -PathType Container) -and $rel.Contains('\') -and
                       -not (Test-Path -LiteralPath (Join-Path $base "$top.ok")) -and -not (Test-Path -LiteralPath (Join-Path (Join-Path $base $top) 'gpu_model.json')) -and
                       -not (Test-Path -LiteralPath "$($_.FullName).ok")) { '아직 다 받지 않은 것. 다 받으면 목록에 들어가요' }
               else { '목록에 없는 파일(예전에 받았거나 목록에서 뺀 것)' }
        Write-Host "   $rel  ($(Format-Size $_.Length)) - $why" }
    if ($extra.Count -gt 8) { Write-Host "   ... 그 밖에 $($extra.Count - 8)개" }
}

# GPU 서버에서 root 가 확인할 지문(sha256, 소문자).
# 파일 하나면 그 파일의 sha256(서버: sha256sum 파일), 여러 개면 이어 붙인 내용의 sha256(서버: cat 파일들 | sha256sum)
function Get-Fingerprint([string[]]$files) {
    if ($files.Count -eq 1) { return (Get-FileHash $files[0] -Algorithm SHA256).Hash.ToLower() }
    $ms = New-Object IO.MemoryStream
    foreach ($f in $files) { $b = [IO.File]::ReadAllBytes($f); $ms.Write($b, 0, $b.Length) }
    $ms.Position = 0
    $h = [Security.Cryptography.SHA256]::Create().ComputeHash($ms)
    return (($h | ForEach-Object { $_.ToString('x2') }) -join '')
}

# ---- 점검 결과를 reports\ 에 남겨 git 으로 올리기(check.ps1, wildscenes_check.ps1) ----
# 가리기: 주소의 ? 뒤 값, 사내 IP, 서명·키·토큰처럼 보이는 값
function Hide-Text($s) {
    if (-not $s) { return '' }
    $s = $s -replace '\?[^\s"<>]*', '?…'
    $s = $s -replace '(^|[^0-9.])(10\.\d{1,3}|192\.168|172\.(1[6-9]|2\d|3[01]))\.\d{1,3}\.\d{1,3}', '$1(사내 IP)'
    $s = $s -replace '(?i)(Signature|Credential|AccessKeyId|Security-Token|Token|Expires)([=:>]\s*)[^&\s<"]+', '$1$2…'
    $s = $s -replace '(AKIA|ASIA)[0-9A-Z]{16}', '(키)'
    $s = $s -replace 'hf_[A-Za-z0-9]{20,}', '(토큰)'
    return $s
}
# 프록시는 주소 대신 종류와 포트만
function Proxy-Label($p) { if (-not $p) { return '없음' } try { $u = [uri]$p; return "있음($($u.Scheme), 포트 $($u.Port))" } catch { return '있음' } }

# 줄 목록을 UTF-8(BOM 없음)로 쓴다
function Save-Report($lines, $file) {
    New-Item -ItemType Directory -Force (Split-Path $file) | Out-Null
    [IO.File]::WriteAllText($file, (($lines -join "`n") + "`n"), (New-Object Text.UTF8Encoding $false))
}

# 물어본 뒤 그 파일 하나만 커밋해 올린다(커밋 검사가 사내 정보를 한 번 더 본다)
function Push-Report($file, $msg) {
    $a = Read-Host ' 이 파일을 git 으로 올릴까요? [Y/n]'
    if ($a -match '^[nN]') { Write-Host " 올리지 않았어요. 나중에: git add reports && git commit -m `"$msg`" && git push"; return }
    Push-Location $root
    try {
        & git add -- $file
        & git commit -m $msg -- $file
        if ($LASTEXITCODE -ne 0) { Write-Host ' [문제] 커밋하지 못했어요. 위 메시지를 보세요(커밋 검사가 멈췄다면 파일에서 그 줄을 지우고 다시 실행하세요).' -ForegroundColor Red; return }
        & git pull --rebase --autostash
        & git push
        if ($LASTEXITCODE -eq 0) { Write-Host ' 올렸어요. 담당자에게 알려 주세요.' -ForegroundColor Green }
        else { Write-Host ' [문제] 올리지 못했어요. 인터넷 연결을 확인하고 git push 를 다시 하세요.' -ForegroundColor Red }
    } finally { Pop-Location }
}

# 실행 중 접근 PC 절전 막기(끝나면 원래대로)
Add-Type -Namespace GPU -Name Power -MemberDefinition `
    '[DllImport("kernel32.dll")] public static extern uint SetThreadExecutionState(uint f);' -ErrorAction SilentlyContinue
function Stop-Sleep  { [GPU.Power]::SetThreadExecutionState([uint32]2147483649) | Out-Null }  # ES_CONTINUOUS | ES_SYSTEM_REQUIRED
function Allow-Sleep { [GPU.Power]::SetThreadExecutionState([uint32]2147483648) | Out-Null }  # ES_CONTINUOUS
