# NAS 구조·권한·용량

두 GPU 서버가 같이 쓰는 NAS(`/data`)에 무엇을 어디에 두고, 누가 쓸 수 있고, 용량이 얼마나 필요한지 정리했어요.
NAS는 팀마다 나눠 받는 공간이 아니라 여러 팀이 각자 알아서 쓰는 곳이에요. 그래서 우리 팀은 **`/data/autonomy_sw` 한 폴더 아래에만** 둬요.
**데이터셋과 모델은 NAS에 한 번만 두고 두 서버가 같이 읽어요.** 측정해 보니 NAS가 충분히 빨라서(동시 읽기 11 GB/s, `admin/4_네트워크.md`) 서버마다 따로 설치할 필요가 없어요.
2026-11-06에 두 서버에서 점검한 결과는 `reports/check_공유용_…_20261106-*.txt` 에 있어요. NAS 점검은 서버·네트워크 점검과 함께 `check.sh` 하나로 해요.

> **2026-11-06 점검에서 바뀐 것: 지금은 팀 폴더가 잠겨 있지 않아요.** 11-03에는 `/data` 가 root 소유 755(root 만 고치고 누구나 읽는 권한)였는데, 지금은 공용 계정(팀원이 같이 쓰는 서버 계정)이 `/data` 에 쓸 수 있어요. 팀 폴더(`/data/autonomy_sw`)도 공용 계정 소유 755라 다른 팀도 읽을 수 있어요. 아래 "이미 있는 팀 폴더 잠그기" 대로 고쳐요. 그 안의 `datasets`·`models`·`backup`·`inbox` 가 공용 계정 소유인 것은 정한 대로예요(팀원이 써요). 고치기 전에는 root 가 NAS에 쓰지 않아서 `check.sh` 의 NAS 속도 측정과 1단계의 팀 폴더 만들기를 건너뛰어요. 사용자의 4·5단계(데이터셋·모델)는 공용 계정으로 하니 상관없어요.

## 지금 아는 것과 모르는 것

| 항목 | 내용 |
|---|---|
| 주소 | 두 서버 모두 `/data` 에 연결(주소는 서버의 `findmnt /data` 로 확인) |
| 연결 방식 | NFSv3(네트워크로 폴더를 함께 쓰는 방식) over RDMA(CPU를 거치지 않고 메모리끼리 바로 주고받는 방식. InfiniBand 400 Gbps), `nconnect=24` |
| 용량 | 전체 414 TB, 쓴 것 2.8 TB(1%). 할당량은 없어요(2026-11-06) |
| 속도 | 파일 1개 쓰기 1.9 GB/s·읽기 4.3 GB/s, 동시 8개 쓰기 12.9~13.1 GB/s·읽기 8.0~11.2 GB/s(`admin/4_네트워크.md`) |
| `/data` 최상위 | 11-03에는 root 소유 755였어요. **11-06에는 공용 계정이 쓸 수 있어요**(누가 바꿨는지 서버 관리 팀에 확인). root 소유 755로 돌려야 해요 |
| root squash(NAS가 서버의 root 를 일반 사용자로 낮춰 다루는 설정) | **안 해요**(11-03 확인. 11-06에는 `/data` 가 root 소유 755가 아니라서 다시 확인하지 못했어요). 서버의 root 가 NAS에서도 root 예요. 그래서 원칙 3을 꼭 지켜요 |
| `/data/tmp` | root 소유 755(스티키 비트 없음. 스티키 비트는 남의 파일을 못 지우게 하는 설정이에요). **팀원(공용 계정)은 여기에 못 써요** |
| 같이 쓰는 곳 | 다른 팀도 같은 NAS를 써요. 팀별 할당량이나 팀 폴더는 따로 없어요. 우리 팀 폴더는 **`/data/autonomy_sw`** 로 정했어요(`/app/admin/gpu.conf` 의 `NAS_DIR`) |
| 팀 폴더 지금 상태 | `/data/autonomy_sw` 와 `backup`·`datasets`·`inbox`·`models` 가 있어요. 모두 공용 계정(uid 1001) 소유 755예요(2026-11-06). 데이터셋·모델은 들어 있어요 |
| 공용 계정 번호 | 두 서버 모두 uid 1001, gid 1001 로 같아요(2026-11-06) |
| 아직 모르는 것 | 누가 `/data` 권한을 바꾸고 팀 폴더를 공용 계정으로 만들었는지, 이미지처럼 작은 파일을 많이 읽을 때의 속도 |

모르는 것은 두 서버에서 각각 아래를 실행하면 한 화면에 나와요. 아무것도 바꾸지 않아요. root 로 실행하고, 결과는 공용 계정 홈의 `check_report_<서버>_<시각>.txt` 에도 남아요. 원본에는 NAS 주소·계정 같은 사내 정보가 있어서, 같이 생기는 공유용(`check_공유용_…txt`)만 git 으로 올려요(`admin/4_네트워크.md` 의 "결과 가져오기").

```bash
# [서버 1, 서버 2 각각] root. 팀 폴더는 /app/admin/gpu.conf 의 NAS_DIR(기본 /data/autonomy_sw)을 봐요
bash /app/inbox/check.sh       # 1단계 전에는 admin/1_처음_설치.md 의 "0단계: 서버 점검" 대로
```

## 정한 원칙

1. **우리 팀 폴더(`/data/autonomy_sw`) 아래에만 만들어요.** 다른 팀 폴더와 NAS 최상위는 건드리지 않아요.
2. **데이터셋·모델은 NAS에 한 번만 두고 두 서버가 같이 읽어요.** 넣는 일은 사용자(공용 계정) 몫이고, 규칙은 자리뿐이에요. 데이터셋은 `datasets/<데이터셋 폴더>/`, 모델은 `models/<만든 곳>/<모델>/` 에 둬요(`user/데이터셋_넣기.md`, `user/모델_넣기.md`). root 소유는 팀 폴더 자체와 `originals` 뿐이에요.
3. **root 는 root 만 고칠 수 있는 NAS 폴더에만 써요.** 우리 NAS는 root squash 를 하지 않아서, root 가 팀원이 쓸 수 있는 폴더에 쓰면 누가 심어 둔 링크를 따라 서버의 시스템 파일을 덮어쓸 수 있어요.
   - `/data` 가 root 소유(755)라 그 아래 root 소유 팀 폴더는 공용 계정이 바꿔치기할 수 없어요. `prepare.sh` 는 경로 전체가 root 만 고칠 수 있는지 확인한 뒤에만 써요.
   - `datasets`·`models`·`backup`·`docker_images`·`tmp_transfer`·`inbox` 처럼 팀원이 쓰는 폴더는 root 가 다루지 않거나, 공용 계정 권한(`runuser -u "$(cat /etc/gpu/account)" --`)으로만 다뤄요.
4. **NAS에서 실행할 파일을 가져올 때는 지문(파일 내용으로 계산한 sha256 값)을 확인해요.** 설치 묶음(`.tar`)은 NAS 의 `inbox` 에서 `/app/inbox` 로 새로 복사하고(`gpu fetch`) 지문을 맞춘 뒤 실행해요.
5. **두 서버의 공용 계정 번호(uid·gid)가 같아야 해요.** NFSv3는 이름이 아니라 번호로 주인을 구분해요. 다르면 한 서버에서 만든 파일을 다른 서버에서 못 고치고, 팀 폴더(그룹으로만 읽기)도 못 읽어요.

## 폴더 구조

```text
/data/autonomy_sw/                  root 소유, 그룹 공용 계정, 750 (다른 팀은 못 봐요)
├── datasets/<데이터셋 폴더>/       데이터셋(사용자가 4단계에서 넣어요). 공용 계정 소유
├── models/<만든 곳>/<모델>/        사전학습 모델(사용자가 5단계에서 넣어요). 공용 계정 소유
├── originals/
│   └── server_setup/<날짜>/       설치 묶음 보관본(최근 3판). root 소유
├── docker_images/<이름>/          팀원이 만든 도커 이미지 .tar. 공용 계정 소유
├── backup/<이름>/                 실험 결과·체크포인트. 공용 계정 소유
├── inbox/                        올리는 곳(관리자: check.sh, 설치 묶음 .tar / 사용자: datasets/, models/). 다른 파일이 있어도 괜찮아요. 공용 계정 소유
└── tmp_transfer/                 서버 사이 임시 전달. 14일 지나면 지워요. 공용 계정 소유
```

컨테이너에는 팀 폴더를 같은 경로에 읽기 전용으로 연결해요(`-v /data/autonomy_sw:/data/autonomy_sw:ro`). 서버 화면과 컨테이너 안에서 경로가 같아요.

| 폴더 | 누가 써요 | 왜 이렇게 |
|---|---|---|
| 팀 폴더 | root(만들기만) | 다른 팀이 못 보게 750, 그룹은 공용 계정. GO 같은 비상업 라이선스 데이터셋이 있어요 |
| `datasets/`, `models/` | 사용자(공용 계정) | 규칙은 자리뿐이에요. 같은 이름의 폴더를 덮어쓰지만 않으면 돼요 |
| `originals/` | root | 관리자가 설치 묶음을 보관하는 곳이에요 |
| `docker_images/<이름>`, `backup/<이름>` | 그 팀원 | 이름별로 나눠 누가 얼마나 쓰는지 주간 보고서로 봐요 |
| `tmp_transfer/` | 누구나 | 옮긴 뒤 지우는 임시 공간이에요 |
| `inbox/` | 관리자·사용자(FileZilla) | 한 번 올려 두 서버에서 써요. 다 쓰면 올린 사람이 지워요 |

- 계정 하나를 같이 쓰니 사람별 권한은 나눌 수 없어요. 서버에서처럼 "이름별 폴더 + 사용량 보고" 로 관리해요.
- 컨테이너 안에서 `--user` 로 만든 파일을 NAS로 옮기면 주인 번호가 이상하게 보여요. NAS로 옮길 때는 서버 화면(컨테이너 밖)에서 `rsync` 로 옮겨요.
- NAS가 멈추거나 느려지면 학습도 같이 느려져요. 자주 읽는 작은 데이터셋은 각자 `/app/autonomy_sw/<이름>` 에 복사해 써도 돼요.

## 용량 계획

지금 목록을 기준으로 잡은 값이에요. 팀원 수(N)와 1인당 백업 몫(B)은 정해야 해요.

| 폴더 | 크기 | 근거 |
|---|---|---|
| `datasets` | 약 900 GB | 세그 데이터셋 전부와 RELLIS-3D·GO·ORAD-3D 의 라이다·rosbag(`user/데이터셋_넣기.md`). 풀면 조금 더 커져요 |
| `models` | 약 334 GB | 기본 모델(`user/모델_넣기.md`). 선택 모델을 받으면 늘어요(`vlmxl` 의 Qwen3.5-397B만 406 GB) |
| `originals/server_setup` | 버전마다 1 GB 안팎 | 접근 PC(인터넷이 되는 윈도우 PC)의 `setup\gpu-setup.tar`(아주 작아요), `pack_pkgs\gpu-pkgs.tar`(70 MB 안팎), `pack_docker\gpu-docker.tar` 크기. 최근 3판만 둬요 |
| `docker_images/` | N × 약 40 GB | PyTorch 기반 이미지 하나 15~25 GB × 사람마다 2개 |
| `backup/` | N × B | 체크포인트가 가장 커요. 예: ViT-L 체크포인트 하나 1~3 GB |
| `tmp_transfer/` | 약 200 GB | 서버 사이에 큰 결과를 옮길 때 |

예를 들어 팀원 10명, 1인당 백업 500 GB면 약 900 + 334 + 3 + 400 + 5,000 + 200 ≈ **6.8 TB** 예요. 30% 여유를 더하면 약 8.9 TB이고, NAS에 남은 용량(397 TB, 2026-11-03)으로 충분해요.

## 처음 만들기

1단계 준비(`prepare.sh`)가 만들어요. 따로 할 일은 없어요.

- `/app/admin/gpu.conf` 의 `NAS_DIR`(기본 `/data/autonomy_sw`)을 읽어요.
- 그 위 폴더(`/data`)가 NAS로 연결돼 있고 root 만 고칠 수 있으면, 팀 폴더와 `originals`(root 소유), `datasets`·`models`·`inbox`·`backup`·`docker_images`·`tmp_transfer`(공용 계정 소유)를 만들어요. 이미 있는 폴더는 그 폴더의 주인만 맞추고 안의 파일은 그대로 둬요. 팀원별 폴더(`backup/<이름>`, `docker_images/<이름>`)는 6단계 `admin_setup.sh` 가 명단을 보고 만들어요.
- NAS가 없거나, root squash 로 root 가 쓸 수 없거나, 팀 폴더를 root 말고도 고칠 수 있으면 `[주의]` 를 남기고 만들지 않아요. 이미 `datasets`·`models` 가 있고 공용 계정이 쓸 수 있으면 4·5단계는 그대로 할 수 있어요.
- 예전 `/app/shared` 에 데이터셋·모델이 있으면 NAS로 옮기는 명령을 화면에 보여 줘요. `tmux` 안에서 실행하세요.

```bash
# [서버 1] root. prepare.sh 뒤에 확인
ls -ld /data/autonomy_sw /data/autonomy_sw/*                                 # 주인·권한
QUICK=1 bash /app/inbox/check.sh                       # 팀 폴더의 주인·권한·용량, 공용 계정이 쓸 수 있는지(속도 측정 없이)
```

## 이미 있는 팀 폴더 잠그기

팀 폴더를 공용 계정이 먼저 만들었으면(2026-11-06 지금 상태) `prepare.sh` 는 `[주의]` 만 남기고 손대지 않아요. 아래 순서로 root 가 직접 잠가요. **순서를 바꾸지 마세요.** 위 폴더를 먼저 잠가야 아래 폴더를 바꿔치기할 수 없어요.

1. **서버 관리 팀에 `/data` 를 root 소유 755로 돌려 달라고 해요.** `check.sh` 의 "서버 관리 팀에 요청할 것" 에 나와요. 이것이 안 되면 2단계부터 하지 마세요. `/data` 를 남이 고칠 수 있으면 팀 폴더를 잠가도 폴더째 옮기고 링크로 바꿔치기할 수 있어요.
2. 팀원에게 잠시 팀 폴더를 쓰지 말라고 알리고, 서버 1에서 root 로 실행해요.

```bash
# [서버 1] root. <계정이름> 을 공용 계정 이름으로 바꿔요. /data 가 root 소유 755 가 된 뒤에만
T=/data/autonomy_sw; G=$(id -gn <계정이름>)
stat -c '%U %a' /data                                              # root 755 인지 다시 확인
chown root:$G $T && chmod 750 $T                                   # 팀 폴더: root 만 고치고, 공용 계정 그룹만 읽어요
ls -ld $T $T/*
```

- `datasets`·`models`·`backup`·`inbox` 는 공용 계정 소유 그대로 둬요(팀원이 쓰는 곳). `docker_images`·`tmp_transfer`·`originals` 는 1단계 `prepare.sh` 가 만들어요.
- 다 되면 두 서버에서 `check.sh` 를 다시 실행해 팀 폴더 줄에 `[문제]` 가 없는지 봐요.

## 쓰는 법

### 사용자: 데이터셋·모델 넣기

사용자가 공용 계정으로 `/data/autonomy_sw/datasets`, `models` 에 넣어요(`user/데이터셋_넣기.md`, `user/모델_넣기.md`). 두 서버 중 한 곳에서 한 번만 하면 다른 서버에서도 바로 보여요.

### 관리자: 설치 묶음 보관

설치 묶음은 NAS inbox 에 올린 그대로 두 서버가 함께 써요. 두 서버에서 모두 설치한 뒤 보관하고 싶으면 root 가 `originals` 로 옮겨 둬요.

```bash
# [서버 1 또는 2] root. 두 서버에서 모두 설치한 뒤. originals 는 root 소유라 root 가 바로 복사해요(원칙 3)
P=/data/autonomy_sw/originals/server_setup/$(date +%F)       # 묶음은 날짜 폴더마다 따로 둬요
mkdir -p $P && cp /app/inbox/gpu-setup.tar /app/inbox/gpu-pkgs.tar /app/inbox/gpu-docker.tar $P/
ls /data/autonomy_sw/originals/server_setup                 # 날짜 폴더가 4개 이상이면 가장 오래된 것을 지워요(최근 3판만)
```

### 관리자: 다른 서버에도 설치

데이터셋·모델은 이미 NAS에 넣은 것을 그대로 읽어서 할 일이 없어요. 설치 묶음 세 개만 NAS inbox 에서 가져와요. 지문은 접근 PC의 `D:\gpu\지문_기록.txt` 와 맞춰요.

```bash
# [서버 2] root. 1단계의 "처음 한 번"(/etc/gpu/account, /app/inbox 만들기)은 먼저 해 둬요
cp /data/autonomy_sw/inbox/gpu-setup.tar /app/inbox/ && sha256sum /app/inbox/gpu-setup.tar   # 지문 확인
cd /app/inbox && tar xf gpu-setup.tar && bash prepare.sh            # 1단계 준비(같을 때만)
/app/admin/bin/gpu fetch gpu-pkgs.tar                               # 지문 확인
cd /app/inbox && tar xf gpu-pkgs.tar && bash pkgs_install.sh        # 2단계 기초 프로그램(같을 때만)
/app/admin/bin/gpu fetch gpu-docker.tar                             # 지문 확인
cd /app/inbox && tar xf gpu-docker.tar && bash docker_install.sh    # 3단계 도커(같을 때만)
cd /app/inbox && bash admin_setup.sh                                # 6단계 권한·규칙 설정
```

### 팀원

| 할 일 | 명령 |
|---|---|
| 실험 결과 보관 | `rsync -a /app/autonomy_sw/<이름>/runs/exp1 /data/autonomy_sw/backup/<이름>/` |
| 도커 이미지 보관·다른 서버에서 쓰기 | `docker save -o /data/autonomy_sw/docker_images/<이름>/myseg_v1.tar <이름>/myseg:v1` → 다른 서버에서 `docker load -i` 같은 파일 |
| 서버 사이 큰 파일 전달 | `tmp_transfer/` 에 두고 다른 서버에서 가져간 뒤 지워요 |

- 데이터셋·모델은 서버 경로 그대로 읽어요: `/data/autonomy_sw/datasets/...`, `/data/autonomy_sw/models/...`(컨테이너 안에서도 같아요).
- 설치 묶음은 NAS에서 바로 실행하지 않고 `/app/inbox` 로 복사해 지문을 맞춘 뒤 실행해요(원칙 4).

## 정해야 할 것

`check.sh` 결과의 NAS 부분으로 채워요.

| 항목 | 확인하는 곳 | 결과 |
|---|---|---|
| 우리 팀 폴더 이름·위치 | 팀 회의 | `/data/autonomy_sw`(정함) |
| 누가 팀 폴더를 만드는지 | | root 가 만들어요(`prepare.sh`). 그런데 11-06에는 공용 계정이 이미 만들어 둔 상태였어요. 위 "이미 있는 팀 폴더 잠그기" 로 root 소유로 바꿔요 |
| root squash | 화면의 "root squash"(root 로 실행했을 때) | 안 해요(11-03, root 가 root 소유 755 `/data` 에 쓸 수 있었음). `/data` 를 되돌린 뒤 다시 확인해요 |
| 두 서버의 공용 계정 번호가 같은지 | 화면의 "상대 서버 찾기"(두 서버에서 함께 실행하면 맞춰 봐요), "계정 번호" | 같아요(uid 1001, gid 1001, 2026-11-06) |
| 전체·남은 용량 | 화면의 "용량" | 전체 414 TB, 남은 것 396 TB(2026-11-06). 계획한 약 9 TB 는 충분해요 |
| 팀원 수(N), 1인당 백업 몫(B) | 팀 회의 | |
| 보관 기간 | 팀 회의(`tmp_transfer/` 14일, 이미지 1인 2개 안) | |
| 스냅숏(실수로 지운 것 되살리기) | 서버 관리 팀 | |

## 서버 관리 팀에 물어볼 것

NAS는 팀마다 나눠 주는 공간이 아니라서 폴더나 할당량을 요청하지는 않아요. 아래 경우에만 물어봐요.

- `/data` 바로 아래의 `1`, `2`, `3`, `12`, `13`, `14`, `18` 은 권한이 644라 폴더가 아니라 root 소유 파일로 보여요(다음 점검부터 화면에 "(파일)" 로 나와요). 누가 왜 만들었는지(명령을 잘못 쳐서 생긴 파일인지).
- `/data/tmp` 를 누구나 쓰는 임시 폴더(1777)로 쓰는 건지. 지금은 root 만 쓸 수 있어요.
- **`/data` 최상위를 누가 왜 공용 계정이 쓸 수 있게 바꿨는지**(11-03 root 소유 755 → 11-06 공용 계정이 씀). root 소유 755로 돌려 달라고 해요. 다른 팀도 이 때문에 남의 폴더를 옮기거나 지울 수 있어요.

- `/data/autonomy_sw` 를 우리 팀 폴더로 쓴다고 알려요. 나중에 root squash 를 켜면 root 가 팀 폴더를 만들거나 관리할 수 없게 되니, 켤 계획이 있는지도 물어봐요.
- 두 서버의 공용 계정 uid·gid가 다를 때: 같은 번호로 맞춰 줄 수 있는지.
- `backup/` 폴더에 스냅숏(예: 하루 한 번, 7일 보관)을 걸 수 있는지. 걸 수 있으면 실수로 지운 체크포인트를 되살릴 수 있어요.
