<#
[접근 PC] 받기·묶기를 한 번에 한다. 무엇을 할지와 토큰·프록시 같은 설정은 저장소 맨 위의 .env 에 적는다(예시: .env.example).
하나가 멈춰도 나머지는 이어서 하고, 끝에 결과를 한눈에 보여 준다. 끝난 것은 건너뛰므로 몇 번이고 다시 실행해도 된다.
서버에 올리기·설치는 하지 않는다. 각 작업이 끝날 때 보여 주는 안내(지문 포함)를 따라 한다.

  powershell -ExecutionPolicy Bypass -File .\pc\run_all.ps1                     # .env 의 GPU_RUN(없으면 네 가지 모두)
  powershell -ExecutionPolicy Bypass -File .\pc\run_all.ps1 -Run models,datasets   # 이번에만 고른 것
#>
param(
    [string[]]$Run = @()   # setup, docker, datasets, models 중에서(쉼표로 여러 개)
)
$here = $PSScriptRoot
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $here 'gpu_common.ps1')

$Jobs = [ordered]@{
    setup    = @{ File = 'setup_pack.ps1';        Title = '서버 설치 스크립트 묶음(setup\gpu-setup.tar)' }
    docker   = @{ File = 'docker_pack.ps1';       Title = 'rootless Docker 묶음(pack_docker\gpu-docker.tar)' }
    datasets = @{ File = 'datasets_download.ps1'; Title = '데이터셋(datasets\)' }
    models   = @{ File = 'models_download.ps1';   Title = '사전학습 모델(models\)' }
}
if (-not $Run.Count -and $env:GPU_RUN) { $Run = @($env:GPU_RUN) }
$Run = @($Run | ForEach-Object { $_ -split '[,\s]+' } | Where-Object { $_ } | ForEach-Object { $_.ToLower() } | Select-Object -Unique)
if (-not $Run.Count) { $Run = @($Jobs.Keys) }
$unknown = @($Run | Where-Object { -not $Jobs.Contains($_) })
if ($unknown.Count) {
    Write-Host "  [문제] 모르는 작업이에요: $($unknown -join ', '). 쓸 수 있는 것: $(@($Jobs.Keys) -join ', ')" -ForegroundColor Red
    Write-Host '  .env 의 GPU_RUN 이나 -Run 뒤의 이름을 고쳐 다시 실행하세요.'
    exit 1
}

Write-Host "[접근 PC] 한 번에 받기  ($(Get-Date -Format 'yyyy-MM-dd HH:mm')): $($Run -join ' → ')"
if (-not (Test-Path (Join-Path $root '.env'))) {
    Write-Warn '.env 가 없어서 토큰 같은 값은 실행 중에 물어봐요. 미리 적어 두려면: copy .env.example .env 한 뒤 notepad .env'
}
Stop-Sleep
$ps = (Get-Process -Id $PID).Path   # 지금 쓰는 PowerShell 로 각 작업을 따로 실행한다(멈춤이 다음 작업을 막지 않게)
$result = [ordered]@{}
$i = 0
foreach ($k in $Run) {
    $i++
    Write-Host ''
    Write-Host "######## [$i/$($Run.Count)] $($Jobs[$k].Title) ########" -ForegroundColor Magenta
    & $ps -NoProfile -ExecutionPolicy Bypass -File (Join-Path $here $Jobs[$k].File)
    $result[$k] = $LASTEXITCODE
}
Allow-Sleep

Write-Host ''
Write-Host '######## 한 번에 받기 결과 ########' -ForegroundColor Cyan
foreach ($k in $result.Keys) {
    if ($result[$k] -eq 0) { Write-Ok $Jobs[$k].Title }
    else { Write-Bad "$($Jobs[$k].Title): 끝까지 못 했어요. 위의 그 작업 화면에서 '멈춤' 상자나 [문제] 줄을 보세요" }
}
Write-Host ''
if ($script:Fails) {
    Write-Host ' 할 일을 한 뒤 같은 명령을 다시 실행하세요. 끝난 것은 건너뛰어요. 그 작업만 하려면 -Run 뒤에 이름을 적어요.' -ForegroundColor Yellow
} else {
    Write-Host ' 모두 끝났어요. 올리기·설치는 각 작업 끝의 안내를 따르세요(docs\1_처음_설치.md 의 "전체 흐름").' -ForegroundColor Green
}
Write-Host " 지문(sha256)은 $(Join-Path $root '지문_기록.txt') 에도 모아 뒀어요."
exit [int]($script:Fails -gt 0)
