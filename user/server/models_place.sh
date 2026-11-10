#!/usr/bin/env bash
# [GPU 서버 · 사용자(공용 계정)] NAS inbox 에 올린 models 폴더의 모델을 NAS 팀 폴더의 /data/autonomy_sw/models/<만든 곳>/<모델> 아래 둔다(5단계).
# 점검 → 체크섬 확인 → 제자리로 옮기기 → 가중치 파일을 열어 보는 검사까지 한 번에 한다.
#   bash /data/autonomy_sw/inbox/models/models_place.sh
# 다시 실행해도 된다. 이미 옮긴 것은 건너뛴다. 모델 폴더 몇 개씩 나눠 올려도 된다.
# models 폴더에 원래 있던 다른 폴더는 건드리지 않는다. 같은 이름의 모델 폴더가 있는데 이 스크립트가 넣은 것이 아니면 그 모델은 건너뛰고 알린다
set -uo pipefail
if [ "$(uname -s)" != Linux ]; then echo "이 스크립트는 GPU 서버(리눅스)에서 실행해요. 접근 PC에서는 pc 폴더의 .ps1 을 쓰세요."; exit 1; fi
# 모델은 팀원이 같이 쓰고 고치는 것이라 공용 계정으로 넣는다. root 로 넣으면 팀원이 고치거나 지울 수 없는 파일이 생긴다
if [ "$(id -u)" = 0 ] && [ -z "${GPU_TEST_ROOT_OK:-}" ]; then echo "멈춤: root 말고 공용 계정으로 실행하세요(모델 넣기는 사용자 몫이에요): bash $0"; exit 1; fi
cd "$(dirname "$0")"
HERE=$PWD   # 올린 models 폴더. 목록(MANIFEST.sha256)과 이 스크립트, 모델 폴더가 같이 있다
APP=${GPU_APP:-/app}   # 시험할 때만 바꾼다(tests/run.sh)
# 넣을 곳: NAS 팀 폴더의 models(/app/admin/gpu.conf 의 NAS_DIR, 기본 /data/autonomy_sw)
NAS=${GPU_NAS_DIR:-$(sed -n 's/^NAS_DIR=\([^ #]*\).*/\1/p' "$APP/admin/gpu.conf" 2>/dev/null | tail -1)}   # GPU_NAS_DIR: 시험할 때만
NAS=${NAS:-/data/autonomy_sw}
D="$NAS/models"
SRC=$HERE
[ -d "$D" ] || { echo "멈춤: 넣을 곳($D)이 없어요. 관리자에게 NAS 팀 폴더를 준비해 달라고 하세요(admin/1_처음_설치.md 1단계)."; exit 1; }
[ -w "$D" ] || { echo "멈춤: $D 에 쓸 수 없어요. 관리자에게 공용 계정이 쓸 수 있게 해 달라고 하세요(admin/5_NAS.md 의 \"폴더 구조\")."; exit 1; }
LOG="$HERE/models_place_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "$LOG") 2>&1
T=3
FAILS=0
PY=python3   # 표준 라이브러리만 쓴다. -I 로 실행해 지금 폴더의 파일을 모듈로 잘못 읽지 않게 한다

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
    echo "기록 파일: $LOG  (해결이 안 되면 admin/6_문제_해결.md)"
    exit 1
}

echo "[GPU 서버] 사전학습 모델 넣기  ($(date '+%Y-%m-%d %H:%M'), $(hostname), $(id -un))"
echo "올린 곳:   $SRC"
echo "두는 곳:   $D"

# ------------------------------------------------------------------ 1. 점검
step 1 '점검'
[ -f MANIFEST.sha256 ] || stop "MANIFEST.sha256 파일이 없어요" "접근 PC의 models 폴더 자체를 NAS 의 $(dirname "$SRC") 에 올렸는지 확인하세요(폴더 안에 폴더가 한 겹 더 있으면 안 돼요)."
# 목록이 비었거나 모양이 다른 줄이 있으면 따로 본다
[ "$(grep -c . MANIFEST.sha256)" -gt 0 ] && ! grep -v '^$' MANIFEST.sha256 | grep -qvE '^[0-9a-f]{64}  [^/].*$' && ! grep -q '\.\./' MANIFEST.sha256 ||
    stop "체크섬 목록(MANIFEST.sha256)이 비었거나 모양이 이상해요" "접근 PC에서 models_download.ps1 을 다시 실행해 목록을 새로 만든 뒤 models 폴더를 다시 올리세요."
# 체크섬 목록에는 접근 PC에서 받은 모든 모델이 들어 있다. 나눠 올릴 수 있게,
# 이번에 올린 모델 폴더(목록의 맨 앞 폴더, 예: org__model)만 다룬다. 폴더째 안 올린 모델은 건너뛴다
SUMS=$(mktemp); trap 'rm -f "$SUMS"' EXIT
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
[ -s "$SUMS" ] || stop "넣을 모델이 없어요" "$SRC 안에 모델 폴더(예: facebook__mask2former-swin-large-cityscapes-semantic)를 넣어 올렸는지, 위 [주의] 의 같은 이름 폴더를 정리했는지 확인하세요(user/모델_넣기.md)."
# 빠진 파일은 먼저 알린다(이미 제자리로 옮긴 파일이나 다 넣은 모델의 파일은 올린 곳에 없어도 된다)
have() { local m=${1%%/*}; [ -f "$SRC/$1" ] || [ -f "$D/${m/__//}/${1#*/}" ] || [ -f "$D/${m/__//}/gpu_model.json" ]; }
missing=$( { sed -n 's/^[0-9a-f]\{64\}  //p' "$SUMS"; for m in "${dirs[@]}"; do echo "$m/gpu_model.json"; done; } | while IFS= read -r f; do have "$f" || echo "$f"; done)
if [ -n "$missing" ]; then
    echo "$missing" | head -20 | sed 's/^/    없는 파일: /'
    stop "올린 폴더에 빠진 파일이 있어요" "위 파일을 접근 PC에서 $SRC 같은 자리에 다시 올리세요(FileZilla 이어 올리기)."
fi
n=$(grep -c . "$SUMS" || true)
ok "넣을 모델 ${#dirs[@]}개, 파일 ${n}개가 모두 있어요"
need=$(( $(for m in "${dirs[@]}"; do du -sm "$SRC/$m"; done | awk '{t += $1} END {print t + 0}') / 1024 + 5 ))
free=$(( $(df -Pm "$D" | awk 'NR==2 {print $4}') / 1024 ))
[ "$free" -ge "$need" ] || stop "남은 공간이 ${free} GB예요(약 ${need} GB 필요)" "NAS 팀 폴더($NAS)의 안 쓰는 파일을 정리하거나 서버 관리 팀에 물어보세요."
ok "남은 공간 ${free} GB (필요한 공간 약 ${need} GB)"

# ------------------------------------------------------------------ 2. 옮기기
step 2 "체크섬 확인하고 옮기기 → $D/<만든 곳>/<모델>"
for d in "${dirs[@]}"; do
    repo=${d/__//}
    dest="$D/$repo"
    if [ -f "$dest/gpu_model.json" ] && { [ ! -f "$SRC/$d/gpu_model.json" ] || cmp -s "$SRC/$d/gpu_model.json" "$dest/gpu_model.json"; } &&
       { ! grep -qF "  $d/code.zip" "$SUMS" || [ -d "$dest/code" ]; }; then
        echo "  $repo: 이미 있어요"; continue
    fi
    echo "  $repo 확인하는 중이에요"
    # gpu_model.json(모델 이름·라이선스)은 목록에 없어서, JSON 이고 폴더 이름과 같은 모델인지 따로 확인한다
    if ! "$PY" -I -c 'import json,sys; m=json.load(open(sys.argv[1],encoding="utf-8")); sys.exit(0 if isinstance(m,dict) and m.get("repo")==sys.argv[2] else 1)' "$SRC/$d/gpu_model.json" "$repo" 2>/dev/null; then
        bad "$repo: gpu_model.json 이 이상해요(모델 이름이 폴더와 다르거나 JSON 이 아니에요). 접근 PC의 모델 폴더를 다시 올리세요"; continue
    fi
    [ -d "$dest" ] || { mkdir -p "$dest" && touch "$dest/.gpu_placed"; }
    ok_all=1
    while IFS= read -r line; do
        sum=${line%%  *}; f=${line#*  }
        out="$dest/${f#"$d"/}"; src="$SRC/$f"
        [ ! -f "$src" ] && [ -f "$out" ] && continue   # 지난번에 이미 옮긴 파일
        if ! printf '%s  %s\n' "$sum" "$src" | sha256sum -c --quiet --strict - >/dev/null 2>&1; then
            bad "$f: 체크섬이 맞지 않아요(받거나 올리는 중에 깨졌어요). 이 파일만 다시 올리고 다시 실행하세요"; ok_all=; continue
        fi
        mkdir -p "$(dirname "$out")" && mv "$src" "$out" || { bad "$f: 옮기지 못했어요(남은 공간과 권한을 확인하세요)"; ok_all=; }
    done < <(grep -F "  $d/" "$SUMS")
    # 파일이 모두 맞을 때만 gpu_model.json 을 둔다(이게 있어야 "이미 있어요" 로 건너뛴다)
    [ -n "$ok_all" ] && cp "$SRC/$d/gpu_model.json" "$dest/gpu_model.json" || continue
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
    echo " 불러오기 예: from_pretrained(\"$D/<만든 곳>/<모델>\")  (user/모델_넣기.md)"
    echo " NAS에 들어가서 두 서버 모두 바로 써요. 올린 곳($SRC)의 이번에 넣은 모델 폴더는 지워도 돼요(파일은 이미 옮겼어요)"
    echo "${c_g}##############################################################${c_0}"
else
    echo "${c_r}############## 끝났지만 문제 ${FAILS}개 ##############${c_0}"
    echo " 빨간 줄의 파일이나 모델 폴더만 접근 PC에서 $SRC 같은 자리에 다시 올린 뒤 다시 실행하세요(된 것은 건너뛰어요)."
    echo " 기록 파일: $LOG"
    echo " 올린 곳($SRC)은 문제가 풀릴 때까지 지우지 마세요."
    exit 1
fi
