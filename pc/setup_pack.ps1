<#
[접근 PC] GPU 서버 설치 스크립트 묶음(setup\gpu-setup.tar)을 만든다.
들어가는 것: 준비(prepare.sh), 권한·규칙 설정(admin_setup.sh), 점검 스크립트(check.sh), 도우미(bin/gpu, bin/docker, bin/nvidia-smi).
서버 화면에서 쓰는 프로그램(tmux, nvtop 등)은 pkgs_pack.ps1 묶음으로 설치하고(docs/1_처음_설치.md 의 2단계), 학습 도구는 도커 이미지에 넣는다.

  powershell -ExecutionPolicy Bypass -File .\pc\setup_pack.ps1
#>
$here = $PSScriptRoot
$root = Split-Path $PSScriptRoot -Parent   # 저장소 맨 위(D:\gpu). 결과 폴더는 여기
. (Join-Path $here 'gpu_common.ps1')
$out = Join-Path $root 'setup'
$T = 2
New-Item -ItemType Directory -Force $out | Out-Null
Start-Log (Join-Path $out 'build.log')
Write-Host "[접근 PC] 서버 설치 스크립트 묶기  ($(Get-Date -Format 'yyyy-MM-dd HH:mm'))"

# ------------------------------------------------------------------ 1. 점검
Write-Step 1 $T '점검'
if (Get-Command 'tar.exe' -ErrorAction SilentlyContinue) { Write-Ok 'tar.exe' }
else { Stop-Run '없는 프로그램: tar.exe' '윈도우 10 1803 이후에는 기본으로 들어 있어요. 윈도우를 업데이트하세요.' }
$scripts = @('prepare.sh', 'admin_setup.sh', 'check.sh', 'bin/gpu', 'bin/docker', 'bin/nvidia-smi')
foreach ($f in $scripts) {
    if (-not (Test-Path (Join-Path $root ('server\' + ($f -replace '/', '\'))))) { Stop-Run "없는 파일: server\$f" 'git pull로 저장소를 최신으로 받으세요.' }
}
Write-Ok "서버 스크립트 $($scripts.Count)개가 있어요"

# ------------------------------------------------------------------ 2. 묶기 + 검사
Write-Step 2 $T '묶기와 검사'
$work = Join-Path $out 'files'
Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $work
New-Item -ItemType Directory -Force (Join-Path $work 'bin') | Out-Null
foreach ($f in $scripts) {
    # 줄 끝을 LF 로 써야 서버(리눅스)에서 문제가 없다
    $sh = [IO.File]::ReadAllText((Join-Path $root ('server\' + ($f -replace '/', '\')))) -replace "`r", ''
    [IO.File]::WriteAllText((Join-Path $work $f), $sh, (New-Object Text.UTF8Encoding $false))
}
$tar = Join-Path $out 'gpu-setup.tar'
Remove-Item -Force -ErrorAction SilentlyContinue $tar
Push-Location $work
& tar.exe -cf $tar @scripts
$code = $LASTEXITCODE
$listed = @(& tar.exe -tf $tar | Where-Object { $_ -notmatch '/$' }).Count
Pop-Location
Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $work
if ($code -ne 0) { Stop-Run 'tar로 묶지 못했어요' '남은 공간을 확인하고 다시 실행하세요.' }
if ($listed -ne $scripts.Count) { Stop-Run "묶음 안의 파일 수가 맞지 않아요(묶음 ${listed}개, 있어야 할 것 $($scripts.Count)개)" '다시 실행하세요.' }
Write-Ok "묶음 안의 파일 ${listed}개를 확인했어요"

Write-Host ''
Write-Host '############################ 완료 ############################' -ForegroundColor Green
Write-Host ' 접근 PC에서 할 일은 끝났어요. GPU 서버에 올릴 파일(하나):' -ForegroundColor Green
Write-Host "   $tar  ($(Format-Size (Get-Item $tar).Length))"
Write-Host ''
Save-Fingerprint 'gpu-setup.tar' (Get-Fingerprint @($tar))
Write-Host ''
Write-Host ' 1) 공용 계정의 FileZilla로 GPU 서버의 /app/upload 에 올리세요.' -ForegroundColor Green
Write-Host ' 2) root(PuTTY)로 /app/inbox 에 복사하고, 나온 지문이 위 지문과 같은지 보세요. 다르면 실행하지 마세요.' -ForegroundColor Green
Write-Host '   처음:  cp /app/upload/gpu-setup.tar /app/inbox/ && sha256sum /app/inbox/gpu-setup.tar'
Write-Host '   그 뒤: /app/admin/bin/gpu fetch gpu-setup.tar'
Write-Host ' 3) 같으면 풀어서 준비를 실행하세요. 처음 설치할 때는 맨 먼저 해요(/app 잠금).' -ForegroundColor Green
Write-Host '   cd /app/inbox && tar xf gpu-setup.tar && bash prepare.sh'
Write-Host ' 4) 권한·규칙 설정(admin_setup.sh)은 기초 프로그램·도커·데이터셋·모델을 다 설치한 뒤에 해요.' -ForegroundColor Green
Write-Host ' 자세한 순서: docs\1_처음_설치.md 의 1단계와 6단계'
Write-Host '##############################################################' -ForegroundColor Green
Stop-Transcript | Out-Null
