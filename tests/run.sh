#!/usr/bin/env bash
# 저장소 자동 시험. 임시 폴더에 가짜 /app, 가짜 docker·nvidia-smi 를 만들고 스크립트를 실제로 돌려 본다.
# 서버에서 돌리지 않는다(실제 /app 이 있으면 멈춘다). 이 저장소를 고친 뒤, 커밋하기 전에 돌린다.
#   bash tests/run.sh                 전체(root 가 아니면 root 가 필요한 시험은 건너뛴다)
#   bash tests/run.sh docs gpu       고른 묶음만: static docs installers gpu wrapper fetch reports hook system
#   GPU_TEST_SYSTEM=1 bash tests/run.sh system
#                                     admin_setup.sh 를 진짜 /app 과 /etc 에 돌린다. 버리는 가상 머신(GitHub Actions)에서만
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
    *index,memory.used,memory.total,utilization.gpu*) for i in 0 1 2 3 4 5 6 7; do echo "$i, 0, 179000, 0"; done ;;
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
    # 사내 IP(사설 대역)는 저장소에 없어야 한다. 이 시험 파일의 예시 IP 는 실행할 때 만든다
    bad=$(git grep -nIE '(^|[^0-9.])(10\.[0-9]{1,3}|192\.168|172\.(1[6-9]|2[0-9]|3[01]))\.[0-9]{1,3}\.[0-9]{1,3}([^0-9]|$)' -- . ':!*.xlsx' | grep -v 'check_network.sh send 10\.0\.0\.2')
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
        case "$n" in gpu.sh|gpu-docker.sh|catalog.py|train.py|json.py) continue ;; esac
        [ -n "$(find server pc tests -name "$n" -print -quit)" ] || bad+=" $n"
    done
    [ -z "$bad" ] && ok '문서에 나온 스크립트가 모두 있어요' || no "없는 스크립트:$bad"
    # docs/… 를 가리키는 곳(문서·스크립트)이 실제 파일이고, 같이 적은 "절 이름" 이 그 파일의 제목에 있다
    bad=$(git grep -hoIE 'docs[/\\][0-9]_[^ )`"'"'"'\\]+\.md( 의 \\?"[^"\\]+\\?")?' -- . ':!tests' | sed 's/\\"/"/g' | sort -u | while IFS= read -r ref; do
        f=${ref%%.md*}.md; f=${f//\\//}
        [ -f "$f" ] || { echo "없는 문서: $ref"; continue; }
        case "$ref" in *'"'*) s=${ref#*\"}; s=${s%\"}; grep -E '^#+ ' "$f" | tr -d '`' | grep -qF -- "$s" || echo "제목 없음: $ref" ;; esac
    done)
    [ -z "$bad" ] && ok '문서 이름과 절 이름이 모두 있어요' || no '가리키는 문서·절이 없어요' "$bad"
    # 문제 해결 표에 적은 화면 메시지가 스크립트에 실제로 있다(… 는 바뀌는 부분, '습니다' 는 Windows 메시지)
    bad=$(grep -oP '^\| `\K[^`]+' docs/8_문제_해결.md | while IFS= read -r m; do
        case "$m" in *습니다*) continue ;; esac
        IFS='…' read -ra parts <<< "$m"
        for p in "${parts[@]}"; do p=$(echo "$p" | sed 's/^ *//; s/ *$//'); [ ${#p} -ge 3 ] || continue
            grep -rqF -- "$p" server pc || echo "$m  (못 찾은 부분: $p)"; done
    done)
    [ -z "$bad" ] && ok '문제 해결 표의 메시지가 스크립트에 있어요' || no '문제 해결 표의 메시지가 스크립트에 없어요' "$bad"
    # README 의 폴더 표에 있는 경로가 있다
    bad=$(grep -oP '^\| `\K[^`]+(?=`)' README.md | while read -r p; do [ -e "${p%/}" ] || echo "$p"; done)
    [ -z "$bad" ] && ok 'README 폴더 표의 경로가 모두 있어요' || no 'README 폴더 표에 없는 경로' "$bad"
}

# ================================================================== 3. 데이터셋·모델 설치
mk_datasets() {   # $1 폴더. 압축 1개 + wildscenes 파일 2개와 맞는 체크섬 목록
    local d=$1; mkdir -p "$d/goose" "$d/wildscenes/a"
    ( cd "$d" && echo z > z.txt && zip -q goose/g.zip z.txt && rm z.txt
      echo hi > wildscenes/a/1.png; echo yo > wildscenes/2.png
      sha256sum goose/g.zip wildscenes/a/1.png wildscenes/2.png > MANIFEST.sha256
      echo 'files=2 bytes=6' > wildscenes.ok )
    cp server/datasets_install.sh "$d/"
}
# GPU_APP 을 없는 폴더로 둬서, 시험하는 곳에 /app 이 있어도(admin_setup 시험 뒤) 홈의 shared 에 설치하게 한다
run_ds() { HOME=$1 GPU_APP=$T/no-app bash "$2/datasets_install.sh" > "$LOG" 2>&1; }
t_installers() {
    head_ '데이터셋·모델 설치'
    local H=$T/inst/home D=$T/inst/ds
    mkdir -p "$H"
    mk_datasets "$D"
    run_ds "$H" "$D"; t '데이터셋: 정상 설치' has "$LOG" '파일 3개의 체크섬이 맞아요'
    t '데이터셋: wildscenes 는 목록의 파일만 옮겨요' test -f "$H/shared/datasets/wildscenes/a/1.png" -a -f "$H/shared/datasets/wildscenes/.gpu_done"
    t '데이터셋: wildscenes 파일을 압축 풀기 목록에 넣지 않아요' test ! -e "$H/shared/datasets/wildscenes/1.png"
    rm -rf "$H/shared" "$D"; mk_datasets "$D"; echo bad > "$D/wildscenes/2.png"
    run_ds "$H" "$D"; t '데이터셋: 바뀐 wildscenes 파일을 잡아요' has "$LOG" '깨졌거나 없는 파일: wildscenes/2.png'
    rm -rf "$H/shared" "$D"; mk_datasets "$D"; echo x > "$D/wildscenes/a/evil.sh"
    run_ds "$H" "$D"; t '데이터셋: 목록에 없는 wildscenes 파일이 있으면 멈춰요' has "$LOG" 'wildscenes 파일이 3개예요'
    rm -rf "$H/shared" "$D"; mk_datasets "$D"; : > "$D/MANIFEST.sha256"
    run_ds "$H" "$D"; t '데이터셋: 빈 체크섬 목록이면 멈춰요' has "$LOG" '비었거나 모양이 이상해요'
    rm -rf "$H/shared" "$D"; mk_datasets "$D"; echo 'garbage' >> "$D/MANIFEST.sha256"
    run_ds "$H" "$D"; t '데이터셋: 모양이 다른 줄이 있으면 멈춰요' has "$LOG" '비었거나 모양이 이상해요'
    rm -rf "$H/shared" "$D"; mk_datasets "$D"; grep -v wildscenes "$D/MANIFEST.sha256" > "$D/m" && mv "$D/m" "$D/MANIFEST.sha256"
    run_ds "$H" "$D"; t '데이터셋: 예전 목록(wildscenes 체크섬 없음)이면 멈춰요' has "$LOG" '체크섬 목록에 wildscenes 파일이 없어요'

    # 모델: 목록에 있는 파일만 옮기고, 올린 폴더의 json.py 같은 파일이 실행되지 않는다
    local M=$T/inst/models; rm -rf "$H/shared"; mkdir -p "$M/org__m"
    ( cd "$M" && echo '{"a":1}' > org__m/config.json && echo '{"repo":"org/m","license":"mit"}' > org__m/gpu_model.json
      echo extra > org__m/extra.py
      python3 -I -c "
import zipfile
with zipfile.ZipFile('org__m/code.zip','w') as z:
    z.writestr('top/ok/a.py','x'); z.writestr('top//$T/inst/escaped','x'); z.writestr('top/../../escaped2','x')"
      sha256sum org__m/config.json org__m/code.zip > MANIFEST.sha256
      for m in json os zipfile struct sys; do echo "open('$T/inst/PWNED','w')" > $m.py; done )
    cp server/models_install.sh "$M/"
    HOME=$H GPU_APP=$T/no-app bash "$M/models_install.sh" > "$LOG" 2>&1
    t '모델: 정상 설치' has "$LOG" '모델 1개가 모두 정상이에요'
    t '모델: 올린 폴더의 json.py 등이 실행되지 않아요(python -I)' test ! -e "$T/inst/PWNED"
    t '모델: 목록에 없는 파일은 옮기지 않아요' test ! -e "$H/shared/models/org/m/extra.py"
    t '모델: 코드 묶음을 풀어요' test -f "$H/shared/models/org/m/code/ok/a.py"
    t '모델: 코드 묶음이 폴더 밖에 쓰지 않아요' test ! -e "$T/inst/escaped" -a ! -e "$T/escaped2" -a ! -e "$H/shared/models/escaped2"
}

# ================================================================== 4. gpu (정기 점검·현황·보고서)
APPT=$T/app
setup_app() {   # 가짜 /app. gpu 은 root 로 돌 때 자기 파일이 root 소유여야 한다
    rm -rf "$APPT"; mkdir -p "$APPT"/shared/bin "$APPT"/workspace/{hong,kim} "$APPT"/state/{gpu_log,notice,reports,images,notice_seen,tty} "$APPT"/upload "$APPT"/inbox
    install -m 755 server/bin/gpu server/bin/docker server/bin/nvidia-smi "$APPT/shared/bin/"
    printf '홍길동 인지\nhong 인지\nkim 판단\n관리자 인지\n' > "$APPT/shared/team.txt"
    printf '# 시험\n  # 들여쓴 주석\n0 다른팀\n1 다른팀\n2 다른팀\n3 다른팀\n4 인지\n5 판단\n6 공용\n7 공용\n' > "$APPT/shared/gpu_alloc.txt"
    : > "$APPT/state/images/loaded.tsv"
    rm -f "$T/fake/inspect" "$T/fake/images" "$T/fake/args.log"
}
# 컨테이너 한 줄: pid 이름 이름표(사람) GPU요청 이미지 이름표(GPU) ID  (gpu 이 docker inspect 로 받는 모양)
ctr() { printf '%s\t%s\t"%s"\t%s\t"%s"\t"%s"\t%s\n' "$@" >> "$T/fake/inspect"; }
gpu() { env GPU_APP="$APPT" GPU_DOCKER="$T/fake/docker" GPU_NVSMI="$T/fake/nvidia-smi" GPU_ACCOUNT=nobody FAKE_DIR="$T/fake" "$APPT/shared/bin/gpu" "$@"; }
t_gpu() {
    head_ 'gpu (현황·정기 점검·보고서)'
    is_root || { skip 'root 가 아니라서 건너뛰어요(gpu 정기 점검은 root 로 돌아요)'; return; }
    setup_app
    printf 'MAX_GPUS=6\nIDLE_HOURS=$(touch %s/PWNED1)\ntouch %s/PWNED2\nNAS_DIR=/data/team\n' "$T" "$T" > "$APPT/shared/gpu.conf"
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
    ln -s / "$APPT/workspace/zz-link"
    if timeout 60 env GPU_APP="$APPT" GPU_DOCKER="$T/fake/docker" GPU_NVSMI="$T/fake/nvidia-smi" GPU_ACCOUNT=nobody FAKE_DIR="$T/fake" "$APPT/shared/bin/gpu" _report > "$LOG" 2>&1; then
        t '주간 보고서가 나와요' has "$LOG" '== 디스크'
    else no '주간 보고서가 60초 안에 끝나지 않아요(작업 폴더의 링크를 따라갔을 수 있어요)'; fi
    rm -f "$APPT/workspace/zz-link"
}

# ================================================================== 5. docker 래퍼(팀원 = 공용 계정으로)
t_wrapper() {
    head_ 'docker 래퍼'
    is_root || { skip 'root 가 아니라서 건너뛰어요(공용 계정 대신 nobody 로 돌려 봐요)'; return; }
    setup_app
    local dk=(runuser -u nobody -- env GPU_APP="$APPT" GPU_DOCKER="$T/fake/docker" GPU_NVSMI="$T/fake/nvidia-smi" FAKE_DIR="$T/fake" GPU_USER=hong "$APPT/shared/bin/docker")
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

# ================================================================== 6. gpu fetch (올린 파일 들여오기)
t_fetch() {
    head_ 'gpu fetch'
    is_root || { skip 'root 가 아니라서 건너뛰어요(fetch 는 root 전용)'; return; }
    setup_app; chmod 755 "$APPT/inbox"; chown nobody "$APPT/upload"
    mk_datasets "$APPT/upload/datasets"
    gpu fetch datasets > "$LOG" 2>&1
    t '정상 폴더는 복사하고 지문을 보여 줘요' has "$LOG" '지문(sha256)'
    t '지문을 보는 줄과 실행 줄이 따로예요(&& 로 잇지 않아요)' lacks "$LOG" '&& bash'
    ln -s /etc/passwd "$APPT/upload/datasets/goose/link"
    gpu fetch datasets > "$LOG" 2>&1
    t '링크가 든 폴더는 복사본을 지우고 멈춰요' test ! -e "$APPT/inbox/datasets"
    rm -rf "$APPT/upload/datasets"; mkdir -p "$APPT/upload/datasets/datasets"
    gpu fetch datasets > "$LOG" 2>&1
    t '한 겹 더 들어간 폴더는 알려 주고 멈춰요' has "$LOG" '한 겹 더'
}

# ================================================================== 7. 점검 보고서의 공유용 사본(사내 정보 가리기)
t_reports() {
    head_ '점검 보고서 공유용 사본'
    is_root || { skip 'root 가 아니라서 건너뛰어요(보고서는 root 로 /app/inbox/reports 에 남겨요)'; return; }
    local ib=$T/rep/inbox host; host=$(hostname -s); mkdir -p "$ib"
    # 공유용 사본을 만드는 함수는 세 점검 스크립트에 똑같이 들어 있어야 한다(0단계에서 파일 하나씩 따로 올려서 나눠 두지 않았다)
    local fn f bad=
    for fn in report_dir share_copy; do for f in server/check_network.sh server/check_nas.sh; do
        diff -q <(sed -n "/^$fn() {/,/^}/p" server/check_server.sh) <(sed -n "/^$fn() {/,/^}/p" "$f") >/dev/null || bad+=" $f:$fn"
    done; done
    [ -z "$bad" ] && ok '세 점검 스크립트의 보고서 함수가 같아요' || no '점검 스크립트마다 보고서 함수가 달라요' "$bad"
    GPU_INBOX=$ib GPU_ACCOUNT=nobody timeout 60 bash server/check_server.sh > "$LOG" 2>&1 < /dev/null
    local share; share=$(ls "$ib"/reports/server_공유용_*.txt 2>/dev/null | head -1)
    if [ -n "$share" ] && ls "$ib"/reports/server_report_*.txt >/dev/null 2>&1; then
        ok '서버 점검: 원본과 공유용 사본을 만들어요'
        t '서버 점검: 공유용 사본에 서버·계정 이름이 없어요' bash -c "! sed 's/(…[^)]*)//g' '$share' | grep -qwE -- '$host|nobody'"
    else no '서버 점검: 보고서가 없어요' "$(tail -5 "$LOG")"; fi
    # 같은 줄에 칸을 맞춘 이름은 바꾼 뒤에도 같은 칸 너비여서, 원래 이름의 길이가 드러나지 않는다
    local sc=$T/rep/sc; printf '  alice(1000)          그룹 alice      755\n  bo(1001)             그룹 bo         755\n' > "$sc.in"
    bash -c "$(sed -n '/^share_copy() {/,/^}/p' server/check_nas.sh)"'; share_copy "$1" "$2" alice=계정1 bo=계정2' _ "$sc.in" "$sc.out"
    cols() { local l; while IFS= read -r l; do printf '%s,%s ' "$(printf '%s' "${l%%그룹*}" | wc -L)" "$(printf '%s' "${l%%755*}" | wc -L)"; done < "$1"; }
    t '공유용 사본: 이름을 바꿔도 칸 너비가 그대로예요' test "$(cols "$sc.in")" = "$(cols "$sc.out")"
    mkdir -p "$T/rep/nvl"
    # PCIe 카드(H200 NVL)면 Fabric Manager 를 찾지 않고 NVLink 브리지 묶음을 보여 준다
    PATH=$T/fake:$PATH FAKE_GPU_NAME='NVIDIA H200 NVL' GPU_INBOX=$T/rep/nvl GPU_ACCOUNT=nobody timeout 60 bash server/check_server.sh > "$LOG" 2>&1 < /dev/null
    t 'H200 NVL: NVLink 브리지 묶음을 보여 줘요' has "$LOG" 'NVLink 브리지로 묶인 GPU: [0,1,2,3] [4,5,6,7]'
    t 'H200 NVL: Fabric Manager를 찾지 않아요' lacks "$LOG" 'fabricmanager'
    FAKE_GPU_NAME='NVIDIA H100 80GB HBM3' PATH=$T/fake:$PATH GPU_INBOX=$T/rep/nvl GPU_ACCOUNT=nobody timeout 60 bash server/check_server.sh > "$LOG" 2>&1 < /dev/null
    t 'HGX 보드(SXM): Fabric 상태를 확인해요' has "$LOG" 'NVLink Fabric'
    GPU_INBOX=$ib timeout 120 bash server/check_network.sh all > "$LOG" 2>&1 < /dev/null
    share=$(ls "$ib"/reports/network_공유용_*.txt 2>/dev/null | head -1)
    if [ -n "$share" ]; then
        ok '네트워크 점검: 공유용 사본을 만들어요'
        # 공유용 이름 "서버(…끝 두 글자)" 는 일부러 남긴다. 그 밖에 서버 이름이 있으면 안 된다
        t '네트워크 점검: 공유용 사본에 서버 이름이 없어요' bash -c "! sed 's/(…[^)]*)//g' '$share' | grep -qw -- '$host'"
        t '네트워크 점검: 공유용 사본에 IP가 없어요' bash -c "! grep -qE '\b([0-9]{1,3}\.){3}[0-9]{1,3}\b' '$share'"
    else no '네트워크 점검: 공유용 사본이 없어요' "$(tail -5 "$LOG")"; fi
    mkdir -p "$T/rep/nas/tmp" "$T/rep/nas/teamA"; chmod 1777 "$T/rep/nas/tmp"
    GPU_INBOX=$ib GPU_NAS=$T/rep/nas GPU_ACCOUNT=nobody timeout 60 bash server/check_nas.sh > "$LOG" 2>&1 < /dev/null
    share=$(ls "$ib"/reports/nas_공유용_*.txt 2>/dev/null | head -1)
    if [ -n "$share" ]; then
        t 'NAS 점검: 공유용 사본에 계정·폴더 이름이 없어요' bash -c "! grep -qwE 'nobody|teamA' '$share'"
    else no 'NAS 점검: 공유용 사본이 없어요' "$(tail -5 "$LOG")"; fi
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
    echo x > "$g/network_report_a.txt"; t '원본 보고서(_report_)는 막아요' blocked; rm -f "$g/network_report_a.txt"; git -C "$g" reset -q
    mk_xlsx "$g/d.xlsx" "자율팀 규칙"; t '엑셀 안의 가릴 낱말(한글)도 막아요' blocked; rm -f "$g/d.xlsx"; git -C "$g" reset -q
    mk_xlsx "$g/e.xlsx" "주소 $ip"; t '엑셀 안의 사설 IP도 막아요' blocked; rm -f "$g/e.xlsx"; git -C "$g" reset -q
    echo 'HF_TOKEN=x' > "$g/.env"; t '.env 는 막아요' blocked; rm -f "$g/.env"; git -C "$g" reset -q
    echo 'HF_TOKEN=x' > "$g/.env.local"; t '.env.local 도 막아요' blocked; rm -f "$g/.env.local"; git -C "$g" reset -q
    echo "HF_TOKEN=hf_$(printf 'a%.0s' {1..34})" > "$g/f.txt"; t 'HF 토큰처럼 보이는 값은 막아요' blocked; rm -f "$g/f.txt"; git -C "$g" reset -q
    echo "key AKIA$(printf 'A%.0s' {1..16})" > "$g/k.txt"; t 'AWS 키처럼 보이는 값은 막아요' blocked; rm -f "$g/k.txt"; git -C "$g" reset -q
    cp .env.example "$g/"; t '값 없는 .env.example 은 커밋돼요' cm
    cp team/서버_사용_규칙.xlsx "$g/"; echo zzzz > "$g/.git/info/gpu-blocklist.txt"; t '저장소의 규칙 엑셀은 통과해요' cm
}

# ================================================================== 9. admin_setup.sh 를 진짜 /app 에(버리는 가상 머신에서만)
t_system() {
    head_ 'admin_setup.sh (진짜 /app·/etc)'
    if [ "${GPU_TEST_SYSTEM:-}" != 1 ] || ! is_root; then skip 'GPU_TEST_SYSTEM=1 과 root 일 때만 돌려요(GitHub Actions)'; return; fi
    [ -e /etc/gpu/account ] && [ ! -e /app/.gpu_test_sandbox ] && { no '/etc/gpu/account 가 있어요. 서버에서는 돌리지 않아요'; return; }
    id gputest >/dev/null 2>&1 || useradd -m -s /bin/bash gputest
    mkdir -p /etc/gpu && echo gputest > /etc/gpu/account
    # 잠그기 전에 공용 계정이 만든 /app/shared(예전 설치)
    mkdir -p /app && touch /app/.gpu_test_sandbox && rm -rf /app/.shared_old_* /app/shared/.gpu_root   # 다시 돌릴 때 앞 시험의 흔적을 지운다
    mkdir -p /app/shared/{tools/bin,datasets/x}
    echo evil > /app/shared/tools/bin/git; echo d > /app/shared/datasets/x/f; ln -s /etc/passwd /app/shared/datasets/x/l
    printf 'IDLE_HOURS=12\n' > /app/shared/gpu.conf; chown -R gputest /app/shared /app
    local P=$T/pack; mkdir -p "$P"; cp -r server/. "$P/"
    printf '2\n' | script -qec "bash $P/admin_setup.sh" /dev/null > "$LOG" 2>&1
    t '끝까지 실행돼요' has "$LOG" '완료'
    t '/app 과 /app/shared 를 root 소유로 잠가요' test "$(stat -c %U /app)$(stat -c %U /app/shared)" = rootroot
    t '예전 /app/shared 의 프로그램을 치워요' bash -c 'ls -d /app/.shared_old_*/tools/bin/git >/dev/null && [ ! -e /app/shared/tools/bin/git ]'
    t '예전 데이터셋·설정은 옮기고 링크는 지워요' bash -c '[ -f /app/shared/datasets/x/f ] && [ ! -L /app/shared/datasets/x/l ] && [ -f /app/shared/gpu.conf ]'
    t '서버 번호 2를 고르면 0~3번이 다른팀이에요' grep -qE '^0[[:space:]]+다른팀' /app/shared/gpu_alloc.txt
    t '접속 설정과 정기 점검을 만들어요' test -f /etc/profile.d/gpu.sh -a -f /etc/cron.d/gpu
    t '정기 점검 파일에 PATH(runuser 위치)가 있어요' grep -q '^PATH=.*/usr/sbin' /etc/cron.d/gpu
    bash "$P/admin_setup.sh" < /dev/null > "$LOG" 2>&1
    t '두 번째 실행도 끝까지(질문 없이) 돼요' has "$LOG" '완료'
    t '두 번째 실행에서는 다시 치우지 않아요' test "$(ls -d /app/.shared_old_* | wc -l)" = 1
    GPU_ACCOUNT=gputest /app/shared/bin/gpu _check > "$LOG" 2>&1; t '설치된 gpu 정기 점검이 돌아요(도커 없음)' test $? -le 1
    # 팀원 접속: 명단에 넣고 다시 실행 → 공용 계정으로 로그인해 번호로 이름을 고른다
    printf '홍길동  인지\n' >> /app/shared/team.txt
    bash "$P/admin_setup.sh" < /dev/null > /dev/null 2>&1
    rm -f /app/state/tty/pts-*
    printf '1\necho "WS=$GPU_WS USER=$GPU_USER"\ntype docker | head -1\nexit\n' | timeout 60 script -qec 'su -l gputest' /dev/null > "$LOG" 2>&1
    t '접속하면 이름 목록이 나와요' has "$LOG" '1 홍길동'
    t '번호로 고르면 이름과 작업 폴더가 정해져요' has "$LOG" 'WS=/app/workspace/홍길동 USER=홍길동'
    t '공용 계정의 docker 는 도우미(/app/shared/bin/docker)예요' has "$LOG" 'docker is /app/shared/bin/docker'
    t '알림을 보낼 창(pts)과 이름을 적어 둬요' bash -c 'grep -qx 홍길동 /app/state/tty/pts-*'
}

all=(static docs installers gpu wrapper fetch reports hook system)
sel=("$@"); [ ${#sel[@]} -gt 0 ] || sel=("${all[@]}")
echo "${C}[GPU 서버 저장소] 자동 시험  ($(date '+%Y-%m-%d %H:%M'), $(id -un))${Z}"
for s in "${sel[@]}"; do
    case " ${all[*]} " in *" $s "*) "t_$s" ;; *) echo "모르는 묶음: $s (있는 것: ${all[*]})"; exit 2 ;; esac
done
echo
if [ "$FAIL" = 0 ]; then echo "${G}######## 모두 통과: ${PASS}개 (건너뜀 ${SKIP}개) ########${Z}"
else echo "${RD}######## 실패 ${FAIL}개, 통과 ${PASS}개 (건너뜀 ${SKIP}개) ########${Z}"; exit 1; fi
