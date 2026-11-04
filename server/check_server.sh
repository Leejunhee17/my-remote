#!/usr/bin/env bash
# [GPU 서버] OS를 새로 설치한 직후, 반입 전에 서버 상태를 점검한다. root 없이 되고 아무것도 바꾸지 않는다.
#   bash check_server.sh
# 결과의 [문제] 줄은 서버 관리 팀에 요청할 내용이다.
# 결과는 /app/inbox/reports/server_report_<서버>_<시각>.txt(원본)와 사내 정보를 가린 server_공유용_….txt 에도 남긴다(root 일 때).
set -uo pipefail
c_g=$'\e[32m'; c_y=$'\e[33m'; c_r=$'\e[31m'; c_c=$'\e[36m'; c_0=$'\e[0m'
ok()   { echo "  ${c_g}[정상]${c_0} $*"; }
warn() { echo "  ${c_y}[주의]${c_0} $*"; }
ASK=(); MINE=()
bad()  { echo "  ${c_r}[문제]${c_0} $1"; ASK+=("$2"); }    # 서버 관리 팀에 요청할 것
mine() { echo "  ${c_r}[문제]${c_0} $1"; MINE+=("$2"); }   # 관리자가 직접 할 것
ACC=${GPU_ACCOUNT:-$(cat /etc/gpu/account 2>/dev/null)}   # 공용 계정 이름은 서버의 /etc/gpu/account 한 곳에 적는다
ver_ge() { [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -1)" = "$2" ]; }
APP=${APP:-/app}
ME=$(hostname -s)

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

body() {
echo "${c_c}[GPU 서버] 점검  ($(date '+%Y-%m-%d %H:%M'), $(hostname), $(id -un))${c_0}"

echo; echo "${c_c}== 운영체제 ==${c_0}"
os=$(. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME")
echo "  $os, 커널 $(uname -r)"
case "$os" in Ubuntu*) ;; *) warn "Ubuntu가 아니에요($os). 설치 스크립트는 Ubuntu 24.04 기준이에요(22.04도 돼요)" ;; esac
if [ -z "$ACC" ]; then mine "공용 계정 이름을 알 수 없어요" "서버에 한 번 적어 두기: mkdir -p /etc/gpu && echo <계정이름> > /etc/gpu/account"
elif id "$ACC" >/dev/null 2>&1; then ok "공용 계정($ACC)이 있어요"; else
    bad "공용 계정이 없어요: $ACC (이름을 잘못 적었으면 /etc/gpu/account 를 고치세요)" "팀원 공용 계정($ACC)을 예전과 같은 이름으로 만들어 주세요(sudo·docker 그룹 없이)"; fi

echo; echo "${c_c}== GPU ==${c_0}"
if command -v nvidia-smi >/dev/null && nvidia-smi -L >/dev/null 2>&1; then
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
else
    bad "nvidia-smi가 없거나 GPU를 못 봐요" "NVIDIA 드라이버 580 이상(open 커널 모듈)을 설치해 주세요(HGX 보드면 nvidia-fabricmanager 도)"
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
    # /app 은 root 소유로 둔다(admin_setup.sh 가 잠근다). 팀원은 그 아래 /app/autonomy_sw 에 쓴다
    owner=$(stat -c %U "$APP")
    if [ "$owner" = root ]; then ok "$APP 주인이 root예요(팀원은 $APP/autonomy_sw 에 써요)"
    else warn "$APP 주인: $owner. 1단계에서 root로 admin_setup.sh 를 실행하면 root 소유로 잠가요"; fi
    if [ -d "$APP/autonomy_sw" ] && [ ! -w "$APP/autonomy_sw" ]; then
        mine "$APP/autonomy_sw 에 쓸 수 없어요" "root로 다시 실행하기: bash /app/inbox/admin_setup.sh (공용 계정 소유로 맞춰요)"
    fi
    [ -e "$APP/shared" ] && warn "$APP/shared 가 남아 있어요(예전 설치). admin_setup.sh 가 명단·설정만 $APP/admin 으로 옮기고 나머지는 치워요. 예전 데이터셋·모델을 NAS로 옮기는 명령도 알려 줘요"
else
    bad "$APP 폴더가 없어요" "2 TB SSD를 $APP 에 연결해 주세요(주인은 root 그대로)"
fi

echo; echo "${c_c}== NAS 팀 폴더 ==${c_0}"
NAS=$(sed -n 's/^NAS_DIR=\([^ #]*\).*/\1/p' "$APP/admin/gpu.conf" 2>/dev/null | tail -1); NAS=${NAS:-/data/autonomy_sw}
if [ ! -d "$(dirname "$NAS")" ]; then bad "NAS($(dirname "$NAS"))가 연결돼 있지 않아요" "두 서버 모두 NAS를 $(dirname "$NAS") 에 연결해 주세요"
elif [ -d "$NAS" ]; then
    for n in datasets models; do [ -n "$(ls -A "$NAS/$n" 2>/dev/null)" ] && ok "$NAS/$n 에 설치돼 있어요(두 서버가 같이 써요. 다시 올리지 않아도 돼요)"; done
    [ -n "$(ls -A "$NAS/datasets" 2>/dev/null)$(ls -A "$NAS/models" 2>/dev/null)" ] || echo "  $NAS 는 있지만 데이터셋·모델은 아직 없어요(3·4단계)"
else echo "  $NAS 는 아직 없어요. 1단계 admin_setup.sh 가 만들어요"; fi

echo; echo "${c_c}== 서버 프로그램 ==${c_0}"
# "명령:Ubuntu 패키지". 서버 화면(컨테이너 밖)에서 쓰는 프로그램은 OS 에 설치해 달라고 한다. docs/1_처음_설치.md 의 요청 목록과 같게 둔다
NEED=(bash:bash tar:tar sha256sum:coreutils awk:gawk sed:sed grep:grep perl:perl python3:python3 unzip:unzip
      runuser:util-linux setsid:util-linux findmnt:util-linux script:bsdutils)
WANT=(tmux:tmux screen:screen vim:vim nano:nano micro:micro less:less htop:htop btop:btop nvtop:nvtop iotop:iotop iostat:sysstat
      lsof:lsof strace:strace tree:tree ncdu:ncdu jq:jq bc:bc file:file rsync:rsync zip:zip 7z:p7zip-full pigz:pigz zstd:zstd
      xz:xz-utils pv:pv git:git git-lfs:git-lfs curl:curl wget:wget iperf3:iperf3 ethtool:ethtool ib_write_bw:perftest
      ibhosts:infiniband-diags ibv_devinfo:ibverbs-utils)
lack() { local p m=(); for p in "$@"; do command -v "${p%%:*}" >/dev/null || m+=("${p#*:}"); done; printf '%s\n' "${m[@]}" | grep . | sort -u | tr '\n' ' '; }
miss=$(lack "${NEED[@]}")
[ -z "$miss" ] && ok "설치 스크립트에 필요한 명령이 모두 있어요" ||
    bad "설치 스크립트에 필요한 패키지가 없어요: $miss" "패키지 설치: apt install $miss"
miss=$(lack "${WANT[@]}")
[ -z "$miss" ] && ok "서버 화면에서 쓰는 프로그램(tmux, nvtop, rsync 등)이 모두 있어요" ||
    bad "서버 화면에서 쓰는 프로그램 중 없는 것: $miss" "패키지 설치: apt install $miss"

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
}

# 보고서 둘 곳: root 는 /app/inbox/reports(root 만 고치고 공용 계정 FileZilla로 내려받을 수 있음),
# 그 밖에는 실행한 폴더(내 것일 때)나 홈. 남이 쓸 수 있는 폴더에는 쓰지 않는다(링크로 다른 파일을 덮게 만들 수 있다)
report_dir() {
    local ib=${GPU_INBOX:-/app/inbox}   # 시험할 때만 바꾼다
    if [ "$(id -u)" = 0 ] && [ -d "$ib" ] && [ ! -L "$ib" ] && [ "$(stat -c %U "$ib")" = root ]; then
        mkdir -p "$ib/reports" && [ ! -L "$ib/reports" ] && chmod 755 "$ib/reports" && echo "$ib/reports" && return
    fi
    if [ -O . ] && [ -w . ]; then echo "$PWD"; else echo "$HOME"; fi
}
# 공유용 사본(check_network.sh, check_nas.sh 와 같음): 서버 이름·IP·NAS 주소·계정·폴더 이름을 가려서 git 으로 올려도 되게 만든다.
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
LABEL="서버(…$(hostname -s | tail -c 3))"   # 공유용 사본에서 이 서버를 부르는 이름(이름 끝 두 글자만)
RDIR=$(report_dir)
out=$(mktemp "$RDIR/server_report_${ME}_$(date +%Y%m%d-%H%M)_XXXX.txt" 2>/dev/null) || out=$(mktemp)
body 2>&1 | tee >(sed 's/\x1b\[[0-9;]*m//g' > "$out")
sleep 1
chmod 644 "$out" 2>/dev/null   # 공용 계정(FileZilla)으로 내려받을 수 있게
# 공유용 사본: 서버 이름, 공용 계정과 사람 계정 이름(실행한 계정, 홈 경로에 나와요)을 가린다
masks=("$(hostname -f 2>/dev/null)=$LABEL" "$(hostname 2>/dev/null)=$LABEL" "$ME=$LABEL")
[ -n "$ACC" ] && masks+=("$ACC=공용계정")
i=0; while IFS=: read -r n _ u _; do [ "$u" -ge 1000 ] && [ "$u" -lt 60000 ] && [ "$n" != "$ACC" ] && { i=$((i + 1)); masks+=("$n=계정$i"); }; done < <(getent passwd)
share="$RDIR/server_공유용_${LABEL//[^A-Za-z0-9]/}_$(date +%Y%m%d-%H%M).txt"
share_copy "$out" "$share" "${masks[@]}"
echo; echo "보고서(원본, 사내 정보 있음): $(readlink -f "$out")"
echo "보고서(공유용, git 으로 올려도 돼요): $share"
echo "  공유용만 내려받아 저장소의 reports 폴더에 넣고 올리세요(docs/4_네트워크.md 의 \"결과 가져오기\")."
