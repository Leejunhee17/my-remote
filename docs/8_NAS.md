# NAS 구조·권한·용량 계획

두 GPU 서버가 같이 쓰는 NAS(`/data`)에 무엇을 어디에 두고, 누가 쓸 수 있고, 용량이 얼마나 필요한지 정하는 계획(안)이에요.
NAS는 팀마다 나눠 받는 공간이 아니에요. 여러 팀이 각자 알아서 쓰는 곳이라, 아무렇게나 쓰면 찾기 어렵고 서로 불편해요. 그래서 우리 팀이 쓸 규칙을 정하는 중이에요.
2026-11-03에 두 서버에서 `check_nas.sh` 를 실행해 아래 "정해야 할 것" 의 일부를 채웠어요(`reports/nas_공유용_…txt`). 나머지는 공용 계정 이름을 서버에 적은 뒤 다시 실행해서 채워요.

## 지금 아는 것과 모르는 것

| 항목 | 내용 |
|---|---|
| 주소 | 두 서버 모두 `/data` 에 연결(주소는 서버의 `findmnt /data` 로 확인) |
| 연결 방식 | NFSv3 over RDMA(InfiniBand 400 Gbps), `nconnect=24` |
| 용량 | 전체 414 TB, 쓴 것 2.4 TB(1%). 할당량은 없어요(2026-11-03) |
| 속도 | 파일 1개 쓰기 1.8 GB/s·읽기 4.3 GB/s, 동시 8개 쓰기 12.7 GB/s·읽기 11 GB/s(`docs/4_네트워크.md`) |
| root squash | **안 해요(추정).** 서버의 root 가 root 소유 `/data`(755)에 쓸 수 있어요. 그래서 원칙 3을 꼭 지켜요 |
| `/data/tmp` | root 소유 755(스티키 아님). **팀원(공용 계정)은 여기에 못 써요** |
| 같이 쓰는 곳 | 다른 팀도 같은 NAS를 써요. 팀별 할당량이나 팀 폴더는 따로 없어요. 그래서 **우리 팀 폴더 하나** 를 직접 정해 그 아래에만 둬요 |
| 아직 모르는 것 | 공용 계정이 `/data` 아래에 폴더를 만들 수 있는지, 두 서버의 공용 계정 번호가 같은지(서버에 공용 계정 이름을 아직 안 적어서 확인하지 못했어요) |

모르는 것은 두 서버에서 각각 아래를 실행하면 한 화면에 나와요. 아무것도 바꾸지 않아요. 결과는 `/app/inbox/reports/nas_report_<서버>_<시각>.txt` 에도 남아요. 원본에는 NAS 주소·계정 같은 사내 정보가 있어서, 같이 생기는 공유용(`nas_공유용_…txt`)만 git 으로 올려요(`docs/4_네트워크.md` 의 "결과 가져오기").

```bash
# [서버 1, 서버 2 각각] root
cd /app/inbox && bash check_nas.sh                 # 우리 팀 폴더를 정했으면 뒤에 붙여요: bash check_nas.sh /data/<팀 폴더>
```

## 정한 원칙

1. **우리 팀 폴더 하나 아래에만 만들어요.** 다른 팀 폴더와 NAS 최상위는 건드리지 않아요.
2. **NAS의 파일은 믿지 않고, 가져올 때 지문을 확인해요.** NAS는 팀원 모두(공용 계정)와 다른 팀이 접근할 수 있는 곳이에요. root 가 실행할 파일은 지금처럼 `/app/inbox` 로 새로 복사해 지문을 맞춘 뒤 실행해요.
3. **root 는 NAS에서 직접 쓰거나 실행하지 않아요.** 폴더 만들기·정리는 공용 계정 권한(`runuser -u "$(cat /etc/gpu/account)" --`)으로 해요.
   - 우리 NAS는 root squash 를 하지 않는 것으로 보여요. 그러면 누가 심어 둔 링크를 따라 root 가 서버의 시스템 파일을 덮어쓸 수 있어요.
   - root 로 NAS에 만든 파일은 root 소유가 돼서 팀원이 고치거나 지울 수 없어요.
4. **학습은 `/app`(로컬 SSD)에서 하고, NAS는 보관·전달에만 써요.** 작은 파일이 많은 데이터셋은 NAS에서 직접 읽으면 느려요.
5. **두 서버의 공용 계정 번호(uid·gid)가 같아야 해요.** NFSv3는 이름이 아니라 번호로 주인을 구분해요. 다르면 한 서버에서 만든 파일을 다른 서버에서 못 고쳐요.

## 폴더 구조 (안)

팀 폴더 이름은 아직 정하지 않았어요. 아래에서는 `/data/<팀 폴더>` 로 적었어요.

```text
/data/<팀 폴더>/                     주인 공용 계정, 750 (다른 팀은 못 봐요)
├── originals/                    반입 원본. 지울 일이 거의 없어요
│   ├── datasets/                 접근 PC의 datasets 폴더 그대로(MANIFEST.sha256 포함)
│   ├── models/                   접근 PC의 models 폴더 그대로
│   └── server_setup/<날짜>/       gpu-setup.tar, gpu-docker.tar
├── docker_images/<이름>/          팀원이 만든 도커 이미지 .tar
├── backup/<이름>/                 실험 결과·체크포인트
└── tmp_transfer/                 서버 사이 임시 전달. 14일 지나면 지워요
```

| 폴더 | 누가 써요 | 왜 이렇게 |
|---|---|---|
| 팀 폴더 | 공용 계정(팀원 모두) | 다른 팀이 못 보게 750. GO 같은 비상업 라이선스 데이터셋이 있어요 |
| `originals/` | 관리자(공용 계정 권한으로) | 공용 계정이라 팀원도 고칠 수는 있어요. 그래서 꺼내 쓸 때 지문을 확인해요 |
| `docker_images/<이름>`, `backup/<이름>` | 그 팀원 | 이름별로 나눠 누가 얼마나 쓰는지 주간 보고서로 봐요 |
| `tmp_transfer/` | 누구나 | 옮긴 뒤 지우는 임시 공간이에요 |

- 계정 하나를 같이 쓰니 사람별 권한은 나눌 수 없어요. 서버에서처럼 "이름별 폴더 + 사용량 보고" 로 관리해요.
- 컨테이너 안에서 `--user` 로 만든 파일을 NAS로 옮기면 주인 번호가 이상하게 보여요. NAS로 옮길 때는 서버 화면(컨테이너 밖)에서 `rsync` 로 옮겨요.

## 용량 계획

지금 목록을 기준으로 잡은 값이에요. 팀원 수(N)와 1인당 백업 몫(B)은 정해야 해요.

| 폴더 | 크기 | 근거 |
|---|---|---|
| `originals/datasets` | 약 112 GB | 데이터셋 7개(`docs/5_데이터셋.md`) |
| `originals/models` | 약 334 GB | 기본 모델(`docs/6_모델.md`). 선택 모델을 받으면 늘어요(`vlmxl` 의 Qwen3.5-397B만 406 GB) |
| `originals/server_setup` | 버전마다 1 GB 안팎 | 접근 PC의 `setup\gpu-setup.tar`(아주 작아요)와 `pack_docker\gpu-docker.tar` 크기. 최근 3판만 둬요 |
| `docker_images/` | N × 약 40 GB | PyTorch 기반 이미지 하나 15~25 GB × 사람마다 2개 |
| `backup/` | N × B | 체크포인트가 가장 커요. 예: ViT-L 체크포인트 하나 1~3 GB |
| `tmp_transfer/` | 약 450 GB | 데이터셋과 기본 모델을 한 번에 옮길 때 |

예를 들어 팀원 10명, 1인당 백업 500 GB면 약 112 + 334 + 15 + 400 + 5,000 + 450 ≈ **6.3 TB** 예요. 따로 받는 할당량이 없으니, NAS에 남은 용량이 여기에 30% 여유를 더한 값(약 8.2 TB)보다 많은지 `check_nas.sh` 로 확인해요. 모자라면 1인당 백업 몫(B)을 줄여요.

## 처음 만들기

1. 두 서버에서 `check_nas.sh` 를 실행하고 아래 "정해야 할 것" 을 채워요.
2. 공용 계정이 NAS에 폴더를 만들 수 있으면 직접 만들어요.

   ```bash
   # [서버 1] root. 공용 계정 권한으로 만들어요(원칙 3)
   T=/data/<팀 폴더>
   runuser -u "$(cat /etc/gpu/account)" -- mkdir -p $T/originals/datasets $T/originals/models $T/originals/server_setup $T/docker_images $T/backup $T/tmp_transfer
   runuser -u "$(cat /etc/gpu/account)" -- chmod 750 $T
   bash /app/inbox/check_nas.sh $T                  # 주인·권한·용량 확인
   ```

3. 만들 수 없으면 아래 "서버 관리 팀에 물어볼 것" 을 보고 물어봐요.
4. `/app/admin/gpu.conf` 에 `NAS_DIR=/data/<팀 폴더>` 를 적고 `cd /app/inbox && bash admin_setup.sh` 를 다시 실행해요. 팀원별 `backup/<이름>`, `docker_images/<이름>` 폴더가 생기고, 주간 보고서에 폴더별 사용량과 오래된 `tmp_transfer/` 파일이 나와요. 나중에 팀원을 명단에 추가하면 그때도 다시 실행해요.

## 쓰는 법

### 서버 1: 설치가 끝나면 원본을 NAS에 보관

`/app/inbox` 의 원본을 지우기 전에 해요. 공용 계정 권한으로 옮겨요(원칙 3).

```bash
# [서버 1] root
A=$(cat /etc/gpu/account); T=/data/<팀 폴더>/originals
P=$T/server_setup/$(date +%F)                          # 묶음은 만든 날짜 폴더마다 따로 둬요
runuser -u "$A" -- mkdir -p $P
runuser -u "$A" -- cp /app/inbox/gpu-setup.tar /app/inbox/gpu-docker.tar $P/
runuser -u "$A" -- ls $T/server_setup                 # 날짜 폴더가 4개 이상이면 가장 오래된 것을 지워요(최근 3판만)
runuser -u "$A" -- cp -r /app/inbox/datasets /app/inbox/models $T/
```

### 서버 2: NAS에서 가져와 설치

공용 계정 권한으로 NAS에서 `/app/upload` 로 옮겨 온 뒤에는 서버 1과 같은 순서예요. 지문은 접근 PC의 `D:\gpu\지문_기록.txt` 와 맞춰요.

```bash
# [서버 2] root. 0단계(/etc/gpu/account, /app/inbox·upload 만들기)는 먼저 해 둬요
A=$(cat /etc/gpu/account); T=/data/<팀 폴더>/originals
runuser -u "$A" -- ls $T/server_setup                 # 날짜 폴더 목록. 가장 최근 날짜를 아래 <날짜> 에 적어요
P=$T/server_setup/<날짜>
runuser -u "$A" -- cp $P/gpu-setup.tar $P/gpu-docker.tar /app/upload/
runuser -u "$A" -- cp -r $T/datasets $T/models /app/upload/
```

그다음은 **지문을 보는 줄과 실행하는 줄을 나눠서** 해요. 지문이 `지문_기록.txt` 와 같을 때만 다음 줄을 실행해요.

```bash
# 1단계: 아직 gpu 명령이 없어서 직접 복사해요
cp /app/upload/gpu-setup.tar /app/inbox/ && sha256sum /app/inbox/gpu-setup.tar          # 지문 확인
cd /app/inbox && tar xf gpu-setup.tar && bash admin_setup.sh

# 2~4단계: 여기부터는 gpu fetch 를 써요
/app/admin/bin/gpu fetch gpu-docker.tar                                               # 지문 확인
cd /app/inbox && tar xf gpu-docker.tar && bash docker_install.sh
/app/admin/bin/gpu fetch datasets                                                      # 지문 확인
bash /app/inbox/datasets/datasets_install.sh
/app/admin/bin/gpu fetch models                                                        # 지문 확인
bash /app/inbox/models/models_install.sh
```

### 팀원

| 할 일 | 명령 |
|---|---|
| 실험 결과 보관 | `rsync -a /app/autonomy_sw/<이름>/runs/exp1 /data/<팀 폴더>/backup/<이름>/` |
| 도커 이미지 보관·다른 서버에서 쓰기 | `docker save -o /data/<팀 폴더>/docker_images/<이름>/myseg_v1.tar <이름>/myseg:v1` → 다른 서버에서 `docker load -i` 같은 파일 |
| 서버 사이 큰 파일 전달 | `tmp_transfer/` 에 두고 다른 서버에서 가져간 뒤 지워요 |

- NAS에 지문 파일을 같이 두지 않아요. 누구나 고칠 수 있어서 맞춰 봐도 의미가 없어요.
- root 가 NAS에서 바로 복사하지 않는 이유: root squash 를 하면 root 는 `nobody` 가 되어 750 팀 폴더를 못 읽고, 하지 않으면 원칙 3의 위험이 있어요. 공용 계정 권한으로 `/app/upload` 에 옮겨 오면 서버 1과 같은 순서가 돼요.
- `cp -r` 는 링크를 링크 그대로 복사해요. 설치 스크립트는 복사본에 링크가 있으면 멈춰요.

## 정해야 할 것

`check_nas.sh` 결과로 채워요.

| 항목 | 확인하는 곳 | 결과 |
|---|---|---|
| 우리 팀 폴더 이름·위치 | 팀 회의. 화면의 "바로 아래 폴더" 에서 다른 팀 폴더와 겹치지 않는 이름으로 | |
| 공용 계정이 만들 수 있는지 | 화면의 "공용 계정이 쓸 수 있는 곳" | 아직 몰라요. 공용 계정 이름을 `/etc/gpu/account` 에 적고 다시 실행해요. `/data` 가 root 소유 755라 아마 못 만들어요 |
| root squash | 화면의 "root squash" | 안 해요(추정, root 가 root 소유 755 `/data` 에 쓸 수 있음). 다음 실행부터는 화면에 바로 나와요 |
| 두 서버의 공용 계정 번호가 같은지 | 화면의 "계정 번호"(두 서버에서 모두 실행한 뒤 맞춰 봐요) | 일반 계정 4개(uid 1000~1003)는 두 서버에서 같아 보여요. 공용 계정은 이름을 적은 뒤 확인해요 |
| 전체·남은 용량 | 화면의 "용량" | 전체 414 TB, 남은 것 397 TB(2026-11-03). 계획한 8.2 TB 는 충분해요 |
| 팀원 수(N), 1인당 백업 몫(B) | 팀 회의 | |
| 보관 기간 | 팀 회의(`tmp_transfer/` 14일, 이미지 1인 2개 안) | |
| 스냅숏(실수로 지운 것 되살리기) | 서버 관리 팀 | |

## 서버 관리 팀에 물어볼 것

NAS는 팀마다 나눠 주는 공간이 아니라서 폴더나 할당량을 요청하지는 않아요. 아래 경우에만 물어봐요.

- `/data` 바로 아래의 `1`, `2`, `3`, `12`, `13`, `14`, `18` 은 권한이 644라 폴더가 아니라 root 소유 파일로 보여요(다음 점검부터 화면에 "(파일)" 로 나와요). 누가 왜 만들었는지(명령을 잘못 쳐서 생긴 파일인지).
- `/data/tmp` 를 누구나 쓰는 임시 폴더(1777)로 쓰는 건지. 지금은 root 만 쓸 수 있어요.

- 공용 계정이 `/data` 바로 아래에 폴더를 만들 수 없을 때: 우리 팀 폴더 하나를 만들어 줄 수 있는지(주인 공용 계정, 권한 750).
- 두 서버의 공용 계정 uid·gid가 다를 때: 같은 번호로 맞춰 줄 수 있는지.
- `backup/` 폴더에 스냅숏(예: 하루 한 번, 7일 보관)을 걸 수 있는지. 걸 수 있으면 실수로 지운 체크포인트를 되살릴 수 있어요.
