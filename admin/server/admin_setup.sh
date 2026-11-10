#!/usr/bin/env bash
# [GPU 서버 · 관리자(root) 전용] 6단계 권한·규칙 설정. 설치를 다 끝낸 뒤, 팀원에게 서버를 열기 전에 실행한다. 여러 번 실행해도 된다.
#   bash admin_setup.sh          적용
#   bash admin_setup.sh --undo   되돌리기(접속 설정과 정기 점검만 지운다. 준비(prepare.sh)에서 만든 폴더·잠금·gpu 명령·기록은 그대로 둔다)
# 하는 일 (팀원에게 새 명령을 외우게 하지 않고, 막기보다 알린다)
#   - 공용 계정(/etc/gpu/account)에 관리자 권한(sudo, docker·disk·lxd 등 그룹)이 없는지 확인한다(있으면 알려만 준다)
#   - 팀원 명단·GPU 배분 파일과 이름별 작업 폴더, NAS 의 이름별 backup·docker_images 폴더를 만든다
#   - 접속할 때 이름을 고르게 하고, 이름별 캐시·명령 기록을 나눈다(/etc/profile.d/gpu.sh)
#   - docker, nvidia-smi 도우미를 /app/admin/bin 에 설치한다(이름표, GPU 겹침 경고, "GPU별 사용자" 표)
#   - GPU 서비스(persistenced, HGX 보드면 Fabric Manager)를 켠다. 드라이버 버전은 고정하지 않는다(업데이트는 서버 관리 팀이 정한다)
#   - 10분마다 GPU 사용 기록과 알림, 월요일 아침 주간 보고서(/etc/cron.d/gpu)
# 권한은 서버 관리 팀 설정에 따라 마음대로 안 될 수 있다. 그래서 하나가 안 돼도 멈추지 않고 [주의]로 알린 뒤 나머지를 계속한다
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


if [ "${1:-}" = --undo ]; then
    step '되돌리기'
    rm -f /etc/profile.d/gpu.sh /etc/cron.d/gpu
    sed -i '/# gpu admin_setup/d' /etc/bash.bashrc
    ok '접속 설정과 정기 점검을 지웠어요. 준비(prepare.sh)에서 만든 폴더·잠금·gpu 명령과 기록(/app/state)은 그대로 뒀어요.'
    echo "  다시 쓰려면 같은 폴더에서 bash admin_setup.sh 를 실행하세요."
    exit 0
fi


echo "[GPU 서버] 권한·규칙 설정  ($(date '+%Y-%m-%d %H:%M'), 공용 계정 $ACC)"

# 준비(prepare.sh)가 만든 /app/admin 이 있어야 한다(root 소유 + root 가 잠근 표시 파일)
{ [ "$(stat -c %U "$S" 2>/dev/null)" = root ] && [ "$(stat -c %U "$S/.gpu_root" 2>/dev/null)" = root ] && [ ! -L "$S" ]; } ||
    stop "준비가 안 돼 있어요($S 가 없거나 root 가 잠그지 않았어요)" "먼저 실행하세요: cd /app/inbox && bash prepare.sh"

# ------------------------------------------------------------------ 1. 공용 계정 권한 (확인만)
# 공용 계정이 sudo 나 docker 그룹을 가지면 누구든 root 가 될 수 있어, 아래 잠금이 모두 무의미해진다.
# 지금은 없다고 들었지만 서버 관리 팀이 나중에 넣을 수도 있어 실행할 때마다 확인만 한다(바꾸지는 않는다)
step '1. 공용 계정 권한 확인'
# disk(디스크 장치 직접 읽고 쓰기), lxd·incus-admin(컨테이너로 root), libvirt(가상 머신)도 root 와 다름없다
bad=$(id -nG "$ACC" | tr ' ' '\n' | grep -xE 'sudo|admin|wheel|docker|disk|lxd|incus-admin|libvirt' | tr '\n' ' ')
[ -z "$bad" ] && ok "공용 계정($ACC)은 관리자 권한 그룹(sudo·docker·disk·lxd 등)에 없어요" ||
    warn "공용 계정($ACC)이 관리자 그룹에 있어요: $bad. 팀원 누구나 root가 될 수 있으니 서버 관리 팀과 확인하세요(빼는 명령: gpasswd -d $ACC 그룹이름)"
sudo -l -U "$ACC" 2>/dev/null | grep -q 'may run' && warn "공용 계정($ACC)이 sudo를 쓸 수 있어요. 설정 위치: grep -rn $ACC /etc/sudoers /etc/sudoers.d/" || ok "공용 계정($ACC)은 sudo를 못 써요"

# ------------------------------------------------------------------ 2. 팀원 명단과 작업 폴더
step '2. 팀원 명단, GPU 배분, 작업 폴더'
# 팀원 명단과 GPU 배분: 관리자가 고치고, gpu 명령이 읽는다(엑셀 '팀원', 'GPU 배분' 시트와 같게)
[ -f "$S/team.txt" ] || cat > "$S/team.txt" <<'EOF'
# 팀원 명단. 관리자만 고친다. 엑셀 '팀원' 시트와 같게 맞춘다.
# 형식: 이름  그룹   (그룹은 gpu_alloc.txt 의 그룹 이름)
# 예:  홍길동  인지
EOF
# GPU 배분은 서버마다 다르다. 서버 2는 다른 팀과 같이 써서 0~3번이 다른 팀 것이다.
# 서버 이름만으로 정하면 이름이 예상과 다를 때 서버 1 배분이 들어가고(다른 팀 GPU 경고가 빠진다),
# 처음 만들 때는 관리자에게 묻는다. 이름 끝이 p2 면 2를 기본값으로 보여 준다
if [ ! -f "$S/gpu_alloc.txt" ]; then
    guess=1; case "$(hostname -s)" in *p2) guess=2 ;; esac
    [ -t 0 ] || stop 'GPU 배분 파일을 처음 만들려면 서버 번호를 답해야 해요' 'PuTTY 화면에서 직접 실행하세요: bash admin_setup.sh'
    echo "  GPU 배분 파일을 처음 만들어요. 이 서버는 몇 번인가요?"
    echo "    1 = 우리 팀만 쓰는 서버,  2 = 다른 팀과 같이 쓰는 서버(0~3번이 다른 팀)"
    read -r -p "  서버 번호 [Enter = $guess]: " srv; srv=${srv:-$guess}
    case "$srv" in 1|2) ;; *) stop "서버 번호는 1이나 2예요(입력: $srv)" '다시 실행해 1이나 2를 입력하세요: bash admin_setup.sh' ;; esac
fi
if [ ! -f "$S/gpu_alloc.txt" ]; then case "$srv" in
2) cat > "$S/gpu_alloc.txt" <<'EOF'
# GPU 배분(서버 2). 관리자만 고친다. 엑셀 'GPU 배분' 시트와 같게 맞춘다.
# 형식: GPU번호  그룹      (공용 = 누구나 선착순, 다른팀 = 다른 팀 GPU라 우리 팀은 쓰지 않는다)
# 서버 2는 다른 팀과 같이 써서 우리 팀은 4~7번만 쓴다. 그룹 배분은 임시
0  다른팀
1  다른팀
2  다른팀
3  다른팀
4  인지
5  판단
6  공용
7  공용
EOF
;;
*) cat > "$S/gpu_alloc.txt" <<'EOF'
# GPU 배분(서버 1). 관리자만 고친다. 엑셀 'GPU 배분' 시트와 같게 맞춘다.
# 형식: GPU번호  그룹      (공용 = 누구나 선착순, 다른팀 = 다른 팀 GPU라 우리 팀은 쓰지 않는다)
0  자율주행매니저
1  인지
2  인지
3  판단
4  판단
5  공용
6  공용
7  공용
EOF
;;
esac; fi
chmod 644 "$S/team.txt" "$S/gpu_alloc.txt"
ok "GPU 배분: $(awk '!/^[ \t]*#/ && NF>=2 {g[$2] = g[$2] (g[$2] ? "," : "") $1} END {for (k in g) printf "%s %s  ", k, g[k]}' "$S/gpu_alloc.txt")($S/gpu_alloc.txt)"
n_team=$(grep -cvE '^\s*(#|$)' "$S/team.txt")
[ "$n_team" -gt 0 ] && ok "팀원 ${n_team}명 등록돼 있어요($S/team.txt)" ||
    warn "팀원 명단이 비어 있어요. $S/team.txt 에 한 줄에 '이름 그룹'으로 적고 다시 실행하세요(비어 있는 동안은 접속할 때 번호 목록 없이 아무 이름이나 받아요)"
grep -vE '^\s*(#|$)' "$S/team.txt" | while read -r name grp _; do
    case "$name" in *-*|*/*|.*) warn "쓸 수 없는 이름이라 건너뛰어요: $name ('-', '/'를 빼고 다시 적으세요)"; continue ;; esac
    case "$name" in 관리자|다른팀|이름없음|'?') warn "알림·표시에 쓰는 이름이라 팀원 이름으로 쓸 수 없어요: $name"; continue ;; esac
    [ -n "$grp" ] && grep -qE "^\s*[0-9]+\s+$grp\s*$" "$S/gpu_alloc.txt" ||
        warn "$name: gpu_alloc.txt에 없는 그룹이에요(${grp:-그룹 칸 비어 있음}). team.txt의 그룹 이름을 gpu_alloc.txt와 글자까지 같게 적으세요"
    [ -d "$W/$name" ] || { setsid -w runuser -u "$ACC" -- mkdir -p "$W/$name/images" && echo "    작업 폴더를 만들었어요: $W/$name"; }
done
# NAS 의 이름별 폴더(backup·docker_images). 준비(prepare.sh)가 NAS 팀 폴더를 만들었을 때만
NAS_DIR=$(sed -n 's/^NAS_DIR=\([^ #]*\).*/\1/p' "$S/gpu.conf" 2>/dev/null | tail -1); NAS_DIR=${NAS_DIR:-/data/autonomy_sw}
if [ -d "$NAS_DIR/backup" ] && [ ! -L "$NAS_DIR/backup" ] && [ ! -L "$NAS_DIR/docker_images" ]; then
    grep -vE '^\s*(#|$)' "$S/team.txt" | while read -r name _; do
        case "$name" in *-*|*/*|.*) continue ;; esac
        setsid -w runuser -u "$ACC" -- mkdir -p "$NAS_DIR/backup/$name" "$NAS_DIR/docker_images/$name"
    done
    ok "NAS 의 이름별 폴더: $NAS_DIR/backup/<이름>, $NAS_DIR/docker_images/<이름>"
else
    warn "NAS 팀 폴더($NAS_DIR/backup)가 없어서 이름별 폴더를 만들지 않았어요. 준비(prepare.sh)의 NAS 줄을 확인하세요"
fi
# ------------------------------------------------------------------ 3. 도우미
step '3. 도우미 설치 (docker, nvidia-smi, gpu)'
for f in gpu docker nvidia-smi; do
    [ -f "bin/$f" ] || stop "도우미 파일이 없어요: $HERE/bin/$f" "묶음을 다시 푸세요: cd $HERE && tar xf gpu-setup.tar"
    install -m 755 "bin/$f" "$S/bin/$f"
done
rm -f "$S/bin/rules.txt" "$ST/claims.tsv" "$ST/unknown_seen.tsv"   # 예전 버전의 파일
ok "$S/bin 에 설치했어요: docker(이름표·GPU 겹침 경고), nvidia-smi(GPU별 사용자 표), gpu(접속 인사·정기 점검)"
# docker ps 에 사람(USER)과 GPU 열을 보이게 한다(공용 계정의 docker 설정). 공용 계정 홈이라 공용 계정 권한으로 쓴다
setsid -w runuser -u "$ACC" -- mkdir -p "$HOME_A/.docker"
setsid -w runuser -u "$ACC" -- python3 -I - "$HOME_A/.docker/config.json" <<'PY'
import json, os, sys
p = sys.argv[1]
try: c = json.load(open(p))
except Exception: c = {}
c["psFormat"] = 'table {{.Names}}\t{{.Label "gpu.USER"}}\t{{.Label "gpu.GPUS"}}\t{{.Image}}\t{{.Status}}'
json.dump(c, open(p, "w"), indent=2)
PY
ok 'docker ps 에 이름(USER)과 GPU(GPUS) 열을 넣었어요'


# ------------------------------------------------------------------ 4. 접속 설정
step '4. 접속 설정 (/etc/profile.d/gpu.sh)'
cat > /etc/profile.d/gpu.sh <<EOF
# GPU 서버 공용 설정. admin_setup.sh 가 만든다. 관리자만 고칠 수 있다.
[ -n "\${BASH_VERSION:-}" ] || return 0
# 우리 공용 계정에만 건다. 다른 계정(서버 2의 다른 팀, root)의 docker·nvidia-smi·PATH 는 건드리지 않는다
# 한글이 깨지지 않게 UTF-8 로 맞춘다(HIWARE 접속은 언어 설정이 비어 올 수 있다). root 도 team.txt 에 한글을 적는다
case "\$(locale charmap 2>/dev/null)" in UTF-8) ;; *) unset LC_ALL; export LANG=C.UTF-8 ;; esac
if [ "\$(id -u)" = 0 ]; then
    # 관리자: 아직 안 본 알림(이름 없는 GPU 사용, 디스크, GPU 오류, 주간 보고서)
    case \$- in *i*) [ -n "\${GPU_ADMIN_DONE:-}" ] || $S/bin/gpu _notices 관리자; GPU_ADMIN_DONE=1 ;; esac
    return 0
fi
[ "\$(id -un)" = "$ACC" ] || return 0
# 도우미(docker, nvidia-smi)가 진짜 명령보다 먼저 오게 맨 앞에
case ":\$PATH:" in *":$S/bin:"*) ;; *) PATH="$S/bin:\$PATH"; export PATH ;; esac
[ -n "\${GPU_PROFILE_DONE:-}" ] && return 0
GPU_PROFILE_DONE=1
# 서버에는 인터넷이 없으니 Hugging Face 가 접속을 시도하지 않게 한다
export HF_HUB_OFFLINE=1 HF_DATASETS_OFFLINE=1 TRANSFORMERS_OFFLINE=1
case \$- in *i*) ;; *) return 0 ;; esac   # 파일 전송(FileZilla) 같은 비대화 접속은 여기까지
# 이름 고르기. tmux 새 창 등에서는 이미 이름이 있다
if [ -z "\${GPU_USER:-}" ]; then
    $S/bin/gpu _hello
    _gpu_list=\$($S/bin/gpu _names)
    if [ -n "\$_gpu_list" ]; then echo "  이름을 고르세요(번호나 이름):"; echo "\$_gpu_list"; fi
    for _gpu_i in 1 2 3; do
        read -r -p "  > " _gpu_a || break
        GPU_USER=\$($S/bin/gpu _resolve "\$_gpu_a") && break
        echo "  목록에 없어요. 번호나 이름을 다시 입력하세요(명단에 내 이름이 없으면 관리자에게 등록을 요청하세요)."
    done
    unset _gpu_list _gpu_i _gpu_a
    [ -n "\${GPU_USER:-}" ] || echo "  이름 없이 접속했어요. 내 GPU 작업과 컨테이너가 '이름 없음'으로 보여요. 다시 고르려면: exec bash -l"
    # 이 창에 알림을 보낼 수 있게 창(pts)과 이름을 적어 둔다
    _gpu_t=\$(tty 2>/dev/null)
    case "\$_gpu_t" in /dev/pts/[0-9]*) [ -n "\${GPU_USER:-}" ] && printf '%s' "\$GPU_USER" > "$ST/tty/pts-\${_gpu_t##*/}" 2>/dev/null ;; esac
    unset _gpu_t
fi
# 사람마다 tmux 를 따로 쓴다(계정이 같아 tmux 하나를 같이 쓰면 남의 창이 섞인다)
tmux() { LC_ALL=C.UTF-8 command tmux -L "u-\${GPU_USER:-이름없음}" "\$@"; }
[ -n "\${GPU_USER:-}" ] || return 0
export GPU_USER GPU_WS=$W/\$GPU_USER
[ -d "\$GPU_WS" ] || mkdir -p "\$GPU_WS/images" 2>/dev/null   # 명단에 나중에 넣은 사람
# 홈(10 GB)은 모두가 같이 쓰므로 캐시와 pip --user 설치는 내 작업 폴더에
export XDG_CACHE_HOME=\$GPU_WS/.cache TRITON_CACHE_DIR=\$GPU_WS/.cache/triton PYTHONUSERBASE=\$GPU_WS/.local
case ":\$PATH:" in *":\$PYTHONUSERBASE/bin:"*) ;; *) PATH="\$PATH:\$PYTHONUSERBASE/bin" ;; esac
export HISTFILE=$ST/history/\$GPU_USER.bash_history HISTTIMEFORMAT='%F %T '
export GIT_AUTHOR_NAME=\$GPU_USER GIT_COMMITTER_NAME=\$GPU_USER
_gpu_ps1() { case "\$PS1" in "[\$GPU_USER] "*) ;; *) PS1="[\$GPU_USER] \$PS1" ;; esac; }
PROMPT_COMMAND="_gpu_ps1\${PROMPT_COMMAND:+;\$PROMPT_COMMAND}"
if [ -z "\${TMUX:-}" ]; then
    [ "\$PWD" = "\$HOME" ] && [ -d "\$GPU_WS" ] && cd "\$GPU_WS"
    $S/bin/gpu _notices
fi
EOF
chmod 644 /etc/profile.d/gpu.sh
# 로그인 셸이 아닌 새 셸에서도 같은 설정을 읽게 한다
grep -q '# gpu admin_setup' /etc/bash.bashrc ||
    echo '[ -r /etc/profile.d/gpu.sh ] && . /etc/profile.d/gpu.sh  # gpu admin_setup' >> /etc/bash.bashrc
# 예전 방식(~/.bashrc 의 PATH 줄)은 지운다. 이제 시스템 설정이 맡는다
[ -f "$HOME_A/.bashrc" ] && setsid -w runuser -u "$ACC" -- sed -i '\#shared/tools/bin#d' "$HOME_A/.bashrc"
ok '접속 설정: 이름 고르기(번호), 이름별 캐시·명령 기록, 작업 폴더로 이동, 알림 보기'

# ------------------------------------------------------------------ 5. GPU 서비스
step '5. GPU 서비스'
# PCIe 카드(H200 NVL 등)는 NVSwitch 가 없어 Fabric Manager 가 필요 없다(켜면 시작하지 못하고 실패만 남긴다)
gname=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1)
svcs=(nvidia-persistenced nvidia-fabricmanager nvlsm)
case "$gname" in *NVL*|*PCIe*) svcs=(nvidia-persistenced); ok "PCIe 카드($gname)라 Fabric Manager는 켜지 않아요" ;; esac
for svc in "${svcs[@]}"; do
    if systemctl list-unit-files "$svc.service" 2>/dev/null | grep -q "$svc"; then
        systemctl enable --now "$svc" >/dev/null 2>&1 && ok "$svc 서비스를 켰어요(부팅할 때도 자동으로 켜져요)" || warn "$svc 를 켜지 못했어요. 원인 확인: systemctl status $svc"
    else
        [ "$svc" = nvidia-persistenced ] && warn "$svc 서비스가 없어요(보통 드라이버와 함께 설치돼요). 서버 관리 팀에 확인하세요"
        [ "$svc" = nvidia-fabricmanager ] && warn "$svc 서비스가 없어요. HGX(SXM) 보드는 이게 있어야 GPU를 써요. 서버 관리 팀에 드라이버와 같은 버전으로 요청하세요"
    fi
done

# ------------------------------------------------------------------ 6. 정기 점검
step '6. 정기 점검'
cat > /etc/cron.d/gpu <<EOF
# gpu admin_setup.sh 가 만든다. cron 기본 PATH 에는 /usr/sbin(runuser)이 없다
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
*/10 * * * * root $S/bin/gpu _check
40 7 * * 1   root $S/bin/gpu _report > $ST/reports/\$(date +\%F).txt 2>&1 && echo "\$(date '+\%F \%H:\%M')	보고서-\$(date +\%F)	주간 보고서: $ST/reports/\$(date +\%F).txt" >> $ST/notice/관리자.txt
EOF
chmod 644 /etc/cron.d/gpu
ok "10분마다 GPU 사용 기록과 알림(같은 알림은 하루나 한 주에 한 번), 월요일 07:40에 주간 보고서($ST/reports)"


echo
echo "${c_g}############################ 완료 ############################${c_0}"
echo " 남은 일"
echo "  1) $S/team.txt 에 팀원을 한 줄에 '이름 그룹'으로 적고 이 스크립트를 한 번 더 실행하세요(작업 폴더가 생겨요)"
echo "  2) GPU 배분은 $S/gpu_alloc.txt, 알림 기준은 $S/gpu.conf 에서 바꿔요(user/ 규칙 문서·엑셀도 같이)"
echo "  3) 위에 [주의]가 있으면 그 줄의 안내대로 서버 관리 팀과 정리하세요. 안 돼도 서버는 쓸 수 있어요"
echo "  4) 팀원에게 규칙(user/서버_사용_규칙.md·xlsx)과 사용법(user/사용_안내.md)을 알리세요"
echo " 확인: 공용 계정으로 다시 접속하면 이름 목록이 나오고, nvidia-smi 아래에 'GPU별 사용자' 표가 붙어요."
echo "${c_g}##############################################################${c_0}"
