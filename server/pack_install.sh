#!/usr/bin/env bash
# [B200 서버] b200-pack.tar 의 기초 프로그램(tmux, nvtop, rsync 등)을 공용 폴더에 설치한다.
# 팀원은 Python 패키지를 도커 이미지에 넣어 오므로 공용 휠·공용 Python 환경은 만들지 않는다.
# 점검 → 설치 → 검사까지 한 번에 한다. 실패하면 고친 뒤 다시 실행하면 된다.
#   bash pack_install.sh /app/shared   관리자(root). admin_setup.sh 다음에 실행한다(지금 방식)
#   bash pack_install.sh               공용 계정으로 ~/shared 에 설치(예전 방식, 관리자 설정 전)
#   공용 계정으로 경로를 주면 ~/shared 를 그곳을 가리키는 링크로 만들고, 작업 폴더와 링크 ~/workspace 도 없으면 만든다
set -uo pipefail
if [ "$(uname -s)" != Linux ]; then echo "이 스크립트는 B200 서버(리눅스)에서 실행해요. 접근 PC에서는 pc 폴더의 .ps1 을 쓰세요."; exit 1; fi
cd "$(dirname "$0")"
HERE=$PWD
# root 로 설치할 때는 /app 이 잠겨 있어야 한다(admin_setup.sh). 공용 계정이 /app 에 링크를 심어 두면 root 가 시스템 폴더에 쓰게 된다
if [ "$(id -u)" = 0 ] && [ -d /app ] && { [ "$(stat -c %U /app)" != root ] || [ -L /app/shared ] || [ -L /app/workspace ]; }; then
    echo "멈춤: /app이 아직 잠기지 않았어요. 먼저 root로 실행하세요: cd $HERE && bash admin_setup.sh"; exit 1
fi

# (공용 계정으로 실행할 때) 큰 디스크 경로를 줬으면 ~/shared 를 그곳을 가리키는 링크로 만든다.
# 이후 모든 경로는 ~/shared 로 쓰므로 문서와 다른 스크립트를 그대로 쓸 수 있다.
REAL=${1:-}
if [ "$(id -u)" = 0 ]; then
    # 관리자 설치: root 홈에 링크를 만들지 않고 준 경로에 바로 설치한다
    [ -n "$REAL" ] || { echo "멈춤: root로 설치할 때는 설치할 곳을 붙여 실행하세요: bash pack_install.sh /app/shared"; exit 1; }
    mkdir -p "$REAL" || { echo "멈춤: 폴더를 만들지 못했어요: $REAL"; exit 1; }
elif [ -n "$REAL" ]; then
    REAL=$(realpath -m "$REAL")
    mkdir -p "$REAL" 2>/dev/null || { echo "멈춤: 폴더를 만들지 못했어요: $REAL (쓰기 권한을 확인하세요)"; exit 1; }
    if [ -L "$HOME/shared" ]; then
        [ "$(realpath "$HOME/shared")" = "$REAL" ] ||
            { echo "멈춤: ~/shared가 이미 다른 곳을 가리키는 링크예요: $(realpath "$HOME/shared"). 그 경로를 붙여 실행하거나, 링크를 지우고 다시 실행하세요."; exit 1; }
    elif [ -d "$HOME/shared" ]; then
        if [ "$(du -sm "$HOME/shared" | cut -f1)" -lt 200 ]; then
            # 지난번 실패한 실행이 남긴 기록 정도라 옮기고 링크로 바꾼다
            cp -a "$HOME/shared/." "$REAL/" && rm -rf "$HOME/shared" && ln -s "$REAL" "$HOME/shared" ||
                { echo "멈춤: ~/shared를 옮기지 못했어요: $REAL"; exit 1; }
        else
            echo "멈춤: ~/shared에 이미 설치된 내용이 있어요. docs/8_문제_해결.md 의 \"예전 서버(RHEL)에서 ~/shared 를 큰 디스크로 옮겨야 할 때\"를 따라 먼저 옮기세요."; exit 1
        fi
    else
        ln -s "$REAL" "$HOME/shared"
    fi
    # 같은 디스크에 개인 작업 폴더를 두고 홈에는 링크만 둔다(OS를 새로 설치했을 때 다시 만들 필요 없게)
    W="$(dirname "$REAL")/workspace"
    if [ ! -e "$HOME/workspace" ] && mkdir -p "$W" 2>/dev/null; then ln -s "$W" "$HOME/workspace"; fi
fi
# 실제 경로로 적어야 기초 프로그램에 박히는 경로가 누구에게나 맞다(예: /app/shared)
if [ "$(id -u)" = 0 ]; then S=$(realpath -m "$REAL"); else S=$(realpath -m "$HOME/shared"); fi
if [ -d "$S" ] && [ ! -w "$S" ]; then
    echo "멈춤: 공용 폴더($S)는 root만 고칠 수 있어요. root로 실행하세요: bash pack_install.sh /app/shared"; exit 1
fi
LOG="$S/logs/pack_install_$(date +%Y%m%d_%H%M%S).log"
mkdir -p "$S/logs"
exec > >(tee -a "$LOG") 2>&1
T=3
FAILS=0

c_g=$'\e[32m'; c_y=$'\e[33m'; c_r=$'\e[31m'; c_c=$'\e[36m'; c_0=$'\e[0m'
step() { echo; echo "${c_c}==== [$1/$T] $2 ====${c_0}"; }
ok()   { echo "  ${c_g}[정상]${c_0} $*"; }
warn() { echo "  ${c_y}[주의]${c_0} $*"; }
bad()  { echo "  ${c_r}[문제]${c_0} $*"; FAILS=$((FAILS + 1)); }
stop() {
    echo
    echo "${c_r}################ 멈춤 ################${c_0}"
    echo "${c_r}멈춘 이유: $1${c_0}"
    echo "할 일: $2"
    echo "고친 뒤 같은 명령을 다시 실행하세요: bash pack_install.sh $S"
    echo "기록 파일: $LOG  (해결이 안 되면 docs/8_문제_해결.md)"
    exit 1
}
info() { sed -n "s/^$1=//p" pack_info.txt; }
ver_ge() { [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -1)" = "$2" ]; }

echo "[B200 서버] 기초 프로그램 설치  ($(date '+%Y-%m-%d %H:%M'), $(hostname), $(id -un))"
echo "  운영체제: $(. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME")"

# ------------------------------------------------------------------ 1. 점검
step 1 '점검'
for f in MANIFEST.sha256 micromamba explicit.txt pack_info.txt pkgs; do
    [ -e "$f" ] || stop "묶음 안의 파일이 없어요: $f" "묶음을 풀었는지 확인하세요: cd $HERE && tar xf b200-pack.tar  (풀었는데도 없으면 접근 PC의 b200-pack.tar 를 다시 올려 복사하세요)"
done
echo "  묶음 정보: $(info made)에 만든 묶음, glibc $(info glibc) 기준, 기초 프로그램 패키지 $(info tools)개"

echo "  파일 체크섬을 확인하고 있어요(1~3분)"
# 설치 스크립트 자신은 고친 버전을 따로 올려 덮어쓸 수 있도록 검사에서 뺀다
bad_files=$(grep -vE '  ((pack_install|move_shared|check_server|check_network|check_nas|admin_setup)\.sh|bin/.*)$' MANIFEST.sha256 | sha256sum -c --quiet - 2>/dev/null | sed 's/: .*//')
if [ -n "$bad_files" ]; then
    echo "$bad_files" | head -20 | sed 's/^/    깨진 파일: /'
    stop "올리는 중에 파일이 깨졌어요($(echo "$bad_files" | wc -l)개)" \
         "접근 PC의 pack\\b200-pack.tar 를 /app/upload 에 다시 올리고, /app/inbox 로 새로 복사해 지문을 확인한 뒤 다시 푸세요."
fi
ok "파일 $(grep -cvE '  ((pack_install|move_shared|check_server|check_network|check_nas|admin_setup)\.sh|bin/.*)$' MANIFEST.sha256)개 체크섬이 맞아요"

glibc=$(ldd --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+$')
if ver_ge "$glibc" "$(info glibc)"; then
    ok "B200 서버 glibc $glibc (묶음 기준 $(info glibc) 이상)"
else
    stop "B200 서버의 glibc($glibc)가 묶음 기준($(info glibc))보다 낮아서 안 맞아요" \
         "접근 PC에서 -Glibc $glibc 를 붙여 pack_build.ps1 을 다시 실행하고, 새 묶음 파일을 올리세요."
fi

need=$(( $(du -sm pkgs | awk '{s+=$1} END {print s}') * 3 / 1024 + 2 ))
# ~/shared 가 큰 디스크를 가리키는 링크여도 그 디스크를 잰다
free=$(( $(df -Pm "$S/." | awk 'NR==2 {print $4}') / 1024 ))
if [ "$free" -lt "$need" ]; then
    [ -f b200-pack.tar ] && warn "다 푼 b200-pack.tar 를 지우면 $(( $(du -sm b200-pack.tar | cut -f1) / 1024 )) GB를 비울 수 있어요: rm $HERE/b200-pack.tar"
    stop "$S 가 있는 디스크의 남은 공간이 ${free} GB예요(${need} GB 필요)" \
         "다 푼 b200-pack.tar 나 /app/upload 의 원본을 지워 공간을 비우세요. 홈(10 GB)에 설치하려던 거면 /app 경로를 붙이세요: bash pack_install.sh /app/shared"
fi
ok "$S 남은 공간 ${free} GB (필요한 공간 약 ${need} GB)"

# ------------------------------------------------------------------ 2. 기초 프로그램
step 2 "기초 프로그램 설치 → $S/tools"
mkdir -p "$S/mamba/pkgs"
cp pack_info.txt "$S/" && cp -n pkgs/* "$S/mamba/pkgs/" || stop "패키지 파일을 복사하지 못했어요" "남은 공간(df -h $S)과 쓰기 권한을 확인하세요."
chmod +x micromamba
export MAMBA_ROOT_PREFIX="$S/mamba"
if [ -f "$S/tools/.b200_ok" ] && cmp -s explicit.txt "$S/tools/.b200_ok"; then
    ok "이미 같은 버전이 설치돼 있어서 건너뛰어요"
elif [ -f "$S/tools/.b200_ok" ] && [ "${B200_REBUILD_TOOLS:-0}" != 1 ]; then
    warn "기초 프로그램 목록이 바뀌었어요. 쓰는 사람이 있을 수 있어 지금 설치된 것을 그대로 뒀어요."
    warn "팀원이 안 쓸 때 새로 설치하세요: B200_REBUILD_TOOLS=1 bash pack_install.sh $S"
else
    rm -rf "$S/tools"   # 지난번에 끝까지 못 깐 것
    ./micromamba create -p "$S/tools" --offline -y -f explicit.txt ||
        stop "기초 프로그램을 설치하지 못했어요" "바로 위의 오류 줄을 확인하세요. 원인을 모르겠으면 기록 파일을 보세요."
    cp micromamba "$S/tools/bin/"
    cp explicit.txt "$S/tools/.b200_ok"
    ok "설치했어요"
fi
if [ -f /etc/profile.d/b200.sh ] || [ "$(id -u)" = 0 ]; then
    ok "PATH는 관리자 설정(/etc/profile.d/b200.sh)이 맡아요. 공용 계정으로 다시 접속하면 바로 써요"
elif ! grep -q 'shared/tools/bin' ~/.bashrc; then
    # 서버에 원래 있는 명령이 먼저 잡히도록 뒤에 붙인다
    echo 'export PATH=$PATH:$HOME/shared/tools/bin' >> ~/.bashrc
    ok "~/.bashrc 에 PATH를 추가했어요"
fi

# ------------------------------------------------------------------ 3. 검사
step 3 '검사'
missing=()
for b in python uv git git-lfs delta lazygit tmux screen vim nvim nano micro less direnv zoxide fzf \
         tree rg fd bat eza ncdu dust duf jq yq dos2unix entr parallel just hyperfine \
         zip unzip 7za pigz zstd htop btop nvtop lsof strace gdb \
         make cmake ninja pkg-config gcc g++ ccache patchelf clang-format shellcheck \
         ffmpeg magick sqlite3 rsync bc; do
    [ -x "$S/tools/bin/$b" ] || missing+=("$b")
done
if [ ${#missing[@]} -eq 0 ]; then ok "기초 프로그램 명령이 모두 있어요"; else warn "기초 프로그램에 없는 명령: ${missing[*]} (패키지 이름과 명령 이름이 다를 수 있어요. lists/tools.txt 를 확인하세요)"; fi
"$S/tools/bin/git" --version >/dev/null 2>&1 && "$S/tools/bin/tmux" -V >/dev/null 2>&1 &&
    ok "git, tmux가 실행돼요" || bad "git이나 tmux가 실행되지 않아요. 직접 실행해 오류를 확인하세요: $S/tools/bin/tmux -V"

# 예전 버전이 만든 공용 휠·공용 Python 환경. 지우지는 않고 알려만 준다(쓰는 사람이 있을 수 있다)
for d in "$S/wheels" "$S/venv"; do
    [ -e "$d" ] && warn "예전 공용 휠·Python 환경이 남아 있어요: $d ($(du -sh "$d" 2>/dev/null | cut -f1)). 쓰는 사람이 없으면 지우세요: rm -rf $d"
done
[ -f "$S/lock.txt" ] && rm -f "$S/lock.txt"

echo
if [ "$FAILS" -eq 0 ]; then
    echo "${c_g}############################ 완료 ############################${c_0}"
    echo " 모두 정상이에요. 기초 프로그램: $S/tools"
    echo " 공용 계정으로 새로 접속하면 바로 쓸 수 있어요(목록: docs/5_기초프로그램.md)."
    echo " 다음 단계: 도커(docs/1_처음_설치.md 3단계)"
    echo " 공간 정리(묶음 파일만): rm -f $HERE/b200-pack.tar /app/upload/b200-pack.tar"
    echo "${c_g}##############################################################${c_0}"
else
    echo "${c_r}############## 끝났지만 문제 ${FAILS}개 ##############${c_0}"
    echo " 위의 [문제] 줄을 보고 고친 뒤 다시 실행하세요. 기록 파일: $LOG"
    exit 1
fi
