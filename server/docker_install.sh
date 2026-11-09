#!/usr/bin/env bash
# [GPU 서버 · 관리자(root) 전용] gpu-docker.tar 로 공용 계정 전용 rootless Docker 를 설치한다.
#   cd /app/inbox && tar xf gpu-docker.tar && bash docker_install.sh            # 공용 계정은 /etc/gpu/account
# 도커 데몬은 root 가 아니라 공용 계정 권한으로 돈다. 그래서 컨테이너 안에서 무엇을 해도 서버 root 권한은 얻지 못한다.
# 데몬은 root 가 관리하는 서비스(gpu-docker)라 팀원이 끄거나 설정을 바꿀 수 없다.
set -uo pipefail
cd "$(dirname "$0")"
HERE=$PWD
ACC=${GPU_ACCOUNT:-$(cat /etc/gpu/account 2>/dev/null)}   # 공용 계정 이름은 서버의 /etc/gpu/account 한 곳에 적는다
OPT=/opt/gpu/docker
CONF=/etc/gpu/docker
DATA=/app/docker
LOG=/var/log/gpu/docker_install_$(date +%Y%m%d_%H%M%S).log
mkdir -p /var/log/gpu 2>/dev/null && exec > >(tee -a "$LOG") 2>&1
T=6
c_g=$'\e[32m'; c_y=$'\e[33m'; c_r=$'\e[31m'; c_c=$'\e[36m'; c_0=$'\e[0m'
step() { echo; echo "${c_c}==== [$1/$T] $2 ====${c_0}"; }
ok()   { echo "  ${c_g}[정상]${c_0} $*"; }
warn() { echo "  ${c_y}[주의]${c_0} $*"; }
stop() {
    echo; echo "${c_r}################ 멈춤 ################${c_0}"
    echo "${c_r}멈춘 이유: $1${c_0}"; echo "할 일: $2"
    echo "고친 뒤 같은 명령을 다시 실행하세요: cd $HERE && bash docker_install.sh"; echo "기록 파일: $LOG  (해결이 안 되면 docs/7_문제_해결.md)"
    exit 1
}
info() { sed -n "s/^$1=//p" docker_info.txt; }

echo "[GPU 서버] rootless Docker(root 권한 없이 도는 도커) 설치  ($(date '+%Y-%m-%d %H:%M'), 공용 계정 $ACC)"

# ------------------------------------------------------------------ 1. 점검
step 1 '점검'
[ "$(id -u)" = 0 ] || stop 'root 계정이 아니에요' 'HIWARE에서 root로 접속해(PuTTY) 다시 실행하세요.'
[ -n "$ACC" ] || stop '공용 계정 이름을 알 수 없어요' '서버에 한 번 적어 두세요: mkdir -p /etc/gpu && echo <계정이름> > /etc/gpu/account'
id "$ACC" >/dev/null 2>&1 || stop "공용 계정을 찾지 못했어요: $ACC" "/etc/gpu/account 의 계정 이름을 확인하세요: cat /etc/gpu/account"
UID_A=$(id -u "$ACC")
for f in MANIFEST_docker.sha256 docker_info.txt; do [ -f "$f" ] || stop "묶음 안의 파일이 없어요: $f" "묶음을 풀었는지 확인하세요: cd $HERE && tar xf gpu-docker.tar"; done
# 목록이 비었거나 모양이 다른 줄이 있으면 sha256sum 은 그 줄을 건너뛰고 "맞음"이 될 수 있어 따로 본다
[ "$(grep -c . MANIFEST_docker.sha256)" -gt 0 ] && ! grep -v '^$' MANIFEST_docker.sha256 | grep -qvE '^[0-9a-f]{64}  [^/].*$' ||
    stop "체크섬 목록(MANIFEST_docker.sha256)이 비었거나 모양이 이상해요" "접근 PC에서 docker_pack.ps1 을 다시 실행해 새 묶음을 올리세요."
bad=$(grep -v '  docker_install\.sh$' MANIFEST_docker.sha256 | sha256sum -c --quiet --strict - 2>/dev/null | sed 's/: .*//'); rc=$?
[ "$rc" = 0 ] || [ -n "$bad" ] || stop '체크섬을 확인하지 못했어요' "묶음을 NAS 의 /data/autonomy_sw/inbox 에 다시 올려 새로 들여온 뒤 다시 실행하세요. 기록 파일: $LOG"
[ -z "$bad" ] || { echo "$bad" | sed 's/^/    깨진 파일: /'; stop '올리는 중에 파일이 깨졌어요' '접근 PC의 pack_docker\gpu-docker.tar 를 NAS 의 /data/autonomy_sw/inbox 에 다시 올리고, /app/inbox 로 새로 복사해 지문을 확인한 뒤 다시 푸세요.'; }
ok "파일 체크섬이 맞아요 (Docker $(info docker), NVIDIA Container Toolkit $(info nvidia_toolkit))"
CODE=$(. /etc/os-release && echo "${VERSION_CODENAME:-}")
ok "운영체제 $(. /etc/os-release && echo "$PRETTY_NAME"), 커널 $(uname -r)"
id -nG "$ACC" | tr ' ' '\n' | grep -qx docker && warn "공용 계정($ACC)이 docker 그룹에 있어요. root 권한과 같으니 서버 관리 팀에 빼 달라고 하세요(gpasswd -d $ACC docker)"
command -v nvidia-smi >/dev/null && nvidia-smi -L >/dev/null 2>&1 && ok "GPU $(nvidia-smi -L | wc -l)장이 보여요" ||
    warn 'nvidia-smi가 GPU를 못 봐요. 도커는 설치하지만, GPU 컨테이너는 드라이버를 고친 뒤에 돼요(QUICK=1 bash /app/inbox/check.sh 로 확인).'
[ -d /app ] || stop '/app 폴더가 없어요' '서버 관리 팀에 2 TB SSD를 /app에 연결해 달라고 요청한 뒤 다시 실행하세요.'

# ------------------------------------------------------------------ 2. 시스템 패키지
step 2 'rootless 도커에 필요한 시스템 패키지'
need_debs=()
if [ -d "debs/$CODE" ]; then
    for deb in "debs/$CODE"/*.deb; do
        pkg=$(dpkg-deb -f "$deb" Package)
        if dpkg -s "$pkg" >/dev/null 2>&1; then ok "$pkg 이미 있어요"; else need_debs+=("$deb"); fi
    done
else
    warn "Ubuntu $CODE 용 패키지는 묶음에 없어요(22.04 jammy, 24.04 noble만 넣었어요). 서버에 이미 있는지만 확인해요."
fi
if [ ${#need_debs[@]} -gt 0 ]; then
    dpkg -i "${need_debs[@]}" || stop '시스템 패키지를 설치하지 못했어요' '바로 위 dpkg 오류를 확인하세요. 빠진 의존 패키지가 있으면 서버 관리 팀에 설치를 요청하세요.'
    ok "설치했어요: $(printf '%s ' "${need_debs[@]##*/}")"
fi
command -v newuidmap >/dev/null || stop 'newuidmap 명령이 없어요(uidmap 패키지)' '서버 관리 팀에 uidmap 패키지 설치를 요청하세요.'
command -v slirp4netns >/dev/null || command -v pasta >/dev/null || stop 'slirp4netns, pasta가 둘 다 없어요' '서버 관리 팀에 slirp4netns 패키지 설치를 요청하세요.'
NET=slirp4netns; command -v slirp4netns >/dev/null || NET=pasta
ok "uidmap, 컨테이너 네트워크($NET) 준비됐어요"

nv_have=$(dpkg-query -W -f='${Version}' nvidia-container-toolkit 2>/dev/null || true)
# 이미 설치돼 있으면 버전이 달라도 그대로 쓴다(다른 팀이 같이 쓰는 서버에서 남의 도커 GPU 설정을 바꾸지 않게)
if [ -n "$nv_have" ]; then ok "NVIDIA Container Toolkit $nv_have 이미 있어요(그대로 써요)"
else
    dpkg -i debs/nvidia/*.deb || stop 'NVIDIA Container Toolkit을 설치하지 못했어요' '바로 위 dpkg 오류를 확인하세요.'
    ok "NVIDIA Container Toolkit $(info nvidia_toolkit) 설치했어요"
fi
# rootless 에서는 cgroup 을 직접 못 만지므로 GPU 연결 도구가 cgroup 을 건드리지 않게 한다.
# 서버 전체 설정(/etc/nvidia-container-runtime)은 그대로 두고, 우리 도커만 읽는 설정 파일을 따로 둔다(서비스의 XDG_CONFIG_HOME)
mkdir -p "$CONF/nvidia-container-runtime"
[ -f /etc/nvidia-container-runtime/config.toml ] && cp /etc/nvidia-container-runtime/config.toml "$CONF/nvidia-container-runtime/config.toml"
nvidia-ctk config --set nvidia-container-cli.no-cgroups --in-place --config "$CONF/nvidia-container-runtime/config.toml" >/dev/null 2>&1 &&
    ok "GPU 연결 도구를 rootless 모드로 설정했어요(설정 위치 $CONF/nvidia-container-runtime, 서버 전체 설정은 그대로 둬요)" ||
    warn "nvidia-ctk 설정에 실패했어요. $CONF/nvidia-container-runtime/config.toml 의 [nvidia-container-cli] 아래에 no-cgroups = true 를 직접 적으세요."

# ------------------------------------------------------------------ 3. Docker 프로그램
step 3 "Docker $(info docker) 설치 → $OPT"
V=$(info docker)
if [ ! -x "$OPT/$V/dockerd" ]; then
    rm -rf "$OPT/$V.tmp" && mkdir -p "$OPT/$V.tmp"
    tar xzf "docker-$V.tgz" -C "$OPT/$V.tmp" --strip-components=1 &&
        tar xzf "docker-rootless-extras-$V.tgz" -C "$OPT/$V.tmp" --strip-components=1 ||
        stop 'Docker 압축을 풀지 못했어요' '남은 공간을 확인하세요: df -h /opt'
    mv "$OPT/$V.tmp" "$OPT/$V"
fi
ln -sfn "$OPT/$V" "$OPT/current"
# buildx·compose 는 우리 도커 폴더에 둔다. /usr/local/lib/docker/cli-plugins 에 두면 다른 계정의 docker 도 이것을 쓰게 된다
mkdir -p "$OPT/cli-plugins"
for p in docker-buildx docker-compose; do
    [ -f "plugins/$p" ] && install -m 755 "plugins/$p" "$OPT/cli-plugins/$p" && ok "설치했어요: $p"
done
setsid -w runuser -u "$ACC" -- mkdir -p "$(getent passwd "$ACC" | cut -d: -f6)/.docker"
setsid -w runuser -u "$ACC" -- python3 -I - "$(getent passwd "$ACC" | cut -d: -f6)/.docker/config.json" "$OPT/cli-plugins" <<'PY'
import json, sys
p, d = sys.argv[1], sys.argv[2]
try: c = json.load(open(p))
except Exception: c = {}
c["cliPluginsExtraDirs"] = [d]
json.dump(c, open(p, "w"), indent=2)
PY
ok "docker $("$OPT/current/docker" --version | sed 's/Docker version //')"

# ------------------------------------------------------------------ 4. 공용 계정 설정
step 4 "공용 계정 $ACC 설정"
# 컨테이너 안의 사용자 번호를 서버의 다른 번호로 옮기는 범위(rootless 의 핵심)
for f in /etc/subuid /etc/subgid; do
    touch "$f"
    if ! grep -q "^$ACC:" "$f"; then
        start=$(awk -F: '{e=$2+$3; if (e>m) m=e} END {print (m>100000 ? m : 100000)}' "$f")
        echo "$ACC:$start:65536" >> "$f"
        ok "$f 에 $ACC:$start:65536 을 추가했어요"
    else ok "$f 에 공용 계정 범위가 이미 있어요"; fi
done
loginctl enable-linger "$ACC" && ok '공용 계정이 로그인하지 않아도 도커가 돌게 했어요(linger)'
# Ubuntu 24.04 는 일반 사용자의 이름공간 만들기를 AppArmor 로 막는다. rootlesskit 만 풀어 준다
if [ "$(cat /proc/sys/kernel/apparmor_restrict_unprivileged_userns 2>/dev/null)" = 1 ]; then
    cat > /etc/apparmor.d/gpu-rootlesskit <<EOF
abi <abi/4.0>,
include <tunables/global>

"$OPT/*/rootlesskit" flags=(unconfined) {
  userns,
  include if exists <local/gpu-rootlesskit>
}
EOF
    apparmor_parser -r /etc/apparmor.d/gpu-rootlesskit && ok 'AppArmor에서 rootlesskit을 허용했어요' ||
        stop 'AppArmor 프로필을 적용하지 못했어요' '바로 위 오류를 확인하세요.'
fi
[ "$(stat -c %U /app)" = root ] && [ ! -L "$DATA" ] || stop '/app이 잠기지 않았거나 /app/docker가 링크예요' '준비를 먼저 하세요: cd /app/inbox && bash prepare.sh'
mkdir -p "$DATA" && chown "$ACC:$ACC" "$DATA" && chmod 700 "$DATA"
mkdir -p "$CONF"
# 기본 런타임은 runc 그대로 둔다. nvidia 를 기본으로 하면 --gpus 없이 띄운 CUDA 이미지에도 GPU 8장이 모두 보인다
cat > "$CONF/daemon.json" <<EOF
{
  "data-root": "$DATA",
  "runtimes": { "nvidia": { "path": "nvidia-container-runtime", "args": [] } },
  "log-opts": { "max-size": "50m", "max-file": "3" }
}
EOF
chmod 644 "$CONF/daemon.json"
ok "이미지·컨테이너 저장 위치 $DATA, 설정 $CONF/daemon.json (설정은 root만 고칠 수 있어요)"

cat > /etc/systemd/system/gpu-docker.service <<EOF
[Unit]
Description=GPU 서버 rootless Docker ($ACC)
After=network.target user@$UID_A.service
Requires=user@$UID_A.service

[Service]
User=$ACC
Environment=XDG_RUNTIME_DIR=/run/user/$UID_A
Environment=XDG_CONFIG_HOME=$CONF
Environment=PATH=$OPT/current:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
Environment=DOCKERD_ROOTLESS_ROOTLESSKIT_NET=$NET
Environment=DOCKERD_ROOTLESS_ROOTLESSKIT_PORT_DRIVER=builtin
ExecStart=$OPT/current/dockerd-rootless.sh --config-file $CONF/daemon.json
Restart=always
RestartSec=5
LimitNOFILE=infinity
LimitNPROC=infinity
TasksMax=infinity
Delegate=yes
KillMode=mixed

[Install]
WantedBy=multi-user.target
EOF
# 팀원 셸에서 docker 명령이 이 데몬을 쓰게 한다. 우리 공용 계정에만 건다(다른 계정의 docker 는 그대로)
cat > /etc/profile.d/gpu-docker.sh <<EOF
# gpu docker_install.sh 가 만든 파일
# 뒤에 붙인다. 앞에는 /app/admin/bin/docker(이름표를 붙이고 GPU 겹침을 경고하는 docker)가 온다
if [ "\$(id -un)" = "$ACC" ]; then
    case ":\$PATH:" in *":$OPT/current:"*) ;; *) PATH="\$PATH:$OPT/current" ;; esac
    export DOCKER_HOST=unix:///run/user/$UID_A/docker.sock
fi
EOF
ok 'gpu-docker 서비스와 /etc/profile.d/gpu-docker.sh 를 만들었어요'

# ------------------------------------------------------------------ 5. 켜기
step 5 '켜기'
systemctl daemon-reload
systemctl enable gpu-docker >/dev/null 2>&1
# 이미 돌고 있으면 다시 켤 때 팀원 컨테이너(학습)가 모두 멈춘다. 몇 개인지 보여 주고 한 번 묻는다
if systemctl is-active -q gpu-docker; then
    nrun=$(setsid -w runuser -u "$ACC" -- env DOCKER_HOST="unix:///run/user/$UID_A/docker.sock" DOCKER_CONFIG=/etc/gpu/docker/cli "$OPT/current/docker" ps -q </dev/null 2>/dev/null | grep -c .)
    if [ "${nrun:-0}" -gt 0 ]; then
        warn "도커를 다시 켜면 돌고 있는 컨테이너 ${nrun}개(팀원 학습)가 모두 멈춰요. 팀에 미리 알리세요"
        if [ -t 0 ]; then read -r -p "  지금 다시 켤까요? [y/N] " a; [[ "$a" =~ ^[yY] ]] || stop '도커 다시 켜기를 미뤘어요' '팀원이 쓰지 않을 때 같은 명령을 다시 실행하세요. 설치한 버전은 다시 켤 때 적용돼요.'
        else stop '돌고 있는 컨테이너가 있어요' 'PuTTY 화면에서 직접 실행해 확인 질문에 답하세요.'; fi
    fi
fi
systemctl restart gpu-docker
for i in $(seq 1 30); do [ -S "/run/user/$UID_A/docker.sock" ] && break; sleep 1; done
[ -S "/run/user/$UID_A/docker.sock" ] || {
    journalctl -u gpu-docker -n 30 --no-pager | sed 's/^/    /'
    stop '도커 데몬이 켜지지 않았어요' '바로 위 서비스 기록을 확인하세요. 더 보려면: journalctl -u gpu-docker -n 100'
}
ok 'gpu-docker 서비스가 돌고 있어요'

# ------------------------------------------------------------------ 6. 검사
step 6 '검사 (공용 계정으로)'
# 터미널을 떼고(setsid), 공용 계정이 고칠 수 있는 ~/.docker 설정(플러그인 등)은 읽지 않는다
as_acc() { setsid -w runuser -u "$ACC" -- env DOCKER_HOST="unix:///run/user/$UID_A/docker.sock" DOCKER_CONFIG=/etc/gpu/docker/cli PATH="$OPT/current:/usr/bin:/bin" "$@" </dev/null; }
as_acc docker info --format '{{.SecurityOptions}} {{.DockerRootDir}}' | grep -q rootless &&
    ok "rootless로 동작해요. 저장 위치 $(as_acc docker info --format '{{.DockerRootDir}}')" ||
    stop 'rootless로 동작하지 않아요' "공용 계정 도커 정보를 확인하세요: /app/admin/bin/gpu docker info"
as_acc docker info --format '{{json .Runtimes}}' | grep -q nvidia && ok 'GPU 런타임(nvidia)이 등록됐어요' || warn "GPU 런타임(nvidia)이 보이지 않아요. $CONF/daemon.json 의 runtimes 항목과 nvidia-container-runtime 설치를 확인하세요"
echo "  GPU 컨테이너는 PyTorch 이미지를 처음 들여온 뒤 공용 계정으로 확인해요: gpu doctor <이미지>"

echo
echo "${c_g}############################ 완료 ############################${c_0}"
echo " 공용 계정($ACC) 전용 rootless Docker $(info docker)를 설치했어요."
echo " 팀원은 다시 접속하면 docker 명령을 바로 써요. 컨테이너에는 --gpus 로 정한 GPU만 보여요."
echo " 관리: systemctl status gpu-docker (다시 켜기: systemctl restart gpu-docker),  기록: journalctl -u gpu-docker"
echo " 다음 단계: 데이터셋·모델(docs/1_처음_설치.md 4·5단계, 두 서버 중 한 곳에서 한 번만). 그 서버가 아니면 6단계 권한·규칙 설정(bash /app/inbox/admin_setup.sh)"
echo " 공간 정리: NAS 의 /data/autonomy_sw/inbox 에 올린 gpu-docker.tar 는 두 서버에서 모두 설치한 뒤 지워요(다른 서버도 거기서 가져가요)"
echo "${c_g}##############################################################${c_0}"
