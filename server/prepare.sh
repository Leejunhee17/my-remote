#!/usr/bin/env bash
# [GPU 서버 · 관리자(root) 전용] 1단계 준비. 설치 스크립트(기초 프로그램·도커·데이터셋·모델)를 안전하게 돌릴 자리를 만든다. 여러 번 실행해도 된다.
#   cd /app/inbox && tar xf gpu-setup.tar && bash prepare.sh
# 하는 일
#   - /app 을 root 소유로 잠그고, /app/admin(도우미·설정), /app/inbox(root 가 지문을 확인한 설치 파일을 두는 곳),
#     팀원 작업 공간(/app/autonomy_sw)과 기록 폴더(/app/state)를 만든다
#   - 알림 기준과 NAS 위치를 적은 /app/admin/gpu.conf 를 만든다
#   - NAS 팀 폴더(/data/autonomy_sw)와 그 안의 datasets·models 등을 만든다(데이터셋·모델을 여기에 푼다)
#   - 올린 파일을 /app/inbox 로 옮기는 gpu 명령(gpu fetch)을 /app/admin/bin 에 설치한다
# 팀원 맞이 설정(이름 고르기, docker·nvidia-smi 도우미, 알림, 정기 점검)은 설치를 다 끝낸 뒤 admin_setup.sh 가 한다
# root 가 공용 계정이 고칠 수 있는 곳에서 설치하면, 미리 심어 둔 링크를 따라가 시스템 파일을 덮어쓸 수 있다. 그래서 이 잠금이 설치보다 먼저다
set -uo pipefail
cd "$(dirname "$0")"
HERE=$PWD
ACC=${GPU_ACCOUNT:-$(cat /etc/gpu/account 2>/dev/null)}   # 공용 계정 이름은 서버의 /etc/gpu/account 한 곳에 적는다
S=/app/admin          # 도우미(bin)·명단·GPU 배분·알림 설정. root 만 고친다
W=/app/autonomy_sw
ST=/app/state
c_g=$'\e[32m'; c_y=$'\e[33m'; c_r=$'\e[31m'; c_c=$'\e[36m'; c_0=$'\e[0m'
step() { echo; echo "${c_c}==== $1 ====${c_0}"; }
ok()   { echo "  ${c_g}[정상]${c_0} $*"; }
warn() { echo "  ${c_y}[주의]${c_0} $*"; }
stop() { echo "${c_r}멈춤: $1${c_0}"; echo "할 일: $2"; exit 1; }
# 폴더와 그 위의 모든 폴더가 root 소유이고 root 만 쓸 수 있는지(스티키 폴더는 남이 써도 바꿔치기를 못 해서 괜찮다).
# 이런 곳은 공용 계정이 링크를 심거나 폴더를 바꿔치기할 수 없어서 root 가 써도 안전하다
safe_dir() {
    local p m; p=$(readlink -f "$1") && [ -d "$p" ] || return 1
    while :; do
        m=$(stat -c '%u %a' "$p") || return 1
        [ "${m%% *}" = 0 ] || return 1
        [ $(( 8#${m##* } & 8#1000 )) -ne 0 ] || [ $(( 8#${m##* } & 8#022 )) -eq 0 ] || return 1
        [ "$p" = / ] && return 0; p=$(dirname "$p")
    done
}

[ "$(id -u)" = 0 ] || stop 'root 계정이 아니에요' 'HIWARE에서 root로 접속해(PuTTY) 다시 실행하세요.'
[ -n "$ACC" ] || stop '공용 계정 이름을 알 수 없어요' '서버에 한 번 적어 두세요: mkdir -p /etc/gpu && echo <계정이름> > /etc/gpu/account'
[[ "$ACC" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || stop "공용 계정 이름이 이상해요: $ACC" '/etc/gpu/account 에 계정 이름 한 줄만 적으세요'
id "$ACC" >/dev/null 2>&1 || stop "공용 계정을 찾지 못했어요: $ACC" '/etc/gpu/account 의 계정 이름을 확인하세요: cat /etc/gpu/account'
HOME_A=$(getent passwd "$ACC" | cut -d: -f6)

echo "[GPU 서버] 준비  ($(date '+%Y-%m-%d %H:%M'), 공용 계정 $ACC)"

# ------------------------------------------------------------------ 1. 폴더
step '1. 폴더와 잠금'
[ -d /app ] || stop '/app 폴더가 없어요' '서버 관리 팀에 2 TB SSD를 /app에 연결해 달라고 요청하세요.'
[ -L /app ] && stop '/app이 링크예요' 'ls -l /app 으로 어디를 가리키는지 보고, 서버 관리 팀에 실제 디스크로 연결해 달라고 요청하세요.'
# /app 은 root 만 고칠 수 있게 한다. 공용 계정이 /app 에 쓸 수 있으면 admin·state 같은 이름으로 시스템 폴더 링크를 심어 두고,
# 아래 chown·chmod(링크를 따라간다)를 시스템 폴더에 하게 만들 수 있다. 잠근 뒤에 링크가 있는지 본다
# 서버 2처럼 다른 팀과 같이 쓰는 서버에서 다른 계정이 /app 에 폴더를 두고 있으면, 잠그면 그 계정이 /app 에 새 폴더를 못 만든다
others=$(find /app -mindepth 1 -maxdepth 1 ! -user root ! -user "$ACC" -printf '%u %p\n' 2>/dev/null)
if [ -n "$others" ] && [ "$(stat -c '%U %a' /app)" != "root 755" ]; then
    echo "$others" | sed 's/^/    다른 계정 폴더: /'
    warn "/app 을 다른 계정도 쓰는 것 같아요. 잠그면(root 소유, 755) 그 계정은 /app 바로 아래에 새 폴더를 못 만들어요(있는 폴더는 그대로 써요)"
    if [ -t 0 ]; then read -r -p "  서버 관리 팀·다른 팀과 이미 정했으면 y, 아니면 Enter(여기서 멈춰요): " a; [ "$a" = y ] || stop '/app 잠금 보류' '서버 관리 팀·다른 팀과 /app 사용을 정한 뒤 다시 실행하세요.'
    else stop '/app 을 다른 계정도 써요' 'PuTTY 화면에서 직접 실행해 확인 질문에 답하세요: bash prepare.sh'; fi
fi
chown root:root /app && chmod 755 /app
for d in "$S" /app/shared "$W" "$ST" /app/inbox /app/docker "$ST"/{history,gpu_log,reports,images,notice,notice_seen,tty}; do
    [ -L "$d" ] && stop "링크가 있어요(누가 만들었는지 몰라요): $d" "ls -l $d 로 어디를 가리키는지 보고, 직접 만든 게 아니면 rm $d 로 링크만 지운 뒤 다시 실행하세요."
done
# 예전 설치의 /app/shared(기초 프로그램·데이터셋·모델·설정을 한곳에 두던 방식)를 치운다. 명단·배분·알림 설정만 /app/admin 으로 옮긴다.
# 공용 계정이 만들었을 수 있는 폴더라 프로그램은 믿지 않는다. 설정 파일은 gpu 가 실행하지 않고 값만 꺼내 확인한다
if [ -d /app/shared ]; then
    old="/app/.shared_old_$(date +%Y%m%d_%H%M%S)"
    mv /app/shared "$old" && chown root:root "$old" && chmod 700 "$old" || stop "예전 /app/shared 를 치우지 못했어요" "ls -la /app 으로 상태를 확인하세요."
    mkdir -p "$S"
    for n in team.txt gpu_alloc.txt gpu.conf; do [ -f "$old/$n" ] && [ ! -L "$old/$n" ] && [ ! -e "$S/$n" ] && mv "$old/$n" "$S/$n"; done
    warn "예전 /app/shared 를 $old 로 치우고 명단·배분·알림 설정만 $S 로 옮겼어요(root만 볼 수 있어요)"
    for n in datasets models; do [ -d "$old/$n" ] && echo "    예전 $n 을 NAS로 옮기려면(tmux 안에서): rsync -a --no-links $old/$n/ /data/autonomy_sw/$n/"; done
    echo "    치운 폴더는 확인한 뒤 지워도 돼요: rm -rf $old"
fi
# /app/admin 은 root 가 잠근 표시 파일(.gpu_root)이 있어야 믿는다. 공용 계정은 root 소유 파일을 만들 수 없다.
# 잠그기 전에 공용 계정이 만든 /app/admin 이면 설정 파일만 남기고 치운다(도우미를 바꿔 두면 root 가 그것을 실행하게 된다)
if [ -d "$S" ] && ! { [ "$(stat -c %U "$S")" = root ] && [ "$(stat -c %U "$S/.gpu_root" 2>/dev/null)" = root ]; }; then
    old="/app/.admin_old_$(date +%Y%m%d_%H%M%S)"
    mv "$S" "$old" && chown root:root "$old" && chmod 700 "$old" && mkdir -p "$S" || stop "예전 $S 를 치우지 못했어요" "ls -la /app 으로 상태를 확인하세요."
    for n in team.txt gpu_alloc.txt gpu.conf; do [ -f "$old/$n" ] && [ ! -L "$old/$n" ] && mv "$old/$n" "$S/$n"; done
    [ -n "$(ls -A "$old" 2>/dev/null)" ] && warn "root 가 잠그기 전에 만든 $S 라 명단·배분·알림 설정만 남기고 나머지는 $old 로 치웠어요" || rmdir "$old"
fi
# 예전 작업 폴더 이름(/app/workspace)을 쓰던 서버: 안의 파일은 그대로 두고 폴더 이름만 바꾼다(같은 디스크라 바로 끝난다)
if [ -d /app/workspace ] && [ ! -L /app/workspace ] && [ ! -e "$W" ]; then
    mv /app/workspace "$W" && warn "예전 작업 폴더 /app/workspace 를 $W 로 옮겼어요(안의 파일은 그대로). 팀원에게 새 위치를 알려 주세요"
elif [ -e /app/workspace ] && [ -e "$W" ]; then
    warn "/app/workspace 와 $W 가 둘 다 있어요. /app/workspace 안의 파일을 확인해 $W 로 옮긴 뒤 지우세요"
fi
mkdir -p "$S/bin" "$S/logs" "$W" "$ST"/{history,gpu_log,reports,images,notice,notice_seen,tty} /app/inbox
# 공용: root 만 쓰고 모두 읽는다
chown -R root:root "$S" && chmod -R u+rwX,go+rX,go-w "$S" && touch "$S/.gpu_root"
ok "$S(도우미·명단·설정): root만 고치고 팀원은 읽기만 해요"
# 작업 공간과 기록: 공용 계정이 쓴다(보고서만 root)
chown "$ACC:$ACC" "$W" && chmod 755 "$W"
# 기록 폴더: 공용 계정이 쓰는 곳(history, images, notice_seen)과 root 만 쓰는 곳(reports, gpu_log, notice)을 나눈다.
# root 는 공용 계정이 쓸 수 있는 곳에 파일을 만들거나 고치지 않는다(미리 심어 둔 링크로 시스템 파일을 덮거나 주인을 바꿀 수 있다)
chown root:root "$ST" && chmod 755 "$ST"   # root 소유라야 공용 계정이 아래 root 폴더를 바꿔치기하지 못한다
for d in history images notice_seen tty; do chown -R "$ACC:$ACC" "$ST/$d"; done
for d in reports gpu_log notice; do chown -R root:root "$ST/$d" && chmod 755 "$ST/$d"; done
setsid -w runuser -u "$ACC" -- touch "$ST/images/loaded.tsv"   # docker 래퍼(공용 계정)가 이미지를 들여온 사람을 적는다
# root 가 실행할 설치 파일을 두는 곳. 공용 계정이 고칠 수 있으면 누구든 root 로 원하는 명령을 실행시킬 수 있다
chown root:root /app/inbox && chmod 755 /app/inbox
[ -d /app/inbox/images ] && rmdir /app/inbox/images/* /app/inbox/images 2>/dev/null
# root 는 FileZilla 를 못 쓰므로 설치 파일은 공용 계정이 여기에 올린다. root 는 /app/inbox 로 새로 복사하고 지문을 확인한 뒤 실행한다
ok "$W: 팀원 작업 공간,  $ST: 기록·알림,  /app/inbox: root가 지문을 확인한 설치 파일(올리는 곳은 NAS 의 inbox 예요)"
# 홈에서도 보이게 링크(홈은 10 GB 라 실제 파일은 /app 에)
for n in workspace shared; do   # 예전 방식의 링크
    [ -L "$HOME_A/$n" ] && case "$(readlink "$HOME_A/$n")" in /app/workspace|/app/shared) setsid -w runuser -u "$ACC" -- rm -f "$HOME_A/$n" ;; esac
done
for n in autonomy_sw; do
    [ -e "$HOME_A/$n" ] || [ -L "$HOME_A/$n" ] || setsid -w runuser -u "$ACC" -- ln -sn "/app/$n" "$HOME_A/$n"   # 공용 계정 홈이라 그 권한으로
done
# 알림 기준 숫자. 바꾸면 규칙 문서(team/)의 숫자도 같이 바꾼다. 예전 설정(자동 종료 등)이 있으면 새로 쓴다
grep -q '^IDLE_HOURS=' "$S/gpu.conf" 2>/dev/null || cat > "$S/gpu.conf" <<'EOF'
# gpu 알림 기준. 관리자만 고친다. 바꾸면 팀원 규칙 문서의 숫자도 같이 바꾼다. 모두 알림만 하고 멈추거나 지우지 않는다.
MAX_GPUS=4            # docker run 때 내 GPU가 이보다 많아지면 경고
IDLE_HOURS=12         # GPU를 잡고 이 시간 내내 사용률 0%면 그 사람에게 알림(하루 한 번)
DISK_ALERT=85         # /app 이 이 % 를 넘으면 많이 쓰는 3명과 관리자에게 알림(주 한 번)
IMAGE_NOTICE_DAYS=30  # 이 일수 동안 안 쓴 도커 이미지는 들여온 사람에게 알림(주 한 번)
NAS_DIR=/data/autonomy_sw   # NAS 팀 폴더. 데이터셋·모델·백업을 여기에 둬요(docs/8_NAS.md)
EOF
grep -q '^NAS_DIR=' "$S/gpu.conf" ||   # 예전 버전으로 만든 설정에는 없다
    echo 'NAS_DIR=/data/autonomy_sw   # NAS 팀 폴더. 데이터셋·모델·백업을 여기에 둬요(docs/8_NAS.md)' >> "$S/gpu.conf"
chmod 644 "$S/gpu.conf"
# ------------------------------------------------------------------ NAS 팀 폴더
# 데이터셋·모델은 NAS 팀 폴더(gpu.conf 의 NAS_DIR, 기본 /data/autonomy_sw)에 한 번만 두고 두 서버가 같이 읽는다.
# 팀 폴더는 root 소유·그룹 공용 계정 750(다른 팀은 못 봄), datasets·models·originals 는 root 소유 755(팀원은 읽기만),
# backup·docker_images·tmp_transfer 는 공용 계정 소유. /data 가 root 소유라 공용 계정이 이 경로를 바꿔치기할 수 없다
NAS_DIR=$(sed -n 's/^NAS_DIR=\([^ #]*\).*/\1/p' "$S/gpu.conf" | tail -1); NAS_DIR=${NAS_DIR:-/data/autonomy_sw}
{ [[ "$NAS_DIR" =~ ^/[A-Za-z0-9._/-]+$ ]] && [[ "$NAS_DIR" != *..* ]]; } ||
    stop "gpu.conf 의 NAS_DIR 이 이상해요: $NAS_DIR" "$S/gpu.conf 에 NAS_DIR=/data/autonomy_sw 처럼 적으세요"
if ! safe_dir "$(dirname "$NAS_DIR")"; then
    warn "NAS($(dirname "$NAS_DIR"))가 없거나 root 말고도 고칠 수 있어요. 데이터셋·모델을 설치할 수 없어요. NAS 연결을 서버 관리 팀에 확인하세요"
elif [ -L "$NAS_DIR" ] || { [ -e "$NAS_DIR" ] && ! safe_dir "$NAS_DIR"; }; then
    warn "NAS 팀 폴더($NAS_DIR)가 링크이거나, root 소유가 아니거나, 다른 사람이 쓸 수 있어요. 안을 확인하고 chown root:$(id -gn "$ACC") $NAS_DIR && chmod 750 $NAS_DIR 한 뒤 다시 실행하세요"
elif ! { mkdir -p "$NAS_DIR" && chown root:"$(id -gn "$ACC")" "$NAS_DIR" && chmod 750 "$NAS_DIR"; } 2>/dev/null; then
    warn "root 가 NAS에 $NAS_DIR 를 만들지 못했어요(NAS가 root 를 일반 계정으로 바꾸는 root squash 설정일 수 있어요). 서버 관리 팀에 root 소유로 만들어 달라고 하세요"
else
    for n in datasets models originals backup docker_images tmp_transfer inbox; do
        d=$NAS_DIR/$n; [ -L "$d" ] && { warn "$d 가 링크라 건너뛰어요. 확인하고 지운 뒤 다시 실행하세요"; continue; }
        case $n in datasets|models|originals) o=root:root ;; *) o=$ACC:$ACC ;; esac
        mkdir -p "$d" && chown "$o" "$d" && chmod 755 "$d"
    done
    ok "NAS 팀 폴더 $NAS_DIR: datasets·models·originals 는 root만 고치고, backup·docker_images·tmp_transfer·inbox 는 팀원이 써요"
fi

# ------------------------------------------------------------------ 2. gpu 명령
step '2. gpu 명령 설치 (gpu fetch)'
[ -f bin/gpu ] || stop "파일이 없어요: $HERE/bin/gpu" "묶음을 다시 푸세요: cd $HERE && tar xf gpu-setup.tar"
install -m 755 bin/gpu "$S/bin/gpu"
ok "$S/bin/gpu 를 설치했어요. 올린 파일은 이 명령으로 /app/inbox 에 옮겨요: $S/bin/gpu fetch <이름>"

echo
echo "${c_g}############################ 완료 ############################${c_0}"
echo " 다음 단계(docs/1_처음_설치.md). 올린 파일은 모두 $S/bin/gpu fetch 로 옮기고 지문을 확인한 뒤 실행해요"
echo "  2) 기초 프로그램: $S/bin/gpu fetch gpu-pkgs.tar → cd /app/inbox && tar xf gpu-pkgs.tar && bash pkgs_install.sh"
echo "  3) 도커:         $S/bin/gpu fetch gpu-docker.tar → cd /app/inbox && tar xf gpu-docker.tar && bash docker_install.sh"
echo "  4) 데이터셋:     $S/bin/gpu fetch datasets → bash /app/inbox/datasets/datasets_unpack.sh (두 서버 중 한 곳에서 한 번만)"
echo "  5) 모델:         $S/bin/gpu fetch models → bash /app/inbox/models/models_place.sh (두 서버 중 한 곳에서 한 번만)"
echo "  6) 권한·규칙 설정: 설치를 다 끝낸 뒤 cd /app/inbox && bash admin_setup.sh"
echo "${c_g}##############################################################${c_0}"
