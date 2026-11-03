"""Hugging Face 모델 하나를 받아 검사한다. models_download.ps1 이 부른다.

  hf_fetch.py plan  <repo> <local_dir>   남은 바이트 수만 출력
  hf_fetch.py fetch <repo> <local_dir>   받고(이어받기) 크기·sha256 검사, 체크섬 목록 작성

종료 코드 0: 정상, 1: 다시 시도할 만한 오류, 3: 권한(승인 필요·토큰), 4: 저장소 없음.
"""

import fnmatch
import hashlib
import json
import os
import sys
import time

try:  # 회사 보안 장비 인증서를 쓰는 망에서도 되도록 윈도우 인증서 저장소를 쓴다
    import truststore

    truststore.inject_into_ssl()
except Exception:
    pass

from huggingface_hub import HfApi, hf_hub_download
from huggingface_hub.errors import GatedRepoError, RepositoryNotFoundError

# 같은 가중치의 다른 형식, 학습에 안 쓰는 파일
SKIP = [
    "*.h5", "*.msgpack", "*.ot", "*.onnx", "*.onnx_data", "*.gguf", "*.tflite",
    "*.mlmodel", "*.mlpackage/*", "onnx/*", "openvino/*", "coreml/*", "*.png", "*.jpg", "*.gif", "*.mp4",
]
WEIGHT_ALT = ["*.bin", "*.pth", "*.pt", "*.ckpt"]  # safetensors 가 있으면 뺀다
STATE = ".b200_state.json"
SUMS = ".b200_sha256"


def pick(info):
    files = [s for s in info.siblings if not any(fnmatch.fnmatch(s.rfilename, p) for p in SKIP)]
    if any(s.rfilename.endswith(".safetensors") for s in files):
        files = [s for s in files if not any(fnmatch.fnmatch(s.rfilename, p) for p in WEIGHT_ALT)]
    return files


def size_of(s):
    return s.size if s.size is not None else (s.lfs.size if s.lfs else 0)


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for b in iter(lambda: f.read(1 << 22), b""):
            h.update(b)
    return h.hexdigest()


def load_state(d):
    try:
        with open(os.path.join(d, STATE), encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return {}


def main(cmd, repo, d):
    token = os.environ.get("HF_TOKEN") or None
    api = HfApi()
    try:
        info = api.model_info(repo, files_metadata=True, token=token)
    except GatedRepoError:
        print(f"  승인이 필요한 모델이에요. https://huggingface.co/{repo} 에서 약관에 동의하고, 그 계정의 토큰을 넣으세요.")
        return 3
    except RepositoryNotFoundError:
        print(f"  저장소가 없거나 볼 권한이 없어요: {repo}")
        return 4
    files = pick(info)
    state = load_state(d)
    done = {k for k, v in state.items() if v.get("commit") == info.sha}

    if cmd == "plan":
        print(sum(size_of(s) for s in files if s.rfilename not in done))
        return 0

    total = sum(size_of(s) for s in files)
    print(f"  파일 {len(files)}개, {total / 2**30:.1f} GB (커밋 {info.sha[:8]})")
    os.makedirs(d, exist_ok=True)
    for i, s in enumerate(files, 1):
        name, size = s.rfilename, size_of(s)
        path = os.path.join(d, *name.split("/"))
        if name in done and os.path.exists(path) and os.path.getsize(path) == size:
            continue
        print(f"  ({i}/{len(files)}) {name} ({size / 2**20:.0f} MB)", flush=True)
        for attempt in range(1, 6):
            try:
                hf_hub_download(repo, name, revision=info.sha, local_dir=d, token=token)
                break
            except GatedRepoError:
                print("  승인이 필요한 파일이에요. 약관 동의와 토큰을 확인하세요.")
                return 3
            except Exception as e:  # 끊김 등은 이어받기로 다시 시도
                print(f"  연결이 끊겼어요({type(e).__name__}). 20초 뒤 이어받아요({attempt}/5)", flush=True)
                time.sleep(20)
        else:
            return 1
        if os.path.getsize(path) != size:
            print(f"  크기가 맞지 않아요: {name}. 지우고 다시 받아요.")
            os.remove(path)
            return 1
        digest = sha256(path)
        if s.lfs and s.lfs.sha256 and digest != s.lfs.sha256:
            print(f"  sha256이 맞지 않아요: {name}. 지우고 다시 받아요.")
            os.remove(path)
            return 1
        state[name] = {"commit": info.sha, "sha256": digest}
        with open(os.path.join(d, STATE), "w", encoding="utf-8") as f:
            json.dump(state, f)

    # GPU 서버에서 확인할 체크섬 목록(경로는 받는 곳 기준 상대 경로)
    base = os.path.basename(os.path.normpath(d))
    with open(os.path.join(d, SUMS), "w", encoding="utf-8", newline="\n") as f:
        for s in files:
            f.write(f"{state[s.rfilename]['sha256']}  {base}/{s.rfilename}\n")
    with open(os.path.join(d, "b200_model.json"), "w", encoding="utf-8") as f:
        json.dump({"repo": repo, "commit": info.sha, "files": len(files), "bytes": total,
                   "license": getattr(info.card_data, "license", None)}, f, ensure_ascii=False)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(*sys.argv[1:4]))
    except Exception as e:
        print(f"  오류: {type(e).__name__}: {e}")
        sys.exit(1)
