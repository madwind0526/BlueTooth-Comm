# Design Document

> Wave 1 확정 — 2026-06-01

## 배경

2026년 기상 이변으로 기지국 2000여개가 침수되어 통신 대란 발생.
인프라 의존 없이 사람들 간 연결을 유지하는 방법에 대한 아이디어 구체화.

---

## 핵심 문제

기존 통신 인프라(기지국, 서버)가 망가졌을 때 사람들이 통신할 방법이 없다.

---

## 플랫폼

- **Android** — 모바일 노드
- **Windows** — PC 노드
- iOS / Linux 는 향후 검토

**핵심 패키지:**

| 패키지 | 용도 | 플랫폼 |
|--------|------|--------|
| `flutter_blue_plus` | BLE 스캔·연결·GATT | Android (Peripheral+Central), Windows (Central 전용) |
| `flutter_background_service` | 화면 꺼진 상태 릴레이 | Android |
| `sqflite` | 로컬 메시지·키 저장 | 전체 |
| `cryptography` | Ed25519 서명 + X25519 키교환 + AES-GCM | 전체 |

---

## 노드 아키텍처

### 통신 계층 — BLE 단일화

모든 노드 간 통신은 **BLE만 사용**한다.
WiFi Direct·WiFi 핫스팟·TCP 소켓은 MVP 범위 제외.

```
1순위: BLE  (10~100m, 저전력, 모든 노드 간)
선택적: 잔존 LAN (Optional, 별도 모듈, 핵심 기능 의존 금지)
```

### 노드 역할

**모바일 노드 (Android 폰)**
- BLE Peripheral: 광고(Advertise), 연결 수락 → 서버 역할
- BLE Central: 다른 폰 스캔·연결 → 클라이언트 역할
- 두 역할 동시 운용 가능
- 메시지 송수신 + 릴레이

**PC 노드 (Windows)**
- BLE Central 전용: 주변 폰들에게 연결 요청
  (`flutter_blue_plus`가 Windows에서 Peripheral 미지원)
- Peripheral 역할 없음 → 폰이 PC에 먼저 연결하는 방식 불가
- 항상 켜진 상태, 배터리 제약 없음 → 안정적 릴레이
- 관리자 UI / 공지 발송

### PC 간 연결 방식

PC끼리 직접 연결 없음. **폰 메시 네트워크를 통해서만** PC↔PC 통신.

```
[PC-A] ←BLE→ [폰 B] ←BLE→ [폰 C] ←BLE→ [PC-D]

PC-A는 폰 B에 Central로 연결
PC-D는 폰 C에 Central로 연결
PC-A → PC-D 메시지는 폰 B, C를 통해 릴레이됨
```

이 구조로 WiFi 핫스팟 없이도 PC 간 통신이 가능하며,
아키텍처가 BLE 단일 프로토콜로 단순화됨.

### 전체 토폴로지

```
[폰 A] ←BLE→ [폰 B] ←BLE→ [폰 C] ←BLE→ [폰 D]
                ↑ BLE                ↑ BLE
            [PC 노드 1]          [PC 노드 2]
            (Central)            (Central)
            관리자 UI             관리자 UI
```

---

## 네트워크 가정

| 인프라 | 가정 | 비고 |
|--------|------|------|
| 인터넷 | ❌ DOWN | 기본 가정 |
| 기지국 / 셀룰러 | ❌ DOWN | 기본 가정 |
| 라우터 / 공유기 | ❌ DOWN | 기본 가정 |
| 일반 LAN | ❌ DOWN | 기본 가정 |
| BLE 라디오 | ✅ 항상 사용 가능 | 인프라 불필요, 기기 간 직접 |
| 잔존 LAN | ⚡ Optional | 별도 모듈, 핵심 기능 의존 금지 |

---

## 기능 우선순위

### Phase 1 — MVP (Android + Windows)
- BLE 기기 탐색 및 연결 (GATT 서비스 UUID 기반 필터링)
- 기기 ID 생성 (공개키 해시, 오프라인, 영구)
- Ed25519 키쌍 생성 및 로컬 암호화 저장
- QR 코드로 연락처(공개키) 직접 교환
- KEY_ANNOUNCE 브로드캐스트 (앱 시작 + 5분 주기 재전송)
- TOFU 핑거프린트 확인 및 신뢰 연락처 등록
- 1:1 텍스트 메시지 (직접 연결, E2E 암호화)
- 모든 패킷 Ed25519 서명 및 검증
- Heartbeat PING/PONG (30초, 2회 무응답 시 이웃 제거)

### Phase 2 — 메시 릴레이
- 멀티홉 메시지 전달 (Flooding + Reverse Path Filtering)
- msg_id 캐시 기반 중복 제거
- 네트워크 토폴로지 시각화
- Epidemic Routing 전환 검토

### Phase 3 — 관리자 기능
- 관리자 개인키 서명 기반 공지 브로드캐스트
- 기여도 측정 및 등급 부여

### Phase 4 — 확장
- 음성 메시지
- 위성 연동

---

## SCAN Tree 시각화 방향

참고 구현: `C:\Claude\Connection-map`

메뉴 이름은 `Tree`로 유지하지만, 단순한 계층형 목록이 아니라
자신을 중심으로 한 인터랙티브 네트워크 맵으로 표시한다.

### 기본 화면

- 중심 노드: 현재 기기
- 주변 노드: SCAN 응답으로 발견된 장비
- 연결선: 노드 간 직접 연결 관계
- force-directed 배치: 참고 구현의 Cytoscape.js `COSE` 스타일
- 줌, 팬, 전체 보기, 내 위치로 복귀
- 노드 클릭 시 선택 노드와 직접 연결선을 강조하고 나머지는 흐리게 표시
- 배경 클릭 시 강조 해제
- 노드 클릭 시 상세 정보 패널 표시

### 노드 표시 규칙

| 항목 | 표시 |
|------|------|
| 장비 유형 | PC / Phone 아이콘 |
| 통신 경로 | LAN=초록, Wi-Fi=파랑, Bluetooth=보라, 연결 없음=회색 |
| 중심 노드 | 별도 강조색 + `Me` 라벨 |
| 홉 수 | 중심 노드와의 거리 또는 상세 패널에 표시 |
| 신뢰 상태 | 신뢰 / 미확인 배지 |
| 상세 미수집 노드 | 반투명 또는 점선 스타일 |

노드 크기는 기본적으로 동일하게 두되, 직접 연결 수가 많은 노드는 제한된 범위에서
조금 크게 표시한다. 연결 수가 많은 노드가 화면을 과도하게 점유하지 않도록 상한을 둔다.

### SCAN 제어

- 상단: `SCAN START`, depth 입력, 정지, 새로고침, 내 위치, 전체 보기
- depth `N`: 나를 기준으로 최대 N홉 조회
- depth `-1`: 가능한 전체망 조회. 관리자 권한과 cooldown 적용
- SCAN은 `Tree` 단일 화면으로 제공한다.
- GPS/Map은 기능 범위에서 제외한다. 재난 상황에서 위치 권한, 지도 데이터,
  개인정보 부담이 크므로 현재 제품 방향과 맞지 않는다.

### 상세 정보 패널

- node ID 축약값
- 로컬 표시 이름
- PC / Phone
- 현재 사용 가능한 transport
- 홉 수
- 직접 연결 수
- 마지막 발견 시각
- 신뢰 상태
- 중심 이동
- 채팅 열기

### 경로 탐색

`C:\Claude\Connection-map\server\pathfinder.js`의 BFS 패턴을 참고한다.

- 나와 대상 사이의 최단 경로를 탐색
- 경로 카드 선택 시 해당 노드와 연결선만 강조
- 큰 그래프에서는 경로 개수와 탐색 노드 수에 상한 적용

### 구현 주의

`Connection-map`은 Electron + Cytoscape.js 앱이므로 Flutter 코드에 직접 복사하지 않는다.
초기 구현 전에 아래 두 Tree 렌더러를 작은 프로토타입으로 비교한다.

1. Flutter 네이티브 그래프 렌더러
2. 로컬 HTML Cytoscape.js 그래프를 임베드하는 렌더러

Android와 Windows에서 줌, 팬, 노드 클릭, 100~500개 노드 성능을 비교한 뒤 선택한다.

---

## 보안 설계

### 기기 ID 생성

```
앱 최초 설치 시:
  1. Ed25519 키쌍 생성
  2. node_id = SHA-256(공개키) 앞 16 bytes
  3. 개인키는 기기 로컬에 암호화 저장

특성:
  node_id는 공개키로부터 결정적으로 생성 → 위조 불가
  개인키를 모르면 해당 node_id로 서명 불가 → 사칭 불가
```

### TOFU 공개키 신뢰 모델

```
최초 연결:
  → 화면에 핑거프린트 표시 (예: "A1B2-C3D4-E5F6-G7H8")
  → 사용자가 QR 또는 구두로 상대방과 대조
  → 확인 → 신뢰 연락처 저장

이후:
  → 저장된 공개키와 다르면 경고 (기기 분실 재설치 등)
  → 사용자가 수동 재확인 후 새 키로 교체

미확인 연락처 (KEY_ANNOUNCE 브로드캐스트 수신):
  → 임시 목록에 추가
  → 직접 만나 QR 확인 시 신뢰 연락처로 승격
```

### 키 교환 플로우

**방법 1 — QR 직접 교환 (권장):**
```
A가 자신의 공개키 QR 표시
B가 QR 스캔 → 공개키 저장 + 핑거프린트 대조
B도 자신의 QR을 A에게 표시 → 양방향 완료
```

**방법 2 — KEY_ANNOUNCE 브로드캐스트:**
```
앱 시작 시 + 이후 5분마다:
  KEY_ANNOUNCE 패킷(msg_type=0x02) 브로드캐스트
  → 주변 기기들이 수신 → 임시 연락처에 추가
  → 나중에 QR 확인 시 신뢰 연락처로 승격
```

### 패킷 서명

```
서명 대상: 헤더 전체 + payload
알고리즘: Ed25519
검증 실패 시: 즉시 폐기, 릴레이하지 않음
KEY_ANNOUNCE 포함 모든 패킷에 서명 필수
```

---

## 메시지 패킷 구조 (확정)

```
┌─────────────────────────────────────────────────────────────────┐
│  version       1 byte   프로토콜 버전 (현재 2)                    │
│  msg_id      16 bytes  UUID v4, 중복 감지 및 루프 방지            │
│  sender_id   16 bytes  SHA-256(발신자 공개키) 앞 16 bytes         │
│  target_id   16 bytes  수신자 node_id (브로드캐스트 = 0xFF × 16)  │
│  msg_type     1 byte   메시지 유형 (아래 표)                      │
│  ttl          1 byte   남은 홉 수 (기본 7, 0이면 폐기)            │
│  hop_count    1 byte   경유 홉 수 (0에서 시작, 릴레이마다 +1)     │
│  timestamp    8 bytes  발신 Unix timestamp ms (UI 표시용)        │
│  signature   64 bytes  Ed25519 발신자 서명                       │
│  payload   최대 4096 bytes  암호화된 메시지 본문                  │
└─────────────────────────────────────────────────────────────────┘
총 헤더 124 bytes + payload ≤ 4220 bytes

MTU 협상: 연결 후 requestMtu(512) 시도.
BLE 전송: MeshPacket 전체를 협상 MTU에 맞는 전송 프레임으로 분할한다.
         수신 노드는 device_id + transfer_id 기준으로 재조립 후 패킷을 검증한다.
         릴레이 노드는 재조립·검증 후 다음 이웃 MTU에 맞춰 다시 분할한다.
```

### BLE 조각 프레임

```
magic 2 bytes ("MC") + frame_version 1 + flags 1
+ transfer_id 4 + fragment_index 2 + fragment_count 2
+ fragment payload
```

- ATT 헤더 3 bytes를 제외한 크기에 맞춰 항상 프레임 단위로 전송한다.
- 기본 MTU 23에서도 동작한다. Windows ↔ S21+에서 MTU 23 전송을 확인했다.
- 미완성 조각 묶음은 30초 후 폐기한다.

**msg_type 정의:**

| 값 | 유형 | 설명 |
|----|------|------|
| 0x01 | TEXT | 일반 텍스트 메시지 |
| 0x02 | KEY_ANNOUNCE | 공개키 브로드캐스트 공지 (서명 필수) |
| 0x03 | ADMIN_NOTICE | 관리자 서명 공지 |
| 0x04 | ACK | 수신 확인 (Phase 2 구현) |
| 0x05 | PING | Heartbeat 요청 |
| 0x06 | PONG | Heartbeat 응답 |

**msg_id 캐시 정책:**
- 보존 기간: 30분
- 최대 크기: 10,000개 FIFO (오래된 것부터 제거)

---

## Flooding 브로드캐스트 폭풍 완화

**Reverse Path Filtering 규칙:**

```
받은 BLE 연결(connection 객체)로는 같은 msg_id를 재전송하지 않는다.

예시:
  A → B → C : B는 A로부터 받은 메시지를 A에게 재전송 안 함
  B는 A를 제외한 나머지 연결(C, D...)에만 릴레이

효과: 단순 Flooding 대비 트래픽 대폭 감소
Phase 2에서 Epidemic Routing으로 교체 예정
```

---

## BLE 기기 발견 (Discovery)

```
광고 패킷 내용:
  - 커스텀 GATT 서비스 UUID (앱 고유값, 일반 BLE 기기 필터링)
  - node_type: 0x01=mobile, 0x02=pc
  - node_id: 16 bytes (공개키 해시)
  - app_version: 1 byte

스캔 모드:
  기본: SCAN_MODE_LOW_POWER (배터리 절약)
  연결 중: 일시적 BALANCED 전환
  배터리 20% 이하: 광고 주기 자동 연장
```
