#!/usr/bin/env bash
# [B200 서버] 홈의 ~/shared, ~/inbox (있으면 ~/tools 도) 를 큰 디스크로 옮기고, 홈에는 같은 이름의 링크를 둔다.
# 링크를 두기 때문에 지금까지의 경로(~/shared/venv 등)와 설치된 환경은 그대로 쓸 수 있다.
#   bash move_shared.sh /app/$USER
# 점검 → 복사 → 복사본 확인 → 링크로 바꾸기 → 동작 검사 → (물어본 뒤) 홈의 옛 폴더 지우기
set -uo pipefail
if [ "$(uname -s)" != Linux ]; then echo "이 스크립트는 B200 서버(리눅스)에서 실행해요."; exit 1; fi
TARGET=${1:-}
LOG="$HOME/b200_move_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "$LOG") 2>&1

c_g=$'\e[32m'; c_y=$'\e[33m'; c_r=$'\e[31m'; c_c=$'\e[36m'; c_0=$'\e[0m'
step() { echo; echo "${c_c}==== [$1/5] $2 ====${c_0}"; }
ok()   { echo "  ${c_g}[정상]${c_0} $*"; }
warn() { echo "  ${c_y}[주의]${c_0} $*"; }
stop() {
    echo
    echo "${c_r}################ 멈춤 ################${c_0}"
    echo "${c_r}멈춘 이유: $1${c_0}"
    echo "할 일: $2"
    echo "홈의 원래 폴더는 그대로 있어요. 고친 뒤 같은 명령을 다시 실행하세요."
    echo "기록 파일: $LOG"
    exit 1
}

echo "[B200 서버] 공용 폴더를 큰 디스크로 옮기기  ($(date '+%Y-%m-%d %H:%M'), $(hostname), $(id -un))"
[ -n "$TARGET" ] || stop "옮길 곳을 붙이지 않았어요" "옮길 폴더를 붙여 실행하세요: bash move_shared.sh /app"
TARGET=$(realpath -m "$TARGET")

# ------------------------------------------------------------------ 1. 점검
step 1 '점검'
names=()
for n in shared inbox tools; do
    src="$HOME/$n"
    if [ -L "$src" ]; then
        ok "~/$n: 이미 다른 곳을 가리키는 링크예요($(readlink "$src")). 건너뛰어요"
    elif [ -d "$src" ]; then
        names+=("$n")
    fi
done
[ ${#names[@]} -gt 0 ] || { echo; echo "${c_g}옮길 것이 없어요. 이미 모두 옮겼어요.${c_0}"; exit 0; }
echo "  옮길 폴더: ${names[*]/#/\~/}"

mkdir -p "$TARGET" 2>/dev/null || stop "폴더를 만들지 못했어요: $TARGET" "root로 $TARGET 을 만들어 쓰기 권한을 주거나, 다른 폴더를 붙여 실행하세요."
probe="$TARGET/.b200_write_test"
touch "$probe" 2>/dev/null && rm -f "$probe" || stop "쓸 수 없는 폴더예요: $TARGET" "root로 쓰기 권한을 주거나, 다른 폴더를 붙여 실행하세요."
ok "$TARGET 에 쓸 수 있어요"
for n in "${names[@]}"; do
    [ -e "$TARGET/$n" ] && [ -n "$(ls -A "$TARGET/$n" 2>/dev/null)" ] && [ ! -f "$TARGET/$n/.b200_copying" ] &&
        stop "옮길 자리에 이미 내용이 있어요: $TARGET/$n" "다른 사람이 쓰는 폴더인지 확인하세요. 아니면 지우거나 다른 옮길 곳을 붙여 실행하세요."
done

if [ "$(stat -c %d "$HOME")" = "$(stat -c %d "$TARGET")" ]; then
    warn "홈과 $TARGET 이 같은 디스크라서 옮겨도 공간이 늘지 않아요"
fi
need=$(du -sm "${names[@]/#/$HOME/}" 2>/dev/null | awk '{s+=$1} END {print int(s/1024)+1}')
free=$(( $(df -Pm "$TARGET" | awk 'NR==2 {print $4}') / 1024 ))
[ "$free" -ge "$need" ] || stop "$TARGET 의 남은 공간이 ${free} GB예요(${need} GB 필요)" "공간이 넉넉한 다른 디스크의 폴더를 붙여 실행하세요."
ok "옮길 크기 약 ${need} GB, $TARGET 남은 공간 ${free} GB"
if command -v lsblk >/dev/null; then
    src_dev=$(findmnt -no SOURCE -T "$TARGET")
    rota=$(lsblk -nso ROTA "$src_dev" 2>/dev/null | sort -u | tr '\n' ' ')
    case "$rota" in
        "0 ") ok "$TARGET 은 SSD(또는 NVMe)에 있어요" ;;
        *1*)  warn "$TARGET 은 HDD가 섞인 디스크예요($src_dev). 데이터셋 읽기가 느릴 수 있어요" ;;
        *)    warn "$TARGET 의 디스크 종류를 알 수 없어요($src_dev, 네트워크 저장소일 수 있어요)" ;;
    esac
fi

# ------------------------------------------------------------------ 2. 복사
step 2 "복사 → $TARGET (크면 오래 걸려요. 끊기면 다시 실행하면 이어서 해요)"
for n in "${names[@]}"; do
    mkdir -p "$TARGET/$n" && touch "$TARGET/$n/.b200_copying"
    echo "  ~/$n 복사하는 중이에요"
    if command -v rsync >/dev/null || [ -x "$HOME/shared/tools/bin/rsync" ]; then
        RSYNC=$(command -v rsync || echo "$HOME/shared/tools/bin/rsync")
        "$RSYNC" -aH --info=progress2 "$HOME/$n/" "$TARGET/$n/" || stop "~/$n 을 복사하지 못했어요" "남은 공간과 권한을 확인하세요."
    else
        cp -a "$HOME/$n/." "$TARGET/$n/" || stop "~/$n 을 복사하지 못했어요" "남은 공간과 권한을 확인하세요."
    fi
done

# ------------------------------------------------------------------ 3. 복사본 확인
step 3 '복사본 확인 (파일 수와 크기 비교)'
for n in "${names[@]}"; do
    a_f=$(find "$HOME/$n" -type f | wc -l);   b_f=$(find "$TARGET/$n" -type f ! -name .b200_copying | wc -l)
    if [ "$a_f" != "$b_f" ]; then stop "~/$n 의 파일 수가 달라요(원본 $a_f / 사본 $b_f)" "같은 명령을 다시 실행해 복사를 마저 하세요."; fi
    # 폴더 자체 크기는 디스크마다 달라서 파일 내용 크기만 비교한다
    a_c=$(find "$HOME/$n" -type f -printf '%s\n' | awk '{s+=$1} END {print s+0}')
    b_c=$(find "$TARGET/$n" -type f ! -name .b200_copying -printf '%s\n' | awk '{s+=$1} END {print s+0}')
    [ "$a_c" = "$b_c" ] || stop "~/$n 의 내용 크기가 달라요(원본 $a_c / 사본 $b_c 바이트)" "같은 명령을 다시 실행해 복사를 마저 하세요."
    ok "~/$n: 파일 ${a_f}개, $(( a_c / 1024 / 1024 / 1024 )) GB가 원본과 같아요"
done

# ------------------------------------------------------------------ 4. 링크로 바꾸기
step 4 '홈의 폴더를 링크로 바꾸기'
for n in "${names[@]}"; do
    rm -f "$TARGET/$n/.b200_copying"
    mv "$HOME/$n" "$HOME/$n.b200old" && ln -s "$TARGET/$n" "$HOME/$n" ||
        stop "~/$n 을 링크로 바꾸지 못했어요" "ls -la ~ 로 상태를 확인하세요. 원본은 ~/$n.b200old 에 있어요."
    ok "~/$n → $TARGET/$n"
done

# ------------------------------------------------------------------ 5. 동작 검사
step 5 '동작 검사'
fail=0
if [ -x "$HOME/shared/tools/bin/git" ]; then
    "$HOME/shared/tools/bin/git" --version >/dev/null && ok "기초 프로그램이 실행돼요" || { warn "기초 프로그램이 실행되지 않아요"; fail=1; }
fi
if [ -x "$HOME/shared/venv/bin/python" ]; then
    "$HOME/shared/venv/bin/python" -c "import torch, numpy" && ok "공용 Python 환경에서 torch를 불러왔어요" || { warn "공용 Python 환경이 동작하지 않아요"; fail=1; }
fi

echo
if [ "$fail" -ne 0 ]; then
    echo "${c_r}문제가 있어서 홈의 옛 폴더(~/*.b200old)를 지우지 않았어요.${c_0}"
    echo "되돌리기: 각 이름마다  rm ~/이름 && mv ~/이름.b200old ~/이름"
    echo "기록 파일: $LOG"
    exit 1
fi
echo "${c_g}다 옮겼어요. 지금까지의 경로(~/shared, ~/inbox)를 그대로 쓰면 돼요.${c_0}"
echo "홈의 옛 폴더: $(printf '~/%s.b200old ' "${names[@]}")"
read -r -p "옛 폴더를 지워 홈 공간을 비울까요? [y/N] " ans
if [ "$ans" = y ] || [ "$ans" = Y ]; then
    for n in "${names[@]}"; do rm -rf "$HOME/$n.b200old"; done
    ok "지웠어요. 홈 남은 공간: $(df -h --output=avail "$HOME" | tail -1 | tr -d ' ')"
else
    echo "  나중에 지우려면: rm -rf $(printf '~/%s.b200old ' "${names[@]}")"
fi
