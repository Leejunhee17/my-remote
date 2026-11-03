#!/usr/bin/env bash
# [GPU 서버 · 관리자(root)] 접근 PC에서 올린 datasets 폴더를 /app/shared/datasets 아래 푼다(admin_setup.sh 다음).
# 점검(체크섬) → 풀기 → 학습 코드가 찾는 라벨이 있는지 검사까지 한 번에 한다.
#   bash /app/inbox/datasets/datasets_install.sh
# 다시 실행해도 된다. 이미 푼 것은 건너뛴다.
set -uo pipefail
if [ "$(uname -s)" != Linux ]; then echo "이 스크립트는 GPU 서버(리눅스)에서 실행해요. 접근 PC에서는 pc 폴더의 .ps1 을 쓰세요."; exit 1; fi
cd "$(dirname "$0")"
SRC=$PWD
# root 는 공용 계정이 올린 폴더를 /app/inbox 로 새로 복사한 뒤 실행한다. 복사본에 링크가 있으면 누가 심은 것이라 멈춘다
if [ "$(id -u)" = 0 ] && [ -n "$(find "$SRC" -type l -print -quit)" ]; then
    echo "멈춤: $SRC 안에 링크가 있어요(올린 폴더에 누가 넣었을 수 있어요). /app/upload/datasets 를 지우고 접근 PC 폴더를 다시 올린 뒤 새로 들여오세요: /app/shared/bin/gpu fetch datasets"; exit 1
fi
# root 로 설치할 때는 /app 이 잠겨 있어야 한다(admin_setup.sh). 공용 계정이 /app 에 링크를 심어 두면 root 가 시스템 폴더에 쓰게 된다
APP=${GPU_APP:-/app}   # 시험할 때만 바꾼다(tests/run.sh)
if [ "$(id -u)" = 0 ] && [ -d "$APP" ] && { [ "$(stat -c %U "$APP")" != root ] || [ -L "$APP/shared" ] || [ -L "$APP/autonomy_sw" ]; }; then
    echo "멈춤: /app이 아직 잠기지 않았어요. 관리자 기본 설정을 먼저 하세요: cd /app/inbox && bash admin_setup.sh"; exit 1
fi
# 공용 폴더 실제 위치. 관리자 설정(admin_setup.sh) 뒤에는 /app/shared 이고 root 만 고칠 수 있다
SH=$(realpath -m "$HOME/shared"); [ -d "$APP/shared" ] && SH=$APP/shared
if [ -d "$SH" ] && [ ! -w "$SH" ]; then
    echo "멈춤: 공용 폴더($SH)는 root만 고칠 수 있어요. root로 같은 명령을 실행하세요: bash $SRC/datasets_install.sh"; exit 1
fi
D="$SH/datasets"
LOG="$SH/logs/datasets_install_$(date +%Y%m%d_%H%M%S).log"
mkdir -p "$D" "$SH/logs"
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
    echo "고친 뒤 같은 명령을 다시 실행하세요: bash $SRC/datasets_install.sh"
    echo "기록 파일: $LOG  (해결이 안 되면 docs/8_문제_해결.md)"
    exit 1
}

echo "[GPU 서버] 세그멘테이션 데이터셋 설치  ($(date '+%Y-%m-%d %H:%M'), $(hostname), $(id -un))"
echo "가져올 곳: $SRC"
echo "푸는 곳: $D"

# ------------------------------------------------------------------ 1. 점검
step 1 '점검'
[ -f MANIFEST.sha256 ] || stop "MANIFEST.sha256 파일이 없어요" "접근 PC의 datasets 폴더를 통째로 /app/upload 에 올리고 /app/inbox 로 복사했는지 확인하세요(docs/6_데이터셋.md)."
command -v unzip >/dev/null || [ -x "$SH/tools/bin/unzip" ] ||
    stop "unzip 명령이 없어요" "기초 프로그램을 먼저 설치하세요: cd /app/inbox && bash pack_install.sh /app/shared"
export PATH="$PATH:$SH/tools/bin"

# 목록이 비었거나 모양이 다른 줄이 있으면 sha256sum 은 그 줄을 건너뛰고 "맞음"이 될 수 있어 따로 본다
[ "$(grep -c . MANIFEST.sha256)" -gt 0 ] && ! grep -v '^$' MANIFEST.sha256 | grep -qvE '^[0-9a-f]{64}  [^/].*$' ||
    stop "체크섬 목록(MANIFEST.sha256)이 비었거나 모양이 이상해요" "접근 PC에서 datasets_download.ps1 을 다시 실행해 목록을 새로 만든 뒤 datasets 폴더를 다시 올려 들여오세요."
# 체크섬 목록에는 압축 파일과 wildscenes 파일(하나하나)이 들어 있다. wildscenes 를 이미 옮겨서 이번에 안 올렸으면 그 줄은 뺀다
SUMS=$(mktemp); trap 'rm -f "$SUMS"' EXIT
if [ ! -d wildscenes ] && [ -f "$D/wildscenes/.gpu_done" ]; then grep -v '^[0-9a-f]\{64\}  wildscenes/' MANIFEST.sha256 > "$SUMS"
else cat MANIFEST.sha256 > "$SUMS"; fi
n=$(grep -c . "$SUMS" || true); nw=$(grep -c '^[0-9a-f]\{64\}  wildscenes/' "$SUMS" || true)
echo "  파일 ${n}개(그중 wildscenes ${nw}개)의 체크섬을 확인하고 있어요(100 GB면 10분 안팎)"
bad_files=; rc=0
[ "$n" -gt 0 ] && { bad_files=$(sha256sum -c --quiet --strict "$SUMS" 2>/dev/null | sed 's/: .*//'); rc=$?; }
[ "$rc" = 0 ] || [ -n "$bad_files" ] || stop "체크섬을 확인하지 못했어요" "묶음이나 폴더를 /app/upload 에 다시 올려 새로 들여온 뒤 다시 실행하세요. 기록 파일: $LOG"
if [ -n "$bad_files" ]; then
    echo "$bad_files" | sed 's/^/    깨졌거나 없는 파일: /'
    stop "올리는 중에 깨졌거나 빠진 파일이 있어요" "위 파일만 접근 PC에서 /app/upload/datasets 의 같은 자리에 다시 올리고, root로 /app/inbox/datasets 의 같은 자리에 복사하세요(예: cp /app/upload/datasets/goose/파일 $SRC/goose/). 체크섬은 이 스크립트가 다시 확인해요."
fi
ok "파일 ${n}개의 체크섬이 맞아요"

if [ -f wildscenes.ok ]; then
    want_f=$(sed -n 's/.*files=\([0-9]*\).*/\1/p' wildscenes.ok)
    if [ -d wildscenes ]; then
        have_f=$(find wildscenes -type f | wc -l)
    elif [ -f "$D/wildscenes/.gpu_done" ]; then
        have_f=$want_f
    else
        have_f=0
    fi
    # 예전 접근 PC 스크립트로 만든 목록에는 wildscenes 체크섬이 없다. 올리는 중에 바뀌어도 모르므로 목록을 새로 만들게 한다
    [ -d wildscenes ] && [ "$nw" = 0 ] && stop "체크섬 목록에 wildscenes 파일이 없어요" "접근 PC에서 git pull 뒤 datasets_download.ps1 을 다시 실행하세요(새로 받지 않고 체크섬 목록만 만들어요). 그다음 datasets 폴더를 다시 올려 들여오세요."
    [ "$have_f" = "$want_f" ] || stop "wildscenes 파일이 ${have_f}개예요(${want_f}개여야 해요)" "접근 PC의 datasets\\wildscenes 폴더를 /app/upload/datasets 에 다시 올리고 /app/inbox/datasets 로 복사하세요."
    ok "wildscenes 파일 ${want_f}개가 모두 있어요"
fi

need=$(( $(du -sm --exclude=wildscenes . | cut -f1) / 1024 + 10 ))
free=$(( $(df -Pm "$D" | awk 'NR==2 {print $4}') / 1024 ))
[ "$free" -ge "$need" ] || stop "남은 공간이 ${free} GB예요(약 ${need} GB 필요)" "/app/upload 의 원본이나 안 쓰는 파일을 지워 공간을 비우세요. 그래도 모자라면 서버 관리 팀에 디스크를 요청하세요."
ok "남은 공간 ${free} GB (필요한 공간 약 ${need} GB)"

# ------------------------------------------------------------------ 2. 풀기
step 2 '풀기'
mapfile -t files < <(sed -n 's/^[0-9a-f]\{64\}  //p' MANIFEST.sha256 | grep -v '^wildscenes/')   # wildscenes 는 아래에서 따로 옮긴다
i=0
for f in "${files[@]}"; do
    i=$((i + 1))
    set_dir=${f%%/*}
    dest="$D/$set_dir"
    mark="$dest/.gpu_$(basename "$f").done"
    if [ -f "$mark" ]; then echo "  ($i/${#files[@]}) $f: 이미 풀었어요"; continue; fi
    echo "  ($i/${#files[@]}) $f 푸는 중이에요"
    mkdir -p "$dest"
    case "$f" in
        *.zip)            unzip -q -o "$f" -d "$dest" ;;
        *.tar|*.tar.gz|*.tgz|*.tar.xz) tar xf "$f" -C "$dest" --no-same-owner ;;   # root 로 풀 때 압축 안의 주인을 따르지 않게
        *)  warn "$f: zip·tar가 아니라서 $dest 에 그대로 복사했어요. 직접 풀어야 할 수 있어요."
            cp "$f" "$dest/" ;;
    esac
    if [ $? -eq 0 ]; then touch "$mark"; else bad "$f: 풀지 못했어요(남은 공간과 권한을 확인하세요)"; fi
done
if [ -d wildscenes ] && [ ! -f "$D/wildscenes/.gpu_done" ]; then
    echo "  wildscenes 옮기는 중이에요"
    mkdir -p "$D/wildscenes"
    # 체크섬을 확인한 파일만 옮긴다(목록에 없는 파일이 끼어 있어도 공용 데이터셋에 들어가지 않게)
    sed -n 's|^[0-9a-f]\{64\}  wildscenes/||p' "$SUMS" > "$SUMS.w"
    (cd wildscenes && tar -cf - --no-recursion -T "$SUMS.w") | tar -xf - -C "$D/wildscenes" --no-same-owner &&
        touch "$D/wildscenes/.gpu_done" || bad "wildscenes를 옮기지 못했어요(남은 공간과 권한을 확인하세요)"
    rm -f "$SUMS.w"
fi
ok "다 풀었어요"

# ------------------------------------------------------------------ 3. 검사
step 3 '검사 (학습 코드 data/catalog.py 가 찾는 라벨이 있는지)'
check() {   # 이름 폴더 find-path 패턴 파일이름패턴
    local name=$1 dir=$2 path=$3 pat=$4
    if [ ! -d "$D/$dir" ]; then printf '  %-11s %s\n' "$name" "${c_y}올리지 않음${c_0}"; return; fi
    local c
    c=$(find "$D/$dir" -path "$D/$dir/$path" -name "$pat" 2>/dev/null | wc -l)
    if [ "$c" -gt 0 ]; then
        printf '  %-11s %s\n' "$name" "${c_g}라벨 ${c}장${c_0}"
    else
        printf '  %-11s %s\n' "$name" "${c_r}라벨을 못 찾음 ($dir/$path/$pat)${c_0}"
        echo "              지금 구조: $(cd "$D/$dir" && ls | head -8 | tr '\n' ' ')"
        FAILS=$((FAILS + 1))
    fi
}
check GOOSE      goose      'goose_2d_*/labels/*'          '*_labelids.png'
check GOOSE-Ex   gooseEx    'gooseEx_2d_*/labels/*'        '*_labelids.png'
check RELLIS-3D  rellis_2d  'annotations_id/Rellis-3D/*'   '*.png'
check RUGD       RUGD       'RUGD_annotations/*'           '*.png'
check WildScenes wildscenes '*/indexLabel/*'               '*.png'
check TAS500     tas500v1.1 '*_labels_ids/*'               '*.png'
check GO         go         '*/pylon_camera_node_label_id/*' '*.png'
if [ -d "$D/RUGD" ] && [ ! -f "$D/RUGD/RUGD_annotation-colormap.txt" ]; then
    found=$(find "$D/RUGD" -name 'RUGD_annotation-colormap.txt' | head -1)
    if [ -n "$found" ]; then cp "$found" "$D/RUGD/"; ok "RUGD 색상표를 $D/RUGD 에 복사했어요"
    else bad "RUGD 색상표(RUGD/RUGD_annotation-colormap.txt)가 없어요. 워크스테이션의 ~/datasets/semantic_segmentation/RUGD/ 에 있는 파일을 올려 $D/RUGD/ 에 복사하세요."; fi
fi

echo
if [ "$FAILS" -eq 0 ]; then
    echo "${c_g}############################ 완료 ############################${c_0}"
    echo " 올린 데이터셋이 모두 정상이에요. 위치: $D"
    echo " 엑셀 '데이터셋 목록' 시트의 진행 상황을 '서버 반입'으로 바꾸세요."
    echo " 다음 단계: 사전학습 모델(docs/1_처음_설치.md 5단계)"
    echo " 서버 2로 옮길 거면 지우기 전에 NAS에 먼저 보관하세요(docs/9_NAS.md 의 \"쓰는 법\")."
    echo " 공간 정리(보관한 뒤): rm -rf /app/inbox/datasets /app/upload/datasets"
    echo "${c_g}##############################################################${c_0}"
else
    echo "${c_r}############## 끝났지만 문제 ${FAILS}개 ##############${c_0}"
    echo " 빨간 줄을 확인하세요. '라벨을 못 찾음'은 압축 안 폴더가 한 단계 더 있거나 없는 경우가 많아요."
    echo " '지금 구조'를 보고 학습 코드가 찾는 위치로 폴더를 옮기세요(docs/6_데이터셋.md 의 \"학습 코드가 읽는 라벨 위치\")."
    echo " 기록 파일: $LOG"
    echo " /app/inbox/datasets 는 문제가 풀릴 때까지 지우지 마세요."
    exit 1
fi
