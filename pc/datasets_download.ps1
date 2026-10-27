<#
[접근 PC] 세그멘테이션 데이터셋을 받는다. 설명은 docs\2_데이터셋.md.
점검 → 받기(끊기면 이어받기) → 검사 → B200 서버에 올릴 목록 만들기까지 한 번에 한다.
끊기거나 실패하면 같은 명령을 다시 실행한다. 받은 것은 건너뛴다.

  powershell -ExecutionPolicy Bypass -File .\pc\datasets_download.ps1               # WildScenes 빼고
  powershell -ExecutionPolicy Bypass -File .\pc\datasets_download.ps1 -WildScenes   # WildScenes 포함(접속 정보를 물어본다)
  powershell -ExecutionPolicy Bypass -File .\pc\datasets_download.ps1 -WildScenesLinks C:\Users\나\Downloads\61541v001.txt
                                                                     # WildScenes 를 포털의 링크 목록 파일로 받는다(AWS CLI 가 안 될 때)
  powershell -ExecutionPolicy Bypass -File .\pc\datasets_download.ps1 -Only goose,RUGD
  powershell -ExecutionPolicy Bypass -File .\pc\datasets_download.ps1 -DriveCheck     # Google Drive 파일마다 받을 수 있는지만 진단
#>
param(
    [string]$Dest = (Join-Path (Split-Path $PSScriptRoot -Parent) 'datasets'),
    [switch]$WildScenes,              # WildScenes 도 받는다. CSIRO 포털의 S3 접속 정보를 물어본다
    [string]$WildScenesLinks = '',    # WildScenes 를 포털 "Get a list of file download links" 로 받은 목록 파일로 받는다
    [string[]]$Only = @(),            # 이 폴더만 받는다(쉼표로 여러 개)
    [switch]$DriveCheck,              # 받지 않고 Google Drive 파일마다 받을 수 있는지, 안 되면 왜인지 진단만 한다
    [int]$MaxTries = 30               # 받은 양이 늘지 않은 채 연속으로 끊긴 횟수가 이만큼이면 그 파일은 포기(약 2시간)
)
$here = $PSScriptRoot
$root = Split-Path $PSScriptRoot -Parent   # 저장소 맨 위(D:\b200). 결과 폴더와 uv.exe 는 여기
. (Join-Path $here 'b200_common.ps1')
$Only   = @($Only | ForEach-Object { $_ -split ',' } | Where-Object { $_ })
$check  = Join-Path $here 'check_archive.py'
$T = 4

function Want($set) { return (-not $Only.Count) -or ($Only -contains $set) }

# 직접 링크로 받는 것. Set: 폴더, GB: 대략 크기
$Items = @(
    @{ Set = 'goose';   GB = 20; Name = 'goose_2d_train.zip';     Url = 'https://goose-dataset.de/storage/goose_2d_train.zip' }
    @{ Set = 'goose';   GB = 4;  Name = 'goose_2d_val.zip';       Url = 'https://goose-dataset.de/storage/goose_2d_val.zip' }
    @{ Set = 'goose';   GB = 4;  Name = 'goose_2d_test.zip';      Url = 'https://goose-dataset.de/storage/goose_2d_test.zip' }
    @{ Set = 'gooseEx'; GB = 14; Name = 'gooseEx_2d_train.zip';   Url = 'https://goose-dataset.de/storage/gooseEx_2d_train.zip' }
    @{ Set = 'gooseEx'; GB = 3;  Name = 'gooseEx_2d_val.zip';     Url = 'https://goose-dataset.de/storage/gooseEx_2d_val.zip' }
    @{ Set = 'gooseEx'; GB = 3;  Name = 'gooseEx_2d_test.zip';    Url = 'https://goose-dataset.de/storage/gooseEx_2d_test.zip' }
    @{ Set = 'RUGD';    GB = 5;  Name = 'RUGD_frames-with-annotations.zip'; Url = 'http://rugd.vision/data/RUGD_frames-with-annotations.zip' }
    @{ Set = 'RUGD';    GB = 1;  Name = 'RUGD_annotations.zip';   Url = 'http://rugd.vision/data/RUGD_annotations.zip' }
)
$Items = @($Items | Where-Object { Want $_.Set })

# Google Drive 에만 있는 것. Drive 에 접속되면 curl 로 받고(이어받기), 안 되면 건너뛴다.
# 브라우저로 받아 datasets\<폴더>\ 에 직접 넣어 둔 압축 파일도 검사해서 목록에 넣는다.
$DriveItems = @(
    @{ Set = 'rellis_2d';  GB = 11; Name = 'images';            Id = '1F3Leu0H_m6aPVpZITragfreO_SGtL2yV' }
    @{ Set = 'rellis_2d';  GB = 1;  Name = 'annotations_id';    Id = '16URBUQn_VOGvUqfms-0I8HHKMtjPHsu5' }
    @{ Set = 'rellis_2d';  GB = 1;  Name = 'annotations_color'; Id = '1HJl8Fi5nAjOr41DPUFmkeKWtDXhCZDke' }
    @{ Set = 'rellis_2d';  GB = 1;  Name = 'split';             Id = '1zHmnVaItcYJAWat3Yti1W_5Nfux194WQ' }
    @{ Set = 'tas500v1.1'; GB = 2;  Name = 'tas500';            Id = '1dCxJNWGbQT-tbuDTD6nQvmWPwGS9MPwT' }
    @{ Set = 'go';         GB = 2;  Name = 'images';            Id = '1Y_XHZw6BeuqwD280K7xw4eapNRpSKXA5' }
    @{ Set = 'go';         GB = 1;  Name = 'annotations_id';    Id = '1VehRXZ_Bw4DolGVvqVk4qr_pmbUXYgQA' }
    @{ Set = 'go';         GB = 1;  Name = 'annotations_color'; Id = '1qc4J1DgiWU0MsUhUhyX0p8sQROoVb4uZ' }
)
$DriveItems = @($DriveItems | Where-Object { Want $_.Set })
$Manual = @($DriveItems | ForEach-Object { $_.Set } | Select-Object -Unique)
$doWild = ($WildScenes -or $WildScenesLinks) -and (Want 'wildscenes')
$WsPortal = 'https://data.csiro.au/collection/csiro:61541'   # WildScenes 포털 페이지

New-Item -ItemType Directory -Force $Dest | Out-Null
$Dest = (Resolve-Path $Dest).Path.TrimEnd('\')
Start-Log (Join-Path $Dest 'download.log')
Stop-Sleep
Write-Host "[접근 PC] 세그멘테이션 데이터셋 받기  ($(Get-Date -Format 'yyyy-MM-dd HH:mm'))"
Write-Host "받는 곳: $Dest"

# 압축 검사: 0 정상, 1 깨짐, 2 모르는 형식
function Test-Archive($file) {
    Write-Info "검사 중(크면 몇 분): $(Split-Path -Leaf $file)"
    $env:PYTHONIOENCODING = 'utf-8'   # 한글 출력 때문에 검사가 실패하지 않게
    & $uv run --no-project --python 3.12 $check $file | Out-Host
    return $LASTEXITCODE
}

# 다 받고 검사도 끝난 파일을 기록한다(서버에서 맞는지 볼 체크섬)
function Set-Done($okFile, $file) {
    $rel  = $file.Substring($Dest.Length + 1) -replace '\\', '/'
    $hash = (Get-FileHash $file -Algorithm SHA256).Hash.ToLower()
    [IO.File]::WriteAllText($okFile, "$hash  $rel`n", (New-Object Text.UTF8Encoding $false))
}

function Get-RemoteSize($url) {
    $ca = Get-CurlArgs $url
    $h = & curl.exe -sIL --connect-timeout 30 --max-time 60 @ca $url
    $m = $h | Select-String '^content-length:\s*(\d+)'
    if ($m) { return [int64]$m[-1].Matches[0].Groups[1].Value }
    return $null
}

function Get-Url($url, $file) {
    New-Item -ItemType Directory -Force (Split-Path $file) | Out-Null
    $stall = 0
    while ($stall -lt $MaxTries) {
        $remote = Get-RemoteSize $url
        $local  = if (Test-Path $file) { (Get-Item $file).Length } else { 0 }
        if (-not ($remote -and $local -eq $remote)) {
            if ($remote -and $local -gt $remote) { Remove-Item -Force $file }
            if ($local) { Write-Info "이어받기: $(Format-Size $local) 부터" }
            # -C - : 이어받기, -Y/-y : 2분 동안 1 KB/s 아래면 끊고 다시
            $ca = Get-CurlArgs $url
            & curl.exe -L -C - --fail --retry 3 --retry-delay 10 --connect-timeout 30 -Y 1024 -y 120 @ca -o $file $url
            $code = $LASTEXITCODE
            if ($code -eq 33 -or $code -eq 36) {
                Write-Warn '다운로드 사이트가 이어받기를 지원하지 않아 처음부터 받는다'
                Remove-Item -Force -ErrorAction SilentlyContinue $file
            }
            if ($code -ne 0) {
                $stall = Step-Retry $stall $local (Get-Size $file) $MaxTries "curl $code"
                continue
            }
        }
        $r = Test-Archive $file
        if ($r -eq 0) { return $file }
        if ($r -eq 2) { Write-Warn 'zip/tar 가 아니라 검사를 건너뛰었다'; return $file }
        Write-Warn '압축이 깨졌다. 처음부터 다시 받는다'
        Remove-Item -Force $file
        $stall++
    }
    return $null
}

# WildScenes: CSIRO 포털의 S3 저장소에서 AWS CLI 로 받는다(uv 로 실행해 따로 설치하지 않는다)
function Invoke-Aws {
    # 이 주소에만 따로 찾은 프록시가 있으면 AWS CLI 에도 쓴다(윈도우 로그인 인증은 AWS CLI 가 못 한다)
    $pa = $script:HostArgs[([uri]$script:WsEndpoint).Host]
    $old = $env:HTTPS_PROXY
    if ($pa) { $env:HTTPS_PROXY = $pa[1] }
    try { & $uv tool run --from awscli aws @args --endpoint-url $script:WsEndpoint }
    finally { if ($pa) { $env:HTTPS_PROXY = $old } }
}

# 포털 "Get a list of file download links" 의 목록 파일에서 WildScenes2d 아래 파일만 고른다.
# https 로 시작하는 줄이 파일 하나(서명이 붙은 임시 주소), 들여쓴 줄은 aria2 용 옵션이라 건너뛴다
function Get-WsLinks($file) {
    $list = New-Object System.Collections.Generic.List[object]
    foreach ($l in [IO.File]::ReadAllLines($file)) {
        if ($l -notmatch '^https://') { continue }
        $m = [regex]::Match(($l -split '\?')[0], '(?i)/WildScenes2d/(.+)$')
        if (-not $m.Success) { continue }
        $rel = [uri]::UnescapeDataString($m.Groups[1].Value) -replace '/', '\'
        $list.Add([pscustomobject]@{ Url = $l.Trim(); Rel = $rel })
    }
    return ,$list
}

# 원격 폴더 아래에서 WildScenes2d 폴더를 찾는다(3단계 깊이까지)
function Find-WsPrefix($base) {
    $queue = @($base)
    for ($depth = 0; $depth -le 3; $depth++) {
        $next = @()
        foreach ($p in $queue) {
            foreach ($l in @(Invoke-Aws s3 ls "s3://$p")) {
                if ($l -match '^\s*PRE (.+/)\s*$') {
                    $name = $Matches[1]
                    if ($name -ieq 'WildScenes2d/') { return "$p$name" }
                    if ($next.Count -lt 50) { $next += "$p$name" }
                }
            }
        }
        $queue = $next
    }
    return $null
}

# 받은 파일 앞부분으로 압축 종류를 알아내 확장자를 정한다
function Get-ArchiveExt($file) {
    $b = New-Object byte[] 512
    $fs = [IO.File]::OpenRead($file)
    try { $n = $fs.Read($b, 0, 512) } finally { $fs.Close() }
    if ($n -ge 2 -and $b[0] -eq 0x50 -and $b[1] -eq 0x4B) { return '.zip' }
    if ($n -ge 2 -and $b[0] -eq 0x1F -and $b[1] -eq 0x8B) { return '.tar.gz' }
    if ($n -ge 2 -and $b[0] -eq 0x37 -and $b[1] -eq 0x7A) { return '.7z' }
    if ($n -ge 262 -and [Text.Encoding]::ASCII.GetString($b, 257, 5) -eq 'ustar') { return '.tar' }
    if ($n -ge 1 -and $b[0] -eq 0x3C) { return '.html' }   # '<' : 파일 대신 웹 페이지가 왔다
    return '.bin'
}

function Get-DoneDrive($target) {
    $dir = Split-Path $target
    if (-not (Test-Path $dir)) { return $null }
    return Get-ChildItem $dir -File -Filter "$(Split-Path -Leaf $target).*.ok" | Select-Object -First 1
}

# 큰 파일 확인 페이지가 주는 쿠키를 다음 요청에 이어 쓴다
$DriveJar = Join-Path $env:TEMP 'b200_drive_cookies.txt'   # 서버에 올리는 datasets 폴더에 섞이지 않게

# Google Drive 파일 하나를 앞부분만 받아 보고, 안 되면 왜 안 되는지 가린다.
# 응답 머리글과 본문 앞부분은 datasets\drive_check 에 남긴다(담당자에게 보낼 자료)
function Test-DriveFile($id) {
    $save = Join-Path $Dest 'drive_check'
    New-Item -ItemType Directory -Force $save | Out-Null
    $hdr  = Join-Path $save "$id.headers.txt"
    $body = Join-Path $save "$id.body.txt"
    Remove-Item -Force -ErrorAction SilentlyContinue $hdr, $body
    $url = "https://drive.usercontent.google.com/download?id=$id&export=download&confirm=t"
    # 앞 64 KB 만 요청하고, 서버가 무시하고 통째로 보내면 1 MB 에서 끊는다(그래도 '받을 수 있음' 이다)
    $ca = Get-CurlArgs $url
    # -v : 응답이 아예 없을 때도 어디서 막혔는지(DNS, 프록시, TLS) 알 수 있게 연결 과정을 남긴다
    $out = & curl.exe -v -sS -L -r 0-65535 --max-filesize 1048576 --connect-timeout 30 --max-time 90 `
        -b $DriveJar -c $DriveJar @ca -D $hdr -o $body -w '##%{http_code}|%{url_effective}|%{content_type}' `
        --stderr - $url | Out-String
    $code = $LASTEXITCODE
    $http = 0; $final = ''; $ctype = ''
    if ($out -match '##(\d{3})\|([^|]*)\|(.*)') { $http = [int]$Matches[1]; $final = $Matches[2]; $ctype = $Matches[3].Trim() }
    $err = (@($out -split "`r?`n" | Where-Object { $_ -match '^curl: \(' }) -join ' ').Trim()
    # 응답이 없어도 진단 기록은 항상 남긴다(쿠키 줄은 뺀다)
    $trace = @($out -split "`r?`n" | Where-Object { $_ -notmatch '^[<>] (Set-)?Cookie:' }) -join "`r`n"
    $bp = Get-BrowserProxy $url
    [IO.File]::WriteAllText((Join-Path $save "$id.report.txt"), (@(
        "시각: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')", "주소: $url", "curl 종료 코드: $code",
        "curl 버전: $((& curl.exe -V | Select-Object -First 1))", "추가 인자: $($ca -join ' ')",
        "HTTPS_PROXY: $env:HTTPS_PROXY", "윈도우 프록시: $(Get-WindowsProxy)", "브라우저가 이 주소에 쓰는 프록시: $bp",
        '', '---- curl 연결 과정 ----', $trace) -join "`r`n"), (New-Object Text.UTF8Encoding $false))
    $h = if (Test-Path $hdr) { [IO.File]::ReadAllText($hdr) } else { '' }
    $blocks = @($h -split '(?m)^(?=HTTP/)' | Where-Object { $_.Trim() })
    $last = if ($blocks.Count) { $blocks[-1] } else { '' }   # 넘겨주기(redirect) 끝의 마지막 응답
    $server = if ($last -match '(?im)^server:\s*(.+)$') { $Matches[1].Trim() } else { '' }
    $google = $last -match '(?im)^(x-guploader-uploadid|server:\s*(uploadserver|esf|gse|sffe|gws|google))'
    $text = if (Test-Path $body) { [IO.File]::ReadAllText($body) } else { '' }
    $title = if ($text -match '(?is)<title>(.*?)</title>') { ($Matches[1] -replace '\s+', ' ').Trim() } else { '' }
    $html = ($ctype -like 'text/html*') -or $text.TrimStart().StartsWith('<')
    $kind = 'other'
    if ($code -eq 56 -and $err -match 'CONNECT tunnel failed, response (\d+)') { $kind = 'proxy'; $http = [int]$Matches[1] }
    elseif ($code -eq 63) { $kind = 'ok' }
    elseif ($code -ne 0 -and -not $http) { $kind = 'net' }
    elseif (($http -eq 200 -or $http -eq 206) -and -not $html) { $kind = 'ok' }
    elseif ($text -match 'Too many users|Quota exceeded|download quota|할당량') { $kind = 'quota' }
    elseif ($final -match 'accounts\.google\.com' -or $text -match 'ServiceLogin|You need access|Request access|액세스 권한') { $kind = 'login' }
    elseif ($text -match 'unusual traffic|automated queries|/sorry/') { $kind = 'bot' }
    elseif ($http -eq 200 -and $text -match 'name="uuid"') { $kind = 'confirm' }
    elseif (-not $google) { $kind = 'proxy' }
    elseif ($http -ge 400) { $kind = 'google' }
    return [pscustomobject]@{ Kind = $kind; Http = $http; Curl = $code; Err = $err; Server = $server; Title = $title; Saved = $save }
}

function Show-DriveDiag($d, $label) {
    $info = "HTTP $($d.Http), curl $($d.Curl)"
    if ($d.Server) { $info += ", Server: $($d.Server)" }
    if ($d.Title)  { $info += ", 페이지 제목: $($d.Title)" }
    switch ($d.Kind) {
        'ok'      { Write-Ok "$label : 받을 수 있음" }
        'confirm' { Write-Ok "$label : 받을 수 있음(큰 파일 확인 페이지는 스크립트가 넘긴다)" }
        'quota'   { Write-Bad "$label : Google 다운로드 한도 초과 ($info)"
                    Write-Info '    최근 이 파일을 받은 사람이 너무 많아 Google 이 하루쯤 막았다. 내일 다시 실행한다.'
                    Write-Info '    급하면 브라우저에서 Google 에 로그인해 "내 드라이브에 사본 만들기" 를 한 뒤 그 사본을 받아 datasets\<폴더> 에 넣는다.' }
        'login'   { Write-Bad "$label : 로그인이나 접근 권한이 필요하다 ($info)"
                    Write-Info '    공유가 "링크가 있는 모든 사용자" 가 아니게 바뀌었다. 브라우저에서 로그인해 받아 datasets\<폴더> 에 넣는다.' }
        'bot'     { Write-Bad "$label : Google 이 이 망의 요청을 자동 요청으로 보고 막았다 ($info)"
                    Write-Info '    회사 전체가 같은 IP 로 나가는 망에서 생긴다. 몇 시간 뒤 다시 하거나 브라우저로 받아 datasets\<폴더> 에 넣는다.' }
        'proxy'   { Write-Bad "$label : 회사 프록시나 보안 장비가 막았다 ($info)"
                    Write-Info '    Google 이 아니라 중간 장비가 준 응답이다. 웹 페이지는 열어 주고 파일 받기만 막는 설정이 흔하다.'
                    Write-Info '    사내 IT에 drive.usercontent.google.com 파일 다운로드 허용을 요청하고, 위 Server 와 페이지 제목을 같이 알려 준다.' }
        'google'  { Write-Bad "$label : Google 이 거절했는데 이유 문구를 찾지 못했다 ($info)" }
        'net'     { Write-Bad "$label : 응답을 받기 전에 연결이 끊겼다 ($($d.Err))"
                    if ($d.Err -match '\((6|7|28)\)') { Write-Info '    주소를 찾지 못했거나 연결이 막혔다. 브라우저만 프록시를 쓰는 망일 수 있다.' }
                    elseif ($d.Err -match '\((35|60)\)') { Write-Info '    보안 연결(TLS) 단계에서 실패했다. 회사 보안 장비가 막거나 인증서를 바꾸는 망이다.' }
                    elseif ($d.Err -match '\(56\)') { Write-Info '    연결 중 끊겼다. 회사 프록시나 방화벽이 막은 경우가 대부분이다.' } }
        default   { Write-Bad "$label : 예상하지 못한 응답 ($info)" }
    }
    if ($d.Kind -ne 'ok' -and $d.Kind -ne 'confirm') { Write-Info "    진단 기록: $($d.Saved) (파일 ID 마다 .report.txt)" }
}

# Google Drive 파일을 curl 로 받는다. 끊기면 이어받고, 큰 파일의 "바이러스 검사 안 함" 확인 페이지도 넘긴다
function Get-Drive($id, $target) {
    New-Item -ItemType Directory -Force (Split-Path $target) | Out-Null
    $part = "$target.download"
    $url  = "https://drive.usercontent.google.com/download?id=$id&export=download&confirm=t"
    $stall = 0
    while ($stall -lt $MaxTries) {
        $local = Get-Size $part
        if ($local) { Write-Info "이어받기: $(Format-Size $local) 부터" }
        $ca = Get-CurlArgs $url
        & curl.exe -L -C - --fail --retry 3 --retry-delay 10 --connect-timeout 30 -Y 1024 -y 120 `
            -b $DriveJar -c $DriveJar @ca -o $part $url
        $code = $LASTEXITCODE
        if ($code -eq 33 -or $code -eq 36) { Remove-Item -Force -ErrorAction SilentlyContinue $part }
        if ($code -eq 22 -or $code -eq 56) {
            # 403 같은 거절: 다시 해도 소용없는 경우면 기다리지 말고 이유를 알려 준다
            $d = Test-DriveFile $id
            if ($d.Kind -eq 'ok' -or $d.Kind -eq 'confirm') {
                if ($local) { Write-Warn '이어받기 요청을 거절했다. 처음부터 다시 받는다'; Remove-Item -Force $part }
            } elseif ($d.Kind -ne 'net') {
                Show-DriveDiag $d $id
                return $null
            }
        }
        if ($code -ne 0) {
            $stall = Step-Retry $stall $local (Get-Size $part) $MaxTries "curl $code"
            continue
        }
        $ext = Get-ArchiveExt $part
        if ($ext -eq '.html') {
            $html = [IO.File]::ReadAllText($part)
            Remove-Item -Force $part
            if ($html -match 'Quota exceeded|Too many users|할당량') {
                Write-Bad 'Google Drive 하루 다운로드 한도에 걸렸다. 내일 다시 실행한다.'
                return $null
            }
            $inputs = [regex]::Matches($html, 'name="([^"]+)"\s+value="([^"]*)"')
            if ($inputs.Count -and $html -match 'uuid') {
                $q = ($inputs | ForEach-Object { "$($_.Groups[1].Value)=$([uri]::EscapeDataString($_.Groups[2].Value))" }) -join '&'
                $url = "https://drive.usercontent.google.com/download?$q"
                Write-Info '큰 파일 확인 페이지를 넘기고 다시 받는다'
                $stall++
                continue
            }
            Write-Bad 'Google Drive 가 파일 대신 웹 페이지를 줬다.'
            Show-DriveDiag (Test-DriveFile $id) $id
            return $null
        }
        $r = Test-Archive $part
        if ($r -eq 1) {
            Write-Warn '압축이 깨졌다. 처음부터 다시 받는다'
            Remove-Item -Force $part
            $stall++
            continue
        }
        $final = "$target$ext"
        Move-Item -Force $part $final
        return $final
    }
    return $null
}

function Read-Plain($prompt) {
    $s = Read-Host $prompt -AsSecureString   # 화면과 기록 파일에 남지 않게
    $b = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($s)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($b) } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b) }
}

# -DriveCheck: 받지 않고 Google Drive 파일마다 진단만 하고 끝낸다
if ($DriveCheck) {
    Write-Host ''
    Write-Host '[Google Drive 진단] 파일마다 앞부분만 받아 본다' -ForegroundColor Cyan
    Write-Host "  curl: $((& curl.exe -V | Select-Object -First 1))"
    $p = Get-WindowsProxy
    Write-Host "  윈도우 프록시: $(if ($p) { $p } else { '없음' }), HTTPS_PROXY: $(if ($env:HTTPS_PROXY) { $env:HTTPS_PROXY } else { '없음' })"
    Test-Site 'Google Drive' 'https://drive.google.com/' | Out-Null
    Test-Site 'Google Drive 파일 서버' 'https://drive.usercontent.google.com/' | Out-Null
    foreach ($it in $DriveItems) { Show-DriveDiag (Test-DriveFile $it.Id) "$($it.Set)/$($it.Name)" }
    Write-Host ''
    Write-Host ' 해결이 안 되면 아래 두 가지를 담당자에게 보내 준다:' -ForegroundColor Yellow
    Write-Host "   $(Join-Path $Dest 'drive_check') 폴더, $script:LogPath"
    Allow-Sleep
    Stop-Transcript | Out-Null
    exit 0
}

# ------------------------------------------------------------------ 1. 점검
Write-Step 1 $T '점검'
$uv = Find-Exe 'uv' $root
if ($uv) { Write-Ok "uv : $uv" } else { Write-Bad 'uv 가 없다' }
foreach ($e in 'curl.exe', 'tar.exe') {
    if (Get-Command $e -ErrorAction SilentlyContinue) { Write-Ok $e } else { Write-Bad "$e 가 없다(윈도우 10 1803 이후에 기본으로 있다)" }
}
if (-not (Test-Path $check)) { Write-Bad 'check_archive.py 가 없다(git pull 로 받는다)' }
if (-not (Test-Path (Join-Path $root 'server\datasets_install.sh'))) { Write-Bad 'datasets_install.sh 가 없다(git pull 로 받는다)' }
if ($script:Fails) { Stop-Run '필요한 파일이 없다' 'uv 를 설치하고 PowerShell 창을 새로 연다. 저장소 파일은 git pull 로 받는다.' }

$sites = [ordered]@{ 'PyPI (검사 도구)' = 'https://pypi.org/simple/pip/' }
if ($Items | Where-Object { $_.Set -like 'goose*' }) { $sites['goose-dataset.de'] = 'https://goose-dataset.de/' }
if ($Items | Where-Object { $_.Set -eq 'RUGD' })     { $sites['rugd.vision'] = 'http://rugd.vision/' }
foreach ($k in $sites.Keys) { Test-Site $k $sites[$k] | Out-Null }
if ($script:Fails) {
    Stop-Run '인터넷 접속이 안 되는 곳이 있다' ('위 [문제] 줄 아래의 curl 오류와 설명을 본다. 브라우저로는 열리면 ' +
        '사내 IT에 프록시 주소를 물어 $env:HTTPS_PROXY = "http://프록시주소:포트" 를 넣고 다시 실행한다. ' +
        '한 사이트만 막혔으면 -Only 로 나머지만 먼저 받는다.')
}

# Google Drive 는 스크립트가 받지 않지만, 브라우저로 받을 수 있는지 알려 준다(실패해도 멈추지 않는다)
$driveOk = $false
if ($Manual.Count) {
    $d1 = Invoke-Probe 'https://drive.google.com/'
    if ($d1.Code -ne 0) {
        Write-Warn "Google Drive 접속 안 됨(curl $($d1.Code)). RELLIS-3D, TAS500, GO 는 건너뛰고 나머지를 받는다. 접근이 생기면 다시 실행한다."
    } else {
        # 첫 페이지만 열리고 파일 받기는 막힌 망이 있어, 실제 파일 하나를 앞부분만 받아 본다
        $d = Test-DriveFile $DriveItems[0].Id
        $driveOk = $d.Kind -ne 'proxy' -and $d.Kind -ne 'net'
        if ($d.Kind -eq 'ok' -or $d.Kind -eq 'confirm') {
            Write-Ok 'Google Drive 파일 받기 확인함. RELLIS-3D, TAS500, GO 도 받는다'
        } else {
            Show-DriveDiag $d "Google Drive 시험 파일($($DriveItems[0].Set)/$($DriveItems[0].Name))"
            if ($driveOk) { Write-Warn 'Google 에는 닿으니 파일마다 시도한다.' }
            else { Write-Warn 'RELLIS-3D, TAS500, GO 는 건너뛰고 나머지를 받는다. 파일마다 자세히 보려면 -DriveCheck 로 실행한다.' }
        }
    }
}

Write-Info '검사용 Python 준비 중(처음 한 번)'
& $uv python install 3.12 | Out-Host
if ($LASTEXITCODE -ne 0) { Stop-Run 'uv 가 Python 3.12 를 받지 못했다' '인터넷(github.com) 접속을 확인하고 다시 실행한다.' }
Write-Ok 'Python 3.12 준비됨'

if ($doWild -and $WildScenesLinks -and -not (Test-Path (Join-Path $Dest 'wildscenes.ok'))) {
    if (-not (Test-Path $WildScenesLinks)) { Stop-Run "링크 목록 파일이 없다: $WildScenesLinks" '포털에서 받은 .txt 파일의 전체 경로를 적는다.' }
    $script:WsLinks = Get-WsLinks $WildScenesLinks
    if (-not $script:WsLinks.Count) {
        Stop-Run '링크 목록에 WildScenes2d 파일이 없다' "포털($WsPortal)에서 Download → Get a list of file download links 로 받은 .txt 파일인지 확인한다."
    }
    Write-Ok "WildScenes 링크 목록: 2D 파일 $($script:WsLinks.Count)개"
    Test-Site 'CSIRO S3 저장소' "https://$(([uri]$script:WsLinks[0].Url).Host)/" | Out-Null
    if ($script:Fails) { Stop-Run 'CSIRO S3 저장소에 접속 안 된다' '위 [문제] 줄 아래 설명을 본다. 브라우저로는 열리면 기록 파일을 담당자에게 보내 준다.' }
} elseif ($doWild -and -not (Test-Path (Join-Path $Dest 'wildscenes.ok'))) {
    Write-Host ''
    Write-Host '  WildScenes 접속 정보를 넣는다. 정보는 약 48시간 유효하니 지금 새로 받는다.' -ForegroundColor Cyan
    Write-Host "  포털: $WsPortal"
    Write-Host '  포털에서 Download → Download files via S3 Client 를 고르고, 나온 네 값을 차례로 복사해 붙여 넣는다.'
    Write-Host '  (자세한 설명: docs\2_데이터셋.md 의 "WildScenes 접속 정보 받기")'
    $open = Read-Host '  포털 페이지를 브라우저로 열까? [Y/n]'
    if ($open -notmatch '^[nN]') { Start-Process $WsPortal }
    $server = (Read-Host '  Server (예: s3.data.csiro.au)').Trim()
    $wsDir  = (Read-Host '  Remote Directory (예: dapprd/000012345v001/)').Trim().TrimStart('/')
    $env:AWS_ACCESS_KEY_ID     = (Read-Plain '  Access Key').Trim()
    $env:AWS_SECRET_ACCESS_KEY = (Read-Plain '  Secret Access Key').Trim()
    $env:AWS_DEFAULT_REGION    = 'us-east-1'   # S3 호환 저장소라 지역은 아무 값이나 된다
    $env:AWS_RETRY_MODE        = 'standard'
    $env:AWS_MAX_ATTEMPTS      = '10'
    if (-not $wsDir.EndsWith('/')) { $wsDir += '/' }
    $script:WsEndpoint = if ($server -match '://') { $server } else { "https://$server" }

    Test-Site 'CSIRO S3 저장소' $script:WsEndpoint | Out-Null
    if ($script:Fails) {
        Stop-Run 'CSIRO S3 저장소에 접속 안 된다' ('위 [문제] 줄 아래 설명을 본다. 브라우저로는 열리면(401, AccessDenied 등이 떠도 열리는 것) ' +
            'docs\2_데이터셋.md 의 "WildScenes 링크 목록으로 받기" 를 따라 -WildScenesLinks 로 실행한다.')
    }
    $pa = $script:HostArgs[([uri]$script:WsEndpoint).Host]
    if ($pa -and $pa.Count -gt 2) {
        Stop-Run 'CSIRO S3 저장소는 윈도우 로그인 인증 프록시로만 닿는데, AWS CLI 는 그 인증을 못 한다' `
            'docs\2_데이터셋.md 의 "WildScenes 링크 목록으로 받기" 를 따라 -WildScenesLinks 로 실행한다(curl 로 받아 인증이 된다).'
    }

    Write-Info 'AWS CLI 준비 중(처음 한 번)'
    & $uv tool install awscli | Out-Host
    if ($LASTEXITCODE -ne 0) { Stop-Run 'AWS CLI 준비 실패' 'PyPI 접속을 확인하고 다시 실행한다.' }

    Write-Info 'WildScenes2d 폴더 찾는 중'
    $wsPrefix = Find-WsPrefix $wsDir
    if (-not $wsPrefix) {
        Write-Host '  원격 폴더 내용:'
        Invoke-Aws s3 ls "s3://$wsDir" | Out-Host
        Stop-Run 'WildScenes2d 폴더를 찾지 못했다' ("접속 정보가 틀렸거나 48시간이 지났을 수 있다. 포털($WsPortal)에서 접속 정보를 새로 받아 다시 실행한다. " +
            'SSL/certificate 오류가 보이면 회사 보안 장비 때문이니 담당자에게 기록 파일을 보내 준다.')
    }
    Write-Ok "WildScenes 접속: s3://$wsPrefix"
}

$needGB = ($Items | Where-Object { -not (Test-Path "$(Join-Path (Join-Path $Dest $_.Set) $_.Name).ok") } |
    ForEach-Object { $_.GB } | Measure-Object -Sum).Sum
if (-not $needGB) { $needGB = 0 }
if ($driveOk) {
    $needGB += ($DriveItems | Where-Object { -not (Get-DoneDrive (Join-Path (Join-Path $Dest $_.Set) $_.Name)) } |
        ForEach-Object { $_.GB } | Measure-Object -Sum).Sum
}
if ($doWild -and -not (Test-Path (Join-Path $Dest 'wildscenes.ok'))) { $needGB += 47 }
$free = Get-FreeGB $Dest
if ($free -lt $needGB + 5) {
    Stop-Run "남은 공간이 $free GB 다(앞으로 약 $needGB GB 필요)" '공간이 넉넉한 드라이브에서 -Dest E:\datasets 처럼 받는 곳을 바꾸거나 -Only 로 나눠 받는다.'
}
Write-Ok "남은 공간 $free GB (앞으로 약 $needGB GB 받음)"

# ------------------------------------------------------------------ 2. 받기
Write-Step 2 $T '받기 (끊기면 자동으로 이어받는다)'
$result = [ordered]@{}
$n = 0
foreach ($it in $Items) {
    $n++
    $target = Join-Path (Join-Path $Dest $it.Set) $it.Name
    $label  = "$($it.Set)/$($it.Name)"
    if (Test-Path "$target.ok") { Write-Host "  ($n/$($Items.Count)) $label : 이미 받음"; $result[$label] = '받음'; continue }
    Write-Host ''
    Write-Host "  ($n/$($Items.Count)) $label 받는 중 (약 $($it.GB) GB)" -ForegroundColor Cyan
    $f = Get-Url $it.Url $target
    if ($f) { Set-Done "$target.ok" $f; Write-Ok "$label 받음"; $result[$label] = '받음' }
    else    { Write-Bad "$label 못 받음"; $result[$label] = '실패' }
}

if ($doWild) {
    $wdir = Join-Path $Dest 'wildscenes'
    if (Test-Path "$wdir.ok") {
        Write-Host '  wildscenes : 이미 받음'; $result['wildscenes'] = '받음'
    } else {
        Write-Host ''
        Write-Host '  wildscenes 받는 중 (약 47 GB, 파일이 많아 오래 걸린다)' -ForegroundColor Cyan
        $done = $false
        $stall = 0
        if ($WildScenesLinks) {
            # 링크 목록: 파일마다 curl 로 이어받기. 끝난 파일은 목록에 적어 다시 실행하면 건너뛴다
            $links = $script:WsLinks
            $doneFile = "$wdir.links_done.txt"
            $doneSet = New-Object 'System.Collections.Generic.HashSet[string]'
            if (Test-Path $doneFile) { foreach ($x in [IO.File]::ReadAllLines($doneFile)) { [void]$doneSet.Add($x) } }
            $utf8 = New-Object Text.UTF8Encoding $false
            $expired = $false
            while ($stall -lt $MaxTries) {
                $todo = @($links | Where-Object { -not $doneSet.Contains($_.Rel) })
                if (-not $todo.Count) { $done = $true; break }
                $before = $doneSet.Count
                $i = 0
                foreach ($it in $todo) {
                    $i++
                    if ($i % 20 -eq 1) { Write-Progress -Activity 'WildScenes 받기' -Status "$($doneSet.Count)/$($links.Count) 끝, 지금: $($it.Rel)" -PercentComplete (100 * $doneSet.Count / $links.Count) }
                    $out = Join-Path $wdir $it.Rel
                    New-Item -ItemType Directory -Force (Split-Path $out) | Out-Null
                    $ca = Get-CurlArgs $it.Url
                    $msg = & curl.exe -sS -L -C - --fail --retry 3 --retry-delay 5 --connect-timeout 30 -Y 1024 -y 120 @ca `
                        -o $out --stderr - $it.Url | Out-String
                    $code = $LASTEXITCODE
                    if ($code -eq 0) { [void]$doneSet.Add($it.Rel); [IO.File]::AppendAllText($doneFile, "$($it.Rel)`n", $utf8) }
                    elseif ($msg -match 'returned error: 403') { $expired = $true; break }
                    elseif ($code -eq 33 -or $code -eq 36) { Remove-Item -Force -ErrorAction SilentlyContinue $out }
                }
                Write-Progress -Activity 'WildScenes 받기' -Completed
                if ($expired) {
                    Write-Bad 'WildScenes 링크가 만료됐다(403)'
                    Write-Info "    포털($WsPortal)에서 링크 목록을 새로 받아 같은 명령을 다시 실행한다. 받은 파일은 건너뛴다."
                    break
                }
                if ($doneSet.Count -gt $before) { $stall = 0; Write-Warn "남은 $($links.Count - $doneSet.Count)개를 다시 받는다"; Start-Sleep 10 }
                else { $stall = Step-Retry $stall 0 0 $MaxTries 'WildScenes' }
            }
        }
        while (-not $WildScenesLinks -and -not $done -and $stall -lt $MaxTries) {
            # sync 는 이미 받은 파일을 건너뛰므로 몇 번이고 다시 해도 된다
            $before = Get-Size $wdir
            Invoke-Aws s3 sync "s3://$wsPrefix" $wdir --only-show-errors | Out-Host
            $code = $LASTEXITCODE
            if ($code -eq 0) {
                Write-Info '빠진 파일이 없는지 확인 중'
                $left = @(Invoke-Aws s3 sync "s3://$wsPrefix" $wdir --dryrun | Where-Object { $_ -match '\(dryrun\)' })
                if ($LASTEXITCODE -eq 0 -and $left.Count -eq 0) { $done = $true; break }
                Write-Warn "아직 $($left.Count)개가 남았다"
            } else {
                # 접속 정보가 만료됐으면 기다려도 소용없다
                Invoke-Aws s3 ls "s3://$wsPrefix" | Out-Null
                if ($LASTEXITCODE -ne 0) {
                    Write-Bad 'WildScenes 접속 정보가 만료됐거나 막혔다'
                    Write-Info "    포털($WsPortal)에서 접속 정보를 새로 받아 같은 명령(-WildScenes)을 다시 실행한다. 받은 파일은 건너뛴다."
                    break
                }
            }
            $stall = Step-Retry $stall $before (Get-Size $wdir) $MaxTries "aws $code"
        }
        if ($done) {
            $m = Get-ChildItem $wdir -Recurse -File | Measure-Object -Property Length -Sum
            [IO.File]::WriteAllText("$wdir.ok", "files=$($m.Count) bytes=$($m.Sum)`n", (New-Object Text.UTF8Encoding $false))
            Write-Ok "wildscenes 받음 (파일 $($m.Count)개)"; $result['wildscenes'] = '받음'
        } else { $result['wildscenes'] = '실패' }
    }
} elseif (Want 'wildscenes') {
    $result['wildscenes'] = '건너뜀(받으려면 -WildScenes 나 -WildScenesLinks)'
}
Remove-Item Env:AWS_ACCESS_KEY_ID, Env:AWS_SECRET_ACCESS_KEY -ErrorAction SilentlyContinue

# Google Drive 데이터셋
$n = 0
foreach ($it in $DriveItems) {
    $n++
    $target = Join-Path (Join-Path $Dest $it.Set) $it.Name
    $label  = "$($it.Set)/$($it.Name)"
    if (Get-DoneDrive $target) { Write-Host "  (Drive $n/$($DriveItems.Count)) $label : 이미 받음"; $result[$label] = '받음'; continue }
    if (-not $driveOk) { $result[$label] = '건너뜀(Drive 접속 안 됨. 접근이 생기면 다시 실행)'; continue }
    Write-Host ''
    Write-Host "  (Drive $n/$($DriveItems.Count)) $label 받는 중 (약 $($it.GB) GB)" -ForegroundColor Cyan
    $f = Get-Drive $it.Id $target
    if ($f) { Set-Done "$f.ok" $f; Write-Ok "$label 받음"; $result[$label] = '받음' }
    else    { Write-Bad "$label 못 받음"; $result[$label] = '실패' }
}

# 브라우저로 받아 직접 넣어 둔 압축 파일도 검사한다(스크립트가 받은 파일은 이미 .ok 가 있다)
foreach ($set in $Manual) {
    $dir = Join-Path $Dest $set
    if (-not (Test-Path $dir)) { continue }
    $arcs = @(Get-ChildItem $dir -File | Where-Object { $_.Name -match '\.(zip|tar|tgz|tar\.gz|7z)$' -and -not (Test-Path "$($_.FullName).ok") })
    foreach ($a in $arcs) {
        $label = "$set/$($a.Name) (직접 넣음)"
        $r = Test-Archive $a.FullName
        if ($r -ne 1) { Set-Done "$($a.FullName).ok" $a.FullName; $result[$label] = '받음' }
        else { Write-Bad "$set/$($a.Name) 가 깨졌다. 다시 받아 넣는다."; $result[$label] = '실패' }
    }
}

# ------------------------------------------------------------------ 3. B200 서버에 올릴 목록
Write-Step 3 $T 'B200 서버에서 확인할 체크섬 목록 만들기'
$oks = @(Get-ChildItem $Dest -Recurse -Filter '*.ok' -File | Where-Object { $_.Name -ne 'wildscenes.ok' })
$lines = @($oks | ForEach-Object { (Get-Content -Raw $_.FullName).Trim() })
[IO.File]::WriteAllText((Join-Path $Dest 'MANIFEST.sha256'), (($lines -join "`n") + "`n"), (New-Object Text.UTF8Encoding $false))
$sh = [IO.File]::ReadAllText((Join-Path $root 'server\datasets_install.sh')) -replace "`r", ''
[IO.File]::WriteAllText((Join-Path $Dest 'datasets_install.sh'), $sh, (New-Object Text.UTF8Encoding $false))
Write-Ok "압축 $($lines.Count)개 기록, datasets_install.sh 넣음"

# ------------------------------------------------------------------ 4. 결과
Write-Step 4 $T '결과'
foreach ($k in $result.Keys) {
    $v = $result[$k]
    $c = if ($v -like '받음*') { 'Green' } elseif ($v -eq '실패') { 'Red' } else { 'Yellow' }
    Write-Host ('  {0,-40} {1}' -f $k, $v) -ForegroundColor $c
}
$total = (Get-ChildItem $Dest -Recurse -File | Measure-Object -Property Length -Sum).Sum
$failed = @($result.Keys | Where-Object { $result[$_] -eq '실패' })
Allow-Sleep
Write-Host ''
if ($failed.Count) {
    Write-Host '################ 일부 못 받음 ################' -ForegroundColor Yellow
    Write-Host " 못 받은 것: $($failed -join ', ')"
    Write-Host ' 같은 명령을 다시 실행하면 못 받은 것만 이어서 받는다.'
    Write-Host ' 받은 것만 먼저 B200 서버에 올려도 된다(B200 서버 스크립트가 있는 것만 설치한다).'
    Write-Host " 계속 안 되면 이 파일을 담당자에게 보내 준다: $script:LogPath"
} else {
    Write-Host '############################ 완료 ############################' -ForegroundColor Green
}
Write-Host ''
Write-Host ' 접근 PC에서 할 일은 끝. B200 서버에 올릴 것 (폴더 통째로):' -ForegroundColor Green
Write-Host "   $Dest  ($(Format-Size $total))"
Write-Host ''
Write-Host ' 회사 프로그램으로 B200 서버 /app/inbox/datasets 에 올린 뒤, B200 서버 터미널에서:' -ForegroundColor Green
Write-Host '   bash /app/inbox/datasets/datasets_install.sh'
Write-Host '##############################################################'
Stop-Transcript | Out-Null
if ($failed.Count) { exit 1 }
