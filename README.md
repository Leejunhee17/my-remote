# B200 서버 관리 (관리자 전용)

인터넷이 안 되는 B200 서버에 공용 환경·데이터셋·모델·도커를 반입하고, 여럿이 공용 계정 하나로 쓰는 서버를 관리하는 저장소예요.
**이 저장소의 대부분은 관리자(나)만 써요.** 팀원에게 줄 것은 `team/` 폴더뿐이에요.

## 누가 무엇을 보나

| 대상 | 자료 | 내용 |
|---|---|---|
| **팀원(모두)** | `team/서버_사용_규칙.xlsx`, `team/서버_사용_규칙.md` | 규칙 6가지, `b200` 명령, 폴더, Python 환경, 도커 사용·이미지 반입 |
| | `team/image_download.ps1` | 각자 접근 PC에서 공개 도커 이미지를 받는 파일(이 파일 하나만 나눠 줘요) |
| **관리자(나)** | 이 README, `docs/` | 반입·설치·서버 관리 절차 |
| | `pc/` | 접근 PC에서 실행하는 받기 스크립트 |
| | `server/` | B200 서버에서 root 나 공용 계정으로 실행하는 설치 스크립트 |
| | `server/bin/b200` | 팀원이 쓰는 명령. 관리자가 `/app/shared/bin` 에 깔아요 |
| | `lists/` | 받을 목록(기초 프로그램, 공용 휠, 모델) |

받은 결과는 저장소 맨 위의 `pack\`, `pack_docker\`, `datasets\`, `models\` 에 생겨요(git에는 올라가지 않아요).

## 서버 구성

| | 접근 PC | B200 서버 |
|---|---|---|
| 운영체제 | 윈도우 | Ubuntu 22.04 이상(버전 확정 전) |
| 인터넷 | 돼요. 여기서 내려받아요 | 안 돼요 |
| 접속 | | HIWARE 를 거쳐요. 팀원은 모두 공용 계정 `shareduser`, 관리자는 별도 root 계정 |
| 저장 공간 | | 홈 10 GB, `/app` 2 TB SSD |
| 주요 위치 | `D:\b200` | 공용 `/app/shared`(root 만 고침), 작업 `/app/workspace/<이름>`, 기록 `/app/state`, 올리는 곳 `/app/inbox`, 도커 `/app/docker` |

## 한눈에 보기 (관리자)

| 단계 | ⓐ 접근 PC (PowerShell, `D:\b200`) | ⓑ 올릴 것 → `/app/inbox` | ⓒ B200 서버 (root) |
|---|---|---|---|
| 0. 서버 점검 | 없음 | `server\check_server.sh` | `bash /app/inbox/check_server.sh` |
| 1. 공용 휠·기초 프로그램 | `.\pc\pack_build.ps1` | `pack\b200-pack.tar` | `cd /app/inbox && tar xf b200-pack.tar && bash pack_install.sh /app/shared` |
| 2. 관리자 기본 설정 | (1단계 묶음에 들어 있어요) | | `cd /app/inbox && bash admin_setup.sh` |
| 3. 도커 | `.\pc\docker_pack.ps1` | `pack_docker\b200-docker.tar` | `cd /app/inbox && tar xf b200-docker.tar && bash docker_install.sh` |
| 4. 데이터셋 | `.\pc\datasets_download.ps1` | `datasets` 폴더 | `bash /app/inbox/datasets/datasets_install.sh` |
| 5. 사전학습 모델 | `.\pc\models_download.ps1` | `models` 폴더 | `bash /app/inbox/models/models_install.sh` |

- 접근 PC 명령 앞에는 모두 `powershell -ExecutionPolicy Bypass -File` 이 붙어요.
- 2단계(`admin_setup.sh`) 뒤에는 `/app/shared` 가 잠겨서, 1·4·5단계 설치는 root 로만 돼요.
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
