#!/usr/bin/env bash
# [B200 서버] 접근 PC에서 올린 datasets 폴더를 ~/shared/datasets 아래 푼다. root 없이 된다.
# 점검(체크섬) → 풀기 → 학습 코드가 찾는 라벨이 있는지 검사까지 한 번에 한다.
#   bash /app/inbox/datasets/datasets_install.sh
# 다시 실행해도 된다. 이미 푼 것은 건너뛴다.
set -uo pipefail
if [ "$(uname -s)" != Linux ]; then echo "이 스크립트는 B200 서버(리눅스)에서 실행한다. 접근 PC에서는 .ps1 을 쓴다."; exit 1; fi
cd "$(dirname "$0")"
SRC=$PWD
D="$HOME/shared/datasets"
LOG="$HOME/shared/logs/datasets_install_$(date +%Y%m%d_%H%M%S).log"
mkdir -p "$D" "$HOME/shared/logs"
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
    echo "${c_r}무엇이: $1${c_0}"
    echo "할 일 : $2"
    echo "고친 뒤 같은 명령을 다시 실행하면 된다."
    echo "해결이 안 되면 이 파일을 담당자에게 보내 준다: $LOG"
    exit 1
}

echo "[B200 서버] 세그 데이터셋 설치  ($(date '+%Y-%m-%d %H:%M'), $(hostname), $(id -un))"
echo "올린 곳: $SRC"
echo "푸는 곳: $D"

# ------------------------------------------------------------------ 1. 점검
step 1 '점검'
[ -f MANIFEST.sha256 ] || stop "MANIFEST.sha256 이 없다" "접근 PC의 datasets 폴더를 통째로 /app/inbox/datasets 에 올렸는지 본다."
command -v unzip >/dev/null || [ -x "$HOME/shared/tools/bin/unzip" ] ||
    stop "unzip 이 없다" "공용 기초 프로그램(pack_install.sh)을 먼저 설치하거나 source ~/.bashrc 를 한다."
export PATH="$PATH:$HOME/shared/tools/bin"

n=$(grep -c . MANIFEST.sha256 || true)
echo "  압축 ${n}개 체크섬 확인 중 (100 GB면 10분 안팎)"
bad_files=$(sha256sum -c --quiet MANIFEST.sha256 2>/dev/null | sed 's/: .*//')
if [ -n "$bad_files" ]; then
    echo "$bad_files" | sed 's/^/    깨짐 또는 없음: /'
    stop "올리는 중에 깨졌거나 빠진 파일이 있다" "위 파일만 접근 PC에서 다시 올려 같은 자리에 덮어쓴다."
fi
ok "압축 ${n}개 체크섬 일치"

if [ -f wildscenes.ok ]; then
    want_f=$(sed -n 's/.*files=\([0-9]*\).*/\1/p' wildscenes.ok)
    if [ -d wildscenes ]; then
        have_f=$(find wildscenes -type f | wc -l)
    elif [ -f "$D/wildscenes/.b200_done" ]; then
        have_f=$want_f
    else
        have_f=0
    fi
    [ "$have_f" = "$want_f" ] || stop "wildscenes 파일이 ${have_f}개다(${want_f}개여야 한다)" "접근 PC의 datasets\\wildscenes 폴더를 다시 올린다."
    ok "wildscenes 파일 ${want_f}개 일치"
fi

need=$(( $(du -sm --exclude=wildscenes . | cut -f1) / 1024 + 10 ))
free=$(( $(df -Pm "$D" | awk 'NR==2 {print $4}') / 1024 ))
[ "$free" -ge "$need" ] || stop "남은 공간이 ${free} GB 다(약 ${need} GB 필요)" "공간을 비우거나 관리자에게 큰 디스크를 요청한다."
ok "남은 공간 ${free} GB (필요 약 ${need} GB)"

# ------------------------------------------------------------------ 2. 풀기
step 2 '풀기'
mapfile -t files < <(sed -n 's/^[0-9a-f]\{64\}  //p' MANIFEST.sha256)
i=0
for f in "${files[@]}"; do
    i=$((i + 1))
    set_dir=${f%%/*}
    dest="$D/$set_dir"
    mark="$dest/.b200_$(basename "$f").done"
    if [ -f "$mark" ]; then echo "  ($i/${#files[@]}) $f : 이미 풂"; continue; fi
    echo "  ($i/${#files[@]}) $f 푸는 중"
    mkdir -p "$dest"
    case "$f" in
        *.zip)            unzip -q -o "$f" -d "$dest" ;;
        *.tar|*.tar.gz|*.tgz|*.tar.xz) tar xf "$f" -C "$dest" ;;
        *)  warn "$f 는 zip/tar 가 아니라 $dest 에 그대로 복사한다. 직접 풀어야 할 수 있다."
            cp "$f" "$dest/" ;;
    esac
    if [ $? -eq 0 ]; then touch "$mark"; else bad "$f 풀기 실패(공간이나 권한을 본다)"; fi
done
if [ -d wildscenes ] && [ ! -f "$D/wildscenes/.b200_done" ]; then
    echo "  wildscenes 옮기는 중"
    mkdir -p "$D/wildscenes"
    cp -a wildscenes/. "$D/wildscenes/" && touch "$D/wildscenes/.b200_done" || bad "wildscenes 옮기기 실패"
fi
ok "풀기 끝"

# ------------------------------------------------------------------ 3. 검사
step 3 '검사 (학습 코드 data/catalog.py 가 찾는 라벨이 있는지)'
check() {   # 이름 폴더 find-path 패턴 파일이름패턴
    local name=$1 dir=$2 path=$3 pat=$4
    if [ ! -d "$D/$dir" ]; then printf '  %-11s %s\n' "$name" "${c_y}안 받음${c_0}"; return; fi
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
    if [ -n "$found" ]; then cp "$found" "$D/RUGD/"; ok "RUGD colormap 을 $D/RUGD 로 복사"
    else bad "RUGD/RUGD_annotation-colormap.txt 가 없다. 워크스테이션 ~/datasets/semantic_segmentation/RUGD/ 에서 복사한다."; fi
fi

echo
if [ "$FAILS" -eq 0 ]; then
    echo "${c_g}############################ 완료 ############################${c_0}"
    echo " 받은 데이터셋은 모두 정상. 위치: $D"
    echo " 엑셀 '데이터셋 목록' 시트의 진행 상황을 '서버 반입'으로 바꾼다."
    echo " 정리: rm -rf /app/inbox/datasets"
    echo "${c_g}##############################################################${c_0}"
else
    echo "${c_r}############## 끝났지만 문제 ${FAILS}개 ##############${c_0}"
    echo " 빨간 줄을 본다. '라벨을 못 찾음'은 압축 안 폴더 이름이 한 단계 다른 경우가 많다:"
    echo " 지금 구조를 보고 학습 코드가 찾는 모양으로 옮긴다(docs/2_데이터셋.md 의 "학습 코드가 읽는 라벨 위치")."
    echo " 해결이 안 되면 이 파일을 담당자에게 보내 준다: $LOG"
    echo " /app/inbox/datasets 는 문제가 풀릴 때까지 지우지 않는다."
    exit 1
fi
