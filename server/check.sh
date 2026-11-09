#!/usr/bin/env bash
# [GPU 서버] 서버·NAS·네트워크를 한 번에 점검하고 보고서 하나로 남겨요. 설정은 아무것도 바꾸지 않아요.
# root 로 실행해요(1단계 전에는 root 만 NAS(/data/tmp)에 써서 두 서버가 서로 찾을 수 있어요). 보고서는 공용 계정 홈에 넣어요.
# 공용 계정으로도 돼요. 그때는 공용 계정이 쓸 수 있는 NAS 폴더(1단계 뒤 /data/autonomy_sw/tmp_transfer)가 있어야 속도를 재요.
#   bash check.sh                     전체 점검. 두 서버에서 각각 실행하면 NAS로 서로를 찾아 서버 사이(이더넷·InfiniBand·RDMA),
#                                     로컬 SSD, NAS 속도까지 재요. 상대 서버를 최대 10분 기다려요
#   bash check.sh <NAS 안 폴더>        속도 측정에 쓸 NAS 폴더를 직접 정해요(내가 쓸 수 있는 폴더)
#   QUICK=1 bash check.sh             속도 측정 없이 상태만 봐요(1분 안에 끝나요)
#   bash check.sh listen              서버 사이 속도만: 받는 쪽(먼저 실행, 2분 기다려요)
#   bash check.sh send <받는 쪽 IP>     서버 사이 속도만: 보내는 쪽(10초)
#   bash check.sh disk <폴더>          그 폴더(NAS나 /app)의 쓰기·읽기 속도만(시험 파일 4 GB를 쓰고 지워요)
#   JOBS=8 bash check.sh disk <폴더>   파일 8개를 동시에(여럿이 함께 쓸 때의 전체 속도)
# [문제] 줄은 마지막 "고칠 것" 목록에 모여요. 보고서는 원본(check_report_…txt)과 사내 정보를 가린 공유용(check_공유용_…txt)
# 두 개예요. root 면 공용 계정 홈에(FileZilla로 바로 내려받게), 공용 계정이면 실행한 폴더(내 폴더가 아니면 홈)에 남아요. 숫자는 GB/s 와 Gbps(카드 속도 단위)를 같이 보여 줘요. 1 GB/s = 8 Gbps.
set -uo pipefail
c_g=$'\e[32m'; c_y=$'\e[33m'; c_r=$'\e[31m'; c_c=$'\e[36m'; c_0=$'\e[0m'
ok()   { echo "  ${c_g}[정상]${c_0} $*"; }
warn() { echo "  ${c_y}[주의]${c_0} $*"; }
ASK=(); MINE=(); SUM=()
bad()  { echo "  ${c_r}[문제]${c_0} $1"; [ -z "${2:-}" ] || ASK+=("$2"); }   # $2: 서버 관리 팀에 요청할 것
mine() { echo "  ${c_r}[문제]${c_0} $1"; MINE+=("$2"); }                    # $2: 관리자가 직접 할 것
head_() { echo; echo "${c_c}== $* ==${c_0}"; }

IS_ROOT=; [ "$(id -u)" = 0 ] && IS_ROOT=1
APP=${APP:-/app}
ME=${GPU_HOST:-$(hostname -s)}
ACC=${GPU_ACCOUNT:-$(cat /etc/gpu/account 2>/dev/null)}   # 공용 계정 이름은 서버의 /etc/gpu/account 한 곳에 적는다
ACC_SET=${ACC:+1}; [ -n "$ACC" ] || [ -n "$IS_ROOT" ] || ACC=$(id -un)   # 아직 안 적었으면 지금 계정을 공용 계정으로 본다(root 는 빼고)
TEAM=${NAS_DIR:-$(sed -n 's/^NAS_DIR=\([^ #]*\).*/\1/p' "$APP/admin/gpu.conf" 2>/dev/null | tail -1)}; TEAM=${TEAM:-/data/autonomy_sw}
PORT=${PORT:-5201}
STREAMS=${STREAMS:-8}
SECS=${SECS:-10}
WAIT_PEER=${WAIT_PEER:-600}
NAS_FS=nfs,nfs4,cifs,smb3,lustre,gpfs,beegfs

ver_ge() { [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -1)" = "$2" ]; }
# 화면 폭(한글은 두 칸)에 맞춰 채운다
pad() { local w; w=$(printf '%s' "$1" | LC_ALL=C.UTF-8 wc -L); printf '%s%*s' "$1" $(( $2 > w ? $2 - w : 0 )) ''; }
grp_name() { local n; n=$(getent group "$1" | cut -d: -f1); echo "${n:-$1}"; }
# 주인 번호 → "이름(번호)". 이 서버에 없는 번호면 그렇다고 적는다
who_uid() { local n; n=$(getent passwd "$1" | cut -d: -f1); echo "${n:-이 서버에 없는 계정}($1)"; }
# 권한 숫자 → 누가 쓸 수 있는지
who_writes() {
    local m=$1 s=''
    [ $(( 8#$m & 8#0002 )) -ne 0 ] && s='누구나 씀'
    [ -z "$s" ] && [ $(( 8#$m & 8#0020 )) -ne 0 ] && s='주인·그룹이 씀'
    [ -z "$s" ] && s='주인만 씀'
    [ $(( 8#$m & 8#1000 )) -ne 0 ] && s="$s, 스티키(남의 파일은 못 지움)"
    echo "$s"
}
# NAS 로 연결된 폴더: "TARGET SOURCE FSTYPE OPTIONS" 한 줄씩. GPU_NAS 는 mount 목록에 안 보일 때(시험할 때) 직접 적는다
nas_mounts() {
    if [ -n "${GPU_NAS:-}" ]; then echo "$GPU_NAS (직접지정) - -"
    else findmnt -rn -t "$NAS_FS" -o TARGET,SOURCE,FSTYPE,OPTIONS 2>/dev/null; fi
}
main_nas() {   # 팀 폴더가 들어 있는 NAS, 없으면 첫 NAS
    local t best=
    while read -r t _; do
        [ -n "$best" ] || best=$t
        case "$TEAM/" in "$t"/*) best=$t; break ;; esac
    done < <(nas_mounts)
    echo "$best"
}
# root 만 고칠 수 있는 폴더인지: 그 폴더부터 / 까지 모두 root 소유이고 남이 못 쓰거나 스티키(남의 파일·폴더를 못 지움).
# 위 폴더 하나라도 남이 쓸 수 있으면, 그 사람이 아래 폴더를 다른 이름으로 옮기고 같은 이름의 링크를 심을 수 있다
root_only() {
    local p m; p=$(readlink -f "$1") && [ -d "$p" ] || return 1
    while :; do
        m=$(stat -c '%u %a' "$p") || return 1
        [ "${m%% *}" = 0 ] || return 1
        [ $(( 8#${m##* } & 8#1000 )) -ne 0 ] || [ $(( 8#${m##* } & 8#022 )) -eq 0 ] || return 1
        [ "$p" = / ] && return 0; p=$(dirname "$p")
    done
}
# 시험 파일·주소 파일을 써도 되는 폴더인지. root 는 남이 바꿔치기할 수 없는 폴더(root_only)에만 쓴다.
# 그렇지 않은 폴더에 root 가 쓰면, 그 폴더를 고칠 수 있는 사람이 링크를 심어 root 가 시스템 파일을 덮게 만들 수 있다
usable_dir() {
    [ -d "$1" ] && [ ! -L "$1" ] && [ -w "$1" ] || return 1
    [ -z "$IS_ROOT" ] || root_only "$1"
}
# 속도 측정과 상대 서버 찾기에 쓸 NAS 폴더: 직접 적은 폴더 → 팀 폴더의 tmp_transfer(공용 계정) → NAS/tmp → NAS
nas_dir() {
    [ -n "${1:-}" ] && { usable_dir "$1" && echo "$1"; return; }
    local c t
    { echo "$TEAM/tmp_transfer"; while read -r t _; do echo "$t/tmp"; echo "$t"; done < <(nas_mounts); } |
        while IFS= read -r c; do usable_dir "$c" && { echo "$c"; break; }; done
}
# 공용 계정이 그 폴더에 쓸 수 있는지. root 는 공용 계정 권한으로 확인한다(setsid: 공용 계정 프로그램이 root 화면에 글자를 넣지 못하게)
acc_writes() {
    if [ -n "$IS_ROOT" ]; then setsid -w runuser -u "$ACC" -- test -w "$1" 2>/dev/null; else [ -w "$1" ]; fi
}

# nvidia-smi topo -m 에서 NVLink(NV숫자)로 이어진 GPU 묶음: "[0,1,2,3] [4,5,6,7]". 묶인 것이 없으면 빈 줄
nvl_groups() {
    nvidia-smi topo -m 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g' | awk '
        function f(x) { while (p[x] != x) x = p[x]; return x }
        /^GPU[0-9]+[ \t]/ { i = substr($1, 4) + 0; g[i] = 1; p[i] = i
                            for (k = 2; k <= NF; k++) if ($k ~ /^NV[0-9]+$/) e[i "," (k - 2)] = 1 }
        END { for (x in e) { split(x, a, ","); if (!(a[2] in g)) continue; r1 = f(a[1]); r2 = f(a[2]); if (r1 != r2) p[r1] = r2 }
              for (i = 0; i < 64; i++) if (i in g) { r = f(i); m[r] = c[r]++ ? m[r] "," i : i }
              out = ""; for (i = 0; i < 64; i++) if (i in g) { r = f(i); if (c[r] > 1 && !(r in done)) { done[r] = 1; out = out (out == "" ? "" : " ") "[" m[r] "]" } }
              print out }'
}

# 카드 하나: 이름 종류 상태 속도(Mb/s) MTU 주소
nic_line() {
    local n=$1 d=/sys/class/net/$1 type kind speed state mtu addr
    type=$(cat "$d/type" 2>/dev/null); state=$(cat "$d/operstate" 2>/dev/null)
    speed=$(cat "$d/speed" 2>/dev/null); [ "${speed:--1}" -gt 0 ] 2>/dev/null || speed=
    mtu=$(cat "$d/mtu" 2>/dev/null)
    case "$type" in 32) kind=InfiniBand ;; 1) kind=이더넷 ;; *) kind="종류$type" ;; esac
    [ -d "$d/device" ] || kind="$kind(가상)"
    addr=$(ip -4 -br addr show "$n" 2>/dev/null | awk '{print $3}')
    echo "  $(pad "$n" 16)$(pad "$kind" 16)$(pad "$state" 8)$(pad "${speed:+$((speed / 1000)) Gbps}" 11)$(pad "$mtu" 7)${addr:--}"
    # 묶은 카드(bond): 어떤 카드를 묶었는지와 나눠 보내는 방식(모드마다 한 연결이 낼 수 있는 속도가 다르다)
    if [ -d "$d/bonding" ]; then
        local bmode; bmode=$(cut -d' ' -f1 "$d/bonding/mode" 2>/dev/null)
        case "$bmode" in
        balance-rr)
            echo "      = $(cat "$d/bonding/slaves" 2>/dev/null | sed 's/ / + /g'),  모드 balance-rr(패킷을 카드마다 번갈아 보내요)"
            echo "        한 연결도 두 카드를 같이 쓰지만, 패킷 순서가 뒤섞여 보통 카드 하나 속도 안팎이에요. 여러 연결을 동시에 하면 합친 속도가 나와요" ;;
        active-backup)
            echo "      = $(cat "$d/bonding/slaves" 2>/dev/null | sed 's/ / + /g'),  모드 active-backup"
            echo "        한 번에 카드 하나만 써요(나머지는 고장 대비 예비). 여러 연결을 해도 카드 하나 속도예요" ;;
        *)
            echo "      = $(cat "$d/bonding/slaves" 2>/dev/null | sed 's/ / + /g'),  모드 $bmode, 연결 분배 방식 $(cut -d' ' -f1 "$d/bonding/xmit_hash_policy" 2>/dev/null)"
            echo "        한 연결(scp 하나 등)은 카드 하나 속도까지만 나와요. 여러 연결을 동시에 해야 합친 속도가 나와요" ;;
        esac
    fi
}
# IP 로 가는 카드와 그 카드의 속도
route_to() {
    local ip=$1 dev speed
    dev=$(ip route get "$ip" 2>/dev/null | grep -oP 'dev \K\S+' | head -1)
    [ -n "$dev" ] || { echo "-"; return; }
    speed=$(cat "/sys/class/net/$dev/speed" 2>/dev/null)
    [ "${speed:--1}" -gt 0 ] 2>/dev/null && echo "$dev ($((speed / 1000)) Gbps)" || echo "$dev (속도 모름)"
}
rate() {   # 바이트 초 → "x.xx GB/s (y Gbps)"
    awk -v b="$1" -v s="$2" 'BEGIN {g=b/s/1e9; printf "%.2f GB/s (%.1f Gbps)", g, g*8}'
}

# ================================================================== 서버
sec_os() {
    head_ '운영체제·공용 계정'
    local os; os=$(. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME")
    echo "  $os, 커널 $(uname -r)"
    case "$os" in Ubuntu*) ;; *) warn "Ubuntu가 아니에요($os). 설치 스크립트는 Ubuntu 24.04 기준이에요(22.04도 돼요)" ;; esac
    if [ -z "$ACC_SET" ] && [ -n "$IS_ROOT" ]; then
        mine "공용 계정 이름을 알 수 없어요(/etc/gpu/account 는 1단계에서 적어요). 보고서를 공용 계정 홈에 넣지 못해요" \
             "공용 계정 이름을 앞에 붙여 다시 점검하기: GPU_ACCOUNT=<계정이름> bash $(readlink -f "$0")"
    elif [ -z "$ACC_SET" ]; then
        warn "/etc/gpu/account 가 아직 없어요. 지금 계정($ACC)을 공용 계정으로 보고 점검해요"
        echo "      root 로 적어 둬요(docs/1_처음_설치.md 의 \"처음 한 번: 공용 계정 이름과 /app/inbox\")"
    elif id "$ACC" >/dev/null 2>&1; then
        ok "공용 계정($ACC)이 있어요"
        [ -n "$IS_ROOT" ] || [ "$(id -un)" = "$ACC" ] || warn "공용 계정이 아닌 $(id -un) 로 실행했어요. 쓸 수 있는 곳은 지금 계정 기준으로 봐요"
    else
        bad "공용 계정이 없어요: $ACC (이름을 잘못 적었으면 /etc/gpu/account 를 고치세요)" "팀원 공용 계정($ACC)을 예전과 같은 이름으로 만들어 주세요(sudo·docker 그룹 없이)"
    fi
}

sec_gpu() {
    head_ 'GPU'
    if ! { command -v nvidia-smi >/dev/null && nvidia-smi -L >/dev/null 2>&1; }; then
        bad "nvidia-smi가 없거나 GPU를 못 봐요" "NVIDIA 드라이버 580 이상(open 커널 모듈)을 설치해 주세요(HGX 보드면 nvidia-fabricmanager 도)"
        return
    fi
    local drv ngpu gname groups fab st pm
    drv=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -1)
    ngpu=$(nvidia-smi -L | wc -l)
    gname=$(nvidia-smi --query-gpu=name --format=csv,noheader | head -1)
    echo "  $gname × $ngpu, 드라이버 $drv"
    if ver_ge "$drv" 580; then ok "드라이버 $drv (CUDA 13 이미지도 돌아가요)"
    else bad "드라이버 $drv: 580보다 낮아요" "NVIDIA 드라이버 580 이상(open 커널 모듈, 예: nvidia-driver-580-open)으로 설치해 주세요"; fi
    [ "$ngpu" -eq 8 ] && ok "GPU 8장이 보여요" || warn "GPU가 ${ngpu}장만 보여요(8장이어야 해요). 서버 관리 팀에 확인하세요"
    case "$gname" in
    *NVL*|*PCIe*)
        # PCIe 카드(H200 NVL 등)는 NVSwitch 가 없어 Fabric Manager 가 필요 없다. NVLink 는 브리지로 2장·4장씩 묶인다
        ok "PCIe 카드라 Fabric Manager가 필요 없어요"
        groups=$(nvl_groups)
        if [ -n "$groups" ]; then
            ok "NVLink 브리지로 묶인 GPU: $groups"
            echo "      여러 장을 한 작업에 쓸 때는 같은 묶음 안에서 고르면 GPU끼리 빠르게 주고받아요(묶음 밖은 PCIe)"
        else
            warn "NVLink 브리지로 묶인 GPU가 없어요(GPU끼리 PCIe로만 주고받아요). 브리지를 끼웠는지 서버 관리 팀에 확인하세요"
        fi ;;
    *)
        # HGX(SXM) 보드는 Fabric Manager 가 NVLink 를 초기화해야 CUDA 가 GPU를 쓸 수 있다(Blackwell 세대부터는 nvlsm 도)
        fab=$(nvidia-smi -q 2>/dev/null | awk '/^ *Fabric/{f=1} f && /State/{print $3; exit}')
        case "$fab" in
            Completed) ok "NVLink Fabric 초기화가 끝났어요" ;;
            ""|N/A)    warn "NVLink Fabric 상태를 읽지 못했어요(HGX 보드가 아니면 상관없어요)" ;;
            *)         bad "NVLink Fabric 상태: $fab (Completed여야 GPU를 써요)" "드라이버와 같은 버전의 nvidia-fabricmanager(Blackwell 세대부터는 nvlsm 도)를 설치하고 서비스를 켜 주세요" ;;
        esac
        if command -v systemctl >/dev/null; then
            st=$(systemctl is-active nvidia-fabricmanager 2>/dev/null)
            [ "$st" = active ] && ok "nvidia-fabricmanager 서비스가 돌고 있어요" || warn "nvidia-fabricmanager 서비스: ${st:-없음}. 서버 관리 팀에 확인하세요"
        fi ;;
    esac
    pm=$(nvidia-smi --query-gpu=persistence_mode --format=csv,noheader | sort -u | tr '\n' ' ')
    [ "${pm% }" = Enabled ] && ok "Persistence mode가 켜져 있어요" || warn "Persistence mode: ${pm% }. nvidia-persistenced를 켜 두면 GPU를 처음 쓸 때 기다리지 않아요"
}

sec_storage() {
    head_ '저장 공간'
    local app_dev app_gb rota kind owner
    df -Pm "$HOME/." 2>/dev/null | awk -v h="$HOME" 'NR==2 {printf "  홈 %s: 전체 %d GB, 남은 공간 %d GB\n", h, $2 / 1024, $4 / 1024}'
    if [ ! -d "$APP" ]; then
        bad "$APP 폴더가 없어요" "2 TB SSD를 $APP 에 연결해 주세요(주인은 root 그대로)"
        return
    fi
    app_dev=$(df -P "$APP/." | awk 'NR==2 {print $1}')
    app_gb=$(( $(df -Pm "$APP/." | awk 'NR==2 {print $4}') / 1024 ))
    rota=$(lsblk -ndo ROTA "$app_dev" 2>/dev/null || lsblk -no ROTA "$app_dev" 2>/dev/null | head -1)
    kind=$([ "$(echo $rota)" = 0 ] && echo SSD || { [ "$(echo $rota)" = 1 ] && echo HDD || echo 종류 모름; })
    echo "  $APP: $app_dev, $kind, 남은 공간 ${app_gb} GB"
    # /app 은 root 소유로 둔다(1단계 prepare.sh 가 잠근다). 팀원은 그 아래 /app/autonomy_sw 에 쓴다
    owner=$(stat -c %U "$APP")
    if [ "$owner" = root ]; then ok "$APP 주인이 root예요(팀원은 $APP/autonomy_sw 에 써요)"
    else warn "$APP 주인: $owner. 1단계에서 root로 prepare.sh 를 실행하면 root 소유로 잠가요"; fi
    if [ -d "$APP/autonomy_sw" ] && id "$ACC" >/dev/null 2>&1 && ! acc_writes "$APP/autonomy_sw"; then
        mine "공용 계정이 $APP/autonomy_sw 에 쓸 수 없어요" "root로 다시 실행하기: bash /app/inbox/prepare.sh (공용 계정 소유로 맞춰요)"
    fi
    [ -e "$APP/shared" ] && warn "$APP/shared 가 남아 있어요(예전 설치). 1단계 prepare.sh 가 명단·설정만 $APP/admin 으로 옮기고 나머지는 치워요. 예전 데이터셋·모델을 NAS로 옮기는 명령도 알려 줘요"
}

# ================================================================== 서버 폴더·권한(읽기만 한다)
# 한 줄: 이름  주인(번호)  그룹  권한  누가 쓰는지. 링크·파일·없음도 표시한다
perm_line() {   # $1 경로 $2 보일 이름(없으면 경로) $3 이름 칸 너비
    local p=$1 name=${2:-$1} w=${3:-34} st uid gid mode extra=
    if [ -L "$p" ]; then extra=" → $(readlink "$p")"; name="$name (링크)"
    elif [ ! -e "$p" ]; then echo "  $(pad "$name" "$w") (없어요)"; return; fi
    st=$(stat -c '%u %g %a' "$p" 2>/dev/null) || { echo "  $(pad "$name" "$w") (읽지 못했어요)"; return; }
    read -r uid gid mode <<< "$st"
    [ -L "$p" ] || [ -d "$p" ] || name="$name (파일)"
    echo "  $(pad "$name" "$w") 주인 $(pad "$(who_uid "$uid")" 22) 그룹 $(pad "$(grp_name "$gid")" 12) $(pad "$mode" 5) $(who_writes "$mode")$extra"
}
sec_dirs() {
    head_ '서버 폴더·권한 (읽기만 해요)'
    local p n i others='' links='' open=''
    # /app: 팀원 작업 공간·도커·설치 파일이 놓일 곳. 1단계 prepare.sh 가 root 소유로 잠근다
    if [ -d "$APP" ]; then
        echo "  [$APP 과 그 아래 두 단계]"
        perm_line "$APP" "" 34
        i=0
        while IFS= read -r -d '' p; do
            i=$((i + 1)); [ "$i" -le 80 ] || continue
            perm_line "$p" "${p#"$APP"/}" 34
        done < <(find "$APP" -mindepth 1 -maxdepth 2 -print0 2>/dev/null | sort -z)
        [ "$i" -le 80 ] || echo "  ... 모두 ${i}개 중 80개만 보였어요"
        # 1단계에서 /app 을 잠그기 전에 알아야 할 것: 다른 계정 것, 링크, 누구나 쓰는(스티키 아닌) 폴더
        others=$(find "$APP" -mindepth 1 -maxdepth 2 ! -user root ${ACC:+! -user "$ACC"} -printf '%u ' 2>/dev/null | tr ' ' '\n' | grep . | sort | uniq -c | awk '{printf "%s(%s개) ", $2, $1}')
        [ "$(stat -c %U "$APP")" = root ] || [ "$(stat -c %U "$APP")" = "$ACC" ] || others="$(stat -c %U "$APP")($APP 자체) $others"
        if [ -n "$others" ]; then
            warn "$APP 아래에 root·공용 계정이 아닌 계정의 것이 있어요: $others"
            echo "      1단계 prepare.sh 가 $APP 을 잠그면(root 소유 755) 그 계정은 $APP 바로 아래에 새 폴더를 못 만들어요. 누구 것인지 서버 관리 팀에 확인하세요"
        else ok "$APP 아래는 root·공용 계정 것만 있어요"; fi
        links=$(find "$APP" -mindepth 1 -maxdepth 2 -type l 2>/dev/null | wc -l)
        [ "$links" -eq 0 ] || warn "$APP 아래에 링크가 ${links}개 있어요(위 목록의 '(링크)'). 누가 만들었는지 확인하세요. 1단계 prepare.sh 는 쓰는 자리에 링크가 있으면 멈춰요"
        open=$(find "$APP" -mindepth 0 -maxdepth 2 -type d -perm -0002 ! -perm -1000 2>/dev/null | wc -l)
        [ "$open" -eq 0 ] || warn "$APP 아래에 누구나 쓰고 지울 수 있는 폴더(스티키 아님, o+w)가 ${open}개 있어요"
    fi

    # 홈 폴더: 공용 계정 홈은 보고서가 들어가는 곳이고 팀원이 함께 쓴다
    echo; echo "  [홈 폴더 /home]"
    i=0
    while IFS= read -r -d '' p; do
        i=$((i + 1)); [ "$i" -le 40 ] || continue
        perm_line "$p" "${p#/home/}" 34
    done < <(find /home -mindepth 1 -maxdepth 1 -print0 2>/dev/null | sort -z)
    [ "$i" -gt 0 ] || echo "  (없어요)"
    if id "$ACC" >/dev/null 2>&1; then
        p=$(getent passwd "$ACC" | cut -d: -f6)
        if [ -z "$p" ] || [ ! -d "$p" ]; then warn "공용 계정 홈($p)이 없어요. 보고서를 넣을 곳이 없어요"
        else
            [ "$p" = "/home/$ACC" ] || perm_line "$p" "공용 계정 홈 $p" 34
            [ "$(stat -c %u "$p")" = "$(id -u "$ACC")" ] || warn "공용 계정 홈($p)의 주인이 공용 계정이 아니에요"
            [ -z "$(find "$p" -maxdepth 0 -perm /022)" ] || warn "공용 계정 홈($p)을 다른 계정도 쓸 수 있어요(그룹·누구나 쓰기)"
        fi
    fi

    # 설치 스크립트(root)가 나중에 쓸 시스템 폴더. root 말고 다른 계정이 쓸 수 있으면 root 가 설치할 때 바꿔치기될 수 있다
    echo; echo "  [설치 스크립트가 쓸 시스템 폴더]"
    local sys=(/etc/gpu /etc/profile.d /etc/cron.d /etc/sudoers.d /etc/systemd/system /etc/apparmor.d /etc/nvidia-container-runtime
               /etc/bash.bashrc /etc/subuid /etc/subgid /usr/local/bin /usr/local/sbin /usr/local/lib /opt /var/log /tmp /var/tmp)
    local weak=
    for p in "${sys[@]}"; do
        perm_line "$p" "" 34
        [ -e "$p" ] && [ ! -L "$p" ] || continue
        case "$p" in /tmp|/var/tmp) [ -k "$p" ] || weak+="$p(스티키 아님) "; continue ;; esac
        { [ "$(stat -c %u "$p")" = 0 ] && [ -z "$(find "$p" -maxdepth 0 -perm /022)" ]; } || weak+="$p "
    done
    [ -z "$weak" ] && ok "시스템 폴더는 모두 root 만 고칠 수 있어요" ||
        bad "root 말고도 고칠 수 있는 시스템 폴더가 있어요: $weak" "다음 폴더를 root 소유로, 그룹·다른 계정은 못 쓰게 해 주세요(/tmp·/var/tmp 는 1777): $weak"
    # 예전 설치 흔적(새로 설치한 OS 에는 없어야 한다)
    local left=; for p in /etc/gpu /etc/profile.d/gpu.sh /etc/profile.d/gpu-docker.sh /etc/cron.d/gpu /opt/gpu /etc/systemd/system/gpu-docker.service /var/log/gpu; do
        [ -e "$p" ] || [ -L "$p" ] && left+="$p "; done
    [ -z "$left" ] || echo "  이 저장소의 설치 스크립트가 만드는 것이 이미 있어요(예전에 설치한 흔적이에요): $left"

    # 공용 계정 권한: 관리자 그룹·sudo 가 있으면 누구나 root 가 될 수 있다(admin_setup.sh 와 같은 기준)
    if id "$ACC" >/dev/null 2>&1; then
        echo; echo "  [공용 계정($ACC)]"
        echo "  $(id "$ACC")"
        n=$(id -nG "$ACC" | tr ' ' '\n' | grep -xE 'sudo|admin|wheel|docker|disk|lxd|incus-admin|libvirt' | tr '\n' ' ')
        [ -z "$n" ] && ok "관리자 권한 그룹(sudo·docker·disk·lxd 등)에 없어요" ||
            bad "공용 계정이 관리자 그룹에 있어요: $n(팀원 누구나 root 가 될 수 있어요)" "공용 계정($ACC)을 관리자 그룹에서 빼 주세요: $n"
        if [ -n "$IS_ROOT" ]; then
            sudo -l -U "$ACC" 2>/dev/null | grep -q 'may run' &&
                bad "공용 계정이 sudo 를 쓸 수 있어요" "공용 계정($ACC)의 sudo 권한을 없애 주세요(/etc/sudoers, /etc/sudoers.d/)" || ok "sudo 를 못 써요"
        else echo "  sudo 권한은 root 로 실행하면 확인해요."; fi
        grep -q "^$ACC:" /etc/subuid 2>/dev/null && echo "  /etc/subuid 에 있어요(rootless 도커에 필요해요. 3단계 docker_install.sh 가 맞춰요)" ||
            echo "  /etc/subuid 에 아직 없어요(3단계 docker_install.sh 가 넣어요)"
    fi

    # 연결 옵션: nosuid·noexec 등
    echo; echo "  [연결 옵션]"
    for p in / "$APP" /home /tmp; do
        [ -d "$p" ] || continue
        echo "  $(pad "$p" 8) $(findmnt -no SOURCE,FSTYPE --target "$p" 2>/dev/null | head -1)  $(findmnt -no OPTIONS --target "$p" 2>/dev/null | head -1 | tr ',' '\n' | grep -E '^(ro|rw|nosuid|noexec|nodev)$' | tr '\n' ' ')"
    done
}

sec_programs() {
    head_ '서버 프로그램'
    # "명령:Ubuntu 패키지". 서버 화면(컨테이너 밖)에서 쓰는 프로그램은 관리자가 기초 프로그램 묶음(pkgs_install.sh)으로 설치한다.
    # docs/1_처음_설치.md 의 "서버 기초 프로그램" 목록, pc/pkgs_pack.ps1 과 같게 둔다(tests/run.sh 가 확인)
    local NEED=(bash:bash tar:tar sha256sum:coreutils awk:gawk sed:sed grep:grep perl:perl python3:python3 unzip:unzip
          runuser:util-linux setsid:util-linux findmnt:util-linux script:bsdutils)
    local WANT=(tmux:tmux screen:screen vim:vim nano:nano micro:micro less:less htop:htop btop:btop nvtop:nvtop iotop:iotop iostat:sysstat
          lsof:lsof strace:strace tree:tree ncdu:ncdu jq:jq bc:bc file:file rsync:rsync zip:zip 7z:p7zip-full pigz:pigz zstd:zstd
          xz:xz-utils pv:pv git:git git-lfs:git-lfs curl:curl wget:wget iperf3:iperf3 ethtool:ethtool ib_write_bw:perftest
          ibhosts:infiniband-diags ibv_devinfo:ibverbs-utils)
    local miss
    miss=$(lack "${NEED[@]}")
    [ -z "$miss" ] && ok "설치 스크립트에 필요한 명령이 모두 있어요" ||
        mine "설치 스크립트에 필요한 패키지가 없어요: $miss" "기초 프로그램 설치(docs/1_처음_설치.md 의 \"2단계: 서버 기초 프로그램\"): $miss"
    miss=$(lack "${WANT[@]}")
    [ -z "$miss" ] && ok "서버 화면에서 쓰는 프로그램(tmux, nvtop, rsync 등)이 모두 있어요" ||
        mine "서버 화면에서 쓰는 프로그램 중 없는 것: $miss" "기초 프로그램 설치(docs/1_처음_설치.md 의 \"2단계: 서버 기초 프로그램\"): $miss"
}
lack() { local p m=(); for p in "$@"; do command -v "${p%%:*}" >/dev/null || m+=("${p#*:}"); done; printf '%s\n' "${m[@]}" | grep . | sort -u | tr '\n' ' '; }

# ================================================================== 네트워크 카드
sec_nic() {
    head_ '네트워크 카드'
    command -v ip >/dev/null || warn 'ip 명령(iproute2)이 없어 주소와 경로를 못 봐요'
    echo "  $(pad 이름 16)$(pad 종류 16)$(pad 상태 8)$(pad 속도 11)$(pad MTU 7)IPv4"
    local d n p hca nd ndip
    for d in /sys/class/net/*; do
        [ -d "$d" ] || continue   # bonding_masters 같은 파일은 뺀다
        n=$(basename "$d")
        case "$n" in lo|docker*|veth*|br-*|ifb*|virbr*|cni*|flannel*|tap*|tun*) continue ;; esac   # 컨테이너·가상 카드는 뺀다
        nic_line "$n"
    done
    echo "  기본 경로: $(ip route show default 2>/dev/null | head -1)"
    [ -d /sys/class/infiniband ] || return 0
    head_ 'InfiniBand·RoCE (GPU 서버끼리 빠르게 주고받는 카드)'
    for p in /sys/class/infiniband/*/ports/*; do
        [ -e "$p/rate" ] || continue
        hca=$(basename "$(dirname "$(dirname "$p")")")
        nd=$(ls "/sys/class/infiniband/$hca/device/net" 2>/dev/null | head -1)
        ndip=$(ip -4 -br addr show "$nd" 2>/dev/null | awk '{print $3}')
        echo "  $(pad "$hca" 10)포트 $(basename "$p")  $(pad "$(cut -d: -f2 "$p/state" | tr -d ' ')" 8)$(pad "$(cat "$p/rate")" 22)$(pad "${nd:--}" 13)${ndip:-IP 없음}"
    done
    echo "  IP가 있는 포트는 NAS·IP 통신용이고, IP가 없는 포트는 보통 GPU 서버끼리 RDMA(CPU를 거치지 않고 메모리끼리 바로 주고받는 빠른 통신)로만 쓰는 포트예요. GPU 사이 통신 라이브러리인 NCCL 이 이 포트를 써요."
}

# ================================================================== NAS
sec_nas() {
    head_ 'NAS (네트워크 저장소)'
    local mounts m tgt src fs opts host ip NAS
    mapfile -t mounts < <(nas_mounts)
    if [ ${#mounts[@]} -eq 0 ]; then
        bad 'NAS로 연결된 폴더가 없어요' "두 서버 모두 NAS를 $(dirname "$TEAM") 에 연결해 주세요"
        return
    fi
    for m in "${mounts[@]}"; do
        read -r tgt src fs opts <<< "$m"
        echo "  $tgt  ←  $src  ($fs)"
        if [ "$fs" != - ]; then
            host=${src%%:*}; host=${host#//}; host=${host%%/*}
            ip=$(getent ahostsv4 "$host" 2>/dev/null | awk 'NR==1 {print $1}'); ip=${ip:-$host}
            echo "      쓰는 네트워크 카드: $(route_to "$ip")"
            echo "      옵션: $(echo "$opts" | tr ',' '\n' | grep -E '^(vers|proto|sec|rsize|wsize|nconnect|hard|soft|ro|rw|actimeo|lookupcache)=?' | tr '\n' ' ')"
            echo "$opts" | grep -q 'proto=rdma' && ok 'RDMA로 연결돼 있어요(빠른 방식)'
        fi
    done
    [ -d "$(dirname "$TEAM")" ] || bad "팀 폴더를 둘 NAS($(dirname "$TEAM"))가 연결돼 있지 않아요" "두 서버 모두 NAS를 $(dirname "$TEAM") 에 연결해 주세요"
    NAS=$(main_nas)

    head_ "NAS 용량 ($NAS)"
    df -hP "$NAS" | awk 'NR==2 {printf "  전체 %s, 쓴 것 %s, 남은 것 %s (%s 찼어요)\n", $2, $3, $4, $5}'
    df -iP "$NAS" 2>/dev/null | awk 'NR==2 && $2 > 0 {printf "  파일 수: 전체 %s, 쓴 것 %s (%s)\n", $2, $3, $5}'
    echo "  (NAS에 폴더별 할당량(quota)이 걸려 있으면, 그 폴더에서 df 로 본 '전체' 용량은 실제로는 할당량이에요)"

    head_ "$NAS 바로 아래 (주인·권한)"
    local n=0 d st uid gid mode
    read -r uid gid mode <<< "$(stat -c '%u %g %a' "$NAS")"
    echo "  $(pad "$NAS (NAS 최상위)" 26) 주인 $(pad "$(who_uid "$uid")" 24) 그룹 $(pad "$(grp_name "$gid")" 10) $(pad "$mode" 5) $(who_writes "$mode")"
    root_only "$NAS" || bad "NAS 최상위($NAS)를 root 말고도 고칠 수 있어요. 누구든 그 아래 폴더(팀 폴더, $NAS/tmp)를 옮기고 링크로 바꿔치기할 수 있어요. 그래서 root 로는 NAS 에 쓰지 않아요(이 점검의 NAS 속도 측정, 1단계 팀 폴더 만들기, 4·5단계 데이터셋·모델 넣기)" \
        "NAS 최상위($NAS)를 root 소유 755 로 해 주세요(지금 root 말고도 고칠 수 있어요). 다른 팀은 그 아래 각자 폴더를 쓰면 돼요"
    while IFS= read -r -d '' d; do
        n=$((n + 1)); [ "$n" -le 60 ] || continue
        st=$(stat -c '%u %g %a' "$d" 2>/dev/null) || continue
        read -r uid gid mode <<< "$st"
        echo "  $(pad "$(basename "$d")$([ -L "$d" ] && echo ' (링크)')$([ ! -L "$d" ] && [ ! -d "$d" ] && echo ' (파일)')" 26) 주인 $(pad "$(who_uid "$uid")" 24) 그룹 $(pad "$(grp_name "$gid")" 10) $(pad "$mode" 5) $(who_writes "$mode")"
    done < <(find "$NAS" -mindepth 1 -maxdepth 1 -print0 2>/dev/null | sort -z)
    [ "$n" -le 60 ] || echo "  ... 모두 ${n}개 중 60개만 보였어요"
    [ "$n" -gt 0 ] || warn "$NAS 아래를 읽지 못했어요(권한이 없거나 비어 있어요)"
    echo "  '이 서버에 없는 계정' 은 다른 팀 계정이거나, 두 서버의 계정 번호가 달라서 생겨요."

    head_ '계정 번호 (NFSv3 는 이름이 아니라 번호로 주인을 구분해요)'
    if id "$ACC" >/dev/null 2>&1; then echo "  우리 공용 계정 $ACC: uid $(id -u "$ACC"), gid $(id -g "$ACC")"; fi
    echo "  이 서버의 일반 계정(uid 1000 이상):"
    getent passwd | awk -F: '$3 >= 1000 && $3 < 60000 {printf "    %-16s uid %s\n", $1, $3}'
    echo "  두 서버의 공용 계정 번호가 같은지는 아래 '상대 서버 찾기' 에서 맞춰 봐요(속도 측정을 할 때)."

    head_ "우리 팀 폴더 ($TEAM)"
    if [ -L "$TEAM" ]; then
        bad "링크예요: $TEAM → $(readlink "$TEAM"). 1단계 prepare.sh 는 링크면 팀 폴더를 만들지 않아요"
    elif [ -d "$TEAM" ]; then
        read -r uid gid mode <<< "$(stat -c '%u %g %a' "$TEAM")"
        echo "  주인 $(who_uid "$uid"), 그룹 $(grp_name "$gid"), 권한 $mode ($(who_writes "$mode"))"
        local grp=${ACC:+$(id -gn "$ACC" 2>/dev/null)}
        [ "$uid" = 0 ] && [ $(( 8#$mode & 8#027 )) -eq 0 ] ||
            mine "팀 폴더가 root 소유 750 이 아니에요(주인 $(who_uid "$uid"), 권한 $mode). 팀원이 datasets·models 를 지우거나 바꿀 수 있고, 750 이 아니면 다른 팀도 읽어요" \
                 "NAS 최상위를 고친 뒤 팀 폴더 잠그기: chown root:${grp:-<공용 계정 그룹>} $TEAM && chmod 750 $TEAM (docs/8_NAS.md 의 '이미 있는 팀 폴더 잠그기')"
        local bad_sub=() s
        for s in datasets models originals; do
            [ -e "$TEAM/$s" ] || [ -L "$TEAM/$s" ] || continue
            # 안쪽 세 단계까지 root 소유이고 남이 못 쓰는지(링크는 권한이 없어서 뺀다). 처음 하나만 찾으면 멈춘다
            [ ! -L "$TEAM/$s" ] && [ -z "$(find "$TEAM/$s" -maxdepth 3 ! -type l \( ! -uid 0 -o -perm /022 \) -print -quit 2>/dev/null)" ] || bad_sub+=("$s")
        done
        [ ${#bad_sub[@]} -eq 0 ] ||
            mine "팀 폴더의 ${bad_sub[*]} 안에 root 소유가 아니거나 남이 쓸 수 있는 것이 있어요(팀원이 데이터셋·모델을 지우거나 바꿀 수 있어요)" \
                 "팀 폴더를 잠근 뒤 ${bad_sub[*]} 를 root 소유로: docs/8_NAS.md 의 '이미 있는 팀 폴더 잠그기'"
        df -hP "$TEAM" | awk 'NR==2 {printf "  여기서 본 용량: 전체 %s, 쓴 것 %s, 남은 것 %s (할당량이 있으면 할당량이에요)\n", $2, $3, $4}'
        if [ -r "$TEAM" ] && [ -x "$TEAM" ]; then
            for n in datasets models; do [ -n "$(ls -A "$TEAM/$n" 2>/dev/null)" ] && ok "$TEAM/$n 에 설치돼 있어요(두 서버가 같이 써요. 다시 올리지 않아도 돼요)"; done
            [ -n "$(ls -A "$TEAM/datasets" 2>/dev/null)$(ls -A "$TEAM/models" 2>/dev/null)" ] || echo "  데이터셋·모델은 아직 없어요(4·5단계에서 넣어요)"
            echo "  바로 아래:"; find "$TEAM" -mindepth 1 -maxdepth 1 -printf '    %f  (주인 uid %U, 권한 %m)\n' 2>/dev/null | sort | head -30
        else
            bad "$(id -un) 가 팀 폴더를 읽을 수 없어요. 그룹이 공용 계정인지, 두 서버의 공용 계정 번호가 같은지 확인하세요"
        fi
    else
        echo "  아직 없어요. 1단계 prepare.sh(root)가 만들어요(docs/8_NAS.md 의 '처음 만들기')."
    fi

    if id "$ACC" >/dev/null 2>&1; then
        head_ "공용 계정($ACC)이 쓸 수 있는 곳"
        for d in "$NAS" "$NAS/tmp" "$TEAM" "$TEAM/tmp_transfer" "$TEAM/backup"; do
            [ -d "$d" ] && { acc_writes "$d" && echo "  $d: 쓸 수 있어요" || echo "  $d: 쓸 수 없어요"; }
        done
    fi

    head_ 'root squash (root 가 NAS에서 누구로 보이는지)'
    if [ -z "$IS_ROOT" ]; then
        echo "  root 로 실행하면 확인해요. 1단계 prepare.sh 도 팀 폴더를 만들 때 확인해요."
    elif [ "$(stat -c %u "$NAS")" = 0 ] && [ -z "$(find "$NAS" -maxdepth 0 -perm /022)" ]; then
        # root 소유이고 남은 못 쓰는 NAS 최상위에 root 가 쓸 수 있는지만 NAS 에 물어본다(아무것도 만들지 않음)
        if [ -w "$NAS" ]; then
            warn "root 가 NAS에서도 root 예요(no_root_squash. root 소유 $NAS 에 root 가 쓸 수 있어요). 팀원이 쓸 수 있는 NAS 폴더에서는 root 로 작업하지 마세요"
        else
            ok "root 가 NAS에서는 다른 계정으로 바뀌어요(root squash. root 소유 $NAS 에 root 가 쓸 수 없어요)"
        fi
    else
        echo "  $NAS 가 root 소유(755)가 아니라서 확인하지 않았어요. 서버 관리 팀에 root squash 설정을 물어보세요."
    fi
}

# ================================================================== 서버 사이 속도(따로 잴 때)
PY_LISTEN='
import socket, sys, threading, time
port, streams, wait = int(sys.argv[1]), int(sys.argv[2]), int(sys.argv[3])
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("0.0.0.0", port)); s.listen(streams); s.settimeout(wait)
print(f"  {port}번 포트에서 기다려요(최대 {wait}초). 다른 서버에서 send 를 실행하세요.", flush=True)
total = [0]; lock = threading.Lock(); conns = []
def recv(c):
    n = 0; buf = bytearray(4 << 20); mv = memoryview(buf)
    while True:
        k = c.recv_into(mv)
        if not k: break
        n += k
    with lock: total[0] += n
try:
    c, a = s.accept()
except socket.timeout:
    print("  연결이 들어오지 않았어요(방화벽이나 네트워크 연결을 확인하세요)."); sys.exit(1)
t0 = time.time(); th = [threading.Thread(target=recv, args=(c,))]; th[0].start()
s.settimeout(3)
for _ in range(streams - 1):
    try: c2, _ = s.accept(); t = threading.Thread(target=recv, args=(c2,)); t.start(); th.append(t)
    except socket.timeout: break
for t in th: t.join()
dt = time.time() - t0
print(f"  {a[0]} 에서 동시 연결 {len(th)}개로 {total[0]/1e9:.1f} GB를 {dt:.1f}초에 받았어요: {total[0]/dt/1e9:.2f} GB/s ({total[0]/dt*8/1e9:.1f} Gbps)")
'
PY_SEND='
import socket, sys, time, multiprocessing as mp
host, port, streams, secs = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), float(sys.argv[4])
wait = float(sys.argv[5]) if len(sys.argv) > 5 else 0   # 받는 쪽이 아직 안 켜졌으면 이만큼 다시 시도
def send(q):
    deadline = time.time() + wait
    while True:
        try: c = socket.create_connection((host, port), timeout=10); break
        except OSError:
            if time.time() > deadline: q.put(0); return
            time.sleep(1)
    buf = memoryview(bytes(4 << 20)); n = 0; end = time.time() + secs
    while time.time() < end:
        c.sendall(buf); n += len(buf)
    c.close(); q.put(n)
q = mp.Queue(); ps = []
for i in range(streams):
    p = mp.Process(target=send, args=(q,)); p.start(); ps.append(p); time.sleep(0.05)
for p in ps: p.join()
tot = sum(q.get() for _ in ps)
if tot == 0: print(f"  {host}:{port} 에 연결하지 못했어요. 받는 쪽에서 listen 을 먼저 실행했는지, 방화벽이 막는지 확인하세요."); sys.exit(1)
print(f"  동시 연결 {streams}개로 {tot/1e9:.1f} GB를 {secs:.0f}초 동안 보냈어요: 약 {tot/secs/1e9:.2f} GB/s ({tot/secs*8/1e9:.1f} Gbps). 정확한 값은 받는 쪽 숫자를 보세요.")
'
cmd_listen() {
    if command -v iperf3 >/dev/null; then echo "  iperf3로 받을 준비를 했어요(한 번 측정하면 끝나요)"; exec iperf3 -s -1 -p "$PORT"; fi
    python3 -I -c "$PY_LISTEN" "$PORT" "$STREAMS" 120
}
cmd_send() {
    local to=${1:?받는 쪽 IP 를 적으세요: bash check.sh send 10.0.0.2}
    echo "  쓰는 네트워크 카드: $(route_to "$to"),  동시 연결 ${STREAMS}개, ${SECS}초"
    if command -v iperf3 >/dev/null; then exec iperf3 -c "$to" -p "$PORT" -P "$STREAMS" -t "$SECS"; fi
    python3 -I -c "$PY_SEND" "$to" "$PORT" "$STREAMS" "$SECS"
    echo "  (python으로 잰 값이라 100 Gbps 이상 카드에서는 실제보다 낮게 나올 수 있어요)"
}


cmd_disk() {
    local dir=${1:?폴더를 적으세요: bash check.sh disk /data/autonomy_sw/tmp_transfer} size_gb=${SIZE_GB:-4} t0 t1 b f
    [[ "$size_gb" =~ ^[0-9]+$ ]] && [ "$size_gb" -ge 1 ] || size_gb=4
    [ -d "$dir" ] && [ -w "$dir" ] || { bad "$dir 에 쓸 수 없어요(없거나 권한 없음)"; exit 1; }
    usable_dir "$dir" || { bad "root로 실행하면 다른 계정이 쓰는 폴더는 측정하지 않아요(그 위 폴더까지 root 만 고칠 수 있어야 해요): $dir. 같은 디스크의 root 폴더(예: /app/inbox)에서 측정하거나, 공용 계정으로 실행하세요"; exit 1; }
    local free; free=$(df -Pk "$dir" | awk 'NR==2 {print int($4/1048576)}')
    [ "$free" -gt $((size_gb * 2)) ] || { bad "남은 공간이 ${free} GB라서 시험 파일(${size_gb} GB)을 쓰기 어려워요"; exit 1; }
    local jobs=${JOBS:-1} i cnt
    [[ "$jobs" =~ ^[0-9]+$ ]] && [ "$jobs" -ge 1 ] || jobs=1
    # 시험 파일은 새로 만든 내 폴더 안에만 쓴다(남이 같은 이름의 링크를 심어 두어도 따라가지 않게)
    TD=$(mktemp -d "$dir/.gpu_speedtest.XXXXXX") || { bad "$dir 에 시험 폴더를 만들지 못했어요"; exit 1; }
    trap 'rm -rf "$TD"' EXIT   # TD 는 끝날 때 지우려고 전역
    f="$TD/t"
    cnt=$((size_gb * 64 / jobs)); [ "$cnt" -ge 1 ] || cnt=1; b=$((cnt * jobs * 16 * 1024 * 1024))
    echo "${c_c}[$(hostname)] $dir 속도 ($(df -P "$dir" | awk 'NR==2 {print $1}'), 시험 파일 합계 $((b >> 30)) GB, 동시에 파일 ${jobs}개)${c_0}"
    t0=$(date +%s.%N)
    for i in $(seq 1 "$jobs"); do
        { dd if=/dev/zero of="$f.$i" bs=16M count="$cnt" oflag=direct conv=fsync status=none 2>/dev/null ||
          dd if=/dev/zero of="$f.$i" bs=16M count="$cnt" conv=fsync status=none; } &
    done; wait
    t1=$(date +%s.%N); echo "  쓰기: $(rate "$b" "$(awk -v a="$t1" -v b="$t0" 'BEGIN{print a-b}')")"
    t0=$(date +%s.%N)
    for i in $(seq 1 "$jobs"); do
        { dd if="$f.$i" of=/dev/null bs=16M iflag=direct status=none 2>/dev/null || dd if="$f.$i" of=/dev/null bs=16M status=none; } &
    done; wait
    t1=$(date +%s.%N); echo "  읽기: $(rate "$b" "$(awk -v a="$t1" -v b="$t0" 'BEGIN{print a-b}')")"
    [ "$jobs" = 1 ] && [ -z "${FULL_MODE:-}" ] && echo "  (파일 하나로 측정한 값이에요. 여럿이 동시에 쓸 때 속도는 앞에 JOBS=8 을 붙여 측정하세요)"
}

# ================================================================== 속도(두 서버가 함께)
# 두 서버에서 각각 "bash check.sh" 를 실행한다. 같은 NAS 의 .gpu_net 폴더에 서로의 주소를 적어 두고,
# 짝이 보이면 서버 사이 속도를 양쪽에서 동시에 잰다(이더넷은 전이중이라 서로 방해하지 않는다). 짝이 없으면 혼자 잰다.
eth_ip() {   # 기본 경로 카드의 IP
    local dev; dev=$(ip route show default 2>/dev/null | grep -oP 'dev \K\S+' | head -1)
    { ip -4 -br addr show "$dev" 2>/dev/null | awk '{print $3}' | cut -d/ -f1; hostname -I 2>/dev/null | awk '{print $1}'; } | grep . | head -1
}
ib_ips() {   # InfiniBand 카드의 IP 들
    local d; for d in /sys/class/net/*; do
        [ "$(cat "$d/type" 2>/dev/null)" = 32 ] || continue
        ip -4 -br addr show "$(basename "$d")" 2>/dev/null | awk '{print $3}' | cut -d/ -f1
    done | grep . | tr '\n' ' '
}
active_hcas() {
    local p; for p in /sys/class/infiniband/*/ports/1; do
        grep -q ACTIVE "$p/state" 2>/dev/null && basename "$(dirname "$(dirname "$p")")"
    done | tr '\n' ' '
}
field() { grep -m1 "^$1=" "$2" 2>/dev/null | cut -d= -f2-; }   # 짝 정보 파일은 읽기만 한다(실행하지 않음)
# 짝 정보는 같은 NAS 를 쓰는 누구나 고칠 수 있는 파일에서 온다. 모양이 맞는 값만 쓴다
# (예: PORT 에 산술식을 넣으면 $(( )) 안에서 명령이 실행된다)
peer_ok() {
    local f=$1 ip='([0-9]{1,3}\.){3}[0-9]{1,3}'
    [[ "$(field HOST "$f")" =~ ^[A-Za-z0-9._-]{1,64}$ ]] &&
    [[ "$(field ETH "$f")" =~ ^$ip$ ]] &&
    [[ "$(field IB "$f")" =~ ^(($ip) ?)*$ ]] &&
    [[ "$(field HCAS "$f")" =~ ^([A-Za-z0-9_]+ ?)*$ ]] &&
    [[ "$(field PORT "$f")" =~ ^[0-9]{1,5}$ ]] &&
    [[ "$(field PERFTEST "$f")" =~ ^1?$ ]] &&
    [[ "$(field UID "$f")" =~ ^[0-9]*$ ]] &&
    [[ "$(field GID "$f")" =~ ^[0-9]*$ ]]
}
# 파일을 바로 쓰지 않고 새 임시 파일을 만든 뒤 이름을 바꾼다(그 자리에 링크가 있어도 링크를 따라가지 않는다)
put() {   # $1 경로, 내용은 표준 입력
    local t; t=$(mktemp "$(dirname "$1")/.tmp.XXXXXX") || return 1
    cat > "$t" && chmod 644 "$t" && mv -f "$t" "$1"   # 다른 서버(다른 계정일 수도)가 읽을 수 있게
}
gbs() { local v; v=$(grep -oE '[0-9.]+ GB/s \([0-9.]+ Gbps\)' | tail -1); [ -n "$v" ] && echo "$v"; }
wait_file() {   # $1 파일이 $2 파일보다 새것으로 생길 때까지 $3 초 기다린다
    local i; for i in $(seq 1 "$3"); do [ -f "$1" ] && [ ! "$1" -ot "$2" ] && return 0; sleep 1; done; return 1
}

pair_tcp() {   # $1 이름 $2 내 포트 $3 짝 IP $4 짝 포트
    local tmp; tmp=$(mktemp)
    python3 -I -c "$PY_LISTEN" "$2" "$STREAMS" 90 > "$tmp" 2>&1 &
    local lp=$!
    sleep 2
    local sent; sent=$(python3 -I -c "$PY_SEND" "$3" "$4" "$STREAMS" "$SECS" 60 2>&1)
    wait "$lp"
    local got; got=$(grep -v '기다려요' "$tmp"); rm -f "$tmp"
    echo "  보내기 → $3: $(echo "$sent" | gbs || echo '실패(연결하지 못했어요)')"
    echo "  받기 ← $3: $(echo "$got" | gbs || echo '실패(상대 서버가 보내지 못했어요)')"
    SUM+=("서버 사이 $1: 받기 $(echo "$got" | gbs || echo '실패'), 보내기 $(echo "$sent" | gbs || echo '실패')")
}

pair_rdma() {   # 같은 이름의 InfiniBand 카드끼리 RDMA 쓰기 속도(perftest). 연결 준비는 이더넷 IP 로 한다
    local role=$1 peer_eth=$2 hcas=$3 i=0 hca out bw
    for hca in $hcas; do
        i=$((i + 1))
        if [ "$role" = A ]; then
            out=$(timeout 45 ib_write_bw -d "$hca" -p $((18514 + i)) -D 5 -F --report_gbits 2>&1)
        else
            # 짝이 아직 안 켜졌으면(연결 거부) 다시 시도. 연결은 됐는데 실패하면 그 카드는 거기서 끝
            local t; for t in $(seq 1 60); do
                out=$(timeout 25 ib_write_bw -d "$hca" -p $((18514 + i)) -D 5 -F --report_gbits "$peer_eth" 2>&1) && break
                echo "$out" | grep -qi "couldn't connect" || break
                sleep 1
            done
        fi
        bw=$(echo "$out" | awk '/^ *[0-9]+ +[0-9]+ +[0-9.]+ +[0-9.]+/ {v=$4} END {if (v) print v}')
        if [ -n "$bw" ]; then
            echo "  $(pad "$hca" 10) $bw Gb/s"; SUM+=("RDMA $hca: $bw Gb/s")
        else
            echo "  $(pad "$hca" 10) 연결 안 됨 (같은 InfiniBand 망이 아니거나 막혀 있어요)"; SUM+=("RDMA $hca: 연결 안 됨")
        fi
    done
}

disk_both() {   # 파일 1개로 한 번, 8개를 동시에 한 번
    local name=$1 dir=$2 r1 r8
    r1=$( (JOBS=1 cmd_disk "$dir") 2>&1); echo "$r1"
    r8=$( (JOBS=8 cmd_disk "$dir") 2>&1); echo "$r8"
    SUM+=("$name 파일 1개: 쓰기 $(echo "$r1" | grep 쓰기 | gbs || echo 실패) / 읽기 $(echo "$r1" | grep 읽기 | gbs || echo 실패)")
    SUM+=("$name 동시 8개: 쓰기 $(echo "$r8" | grep 쓰기 | gbs || echo 실패) / 읽기 $(echo "$r8" | grep 읽기 | gbs || echo 실패)")
}

sec_speed() {
    local nas R peer='' pf role local_dir d
    NET_R=; NET_MINE=; NET_PINFO=; NET_KEEP=   # 끝날 때 지울 것(trap 이 함수 밖에서 읽으므로 전역)
    nas=$(nas_dir "${1:-}")
    R="$nas/.gpu_net"
    if [ -n "$nas" ] && [ -L "$R" ]; then
        warn "상대 서버 확인용 폴더가 링크라서 쓰지 않아요: $R (누가 만들었는지 확인하세요). 이 서버만 측정해요"; nas=
    fi
    if [ -n "$nas" ] && [ ! -d "$R" ]; then
        # root 는 root 만 쓰는 755, 공용 계정은 스티키 1777(두 서버의 계정 번호가 달라도 서로 쓰고, 남의 파일은 못 지운다)
        { mkdir -p "$R" && chmod "$([ -n "$IS_ROOT" ] && echo 755 || echo 1777)" "$R"; } 2>/dev/null
    fi
    # root 는 다른 계정이 만든 폴더에 쓰지 않는다(그 계정이 파일을 링크로 바꿔치기하면 root 가 이 서버의 파일을 덮는다)
    if [ -n "$nas" ] && [ -n "$IS_ROOT" ] && ! [[ "$(stat -c %u "$R" 2>/dev/null)" =~ ^(0|65534|4294967294)$ ]]; then
        warn "상대 서버 확인용 폴더를 다른 계정이 만들었어요: $R (주인 uid $(stat -c %u "$R")). 지우거나 그 계정으로 실행하세요. 이 서버만 측정해요"; nas=
    fi
    if [ -n "$nas" ]; then
        rm -f "$R/$ME".*
        NET_R=$R; NET_MINE="$R/$ME.info"
        # 끝나거나 중간에 멈추면 NAS 에 만든 것을 지운다(남아 있으면 다음에 한쪽만 실행해도 짝이 있는 줄 안다)
        trap net_cleanup EXIT; trap 'net_cleanup; exit 130' INT TERM
        { echo "HOST=$ME"; echo "ETH=${GPU_ETH:-$(eth_ip)}"; echo "IB=$(ib_ips)"; echo "HCAS=$(active_hcas)"
          echo "PORT=$PORT"; echo "PERFTEST=$(command -v ib_write_bw >/dev/null && echo 1)"
          echo "UID=$(id -u "$ACC" 2>/dev/null)"; echo "GID=$(id -g "$ACC" 2>/dev/null)"; } | put "$NET_MINE" ||
            { warn "상대 서버 확인용 파일을 쓰지 못했어요: $R. 이 서버만 측정해요"; nas=; }
    fi
    if [ -n "$nas" ]; then
        head_ "상대 서버 찾기 (NAS: $R)"
        echo "  다른 서버에서도 같은 점검을 실행하세요. 최대 $((WAIT_PEER / 60))분 기다려요."
        local i rejected=' '
        for i in $(seq 1 "$WAIT_PEER"); do
            for pf in "$R"/*.info; do
                [ -f "$pf" ] && [ ! -L "$pf" ] && [ "$pf" != "$NET_MINE" ] && [ -n "$(find "$pf" -mmin -30 2>/dev/null)" ] || continue
                case "$rejected" in *" $pf "*) continue ;; esac
                # 짝 정보는 지금 한 번 복사해 두고 그것만 쓴다(시각도 함께: 짝의 완료 표시가 이번 실행 것인지 가릴 때 쓴다)
                NET_PINFO=$(mktemp); cp -p "$pf" "$NET_PINFO"
                if peer_ok "$NET_PINFO"; then peer=$(field HOST "$NET_PINFO"); pf=$NET_PINFO; break 2; fi
                warn "상대 서버 정보 파일의 내용이 이상해서 쓰지 않아요: $pf"; rm -f "$NET_PINFO"; rejected+=" $pf "
            done
            [ $((i % 60)) = 0 ] && echo "  ...기다리는 중이에요($((i / 60))분)"
            sleep 1
        done
        # 공유용 사본에서 상대 서버 이름을 가리려면 이름이 필요하다. 상대가 먼저 끝나면 NAS 의 정보 파일이 지워지므로 따로 적어 둔다
        [ -n "$peer" ] && [ -n "${PEER_NOTE:-}" ] && echo "$peer" > "$PEER_NOTE"
        if [ -n "$peer" ]; then
            local pibs puid pgid muid mgid
            pibs=$(field IB "$pf"); ok "상대 서버: $peer (이더넷 $(field ETH "$pf"), InfiniBand ${pibs:-없음})"
            puid=$(field UID "$pf"); pgid=$(field GID "$pf"); muid=$(id -u "$ACC" 2>/dev/null); mgid=$(id -g "$ACC" 2>/dev/null)
            if [ -n "$puid" ] && [ -n "$muid" ]; then
                if [ "$puid" = "$muid" ] && [ "$pgid" = "$mgid" ]; then ok "두 서버의 공용 계정 번호가 같아요(uid $muid, gid $mgid)"
                else bad "두 서버의 공용 계정 번호가 달라요($ME: uid $muid gid $mgid, $peer: uid $puid gid $pgid). 한 서버에서 만든 NAS 파일을 다른 서버에서 못 고칠 수 있어요" \
                         "두 서버의 공용 계정 번호(uid·gid)를 같게 맞춰 주세요($ME: $muid/$mgid, $peer: $puid/$pgid)"; fi
            fi
        else warn '상대 서버를 찾지 못해서 이 서버만 측정해요'; fi
    else
        head_ '상대 서버 찾기'
        warn "NAS에 지금 계정이 쓸 수 있는 폴더가 없어서 상대 서버 찾기와 NAS 속도는 건너뛰어요."
        if [ -n "$IS_ROOT" ]; then echo "      root 는 그 폴더와 위 폴더가 모두 root 만 고칠 수 있을 때(root 소유이고 남이 못 쓰거나 스티키)만 써요. $(main_nas) 를 남도 고칠 수 있으면 위 'NAS 바로 아래' 의 [문제] 부터 고쳐요"
        else echo "      root 로 실행하거나, 1단계 prepare.sh 가 $TEAM/tmp_transfer 를 만든 뒤 다시 실행하거나, 쓸 수 있는 NAS 폴더를 적어 주세요: bash check.sh <폴더>"; fi
    fi

    if [ -n "$peer" ]; then
        # 이름이 앞서는 쪽이 A(RDMA 받는 쪽, NAS 먼저). 언어 설정과 상관없이 같은 결과가 나오게 C 순서로 비교한다
        role=B; [ "$(printf '%s\n%s\n' "$ME" "$peer" | LC_ALL=C sort | head -1)" = "$ME" ] && role=A
        local peth pib pport myib
        peth=$(field ETH "$pf"); pib=$(field IB "$pf" | awk '{print $1}'); pport=$(field PORT "$pf")
        head_ "서버 사이: 이더넷 ($ME ↔ $peer, 양쪽 동시에 ${SECS}초)"
        echo "  쓰는 네트워크 카드: $(route_to "$peth")"
        pair_tcp 이더넷 "$PORT" "$peth" "$pport"
        myib=$(ib_ips)
        if [ -n "$pib" ] && [ -n "$myib" ]; then
            head_ "서버 사이: InfiniBand로 IP 통신 (IPoIB, $pib)"
            echo "  쓰는 네트워크 카드: $(route_to "$pib")"
            pair_tcp IPoIB $((PORT + 1)) "$pib" $((pport + 1))
            echo "  (TCP로 잰 값이에요. 두 서버를 묶어 학습할 때 쓰는 RDMA 는 CPU를 거치지 않아 보통 이보다 빨라요. 아래 RDMA 값을 보세요)"
        fi
        head_ '서버 사이: RDMA (두 서버를 묶어 학습할 때 NCCL 이 쓰는 통신)'
        if command -v ib_write_bw >/dev/null && [ "$(field PERFTEST "$pf")" = 1 ]; then
            local common; common=$(comm -12 <(active_hcas | tr ' ' '\n' | grep . | sort) <(field HCAS "$pf" | tr ' ' '\n' | grep . | sort) | tr '\n' ' ')
            pair_rdma "$role" "$peth" "$common"
        else
            warn '양쪽에 perftest(ib_write_bw)가 있어야 측정할 수 있어요. 설치 방법: docs/4_네트워크.md 의 "InfiniBand 도구"'
            SUM+=("RDMA: perftest가 없어 측정 못 함")
        fi
        : | put "$R/$ME.netdone"; wait_file "$R/$peer.netdone" "$pf" 180 || true
    fi

    # 디스크: NAS 는 두 서버가 차례로(동시에 재면 나눠 가져서 값이 반이 된다). 로컬 SSD 는 /app 아래 써도 되는 폴더(root 는 /app/inbox)
    local_dir=; for d in "$APP/autonomy_sw" "$APP/upload" "$APP/inbox" "$APP"; do usable_dir "$d" && { local_dir=$d; break; }; done
    if [ -n "$peer" ] && [ "$role" = B ]; then
        [ -n "$local_dir" ] && { head_ "로컬 SSD ($local_dir)"; disk_both '로컬 SSD' "$local_dir"; }
        echo "  상대 서버($peer)가 NAS 측정을 마칠 때까지 기다려요..."; wait_file "$R/$peer.nasdone" "$pf" 900 || warn '상대 서버가 15분 안에 끝내지 않아서 기다리지 않고 넘어가요'
        head_ "NAS 속도 ($nas)"; disk_both NAS "$nas"
        : | put "$R/$ME.nasdone"; NET_KEEP=1   # 상대 서버가 이 표시를 본 뒤 지워 준다
    else
        if [ -n "$nas" ]; then head_ "NAS 속도 ($nas)"; disk_both NAS "$nas"; : | put "$R/$ME.nasdone"; fi
        [ -n "$local_dir" ] && { head_ "로컬 SSD ($local_dir)"; disk_both '로컬 SSD' "$local_dir"; }
        [ -n "$peer" ] && { wait_file "$R/$peer.nasdone" "$pf" 900 && rm -f "$R/$peer.nasdone"; }
    fi
    [ -n "$local_dir" ] || echo "  (로컬 SSD 속도는 쓸 수 있는 폴더가 있을 때만 재요. 공용 계정은 $APP/autonomy_sw 에, root 는 root 소유인 $APP/inbox 나 $APP 에 쓸 수 있어야 해요)"
}

# NAS 에 남긴 주소·완료 표시와 폴더를 지운다. 나중에 끝나는 쪽(B)의 NAS 완료 표시는 A 가 본 뒤 지운다
net_cleanup() {
    [ -n "${NET_R:-}" ] || return 0
    rm -f "$NET_MINE" "$NET_PINFO" "$NET_R/$ME.netdone"
    [ -n "$NET_KEEP" ] || rm -f "$NET_R/$ME.nasdone"
    rmdir "$NET_R" 2>/dev/null
    return 0
}

# InfiniBand 망: 카드마다 어떤 서버·장비가 보이나(같은 망인지). ibhosts 는 보통 root 만 쓸 수 있다(/dev/infiniband/umad*)
sec_ibnet() {
    [ -n "$(active_hcas)" ] || return 0
    head_ 'InfiniBand 망에 보이는 장비 (카드별)'
    if ! command -v ibhosts >/dev/null; then
        echo "  ibhosts(infiniband-diags)가 없어서 못 봐요. 위 RDMA 측정이 되면 같은 망이에요."; return 0
    fi
    local hca devs seen got=
    for hca in $(active_hcas); do
        devs=$(ibhosts -C "$hca" -P 1 2>/dev/null | grep -oP '"\K[^"]+' | awk '{print $1}' | sort -u)
        [ -n "$devs" ] || continue
        got=1
        seen=; [ -s "${PEER_NOTE:-/nonexistent}" ] && echo "$devs" | grep -qxF "$(head -1 "$PEER_NOTE")" && seen=', 상대 서버가 보여요(같은 망)'
        echo "  $(pad "$hca" 10) 장비 $(echo "$devs" | grep -c .)대$seen"
        echo "    장비: $(echo "$devs" | tr '\n' ' ')"
    done
    [ -n "$got" ] || echo "  조회하지 못했어요(ibhosts 는 보통 root 만 돼요). 위 RDMA 측정이 되면 같은 망이에요. 꼭 보려면 root 로: ibhosts -C <카드> -P 1"
}

body() {
    echo "${c_c}[GPU 서버] 점검  ($(date '+%Y-%m-%d %H:%M'), $(hostname), $(id -un))${c_0}"
    sec_os; sec_gpu; sec_storage; sec_dirs; sec_programs; sec_nic; sec_nas
    if [ -n "${QUICK:-}" ]; then head_ '속도'; echo "  QUICK=1 로 실행해서 속도 측정은 건너뛰었어요."
    else sec_speed "$@"; fi
    sec_ibnet
    if [ ${#SUM[@]} -gt 0 ]; then head_ '속도 요약'; printf '  %s\n' "${SUM[@]}"; fi

    echo
    if [ ${#ASK[@]} -eq 0 ] && [ ${#MINE[@]} -eq 0 ]; then
        echo "${c_g}######## 모두 정상이에요. 설치를 시작해도 돼요 (docs/1_처음_설치.md 1단계) ########${c_0}"
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
        echo " 고친 뒤 다시 점검하세요: bash $(readlink -f "$0")"
    fi
}

# ================================================================== 보고서
# 보고서 둘 곳: root 는 root 만 보는 새 임시 폴더(다 쓴 뒤 공용 계정 홈으로 옮긴다), 그 밖에는 실행한 폴더(내 것일 때)나 홈.
# 남이 쓸 수 있는 폴더에는 쓰지 않는다(링크로 다른 파일을 덮게 만들 수 있다)
report_dir() {
    local d
    [ -n "$IS_ROOT" ] && { mktemp -d; return; }
    for d in "$PWD" "$HOME"; do [ -d "$d" ] && [ -O "$d" ] && [ -w "$d" ] && { echo "$d"; return; }; done
    mktemp -d
}
# root: 보고서를 공용 계정 홈에 공용 계정 권한으로 넣는다. 홈은 공용 계정이 고칠 수 있는 곳이라 root 가 직접 쓰면
# 심어 둔 링크를 따라 다른 파일을 덮을 수 있다. 공용 계정 권한으로 쓰면 그런 일이 없고, 파일 주인도 공용 계정이 된다
to_acc_home() {   # 파일들 → 넣은 폴더를 출력. 못 넣으면 1
    local home f
    id "$ACC" >/dev/null 2>&1 || return 1
    home=${GPU_ACC_HOME:-$(getent passwd "$ACC" | cut -d: -f6)}   # GPU_ACC_HOME 은 시험할 때만
    [ -n "$home" ] && [ -d "$home" ] || return 1
    for f in "$@"; do
        setsid -w runuser -u "$ACC" -- sh -c 'umask 022; cat > "$1"' _ "$home/$(basename "$f")" < "$f" 2>/dev/null || return 1
    done
    echo "$home"
}
# 공유용 사본: 서버 이름·IP·NAS 주소·계정·폴더 이름을 가려서 git 으로 올려도 되게 만든다.
# $1 원본, $2 사본, 나머지는 "가릴말=바꿀말". IP 는 처음 나온 순서대로 IP-1, IP-2 … 로 바꿔 같은 IP 는 같은 번호가 된다
share_copy() {
    local src=$1 dst=$2; shift 2
    perl -Mutf8 -CSDA -ne '
        BEGIN { for (@ARGV) { my ($k, $v) = split /=/, $_, 2; $m{$k} //= $v if length($k) >= 2 }
                @ARGV = (); $re = join "|", map { quotemeta } sort { length($b) <=> length($a) } keys %m; $n = 0 }
        sub w { my $n = 0; $n += $_ =~ /[\x{1100}-\x{115F}\x{2E80}-\x{A4CF}\x{AC00}-\x{D7A3}\x{F900}-\x{FAFF}\x{FF00}-\x{FF60}]/ ? 2 : 1 for split //, $_[0]; $n }   # 화면 폭(한글 두 칸)
        sub max { $_[0] > $_[1] ? $_[0] : $_[1] }
        next if /^\s*장비: /;                                  # InfiniBand 망의 장비 이름(다른 팀 장비일 수 있음)
        # 한 번에 바꾼다(바꾼 말을 다시 바꾸지 않게). 뒤에 칸을 맞춘 빈칸이 있으면 원래 칸 너비로 다시 채워 원래 이름 길이가 드러나지 않게 한다
        s{($re)(\(\d+\))?( {2,})?}{ my ($k, $u, $sp) = ($1, $2 // "", $3); $m{$k} . $u . (defined $sp ? " " x max(1, w($k) + length($sp) - w($m{$k})) : "") }ge if length $re;
        s{\b[\w.-]+:/[\w./-]*}{NAS주소}g;
        s{\b((?:\d{1,3}\.){3}\d{1,3})(?:/\d+)?\b}{ $ip{$1} //= "IP-" . ++$n }ge;
        print;
    ' "$@" < "$src" > "$dst"
    chmod 644 "$dst" 2>/dev/null
}
cmd_full() {
    FULL_MODE=1
    local label rdir out share masks i n u d f h nasd
    label="서버(…$(hostname -s | tail -c 3))"   # 공유용 사본에서 이 서버를 부르는 이름(이름 끝 두 글자만)
    rdir=$(report_dir)
    out=$(mktemp "$rdir/check_report_${ME}_$(date +%Y%m%d-%H%M)_XXXX.txt") || out=$(mktemp)
    PEER_NOTE=$(mktemp)
    body "$@" 2>&1 | tee >(sed 's/\x1b\[[0-9;]*m//g' > "$out")
    sleep 1
    chmod 644 "$out" 2>/dev/null   # 공용 계정(FileZilla)으로 내려받을 수 있게
    # 가릴 것: 이 서버·상대 서버 이름, 공용 계정과 사람 계정 이름(홈 경로에도 나와요), NAS 바로 아래 폴더 이름(다른 팀 이름일 수 있음)
    masks=("$(hostname -f 2>/dev/null)=$label" "$(hostname 2>/dev/null)=$label" "$ME=$label" "$ACC=공용계정")
    i=0; while IFS=: read -r n _ u _; do [ "$u" -ge 1000 ] && [ "$u" -lt 60000 ] && [ "$n" != "$ACC" ] && { i=$((i + 1)); masks+=("$n=계정$i"); }; done < <(getent passwd)
    nasd=$(main_nas)
    # 흔한 이름(tmp, backup 처럼 시스템 폴더나 이 스크립트에 나오는 말)은 사내 정보가 아니고, 가리면 /tmp 같은 경로까지 바뀌어 보고서를 못 읽는다
    common() { [ -e "/$1" ] || [ -e "/var/$1" ] || [ -e "/usr/$1" ] || grep -qwF -- "$1" "${BASH_SOURCE[0]}" 2>/dev/null; }
    i=0; [ -n "$nasd" ] && for d in "$nasd"/*/; do n=$(basename "$d"); case "$n" in tmp|data|home|"$(basename "$TEAM")"|'*') continue ;; esac; common "$n" && continue; i=$((i + 1)); masks+=("$n=폴더$i"); done 2>/dev/null
    i=0; for d in "$APP"/* "$APP"/.[!.]* /home/*; do
        [ -e "$d" ] || [ -L "$d" ] || continue; n=$(basename "$d")
        case "$n" in admin|autonomy_sw|inbox|upload|docker|state|shared|workspace|lost+found|.shared_old_*|.admin_old_*|"$ACC") continue ;; esac
        common "$n" && continue
        getent passwd "$n" >/dev/null && continue   # 계정 이름은 위에서 가렸다
        i=$((i + 1)); masks+=("$n=서버폴더$i")
    done 2>/dev/null
    for f in "$PEER_NOTE" "$(nas_dir "${1:-}")"/.gpu_net/*.info; do
        if [ "$f" = "$PEER_NOTE" ]; then h=$(head -1 "$f"); else h=$(field HOST "$f"); fi
        [[ "$h" =~ ^[A-Za-z0-9._-]{2,64}$ ]] && [ "$h" != "$ME" ] && masks+=("$h=상대서버(…${h: -2})")
    done 2>/dev/null
    share="$rdir/check_공유용_${label//[^A-Za-z0-9]/}_$(date +%Y%m%d-%H%M).txt"
    share_copy "$out" "$share" "${masks[@]}"
    rm -f "$PEER_NOTE"
    if [ -n "$IS_ROOT" ]; then
        local home
        if home=$(to_acc_home "$out" "$share"); then
            rm -rf "$rdir"; out="$home/$(basename "$out")"; share="$home/$(basename "$share")"
        else
            echo; warn "공용 계정 홈에 보고서를 넣지 못해서 root 만 보는 곳에 남겼어요: $rdir"
        fi
    fi
    echo; echo "보고서(원본, 사내 정보 있음): $(readlink -f "$out")"
    echo "보고서(공유용, git 으로 올려도 돼요): $share"
    echo "  공유용만 내려받아 저장소의 reports 폴더에 넣고 올리세요(docs/4_네트워크.md 의 \"결과 가져오기\")."
}

case "${1:-}" in
    listen) cmd_listen ;;
    send)   shift; cmd_send "$@" ;;
    disk)   shift; cmd_disk "$@" ;;
    -h|--help|help) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0" ;;
    *)      [ -z "${1:-}" ] || [ -d "$1" ] || { echo "모르는 명령이에요: $1 (쓰는 법: bash check.sh --help)"; exit 1; }
            cmd_full "$@" ;;
esac
