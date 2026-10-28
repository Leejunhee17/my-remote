#!/usr/bin/env bash
# [B200 서버 · 관리자(root) 전용] 공용 계정으로 여럿이 쓰는 서버의 기본 규칙을 시스템에 건다. 여러 번 실행해도 된다.
#   bash admin_setup.sh          적용
#   bash admin_setup.sh --undo   되돌리기(공용 폴더 잠금 풀기, 시스템 설정 지우기)
# 하는 일
#   - 공용 계정(shareduser)에서 관리자 권한(sudo, docker 그룹)을 뺀다
#   - /app/shared(휠·기초 프로그램·데이터셋·모델)를 root 소유로 잠근다. 팀원은 읽기만 한다
#   - 접속할 때 이름을 묻고, 이름별 작업 폴더·명령 기록·GPU 사용 기록을 나눈다(/etc/profile.d/b200.sh)
#   - b200 명령을 /app/shared/bin 에 깐다
#   - GPU 서비스(Fabric Manager, persistenced)를 켜고 드라이버 버전을 고정한다
#   - 5분마다 GPU 사용 기록, 매일 아침 점검 보고서를 남긴다(/etc/cron.d/b200)
set -uo pipefail
cd "$(dirname "$0")"
HERE=$PWD
ACC=${B200_ACCOUNT:-shareduser}
S=/app/shared
W=/app/workspace
ST=/app/state
c_g=$'\e[32m'; c_y=$'\e[33m'; c_r=$'\e[31m'; c_c=$'\e[36m'; c_0=$'\e[0m'
step() { echo; echo "${c_c}==== $1 ====${c_0}"; }
ok()   { echo "  ${c_g}[정상]${c_0} $*"; }
warn() { echo "  ${c_y}[주의]${c_0} $*"; }
stop() { echo "${c_r}멈춤: $1${c_0}"; echo "할 일: $2"; exit 1; }

[ "$(id -u)" = 0 ] || stop 'root 가 아니다' '관리자(root) 계정으로 접속해 다시 실행한다.'
id "$ACC" >/dev/null 2>&1 || stop "공용 계정 $ACC 가 없다" '계정 이름이 다르면 B200_ACCOUNT=계정 bash admin_setup.sh'
HOME_A=$(getent passwd "$ACC" | cut -d: -f6)

if [ "${1:-}" = --undo ]; then
    step '되돌리기'
    rm -f /etc/profile.d/b200.sh /etc/cron.d/b200
    sed -i '/# b200 admin_setup/d' /etc/bash.bashrc
    [ -d "$S" ] && chown -R "$ACC:$ACC" "$S" && ok "$S 를 다시 $ACC 소유로"
    ok '접속 설정과 정기 점검을 지웠다. b200 명령, 기록(/app/state), 드라이버 고정은 그대로 둔다.'
    exit 0
fi

echo "[B200 서버] 관리자 기본 설정  ($(date '+%Y-%m-%d %H:%M'), 공용 계정 $ACC)"

# ------------------------------------------------------------------ 1. 공용 계정 권한
step '1. 공용 계정에서 관리자 권한 빼기'
for g in sudo admin wheel docker; do
    if id -nG "$ACC" | tr ' ' '\n' | grep -qx "$g"; then
        gpasswd -d "$ACC" "$g" >/dev/null && ok "$ACC 를 $g 그룹에서 뺐다"
    fi
done
if grep -rqsE "^[^#]*\b$ACC\b" /etc/sudoers /etc/sudoers.d/; then
    warn "sudoers 에 $ACC 가 적혀 있다. 직접 지운다: grep -rn $ACC /etc/sudoers /etc/sudoers.d/"
fi
sudo -l -U "$ACC" 2>/dev/null | grep -q 'may run' && warn "$ACC 가 아직 sudo 를 쓸 수 있다(위 sudoers 확인)" || ok "$ACC 는 sudo 를 못 쓴다"

# ------------------------------------------------------------------ 2. 폴더
step '2. 폴더와 잠금'
[ -d /app ] || stop '/app 이 없다' '2 TB SSD 를 /app 에 연결한다.'
mkdir -p "$S/bin" "$W" "$ST"/{history,gpu_log,reports,images} /app/inbox/images
# 공용: root 만 쓰고 모두 읽는다
chown -R root:root "$S" && chmod -R u+rwX,go+rX,go-w "$S"
ok "$S : root 만 고친다, 팀원은 읽기만"
# 작업 공간과 기록: 공용 계정이 쓴다(보고서만 root)
chown "$ACC:$ACC" "$W" && chmod 755 "$W"
chown -R "$ACC:$ACC" "$ST" && chown root:root "$ST/reports" && chmod 755 "$ST" "$ST/reports"
chown "$ACC:$ACC" /app/inbox /app/inbox/images
ok "$W : 팀원 작업 공간,  $ST : 명령·GPU 사용·이미지 기록,  /app/inbox/images : 팀원이 이미지를 올리는 곳"
# 홈에서도 보이게 링크(홈은 10 GB 라 실제 파일은 /app 에)
for n in shared workspace; do
    [ -e "$HOME_A/$n" ] || { ln -s "/app/$n" "$HOME_A/$n" && chown -h "$ACC:$ACC" "$HOME_A/$n"; }
done
# 팀원 명단과 GPU 배분: 관리자가 고치고, b200 명령이 읽는다(엑셀 '팀원', 'GPU 배분' 시트와 같게)
[ -f "$S/team.txt" ] || cat > "$S/team.txt" <<'EOF'
# 팀원 명단. 관리자만 고친다. 엑셀 '팀원' 시트와 같게 맞춘다.
# 형식: 이름  그룹   (그룹은 gpu_alloc.txt 의 그룹 이름)
# 예:  홍길동  인지
EOF
[ -f "$S/gpu_alloc.txt" ] || cat > "$S/gpu_alloc.txt" <<'EOF'
# GPU 배분. 관리자만 고친다. 엑셀 'GPU 배분' 시트와 같게 맞춘다.
# 형식: GPU번호  그룹      (공용 = 누구나 선착순)
0  자율주행매니저
1  인지
2  인지
3  판단
4  판단
5  공용
6  공용
7  공용
EOF
chmod 644 "$S/team.txt" "$S/gpu_alloc.txt"
n_team=$(grep -cvE '^\s*(#|$)' "$S/team.txt")
[ "$n_team" -gt 0 ] && ok "팀원 $n_team 명 등록됨 ($S/team.txt)" ||
    warn "팀원 명단이 비어 있다. $S/team.txt 에 '이름 그룹' 을 적는다(비어 있으면 아무 이름이나 받는다)"
grep -vE '^\s*(#|$)' "$S/team.txt" | while read -r name _; do
    [ -d "$W/$name" ] || { mkdir -p "$W/$name" && chown "$ACC:$ACC" "$W/$name"; echo "    작업 폴더 만듦: $W/$name"; }
done

# ------------------------------------------------------------------ 3. b200 명령
step '3. b200 명령 설치'
[ -f bin/b200 ] || stop "bin/b200 이 없다" "$HERE 에 묶음을 다시 푼다(b200-pack.tar 에 들어 있다)."
install -m 755 bin/b200 "$S/bin/b200"
install -m 644 bin/rules.txt "$S/bin/rules.txt"
ok "$S/bin/b200 (팀원 명령),  규칙 요약 $S/bin/rules.txt"

# ------------------------------------------------------------------ 4. 접속 설정
step '4. 접속 설정 (/etc/profile.d/b200.sh)'
cat > /etc/profile.d/b200.sh <<EOF
# B200 서버 공용 설정. admin_setup.sh 가 만든다. 관리자만 고칠 수 있다.
[ -n "\${BASH_VERSION:-}" ] || return 0
case ":\$PATH:" in *":$S/bin:"*) ;; *) PATH="$S/bin:\$PATH:$S/tools/bin"; export PATH ;; esac
[ "\$(id -un)" = "$ACC" ] || return 0
[ -n "\${B200_PROFILE_DONE:-}" ] && return 0
B200_PROFILE_DONE=1
# 한글이 깨지지 않게 UTF-8 로 맞춘다(HIWARE 접속은 언어 설정이 비어 올 수 있다)
case "\$(locale charmap 2>/dev/null)" in UTF-8) ;; *) unset LC_ALL; export LANG=C.UTF-8 ;; esac
# 이름: tmux 안이면 세션 이름 앞부분(이름-작업), 아니면 접속할 때 묻는다
if [ -n "\${TMUX:-}" ]; then
    _b200_s=\$(tmux display-message -p '#S' 2>/dev/null)
    case "\$_b200_s" in *-*) B200_USER=\${_b200_s%%-*} ;; esac
fi
case \$- in *i*) ;; *) return 0 ;; esac
if [ -z "\${B200_USER:-}" ]; then
    $S/bin/b200 _hello
    for _b200_i in 1 2 3; do
        read -r -p "  이름을 입력하세요 (예: 홍길동): " B200_USER
        $S/bin/b200 _is-member "\$B200_USER" && break
        echo "  등록된 이름이 아니에요. 등록된 이름: \$($S/bin/b200 _names)"
        B200_USER=
    done
fi
export B200_USER
# 서버에는 인터넷이 없으니 Hugging Face 가 접속을 시도하지 않게 한다
export HF_HUB_OFFLINE=1 HF_DATASETS_OFFLINE=1 TRANSFORMERS_OFFLINE=1
if [ -n "\$B200_USER" ]; then
    export HISTFILE=$ST/history/\$B200_USER.bash_history HISTTIMEFORMAT='%F %T '
    export GIT_AUTHOR_NAME=\$B200_USER GIT_COMMITTER_NAME=\$B200_USER
    _b200_ps1() { case "\$PS1" in "[\$B200_USER] "*) ;; *) PS1="[\$B200_USER] \$PS1" ;; esac; }
    PROMPT_COMMAND="_b200_ps1\${PROMPT_COMMAND:+;\$PROMPT_COMMAND}"
    [ "\$PWD" = "\$HOME" ] && [ -d $W/\$B200_USER ] && cd $W/\$B200_USER
else
    echo "  [주의] 이름 없이 접속했어요. GPU를 쓰면 '누군지 모름'으로 표시돼요. 이름을 정하려면 다시 접속하세요."
fi
EOF
chmod 644 /etc/profile.d/b200.sh
# 로그인 셸이 아닌 새 셸에서도 같은 설정을 읽게 한다
grep -q '# b200 admin_setup' /etc/bash.bashrc ||
    echo '[ -r /etc/profile.d/b200.sh ] && . /etc/profile.d/b200.sh  # b200 admin_setup' >> /etc/bash.bashrc
# 예전 방식(~/.bashrc 의 PATH 줄)은 지운다. 이제 시스템 설정이 맡는다
[ -f "$HOME_A/.bashrc" ] && sed -i '\#shared/tools/bin#d' "$HOME_A/.bashrc"
ok '접속할 때 이름 묻기, 이름별 명령 기록, 작업 폴더로 이동, b200·기초 프로그램 PATH'

# ------------------------------------------------------------------ 5. GPU 서비스
step '5. GPU 서비스와 드라이버 고정'
for svc in nvidia-persistenced nvidia-fabricmanager nvlsm; do
    if systemctl list-unit-files "$svc.service" 2>/dev/null | grep -q "$svc"; then
        systemctl enable --now "$svc" >/dev/null 2>&1 && ok "$svc 켜짐(부팅 때 자동)" || warn "$svc 를 켜지 못했다: systemctl status $svc"
    else
        [ "$svc" = nvidia-persistenced ] && warn "$svc 서비스가 없다(드라이버와 함께 깔리는 서비스)"
        [ "$svc" = nvidia-fabricmanager ] && warn "$svc 가 없다. HGX B200 은 이것이 있어야 GPU를 쓴다(서버 관리 팀에 요청)"
    fi
done
mapfile -t held < <(dpkg-query -W -f='${Package} ${Status}\n' 2>/dev/null |
    awk '$NF=="installed" && $1 ~ /^(nvidia-|libnvidia-|cuda-drivers|nvlsm|libnvsdm|datacenter-gpu-manager)/ {print $1}')
if [ ${#held[@]} -gt 0 ]; then
    apt-mark hold "${held[@]}" >/dev/null && ok "드라이버 관련 패키지 ${#held[@]}개 버전 고정(apt-mark hold)"
else warn '고정할 NVIDIA 패키지를 찾지 못했다(드라이버를 패키지가 아닌 방식으로 깔았을 수 있다)'; fi

# ------------------------------------------------------------------ 6. 정기 점검
step '6. 정기 점검'
cat > /etc/cron.d/b200 <<EOF
# b200 admin_setup.sh 가 만든다
*/5 * * * * root $S/bin/b200 _log-gpu
40 7 * * *  root $S/bin/b200 _report > $ST/reports/\$(date +\%F).txt 2>&1
EOF
chmod 644 /etc/cron.d/b200
ok "5분마다 GPU 사용 기록($ST/gpu_log), 매일 07:40 점검 보고서($ST/reports)"

echo
echo "${c_g}############################ 완료 ############################${c_0}"
echo " 남은 일"
echo "  1) $S/team.txt 에 팀원 '이름 그룹' 을 적고 이 스크립트를 한 번 더 실행(작업 폴더 생성)"
echo "  2) GPU 배분이 바뀌면 $S/gpu_alloc.txt 를 고친다(엑셀과 같게)"
echo "  3) 공용 휠·데이터셋·모델 설치는 이제 root 로: bash pack_install.sh /app/shared 등"
echo "  4) 도커: bash docker_install.sh (b200-docker.tar)"
echo " 확인: 공용 계정으로 다시 접속하면 이름을 묻고 b200 현황이 나온다."
echo "${c_g}##############################################################${c_0}"
