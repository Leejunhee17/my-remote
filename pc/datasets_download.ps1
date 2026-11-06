<#
[접근 PC] 세그멘테이션 라벨이 있는 데이터셋을 받는다(RELLIS-3D·GO·ORAD-3D 등은 라이다·rosbag 까지 전부). 설명은 docs\5_데이터셋.md.
점검 → 받기(끊기면 이어받기) → 검사 → GPU 서버에 올릴 목록 만들기까지 한 번에 한다.
끊기거나 실패하면 같은 명령을 다시 실행한다. 받은 것은 건너뛴다.

  powershell -ExecutionPolicy Bypass -File .\pc\datasets_download.ps1               # WildScenes 빼고
  powershell -ExecutionPolicy Bypass -File .\pc\datasets_download.ps1 -WildScenes   # WildScenes 포함(접속 정보를 물어본다)
  powershell -ExecutionPolicy Bypass -File .\pc\datasets_download.ps1 -WildScenesLinks C:\Users\나\Downloads\61541v001.txt
                                                                     # WildScenes 를 포털의 링크 목록 파일로 받는다(AWS CLI 가 안 될 때)
  powershell -ExecutionPolicy Bypass -File .\pc\datasets_download.ps1 -Only goose,RUGD
  powershell -ExecutionPolicy Bypass -File .\pc\datasets_download.ps1 -Only ORAD-3D       # 큰 것은 따로(약 350 GB)
  powershell -ExecutionPolicy Bypass -File .\pc\datasets_download.ps1 -DriveCheck     # Google Drive 파일마다 받을 수 있는지만 진단
.env 에 WildScenes 접속 정보(WILDSCENES_S3_*, WILDSCENES_*_KEY)나 링크 목록(WILDSCENES_LINKS)을 적어 두면
-WildScenes 를 붙이지 않아도 WildScenes 까지 받고, 접속 정보를 묻지 않는다.
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
$root = Split-Path $PSScriptRoot -Parent   # 저장소 맨 위(D:\gpu). 결과 폴더와 uv.exe 는 여기
. (Join-Path $here 'gpu_common.ps1')
$Only   = @($Only | ForEach-Object { $_ -split ',' } | Where-Object { $_ })
# .env 의 WildScenes 설정. 명령에 붙인 값이 먼저다
if (-not $WildScenesLinks -and $env:WILDSCENES_LINKS) { $WildScenesLinks = [Environment]::ExpandEnvironmentVariables($env:WILDSCENES_LINKS) }
$wsEnv = [bool]($env:WILDSCENES_S3_SERVER -and $env:WILDSCENES_S3_DIR -and $env:WILDSCENES_ACCESS_KEY -and $env:WILDSCENES_SECRET_KEY)
if ($wsEnv) { $WildScenes = $true }
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
    # CAVS 시맨틱 세그(실제 1,077장 + 합성 1,947장 + rosbag). 주소는 사이트의 "Download Dataset" 링크(2026-11-06 확인). 막히면 브라우저로 받아 datasets\CaSSeD 에 넣는다
    # Late: 사내망에서 접속되지 않아(타임아웃) 다른 것을 다 받은 뒤 맨 끝에 받는다
    @{ Set = 'CaSSeD';  GB = 38; Name = 'CaSSeD.tar.gz';          Url = 'https://www.cavs.msstate.edu/resources/downloads/CaSSeD/CaSSeD.tar.gz'; Late = $true }
    # Freiburg Forest: 라벨이 있는 다중 스펙트럼 묶음. 라벨 없는 raw(15,000장)는 사이트에서 브라우저로 받아 datasets\freiburg_forest 에 넣는다
    @{ Set = 'freiburg_forest'; GB = 3; Name = 'freiburg_forest_multispectral_annotated.tar.gz'; Url = 'http://deepscene.cs.uni-freiburg.de/static/datasets/freiburg_forest_multispectral_annotated.tar.gz' }
)
$Items = @($Items | Where-Object { Want $_.Set })
$LateItems = @($Items | Where-Object { $_.Late })
$Items     = @($Items | Where-Object { -not $_.Late })

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
    # RELLIS-3D 나머지 전부(github.com/unmannedlab/RELLIS-3D): 라이다, 보정, rosbag. 2D 세그는 위 rellis_2d
    @{ Set = 'rellis_full'; GB = 1;  Name = 'ontology';               Id = '1K8Zf0ju_xI5lnx3NTDLJpVTs59wmGPI6' }
    @{ Set = 'rellis_full'; GB = 1;  Name = 'image_examples';         Id = '1wIig-LCie571DnK72p2zNAYYWeclEz1D' }
    @{ Set = 'rellis_full'; GB = 1;  Name = 'ouster_examples';        Id = '1QikPnpmxneyCuwefr6m50fBOSB2ny4LC' }
    @{ Set = 'rellis_full'; GB = 26; Name = 'ouster_color_ply';       Id = '1BZWrPOeLhbVItdN0xhzolfsABr6ymsRr' }
    @{ Set = 'rellis_full'; GB = 14; Name = 'ouster_semantickitti';   Id = '1lDSVRf_kZrD0zHHMsKJ0V1GN9QATR4wH' }
    @{ Set = 'rellis_full'; GB = 1;  Name = 'ouster_semantickitti_labels'; Id = '12bsblHXtob60KrjV7lGXUQTdC5PhV8Er' }
    @{ Set = 'rellis_full'; GB = 1;  Name = 'ouster_scan_poses';      Id = '1V3PT_NJhA41N7TBLp5AbW31d0ztQDQOX' }
    @{ Set = 'rellis_full'; GB = 1;  Name = 'ouster_split';           Id = '1raQJPySyqDaHpc53KPnJVl3Bln6HlcVS' }
    @{ Set = 'rellis_full'; GB = 6;  Name = 'velodyne_semantickitti'; Id = '1PiQgPQtJJZIpXumuHSig5Y6kxhAzz1cz' }
    @{ Set = 'rellis_full'; GB = 1;  Name = 'velodyne_semantickitti_labels'; Id = '1n-9FkpiH4QUP7n0PnQBp-s7nzbSzmxp8' }
    @{ Set = 'rellis_full'; GB = 1;  Name = 'calib_camera_intrinsic';  Id = '1NAigZTJYocRSOTfgFBddZYnDsI_CSpwK' }
    @{ Set = 'rellis_full'; GB = 1;  Name = 'calib_camera_to_ouster';  Id = '19EOqWS9fDUFp4nsBrMCa69xs9LgIlS2e' }
    @{ Set = 'rellis_full'; GB = 1;  Name = 'calib_velodyne_to_ouster'; Id = '1T6yPwcdzJoU-ifFRelLtDLPuPQswIQwf' }
    @{ Set = 'rellis_full'; GB = 1;  Name = 'calib_stereo';           Id = '1cP5-l_nYt3kZ4hZhEAHEdpt2fzToar0R' }
    @{ Set = 'rellis_full'; GB = 2;  Name = 'rosbag_example_synced';   Id = '13EHwiJtU0aAWBQn-ZJhTJwC1Yx2zDVUv' }
    @{ Set = 'rellis_full'; GB = 5;  Name = 'rosbag_example_merged';   Id = '1qSeOoY6xbQGjcrZycgPM8Ty37eKDjpJL' }
    @{ Set = 'rellis_full'; GB = 5;  Name = 'rosbag_example_split_raw'; Id = '1-TDpelP4wKTWUDTIn0dNuZIT3JkBoZ_R' }
    @{ Set = 'rellis_full'; GB = 12; Name = 'rosbag_00000_synced';     Id = '1bIb-6fWbaiI9Q8Pq9paANQwXWn7GJDtl' }
    @{ Set = 'rellis_full'; GB = 23; Name = 'rosbag_00000_merged';     Id = '1grcYRvtAijiA0Kzu-AV_9K4k2C1Kc3Tn' }
    @{ Set = 'rellis_full'; GB = 8;  Name = 'rosbag_00001_synced';     Id = '1xNjAFE3cv6X8n046irm8Bo5QMerNbwP1' }
    @{ Set = 'rellis_full'; GB = 16; Name = 'rosbag_00001_merged';     Id = '1geoU45pPavnabQ0arm4ILeHSsG3cU6ti' }
    @{ Set = 'rellis_full'; GB = 14; Name = 'rosbag_00002_synced';     Id = '1gy0ehP9Buj-VkpfvU9Qwyz1euqXXQ_mj' }
    @{ Set = 'rellis_full'; GB = 28; Name = 'rosbag_00002_merged';     Id = '1h0CVg62jTXiJ91LnR6md-WrUBDxT543n' }
    @{ Set = 'rellis_full'; GB = 8;  Name = 'rosbag_00003_synced';     Id = '1vCeZusijzyn1ZrZbg4JaHKYSc2th7GEt' }
    @{ Set = 'rellis_full'; GB = 15; Name = 'rosbag_00003_merged';     Id = '1glJzgnTYLIB_ar3CgHpc_MBp5AafQpy9' }
    @{ Set = 'rellis_full'; GB = 7;  Name = 'rosbag_00004_synced';     Id = '1gxODhAd8CBM5AGvsoyuqN7yGpWazzmVy' }
    @{ Set = 'rellis_full'; GB = 14; Name = 'rosbag_00004_merged';     Id = '1AuEjX0do3jGZhGKPszSEUNoj85YswNya' }
    # GO 나머지 전부(github.com/unmannedlab/the-great-outdoors-dataset): 열화상, 라이다, 레이더, 보정, rosbag. 크기는 공개되지 않아 대략값
    @{ Set = 'go_full'; GB = 1;  Name = 'sensor_setup_scan';         Id = '1lTc4GO6WiOHxn7cqnY3baj5yh7qnQ5oX' }
    @{ Set = 'go_full'; GB = 1;  Name = 'image_examples';            Id = '1oi5KpBYXefvMpiUzrVE1BWcPfmMieTdx' }
    @{ Set = 'go_full'; GB = 2;  Name = 'thermal_images';            Id = '1kTwL7O_v4Qc8WpzpT7416VXgENYm1ZK-' }
    @{ Set = 'go_full'; GB = 1;  Name = 'thermal_annotations_color'; Id = '1g6Hf7-wg3JqQMDufhpHCyGK-cPrkQ7Ck' }
    @{ Set = 'go_full'; GB = 1;  Name = 'thermal_annotations_id';    Id = '1u_cRN-SkU2b_M5pWCRU0rL4_RkCTUTsA' }
    @{ Set = 'go_full'; GB = 10; Name = 'lidar_semantickitti';       Id = '1pzBnAVe-q531XBSnNUY8I42XOogDnLY7' }
    @{ Set = 'go_full'; GB = 5;  Name = 'radar_polar';               Id = '1KC56g3GriVsIA5rkKCFA7mqBWeuZL9PQ' }
    @{ Set = 'go_full'; GB = 1;  Name = 'calib_camera_intrinsic';    Id = '1I489hMmcnly5gwao6YC2I0wnOcL8W96w' }
    @{ Set = 'go_full'; GB = 1;  Name = 'calib_rgb_to_ouster';       Id = '1JZPWwZa7wA6mN_Qv8ze7_535D-xo8Zex' }
    @{ Set = 'go_full'; GB = 1;  Name = 'calib_thermal_to_rgb';      Id = '1bal8q-ytdc8od2wV9nXW9-fKIPbGuNau' }
    @{ Set = 'go_full'; GB = 50; Name = 'rosbag';                    Id = '1aze9xgbN1ID-9CW4U3CJtYi6ChBmaKGO' }
)
# 스크립트로 받을 수 없어서 브라우저로 받아 datasets\<폴더> 에 넣는 것. 넣어 둔 압축 파일은 검사해서 목록에 넣는다(docs\5_데이터셋.md)
#   rellis_full: Drive 폴더(원본 rosbag 5개 시퀀스, 보정 원본), ycor: Box 공유 링크, freiburg_forest: raw 묶음
$HandSets = @('rellis_full', 'ycor', 'freiburg_forest', 'CaSSeD')
# ORAD-3D: ModelScope(중국) 데이터셋 저장소에서 modelscope 도구로 받는다(약 350 GB, 끊기면 이어받기)
$ModelScopeId = 'Georgehhhh/ORAD-3D'
$DriveItems = @($DriveItems | Where-Object { Want $_.Set })
$Manual = @(@($DriveItems | ForEach-Object { $_.Set }) + @($HandSets | Where-Object { Want $_ }) | Select-Object -Unique)
$doOrad = Want 'ORAD-3D'
$doWild = ($WildScenes -or $WildScenesLinks) -and (Want 'wildscenes')
$WsPortal = 'https://data.csiro.au/collection/csiro:61541'   # WildScenes 포털 페이지

New-Item -ItemType Directory -Force $Dest | Out-Null
$Dest = (Resolve-Path $Dest).Path.TrimEnd('\')
Start-Log (Join-Path $Dest 'download.log')
Stop-Sleep
Write-Host "[접근 PC] 세그멘테이션 데이터셋 받기(라벨이 있는 데이터셋 전부)  ($(Get-Date -Format 'yyyy-MM-dd HH:mm'))"
Write-Host "받는 곳: $Dest"

# 압축 검사: 0 정상, 1 깨짐, 2 모르는 형식
function Test-Archive($file) {
    Write-Info "압축 파일을 검사하는 중이에요(크면 몇 분 걸려요): $(Split-Path -Leaf $file)"
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
    # 사이트에 접속되지 않을 때 브라우저로 받아 넣어 둔 파일이 있으면, 다시 받으려 하기 전에 그 파일부터 검사한다(다 받은 파일이면 그대로 쓴다)
    if ((Test-Path $file) -and -not (Get-RemoteSize $url)) {
        Write-Info '사이트에 접속되지 않아요. 넣어 둔 파일이 다 받아진 것인지 먼저 검사해요'
        if ((Test-Archive $file) -eq 0) { return $file }
        Write-Warn '넣어 둔 파일이 덜 받아졌거나 깨졌어요. 사이트에서 이어받기를 해 봐요'
    }
    $stall = 0
    while ($stall -lt $MaxTries) {
        $remote = Get-RemoteSize $url
        $local  = if (Test-Path $file) { (Get-Item $file).Length } else { 0 }
        if (-not ($remote -and $local -eq $remote)) {
            if ($remote -and $local -gt $remote) { Remove-Item -Force $file }
            if ($local) { Write-Info "이어받기: $(Format-Size $local)부터" }
            # -C - : 이어받기, -Y/-y : 2분 동안 1 KB/s 아래면 끊고 다시
            $ca = Get-CurlArgs $url
            & curl.exe -L -C - --fail --retry 3 --retry-delay 10 --connect-timeout 30 -Y 1024 -y 120 @ca -o $file $url
            $code = $LASTEXITCODE
            if ($code -eq 33 -or $code -eq 36) {
                Write-Warn '다운로드 사이트가 이어받기를 지원하지 않아서 처음부터 다시 받아요'
                Remove-Item -Force -ErrorAction SilentlyContinue $file
            }
            if ($code -ne 0) {
                $stall = Step-Retry $stall $local (Get-Size $file) $MaxTries "curl $code"
                continue
            }
        }
        $r = Test-Archive $file
        if ($r -eq 0) { return $file }
        if ($r -eq 2) {
            # 여기서 받는 파일은 모두 zip 이다. 다른 것이 왔으면 차단·안내 페이지라서 다시 받아도 같다
            $kind = Get-ArchiveExt $file
            if ($kind -eq '.html') { Write-Bad "파일 대신 웹 페이지가 왔어요(회사 보안 장비의 차단 페이지나 사이트 안내 페이지일 수 있어요): $(Split-Path -Leaf $file)" }
            else { Write-Bad "zip 파일이 아닌 것이 왔어요($kind): $(Split-Path -Leaf $file)" }
            Write-Info "    브라우저로 이 주소를 열어 무엇이 뜨는지 보세요: $url"
            Remove-Item -Force $file
            return $null
        }
        Write-Warn '압축 파일이 깨졌어요. 처음부터 다시 받아요'
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
    $script:WsLinkCount = 0
    $script:WsLinkSample = @()
    foreach ($l in [IO.File]::ReadAllLines($file)) {
        # 줄 앞 BOM·공백, "url = " 같은 앞말이 붙어 있어도 주소만 꺼낸다
        $u = [regex]::Match($l, 'https://\S+').Value.Trim('"')
        if (-not $u -or $l -match '^\s+\S+=') { continue }   # 들여쓴 aria2 옵션 줄은 건너뛴다
        $script:WsLinkCount++
        # 경로의 %2F 같은 부호를 먼저 풀어야 폴더 이름이 보인다
        $path = [uri]::UnescapeDataString(($u -split '\?')[0])
        if ($script:WsLinkSample.Count -lt 3) { $script:WsLinkSample += $path }
        $m = [regex]::Match($path, '(?i)/WildScenes_?2d/(.+)$')
        if (-not $m.Success) { continue }
        $list.Add([pscustomobject]@{ Url = $u; Rel = ($m.Groups[1].Value -replace '/', '\') })
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
$DriveJar = Join-Path $env:TEMP 'gpu_drive_cookies.txt'   # 서버에 올리는 datasets 폴더에 섞이지 않게

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
        'ok'      { Write-Ok "${label}: 받을 수 있어요" }
        'confirm' { Write-Ok "${label}: 받을 수 있어요(큰 파일 확인 페이지는 스크립트가 넘겨요)" }
        'quota'   { Write-Bad "${label}: Google 다운로드 한도 초과 ($info)"
                    Write-Info '    최근 이 파일을 받은 사람이 많아서 Google이 하루쯤 막았어요. 내일 다시 실행하세요.'
                    Write-Info '    급하면 브라우저에서 Google에 로그인해 "내 드라이브에 사본 만들기"를 한 뒤, 그 사본을 받아 datasets\<폴더> 에 넣으세요.' }
        'login'   { Write-Bad "${label}: 로그인이나 접근 권한이 필요해요 ($info)"
                    Write-Info '    공유 설정이 "링크가 있는 모든 사용자"에서 바뀌었어요. 브라우저에서 로그인해 받아 datasets\<폴더> 에 넣으세요.' }
        'bot'     { Write-Bad "${label}: Google이 이 망의 요청을 자동 요청으로 보고 막았어요 ($info)"
                    Write-Info '    회사 전체가 같은 IP로 나가는 망에서 생겨요. 몇 시간 뒤 다시 실행하거나, 브라우저로 받아 datasets\<폴더> 에 넣으세요.' }
        'proxy'   { Write-Bad "${label}: 회사 프록시나 보안 장비가 막았어요 ($info)"
                    Write-Info '    Google이 아니라 중간 장비가 보낸 응답이에요. 웹 페이지는 열어 주고 파일 받기만 막는 설정이 흔해요.'
                    Write-Info '    사내 IT에 drive.usercontent.google.com 파일 다운로드 허용을 요청하세요. 위 Server와 페이지 제목도 같이 알려 주세요.' }
        'google'  { Write-Bad "${label}: Google이 거절했는데 이유를 알 수 없어요 ($info)" }
        'net'     { Write-Bad "${label}: 응답을 받기 전에 연결이 끊겼어요 ($($d.Err))"
                    if ($d.Err -match '\((6|7|28)\)') { Write-Info '    주소를 찾지 못했거나 연결이 막혔어요. 브라우저만 프록시를 쓰는 망일 수 있어요.' }
                    elseif ($d.Err -match '\((35|60)\)') { Write-Info '    보안 연결(TLS) 단계에서 실패했어요. 회사 보안 장비가 막거나 인증서를 바꾸는 망이에요.' }
                    elseif ($d.Err -match '\(56\)') { Write-Info '    연결 중에 끊겼어요. 대부분 회사 프록시나 방화벽이 막은 경우예요.' } }
        default   { Write-Bad "${label}: 예상하지 못한 응답이에요 ($info)" }
    }
    if ($d.Kind -ne 'ok' -and $d.Kind -ne 'confirm') {
        Write-Info "    진단 기록: $($d.Saved) (파일 ID마다 .report.txt). 해결되지 않으면 이 폴더를 담당자에게 보내 주세요."
        Write-Info '    직접 받아 넣을 폴더와 파일 ID: docs\5_데이터셋.md 의 "Google Drive 데이터셋 받기"'
    }
}

# Google Drive 파일을 curl 로 받는다. 끊기면 이어받고, 큰 파일의 "바이러스 검사 안 함" 확인 페이지도 넘긴다
function Get-Drive($id, $target) {
    New-Item -ItemType Directory -Force (Split-Path $target) | Out-Null
    $part = "$target.download"
    $hdr  = "$target.headers"   # 응답 머리글. 압축이 아닌 파일(rosbag, 보정 파일)은 원래 파일 이름의 확장자를 여기서 가져온다
    $url  = "https://drive.usercontent.google.com/download?id=$id&export=download&confirm=t"
    $stall = 0
    while ($stall -lt $MaxTries) {
        $local = Get-Size $part
        if ($local) { Write-Info "이어받기: $(Format-Size $local)부터" }
        $ca = Get-CurlArgs $url
        & curl.exe -L -C - --fail --retry 3 --retry-delay 10 --connect-timeout 30 -Y 1024 -y 120 `
            -b $DriveJar -c $DriveJar @ca -D $hdr -o $part $url
        $code = $LASTEXITCODE
        if ($code -eq 33 -or $code -eq 36) { Remove-Item -Force -ErrorAction SilentlyContinue $part }
        if ($code -eq 22 -or $code -eq 56) {
            # 403 같은 거절: 다시 해도 소용없는 경우면 기다리지 말고 이유를 알려 준다
            $d = Test-DriveFile $id
            if ($d.Kind -eq 'ok' -or $d.Kind -eq 'confirm') {
                if ($local) { Write-Warn 'Google Drive가 이어받기 요청을 거절했어요. 처음부터 다시 받아요'; Remove-Item -Force $part }
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
                Write-Bad 'Google Drive 하루 다운로드 한도에 걸렸어요. 내일 다시 실행하세요.'
                return $null
            }
            $inputs = [regex]::Matches($html, 'name="([^"]+)"\s+value="([^"]*)"')
            if ($inputs.Count -and $html -match 'uuid') {
                $q = ($inputs | ForEach-Object { "$($_.Groups[1].Value)=$([uri]::EscapeDataString($_.Groups[2].Value))" }) -join '&'
                $url = "https://drive.usercontent.google.com/download?$q"
                Write-Info '큰 파일 확인 페이지를 넘기고 다시 받아요'
                $stall++
                continue
            }
            Write-Bad 'Google Drive가 파일 대신 웹 페이지를 보냈어요.'
            Show-DriveDiag (Test-DriveFile $id) $id
            return $null
        }
        $r = Test-Archive $part
        if ($r -eq 1) {
            Write-Warn '압축 파일이 깨졌어요. 처음부터 다시 받아요'
            Remove-Item -Force $part
            $stall++
            continue
        }
        if ($ext -eq '.bin' -and (Test-Path $hdr)) {
            # 압축이 아니면 Drive 가 알려 준 원래 파일 이름(Content-Disposition)의 확장자를 쓴다. 예: .bag, .yaml, .txt
            $cd = [regex]::Matches([IO.File]::ReadAllText($hdr), '(?im)^content-disposition:.*?filename="?([^";\r\n]+)')
            if ($cd.Count) { $e = [IO.Path]::GetExtension($cd[$cd.Count - 1].Groups[1].Value); if ($e -match '^\.[A-Za-z0-9]{1,6}$') { $ext = $e.ToLower() } }
        }
        Remove-Item -Force -ErrorAction SilentlyContinue $hdr
        $final = "$target$ext"
        Move-Item -Force $part $final
        return $final
    }
    return $null
}

# ORAD-3D: ModelScope 데이터셋 저장소를 modelscope 도구(uv 로 실행)로 통째로 받는다. 끊기면 다시 실행하면 이어서 받는다.
# 다 받으면 파일마다 체크섬을 ORAD-3D.ok 에 적는다(서버가 하나하나 확인한다)
function Get-ModelScope($id, $dir) {
    New-Item -ItemType Directory -Force $dir | Out-Null
    $stall = 0
    while ($stall -lt $MaxTries) {
        $before = (Get-ChildItem $dir -Recurse -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
        & $uv tool run --python 3.12 --from modelscope modelscope download --dataset $id --local_dir $dir | Out-Host
        if ($LASTEXITCODE -eq 0) { return $true }
        $after = (Get-ChildItem $dir -Recurse -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
        $stall = Step-Retry $stall $before $after $MaxTries "modelscope $LASTEXITCODE"
    }
    return $false
}

function Read-Plain($prompt) {
    $s = Read-Host $prompt -AsSecureString   # 화면과 기록 파일에 남지 않게
    $b = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($s)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($b) } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b) }
}

# -DriveCheck: 받지 않고 Google Drive 파일마다 진단만 하고 끝낸다
if ($DriveCheck) {
    Write-Host ''
    Write-Host '[Google Drive 진단] 파일마다 앞부분만 받아 봐요(데이터셋은 받지 않아요)' -ForegroundColor Cyan
    Write-Host "  curl: $((& curl.exe -V | Select-Object -First 1))"
    $p = Get-WindowsProxy
    Write-Host "  윈도우 프록시: $(if ($p) { $p } else { '없음' }), HTTPS_PROXY: $(if ($env:HTTPS_PROXY) { $env:HTTPS_PROXY } else { '없음' })"
    Test-Site 'Google Drive' 'https://drive.google.com/' | Out-Null
    Test-Site 'Google Drive 파일 서버' 'https://drive.usercontent.google.com/' | Out-Null
    foreach ($it in $DriveItems) { Show-DriveDiag (Test-DriveFile $it.Id) "$($it.Set)/$($it.Name)" }
    Write-Host ''
    Write-Host ' 받을 수 있는 파일은 -DriveCheck 를 빼고 다시 실행하면 받아요.'
    Write-Host ' 해결되지 않으면 아래 두 가지를 담당자에게 보내 주세요:' -ForegroundColor Yellow
    Write-Host "   $(Join-Path $Dest 'drive_check') 폴더, $script:LogPath"
    Allow-Sleep
    Stop-Transcript | Out-Null
    exit 0
}

# ------------------------------------------------------------------ 1. 점검
Write-Step 1 $T '점검'
$uv = Find-Exe 'uv' $root
if ($uv) { Write-Ok "uv : $uv" } else { Write-Bad 'uv가 없어요' }
foreach ($e in 'curl.exe', 'tar.exe') {
    if (Get-Command $e -ErrorAction SilentlyContinue) { Write-Ok $e } else { Write-Bad "없는 프로그램: $e (윈도우 10 1803 이후에는 기본으로 들어 있어요)" }
}
if (-not (Test-Path $check)) { Write-Bad '없는 파일: pc\check_archive.py (git pull로 저장소를 최신으로 받으세요)' }
if (-not (Test-Path (Join-Path $root 'server\datasets_install.sh'))) { Write-Bad '없는 파일: server\datasets_install.sh (git pull로 저장소를 최신으로 받으세요)' }
if ($script:Fails) {
    Stop-Run '필요한 프로그램이나 파일이 없어요' ("위 [문제] 줄을 보세요. uv는 설치한 뒤 PowerShell 창을 새로 여세요(또는 uv.exe를 $root 폴더에 넣기). " +
        '저장소 파일은 git pull로 받으세요.')
}

$sites = [ordered]@{ 'PyPI (검사 도구)' = 'https://pypi.org/simple/pip/' }
if ($Items | Where-Object { $_.Set -like 'goose*' }) { $sites['goose-dataset.de'] = 'https://goose-dataset.de/' }
if ($Items | Where-Object { $_.Set -eq 'RUGD' })     { $sites['rugd.vision'] = 'http://rugd.vision/' }
foreach ($k in $sites.Keys) { Test-Site $k $sites[$k] | Out-Null }
if ($script:Fails) {
    Stop-Run '접속되지 않는 사이트가 있어요' ('위 [문제] 줄 아래의 curl 오류와 설명을 보세요. 브라우저에서는 열린다면 ' +
        '사내 IT에 프록시 주소를 물어 .env 에 HTTPS_PROXY=http://프록시주소:포트 를 적고 다시 실행하세요. ' +
        '한 사이트만 막혔다면 -Only로 나머지만 먼저 받으세요(예: -Only goose,gooseEx).')
}

# Google Drive 는 스크립트가 받지 않지만, 브라우저로 받을 수 있는지 알려 준다(실패해도 멈추지 않는다)
$driveOk = $false
if ($DriveItems.Count) {
    $d1 = Invoke-Probe 'https://drive.google.com/'
    if ($d1.Code -ne 0) {
        Write-Warn "Google Drive 접속 안 됨(curl $($d1.Code)). RELLIS-3D, TAS500, GO는 건너뛰고 나머지를 받아요. 접속되면 같은 명령을 다시 실행하세요."
    } else {
        # 첫 페이지만 열리고 파일 받기는 막힌 망이 있어, 실제 파일 하나를 앞부분만 받아 본다
        $d = Test-DriveFile $DriveItems[0].Id
        $driveOk = $d.Kind -ne 'proxy' -and $d.Kind -ne 'net'
        if ($d.Kind -eq 'ok' -or $d.Kind -eq 'confirm') {
            Write-Ok 'Google Drive 파일을 받을 수 있어요. RELLIS-3D, TAS500, GO도 받아요'
        } else {
            Show-DriveDiag $d "Google Drive 시험 파일($($DriveItems[0].Set)/$($DriveItems[0].Name))"
            if ($driveOk) { Write-Warn 'Google에는 접속되니 파일마다 받아 볼게요.' }
            else { Write-Warn 'RELLIS-3D, TAS500, GO는 건너뛰고 나머지를 받아요. 파일마다 자세히 보려면 -DriveCheck를 붙여 실행하세요.' }
        }
    }
}

Write-Info '검사용 Python을 준비하는 중이에요(처음 한 번만)'
& $uv python install 3.12 | Out-Host
if ($LASTEXITCODE -ne 0) { Stop-Run 'uv가 Python 3.12를 받지 못했어요' '인터넷(github.com) 접속을 확인하고 다시 실행하세요.' }
Write-Ok 'Python 3.12를 준비했어요'

if ($doWild -and $WildScenesLinks -and -not (Test-Path (Join-Path $Dest 'wildscenes.ok'))) {
    if (-not (Test-Path $WildScenesLinks)) { Stop-Run "링크 목록 파일을 찾지 못했어요: $WildScenesLinks" '-WildScenesLinks 뒤(또는 .env 의 WILDSCENES_LINKS)에 포털에서 받은 .txt 파일의 전체 경로를 적어 다시 실행하세요.' }
    $script:WsLinks = Get-WsLinks $WildScenesLinks
    if (-not $script:WsLinks.Count) {
        Write-Info "    목록 파일의 주소 줄: $($script:WsLinkCount)개"
        $script:WsLinkSample | ForEach-Object { Write-Info "    예: $_" }
        Stop-Run '링크 목록에 WildScenes2d 파일이 없어요' "포털($WsPortal)의 Download → Get a list of file download links 에서 받은 .txt 파일인지 확인하세요."
    }
    Write-Ok "WildScenes 링크 목록: 2D 파일 $($script:WsLinks.Count)개"
    $f0 = $script:Fails   # 앞의 Google Drive 진단 실패는 세지 않는다(CSIRO 접속만 본다)
    Test-Site 'CSIRO S3 저장소' "https://$(([uri]$script:WsLinks[0].Url).Host)/" | Out-Null
    if ($script:Fails -gt $f0) { Stop-Run 'CSIRO S3 저장소에 접속되지 않아요' '위 [문제] 줄 아래 설명을 보세요. 브라우저에서는 열린다면 아래 기록 파일을 담당자에게 보내 주세요.' }
} elseif ($doWild -and -not (Test-Path (Join-Path $Dest 'wildscenes.ok'))) {
    if ($wsEnv) {
        Write-Ok 'WildScenes 접속 정보는 .env 에서 읽었어요(약 48시간만 유효해요. 거절되면 포털에서 새로 받아 .env 를 고치세요)'
        $server = $env:WILDSCENES_S3_SERVER.Trim()
        $wsDir  = $env:WILDSCENES_S3_DIR.Trim().TrimStart('/')
        $env:AWS_ACCESS_KEY_ID     = $env:WILDSCENES_ACCESS_KEY.Trim()
        $env:AWS_SECRET_ACCESS_KEY = $env:WILDSCENES_SECRET_KEY.Trim()
    } else {
        Write-Host ''
        Write-Host '  WildScenes 접속 정보를 입력하세요. 접속 정보는 약 48시간만 유효하니 지금 새로 받으세요.' -ForegroundColor Cyan
        Write-Host "  포털: $WsPortal"
        Write-Host '  포털에서 Download → Download files via S3 Client 를 고르고, 화면에 나온 네 값을 차례로 복사해 붙여 넣으세요.'
        Write-Host '  두 키는 입력해도 화면과 기록 파일에 남지 않아요. .env 에 적어 두면 묻지 않아요.'
        Write-Host '  (자세한 설명: docs\5_데이터셋.md 의 "WildScenes 접속 정보 받기")'
        $open = Read-Host '  포털 페이지를 브라우저로 열까요? [Y/n]'
        if ($open -notmatch '^[nN]') { Start-Process $WsPortal }
        $server = (Read-Host '  Server (예: s3.data.csiro.au)').Trim()
        $wsDir  = (Read-Host '  Remote Directory (예: dapprd/000012345v001/)').Trim().TrimStart('/')
        $env:AWS_ACCESS_KEY_ID     = (Read-Plain '  Access Key').Trim()
        $env:AWS_SECRET_ACCESS_KEY = (Read-Plain '  Secret Access Key').Trim()
    }
    $env:AWS_DEFAULT_REGION    = 'us-east-1'   # S3 호환 저장소라 지역은 아무 값이나 된다
    $env:AWS_RETRY_MODE        = 'standard'
    $env:AWS_MAX_ATTEMPTS      = '10'
    if (-not $wsDir.EndsWith('/')) { $wsDir += '/' }
    $script:WsEndpoint = if ($server -match '://') { $server } else { "https://$server" }

    $f0 = $script:Fails
    Test-Site 'CSIRO S3 저장소' $script:WsEndpoint | Out-Null
    if ($script:Fails -gt $f0) {
        Stop-Run 'CSIRO S3 저장소에 접속되지 않아요' ('위 [문제] 줄 아래 설명을 보세요. 브라우저에서는 열린다면(401, AccessDenied 같은 오류가 떠도 열린 거예요) ' +
            'docs\5_데이터셋.md 의 "WildScenes 링크 목록으로 받기"를 따라 -WildScenesLinks를 붙여 실행하세요.')
    }
    $pa = $script:HostArgs[([uri]$script:WsEndpoint).Host]
    if ($pa -and $pa.Count -gt 2) {
        Stop-Run 'CSIRO S3 저장소는 윈도우 로그인 인증 프록시로만 연결되는데, AWS CLI는 그 인증을 하지 못해요' `
            'docs\5_데이터셋.md 의 "WildScenes 링크 목록으로 받기"를 따라 -WildScenesLinks를 붙여 실행하세요(curl로 받아서 인증이 돼요).'
    }

    Write-Info 'AWS CLI를 준비하는 중이에요(처음 한 번만)'
    & $uv tool install awscli | Out-Host
    if ($LASTEXITCODE -ne 0) { Stop-Run 'AWS CLI를 준비하지 못했어요' 'PyPI(pypi.org) 접속을 확인하고 다시 실행하세요.' }

    Write-Info 'WildScenes2d 폴더를 찾는 중이에요'
    $wsPrefix = Find-WsPrefix $wsDir
    if (-not $wsPrefix) {
        Write-Host '  원격 폴더 내용:'
        Invoke-Aws s3 ls "s3://$wsDir" | Out-Host
        Stop-Run 'WildScenes2d 폴더를 찾지 못했어요' ("접속 정보가 틀렸거나 48시간이 지났을 수 있어요. 포털($WsPortal)에서 접속 정보를 새로 받아 다시 실행하세요. " +
            'SSL·certificate 오류가 보이면 회사 보안 장비 때문이니 아래 기록 파일을 담당자에게 보내 주세요.')
    }
    Write-Ok "WildScenes에 접속했어요: s3://$wsPrefix"
}

$needGB = (@($Items) + @($LateItems) | Where-Object { -not (Test-Path "$(Join-Path (Join-Path $Dest $_.Set) $_.Name).ok") } |
    ForEach-Object { $_.GB } | Measure-Object -Sum).Sum
if (-not $needGB) { $needGB = 0 }
if ($driveOk) {
    $needGB += ($DriveItems | Where-Object { -not (Get-DoneDrive (Join-Path (Join-Path $Dest $_.Set) $_.Name)) } |
        ForEach-Object { $_.GB } | Measure-Object -Sum).Sum
}
if ($doWild -and -not (Test-Path (Join-Path $Dest 'wildscenes.ok'))) { $needGB += 47 }
if ($doOrad -and -not (Test-Path (Join-Path $Dest 'ORAD-3D.ok'))) { $needGB += 350 }
$free = Get-FreeGB $Dest
if ($free -lt $needGB + 5) {
    Stop-Run "남은 공간이 $free GB예요(앞으로 약 $needGB GB가 필요해요)" '공간을 비우거나, -Dest E:\datasets 처럼 넉넉한 드라이브로 받는 곳을 바꾸거나, -Only로 나눠 받으세요.'
}
Write-Ok "남은 공간 $free GB, 앞으로 받을 양 약 $needGB GB"

# ------------------------------------------------------------------ 2. 받기
Write-Step 2 $T '받기 (끊기면 이어받아요)'
$result = [ordered]@{}
# 직접 링크 목록을 차례로 받는다. $tag 는 화면의 번호 앞에 붙는 글자
function Get-Items($list, $tag) {
    $n = 0
    foreach ($it in $list) {
        $n++
        $target = Join-Path (Join-Path $Dest $it.Set) $it.Name
        $label  = "$($it.Set)/$($it.Name)"
        if (Test-Path "$target.ok") { Write-Host "  ($tag$n/$($list.Count)) ${label}: 이미 받았어요"; $result[$label] = '받음'; continue }
        Write-Host ''
        Write-Host "  ($tag$n/$($list.Count)) $label 받는 중 (약 $($it.GB) GB)" -ForegroundColor Cyan
        $f = Get-Url $it.Url $target
        if ($f) { Set-Done "$target.ok" $f; Write-Ok "$label 받았어요"; $result[$label] = '받음' }
        else    { Write-Bad "$label 받지 못했어요"; $result[$label] = '실패' }
    }
}
Get-Items $Items ''

if ($doWild) {
    $wdir = Join-Path $Dest 'wildscenes'
    if (Test-Path "$wdir.ok") {
        Write-Host '  wildscenes: 이미 받았어요'; $result['wildscenes'] = '받음'
    } else {
        Write-Host ''
        Write-Host '  wildscenes 받는 중 (약 47 GB, 파일이 많아 오래 걸려요)' -ForegroundColor Cyan
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
                $shown = 0
                foreach ($it in $todo) {
                    $i++
                    if ($i % 20 -eq 1) { Write-Progress -Activity 'WildScenes 받기' -Status "$($doneSet.Count)/$($links.Count) 완료, 지금: $($it.Rel)" -PercentComplete (100 * $doneSet.Count / $links.Count) }
                    $out = Join-Path $wdir $it.Rel
                    New-Item -ItemType Directory -Force (Split-Path $out) | Out-Null
                    $ca = Get-CurlArgs $it.Url
                    $msg = & curl.exe -sS -L -C - --fail --retry 3 --retry-delay 5 --connect-timeout 30 -Y 1024 -y 120 @ca `
                        -o $out --stderr - $it.Url | Out-String
                    $code = $LASTEXITCODE
                    if ($code -eq 0) { [void]$doneSet.Add($it.Rel); [IO.File]::AppendAllText($doneFile, "$($it.Rel)`n", $utf8) }
                    elseif ($msg -match 'returned error: 403') { $expired = $true; Write-Info "    $($it.Rel): $($msg.Trim())"; break }
                    else {
                        if ($code -eq 33 -or $code -eq 36) { Remove-Item -Force -ErrorAction SilentlyContinue $out }
                        # 실패 이유를 처음 몇 개만 보여 준다(전부는 기록 파일이 너무 길어진다)
                        if ($shown -lt 3) { $shown++; Write-Warn "받지 못한 파일: $($it.Rel) (curl $code $($msg.Trim()))" }
                    }
                }
                Write-Progress -Activity 'WildScenes 받기' -Completed
                if ($expired) {
                    Write-Bad 'WildScenes 링크가 만료됐어요(403)'
                    Write-Info "    포털($WsPortal)에서 링크 목록을 새로 받아 같은 명령을 다시 실행하세요. 받은 파일은 건너뛰어요."
                    break
                }
                if ($doneSet.Count -gt $before) { $stall = 0; Write-Warn "남은 $($links.Count - $doneSet.Count)개를 다시 받아요"; Start-Sleep 10 }
                else { $stall = Step-Retry $stall 0 0 $MaxTries 'WildScenes' }
            }
        }
        while (-not $WildScenesLinks -and -not $done -and $stall -lt $MaxTries) {
            # sync 는 이미 받은 파일을 건너뛰므로 몇 번이고 다시 해도 된다
            $before = Get-Size $wdir
            Invoke-Aws s3 sync "s3://$wsPrefix" $wdir --only-show-errors | Out-Host
            $code = $LASTEXITCODE
            if ($code -eq 0) {
                Write-Info '빠진 파일이 없는지 확인하는 중이에요'
                $left = @(Invoke-Aws s3 sync "s3://$wsPrefix" $wdir --dryrun | Where-Object { $_ -match '\(dryrun\)' })
                if ($LASTEXITCODE -eq 0 -and $left.Count -eq 0) { $done = $true; break }
                Write-Warn "아직 $($left.Count)개가 남았어요"
            } else {
                # 접속 정보가 만료됐으면 기다려도 소용없다
                Invoke-Aws s3 ls "s3://$wsPrefix" | Out-Null
                if ($LASTEXITCODE -ne 0) {
                    Write-Bad 'WildScenes 접속 정보가 만료됐거나 막혔어요'
                    Write-Info "    포털($WsPortal)에서 접속 정보를 새로 받아 같은 명령(-WildScenes)을 다시 실행하세요. 받은 파일은 건너뛰어요."
                    break
                }
            }
            $stall = Step-Retry $stall $before (Get-Size $wdir) $MaxTries "aws $code"
        }
        if ($done) {
            $m = Get-ChildItem $wdir -Recurse -File | Measure-Object -Property Length -Sum
            [IO.File]::WriteAllText("$wdir.ok", "files=$($m.Count) bytes=$($m.Sum)`n", (New-Object Text.UTF8Encoding $false))
            Remove-Item -Force -ErrorAction SilentlyContinue "$wdir.sha256"   # 3단계에서 새로 만든다
            Write-Ok "wildscenes를 받았어요(파일 $($m.Count)개)"; $result['wildscenes'] = '받음'
        } else { $result['wildscenes'] = '실패' }
    }
} elseif (Want 'wildscenes') {
    $result['wildscenes'] = '건너뜀(받으려면 -WildScenes 또는 -WildScenesLinks 를 붙여 실행)'
}
Remove-Item Env:AWS_ACCESS_KEY_ID, Env:AWS_SECRET_ACCESS_KEY -ErrorAction SilentlyContinue

# Google Drive 데이터셋
$n = 0
foreach ($it in $DriveItems) {
    $n++
    $target = Join-Path (Join-Path $Dest $it.Set) $it.Name
    $label  = "$($it.Set)/$($it.Name)"
    if (Get-DoneDrive $target) { Write-Host "  (Drive $n/$($DriveItems.Count)) ${label}: 이미 받았어요"; $result[$label] = '받음'; continue }
    if (-not $driveOk) { $result[$label] = '건너뜀(Drive 접속 안 됨. 접속되면 다시 실행)'; continue }
    Write-Host ''
    Write-Host "  (Drive $n/$($DriveItems.Count)) $label 받는 중 (약 $($it.GB) GB)" -ForegroundColor Cyan
    $f = Get-Drive $it.Id $target
    if ($f) { Set-Done "$f.ok" $f; Write-Ok "$label 받았어요"; $result[$label] = '받음' }
    else    { Write-Bad "$label 받지 못했어요"; $result[$label] = '실패' }
}

# ORAD-3D (ModelScope)
if ($doOrad) {
    $odir = Join-Path $Dest 'ORAD-3D'
    if (Test-Path "$odir.ok") {
        Write-Host '  ORAD-3D: 이미 받았어요'; $result['ORAD-3D'] = '받음'
    } else {
        Write-Host ''
        Write-Host "  ORAD-3D 받는 중 (약 350 GB, ModelScope $ModelScopeId)" -ForegroundColor Cyan
        if (Get-ModelScope $ModelScopeId $odir) {
            # 파일마다 체크섬(서버가 하나하나 확인). 받기 도구가 남긴 임시 파일은 뺀다
            $ofiles = @(Get-ChildItem $odir -Recurse -File | Where-Object { $_.FullName -notmatch '\\(\._____temp|\.cache)\\' -and $_.Name -notmatch '\.(incomplete|lock)$' })
            Write-Info "ORAD-3D 파일 $($ofiles.Count)개의 체크섬을 계산하는 중이에요(크면 한 시간 안팎)"
            $ol = foreach ($f in $ofiles) { "$((Get-FileHash $f.FullName -Algorithm SHA256).Hash.ToLower())  $($f.FullName.Substring($Dest.Length + 1) -replace '\\', '/')" }
            [IO.File]::WriteAllText("$odir.ok.part", ((@($ol) -join "`n") + "`n"), (New-Object Text.UTF8Encoding $false))
            Move-Item -Force "$odir.ok.part" "$odir.ok"
            Write-Ok 'ORAD-3D 받았어요'; $result['ORAD-3D'] = '받음'
        } else {
            Write-Bad 'ORAD-3D 받지 못했어요. www.modelscope.cn 접속을 확인하고 같은 명령을 다시 실행하세요(받은 데까지 이어서 받아요)'
            $result['ORAD-3D'] = '실패'
        }
    }
}

# 접속이 잘 안 되는 사이트(CaSSeD)는 다른 것을 다 받은 뒤 맨 끝에
Get-Items $LateItems '나중 '

# 브라우저로 받아 직접 넣어 둔 압축 파일도 검사한다(스크립트가 받은 파일은 이미 .ok 가 있다)
foreach ($set in $Manual) {
    $dir = Join-Path $Dest $set
    if (-not (Test-Path $dir)) { continue }
    $arcs = @(Get-ChildItem $dir -File | Where-Object { $_.Name -match '\.(zip|tar|tgz|tar\.gz|7z)$' -and -not (Test-Path "$($_.FullName).ok") })
    foreach ($a in $arcs) {
        $label = "$set/$($a.Name) (직접 넣음)"
        $r = Test-Archive $a.FullName
        if ($r -ne 1) { Set-Done "$($a.FullName).ok" $a.FullName; $result[$label] = '받음' }
        else { Write-Bad "깨진 파일: $set/$($a.Name). 다시 받아 넣으세요."; $result[$label] = '실패' }
    }
}

# ------------------------------------------------------------------ 3. GPU 서버에 올릴 목록
Write-Step 3 $T 'GPU 서버에서 확인할 체크섬 목록 만들기'
$oks = @(Get-ChildItem $Dest -Recurse -Filter '*.ok' -File | Where-Object { $_.Name -ne 'wildscenes.ok' })
$lines = @($oks | ForEach-Object { (Get-Content -Raw -Encoding UTF8 $_.FullName).Trim() })
# WildScenes 는 압축이 아니라 파일 수만 개라, 파일마다 체크섬을 따로 적어 두고 목록에 넣는다(서버가 하나하나 확인)
$wok = Join-Path $Dest 'wildscenes.ok'
$wsum = Join-Path $Dest 'wildscenes.sha256'
if ((Test-Path $wok) -and -not (Test-Path $wsum)) {
    $wfiles = @(Get-ChildItem (Join-Path $Dest 'wildscenes') -Recurse -File)
    Write-Info "wildscenes 파일 $($wfiles.Count)개의 체크섬을 계산하는 중이에요(약 47 GB, 10분 안팎)"
    $i = 0
    $wl = foreach ($f in $wfiles) {
        $i++; if ($i % 200 -eq 1) { Write-Progress -Activity 'wildscenes 체크섬' -Status "$i/$($wfiles.Count)" -PercentComplete (100 * $i / $wfiles.Count) }
        "$((Get-FileHash $f.FullName -Algorithm SHA256).Hash.ToLower())  $($f.FullName.Substring($Dest.Length + 1) -replace '\\', '/')"
    }
    Write-Progress -Activity 'wildscenes 체크섬' -Completed
    [IO.File]::WriteAllText("$wsum.part", ((@($wl) -join "`n") + "`n"), (New-Object Text.UTF8Encoding $false))
    Move-Item -Force "$wsum.part" $wsum
}
if (Test-Path $wsum) { $lines += @([IO.File]::ReadAllLines($wsum) | Where-Object { $_ }) }
[IO.File]::WriteAllText((Join-Path $Dest 'MANIFEST.sha256'), (($lines -join "`n") + "`n"), (New-Object Text.UTF8Encoding $false))
$sh = [IO.File]::ReadAllText((Join-Path $root 'server\datasets_install.sh')) -replace "`r", ''
[IO.File]::WriteAllText((Join-Path $Dest 'datasets_install.sh'), $sh, (New-Object Text.UTF8Encoding $false))
Write-Ok "파일 $($lines.Count)개를 체크섬 목록에 적고 datasets_install.sh를 넣었어요"

# ------------------------------------------------------------------ 4. 결과
Write-Step 4 $T '결과'
foreach ($k in $result.Keys) {
    $v = $result[$k]
    $c = if ($v -like '받음*') { 'Green' } elseif ($v -eq '실패') { 'Red' } else { 'Yellow' }
    Write-Host ('  {0,-40} {1}' -f $k, $v) -ForegroundColor $c
}
$total = (Get-ChildItem $Dest -Recurse -File | Measure-Object -Property Length -Sum).Sum
$failed = @($result.Keys | Where-Object { $result[$_] -eq '실패' })
$skipped = @($result.Keys | Where-Object { $result[$_] -like '건너뜀*' })
Allow-Sleep
Write-Host ''
if ($failed.Count) {
    Write-Host '################ 일부 못 받음 ################' -ForegroundColor Yellow
    Write-Host " 못 받은 것: $($failed -join ', ')"
    Write-Host ' 같은 명령을 다시 실행하면 못 받은 것만 이어서 받아요.'
    Write-Host ' 받은 것만 먼저 GPU 서버에 올려도 돼요(GPU 서버 스크립트는 올라온 것만 설치해요).'
    Write-Host " 계속 안 되면 이 기록 파일을 담당자에게 보내 주세요: $script:LogPath"
} else {
    Write-Host '############################ 완료 ############################' -ForegroundColor Green
}
if ($skipped.Count) {
    Write-Host " 건너뛴 것: $($skipped -join ', ')" -ForegroundColor Yellow
    Write-Host '   이유는 위 결과 표에 있어요. 준비되면 같은 명령을 다시 실행하세요(받은 것은 건너뛰어요).'
}
Write-Host ''
Write-Host ' 접근 PC에서 할 일은 끝났어요. GPU 서버에 올릴 폴더(통째로):' -ForegroundColor Green
Write-Host "   $Dest  ($(Format-Size $total))"
if ((Split-Path -Leaf $Dest) -ne 'datasets') { Write-Host '   폴더 이름이 datasets 가 아니면, 올리기 전에 datasets 로 바꾸세요(서버 명령이 이 이름만 받아요).' -ForegroundColor Yellow }
Write-Host ''
Save-Fingerprint 'datasets 폴더' (Get-Fingerprint @((Join-Path $Dest 'MANIFEST.sha256'), (Join-Path $Dest 'datasets_install.sh')))
Write-Host '   (MANIFEST.sha256과 datasets_install.sh를 이어 붙인 지문이에요. 나머지 파일은 설치 스크립트가 MANIFEST.sha256으로 하나하나 확인해요)'
Show-NotNeeded $Dest (Join-Path $Dest 'MANIFEST.sha256') @('wildscenes/')
Write-Host ''
Write-Host ' 1) 공용 계정의 FileZilla로 GPU 서버의 /app/upload 에 폴더째 올리세요.' -ForegroundColor Green
Write-Host ' 2) root(PuTTY)로 /app/inbox 에 새로 복사하세요. 링크가 섞였으면 멈추고, 아니면 지문을 보여 줘요. 위 지문과 다르면 실행하지 마세요.' -ForegroundColor Green
Write-Host '   /app/admin/bin/gpu fetch datasets'
Write-Host ' 3) 같으면 설치하세요. 서버 1에서만 하면 돼요(NAS에 설치돼 서버 2도 같이 써요). 다 끝나면 /app/upload/datasets 는 지워 공간을 비우세요.' -ForegroundColor Green
Write-Host '   bash /app/inbox/datasets/datasets_install.sh'
Write-Host ' 자세한 순서: docs\5_데이터셋.md'
Write-Host '##############################################################'
Stop-Transcript | Out-Null
if ($failed.Count) { exit 1 }
