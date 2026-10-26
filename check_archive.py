"""압축 파일을 끝까지 읽어 깨졌는지 본다. datasets_download.ps1 이 부른다.

종료 코드 0: 정상, 1: 깨짐, 2: 모르는 형식이라 검사하지 않음.
"""

import sys
import tarfile
import zipfile


def main(path):
    with open(path, "rb") as f:
        head = f.read(4)

    if head.startswith(b"PK"):
        with zipfile.ZipFile(path) as z:
            bad = z.testzip()
        if bad:
            print(f"  깨짐: {bad}")
            return 1
        return 0

    try:
        t = tarfile.open(path)
    except tarfile.ReadError:
        print("  zip, tar 가 아니라 검사하지 않음")
        return 2
    with t:
        for m in t:
            if m.isfile():
                f = t.extractfile(m)
                while f.read(1 << 20):
                    pass
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1]))
    except Exception as e:
        print(f"  깨짐: {e}")
        sys.exit(1)
