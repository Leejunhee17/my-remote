#!/usr/bin/env bash
# 저장소 자동 시험. 임시 폴더에 가짜 /app, 가짜 docker·nvidia-smi 를 만들고 스크립트를 실제로 돌려 본다.
# 서버에서 돌리지 않는다(실제 /app 이 있으면 멈춘다). 이 저장소를 고친 뒤, 커밋하기 전에 돌린다.
#   bash tests/run.sh                 전체(root 가 아니면 root 가 필요한 시험은 건너뛴다)
#   bash tests/run.sh docs gpu       고른 묶음만: static docs installers gpu wrapper fetch reports hook pkgs system
#   GPU_TEST_SYSTEM=1 bash tests/run.sh system
#                                     prepare.sh 와 admin_setup.sh 를 진짜 /app 과 /etc 에 돌린다. 버리는 가상 머신(GitHub Actions)에서만
# 시험이 하나라도 실패하면 종료 코드가 1 이다.
set -uo pipefail
export LC_ALL=C.UTF-8
cd "$(dirname "$0")/.." || exit 1
R=$PWD
# root 로 돌릴 때 저장소 주인이 달라도 git 이 멈추지 않게(GitHub Actions 는 sudo 로 돌린다)
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=safe.directory GIT_CONFIG_VALUE_0='*'
G=$'\e[32m'; RD=$'\e[31m'; Y=$'\e[33m'; C=$'\e[36m'; Z=$'\e[0m'
PASS=0; FAIL=0; SKIP=0
ok()   { PASS=$((PASS + 1)); echo "  ${G}[통과]${Z} $1"; }
no()   { FAIL=$((FAIL + 1)); echo "  ${RD}[실패]${Z} $1"; [ -z "${2:-}" ] || printf '%s\n' "$2" | head -15 | sed 's/^/         /'; }
skip() { SKIP=$((SKIP + 1)); echo "  ${Y}[건너뜀]${Z} $1"; }
head_() { echo; echo "${C}== $1 ==${Z}"; }
is_root() { [ "$(id -u)" = 0 ]; }
# 조건이 참이면 통과: t "이름" 명령...   (실패하면 명령 출력을 보여 준다)
t() { local n=$1 out; shift; if out=$("$@" 2>&1); then ok "$n"; else no "$n" "$out"; fi; }
has()   { grep -qF -- "$2" "$1"; }   # 파일 $1 에 글자 $2 가 있다
lacks() { ! grep -qF -- "$2" "$1"; }

if [ -e /app ] && [ ! -e /app/.gpu_test_sandbox ]; then
    echo "멈춤: /app 이 있어요. 이 시험은 서버가 아닌 곳(접근 PC의 WSL, GitHub Actions 등)에서 돌려요."; exit 1
fi
T=$(mktemp -d); chmod 755 "$T"
trap 'rm -rf "$T"' EXIT
LOG=$T/out.txt

# ------------------------------------------------------------------ 가짜 nvidia-smi·docker
# GPU 8장. 5번의 UUID 는 GPU-bbbbbbbb-2222
mkdir -p "$T/fake" && chmod 777 "$T/fake"
cat > "$T/fake/nvidia-smi" <<'EOF'
#!/usr/bin/env bash
case "$*" in
    -L) for i in 0 1 2 3 4 5 6 7; do echo "GPU $i: ${FAKE_GPU_NAME:-NVIDIA H100 80GB HBM3} (UUID: GPU-$i)"; done ;;
    --query-gpu=name\ *) for i in 0 1 2 3 4 5 6 7; do echo "${FAKE_GPU_NAME:-NVIDIA H100 80GB HBM3}"; done ;;
    --query-gpu=driver_version\ *) for i in 0 1 2 3 4 5 6 7; do echo 595.58.03; done ;;
    --query-gpu=persistence_mode\ *) for i in 0 1 2 3 4 5 6 7; do echo Enabled; done ;;
    'topo -m')   # NVLink 브리지 4장씩 두 묶음(H200 NVL 모양)
        printf '\tGPU0\tGPU1\tGPU2\tGPU3\tGPU4\tGPU5\tGPU6\tGPU7\tNIC0\tCPU Affinity\n'
        for i in 0 1 2 3 4 5 6 7; do printf 'GPU%s' $i; for j in 0 1 2 3 4 5 6 7; do
            if [ $i = $j ]; then printf '\t X '; elif [ $((i / 4)) = $((j / 4)) ]; then printf '\tNV18'; else printf '\tSYS'; fi; done; printf '\tSYS\t0-55\n'; done
        printf 'NIC0\tSYS\n\nLegend:\n  NV#  = Connection traversing a bonded set of # NVLinks\n' ;;
    *index,uuid*) for i in 0 1 2 3 4 6 7; do echo "$i, GPU-0000000$i-1111"; done; echo "5, GPU-bbbbbbbb-2222" ;;
    *index,memory.used,memory.total,utilization.gpu*) for i in 0 1 2 3 4 5 6 7; do echo "$i, 0, 143000, 0"; done ;;
    *index,utilization.gpu,memory.used*) for i in 0 1 2 3 4 5 6 7; do echo "$i, 0, 0"; done ;;
    *) ;;
esac
EOF
# 컨테이너 목록은 $FAKE_DIR/inspect(이미 docker inspect 모양으로 적은 줄), 그 밖의 호출은 args.log 에 남긴다
cat > "$T/fake/docker" <<'EOF'
#!/usr/bin/env bash
D=${FAKE_DIR:?}
case "${1:-}" in
    version) echo 27.0 ;;
    ps)      [ -f "$D/inspect" ] && awk -F'\t' '{print $NF}' "$D/inspect" ;;
    inspect) [ -f "$D/inspect" ] && cat "$D/inspect" ;;
    images)  [ -f "$D/images" ] && cat "$D/images" ;;
    info)    echo "  Docker 27.0" ;;
    *)       printf '%q ' "$@" >> "$D/args.log"; echo >> "$D/args.log" ;;
esac
EOF
chmod 755 "$T/fake/nvidia-smi" "$T/fake/docker"

# ================================================================== 1. 문법·형식
t_static() {
    head_ '문법·형식'
    local f bad=
    for f in server/*.sh server/bin/* .githooks/pre-commit tests/*.sh; do bash -n "$f" 2>>"$LOG" || bad+=" $f"; done
    [ -z "$bad" ] && ok 'bash 문법(bash -n)' || no "bash 문법:$bad" "$(cat "$LOG")"
    if command -v shellcheck >/dev/null; then
        t 'shellcheck(오류 수준)' shellcheck -S error server/*.sh server/bin/* .githooks/pre-commit tests/*.sh
    else skip 'shellcheck 가 없어요'; fi
    bad=; for f in pc/*.py; do python3 -I -c 'import ast,sys; ast.parse(open(sys.argv[1], encoding="utf-8").read())' "$f" 2>>"$LOG" || bad+=" $f"; done
    [ -z "$bad" ] && ok 'Python 문법' || no "Python 문법:$bad"
    if command -v pwsh >/dev/null; then
        local out; out=$(pwsh -NoProfile -Command '$bad=0; foreach ($f in Get-ChildItem pc/*.ps1) { $e=$null; [void][Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$e); foreach ($x in $e) { $bad++; "$($f.Name):$($x.Extent.StartLineNumber): $($x.Message)" } }; exit $bad' 2>&1)
        [ $? = 0 ] && ok 'PowerShell 문법(pwsh)' || no 'PowerShell 문법' "$out"
    else skip 'PowerShell 문법: pwsh 가 없어요(GitHub Actions 에서는 돌아요)'; fi
    # .ps1: Windows PowerShell 5.1 이 한글을 읽으려면 BOM 이 있어야 한다. 줄 끝은 받을 때 CRLF(.gitattributes)
    bad=; for f in pc/*.ps1; do [ "$(head -c3 "$f" | od -An -tx1 | tr -d ' ')" = efbbbf ] || bad+=" $f"; done
    [ -z "$bad" ] && ok '.ps1 은 모두 UTF-8 BOM' || no ".ps1 BOM 없음:$bad"
    # PowerShell 은 한글도 변수 이름으로 읽는다: "$n번째" 는 $n 이 아니라 $n번째. "$($n)번째" 로 써야 한다
    bad=$(grep -nP '(?<!`)\$[A-Za-z_][A-Za-z0-9_]*[가-힣]' pc/*.ps1)
    [ -z "$bad" ] && ok '.ps1 에 한글이 붙은 변수가 없어요("$($n)번째" 처럼 써요)' || no '.ps1 에 한글이 붙은 변수' "$bad"
    bad=$(git ls-files --eol -- '*.ps1' '*.sh' 'server/bin/*' | awk '($NF ~ /\.ps1$/ && $0 !~ /eol=crlf/) || ($NF !~ /\.ps1$/ && $0 !~ /eol=lf/) || $1 != "i/lf"')
    [ -z "$bad" ] && ok '줄 끝 설정(.ps1 CRLF, .sh LF, 저장소 안은 LF)' || no '줄 끝 설정' "$bad"
    bad=$(git ls-files | grep -E '_report_|__pycache__|\.pyc$|(^|/)지문_기록\.txt$|(^|/)\.env(\.[^/]*)?$' | grep -vE '(^|/)\.env\.example$')
    [ -z "$bad" ] && ok '올리면 안 되는 파일이 없어요(원본 보고서, pyc, 지문 기록, .env)' || no '올리면 안 되는 파일' "$bad"
    bad=$(grep -nE '^[A-Za-z_][A-Za-z0-9_]*=.+' .env.example | grep -vE '^[0-9]+:GPU_RUN=')
    [ -z "$bad" ] && ok '.env.example 에는 값이 비어 있어요(GPU_RUN 만 기본값)' || no '.env.example 에 값이 들어 있어요' "$bad"
    if command -v pwsh >/dev/null; then
        # .env 읽기: 주석·빈 값·따옴표·뒤 # 설명·export·이상한 줄, 그리고 이미 정한 환경 변수가 이긴다
        printf '# 설명\r\nGPU_T1=a b\r\nexport GPU_T2 = "x # y"\r\nGPU_T3=v # 설명\r\nGPU_T4=\r\n이상한 줄\r\nGPU_T5=env\r\n' > "$T/dotenv"
        out=$(GPU_T5=mine pwsh -NoProfile -Command ". ./pc/gpu_common.ps1; Import-DotEnv '$T/dotenv'; '[{0}][{1}][{2}][{3}][{4}]' -f \$env:GPU_T1, \$env:GPU_T2, \$env:GPU_T3, \$env:GPU_T4, \$env:GPU_T5" 2>&1)
        case "$out" in *'[a b][x # y][v][][mine]'*) ok '.env 읽기(pwsh)' ;; *) no '.env 읽기(pwsh)' "$out" ;; esac
        case "$out" in *'6번째 줄을 읽지 못했어요'*) ok '.env 의 이상한 줄은 몇 번째인지 알려 줘요' ;; *) no '.env 의 이상한 줄 알림' "$out" ;; esac
        if grep -qx '  .env 에서 읽은 설정: GPU_T1, GPU_T2, GPU_T3' <<< "$out"; then ok '.env 는 이름만 보여 주고 값은 안 보여 줘요'; else no '.env 이름만 보여 주기' "$out"; fi
    else skip '.env 읽기: pwsh 가 없어요(GitHub Actions 에서는 돌아요)'; fi
    if command -v pwsh >/dev/null; then
        # 점검 결과(reports\)에 쓰는 가리기: 주소 뒤 서명, 사내 IP, AWS 키, HF 토큰. 프록시는 종류·포트만. 예시 IP 는 실행할 때 만든다
        local ip="10.$((1+1)).3.4" key="AKIA$(printf 'A%.0s' {1..16})" tk="hf_$(printf 'b%.0s' {1..34})"
        out=$(pwsh -NoProfile -Command ". ./pc/gpu_common.ps1; Hide-Text 'get https://s3.example/a?X-Amz-Signature=abc from $ip key $key tok $tk'; Proxy-Label 'http://proxy.example:8080'" 2>&1)
        case "$out" in *'get https://s3.example/a?… from (사내 IP) key (키) tok (토큰)'*'있음(http, 포트 8080)'*) ok '점검 결과 가리기(pwsh)' ;; *) no '점검 결과 가리기(pwsh)' "$out" ;; esac
    else skip '점검 결과 가리기: pwsh 가 없어요(GitHub Actions 에서는 돌아요)'; fi
    # 사내 IP(사설 대역)는 저장소에 없어야 한다. 이 시험 파일의 예시 IP 는 실행할 때 만든다
    bad=$(git grep -nIE '(^|[^0-9.])(10\.[0-9]{1,3}|192\.168|172\.(1[6-9]|2[0-9]|3[01]))\.[0-9]{1,3}\.[0-9]{1,3}([^0-9]|$)' -- . ':!*.xlsx' | grep -v 'check.sh send 10\.0\.0\.2')
    [ -z "$bad" ] && ok '사설 IP가 없어요' || no '사설 IP가 있어요' "$bad"
}

# ================================================================== 2. 문서와 코드가 맞는지
t_docs() {
    head_ '문서와 코드'
    local f n bad=
    for f in README.md docs/*.md team/*.md reports/*.md; do
        n=$(grep -c '^[[:space:]]*```' "$f"); [ $((n % 2)) = 0 ] || bad+=" $f($n)"
    done
    [ -z "$bad" ] && ok '코드 블록(```) 짝이 맞아요' || no "코드 블록 짝이 안 맞아요:$bad"
    # 문서에 나온 스크립트 이름이 저장소에 있다(예시로 쓴 이름은 뺀다)
    bad=; for n in $(grep -rhoE '[A-Za-z0-9_]+\.(sh|ps1|py)\b' README.md docs team | sort -u); do
        case "$n" in gpu.sh|gpu-docker.sh|catalog.py|train.py|json.py|download_freiburg_forest_*.sh) continue ;; esac   # 예시 이름, 데이터셋 사이트의 스크립트
        [ -n "$(find server pc tests -name "$n" -print -quit)" ] || bad+=" $n"
    done
    [ -z "$bad" ] && ok '문서에 나온 스크립트가 모두 있어요' || no "없는 스크립트:$bad"
    # docs/… 를 가리키는 곳(문서·스크립트)이 실제 파일이고, 같이 적은 "절 이름" 이 그 파일의 제목에 있다. 점검 보고서(reports/*.txt)는 그때 화면 그대로라 뺀다
    bad=$(git grep -hoIE 'docs[/\\][0-9]_[^ )`"'"'"'\\]+\.md( 의 \\?"[^"\\]+\\?")?' -- . ':!tests' ':!reports/*.txt' | sed 's/\\"/"/g' | sort -u | while IFS= read -r ref; do
        f=${ref%%.md*}.md; f=${f//\\//}
        [ -f "$f" ] || { echo "없는 문서: $ref"; continue; }
        case "$ref" in *'"'*) s=${ref#*\"}; s=${s%\"}; grep -E '^#+ ' "$f" | tr -d '`' | grep -qF -- "$s" || echo "제목 없음: $ref" ;; esac
    done)
    [ -z "$bad" ] && ok '문서 이름과 절 이름이 모두 있어요' || no '가리키는 문서·절이 없어요' "$bad"
    # 문제 해결 표에 적은 화면 메시지가 스크립트에 실제로 있다(… 는 바뀌는 부분, '습니다' 는 Windows 메시지)
    bad=$(grep -oP '^\| `\K[^`]+' docs/7_문제_해결.md | while IFS= read -r m; do
        case "$m" in *습니다*) continue ;; esac
        IFS='…' read -ra parts <<< "$m"
        for p in "${parts[@]}"; do p=$(echo "$p" | sed 's/^ *//; s/ *$//'); [ ${#p} -ge 3 ] || continue
            grep -rqF -- "$p" server pc || echo "$m  (못 찾은 부분: $p)"; done
    done)
    [ -z "$bad" ] && ok '문제 해결 표의 메시지가 스크립트에 있어요' || no '문제 해결 표의 메시지가 스크립트에 없어요' "$bad"
    # check.sh 가 찾는 패키지와 docs/1 의 "서버 기초 프로그램" 명령이 같다(빠진 것을 할 일 목록에 적어 주므로)
    local want doc; want=$(sed -n '/local NEED=(/,/local miss/p' server/check.sh | grep -oE '[a-z0-9_.-]+:[a-z0-9.+-]+' | cut -d: -f2 | grep -vxE 'bash|tar|coreutils|sed|grep|util-linux|bsdutils' | sort -u)
    doc=$(sed -n '/^apt install -y/,/^```/p' docs/1_처음_설치.md | tr -s ' \\\n' '\n' | grep -vE '^(apt|install|-y|```)$' | sort -u)
    bad=$(comm -3 <(echo "$want") <(echo "$doc"))
    [ -n "$want" ] && [ -z "$bad" ] && ok '점검 스크립트와 문서의 서버 패키지 목록이 같아요' || no '점검 스크립트와 문서의 서버 패키지 목록이 달라요(왼쪽: 스크립트만, 오른쪽: 문서만)' "$bad"
    # 기초 프로그램 묶음(pkgs_pack.ps1)에 넣는 패키지도 문서 목록과 같다
    want=$(sed -n '/^\$Pkgs = @(/,/^)/p' pc/pkgs_pack.ps1 | grep -oE "'[^']+'" | tr -d "'" | sort -u)
    bad=$(comm -3 <(echo "$want") <(echo "$doc"))
    [ -n "$want" ] && [ -z "$bad" ] && ok '기초 프로그램 묶음과 문서의 패키지 목록이 같아요' || no '기초 프로그램 묶음과 문서의 패키지 목록이 달라요(왼쪽: pkgs_pack.ps1 만, 오른쪽: 문서만)' "$bad"
    # README 의 폴더 표에 있는 경로가 있다
    bad=$(grep -oP '^\| `\K[^`]+(?=`)' README.md | while read -r p; do [ -e "${p%/}" ] || echo "$p"; done)
    [ -z "$bad" ] && ok 'README 폴더 표의 경로가 모두 있어요' || no 'README 폴더 표에 없는 경로' "$bad"
}

# ================================================================== 3. 데이터셋·모델 넣기(사용자가 공용 계정으로)
mk_datasets() {   # $1 폴더(NAS inbox 의 datasets 처럼). 압축 1개 + wildscenes 파일 2개와 맞는 체크섬 목록
    local d=$1; mkdir -p "$d/goose" "$d/wildscenes/a"
    ( cd "$d" && echo z > z.txt && zip -q goose/g.zip z.txt && rm z.txt
      echo hi > wildscenes/a/1.png; echo yo > wildscenes/2.png
      sha256sum goose/g.zip wildscenes/a/1.png wildscenes/2.png > MANIFEST.sha256
      echo 'files=2 bytes=6' > wildscenes.ok )
    cp server/datasets_unpack.sh "$d/"
}
# 올린 그 자리(NAS inbox 의 datasets)에서 바로 실행한다. 시험은 root 로 돌 수 있어서 root 막기를 끈다
DSRC=$T/nas/inbox/datasets
run_ds() { mkdir -p "$T/nas/datasets"; GPU_TEST_ROOT_OK=1 GPU_APP=$T/no-app GPU_NAS_DIR=$T/nas bash "$DSRC/datasets_unpack.sh" > "$LOG" 2>&1; }
fresh_ds() { rm -rf "$T/nas"; mk_datasets "$DSRC"; }
t_installers() {
    head_ '데이터셋·모델 넣기'
    local N=$T/nas/datasets
    fresh_ds
    run_ds; t '데이터셋: 정상으로 풀어요' bash -c 'grep -q "다 풀었어요" "$1" && [ -f "$2/goose/z.txt" ]' _ "$LOG" "$N"
    t '데이터셋: wildscenes 는 목록의 파일을 그 자리에 옮겨요' test -f "$N/wildscenes/a/1.png" -a -f "$N/wildscenes/2.png"
    t '데이터셋: 기록 파일은 올린 곳에 남겨요' bash -c 'ls "$1"/datasets_unpack_*.log >/dev/null' _ "$DSRC"
    run_ds; t '데이터셋: 다시 실행하면 푼 것은 건너뛰어요(옮긴 파일이 올린 곳에 없어도)' bash -c 'grep -q "이미 풀었어요" "$1" && grep -q "다 풀었어요" "$1"' _ "$LOG"
    fresh_ds; echo bad > "$DSRC/wildscenes/2.png"
    run_ds; t '데이터셋: 깨진 파일은 체크섬으로 잡고 넣지 않아요' bash -c 'grep -q "wildscenes/2.png: 체크섬이 맞지 않아요" "$1" && [ ! -e "$2/wildscenes/2.png" ]' _ "$LOG" "$N"
    fresh_ds; : > "$DSRC/MANIFEST.sha256"
    run_ds; t '데이터셋: 빈 체크섬 목록이면 멈춰요' has "$LOG" '비었거나 모양이 이상해요'
    fresh_ds; echo 'garbage' >> "$DSRC/MANIFEST.sha256"
    run_ds; t '데이터셋: 모양이 다른 줄이 있으면 멈춰요' has "$LOG" '비었거나 모양이 이상해요'
    fresh_ds; grep -v wildscenes "$DSRC/MANIFEST.sha256" > "$DSRC/m" && mv "$DSRC/m" "$DSRC/MANIFEST.sha256"
    run_ds; t '데이터셋: 예전 목록(wildscenes 체크섬 없음)이면 멈춰요' has "$LOG" '체크섬 목록에 wildscenes 파일이 없어요'
    fresh_ds; rm "$DSRC/goose/g.zip"
    run_ds; t '데이터셋: 빠진 파일은 먼저 알려 주고 멈춰요' has "$LOG" '없는 파일: goose/g.zip'
    # 넣을 곳에 원래 있던 폴더: 이름이 다르면 그대로 두고, 같은 이름인데 스크립트가 넣은 것이 아니면 건너뛴다
    fresh_ds; mkdir -p "$N/other" "$N/goose"; echo k > "$N/other/keep"; echo k > "$N/goose/keep"
    run_ds
    t '데이터셋: 같은 이름의 남의 폴더는 덮어쓰지 않고 알려요' bash -c 'grep -q "goose 가 이미 있는데 이 스크립트가 넣은 폴더가 아니에요" "$1" && [ -f "$2/goose/keep" ] && [ ! -e "$2/goose/z.txt" ]' _ "$LOG" "$N"
    t '데이터셋: 원래 있던 다른 폴더는 그대로 둬요' test -f "$N/other/keep" -a -f "$N/wildscenes/2.png"

    # 나눠 올리기: 폴더째 안 올린 데이터셋은 건너뛰고, 폴더 안의 압축은 그 폴더에 풀고, 압축이 아닌 파일은 경로대로 둔다
    fresh_ds
    ( cd "$DSRC" && mkdir -p ORAD-3D/training_zip rellis_full && echo s > s.txt && zip -q ORAD-3D/training_zip/seq1.zip s.txt && rm s.txt
      echo bag > rellis_full/rosbag_00000_synced.bag
      sha256sum ORAD-3D/training_zip/seq1.zip rellis_full/rosbag_00000_synced.bag >> MANIFEST.sha256
      echo "0000000000000000000000000000000000000000000000000000000000000000  CaSSeD/CaSSeD.tar.gz" >> MANIFEST.sha256
      rm -rf goose )
    run_ds
    t '데이터셋: 안 올린 데이터셋(goose·CaSSeD)은 건너뛰어요' bash -c 'grep -q "이번에 올리지 않은 데이터셋(건너뛰어요): CaSSeD goose" "$1" && ! [ -e "$2/goose" ]' _ "$LOG" "$N"
    t '데이터셋: 폴더 안의 압축은 그 폴더에 풀어요' test -f "$N/ORAD-3D/training_zip/s.txt"
    t '데이터셋: 압축이 아닌 파일(rosbag)은 같은 경로에 둬요' test -f "$N/rellis_full/rosbag_00000_synced.bag"
    # 넣을 곳(NAS 의 datasets)이 없으면 관리자에게 알리라고 멈춘다
    fresh_ds; GPU_TEST_ROOT_OK=1 GPU_APP=$T/no-app GPU_NAS_DIR=$T/nas bash "$DSRC/datasets_unpack.sh" > "$LOG" 2>&1
    t '데이터셋: 넣을 곳이 없으면 관리자에게 알리라고 멈춰요' has "$LOG" '관리자에게 NAS 팀 폴더를 준비해 달라고'
    if is_root; then
        fresh_ds; mkdir -p "$N"
        GPU_APP=$T/no-app GPU_NAS_DIR=$T/nas bash "$DSRC/datasets_unpack.sh" > "$LOG" 2>&1
        t '데이터셋: root 로 실행하면 공용 계정으로 하라고 멈춰요' bash -c 'grep -q "root 말고 공용 계정으로 실행하세요" "$1" && [ ! -e "$2/goose" ]' _ "$LOG" "$N"
    else skip '데이터셋 root 막기: root 가 아니라서 건너뛰어요'; fi

    # 모델: 올린 자리에서 실행한다. 목록에 있는 파일만 확인해서 옮기고, 올린 폴더의 json.py 같은 파일을 모듈로 읽지 않는다
    local MSRC=$T/nas/inbox/models MD=$T/nas/models
    mk_models() {
        rm -rf "$T/nas"; mkdir -p "$MSRC/org__m" "$MD"
        ( cd "$MSRC" && echo '{"a":1}' > org__m/config.json && echo '{"repo":"org/m","license":"mit"}' > org__m/gpu_model.json
          python3 -I -c "
import zipfile
with zipfile.ZipFile('org__m/code.zip','w') as z:
    z.writestr('top/ok/a.py','x'); z.writestr('top//$T/inst/escaped','x'); z.writestr('top/../../escaped2','x')"
          sha256sum org__m/config.json org__m/code.zip > MANIFEST.sha256
          for m in json os zipfile struct sys; do echo "open('$T/inst/PWNED','w')" > $m.py; done )
        cp server/models_place.sh "$MSRC/"
    }
    run_mp() { GPU_TEST_ROOT_OK=1 GPU_APP=$T/no-app GPU_NAS_DIR=$T/nas bash "$MSRC/models_place.sh" > "$LOG" 2>&1; }
    mkdir -p "$T/inst"; mk_models
    run_mp
    t '모델: 정상으로 넣어요' bash -c 'grep -q "이번에 올린 모델 1개가 모두 정상" "$1" && [ -f "$2/org/m/config.json" ] && [ -f "$2/org/m/gpu_model.json" ]' _ "$LOG" "$MD"
    t '모델: 지금 폴더의 json.py 등을 모듈로 읽지 않아요(python -I)' test ! -e "$T/inst/PWNED"
    t '모델: 코드 묶음을 풀어요' test -f "$MD/org/m/code/ok/a.py"
    t '모델: 코드 묶음이 폴더 밖에 쓰지 않아요' test ! -e "$T/inst/escaped" -a ! -e "$T/escaped2" -a ! -e "$MD/escaped2"
    run_mp; t '모델: 다시 실행하면 넣은 모델은 건너뛰어요(옮긴 파일이 올린 곳에 없어도)' bash -c 'grep -q "org/m: 이미 있어요" "$1" && grep -q "모두 정상" "$1"' _ "$LOG"
    # 나눠 올리기: 목록에는 있지만 이번에 폴더째 안 올린 모델은 건너뛰고, 올린 모델만 넣는다
    mk_models
    echo "0000000000000000000000000000000000000000000000000000000000000000  org__absent/model.safetensors" >> "$MSRC/MANIFEST.sha256"
    run_mp
    t '모델: 안 올린 모델 폴더는 건너뛰어요' bash -c 'grep -q "이번에 올리지 않은 모델(건너뛰어요): org/absent" "$1" && grep -q "이번에 올린 모델 1개가 모두 정상" "$1" && [ -f "$2/org/m/config.json" ]' _ "$LOG" "$MD"
    # 같은 이름의 남의 폴더(gpu_model.json 없음)는 덮어쓰지 않는다. 다른 폴더는 그대로 둔다
    mk_models; mkdir -p "$MD/org/m" "$MD/mine"; echo k > "$MD/org/m/keep"; echo k > "$MD/mine/keep"
    run_mp
    t '모델: 같은 이름의 남의 폴더는 덮어쓰지 않고 알려요' bash -c 'grep -q "org/m 가 이미 있는데 이 스크립트가 넣은 폴더가 아니에요" "$1" && [ -f "$2/org/m/keep" ] && [ ! -e "$2/org/m/config.json" ] && [ -f "$2/mine/keep" ]' _ "$LOG" "$MD"
    # 깨진 파일과 이상한 gpu_model.json
    mk_models; echo '{"a":2}' > "$MSRC/org__m/config.json"
    run_mp; t '모델: 깨진 파일은 체크섬으로 잡고 "넣은 모델" 로 치지 않아요' bash -c 'grep -q "config.json: 체크섬이 맞지 않아요" "$1" && [ ! -e "$2/org/m/gpu_model.json" ]' _ "$LOG" "$MD"
    echo '{"a":1}' > "$MSRC/org__m/config.json"
    run_mp; t '모델: 깨진 파일만 다시 올리면 마저 넣어요' bash -c 'grep -q "모두 정상" "$1" && [ -f "$2/org/m/gpu_model.json" ]' _ "$LOG" "$MD"
    mk_models; echo '{"repo":"other/x"}' > "$MSRC/org__m/gpu_model.json"
    run_mp; t '모델: gpu_model.json 의 모델 이름이 폴더와 다르면 넣지 않아요' has "$LOG" 'gpu_model.json 이 이상해요'
    if is_root; then
        mk_models; GPU_APP=$T/no-app GPU_NAS_DIR=$T/nas bash "$MSRC/models_place.sh" > "$LOG" 2>&1
        t '모델: root 로 실행하면 공용 계정으로 하라고 멈춰요' bash -c 'grep -q "root 말고 공용 계정으로 실행하세요" "$1" && [ ! -e "$2/org" ]' _ "$LOG" "$MD"
    else skip '모델 root 막기: root 가 아니라서 건너뛰어요'; fi
}

# ================================================================== 4. gpu (정기 점검·현황·보고서)
APPT=$T/app
setup_app() {   # 가짜 /app. gpu 는 root 로 돌 때 자기 파일이 root 소유여야 한다
    rm -rf "$APPT"; mkdir -p "$APPT"/admin/bin "$APPT"/autonomy_sw/{hong,kim} "$APPT"/state/{gpu_log,notice,reports,images,notice_seen,tty} "$APPT"/inbox
    install -m 755 server/bin/gpu server/bin/docker server/bin/nvidia-smi "$APPT/admin/bin/"
    printf '홍길동 인지\nhong 인지\nkim 판단\n관리자 인지\n' > "$APPT/admin/team.txt"
    printf '# 시험\n  # 들여쓴 주석\n0 다른팀\n1 다른팀\n2 다른팀\n3 다른팀\n4 인지\n5 판단\n6 공용\n7 공용\n' > "$APPT/admin/gpu_alloc.txt"
    : > "$APPT/state/images/loaded.tsv"
    rm -f "$T/fake/inspect" "$T/fake/images" "$T/fake/args.log"
}
# 컨테이너 한 줄: pid 이름 이름표(사람) GPU요청 이미지 이름표(GPU) ID  (gpu 가 docker inspect 로 받는 모양)
ctr() { printf '%s\t%s\t"%s"\t%s\t"%s"\t"%s"\t%s\n' "$@" >> "$T/fake/inspect"; }
gpu() { env GPU_APP="$APPT" GPU_DOCKER="$T/fake/docker" GPU_NVSMI="$T/fake/nvidia-smi" GPU_ACCOUNT=nobody FAKE_DIR="$T/fake" "$APPT/admin/bin/gpu" "$@"; }
t_gpu() {
    head_ 'gpu (현황·정기 점검·보고서)'
    is_root || { skip 'root 가 아니라서 건너뛰어요(gpu 정기 점검은 root 로 돌아요)'; return; }
    setup_app
    printf 'MAX_GPUS=6\nIDLE_HOURS=$(touch %s/PWNED1)\ntouch %s/PWNED2\nNAS_DIR=/data/team\n' "$T" "$T" > "$APPT/admin/gpu.conf"
    ctr 101 hong-seg hong 4 'hong/seg:v1' '' aaa1
    ctr 102 fake-admin 관리자 6 'x:1' '' aaa2
    ctr 103 uuid-run kim GPU-bbbbbbbb-2222 'kim/y:1' '' aaa3
    gpu _check > "$LOG" 2>&1
    t '알림 설정(gpu.conf)의 명령을 실행하지 않아요' test ! -e "$T/PWNED1" -a ! -e "$T/PWNED2"
    t '처음 점검에서 이미지 사용 기록(images_used.tsv)을 만들어요' grep -q "hong/seg:v1" "$APPT/state/gpu_log/images_used.tsv"
    gpu who > "$LOG" 2>&1
    t 'GPU 현황 표가 나와요' has "$LOG" 'GPU별 사용자'
    t '이름표 "관리자" 는 사람 이름으로 쓰지 않아요' grep -qE '^6 .*\?\(이름 없음\)' <(sed 's/\x1b\[[0-9;]*m//g' "$LOG")
    t 'GPU-<uuid> 로 고른 컨테이너도 그 GPU 번호에 보여요' grep -qE '^5 .*kim.*uuid-run' <(sed 's/\x1b\[[0-9;]*m//g' "$LOG")
    t '들여쓴 주석 줄을 GPU 배분으로 읽지 않아요(mawk)' lacks "$LOG" '들여쓴'
    gpu _names > "$LOG" 2>&1; t '팀원 이름 목록에 "관리자" 가 없어요(이름표로 관리자 알림을 꾸미지 못하게)' lacks "$LOG" 관리자
    ln -s / "$APPT/autonomy_sw/zz-link"
    if timeout 60 env GPU_APP="$APPT" GPU_DOCKER="$T/fake/docker" GPU_NVSMI="$T/fake/nvidia-smi" GPU_ACCOUNT=nobody FAKE_DIR="$T/fake" "$APPT/admin/bin/gpu" _report > "$LOG" 2>&1; then
        t '주간 보고서가 나와요' has "$LOG" '== 디스크'
    else no '주간 보고서가 60초 안에 끝나지 않아요(작업 폴더의 링크를 따라갔을 수 있어요)'; fi
    rm -f "$APPT/autonomy_sw/zz-link"
}

# ================================================================== 5. docker 래퍼(팀원 = 공용 계정으로)
t_wrapper() {
    head_ 'docker 래퍼'
    is_root || { skip 'root 가 아니라서 건너뛰어요(공용 계정 대신 nobody 로 돌려 봐요)'; return; }
    setup_app
    local dk=(runuser -u nobody -- env GPU_APP="$APPT" GPU_DOCKER="$T/fake/docker" GPU_NVSMI="$T/fake/nvidia-smi" FAKE_DIR="$T/fake" GPU_USER=hong "$APPT/admin/bin/docker")
    "${dk[@]}" run --gpus '"device=4"' hong/seg:v1 > "$LOG" 2>&1 < /dev/null
    t 'run 에 이름표(사람·GPU)를 붙여요' grep -q 'gpu.USER=hong.*gpu.GPUS=4\|gpu.GPUS=4.*gpu.USER=hong' "$T/fake/args.log"
    : > "$T/fake/args.log"
    "${dk[@]}" run --gpus '"device=GPU-bbbbbbbb-2222"' hong/seg:v1 > "$LOG" 2>&1 < /dev/null
    t 'GPU-<uuid> 로 골라도 번호 이름표(gpu.GPUS=5)를 붙여요' grep -q 'gpu.GPUS=5' "$T/fake/args.log"
    "${dk[@]}" run --gpus '"device=0"' hong/seg:v1 > "$LOG" 2>&1 < /dev/null
    t '다른 팀 GPU를 고르면 경고해요' has "$LOG" '다른 팀'
    "${dk[@]}" run --gpus all hong/seg:v1 > "$LOG" 2>&1 < /dev/null
    t '--gpus all 이면 경고해요' has "$LOG" '--gpus all'
}

# ================================================================== 6. gpu fetch (올린 설치 묶음 들여오기)
t_fetch() {
    head_ 'gpu fetch'
    is_root || { skip 'root 가 아니라서 건너뛰어요(fetch 는 root 전용)'; return; }
    setup_app; chmod 755 "$APPT/inbox"
    local FN=$T/fnas; rm -rf "$FN"; mkdir -p "$FN/inbox"; echo "NAS_DIR=$FN" > "$APPT/admin/gpu.conf"
    echo x > "$FN/inbox/other.txt"; echo t > "$FN/inbox/gpu-pkgs.tar"
    gpu fetch gpu-pkgs.tar > "$LOG" 2>&1
    t '설치 묶음(.tar)은 NAS inbox 에서 통째로 복사하고 지문을 보여 줘요' bash -c 'grep -q "지문(sha256): $(sha256sum "$3/inbox/gpu-pkgs.tar" | cut -d" " -f1)" "$1" && cmp -s "$2/gpu-pkgs.tar" "$3/inbox/gpu-pkgs.tar"' _ "$LOG" "$APPT/inbox" "$FN"
    t '지문을 보는 줄과 실행 줄이 따로예요(&& 로 잇지 않아요)' bash -c '! grep -q "지문(sha256).*&&" "$1"' _ "$LOG"
    t 'NAS inbox 의 다른 파일은 건드리지 않아요' test -f "$FN/inbox/other.txt" -a -f "$FN/inbox/gpu-pkgs.tar"
    rm "$FN/inbox/gpu-pkgs.tar"; ln -s /etc/passwd "$FN/inbox/gpu-pkgs.tar"
    gpu fetch gpu-pkgs.tar > "$LOG" 2>&1
    t '묶음이 링크면 복사하지 않고 멈춰요' bash -c 'grep -q "멈춤" "$1" && [ ! -e "$2/gpu-pkgs.tar" ]' _ "$LOG" "$APPT/inbox"
    mkdir -p "$FN/inbox/datasets"
    gpu fetch datasets > "$LOG" 2>&1
    t '데이터셋은 공용 계정으로 넣으라고 알려요' has "$LOG" '공용 계정으로 넣어요'
}

# ================================================================== 7. 점검(check.sh)과 공유용 보고서(사내 정보 가리기)
t_reports() {
    head_ '점검과 공유용 보고서'
    local rep=$T/rep host share; host=$(hostname -s)
    mkdir -p "$rep/run" "$rep/run2" "$rep/nas/tmp" "$rep/nas/teamA"; chmod 755 "$rep"; chmod 1777 "$rep/nas/tmp"
    cp server/check.sh "$rep/check.sh"; chmod 755 "$rep/check.sh"
    # root 로 돌리면 보고서를 공용 계정(여기서는 nobody) 홈에 공용 계정 권한으로 넣는다
    if is_root; then
        chown nobody "$rep/run" "$rep/run2"
        mkdir -p "$rep/home" "$rep/home2"; chown nobody "$rep/home" "$rep/home2"
        (cd "$rep" && timeout 60 env GPU_NAS="$rep/nas" GPU_ACCOUNT=nobody GPU_ACC_HOME="$rep/home" QUICK=1 bash "$rep/check.sh") > "$LOG" 2>&1 < /dev/null
        t 'root: 보고서 두 개를 공용 계정 홈에 공용 계정 소유로 넣어요' test "$(stat -c %U "$rep"/home/check_* 2>/dev/null | grep -cx nobody)" = 2
        t 'root: 공용 계정이 쓸 수 있는 곳을 공용 계정 권한으로 봐요' has "$LOG" "$rep/nas/tmp: 쓸 수 있어요"
        t 'root: root squash 를 봐요' has "$LOG" 'no_root_squash'
        (cd "$rep" && timeout 60 env GPU_NAS="$rep/nas" GPU_ACC_HOME="$rep/home" QUICK=1 bash "$rep/check.sh") > "$LOG" 2>&1 < /dev/null
        [ -e /etc/gpu/account ] && skip 'root: 공용 계정 이름 없이(이 컴퓨터에 /etc/gpu/account 가 있어요)' ||
            t 'root: 공용 계정 이름을 모르면 GPU_ACCOUNT 로 다시 하라고 해요' has "$LOG" 'GPU_ACCOUNT=<계정이름>'
        (cd "$rep" && timeout 30 bash "$rep/check.sh" disk "$rep/run") > "$LOG" 2>&1 < /dev/null
        t 'root: 다른 계정이 쓰는 폴더는 속도를 재지 않아요' has "$LOG" 'root로 실행하면 다른 계정이 쓰는 폴더는 측정하지 않아요'
        # 서버 폴더·권한: /app 아래 다른 계정 것과 링크를 알려 주고, 공유용 사본에서는 폴더 이름을 가린다
        mkdir -p "$rep/app/autonomy_sw" "$rep/app/teamB" "$rep/home3"; chown nobody "$rep/app/autonomy_sw" "$rep/home3"; chown 1234 "$rep/app/teamB"; ln -s /etc "$rep/app/odd"
        (cd "$rep" && timeout 60 env APP="$rep/app" GPU_NAS="$rep/nas" GPU_ACCOUNT=nobody GPU_ACC_HOME="$rep/home3" QUICK=1 bash "$rep/check.sh") > "$LOG" 2>&1 < /dev/null
        t '서버 폴더: /app 아래 다른 계정 것을 알려 줘요' has "$LOG" '아래에 root·공용 계정이 아닌 계정의 것이 있어요'
        t '서버 폴더: /app 아래 링크를 알려 줘요' has "$LOG" '링크가 1개 있어요'
        t '서버 폴더: 시스템 폴더 주인·권한을 봐요' has "$LOG" '[설치 스크립트가 쓸 시스템 폴더]'
        t '서버 폴더: 공유용 사본에 /app 아래 폴더 이름이 없어요' bash -c "! grep -qwE 'teamB|odd' $rep/home3/check_공유용_*.txt"
        t '서버 폴더: NAS 가 없어도 / 아래 이름(etc 등)을 가리지 않아요' bash -c "grep -q '/etc/profile.d' $rep/home3/check_공유용_*.txt"
        # 공용 계정이 홈에 보고서 이름으로 링크를 심어 둬도 root 파일을 덮지 않는다(공용 계정 권한으로 쓰므로)
        local victim=$rep/victim tag m; echo 원래 > "$victim"; chmod 644 "$victim"; tag=$(hostname -s | tail -c 3)
        for m in "$(date +%Y%m%d-%H%M)" "$(date -d '+1 min' +%Y%m%d-%H%M)"; do ln -s "$victim" "$rep/home2/check_공유용_${tag}_$m.txt"; done
        (cd "$rep" && timeout 60 env GPU_NAS="$rep/nas" GPU_ACCOUNT=nobody GPU_ACC_HOME="$rep/home2" QUICK=1 bash "$rep/check.sh") > "$LOG" 2>&1 < /dev/null
        t 'root: 홈에 심어 둔 링크를 따라 root 파일을 덮지 않아요' test "$(cat "$victim")" = 원래
        t 'root: 홈에 못 넣으면 root 만 보는 곳에 남겨요' has "$LOG" '공용 계정 홈에 보고서를 넣지 못해서'
    fi
    # 공용 계정으로도 돌린다. root 로 시험할 때는 nobody 로 돌린다
    chk() {   # $1 실행할 폴더, 나머지는 환경 변수(이름=값). 출력은 표준 출력
        local d=$1; shift
        if is_root; then (cd "$d" && timeout 120 runuser -u nobody -- env PATH="$PATH" GPU_ACCOUNT=nobody "$@" bash "$rep/check.sh") 2>&1 < /dev/null
        else (cd "$d" && timeout 120 env GPU_ACCOUNT=nobody "$@" bash "$rep/check.sh") 2>&1 < /dev/null; fi
    }
    chk "$rep/run" GPU_NAS="$rep/nas" QUICK=1 > "$LOG"
    share=$(ls "$rep"/run/check_공유용_*.txt 2>/dev/null | head -1)
    if [ -n "$share" ] && ls "$rep"/run/check_report_*.txt >/dev/null 2>&1; then
        ok '점검: 보고서 하나와 공유용 사본을 만들어요'
        t '점검: 서버·NAS·네트워크가 한 보고서에 있어요' bash -c "grep -q '== GPU ==' '$share' && grep -q '== NAS (네트워크 저장소) ==' '$share' && grep -q '== 네트워크 카드 ==' '$share'"
        # 공유용 이름 "서버(…끝 두 글자)" 는 일부러 남긴다. 그 밖에 서버·계정·NAS 폴더 이름이 있으면 안 된다
        t '점검: 공유용 사본에 서버·계정·폴더 이름이 없어요' bash -c "! sed 's/(…[^)]*)//g' '$share' | grep -qwE -- '$host|nobody|teamA'"
        t '점검: 공유용 사본에 IP가 없어요' bash -c "! grep -qE '\b([0-9]{1,3}\.){3}[0-9]{1,3}\b' '$share'"
    else no '점검: 보고서가 없어요' "$(tail -5 "$LOG")"; fi
    # 같은 줄에 칸을 맞춘 이름은 바꾼 뒤에도 같은 칸 너비여서, 원래 이름의 길이가 드러나지 않는다
    local sc=$rep/sc; printf '  alice(1000)          그룹 alice      755\n  bo(1001)             그룹 bo         755\n' > "$sc.in"
    bash -c "$(sed -n '/^share_copy() {/,/^}/p' server/check.sh)"'; share_copy "$1" "$2" alice=계정1 bo=계정2' _ "$sc.in" "$sc.out"
    cols() { local l; while IFS= read -r l; do printf '%s,%s ' "$(printf '%s' "${l%%그룹*}" | wc -L)" "$(printf '%s' "${l%%755*}" | wc -L)"; done < "$1"; }
    t '공유용 사본: 이름을 바꿔도 칸 너비가 그대로예요' test "$(cols "$sc.in")" = "$(cols "$sc.out")"
    # PCIe 카드(H200 NVL)면 Fabric Manager 를 찾지 않고 NVLink 브리지 묶음을 보여 준다
    chk "$rep/run" PATH="$T/fake:$PATH" FAKE_GPU_NAME='NVIDIA H200 NVL' QUICK=1 > "$LOG"
    t 'H200 NVL: NVLink 브리지 묶음을 보여 줘요' has "$LOG" 'NVLink 브리지로 묶인 GPU: [0,1,2,3] [4,5,6,7]'
    t 'H200 NVL: Fabric Manager를 찾지 않아요' lacks "$LOG" 'fabricmanager'
    chk "$rep/run" PATH="$T/fake:$PATH" FAKE_GPU_NAME='NVIDIA H100 80GB HBM3' QUICK=1 > "$LOG"
    t 'HGX 보드(SXM): Fabric 상태를 확인해요' has "$LOG" 'NVLink Fabric'
    # 속도까지: 두 서버(이름·포트만 다르게)가 NAS 로 서로 찾아 이더넷을 동시에, NAS 를 차례로 잰다. 시험 파일은 1 GB
    if [ "$(df -Pk "$rep" | awk 'NR==2 {print int($4/1048576)}')" -lt 4 ]; then skip '속도 측정: 남은 공간이 4 GB보다 적어요'; return; fi
    local e=(GPU_NAS="$rep/nas" GPU_ETH=127.0.0.1 WAIT_PEER=40 SIZE_GB=1 SECS=1)
    chk "$rep/run" "${e[@]}" GPU_HOST=pa PORT=25201 > "$LOG" &
    sleep 2; chk "$rep/run2" "${e[@]}" GPU_HOST=pb PORT=25301 > "$LOG.b"; wait
    t '두 서버: NAS 로 상대 서버를 찾아요' bash -c "grep -q '상대 서버: pb' '$LOG' && grep -q '상대 서버: pa' '$LOG.b'"
    t '두 서버: 공용 계정 번호를 맞춰 봐요' has "$LOG.b" '두 서버의 공용 계정 번호가 같아요'
    t '두 서버: 서버 사이 이더넷 속도를 재요' bash -c "grep -qE '서버 사이 이더넷: 받기 [0-9.]+ GB/s' '$LOG' && grep -qE '서버 사이 이더넷: 받기 [0-9.]+ GB/s' '$LOG.b'"
    t '두 서버: NAS 를 차례로 재요(나중 쪽이 기다려요)' has "$LOG.b" 'NAS 측정을 마칠 때까지 기다려요'
    t '두 서버: NAS 속도가 요약에 있어요' bash -c "grep -qE 'NAS 동시 8개: 쓰기 [0-9.]+ GB/s' '$LOG'"
    t '두 서버: 끝나면 NAS 에 만든 주소 파일·폴더를 지워요' test ! -e "$rep/nas/tmp/.gpu_net"
    share=$(ls -t "$rep"/run2/check_공유용_*.txt 2>/dev/null | head -1)
    t '두 서버: 공유용 사본에 상대 서버 이름이 없어요' bash -c "[ -n '$share' ] && ! sed 's/(…[^)]*)//g' '$share' | grep -qw pa"
}

# ================================================================== 8. 커밋 검사(.githooks/pre-commit)
mk_xlsx() {   # $1 파일 $2 글자. 엑셀 안 xml 에 글자를 숫자 문자 참조(&#…;)로 넣는다(openpyxl 이 이렇게 쓴다)
    local d; d=$(mktemp -d); mkdir -p "$d/xl"
    printf '<sst><si><t>%s</t></si></sst>' "$(perl -CSA -e 'print join "", map { ord($_) > 127 ? sprintf("&#%d;", ord $_) : $_ } split //, $ARGV[0]' -- "$2")" > "$d/xl/sharedStrings.xml"
    (cd "$d" && zip -qr "$1" xl); rm -rf "$d"
}
t_hook() {
    head_ '커밋 검사'
    local g=$T/hook ip; ip="10.$((20)).30.40"
    git init -q "$g" && git -C "$g" config core.hooksPath "$R/.githooks" && git -C "$g" config user.email t@t && git -C "$g" config user.name t
    echo '자율팀' > "$g/.git/info/gpu-blocklist.txt"
    cm() { git -C "$g" add -A >/dev/null 2>&1 && git -C "$g" commit -qm x >/dev/null 2>&1; }
    blocked() { ! cm; }
    reset_() { git -C "$g" reset -q --hard 2>/dev/null; git -C "$g" clean -qfd; git -C "$g" rm -rqf --cached . >/dev/null 2>&1; }
    echo ok > "$g/a.txt"; t '보통 파일은 커밋돼요' cm
    echo "server $ip" > "$g/b.txt"; t '사설 IP가 든 줄은 막아요' blocked; rm -f "$g/b.txt"; git -C "$g" reset -q
    echo '자율팀 서버' > "$g/c.txt"; t '가릴 낱말은 막아요' blocked; rm -f "$g/c.txt"; git -C "$g" reset -q
    echo x > "$g/check_report_a.txt"; t '원본 보고서(_report_)는 막아요' blocked; rm -f "$g/check_report_a.txt"; git -C "$g" reset -q
    mk_xlsx "$g/d.xlsx" "자율팀 규칙"; t '엑셀 안의 가릴 낱말(한글)도 막아요' blocked; rm -f "$g/d.xlsx"; git -C "$g" reset -q
    mk_xlsx "$g/e.xlsx" "주소 $ip"; t '엑셀 안의 사설 IP도 막아요' blocked; rm -f "$g/e.xlsx"; git -C "$g" reset -q
    echo 'HF_TOKEN=x' > "$g/.env"; t '.env 는 막아요' blocked; rm -f "$g/.env"; git -C "$g" reset -q
    echo 'HF_TOKEN=x' > "$g/.env.local"; t '.env.local 도 막아요' blocked; rm -f "$g/.env.local"; git -C "$g" reset -q
    echo "HF_TOKEN=hf_$(printf 'a%.0s' {1..34})" > "$g/f.txt"; t 'HF 토큰처럼 보이는 값은 막아요' blocked; rm -f "$g/f.txt"; git -C "$g" reset -q
    echo "key AKIA$(printf 'A%.0s' {1..16})" > "$g/k.txt"; t 'AWS 키처럼 보이는 값은 막아요' blocked; rm -f "$g/k.txt"; git -C "$g" reset -q
    cp .env.example "$g/"; t '값 없는 .env.example 은 커밋돼요' cm
    cp team/서버_사용_규칙.xlsx "$g/"; echo zzzz > "$g/.git/info/gpu-blocklist.txt"; t '저장소의 규칙 엑셀은 통과해요' cm
}

# ================================================================== 9. 기초 프로그램 설치(pkgs_install.sh)
# $1 폴더에 시험용 패키지 하나(gpu-test-hello)로 묶음을 만든다. 접근 PC의 pkgs_pack.ps1 이 만드는 모양 그대로
mk_pkgs() {
    local d=$1 b=$T/pkgbuild f=gpu-test-hello_1.0_all.deb
    rm -rf "$d" "$b"; mkdir -p "$d/debs" "$b/DEBIAN" "$b/usr/bin"
    printf 'Package: gpu-test-hello\nVersion: 1.0\nArchitecture: all\nMaintainer: test <test@example.com>\nDescription: test\n' > "$b/DEBIAN/control"
    printf '#!/bin/sh\necho hello\n' > "$b/usr/bin/gpu-test-hello"; chmod 755 "$b/usr/bin/gpu-test-hello"
    dpkg-deb --root-owner-group -b "$b" "$d/debs/$f" > /dev/null
    ( cd "$d/debs" && { dpkg-deb -f "$f"; echo "Filename: ./$f"; echo "Size: $(stat -c %s "$f")"; echo "SHA256: $(sha256sum "$f" | cut -d' ' -f1)"; echo; } > Packages )
    printf 'made=test\nubuntu=%s\npkgs=gpu-test-hello\ndebs=1\n' "$(. /etc/os-release && echo "${VERSION_CODENAME:-}")" > "$d/pkgs_info.txt"
    ( cd "$d" && sha256sum debs/"$f" debs/Packages pkgs_info.txt > MANIFEST_pkgs.sha256 )
    cp server/pkgs_install.sh "$d/"
}
run_pk() { GPU_LOG_DIR=$T/pklog bash "$1/pkgs_install.sh" > "$LOG" 2>&1 < /dev/null; }
t_pkgs() {
    head_ '기초 프로그램 설치'
    is_root || { skip 'root 가 아니라서 건너뛰어요(pkgs_install.sh 는 root 전용)'; return; }
    command -v dpkg-deb >/dev/null && command -v apt-get >/dev/null || { skip 'dpkg-deb·apt-get 이 없어요(Ubuntu 에서 돌려요)'; return; }
    local D=$T/pk/inbox; mkdir -p "$T/pk"; chmod 755 "$T/pk"
    mk_pkgs "$D"; echo x >> "$D/debs/gpu-test-hello_1.0_all.deb"
    run_pk "$D"; t '바뀐 .deb 를 잡아요' has "$LOG" '깨진 파일: debs/gpu-test-hello_1.0_all.deb'
    mk_pkgs "$D"; echo x > "$D/debs/evil.deb"
    run_pk "$D"; t '체크섬 목록에 없는 .deb 가 있으면 멈춰요' has "$LOG" '체크섬 목록에 없는 파일이 debs 폴더에 있어요'
    mk_pkgs "$D"; : > "$D/MANIFEST_pkgs.sha256"
    run_pk "$D"; t '빈 체크섬 목록이면 멈춰요' has "$LOG" '비었거나 모양이 이상해요'
    mk_pkgs "$D"; sed -i 's/^ubuntu=.*/ubuntu=jammy-test/' "$D/pkgs_info.txt"; ( cd "$D" && sha256sum debs/* pkgs_info.txt > MANIFEST_pkgs.sha256 )
    run_pk "$D"; t '다른 Ubuntu 버전용 묶음이면 멈춰요' has "$LOG" '이 묶음은 Ubuntu jammy-test 용인데'
    mk_pkgs "$D"; chmod 777 "$T/pk"
    run_pk "$D"; t '푼 곳을 남도 고칠 수 있으면 멈춰요' has "$LOG" 'root 말고도 고칠 수 있어요'
    chmod 755 "$T/pk"
    # 진짜 설치는 버리는 가상 머신에서만(서버의 dpkg 에 시험 패키지를 넣지 않게)
    if [ "${GPU_TEST_SYSTEM:-}" != 1 ]; then skip '진짜 설치: GPU_TEST_SYSTEM=1 일 때만 돌려요(GitHub Actions)'; return; fi
    mk_pkgs "$D"
    run_pk "$D"; t '없는 프로그램만 임시 저장소로 설치해요' bash -c 'grep -q "기초 프로그램 1개가 모두 있어요" "$1" && [ "$(gpu-test-hello)" = hello ]' _ "$LOG"
    t '서버의 apt 저장소 목록은 그대로예요' bash -c '! grep -rqs gpu-test-hello /var/lib/apt/lists/'
    run_pk "$D"; t '두 번째 실행은 설치할 것이 없어요' has "$LOG" '설치할 것이 없어요'
    dpkg -r gpu-test-hello > /dev/null 2>&1
}

# ================================================================== 10. prepare.sh·admin_setup.sh 를 진짜 /app 에(버리는 가상 머신에서만)
t_system() {
    head_ 'prepare.sh·admin_setup.sh (진짜 /app·/etc)'
    if [ "${GPU_TEST_SYSTEM:-}" != 1 ] || ! is_root; then skip 'GPU_TEST_SYSTEM=1 과 root 일 때만 돌려요(GitHub Actions)'; return; fi
    [ -e /etc/gpu/account ] && [ ! -e /app/.gpu_test_sandbox ] && { no '/etc/gpu/account 가 있어요. 서버에서는 돌리지 않아요'; return; }
    id gputest >/dev/null 2>&1 || useradd -m -s /bin/bash gputest
    mkdir -p /etc/gpu && echo gputest > /etc/gpu/account
    # 잠그기 전에 공용 계정이 만든 /app/shared(예전 설치: 기초 프로그램·데이터셋·설정을 한곳에)
    mkdir -p /app && touch /app/.gpu_test_sandbox && rm -rf /app/.shared_old_* /app/.admin_old_* /app/admin /srv/gpunas; rm -f /etc/profile.d/gpu.sh /etc/cron.d/gpu   # 다시 돌릴 때 앞 시험의 흔적을 지운다
    mkdir -p /srv/gpunas && chmod 755 /srv/gpunas   # NAS 대신(/data 처럼 root 소유 755)
    mkdir -p /app/shared/{tools/bin,datasets/x,models/org/m}
    echo evil > /app/shared/tools/bin/git; echo d > /app/shared/datasets/x/f; ln -s /etc/passwd /app/shared/datasets/x/l; echo w > /app/shared/models/org/m/w
    printf 'IDLE_HOURS=12\nNAS_DIR=/srv/gpunas/autonomy_sw\n' > /app/shared/gpu.conf; chown -R gputest /app/shared /app
    rm -rf /app/autonomy_sw; mkdir -p /app/workspace/kim && echo r > /app/workspace/kim/result.txt && chown -R gputest /app/workspace   # 예전 이름의 작업 폴더
    local P=$T/pack; mkdir -p "$P"; cp -r server/. "$P/"
    bash "$P/admin_setup.sh" < /dev/null > "$LOG" 2>&1
    t '권한·규칙 설정: 준비(prepare.sh) 전에는 멈춰요' has "$LOG" '준비가 안 돼 있어요'
    bash "$P/prepare.sh" < /dev/null > "$LOG" 2>&1
    t '준비: 끝까지 실행돼요(질문 없이)' has "$LOG" '완료'
    cp "$LOG" "$T/prepare.log"
    t '준비: gpu 명령(gpu fetch)을 설치해요' test -x /app/admin/bin/gpu
    t '준비: 팀원 맞이 설정(접속 설정, 정기 점검, docker 도우미)은 아직 하지 않아요' test ! -e /etc/profile.d/gpu.sh -a ! -e /etc/cron.d/gpu -a ! -e /app/admin/bin/docker
    printf '2\n' | script -qec "bash $P/admin_setup.sh" /dev/null > "$LOG" 2>&1
    t '권한·규칙 설정: 끝까지 실행돼요' has "$LOG" '완료'
    t '/app, /app/admin 을 root 소유로 잠가요' test "$(stat -c %U /app /app/admin | sort -u)" = root
    t '예전 /app/shared 를 없애고 프로그램은 치워요' bash -c 'ls -d /app/.shared_old_*/tools/bin/git >/dev/null && [ ! -e /app/shared ] && [ ! -e /app/admin/tools ]'
    t '예전 설정은 /app/admin 으로 옮기고, 데이터셋은 NAS로 옮기는 명령을 알려 줘요' bash -c '[ -f /app/admin/gpu.conf ] && [ -f /app/.shared_old_*/datasets/x/f ] && grep -q "rsync -a --no-links /app/.shared_old_.*/datasets/" "$1"' _ "$T/prepare.log"
    t 'NAS 팀 폴더(root·공용 계정 그룹 750)와 originals(root 755)를 만들어요' test "$(stat -c '%U %G %a' /srv/gpunas/autonomy_sw)|$(stat -c '%U %a' /srv/gpunas/autonomy_sw/originals)" = "root $(id -gn gputest) 750|root 755"
    t '팀원(공용 계정)이 NAS 의 datasets·models 에 넣을 수 있어요' bash -c 'runuser -u gputest -- touch /srv/gpunas/autonomy_sw/datasets/g /srv/gpunas/autonomy_sw/models/g && rm -f /srv/gpunas/autonomy_sw/{datasets,models}/g'
    t '예전 작업 폴더(/app/workspace)를 /app/autonomy_sw 로 옮겨요' bash -c '[ -f /app/autonomy_sw/kim/result.txt ] && [ ! -e /app/workspace ]'
    t '서버 번호 2를 고르면 0~3번이 다른팀이에요' grep -qE '^0[[:space:]]+다른팀' /app/admin/gpu_alloc.txt
    t '접속 설정과 정기 점검을 만들어요' test -f /etc/profile.d/gpu.sh -a -f /etc/cron.d/gpu
    t '정기 점검 파일에 PATH(runuser 위치)가 있어요' grep -q '^PATH=.*/usr/sbin' /etc/cron.d/gpu
    bash "$P/prepare.sh" < /dev/null > "$LOG" 2>&1 && bash "$P/admin_setup.sh" < /dev/null >> "$LOG" 2>&1
    t '두 번째 실행도 끝까지(질문 없이) 돼요' test "$(grep -c '완료' "$LOG")" = 2
    t '두 번째 실행에서는 다시 치우지 않아요' bash -c '[ "$(ls -d /app/.shared_old_* | wc -l)" = 1 ] && ! ls -d /app/.admin_old_* >/dev/null 2>&1'
    GPU_ACCOUNT=gputest /app/admin/bin/gpu _check > "$LOG" 2>&1; t '설치된 gpu 정기 점검이 돌아요(도커 없음)' test $? -le 1
    # 팀원 접속: 명단에 넣고 다시 실행 → 공용 계정으로 로그인해 번호로 이름을 고른다
    printf '홍길동  인지\n' >> /app/admin/team.txt
    bash "$P/admin_setup.sh" < /dev/null > /dev/null 2>&1
    rm -f /app/state/tty/pts-*
    printf '1\necho "WS=$GPU_WS USER=$GPU_USER"\ntype docker | head -1\nexit\n' | timeout 60 script -qec 'su -l gputest' /dev/null > "$LOG" 2>&1
    t '접속하면 이름 목록이 나와요' has "$LOG" '1 홍길동'
    t '번호로 고르면 이름과 작업 폴더가 정해져요' has "$LOG" 'WS=/app/autonomy_sw/홍길동 USER=홍길동'
    t '공용 계정의 docker 는 도우미(/app/admin/bin/docker)예요' has "$LOG" 'docker is /app/admin/bin/docker'
    t '알림을 보낼 창(pts)과 이름을 적어 둬요' bash -c 'grep -qx 홍길동 /app/state/tty/pts-*'
    t 'NAS: 팀원 폴더(backup/<이름>)는 공용 계정 것이에요' test "$(stat -c %U /srv/gpunas/autonomy_sw/backup /srv/gpunas/autonomy_sw/backup/홍길동 | sort -u)" = gputest
    chmod 777 /srv/gpunas
    bash "$P/prepare.sh" < /dev/null > "$LOG" 2>&1
    t 'NAS: 위 폴더를 남도 고칠 수 있으면 NAS 팀 폴더를 손대지 않고 알려 줘요' has "$LOG" 'root 말고도 고칠 수 있어서, root 가 팀 폴더를 만들지 않았어요'
    chmod 755 /srv/gpunas
}

all=(static docs installers gpu wrapper fetch reports hook pkgs system)
sel=("$@"); [ ${#sel[@]} -gt 0 ] || sel=("${all[@]}")
echo "${C}[GPU 서버 저장소] 자동 시험  ($(date '+%Y-%m-%d %H:%M'), $(id -un))${Z}"
for s in "${sel[@]}"; do
    case " ${all[*]} " in *" $s "*) "t_$s" ;; *) echo "모르는 묶음: $s (있는 것: ${all[*]})"; exit 2 ;; esac
done
echo
if [ "$FAIL" = 0 ]; then echo "${G}######## 모두 통과: ${PASS}개 (건너뜀 ${SKIP}개) ########${Z}"
else echo "${RD}######## 실패 ${FAIL}개, 통과 ${PASS}개 (건너뜀 ${SKIP}개) ########${Z}"; exit 1; fi
