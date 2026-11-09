#!/usr/bin/env bash
# [GPU 서버 · 관리자(root)] NAS inbox 에 올린 models 폴더의 모델을 NAS 팀 폴더의 /data/autonomy_sw/models/<만든 곳>/<모델> 아래 둔다(5단계).
# 점검 → 파일마다 root 전용 임시 폴더로 복사해 체크섬 확인 → 제자리로 옮기기 → 가중치 파일을 열어 보는 검사까지 한 번에 한다.
#   /app/admin/bin/gpu fetch models       # 목록(MANIFEST.sha256)과 이 스크립트만 /app/inbox/models 로 복사하고 지문을 보여 준다
#   bash /app/inbox/models/models_place.sh
# 다시 실행해도 된다. 이미 옮긴 것은 건너뛴다. 모델 폴더 몇 개씩 나눠 올려도 된다.
# 데이터 파일은 NAS inbox(공용 계정이 고칠 수 있는 곳)에 둔 채로 쓴다. 그래서 root 는 파일을 하나씩 root 전용 임시 폴더에 복사하고,
# 그 복사본의 체크섬이 목록과 맞을 때만 제자리로 옮긴다
# models 폴더에 원래 있던 다른 폴더는 건드리지 않는다. 같은 이름의 모델 폴더가 있는데 이 스크립트가 넣은 것이 아니면 그 모델은 건너뛰고 알린다
set -uo pipefail
if [ "$(uname -s)" != Linux ]; then echo "이 스크립트는 GPU 서버(리눅스)에서 실행해요. 접근 PC에서는 pc 폴더의 .ps1 을 쓰세요."; exit 1; fi
cd "$(dirname "$0")"
HERE=$PWD   # 목록(MANIFEST.sha256)과 이 스크립트가 있는 곳. root 는 gpu fetch 가 복사한 /app/inbox/models 에서 실행한다
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
# 목록과 스크립트는 root 만 고칠 수 있는 곳(gpu fetch 가 복사한 /app/inbox/models)에 있어야 믿는다
if [ "$(id -u)" = 0 ] && ! safe_dir "$HERE"; then
    echo "멈춤: $HERE 를 root 말고도 고칠 수 있어요. root 로 목록과 스크립트를 복사한 뒤 거기서 실행하세요: /app/admin/bin/gpu fetch models"; exit 1
fi
# 넣을 곳: NAS 팀 폴더의 models(/app/admin/gpu.conf 의 NAS_DIR, 기본 /data/autonomy_sw). root 만 고치고 팀원은 읽는다
NAS=${GPU_NAS_DIR:-$(sed -n 's/^NAS_DIR=\([^ #]*\).*/\1/p' "$APP/admin/gpu.conf" 2>/dev/null | tail -1)}   # GPU_NAS_DIR: 시험할 때만
NAS=${NAS:-/data/autonomy_sw}
D="$NAS/models"
SRC=${GPU_SRC:-$NAS/inbox/models}   # 데이터 파일이 있는 곳(공용 계정이 FileZilla 로 올린 곳)
if [ "$(id -u)" = 0 ] && ! safe_dir "$D"; then
    echo "멈춤: 넣을 곳($D)이 없거나 root 말고도 고칠 수 있어요. 준비를 먼저 하세요(이미 있는 팀 폴더면 docs/8_NAS.md 의 \"이미 있는 팀 폴더 잠그기\"): cd /app/inbox && bash prepare.sh"; exit 1
fi
if [ -d "$D" ] && [ ! -w "$D" ]; then
    echo "멈춤: $D 는 root만 고칠 수 있어요. root로 같은 명령을 실행하세요: bash $HERE/models_place.sh"; exit 1
fi
[ -d "$SRC" ] || { echo "멈춤: 데이터 파일을 올린 곳($SRC)이 없어요. 접근 PC의 models 폴더를 공용 계정 FileZilla로 NAS 의 $(dirname "$SRC") 에 올리세요."; exit 1; }
LOG="$APP/admin/logs/models_place_$(date +%Y%m%d_%H%M%S).log"
mkdir -p "$D" "$APP/admin/logs"
exec > >(tee -a "$LOG") 2>&1
T=3
FAILS=0
PY=python3   # 표준 라이브러리만 쓴다. -I 로 실행해 올린 폴더의 json.py 같은 파일을 읽지 않는다

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
    echo "고친 뒤 같은 명령을 다시 실행하세요: bash $HERE/models_place.sh"
    echo "기록 파일: $LOG  (해결이 안 되면 docs/7_문제_해결.md)"
    exit 1
}

echo "[GPU 서버] 사전학습 모델 넣기  ($(date '+%Y-%m-%d %H:%M'), $(hostname), $(id -un))"
echo "목록:      $HERE/MANIFEST.sha256"
echo "올린 곳:   $SRC"
echo "두는 곳:   $D"

# ------------------------------------------------------------------ 1. 점검
step 1 '점검'
[ -f MANIFEST.sha256 ] || stop "MANIFEST.sha256 파일이 없어요" "root 로 목록을 복사하세요: /app/admin/bin/gpu fetch models"
# 목록이 비었거나 모양이 다른 줄이 있으면 따로 본다
[ "$(grep -c . MANIFEST.sha256)" -gt 0 ] && ! grep -v '^$' MANIFEST.sha256 | grep -qvE '^[0-9a-f]{64}  [^/].*$' && ! grep -q '\.\./' MANIFEST.sha256 ||
    stop "체크섬 목록(MANIFEST.sha256)이 비었거나 모양이 이상해요" "접근 PC에서 models_download.ps1 을 다시 실행해 목록을 새로 만든 뒤 models 폴더를 다시 올리세요."
# 체크섬 목록에는 접근 PC에서 받은 모든 모델이 들어 있다. 나눠 올릴 수 있게,
# 이번에 올린 모델 폴더(목록의 맨 앞 폴더, 예: org__model)만 다룬다. 폴더째 안 올린 모델은 건너뛴다
SUMS=$(mktemp); TMP=; trap 'rm -f "$SUMS"; [ -n "$TMP" ] && rm -rf "$TMP"' EXIT
skipped=; conflict=; dirs=()
for m in $(sed -n 's/^[0-9a-f]\{64\}  \([^/]*\)\/.*/\1/p' MANIFEST.sha256 | sort -u); do
    repo=${m/__//}
    if [ ! -d "$SRC/$m" ]; then skipped+=" $repo"; continue; fi
    # 같은 이름의 모델 폴더가 있는데 이 스크립트가 넣은 것(gpu_model.json 이나 처음 만들 때 남긴 .gpu_placed 가 있음)이 아니면 건너뛴다
    if [ -e "$D/$repo" ] && [ ! -f "$D/$repo/gpu_model.json" ] && [ ! -f "$D/$repo/.gpu_placed" ]; then conflict+=" $repo"; continue; fi
    dirs+=("$m"); grep -F "  $m/" MANIFEST.sha256 >> "$SUMS"
done
[ -n "$skipped" ] && echo "  이번에 올리지 않은 모델(건너뛰어요):$skipped"
if [ -n "$conflict" ]; then
    for r in $conflict; do warn "$D/$r 가 이미 있는데 이 스크립트가 넣은 폴더가 아니에요. 덮어쓰지 않고 건너뛰어요. 안을 확인하고 지우거나 이름을 바꾼 뒤 다시 실행하세요"; done
fi
[ -s "$SUMS" ] || stop "넣을 모델이 없어요" "NAS 의 $SRC 안에 모델 폴더(예: facebook__mask2former-swin-large-cityscapes-semantic)를 넣어 올렸는지, 위 [주의] 의 같은 이름 폴더를 정리했는지 확인하세요(docs/6_모델.md)."
links=$(for m in "${dirs[@]}"; do find "$SRC/$m" -type l; done | head -5)
[ -z "$links" ] || { echo "$links" | sed 's/^/    링크: /'; stop "올린 폴더에 링크가 있어요(누가 넣었을 수 있어요)" "NAS 의 $SRC 에서 그 모델 폴더를 지우고 접근 PC 폴더를 다시 올리세요."; }
missing=$( { sed -n 's/^[0-9a-f]\{64\}  //p' "$SUMS"; for m in "${dirs[@]}"; do echo "$m/gpu_model.json"; done; } | while IFS= read -r f; do [ -f "$SRC/$f" ] || echo "$f"; done)
if [ -n "$missing" ]; then
    echo "$missing" | head -20 | sed 's/^/    없는 파일: /'
    stop "올린 폴더에 빠진 파일이 있어요" "위 파일을 접근 PC에서 NAS 의 $SRC 같은 자리에 다시 올리세요(FileZilla 이어 올리기)."
fi
n=$(grep -c . "$SUMS" || true)
ok "넣을 모델 ${#dirs[@]}개, 파일 ${n}개가 모두 올라와 있어요"
need=$(( $(for m in "${dirs[@]}"; do du -sm "$SRC/$m"; done | awk '{t += $1} END {print t + 0}') / 1024 + 5 ))
free=$(( $(df -Pm "$D" | awk 'NR==2 {print $4}') / 1024 ))
[ "$free" -ge "$need" ] || stop "남은 공간이 ${free} GB예요(약 ${need} GB 필요)" "NAS 팀 폴더($NAS)의 안 쓰는 파일을 정리하거나 서버 관리 팀에 물어보세요."
ok "남은 공간 ${free} GB (필요한 공간 약 ${need} GB)"

# ------------------------------------------------------------------ 2. 옮기기
step 2 "복사해 확인하고 옮기기 → $D/<만든 곳>/<모델>"
# root 만 들어가는 임시 폴더. 넣을 곳과 같은 NAS 라서, 확인한 복사본을 제자리로 옮기기만 하면 된다
TMP="$D/.gpu_tmp_$$"; rm -rf "$TMP"; mkdir -m 700 "$TMP" || stop "임시 폴더($TMP)를 만들지 못했어요" "남은 공간과 권한을 확인하세요."
for d in "${dirs[@]}"; do
    repo=${d/__//}
    dest="$D/$repo"
    if [ -f "$dest/gpu_model.json" ] && cmp -s "$SRC/$d/gpu_model.json" "$dest/gpu_model.json" &&
       { ! grep -qF "  $d/code.zip" "$SUMS" || [ -d "$dest/code" ]; }; then
        echo "  $repo: 이미 있어요"; continue
    fi
    echo "  $repo 복사해 확인하는 중이에요"
    # 체크섬 목록에 없는 파일(예: 몰래 넣은 .py)은 root 소유 NAS 모델 폴더로 가져가지 않는다
    extra=$(comm -23 <(cd "$SRC" && find "$d" -type f ! -path "$d/.cache/*" ! -name '.gpu_*' ! -path "$d/gpu_model.json" | sort) \
                     <(sed -n "s|^[0-9a-f]\{64\}  \($d/.*\)|\1|p" "$SUMS" | sort))
    [ -z "$extra" ] || warn "$repo: 체크섬 목록에 없는 파일 $(echo "$extra" | grep -c .)개는 옮기지 않아요(예: $(echo "$extra" | head -1))"
    # gpu_model.json(모델 이름·라이선스)은 목록에 없어서, 복사본이 JSON 이고 폴더 이름과 같은 모델인지 확인한 뒤 옮긴다
    t="$TMP/f"
    if [ ! -f "$SRC/$d/gpu_model.json" ] || [ -L "$SRC/$d/gpu_model.json" ] || ! head -c 65536 "$SRC/$d/gpu_model.json" > "$t" ||
       ! "$PY" -I -c 'import json,sys; m=json.load(open(sys.argv[1],encoding="utf-8")); sys.exit(0 if isinstance(m,dict) and m.get("repo")==sys.argv[2] else 1)' "$t" "$repo"; then
        bad "$repo: gpu_model.json 이 이상해요(모델 이름이 폴더와 다르거나 JSON 이 아니에요). 접근 PC의 모델 폴더를 다시 올리세요"; rm -f "$t"; continue
    fi
    [ -d "$dest" ] || { mkdir -p "$dest" && touch "$dest/.gpu_placed"; }
    placed=1
    while IFS= read -r line; do
        sum=${line%%  *}; f=${line#*  }
        out="$dest/${f#"$d"/}"; src="$SRC/$f"; c="$TMP/c"
        if [ ! -f "$src" ] || [ -L "$src" ]; then bad "$f: 올린 곳에 보통 파일로 없어요"; placed=; continue; fi
        cp "$src" "$c" || { bad "$f: 복사하지 못했어요(남은 공간을 확인하세요)"; placed=; rm -f "$c"; continue; }
        if ! printf '%s  %s\n' "$sum" "$c" | sha256sum -c --quiet --strict - >/dev/null 2>&1; then
            bad "$f: 체크섬이 맞지 않아요(올리는 중에 깨졌거나 바뀌었어요). 이 파일만 다시 올리고 다시 실행하세요"; placed=; rm -f "$c"; continue
        fi
        mkdir -p "$(dirname "$out")" && mv "$c" "$out" || { bad "$f: 옮기지 못했어요(남은 공간과 권한을 확인하세요)"; placed=; }
    done < <(grep -F "  $d/" "$SUMS")
    # 파일이 모두 맞을 때만 gpu_model.json 을 둔다(이게 있어야 "이미 있어요" 로 건너뛴다)
    if [ -n "$placed" ]; then mv "$t" "$dest/gpu_model.json"; else rm -f "$t"; continue; fi
    # GitHub 코드 묶음은 code/ 폴더로 푼다(맨 위 폴더 한 단계는 뺀다)
    if [ -f "$dest/code.zip" ]; then
        rm -rf "$dest/code"
        "$PY" -I - "$dest/code.zip" "$dest/code" <<'EOF' && rm -f "$dest/code.zip" && echo "    코드를 풀었어요: $dest/code" || bad "$repo: 코드 묶음(code.zip)을 풀지 못했어요"
import os, sys, zipfile
src, out = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(src) as z:
    for i in z.infolist():
        rel = i.filename.split("/", 1)[1] if "/" in i.filename else ""
        parts = [p for p in rel.replace("\\", "/").split("/") if p not in ("", ".")]
        if not parts or ".." in parts or ":" in parts[0]:
            continue
        # 이름이 top//etc/... 처럼 / 로 시작해도 out 밖으로 나가지 않게 조각을 다시 붙이고, 마지막에 한 번 더 확인한다
        t = os.path.join(out, *parts)
        if os.path.commonpath([os.path.realpath(out), os.path.realpath(t)]) != os.path.realpath(out):
            continue
        if i.is_dir():
            os.makedirs(t, exist_ok=True)
            continue
        os.makedirs(os.path.dirname(t), exist_ok=True)
        with z.open(i) as a, open(t, "wb") as b:
            b.write(a.read())
EOF
    fi
done
rm -rf "$TMP"; TMP=
[ "$FAILS" -eq 0 ] && ok "다 옮겼어요" || warn "옮기지 못한 모델이 있어요. 위 [문제] 줄의 파일만 다시 올리고 같은 명령을 다시 실행하세요(된 것은 건너뛰어요)"

# ------------------------------------------------------------------ 3. 검사
step 3 '검사 (설정 파일과 가중치 파일을 열어 봐요)'
for d in "${dirs[@]}"; do
    repo=${d/__//}
    [ -f "$D/$repo/gpu_model.json" ] || continue   # 위에서 옮기지 못한 모델(이미 [문제] 로 셌어요)
    "$PY" -I - "$D/$repo" "$repo" <<'EOF' || FAILS=$((FAILS + 1))
import glob, json, os, struct, sys
d, repo = sys.argv[1], sys.argv[2]
meta = json.load(open(os.path.join(d, "gpu_model.json"), encoding="utf-8"))
st = glob.glob(os.path.join(d, "**", "*.safetensors"), recursive=True)
other = [p for e in ("*.bin", "*.pth", "*.pt", "*.ckpt") for p in glob.glob(os.path.join(d, "**", e), recursive=True)
         if os.sep + "code" + os.sep not in p]
bad = []
for p in st:  # safetensors 머리말(JSON)을 읽어 텐서 목록이 있는지 본다
    try:
        with open(p, "rb") as f:
            n = struct.unpack("<Q", f.read(8))[0]
            h = json.loads(f.read(n))
        if not [k for k in h if k != "__metadata__"]:
            bad.append(os.path.basename(p))
    except Exception:
        bad.append(os.path.basename(p))
size = sum(os.path.getsize(p) for p in glob.glob(os.path.join(d, "**", "*"), recursive=True) if os.path.isfile(p))
g, r, y, z = "\033[32m", "\033[31m", "\033[33m", "\033[0m"
if bad:
    print(f"  {r}[문제]{z} {repo}: 가중치 파일을 열지 못했어요: {', '.join(bad)}. 이 모델 폴더를 다시 올려 복사하세요")
    sys.exit(1)
if not st and not other:
    print(f"  {y}[주의]{z} {repo}: 가중치 파일이 없어요(설정만 있는 저장소일 수 있어요)")
    sys.exit(0)
kind = "safetensors" if st else "pytorch"
cfg = "config.json 있음" if os.path.exists(os.path.join(d, "config.json")) else "config.json 없음"
code = ", 코드(code/) 있음" if os.path.isdir(os.path.join(d, "code")) else ""
print(f"  {g}[정상]{z} {repo}: {size / 2**30:.1f} GB, {kind} {len(st) or len(other)}개, {cfg}{code}, 라이선스 {meta.get('license')}")
EOF
done

echo
if [ "$FAILS" -eq 0 ]; then
    echo "${c_g}############################ 완료 ############################${c_0}"
    echo " 이번에 올린 모델 ${#dirs[@]}개가 모두 정상이에요. 위치: $D"
    [ -n "$skipped" ] && echo " 이번에 올리지 않은 모델은 다음에 그 폴더만 올려 같은 방법으로 넣으면 돼요:$skipped"
    [ -n "$conflict" ] && echo " 같은 이름의 폴더가 이미 있어서 건너뛴 것:$conflict (위 [주의] 를 보고 정리한 뒤 다시 실행하세요)"
    echo " 불러오기 예: from_pretrained(\"$D/<만든 곳>/<모델>\")  (docs/6_모델.md)"
    echo " 다음 단계: 권한·규칙 설정(docs/1_처음_설치.md 6단계): cd /app/inbox && bash admin_setup.sh"
    echo " NAS에 들어가서 두 서버 모두 바로 써요. 올린 원본은 지워도 돼요: NAS 의 $SRC 에서 이번에 넣은 모델 폴더(FileZilla), root 의 /app/inbox/models"
    echo "${c_g}##############################################################${c_0}"
else
    echo "${c_r}############## 끝났지만 문제 ${FAILS}개 ##############${c_0}"
    echo " 빨간 줄의 파일이나 모델 폴더만 접근 PC에서 NAS 의 $SRC 같은 자리에 다시 올린 뒤 다시 실행하세요(된 것은 건너뛰어요)."
    echo " 기록 파일: $LOG"
    echo " NAS 의 $SRC 와 /app/inbox/models 는 문제가 풀릴 때까지 지우지 마세요."
    exit 1
fi
