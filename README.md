# B200 서버 관리 (관리자 전용)

인터넷이 안 되는 B200 서버 2대에 기초 프로그램·데이터셋·모델·도커를 반입하고, 팀원 여럿이 공용 계정 하나로 같이 쓰도록 관리하는 저장소예요.
**이 저장소의 대부분은 관리자(나)만 써요.** 팀원에게 줄 것은 `team/` 폴더뿐이에요.

이 저장소로 할 수 있는 일이에요.

- 접근 PC(인터넷 됨)에서 필요한 것을 받아 묶고, B200 서버(인터넷 안 됨)에 올려 설치해요.
- 팀원은 평소 쓰던 `docker`, `nvidia-smi` 로 서버를 쓰고, 서버는 누가 어떤 GPU를 쓰는지 보여 주고 겹치면 알려 줘요.
- 공용 계정으로는 서버 root 권한을 얻을 수 없게 막아요.

## 서버 구성

| | 접근 PC | B200 서버 |
|---|---|---|
| 대수 | | 2대. 서버 1은 GPU 8장, 서버 2는 다른 팀과 같이 써서 4장(4~7번) |
| 운영체제 | 윈도우 | Ubuntu 24.04 LTS |
| 인터넷 | 돼요. 여기서 내려받아요 | 안 돼요 |
| 접속 | | HIWARE 를 거쳐요. 팀원은 모두 공용 계정 하나(PuTTY, FileZilla). 관리자는 root(PuTTY만 돼요). 파일은 공용 계정 FileZilla로 올려요 |
| 저장 공간 | | 홈 10 GB, `/app` 2 TB SSD, NAS `/data`(다른 팀과 같이 써요. 계획: `docs/9_NAS.md`) |
| 주요 위치 | `D:\b200` | 공용 `/app/shared`(root 만 고침), 작업 `/app/workspace/<이름>`, 기록·알림 `/app/state`, 설치 파일 올리는 곳 `/app/upload`(공용 계정) → root 가 확인한 설치 파일 `/app/inbox`(root 만 고침), 도커 `/app/docker` |

## 문서 지도

| 이럴 때 | 문서 |
|---|---|
| 서버를 처음 설치해요(Ubuntu로 다시 설치한 뒤) | `docs/1_처음_설치.md` |
| 팀원 추가, GPU 배분, 알림 기준, 도커·드라이버 관리 | `docs/2_서버_운영.md` |
| 잠금·알림·사람 구분이 왜 이렇게 생겼는지 알고 싶어요 | `docs/3_구조와_보안.md` |
| 두 서버와 NAS 사이 속도, 큰 파일 옮기는 방법 | `docs/4_네트워크.md` |
| NAS에 무엇을 어디에 두고, 누가 쓰고, 얼마나 필요한지 | `docs/9_NAS.md` |
| 서버의 기초 프로그램(tmux, nvtop 등) 목록을 보거나 바꿔요 | `docs/5_기초프로그램.md` |
| 데이터셋을 받거나 폴더 구조를 확인해요 | `docs/6_데이터셋.md` |
| 사전학습 모델을 받거나 목록을 바꿔요 | `docs/7_모델.md` |
| 스크립트가 멈췄거나 `[문제]` 가 나왔어요 | `docs/8_문제_해결.md` |
| 팀원에게 줄 규칙(한눈에 보기) | `team/서버_사용_규칙.md`, `team/서버_사용_규칙.xlsx` |
| 팀원에게 줄 사용법(코드·이미지 반입 → 도커에서 실행) | `team/사용_안내.md` |

## 설치 순서 한눈에

자세한 명령과 확인 방법은 `docs/1_처음_설치.md` 에 있어요. 서버 2대 모두 같은 순서로 해요.

| 단계 | 접근 PC | B200 서버 (root) |
|---|---|---|
| 0. 서버 점검 | | `check_server.sh`, `check_network.sh all`, `check_nas.sh` |
| 1. 관리자 기본 설정 | `pc\pack_build.ps1` | `admin_setup.sh` (**맨 먼저**: `/app` 잠금) |
| 2. 기초 프로그램 | (1단계 묶음) | `pack_install.sh /app/shared` |
| 3. 도커 | `pc\docker_pack.ps1` | `docker_install.sh` |
| 4. 데이터셋 | `pc\datasets_download.ps1` | `datasets_install.sh` |
| 5. 사전학습 모델 | `pc\models_download.ps1` | `models_install.sh` |
| 6. 팀원 입장에서 확인 | | 공용 계정으로 접속 |

접근 PC의 토큰·프록시 같은 설정은 `.env` 하나에 적어 두고(`copy .env.example .env`), 1·3·4·5단계의 받기는 `pc\run_all.ps1` 하나로 한 번에 할 수 있어요(`docs/1_처음_설치.md` 의 "접근 PC 설정(.env)").

## 폴더 구성

| 폴더 | 내용 |
|---|---|
| `docs/` | 관리자 문서(위 문서 지도) |
| `team/` | 팀원에게 줄 규칙과 사용법 |
| `pc/` | 접근 PC에서 실행하는 받기·묶기 스크립트(`run_all.ps1` 은 한 번에) |
| `.env.example` | 접근 PC 설정 예시. 복사해 `.env` 를 만들고 토큰·프록시를 적어요(`.env` 는 git에 올라가지 않아요) |
| `server/` | B200 서버에서 root 로 실행하는 점검·설치 스크립트 |
| `server/bin/` | 팀원이 쓰는 `docker`, `nvidia-smi` 뒤에서 이름표·경고·"GPU별 사용자" 표를 붙이는 도우미와 정기 점검(`b200`). `admin_setup.sh` 가 `/app/shared/bin` 에 설치해요 |
| `lists/` | 받을 목록(기초 프로그램, 모델) |
| `reports/` | 서버 점검 결과 중 사내 정보를 가린 공유용만 올리는 곳 |
| `.githooks/` | 커밋 전에 사내 정보·`.env`·토큰이 들어가지 않았는지 보는 검사(`git config core.hooksPath .githooks`) |
| `tests/` | 자동 시험(`bash tests/run.sh`). 가짜 `/app`·docker·nvidia-smi 로 스크립트를 실제로 돌려 봐요 |
| `.github/workflows/` | 푸시할 때마다 GitHub 에서 자동 시험을 돌리는 설정 |

## 고친 뒤 확인

스크립트나 문서를 고치면 푸시할 때 GitHub 가 `tests/run.sh` 를 자동으로 돌려요. 저장소 페이지의 **Actions** 탭에서 초록 체크면 통과, 빨간 X 면 어느 시험이 실패했는지 눌러 볼 수 있어요. 서버에는 손대지 않고 GitHub 의 버리는 가상 머신에서 돌아요.

- 문법: bash·Python·PowerShell 문법, shellcheck, `.ps1` BOM·줄 끝, 올리면 안 되는 파일, 사설 IP
- 문서: 코드 블록 짝, 문서에 나온 스크립트·문서·절 이름이 실제로 있는지, 문제 해결 표의 메시지가 스크립트에 있는지
- 설치: 데이터셋·모델 설치를 정상·깨진 파일·빈 목록·끼워 넣은 파일로 돌려 봐요
- 서버 도우미: 정기 점검, GPU 현황, 주간 보고서, docker 래퍼 경고, `b200 fetch`, 공유용 보고서 가리기, 커밋 검사
- 관리자 설정: `admin_setup.sh` 를 진짜 `/app` 에 돌리고, 공용 계정으로 접속해 이름 고르기까지 해 봐요

시험하지 못하는 것: 실제 GPU·도커, HIWARE, 접근 PC에서의 받기(인터넷), NAS. 이건 서버에서 문서 순서대로 따라 하며 확인해요.

받은 결과는 저장소 맨 위의 `pack\`, `pack_docker\`, `datasets\`, `models\` 에 생겨요(git에는 올라가지 않아요).
