#!/usr/bin/env bash
# [GPU 서버] NAS 구조·권한·용량을 점검해요. 두 서버에서 각각 실행해요(docs/8_NAS.md).
#   bash check_nas.sh                 NAS(nfs 등)로 연결된 폴더를 모두 봐요
#   bash check_nas.sh <우리 팀 폴더>   그 폴더(예: /data/autonomy_sw)의 주인·권한·용량도 봐요
# 바꾸는 것은 없어요. root 로 실행하면 root squash 를 알아보려고 NAS 의 tmp 폴더(스티키 비트가 있을 때만)에
# 빈 파일 하나를 만들었다 바로 지워요. 결과는 /app/inbox/reports/nas_report_<서버>_<시각>.txt 에도 남겨요(root 일 때).
set -uo pipefail
c_g=$'\e[32m'; c_y=$'\e[33m'; c_r=$'\e[31m'; c_c=$'\e[36m'; c_0=$'\e[0m'
ok()   { echo "  ${c_g}[정상]${c_0} $*"; }
warn() { echo "  ${c_y}[주의]${c_0} $*"; }
bad()  { echo "  ${c_r}[문제]${c_0} $*"; }
head_() { echo; echo "${c_c}== $* ==${c_0}"; }
ACC=${GPU_ACCOUNT:-$(cat /etc/gpu/account 2>/dev/null)}   # 공용 계정 이름은 서버의 /etc/gpu/account 한 곳에 적는다
ME=$(hostname -s)
TEAM_DIR=${1:-}
IS_ROOT=; [ "$(id -u)" = 0 ] && IS_ROOT=1

# 화면 폭(한글은 두 칸)에 맞춰 채운다
pad() { local w; w=$(printf '%s' "$1" | LC_ALL=C.UTF-8 wc -L); printf '%s%*s' "$1" $(( $2 > w ? $2 - w : 0 )) ''; }
grp_name() { local n; n=$(getent group "$1" | cut -d: -f1); echo "${n:-$1}"; }
# 주인 번호 → "이름(번호)". 이 서버에 없는 번호면 그렇다고 적는다
who_uid() { local n; n=$(getent passwd "$1" | cut -d: -f1); echo "${n:-이 서버에 없는 계정}($1)"; }
# 권한 숫자 → 누가 쓸 수 있는지
who_writes() {
    local m=$1 s=''
    [ $(( 8#$m & 8#0002 )) -ne 0 ] && s='누구나 씀'
    [ -z "$s" ] && [ $(( 8#$m & 8#0020 )) -ne 0 ] && s='주인·그룹이 씀'
    [ -z "$s" ] && s='주인만 씀'
    [ $(( 8#$m & 8#1000 )) -ne 0 ] && s="$s, 스티키(남의 파일은 못 지움)"
    echo "$s"
}

body() {
    echo "${c_c}[GPU 서버] NAS 점검  ($(date '+%Y-%m-%d %H:%M'), $ME, $(id -un))${c_0}"

    head_ '연결된 NAS'
    mapfile -t mounts < <(findmnt -rn -t nfs,nfs4,cifs,smb3,lustre,gpfs,beegfs -o TARGET,SOURCE,FSTYPE,OPTIONS 2>/dev/null)
    [ -z "${GPU_NAS:-}" ] || mounts=("$GPU_NAS (직접지정) - -")   # NAS 가 mount 목록에 안 보일 때 직접 적는다
    if [ ${#mounts[@]} -eq 0 ]; then
        bad 'NAS로 연결된 폴더가 없어요. 서버 관리 팀에 NAS 연결(mount)을 요청하세요'
        return
    fi
    local m tgt src fs opts
    for m in "${mounts[@]}"; do
        read -r tgt src fs opts <<< "$m"
        echo "  $tgt  ←  $src  ($fs)"
        echo "      옵션: $(echo "$opts" | tr ',' '\n' | grep -E '^(vers|proto|sec|nconnect|hard|soft|ro|rw|actimeo|lookupcache)=?' | tr '\n' ' ')"
    done
    read -r NAS _ <<< "${mounts[0]}"

    head_ "용량 ($NAS)"
    df -hP "$NAS" | awk 'NR==2 {printf "  전체 %s, 쓴 것 %s, 남은 것 %s (%s 찼어요)\n", $2, $3, $4, $5}'
    df -iP "$NAS" 2>/dev/null | awk 'NR==2 && $2 > 0 {printf "  파일 수: 전체 %s, 쓴 것 %s (%s)\n", $2, $3, $5}'
    echo "  (NAS에 폴더별 할당량(quota)이 있으면 그 폴더에서 df 를 하면 할당량이 '전체'로 보여요)"

    head_ "$NAS 바로 아래 (주인·권한)"
    local n=0 d st uid gid mode
    while IFS= read -r -d '' d; do
        n=$((n + 1)); [ "$n" -le 60 ] || continue
        st=$(stat -c '%u %g %a' "$d" 2>/dev/null) || continue
        read -r uid gid mode <<< "$st"
        echo "  $(pad "$(basename "$d")$([ -L "$d" ] && echo ' (링크)')$([ ! -L "$d" ] && [ ! -d "$d" ] && echo ' (파일)')" 26) 주인 $(pad "$(who_uid "$uid")" 24) 그룹 $(pad "$(grp_name "$gid")" 10) $(pad "$mode" 5) $(who_writes "$mode")"
    done < <(find "$NAS" -mindepth 1 -maxdepth 1 -print0 2>/dev/null | sort -z)
    [ "$n" -le 60 ] || echo "  ... 모두 ${n}개 중 60개만 보였어요"
    [ "$n" -gt 0 ] || warn "$NAS 아래를 읽지 못했어요(권한이 없거나 비어 있어요)"
    echo "  '이 서버에 없는 계정' 은 다른 팀 계정이거나, 두 서버의 계정 번호가 달라서 생겨요."

    head_ '계정 번호 (NFSv3 는 이름이 아니라 번호로 주인을 구분해요)'
    if id "$ACC" >/dev/null 2>&1; then
        ACC_UID=$(id -u "$ACC"); ACC_GID=$(id -g "$ACC")
        echo "  우리 공용 계정 $ACC: uid $ACC_UID, gid $ACC_GID"
    else
        bad "공용 계정이 없거나 이름을 알 수 없어요: ${ACC:-(비어 있음)}. /etc/gpu/account 를 확인하세요"; ACC_UID=; ACC_GID=
    fi
    echo "  이 서버의 일반 계정(uid 1000 이상):"
    getent passwd | awk -F: '$3 >= 1000 && $3 < 60000 {printf "    %-16s uid %s\n", $1, $3}'
    # 다른 서버의 결과와 맞춰 본다(NAS 의 스티키 tmp 폴더에 번호만 적어 둔다)
    local shr="$NAS/tmp/.gpu_nas" peer f puid pgid seen=
    if [ -n "$ACC_UID" ] && [ -d "$NAS/tmp" ] && [ -k "$NAS/tmp" ] && [ ! -L "$shr" ]; then
        mkdir -p "$shr" 2>/dev/null && chmod 1777 "$shr" 2>/dev/null
        # root 는 다른 계정이 만든 폴더에 쓰지 않는다(그 계정이 파일을 링크로 바꿔치기하면 root 가 이 서버의 파일을 덮는다)
        if [ -n "$IS_ROOT" ] && ! [[ "$(stat -c %u "$shr" 2>/dev/null)" =~ ^(0|65534|4294967294)$ ]]; then
            warn "두 서버 번호 비교용 폴더를 다른 계정이 만들었어요: $shr. 두 서버의 번호는 위 목록을 눈으로 비교하세요"
        elif [ -d "$shr" ] && [ ! -L "$shr" ] && [ -k "$shr" ]; then
            local t; t=$(mktemp "$shr/.tmp.XXXXXX" 2>/dev/null) &&
                printf 'HOST=%s\nUID=%s\nGID=%s\n' "$ME" "$ACC_UID" "$ACC_GID" > "$t" && chmod 644 "$t" && mv -f "$t" "$shr/$ME.txt"
            for f in "$shr"/*.txt; do
                [ -f "$f" ] && [ ! -L "$f" ] || continue
                peer=$(sed -n 's/^HOST=//p' "$f" | head -1); puid=$(sed -n 's/^UID=//p' "$f" | head -1); pgid=$(sed -n 's/^GID=//p' "$f" | head -1)
                [[ "$peer" =~ ^[A-Za-z0-9._-]{1,64}$ && "$puid" =~ ^[0-9]+$ && "$pgid" =~ ^[0-9]+$ ]] || continue
                [ "$peer" = "$ME" ] && continue
                seen=1
                if [ "$puid" = "$ACC_UID" ] && [ "$pgid" = "$ACC_GID" ]; then ok "$peer 의 $ACC 번호(uid $puid, gid $pgid)와 같아요"
                else bad "$peer 의 $ACC 번호(uid $puid, gid $pgid)가 이 서버와 달라요. 한 서버에서 만든 파일을 다른 서버에서 못 고칠 수 있어요. 서버 관리 팀에 두 서버의 번호를 맞춰 달라고 요청하세요"; fi
            done
            [ -n "$seen" ] || echo "  다른 서버에서도 실행하면 두 서버의 번호가 같은지 여기서 맞춰 봐요."
        fi
    fi

    head_ 'root squash (root 가 NAS에서 누구로 보이는지)'
    if [ -z "$IS_ROOT" ]; then
        echo "  root 로 실행하면 확인해요."
    elif [ -d "$NAS/tmp" ] && [ -k "$NAS/tmp" ]; then
        local probe owner; probe=$(mktemp "$NAS/tmp/.gpu_squash.XXXXXX" 2>/dev/null)
        if [ -n "$probe" ]; then
            owner=$(stat -c '%u' "$probe"); rm -f "$probe"
            if [ "$owner" = 0 ]; then
                warn "root 가 NAS에서도 root 예요(no_root_squash). root 로 NAS에 쓰면 그대로 root 소유가 돼요. 팀원이 쓸 수 있는 NAS 폴더에서는 root 로 작업하지 마세요"
            else
                ok "root 가 NAS에서는 $(who_uid "$owner") 로 바뀌어요(root squash). root 는 NAS에 root 소유 폴더를 만들 수 없어요"
            fi
        else warn "$NAS/tmp 에 시험 파일을 만들지 못해 확인하지 못했어요"; fi
    elif [ "$(stat -c %u "$NAS")" = 0 ] && [ $(( 8#$(stat -c %a "$NAS") & 8#0022 )) -eq 0 ]; then
        # 시험 파일을 만들 곳이 없으면, root 소유이고 남은 못 쓰는 NAS 최상위에 root 가 쓸 수 있는지만 NAS 에 물어본다(만들지 않음)
        if [ -w "$NAS" ]; then
            warn "root 가 NAS에서도 root 예요(no_root_squash. root 소유 $NAS 에 root 가 쓸 수 있어요). 팀원이 쓸 수 있는 NAS 폴더에서는 root 로 작업하지 마세요"
        else
            ok "root 가 NAS에서는 다른 계정으로 바뀌어요(root squash. root 소유 $NAS 에 root 가 쓸 수 없어요)"
        fi
    else
        echo "  $NAS/tmp(스티키 폴더)가 없어서 확인하지 않았어요. 서버 관리 팀에 root squash 설정을 물어보세요."
    fi

    head_ "공용 계정($ACC)이 쓸 수 있는 곳"
    if [ -n "$IS_ROOT" ] && id "$ACC" >/dev/null 2>&1; then
        for d in "$NAS" "$NAS/tmp" ${TEAM_DIR:+"$TEAM_DIR"}; do
            [ -d "$d" ] || continue
            setsid -w runuser -u "$ACC" -- test -w "$d" && echo "  $d: 쓸 수 있어요" || echo "  $d: 쓸 수 없어요"
        done
    else
        for d in "$NAS" "$NAS/tmp" ${TEAM_DIR:+"$TEAM_DIR"}; do [ -d "$d" ] && { [ -w "$d" ] && echo "  $d: 지금 계정은 쓸 수 있어요" || echo "  $d: 지금 계정은 쓸 수 없어요"; }; done
    fi

    if [ -n "$TEAM_DIR" ]; then
        head_ "우리 팀 폴더 ($TEAM_DIR)"
        if [ -L "$TEAM_DIR" ]; then bad "링크예요. 실제 폴더를 쓰세요: $(readlink "$TEAM_DIR")"
        elif [ -d "$TEAM_DIR" ]; then
            read -r uid gid mode <<< "$(stat -c '%u %g %a' "$TEAM_DIR")"
            echo "  주인 $(who_uid "$uid"), 그룹 $(grp_name "$gid"), 권한 $mode ($(who_writes "$mode"))"
            df -hP "$TEAM_DIR" | awk 'NR==2 {printf "  여기서 본 용량: 전체 %s, 쓴 것 %s, 남은 것 %s (할당량이 있으면 할당량이에요)\n", $2, $3, $4}'
            echo "  바로 아래:"; find "$TEAM_DIR" -mindepth 1 -maxdepth 1 -printf '    %f  (주인 uid %U, 권한 %m)\n' 2>/dev/null | sort | head -30
        else
            echo "  아직 없어요. 만들 수 있는지는 위 '쓸 수 있는 곳'을 보세요(docs/8_NAS.md 의 '처음 만들기')."
        fi
    fi

    echo
    echo "다음: 두 서버에서 모두 실행한 뒤, 이 화면(보고서 파일)으로 docs/8_NAS.md 의 '정해야 할 것'을 채워요."
}

# 보고서 둘 곳: root 는 /app/inbox/reports(root 만 고치고 공용 계정 FileZilla로 내려받을 수 있음),
# 그 밖에는 실행한 폴더(내 것일 때)나 홈. 남이 쓸 수 있는 폴더에는 쓰지 않는다(링크로 다른 파일을 덮게 만들 수 있다)
report_dir() {
    local ib=${GPU_INBOX:-/app/inbox}   # 시험할 때만 바꾼다
    if [ "$(id -u)" = 0 ] && [ -d "$ib" ] && [ ! -L "$ib" ] && [ "$(stat -c %U "$ib")" = root ]; then
        mkdir -p "$ib/reports" && [ ! -L "$ib/reports" ] && chmod 755 "$ib/reports" && echo "$ib/reports" && return
    fi
    if [ -O . ] && [ -w . ]; then echo "$PWD"; else echo "$HOME"; fi
}
# 공유용 사본(check_network.sh 와 같음): 서버 이름·IP·NAS 주소·계정·폴더 이름을 가려서 git 으로 올려도 되게 만든다.
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
RDIR=$(report_dir)
out=$(mktemp "$RDIR/nas_report_${ME}_$(date +%Y%m%d-%H%M)_XXXX.txt" 2>/dev/null) || out=$(mktemp)
body 2>&1 | tee >(sed 's/\x1b\[[0-9;]*m//g' > "$out")
sleep 1
chmod 644 "$out" 2>/dev/null   # 공용 계정(FileZilla)으로 내려받을 수 있게
# 공유용 사본: 서버 이름, 계정 이름, NAS 바로 아래 폴더 이름(다른 팀 이름일 수 있음)을 가린다
masks=("$(hostname -f 2>/dev/null)=$LABEL" "$ME=$LABEL")
[ -n "$ACC" ] && masks+=("$ACC=공용계정")
i=0; while IFS=: read -r n _ u _; do [ "$u" -ge 1000 ] && [ "$u" -lt 60000 ] && [ "$n" != "$ACC" ] && { i=$((i + 1)); masks+=("$n=계정$i"); }; done < <(getent passwd)
NASD=$(findmnt -rn -t nfs,nfs4,cifs,smb3,lustre,gpfs,beegfs -o TARGET 2>/dev/null | head -1); NASD=${GPU_NAS:-$NASD}
i=0; for d in "$NASD"/*/; do n=$(basename "$d"); case "$n" in tmp|data|home|'*') continue ;; esac; i=$((i + 1)); masks+=("$n=폴더$i"); done 2>/dev/null
for f in "$NASD"/tmp/.gpu_nas/*.txt; do h=$(sed -n 's/^HOST=//p' "$f" 2>/dev/null | head -1); [[ "$h" =~ ^[A-Za-z0-9._-]{2,64}$ ]] && [ "$h" != "$ME" ] && masks+=("$h=상대서버(…${h: -2})"); done 2>/dev/null
share="$RDIR/nas_공유용_${LABEL//[^A-Za-z0-9]/}_$(date +%Y%m%d-%H%M).txt"
share_copy "$out" "$share" "${masks[@]}"
echo; echo "보고서(원본, 사내 정보 있음): $(readlink -f "$out")"
echo "보고서(공유용, git 으로 올려도 돼요): $share"
echo "  공유용만 내려받아 저장소의 reports 폴더에 넣고 올리세요(docs/4_네트워크.md 의 \"결과 가져오기\")."
