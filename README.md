# B200 서버 반입 안내

인터넷이 안 되는 B200 서버에 공용 Python 패키지, 기초 프로그램, 학습 데이터셋, 사전학습 모델을 설치하는 방법이에요.
접근 PC에서 명령 한 줄로 받고, 만들어진 파일을 B200 서버에 올린 뒤, B200 서버에서 명령 한 줄로 설치해요.
스크립트가 점검, 진행 상황 표시, 결과 검사를 하고, 끝나면 올릴 파일과 B200 서버에서 입력할 명령을 알려 줘요.

## 폴더 구성

| 폴더 | 내용 |
|---|---|
| `pc/` | **접근 PC**에서 실행하는 스크립트(`.ps1`)와 보조 파일 |
| `server/` | **B200 서버**에서 실행하는 스크립트(`.sh`). 받은 파일에 자동으로 함께 들어가요 |
| `lists/` | 받을 목록: 기초 프로그램(`tools.txt`), 공용 휠(`wheels.txt`), 사전학습 모델(`models.txt`) |
| `docs/` | 자세한 설명: 1 공용 휠·기초 프로그램, 2 데이터셋, 3 모델, 4 문제 해결 |
| `서버_사용_규칙.xlsx` | 팀원용 서버 사용 규칙, GPU 배분, 데이터셋·휠·기초 프로그램·모델 목록 |

받은 결과는 저장소 맨 위의 `pack\`, `datasets\`, `models\` 폴더에 생겨요(git에는 올라가지 않아요).

## 컴퓨터 두 대 구분하기

| | 접근 PC | B200 서버 |
|---|---|---|
| 하는 일 | B200 서버에 접속할 때 쓰는 PC | 학습을 실행하는 서버(B200 GPU 8장) |
| 운영체제 | 윈도우 | RHEL(Red Hat Enterprise Linux) 9 |
| 인터넷 | 돼요. 여기서 내려받아요 | 안 돼요 |
| 명령 입력 창 | PowerShell (`PS D:\b200>`) | 터미널 (`[아이디@서버이름 ~]$`) |
| 저장 공간 | | 홈(`~`) 10 GB, `/app` 2 TB SSD. 팀원 모두 같은 계정 |
| 파일 놓는 곳 | `D:\b200` | 올리는 곳 `/app/inbox`, 공용 폴더 `/app/shared`(홈의 `~/shared` 는 링크) |

## 한눈에 보기

| 단계 | ⓐ 접근 PC (PowerShell, `D:\b200` 에서) | ⓑ B200 서버에 올릴 것 | ⓒ B200 서버 (터미널) |
|---|---|---|---|
| 1. 공용 휠·기초 프로그램 | `powershell -ExecutionPolicy Bypass -File .\pc\pack_build.ps1` | `pack\b200-pack.tar` → `/app/inbox` | `cd /app/inbox && tar xf b200-pack.tar && bash pack_install.sh /app/shared` |
| 2. 데이터셋 | `powershell -ExecutionPolicy Bypass -File .\pc\datasets_download.ps1 -WildScenes` | `datasets` 폴더 전체 → `/app/inbox/datasets` | `bash /app/inbox/datasets/datasets_install.sh` |
| 3. 사전학습 모델 | `powershell -ExecutionPolicy Bypass -File .\pc\models_download.ps1` | `models` 폴더 전체 → `/app/inbox/models` | `bash /app/inbox/models/models_install.sh` |

- 1단계를 먼저 하세요. 2·3단계의 B200 서버 스크립트가 1단계에서 설치한 프로그램을 써요.
- 모든 명령은 여러 번 다시 실행해도 돼요. 끝난 것은 건너뛰고, 받다 만 것은 이어서 받아요.
- 단계마다 자세한 내용은 `docs/` 의 문서를 보세요.

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

받는 데 몇 시간 걸릴 수 있어요. 노트북이면 전원을 연결하고 Windows 업데이트를 일시 중지하세요. 실행 중 절전은 스크립트가 막아요.

## 실행 화면 읽기

| 표시 | 뜻 | 할 일 |
|---|---|---|
| `[정상]` 초록 | 확인했어요 | 없어요 |
| `[주의]` 노랑 | 계속 진행하지만 알아 둘 내용이 있어요 | 메시지를 읽으세요 |
| `[문제]` 빨강 | 끝까지 진행하지만 고칠 것이 있어요 | 메시지에 적힌 할 일을 하세요 |
| `멈춤` 빨간 상자 | 더 진행할 수 없어요 | 상자 안의 **할 일** 을 한 뒤 **같은 명령을 다시 실행** 하세요 |

해결이 안 되면 `docs/4_문제_해결.md` 를 보고, 그래도 안 되면 화면 끝에 나온 기록 파일을 담당자에게 보내 주세요.
