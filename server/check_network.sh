#!/usr/bin/env bash
# [GPU 서버] 네트워크와 NAS를 점검해요. 설정은 아무것도 바꾸지 않아요.
#   bash check_network.sh all               ★ 전체 점검: 두 서버에서 각각 실행하면 NAS로 서로를 찾아
#                                           서버 사이(이더넷·InfiniBand·RDMA), 로컬 SSD, NAS 속도를 모두 측정하고 보고서를 남겨요(root 권장)
#   bash check_network.sh                   이 서버의 네트워크 카드·속도, NAS 연결 보기
#   bash check_network.sh <다른 서버 IP>     + 다른 서버와 연결되는지, 어느 카드로 가는지
#   bash check_network.sh listen            서버 사이 속도 측정: 받는 쪽(먼저 실행, 2분 기다려요)
#   bash check_network.sh send <받는 쪽 IP>  서버 사이 속도 측정: 보내는 쪽(10초)
#   bash check_network.sh disk <폴더>        그 폴더(NAS나 /app)의 쓰기·읽기 속도(시험 파일 4 GB를 쓰고 지워요)
#   JOBS=8 bash check_network.sh disk <폴더> 파일 8개를 동시에(여럿이 함께 쓸 때의 전체 속도)
# 숫자는 GB/s(초당 기가바이트)와 Gbps(초당 기가비트, 카드 속도 단위)를 같이 보여 줘요. 1 GB/s = 8 Gbps.
set -uo pipefail
c_g=$'\e[32m'; c_y=$'\e[33m'; c_r=$'\e[31m'; c_c=$'\e[36m'; c_0=$'\e[0m'
ok()   { echo "  ${c_g}[정상]${c_0} $*"; }
warn() { echo "  ${c_y}[주의]${c_0} $*"; }
bad()  { echo "  ${c_r}[문제]${c_0} $*"; }
head_() { echo; echo "${c_c}== $* ==${c_0}"; }
PORT=${PORT:-5201}
STREAMS=${STREAMS:-8}
SECS=${SECS:-10}

pad() { local w; w=$(printf '%s' "$1" | LC_ALL=C.UTF-8 wc -L); printf '%s%*s' "$1" $(( $2 > w ? $2 - w : 0 )) ''; }
# 카드 하나: 이름 종류 상태 속도(Mb/s) MTU 주소
nic_line() {
    local n=$1 d=/sys/class/net/$1 type kind speed state mtu addr
    type=$(cat "$d/type" 2>/dev/null); state=$(cat "$d/operstate" 2>/dev/null)
    speed=$(cat "$d/speed" 2>/dev/null); [ "${speed:--1}" -gt 0 ] 2>/dev/null || speed=
    mtu=$(cat "$d/mtu" 2>/dev/null)
    case "$type" in 32) kind=InfiniBand ;; 1) kind=이더넷 ;; *) kind="종류$type" ;; esac
    [ -d "$d/device" ] || kind="$kind(가상)"
    addr=$(ip -4 -br addr show "$n" 2>/dev/null | awk '{print $3}')
    echo "  $(pad "$n" 16)$(pad "$kind" 16)$(pad "$state" 8)$(pad "${speed:+$((speed / 1000)) Gbps}" 11)$(pad "$mtu" 7)${addr:--}"
    # 묶은 카드(bond): 어떤 카드를 묶었는지와 나눠 보내는 방식(모드마다 한 연결이 낼 수 있는 속도가 다르다)
    if [ -d "$d/bonding" ]; then
        local bmode; bmode=$(cut -d' ' -f1 "$d/bonding/mode" 2>/dev/null)
        case "$bmode" in
        balance-rr)
            echo "      = $(cat "$d/bonding/slaves" 2>/dev/null | sed 's/ / + /g'),  모드 balance-rr(패킷을 카드마다 번갈아 보내요)"
            echo "        한 연결도 두 카드를 같이 쓰지만, 패킷 순서가 뒤섞여 보통 카드 하나 속도 안팎이에요. 여러 연결을 동시에 하면 합친 속도가 나와요" ;;
        active-backup)
            echo "      = $(cat "$d/bonding/slaves" 2>/dev/null | sed 's/ / + /g'),  모드 active-backup"
            echo "        한 번에 카드 하나만 써요(나머지는 고장 대비 예비). 여러 연결을 해도 카드 하나 속도예요" ;;
        *)
            echo "      = $(cat "$d/bonding/slaves" 2>/dev/null | sed 's/ / + /g'),  모드 $bmode, 연결 분배 방식 $(cut -d' ' -f1 "$d/bonding/xmit_hash_policy" 2>/dev/null)"
            echo "        한 연결(scp 하나 등)은 카드 하나 속도까지만 나와요. 여러 연결을 동시에 해야 합친 속도가 나와요" ;;
        esac
    fi
}
# IP 로 가는 카드와 그 카드의 속도
route_to() {
    local ip=$1 dev speed
    dev=$(ip route get "$ip" 2>/dev/null | grep -oP 'dev \K\S+' | head -1)
    [ -n "$dev" ] || { echo "-"; return; }
    speed=$(cat "/sys/class/net/$dev/speed" 2>/dev/null)
    [ "${speed:--1}" -gt 0 ] 2>/dev/null && echo "$dev ($((speed / 1000)) Gbps)" || echo "$dev (속도 모름)"
}
rate() {   # 바이트 초 → "x.xx GB/s (y Gbps)"
    awk -v b="$1" -v s="$2" 'BEGIN {g=b/s/1e9; printf "%.2f GB/s (%.1f Gbps)", g, g*8}'
}

cmd_info() {
    [ -n "${ALL_MODE:-}" ] || echo "${c_c}[GPU 서버] 네트워크 점검  ($(date '+%Y-%m-%d %H:%M'), $(hostname), $(id -un))${c_0}"
    head_ '네트워크 카드'
    command -v ip >/dev/null || warn 'ip 명령(iproute2)이 없어 주소와 경로를 못 봐요'
    echo "  $(pad 이름 16)$(pad 종류 16)$(pad 상태 8)$(pad 속도 11)$(pad MTU 7)IPv4"
    for d in /sys/class/net/*; do
        [ -d "$d" ] || continue   # bonding_masters 같은 파일은 뺀다
        n=$(basename "$d")
        case "$n" in lo|docker*|veth*|br-*|ifb*|virbr*|cni*|flannel*|tap*|tun*) continue ;; esac   # 컨테이너·가상 카드는 뺀다
        nic_line "$n"
    done
    echo "  기본 경로: $(ip route show default 2>/dev/null | head -1)"
    if [ -d /sys/class/infiniband ]; then
        head_ 'InfiniBand·RoCE (GPU 서버끼리 빠르게 주고받는 카드)'
        for p in /sys/class/infiniband/*/ports/*; do
            [ -e "$p/rate" ] || continue
            local hca nd ndip
            hca=$(basename "$(dirname "$(dirname "$p")")")
            nd=$(ls "/sys/class/infiniband/$hca/device/net" 2>/dev/null | head -1)
            ndip=$(ip -4 -br addr show "$nd" 2>/dev/null | awk '{print $3}')
            echo "  $(pad "$hca" 10)포트 $(basename "$p")  $(pad "$(cut -d: -f2 "$p/state" | tr -d ' ')" 8)$(pad "$(cat "$p/rate")" 22)$(pad "${nd:--}" 13)${ndip:-IP 없음}"
        done
        echo "  IP가 있는 포트는 NAS·IP 통신용이고, IP가 없는 포트는 보통 GPU 서버끼리 RDMA(NCCL)로만 쓰는 포트예요."
        echo "  다른 서버와 같은 InfiniBand 망인지는 root로 iblinkinfo나 ibnetdiscover를 실행하면 보여요(다른 서버 이름이 나오면 같은 망이에요)."
    fi

    head_ 'NAS (네트워크 저장소)'
    local m found=
    while read -r tgt src fs opts; do
        found=1
        local host=${src%%:*}; host=${host#//}; host=${host%%/*}
        local ip; ip=$(getent ahostsv4 "$host" 2>/dev/null | awk 'NR==1 {print $1}'); ip=${ip:-$host}
        echo "  $tgt  ←  $src  ($fs)"
        echo "      쓰는 네트워크 카드: $(route_to "$ip")"
        echo "      옵션: $(echo "$opts" | tr ',' '\n' | grep -E '^(vers|proto|rsize|wsize|nconnect|hard|soft)=?' | tr '\n' ' ')"
        echo "$opts" | grep -q 'proto=rdma' && ok 'RDMA로 연결돼 있어요(빠른 방식)'
    done < <(findmnt -rn -t nfs,nfs4,cifs,smb3,lustre,gpfs,beegfs,fuse.sshfs,9p -o TARGET,SOURCE,FSTYPE,OPTIONS 2>/dev/null)
    [ -n "$found" ] || warn 'NAS가 연결(mount)돼 있지 않아요. 연결은 서버 관리 팀이 하니, 연결할 폴더 경로를 물어보세요.'
    [ -n "$found" ] && echo "  속도 측정: bash check_network.sh disk <위 폴더 안의 내가 쓸 수 있는 폴더>"

    if [ $# -ge 1 ]; then
        local other=$1
        head_ "다른 서버 $other"
        echo "  쓰는 네트워크 카드: $(route_to "$other")"
        if ping -c 4 -W 2 "$other" >/tmp/.b200ping.$$ 2>&1; then
            ok "응답이 와요(왕복 $(tail -1 /tmp/.b200ping.$$ | awk -F/ '{print $5}') ms)"
        else
            warn "ping 응답이 없어요(ping만 막혀 있을 수도 있어요)"
        fi
        rm -f /tmp/.b200ping.$$
        if timeout 3 bash -c "</dev/tcp/$other/22" 2>/dev/null; then ok "SSH(22) 포트가 열려 있어요"
        else warn "SSH(22) 포트에 연결되지 않아요"; fi
        echo "  속도 측정: 그 서버에서 bash check_network.sh listen  →  이 서버에서 bash check_network.sh send $other"
    fi
}

# 서버 사이 속도: iperf3 가 있으면 그것을, 없으면 python3 으로 TCP 여러 줄기를 보낸다
PY_LISTEN='
import socket, sys, threading, time
port, streams, wait = int(sys.argv[1]), int(sys.argv[2]), int(sys.argv[3])
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("0.0.0.0", port)); s.listen(streams); s.settimeout(wait)
print(f"  {port}번 포트에서 기다려요(최대 {wait}초). 다른 서버에서 send 를 실행하세요.", flush=True)
total = [0]; lock = threading.Lock(); conns = []
def recv(c):
    n = 0; buf = bytearray(4 << 20); mv = memoryview(buf)
    while True:
        k = c.recv_into(mv)
        if not k: break
        n += k
    with lock: total[0] += n
try:
    c, a = s.accept()
except socket.timeout:
    print("  연결이 오지 않았어요(방화벽이나 네트워크 연결을 확인하세요)."); sys.exit(1)
t0 = time.time(); th = [threading.Thread(target=recv, args=(c,))]; th[0].start()
s.settimeout(3)
for _ in range(streams - 1):
    try: c2, _ = s.accept(); t = threading.Thread(target=recv, args=(c2,)); t.start(); th.append(t)
    except socket.timeout: break
for t in th: t.join()
dt = time.time() - t0
print(f"  {a[0]} 에서 동시 연결 {len(th)}개로 {total[0]/1e9:.1f} GB를 {dt:.1f}초에 받았어요: {total[0]/dt/1e9:.2f} GB/s ({total[0]/dt*8/1e9:.1f} Gbps)")
'
PY_SEND='
import socket, sys, time, multiprocessing as mp
host, port, streams, secs = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), float(sys.argv[4])
wait = float(sys.argv[5]) if len(sys.argv) > 5 else 0   # 받는 쪽이 아직 안 켜졌으면 이만큼 다시 시도
def send(q):
    deadline = time.time() + wait
    while True:
        try: c = socket.create_connection((host, port), timeout=10); break
        except OSError:
            if time.time() > deadline: q.put(0); return
            time.sleep(1)
    buf = memoryview(bytes(4 << 20)); n = 0; end = time.time() + secs
    while time.time() < end:
        c.sendall(buf); n += len(buf)
    c.close(); q.put(n)
q = mp.Queue(); ps = []
for i in range(streams):
    p = mp.Process(target=send, args=(q,)); p.start(); ps.append(p); time.sleep(0.05)
for p in ps: p.join()
tot = sum(q.get() for _ in ps)
if tot == 0: print(f"  {host}:{port} 에 연결하지 못했어요. 받는 쪽에서 listen 을 먼저 실행했는지, 방화벽이 막는지 확인하세요."); sys.exit(1)
print(f"  동시 연결 {streams}개로 {tot/1e9:.1f} GB를 {secs:.0f}초 동안 보냈어요: 약 {tot/secs/1e9:.2f} GB/s ({tot/secs*8/1e9:.1f} Gbps). 정확한 값은 받는 쪽 숫자를 보세요.")
'
cmd_listen() {
    if command -v iperf3 >/dev/null; then echo "  iperf3로 받을 준비를 했어요(한 번 측정하면 끝나요)"; exec iperf3 -s -1 -p "$PORT"; fi
    python3 -I -c "$PY_LISTEN" "$PORT" "$STREAMS" 120
}
cmd_send() {
    local to=${1:?받는 쪽 IP 를 적으세요: bash check_network.sh send 10.0.0.2}
    echo "  쓰는 네트워크 카드: $(route_to "$to"),  동시 연결 ${STREAMS}개, ${SECS}초"
    if command -v iperf3 >/dev/null; then exec iperf3 -c "$to" -p "$PORT" -P "$STREAMS" -t "$SECS"; fi
    python3 -I -c "$PY_SEND" "$to" "$PORT" "$STREAMS" "$SECS"
    echo "  (python으로 잰 값이라 100 Gbps 이상 카드에서는 실제보다 낮게 나올 수 있어요)"
}

cmd_disk() {
    local dir=${1:?폴더를 적으세요: bash check_network.sh disk /mnt/nas/내폴더} size_gb=${SIZE_GB:-4} t0 t1 b f
    [[ "$size_gb" =~ ^[0-9]+$ ]] && [ "$size_gb" -ge 1 ] || size_gb=4
    [ -d "$dir" ] && [ -w "$dir" ] || { bad "$dir 에 쓸 수 없어요(없거나 권한 없음)"; exit 1; }
    local free; free=$(df -Pk "$dir" | awk 'NR==2 {print int($4/1048576)}')
    [ "$free" -gt $((size_gb * 2)) ] || { bad "남은 공간이 ${free} GB라서 시험 파일(${size_gb} GB)을 쓰기 어려워요"; exit 1; }
    local jobs=${JOBS:-1} i cnt
    [[ "$jobs" =~ ^[0-9]+$ ]] && [ "$jobs" -ge 1 ] || jobs=1
    # 시험 파일은 새로 만든 내 폴더 안에만 쓴다(남이 같은 이름의 링크를 심어 두어도 따라가지 않게)
    # root 는 다른 계정이 지우고 바꿀 수 있는 폴더에서 재지 않는다(시험 폴더를 링크로 바꿔치기하면 root 가 시스템 파일을 덮는다)
    if [ "$(id -u)" = 0 ] && [ ! -k "$dir" ] && { [ ! -O "$dir" ] || [ -n "$(find "$dir" -maxdepth 0 -perm /022)" ]; }; then
        bad "root로 실행하면 다른 계정이 쓰는 폴더는 측정하지 않아요: $dir. 같은 디스크의 root 폴더(예: /app/inbox)에서 측정하거나, 그 계정으로 실행하세요"; exit 1
    fi
    TD=$(mktemp -d "$dir/.b200_speedtest.XXXXXX") || { bad "$dir 에 시험 폴더를 만들지 못했어요"; exit 1; }
    trap 'rm -rf "$TD"' EXIT   # TD 는 끝날 때 지우려고 전역
    f="$TD/t"
    cnt=$((size_gb * 64 / jobs)); [ "$cnt" -ge 1 ] || cnt=1; b=$((cnt * jobs * 16 * 1024 * 1024))
    echo "${c_c}[$(hostname)] $dir 속도 ($(df -P "$dir" | awk 'NR==2 {print $1}'), 시험 파일 합계 $((b >> 30)) GB, 동시에 파일 ${jobs}개)${c_0}"
    t0=$(date +%s.%N)
    for i in $(seq 1 "$jobs"); do
        { dd if=/dev/zero of="$f.$i" bs=16M count="$cnt" oflag=direct conv=fsync status=none 2>/dev/null ||
          dd if=/dev/zero of="$f.$i" bs=16M count="$cnt" conv=fsync status=none; } &
    done; wait
    t1=$(date +%s.%N); echo "  쓰기: $(rate "$b" "$(awk -v a="$t1" -v b="$t0" 'BEGIN{print a-b}')")"
    t0=$(date +%s.%N)
    for i in $(seq 1 "$jobs"); do
        { dd if="$f.$i" of=/dev/null bs=16M iflag=direct status=none 2>/dev/null || dd if="$f.$i" of=/dev/null bs=16M status=none; } &
    done; wait
    t1=$(date +%s.%N); echo "  읽기: $(rate "$b" "$(awk -v a="$t1" -v b="$t0" 'BEGIN{print a-b}')")"
    [ "$jobs" = 1 ] && [ -z "${ALL_MODE:-}" ] && echo "  (파일 하나로 측정한 값이에요. 여럿이 동시에 쓸 때 속도는 앞에 JOBS=8 을 붙여 측정하세요)"
}

# ------------------------------------------------------------------ 한 번에(턴키)
# 두 서버에서 각각 "bash check_network.sh all" 을 실행한다. 같은 NAS 의 .b200_net 폴더에 서로의 주소를 적어 두고,
# 짝이 보이면 서버 사이 속도를 양쪽에서 동시에 잰다(이더넷은 전이중이라 서로 방해하지 않는다). 짝이 없으면 혼자 잰다.
WAIT_PEER=${WAIT_PEER:-600}
ME=${B200_HOST:-$(hostname -s)}
SUM=()
nas_dir() {   # 쓸 수 있는 NAS 폴더: 적어 준 폴더 → NAS/tmp → NAS
    local d c
    [ -n "${1:-}" ] && { echo "$1"; return; }
    while read -r d; do
        for c in "$d/tmp" "$d"; do [ -d "$c" ] && [ -w "$c" ] && { echo "$c"; return; }; done
    done < <(findmnt -rn -t nfs,nfs4,cifs,smb3,lustre,gpfs,beegfs -o TARGET 2>/dev/null)
}
eth_ip() {   # 기본 경로 카드의 IP
    local dev; dev=$(ip route show default 2>/dev/null | grep -oP 'dev \K\S+' | head -1)
    { ip -4 -br addr show "$dev" 2>/dev/null | awk '{print $3}' | cut -d/ -f1; hostname -I 2>/dev/null | awk '{print $1}'; } | grep . | head -1
}
ib_ips() {   # InfiniBand 카드의 IP 들
    local d; for d in /sys/class/net/*; do
        [ "$(cat "$d/type" 2>/dev/null)" = 32 ] || continue
        ip -4 -br addr show "$(basename "$d")" 2>/dev/null | awk '{print $3}' | cut -d/ -f1
    done | grep . | tr '\n' ' '
}
active_hcas() {
    local p; for p in /sys/class/infiniband/*/ports/1; do
        grep -q ACTIVE "$p/state" 2>/dev/null && basename "$(dirname "$(dirname "$p")")"
    done | tr '\n' ' '
}
field() { grep -m1 "^$1=" "$2" 2>/dev/null | cut -d= -f2-; }   # 짝 정보 파일은 읽기만 한다(실행하지 않음)
# 짝 정보는 같은 NAS 를 쓰는 누구나 고칠 수 있는 파일에서 온다. 모양이 맞는 값만 쓴다
# (예: PORT 에 산술식을 넣으면 $(( )) 안에서 명령이 실행된다)
peer_ok() {
    local f=$1 ip='([0-9]{1,3}\.){3}[0-9]{1,3}'
    [[ "$(field HOST "$f")" =~ ^[A-Za-z0-9._-]{1,64}$ ]] &&
    [[ "$(field ETH "$f")" =~ ^$ip$ ]] &&
    [[ "$(field IB "$f")" =~ ^(($ip) ?)*$ ]] &&
    [[ "$(field HCAS "$f")" =~ ^([A-Za-z0-9_]+ ?)*$ ]] &&
    [[ "$(field PORT "$f")" =~ ^[0-9]{1,5}$ ]] &&
    [[ "$(field PERFTEST "$f")" =~ ^1?$ ]]
}
# 파일을 바로 쓰지 않고 새 임시 파일을 만든 뒤 이름을 바꾼다(그 자리에 링크가 있어도 링크를 따라가지 않는다)
put() {   # $1 경로, 내용은 표준 입력
    local t; t=$(mktemp "$(dirname "$1")/.tmp.XXXXXX") || return 1
    cat > "$t" && chmod 644 "$t" && mv -f "$t" "$1"   # 다른 서버(다른 계정일 수도)가 읽을 수 있게
}
gbs() { local v; v=$(grep -oE '[0-9.]+ GB/s \([0-9.]+ Gbps\)' | tail -1); [ -n "$v" ] && echo "$v"; }
wait_file() {   # $1 파일이 $2 파일보다 새것으로 생길 때까지 $3 초 기다린다
    local i; for i in $(seq 1 "$3"); do [ -f "$1" ] && [ ! "$1" -ot "$2" ] && return 0; sleep 1; done; return 1
}

pair_tcp() {   # $1 이름 $2 내 포트 $3 짝 IP $4 짝 포트
    local tmp; tmp=$(mktemp)
    python3 -I -c "$PY_LISTEN" "$2" "$STREAMS" 90 > "$tmp" 2>&1 &
    local lp=$!
    sleep 2
    local sent; sent=$(python3 -I -c "$PY_SEND" "$3" "$4" "$STREAMS" "$SECS" 60 2>&1)
    wait "$lp"
    local got; got=$(grep -v '기다려요' "$tmp"); rm -f "$tmp"
    echo "  보내기 → $3: $(echo "$sent" | gbs || echo '실패(연결하지 못했어요)')"
    echo "  받기 ← $3: $(echo "$got" | gbs || echo '실패(상대 서버가 보내지 못했어요)')"
    SUM+=("서버 사이 $1: 받기 $(echo "$got" | gbs || echo '실패'), 보내기 $(echo "$sent" | gbs || echo '실패')")
}

pair_rdma() {   # 같은 이름의 InfiniBand 카드끼리 RDMA 쓰기 속도(perftest). 연결 준비는 이더넷 IP 로 한다
    local role=$1 peer_eth=$2 hcas=$3 i=0 hca out bw
    for hca in $hcas; do
        i=$((i + 1))
        if [ "$role" = A ]; then
            out=$(timeout 45 ib_write_bw -d "$hca" -p $((18514 + i)) -D 5 -F --report_gbits 2>&1)
        else
            # 짝이 아직 안 켜졌으면(연결 거부) 다시 시도. 연결은 됐는데 실패하면 그 카드는 거기서 끝
            local t; for t in $(seq 1 60); do
                out=$(timeout 25 ib_write_bw -d "$hca" -p $((18514 + i)) -D 5 -F --report_gbits "$peer_eth" 2>&1) && break
                echo "$out" | grep -qi "couldn't connect" || break
                sleep 1
            done
        fi
        bw=$(echo "$out" | awk '/^ *[0-9]+ +[0-9]+ +[0-9.]+ +[0-9.]+/ {v=$4} END {if (v) print v}')
        if [ -n "$bw" ]; then
            echo "  $(pad "$hca" 10) $bw Gb/s"; SUM+=("RDMA $hca: $bw Gb/s")
        else
            echo "  $(pad "$hca" 10) 연결 안 됨 (같은 InfiniBand 망이 아니거나 막혀 있어요)"; SUM+=("RDMA $hca: 연결 안 됨")
        fi
    done
}

disk_both() {   # 한 줄기와 8줄기
    local name=$1 dir=$2 r1 r8
    r1=$( (JOBS=1 cmd_disk "$dir") 2>&1); echo "$r1"
    r8=$( (JOBS=8 cmd_disk "$dir") 2>&1); echo "$r8"
    SUM+=("$name 파일 1개: 쓰기 $(echo "$r1" | grep 쓰기 | gbs || echo 실패) / 읽기 $(echo "$r1" | grep 읽기 | gbs || echo 실패)")
    SUM+=("$name 동시 8개: 쓰기 $(echo "$r8" | grep 쓰기 | gbs || echo 실패) / 읽기 $(echo "$r8" | grep 읽기 | gbs || echo 실패)")
}

all_body() {
    local nas R peer= pf role mine local_dir PINFO=
    nas=$(nas_dir "${1:-}")
    echo "${c_c}[GPU 서버] 네트워크 전체 점검  ($(date '+%Y-%m-%d %H:%M'), $ME, $(id -un))${c_0}"
    [ "$(id -u)" = 0 ] || warn 'root가 아니라서 InfiniBand 망 조회(ibhosts)는 건너뛰어요'
    cmd_info

    # 짝 찾기
    R="$nas/.b200_net"
    if [ -n "$nas" ] && { [ -L "$R" ] || [ -L "$nas" ]; }; then
        warn "상대 서버 확인용 폴더가 링크라서 쓰지 않아요: $R (누가 만들었는지 확인하세요). 이 서버만 측정해요"; nas=
    fi
    if [ -n "$nas" ]; then
        mkdir -p "$R" 2>/dev/null; [ -L "$R" ] && { warn "상대 서버 확인용 폴더가 링크예요: $R. 여기서 멈춰요"; return 1; }
        # root 는 다른 계정이 만든 폴더에 쓰지 않는다(그 계정이 파일을 링크로 바꿔치기하면 root 가 이 서버의 파일을 덮는다)
        if [ "$(id -u)" = 0 ] && ! [[ "$(stat -c %u "$R" 2>/dev/null)" =~ ^(0|65534|4294967294)$ ]]; then
            warn "상대 서버 확인용 폴더를 다른 계정이 만들었어요: $R (주인 uid $(stat -c %u "$R")). 지우거나 그 계정으로 실행하세요. 이 서버만 측정해요"; nas=
        fi
    fi
    if [ -n "$nas" ]; then
        rm -f "$R/$ME".*
        mine="$R/$ME.info"
        # 끝나거나 중간에 멈추면 내 정보를 지운다(남아 있으면 다음에 한쪽만 실행해도 짝이 있는 줄 안다)
        trap 'rm -f "$mine" "$PINFO"' EXIT; trap 'rm -f "$mine" "$PINFO"; exit 130' INT TERM
        { echo "HOST=$ME"; echo "ETH=${B200_ETH:-$(eth_ip)}"; echo "IB=$(ib_ips)"; echo "HCAS=$(active_hcas)"
          echo "PORT=$PORT"; echo "PERFTEST=$(command -v ib_write_bw >/dev/null && echo 1)"; } | put "$mine"
        head_ "상대 서버 찾기 (NAS: $R)"
        echo "  다른 서버에서도 bash /app/inbox/check_network.sh all 을 실행하세요. 최대 $((WAIT_PEER / 60))분 기다려요."
        local i rejected=' '
        for i in $(seq 1 "$WAIT_PEER"); do
            for pf in "$R"/*.info; do
                [ -f "$pf" ] && [ ! -L "$pf" ] && [ "$pf" != "$mine" ] && [ -n "$(find "$pf" -mmin -30 2>/dev/null)" ] || continue
                case "$rejected" in *" $pf "*) continue ;; esac
                # 짝 정보는 지금 한 번 복사해 두고 그것만 쓴다(시각도 함께: 짝의 완료 표시가 이번 실행 것인지 가릴 때 쓴다)
                PINFO=$(mktemp); cp -p "$pf" "$PINFO"
                if peer_ok "$PINFO"; then peer=$(field HOST "$PINFO"); pf=$PINFO; break 2; fi
                warn "상대 서버 정보 파일의 내용이 이상해서 쓰지 않아요: $pf"; rm -f "$PINFO"; rejected+=" $pf "
            done
            [ $((i % 60)) = 0 ] && echo "  ...기다리는 중이에요($((i / 60))분)"
            sleep 1
        done
        # 공유용 사본에서 상대 서버 이름을 가리려면 이름이 필요하다. 상대가 먼저 끝나면 NAS 의 정보 파일이 지워지므로 따로 적어 둔다
        [ -n "$peer" ] && [ -n "${PEER_NOTE:-}" ] && echo "$peer" > "$PEER_NOTE"
        if [ -n "$peer" ]; then local pibs; pibs=$(field IB "$pf"); ok "상대 서버: $peer (이더넷 $(field ETH "$pf"), InfiniBand ${pibs:-없음})"
        else warn '상대 서버를 찾지 못해서 이 서버만 측정해요'; fi
    else
        warn 'NAS를 찾지 못해서 이 서버만 측정해요(NAS 폴더를 직접 적으려면: bash check_network.sh all <NAS 폴더>)'
    fi

    if [ -n "$peer" ]; then
        # 이름이 앞서는 쪽이 A(RDMA 받는 쪽, NAS 먼저). 언어 설정과 상관없이 같은 결과가 나오게 C 순서로 비교한다
        role=B; [ "$(printf '%s\n%s\n' "$ME" "$peer" | LC_ALL=C sort | head -1)" = "$ME" ] && role=A
        local peth pib pport myib
        peth=$(field ETH "$pf"); pib=$(field IB "$pf" | awk '{print $1}'); pport=$(field PORT "$pf")
        head_ "서버 사이: 이더넷 ($ME ↔ $peer, 양쪽 동시에 ${SECS}초)"
        pair_tcp 이더넷 "$PORT" "$peth" "$pport"
        myib=$(ib_ips)
        if [ -n "$pib" ] && [ -n "$myib" ]; then
            head_ "서버 사이: InfiniBand로 IP 통신 (IPoIB, $pib)"
            echo "  쓰는 네트워크 카드: $(route_to "$pib")"
            pair_tcp IPoIB $((PORT + 1)) "$pib" $((pport + 1))
            echo "  (TCP로 잰 값이에요. 두 서버를 묶어 학습할 때 쓰는 RDMA 는 CPU를 거치지 않아 보통 이보다 빨라요. 아래 RDMA 값을 보세요)"
        fi
        head_ '서버 사이: RDMA (두 서버를 묶어 학습할 때 NCCL 이 쓰는 통신)'
        if command -v ib_write_bw >/dev/null && [ "$(field PERFTEST "$pf")" = 1 ]; then
            local common; common=$(comm -12 <(active_hcas | tr ' ' '\n' | grep . | sort) <(field HCAS "$pf" | tr ' ' '\n' | grep . | sort) | tr '\n' ' ')
            pair_rdma "$role" "$peth" "$common"
        else
            warn '양쪽에 perftest(ib_write_bw)가 있어야 측정할 수 있어요. 설치 방법: docs/4_네트워크.md 의 "InfiniBand 도구"'
            SUM+=("RDMA: perftest가 없어 측정 못 함")
        fi
        : | put "$R/$ME.netdone"; wait_file "$R/$peer.netdone" "$pf" 180 || true
    fi

    # 디스크: NAS 는 두 서버가 차례로(동시에 재면 나눠 가져서 값이 반이 된다)
    # root 는 다른 계정이 쓸 수 있는 폴더(/app/workspace)에서 재지 않는다(시험 폴더를 바꿔치기해 시스템 파일을 덮을 수 있다)
    local_dir=; for d in /app/inbox /app/workspace /app; do [ -d "$d" ] && [ -w "$d" ] && [ -O "$d" ] && { local_dir=$d; break; }; done
    if [ -n "$peer" ] && [ "$role" = B ]; then
        [ -n "$local_dir" ] && { head_ "로컬 SSD ($local_dir)"; disk_both '로컬 SSD' "$local_dir"; }
        echo "  상대 서버($peer)가 NAS 측정을 마칠 때까지 기다려요..."; wait_file "$R/$peer.nasdone" "$pf" 900 || warn '상대 서버가 15분 안에 끝내지 않아서 기다리지 않고 넘어가요'
        head_ "NAS ($nas)"; disk_both NAS "$nas"
        : | put "$R/$ME.nasdone"
    else
        if [ -n "$nas" ]; then head_ "NAS ($nas)"; disk_both NAS "$nas"; fi
        [ -n "$nas" ] && { : | put "$R/$ME.nasdone"; }
        [ -n "$local_dir" ] && { head_ "로컬 SSD ($local_dir)"; disk_both '로컬 SSD' "$local_dir"; }
        [ -n "$peer" ] && { wait_file "$R/$peer.nasdone" "$pf" 900 || true; }
    fi

    # InfiniBand 망: 카드마다 어떤 서버·장비가 보이나(같은 망인지)
    if [ "$(id -u)" = 0 ] && command -v ibhosts >/dev/null; then
        head_ 'InfiniBand 망에 보이는 장비 (카드별)'
        local devs seen
        for hca in $(active_hcas); do
            devs=$(ibhosts -C "$hca" -P 1 2>/dev/null | grep -oP '"\K[^"]+' | awk '{print $1}' | sort -u)
            seen=; [ -n "$peer" ] && echo "$devs" | grep -qxF "$peer" && seen=', 상대 서버가 보여요(같은 망)'
            echo "  $(pad "$hca" 10) 장비 $(echo "$devs" | grep -c .)대$seen"
            echo "    장비: $(echo "$devs" | tr '\n' ' ')"
        done
    elif [ "$(id -u)" = 0 ]; then
        warn 'ibhosts(infiniband-diags)가 없어서 InfiniBand 망은 못 봐요. 설치 방법: docs/4_네트워크.md 의 "InfiniBand 도구"'
    fi

    head_ '요약'
    printf '  %s\n' "${SUM[@]}"
}
# 보고서 둘 곳: root 는 /app/inbox/reports(root 만 고치고 공용 계정 FileZilla로 내려받을 수 있음),
# 그 밖에는 실행한 폴더(내 것일 때)나 홈. 남이 쓸 수 있는 폴더에는 쓰지 않는다(링크로 다른 파일을 덮게 만들 수 있다)
report_dir() {
    local ib=${B200_INBOX:-/app/inbox}   # 시험할 때만 바꾼다
    if [ "$(id -u)" = 0 ] && [ -d "$ib" ] && [ ! -L "$ib" ] && [ "$(stat -c %U "$ib")" = root ]; then
        mkdir -p "$ib/reports" && [ ! -L "$ib/reports" ] && chmod 755 "$ib/reports" && echo "$ib/reports" && return
    fi
    if [ -O . ] && [ -w . ]; then echo "$PWD"; else echo "$HOME"; fi
}
# 공유용 사본: 서버 이름·IP·NAS 주소·계정·폴더 이름을 가려서 git 으로 올려도 되게 만든다.
# $1 원본, $2 사본, 나머지는 "가릴말=바꿀말". IP 는 처음 나온 순서대로 IP-1, IP-2 … 로 바꿔 같은 IP 는 같은 번호가 된다
share_copy() {
    local src=$1 dst=$2; shift 2
    perl -Mutf8 -CSDA -ne '
        BEGIN { for (@ARGV) { my ($k, $v) = split /=/, $_, 2; $m{$k} //= $v if length($k) >= 2 }
                @ARGV = (); $re = join "|", map { quotemeta } sort { length($b) <=> length($a) } keys %m; $n = 0 }
        sub w { my $n = 0; $n += $_ =~ /[\x{1100}-\x{115F}\x{2E80}-\x{A4CF}\x{AC00}-\x{D7A3}\x{F900}-\x{FAFF}\x{FF00}-\x{FF60}]/ ? 2 : 1 for split //, $_[0]; $n }   # 화면 폭(한글 두 칸)
        sub max { $_[0] > $_[1] ? $_[0] : $_[1] }
        next if /^\s*장비: /;                                  # InfiniBand 망의 장비 이름(다른 팀 장비일 수 있음)
        # 한 번에 바꾼다(바꾼 말을 다시 바꾸지 않게). 뒤에 칸을 맞춘 빈칸이 있으면 원래 칸 너비로 다시 채워 원래 이름 길이가 드러나지 않게 한다
        s{($re)(\(\d+\))?( {2,})?}{ my ($k, $u, $sp) = ($1, $2 // "", $3); $m{$k} . $u . (defined $sp ? " " x max(1, w($k) + length($sp) - w($m{$k})) : "") }ge if length $re;
        s{\b[\w.-]+:/[\w./-]*}{NAS주소}g;
        s{\b((?:\d{1,3}\.){3}\d{1,3})(?:/\d+)?\b}{ $ip{$1} //= "IP-" . ++$n }ge;
        print;
    ' "$@" < "$src" > "$dst"
    chmod 644 "$dst" 2>/dev/null
}
LABEL="서버(…$(hostname -s | tail -c 3))"   # 공유용 사본에서 이 서버를 부르는 이름(이름 끝 두 글자만)
cmd_all() {
    local dir; dir=$(report_dir)
    local out; out=$(mktemp "$dir/network_report_${ME}_$(date +%Y%m%d-%H%M)_XXXX.txt") || out=$(mktemp)
    PEER_NOTE=$(mktemp)
    all_body "$@" 2>&1 | tee >(sed 's/\x1b\[[0-9;]*m//g' > "$out")
    sleep 1
    chmod 644 "$out" 2>/dev/null   # 공용 계정(FileZilla)으로 내려받을 수 있게
    # 공유용 사본: 이 서버와 상대 서버 이름을 가린다(상대 서버 이름은 NAS 의 상대 정보 파일에서)
    local masks=("$(hostname -f 2>/dev/null)=$LABEL" "$ME=$LABEL") f h
    for f in "$PEER_NOTE" "$(nas_dir "${1:-}")"/.b200_net/*.info; do
        [ "$f" = "$PEER_NOTE" ] && { h=$(head -1 "$f"); [[ "$h" =~ ^[A-Za-z0-9._-]{2,64}$ ]] && masks+=("$h=상대서버(…${h: -2})"); continue; }
        h=$(field HOST "$f"); [[ "$h" =~ ^[A-Za-z0-9._-]{2,64}$ ]] && [ "$h" != "$ME" ] && masks+=("$h=상대서버(…${h: -2})")
    done 2>/dev/null
    local share="$dir/network_공유용_${LABEL//[^A-Za-z0-9]/}_$(date +%Y%m%d-%H%M).txt"
    share_copy "$out" "$share" "${masks[@]}"
    rm -f "$PEER_NOTE"
    echo; echo "보고서(원본, 사내 정보 있음): $(readlink -f "$out")"
    echo "보고서(공유용, git 으로 올려도 돼요): $share"
    echo "  공유용만 내려받아 저장소의 reports 폴더에 넣고 올리세요(docs/4_네트워크.md 의 \"결과 가져오기\")."
}

case "${1:-}" in
    all)    shift; ALL_MODE=1; cmd_all "$@" ;;
    listen) cmd_listen ;;
    send)   shift; cmd_send "$@" ;;
    disk)   shift; cmd_disk "$@" ;;
    -h|--help) sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//' ;;
    *)      cmd_info "$@" ;;
esac
