#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")"
HERE=$PWD
ACC=${GPU_ACCOUNT:-$(cat /etc/gpu/account 2>/dev/null)}
S=/app/admin
W=/app/autonomy_sw
ST=/app/state
c_g=$'\e[32m'; c_y=$'\e[33m'; c_r=$'\e[31m'; c_c=$'\e[36m'; c_0=$'\e[0m'
step() { echo; echo "${c_c}==== $1 ====${c_0}"; }
ok()   { echo "  ${c_g}[정상]${c_0} $*"; }
warn() { echo "  ${c_y}[주의]${c_0} $*"; }
stop() { echo "${c_r}멈춤: $1${c_0}"; echo "할 일: $2"; exit 1; }
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

step '1. 폴더와 잠금'
[ -d /app ] || stop '/app 폴더가 없어요' '서버 관리 팀에 2 TB SSD를 /app에 연결해 달라고 요청하세요.'
[ -L /app ] && stop '/app이 링크예요' 'ls -l /app 으로 어디를 가리키는지 보고, 서버 관리 팀에 실제 디스크로 연결해 달라고 요청하세요.'
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
if [ -d /app/shared ]; then
    old="/app/.shared_old_$(date +%Y%m%d_%H%M%S)"
    mv /app/shared "$old" && chown root:root "$old" && chmod 700 "$old" || stop "예전 /app/shared 를 치우지 못했어요" "ls -la /app 으로 상태를 확인하세요."
    mkdir -p "$S"
    for n in team.txt gpu_alloc.txt gpu.conf; do [ -f "$old/$n" ] && [ ! -L "$old/$n" ] && [ ! -e "$S/$n" ] && mv "$old/$n" "$S/$n"; done
    warn "예전 /app/shared 를 $old 로 치우고 명단·배분·알림 설정만 $S 로 옮겼어요(root만 볼 수 있어요)"
    for n in datasets models; do [ -d "$old/$n" ] && echo "    예전 $n 을 NAS로 옮기려면(tmux 안에서): rsync -a --no-links $old/$n/ /data/autonomy_sw/$n/"; done
    echo "    치운 폴더는 확인한 뒤 지워도 돼요: rm -rf $old"
fi
if [ -d "$S" ] && ! { [ "$(stat -c %U "$S")" = root ] && [ "$(stat -c %U "$S/.gpu_root" 2>/dev/null)" = root ]; }; then
    old="/app/.admin_old_$(date +%Y%m%d_%H%M%S)"
    mv "$S" "$old" && chown root:root "$old" && chmod 700 "$old" && mkdir -p "$S" || stop "예전 $S 를 치우지 못했어요" "ls -la /app 으로 상태를 확인하세요."
    for n in team.txt gpu_alloc.txt gpu.conf; do [ -f "$old/$n" ] && [ ! -L "$old/$n" ] && mv "$old/$n" "$S/$n"; done
    [ -n "$(ls -A "$old" 2>/dev/null)" ] && warn "root 가 잠그기 전에 만든 $S 라 명단·배분·알림 설정만 남기고 나머지는 $old 로 치웠어요" || rmdir "$old"
fi
if [ -d /app/workspace ] && [ ! -L /app/workspace ] && [ ! -e "$W" ]; then
    mv /app/workspace "$W" && warn "예전 작업 폴더 /app/workspace 를 $W 로 옮겼어요(안의 파일은 그대로). 팀원에게 새 위치를 알려 주세요"
elif [ -e /app/workspace ] && [ -e "$W" ]; then
    warn "/app/workspace 와 $W 가 둘 다 있어요. /app/workspace 안의 파일을 확인해 $W 로 옮긴 뒤 지우세요"
fi
mkdir -p "$S/bin" "$S/logs" "$W" "$ST"/{history,gpu_log,reports,images,notice,notice_seen,tty} /app/inbox
chown -R root:root "$S" && chmod -R u+rwX,go+rX,go-w "$S" && touch "$S/.gpu_root"
ok "$S(도우미·명단·설정): root만 고치고 팀원은 읽기만 해요"
chown "$ACC:$ACC" "$W" && chmod 755 "$W"
chown root:root "$ST" && chmod 755 "$ST"
for d in history images notice_seen tty; do chown -R "$ACC:$ACC" "$ST/$d"; done
for d in reports gpu_log notice; do chown -R root:root "$ST/$d" && chmod 755 "$ST/$d"; done
setsid -w runuser -u "$ACC" -- touch "$ST/images/loaded.tsv"
chown root:root /app/inbox && chmod 755 /app/inbox
[ -d /app/inbox/images ] && rmdir /app/inbox/images/* /app/inbox/images 2>/dev/null
ok "$W: 팀원 작업 공간,  $ST: 기록·알림,  /app/inbox: root가 지문을 확인한 설치 파일(올리는 곳은 NAS 의 inbox 예요)"
for n in workspace shared; do
    [ -L "$HOME_A/$n" ] && case "$(readlink "$HOME_A/$n")" in /app/workspace|/app/shared) setsid -w runuser -u "$ACC" -- rm -f "$HOME_A/$n" ;; esac
done
for n in autonomy_sw; do
    [ -e "$HOME_A/$n" ] || [ -L "$HOME_A/$n" ] || setsid -w runuser -u "$ACC" -- ln -sn "/app/$n" "$HOME_A/$n"
done
grep -q '^IDLE_HOURS=' "$S/gpu.conf" 2>/dev/null || cat > "$S/gpu.conf" <<'EOF'
# gpu 알림 기준. 관리자만 고친다. 바꾸면 팀원 규칙 문서의 숫자도 같이 바꾼다. 모두 알림만 하고 멈추거나 지우지 않는다.
MAX_GPUS=4            # docker run 때 내 GPU가 이보다 많아지면 경고
IDLE_HOURS=12         # GPU를 잡고 이 시간 내내 사용률 0%면 그 사람에게 알림(하루 한 번)
DISK_ALERT=85         # /app 이 이 % 를 넘으면 많이 쓰는 3명과 관리자에게 알림(주 한 번)
IMAGE_NOTICE_DAYS=30  # 이 일수 동안 안 쓴 도커 이미지는 들여온 사람에게 알림(주 한 번)
NAS_DIR=/data/autonomy_sw   # NAS 팀 폴더. 데이터셋·모델·백업을 여기에 둬요(admin/5_NAS.md)
EOF
grep -q '^NAS_DIR=' "$S/gpu.conf" ||
    echo 'NAS_DIR=/data/autonomy_sw   # NAS 팀 폴더. 데이터셋·모델·백업을 여기에 둬요(admin/5_NAS.md)' >> "$S/gpu.conf"
chmod 644 "$S/gpu.conf"
NAS_DIR=$(sed -n 's/^NAS_DIR=\([^ #]*\).*/\1/p' "$S/gpu.conf" | tail -1); NAS_DIR=${NAS_DIR:-/data/autonomy_sw}
{ [[ "$NAS_DIR" =~ ^/[A-Za-z0-9._/-]+$ ]] && [[ "$NAS_DIR" != *..* ]]; } ||
    stop "gpu.conf 의 NAS_DIR 이 이상해요: $NAS_DIR" "$S/gpu.conf 에 NAS_DIR=/data/autonomy_sw 처럼 적으세요"
if ! safe_dir "$(dirname "$NAS_DIR")"; then
    warn "NAS($(dirname "$NAS_DIR"))가 없거나 root 말고도 고칠 수 있어서, root 가 팀 폴더를 만들지 않았어요. NAS 연결을 서버 관리 팀에 확인하세요(admin/5_NAS.md)"
elif [ -L "$NAS_DIR" ] || { [ -e "$NAS_DIR" ] && ! safe_dir "$NAS_DIR"; }; then
    warn "NAS 팀 폴더($NAS_DIR)가 링크이거나, root 소유가 아니거나, 다른 사람이 쓸 수 있어요. 안을 확인하고 chown root:$(id -gn "$ACC") $NAS_DIR && chmod 750 $NAS_DIR 한 뒤 다시 실행하세요"
elif ! { mkdir -p "$NAS_DIR" && chown root:"$(id -gn "$ACC")" "$NAS_DIR" && chmod 750 "$NAS_DIR"; } 2>/dev/null; then
    warn "root 가 NAS에 $NAS_DIR 를 만들지 못했어요(NAS가 root 를 일반 계정으로 바꾸는 root squash 설정일 수 있어요). 서버 관리 팀에 root 소유로 만들어 달라고 하세요"
else
    for n in datasets models originals backup docker_images tmp_transfer inbox; do
        d=$NAS_DIR/$n; [ -L "$d" ] && { warn "$d 가 링크라 건너뛰어요. 확인하고 지운 뒤 다시 실행하세요"; continue; }
        case $n in originals) o=root:root ;; *) o=$ACC:$ACC ;; esac
        mkdir -p "$d" && chown "$o" "$d" && chmod 755 "$d"
    done
    ok "NAS 팀 폴더 $NAS_DIR: datasets·models·backup·docker_images·tmp_transfer·inbox 는 팀원이 쓰고, originals 는 root만 고쳐요"
fi

step '2. gpu 명령 설치 (gpu fetch)'
[ -f bin/gpu ] || stop "파일이 없어요: $HERE/bin/gpu" "묶음을 다시 푸세요: cd $HERE && tar xf gpu-setup.tar"
install -m 755 bin/gpu "$S/bin/gpu"
ok "$S/bin/gpu 를 설치했어요. 올린 파일은 이 명령으로 /app/inbox 에 옮겨요: $S/bin/gpu fetch <이름>"

echo
echo "${c_g}############################ 완료 ############################${c_0}"
echo " 다음 단계(admin/1_처음_설치.md). 올린 파일은 모두 $S/bin/gpu fetch 로 옮기고 지문을 확인한 뒤 실행해요"
echo "  2) 기초 프로그램: $S/bin/gpu fetch gpu-pkgs.tar → cd /app/inbox && tar xf gpu-pkgs.tar && bash pkgs_install.sh"
echo "  3) 도커:         $S/bin/gpu fetch gpu-docker.tar → cd /app/inbox && tar xf gpu-docker.tar && bash docker_install.sh"
echo "  6) 권한·규칙 설정: 설치를 다 끝낸 뒤 cd /app/inbox && bash admin_setup.sh"
echo "  (4·5단계 데이터셋·모델은 사용자가 공용 계정으로 넣어요. 2단계가 끝나면 언제든 돼요)"
echo "${c_g}##############################################################${c_0}"
