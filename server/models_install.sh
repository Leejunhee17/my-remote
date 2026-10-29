#!/usr/bin/env bash
# [B200 서버 · 관리자(root)] 접근 PC에서 올린 models 폴더를 /app/shared/models/<만든 곳>/<모델> 아래 둔다(admin_setup.sh 다음).
# 점검(체크섬) → 옮기기 → 가중치 파일을 열어 보는 검사까지 한 번에 한다.
#   bash /app/inbox/models/models_install.sh
# 다시 실행해도 된다. 이미 옮긴 것은 건너뛴다.
set -uo pipefail
if [ "$(uname -s)" != Linux ]; then echo "이 스크립트는 B200 서버(리눅스)에서 실행해요. 접근 PC에서는 pc 폴더의 .ps1 을 쓰세요."; exit 1; fi
cd "$(dirname "$0")"
SRC=$PWD
# root 는 공용 계정이 올린 폴더를 /app/inbox 로 새로 복사한 뒤 실행한다. 복사본에 링크가 있으면 누가 심은 것이라 멈춘다
if [ "$(id -u)" = 0 ] && [ -n "$(find "$SRC" -type l -print -quit)" ]; then
    echo "멈춤: $SRC 안에 링크가 있어요(올린 폴더에 누가 넣었을 수 있어요). /app/upload/models 를 지우고 접근 PC 폴더를 다시 올린 뒤 새로 복사하세요: rm -rf $SRC && cp -r /app/upload/models /app/inbox/"; exit 1
fi
# root 로 설치할 때는 /app 이 잠겨 있어야 한다(admin_setup.sh). 공용 계정이 /app 에 링크를 심어 두면 root 가 시스템 폴더에 쓰게 된다
if [ "$(id -u)" = 0 ] && [ -d /app ] && { [ "$(stat -c %U /app)" != root ] || [ -L /app/shared ] || [ -L /app/workspace ]; }; then
    echo "멈춤: /app이 아직 잠기지 않았어요. 관리자 기본 설정을 먼저 하세요: cd /app/inbox && bash admin_setup.sh"; exit 1
fi
# 공용 폴더 실제 위치. 관리자 설정(admin_setup.sh) 뒤에는 /app/shared 이고 root 만 고칠 수 있다
SH=$(realpath -m "$HOME/shared"); [ -d /app/shared ] && SH=/app/shared
if [ -d "$SH" ] && [ ! -w "$SH" ]; then
    echo "멈춤: 공용 폴더($SH)는 root만 고칠 수 있어요. root로 같은 명령을 실행하세요: bash $SRC/models_install.sh"; exit 1
fi
D="$SH/models"
LOG="$SH/logs/models_install_$(date +%Y%m%d_%H%M%S).log"
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
    echo "${c_r}무엇이: $1${c_0}"
    echo "할 일 : $2"
    echo "고친 뒤 같은 명령을 다시 실행하세요: bash $SRC/models_install.sh"
    echo "기록 파일: $LOG  (해결이 안 되면 docs/8_문제_해결.md)"
    exit 1
}

echo "[B200 서버] 사전학습 모델 설치  ($(date '+%Y-%m-%d %H:%M'), $(hostname), $(id -un))"
echo "가져올 곳: $SRC"
echo "두는 곳: $D"

# ------------------------------------------------------------------ 1. 점검
step 1 '점검'
[ -f MANIFEST.sha256 ] || stop "MANIFEST.sha256 파일이 없어요" "접근 PC의 models 폴더를 통째로 /app/upload 에 올리고 /app/inbox 로 복사했는지 확인하세요(docs/7_모델.md)."
n=$(grep -c . MANIFEST.sha256 || true)
echo "  파일 ${n}개의 체크섬을 확인하고 있어요(100 GB면 10분 안팎)"
bad_files=$(sha256sum -c --quiet MANIFEST.sha256 2>/dev/null | sed 's/: .*//')
if [ -n "$bad_files" ]; then
    echo "$bad_files" | head -20 | sed 's/^/    깨졌거나 없는 파일: /'
    stop "올리는 중에 깨졌거나 빠진 파일이 있어요" "위 파일이 든 모델 폴더만 접근 PC에서 /app/upload/models 의 같은 자리에 다시 올리고, root로 /app/inbox/models 의 같은 자리에 복사하세요. 체크섬은 이 스크립트가 다시 확인해요."
fi
ok "파일 ${n}개의 체크섬이 맞아요"

need=$(( $(du -sm . | cut -f1) / 1024 + 5 ))
free=$(( $(df -Pm "$D" | awk 'NR==2 {print $4}') / 1024 ))
[ "$free" -ge "$need" ] || stop "남은 공간이 ${free} GB예요(약 ${need} GB 필요)" "/app/upload 의 원본이나 안 쓰는 파일을 지워 공간을 비우세요. 그래도 모자라면 서버 관리 팀에 디스크를 요청하세요."
ok "남은 공간 ${free} GB (필요한 공간 약 ${need} GB)"

# ------------------------------------------------------------------ 2. 옮기기
step 2 "옮기기 → $D/<만든 곳>/<모델>"
PY="$SH/tools/bin/python"; [ -x "$PY" ] || PY=python3   # 표준 라이브러리만 쓴다
mapfile -t dirs < <(sed -n 's/^[0-9a-f]\{64\}  \([^/]*\)\/.*/\1/p' MANIFEST.sha256 | sort -u)
for d in "${dirs[@]}"; do
    repo=${d/__//}
    dest="$D/$repo"
    if [ -f "$dest/b200_model.json" ] && cmp -s "$d/b200_model.json" "$dest/b200_model.json" &&
       { [ ! -f "$d/code.zip" ] || [ -d "$dest/code" ]; }; then
        echo "  $repo: 이미 있어요"; continue
    fi
    echo "  $repo 옮기는 중이에요"
    mkdir -p "$dest"
    # 받기 도구가 남긴 .cache, 상태 파일은 옮기지 않는다
    { cp -a "$d/." "$dest/" && rm -rf "$dest/.cache" "$dest"/.b200_*; } ||
        { bad "$repo: 옮기지 못했어요(남은 공간과 권한을 확인하세요)"; continue; }
    # GitHub 코드 묶음은 code/ 폴더로 푼다(맨 위 폴더 한 단계는 뺀다)
    if [ -f "$dest/code.zip" ]; then
        rm -rf "$dest/code"
        "$PY" - "$dest/code.zip" "$dest/code" <<'EOF' && rm -f "$dest/code.zip" && echo "    코드를 풀었어요: $dest/code" || bad "$repo: 코드 묶음(code.zip)을 풀지 못했어요"
import os, sys, zipfile
src, out = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(src) as z:
    for i in z.infolist():
        rel = i.filename.split("/", 1)[1] if "/" in i.filename else ""
        if not rel or ".." in rel.split("/"):
            continue
        t = os.path.join(out, rel)
        if i.is_dir():
            os.makedirs(t, exist_ok=True)
            continue
        os.makedirs(os.path.dirname(t), exist_ok=True)
        with z.open(i) as a, open(t, "wb") as b:
            b.write(a.read())
EOF
    fi
done
ok "다 옮겼어요"

# ------------------------------------------------------------------ 3. 검사
step 3 '검사 (설정 파일과 가중치 파일을 열어 봐요)'
for d in "${dirs[@]}"; do
    repo=${d/__//}
    "$PY" - "$D/$repo" "$repo" <<'EOF' || FAILS=$((FAILS + 1))
import glob, json, os, struct, sys
d, repo = sys.argv[1], sys.argv[2]
meta = json.load(open(os.path.join(d, "b200_model.json"), encoding="utf-8"))
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
    echo " 모델 ${#dirs[@]}개가 모두 정상이에요. 위치: $D"
    echo " 불러오기 예: from_pretrained(\"$D/<만든 곳>/<모델>\")  (docs/7_모델.md)"
    echo " 다음 단계: 공용 계정으로 접속해 확인(docs/1_처음_설치.md 6단계)"
    echo " 공간 정리: rm -rf /app/inbox/models /app/upload/models"
    echo "${c_g}##############################################################${c_0}"
else
    echo "${c_r}############## 끝났지만 문제 ${FAILS}개 ##############${c_0}"
    echo " 빨간 줄의 모델 폴더만 접근 PC에서 /app/upload/models 에 다시 올리고 /app/inbox/models 로 복사한 뒤 다시 실행하세요."
    echo " 기록 파일: $LOG"
    echo " /app/inbox/models 는 문제가 풀릴 때까지 지우지 마세요."
    exit 1
fi
