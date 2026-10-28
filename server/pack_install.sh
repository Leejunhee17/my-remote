#!/usr/bin/env bash
# [B200 서버] b200-pack.tar 를 공용 폴더(~/shared) 아래 설치한다. root 없이 된다.
# 점검 → 설치 → 검사까지 한 번에 한다. 실패하면 고친 뒤 다시 실행하면 된다.
#   bash pack_install.sh               ~/shared 에 설치
#   bash pack_install.sh /app/shared   큰 디스크에 설치하고 ~/shared 는 그곳으로 가는 링크로 만든다.
#                                      개인 작업 폴더 /app/workspace 와 링크 ~/workspace 도 없으면 만든다
set -uo pipefail
if [ "$(uname -s)" != Linux ]; then echo "이 스크립트는 B200 서버(리눅스)에서 실행한다. 접근 PC에서는 .ps1 을 쓴다."; exit 1; fi
cd "$(dirname "$0")"
HERE=$PWD
# root 로 설치할 때는 /app 이 잠겨 있어야 한다(admin_setup.sh). 공용 계정이 /app 에 링크를 심어 두면 root 가 시스템 폴더에 쓰게 된다
if [ "$(id -u)" = 0 ] && [ -d /app ] && { [ "$(stat -c %U /app)" != root ] || [ -L /app/shared ] || [ -L /app/workspace ]; }; then
    echo "멈춤: /app 이 아직 잠기지 않았다. 먼저 root 로 bash admin_setup.sh 를 실행한다."; exit 1
fi

# 공용 폴더를 큰 디스크에 두라고 했으면 ~/shared 를 그곳으로 가는 링크로 만든다.
# 이후 모든 경로는 ~/shared 로 쓰므로 문서와 다른 스크립트를 그대로 쓸 수 있다.
REAL=${1:-}
if [ -n "$REAL" ]; then
    REAL=$(realpath -m "$REAL")
    mkdir -p "$REAL" 2>/dev/null || { echo "멈춤: $REAL 를 만들 수 없다. 쓰기 권한을 확인한다."; exit 1; }
    if [ -L "$HOME/shared" ]; then
        [ "$(realpath "$HOME/shared")" = "$REAL" ] ||
            { echo "멈춤: ~/shared 가 이미 $(realpath "$HOME/shared") 로 가는 링크다. 그 경로를 주거나 링크를 지우고 다시 실행한다."; exit 1; }
    elif [ -d "$HOME/shared" ]; then
        if [ "$(du -sm "$HOME/shared" | cut -f1)" -lt 200 ]; then
            # 지난번 실패한 실행이 남긴 기록 정도라 옮기고 링크로 바꾼다
            cp -a "$HOME/shared/." "$REAL/" && rm -rf "$HOME/shared" && ln -s "$REAL" "$HOME/shared" ||
                { echo "멈춤: ~/shared 를 $REAL 로 옮기지 못했다."; exit 1; }
        else
            echo "멈춤: ~/shared 에 이미 설치된 내용이 있다. README 의 \"공용 폴더를 큰 디스크로 옮기기\" 로 먼저 옮긴다."; exit 1
        fi
    else
        ln -s "$REAL" "$HOME/shared"
    fi
    # 같은 디스크에 개인 작업 폴더를 두고 홈에는 링크만 둔다(OS를 새로 깔았을 때 다시 만들 필요 없게)
    W="$(dirname "$REAL")/workspace"
    if [ ! -e "$HOME/workspace" ] && mkdir -p "$W" 2>/dev/null; then ln -s "$W" "$HOME/workspace"; fi
fi
# 실제 경로로 적어야 venv·기초 프로그램에 박히는 경로가 누구에게나 맞다(예: /app/shared)
S=$(realpath -m "$HOME/shared")
if [ -d "$S" ] && [ ! -w "$S" ]; then
    echo "멈춤: 공용 폴더($S)는 관리자(root)만 고칠 수 있다. 관리자 계정으로 bash pack_install.sh /app/shared 를 실행한다."; exit 1
fi
LOG="$S/logs/pack_install_$(date +%Y%m%d_%H%M%S).log"
mkdir -p "$S/logs"
exec > >(tee -a "$LOG") 2>&1
T=5
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
    echo "고친 뒤 같은 명령(bash pack_install.sh)을 다시 실행하면 된다."
    echo "해결이 안 되면 이 파일을 담당자에게 보내 준다: $LOG"
    exit 1
}
info() { sed -n "s/^$1=//p" pack_info.txt; }
ver_ge() { [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -1)" = "$2" ]; }

echo "[B200 서버] 공용 휠·기초 프로그램 설치  ($(date '+%Y-%m-%d %H:%M'), $(hostname), $(id -un))"
echo "  운영체제: $(. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME")"

# ------------------------------------------------------------------ 1. 점검
step 1 '점검'
for f in MANIFEST.sha256 micromamba explicit.txt lock.txt pack_info.txt pkgs wheels; do
    [ -e "$f" ] || stop "$f 가 없다" "$HERE 에서 tar xf b200-pack.tar 를 했는지 본다. 했다면 접근 PC에서 묶음 파일을 다시 올린다."
done
echo "  묶음 정보: $(info made) 에 만듦, glibc $(info glibc), $(info torch)"

echo "  파일 체크섬 확인 중 (1~3분)"
# 설치 스크립트 자신은 고친 판을 따로 올려 덮어쓸 수 있도록 검사에서 뺀다
bad_files=$(grep -vE '  ((pack_install|move_shared|check_server|check_network|admin_setup)\.sh|bin/.*)$' MANIFEST.sha256 | sha256sum -c --quiet - 2>/dev/null | sed 's/: .*//')
if [ -n "$bad_files" ]; then
    echo "$bad_files" | head -20 | sed 's/^/    깨짐: /'
    stop "올리는 중에 파일이 깨졌다($(echo "$bad_files" | wc -l)개)" \
         "접근 PC의 pack\\b200-pack.tar 를 다시 올린다. B200 서버에서는 $HERE 를 비운 뒤 다시 푼다."
fi
ok "파일 $(grep -cvE '  ((pack_install|move_shared|check_server|check_network|admin_setup)\.sh|bin/.*)$' MANIFEST.sha256)개 체크섬 일치"

glibc=$(ldd --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+$')
if ver_ge "$glibc" "$(info glibc)"; then
    ok "B200 서버 glibc $glibc (묶음 기준 $(info glibc))"
else
    stop "B200 서버 glibc 가 $glibc 다. 묶음은 $(info glibc) 기준이라 안 맞는다" \
         "접근 PC에서 -Glibc $glibc 를 붙여 pack_build.ps1 을 다시 실행해 새 묶음 파일을 올린다."
fi

if command -v nvidia-smi >/dev/null; then
    drv=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -1)
    ngpu=$(nvidia-smi -L | wc -l)
    if ver_ge "$drv" 580; then ok "GPU $ngpu 장, 드라이버 $drv (CUDA $(info cuda) 가능)"
    else warn "드라이버 $drv 는 CUDA $(info cuda) 휠에 낮다(580 이상 필요). 설치는 되지만 GPU를 못 쓸 수 있다. 서버 관리 팀에 드라이버 업데이트를 요청한다."; fi
else
    warn "nvidia-smi 가 없다. 설치는 하지만 GPU 확인은 못 한다."
fi

need=$(( $(du -sm wheels pkgs | awk '{s+=$1} END {print s}') / 1024 + 25 ))
# ~/shared 가 큰 디스크로 가는 링크여도 그 디스크를 잰다
free=$(( $(df -Pm "$S/." | awk 'NR==2 {print $4}') / 1024 ))
if [ "$free" -lt "$need" ]; then
    [ -f b200-pack.tar ] && warn "다 푼 b200-pack.tar 를 지우면 $(( $(du -sm b200-pack.tar | cut -f1) / 1024 )) GB 가 생긴다: rm $HERE/b200-pack.tar"
    stop "$S 가 있는 디스크의 남은 공간이 ${free} GB 다(${need} GB 필요)" \
         "b200-pack.tar 를 지우거나 홈 공간을 비운다. 홈이 작으면 ~/shared 를 큰 디스크로 옮긴다(README 문제 해결하기)."
fi
ok "$S 남은 공간 ${free} GB (필요 약 ${need} GB)"

# ------------------------------------------------------------------ 2. 옮기기
step 2 "휠을 $S/wheels 로 옮기기"
mkdir -p "$S/wheels" "$S/mamba/pkgs"
cp -n wheels/* "$S/wheels/" && cp lock.txt pack_info.txt "$S/" || stop "복사 실패" "남은 공간과 권한을 본다."
cp -n pkgs/* "$S/mamba/pkgs/" || stop "복사 실패" "남은 공간과 권한을 본다."
ok "휠 $(ls wheels | wc -l)개 → $S/wheels"

# ------------------------------------------------------------------ 3. 기초 프로그램
step 3 "기초 프로그램 설치 → $S/tools"
chmod +x micromamba
export MAMBA_ROOT_PREFIX="$S/mamba"
if [ -f "$S/tools/.b200_ok" ] && cmp -s explicit.txt "$S/tools/.b200_ok"; then
    ok "이미 같은 버전이 설치돼 있어 건너뜀"
elif [ -f "$S/tools/.b200_ok" ] && [ "${B200_REBUILD_TOOLS:-0}" != 1 ]; then
    warn "기초 프로그램 목록이 바뀌었다. 지금 것을 그대로 둔다."
    warn "다른 사람이 안 쓸 때 B200_REBUILD_TOOLS=1 bash pack_install.sh 로 다시 설치한다."
else
    rm -rf "$S/tools"   # 지난번에 끝까지 못 깐 것
    ./micromamba create -p "$S/tools" --offline -y -f explicit.txt ||
        stop "기초 프로그램 설치 실패" "위 오류를 본다. 모르겠으면 로그를 담당자에게 보내 준다."
    cp micromamba "$S/tools/bin/"
    cp explicit.txt "$S/tools/.b200_ok"
    ok "설치함"
fi
if [ -f /etc/profile.d/b200.sh ] || [ "$(id -u)" = 0 ]; then
    ok "PATH 는 관리자 설정(/etc/profile.d/b200.sh)이 맡는다"
elif ! grep -q 'shared/tools/bin' ~/.bashrc; then
    # 서버에 원래 있는 명령이 먼저 잡히도록 뒤에 붙인다
    echo 'export PATH=$PATH:$HOME/shared/tools/bin' >> ~/.bashrc
    ok "~/.bashrc 에 PATH 추가"
fi

# ------------------------------------------------------------------ 4. 공용 환경
step 4 "공용 휠 설치 → 공용 환경 $S/venv"
[ -x "$S/venv/bin/python" ] || "$S/tools/bin/python" -m venv "$S/venv" || stop "venv 생성 실패" "3단계가 정상인지 본다."
"$S/venv/bin/pip" install -q --no-index --find-links "$S/wheels" -r "$S/lock.txt" ||
    stop "휠 설치 실패" "위 오류에 나온 패키지를 본다. 모르겠으면 로그를 담당자에게 보내 준다."
ok "설치함 ($("$S/venv/bin/pip" list 2>/dev/null | tail -n +3 | wc -l)개)"

# ------------------------------------------------------------------ 5. 검사
step 5 '검사'
missing=()
for b in python uv git git-lfs delta lazygit tmux screen vim nvim nano micro less direnv zoxide fzf \
         tree rg fd bat eza ncdu dust duf jq yq dos2unix entr parallel just hyperfine \
         zip unzip 7za pigz zstd htop btop nvtop lsof strace gdb \
         make cmake ninja pkg-config gcc g++ ccache patchelf clang-format shellcheck \
         ffmpeg magick sqlite3 rsync bc; do
    [ -x "$S/tools/bin/$b" ] || missing+=("$b")
done
if [ ${#missing[@]} -eq 0 ]; then ok "기초 프로그램 명령 확인"; else warn "기초 프로그램에 없는 명령(이름이 다를 수 있음): ${missing[*]}"; fi
"$S/tools/bin/git" --version >/dev/null 2>&1 && "$S/tools/bin/tmux" -V >/dev/null 2>&1 &&
    ok "git, tmux 실행됨" || bad "git 또는 tmux 가 실행되지 않는다"

if "$S/venv/bin/pip" check >/dev/null 2>&1; then ok "pip check (의존성 맞음)"
else bad "pip check 실패:"; "$S/venv/bin/pip" check | head -10 | sed 's/^/    /'; fi

"$S/venv/bin/python" - <<'EOF' || FAILS=$((FAILS + 1))
import importlib, sys
mods = """torch torchvision torchaudio lightning torchmetrics timm segmentation_models_pytorch kornia
einops safetensors onnx onnxruntime onnxscript transformers datasets accelerate peft huggingface_hub
tokenizers sentencepiece numpy scipy pandas polars pyarrow h5py numba sklearn skimage PIL cv2
albumentations imageio shapely pyquaternion rosbags lmdb msgpack matplotlib seaborn tensorboard
wandb rich tqdm hydra omegaconf yaml typer loguru pydantic jupyterlab ipykernel ipywidgets IPython
pytest mypy debugpy line_profiler pynvml pybind11 Cython packaging""".split()
bad = []
for m in mods:
    try:
        importlib.import_module(m)
    except Exception as e:
        bad.append(f"{m} ({type(e).__name__}: {e})")
if bad:
    print("  \033[31m[문제]\033[0m import 실패:")
    for b in bad: print("    " + b)
    sys.exit(1)
print(f"  \033[32m[정상]\033[0m 주요 패키지 {len(mods)}개 import")
try:
    import open3d
    print(f"  \033[32m[정상]\033[0m open3d {open3d.__version__} import")
except Exception as e:
    print(f"  \033[33m[주의]\033[0m open3d import 실패 ({e}). 서버 관리 팀에 apt 패키지 libgl1 libegl1 libgomp1 설치를 요청한다")
EOF

"$S/venv/bin/python" - <<'EOF' || FAILS=$((FAILS + 1))
try:
    import torch
except Exception as e:
    print(f"  \033[31m[문제]\033[0m torch 를 못 불러온다 ({e})")
    raise SystemExit(1)
try:
    torch.cuda.init()
    n = torch.cuda.device_count()
except Exception as e:
    n, err = 0, str(e).splitlines()[0]
else:
    err = ""
if n == 0:
    print(f"  \033[31m[문제]\033[0m torch {torch.__version__} 가 GPU를 못 본다 {err}")
    if "802" in err or "not yet initialized" in err:
        print("    NVLink Fabric 이 초기화되지 않았다. 서버 관리 팀에 nvidia-fabricmanager(와 nvlsm) 설치·실행을 요청한다")
    else:
        print("    bash check_server.sh 로 드라이버와 Fabric 상태를 본다")
    raise SystemExit(1)
for i in range(n):
    x = torch.randn(256, 256, device=f"cuda:{i}")
    (x @ x).sum().item()
print(f"  \033[32m[정상]\033[0m torch {torch.__version__}, CUDA {torch.version.cuda}, GPU {n}장 계산 확인 ({torch.cuda.get_device_name(0)})")
if n > 1:
    peer = sum(torch.cuda.can_device_access_peer(0, j) for j in range(1, n))
    msg = f"GPU 0 → 다른 GPU 직접 접근(NVLink/P2P) {peer}/{n - 1}"
    print(f"  \033[32m[정상]\033[0m {msg}" if peer == n - 1 else f"  \033[33m[주의]\033[0m {msg}. 여러 GPU 학습이 느릴 수 있다")
EOF

echo
if [ "$FAILS" -eq 0 ]; then
    echo "${c_g}############################ 완료 ############################${c_0}"
    echo " 모두 정상. 기초 프로그램 $S/tools, 공용 환경 $S/venv"
    echo " 새 터미널을 열거나 source ~/.bashrc 하면 기초 프로그램을 쓸 수 있다."
    echo " 내 Python 환경 만들기: docs/1_공용_휠_기초프로그램.md"
    echo " 정리: rm -rf $HERE/*"
    echo "${c_g}##############################################################${c_0}"
else
    echo "${c_r}############## 끝났지만 문제 ${FAILS}개 ##############${c_0}"
    echo " 위의 [문제] 줄을 본다. 해결이 안 되면 이 파일을 담당자에게 보내 준다: $LOG"
    exit 1
fi
