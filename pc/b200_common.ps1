# pack_build.ps1, datasets_download.ps1 이 같이 쓰는 함수. 직접 실행하지 않는다.

$script:Fails = 0

# micromamba, uv 등이 내는 UTF-8 출력을 깨지지 않게 읽는다(한국어 윈도우 기본은 CP949)
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

function Start-Log($path) {
    $script:LogPath = $path
    New-Item -ItemType Directory -Force (Split-Path $path) | Out-Null
    Start-Transcript -Append $path | Out-Null
}

# 멈추고 할 일을 알려 준다
function Stop-Run($what, $fix) {
    Write-Host ''
    Write-Host '################ 멈춤 ################' -ForegroundColor Red
    Write-Host "무엇이: $what" -ForegroundColor Red
    Write-Host "할 일 : $fix"
    Write-Host '할 일을 한 뒤 같은 명령을 다시 실행하세요. 끝난 것은 건너뛰고 이어서 해요.'
    Write-Host "해결되지 않으면 이 기록 파일을 담당자에게 보내 주세요: $script:LogPath"
    Stop-Transcript | Out-Null
    [B200.Power]::SetThreadExecutionState([uint32]2147483648) | Out-Null
    exit 1
}

# 실제 exe 경로를 찾는다. PowerShell 별칭·함수는 건너뛴다
# (micromamba shell init 을 하면 micromamba 가 'Mamba' 모듈의 별칭이 되어 exe 경로가 아니다)
function Find-Exe($name, $root) {
    $c = Get-Command $name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($c) { return $c.Source }
    $cand = @((Join-Path $root "$name.exe"))
    if ($name -eq 'micromamba') {
        $cand += $env:MAMBA_EXE                                              # shell init 이 정해 둔 경로
        $cand += Join-Path $env:LOCALAPPDATA 'micromamba\micromamba.exe'     # 공식 설치 스크립트 기본 위치
        $cand += Join-Path $env:USERPROFILE 'micromamba\micromamba.exe'
    }
    if ($name -eq 'uv') {
        $cand += Join-Path $env:USERPROFILE '.local\bin\uv.exe'              # 공식 설치 스크립트 기본 위치
        $cand += Join-Path $env:USERPROFILE '.cargo\bin\uv.exe'
    }
    foreach ($p in $cand) { if ($p -and (Test-Path $p)) { return $p } }
    return $null
}

# 회사망에서 curl 이 막히는 흔한 경우를 스스로 찾아 우회한다. 모든 curl 호출에 Get-CurlArgs 결과를 붙인다.
$script:CurlExtra = @()
$script:HostArgs  = @{}   # 주소(호스트)마다 따로 쓰는 프록시 설정. 브라우저가 주소마다 다른 프록시를 쓸 때
$script:NoRevoke  = $false
$env:UV_NATIVE_TLS = '1'   # uv 가 윈도우 인증서 저장소를 쓰게 한다(회사 보안 장비 인증서 포함)

function Get-CurlArgs($url) {
    $a = @($script:CurlExtra)
    try { $h = ([uri]$url).Host } catch { $h = '' }
    if ($h -and $script:HostArgs.ContainsKey($h)) { $a += $script:HostArgs[$h] }
    return ,$a
}

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

function Invoke-Probe($url) {
    # HEAD 를 막는 장비가 있어 GET 으로 1바이트만 받는다. 오류 문구는 화면에 보이도록 받아 둔다.
    $ca = Get-CurlArgs $url
    $msg = & curl.exe -sS -o NUL -L -r 0-0 --connect-timeout 15 --max-time 40 --stderr - @ca $url | Out-String
    return [pscustomobject]@{ Code = $LASTEXITCODE; Msg = $msg.Trim() }
}

function Get-WindowsProxy {
    $s = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction SilentlyContinue
    if (-not $s -or $s.ProxyEnable -ne 1 -or -not $s.ProxyServer) { return $null }
    $p = $s.ProxyServer
    if ($p -match 'https=([^;]+)') { $p = $Matches[1] } elseif ($p -match 'http=([^;]+)') { $p = $Matches[1] }
    if ($p -notmatch '://') { $p = "http://$p" }
    return $p
}

function Get-NetHint($code) {
    switch ($code) {
        6       { return '주소를 찾지 못했어요(DNS). 브라우저만 프록시를 쓰는 망일 수 있어요.' }
        7       { return '연결이 거부됐어요. 방화벽이 막았거나 프록시를 거쳐야 하는 망이에요.' }
        28      { return '시간이 초과됐어요. 방화벽이 막았거나 프록시를 거쳐야 하는 망이에요.' }
        35      { return '보안 연결(TLS)에 실패했어요. 회사 보안 장비가 막았을 수 있어요.' }
        56      { return '연결은 됐지만 중간에 끊겼어요. 대부분 회사 프록시나 방화벽이 이 주소를 막은 경우예요.' }
        60      { return '인증서를 믿을 수 없어요. 회사 보안 장비가 인증서를 바꾸는 망이에요.' }
        default { return '' }
    }
}

# 사이트에 접속되는지 보고 [정상]/[문제] 를 찍는다. HTTP 코드는 상관없다.
function Test-Site($name, $url) {
    $first = Invoke-Probe $url
    if ($first.Code -eq 0) { Write-Ok "인터넷: $name"; return $true }

    # 1) 인증서 폐기 확인 서버가 막힌 망: 브라우저는 그냥 넘어가지만 curl 은 실패한다
    if (-not $script:NoRevoke) {
        $script:CurlExtra = @('--ssl-no-revoke')
        if ((Invoke-Probe $url).Code -eq 0) {
            $script:NoRevoke = $true
            $env:MAMBA_SSL_NO_REVOKE = 'true'
            Write-Ok "인터넷: $name"
            Write-Warn '이 망은 인증서 폐기 확인이 막혀 있어서 그 확인을 끄고 진행해요(브라우저도 이렇게 해요).'
            return $true
        }
        $script:CurlExtra = @()
    }

    # 2) 브라우저만 윈도우 프록시 설정을 쓰는 망: 같은 프록시를 스크립트에도 쓴다
    $proxy = Get-WindowsProxy
    if (-not $env:HTTPS_PROXY -and $proxy) {
        $env:HTTPS_PROXY = $proxy; $env:HTTP_PROXY = $proxy
        $ok = (Invoke-Probe $url).Code -eq 0
        if (-not $ok -and -not $script:NoRevoke) {
            $script:CurlExtra = @('--ssl-no-revoke')
            $ok = (Invoke-Probe $url).Code -eq 0
            if ($ok) { $script:NoRevoke = $true; $env:MAMBA_SSL_NO_REVOKE = 'true' } else { $script:CurlExtra = @() }
        }
        if ($ok) {
            Write-Ok "인터넷: $name"
            Write-Warn "윈도우 프록시 설정($proxy)을 찾아 스크립트에도 써요."
            return $true
        }
        Remove-Item Env:HTTPS_PROXY, Env:HTTP_PROXY -ErrorAction SilentlyContinue
    }

    # 3) 브라우저는 닿는데 curl 만 막히는 망: 브라우저가 이 주소에 쓰는 프록시(PAC 포함)와
    #    윈도우 로그인 인증(브라우저가 자동으로 하는 것)을 이 주소에만 똑같이 쓴다
    $site = ([uri]$url).Host
    $bp = Get-BrowserProxy $url
    $px = if ($bp) { $bp } elseif ($env:HTTPS_PROXY) { $env:HTTPS_PROXY } else { Get-WindowsProxy }
    $cands = @()
    if ($bp) { $cands += ,@('--proxy', $bp) }
    if ($px) {
        $cands += ,@('--proxy', $px, '--proxy-negotiate', '--proxy-user', ':')
        $cands += ,@('--proxy', $px, '--proxy-ntlm', '--proxy-user', ':')
    }
    $saved = $script:CurlExtra
    foreach ($c in $cands) {
        foreach ($nr in $false, $true) {
            $script:CurlExtra = if ($nr) { @('--ssl-no-revoke') } else { $saved }
            $script:HostArgs[$site] = $c
            if ((Invoke-Probe $url).Code -eq 0) {
                if ($nr) { $script:NoRevoke = $true; $env:MAMBA_SSL_NO_REVOKE = 'true' }
                $how = if ($c.Count -gt 2) { "프록시 $px, 윈도우 로그인 인증" } else { "브라우저의 자동 프록시 설정이 고른 프록시 $bp" }
                Write-Ok "인터넷: $name"
                Write-Warn "브라우저와 같은 방법으로 접속해요: $site ($how)"
                return $true
            }
        }
    }
    $script:CurlExtra = $saved
    $script:HostArgs.Remove($site)

    Write-Bad "인터넷: $name 접속 안 됨 ($url)"
    Write-Info "    curl 오류 $($first.Code): $($first.Msg)"
    $hint = Get-NetHint $first.Code
    if ($hint) { Write-Info "    $hint" }
    $site = ([uri]$url).Host
    if ($first.Msg -match 'CONNECT tunnel failed, response (\d+)') {
        Write-Info "    → 회사 프록시가 이 주소($site) 연결을 거절했어요(프록시 응답 $($Matches[1])). 이 주소만 막힌 거예요."
        Write-Info "      사내 IT에 $site (포트 443) 접속 허용을 요청하세요."
    } elseif ($first.Msg -match 'reset|abort|closed') {
        Write-Info "    → 방화벽이나 보안 장비가 이 주소($site) 연결을 중간에 끊었어요. 사내 IT에 $site (포트 443) 접속 허용을 요청하세요."
    }
    Write-Info "    확인: 브라우저에서 https://$site/ 를 열어 보세요. 오류 글자(XML)라도 뜨면 브라우저로는 닿는 거고, '연결할 수 없음'이 뜨면 브라우저도 막힌 거예요."
    $pac = (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction SilentlyContinue).AutoConfigURL
    if ($pac) { Write-Info "    이 PC 브라우저는 자동 프록시 설정(PAC)을 써요: $pac" }
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
# 진전 없이 끊긴 횟수만 세고, 기다리는 시간을 30초씩 늘린다(최대 5분). 새 횟수를 돌려준다.
function Step-Retry($stall, $before, $after, $max, $what) {
    if ($after -gt $before) {
        Write-Warn "$what 연결이 끊겼어요. 받은 데까지($(Format-Size $after)) 이어서 받아요"
        Start-Sleep 10
        return 0
    }
    $stall++
    $wait = [math]::Min(300, 30 * $stall)
    Write-Warn "$what 연결이 끊겼고 더 받지 못했어요. ${wait}초 뒤 다시 해요(더 받지 못한 채 끊긴 횟수 $stall/$max)"
    Start-Sleep $wait
    return $stall
}

# 받은 파일이 알려 준 체크섬과 맞는지 본다. 체크섬을 안 주면 맞는 것으로 친다
function Test-Sum($file, $md5, $sha256) {
    if ($sha256) { return (Get-FileHash $file -Algorithm SHA256).Hash -eq $sha256.ToUpper() }
    if ($md5)    { return (Get-FileHash $file -Algorithm MD5).Hash -eq $md5.ToUpper() }
    return $true
}

# 이어받기 + 다시 시도. md5 나 sha256 을 주면 받은 뒤 맞는지 본다. 성공하면 $true.
# 받은 양이 늘고 있는 동안은 몇 번 끊겨도 계속하고, 진전 없이 $tries 번 끊기면 포기한다.
function Get-File($url, $file, $md5, $tries, $sha256) {
    if ((Test-Path $file) -and ($md5 -or $sha256) -and (Test-Sum $file $md5 $sha256)) { return $true }
    $stall = 0
    while ($stall -lt $tries) {
        $before = Get-Size $file
        $ca = Get-CurlArgs $url
        & curl.exe -sS -L -C - --fail --retry 3 --connect-timeout 30 -Y 1024 -y 120 @ca -o $file $url
        $code = $LASTEXITCODE
        if ($code -eq 0) {
            if (Test-Sum $file $md5 $sha256) { return $true }
            Write-Warn "체크섬이 맞지 않아 다시 받아요: $(Split-Path -Leaf $file)"
            Remove-Item -Force $file
            $stall++
            continue
        }
        if ($code -eq 33 -or $code -eq 36 -or $code -eq 22) {
            Remove-Item -Force -ErrorAction SilentlyContinue $file   # 이어받기가 안 되면 처음부터
        }
        $stall = Step-Retry $stall $before (Get-Size $file) $tries "$(Split-Path -Leaf $file) (curl $code)"
    }
    return $false
}

# B200 서버에서 root 가 확인할 지문(sha256, 소문자).
# 파일 하나면 그 파일의 sha256(서버: sha256sum 파일), 여러 개면 이어 붙인 내용의 sha256(서버: cat 파일들 | sha256sum)
function Get-Fingerprint([string[]]$files) {
    if ($files.Count -eq 1) { return (Get-FileHash $files[0] -Algorithm SHA256).Hash.ToLower() }
    $ms = New-Object IO.MemoryStream
    foreach ($f in $files) { $b = [IO.File]::ReadAllBytes($f); $ms.Write($b, 0, $b.Length) }
    $ms.Position = 0
    $h = [Security.Cryptography.SHA256]::Create().ComputeHash($ms)
    return (($h | ForEach-Object { $_.ToString('x2') }) -join '')
}

# 실행 중 접근 PC 절전 막기(끝나면 원래대로)
Add-Type -Namespace B200 -Name Power -MemberDefinition `
    '[DllImport("kernel32.dll")] public static extern uint SetThreadExecutionState(uint f);' -ErrorAction SilentlyContinue
function Stop-Sleep  { [B200.Power]::SetThreadExecutionState([uint32]2147483649) | Out-Null }  # ES_CONTINUOUS | ES_SYSTEM_REQUIRED
function Allow-Sleep { [B200.Power]::SetThreadExecutionState([uint32]2147483648) | Out-Null }  # ES_CONTINUOUS
