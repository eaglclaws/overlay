# Overlay API

로고 파일과 위치 정보를 받아, 투명 배경의 **PNG 오버레이 한 장**으로 합성합니다. 캔버스 크기는 업로드된 이미지와 좌표로부터 **자동으로 잡힙니다**.

## 요구 사항

- Python 3.10+ 권장
- 의존성: `requirements.txt` 참고 (FastAPI, Uvicorn, Pillow 등)

## 로컬 실행

```bash
python3 -m venv .venv
source .venv/bin/activate   # Windows: .venv\Scripts\activate
pip install -r requirements.txt
uvicorn main:app --host 0.0.0.0 --port 8000
```

- API 문서(제한적): `http://127.0.0.1:8000/docs` — `multipart/form-data`와 파일 여러 개라 Swagger에서 입력이 불편할 수 있습니다. `curl` 또는 HTTP 클라이언트 사용을 권장합니다.

## API 요약

| 메서드 | 경로 | 설명 |
|--------|------|------|
| `GET` | `/` | 서비스 이름, `/docs` 링크 |
| `POST` | `/create-overlay` | 로고 + 좌표 → PNG 바이너리 응답 (`image/png`) |

### `POST /create-overlay`

- **형식**: `multipart/form-data`
- **`coordinates`**: JSON **문자열** (폼 필드 하나). 아래 형태의 배열.
- **`logos`**: 파일 필드 이름을 **`logos`로 동일하게** 반복해 여러 장 업로드 (순서는 무관).

### `coordinates` JSON 배열

각 원소는 객체 하나입니다.

| 필드 | 설명 |
|------|------|
| `file` 또는 `name` | 업로드할 파일의 **파일명**과 맞아야 합니다. 경로가 있으면 **basename**만 사용합니다. |
| `x`, `y` | 정수 픽셀. 해당 로고 **왼쪽 위** 모서리 좌표. |

- **그리기 순서**: 배열 **앞에 있는 항목이 아래**, 뒤로 갈수록 위에 그려집니다.
- **같은 파일을 여러 번**: `file`이 같은 항목을 배열에 여러 번 넣으면, 업로드는 한 번만 하면 됩니다. (아래 `curl` 예 참고)
- **업로드와 좌표 매칭**: 각 `file`/`name` 값은 반드시 업로드된 파일의 **basename**과 일치해야 하고, 업로드한 모든 파일은 `coordinates` 안에서 **한 번 이상** 참조되어야 합니다.

## 서버 배포 (선택)

저장소의 `deploy/` 디렉터리:

- **`overlay-api.service`**: systemd 유닛 (기본 설치 경로 `/opt/overlay-api`, 사용자 `overlay-api`)
- **`install.sh`**: 루트로 실행, venv·systemd 설치·서비스 활성화  
  `sudo ./deploy/install.sh --help` 참고. tarball 또는 `deploy/` 상위 디렉터리에서 실행.

방화벽(firewalld) 사용 시 `8000/tcp` 허용이 필요할 수 있습니다. `install.sh`에는 `--open-firewall` 옵션이 있습니다.

## 예시

```bash
curl -sS -X POST "http://127.0.0.1:8000/create-overlay" \
  -F 'coordinates=[{"file":"logo2.png","x":1200,"y":1500},{"file":"logo1.png","x":0,"y":0},{"file":"logo1.png","x":1500,"y":0},{"file":"logo1.png","x":0,"y":1000}]' \
  -F "logos=@logo1.png" \
  -F "logos=@logo2.png" \
  -o overlay.png
```

`logo1.png`를 세 위치에 반복 사용하는 예입니다. 업로드는 `logo1.png`, `logo2.png` 두 번만 하면 됩니다.