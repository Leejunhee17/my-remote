# B200 서버 반입 안내

인터넷이 안 되는 B200 서버에 공용 Python 패키지, 기초 프로그램, 학습 데이터셋, 사전학습 모델을 설치하는 방법이에요.
접근 PC에서 명령 한 줄을 실행하고, 만들어진 파일을 B200 서버에 올린 뒤, B200 서버에서 명령 한 줄을 실행하면 돼요.
스크립트가 점검, 진행 상황 표시, 결과 검사를 모두 하고, 끝나면 올릴 파일과 B200 서버에서 입력할 명령을 알려 줘요.

## 컴퓨터 두 대 구분하기

이 안내에는 컴퓨터가 두 대 나와요. 명령마다 어느 컴퓨터에서 입력하는지 꼭 확인하세요.

| | 접근 PC | B200 서버 |
|---|---|---|
| 하는 일 | B200 서버에 접속할 때 쓰는 PC | 학습을 실행하는 서버(B200 GPU 8장) |
| 운영체제 | 윈도우 | RHEL(Red Hat Enterprise Linux) 9 |
| 인터넷 | 돼요. 여기서 내려받아요 | 안 돼요. 접근 PC에서 받은 파일을 올려요 |
| 명령 입력 창 | PowerShell (`PS D:\b200>` 로 시작) | 터미널 (`[아이디@서버이름 ~]$` 로 시작) |
| 스크립트 | `.ps1` | `.sh` |
| 저장 공간 | | 홈(`~`) 10 GB, `/app` 2 TB SSD. 공용 폴더는 `/app/shared`(홈의 `~/shared` 는 링크), 올리는 곳은 `/app/inbox` |
| 계정 | | 팀원 모두 같은 계정 |
| 파일 위치 예시 | `D:\b200\pack\b200-pack.tar` | `/app/inbox/b200-pack.tar` |

파일은 한 방향으로만 옮겨요. 접근 PC에서 회사 파일 전송 프로그램으로 B200 서버의 `~/inbox` 폴더에 올리면 돼요.
스크립트 화면 첫 줄에도 `[접근 PC]` 또는 `[B200 서버]` 가 나와요. `.sh` 스크립트를 리눅스가 아닌 곳에서 실행하면 바로 멈추고 알려 줘요.

## 전체 흐름

| 단계 | ⓐ 접근 PC에서 실행 | ⓑ B200 서버에 올릴 것 | ⓒ B200 서버에서 실행 |
|---|---|---|---|
| 1. 공용 휠과 기초 프로그램 | `pack_build.ps1` | 묶음 파일 `pack\b200-pack.tar` 하나 → `~/inbox` | `pack_install.sh` |
| 2. 세그멘테이션 데이터셋 | `datasets_download.ps1` | `datasets` 폴더 전체 → `~/inbox/datasets` | `datasets_install.sh` |
| 3. 사전학습 모델 | `models_download.ps1` | `models` 폴더 전체 → `~/inbox/models` | `models_install.sh` |

- **휠**: Python 패키지 설치 파일(`.whl`)이에요. 공용 휠은 팀이 함께 쓰는 패키지 72개예요(목록: `wheels.txt`).
- **기초 프로그램**: git, tmux, vim 같은 명령줄 도구 57개예요(목록: `tools.txt`).
- 1단계를 먼저 하세요. 2단계의 B200 서버 스크립트가 1단계에서 설치한 `unzip` 을 쓸 수 있어요.

## 0단계: 접근 PC 준비하기

처음 한 번만 하면 돼요. B200 서버에는 준비할 것이 없고 관리자(root) 권한도 필요 없어요.

1. 접근 PC에 git, uv, micromamba 가 설치돼 있는지 확인하세요.
2. 시작 메뉴에서 **PowerShell** 을 여세요. 관리자 권한은 필요 없고, PowerShell ISE가 아닌 PowerShell을 여세요.
3. 남은 공간이 1단계는 30 GB, 2단계는 150 GB 이상인 드라이브에 저장소를 내려받으세요. 처음 실행하면 GitHub 로그인 창이 떠요.

```powershell
# [접근 PC] PowerShell
cd D:\
git clone -b claude/adoring-hawking-6bbtgi https://github.com/Leejunhee17/my-remote b200
cd D:\b200
```

이미 내려받았다면 `cd D:\b200` 을 입력한 뒤 `git pull` 만 입력하세요.

4. 1단계는 수십 분, 2단계는 몇 시간에서 하루가 걸려요. 노트북이면 전원을 연결하고, 설정 → Windows 업데이트 → **업데이트 일시 중지** 를 눌러 자동 재시작을 막으세요.
   실행하는 동안 PC가 절전 모드로 들어가는 것은 스크립트가 막아요.

## 1단계: 공용 휠과 기초 프로그램 설치하기

### ⓐ 접근 PC에서 묶음 파일 만들기

```powershell
# [접근 PC] PowerShell
cd D:\b200
powershell -ExecutionPolicy Bypass -File .\pack_build.ps1
```

B200 서버의 RHEL 9(glibc 2.34)에 맞춰 만들어요. B200 서버가 RHEL 8이면 명령 끝에 ` -Glibc 2.28` 을 붙이세요.

### ⓑ B200 서버에 올리기

초록색 **완료** 가 나오면 접근 PC의 `D:\b200\pack\b200-pack.tar` 파일 하나를 B200 서버의 `~/inbox` 에 올리세요.

### ⓒ B200 서버에서 설치하기

```bash
# [B200 서버] 터미널
cd ~/inbox && tar xf b200-pack.tar && bash pack_install.sh
```

홈 디스크가 작으면 큰 디스크 경로를 붙이세요. 그곳에 설치하고, `~/shared` 는 그곳으로 가는 링크로 만들어요. 경로는 지금까지처럼 `~/shared` 로 쓰면 돼요.

```bash
# [B200 서버] 터미널. 묶음을 /app/inbox 에 풀었다면
cd /app/inbox && bash pack_install.sh /app/shared
```

초록색 **완료** 가 나오면 설치가 끝난 거예요. B200 서버에 기초 프로그램(`~/shared/tools`)과 공용 Python 환경(`~/shared/venv`)이 생기고, GPU 계산까지 확인한 상태예요.
내 작업 환경을 만드는 방법은 `공용_휠_기초프로그램_명령어.md` 를 보세요.

## 2단계: 데이터셋 설치하기

접근 PC가 직접 받는 데이터셋은 GOOSE, GOOSE-Ex, RUGD, WildScenes 4개예요.

- WildScenes를 받으려면 실행 직전에 `데이터셋_명령어.md` 의 "WildScenes 접속 정보 받기" 를 따라 접속 정보를 받아 두세요. 스크립트가 물어볼 때 붙여 넣으면 돼요.
- RELLIS-3D, TAS500, GO는 Google Drive에만 있어요. 스크립트가 Google Drive 접속을 확인해서, 접속되면 함께 받고 막혀 있으면 건너뛰어요. 접근이 생기면 같은 명령을 다시 실행하세요.

### ⓐ 접근 PC에서 내려받기

```powershell
# [접근 PC] PowerShell
cd D:\b200
powershell -ExecutionPolicy Bypass -File .\datasets_download.ps1 -WildScenes   # WildScenes 포함. 접속 정보를 물어봐요
powershell -ExecutionPolicy Bypass -File .\datasets_download.ps1               # WildScenes 빼고
```

### ⓑ B200 서버에 올리기

초록색 **완료** 가 나오면 접근 PC의 `D:\b200\datasets` 폴더 전체를 B200 서버의 `~/inbox/datasets` 에 올리세요.

### ⓒ B200 서버에서 풀기

```bash
# [B200 서버] 터미널
bash ~/inbox/datasets/datasets_install.sh
```

초록색 **완료** 가 나오면 끝난 거예요. 데이터셋마다 학습 코드가 읽는 라벨이 몇 장인지 화면에 나와요.

## 3단계: 사전학습 모델 설치하기

Hugging Face에서 세그멘테이션 모델, 기반 모델(DINOv3 등), VLM을 받아요. 목록은 `models.txt`, 자세한 내용은 `모델_명령어.md` 에 있어요.
기본 목록을 모두 받으면 약 130 GB예요. DINOv3와 SAM 3는 모델 페이지에서 약관에 동의한 계정의 토큰이 필요해요(`모델_명령어.md` 의 "승인이 필요한 모델(gated) 받기").

### ⓐ 접근 PC에서 내려받기

```powershell
# [접근 PC] PowerShell
cd D:\b200
powershell -ExecutionPolicy Bypass -File .\models_download.ps1                        # models.txt 의 기본 모델 전부
powershell -ExecutionPolicy Bypass -File .\models_download.ps1 -Only seg,enc,backbone # 그룹만
```

### ⓑ B200 서버에 올리기

초록색 **완료** 가 나오면 접근 PC의 `D:\b200\models` 폴더 전체를 B200 서버의 `~/inbox/models` 에 올리세요.

### ⓒ B200 서버에서 설치하기

```bash
# [B200 서버] 터미널
bash ~/inbox/models/models_install.sh
```

초록색 **완료** 가 나오면 끝난 거예요. 모델은 `~/shared/models/<만든 곳>/<모델>` 에 있어요.

## 실행 화면 읽기

스크립트는 **점검**(시작 전에 필요한 것이 있는지 확인) → **진행** → **검사**(끝난 뒤 결과가 맞는지 확인) 순서로 실행돼요.

| 표시 | 뜻 | 할 일 |
|---|---|---|
| `[정상]` 초록 | 확인했어요 | 없어요 |
| `[주의]` 노랑 | 계속 진행하지만 알아 둘 내용이 있어요 | 메시지를 읽으세요 |
| `[문제]` 빨강 | 끝까지 진행하지만 고칠 것이 있어요 | 메시지에 적힌 할 일을 하세요 |
| `멈춤` 빨간 상자 | 더 진행할 수 없어요 | 상자 안의 **할 일** 을 한 뒤 **같은 명령을 다시 실행** 하세요 |
| 접근 PC의 인터넷 끊김 | 스크립트가 기다렸다가 이어서 받아요. 받은 양이 늘고 있으면 횟수 제한 없이 계속해요 | 기다리세요. 창을 닫았거나 PC가 꺼졌다면 같은 명령을 다시 실행하세요 |

- 모든 명령은 여러 번 다시 실행해도 돼요. 이미 끝난 단계는 건너뛰어요.
- 해결이 안 되면 화면 끝에 나온 로그 파일을 담당자에게 보내 주세요.
  - 접근 PC: `D:\b200\pack\build.log`, `D:\b200\datasets\download.log`, `D:\b200\models\download.log`
  - B200 서버: `~/shared/logs/` 에서 가장 최근 파일

## 문제 해결하기

| 어디서 | 메시지 | 할 일 |
|---|---|---|
| 접근 PC | `스크립트를 실행할 수 없습니다` | `-ExecutionPolicy Bypass` 가 빠졌어요. 위의 명령을 그대로 복사해 실행하세요 |
| 접근 PC | `uv 가 없다`, `micromamba 가 없다` | 설치한 뒤 PowerShell 창을 새로 여세요. 그래도 안 되면 `uv.exe`, `micromamba.exe` 를 `D:\b200` 에 넣으세요. micromamba 실행 파일 위치는 PowerShell에서 `$env:MAMBA_EXE` 를 입력하면 나와요 |
| 접근 PC | `'Mamba' 용어가 … 인식되지 않습니다` | 예전 스크립트에서 나던 오류예요. `git pull` 로 최신 스크립트를 받으세요 |
| 접근 PC | `인터넷: … 에 접속 안 됨` | 브라우저로는 열린다면 회사 프록시를 거쳐야 하는 망이에요. 실행 전에 `$env:HTTPS_PROXY = "http://프록시주소:포트"` 를 입력하세요. 주소는 사내 IT 부서에 물어보세요 |
| 접근 PC | `WildScenes2d 폴더를 찾지 못했다`, `접속 정보가 만료됐거나 막혔다` | WildScenes 접속 정보는 약 48시간만 유효해요. 포털에서 새로 받아 같은 명령을 다시 실행하세요. 받은 파일은 건너뛰어요 |
| B200 서버 | `올리는 중에 파일이 깨졌다` | 화면에 나온 파일만 접근 PC에서 다시 올리세요. 1단계라면 묶음 파일을 다시 올리세요 |
| B200 서버 | `남은 공간이 … GB 다` | 다 푼 묶음 파일(`~/inbox/b200-pack.tar`)을 지우세요. 그래도 모자라면 큰 디스크로 옮기세요: `bash move_shared.sh /app/$USER` (아래 "공용 폴더를 큰 디스크로 옮기기") |
| B200 서버 | `glibc 가 … 안 맞는다` | 화면에 나온 `-Glibc` 값을 붙여 접근 PC에서 1단계를 다시 실행하고, 새 묶음 파일을 올리세요 |
| B200 서버 | `라벨을 못 찾음` | 화면의 "지금 구조" 를 보고, `데이터셋_명령어.md` 의 "학습 코드가 읽는 라벨 위치" 대로 폴더를 옮기세요 |

## 공용 폴더를 큰 디스크로 옮기기

홈 디스크가 작으면 `~/shared`(기초 프로그램, 공용 환경, 데이터셋, 모델)와 `~/inbox` 를 큰 디스크로 옮기세요. 홈에는 같은 이름의 링크가 남아서, 지금까지의 경로와 이미 설치한 환경을 그대로 쓸 수 있어요.

```bash
# [B200 서버] 터미널. /app/$USER 는 옮길 곳
bash move_shared.sh /app/$USER
```

`move_shared.sh` 는 1단계 묶음 파일 안에 들어 있어요(`~/inbox` 에서 압축을 풀면 나와요). 묶음 파일을 만들기 전이라면 이 파일 하나만 B200 서버에 올리세요.
스크립트가 옮길 곳에 쓸 수 있는지, 공간이 충분한지, SSD인지 HDD인지 확인하고, 복사한 뒤 파일 수와 크기를 비교해요. 마지막에 홈의 옛 폴더를 지울지 물어봐요.

## 파일 목록

| 파일 | 실행하는 곳 | 하는 일 |
|---|---|---|
| `pack_build.ps1` | 접근 PC | 1단계: 내려받고 묶음 파일 만들기 |
| `pack_install.sh` | B200 서버 | 1단계: 설치하고 검사하기. 묶음 파일 안에 함께 들어가요 |
| `datasets_download.ps1` | 접근 PC | 2단계: 내려받기 |
| `datasets_install.sh` | B200 서버 | 2단계: 풀고 검사하기. `datasets` 폴더 안에 함께 들어가요 |
| `models_download.ps1` | 접근 PC | 3단계: 내려받기 |
| `models_install.sh` | B200 서버 | 3단계: 옮기고 검사하기. `models` 폴더 안에 함께 들어가요 |
| `models.txt` | | 사전학습 모델 목록 |
| `move_shared.sh` | B200 서버 | 공용 폴더를 큰 디스크로 옮기기 |
| `tools.txt`, `wheels.txt` | | 기초 프로그램 목록, 공용 휠 목록 |
| `b200_common.ps1`, `check_archive.py`, `hf_fetch.py` | 접근 PC | 스크립트가 함께 쓰는 보조 파일 |
| `서버_사용_규칙.xlsx` | | 서버 사용 규칙, GPU 배분, 데이터셋·휠·기초 프로그램 진행 상황 |
