#!/usr/bin/env bash
# [B200 서버] OS를 새로 설치한 직후, 반입 전에 서버 상태를 점검한다. root 없이 되고 아무것도 바꾸지 않는다.
#   bash check_server.sh
# 결과의 [문제] 줄은 서버 관리 팀에 요청할 내용이다.
set -uo pipefail
c_g=$'\e[32m'; c_y=$'\e[33m'; c_r=$'\e[31m'; c_c=$'\e[36m'; c_0=$'\e[0m'
ok()   { echo "  ${c_g}[정상]${c_0} $*"; }
warn() { echo "  ${c_y}[주의]${c_0} $*"; }
ASK=()
bad()  { echo "  ${c_r}[문제]${c_0} $1"; ASK+=("$2"); }
ver_ge() { [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -1)" = "$2" ]; }
GLIBC_NEED=2.35   # 접근 PC pack_build.ps1 의 -Glibc 기본값과 같게 둔다
APP=${APP:-/app}

echo "${c_c}[B200 서버] 서버 점검  ($(date '+%Y-%m-%d %H:%M'), $(hostname), $(id -un))${c_0}"

echo; echo "${c_c}== 운영체제 ==${c_0}"
os=$(. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME")
glibc=$(ldd --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+$')
echo "  $os, 커널 $(uname -r), glibc $glibc"
if ver_ge "$glibc" "$GLIBC_NEED"; then ok "glibc $glibc (묶음 기준 $GLIBC_NEED 이상)"
else bad "glibc $glibc 가 묶음 기준 $GLIBC_NEED 보다 낮다" "접근 PC에서 pack_build.ps1 -Glibc $glibc 로 묶음을 다시 만든다(서버 팀 요청 아님)"; fi

echo; echo "${c_c}== GPU ==${c_0}"
if command -v nvidia-smi >/dev/null && nvidia-smi -L >/dev/null 2>&1; then
    drv=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -1)
    ngpu=$(nvidia-smi -L | wc -l)
    echo "  $(nvidia-smi --query-gpu=name --format=csv,noheader | head -1) × $ngpu, 드라이버 $drv"
    if ver_ge "$drv" 580; then ok "드라이버 $drv (CUDA 13 가능)"
    else bad "드라이버 $drv 가 낮다" "NVIDIA 드라이버 580 이상(open 커널 모듈, 예: nvidia-driver-580-open) 설치"; fi
    [ "$ngpu" -eq 8 ] && ok "GPU 8장 보임" || warn "GPU가 ${ngpu}장 보인다(8장이어야 한다)"
    # HGX B200 은 Fabric Manager 가 NVLink 를 초기화해야 CUDA 가 GPU를 쓸 수 있다
    fab=$(nvidia-smi -q 2>/dev/null | awk '/^ *Fabric/{f=1} f && /State/{print $3; exit}')
    case "$fab" in
        Completed) ok "NVLink Fabric 초기화 완료" ;;
        ""|N/A)    warn "Fabric 상태를 읽지 못했다(HGX 보드가 아니면 상관없다)" ;;
        *)         bad "NVLink Fabric 상태가 $fab 다" "nvidia-fabricmanager(드라이버와 같은 버전)와 B200용 nvlsm 설치, 서비스 켜기" ;;
    esac
    if command -v systemctl >/dev/null; then
        st=$(systemctl is-active nvidia-fabricmanager 2>/dev/null)
        [ "$st" = active ] && ok "nvidia-fabricmanager 서비스 실행 중" || warn "nvidia-fabricmanager 서비스: ${st:-없음}"
    fi
    pm=$(nvidia-smi --query-gpu=persistence_mode --format=csv,noheader | sort -u | tr '\n' ' ')
    [ "${pm% }" = Enabled ] && ok "Persistence mode 켜짐" || warn "Persistence mode: $pm(nvidia-persistenced 를 켜 두면 GPU 첫 사용이 빨라진다)"
else
    bad "nvidia-smi 가 없거나 GPU를 못 본다" "NVIDIA 드라이버 580 이상(open 커널 모듈)과 nvidia-fabricmanager 설치"
fi

echo; echo "${c_c}== 저장 공간 ==${c_0}"
home_gb=$(( $(df -Pm "$HOME/." | awk 'NR==2 {print $2}') / 1024 ))
echo "  홈 $HOME: 전체 ${home_gb} GB, 남음 $(( $(df -Pm "$HOME/." | awk 'NR==2 {print $4}') / 1024 )) GB"
if [ -d "$APP" ]; then
    app_dev=$(df -P "$APP/." | awk 'NR==2 {print $1}')
    app_gb=$(( $(df -Pm "$APP/." | awk 'NR==2 {print $4}') / 1024 ))
    rota=$(lsblk -ndo ROTA "$app_dev" 2>/dev/null || lsblk -no ROTA "$app_dev" 2>/dev/null | head -1)
    kind=$([ "$(echo $rota)" = 0 ] && echo SSD || { [ "$(echo $rota)" = 1 ] && echo HDD || echo 종류 모름; })
    echo "  $APP: $app_dev, $kind, 남음 ${app_gb} GB"
    # /app 은 root 소유로 둔다(admin_setup.sh 가 잠근다). 팀원은 그 아래 /app/workspace 에 쓴다
    owner=$(stat -c %U "$APP")
    if [ "$owner" = root ]; then ok "$APP 주인 root (팀원은 $APP/workspace 에 쓴다)"
    else warn "$APP 주인이 $owner 다. root 로 admin_setup.sh 를 실행하면 root 소유로 잠근다"; fi
    if [ -d "$APP/workspace" ] && [ ! -w "$APP/workspace" ]; then
        bad "$APP/workspace 에 쓸 수 없다" "root 로 bash /app/inbox/admin_setup.sh 다시 실행(공용 계정 소유로 맞춘다)"
    fi
    if [ -e "$APP/shared" ]; then
        warn "$APP/shared 가 남아 있다(예전 설치). pack_install.sh 가 그대로 이어서 쓴다"
    fi
    [ -d "$APP/shared/datasets" ] && ok "예전 데이터셋이 남아 있다: $APP/shared/datasets (다시 올리지 않아도 된다)"
    [ -d "$APP/shared/models" ] && ok "예전 모델이 남아 있다: $APP/shared/models (다시 올리지 않아도 된다)"
else
    bad "$APP 가 없다" "2 TB SSD를 $APP 에 마운트하기(주인은 root 그대로)"
fi

echo; echo "${c_c}== 시스템 라이브러리 (open3d 등이 쓴다) ==${c_0}"
for lib in libGL.so.1 libEGL.so.1 libgomp.so.1 libX11.so.6; do
    if ldconfig -p 2>/dev/null | grep -q "$lib"; then ok "$lib"
    else bad "$lib 가 없다" "apt 패키지 libgl1 libegl1 libgomp1 libx11-6 설치"; fi
done

echo; echo "${c_c}== 기본 명령 ==${c_0}"
miss=()
for b in bash tar sha256sum awk sed grep df du realpath sort; do command -v "$b" >/dev/null || miss+=("$b"); done
[ ${#miss[@]} -eq 0 ] && ok "설치 스크립트에 필요한 명령 모두 있음" ||
    bad "없는 명령: ${miss[*]}" "기본 명령(coreutils, tar) 설치"

echo
if [ ${#ASK[@]} -eq 0 ]; then
    echo "${c_g}######## 모두 정상. 반입을 시작해도 된다 (README 1단계) ########${c_0}"
else
    echo "${c_r}############## 고칠 것 ${#ASK[@]}개 ##############${c_0}"
    printf '%s\n' "${ASK[@]}" | sort -u | sed 's/^/  - /'
    echo " 서버 관리 팀에 위 목록을 보내 준다."
fi
