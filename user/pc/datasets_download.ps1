<#
[접근 PC] 세그멘테이션 라벨이 있는 데이터셋을 받는다(RELLIS-3D·GO·ORAD-3D 등은 라이다·rosbag 까지 전부). 설명은 user\데이터셋_넣기.md.
점검 → 받기(끊기면 이어받기) → 검사 → GPU 서버에 올릴 목록 만들기까지 한 번에 한다.
끊기거나 실패하면 같은 명령을 다시 실행한다. 받은 것은 건너뛴다.

  powershell -ExecutionPolicy Bypass -File .\user\pc\datasets_download.ps1               # .env 에 WILDSCENES_LINKS 가 없으면 WildScenes 빼고
  powershell -ExecutionPolicy Bypass -File .\user\pc\datasets_download.ps1 -WildScenesLinks C:\Users\나\Downloads\61541v001.txt
                                                                     # WildScenes 는 포털의 링크 목록 파일로 받는다
  powershell -ExecutionPolicy Bypass -File .\user\pc\datasets_download.ps1 -Only goose,RUGD
  powershell -ExecutionPolicy Bypass -File .\user\pc\datasets_download.ps1 -Only ORAD-3D       # 큰 것은 따로(약 350 GB)
  powershell -ExecutionPolicy Bypass -File .\user\pc\datasets_download.ps1 -Only cityscapes,bdd100k   # 도심 주행 세그만
  powershell -ExecutionPolicy Bypass -File .\user\pc\datasets_download.ps1 -DriveCheck     # Google Drive 파일마다 받을 수 있는지만 진단
  powershell -ExecutionPolicy Bypass -File .\user\pc\datasets_download.ps1 -Auto           # 자동 받기: Google Drive 데이터셋 중 못 받은 것을 6시간마다 다시 받기(다 받으면 저절로 꺼짐)
  powershell -ExecutionPolicy Bypass -File .\user\pc\datasets_download.ps1 -AutoOff        # 자동 받기 끄기
.env 에 링크 목록 파일 경로(WILDSCENES_LINKS)를 적어 두면 -WildScenesLinks 를 붙이지 않아도 WildScenes 까지 받는다.
Cityscapes 는 회원 계정으로 로그인해서 받는다. .env 의 CITYSCAPES_USERNAME·CITYSCAPES_PASSWORD 가 없으면 실행 중에 묻는다.
#>
param(
    [string]$Dest = (Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'datasets'),
    [string]$WildScenesLinks = '',    # WildScenes 를 포털 "Get a list of file download links" 로 받은 목록 파일로 받는다
    [string[]]$Only = @(),            # 이 폴더만 받는다(쉼표로 여러 개)
    [switch]$DriveCheck,              # 받지 않고 Google Drive 파일마다 받을 수 있는지, 안 되면 왜인지 진단만 한다
    [int]$MaxTries = 5,               # 받은 양이 늘지 않은 채 연속으로 끊긴 횟수가 이만큼이면 그 파일은 포기(약 5분). 받는 중이면 끊겨도 계속해요
    [int]$LateTries = 3,              # 맨 끝에 받는 것(사내망에서 막히는 사이트)은 이만큼만 해 보고 넘어간다(받아지기 시작하면 끝까지 이어받아요)
    [switch]$Auto,                    # 받지 않고, 몇 시간마다 자동으로 다시 받도록 윈도우 작업 스케줄러에 등록한다(-Only 가 없으면 Google Drive 데이터셋만)
    [int]$AutoHours = 6,              # 몇 시간마다 다시 받을지
    [int]$AutoDays = 14,              # 이 날수가 지나면 다 받지 못했어도 자동 받기를 멈춘다
    [switch]$AutoOff,                 # 자동 받기를 끈다
    [switch]$FromTask                 # 작업 스케줄러가 붙인다(직접 쓰지 않는다). 다 받으면 자동 받기를 스스로 끈다
)
$here = $PSScriptRoot
$root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent   # 저장소 맨 위(D:\gpu). 결과 폴더와 uv.exe 는 여기
. (Join-Path $root 'common\gpu_common.ps1')
$Only   = @($Only | ForEach-Object { $_ -split ',' } | Where-Object { $_ })
# .env 의 WildScenes 설정. 명령에 붙인 값이 먼저다
if (-not $WildScenesLinks -and $env:WILDSCENES_LINKS) { $WildScenesLinks = [Environment]::ExpandEnvironmentVariables($env:WILDSCENES_LINKS) }
# 예전 S3(AWS CLI) 방식 설정은 더 쓰지 않는다. 남아 있으면 지워도 된다고 알려 준다(키가 .env 에 계속 남지 않게)
$oldWs = @('WILDSCENES_S3_SERVER', 'WILDSCENES_S3_DIR', 'WILDSCENES_ACCESS_KEY', 'WILDSCENES_SECRET_KEY' | Where-Object { [Environment]::GetEnvironmentVariable($_) })
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
    # BDD100K 세그(도심 주행 10,000장: train 7,000·val 1,000·test 2,000, 라벨은 train·val). 회원가입 없는 공식 미러(dl.yf.io, 2026-11-12 확인)
    @{ Set = 'bdd100k'; GB = 2;  Name = 'bdd100k_images_10k.zip'; Url = 'http://dl.yf.io/bdd100k/bdd100k_images_10k.zip' }
    @{ Set = 'bdd100k'; GB = 1;  Name = 'bdd100k_seg_maps.zip';   Url = 'http://dl.yf.io/bdd100k/bdd100k_seg_maps.zip' }
    # YCOR(Yamaha-CMU): AirLab 페이지의 Box 공유 링크(cmu.box.com/s/3fngoljhcwhqf2z5cbepufh331qtesxt)에 든 파일 하나. 받을 때마다 Box 가 임시 주소로 넘겨 준다(2026-11-06 확인)
    # Late: 사내망에서 cmu.box.com 이 막혀 있어 맨 끝에 받는다
    @{ Set = 'ycor';    GB = 1;  Name = 'yamaha_seg.tar.gz';      Url = 'https://cmu.app.box.com/index.php?rm=box_download_shared_file&shared_name=3fngoljhcwhqf2z5cbepufh331qtesxt&file_id=f_771170167866'; Late = $true }
    # CAVS 시맨틱 세그(실제 1,077장 + 합성 1,947장 + rosbag). 주소는 사이트의 "Download Dataset" 링크(2026-11-06 확인). 막히면 브라우저로 받아 datasets\CaSSeD 에 넣는다
    # Late: 사내망에서 접속되지 않아(타임아웃) 다른 것을 다 받은 뒤 맨 끝에 받는다
    @{ Set = 'CaSSeD';  GB = 38; Name = 'CaSSeD.tar.gz';          Url = 'https://www.cavs.msstate.edu/resources/downloads/CaSSeD/CaSSeD.tar.gz'; Late = $true }
    # Freiburg Forest: 사이트의 download_freiburg_forest_*.sh 가 받는 512 MB 조각들(.part-aa …). 조각을 받아 하나로 합친 뒤 검사한다(2026-11-06 확인)
    @{ Set = 'freiburg_forest'; GB = 2;  Name = 'freiburg_forest_annotated.tar.gz'; Url = 'https://deepscene.cs.uni-freiburg.de/static/datasets/freiburg_forest_annotated.tar.gz'; Parts = 3 }
    @{ Set = 'freiburg_forest'; GB = 18; Name = 'freiburg_forest_raw.tar.gz';       Url = 'https://deepscene.cs.uni-freiburg.de/static/datasets/freiburg_forest_raw.tar.gz';       Parts = 34 }
)
$Items = @($Items | Where-Object { Want $_.Set })
$LateItems = @($Items | Where-Object { $_.Late })
$Items     = @($Items | Where-Object { -not $_.Late })

# Google Drive 에만 있는 것. Drive 에 접속되면 aria2c 로 받고(이어받기), 안 되면 건너뛴다.
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
# 스크립트로 받을 수 없어서 브라우저로 받아 datasets\<폴더> 에 넣는 것. 넣어 둔 압축 파일은 검사해서 목록에 넣는다(user\데이터셋_넣기.md)
#   rellis_full: Drive 폴더(원본 rosbag 5개 시퀀스, 보정 원본), CaSSeD: 사내망에서 접속 안 될 때. ycor·freiburg_forest 도 스크립트가 못 받으면 손으로 넣을 수 있게 둔다
#   cityscapes·bdd100k: 브라우저로 받은 압축 파일을 넣어도 되게 둔다
$HandSets = @('rellis_full', 'ycor', 'freiburg_forest', 'CaSSeD', 'cityscapes', 'bdd100k')
# Cityscapes: 회원 계정으로 로그인한 뒤 받는다(packageID 는 사이트 다운로드 페이지의 번호). 받기 전에 사이트가 알려 주는 파일 이름이 맞는지 본다
$CsItems = @(
    @{ Set = 'cityscapes'; GB = 1;  Name = 'gtFine_trainvaltest.zip';     Url = 'https://www.cityscapes-dataset.com/file-handling/?packageID=1' }   # 정밀 라벨 5,000장(241 MB)
    @{ Set = 'cityscapes'; GB = 11; Name = 'leftImg8bit_trainvaltest.zip'; Url = 'https://www.cityscapes-dataset.com/file-handling/?packageID=3' }   # 사진(11 GB)
)
$CsItems = @($CsItems | Where-Object { Want $_.Set })
$CsLogin = 'https://www.cityscapes-dataset.com/login/'
# ORAD-3D: ModelScope(중국) 데이터셋 저장소에서 modelscope 도구로 받는다(약 350 GB, 끊기면 이어받기)
$ModelScopeId = 'Georgehhhh/ORAD-3D'
$DriveItems = @($DriveItems | Where-Object { Want $_.Set })
$Manual = @(@($DriveItems | ForEach-Object { $_.Set }) + @($HandSets | Where-Object { Want $_ }) | Select-Object -Unique)
$doOrad = Want 'ORAD-3D'
$doWild = [bool]$WildScenesLinks -and (Want 'wildscenes')
$WsPortal = 'https://data.csiro.au/collection/csiro:61541'   # WildScenes 포털 페이지

New-Item -ItemType Directory -Force $Dest | Out-Null
$Dest = (Resolve-Path $Dest).Path.TrimEnd('\')

# 자동 받기(윈도우 작업 스케줄러). Google Drive 하루 다운로드 한도에 걸린 파일을 풀리는 대로 다시 받으려고 쓴다.
# 한도는 정해진 시각에 풀리지 않고 걸린 때부터 하루쯤 지나야 풀려서(Google 이 시각을 알려 주지 않는다), 하루 한 번이 아니라 몇 시간마다 다시 해 본다
$TaskName = 'GPU 데이터셋 자동 받기'
function Remove-AutoTask {
    if (-not (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue)) { return $false }
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    return $true
}
if ($AutoOff) {
    if (Remove-AutoTask) { Write-Ok "자동 받기를 껐어요($TaskName)" } else { Write-Info '켜 둔 자동 받기가 없어요' }
    exit 0
}
if ($Auto) {
    if ($AutoHours -lt 1) { Write-Bad "-AutoHours 는 1 이상으로 적어 주세요(지금 값: $AutoHours)"; exit 1 }
    $sets = if ($Only.Count) { $Only } else { @($DriveItems | ForEach-Object { $_.Set } | Select-Object -Unique) }
    $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"", '-Dest', "`"$Dest`"", '-Only', ($sets -join ','), '-AutoHours', $AutoHours, '-FromTask')
    if ($WildScenesLinks -and ($sets -contains 'wildscenes')) { $a += @('-WildScenesLinks', "`"$WildScenesLinks`"") }
    if ($PSBoundParameters.ContainsKey('MaxTries'))  { $a += @('-MaxTries', $MaxTries) }
    if ($PSBoundParameters.ContainsKey('LateTries')) { $a += @('-LateTries', $LateTries) }
    $start = (Get-Date).AddHours($AutoHours)
    $until = (Get-Date).AddDays($AutoDays)
    $action  = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ($a -join ' ') -WorkingDirectory $root
    $trigger = New-ScheduledTaskTrigger -Once -At $start -RepetitionInterval (New-TimeSpan -Hours $AutoHours) -RepetitionDuration (New-TimeSpan -Days $AutoDays)
    $trigger.EndBoundary = $until.ToString('s')
    # 놓친 시각(꺼져 있었음)이면 켜질 때 실행, 절전 중이면 깨워서 실행. 받는 중이면 다음 차례는 건너뛰고, 오래 받아도 끊지 않는다
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -WakeToRun -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -MultipleInstances IgnoreNew -ExecutionTimeLimit ([TimeSpan]::Zero)
    # 로그인한 사용자 권한으로 실행한다(브라우저와 같은 프록시·윈도우 로그인 인증을 쓰려고). 비밀번호를 묻지 않는 대신 로그인돼 있을 때만 실행된다
    $principal = New-ScheduledTaskPrincipal -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogonType Interactive -RunLevel Limited
    try {
        Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Force -ErrorAction Stop | Out-Null
    } catch {
        Write-Bad "작업 스케줄러에 등록하지 못했어요: $($_.Exception.Message)"
        Write-Info '    회사 정책으로 작업 스케줄러가 막혀 있을 수 있어요. 사내 IT에 물어보거나, 하루 뒤에 같은 명령을 직접 실행하세요.'
        exit 1
    }
    Write-Ok "자동 받기를 켰어요. 못 받은 파일을 $($AutoHours)시간마다 다시 받아요($TaskName)"
    Write-Info "    처음 실행: $($start.ToString('MM-dd HH:mm')), 끝나는 날: $($until.ToString('MM-dd'))"
    Write-Info "    받을 데이터셋: $($sets -join ', ')"
    Write-Info '    PC가 켜져 있고 윈도우에 로그인돼 있어야 해요(화면 잠금은 괜찮아요). 꺼져 있었으면 켜질 때 바로 실행해요.'
    Write-Info '    다 받으면 자동 받기가 저절로 꺼져요. 진행 상황은 아래 기록 파일 맨 끝에 쌓여요.'
    Write-Info "    $(Join-Path $Dest 'download.log')"
    Write-Info '    끄려면: powershell -ExecutionPolicy Bypass -File .\user\pc\datasets_download.ps1 -AutoOff'
    exit 0
}
if (-not (Enter-SingleRun $Dest)) {
    if ($FromTask) { exit 0 }   # 자동 받기 차례인데 이미 받고 있으면 조용히 건너뛴다
    Write-Bad "다른 창이나 자동 받기가 이미 데이터셋을 받고 있어요($Dest)"
    Write-Info '    그 실행이 끝난 뒤 다시 실행하세요. 자동 받기가 도는 중인지 보기: Get-ScheduledTask -TaskName ''GPU 데이터셋 자동 받기'' | Select-Object State'
    Write-Info "    진행 상황은 기록 파일 끝에 쌓여요: Get-Content -Tail 30 -Wait $(Join-Path $Dest 'download.log')"
    exit 1
}
Start-Log (Join-Path $Dest 'download.log')
try {   # 끝에서(멈춤·Ctrl+C 포함) 기록을 닫고 잠금을 푼다(Exit-Run)
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

# 조각(.part-aa, -ab …)으로 나뉜 파일: 조각마다 이어받기로 받고 크기를 맞춘 뒤 하나로 합쳐 검사한다. 성공하면 조각은 지운다
function Get-PartName([int]$i) { return [string][char][int](97 + [math]::Floor($i / 26)) + [string][char][int](97 + $i % 26) }   # 0 → aa, 26 → ba
function Get-Parts($url, $file, $count) {
    New-Item -ItemType Directory -Force (Split-Path $file) | Out-Null
    $parts = @(0..($count - 1) | ForEach-Object { "$file.part-$(Get-PartName $_)" })
    if (-not (Test-Path $file)) {
        for ($i = 0; $i -lt $count; $i++) {
            $p = $parts[$i]; $u = "$url.part-$(Get-PartName $i)"
            $remote = Get-RemoteSize $u
            if (-not $remote) { Write-Bad "조각 크기를 알 수 없어요(사이트에 접속되지 않아요): $(Split-Path -Leaf $p)"; return $null }
            if ((Test-Path $p) -and (Get-Item $p).Length -eq $remote) { continue }
            if ((Test-Path $p) -and (Get-Item $p).Length -gt $remote) { Remove-Item -Force $p }
            Write-Info "조각 $($i + 1)/$count 받는 중: $(Split-Path -Leaf $p)"
            if (-not (Get-File $u $p $null $MaxTries) -or (Get-Item $p).Length -ne $remote) {
                Write-Bad "조각을 받지 못했어요: $(Split-Path -Leaf $p). 같은 명령을 다시 실행하면 이어서 받아요"; return $null
            }
        }
        Write-Info "조각 $($count)개를 하나로 합치는 중이에요"
        $out = [IO.File]::Create("$file.join")
        try { foreach ($p in $parts) { $in = [IO.File]::OpenRead($p); try { $in.CopyTo($out) } finally { $in.Close() } } }
        finally { $out.Close() }
        Move-Item -Force "$file.join" $file
    }
    $r = Test-Archive $file
    if ($r -eq 0) { $parts | ForEach-Object { Remove-Item -Force -ErrorAction SilentlyContinue $_ }; return $file }
    Write-Warn '합친 파일이 깨졌어요. 합친 파일은 지우고, 다음 실행 때 조각을 다시 확인해요'
    Remove-Item -Force $file
    return $null
}

function Get-Url($url, $file, $tries = $MaxTries) {
    New-Item -ItemType Directory -Force (Split-Path $file) | Out-Null
    # 사이트에 접속되지 않을 때 브라우저로 받아 넣어 둔 파일이 있으면, 다시 받으려 하기 전에 그 파일부터 검사한다(다 받은 파일이면 그대로 쓴다)
    if ((Test-Path $file) -and -not (Get-RemoteSize $url)) {
        Write-Info '사이트에 접속되지 않아요. 넣어 둔 파일이 다 받아진 것인지 먼저 검사해요'
        if ((Test-Archive $file) -eq 0) { return $file }
        Write-Warn '넣어 둔 파일이 덜 받아졌거나 깨졌어요. 사이트에서 이어서 받아 볼게요'
    }
    # 일반 사이트는 연결 4개로 나눠 받는다(서버가 연결 하나당 속도를 제한하면 몇 배 빨라진다).
    # Box 는 여러 연결을 거절하기 쉬워서 1개. 다른 사이트도 4개로 안 되면 그 파일은 1개로 다시 받는다
    $conn = if ($url -match 'box\.com') { 1 } else { 4 }
    $reset = $false
    $stall = 0
    while ($stall -lt $tries) {
        $remote = Get-RemoteSize $url
        $local  = if (Test-Path $file) { (Get-Item $file).Length } else { 0 }
        if (-not ($remote -and $local -eq $remote -and -not (Test-Path "$file.aria2"))) {
            if ($remote -and $local -gt $remote) { Remove-Item -Force $file }
            if ($local) { Write-Info "이어받기: $(Format-Size $local)부터" }
            $code = Invoke-Aria2 $url $file @(if ($tries -le 1) { '--max-tries=1' }) $conn   # 처음 받을 때는 aria2c 도 다시 해 보지 않는다
            if ($code -eq 99) { return $null }
            if ($code -ne 0 -and -not $reset -and -not ((Get-Size $file) -gt $local) -and (Reset-SmallPart $file)) { $reset = $true; continue }
            if ($code -ne 0 -and $conn -gt 1 -and -not ((Get-Size $file) -gt $local)) {
                Write-Warn "연결 $($conn)개로는 받지 못했어요(aria2c $code). 연결 1개로 다시 받아요"
                $conn = 1
                continue
            }
            if ($code -in 8, 13) {
                Write-Warn '다운로드 사이트가 이어받기를 지원하지 않아서 처음부터 다시 받아요'
                Remove-Item -Force -ErrorAction SilentlyContinue $file, "$file.aria2"
            }
            # 없는 주소(404)·거절(403)·인증 실패(401)는 다시 해도 같다
            if ($code -in 3, 22, 24 -and -not ((Get-Size $file) -gt $local)) {
                $r = Invoke-Http $url -Range '0-0' -Max 2048
                Write-Bad "사이트가 거절했어요(HTTP $($r.Status)): $(Split-Path -Leaf $file). 주소가 바뀌었거나 막혔을 수 있어요"
                Write-Info "    주소: $(($url -split '\?')[0])"
                return $null
            }
            # 사이트에 아예 접속되지 않으면(크기도 모르고 한 바이트도 못 받음) 기다려도 같아서 바로 넘어간다
            if ($code -ne 0 -and -not $remote -and -not ((Get-Size $file) -gt $local)) {
                Write-Bad "사이트에 접속되지 않아요: $(Split-Path -Leaf $file). 네트워크(방화벽·프록시)를 확인하고 다시 실행하세요(받은 데까지는 이어받아요)"
                Write-Info "    주소: $(($url -split '\?')[0])"
                return $null
            }
            if ($code -ne 0) {
                $stall = Step-Retry $stall $local (Get-Size $file) $tries "aria2c $code"
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


# 링크가 401·403 으로 거절될 때 서버가 돌려준 이유를 보여 준다(상태 줄, Server, WWW-Authenticate, 본문 앞부분). 주소의 ? 뒤(서명)는 가린다
function Show-WsDenied($it) {
    $h = @{}; foreach ($x in $it.Headers) { if ($x -match '^([^:]+):\s*(.*)$') { $h[$Matches[1]] = $Matches[2] } }
    $r = Invoke-Http $it.Url -Range '0-1023' -Max 2048 -Headers $h
    Write-Info "    거절된 주소: $(($it.Url -split '\?')[0])?…  (목록에 적힌 요청 머리글(header) $($it.Headers.Count)개를 같이 보냈어요)"
    if (-not $r.Ok) { Write-Info "    응답 없음: $($r.Error)"; return }
    Write-Info "    응답: HTTP $($r.Status)"
    foreach ($k in 'server', 'www-authenticate', 'content-type', 'location') { if ($r.Headers[$k]) { Write-Info "    응답: ${k}: $(($r.Headers[$k] -replace '\?\S*', '?…').Trim())" } }
    if ($r.Body) { $t = (($r.Body -replace '\s+', ' ') -replace '(Signature|Credential|AccessKeyId|Token)[^<]*', '$1…'); Write-Info "    응답 본문: $($t.Substring(0, [math]::Min(400, $t.Length)))" }
}

# 포털 "Get a list of file download links" 의 목록 파일에서 WildScenes2d 아래 파일만 고른다.
# https 로 시작하는 줄이 파일 하나(서명이 붙은 임시 주소), 들여쓴 줄은 aria2 용 옵션이라 건너뛴다
function Get-WsLinks($file) {
    $list = New-Object System.Collections.Generic.List[object]
    $script:WsLinkCount = 0
    $script:WsLinkSample = @()
    $last = $null
    foreach ($l in [IO.File]::ReadAllLines($file)) {
        # 들여쓴 aria2 옵션 줄. header= 는 바로 위 링크에 필요한 머리글(인증 등)이라 aria2c 에도 넘긴다. 나머지(out= 등)는 쓰지 않는다
        if ($l -match '^\s+(\S+?)=(.*)$') {
            if ($last -and $Matches[1] -ieq 'header') { $last.Headers.Add($Matches[2].Trim()) }
            continue
        }
        $last = $null
        # 줄 앞 BOM·공백, "url = " 같은 앞말이 붙어 있어도 주소만 꺼낸다
        $u = [regex]::Match($l, 'https://\S+').Value.Trim('"')
        if (-not $u) { continue }
        $script:WsLinkCount++
        # 경로의 %2F 같은 부호를 먼저 풀어야 폴더 이름이 보인다
        $path = [uri]::UnescapeDataString(($u -split '\?')[0])
        if ($script:WsLinkSample.Count -lt 3) { $script:WsLinkSample += $path }
        $m = [regex]::Match($path, '(?i)/WildScenes_?2d/(.+)$')
        if (-not $m.Success) { continue }
        $last = [pscustomobject]@{ Url = $u; Rel = ($m.Groups[1].Value -replace '/', '\'); Headers = (New-Object System.Collections.Generic.List[string]) }
        $list.Add($last)
    }
    return ,$list
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
$DriveJar = Join-Path ([IO.Path]::GetTempPath()) 'gpu_drive_cookies.txt'   # aria2c 쿠키. 서버에 올리는 datasets 폴더에 섞이지 않게
$script:DriveCookies = New-Object Net.CookieContainer   # .NET 진단 요청의 쿠키

# Google Drive 파일 하나를 앞부분만 받아 보고, 안 되면 왜 안 되는지 가린다.
# 응답 머리글과 본문 앞부분은 datasets\drive_check 에 남긴다(담당자에게 보낼 자료)
function Test-DriveFile($id) {
    $save = Join-Path $Dest 'drive_check'
    New-Item -ItemType Directory -Force $save | Out-Null
    $url = "https://drive.usercontent.google.com/download?id=$id&export=download&confirm=t"
    # 앞 64 KB 만 요청한다(서버가 무시하고 통째로 보내도 64 KB 만 읽는다)
    $r = Invoke-Http $url -Range '0-65535' -Max 65536 -Cookies $script:DriveCookies -TimeoutSec 90
    $http = $r.Status; $final = $r.Url; $ctype = [string]$r.Headers['content-type']; $text = $r.Body
    $bp = Get-BrowserProxy $url
    $html = ($ctype -like 'text/html*') -or $text.TrimStart().StartsWith('<')
    # 웹 페이지가 아니면 본문은 파일 내용(압축 파일 등)이라 글자로 읽을 수 없다. 기록에는 그 사실만 적는다
    $body = if ($html -or -not $text) { $text.Substring(0, [math]::Min(4000, $text.Length)) } else { "(웹 페이지가 아니라 파일 내용이 와서 적지 않았어요. Google Drive가 파일을 정상으로 보내고 있다는 뜻이에요. content-type: $ctype)" }
    # 응답이 없어도 진단 기록은 항상 남긴다(쿠키 머리글은 뺀다)
    $hl = @($r.Headers.Keys | Where-Object { $_ -notmatch 'cookie' } | Sort-Object | ForEach-Object { "${_}: $($r.Headers[$_])" })
    [IO.File]::WriteAllText((Join-Path $save "$id.report.txt"), (@(
        "시각: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')", "주소: $url", "응답: $(if ($r.Ok) { "HTTP $http" } else { "없음($($r.Kind)) $($r.Error)" })", "마지막 주소: $final",
        "HTTPS_PROXY: $env:HTTPS_PROXY", "윈도우 프록시: $(Get-WindowsProxy)", "브라우저가 이 주소에 쓰는 프록시: $bp",
        '', '---- 응답 머리글 ----') + $hl + @('', '---- 본문 앞부분 ----', $body) -join "`r`n"), (New-Object Text.UTF8Encoding $false))
    $server = [string]$r.Headers['server']
    $google = $r.Headers.ContainsKey('x-guploader-uploadid') -or $server -match '(?i)uploadserver|esf|gse|sffe|gws|google'
    $title = if ($text -match '(?is)<title>(.*?)</title>') { ($Matches[1] -replace '\s+', ' ').Trim() } else { '' }
    $kind = 'other'
    if (-not $r.Ok -and $r.Kind -eq 'proxy') { $kind = 'proxy' }
    elseif (-not $r.Ok) { $kind = 'net' }
    elseif ($http -eq 407) { $kind = 'proxy' }
    elseif (($http -eq 200 -or $http -eq 206) -and -not $html) { $kind = 'ok' }
    elseif ($text -match 'Too many users|Quota exceeded|download quota|할당량') { $kind = 'quota' }
    elseif ($final -match 'accounts\.google\.com' -or $text -match 'ServiceLogin|You need access|Request access|액세스 권한') { $kind = 'login' }
    elseif ($text -match 'unusual traffic|automated queries|/sorry/') { $kind = 'bot' }
    elseif ($http -eq 200 -and $text -match 'name="uuid"') { $kind = 'confirm' }
    elseif (-not $google) { $kind = 'proxy' }
    elseif ($http -ge 400) { $kind = 'google' }
    return [pscustomobject]@{ Kind = $kind; Http = $http; Code = $(if ($r.Ok) { 0 } else { 1 }); NetKind = $r.Kind; Err = $r.Error; Server = $server; Title = $title; Saved = $save }
}

function Show-DriveDiag($d, $label) {
    $info = "HTTP $($d.Http)"
    if ($d.Server) { $info += ", Server: $($d.Server)" }
    if ($d.Title)  { $info += ", 페이지 제목: $($d.Title)" }
    switch ($d.Kind) {
        'ok'      { Write-Ok "${label}: 받을 수 있어요" }
        'confirm' { Write-Ok "${label}: 받을 수 있어요(큰 파일 확인 페이지는 스크립트가 넘겨요)" }
        'quota'   { Write-Bad "${label}: Google 다운로드 한도 초과 ($info)"
                    Write-Info '    최근 이 파일을 받은 사람이 많아서 Google이 하루쯤 막았어요. 내일 다시 실행하세요(-Auto 를 붙여 실행해 두면 몇 시간마다 알아서 다시 받아요).'
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
                    $hint = Get-NetHint $d.NetKind
                    if ($hint) { Write-Info "    $hint" } }
        default   { Write-Bad "${label}: 예상하지 못한 응답이에요 ($info)" }
    }
    if ($d.Kind -ne 'ok' -and $d.Kind -ne 'confirm') {
        Write-Info "    진단 기록: $($d.Saved) (파일 ID마다 .report.txt). 해결되지 않으면 이 폴더를 담당자에게 보내 주세요."
        Write-Info '    직접 받아 넣을 폴더와 파일 ID: user\데이터셋_넣기.md 의 "Google Drive 데이터셋 받기"'
    }
}

# Google Drive 파일을 aria2c 로 받는다. 끊기면 이어받고, 큰 파일의 "바이러스 검사 안 함" 확인 페이지도 넘긴다(쿠키는 $DriveJar 에 유지)
function Get-Drive($id, $target, $tries = $MaxTries) {
    $script:DriveFinal = $false   # 한도·권한 없음처럼 다시 해도 같은 이유로 못 받았으면 $true(맨 뒤로 미루지 않는다)
    New-Item -ItemType Directory -Force (Split-Path $target) | Out-Null
    $part = "$target.download"
    $url  = "https://drive.usercontent.google.com/download?id=$id&export=download&confirm=t"
    $reset = $false; $swapped = $false
    $stall = 0
    while ($stall -lt $tries) {
        $local = Get-Size $part
        if ($local) { Write-Info "이어받기: $(Format-Size $local)부터" }
        if (-not (Test-Path $DriveJar)) { [IO.File]::WriteAllText($DriveJar, '') }
        $code = Invoke-Aria2 $url $part @("--load-cookies=$DriveJar", "--save-cookies=$DriveJar"; if ($tries -le 1) { '--max-tries=1' })
        if ($code -eq 99) { return $null }
        if ($code -in 8, 13) { Remove-Item -Force -ErrorAction SilentlyContinue $part, "$part.aria2" }
        if ($code -ne 0 -and -not $reset -and -not ((Get-Size $part) -gt $local) -and (Reset-SmallPart $part)) { $reset = $true; continue }
        if ($code -ne 0 -and $local -ge 1MB -and -not ((Get-Size $part) -gt $local)) {
            # 받다 만 큰 파일을 이어받으려는데 한 바이트도 못 받았으면, 이어받는 위치로 직접 요청해 Drive 가 무엇을 보내는지 본다.
            # Drive 가 파일 대신 웹 페이지(한도 안내, 확인 페이지)를 보내면 aria2c 는 크기가 다르다며
            # "total length mismatch. expected: <페이지 크기>, actual: <받던 파일 크기>"(errorCode=1)로 멈춘다
            $pr = Invoke-Http $url -Range "$local-$($local + 65535)" -Max 65536 -Cookies $script:DriveCookies -TimeoutSec 90
            $pt = [string]$pr.Body
            if ($pr.Ok -and (([string]$pr.Headers['content-type'] -like 'text/html*') -or $pt.TrimStart().StartsWith('<'))) {
                $save = Join-Path (Join-Path $Dest 'drive_check') "$id.resume.html"
                New-Item -ItemType Directory -Force (Split-Path $save) | Out-Null
                [IO.File]::WriteAllText($save, $pt, (New-Object Text.UTF8Encoding $false))
                $title = if ($pt -match '(?is)<title>(.*?)</title>') { ($Matches[1] -replace '\s+', ' ').Trim() } else { '' }
                if ($pt -match 'Too many users|Quota exceeded|download quota|할당량') {
                    Write-Bad "Google Drive 하루 다운로드 한도에 걸렸어요(이어받기 요청에 한도 안내 페이지가 왔어요). 받은 $(Format-Size $local)는 그대로 두고, 한도가 풀리면 이어받아요"
                    $script:DriveFinal = $true
                    return $null
                }
                $inputs = [regex]::Matches($pt, 'name="([^"]+)"\s+value="([^"]*)"')
                if (-not $swapped -and $inputs.Count -and $pt -match 'uuid') {
                    $q = ($inputs | ForEach-Object { "$($_.Groups[1].Value)=$([uri]::EscapeDataString($_.Groups[2].Value))" }) -join '&'
                    $url = "https://drive.usercontent.google.com/download?$q"
                    $swapped = $true
                    Write-Info '이어받기 요청에 큰 파일 확인 페이지가 와서, 확인을 넘긴 주소로 다시 이어받아요'
                    continue
                }
                Write-Bad "Google Drive가 이어받기 요청에 파일 대신 웹 페이지를 보냈어요(HTTP $($pr.Status)$(if ($title) { ", 제목: $title" }))"
                Write-Info "    받은 페이지: $save  (이 파일을 담당자에게 보내 주세요. 받은 $(Format-Size $local)는 그대로 둬요)"
                $script:DriveFinal = $true
                return $null
            }
        }
        if ($code -ne 0 -and -not ((Get-Size $part) -gt $local)) {
            # 한 바이트도 더 못 받고 끝났으면 이유를 확인한다(거절이면 한도·권한 문제인지 진단한다)
            $d = Test-DriveFile $id
            if ($d.Kind -eq 'ok' -or $d.Kind -eq 'confirm') {
                if ($local -and $code -in 3, 22, 24) { Write-Warn 'Google Drive가 이어받기 요청을 거절했어요. 처음부터 다시 받아요'; Remove-Item -Force -ErrorAction SilentlyContinue $part, "$part.aria2" }
            } elseif ($d.Kind -ne 'net') {
                Show-DriveDiag $d $id
                $script:DriveFinal = $true
                return $null
            }
        }
        if ($code -ne 0) {
            $stall = Step-Retry $stall $local (Get-Size $part) $tries "aria2c $code"
            continue
        }
        $ext = Get-ArchiveExt $part
        if ($ext -eq '.html') {
            $html = [IO.File]::ReadAllText($part)
            Remove-Item -Force $part
            if ($html -match 'Quota exceeded|Too many users|할당량') {
                Write-Bad 'Google Drive 하루 다운로드 한도에 걸렸어요. 내일 다시 실행하세요.'
                $script:DriveFinal = $true
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
            $script:DriveFinal = $true
            return $null
        }
        $r = Test-Archive $part
        if ($r -eq 1) {
            Write-Warn '압축 파일이 깨졌어요. 처음부터 다시 받아요'
            Remove-Item -Force $part
            $stall++
            continue
        }
        if ($ext -eq '.bin') {
            # 압축이 아니면 Drive 가 알려 주는 원래 파일 이름(Content-Disposition)의 확장자를 쓴다. 예: .bag, .yaml, .txt
            $hr = Invoke-Http $url -Range '0-0' -Max 0 -Cookies $script:DriveCookies
            if ([string]$hr.Headers['content-disposition'] -match 'filename="?([^";]+)') { $e = [IO.Path]::GetExtension($Matches[1]); if ($e -match '^\.[A-Za-z0-9]{1,6}$') { $ext = $e.ToLower() } }
        }
        $final = "$target$ext"
        Move-Item -Force $part $final
        return $final
    }
    return $null
}

# ORAD-3D: ModelScope 데이터셋 저장소를 modelscope 도구(uv 로 실행)로 통째로 받는다. 끊기면 다시 실행하면 이어서 받는다.
# 다 받으면 파일마다 체크섬을 ORAD-3D.ok 에 적는다(서버가 하나하나 확인한다)
# 윈도우 인증서 저장소를 쓰게 하는 ms_fetch.py 로 부른다(회사 보안 장비 인증서를 쓰는 망에서도 되게)
function Get-ModelScope($id, $dir, $tries = $MaxTries) {
    New-Item -ItemType Directory -Force $dir | Out-Null
    $env:PYTHONIOENCODING = 'utf-8'
    $msf = Join-Path $PSScriptRoot 'ms_fetch.py'
    # modelscope 도구도 안에서 파일마다 다시 시도한다(기본 5번). 처음 받을 때는 그것도 끄고 한 번만 해 본 뒤 바로 미룬다
    $env:MODELSCOPE_DOWNLOAD_MAX_RETRIES = if ($tries -le 1) { '0' } else { '3' }
    $stall = 0
    while ($stall -lt $tries) {
        $before = (Get-ChildItem $dir -Recurse -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
        & $uv run --no-project --python 3.12 --with modelscope --with truststore $msf $id $dir | Out-Host
        if ($LASTEXITCODE -eq 0) { return $true }
        if ($tries -le 1) { Write-Warn "modelscope 가 실패했어요(종료 코드 $LASTEXITCODE)"; return $false }   # 받은 양이 조금 늘었어도(임시 파일 등) 다시 하지 않는다
        $after = (Get-ChildItem $dir -Recurse -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
        $stall = Step-Retry $stall $before $after $tries "modelscope $LASTEXITCODE"
    }
    return $false
}
# 다 받은 ORAD-3D 의 파일마다 체크섬(서버가 하나하나 확인). 받기 도구가 남긴 임시 파일은 뺀다
function Complete-Orad($odir) {
    $ofiles = @(Get-ChildItem $odir -Recurse -File | Where-Object { $_.FullName -notmatch '\\(\._____temp|\.cache)\\' -and $_.Name -notmatch '\.(incomplete|lock)$' })
    Write-Info "ORAD-3D 파일 $($ofiles.Count)개의 체크섬을 계산하는 중이에요(크면 한 시간 안팎)"
    $ol = foreach ($f in $ofiles) { "$((Get-FileHash $f.FullName -Algorithm SHA256).Hash.ToLower())  $($f.FullName.Substring($Dest.Length + 1) -replace '\\', '/')" }
    [IO.File]::WriteAllText("$odir.ok.part", ((@($ol) -join "`n") + "`n"), (New-Object Text.UTF8Encoding $false))
    Move-Item -Force "$odir.ok.part" "$odir.ok"
    Write-Ok 'ORAD-3D 받았어요'; $result['ORAD-3D'] = '받음'
}

# -DriveCheck: 받지 않고 Google Drive 파일마다 진단만 하고 끝낸다
if ($DriveCheck) {
    Write-Host ''
    Write-Host '[Google Drive 진단] 파일마다 앞부분만 받아 봐요(데이터셋은 받지 않아요)' -ForegroundColor Cyan
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
# Cityscapes 에 로그인한다. 성공하면 쿠키를 $script:CsJar 에 두고 $true. 비밀번호는 화면·기록 파일에 남기지 않는다
$script:CsJar = $null
$script:CsWhy = ''
function Connect-Cityscapes {
    $script:CsJar = $null
    $jar = New-Object Net.CookieContainer
    $r = Invoke-Http $CsLogin -Cookies $jar -Max 0
    if (-not $r.Ok) { $script:CsWhy = "사이트에 접속되지 않아요($($r.Error)). $(Get-NetHint $r.Kind)"; return $false }
    $body = "username=$([uri]::EscapeDataString($env:CITYSCAPES_USERNAME))&password=$([uri]::EscapeDataString($env:CITYSCAPES_PASSWORD))&submit=Login"
    $r = Invoke-Http $CsLogin -Cookies $jar -Body $body -NoRedirect -Max 65536
    if (-not $r.Ok) { $script:CsWhy = "로그인 중에 연결이 끊겼어요($($r.Error))"; return $false }
    # 맞으면 302 로 다른 페이지로 보내고, 틀리면 200 으로 로그인 페이지에 "Wrong username or password ..." 를 띄운다
    if ($r.Status -ne 302) {
        $script:CsWhy = if ($r.Body -match 'Wrong username or password') { '아이디나 비밀번호가 틀렸거나, 가입 확인 메일의 링크를 아직 누르지 않았어요' }
                        else { "로그인하지 못했어요(HTTP $($r.Status)). 회사 보안 장비가 막았을 수 있어요" }
        return $false
    }
    $script:CsJar = $jar
    return $true
}

# 로그인한 채로 파일 앞 1바이트를 받아 본다. 결과: Ok(받을 수 있음), Size, FileName, Login(로그인이 풀림), Error
function Test-CsFile($url) {
    $r = Invoke-Http $url -Cookies $script:CsJar -Range '0-0' -Max 0 -NoRedirect
    $o = [pscustomobject]@{ Ok = $false; Size = $null; FileName = ''; Login = $false; Error = '' }
    if (-not $r.Ok) { $o.Error = "사이트에 접속되지 않아요($($r.Error))"; return $o }
    if ($r.Status -in 301, 302, 303) { $o.Login = $true; $o.Error = '로그인이 풀렸어요'; return $o }
    if ($r.Status -ge 400) { $o.Error = "사이트가 거절했어요(HTTP $($r.Status))"; return $o }
    if ($r.Headers['content-disposition'] -match 'filename="?([^";]+)') { $o.FileName = $Matches[1].Trim() }
    if ($r.Headers['content-range'] -match '/(\d+)$') { $o.Size = [int64]$Matches[1] }
    elseif ($r.Headers['content-length'] -match '^\d+$') { $o.Size = [int64]$r.Headers['content-length'] }
    $o.Ok = $true
    return $o
}

# Cityscapes 파일 하나를 받는다(이어받기). 받을 때마다 로그인 쿠키를 aria2c 에 넘긴다. 로그인이 풀리면 다시 로그인한다
function Get-Cityscapes($it, $file, $tries = $MaxTries) {
    New-Item -ItemType Directory -Force (Split-Path $file) | Out-Null
    $conn = 4
    $stall = 0
    while ($stall -lt $tries) {
        if (-not $script:CsJar -and -not (Connect-Cityscapes)) { Write-Bad "Cityscapes 로그인: $script:CsWhy"; return $null }
        $p = Test-CsFile $it.Url
        if ($p.Login) { $script:CsJar = $null; if (-not (Connect-Cityscapes)) { Write-Bad "Cityscapes 로그인: $script:CsWhy"; return $null }; $p = Test-CsFile $it.Url }
        if (-not $p.Ok) {
            # 사이트에 접속되지 않을 때 브라우저로 받아 넣어 둔 파일이 있으면 그 파일을 검사한다
            if ((Test-Path $file) -and -not (Test-Path "$file.aria2") -and (Test-Archive $file) -eq 0) { return $file }
            Write-Bad "$($it.Name): $($p.Error)"
            Write-Info "    주소: $($it.Url)"
            return $null
        }
        if ($p.FileName -and $p.FileName -ne $it.Name) {
            Write-Bad "사이트가 다른 파일을 보내요($($p.FileName)). 다운로드 페이지의 번호(packageID)가 바뀌었을 수 있어요"
            Write-Info "    담당자에게 알려 주세요. 그동안은 브라우저로 $($it.Name) 를 받아 datasets\cityscapes\ 에 넣으면 돼요"
            return $null
        }
        $local = Get-Size $file
        if ($p.Size -and $local -gt $p.Size) { Remove-Item -Force $file; $local = 0 }
        if (-not ($p.Size -and $local -eq $p.Size -and -not (Test-Path "$file.aria2"))) {
            if ($local) { Write-Info "이어받기: $(Format-Size $local)부터" }
            $cookie = $script:CsJar.GetCookieHeader([uri]$it.Url)
            $code = Invoke-Aria2 $it.Url $file @("--header=Cookie: $cookie"; if ($tries -le 1) { '--max-tries=1' }) $conn
            if ($code -eq 99) { return $null }
            if ($code -ne 0 -and $conn -gt 1 -and -not ((Get-Size $file) -gt $local)) {
                Write-Warn "연결 $($conn)개로는 받지 못했어요(aria2c $code). 연결 1개로 다시 받아요"
                $conn = 1
                continue
            }
            if ($code -in 8, 13) {
                Write-Warn '다운로드 사이트가 이어받기를 지원하지 않아서 처음부터 다시 받아요'
                Remove-Item -Force -ErrorAction SilentlyContinue $file, "$file.aria2"
            }
            if ($code -ne 0) {
                $script:CsJar = $null   # 받는 사이 로그인이 풀렸을 수 있어 다음에는 다시 로그인한다
                $stall = Step-Retry $stall $local (Get-Size $file) $tries "aria2c $code"
                continue
            }
        }
        $r = Test-Archive $file
        if ($r -eq 0) { return $file }
        Remove-Item -Force $file
        if ($r -eq 2) {
            Write-Bad "zip 파일 대신 다른 것이 왔어요($(Split-Path -Leaf $file)). 로그인 페이지나 회사 보안 장비의 차단 페이지일 수 있어요"
            return $null
        }
        Write-Warn '압축 파일이 깨졌어요. 처음부터 다시 받아요'
        $stall++
    }
    return $null
}

# ------------------------------------------------------------------ 1. 점검
Write-Step 1 $T '점검'
$uv = Find-Exe 'uv' $root
if ($uv) { Write-Ok "uv : $uv" } else { Write-Bad 'uv가 없어요' }
if (Get-Command 'tar.exe' -ErrorAction SilentlyContinue) { Write-Ok 'tar.exe' } else { Write-Bad '없는 프로그램: tar.exe (윈도우 10 1803 이후에는 기본으로 들어 있어요)' }
Test-Aria2 | Out-Null
if ($oldWs.Count) { Write-Warn ".env 의 $($oldWs -join ', ') 는 더 쓰지 않아요(WildScenes 는 링크 목록으로만 받아요). 키가 남지 않게 .env 에서 그 줄들을 지워 주세요" }
if (-not (Test-Path $check)) { Write-Bad '없는 파일: user\pc\check_archive.py (git pull로 저장소를 최신으로 받으세요)' }
if (-not (Test-Path (Join-Path $root 'user\server\datasets_unpack.sh'))) { Write-Bad '없는 파일: user\server\datasets_unpack.sh (git pull로 저장소를 최신으로 받으세요)' }
if ($script:Fails) {
    Stop-Run '필요한 프로그램이나 파일이 없어요' ("위 [문제] 줄을 보세요. uv는 설치한 뒤 PowerShell 창을 새로 여세요(또는 uv.exe를 $root 폴더에 넣기). " +
        '저장소 파일은 git pull로 받으세요.')
}

$sites = [ordered]@{ 'PyPI (검사 도구)' = 'https://pypi.org/simple/pip/' }
if ($Items | Where-Object { $_.Set -like 'goose*' }) { $sites['goose-dataset.de'] = 'https://goose-dataset.de/' }
if ($Items | Where-Object { $_.Set -eq 'RUGD' })     { $sites['rugd.vision'] = 'http://rugd.vision/' }
foreach ($k in $sites.Keys) { Test-Site $k $sites[$k] | Out-Null }
if ($script:Fails) {
    Stop-Run '접속되지 않는 사이트가 있어요' ('위 [문제] 줄 아래의 오류와 설명을 보세요. 브라우저에서는 열린다면 ' +
        '사내 IT에 프록시 주소를 물어 .env 에 HTTPS_PROXY=http://프록시주소:포트 를 적고 다시 실행하세요. ' +
        '한 사이트만 막혔다면 -Only로 나머지만 먼저 받으세요(예: -Only goose,gooseEx).')
}

# Google Drive 에 접속되는지 미리 본다(실패해도 멈추지 않는다)
$driveOk = $false
if ($DriveItems.Count) {
    $d1 = Invoke-Probe 'https://drive.google.com/'
    if ($d1.Code -ne 0) {
        Write-Warn "Google Drive 접속 안 됨($($d1.Msg)). RELLIS-3D, TAS500, GO는 건너뛰고 나머지를 받아요. 접속되면 같은 명령을 다시 실행하세요."
    } else {
        # 첫 페이지만 열리고 파일 받기는 막힌 망이 있어, 실제 파일 하나를 앞부분만 받아 본다.
        # 큰 파일(rellis_2d images 등)로 시험하면 그 파일의 Google 하루 받기 한도를 매번 조금씩 쓰게 되어 작은 파일로 본다
        $probe = @($DriveItems | Where-Object { $_.GB -le 1 } | Select-Object -Last 1) + @($DriveItems[0]) | Select-Object -First 1
        $d = Test-DriveFile $probe.Id
        $driveOk = $d.Kind -ne 'proxy' -and $d.Kind -ne 'net'
        if ($d.Kind -eq 'ok' -or $d.Kind -eq 'confirm') {
            Write-Ok 'Google Drive 파일을 받을 수 있어요. RELLIS-3D, TAS500, GO도 받아요'
        } else {
            Show-DriveDiag $d "Google Drive 시험 파일($($probe.Set)/$($probe.Name))"
            if ($driveOk) { Write-Warn 'Google에는 접속되니 파일마다 받아 볼게요.' }
            else { Write-Warn 'RELLIS-3D, TAS500, GO는 건너뛰고 나머지를 받아요. 파일마다 자세히 보려면 -DriveCheck를 붙여 실행하세요.' }
        }
    }
}

Write-Info '검사용 Python을 준비하는 중이에요(처음 한 번만)'
& $uv python install 3.12 | Out-Host
if ($LASTEXITCODE -ne 0) { Stop-Run 'uv가 Python 3.12를 받지 못했어요' '인터넷(github.com) 접속을 확인하고 다시 실행하세요.' }
Write-Ok 'Python 3.12를 준비했어요'

# Cityscapes 계정. 없으면 묻고(자동 받기는 묻지 않음), 로그인해 본다. 안 되면 Cityscapes 만 건너뛴다
$doCs = $false
$script:CsSkip = ''
$csLeft = @($CsItems | Where-Object { -not (Test-Path "$(Join-Path (Join-Path $Dest $_.Set) $_.Name).ok") })
if ($csLeft.Count) {
    if (-not ($env:CITYSCAPES_USERNAME -and $env:CITYSCAPES_PASSWORD) -and -not $FromTask) {
        Write-Host ''
        Write-Host '  Cityscapes 는 회원 계정으로 로그인해야 받을 수 있어요(가입: https://www.cityscapes-dataset.com/register/)' -ForegroundColor Cyan
        Write-Host '  비워 두고 Enter를 누르면 Cityscapes 는 건너뛰어요. 비밀번호는 화면과 기록 파일에 남지 않아요.'
        Write-Host '  (.env 의 CITYSCAPES_USERNAME, CITYSCAPES_PASSWORD 에 적어 두면 다음부터는 묻지 않아요)'
        if (-not $env:CITYSCAPES_USERNAME) { $u = Read-Host '  Cityscapes 아이디(또는 이메일)'; if ($u.Trim()) { $env:CITYSCAPES_USERNAME = $u.Trim() } }
        if ($env:CITYSCAPES_USERNAME -and -not $env:CITYSCAPES_PASSWORD) {
            $s = Read-Host '  Cityscapes 비밀번호' -AsSecureString
            $b = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($s)
            try { $pw = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($b) } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b) }
            if ($pw) { $env:CITYSCAPES_PASSWORD = $pw }
            $pw = $null
        }
    }
    if (-not ($env:CITYSCAPES_USERNAME -and $env:CITYSCAPES_PASSWORD)) {
        $script:CsSkip = '계정 없음. .env 의 CITYSCAPES_USERNAME·CITYSCAPES_PASSWORD 에 적거나 실행 중에 입력'
        Write-Warn 'Cityscapes 계정이 없어서 Cityscapes 는 건너뛰어요'
    } elseif (Connect-Cityscapes) {
        Write-Ok 'Cityscapes 에 로그인했어요'
        $doCs = $true
    } else {
        $script:CsSkip = "로그인 실패: $script:CsWhy"
        Write-Bad "Cityscapes 로그인: $script:CsWhy"
        Write-Warn 'Cityscapes 는 건너뛰고 나머지를 받아요. 고친 뒤 같은 명령을 다시 실행하세요'
    }
}

# WildScenes 준비. 안 되면 스크립트를 멈추지 않고 WildScenes 만 건너뛰고 나머지를 받는다(do … while 안의 break 로 빠져나온다)
$script:WsSkip = ''
function Skip-Wild($what, $fix) {
    Write-Bad "WildScenes: $what"
    Write-Info "    할 일: $fix"
    Write-Warn 'WildScenes 는 건너뛰고 나머지 데이터셋을 받아요. 고친 뒤 같은 명령을 다시 실행하면 WildScenes 만 받아요'
    $script:doWild = $false
    $script:WsSkip = $what
}
do {
if ($doWild -and $WildScenesLinks -and -not (Test-Path (Join-Path $Dest 'wildscenes.ok'))) {
    if (-not (Test-Path $WildScenesLinks)) { Skip-Wild "링크 목록 파일을 찾지 못했어요: $WildScenesLinks" '-WildScenesLinks 뒤(또는 .env 의 WILDSCENES_LINKS)에 포털에서 받은 .txt 파일의 전체 경로를 적어 다시 실행하세요.'; break }
    $script:WsLinks = Get-WsLinks $WildScenesLinks
    if (-not $script:WsLinks.Count) {
        Write-Info "    목록 파일의 주소 줄: $($script:WsLinkCount)개"
        $script:WsLinkSample | ForEach-Object { Write-Info "    예: $_" }
        Skip-Wild '링크 목록에 WildScenes2d 파일이 없어요' "포털($WsPortal)의 Download → Get a list of file download links 에서 받은 .txt 파일인지 확인하세요."; break
    }
    Write-Ok "WildScenes 링크 목록: 2D 파일 $($script:WsLinks.Count)개"
    $f0 = $script:Fails   # 앞의 Google Drive 진단 실패는 세지 않는다(CSIRO 접속만 본다)
    Test-Site 'CSIRO S3 저장소' "https://$(([uri]$script:WsLinks[0].Url).Host)/" | Out-Null
    if ($script:Fails -gt $f0) { Skip-Wild 'CSIRO S3 저장소에 접속되지 않아요' '위 [문제] 줄 아래 설명을 보세요. 브라우저에서는 열린다면 아래 기록 파일을 담당자에게 보내 주세요.'; break }
}
} while ($false)

$needGB = (@($Items) + @($LateItems) | Where-Object { -not (Test-Path "$(Join-Path (Join-Path $Dest $_.Set) $_.Name).ok") } |
    ForEach-Object { $_.GB } | Measure-Object -Sum).Sum
if (-not $needGB) { $needGB = 0 }
if ($driveOk) {
    $needGB += ($DriveItems | Where-Object { -not (Get-DoneDrive (Join-Path (Join-Path $Dest $_.Set) $_.Name)) } |
        ForEach-Object { $_.GB } | Measure-Object -Sum).Sum
}
if ($doWild -and -not (Test-Path (Join-Path $Dest 'wildscenes.ok'))) { $needGB += 47 }
if ($doOrad -and -not (Test-Path (Join-Path $Dest 'ORAD-3D.ok'))) { $needGB += 350 }
if ($doCs) { $needGB += ($csLeft | ForEach-Object { $_.GB } | Measure-Object -Sum).Sum }
$free = Get-FreeGB $Dest
if ($free -lt $needGB + 5) {
    Stop-Run "남은 공간이 $free GB예요(앞으로 약 $needGB GB가 필요해요)" '공간을 비우거나, -Dest E:\datasets 처럼 넉넉한 드라이브로 받는 곳을 바꾸거나, -Only로 나눠 받으세요.'
}
Write-Ok "남은 공간 $free GB, 앞으로 받을 양 약 $needGB GB"

# ------------------------------------------------------------------ 2. 받기
Write-Step 2 $T '받기 (끊기면 이어받아요)'
$result = [ordered]@{}
# 한 번 못 받은 파일은 그 자리에서 오래 붙잡지 않고 맨 뒤로 미룬다(한 번만). 다른 것을 다 받은 뒤 $MaxTries 번까지 다시 해 본다.
# 처음에는 진전 없이 끊기면 다시 해 보지 않고 바로 미룬다. 받는 중(받은 양이 느는 동안)에는 끊겨도 계속 이어받는 것은 같다
$FirstTries = 1
$Deferred = New-Object System.Collections.ArrayList
function Defer-Item($it, $label, $kind) {
    Write-Warn "$label 맨 뒤로 미뤄요. 다른 것을 다 받은 뒤 한 번 더 받아 봐요"
    [void]$Deferred.Add(@{ It = $it; Label = $label; Kind = $kind })
    $result[$label] = '미룸'
}
# 직접 링크 목록을 차례로 받는다. $tag 는 화면의 번호 앞에 붙는 글자. -Defer 면 못 받은 것을 맨 뒤로 미룬다
function Get-Items($list, $tag, $tries = $MaxTries, [switch]$Defer) {
    $n = 0
    foreach ($it in $list) {
        $n++
        $target = Join-Path (Join-Path $Dest $it.Set) $it.Name
        $label  = "$($it.Set)/$($it.Name)"
        if (Test-Path "$target.ok") { Write-Host "  ($tag$n/$($list.Count)) ${label}: 이미 받았어요"; $result[$label] = '받음'; continue }
        Write-Host ''
        Write-Host "  ($tag$n/$($list.Count)) $label 받는 중 (약 $($it.GB) GB)" -ForegroundColor Cyan
        $f = if ($it.Parts) { Get-Parts $it.Url $target $it.Parts } else { Get-Url $it.Url $target $tries }
        if ($f) { Set-Done "$target.ok" $f; Write-Ok "$label 받았어요"; $result[$label] = '받음' }
        elseif ($Defer) { Defer-Item $it $label 'url' }
        else    { Write-Bad "$label 받지 못했어요"; $result[$label] = '실패' }
    }
}
Get-Items $Items '' $FirstTries -Defer

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
            # 링크 목록: aria2c 로 받는다. 끝난 파일은 목록에 적어 다시 실행하면 건너뛴다
            $links = $script:WsLinks
            $doneFile = "$wdir.links_done.txt"
            $doneSet = New-Object 'System.Collections.Generic.HashSet[string]'
            if (Test-Path $doneFile) { foreach ($x in [IO.File]::ReadAllLines($doneFile)) { [void]$doneSet.Add($x) } }
            $utf8 = New-Object Text.UTF8Encoding $false
            $expired = $false
            # 목록이 aria2 형식이고, 동시에 여러 파일을 받아 빠르다
            $aria = Get-Aria2
            if ($aria) { Write-Ok "aria2c 로 받아요(파일 16개씩 동시에)" }
            $ain = "$wdir.aria2_input.txt"; $asess = "$wdir.aria2_session.txt"; $alog = "$wdir.aria2.log"
            while ($aria -and $stall -lt $MaxTries) {
                $todo = @($links | Where-Object { -not $doneSet.Contains($_.Rel) })
                if (-not $todo.Count) { $done = $true; break }
                $before = $doneSet.Count
                Write-Info "남은 파일 $($todo.Count)개 / 전체 $($links.Count)개"
                # 이번에 받을 것만 aria2 입력 파일로(주소 줄 + 들여쓴 옵션 줄). 저장 위치는 wildscenes 아래 상대 경로
                $sb = New-Object Text.StringBuilder
                foreach ($it in $todo) {
                    [void]$sb.Append("$($it.Url)`n  out=$($it.Rel -replace '\\', '/')`n")
                    foreach ($h in $it.Headers) { [void]$sb.Append("  header=$h`n") }
                }
                [IO.File]::WriteAllText($ain, $sb.ToString(), (New-Object Text.UTF8Encoding $false))
                Remove-Item -Force -ErrorAction SilentlyContinue $asess, $alog
                New-Item -ItemType Directory -Force $wdir | Out-Null
                $px = @(Get-Aria2Proxy $todo[0].Url)
                # -c 이어받기, --save-session: 끝나지 않았거나 실패한 것만 적어 둔다(거기 없는 것 = 다 받은 것)
                & $aria -i $ain -d $wdir -c -j 16 -x 1 --auto-file-renaming=false --file-allocation=none `
                    --max-tries=2 --retry-wait=10 --connect-timeout=30 --timeout=120 `
                    --summary-interval=60 --console-log-level=warn --download-result=hide `
                    --save-session=$asess --log=$alog --log-level=notice @px
                $acode = $LASTEXITCODE
                $left = New-Object 'System.Collections.Generic.HashSet[string]'
                if (Test-Path $asess) { foreach ($x in [IO.File]::ReadAllLines($asess)) { if ($x -match '^\s+out=(.+)$') { [void]$left.Add(($Matches[1].Trim() -replace '/', '\')) } } }
                foreach ($it in $todo) {
                    $f = Join-Path $wdir $it.Rel
                    if (-not $left.Contains($it.Rel) -and (Test-Path $f) -and -not (Test-Path "$f.aria2")) {
                        [void]$doneSet.Add($it.Rel); [IO.File]::AppendAllText($doneFile, "$($it.Rel)`n", $utf8)
                    }
                }
                Write-Info "aria2c 가 끝났어요(종료 코드 $acode). 이번에 $($doneSet.Count - $before)개를 받았고, 남은 것은 $($links.Count - $doneSet.Count)개예요"
                if ($doneSet.Count -eq $links.Count) { $done = $true; break }
                # 하나도 못 받았고 401·403(만료·거절)이면 다시 해도 소용없다
                $alines = if (Test-Path $alog) { @([IO.File]::ReadAllLines($alog)) } else { @() }
                $denied = @($alines | Where-Object { $_ -match 'status=40[13]|Authorization failed' })
                if ($doneSet.Count -eq $before -and $denied.Count) { $expired = $true; Write-Info "    $(($denied[0] -replace '\?\S*', '?…').Trim())"; break }
                $errs = @($alines | Where-Object { $_ -match '(?i)\b(ERROR|exception)\b' } | Select-Object -First 3)
                $errs | ForEach-Object { Write-Warn "aria2c: $(($_ -replace '\?\S*', '?…').Trim())" }
                if ($doneSet.Count -gt $before) { $stall = 0; Start-Sleep 10 }
                else { $stall = Step-Retry $stall 0 0 $MaxTries 'WildScenes(aria2c)' }
            }
            if ($aria -and $expired) {
                Write-Bad 'WildScenes 링크가 만료됐거나 거절됐어요(401·403)'
                Write-Info "    포털($WsPortal)에서 링크 목록을 새로 받아 같은 명령을 다시 실행하세요. 받은 파일은 건너뛰어요."
                Write-Info "    aria2c 기록: $alog"
                if ($todo.Count) { Show-WsDenied $todo[0] }
            }
            if (-not $aria) { Write-Bad 'aria2c 가 없어서 WildScenes 를 받지 못했어요(위 aria2c 준비 [문제] 를 보세요)' }
        }
        if ($done) {
            $m = Get-ChildItem $wdir -Recurse -File | Measure-Object -Property Length -Sum
            [IO.File]::WriteAllText("$wdir.ok", "files=$($m.Count) bytes=$($m.Sum)`n", (New-Object Text.UTF8Encoding $false))
            Remove-Item -Force -ErrorAction SilentlyContinue "$wdir.sha256"   # 3단계에서 새로 만든다
            Write-Ok "wildscenes를 받았어요(파일 $($m.Count)개)"; $result['wildscenes'] = '받음'
        } else { $result['wildscenes'] = '실패' }
    }
} elseif ($script:WsSkip) {
    $result['wildscenes'] = "건너뜀($script:WsSkip. 고친 뒤 다시 실행)"
} elseif (Want 'wildscenes') {
    $result['wildscenes'] = '건너뜀(받으려면 포털의 링크 목록 파일 경로를 .env 의 WILDSCENES_LINKS 에 적거나 -WildScenesLinks 를 붙여 실행)'
}

# Cityscapes (로그인해서 받기)
$n = 0
foreach ($it in $CsItems) {
    $n++
    $target = Join-Path (Join-Path $Dest $it.Set) $it.Name
    $label  = "$($it.Set)/$($it.Name)"
    if (Test-Path "$target.ok") { Write-Host "  (Cityscapes $n/$($CsItems.Count)) ${label}: 이미 받았어요"; $result[$label] = '받음'; continue }
    if (-not $doCs) { $result[$label] = "건너뜀($script:CsSkip)"; continue }
    Write-Host ''
    Write-Host "  (Cityscapes $n/$($CsItems.Count)) $label 받는 중 (약 $($it.GB) GB)" -ForegroundColor Cyan
    $f = Get-Cityscapes $it $target $FirstTries
    if ($f) { Set-Done "$target.ok" $f; Write-Ok "$label 받았어요"; $result[$label] = '받음' }
    else    { Defer-Item $it $label 'cs' }
}

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
    $f = Get-Drive $it.Id $target $FirstTries
    if ($f) { Set-Done "$f.ok" $f; Write-Ok "$label 받았어요"; $result[$label] = '받음' }
    elseif ($script:DriveFinal) { Write-Bad "$label 받지 못했어요"; $result[$label] = '실패' }   # 한도·권한 문제는 같은 날 다시 해도 같다
    else    { Defer-Item $it $label 'drive' }
}

# ORAD-3D (ModelScope)
$oradLater = $false
if ($doOrad) {
    $odir = Join-Path $Dest 'ORAD-3D'
    if (Test-Path "$odir.ok") {
        Write-Host '  ORAD-3D: 이미 받았어요'; $result['ORAD-3D'] = '받음'
    } else {
        Write-Host ''
        Write-Host "  ORAD-3D 받는 중 (약 350 GB, ModelScope $ModelScopeId)" -ForegroundColor Cyan
        if (Get-ModelScope $ModelScopeId $odir $FirstTries) { Complete-Orad $odir }
        else {   # 처음 실패는 다시 해 보지 않고 맨 뒤로 미룬다(다른 데이터셋처럼 한 번만)
            Write-Warn 'ORAD-3D 맨 뒤로 미뤄요. 다른 것을 다 받은 뒤 한 번 더 받아 봐요'
            $oradLater = $true; $result['ORAD-3D'] = '미룸'
        }
    }
}

# 미룬 ORAD-3D 를 한 번 더(이번에는 $MaxTries 번까지)
if ($oradLater) {
    Write-Host ''
    Write-Host "  (미룸) ORAD-3D 다시 받는 중 (ModelScope $ModelScopeId)" -ForegroundColor Cyan
    if (Get-ModelScope $ModelScopeId $odir $MaxTries) { Complete-Orad $odir }
    else {
        Write-Bad 'ORAD-3D 받지 못했어요. 위 modelscope 오류를 보세요. 같은 명령을 다시 실행하면 받은 데까지 이어서 받아요(admin/6_문제_해결.md 에서 "ORAD-3D 받지 못했어요" 줄)'
        $result['ORAD-3D'] = '실패'
    }
}

# 미룬 것을 한 번 더(이번에는 $MaxTries 번까지). 또 못 받으면 실패로 남기고, 다음 실행(자동 받기 포함) 때 이어받는다
if ($Deferred.Count) {
    Write-Host ''
    Write-Host "  미룬 $($Deferred.Count)개를 다시 받아요" -ForegroundColor Cyan
    $n = 0
    foreach ($d in $Deferred) {
        $n++; $it = $d.It; $label = $d.Label
        $target = Join-Path (Join-Path $Dest $it.Set) $it.Name
        Write-Host ''
        Write-Host "  (미룸 $n/$($Deferred.Count)) $label 다시 받는 중 (약 $($it.GB) GB)" -ForegroundColor Cyan
        if ($d.Kind -eq 'drive') {
            $f = Get-Drive $it.Id $target $MaxTries
            if ($f) { Set-Done "$f.ok" $f }
        } elseif ($d.Kind -eq 'cs') {
            $f = Get-Cityscapes $it $target $MaxTries
            if ($f) { Set-Done "$target.ok" $f }
        } else {
            $f = if ($it.Parts) { Get-Parts $it.Url $target $it.Parts } else { Get-Url $it.Url $target $MaxTries }
            if ($f) { Set-Done "$target.ok" $f }
        }
        if ($f) { Write-Ok "$label 받았어요"; $result[$label] = '받음' }
        else    { Write-Bad "$label 받지 못했어요"; $result[$label] = '실패' }
    }
}

# 사내망에서 막히는 사이트(YCOR 의 Box, CaSSeD 의 CAVS)는 다른 것을 다 받은 뒤 맨 끝에. 진전 없이 $LateTries 번 끊기면 넘어간다
Get-Items $LateItems '나중 ' $LateTries

# 브라우저로 받아 직접 넣어 둔 압축 파일도 검사한다(스크립트가 받은 파일은 이미 .ok 가 있다)
foreach ($set in $Manual) {
    $dir = Join-Path $Dest $set
    if (-not (Test-Path $dir)) { continue }
    $arcs = @(Get-ChildItem $dir -File | Where-Object { $_.Name -match '\.(zip|tar|tgz|tar\.gz|7z)$' -and -not (Test-Path "$($_.FullName).ok") -and -not (Test-Path "$($_.FullName).aria2") })   # .aria2 가 있으면 받는 중
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
$sh = [IO.File]::ReadAllText((Join-Path $root 'user\server\datasets_unpack.sh')) -replace "`r", ''
[IO.File]::WriteAllText((Join-Path $Dest 'datasets_unpack.sh'), $sh, (New-Object Text.UTF8Encoding $false))
Write-Ok "파일 $($lines.Count)개를 체크섬 목록에 적고 datasets_unpack.sh를 넣었어요"

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
if ((Split-Path -Leaf $Dest) -ne 'datasets') { Write-Host '   폴더 이름이 datasets 가 아니면, 올리기 전에 datasets 로 바꾸세요(서버에서 실행할 명령이 이 이름으로 돼 있어요).' -ForegroundColor Yellow }
Write-Host ''
Show-NotNeeded $Dest (Join-Path $Dest 'MANIFEST.sha256') @('wildscenes/')
Write-Host ''
Write-Host ' 1) 공용 계정의 FileZilla로 NAS 의 /data/autonomy_sw/inbox 에 datasets 폴더째 올리세요. 몇 개씩 나눠 올려도 돼요.' -ForegroundColor Green
Write-Host ' 2) 공용 계정으로 서버에 접속해(PuTTY) 실행하세요. 두 서버 중 한 곳에서 한 번만 하면 돼요(NAS에 들어가서 다른 서버에서도 보여요).' -ForegroundColor Green
Write-Host '   bash /data/autonomy_sw/inbox/datasets/datasets_unpack.sh'
Write-Host ' 자세한 순서: user\데이터셋_넣기.md'
Write-Host '##############################################################'
# 작업 스케줄러가 실행한 것이면: 못 받은 것(한도·끊김으로 실패, Drive 접속 안 됨)이 없을 때 자동 받기를 끈다
if ($FromTask) {
    $left = @($result.Keys | Where-Object { $result[$_] -eq '실패' -or $result[$_] -like '건너뜀(Drive*' })
    Write-Host ''
    if (-not $left.Count) {
        if (Remove-AutoTask) { Write-Ok '다 받아서 자동 받기를 껐어요' }
    } else {
        Write-Host " 아직 못 받은 파일이 $($left.Count)개 있어요. $($AutoHours)시간쯤 뒤에 알아서 다시 받아요." -ForegroundColor Yellow
    }
}
Remove-Item Env:CITYSCAPES_PASSWORD -ErrorAction SilentlyContinue
Stop-Transcript | Out-Null
if ($failed.Count) { exit 1 }
} finally { Exit-Run }
