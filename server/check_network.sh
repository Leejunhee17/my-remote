#!/usr/bin/env bash
# [B200 서버] 네트워크와 NAS 를 점검한다. root 없이 되고, 설정은 아무것도 바꾸지 않는다.
#   bash check_network.sh                   이 서버의 네트워크 카드·속도, NAS 연결 보기
#   bash check_network.sh <다른 서버 IP>     + 다른 서버와 연결되는지, 어느 카드로 가는지
#   bash check_network.sh listen            서버 사이 속도 재기: 받는 쪽(먼저 실행, 2분 기다림)
#   bash check_network.sh send <받는 쪽 IP>  서버 사이 속도 재기: 보내는 쪽(10초)
#   bash check_network.sh disk <폴더>        그 폴더(NAS 나 /app)의 쓰기·읽기 속도(임시 파일 4 GB 를 쓰고 지움)
#   JOBS=8 bash check_network.sh disk <폴더> 여러 줄기로 동시에(여럿이 함께 쓸 때의 전체 속도)
# 숫자는 GB/s(초당 기가바이트)와 Gbps(초당 기가비트, 카드 속도 단위)를 같이 보여 준다. 1 GB/s = 8 Gbps.
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
    # 묶은 카드(bond): 어떤 카드를 묶었는지와 나눠 보내는 방식. 한 연결(TCP 하나)은 카드 하나 속도를 넘지 못한다
    if [ -d "$d/bonding" ]; then
        echo "      = $(cat "$d/bonding/slaves" 2>/dev/null | sed 's/ / + /g'),  모드 $(cut -d' ' -f1 "$d/bonding/mode" 2>/dev/null), 나누는 기준 $(cut -d' ' -f1 "$d/bonding/xmit_hash_policy" 2>/dev/null)"
        echo "        한 연결(scp 하나 등)은 카드 하나 속도까지만 나와요. 여러 연결을 동시에 해야 합친 속도가 나와요"
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
    echo "${c_c}[B200 서버] 네트워크 점검  ($(date '+%Y-%m-%d %H:%M'), $(hostname), $(id -un))${c_0}"
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
        echo "  IP 가 있는 포트는 NAS·IP 통신용, IP 가 없는 포트는 보통 GPU 서버끼리 RDMA(NCCL)로만 쓰는 포트예요."
        echo "  다른 서버와 같은 InfiniBand 망인지는 root 로 iblinkinfo 나 ibnetdiscover 를 실행하면 보여요(다른 서버 이름이 나오면 같은 망)."
    fi

    head_ 'NAS (네트워크 저장소)'
    local m found=
    while read -r tgt src fs opts; do
        found=1
        local host=${src%%:*}; host=${host#//}; host=${host%%/*}
        local ip; ip=$(getent ahostsv4 "$host" 2>/dev/null | awk 'NR==1 {print $1}'); ip=${ip:-$host}
        echo "  $tgt  ←  $src  ($fs)"
        echo "      가는 카드: $(route_to "$ip")"
        echo "      옵션: $(echo "$opts" | tr ',' '\n' | grep -E '^(vers|proto|rsize|wsize|nconnect|hard|soft)=?' | tr '\n' ' ')"
        echo "$opts" | grep -q 'proto=rdma' && ok 'RDMA 로 연결(빠른 방식)'
    done < <(findmnt -rn -t nfs,nfs4,cifs,smb3,lustre,gpfs,beegfs,fuse.sshfs,9p -o TARGET,SOURCE,FSTYPE,OPTIONS 2>/dev/null)
    [ -n "$found" ] || warn 'NAS 가 연결(mount)돼 있지 않아요. 연결은 서버 관리 팀이 해요: 연결된 폴더 경로를 물어보세요.'
    [ -n "$found" ] && echo "  속도 재기: bash check_network.sh disk <위 폴더 안의 내가 쓸 수 있는 폴더>"

    if [ $# -ge 1 ]; then
        local other=$1
        head_ "다른 서버 $other"
        echo "  가는 카드: $(route_to "$other")"
        if ping -c 4 -W 2 "$other" >/tmp/.b200ping.$$ 2>&1; then
            ok "응답함, 왕복 $(tail -1 /tmp/.b200ping.$$ | awk -F/ '{print $5}') ms"
        else
            warn "ping 응답이 없어요(ping 만 막혀 있을 수도 있어요)"
        fi
        rm -f /tmp/.b200ping.$$
        if timeout 3 bash -c "</dev/tcp/$other/22" 2>/dev/null; then ok "SSH(22) 포트가 열려 있어요"
        else warn "SSH(22) 포트에 닿지 않아요"; fi
        echo "  속도 재기: 그 서버에서 bash check_network.sh listen  →  이 서버에서 bash check_network.sh send $other"
    fi
}

# 서버 사이 속도: iperf3 가 있으면 그것을, 없으면 python3 으로 TCP 여러 줄기를 보낸다
PY_LISTEN='
import socket, sys, threading, time
port, streams, wait = int(sys.argv[1]), int(sys.argv[2]), int(sys.argv[3])
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("0.0.0.0", port)); s.listen(streams); s.settimeout(wait)
print(f"  {port} 번 포트에서 기다려요(최대 {wait}초). 다른 서버에서 send 를 실행하세요.", flush=True)
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
print(f"  {a[0]} 에서 {len(th)}줄기로 {total[0]/1e9:.1f} GB 를 {dt:.1f}초에 받음: {total[0]/dt/1e9:.2f} GB/s ({total[0]/dt*8/1e9:.1f} Gbps)")
'
PY_SEND='
import socket, sys, time, multiprocessing as mp
host, port, streams, secs = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), float(sys.argv[4])
def send(q):
    c = socket.create_connection((host, port), timeout=10)
    buf = memoryview(bytes(4 << 20)); n = 0; end = time.time() + secs
    while time.time() < end:
        c.sendall(buf); n += len(buf)
    c.close(); q.put(n)
q = mp.Queue(); ps = []
for i in range(streams):
    p = mp.Process(target=send, args=(q,)); p.start(); ps.append(p); time.sleep(0.05)
for p in ps: p.join()
tot = sum(q.get() for _ in ps)
print(f"  {streams}줄기로 {tot/1e9:.1f} GB 를 {secs:.0f}초 동안 보냄: 약 {tot/secs/1e9:.2f} GB/s ({tot/secs*8/1e9:.1f} Gbps). 정확한 값은 받는 쪽 숫자를 보세요.")
'
cmd_listen() {
    if command -v iperf3 >/dev/null; then echo "  iperf3 로 기다려요(한 번 재고 끝나요)"; exec iperf3 -s -1 -p "$PORT"; fi
    python3 -c "$PY_LISTEN" "$PORT" "$STREAMS" 120
}
cmd_send() {
    local to=${1:?받는 쪽 IP 를 적으세요: bash check_network.sh send 10.0.0.2}
    echo "  가는 카드: $(route_to "$to"),  ${STREAMS}줄기, ${SECS}초"
    if command -v iperf3 >/dev/null; then exec iperf3 -c "$to" -p "$PORT" -P "$STREAMS" -t "$SECS"; fi
    python3 -c "$PY_SEND" "$to" "$PORT" "$STREAMS" "$SECS"
    echo "  (python 으로 잰 값이라 100 Gbps 이상 카드에서는 실제보다 낮게 나올 수 있어요)"
}

cmd_disk() {
    local dir=${1:?폴더를 적으세요: bash check_network.sh disk /mnt/nas/내폴더} size_gb=${SIZE_GB:-4} t0 t1 b
    [ -d "$dir" ] && [ -w "$dir" ] || { bad "$dir 에 쓸 수 없어요(없거나 권한 없음)"; exit 1; }
    local free; free=$(df -Pk "$dir" | awk 'NR==2 {print int($4/1048576)}')
    [ "$free" -gt $((size_gb * 2)) ] || { bad "남은 공간이 ${free} GB 라 시험 파일(${size_gb} GB)을 쓰기 어려워요"; exit 1; }
    local jobs=${JOBS:-1} i cnt
    f="$dir/.b200_speedtest.$$"; b=$((size_gb * 1024 * 1024 * 1024))   # f 는 끝날 때 지우려고 전역
    cnt=$((size_gb * 64 / jobs)); [ "$cnt" -ge 1 ] || cnt=1; b=$((cnt * jobs * 16 * 1024 * 1024))
    trap 'rm -f "$f".*' EXIT
    echo "${c_c}[$(hostname)] $dir 속도 ($(df -P "$dir" | awk 'NR==2 {print $1}'), 시험 파일 합계 $((b >> 30)) GB, ${jobs}줄기)${c_0}"
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
    [ "$jobs" = 1 ] && echo "  (한 줄기로 잰 값이에요. 전체 속도는 JOBS=8 을 앞에 붙여 재요)"
}

case "${1:-}" in
    listen) cmd_listen ;;
    send)   shift; cmd_send "$@" ;;
    disk)   shift; cmd_disk "$@" ;;
    -h|--help) sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//' ;;
    *)      cmd_info "$@" ;;
esac
