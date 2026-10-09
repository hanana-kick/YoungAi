# 단일 디렉터리 서빙 (DGX Spark / Linux)

이 포크의 `setup.sh`는 **현재 체크아웃한 소스를 빌드**하고 `bin/ds4-server`와
`run.sh`를 만듭니다. 기본 포트는 **8000**, API 모델 ID는 **big**입니다.
상위 저장소의 `install.sh`나 사전 빌드 바이너리는 실행/다운로드하지 않습니다.

## 설치 위치와 빌드

원하는 경로 자체에 저장소를 복제합니다. 경로에는 공백을 포함해도 됩니다.

```bash
# PR 병합 전에는 작업 브랜치를 명시합니다.
git clone --branch feat/local-serving https://github.com/hanana-kick/YoungAi.git /data/youngai
cd /data/youngai
bash setup.sh
```

이미 복제했다면 해당 디렉터리에서 `bash setup.sh`를 실행합니다.
필요한 것은 기존 Linux C/CUDA 빌드 환경(`make`, C 컴파일러, CUDA toolkit/nvcc)과
기본 유틸리티입니다. 누락된 패키지를 자동으로 설치하거나 `sudo`를 실행하지 않습니다.
`JOBS=4`, `CUDA_ARCH=native`가 기본이며 `CUDA_HOME`, `NVCC`, `JOBS`로 변경할 수 있습니다.
현재 upstream의 `cuda-spark`와 같은 아키텍처 설정으로 서버 타깃만 빌드합니다.
추가 헤더 변경도 반영하도록 `make -B`로 재빌드합니다.

```text
/data/youngai/
├── setup.sh
├── run.sh                    # setup.sh가 생성, Git에서 제외
├── bin/ds4-server            # 소스에서 빌드한 바이너리
├── src/                     # 소스 및 Makefile의 .o 빌드 산출물
├── weights/                 # GGUF와 선택한 사이드카
├── engram/                  # 공식 n-gram 가중치 두 샤드
├── logs/build.log           # 빌드 로그, 필요 시 직접 저장하는 서버 로그
└── .runtime/                # HOME, 임시 파일, XDG/HF/CUDA/컴파일러 캐시
```

`setup.sh`는 **가중치를 다운로드하지 않습니다**. 요청한 빌드/실행 준비와
수백 GB의 다운로드를 분리했습니다. 기존 파일을 아래 위치로 복사/이동하거나
해당 경로로 직접 다운로드하십시오. 분할 배포 GGUF는 먼저 하나로 결합해야 합니다.
기존 외부 가중치에 심볼릭 링크를 걸면 디렉터리 삭제만으로 삭제되지 않으므로 사용하지 않습니다.

```text
weights/DeepSeek-V4.1-Flash-vq8sh14-q4k-mtpnative.gguf
weights/DeepSeek-V4.1-Flash-vq8sh14-q4k-mtpnative-grrb-code_fit_n15360-engine/
engram/model-00047-of-00048.safetensors
engram/model-00048-of-00048.safetensors
```

모델 원본: https://huggingface.co/wenzhouwu/YoungAi-DeepSeek-V4.1-Flash
공식 Engram 샤드: https://huggingface.co/deepseek-ai/DeepSeek-V4.1-Flash
사이드카는 코딩용 한 개만 지정하며 post-training 파일은 자동 적용하지 않습니다.

## 실행

```bash
./run.sh --dry-run          # 실제 명령 미리보기; GPU나 가중치 불필요
./run.sh                    # 127.0.0.1:8000, big, 포그라운드 실행

PORT=8001 SERVED_MODEL_NAME=coder BATCH=2 ./run.sh
HOST=0.0.0.0 ./run.sh        # 신뢰할 수 있는 내부망에서만 사용
./run.sh --served-model-name coder --port 8001
```

환경변수 `SERVED_NAME`도 이전 구성과의 호환성을 위해 지원합니다.
우선순위는 **뒤에 전달한 CLI 옵션 > SERVED_MODEL_NAME > SERVED_NAME > big**입니다.
바이너리를 직접 실행해도 `--served-model-name NAME`을 사용할 수 있습니다.
이 옵션을 생략한 직접 실행은 upstream의 모델 ID를 사용합니다.
ID는 1~200자의 영문/숫자 및 `._/-:`를 허용합니다.

`BATCH=0`은 단일 요청 경로이며 2~8로 바꿀 수 있습니다. 배치/컨텍스트 메모리와
실제 성능은 엔진 및 하드웨어 제한을 따릅니다. 이 작업은 양자화/스케줄러를 바꾸지 않습니다.
`MEM_BUDGET_MB=110000`이 기본입니다. 수치의 의미는 엔진의 `--mem-budget-mb`와 같습니다.

가중치 위치는 `MODEL_FILE`, `ENGRAM_DIR`, `ZCHAIN_DIR`로 변경할 수 있으나
런처는 체크아웃 내부 경로만 허용합니다. 상대 경로도 저장소 루트를 기준으로 해석합니다.

```bash
MODEL_FILE=weights/my-model.gguf ZCHAIN_DIR=weights/my-code-sidecar ./run.sh
ZCHAIN_DIR='' ./run.sh       # 사이드카를 사용하지 않는 기본 모델
./run.sh >logs/server.log 2>&1
```

서버는 자동 시작하지 않습니다. 데몬, systemd, cron, 자동 업데이트를 등록하지 않습니다.
`Ctrl+C`로 종료합니다. 기본 바인딩은 루프백이며 API 인증/방화벽을 대신하지 않습니다.

`setup.sh`를 다시 실행할 때 수정한 `run.sh`는 유지하고 `run.sh.new`를 생성합니다.
`bash setup.sh --force-run-script`는 `logs/`에 백업한 뒤 교체합니다.
`--skip-build`는 디렉터리와 런처만 준비하며 실제 바이너리 빌드를 보장하지 않습니다.

## 모델 이름과 모델 정보

```bash
curl -fsS http://localhost:8000/v1/models
curl -fsS http://localhost:8000/v1/models/big
curl -fsS http://localhost:8000/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"big","messages":[{"role":"user","content":"Reply with OK."}],"max_tokens":32}'
```

`/v1/models`는 실제로 로드한 모델 **한 개**만 반환합니다. Flash/Pro 두 개를
고정해서 내보내던 동작을 제거했습니다. 목록과 `/v1/models/{id}`는 동일한 객체를
사용합니다. 존재하지 않는 ID 조회는 HTTP 404와 `model_not_found` 오류를 반환합니다.
네임스페이스 ID의 URL 인코딩(`org%2Fcoder`)도 처리합니다.

OpenAI Model 공식 필드:

| 필드 | 의미 |
| --- | --- |
| `id` | 지정한 서빙 ID, 기본 런처에서는 `big` |
| `object` | `model` |
| `created` | 로컬 GGUF 파일의 수정 시각(Unix 초); 조회 불가 시 0 |
| `owned_by` | 기존 엔진 식별자 `ds4.c` |
| `shutdown_date` | 종료 일정이 없으므로 `null` |

`created`는 원본 모델의 학습/공개 시각이 아닙니다. 존재하지 않는 날짜를 만들지 않습니다.

로컬 서빙 확장 필드:

| 필드 | 의미 |
| --- | --- |
| `name` | 로드한 GGUF의 모델 이름 |
| `root`, `parent` | GGUF 파일명(전체 디스크 경로 비공개), `null` |
| `context_length`, `max_model_len` | 엔진이 실제 사용하는 컨텍스트 설정값 |
| `max_completion_tokens` | 컨텍스트와 `--max-output-tokens`를 반영한 최대 출력 상한 |
| `default_max_tokens` | `--tokens`로 설정한 기본 출력 길이를 위 상한 내로 제한한 값 |
| `top_provider` | 같은 컨텍스트/출력 상한, 비검열 플래그 |
| `supported_parameters` | 기존 엔진이 광고하는 요청 파라미터 목록 |

컨텍스트에는 입력과 출력이 함께 들어갑니다. 요청별 출력 여유는 입력 길이에 따라
줄어들며, 메타데이터의 큰 컨텍스트 값이 실제 모든 길이/동시성을 검증했다는 뜻은 아닙니다.
확장 필드는 OpenAI 표준의 필수 필드가 아닙니다. 가짜 가격, 권한, 비전 지원은 추가하지 않습니다.
공식 스키마: https://developers.openai.com/api/reference/resources/models/methods/list

`--served-model-name` 지정 시 Chat/Completions/Responses/Messages의 응답 모델명과
스트리밍 청크의 모델명도 지정한 값으로 정규화합니다. 기존 `deepseek-chat` /
`deepseek-reasoner` 요청 별칭은 사고 모드를 먼저 해석한 후 이름을 정규화하므로 유지됩니다.
기존의 단일 모델 요청 라우팅을 보존하며, 이 옵션이 새로운 멀티 모델 라우터를 만들지는 않습니다.

## 검증과 삭제

```bash
bash tests/local-serving.sh
```

테스트에는 C 컴파일러와 Node.js가 필요합니다. 서빙/설치에는 Node.js나 Python이 필요하지 않습니다.
모델 ID 파서, 실제 모델 JSON 직렬화 코드, 출력 상한, 경로 이동, 로컬 캐시,
런처 생성/보존/기본값을 가중치 없이 테스트합니다. 빌드 호출 및 런처 테스트는
가짜 make/서버를 사용하므로 실제 CUDA 빌드나 추론 성능 테스트를 대체하지 않습니다.
GitHub Actions는 이 테스트와 실제 수정한 C 파일의 CPU 모드 문법 검사도 수행하도록 구성했습니다.

서버를 종료한 후 이 체크아웃을 삭제하면 이 구성에서 관리하는 파일이 제거됩니다.
기존 CUDA 드라이버/컴파일러, OS 로그 및 셸 기록은 대상이 아닙니다. 이는 파일 경로를
통제하는 구성이지 컨테이너나 파일시스템 샌드박스가 아닙니다. 고급 CLI로 외부 경로를
직접 넘기거나 다른 upstream 도구를 따로 실행하면 이 정리 범위에서 벗어날 수 있습니다.
