#!/usr/bin/env bash
# [B200 서버 · 관리자(root) 전용] 공용 계정으로 여럿이 쓰는 서버의 기본 규칙을 시스템에 건다. 여러 번 실행해도 된다.
#   bash admin_setup.sh          적용
#   bash admin_setup.sh --undo   되돌리기(공용 폴더 잠금 풀기, 시스템 설정 지우기)
# 하는 일 (팀원에게 새 명령을 외우게 하지 않고, 막기보다 알린다)
#   - 공용 계정(/etc/b200/account)에 관리자 권한(sudo, docker 그룹)이 없는지 확인한다(있으면 알려만 준다)
#   - /app/shared(기초 프로그램·데이터셋·모델)와 /app/inbox(관리자가 올리는 설치 파일)를 root 소유로 잠근다
#   - 접속할 때 이름을 고르게 하고, 이름별 작업 폴더·캐시·명령 기록을 나눈다(/etc/profile.d/b200.sh)
#   - docker, nvidia-smi 도우미를 /app/shared/bin 에 설치한다(이름표, GPU 겹침 경고, "GPU별 사용자" 표)
#   - GPU 서비스(Fabric Manager, persistenced)를 켜고 드라이버 버전을 고정한다
#   - 10분마다 GPU 사용 기록과 알림, 월요일 아침 주간 보고서(/etc/cron.d/b200)
set -uo pipefail
cd "$(dirname "$0")"
HERE=$PWD
ACC=${B200_ACCOUNT:-$(cat /etc/b200/account 2>/dev/null)}   # 공용 계정 이름은 서버의 /etc/b200/account 한 곳에 적는다
S=/app/shared
W=/app/workspace
ST=/app/state
c_g=$'\e[32m'; c_y=$'\e[33m'; c_r=$'\e[31m'; c_c=$'\e[36m'; c_0=$'\e[0m'
step() { echo; echo "${c_c}==== $1 ====${c_0}"; }
ok()   { echo "  ${c_g}[정상]${c_0} $*"; }
warn() { echo "  ${c_y}[주의]${c_0} $*"; }
stop() { echo "${c_r}멈춤: $1${c_0}"; echo "할 일: $2"; exit 1; }

[ "$(id -u)" = 0 ] || stop 'root 계정이 아니에요' 'HIWARE에서 root로 접속해(PuTTY) 다시 실행하세요.'
[ -n "$ACC" ] || stop '공용 계정 이름을 알 수 없어요' '서버에 한 번 적어 두세요: mkdir -p /etc/b200 && echo <계정이름> > /etc/b200/account'
[[ "$ACC" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || stop "공용 계정 이름이 이상해요: $ACC" '/etc/b200/account 에 계정 이름 한 줄만 적으세요'
id "$ACC" >/dev/null 2>&1 || stop "공용 계정을 찾지 못했어요: $ACC" '/etc/b200/account 의 계정 이름을 확인하세요: cat /etc/b200/account'
HOME_A=$(getent passwd "$ACC" | cut -d: -f6)

if [ "${1:-}" = --undo ]; then
    step '되돌리기'
    rm -f /etc/profile.d/b200.sh /etc/cron.d/b200
    sed -i '/# b200 admin_setup/d' /etc/bash.bashrc
    ok '접속 설정과 정기 점검을 지웠어요. b200 명령, 공용 폴더 잠금, 기록(/app/state), 드라이버 고정은 그대로 뒀어요.'
    echo "  다시 쓰려면 같은 폴더에서 bash admin_setup.sh 를 실행하세요."
    exit 0
fi

echo "[B200 서버] 관리자 기본 설정  ($(date '+%Y-%m-%d %H:%M'), 공용 계정 $ACC)"

# ------------------------------------------------------------------ 1. 공용 계정 권한 (확인만)
# 공용 계정이 sudo 나 docker 그룹을 가지면 누구든 root 가 될 수 있어, 아래 잠금이 모두 무의미해진다.
# 지금은 없다고 들었지만 서버 관리 팀이 나중에 넣을 수도 있어 실행할 때마다 확인만 한다(바꾸지는 않는다)
step '1. 공용 계정 권한 확인'
bad=$(id -nG "$ACC" | tr ' ' '\n' | grep -xE 'sudo|admin|wheel|docker' | tr '\n' ' ')
[ -z "$bad" ] && ok "공용 계정($ACC)은 sudo·docker 그룹에 없어요" ||
    warn "공용 계정($ACC)이 관리자 그룹에 있어요: $bad. 팀원 누구나 root가 될 수 있으니 서버 관리 팀과 확인하세요(빼는 명령: gpasswd -d $ACC 그룹이름)"
sudo -l -U "$ACC" 2>/dev/null | grep -q 'may run' && warn "공용 계정($ACC)이 sudo를 쓸 수 있어요. 설정 위치: grep -rn $ACC /etc/sudoers /etc/sudoers.d/" || ok "공용 계정($ACC)은 sudo를 못 써요"

# ------------------------------------------------------------------ 2. 폴더
step '2. 폴더와 잠금'
[ -d /app ] || stop '/app 폴더가 없어요' '서버 관리 팀에 2 TB SSD를 /app에 연결해 달라고 요청하세요.'
[ -L /app ] && stop '/app이 링크예요' 'ls -l /app 으로 어디를 가리키는지 보고, 서버 관리 팀에 실제 디스크로 연결해 달라고 요청하세요.'
# /app 은 root 만 고칠 수 있게 한다. 공용 계정이 /app 에 쓸 수 있으면 shared·state 같은 이름으로 시스템 폴더 링크를 심어 두고,
# 아래 chown·chmod(링크를 따라간다)를 시스템 폴더에 하게 만들 수 있다. 잠근 뒤에 링크가 있는지 본다
# 서버 2처럼 다른 팀과 같이 쓰는 서버에서 다른 계정이 /app 에 폴더를 두고 있으면, 잠그면 그 계정이 /app 에 새 폴더를 못 만든다
others=$(find /app -mindepth 1 -maxdepth 1 ! -user root ! -user "$ACC" -printf '%u %p\n' 2>/dev/null)
if [ -n "$others" ] && [ "$(stat -c '%U %a' /app)" != "root 755" ]; then
    echo "$others" | sed 's/^/    다른 계정 폴더: /'
    warn "/app 을 다른 계정도 쓰는 것 같아요. 잠그면(root 소유, 755) 그 계정은 /app 바로 아래에 새 폴더를 못 만들어요(있는 폴더는 그대로 써요)"
    if [ -t 0 ]; then read -r -p "  서버 관리 팀·다른 팀과 이미 정했으면 y, 아니면 Enter(여기서 멈춰요): " a; [ "$a" = y ] || stop '/app 잠금 보류' '서버 관리 팀·다른 팀과 /app 사용을 정한 뒤 다시 실행하세요.'
    else stop '/app 을 다른 계정도 써요' 'PuTTY 화면에서 직접 실행해 확인 질문에 답하세요: bash admin_setup.sh'; fi
fi
chown root:root /app && chmod 755 /app
for d in "$S" "$W" "$ST" /app/inbox /app/upload /app/docker "$ST"/{history,gpu_log,reports,images,notice,notice_seen,tty}; do
    [ -L "$d" ] && stop "링크가 있어요(누가 만들었는지 몰라요): $d" "ls -l $d 로 어디를 가리키는지 보고, 직접 만든 게 아니면 rm $d 로 링크만 지운 뒤 다시 실행하세요."
done
mkdir -p "$S/bin" "$W" "$ST"/{history,gpu_log,reports,images,notice,notice_seen,tty} /app/inbox
# 공용: root 만 쓰고 모두 읽는다
chown -R root:root "$S" && chmod -R u+rwX,go+rX,go-w "$S"
ok "$S: root만 고치고 팀원은 읽기만 해요"
# 작업 공간과 기록: 공용 계정이 쓴다(보고서만 root)
chown "$ACC:$ACC" "$W" && chmod 755 "$W"
# 기록 폴더: 공용 계정이 쓰는 곳(history, images, notice_seen)과 root 만 쓰는 곳(reports, gpu_log, notice)을 나눈다.
# root 는 공용 계정이 쓸 수 있는 곳에 파일을 만들거나 고치지 않는다(미리 심어 둔 링크로 시스템 파일을 덮거나 주인을 바꿀 수 있다)
chown root:root "$ST" && chmod 755 "$ST"   # root 소유라야 공용 계정이 아래 root 폴더를 바꿔치기하지 못한다
for d in history images notice_seen tty; do chown -R "$ACC:$ACC" "$ST/$d"; done
for d in reports gpu_log notice; do chown -R root:root "$ST/$d" && chmod 755 "$ST/$d"; done
runuser -u "$ACC" -- touch "$ST/images/loaded.tsv"   # docker 래퍼(공용 계정)가 이미지를 들여온 사람을 적는다
# root 가 실행할 설치 파일을 두는 곳. 공용 계정이 고칠 수 있으면 누구든 root 로 원하는 명령을 실행시킬 수 있다
chown root:root /app/inbox && chmod 755 /app/inbox
[ -d /app/inbox/images ] && rmdir /app/inbox/images/* /app/inbox/images 2>/dev/null
# root 는 FileZilla 를 못 쓰므로 설치 파일은 공용 계정이 여기에 올린다. root 는 /app/inbox 로 새로 복사하고 지문을 확인한 뒤 실행한다
mkdir -p /app/upload && chown "$ACC:$ACC" /app/upload && chmod 755 /app/upload
ok "$W: 팀원 작업 공간,  $ST: 기록·알림,  /app/upload: 설치 파일 올리는 곳(공용 계정),  /app/inbox: root가 지문을 확인한 설치 파일"
# 홈에서도 보이게 링크(홈은 10 GB 라 실제 파일은 /app 에)
for n in shared workspace; do
    [ -e "$HOME_A/$n" ] || [ -L "$HOME_A/$n" ] || runuser -u "$ACC" -- ln -sn "/app/$n" "$HOME_A/$n"   # 공용 계정 홈이라 그 권한으로
done
# 팀원 명단과 GPU 배분: 관리자가 고치고, b200 명령이 읽는다(엑셀 '팀원', 'GPU 배분' 시트와 같게)
[ -f "$S/team.txt" ] || cat > "$S/team.txt" <<'EOF'
# 팀원 명단. 관리자만 고친다. 엑셀 '팀원' 시트와 같게 맞춘다.
# 형식: 이름  그룹   (그룹은 gpu_alloc.txt 의 그룹 이름)
# 예:  홍길동  인지
EOF
# GPU 배분은 서버마다 다르다. 서버 2(이름이 p2 로 끝남)는 다른 팀과 같이 써서 0~3번이 다른 팀 것이다
if [ ! -f "$S/gpu_alloc.txt" ]; then case "$(hostname -s)" in
*p2) cat > "$S/gpu_alloc.txt" <<'EOF'
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
ok "GPU 배분: $(awk '!/^\s*#/ && NF>=2 {g[$2] = g[$2] (g[$2] ? "," : "") $1} END {for (k in g) printf "%s %s  ", k, g[k]}' "$S/gpu_alloc.txt")($S/gpu_alloc.txt)"
n_team=$(grep -cvE '^\s*(#|$)' "$S/team.txt")
[ "$n_team" -gt 0 ] && ok "팀원 ${n_team}명 등록돼 있어요($S/team.txt)" ||
    warn "팀원 명단이 비어 있어요. $S/team.txt 에 한 줄에 '이름 그룹'으로 적고 다시 실행하세요(비어 있는 동안은 접속할 때 번호 목록 없이 아무 이름이나 받아요)"
grep -vE '^\s*(#|$)' "$S/team.txt" | while read -r name grp _; do
    case "$name" in *-*|*/*|.*) warn "쓸 수 없는 이름이라 건너뛰어요: $name ('-', '/'를 빼고 다시 적으세요)"; continue ;; esac
    [ -n "$grp" ] && grep -qE "^\s*[0-9]+\s+$grp\s*$" "$S/gpu_alloc.txt" ||
        warn "$name: gpu_alloc.txt에 없는 그룹이에요(${grp:-그룹 칸 비어 있음}). team.txt의 그룹 이름을 gpu_alloc.txt와 글자까지 같게 적으세요"
    [ -d "$W/$name" ] || { runuser -u "$ACC" -- mkdir -p "$W/$name/images" && echo "    작업 폴더를 만들었어요: $W/$name"; }
done
# 알림 기준 숫자. 바꾸면 규칙 문서(team/)의 숫자도 같이 바꾼다. 예전 설정(자동 종료 등)이 있으면 새로 쓴다
grep -q '^IDLE_HOURS=' "$S/b200.conf" 2>/dev/null || cat > "$S/b200.conf" <<'EOF'
# b200 알림 기준. 관리자만 고친다. 바꾸면 팀원 규칙 문서의 숫자도 같이 바꾼다. 모두 알림만 하고 멈추거나 지우지 않는다.
MAX_GPUS=4            # docker run 때 내 GPU가 이보다 많아지면 경고
IDLE_HOURS=12         # GPU를 잡고 이 시간 내내 사용률 0%면 그 사람에게 알림(하루 한 번)
DISK_ALERT=85         # /app 이 이 % 를 넘으면 많이 쓰는 3명과 관리자에게 알림(주 한 번)
IMAGE_NOTICE_DAYS=30  # 이 일수 동안 안 쓴 도커 이미지는 들여온 사람에게 알림(주 한 번)
NAS_DIR=              # NAS의 우리 팀 폴더(예: /data/<팀 폴더>). 적으면 주간 보고서에 폴더별 사용량(docs/9_NAS.md)
EOF
grep -q '^NAS_DIR=' "$S/b200.conf" ||   # 예전 버전으로 만든 설정에는 없다
    echo 'NAS_DIR=              # NAS의 우리 팀 폴더(예: /data/<팀 폴더>). 적으면 주간 보고서에 폴더별 사용량(docs/9_NAS.md)' >> "$S/b200.conf"
chmod 644 "$S/b200.conf"
# NAS 팀 폴더를 정했으면(NAS_DIR) 팀원별 backup·images 폴더도 공용 계정 권한으로 만든다(root 는 NAS에 쓰지 않는다)
NAS_DIR=$(sed -n 's/^NAS_DIR=\([^ #]*\).*/\1/p' "$S/b200.conf" | tail -1)
if [ -n "$NAS_DIR" ]; then
    if runuser -u "$ACC" -- test -d "$NAS_DIR" -a -w "$NAS_DIR"; then
        grep -vE '^\s*(#|$)' "$S/team.txt" | while read -r name _; do
            case "$name" in *-*|*/*|.*) continue ;; esac
            runuser -u "$ACC" -- mkdir -p "$NAS_DIR/backup/$name" "$NAS_DIR/images/$name" "$NAS_DIR/transfer"
        done
        ok "NAS 팀 폴더($NAS_DIR)에 팀원별 backup·images 폴더를 맞췄어요"
    else warn "NAS 팀 폴더($NAS_DIR)가 없거나 공용 계정이 쓸 수 없어요(docs/9_NAS.md 의 '처음 만들기')"; fi
fi

# ------------------------------------------------------------------ 3. 도우미
step '3. 도우미 설치 (docker, nvidia-smi, b200)'
for f in b200 docker nvidia-smi; do
    [ -f "bin/$f" ] || stop "도우미 파일이 없어요: $HERE/bin/$f" "묶음을 다시 푸세요: cd $HERE && tar xf b200-pack.tar"
    install -m 755 "bin/$f" "$S/bin/$f"
done
rm -f "$S/bin/rules.txt" "$ST/claims.tsv" "$ST/unknown_seen.tsv"   # 예전 버전의 파일
ok "$S/bin 에 설치했어요: docker(이름표·GPU 겹침 경고), nvidia-smi(GPU별 사용자 표), b200(접속 인사·정기 점검)"
# docker ps 에 사람(USER)과 GPU 열을 보이게 한다(공용 계정의 docker 설정). 공용 계정 홈이라 공용 계정 권한으로 쓴다
runuser -u "$ACC" -- mkdir -p "$HOME_A/.docker"
runuser -u "$ACC" -- python3 - "$HOME_A/.docker/config.json" <<'PY'
import json, os, sys
p = sys.argv[1]
try: c = json.load(open(p))
except Exception: c = {}
c["psFormat"] = 'table {{.Names}}\t{{.Label "b200.USER"}}\t{{.Label "b200.GPUS"}}\t{{.Image}}\t{{.Status}}'
json.dump(c, open(p, "w"), indent=2)
PY
ok 'docker ps 에 이름(USER)과 GPU(GPUS) 열을 넣었어요'


# ------------------------------------------------------------------ 4. 접속 설정
step '4. 접속 설정 (/etc/profile.d/b200.sh)'
cat > /etc/profile.d/b200.sh <<EOF
# B200 서버 공용 설정. admin_setup.sh 가 만든다. 관리자만 고칠 수 있다.
[ -n "\${BASH_VERSION:-}" ] || return 0
# 우리 공용 계정에만 건다. 다른 계정(서버 2의 다른 팀, root)의 docker·nvidia-smi·PATH 는 건드리지 않는다
# 한글이 깨지지 않게 UTF-8 로 맞춘다(HIWARE 접속은 언어 설정이 비어 올 수 있다). root 도 team.txt 에 한글을 적는다
case "\$(locale charmap 2>/dev/null)" in UTF-8) ;; *) unset LC_ALL; export LANG=C.UTF-8 ;; esac
if [ "\$(id -u)" = 0 ]; then
    # 관리자: 아직 안 본 알림(이름 없는 GPU 사용, 디스크, GPU 오류, 주간 보고서)
    case \$- in *i*) [ -n "\${B200_ADMIN_DONE:-}" ] || $S/bin/b200 _notices 관리자; B200_ADMIN_DONE=1 ;; esac
    return 0
fi
[ "\$(id -un)" = "$ACC" ] || return 0
# 도우미(docker, nvidia-smi)가 진짜 명령보다 먼저 오게 맨 앞에, 기초 프로그램은 맨 뒤에
case ":\$PATH:" in *":$S/bin:"*) ;; *) PATH="$S/bin:\$PATH:$S/tools/bin"; export PATH ;; esac
[ -n "\${B200_PROFILE_DONE:-}" ] && return 0
B200_PROFILE_DONE=1
# 서버에는 인터넷이 없으니 Hugging Face 가 접속을 시도하지 않게 한다
export HF_HUB_OFFLINE=1 HF_DATASETS_OFFLINE=1 TRANSFORMERS_OFFLINE=1
case \$- in *i*) ;; *) return 0 ;; esac   # 파일 전송(FileZilla) 같은 비대화 접속은 여기까지
# 이름 고르기. tmux 새 창 등에서는 이미 이름이 있다
if [ -z "\${B200_USER:-}" ]; then
    $S/bin/b200 _hello
    _b200_list=\$($S/bin/b200 _names)
    if [ -n "\$_b200_list" ]; then echo "  이름을 고르세요(번호나 이름):"; echo "\$_b200_list"; fi
    for _b200_i in 1 2 3; do
        read -r -p "  > " _b200_a || break
        B200_USER=\$($S/bin/b200 _resolve "\$_b200_a") && break
        echo "  목록에 없어요. 번호나 이름을 다시 입력하세요(명단에 내 이름이 없으면 관리자에게 등록을 요청하세요)."
    done
    unset _b200_list _b200_i _b200_a
    [ -n "\${B200_USER:-}" ] || echo "  이름 없이 접속했어요. 내 GPU 작업과 컨테이너가 '이름 없음'으로 보여요. 다시 고르려면: exec bash -l"
    # 이 창에 알림을 보낼 수 있게 창(pts)과 이름을 적어 둔다
    _b200_t=\$(tty 2>/dev/null)
    case "\$_b200_t" in /dev/pts/[0-9]*) [ -n "\${B200_USER:-}" ] && printf '%s' "\$B200_USER" > "$ST/tty/pts-\${_b200_t##*/}" 2>/dev/null ;; esac
    unset _b200_t
fi
# 사람마다 tmux 를 따로 쓴다(계정이 같아 tmux 하나를 같이 쓰면 남의 창이 섞인다)
tmux() { LC_ALL=C.UTF-8 command tmux -L "u-\${B200_USER:-이름없음}" "\$@"; }
[ -n "\${B200_USER:-}" ] || return 0
export B200_USER B200_WS=$W/\$B200_USER
[ -d "\$B200_WS" ] || mkdir -p "\$B200_WS/images" 2>/dev/null   # 명단에 나중에 넣은 사람
# 홈(10 GB)은 모두가 같이 쓰므로 캐시와 pip --user 설치는 내 작업 폴더에
export XDG_CACHE_HOME=\$B200_WS/.cache TRITON_CACHE_DIR=\$B200_WS/.cache/triton PYTHONUSERBASE=\$B200_WS/.local
case ":\$PATH:" in *":\$PYTHONUSERBASE/bin:"*) ;; *) PATH="\$PATH:\$PYTHONUSERBASE/bin" ;; esac
export HISTFILE=$ST/history/\$B200_USER.bash_history HISTTIMEFORMAT='%F %T '
export GIT_AUTHOR_NAME=\$B200_USER GIT_COMMITTER_NAME=\$B200_USER
_b200_ps1() { case "\$PS1" in "[\$B200_USER] "*) ;; *) PS1="[\$B200_USER] \$PS1" ;; esac; }
PROMPT_COMMAND="_b200_ps1\${PROMPT_COMMAND:+;\$PROMPT_COMMAND}"
if [ -z "\${TMUX:-}" ]; then
    [ "\$PWD" = "\$HOME" ] && [ -d "\$B200_WS" ] && cd "\$B200_WS"
    $S/bin/b200 _notices
fi
EOF
chmod 644 /etc/profile.d/b200.sh
# 로그인 셸이 아닌 새 셸에서도 같은 설정을 읽게 한다
grep -q '# b200 admin_setup' /etc/bash.bashrc ||
    echo '[ -r /etc/profile.d/b200.sh ] && . /etc/profile.d/b200.sh  # b200 admin_setup' >> /etc/bash.bashrc
# 예전 방식(~/.bashrc 의 PATH 줄)은 지운다. 이제 시스템 설정이 맡는다
[ -f "$HOME_A/.bashrc" ] && runuser -u "$ACC" -- sed -i '\#shared/tools/bin#d' "$HOME_A/.bashrc"
ok '접속 설정: 이름 고르기(번호), 이름별 캐시·명령 기록, 작업 폴더로 이동, 알림 보기'

# ------------------------------------------------------------------ 5. GPU 서비스
step '5. GPU 서비스와 드라이버 고정'
for svc in nvidia-persistenced nvidia-fabricmanager nvlsm; do
    if systemctl list-unit-files "$svc.service" 2>/dev/null | grep -q "$svc"; then
        systemctl enable --now "$svc" >/dev/null 2>&1 && ok "$svc 서비스를 켰어요(부팅할 때도 자동으로 켜져요)" || warn "$svc 를 켜지 못했어요. 원인 확인: systemctl status $svc"
    else
        [ "$svc" = nvidia-persistenced ] && warn "$svc 서비스가 없어요(보통 드라이버와 함께 설치돼요). 서버 관리 팀에 확인하세요"
        [ "$svc" = nvidia-fabricmanager ] && warn "$svc 서비스가 없어요. HGX B200은 이게 있어야 GPU를 써요. 서버 관리 팀에 드라이버와 같은 버전으로 요청하세요"
    fi
done
mapfile -t held < <(dpkg-query -W -f='${Package} ${Status}\n' 2>/dev/null |
    awk '$NF=="installed" && $1 ~ /^(nvidia-|libnvidia-|cuda-drivers|nvlsm|libnvsdm|datacenter-gpu-manager)/ {print $1}')
if grep -qE '^\s*[0-9]+\s+다른팀' "$S/gpu_alloc.txt" 2>/dev/null; then
    warn '다른 팀과 같이 쓰는 서버라 드라이버 버전을 고정(apt-mark hold)하지 않았어요. 드라이버 업데이트는 서버 관리 팀·다른 팀과 정하세요'
elif [ ${#held[@]} -gt 0 ]; then
    apt-mark hold "${held[@]}" >/dev/null && ok "드라이버 관련 패키지 ${#held[@]}개의 버전을 고정했어요(apt-mark hold)"
else warn '고정할 NVIDIA 패키지를 찾지 못했어요(드라이버를 apt가 아닌 방식으로 설치했을 수 있어요)'; fi

# ------------------------------------------------------------------ 6. 정기 점검
step '6. 정기 점검'
cat > /etc/cron.d/b200 <<EOF
# b200 admin_setup.sh 가 만든다. cron 기본 PATH 에는 /usr/sbin(runuser)이 없다
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
*/10 * * * * root $S/bin/b200 _check
40 7 * * 1   root $S/bin/b200 _report > $ST/reports/\$(date +\%F).txt 2>&1 && echo "\$(date '+\%F \%H:\%M')	보고서-\$(date +\%F)	주간 보고서: $ST/reports/\$(date +\%F).txt" >> $ST/notice/관리자.txt
EOF
chmod 644 /etc/cron.d/b200
ok "10분마다 GPU 사용 기록과 알림(같은 알림은 하루나 한 주에 한 번), 월요일 07:40에 주간 보고서($ST/reports)"

echo
echo "${c_g}############################ 완료 ############################${c_0}"
echo " 남은 일"
echo "  1) $S/team.txt 에 팀원을 한 줄에 '이름 그룹'으로 적고 이 스크립트를 한 번 더 실행하세요(작업 폴더가 생겨요)"
echo "  2) GPU 배분은 $S/gpu_alloc.txt, 알림 기준은 $S/b200.conf 에서 바꿔요(team/ 규칙 문서·엑셀도 같이)"
echo "  3) 기초 프로그램: cd $HERE && bash pack_install.sh /app/shared"
echo "  4) 도커: b200-docker.tar 를 /app/upload 에 올린 뒤 $S/bin/b200 fetch b200-docker.tar (지문 확인) → cd /app/inbox && tar xf b200-docker.tar && bash docker_install.sh"
echo "  5) 데이터셋·모델: $S/bin/b200 fetch datasets / models → 설치(docs/1_처음_설치.md 4·5단계)"
echo " 확인: 공용 계정으로 다시 접속하면 이름 목록이 나오고, nvidia-smi 아래에 'GPU별 사용자' 표가 붙어요."
echo "${c_g}##############################################################${c_0}"
