<#
[접근 PC · 팀원용] 공개 도커 이미지를 받아 B200 서버로 올릴 파일(.tar) 하나로 만든다. 도커 설치가 필요 없다.
이 파일 하나만 있으면 된다(윈도우 기본 PowerShell, curl, tar 만 쓴다). 끊기면 같은 명령을 다시 실행하면 이어받는다.

  powershell -ExecutionPolicy Bypass -File .\image_download.ps1 nvcr.io/nvidia/pytorch:25.10-py3
  powershell -ExecutionPolicy Bypass -File .\image_download.ps1 pytorch/pytorch:2.9.0-cuda13.0-cudnn9-runtime -Login   # Docker Hub 로그인
  powershell -ExecutionPolicy Bypass -File .\image_download.ps1 ghcr.io/조직/이미지:태그 -Out D:\images

결과: <받는 폴더>\<이미지>_<태그>.tar 와 .tar.sha256 → B200 서버 /app/inbox/images/<내 이름>/ 에 올리고, 서버에서 b200 image-load
#>
param(
    [Parameter(Mandatory = $true, Position = 0)][string]$Image,
    [string]$Out = (Join-Path ([Environment]::GetFolderPath('Desktop')) 'b200_images'),
    [switch]$Login,              # 로그인이 필요한 저장소나 Docker Hub 받기 한도에 걸렸을 때. 아이디와 토큰(비밀번호)을 묻는다
    [int]$MaxTries = 30
)
$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = New-Object Text.UTF8Encoding $false } catch { }
function Write-Ok($m)   { Write-Host "  [정상] $m" -ForegroundColor Green }
function Write-Warn($m) { Write-Host "  [주의] $m" -ForegroundColor Yellow }
function Write-Info($m) { Write-Host "  $m" }
function Stop-Run($what, $fix) {
    Write-Host ''
    Write-Host '################ 멈춤 ################' -ForegroundColor Red
    Write-Host "무엇이: $what" -ForegroundColor Red
    Write-Host "할 일 : $fix"
    Write-Host '고친 뒤 같은 명령을 다시 실행하면 받은 데까지 건너뛰고 이어서 한다.'
    exit 1
}

# ---------------------------------------------------------------- 회사망 대응(인증서 폐기 확인, 프록시)
$script:Extra = @()
function Get-BrowserProxy($url) {
    try {
        $wp = [System.Net.WebRequest]::GetSystemWebProxy(); $u = [uri]$url
        if ($wp.IsBypassed($u)) { return $null }
        $r = $wp.GetProxy($u); if ($r -and $r.AbsoluteUri -ne $u.AbsoluteUri) { return $r.AbsoluteUri.TrimEnd('/') }
    } catch { }
    return $null
}
function Invoke-Probe($url) {
    $m = & curl.exe -sS -o NUL -L -r 0-0 --connect-timeout 15 --max-time 40 --stderr - @Extra $url | Out-String
    return [pscustomobject]@{ Code = $LASTEXITCODE; Msg = $m.Trim() }
}
# 접속이 안 되면 브라우저와 같은 방법(인증서 폐기 확인 끄기, 브라우저 프록시, 윈도우 로그인 인증)을 차례로 써 본다
function Test-Site($name, $url) {
    $first = Invoke-Probe $url
    if ($first.Code -eq 0) { Write-Ok "인터넷: $name"; return $true }
    $bp = Get-BrowserProxy $url
    $tries = @(, @('--ssl-no-revoke'))
    if ($bp) {
        $tries += , @('--proxy', $bp); $tries += , @('--ssl-no-revoke', '--proxy', $bp)
        $tries += , @('--ssl-no-revoke', '--proxy', $bp, '--proxy-negotiate', '--proxy-user', ':')
        $tries += , @('--ssl-no-revoke', '--proxy', $bp, '--proxy-ntlm', '--proxy-user', ':')
    }
    foreach ($t in $tries) {
        $script:Extra = $t
        if ((Invoke-Probe $url).Code -eq 0) { Write-Ok "인터넷: $name"; Write-Warn "브라우저와 같은 방법으로 접속한다($($t -join ' '))"; return $true }
    }
    $script:Extra = @()
    Write-Host "  [문제] 인터넷: $name 에 접속 안 됨 ($url)" -ForegroundColor Red
    Write-Info "    curl 오류 $($first.Code): $($first.Msg)"
    if ($first.Msg -match 'CONNECT tunnel failed') { Write-Info "    회사 프록시가 $(([uri]$url).Host) 를 막았다. 사내 IT에 허용을 요청한다." }
    return $false
}

function Format-Size($b) { if ($b -ge 1GB) { '{0:N1} GB' -f ($b / 1GB) } else { '{0:N0} MB' -f ($b / 1MB) } }

# ---------------------------------------------------------------- 이미지 이름 풀기
# nvcr.io/nvidia/pytorch:25.10-py3 → 저장소 nvcr.io, 이름 nvidia/pytorch, 태그 25.10-py3
$first = $Image.Split('/')[0]
if ($Image.Contains('/') -and ($first.Contains('.') -or $first.Contains(':') -or $first -eq 'localhost')) {
    $reg = $first; $rest = $Image.Substring($first.Length + 1)
} else { $reg = 'docker.io'; $rest = $Image }
if ($reg -eq 'docker.io' -and -not $rest.Contains('/')) { $rest = "library/$rest" }
if ($rest.Contains('@')) { $repo, $ref = $rest.Split('@', 2) }
elseif ($rest.Split('/')[-1].Contains(':')) { $i = $rest.LastIndexOf(':'); $repo = $rest.Substring(0, $i); $ref = $rest.Substring($i + 1) }
else { $repo = $rest; $ref = 'latest' }
$api = if ($reg -eq 'docker.io') { 'registry-1.docker.io' } else { $reg }
$tagName = if ($ref.StartsWith('sha256:')) { "$($Image.Split('@')[0]):sha-$($ref.Substring(7, 12))" } elseif ($Image.Contains(':') -and $Image.Split('/')[-1].Contains(':')) { $Image } else { "${Image}:latest" }
$safe = ($tagName -replace '^.*/', '' -replace '[:@]', '_' -replace '[^\w.\-]', '_')
New-Item -ItemType Directory -Force $Out | Out-Null
$Out = (Resolve-Path $Out).Path
$work = Join-Path $Out "$safe.parts"
$tar = Join-Path $Out "$safe.tar"
Start-Transcript -Append (Join-Path $Out "$safe.log") | Out-Null
Write-Host "[접근 PC] 도커 이미지 받기  $tagName  ($(Get-Date -Format 'yyyy-MM-dd HH:mm'))"
Write-Host "받는 곳: $Out"

# ---------------------------------------------------------------- 1. 점검
Write-Host ''; Write-Host '==== [1/4] 점검 ====' -ForegroundColor Cyan
foreach ($e in 'curl.exe', 'tar.exe') { if (-not (Get-Command $e -ErrorAction SilentlyContinue)) { Stop-Run "$e 가 없다" '윈도우 10 1803 이후에 기본으로 있다. 윈도우를 업데이트한다.' } }
if (-not (Test-Site "이미지 저장소 $reg" "https://$api/v2/")) { Stop-Run "$reg 에 접속 안 된다" '위 [문제] 아래 설명을 본다.' }

$cred = $null
if ($Login) {
    $u = Read-Host '  아이디'
    $s = Read-Host '  토큰(또는 비밀번호, 화면에 안 보임)' -AsSecureString
    $b = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($s)
    try { $cred = "${u}:$([Runtime.InteropServices.Marshal]::PtrToStringBSTR($b))" } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b) }
}

# 저장소가 요구하는 대로 받기 허가(토큰)를 얻는다. 몇 분 뒤 만료되므로 필요할 때마다 새로 받는다
$script:Token = $null
function Update-Token {
    $h = & curl.exe -sS -o NUL -D - @Extra "https://$api/v2/" | Out-String
    if ($h -notmatch '(?im)^www-authenticate:\s*Bearer\s+(.*)$') { $script:Token = $null; return }
    $p = @{}; [regex]::Matches($Matches[1], '(\w+)="([^"]*)"') | ForEach-Object { $p[$_.Groups[1].Value] = $_.Groups[2].Value }
    $url = "$($p.realm)?service=$([uri]::EscapeDataString("$($p.service)"))&scope=repository:${repo}:pull"
    $auth = if ($cred) { @('-u', $cred) } else { @() }
    $j = & curl.exe -sS @Extra @auth $url | Out-String
    try { $o = $j | ConvertFrom-Json } catch { Stop-Run '받기 허가(토큰)를 얻지 못했다' "저장소 응답: $($j.Substring(0, [math]::Min(200, $j.Length)))" }
    if ($o.token) { $script:Token = $o.token } elseif ($o.access_token) { $script:Token = $o.access_token }
    else { Stop-Run '받기 허가(토큰)를 얻지 못했다' '아이디·토큰이 맞는지, 비공개 이미지면 -Login 을 붙였는지 본다.' }
}
function Get-AuthHeader { if ($script:Token) { @('-H', "Authorization: Bearer $script:Token") } else { @() } }

$Accept = 'application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, ' +
          'application/vnd.docker.distribution.manifest.v2+json, application/vnd.oci.image.manifest.v1+json'
function Get-Manifest($r) {
    for ($k = 0; $k -lt 3; $k++) {
        $ah = Get-AuthHeader
        $j = & curl.exe -sS @Extra @ah -H "Accept: $Accept" "https://$api/v2/$repo/manifests/$r" | Out-String
        try { $o = $j | ConvertFrom-Json } catch { $o = $null }
        if ($o -and $o.errors) {
            $c = $o.errors[0].code
            if ($c -eq 'UNAUTHORIZED') { Update-Token; continue }
            if ($c -eq 'TOOMANYREQUESTS') { Stop-Run 'Docker Hub 받기 한도에 걸렸다(로그인 안 한 사용자는 회사 전체가 같이 센다)' 'Docker Hub 계정을 만들어 -Login 을 붙여 다시 실행한다(토큰은 hub.docker.com 의 Account settings → Personal access tokens).' }
            if ($c -eq 'MANIFEST_UNKNOWN' -or $c -eq 'NAME_UNKNOWN') { Stop-Run "이미지나 태그가 없다: $Image" '이미지 이름과 태그를 저장소 페이지에서 다시 확인한다.' }
            if ($c -eq 'DENIED') { Stop-Run '이 이미지를 받을 권한이 없다' '비공개 이미지면 -Login 을 붙인다.' }
            Stop-Run "저장소 오류 $c" ($o.errors[0].message)
        }
        if ($o) { return $o }
    }
    Stop-Run '이미지 목록(manifest)을 읽지 못했다' "저장소 응답: $($j.Substring(0, [math]::Min(200, $j.Length)))"
}

# ---------------------------------------------------------------- 2. 목록
Write-Host ''; Write-Host '==== [2/4] 이미지 목록 읽기 ====' -ForegroundColor Cyan
Update-Token
$mf = Get-Manifest $ref
if ($mf.manifests) {
    # 여러 플랫폼용이면 B200 서버에 맞는 linux/amd64 를 고른다
    $pick = $mf.manifests | Where-Object { $_.platform.os -eq 'linux' -and $_.platform.architecture -eq 'amd64' } | Select-Object -First 1
    if (-not $pick) { Stop-Run 'linux/amd64 용 이미지가 없다' "있는 플랫폼: $(($mf.manifests | ForEach-Object { "$($_.platform.os)/$($_.platform.architecture)" }) -join ', ')" }
    $mf = Get-Manifest $pick.digest
}
if (-not $mf.layers) { Stop-Run '이미지 목록 형식을 모르겠다' '담당자에게 이미지 이름을 알려 준다.' }
$blobs = @($mf.config) + @($mf.layers)
$total = ($blobs | Measure-Object -Property size -Sum).Sum
Write-Ok "linux/amd64, 조각 $($mf.layers.Count)개, $(Format-Size $total)"
$free = (Get-Item $Out).PSDrive.Free
if ($free -lt $total * 2.1) { Stop-Run "남은 공간이 부족하다($(Format-Size $free), 필요 약 $(Format-Size ($total * 2.1)))" '-Out 으로 공간이 넉넉한 드라이브를 고른다.' }

# ---------------------------------------------------------------- 3. 받기
Write-Host ''; Write-Host '==== [3/4] 받기 (끊기면 이어받는다, 조각마다 sha256 검사) ====' -ForegroundColor Cyan
$bdir = Join-Path $work 'blobs\sha256'
New-Item -ItemType Directory -Force $bdir | Out-Null
$n = 0
foreach ($b in $blobs) {
    $n++
    $hex = $b.digest.Split(':')[1]
    $f = Join-Path $bdir $hex
    $label = "($n/$($blobs.Count)) $($hex.Substring(0, 12)) $(Format-Size $b.size)"
    if ((Test-Path $f) -and (Get-Item $f).Length -eq $b.size -and (Get-FileHash $f -Algorithm SHA256).Hash -eq $hex.ToUpper()) { Write-Host "  $label 이미 받음"; continue }
    Write-Host "  $label"
    $stall = 0
    while ($true) {
        $before = if (Test-Path $f) { (Get-Item $f).Length } else { 0 }
        $ah = Get-AuthHeader
        # 조각은 저장소가 다른 다운로드 서버로 넘겨준다(-L). 허가 머리글은 curl 이 그 서버에는 보내지 않는다
        $msg = & curl.exe -L -C - --fail -sS --connect-timeout 30 -Y 1024 -y 120 --retry 3 @Extra @ah -o $f --stderr - `
            "https://$api/v2/$repo/blobs/$($b.digest)" | Out-String
        $code = $LASTEXITCODE
        $now = if (Test-Path $f) { (Get-Item $f).Length } else { 0 }
        if ($code -eq 0 -and $now -eq $b.size) {
            if ((Get-FileHash $f -Algorithm SHA256).Hash -eq $hex.ToUpper()) { break }
            Write-Warn '조각이 깨져 처음부터 다시 받는다'; Remove-Item -Force $f; $stall++; continue
        }
        if ($msg -match 'returned error: 401') { Update-Token; continue }
        if ($code -eq 33 -or $code -eq 36 -or $msg -match 'returned error: 416') { Remove-Item -Force -ErrorAction SilentlyContinue $f }
        if ($stall -eq 0 -and $code -in 5, 6, 7, 28, 35, 56) {
            # 저장소는 열리는데 다운로드 서버만 막힌 경우를 알려 준다
            $loc = & curl.exe -sS -o NUL -w '%{redirect_url}' @Extra @ah "https://$api/v2/$repo/blobs/$($b.digest)"
            if ($loc) { Write-Warn "조각은 $(([uri]$loc).Host) 에서 내려온다. 이 주소가 막혔으면 사내 IT에 허용을 요청한다. (curl $code)" }
        }
        if ($now -gt $before) { $stall = 0; Write-Warn "끊김. 받은 만큼($(Format-Size $now)) 이어서 받는다"; Start-Sleep 10; continue }
        $stall++
        if ($stall -ge $MaxTries) { Stop-Run "조각을 받지 못했다(curl $code)" "$($msg.Trim()) — 인터넷을 확인하고 다시 실행한다." }
        $wait = [math]::Min(300, 30 * $stall)
        Write-Warn "끊김, 진전 없음(curl $code). $wait 초 뒤 다시 ($stall/$MaxTries)"
        Start-Sleep $wait
    }
}
Write-Ok "조각 $($blobs.Count)개 받음, 모두 sha256 일치"

# ---------------------------------------------------------------- 4. 묶기
Write-Host ''; Write-Host '==== [4/4] 서버용 파일로 묶기 ====' -ForegroundColor Cyan
# docker load 가 읽는 형식: manifest.json + 조각들(압축된 그대로 넣어도 docker load 가 푼다)
$m = @(@{ Config = "blobs/sha256/$($mf.config.digest.Split(':')[1])"; RepoTags = @($tagName)
          Layers = @($mf.layers | ForEach-Object { "blobs/sha256/$($_.digest.Split(':')[1])" }) })
[IO.File]::WriteAllText((Join-Path $work 'manifest.json'), (ConvertTo-Json -InputObject $m -Depth 5 -Compress), (New-Object Text.UTF8Encoding $false))
Remove-Item -Force -ErrorAction SilentlyContinue $tar
& tar.exe -cf $tar -C $work manifest.json blobs
if ($LASTEXITCODE -ne 0) { Stop-Run 'tar 로 묶지 못했다' '남은 공간을 확인하고 다시 실행한다.' }
$h = (Get-FileHash $tar -Algorithm SHA256).Hash.ToLower()
[IO.File]::WriteAllText("$tar.sha256", "$h  $(Split-Path -Leaf $tar)`n", (New-Object Text.UTF8Encoding $false))
Remove-Item -Recurse -Force $work
Write-Ok "$(Split-Path -Leaf $tar) $(Format-Size (Get-Item $tar).Length)"

Write-Host ''
Write-Host '############################ 완료 ############################' -ForegroundColor Green
Write-Host ' B200 서버에 올릴 파일 두 개:' -ForegroundColor Green
Write-Host "   $tar"
Write-Host "   $tar.sha256"
Write-Host ''
Write-Host ' /app/inbox/images/<내 이름>/ 에 올린 뒤, B200 서버에서:' -ForegroundColor Green
Write-Host '   b200 image-load /app/inbox/images/<내 이름>'
Write-Host '##############################################################' -ForegroundColor Green
Stop-Transcript | Out-Null
