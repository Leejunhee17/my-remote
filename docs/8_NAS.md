# NAS 구조·권한·용량

두 GPU 서버가 같이 쓰는 NAS(`/data`)에 무엇을 어디에 두고, 누가 쓸 수 있고, 용량이 얼마나 필요한지 정리했어요.
NAS는 팀마다 나눠 받는 공간이 아니라 여러 팀이 각자 알아서 쓰는 곳이에요. 그래서 우리 팀은 **`/data/autonomy_sw` 한 폴더 아래에만** 둬요.
**데이터셋과 모델은 NAS에 한 번만 설치하고 두 서버가 같이 읽어요.** 측정해 보니 NAS가 충분히 빨라서(동시 읽기 11 GB/s, `docs/4_네트워크.md`) 서버마다 따로 들일 필요가 없어요.
2026-11-03에 두 서버에서 NAS 를 점검한 결과는 `reports/nas_공유용_…txt` 에 있어요. 이제 NAS 점검은 서버·네트워크 점검과 함께 `check.sh` 하나로 해요.

## 지금 아는 것과 모르는 것

| 항목 | 내용 |
|---|---|
| 주소 | 두 서버 모두 `/data` 에 연결(주소는 서버의 `findmnt /data` 로 확인) |
| 연결 방식 | NFSv3 over RDMA(InfiniBand 400 Gbps), `nconnect=24` |
| 용량 | 전체 414 TB, 쓴 것 2.4 TB(1%). 할당량은 없어요(2026-11-03) |
| 속도 | 파일 1개 쓰기 1.8 GB/s·읽기 4.3 GB/s, 동시 8개 쓰기 12.7 GB/s·읽기 11 GB/s(`docs/4_네트워크.md`) |
| root squash | **안 해요.** 서버의 root 가 root 소유 `/data`(755)에 쓸 수 있어요. 그래서 원칙 3을 꼭 지켜요 |
| `/data/tmp` | root 소유 755(스티키 아님). **팀원(공용 계정)은 여기에 못 써요** |
| 같이 쓰는 곳 | 다른 팀도 같은 NAS를 써요. 팀별 할당량이나 팀 폴더는 따로 없어요. 우리 팀 폴더는 **`/data/autonomy_sw`** 로 정했어요(`/app/admin/gpu.conf` 의 `NAS_DIR`) |
| 아직 모르는 것 | 두 서버의 공용 계정 번호가 같은지(서버에 공용 계정 이름을 아직 안 적어서 확인하지 못했어요), 이미지처럼 작은 파일을 많이 읽을 때의 속도 |

모르는 것은 두 서버에서 각각 아래를 실행하면 한 화면에 나와요. 아무것도 바꾸지 않고 root 도 필요 없어요(공용 계정으로 실행해요). 결과는 공용 계정 홈의 `check_report_<서버>_<시각>.txt` 에도 남아요. 원본에는 NAS 주소·계정 같은 사내 정보가 있어서, 같이 생기는 공유용(`check_공유용_…txt`)만 git 으로 올려요(`docs/4_네트워크.md` 의 "결과 가져오기").

```bash
# [서버 1, 서버 2 각각] 공용 계정. 팀 폴더는 /app/admin/gpu.conf 의 NAS_DIR(기본 /data/autonomy_sw)을 봐요
cd /app/inbox && bash check.sh       # 1단계 전에는 공용 계정 홈에 올린 것으로: cd ~ && bash check.sh
```

## 정한 원칙

1. **우리 팀 폴더(`/data/autonomy_sw`) 아래에만 만들어요.** 다른 팀 폴더와 NAS 최상위는 건드리지 않아요.
2. **데이터셋·모델은 NAS에 한 번만 두고, 팀원은 읽기만 해요.** 팀 폴더와 `datasets`·`models`·`originals` 는 root 소유예요. 설치는 서버 1의 root 가 한 번 해요.
3. **root 는 root 만 고칠 수 있는 NAS 폴더에만 써요.** 우리 NAS는 root squash 를 하지 않아서, root 가 팀원이 쓸 수 있는 폴더에 쓰면 누가 심어 둔 링크를 따라 서버의 시스템 파일을 덮어쓸 수 있어요.
   - `/data` 가 root 소유(755)라 그 아래 root 소유 팀 폴더는 공용 계정이 바꿔치기할 수 없어요. `admin_setup.sh` 와 설치 스크립트는 경로 전체가 root 만 고칠 수 있는지 확인한 뒤에만 써요.
   - `backup`·`docker_images`·`tmp_transfer` 처럼 팀원이 쓰는 폴더는 공용 계정 권한(`runuser -u "$(cat /etc/gpu/account)" --`)으로만 다뤄요.
4. **NAS에서 실행할 파일을 가져올 때는 지문을 확인해요.** 설치 묶음(`.tar`)은 `/app/upload` 를 거쳐 `/app/inbox` 로 새로 복사하고 지문을 맞춘 뒤 실행해요.
5. **두 서버의 공용 계정 번호(uid·gid)가 같아야 해요.** NFSv3는 이름이 아니라 번호로 주인을 구분해요. 다르면 한 서버에서 만든 파일을 다른 서버에서 못 고치고, 팀 폴더(그룹으로만 읽기)도 못 읽어요.

## 폴더 구조

```text
/data/autonomy_sw/                  root 소유, 그룹 공용 계정, 750 (다른 팀은 못 봐요)
├── datasets/                     데이터셋(설치 스크립트가 풀어요). root 소유 755, 팀원은 읽기만
├── models/                       사전학습 모델. root 소유 755, 팀원은 읽기만
├── originals/
│   └── server_setup/<날짜>/       gpu-setup.tar, gpu-docker.tar(서버 2가 가져가요). root 소유
├── docker_images/<이름>/          팀원이 만든 도커 이미지 .tar. 공용 계정 소유
├── backup/<이름>/                 실험 결과·체크포인트. 공용 계정 소유
└── tmp_transfer/                 서버 사이 임시 전달. 14일 지나면 지워요. 공용 계정 소유
```

컨테이너에는 팀 폴더를 같은 경로로 읽기 전용 연결해요(`-v /data/autonomy_sw:/data/autonomy_sw:ro`). 서버 화면과 컨테이너 안에서 경로가 같아요.

| 폴더 | 누가 써요 | 왜 이렇게 |
|---|---|---|
| 팀 폴더 | root(만들기만) | 다른 팀이 못 보게 750, 그룹은 공용 계정. GO 같은 비상업 라이선스 데이터셋이 있어요 |
| `datasets/`, `models/`, `originals/` | root(설치 스크립트) | 팀원이 실수로 지우거나 바꾸지 못하게 해요 |
| `docker_images/<이름>`, `backup/<이름>` | 그 팀원 | 이름별로 나눠 누가 얼마나 쓰는지 주간 보고서로 봐요 |
| `tmp_transfer/` | 누구나 | 옮긴 뒤 지우는 임시 공간이에요 |

- 계정 하나를 같이 쓰니 사람별 권한은 나눌 수 없어요. 서버에서처럼 "이름별 폴더 + 사용량 보고" 로 관리해요.
- 컨테이너 안에서 `--user` 로 만든 파일을 NAS로 옮기면 주인 번호가 이상하게 보여요. NAS로 옮길 때는 서버 화면(컨테이너 밖)에서 `rsync` 로 옮겨요.
- NAS가 멈추거나 느려지면 학습도 같이 느려져요. 자주 읽는 작은 데이터셋은 각자 `/app/autonomy_sw/<이름>` 에 복사해 써도 돼요.

## 용량 계획

지금 목록을 기준으로 잡은 값이에요. 팀원 수(N)와 1인당 백업 몫(B)은 정해야 해요.

| 폴더 | 크기 | 근거 |
|---|---|---|
| `datasets` | 약 900 GB | 세그 데이터셋 전부와 RELLIS-3D·GO·ORAD-3D 의 라이다·rosbag(`docs/5_데이터셋.md`). 풀면 조금 더 커져요 |
| `models` | 약 334 GB | 기본 모델(`docs/6_모델.md`). 선택 모델을 받으면 늘어요(`vlmxl` 의 Qwen3.5-397B만 406 GB) |
| `originals/server_setup` | 버전마다 1 GB 안팎 | 접근 PC의 `setup\gpu-setup.tar`(아주 작아요)와 `pack_docker\gpu-docker.tar` 크기. 최근 3판만 둬요 |
| `docker_images/` | N × 약 40 GB | PyTorch 기반 이미지 하나 15~25 GB × 사람마다 2개 |
| `backup/` | N × B | 체크포인트가 가장 커요. 예: ViT-L 체크포인트 하나 1~3 GB |
| `tmp_transfer/` | 약 200 GB | 서버 사이에 큰 결과를 옮길 때 |

예를 들어 팀원 10명, 1인당 백업 500 GB면 약 900 + 334 + 3 + 400 + 5,000 + 200 ≈ **6.8 TB** 예요. 30% 여유를 더하면 약 8.9 TB이고, NAS에 남은 용량(397 TB, 2026-11-03)으로 충분해요.

## 처음 만들기

`admin_setup.sh` 가 만들어요. 따로 할 일은 없어요.

- `/app/admin/gpu.conf` 의 `NAS_DIR`(기본 `/data/autonomy_sw`)을 읽어요.
- 그 위 폴더(`/data`)가 NAS로 연결돼 있고 root 만 고칠 수 있으면, 팀 폴더와 `datasets`·`models`·`originals`(root 소유), `backup`·`docker_images`·`tmp_transfer`(공용 계정 소유)와 팀원별 폴더를 만들어요.
- NAS가 없거나, root squash 로 root 가 쓸 수 없거나, 팀 폴더를 root 말고도 고칠 수 있으면 `[주의]` 를 남기고 만들지 않아요. 그러면 데이터셋·모델 설치도 멈춰요.
- 예전 `/app/shared` 에 데이터셋·모델이 있으면 NAS로 옮기는 명령을 화면에 보여 줘요. `tmux` 안에서 실행하세요.

```bash
# [서버 1] root. admin_setup.sh 뒤에 확인
ls -ld /data/autonomy_sw /data/autonomy_sw/*                                 # 주인·권한
QUICK=1 bash /app/inbox/check.sh                       # 공용 계정으로. 팀 폴더의 주인·권한·용량(속도 측정 없이)
```

## 쓰는 법

### 서버 1: 데이터셋·모델 설치

`docs/1_처음_설치.md` 의 3·4단계 그대로예요. 설치 스크립트가 `/data/autonomy_sw/datasets`, `models` 에 풀어요. 한 번만 하면 서버 2에서도 바로 보여요.

설치가 끝나면 서버 2가 쓸 설치 묶음을 NAS에 남겨 둬요.

```bash
# [서버 1] root. originals 는 root 소유라 root 가 바로 복사해요(원칙 3)
P=/data/autonomy_sw/originals/server_setup/$(date +%F)       # 묶음은 만든 날짜 폴더마다 따로 둬요
mkdir -p $P && cp /app/inbox/gpu-setup.tar /app/inbox/gpu-docker.tar $P/
ls /data/autonomy_sw/originals/server_setup                 # 날짜 폴더가 4개 이상이면 가장 오래된 것을 지워요(최근 3판만)
```

### 서버 2: 설치 묶음만 가져와 설치

데이터셋·모델은 서버 1이 NAS에 설치한 것을 그대로 읽어서 할 일이 없어요. 설치 묶음 두 개만 NAS에서 가져와요. 지문은 접근 PC의 `D:\gpu\지문_기록.txt` 와 맞춰요.

```bash
# [서버 2] root. 0단계(/etc/gpu/account, /app/inbox·upload 만들기)는 먼저 해 둬요
ls /data/autonomy_sw/originals/server_setup                 # 가장 최근 날짜를 아래 <날짜> 에 적어요
P=/data/autonomy_sw/originals/server_setup/<날짜>
cp $P/gpu-setup.tar $P/gpu-docker.tar /app/inbox/ && sha256sum /app/inbox/gpu-*.tar   # root 만 고치는 곳끼리 복사. 지문 확인
```

`originals` 와 `/app/inbox` 는 둘 다 root 만 고칠 수 있어서 `/app/upload` 를 거치지 않아요. 지문이 `지문_기록.txt` 와 같을 때만 다음 줄을 실행해요.

```bash
cd /app/inbox && tar xf gpu-setup.tar && bash admin_setup.sh       # 1단계
cd /app/inbox && tar xf gpu-docker.tar && bash docker_install.sh   # 2단계
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
| 누가 팀 폴더를 만드는지 | | root 가 만들어요(`admin_setup.sh`). `/data` 가 root 소유 755라 공용 계정은 만들 수 없어요 |
| root squash | root 로만 알 수 있어서 `check.sh` 는 보지 않아요. 2026-11-03 점검 결과와 `admin_setup.sh` 화면 | 안 해요(root 가 root 소유 755 `/data` 에 쓸 수 있음) |
| 두 서버의 공용 계정 번호가 같은지 | 화면의 "상대 서버 찾기"(두 서버에서 함께 실행하면 맞춰 봐요), "계정 번호" | 일반 계정 4개(uid 1000~1003)는 두 서버에서 같아 보여요. 공용 계정은 이름을 적은 뒤 확인해요 |
| 전체·남은 용량 | 화면의 "용량" | 전체 414 TB, 남은 것 397 TB(2026-11-03). 계획한 약 9 TB 는 충분해요 |
| 팀원 수(N), 1인당 백업 몫(B) | 팀 회의 | |
| 보관 기간 | 팀 회의(`tmp_transfer/` 14일, 이미지 1인 2개 안) | |
| 스냅숏(실수로 지운 것 되살리기) | 서버 관리 팀 | |

## 서버 관리 팀에 물어볼 것

NAS는 팀마다 나눠 주는 공간이 아니라서 폴더나 할당량을 요청하지는 않아요. 아래 경우에만 물어봐요.

- `/data` 바로 아래의 `1`, `2`, `3`, `12`, `13`, `14`, `18` 은 권한이 644라 폴더가 아니라 root 소유 파일로 보여요(다음 점검부터 화면에 "(파일)" 로 나와요). 누가 왜 만들었는지(명령을 잘못 쳐서 생긴 파일인지).
- `/data/tmp` 를 누구나 쓰는 임시 폴더(1777)로 쓰는 건지. 지금은 root 만 쓸 수 있어요.

- `/data/autonomy_sw` 를 우리 팀 폴더로 쓴다고 알려 두기. 나중에 root squash 를 켜면 root 가 이 폴더에 설치할 수 없게 되니, 켤 계획이 있는지도 물어봐요.
- 두 서버의 공용 계정 uid·gid가 다를 때: 같은 번호로 맞춰 줄 수 있는지.
- `backup/` 폴더에 스냅숏(예: 하루 한 번, 7일 보관)을 걸 수 있는지. 걸 수 있으면 실수로 지운 체크포인트를 되살릴 수 있어요.
