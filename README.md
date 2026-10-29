# B200 서버 관리 (관리자 전용)

인터넷이 안 되는 B200 서버에 공용 환경·데이터셋·모델·도커를 반입하고, 여럿이 공용 계정 하나로 쓰는 서버를 관리하는 저장소예요.
**이 저장소의 대부분은 관리자(나)만 써요.** 팀원에게 줄 것은 `team/` 폴더뿐이에요.

## 누가 무엇을 보나

| 대상 | 자료 | 내용 |
|---|---|---|
| **팀원(모두)** | `team/서버_사용_규칙.xlsx`, `team/서버_사용_규칙.md` | 규칙 5가지, 자주 쓰는 명령, GPU 배분, 폴더 (한눈에 보는 용도) |
| | `team/사용_안내.md` | 코드·이미지 반입 → `docker load` → 컨테이너 → 안에서 수정까지, 모델 불러오기, Jupyter 대안 |
| **관리자(나)** | 이 README, `docs/` | 반입·설치·서버 관리 절차 |
| | `pc/` | 접근 PC에서 실행하는 받기 스크립트 |
| | `server/` | B200 서버에서 root 나 공용 계정으로 실행하는 설치 스크립트 |
| | `server/bin/` | 팀원이 평소처럼 쓰는 `docker`, `nvidia-smi` 뒤에서 이름표·경고·"누가 쓰나" 표를 붙이는 도우미와 정기 점검(`b200`). 관리자가 `/app/shared/bin` 에 깔아요 |
| | `lists/` | 받을 목록(기초 프로그램, 공용 휠, 모델) |

받은 결과는 저장소 맨 위의 `pack\`, `pack_docker\`, `datasets\`, `models\` 에 생겨요(git에는 올라가지 않아요).

## 서버 구성

| | 접근 PC | B200 서버 |
|---|---|---|
| 운영체제 | 윈도우 | Ubuntu 22.04 이상(버전 확정 전) |
| 인터넷 | 돼요. 여기서 내려받아요 | 안 돼요 |
| 접속 | | HIWARE 를 거쳐요. 팀원은 모두 공용 계정 `shareduser`, 관리자는 별도 root 계정 |
| 저장 공간 | | 홈 10 GB, `/app` 2 TB SSD |
| 주요 위치 | `D:\b200` | 공용 `/app/shared`(root 만 고침), 작업 `/app/workspace/<이름>`, 기록·알림 `/app/state`, 관리자 설치 파일 `/app/inbox`(root 만 올림), 도커 `/app/docker` |
| 대수 | | 2대. 서버 1은 GPU 8장, 서버 2는 다른 팀과 같이 써서 4장(4~7번). 모든 단계를 서버마다 해요 |

## 한눈에 보기 (관리자)

| 단계 | ⓐ 접근 PC (PowerShell, `D:\b200`) | ⓑ 올릴 것 → `/app/inbox` | ⓒ B200 서버 (root) |
|---|---|---|---|
| 0. 서버 점검 | 없음 | `server\check_server.sh`, `server\check_network.sh` | `bash /app/inbox/check_server.sh`, 두 서버에서 각각 `bash /app/inbox/check_network.sh all` |
| 1. 관리자 기본 설정 | `.\pc\pack_build.ps1` | `pack\b200-pack.tar` | `cd /app/inbox && tar xf b200-pack.tar && bash admin_setup.sh` |
| 2. 공용 휠·기초 프로그램 | (1단계 묶음에 들어 있어요) | | `cd /app/inbox && bash pack_install.sh /app/shared` |
| 3. 도커 | `.\pc\docker_pack.ps1` | `pack_docker\b200-docker.tar` | `cd /app/inbox && tar xf b200-docker.tar && bash docker_install.sh` |
| 4. 데이터셋 | `.\pc\datasets_download.ps1` | `datasets` 폴더 | `bash /app/inbox/datasets/datasets_install.sh` |
| 5. 사전학습 모델 | `.\pc\models_download.ps1` | `models` 폴더 | `bash /app/inbox/models/models_install.sh` |

- 접근 PC 명령 앞에는 모두 `powershell -ExecutionPolicy Bypass -File` 이 붙어요.
- **`admin_setup.sh` 를 맨 먼저 해요.** `/app` 과 `/app/shared`, `/app/inbox` 를 root 만 고칠 수 있게 잠가요. 잠그기 전에 root 로 설치하면 공용 계정이 심어 둔 링크를 따라 시스템 폴더에 쓸 수 있어서, 설치 스크립트들이 먼저 잠겼는지 확인하고 아니면 멈춰요.
- 잠근 뒤에는 설치 파일을 root 로 올리고 root 로 설치해요.
- 모든 명령은 여러 번 다시 실행해도 돼요. 끝난 것은 건너뛰고, 받다 만 것은 이어서 받아요.
- 단계마다 자세한 내용은 `docs/` 를 보세요. 처음 설치 순서는 `docs/5_우분투_재설치.md`, 운영은 `docs/6_서버_관리.md` 예요.

## 처음 한 번: 접근 PC 준비

1. 접근 PC에 git, uv, micromamba 가 설치돼 있어야 해요.
2. 시작 메뉴에서 **PowerShell** 을 여세요(관리자 권한 필요 없음, PowerShell ISE 아님).
3. 저장소를 받으세요. 이미 받았다면 `cd D:\b200` 후 `git pull` 만 하면 돼요.

```powershell
# [접근 PC] PowerShell
cd D:\
git clone -b claude/adoring-hawking-6bbtgi https://github.com/Leejunhee17/my-remote b200
cd D:\b200
```

받는 데 몇 시간 걸릴 수 있어요. 노트북이면 전원을 연결하세요. 실행 중 절전은 스크립트가 막아요.

## 실행 화면 읽기

| 표시 | 뜻 | 할 일 |
|---|---|---|
| `[정상]` 초록 | 확인했어요 | 없어요 |
| `[주의]` 노랑 | 계속 진행하지만 알아 둘 내용이 있어요 | 메시지를 읽으세요 |
| `[문제]` 빨강 | 끝까지 진행하지만 고칠 것이 있어요 | 메시지에 적힌 할 일을 하세요 |
| `멈춤` 빨간 상자 | 더 진행할 수 없어요 | 상자 안의 **할 일** 을 한 뒤 **같은 명령을 다시 실행** 하세요 |

해결이 안 되면 `docs/4_문제_해결.md` 를 보세요.

## 네트워크 점검 결과

분석과 정한 것은 `docs/6_서버_관리.md` 의 "두 서버와 NAS"에 있어요.

```
[root@server1:/home/shareduser/inbox][root@server1:/home/shareduser/inbox]bash check_network.sh disk /data/tmp
[server1] /data/tmp 속도 (NAS망-IP:/nas, 시험 파일 4 GB)
  쓰기: 1.82 GB/s (14.6 Gbps)
  읽기: 4.29 GB/s (34.3 Gbps)
  (한 줄기로 잰 값이에요. 여러 명이 동시에 쓰면 나눠 가져요)
[root@server1:/home/shareduser/inbox]bash check_network.sh 서버2-IP
[B200 서버] 네트워크 점검  (2026-10-28 17:05, server1, root)

== 네트워크 카드 ==
  이름            종류            상태    속도       MTU    IPv4
  bond0           이더넷(가상)    up      20 Gbps    1500   서버1-IP/24
  bonding_masters 종류(가상)                                -
  eth     이더넷          up      10 Gbps    1500   -
  eth     이더넷          down               1500   -
  eth     이더넷          up      10 Gbps    1500   -
  eth     이더넷          down               1500   -
  ib        InfiniBand      up      400 Gbps   2044   -
  ib      InfiniBand      up      400 Gbps   2044   -
  ib      InfiniBand      up      400 Gbps   2044   NAS망-IP/24
  ib       InfiniBand      up      400 Gbps   2044   -
  ib        InfiniBand      up      400 Gbps   2044   -
  ib         InfiniBand      up      400 Gbps   2044   NAS망-IP/24
20send%20서버2-IP~^C4%9C%EB%B2%84%EC%97%90%EC%84%9C%20bash%20check_network.sh%
[root@server1:/home/shareduser/inbox]bash check_network.sh 서버2-IP
[B200 서버] 네트워크 점검  (2026-10-28 17:06, server1, root)

== 네트워크 카드 ==
  이름            종류            상태    속도       MTU    IPv4
  bond0           이더넷(가상)    up      20 Gbps    1500   서버1-IP/24
  bonding_masters 종류(가상)                                -
  eth     이더넷          up      10 Gbps    1500   -
  eth     이더넷          down               1500   -
  eth     이더넷          up      10 Gbps    1500   -
  eth     이더넷          down               1500   -
  ib        InfiniBand      up      400 Gbps   2044   -
  ib      InfiniBand      up      400 Gbps   2044   -
  ib      InfiniBand      up      400 Gbps   2044   NAS망-IP/24
  ib       InfiniBand      up      400 Gbps   2044   -
  ib        InfiniBand      up      400 Gbps   2044   -
  ib         InfiniBand      up      400 Gbps   2044   NAS망-IP/24
  기본 경로: default via 내부-IP dev bond0 proto static metric 300

== InfiniBand·RoCE (GPU 서버끼리 빠르게 주고받는 카드) ==
  mlx5_0       포트 1  ACTIVE   400 Gb/sec (4X NDR)  (InfiniBand)
  mlx5_1       포트 1  ACTIVE   400 Gb/sec (4X NDR)  (InfiniBand)
  mlx5_2       포트 1  ACTIVE   400 Gb/sec (4X NDR)  (InfiniBand)
  mlx5_3       포트 1  ACTIVE   400 Gb/sec (4X NDR)  (InfiniBand)
  mlx5_4       포트 1  ACTIVE   400 Gb/sec (4X NDR)  (InfiniBand)
  mlx5_5       포트 1  ACTIVE   400 Gb/sec (4X NDR)  (InfiniBand)
  ACTIVE 가 있으면 서버끼리 이 카드로 이어져 있을 수 있어요. 어디에 연결됐는지는 서버 관리 팀에 물어보세요.

== NAS (네트워크 저장소) ==
  /data  ←  NAS망-IP:/nas  (nfs)
      가는 카드: ib (400 Gbps)
      옵션: vers=3 rsize=1048576 wsize=1048576 hard proto=rdma nconnect=24
  [정상] RDMA 로 연결(빠른 방식)
  속도 재기: bash check_network.sh disk <위 폴더 안의 내가 쓸 수 있는 폴더>

== 다른 서버 서버2-IP ==
  가는 카드: bond0 (20 Gbps)
  [정상] 응답함, 왕복 0.057 ms
  [정상] SSH(22) 포트가 열려 있어요
  속도 재기: 그 서버에서 bash check_network.sh listen  →  이 서버에서 bash check_network.sh send 서버2-IP
[root@server1:/home/shareduser/inbox]bash check_network.sh disk /data/tmp
[server1] /data/tmp 속도 (NAS망-IP:/nas, 시험 파일 4 GB)
  쓰기: 1.82 GB/s (14.6 Gbps)
  읽기: 4.34 GB/s (34.8 Gbps)
  (한 줄기로 잰 값이에요. 여러 명이 동시에 쓰면 나눠 가져요)
[root@server1:/home/shareduser/inbox]bash check_network.sh send 서버2-IP
  가는 카드: bond0 (20 Gbps),  8줄기, 10초
  8줄기로 23.7 GB 를 10초 동안 보냄: 약 2.37 GB/s (18.9 Gbps). 정확한 값은 받는 쪽 숫자를 보세요.
  (python 으로 잰 값이라 100 Gbps 이상 카드에서는 실제보다 낮게 나올 수 있어요)
[shareduser@server2:/app/inbox]bash check_network.sh listen
  5201 번 포트에서 기다려요(최대 120초). 다른 서버에서 send 를 실행하세요.
  서버1-IP 에서 8줄기로 23.7 GB 를 10.4초에 받음: 2.28 GB/s (18.3 Gbps)
```

