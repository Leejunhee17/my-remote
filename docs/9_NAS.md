# NAS 구조·권한·용량 계획

두 B200 서버가 같이 쓰는 NAS(`/data`)에 무엇을 어디에 두고, 누가 쓸 수 있고, 얼마나 필요한지 정한 계획이에요.
아직 모르는 것(용량, 권한, 계정 번호)은 `check_nas.sh` 로 확인한 뒤 아래 "정해야 할 것" 을 채워 확정해요.

## 지금 아는 것과 모르는 것

| 항목 | 내용 |
|---|---|
| 주소 | 두 서버 모두 `/data` 에 연결(주소는 서버의 `findmnt /data` 로 확인) |
| 연결 방식 | NFSv3 over RDMA(InfiniBand 400 Gbps), `nconnect=24` |
| 속도 | 파일 1개 쓰기 1.82 GB/s, 읽기 4.3 GB/s(`docs/4_네트워크.md`) |
| 같이 쓰는 곳 | 다른 팀도 같은 NAS를 써요. 그래서 **우리 팀 폴더 하나 아래에만** 구조를 만들어요 |
| 아직 모르는 것 | 전체·남은 용량, 우리 팀 몫(할당량), 우리가 폴더를 만들 수 있는지, root squash, 두 서버의 공용 계정 번호가 같은지 |

모르는 것은 두 서버에서 각각 아래를 실행하면 한 화면에 나와요. 바꾸는 것은 없어요. 결과는 `/app/inbox/reports/nas_report_<서버>_<시각>.txt` 에도 남아요. 원본에는 NAS 주소·계정 같은 사내 정보가 있어서, 같이 생기는 공유용(`nas_공유용_…txt`)만 git 으로 올려요(`docs/4_네트워크.md` 의 "결과 가져오기").

```bash
# [서버 1, 서버 2 각각] root
cd /app/inbox && bash check_nas.sh                 # 우리 팀 폴더를 정했으면 뒤에 붙여요: bash check_nas.sh /data/<팀 폴더>
```

## 정한 원칙

1. **우리 팀 폴더 하나 아래에만 만들어요.** 다른 팀 폴더와 NAS 최상위는 건드리지 않아요.
2. **NAS의 파일은 믿지 않고, 가져올 때 지문을 확인해요.** NAS는 팀원 모두(공용 계정)와 다른 팀이 닿는 곳이에요. root 가 실행할 것은 지금처럼 `/app/inbox` 로 새로 복사하고 지문을 맞춘 뒤 실행해요.
3. **root 는 NAS에서 직접 쓰거나 실행하지 않아요.** 폴더 만들기·정리는 공용 계정 권한(`runuser -u "$(cat /etc/b200/account)" --`)으로 해요.
   - NAS가 root squash 를 하면 root 는 어차피 `nobody` 로 바뀌어 우리 폴더에 못 써요.
   - 하지 않으면, 누가 심어 둔 링크를 따라 root 가 서버의 시스템 파일을 덮을 수 있어요.
4. **학습은 `/app`(로컬 SSD)에서, NAS는 보관·전달용이에요.** 작은 파일이 많은 데이터셋은 NAS에서 직접 읽으면 느려요.
5. **두 서버의 공용 계정 번호(uid·gid)가 같아야 해요.** NFSv3는 이름이 아니라 번호로 주인을 구분해요. 다르면 한 서버에서 만든 파일을 다른 서버에서 못 고쳐요.

## 폴더 구조 (안)

팀 폴더 이름은 정해야 해요. 아래는 `/data/<팀 폴더>` 로 적은 모양이에요.

```text
/data/<팀 폴더>/                     주인 공용 계정, 750 (다른 팀은 못 봐요)
├── originals/                    반입 원본. 지울 일이 거의 없어요
│   ├── datasets/                 접근 PC의 datasets 폴더 그대로(MANIFEST.sha256 포함)
│   ├── models/                   접근 PC의 models 폴더 그대로
│   └── server_setup/<날짜>/       b200-pack.tar, b200-docker.tar
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

- 계정 하나를 같이 쓰니 사람별 권한은 나눌 수 없어요. 서버와 같이 "이름별 폴더 + 사용량 보고" 로 관리해요.
- 컨테이너 안에서 `--user` 로 만든 파일을 NAS로 옮기면 주인 번호가 이상하게 보여요. NAS로 옮길 때는 서버 화면(컨테이너 밖)에서 `rsync` 로 옮겨요.

## 용량 계획

지금 목록 기준 값이에요. 팀원 수(N)와 1인당 백업 몫(B)은 정해야 해요.

| 폴더 | 크기 | 근거 |
|---|---|---|
| `originals/datasets` | 약 112 GB | 데이터셋 7개(`docs/6_데이터셋.md`) |
| `originals/models` | 약 132 GB | 기본 모델(`docs/7_모델.md`). 선택 모델을 받으면 늘어요 |
| `originals/server_setup` | 버전마다 몇 GB | 접근 PC의 `pack\b200-pack.tar` 크기. 최근 3판만 둬요 |
| `docker_images/` | N × 약 40 GB | PyTorch 기반 이미지 하나 15~25 GB × 사람마다 2개 |
| `backup/` | N × B | 체크포인트가 가장 커요. 예: ViT-L 체크포인트 하나 1~3 GB |
| `tmp_transfer/` | 약 250 GB | 데이터셋과 모델을 한 번에 옮길 때 |

예를 들어 팀원 10명, 1인당 백업 500 GB면 약 112 + 132 + 15 + 400 + 5,000 + 250 ≈ **5.9 TB** 예요. 할당량은 여기에 30% 여유를 더해 요청해요(약 7.7 TB).

## 처음 만들기

1. 두 서버에서 `check_nas.sh` 를 실행하고 아래 "정해야 할 것" 을 채워요.
2. 공용 계정이 NAS에 폴더를 만들 수 있으면 직접 만들어요.

   ```bash
   # [서버 1] root. 공용 계정 권한으로 만들어요(원칙 3)
   T=/data/<팀 폴더>
   runuser -u "$(cat /etc/b200/account)" -- mkdir -p $T/originals/datasets $T/originals/models $T/originals/server_setup $T/docker_images $T/backup $T/tmp_transfer
   runuser -u "$(cat /etc/b200/account)" -- chmod 750 $T
   bash /app/inbox/check_nas.sh $T                  # 주인·권한·용량 확인
   ```

3. 만들 수 없으면 아래 "서버 관리 팀에 요청할 것" 으로 요청해요.
4. `/app/shared/b200.conf` 에 `NAS_DIR=/data/<팀 폴더>` 를 적고 `cd /app/inbox && bash admin_setup.sh` 를 다시 실행해요. 팀원별 `backup/<이름>`, `docker_images/<이름>` 폴더가 생기고, 주간 보고서에 폴더별 사용량과 오래된 `tmp_transfer/` 파일이 나와요. 나중에 팀원을 명단에 더하면 그때도 다시 실행해요.

## 쓰는 법

### 서버 1: 설치가 끝나면 원본을 NAS에 보관

`/app/inbox` 의 원본을 지우기 전에 해요. 공용 계정 권한으로 옮겨요(원칙 3).

```bash
# [서버 1] root
A=$(cat /etc/b200/account); T=/data/<팀 폴더>/originals
P=$T/server_setup/$(date +%F)                          # 묶음은 만든 날짜 폴더마다 따로 둬요
runuser -u "$A" -- mkdir -p $P
runuser -u "$A" -- cp /app/inbox/b200-pack.tar /app/inbox/b200-docker.tar $P/
runuser -u "$A" -- ls $T/server_setup                 # 날짜 폴더가 4개 이상이면 가장 오래된 것을 지워요(최근 3판만)
runuser -u "$A" -- cp -r /app/inbox/datasets /app/inbox/models $T/
```

### 서버 2: NAS에서 가져와 설치

공용 계정이 NAS에서 `/app/upload` 로 옮겨 오면, 그다음은 서버 1과 같은 순서예요. 지문은 접근 PC의 `D:\b200\지문_기록.txt` 와 맞춰요.

```bash
# [서버 2] root. 0단계(/etc/b200/account, /app/inbox·upload 만들기)는 먼저 해 둬요
A=$(cat /etc/b200/account); T=/data/<팀 폴더>/originals
runuser -u "$A" -- ls $T/server_setup                 # 날짜 폴더 목록. 가장 최근 날짜를 아래 <날짜> 에 적어요
P=$T/server_setup/<날짜>
runuser -u "$A" -- cp $P/b200-pack.tar $P/b200-docker.tar /app/upload/
runuser -u "$A" -- cp -r $T/datasets $T/models /app/upload/
```

그다음은 **지문을 보는 줄과 실행하는 줄을 나눠서** 해요. 지문이 `지문_기록.txt` 와 같을 때만 다음 줄을 실행해요.

```bash
# 1·2단계: 아직 b200 명령이 없어서 직접 복사해요
cp /app/upload/b200-pack.tar /app/inbox/ && sha256sum /app/inbox/b200-pack.tar          # 지문 확인
cd /app/inbox && tar xf b200-pack.tar && bash admin_setup.sh && bash pack_install.sh /app/shared

# 3~5단계: 여기부터는 b200 fetch 를 써요
/app/shared/bin/b200 fetch b200-docker.tar                                               # 지문 확인
cd /app/inbox && tar xf b200-docker.tar && bash docker_install.sh
/app/shared/bin/b200 fetch datasets                                                      # 지문 확인
bash /app/inbox/datasets/datasets_install.sh
/app/shared/bin/b200 fetch models                                                        # 지문 확인
bash /app/inbox/models/models_install.sh
```

### 팀원

| 할 일 | 명령 |
|---|---|
| 실험 결과 보관 | `rsync -a /app/workspace/<이름>/runs/exp1 /data/<팀 폴더>/backup/<이름>/` |
| 도커 이미지 보관·다른 서버에서 쓰기 | `docker save -o /data/<팀 폴더>/docker_images/<이름>/myseg_v1.tar <이름>/myseg:v1` → 다른 서버에서 `docker load -i` 같은 파일 |
| 서버 사이 큰 파일 전달 | `tmp_transfer/` 에 두고 다른 서버에서 가져간 뒤 지워요 |

- NAS에 지문 파일을 같이 두지 않아요. 누구나 고칠 수 있어서 맞춰 봐도 의미가 없어요.
- root 가 NAS에서 바로 복사하지 않는 이유: root squash 면 root 는 `nobody` 라 750 팀 폴더를 못 읽고, 아니면 원칙 3의 위험이 있어요. 공용 계정이 `/app/upload` 로 옮겨 오면 서버 1과 같은 순서가 돼요.
- `cp -r` 는 링크를 링크로 복사해요. 설치 스크립트는 복사본에 링크가 있으면 멈춰요.

## 정해야 할 것

`check_nas.sh` 결과로 채워요.

| 항목 | 확인하는 곳 | 결과 |
|---|---|---|
| 우리 팀 폴더 이름·위치 | 서버 관리 팀, 화면의 "바로 아래 폴더" | |
| 공용 계정이 만들 수 있는지 | 화면의 "공용 계정이 쓸 수 있는 곳" | |
| root squash | 화면의 "root squash" | |
| 두 서버의 공용 계정 번호가 같은지 | 화면의 "계정 번호"(두 서버를 다 실행하면 맞춰 봐요) | |
| 전체·남은 용량 | 화면의 "용량" | |
| 우리 팀 할당량 | 서버 관리 팀 | |
| 팀원 수(N), 1인당 백업 몫(B) | 팀 회의 | |
| 보관 기간 | 팀 회의(`tmp_transfer/` 14일, 이미지 1인 2개 안) | |
| 스냅숏(실수로 지운 것 되살리기) | 서버 관리 팀 | |

## 서버 관리 팀에 요청할 것

필요한 것만 골라 보내요.

- `/data` 아래 우리 팀 폴더 하나를 만들어 주세요(주인 공용 계정, 권한 750).
- 그 폴더에 할당량 ○ TB를 걸어 주세요(위 용량 계획 기준).
- 두 서버의 공용 계정 uid·gid를 같은 번호로 맞춰 주세요.
- `backup/` 폴더에 스냅숏(예: 하루 한 번, 7일 보관)을 걸어 주세요. 실수로 지운 체크포인트를 되살릴 수 있어요.
