<#
[접근 PC] WildScenes 링크가 브라우저로는 받아지는데 스크립트(curl)로는 401 같은 오류가 날 때, 왜 그런지 여러 방법으로 시험해
결과를 reports\wildscenes_check_공유용_<날짜>.txt 에 남기고, 물어본 뒤 git 으로 올린다(담당자가 그 파일을 읽는다).
아무것도 받지 않는다(링크마다 앞 1 KB 만 요청한다). 서명·키, 프록시 주소, 사내 IP 는 가려서 적는다.

  powershell -ExecutionPolicy Bypass -File .\pc\wildscenes_check.ps1                    # .env 의 WILDSCENES_LINKS 목록에서
  powershell -ExecutionPolicy Bypass -File .\pc\wildscenes_check.ps1 -Links C:\Users\나\Downloads\61541v001.txt
#>
param(
    [string]$Links = '',
    [switch]$NoPush            # 파일만 만들고 git 으로 올리지 않는다
)
$here = $PSScriptRoot
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $here 'gpu_common.ps1')
if (-not $Links -and $env:WILDSCENES_LINKS) { $Links = [Environment]::ExpandEnvironmentVariables($env:WILDSCENES_LINKS) }
$stamp = Get-Date -Format 'yyyyMMdd-HHmm'
$outFile = Join-Path $root "reports\wildscenes_check_공유용_$stamp.txt"
$lines = New-Object System.Collections.Generic.List[string]
function Add-Line($s) { $lines.Add($s); Write-Host $s }

# 가리기: 주소의 ? 뒤 값, 사내 IP, 서명·키처럼 보이는 값
function Hide-Text($s) {
    if (-not $s) { return '' }
    $s = $s -replace '\?[^\s"<>]*', '?…'
    $s = $s -replace '(^|[^0-9.])(10\.\d{1,3}|192\.168|172\.(1[6-9]|2\d|3[01]))\.\d{1,3}\.\d{1,3}', '$1(사내 IP)'
    $s = $s -replace '(?i)(Signature|Credential|AccessKeyId|Security-Token|Token|Expires)([=:>]\s*)[^&\s<"]+', '$1$2…'
    $s = $s -replace '(AKIA|ASIA)[0-9A-Z]{16}', '(키)'
    return $s
}
# Via 머리글 같은 곳의 사내 장비 이름은 빼고 제품 이름(괄호 안)만 남긴다
function Hide-Via($v) { if ($v -match '\(([^)]+)\)') { return "… ($($Matches[1]))" } return '… (이름 가림)' }
function Proxy-Label($p) { if (-not $p) { return '없음' } try { $u = [uri]$p; return "있음($($u.Scheme), 포트 $($u.Port))" } catch { return '있음' } }

Write-Host "[접근 PC] WildScenes 링크 점검  ($(Get-Date -Format 'yyyy-MM-dd HH:mm'))"
if (-not $Links -or -not (Test-Path $Links)) {
    Write-Host '  [문제] 링크 목록 파일을 찾지 못했어요. -Links 뒤에 포털에서 받은 .txt 경로를 적거나 .env 의 WILDSCENES_LINKS 에 적으세요.' -ForegroundColor Red
    exit 1
}
# 목록에서 WildScenes2d 링크 하나와 그 아래 옵션 줄(header= 등)
$url = $null; $opts = @()
foreach ($l in [IO.File]::ReadAllLines($Links)) {
    if ($url) { if ($l -match '^\s+(\S+?)=') { $opts += $Matches[1]; continue } else { break } }
    $u = [regex]::Match($l, 'https://\S+').Value.Trim('"')
    if ($u -and [uri]::UnescapeDataString(($u -split '\?')[0]) -match '(?i)/WildScenes_?2d/') { $url = $u }
}
if (-not $url) { Write-Host '  [문제] 목록에 WildScenes2d 링크가 없어요.' -ForegroundColor Red; exit 1 }
$site = ([uri]$url).Host
$qnames = @(([uri]$url).Query.TrimStart('?') -split '&' | Where-Object { $_ } | ForEach-Object { ($_ -split '=')[0] })

Add-Line "WildScenes 링크 점검  $(Get-Date -Format 'yyyy-MM-dd HH:mm')"
Add-Line "윈도우: $([Environment]::OSVersion.VersionString), PowerShell $($PSVersionTable.PSVersion)"
Add-Line "curl: $((& curl.exe -V | Select-Object -First 1))"
Add-Line "목록 파일: 만든 시각 $((Get-Item $Links).LastWriteTime.ToString('yyyy-MM-dd HH:mm')), 줄 $(([IO.File]::ReadAllLines($Links)).Count)개"
Add-Line "시험한 주소: https://$site$(([uri]$url).AbsolutePath)?…"
Add-Line "주소 뒤에 붙은 값 이름: $($qnames -join ', ')"
Add-Line "주소 모양: 길이 $($url.Length), 공백 $(if ($url -match ' ') {'있음'} else {'없음'}), 한글·특수 글자 $(if ($url -match '[^\x21-\x7E]') {'있음'} else {'없음'}), % 부호 $(([regex]::Matches($url, '%')).Count)개, + 부호 $(([regex]::Matches($url, '\+')).Count)개"
Add-Line "링크 아래 옵션 줄: $(if ($opts.Count) { $opts -join ', ' } else { '없음' })"
$wp = Get-WindowsProxy
$bp = Get-BrowserProxy $url
Add-Line ".env 의 HTTPS_PROXY: $(Proxy-Label $env:HTTPS_PROXY)"
Add-Line "윈도우 프록시 설정: $(Proxy-Label $wp)"
Add-Line "브라우저가 이 주소에 쓰는 프록시(PAC 포함): $(Proxy-Label $bp)$(if ($bp -and $wp -and $bp -ne $wp) { ' ← 윈도우 프록시와 달라요' })"
$pac = (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction SilentlyContinue).AutoConfigURL
Add-Line "자동 프록시 설정(PAC): $(if ($pac) { '있음' } else { '없음' })"
Add-Line ''

# 시험 하나: curl 로 앞 1 KB 만 요청해 상태·머리글·본문 앞부분을 적는다
function Test-Curl($name, [string[]]$extra) {
    $hd = [IO.Path]::GetTempFileName(); $bd = [IO.Path]::GetTempFileName()
    try {
        $err = & curl.exe -sS -L -r 0-1023 --ssl-no-revoke --connect-timeout 20 --max-time 60 @extra -D $hd -o $bd -w '%{http_code}' $url 2>&1
        $code = $LASTEXITCODE
        $http = (@($err) | Where-Object { $_ -match '^\d{3}$' } | Select-Object -Last 1)
        $msg = (@($err) | Where-Object { $_ -notmatch '^\d{3}$' }) -join ' '
        $ok = $code -eq 0 -and $http -match '^20[06]$'
        Add-Line "== $name"
        Add-Line "   결과: $(if ($ok) { '받아져요' } else { '안 돼요' }) (HTTP $http, curl $code)$(if ($msg) { ' ' + (Hide-Text $msg) })"
        foreach ($h in [IO.File]::ReadAllLines($hd)) {
            if ($h -match 'Connection Established') { continue }
            if ($h -match '^(?i)(HTTP/|server:|www-authenticate:|proxy-authenticate:|x-amz-request-id:|x-amz-error|content-type:|x-cache|x-squid|x-bluecoat|x-zscaler|x-fortinet)') { Add-Line "   머리글: $(Hide-Text $h.Trim())" }
            elseif ($h -match '^(?i)via:\s*(.*)$') { Add-Line "   머리글: via: $(Hide-Via $Matches[1])" }
        }
        if (-not $ok) {
            $body = [IO.File]::ReadAllText($bd)
            if ($body) { $b = Hide-Text (($body -replace '\s+', ' ').Trim()); Add-Line "   본문 앞부분: $($b.Substring(0, [math]::Min(400, $b.Length)))" }
        }
        Add-Line ''
        return $ok
    } finally { Remove-Item -Force -ErrorAction SilentlyContinue $hd, $bd }
}

# 시험 하나: .NET(브라우저처럼 윈도우 시스템 프록시와 윈도우 로그인을 쓴다)
function Test-DotNet {
    Add-Line '== .NET (브라우저처럼 시스템 프록시·윈도우 로그인 사용)'
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $req = [Net.HttpWebRequest]::Create($url)
        $req.Proxy = [Net.WebRequest]::GetSystemWebProxy()
        $req.Proxy.Credentials = [Net.CredentialCache]::DefaultNetworkCredentials
        $req.AddRange(0, 1023); $req.Timeout = 60000; $req.AllowAutoRedirect = $true
        $res = $req.GetResponse()
        Add-Line "   결과: 받아져요 (HTTP $([int]$res.StatusCode))"
        Add-Line "   머리글: server: $(Hide-Text $res.Headers['Server'])"
        $res.Close()
        Add-Line ''
        return $true
    } catch [Net.WebException] {
        $r = $_.Exception.Response
        if ($r) {
            Add-Line "   결과: 안 돼요 (HTTP $([int]$r.StatusCode))"
            foreach ($k in 'Server', 'WWW-Authenticate', 'Proxy-Authenticate', 'Content-Type') { if ($r.Headers[$k]) { Add-Line "   머리글: ${k}: $(Hide-Text $r.Headers[$k])" } }
            if ($r.Headers['Via']) { Add-Line "   머리글: via: $(Hide-Via $r.Headers['Via'])" }
            try { $sr = New-Object IO.StreamReader($r.GetResponseStream()); $b = Hide-Text (($sr.ReadToEnd() -replace '\s+', ' ').Trim()); if ($b) { Add-Line "   본문 앞부분: $($b.Substring(0, [math]::Min(400, $b.Length)))" } } catch { }
        } else { Add-Line "   결과: 안 돼요 ($(Hide-Text $_.Exception.Message))" }
    } catch { Add-Line "   결과: 안 돼요 ($(Hide-Text $_.Exception.Message))" }
    Add-Line ''
    return $false
}

$res = [ordered]@{}
$res['curl 그대로(.env 설정 그대로)'] = Test-Curl 'curl 그대로(.env 설정 그대로)' @()
$res['curl, 프록시 없이 바로'] = Test-Curl 'curl, 프록시 없이 바로' @('--noproxy', '*')
$px = @($wp, $bp) | Where-Object { $_ } | Select-Object -Unique
$i = 0
foreach ($p in $px) {
    $i++
    $tag = if ($p -eq $bp -and $p -ne $wp) { "브라우저 자동 프록시" } elseif ($p -eq $wp -and $p -eq $bp) { "윈도우 프록시(브라우저와 같음)" } else { "윈도우 프록시" }
    $res["curl, $tag"] = Test-Curl "curl, $tag" @('--proxy', $p)
    $res["curl, $tag + 윈도우 로그인(negotiate)"] = Test-Curl "curl, $tag + 윈도우 로그인(negotiate)" @('--proxy', $p, '--proxy-negotiate', '--proxy-user', ':')
    $res["curl, $tag + 윈도우 로그인(ntlm)"] = Test-Curl "curl, $tag + 윈도우 로그인(ntlm)" @('--proxy', $p, '--proxy-ntlm', '--proxy-user', ':')
}
$res['.NET(브라우저와 같은 시스템 프록시)'] = Test-DotNet

# 받기 스크립트(datasets_download.ps1)와 똑같이: 점검(Test-Site)이 고른 설정을 붙이고, 같은 curl 옵션으로 이 파일 하나를 끝까지 받는다
Add-Line '== 받기 스크립트와 같은 방법'
Test-Site 'CSIRO S3 저장소' "https://$site/" | Out-Null
$ha = $script:HostArgs[$site]
Add-Line "   점검이 고른 설정: 추가 인자 $(if ($script:CurlExtra.Count) { $script:CurlExtra -join ' ' } else { '없음' }), 이 주소 전용 $(if ($ha) { (@($ha) | ForEach-Object { if ($_ -match '://') { '(프록시)' } else { $_ } }) -join ' ' } else { '없음' })"
$tmpd = Join-Path ([IO.Path]::GetTempPath()) "ws_check_$stamp"
New-Item -ItemType Directory -Force $tmpd | Out-Null
$tf = Join-Path $tmpd 'f'
foreach ($round in 1, 2) {
    # 2번째는 이미 받은 파일이 있는 상태(-C - 이어받기)에서 다시 받는다. 받기 스크립트가 다시 실행될 때와 같다
    $ca = Get-CurlArgs $url
    $msg = & curl.exe -sS -L -C - --fail --retry 3 --retry-delay 5 --connect-timeout 30 -Y 1024 -y 120 @ca -o $tf --stderr - $url | Out-String
    $code = $LASTEXITCODE
    $sz = if (Test-Path $tf) { (Get-Item $tf).Length } else { 0 }
    $what = if ($round -eq 1) { '처음 받기' } else { '받은 파일이 있는 채로 다시(이어받기)' }
    Add-Line "   $($what): $(if ($code -eq 0) { '받아져요' } else { '안 돼요' }) (curl $code, 파일 $sz 바이트)$(if ($msg.Trim()) { ' ' + (Hide-Text $msg.Trim()) })"
    $res["받기 스크립트와 같은 방법: $what"] = ($code -eq 0)
}
Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $tmpd
$rel = [regex]::Match([uri]::UnescapeDataString(($url -split '\?')[0]), '(?i)/WildScenes_?2d/(.+)$').Groups[1].Value -replace '/', '\'
$local = Join-Path $root "datasets\wildscenes\$rel"
Add-Line "   받기 폴더의 같은 파일(datasets\wildscenes\$rel): $(if (Test-Path $local) { "있음, $((Get-Item $local).Length) 바이트" } else { '없음' })"
$doneF = Join-Path $root 'datasets\wildscenes.links_done.txt'
Add-Line "   다 받은 파일 목록(wildscenes.links_done.txt): $(if (Test-Path $doneF) { "$(([IO.File]::ReadAllLines($doneF)).Count)개" } else { '없음' })"
Add-Line ''

# 지난번 받기 기록(datasets\download.log)의 마지막 실행에서 WildScenes 와 멈춤·문제 줄만(가려서)
$log = Join-Path $root 'datasets\download.log'
Add-Line '== 지난번 받기 기록(datasets\download.log, 마지막 실행의 WildScenes·멈춤·문제 줄)'
if (Test-Path $log) {
    $all = [IO.File]::ReadAllLines($log)
    $start = 0
    for ($k = $all.Count - 1; $k -ge 0; $k--) { if ($all[$k] -match '\[접근 PC\] 세그멘테이션 데이터셋 받기') { $start = $k; break } }
    $pick = @($all[$start..($all.Count - 1)] | Where-Object { $_ -match '(?i)wildscenes|CSIRO|S3|멈춤|멈춘 이유|할 일|\[문제\]|curl' } | Select-Object -Last 60)
    foreach ($l in $pick) {
        if ($env:USERPROFILE) { $l = $l.Replace($env:USERPROFILE, '%USERPROFILE%') }   # 윈도우 계정 이름은 가린다
        Add-Line "   $(Hide-Text $l.TrimEnd())"
    }
    if (-not $pick.Count) { Add-Line '   (해당 줄 없음)' }
} else { Add-Line '   기록 파일 없음' }
Add-Line ''

Add-Line '== 요약'
foreach ($k in $res.Keys) { Add-Line ("   {0}  {1}" -f $(if ($res[$k]) { '[됨]  ' } else { '[안 됨]' }), $k) }

New-Item -ItemType Directory -Force (Split-Path $outFile) | Out-Null
[IO.File]::WriteAllText($outFile, (($lines -join "`n") + "`n"), (New-Object Text.UTF8Encoding $false))
Write-Host ''
Write-Host " 결과 파일: $outFile" -ForegroundColor Green
Write-Host ' 서명·키, 프록시 주소, 사내 IP 는 가려 두었어요. 올리기 전에 한 번 열어 보세요.'
if ($NoPush) { exit 0 }
$a = Read-Host ' 이 파일을 git 으로 올릴까요? [Y/n]'
if ($a -match '^[nN]') { Write-Host ' 올리지 않았어요. 나중에: git add reports && git commit -m "WildScenes 링크 점검 결과" && git push'; exit 0 }
Push-Location $root
try {
    & git add -- $outFile
    & git commit -m "WildScenes 링크 점검 결과($stamp)" -- $outFile
    if ($LASTEXITCODE -ne 0) { Write-Host ' [문제] 커밋하지 못했어요. 위 메시지를 보세요(커밋 검사가 멈췄다면 파일에서 그 줄을 지우고 다시 실행하세요).' -ForegroundColor Red; exit 1 }
    & git pull --rebase --autostash
    & git push
    if ($LASTEXITCODE -eq 0) { Write-Host ' 올렸어요. 담당자에게 알려 주세요.' -ForegroundColor Green }
    else { Write-Host ' [문제] 올리지 못했어요. 인터넷 연결을 확인하고 git push 를 다시 하세요.' -ForegroundColor Red }
} finally { Pop-Location }
