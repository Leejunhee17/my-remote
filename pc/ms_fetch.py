"""ModelScope 데이터셋 저장소를 통째로 받는다(이어받기). datasets_download.ps1 이 부른다.

  ms_fetch.py <데이터셋 ID> <local_dir>

modelscope 명령을 그대로 부르되, 회사 보안 장비 인증서를 쓰는 망에서도 되도록 윈도우 인증서 저장소를 쓰게 한다
(hf_fetch.py 와 같은 방법). 그냥 modelscope 명령을 쓰면 파이썬 자체 인증서 목록만 봐서, 브라우저로는 열리는데
스크립트만 "CERTIFICATE_VERIFY_FAILED" 로 실패할 수 있다.
"""

import sys

try:
    import truststore

    truststore.inject_into_ssl()
except Exception:
    pass

from modelscope.cli.cli import run_cmd  # "python -m modelscope.cli.cli" 와 같은 입구(modelscope 가 계속 두겠다고 한 곳)

sys.argv = ["modelscope", "download", "--dataset", sys.argv[1], "--local_dir", sys.argv[2]]
run_cmd()
