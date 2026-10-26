#!/usr/bin/env bash
# [B200 서버] 접근 PC에서 올린 models 폴더를 ~/shared/models/<만든 곳>/<모델> 아래 둔다. root 없이 된다.
# 점검(체크섬) → 옮기기 → 가중치 파일을 열어 보는 검사까지 한 번에 한다.
#   bash ~/inbox/models/models_install.sh
# 다시 실행해도 된다. 이미 옮긴 것은 건너뛴다.
set -uo pipefail
if [ "$(uname -s)" != Linux ]; then echo "이 스크립트는 B200 서버(리눅스)에서 실행한다. 접근 PC에서는 .ps1 을 쓴다."; exit 1; fi
cd "$(dirname "$0")"
SRC=$PWD
D="$HOME/shared/models"
LOG="$HOME/shared/logs/models_install_$(date +%Y%m%d_%H%M%S).log"
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

echo "[B200 서버] 사전학습 모델 설치  ($(date '+%Y-%m-%d %H:%M'), $(hostname), $(id -un))"
echo "올린 곳: $SRC"
echo "두는 곳: $D"

# ------------------------------------------------------------------ 1. 점검
step 1 '점검'
[ -f MANIFEST.sha256 ] || stop "MANIFEST.sha256 이 없다" "접근 PC의 models 폴더를 통째로 ~/inbox/models 에 올렸는지 본다."
n=$(grep -c . MANIFEST.sha256 || true)
echo "  파일 ${n}개 체크섬 확인 중 (100 GB면 10분 안팎)"
bad_files=$(sha256sum -c --quiet MANIFEST.sha256 2>/dev/null | sed 's/: .*//')
if [ -n "$bad_files" ]; then
    echo "$bad_files" | head -20 | sed 's/^/    깨짐 또는 없음: /'
    stop "올리는 중에 깨졌거나 빠진 파일이 있다" "위 파일이 든 모델 폴더만 접근 PC에서 다시 올려 덮어쓴다."
fi
ok "파일 ${n}개 체크섬 일치"

need=$(( $(du -sm . | cut -f1) / 1024 + 5 ))
free=$(( $(df -Pm "$D" | awk 'NR==2 {print $4}') / 1024 ))
[ "$free" -ge "$need" ] || stop "남은 공간이 ${free} GB 다(약 ${need} GB 필요)" "공간을 비우거나 관리자에게 큰 디스크를 요청한다."
ok "남은 공간 ${free} GB (필요 약 ${need} GB)"

# ------------------------------------------------------------------ 2. 옮기기
step 2 "옮기기 → $D/<만든 곳>/<모델>"
mapfile -t dirs < <(sed -n 's/^[0-9a-f]\{64\}  \([^/]*\)\/.*/\1/p' MANIFEST.sha256 | sort -u)
for d in "${dirs[@]}"; do
    repo=${d/__//}
    dest="$D/$repo"
    if [ -f "$dest/b200_model.json" ] && cmp -s "$d/b200_model.json" "$dest/b200_model.json"; then
        echo "  $repo : 이미 있음"; continue
    fi
    echo "  $repo 옮기는 중"
    mkdir -p "$dest"
    # 받기 도구가 남긴 .cache, 상태 파일은 옮기지 않는다
    { cp -a "$d/." "$dest/" && rm -rf "$dest/.cache" "$dest"/.b200_*; } ||
        { bad "$repo 옮기기 실패(공간이나 권한을 본다)"; continue; }
done
ok "옮기기 끝"

# ------------------------------------------------------------------ 3. 검사
step 3 '검사 (설정 파일과 가중치 파일을 열어 본다)'
PY="$HOME/shared/venv/bin/python"; [ -x "$PY" ] || PY=python3
for d in "${dirs[@]}"; do
    repo=${d/__//}
    "$PY" - "$D/$repo" "$repo" <<'EOF' || FAILS=$((FAILS + 1))
import glob, json, os, struct, sys
d, repo = sys.argv[1], sys.argv[2]
meta = json.load(open(os.path.join(d, "b200_model.json"), encoding="utf-8"))
st = glob.glob(os.path.join(d, "**", "*.safetensors"), recursive=True)
other = [p for e in ("*.bin", "*.pth", "*.pt", "*.ckpt") for p in glob.glob(os.path.join(d, "**", e), recursive=True)]
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
    print(f"  {r}[문제]{z} {repo}: 가중치 파일을 못 연다 {bad}")
    sys.exit(1)
if not st and not other:
    print(f"  {y}[주의]{z} {repo}: 가중치 파일이 없다(설정만 있는 저장소일 수 있다)")
    sys.exit(0)
kind = "safetensors" if st else "pytorch"
cfg = "config 있음" if os.path.exists(os.path.join(d, "config.json")) else "config 없음"
print(f"  {g}[정상]{z} {repo}: {size / 2**30:.1f} GB, {kind} {len(st) or len(other)}개, {cfg}, 라이선스 {meta.get('license')}")
EOF
done

echo
if [ "$FAILS" -eq 0 ]; then
    echo "${c_g}############################ 완료 ############################${c_0}"
    echo " 모델 ${#dirs[@]}개 정상. 위치: $D"
    echo " 불러오기 예: from_pretrained(\"$D/<만든 곳>/<모델>\")  (모델_명령어.md)"
    echo " 정리: rm -rf ~/inbox/models"
    echo "${c_g}##############################################################${c_0}"
else
    echo "${c_r}############## 끝났지만 문제 ${FAILS}개 ##############${c_0}"
    echo " 빨간 줄의 모델 폴더만 접근 PC에서 다시 올린다."
    echo " 해결이 안 되면 이 파일을 담당자에게 보내 준다: $LOG"
    echo " ~/inbox/models 는 문제가 풀릴 때까지 지우지 않는다."
    exit 1
fi
