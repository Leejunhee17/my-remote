#!/usr/bin/env bash
# [GPU 서버 · 관리자(root)] NAS inbox 에 올린 datasets 폴더의 데이터셋을 NAS 팀 폴더의 /data/autonomy_sw/datasets 아래 푼다(4단계).
# 점검 → 파일마다 root 전용 임시 폴더로 복사해 체크섬 확인 → 풀기(압축이 아니면 그대로 옮기기) → 라벨 파일 검사까지 한 번에 한다.
#   /app/admin/bin/gpu fetch datasets     # 목록(MANIFEST.sha256)과 이 스크립트만 /app/inbox/datasets 로 복사하고 지문을 보여 준다
#   bash /app/inbox/datasets/datasets_unpack.sh
# 다시 실행해도 된다. 이미 푼 것은 건너뛴다. 데이터셋 폴더 몇 개씩 나눠 올려도 된다.
# 데이터 파일은 NAS inbox(공용 계정이 고칠 수 있는 곳)에 둔 채로 쓴다. 그래서 root 는 파일을 하나씩 root 전용 임시 폴더에 복사하고,
# 그 복사본의 체크섬이 목록과 맞을 때만 푼다. 확인한 뒤에 원본이 바뀌어도 푸는 것은 확인한 복사본이다
# datasets 폴더에 원래 있던 다른 폴더는 건드리지 않는다. 같은 이름의 폴더가 있는데 이 스크립트가 넣은 것이 아니면 그 데이터셋은 건너뛰고 알린다
set -uo pipefail
if [ "$(uname -s)" != Linux ]; then echo "이 스크립트는 GPU 서버(리눅스)에서 실행해요. 접근 PC에서는 pc 폴더의 .ps1 을 쓰세요."; exit 1; fi
cd "$(dirname "$0")"
HERE=$PWD   # 목록(MANIFEST.sha256)과 이 스크립트가 있는 곳. root 는 gpu fetch 가 복사한 /app/inbox/datasets 에서 실행한다
APP=${GPU_APP:-/app}   # 시험할 때만 바꾼다(tests/run.sh)
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
# root 로 설치할 때는 /app 이 잠겨 있어야 한다(prepare.sh). 공용 계정이 /app 에 링크를 심어 두면 root 가 시스템 폴더에 쓰게 된다
if [ "$(id -u)" = 0 ] && [ -d "$APP" ] && { [ "$(stat -c %U "$APP")" != root ] || [ -L "$APP/admin" ] || [ -L "$APP/autonomy_sw" ]; }; then
    echo "멈춤: /app이 아직 잠기지 않았어요. 준비를 먼저 하세요: cd /app/inbox && bash prepare.sh"; exit 1
fi
# 목록과 스크립트는 root 만 고칠 수 있는 곳(gpu fetch 가 복사한 /app/inbox/datasets)에 있어야 믿는다
if [ "$(id -u)" = 0 ] && ! safe_dir "$HERE"; then
    echo "멈춤: $HERE 를 root 말고도 고칠 수 있어요. root 로 목록과 스크립트를 복사한 뒤 거기서 실행하세요: /app/admin/bin/gpu fetch datasets"; exit 1
fi
# 넣을 곳: NAS 팀 폴더의 datasets(/app/admin/gpu.conf 의 NAS_DIR, 기본 /data/autonomy_sw). root 만 고치고 팀원은 읽는다
NAS=${GPU_NAS_DIR:-$(sed -n 's/^NAS_DIR=\([^ #]*\).*/\1/p' "$APP/admin/gpu.conf" 2>/dev/null | tail -1)}   # GPU_NAS_DIR: 시험할 때만
NAS=${NAS:-/data/autonomy_sw}
D="$NAS/datasets"
SRC=${GPU_SRC:-$NAS/inbox/datasets}   # 데이터 파일이 있는 곳(공용 계정이 FileZilla 로 올린 곳)
if [ "$(id -u)" = 0 ] && ! safe_dir "$D"; then
    echo "멈춤: 넣을 곳($D)이 없거나 root 말고도 고칠 수 있어요. 준비를 먼저 하세요(이미 있는 팀 폴더면 docs/8_NAS.md 의 \"이미 있는 팀 폴더 잠그기\"): cd /app/inbox && bash prepare.sh"; exit 1
fi
if [ -d "$D" ] && [ ! -w "$D" ]; then
    echo "멈춤: $D 는 root만 고칠 수 있어요. root로 같은 명령을 실행하세요: bash $HERE/datasets_unpack.sh"; exit 1
fi
[ -d "$SRC" ] || { echo "멈춤: 데이터 파일을 올린 곳($SRC)이 없어요. 접근 PC의 datasets 폴더를 공용 계정 FileZilla로 NAS 의 $(dirname "$SRC") 에 올리세요."; exit 1; }
LOG="$APP/admin/logs/datasets_unpack_$(date +%Y%m%d_%H%M%S).log"
mkdir -p "$D" "$APP/admin/logs"
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
    echo "고친 뒤 같은 명령을 다시 실행하세요: bash $HERE/datasets_unpack.sh"
    echo "기록 파일: $LOG  (해결이 안 되면 docs/7_문제_해결.md)"
    exit 1
}
# 이 스크립트가 넣은 데이터셋 폴더인지: 처음 만들 때 남기는 표시(.gpu_placed)나, 예전 버전이 남긴 표시(.gpu_*.done)가 있으면
ours() { [ -f "$D/$1/.gpu_placed" ] || [ -n "$(find "$D/$1" -maxdepth 3 -name '.gpu_*' -print -quit 2>/dev/null)" ]; }

echo "[GPU 서버] 세그멘테이션 데이터셋 풀기  ($(date '+%Y-%m-%d %H:%M'), $(hostname), $(id -un))"
echo "목록:      $HERE/MANIFEST.sha256"
echo "올린 곳:   $SRC"
echo "푸는 곳:   $D"

# ------------------------------------------------------------------ 1. 점검
step 1 '점검'
[ -f MANIFEST.sha256 ] || stop "MANIFEST.sha256 파일이 없어요" "root 로 목록을 복사하세요: /app/admin/bin/gpu fetch datasets"
command -v unzip >/dev/null ||
    stop "unzip 명령이 없어요" "2단계 기초 프로그램을 설치하세요(docs/1_처음_설치.md 의 \"2단계: 서버 기초 프로그램\")."
# 목록이 비었거나 모양이 다른 줄이 있으면 따로 본다
[ "$(grep -c . MANIFEST.sha256)" -gt 0 ] && ! grep -v '^$' MANIFEST.sha256 | grep -qvE '^[0-9a-f]{64}  [^/].*$' && ! grep -q '\.\./' MANIFEST.sha256 ||
    stop "체크섬 목록(MANIFEST.sha256)이 비었거나 모양이 이상해요" "접근 PC에서 datasets_download.ps1 을 다시 실행해 목록을 새로 만든 뒤 datasets 폴더를 다시 올리세요."

# 체크섬 목록에는 접근 PC에서 받은 모든 데이터셋이 들어 있다. 큰 데이터셋은 나눠 올릴 수 있게,
# 이번에 올린 데이터셋 폴더(목록의 맨 앞 폴더)만 다룬다. 폴더째 안 올린 데이터셋은 건너뛴다
SUMS=$(mktemp); TMP=; trap 'rm -f "$SUMS"; [ -n "$TMP" ] && rm -rf "$TMP"' EXIT
skipped=; conflict=; sets=()
for s in $(sed -n 's/^[0-9a-f]\{64\}  \([^/]*\)\/.*/\1/p' MANIFEST.sha256 | sort -u); do
    if [ ! -d "$SRC/$s" ]; then skipped+=" $s"; continue; fi
    if [ -e "$D/$s" ] && ! ours "$s"; then conflict+=" $s"; continue; fi
    sets+=("$s"); grep -F "  $s/" MANIFEST.sha256 >> "$SUMS"
done
[ -n "$skipped" ] && echo "  이번에 올리지 않은 데이터셋(건너뛰어요):$skipped"
if [ -n "$conflict" ]; then
    for s in $conflict; do warn "$D/$s 가 이미 있는데 이 스크립트가 넣은 폴더가 아니에요. 덮어쓰지 않고 건너뛰어요. 안을 확인하고 지우거나 이름을 바꾼 뒤 다시 실행하세요"; done
fi
[ -s "$SUMS" ] || stop "넣을 데이터셋이 없어요" "NAS 의 $SRC 안에 데이터셋 폴더(예: goose)를 넣어 올렸는지, 위 [주의] 의 같은 이름 폴더를 정리했는지 확인하세요(docs/5_데이터셋.md)."
# 예전 접근 PC 스크립트로 만든 목록에는 wildscenes 체크섬이 없다. 그러면 wildscenes 파일을 확인할 수 없으므로 목록을 새로 만들게 한다
if [ -d "$SRC/wildscenes" ] && ! grep -q '^[0-9a-f]\{64\}  wildscenes/' MANIFEST.sha256; then
    stop "체크섬 목록에 wildscenes 파일이 없어요" "접근 PC에서 git pull 뒤 datasets_download.ps1 을 다시 실행하세요(새로 받지 않고 체크섬 목록만 만들어요). 그다음 datasets 폴더를 다시 올리세요."
fi
# 올린 폴더에 링크가 있으면 멈춘다(링크가 가리키는 다른 파일을 root 가 읽게 하지 않게)
links=$(for s in "${sets[@]}"; do find "$SRC/$s" -type l; done | head -5)
[ -z "$links" ] || { echo "$links" | sed 's/^/    링크: /'; stop "올린 폴더에 링크가 있어요(누가 넣었을 수 있어요)" "NAS 의 $SRC 에서 그 데이터셋 폴더를 지우고 접근 PC 폴더를 다시 올리세요."; }
# 빠진 파일은 먼저 알린다(체크섬은 아래에서 파일마다 복사본으로 확인한다)
missing=$(sed -n 's/^[0-9a-f]\{64\}  //p' "$SUMS" | while IFS= read -r f; do [ -f "$SRC/$f" ] || echo "$f"; done)
if [ -n "$missing" ]; then
    echo "$missing" | head -20 | sed 's/^/    없는 파일: /'
    stop "올린 폴더에 빠진 파일이 있어요" "위 파일을 접근 PC에서 NAS 의 $SRC 같은 자리에 다시 올리세요(FileZilla 이어 올리기)."
fi
n=$(grep -c . "$SUMS" || true)
ok "넣을 데이터셋 ${#sets[@]}개(${sets[*]}), 파일 ${n}개가 모두 올라와 있어요"
need=$(( $(for s in "${sets[@]}"; do du -sm "$SRC/$s"; done | awk '{t += $1} END {print t + 0}') / 1024 + 10 ))
free=$(( $(df -Pm "$D" | awk 'NR==2 {print $4}') / 1024 ))
[ "$free" -ge "$need" ] || stop "남은 공간이 ${free} GB예요(약 ${need} GB 필요)" "NAS 팀 폴더($NAS)의 안 쓰는 파일을 정리하거나 서버 관리 팀에 물어보세요."
ok "남은 공간 ${free} GB (필요한 공간 약 ${need} GB)"

# ------------------------------------------------------------------ 2. 풀기
step 2 '복사해 확인하고 풀기'
# root 만 들어가는 임시 폴더. 넣을 곳과 같은 NAS 라서, 압축이 아닌 파일은 확인한 복사본을 그 자리로 옮기기만 하면 된다
TMP="$D/.gpu_tmp_$$"; rm -rf "$TMP"; mkdir -m 700 "$TMP" || stop "임시 폴더($TMP)를 만들지 못했어요" "남은 공간과 권한을 확인하세요."
for s in "${sets[@]}"; do [ -d "$D/$s" ] || { mkdir -p "$D/$s" && touch "$D/$s/.gpu_placed"; }; done
i=0; nw=0
while IFS= read -r line; do
    sum=${line%%  *}; f=${line#*  }
    i=$((i + 1))
    dest="$D/$(dirname "$f")"; base=$(basename "$f")
    case "$f" in
        *.zip|*.tar|*.tar.gz|*.tgz|*.tar.xz) mark="$dest/.gpu_$base.done"; [ -f "$mark" ] && { echo "  ($i/$n) $f: 이미 풀었어요"; continue; } ;;
        *) mark=; [ -f "$dest/$base" ] && continue ;;   # 확인한 복사본만 옮겨 오므로, 있으면 이미 확인한 것이다
    esac
    case "$f" in
        wildscenes/*) nw=$((nw + 1)); [ $((nw % 2000)) = 1 ] && echo "  ($i/$n) wildscenes 파일 옮기는 중이에요" ;;
        *) echo "  ($i/$n) $f 복사해 확인하는 중이에요" ;;
    esac
    src="$SRC/$f"; t="$TMP/f"
    if [ ! -f "$src" ] || [ -L "$src" ]; then bad "$f: 올린 곳에 보통 파일로 없어요"; continue; fi
    cp "$src" "$t" || { bad "$f: 복사하지 못했어요(남은 공간을 확인하세요)"; rm -f "$t"; continue; }
    if ! printf '%s  %s\n' "$sum" "$t" | sha256sum -c --quiet --strict - >/dev/null 2>&1; then
        bad "$f: 체크섬이 맞지 않아요(올리는 중에 깨졌거나 바뀌었어요). 이 파일만 다시 올리고 다시 실행하세요"; rm -f "$t"; continue
    fi
    mkdir -p "$dest"
    case "$f" in
        *.zip)            unzip -q -o "$t" -d "$dest" ;;
        *.tar|*.tar.gz|*.tgz|*.tar.xz) tar xf "$t" -C "$dest" --no-same-owner ;;   # root 로 풀 때 압축 안의 주인을 따르지 않게
        *.7z|*.rar) warn "$f: 7z·rar 는 풀지 않고 $dest 에 그대로 뒀어요. 필요하면 직접 푸세요."; mv "$t" "$dest/$base" ;;
        *)  mv "$t" "$dest/$base" ;;
    esac
    if [ $? -eq 0 ]; then [ -n "$mark" ] && touch "$mark"; else bad "$f: 풀지 못했어요(남은 공간과 권한을 확인하세요)"; fi
    rm -f "$t"
done < "$SUMS"
rm -rf "$TMP"; TMP=
[ "$FAILS" -eq 0 ] && ok "다 풀었어요" || warn "풀지 못한 파일이 있어요. 위 [문제] 줄의 파일만 다시 올리고 같은 명령을 다시 실행하세요(된 것은 건너뛰어요)"

# ------------------------------------------------------------------ 3. 검사
step 3 '검사 (데이터셋마다 라벨 파일이 있는지)'
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
# 라벨 위치를 정하지 않은 데이터셋(라이다·rosbag 까지 받은 것 등)은 파일 수만 보여 준다
for s in rellis_full go_full ORAD-3D CaSSeD freiburg_forest ycor; do
    [ -d "$D/$s" ] && printf '  %-11s %s\n' "$s" "${c_g}파일 $(find "$D/$s" -type f ! -name '.gpu_*' | wc -l)개${c_0}"
done
if [ -d "$D/RUGD" ] && [ ! -f "$D/RUGD/RUGD_annotation-colormap.txt" ]; then
    found=$(find "$D/RUGD" -name 'RUGD_annotation-colormap.txt' | head -1)
    if [ -n "$found" ]; then cp "$found" "$D/RUGD/"; ok "RUGD 색상표를 $D/RUGD 에 복사했어요"
    else bad "RUGD 색상표(RUGD/RUGD_annotation-colormap.txt)가 없어요. 가지고 있는 RUGD 사본에서 그 파일을 찾아 $D/RUGD/ 에 복사하세요."; fi
fi

echo
if [ "$FAILS" -eq 0 ]; then
    echo "${c_g}############################ 완료 ############################${c_0}"
    echo " 이번에 올린 데이터셋이 모두 정상이에요. 위치: $D"
    [ -n "$skipped" ] && echo " 이번에 올리지 않은 것:$skipped (나눠 올렸다면 다음 묶음을 올려 같은 순서로 설치하세요)"
    [ -n "$conflict" ] && echo " 같은 이름의 폴더가 이미 있어서 건너뛴 것:$conflict (위 [주의] 를 보고 정리한 뒤 다시 실행하세요)"
    echo " 엑셀 '데이터셋 목록' 시트의 진행 상황을 '서버 반입'으로 바꾸세요."
    echo " 다음 단계: 사전학습 모델(docs/1_처음_설치.md 5단계)"
    echo " NAS에 들어가서 두 서버 모두 바로 써요. 올린 원본은 지워도 돼요: NAS 의 $SRC 에서 이번에 넣은 데이터셋 폴더(FileZilla), root 의 /app/inbox/datasets"
    echo "${c_g}##############################################################${c_0}"
else
    echo "${c_r}############## 끝났지만 문제 ${FAILS}개 ##############${c_0}"
    echo " 빨간 줄을 확인하세요. '라벨을 못 찾음'은 압축 안 폴더가 한 단계 더 있거나 없는 경우가 많아요."
    echo " '지금 구조'를 보고 라벨 위치에 맞게 폴더를 옮기세요(docs/5_데이터셋.md 의 \"라벨 위치\")."
    echo " 기록 파일: $LOG"
    echo " NAS 의 $SRC 와 /app/inbox/datasets 는 문제가 풀릴 때까지 지우지 마세요."
    exit 1
fi
