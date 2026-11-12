# GPU 서버 관리 (관리자 전용)

인터넷이 안 되는 GPU 서버 2대에 도커·데이터셋·모델과 관리 스크립트를 들여오고, 팀원 여럿이 공용 계정 하나로 같이 쓰도록 관리하는 저장소예요.
**관리자 일은 `admin/`, 사용자(팀원) 일은 `user/` 폴더에 모여 있어요.** 팀원은 `user/` 만 보면 돼요(아래 "폴더 구성").

이 저장소로 할 수 있는 일이에요.

- 접근 PC(인터넷이 되는 윈도우 PC)에서 필요한 것을 받아 묶고, GPU 서버(인터넷 안 됨)에 올려 설치해요.
- 팀원은 평소 쓰던 `docker`, `nvidia-smi` 를 그대로 쓰고, 서버는 누가 어떤 GPU를 쓰는지 보여 주며 겹치면 알려 줘요.
- 공용 계정으로는 서버 root 권한을 얻을 수 없게 막아요.

공개 저장소예요. 서버 이름·IP·계정 이름 같은 사내 정보와 토큰은 저장소에 두지 않고, 서버의 `/etc/gpu/account` 와 접근 PC의 `.env` 처럼 git 밖에 둬요. 커밋 검사(`.githooks/`)와 자동 시험이 이런 정보가 실수로 올라가지 않게 막아요.

## 빠르게 시작하기

접근 PC(윈도우 PowerShell)에서 저장소를 받고, 설정 파일을 만든 뒤 필요한 것을 한 번에 받아요. 자세한 순서와 서버 쪽 일은 `admin/1_처음_설치.md` 에 있어요.

```powershell
# [접근 PC] PowerShell
cd D:\
git clone https://github.com/Leejunhee17/my-remote.git gpu
cd D:\gpu
git config core.hooksPath .githooks                                   # 커밋 검사 켜기(한 번)
copy .env.example .env                                                # 접근 PC 설정 만들기(한 번)
notepad .env                                                          # HF_TOKEN, 필요하면 HTTPS_PROXY 적기
powershell -ExecutionPolicy Bypass -File .\admin\pc\check.ps1                # 접근 PC 점검(결과를 reports\ 로 git 에 올려요)
powershell -ExecutionPolicy Bypass -File .\admin\pc\run_all.ps1              # 서버 설치 스크립트·기초 프로그램·도커·데이터셋·모델 받기
```

받은 것은 `setup\`, `pack_pkgs\`, `pack_docker\`, `datasets\`, `models\` 에 생겨요. 서버에 올리고 설치하는 일은 각 작업 끝의 안내와 `admin/1_처음_설치.md` 의 "전체 흐름" 을 따라요.

## 서버 구성

| | 접근 PC | GPU 서버 |
|---|---|---|
| 대수 | | 2대. 서버 1은 GPU 8장, 서버 2는 다른 팀과 같이 써서 4장(4~7번) |
| GPU | | NVIDIA H200 NVL(141 GB, PCIe 카드, NVLink 브리지) × 8. 드라이버 595 |
| 운영체제 | 윈도우 | 지금은 RHEL 9. 2026-11-27까지 Ubuntu 24.04 LTS 로 다시 설치할 예정이에요(11-09에 11-12에서 연기됨). 문서는 Ubuntu 기준이에요 |
| 인터넷 | 돼요. 여기서 내려받아요 | 안 돼요 |
| 접속 | | HIWARE(서버에 접속할 때 거치는 사내 접속 관리 시스템)를 거쳐요. 팀원은 모두 공용 계정 하나(PuTTY, FileZilla). 관리자는 root(PuTTY만 돼요). 파일은 공용 계정 FileZilla로 올려요 |
| 저장 공간 | | 홈 10 GB, `/app` 2 TB SSD(작업 폴더·도커), NAS `/data`(다른 팀과 같이 써요). 데이터셋·모델은 NAS의 우리 팀 폴더 `/data/autonomy_sw` 에 한 번만 두고 두 서버가 같이 읽어요(`admin/5_NAS.md`) |
| 주요 위치 | `D:\gpu` | 데이터셋 `/data/autonomy_sw/datasets`, 모델 `/data/autonomy_sw/models`(NAS, 팀원이 넣음), 도우미·명단·설정 `/app/admin`(root 만 고침), 작업 `/app/autonomy_sw/<이름>`, 기록·알림 `/app/state`, 올리는 곳 NAS `/data/autonomy_sw/inbox`(공용 계정) → root 가 확인한 설치 파일 `/app/inbox`(root 만 고침), 도커 `/app/docker` |

## 문서 지도

| 이럴 때 | 문서 |
|---|---|
| 서버를 처음 설치해요(Ubuntu로 다시 설치한 뒤). 접근 PC 설정(`.env`)·점검과 한 번에 받기도 여기 | `admin/1_처음_설치.md` |
| 팀원 추가, GPU 배분, 알림 기준, 도커·드라이버 관리 | `admin/2_서버_운영.md` |
| 잠금·알림·사람 구분이 왜 이렇게 생겼는지 알고 싶어요 | `admin/3_구조와_보안.md` |
| 두 서버와 NAS 사이 속도, 큰 파일 옮기는 방법, 점검 결과 올리기 | `admin/4_네트워크.md` |
| 데이터셋을 받거나 폴더 구조를 확인해요 | `user/데이터셋_넣기.md` |
| 사전학습 모델을 받거나 목록을 바꿔요. 주행 영상 의사 라벨도 만들어요 | `user/모델_넣기.md` |
| 스크립트가 멈췄거나 `[문제]` 가 나왔어요 | `admin/6_문제_해결.md` |
| NAS에 무엇을 어디에 두고(`originals`, `backup`, `docker_images`, `tmp_transfer`), 누가 쓰고, 얼마나 필요한지 | `admin/5_NAS.md` |
| 팀원에게 줄 규칙(한눈에 보기) | `user/서버_사용_규칙.md`, `user/서버_사용_규칙.xlsx` |
| 팀원에게 줄 사용법(코드·이미지 반입 → 도커에서 실행) | `user/사용_안내.md` |

## 설치 순서 한눈에

일은 관리자(0·1·2·3·6·7단계, root)와 사용자(4·5단계, 공용 계정)로 나뉘어요. 관리자는 `admin/1_처음_설치.md` 대로 준비 → 설치 → 권한·규칙 설정 순서로, 서버 2대에서 각각 해요. 사용자는 데이터셋·모델을 정해진 NAS 폴더에 넣기만 하면 돼요(`user/데이터셋_넣기.md`, `user/모델_넣기.md`). 두 서버가 같이 보는 NAS에 들어가서 한 곳에서 한 번만 하면 돼요.

| 단계 | 접근 PC | GPU 서버 |
|---|---|---|
| 0. 점검 | `admin\pc\check.ps1` (프로그램·.env·사이트 접속·디스크를 한 번에. 결과는 `reports\` 로 git 에) | root: `check.sh` (서버·NAS·네트워크를 한 번에. 보고서는 공용 계정 홈에) |
| 1. 준비 | `admin\pc\setup_pack.ps1` | root: `prepare.sh` (`/app` 잠금, `gpu fetch`, NAS 팀 폴더. 설치보다 먼저) |
| 2. 서버 기초 프로그램 | `admin\pc\pkgs_pack.ps1` | root: `pkgs_install.sh` (tmux, nvtop, rsync 등. 없는 것만) |
| 3. 도커 | `admin\pc\docker_pack.ps1` | root: `docker_install.sh` |
| 4. 데이터셋 넣기 (사용자) | `user\pc\datasets_download.ps1` | 공용 계정: `datasets_unpack.sh` (한 서버에서 한 번만) |
| 5. 사전학습 모델 넣기 (사용자) | `user\pc\models_download.ps1` | 공용 계정: `models_place.sh` (한 서버에서 한 번만) |
| 6. 권한·규칙 설정 | (1단계 묶음에 들어 있어요) | root: `admin_setup.sh` (이름 고르기, 도우미, 알림, 정기 점검. 하나가 안 돼도 멈추지 않아요) |
| 7. 팀원에게 알리고 확인 | | 공용 계정으로 접속 |

서버 화면(컨테이너 밖)에서 쓰는 tmux, nvtop, rsync 같은 프로그램은 서버에 인터넷이 없어서 관리자가 2단계 묶음으로 직접 설치해요(`admin/1_처음_설치.md` 의 "2단계: 서버 기초 프로그램"). 학습 도구는 팀원이 도커 이미지에 넣어 와요.

접근 PC의 토큰·프록시 같은 설정은 `.env` 하나에 적어 두고(`copy .env.example .env`), 1~5단계에서 받는 일은 `admin\pc\run_all.ps1` 하나로 한 번에 할 수 있어요(`admin/1_처음_설치.md` 의 "접근 PC 설정(.env)").

## 폴더 구성

누가 하는 일인지로 먼저 나누고, 그 안에서 어디서 실행하는지(접근 PC `pc/`, GPU 서버 `server/`)로 나눴어요.

```
D:\gpu
├─ admin/          관리자(root). 0·1·2·3·6·7단계
│  ├─ 1_처음_설치.md … 6_문제_해결.md   관리자 문서
│  ├─ pc/          접근 PC: 점검(check.ps1), 묶기, 한 번에 받기(run_all.ps1)
│  └─ server/      GPU 서버(root): 점검, 준비, 기초 프로그램·도커 설치, 권한·규칙 설정
│     └─ bin/      팀원이 쓰는 docker·nvidia-smi 도우미와 gpu 명령
├─ user/           사용자(공용 계정). 4·5단계와 팀원에게 줄 것
│  ├─ 데이터셋_넣기.md, 모델_넣기.md      4·5단계 방법
│  ├─ 서버_사용_규칙.md·xlsx, 사용_안내.md  팀원 규칙과 사용법
│  ├─ models.txt   받을 모델 목록
│  ├─ pc/          접근 PC: 데이터셋·모델 받기
│  └─ server/      GPU 서버(공용 계정): 데이터셋 풀기, 모델 넣기
├─ common/         admin·user 의 접근 PC 스크립트가 같이 쓰는 함수(gpu_common.ps1)
├─ reports/        공유용 점검 결과
└─ tests/          자동 시험
```

| 폴더 | 내용 |
|---|---|
| `admin/` | 관리자 문서(위 문서 지도)와 관리자 스크립트 |
| `admin/pc/` | 접근 PC에서 실행하는 점검(`check.ps1`)과 서버 설치 묶음 만들기. `run_all.ps1` 은 1~5단계 받기를 한 번에 해요(관리자가 사용자 일까지 같이 할 때) |
| `admin/server/` | GPU 서버에서 root 로 실행하는 점검·설치 스크립트 |
| `admin/server/bin/` | 팀원이 쓰는 `docker`, `nvidia-smi` 뒤에서 이름표·경고·"GPU별 사용자" 표를 붙이는 도우미와 정기 점검(`gpu`). `gpu` 는 1단계 `prepare.sh`, 나머지는 6단계 `admin_setup.sh` 가 `/app/admin/bin` 에 설치해요 |
| `user/` | 사용자 문서(데이터셋·모델 넣기, 서버 사용 규칙, 사용 안내)와 받을 모델 목록(`models.txt`) |
| `user/pc/` | 접근 PC에서 데이터셋·모델을 받는 스크립트 |
| `user/server/` | GPU 서버에서 공용 계정으로 실행하는 데이터셋 풀기·모델 넣기 스크립트(받을 때 결과 폴더에 같이 들어가요) |
| `common/` | 접근 PC 스크립트가 같이 쓰는 함수(`gpu_common.ps1`). 직접 실행하지 않아요 |
| `.env.example` | 접근 PC 설정 예시. 복사해 `.env` 를 만들고 토큰·프록시를 적어요(`.env` 는 git에 올라가지 않아요) |
| `reports/` | 서버·접근 PC 점검 결과 중 사내 정보를 가린 공유용만 올리는 곳 |
| `.githooks/` | 커밋 전에 사내 정보·`.env`·토큰이 들어가지 않았는지 보는 검사(`git config core.hooksPath .githooks`) |
| `tests/` | 자동 시험(`bash tests/run.sh`). 가짜 `/app`·docker·nvidia-smi 로 스크립트를 실제로 돌려 봐요 |
| `.github/workflows/` | 푸시할 때마다 GitHub 에서 자동 시험을 돌리는 설정 |

## 고친 뒤 확인

스크립트나 문서를 고치면 `main` 에 푸시할 때 GitHub 가 `tests/run.sh` 를 자동으로 돌려요. 푸시하기 전에 WSL 이나 리눅스에서 `bash tests/run.sh` 로 먼저 돌려 볼 수도 있어요. 저장소 페이지의 **Actions** 탭에서 초록 체크면 통과예요. 빨간 X 면 눌러서 어느 시험이 실패했는지 볼 수 있어요. 시험은 서버에 손대지 않고 GitHub 의 일회용 가상 머신에서 돌아요.

- 문법: bash·Python·PowerShell 문법, shellcheck, `.ps1` BOM·줄 끝, `.ps1` 에서 한글이 붙은 변수(`"$n번째"`), 올리면 안 되는 파일(`.env` 포함), 사설 IP
- 접근 PC 설정: `.env` 읽기(주석·따옴표·이미 정한 값이 우선하는지, 값은 화면에 안 나오는지), `.env.example` 에 값이 비어 있는지
- 문서: 코드 블록 짝, 문서에 나온 스크립트·문서·절 이름이 실제로 있는지, 문제 해결 표의 메시지가 스크립트에 있는지
- 데이터셋·모델 넣기: 정상·깨진 파일·빠진 파일·빈 목록·같은 이름 폴더·나눠 올리기로 돌려 봐요
- 서버 도우미: 정기 점검, GPU 현황, 주간 보고서, docker 래퍼 경고, `gpu fetch`, 공유용 보고서 가리기
- 커밋 검사: 사설 IP, 가릴 낱말, 원본 보고서, 엑셀 안의 글자, `.env` 파일, 토큰·키처럼 보이는 값(HF, GitHub, AWS, 개인 키)
- 준비와 권한·규칙 설정: `prepare.sh`, `admin_setup.sh` 를 진짜 `/app` 에 돌리고, 공용 계정으로 접속해 이름 고르기까지 해 봐요

시험하지 못하는 것: 실제 GPU·도커, HIWARE, 접근 PC에서의 받기(인터넷), NAS. 이것들은 서버에서 문서 순서대로 따라 하며 확인해요.

받은 결과는 저장소 맨 위의 `setup\`, `pack_pkgs\`, `pack_docker\`, `datasets\`, `models\` 에 생겨요(git에는 올라가지 않아요).
