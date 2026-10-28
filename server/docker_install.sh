#!/usr/bin/env bash
# [B200 서버 · 관리자(root) 전용] b200-docker.tar 로 공용 계정 전용 rootless Docker 를 설치한다.
#   cd /app/inbox && tar xf b200-docker.tar && bash docker_install.sh            # 공용 계정 shareduser
#   B200_ACCOUNT=다른계정 bash docker_install.sh
# 도커 데몬은 root 가 아니라 공용 계정 권한으로 돈다. 그래서 컨테이너 안에서 무엇을 해도 서버 root 권한은 얻지 못한다.
# 데몬은 root 가 관리하는 서비스(b200-docker)라 팀원이 끄거나 설정을 바꿀 수 없다.
set -uo pipefail
cd "$(dirname "$0")"
HERE=$PWD
ACC=${B200_ACCOUNT:-shareduser}
OPT=/opt/b200/docker
CONF=/etc/b200/docker
DATA=/app/docker
LOG=/var/log/b200/docker_install_$(date +%Y%m%d_%H%M%S).log
mkdir -p /var/log/b200 2>/dev/null && exec > >(tee -a "$LOG") 2>&1
T=6
c_g=$'\e[32m'; c_y=$'\e[33m'; c_r=$'\e[31m'; c_c=$'\e[36m'; c_0=$'\e[0m'
step() { echo; echo "${c_c}==== [$1/$T] $2 ====${c_0}"; }
ok()   { echo "  ${c_g}[정상]${c_0} $*"; }
warn() { echo "  ${c_y}[주의]${c_0} $*"; }
stop() {
    echo; echo "${c_r}################ 멈춤 ################${c_0}"
    echo "${c_r}무엇이: $1${c_0}"; echo "할 일 : $2"
    echo "고친 뒤 같은 명령을 다시 실행하면 된다. 기록: $LOG"
    exit 1
}
info() { sed -n "s/^$1=//p" docker_info.txt; }

echo "[B200 서버] rootless Docker 설치  ($(date '+%Y-%m-%d %H:%M'), 공용 계정 $ACC)"

# ------------------------------------------------------------------ 1. 점검
step 1 '점검'
[ "$(id -u)" = 0 ] || stop 'root 가 아니다' '관리자(root) 계정으로 접속해 다시 실행한다.'
id "$ACC" >/dev/null 2>&1 || stop "공용 계정 $ACC 가 없다" "계정 이름이 다르면 B200_ACCOUNT=계정 bash docker_install.sh 로 실행한다."
UID_A=$(id -u "$ACC")
for f in MANIFEST.sha256 docker_info.txt; do [ -f "$f" ] || stop "$f 가 없다" "$HERE 에서 tar xf b200-docker.tar 를 했는지 본다."; done
bad=$(grep -v '  docker_install\.sh$' MANIFEST.sha256 | sha256sum -c --quiet - 2>/dev/null | sed 's/: .*//')
[ -z "$bad" ] || { echo "$bad" | sed 's/^/    깨짐: /'; stop '올리는 중에 파일이 깨졌다' '접근 PC의 pack_docker\b200-docker.tar 를 다시 올린다.'; }
ok "파일 체크섬 일치 (Docker $(info docker), NVIDIA Container Toolkit $(info nvidia_toolkit))"
CODE=$(. /etc/os-release && echo "${VERSION_CODENAME:-}")
ok "운영체제 $(. /etc/os-release && echo "$PRETTY_NAME"), 커널 $(uname -r)"
id -nG "$ACC" | tr ' ' '\n' | grep -qx docker && warn "$ACC 가 docker 그룹에 있다. root 권한과 같으니 admin_setup.sh 가 뺀다."
command -v nvidia-smi >/dev/null && nvidia-smi -L >/dev/null 2>&1 && ok "GPU $(nvidia-smi -L | wc -l)장 보임" ||
    warn 'nvidia-smi 가 GPU를 못 본다. 도커는 설치하지만 GPU 컨테이너는 드라이버를 고친 뒤에 된다.'
[ -d /app ] || stop '/app 이 없다' '2 TB SSD 를 /app 에 연결한 뒤 다시 실행한다.'

# ------------------------------------------------------------------ 2. 시스템 패키지
step 2 'rootless 에 필요한 시스템 패키지'
need_debs=()
if [ -d "debs/$CODE" ]; then
    for deb in "debs/$CODE"/*.deb; do
        pkg=$(dpkg-deb -f "$deb" Package)
        if dpkg -s "$pkg" >/dev/null 2>&1; then ok "$pkg 이미 있음"; else need_debs+=("$deb"); fi
    done
else
    warn "Ubuntu $CODE 용 패키지는 묶음에 없다(22.04 jammy, 24.04 noble 만 넣었다). 이미 있는지만 본다."
fi
if [ ${#need_debs[@]} -gt 0 ]; then
    dpkg -i "${need_debs[@]}" || stop '시스템 패키지 설치 실패' '위 dpkg 오류를 본다. 빠진 의존 패키지가 있으면 서버 관리 팀에 요청한다.'
    ok "설치함: $(printf '%s ' "${need_debs[@]##*/}")"
fi
command -v newuidmap >/dev/null || stop 'newuidmap 이 없다(uidmap 패키지)' '서버 관리 팀에 uidmap 설치를 요청한다.'
command -v slirp4netns >/dev/null || command -v pasta >/dev/null || stop 'slirp4netns 와 pasta 가 모두 없다' '서버 관리 팀에 slirp4netns 설치를 요청한다.'
NET=slirp4netns; command -v slirp4netns >/dev/null || NET=pasta
ok "uidmap, 컨테이너 네트워크($NET) 준비됨"

nv_have=$(dpkg-query -W -f='${Version}' nvidia-container-toolkit 2>/dev/null || true)
if [ "$nv_have" = "$(info nvidia_toolkit)" ]; then ok "NVIDIA Container Toolkit $nv_have 이미 있음"
else
    dpkg -i debs/nvidia/*.deb || stop 'NVIDIA Container Toolkit 설치 실패' '위 dpkg 오류를 본다.'
    ok "NVIDIA Container Toolkit $(info nvidia_toolkit) 설치함"
fi
# rootless 에서는 cgroup 을 직접 못 만지므로 GPU 연결 도구가 cgroup 을 건드리지 않게 한다
nvidia-ctk config --set nvidia-container-cli.no-cgroups --in-place >/dev/null 2>&1 &&
    ok 'GPU 연결 도구를 rootless 모드로 설정' || warn 'nvidia-ctk 설정 실패. /etc/nvidia-container-runtime/config.toml 에서 no-cgroups = true 로 바꾼다.'

# ------------------------------------------------------------------ 3. Docker 프로그램
step 3 "Docker $(info docker) 설치 → $OPT"
V=$(info docker)
if [ ! -x "$OPT/$V/dockerd" ]; then
    rm -rf "$OPT/$V.tmp" && mkdir -p "$OPT/$V.tmp"
    tar xzf "docker-$V.tgz" -C "$OPT/$V.tmp" --strip-components=1 &&
        tar xzf "docker-rootless-extras-$V.tgz" -C "$OPT/$V.tmp" --strip-components=1 ||
        stop 'Docker 압축 풀기 실패' '남은 공간을 본다.'
    mv "$OPT/$V.tmp" "$OPT/$V"
fi
ln -sfn "$OPT/$V" "$OPT/current"
mkdir -p /usr/local/lib/docker/cli-plugins
for p in docker-buildx docker-compose; do
    [ -f "plugins/$p" ] && install -m 755 "plugins/$p" /usr/local/lib/docker/cli-plugins/$p && ok "$p 설치함"
done
ok "docker $("$OPT/current/docker" --version | sed 's/Docker version //')"

# ------------------------------------------------------------------ 4. 공용 계정 설정
step 4 "공용 계정 $ACC 설정"
# 컨테이너 안의 사용자 번호를 서버의 다른 번호로 옮기는 범위(rootless 의 핵심)
for f in /etc/subuid /etc/subgid; do
    touch "$f"
    if ! grep -q "^$ACC:" "$f"; then
        start=$(awk -F: '{e=$2+$3; if (e>m) m=e} END {print (m>100000 ? m : 100000)}' "$f")
        echo "$ACC:$start:65536" >> "$f"
        ok "$f 에 $ACC:$start:65536 추가"
    else ok "$f 에 $ACC 범위 있음"; fi
done
loginctl enable-linger "$ACC" && ok '로그인하지 않아도 도커가 돌게 함(linger)'
# Ubuntu 24.04 는 일반 사용자의 이름공간 만들기를 AppArmor 로 막는다. rootlesskit 만 풀어 준다
if [ "$(cat /proc/sys/kernel/apparmor_restrict_unprivileged_userns 2>/dev/null)" = 1 ]; then
    cat > /etc/apparmor.d/b200-rootlesskit <<EOF
abi <abi/4.0>,
include <tunables/global>

"$OPT/*/rootlesskit" flags=(unconfined) {
  userns,
  include if exists <local/b200-rootlesskit>
}
EOF
    apparmor_parser -r /etc/apparmor.d/b200-rootlesskit && ok 'AppArmor: rootlesskit 허용' ||
        stop 'AppArmor 프로필 적용 실패' '위 오류를 본다.'
fi
[ "$(stat -c %U /app)" = root ] && [ ! -L "$DATA" ] || stop '/app 이 잠기지 않았거나 /app/docker 가 링크다' '먼저 bash admin_setup.sh 를 실행한다.'
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
ok "이미지·컨테이너 저장 위치 $DATA, 설정 $CONF/daemon.json (root 만 고칠 수 있음)"

cat > /etc/systemd/system/b200-docker.service <<EOF
[Unit]
Description=B200 rootless Docker ($ACC)
After=network.target user@$UID_A.service
Requires=user@$UID_A.service

[Service]
User=$ACC
Environment=XDG_RUNTIME_DIR=/run/user/$UID_A
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
# 팀원 셸에서 docker 명령이 이 데몬을 쓰게 한다
cat > /etc/profile.d/b200-docker.sh <<EOF
# b200 docker_install.sh 가 만든 파일
# 뒤에 붙인다. 앞에는 /app/shared/bin/docker(이름표를 붙이고 GPU 겹침을 경고하는 docker)가 온다
case ":\$PATH:" in *":$OPT/current:"*) ;; *) PATH="\$PATH:$OPT/current" ;; esac
if [ "\$(id -un)" = "$ACC" ]; then export DOCKER_HOST=unix:///run/user/$UID_A/docker.sock; fi
EOF
ok 'b200-docker 서비스와 /etc/profile.d/b200-docker.sh 만듦'

# ------------------------------------------------------------------ 5. 켜기
step 5 '켜기'
systemctl daemon-reload
systemctl enable b200-docker >/dev/null 2>&1
systemctl restart b200-docker
for i in $(seq 1 30); do [ -S "/run/user/$UID_A/docker.sock" ] && break; sleep 1; done
[ -S "/run/user/$UID_A/docker.sock" ] || {
    journalctl -u b200-docker -n 30 --no-pager | sed 's/^/    /'
    stop '도커 데몬이 켜지지 않았다' '위 기록을 본다. 모르겠으면 기록 파일을 담당자에게 보낸다.'
}
ok 'b200-docker 실행 중'

# ------------------------------------------------------------------ 6. 검사
step 6 '검사 (공용 계정으로)'
as_acc() { runuser -u "$ACC" -- env DOCKER_HOST="unix:///run/user/$UID_A/docker.sock" PATH="$OPT/current:/usr/bin:/bin" "$@"; }
as_acc docker info --format '{{.SecurityOptions}} {{.DockerRootDir}}' | grep -q rootless &&
    ok "rootless 로 동작, 저장 위치 $(as_acc docker info --format '{{.DockerRootDir}}')" ||
    stop 'rootless 로 동작하지 않는다' 'docker info 결과를 본다.'
as_acc docker info --format '{{json .Runtimes}}' | grep -q nvidia && ok 'GPU 런타임(nvidia) 등록됨' || warn 'GPU 런타임이 보이지 않는다'
echo "  GPU 컨테이너 실행은 이미지를 처음 들여온 뒤 확인한다: b200 doctor <이미지>"

echo
echo "${c_g}############################ 완료 ############################${c_0}"
echo " 공용 계정 $ACC 전용 rootless Docker $(info docker)"
echo " 팀원은 다시 접속하면 docker 명령을 바로 쓴다. GPU는 --gpus 로 정한 것만 보인다."
echo " 관리: systemctl status|restart b200-docker,  기록: journalctl -u b200-docker"
echo " 정리: rm -rf $HERE/*"
echo "${c_g}##############################################################${c_0}"
