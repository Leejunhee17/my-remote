#!/usr/bin/env bash
# [B200 서버] OS를 새로 설치한 직후, 반입 전에 서버 상태를 점검한다. root 없이 되고 아무것도 바꾸지 않는다.
#   bash check_server.sh
# 결과의 [문제] 줄은 서버 관리 팀에 요청할 내용이다.
set -uo pipefail
c_g=$'\e[32m'; c_y=$'\e[33m'; c_r=$'\e[31m'; c_c=$'\e[36m'; c_0=$'\e[0m'
ok()   { echo "  ${c_g}[정상]${c_0} $*"; }
warn() { echo "  ${c_y}[주의]${c_0} $*"; }
ASK=(); MINE=()
bad()  { echo "  ${c_r}[문제]${c_0} $1"; ASK+=("$2"); }    # 서버 관리 팀에 요청할 것
mine() { echo "  ${c_r}[문제]${c_0} $1"; MINE+=("$2"); }   # 관리자가 직접 할 것
ACC=${B200_ACCOUNT:-$(cat /etc/b200/account 2>/dev/null)}   # 공용 계정 이름은 서버의 /etc/b200/account 한 곳에 적는다
ver_ge() { [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -1)" = "$2" ]; }
GLIBC_NEED=2.35   # 접근 PC pack_build.ps1 의 -Glibc 기본값과 같게 둔다
APP=${APP:-/app}

echo "${c_c}[B200 서버] 점검  ($(date '+%Y-%m-%d %H:%M'), $(hostname), $(id -un))${c_0}"

echo; echo "${c_c}== 운영체제 ==${c_0}"
os=$(. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME")
glibc=$(ldd --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+$')
echo "  $os, 커널 $(uname -r), glibc $glibc"
case "$os" in Ubuntu*) ;; *) warn "Ubuntu가 아니에요($os). 설치 스크립트는 Ubuntu 24.04 기준이에요(22.04도 돼요)" ;; esac
if [ -z "$ACC" ]; then mine "공용 계정 이름을 몰라요" "서버에 한 번 적어 두기: mkdir -p /etc/b200 && echo 공용계정이름 > /etc/b200/account"
elif id "$ACC" >/dev/null 2>&1; then ok "공용 계정($ACC)이 있어요"; else
    bad "공용 계정이 없어요: $ACC" "팀원 공용 계정($ACC)을 예전과 같은 이름으로 만들어 주세요(sudo·docker 그룹 없이)"; fi
if ver_ge "$glibc" "$GLIBC_NEED"; then ok "glibc $glibc (묶음 기준 $GLIBC_NEED 이상)"
else mine "glibc $glibc: 묶음 기준($GLIBC_NEED)보다 낮아요" "접근 PC에서 묶음을 다시 만들기: pack_build.ps1 -Glibc $glibc"; fi

echo; echo "${c_c}== GPU ==${c_0}"
if command -v nvidia-smi >/dev/null && nvidia-smi -L >/dev/null 2>&1; then
    drv=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -1)
    ngpu=$(nvidia-smi -L | wc -l)
    echo "  $(nvidia-smi --query-gpu=name --format=csv,noheader | head -1) × $ngpu, 드라이버 $drv"
    if ver_ge "$drv" 580; then ok "드라이버 $drv (CUDA 13 이미지도 돌아가요)"
    else bad "드라이버 $drv: 580보다 낮아요" "NVIDIA 드라이버 580 이상(open 커널 모듈, 예: nvidia-driver-580-open)으로 설치해 주세요"; fi
    [ "$ngpu" -eq 8 ] && ok "GPU 8장이 보여요" || warn "GPU가 ${ngpu}장만 보여요(8장이어야 해요). 서버 관리 팀에 확인하세요"
    # HGX B200 은 Fabric Manager 가 NVLink 를 초기화해야 CUDA 가 GPU를 쓸 수 있다
    fab=$(nvidia-smi -q 2>/dev/null | awk '/^ *Fabric/{f=1} f && /State/{print $3; exit}')
    case "$fab" in
        Completed) ok "NVLink Fabric 초기화가 끝났어요" ;;
        ""|N/A)    warn "NVLink Fabric 상태를 읽지 못했어요(HGX 보드가 아니면 상관없어요)" ;;
        *)         bad "NVLink Fabric 상태: $fab (Completed여야 GPU를 써요)" "드라이버와 같은 판의 nvidia-fabricmanager와 B200용 nvlsm을 설치하고 서비스를 켜 주세요" ;;
    esac
    if command -v systemctl >/dev/null; then
        st=$(systemctl is-active nvidia-fabricmanager 2>/dev/null)
        [ "$st" = active ] && ok "nvidia-fabricmanager 서비스가 돌고 있어요" || warn "nvidia-fabricmanager 서비스: ${st:-없음}. 서버 관리 팀에 확인하세요"
    fi
    pm=$(nvidia-smi --query-gpu=persistence_mode --format=csv,noheader | sort -u | tr '\n' ' ')
    [ "${pm% }" = Enabled ] && ok "Persistence mode 켜져 있어요" || warn "Persistence mode: ${pm% }. nvidia-persistenced를 켜 두면 GPU를 처음 쓸 때 기다리지 않아요"
else
    bad "nvidia-smi가 없거나 GPU를 못 봐요" "NVIDIA 드라이버 580 이상(open 커널 모듈)과 nvidia-fabricmanager를 설치해 주세요"
fi

echo; echo "${c_c}== 저장 공간 ==${c_0}"
home_gb=$(( $(df -Pm "$HOME/." | awk 'NR==2 {print $2}') / 1024 ))
echo "  홈 $HOME: 전체 ${home_gb} GB, 남은 공간 $(( $(df -Pm "$HOME/." | awk 'NR==2 {print $4}') / 1024 )) GB"
if [ -d "$APP" ]; then
    app_dev=$(df -P "$APP/." | awk 'NR==2 {print $1}')
    app_gb=$(( $(df -Pm "$APP/." | awk 'NR==2 {print $4}') / 1024 ))
    rota=$(lsblk -ndo ROTA "$app_dev" 2>/dev/null || lsblk -no ROTA "$app_dev" 2>/dev/null | head -1)
    kind=$([ "$(echo $rota)" = 0 ] && echo SSD || { [ "$(echo $rota)" = 1 ] && echo HDD || echo 종류 모름; })
    echo "  $APP: $app_dev, $kind, 남은 공간 ${app_gb} GB"
    # /app 은 root 소유로 둔다(admin_setup.sh 가 잠근다). 팀원은 그 아래 /app/workspace 에 쓴다
    owner=$(stat -c %U "$APP")
    if [ "$owner" = root ]; then ok "$APP 주인이 root예요(팀원은 $APP/workspace 에 써요)"
    else warn "$APP 주인: $owner. 1단계에서 root로 admin_setup.sh 를 실행하면 root 소유로 잠가요"; fi
    if [ -d "$APP/workspace" ] && [ ! -w "$APP/workspace" ]; then
        mine "$APP/workspace 에 쓸 수 없어요" "root로 다시 실행하기: bash /app/inbox/admin_setup.sh (공용 계정 소유로 맞춰요)"
    fi
    if [ -e "$APP/shared" ]; then
        warn "$APP/shared 가 남아 있어요(예전 설치). pack_install.sh 가 이어서 써요(새로 깔려면 docs/1_처음_설치.md 2단계)"
    fi
    [ -d "$APP/shared/datasets" ] && ok "예전 데이터셋이 남아 있어요: $APP/shared/datasets (다시 올리지 않아도 돼요)"
    [ -d "$APP/shared/models" ] && ok "예전 모델이 남아 있어요: $APP/shared/models (다시 올리지 않아도 돼요)"
else
    bad "$APP 폴더가 없어요" "2 TB SSD를 $APP 에 연결해 주세요(주인은 root 그대로)"
fi

echo; echo "${c_c}== 기본 명령 ==${c_0}"
miss=()
for b in bash tar sha256sum awk sed grep df du realpath sort; do command -v "$b" >/dev/null || miss+=("$b"); done
[ ${#miss[@]} -eq 0 ] && ok "설치 스크립트에 필요한 명령이 모두 있어요" ||
    bad "없는 명령: ${miss[*]}" "기본 명령(coreutils, tar 등)을 설치해 주세요: ${miss[*]}"

echo
if [ ${#ASK[@]} -eq 0 ] && [ ${#MINE[@]} -eq 0 ]; then
    echo "${c_g}######## 모두 정상이에요. 반입을 시작해도 돼요 (docs/1_처음_설치.md 1단계) ########${c_0}"
else
    echo "${c_r}############## 고칠 것 $(( ${#ASK[@]} + ${#MINE[@]} ))개 ##############${c_0}"
    if [ ${#ASK[@]} -gt 0 ]; then
        echo " 서버 관리 팀에 요청할 것(이 목록을 그대로 보내세요)"
        printf '%s\n' "${ASK[@]}" | sort -u | sed 's/^/  - /'
    fi
    if [ ${#MINE[@]} -gt 0 ]; then
        echo " 관리자가 직접 할 것"
        printf '%s\n' "${MINE[@]}" | sort -u | sed 's/^/  - /'
    fi
    echo " 고친 뒤 다시 점검하세요: bash /app/inbox/check_server.sh"
fi
