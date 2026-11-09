#!/usr/bin/env bash
# [GPU 서버 · 관리자(root) 전용] gpu-pkgs.tar 로 서버 화면에서 쓰는 기초 프로그램(tmux, nvtop, rsync 등)을 설치한다.
#   cd /app/inbox && tar xf gpu-pkgs.tar && bash pkgs_install.sh
# 서버에 인터넷이 없어서, 묶음 안의 .deb 로 임시 apt 저장소를 만들어 없는 프로그램만 설치한다.
# 의존 순서는 apt 가 맞춘다. 서버의 apt 저장소 설정과 목록(/etc/apt, /var/lib/apt/lists)은 건드리지 않는다.
set -uo pipefail
cd "$(dirname "$0")"
HERE=$PWD
LOGD=${GPU_LOG_DIR:-/var/log/gpu}   # GPU_LOG_DIR: 시험할 때만 바꾼다(tests/run.sh)
LOG=$LOGD/pkgs_install_$(date +%Y%m%d_%H%M%S).log
mkdir -p "$LOGD" 2>/dev/null && exec > >(tee -a "$LOG") 2>&1
T=4
c_g=$'\e[32m'; c_y=$'\e[33m'; c_r=$'\e[31m'; c_c=$'\e[36m'; c_0=$'\e[0m'
step() { echo; echo "${c_c}==== [$1/$T] $2 ====${c_0}"; }
ok()   { echo "  ${c_g}[정상]${c_0} $*"; }
warn() { echo "  ${c_y}[주의]${c_0} $*"; }
stop() {
    echo; echo "${c_r}################ 멈춤 ################${c_0}"
    echo "${c_r}멈춘 이유: $1${c_0}"; echo "할 일: $2"
    echo "고친 뒤 같은 명령을 다시 실행하세요: cd $HERE && bash pkgs_install.sh"; echo "기록 파일: $LOG  (해결이 안 되면 docs/7_문제_해결.md)"
    exit 1
}
info() { sed -n "s/^$1=//p" pkgs_info.txt; }
installed() { [ "$(dpkg-query -W -f='${db:Status-Status}' "$1" 2>/dev/null)" = installed ]; }
# 폴더와 그 위의 모든 폴더가 root 소유이고 root 만 쓸 수 있는지(스티키 폴더는 바꿔치기를 못 해서 괜찮다). prepare.sh 와 같음
safe_dir() {
    local p m; p=$(readlink -f "$1") && [ -d "$p" ] || return 1
    while :; do
        m=$(stat -c '%u %a' "$p") || return 1
        [ "${m%% *}" = 0 ] || return 1
        [ $(( 8#${m##* } & 8#1000 )) -ne 0 ] || [ $(( 8#${m##* } & 8#022 )) -eq 0 ] || return 1
        [ "$p" = / ] && return 0; p=$(dirname "$p")
    done
}

echo "[GPU 서버] 기초 프로그램 설치  ($(date '+%Y-%m-%d %H:%M'))"

# ------------------------------------------------------------------ 1. 점검
step 1 '점검'
[ "$(id -u)" = 0 ] || stop 'root 계정이 아니에요' 'HIWARE에서 root로 접속해(PuTTY) 다시 실행하세요.'
command -v apt-get >/dev/null && command -v dpkg-query >/dev/null || stop 'apt-get 이 없어요(Ubuntu 가 아니에요)' '이 묶음은 Ubuntu 24.04 용이에요. 운영체제를 확인하세요: cat /etc/os-release'
# 공용 계정이 체크섬을 확인한 뒤에 .deb 를 바꿔치기하지 못하게, 이 폴더와 그 위가 root 만 고칠 수 있는 곳이어야 한다
safe_dir "$HERE" || stop "$HERE 나 그 위 폴더를 root 말고도 고칠 수 있어요" '묶음은 root 만 고치는 /app/inbox 에 풀어요. 준비를 먼저 하세요: cd /app/inbox && bash prepare.sh'
for f in MANIFEST_pkgs.sha256 pkgs_info.txt debs/Packages; do [ -f "$f" ] || stop "묶음 안의 파일이 없어요: $f" "묶음을 풀었는지 확인하세요: cd $HERE && tar xf gpu-pkgs.tar"; done
[ -z "$(find debs -type l -print -quit)" ] || stop '묶음 안에 링크가 있어요' '접근 PC에서 pkgs_pack.ps1 로 새 묶음을 만들어 다시 올리세요.'
chmod -R go-w debs MANIFEST_pkgs.sha256 pkgs_info.txt   # 윈도우에서 묶은 tar 는 누구나 쓸 수 있는 권한으로 풀릴 수 있다
# 목록이 비었거나 모양이 다른 줄이 있으면 sha256sum 은 그 줄을 건너뛰고 "맞음"이 될 수 있어 따로 본다
[ "$(grep -c . MANIFEST_pkgs.sha256)" -gt 0 ] && ! grep -v '^$' MANIFEST_pkgs.sha256 | grep -qvE '^[0-9a-f]{64}  [^/].*$' ||
    stop "체크섬 목록(MANIFEST_pkgs.sha256)이 비었거나 모양이 이상해요" "접근 PC에서 pkgs_pack.ps1 을 다시 실행해 새 묶음을 올리세요."
bad=$(sha256sum -c --quiet --strict MANIFEST_pkgs.sha256 2>/dev/null | sed 's/: .*//'); rc=$?
[ "$rc" = 0 ] || [ -n "$bad" ] || stop '체크섬을 확인하지 못했어요' "묶음을 /app/upload 에 다시 올려 새로 들여온 뒤 다시 실행하세요. 기록 파일: $LOG"
[ -z "$bad" ] || { echo "$bad" | sed 's/^/    깨진 파일: /'; stop '올리는 중에 파일이 깨졌어요' '접근 PC의 pack_pkgs\gpu-pkgs.tar 를 /app/upload 에 다시 올리고, /app/inbox 로 새로 복사해 지문을 확인한 뒤 다시 푸세요.'; }
# 목록에 없는 .deb 가 섞여 있으면 apt 저장소 목록(Packages)에는 없어서 쓰이지 않지만, 누가 넣은 것이라 멈춘다
extra=$(comm -13 <(sed -n 's/^[0-9a-f]\{64\}  //p' MANIFEST_pkgs.sha256 | sort) <(find debs -type f | sort))
[ -z "$extra" ] || { echo "$extra" | head -5 | sed 's/^/    목록에 없는 파일: /'; stop '체크섬 목록에 없는 파일이 debs 폴더에 있어요' "cd /app/inbox && rm -rf debs && tar xf gpu-pkgs.tar 로 새로 푼 뒤 다시 실행하세요."; }
ok "파일 체크섬이 맞아요 (.deb $(info debs)개, $(info made) 에 만든 묶음)"
CODE=$(. /etc/os-release && echo "${VERSION_CODENAME:-}")
ok "운영체제 $(. /etc/os-release && echo "$PRETTY_NAME")"
[ "$CODE" = "$(info ubuntu)" ] || stop "이 묶음은 Ubuntu $(info ubuntu) 용인데 이 서버는 ${CODE:-알 수 없음}이에요" 'pc\pkgs_pack.ps1 의 $Code 를 서버 버전에 맞게 고쳐 새 묶음을 만드세요.'

# ------------------------------------------------------------------ 2. 설치할 것 고르기
step 2 '설치할 것 고르기'
read -ra PKGS <<< "$(info pkgs)"
[ ${#PKGS[@]} -gt 0 ] || stop 'pkgs_info.txt 에 프로그램 목록이 없어요' '접근 PC에서 pkgs_pack.ps1 을 다시 실행해 새 묶음을 올리세요.'
need=(); have=(); skip=()
for p in "${PKGS[@]}"; do
    if installed "$p"; then have+=("$p")
    # InfiniBand 드라이버 묶음(DOCA-OFED·MLNX_OFED)이 있으면 IB 도구도 그 묶음 것을 써요(Ubuntu 것과 섞으면 충돌할 수 있어요)
    elif command -v ofed_info >/dev/null && [[ " perftest infiniband-diags ibverbs-utils " == *" $p "* ]]; then skip+=("$p")
    else need+=("$p"); fi
done
[ ${#have[@]} -gt 0 ] && ok "이미 있어요(${#have[@]}개): ${have[*]}"
[ ${#skip[@]} -gt 0 ] && warn "InfiniBand 드라이버 묶음($(ofed_info -s 2>/dev/null | tr -d ':'))이 있어서 건너뛰어요: ${skip[*]}. 이 도구는 드라이버 묶음에서 설치하세요."

# ------------------------------------------------------------------ 3. 설치
step 3 "설치 (${#need[@]}개)"
if [ ${#need[@]} -eq 0 ]; then
    ok '설치할 것이 없어요'
else
    echo "  설치할 것: ${need[*]}"
    # 임시 apt 저장소: 이 묶음의 debs 폴더만 보고, 목록·캐시도 임시 폴더에 둔다(서버의 apt 설정과 목록은 그대로)
    W=$(mktemp -d) || stop '임시 폴더를 만들지 못했어요' '남은 공간을 확인하세요: df -h /tmp'
    trap 'rm -rf "$W"' EXIT
    mkdir -p "$W/lists/partial" "$W/cache/archives/partial" "$W/sources.list.d"
    echo "deb [trusted=yes] file:$HERE/debs ./" > "$W/sources.list"
    A=(-o "Dir::Etc::SourceList=$W/sources.list" -o "Dir::Etc::SourceParts=$W/sources.list.d" -o "Dir::State::Lists=$W/lists"
       -o "Dir::Cache=$W/cache" -o APT::Sandbox::User=root -o DPkg::Lock::Timeout=300)
    export DEBIAN_FRONTEND=noninteractive
    apt-get "${A[@]}" -q update > "$W/update.log" 2>&1 || { cat "$W/update.log"; stop '임시 apt 저장소를 읽지 못했어요' '바로 위 apt 오류를 확인하세요.'; }
    # 먼저 흉내만 내서 무엇이 바뀌는지 본다. 지우는 패키지가 있으면 멈춘다(다른 팀이 쓰는 것을 지우지 않게)
    sim=$(apt-get "${A[@]}" -s install --no-install-recommends "${need[@]}" 2>&1) || { echo "$sim" | tail -15; stop '설치할 수 없어요(의존 패키지가 맞지 않아요)' '바로 위 apt 오류를 확인하세요. 빠진 패키지 이름이 나오면 기록 파일을 담당자에게 보내 주세요.'; }
    rm_=$(echo "$sim" | sed -n 's/^Remv \([^ ]*\).*/\1/p' | tr '\n' ' ')
    [ -z "$rm_" ] || stop "설치하려면 지워야 하는 패키지가 있어요: $rm_" '지워도 되는지 서버 관리 팀에 확인하세요. 괜찮으면 그 패키지를 빼고 설치하도록 담당자에게 알려 주세요.'
    n_new=$(echo "$sim" | grep -c '^Inst [^ ]* \['); n_all=$(echo "$sim" | grep -c '^Inst ')
    ok "새로 설치할 것 $((n_all - n_new))개, 새 버전으로 올릴 것 ${n_new}개(의존 패키지 포함)"
    apt-get "${A[@]}" -y install --no-install-recommends "${need[@]}" || stop '설치하지 못했어요' '바로 위 apt·dpkg 오류를 확인하세요. 중간에 끊겼으면 dpkg --configure -a 를 실행한 뒤 다시 실행하세요.'
fi

# ------------------------------------------------------------------ 4. 확인
step 4 '확인'
left=(); for p in "${PKGS[@]}"; do installed "$p" || [[ " ${skip[*]} " == *" $p "* ]] || left+=("$p"); done
[ ${#left[@]} -eq 0 ] || stop "설치되지 않은 것: ${left[*]}" '위 화면의 apt 오류를 확인하세요.'
ok "기초 프로그램 $(( ${#PKGS[@]} - ${#skip[@]} ))개가 모두 있어요"
echo
echo "${c_g}끝났어요.${c_0} 서버 상태를 다시 보려면: QUICK=1 bash /app/inbox/check.sh"
echo "기록 파일: $LOG"
