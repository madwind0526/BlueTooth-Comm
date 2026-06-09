# MeshComm

> **재난 상황에서 인터넷·기지국 없이 동작하는 P2P BLE 메시 네트워크 메신저**

---

## 개요

2026년 기상 이변으로 기지국 2,000여 개가 침수되어 통신 대란이 발생했습니다.  
MeshComm은 이처럼 통신 인프라가 완전히 마비된 상황에서도 사람들이 스마트폰만으로 서로 연결될 수 있도록 설계된 **오프라인 우선 P2P 메신저**입니다.

토렌트처럼 각 기기가 서버 역할을 하며, BLE(Bluetooth Low Energy)로 주변 기기와 직접 연결한 뒤 릴레이 방식으로 메시지를 전파합니다.

```
[폰 A] ←BLE→ [폰 B] ←BLE→ [PC] ←BLE→ [폰 C]
              ↑ 릴레이          ↑ 릴레이
        (A→C 직접 불가 시 B, PC가 중계)
```

---

## 핵심 특징

| 항목 | 내용 |
|------|------|
| **인프라 불필요** | 인터넷, 기지국, 라우터 없이 동작 |
| **E2E 암호화** | X25519 ECDH 키교환 + AES-GCM 암호화 (릴레이 노드 열람 불가) |
| **패킷 서명** | Ed25519 서명으로 발신자 위조 방지 |
| **BLE 메시** | Flooding + Reverse Path Filtering 릴레이 |
| **LAN/Wi-Fi 전송** | 같은 Wi-Fi 네트워크 내 UDP 비콘 발견 + TCP 소켓 전송. LAN 우선, BLE 폴백 |
| **파일 전송** | LAN: 최대 4KB 청크, BLE: 340B 청크. 양방향 ACK + 15초 타임아웃 + 3회 재시도 |
| **MTU 적응** | BLE MTU 23~517 bytes 자동 fragmentation/reassembly |
| **Heartbeat** | 30초 PING/PONG, 2회 무응답 시 자동 이웃 제거. LAN TCP keepalive 30초 |
| **TOFU 신뢰** | QR 핑거프린트 대조로 공개키 진위 확인 |
| **암호화 백업** | 신원(키쌍) PBKDF2+AES-GCM 암호화 내보내기/복원 |
| **토폴로지 스캔** | LAN·BLE 모두 지원. N-depth 이웃 요청·응답으로 메시 구조 시각화 |
| **역할 관리** | Creator/Builder/Admin/User/Server 역할 체계 + 공지 쿨다운 정책 |

---

## 플랫폼 및 역할

| 노드 | 플랫폼 | BLE 역할 | 특징 |
|------|--------|----------|------|
| 모바일 노드 | Android | Peripheral + Central | 광고·스캔 동시, 배경 릴레이 |
| PC 노드 | Windows | Central 전용 | 항상 켜진 안정 릴레이, 관리자 UI |

> **PC 간 통신:** 직접 연결 없음. 폰 메시 네트워크를 통해서만 PC↔PC 통신.

> **⚠️ PC BLE 페어링 제약:** Windows PC는 연결할 Android 핸드폰마다 OS 수준 사전 페어링이 필요합니다 (설정 → Bluetooth에서 수동 등록). 이는 코드 문제가 아닌 Windows Bluetooth 스택의 하드웨어 수준 제약입니다. 따라서 **PC 노드는 사전에 등록된 고정 거점 릴레이 역할에 적합**하며, 재난 상황에서 낯선 사람끼리 즉석으로 연결하는 메시의 핵심 노드는 **Android 폰**입니다 (Android BLE는 OS 페어링 없이 동작).

---

## 검증된 토폴로지

실기기 3대(Galaxy S21+, Galaxy S26 Ultra, Windows PC)로 검증 완료:

```
✅ Android ↔ Windows 직접 연결 + 암호화 TEXT 양방향
✅ S21+ ↔ PC ↔ S26 Ultra  (2홉 릴레이)
✅ S26 Ultra ↔ S21+ ↔ PC  (2홉 릴레이)
✅ PC ↔ S21+ ↔ S26 Ultra  (2홉 릴레이)
✅ Identity Backup/Restore — 재설치 후 노드 ID 복원 검증
⏳ 3홉 릴레이 E2E 검증 예정
```

---

## 기술 스택

```
Flutter (Dart)
├── flutter_blue_plus        BLE 스캔·연결·GATT (Central)
├── ble_peripheral            Android BLE Peripheral GATT 서버
├── cryptography              Ed25519 서명 + X25519 ECDH + AES-GCM + PBKDF2
├── sqflite                   로컬 SQLite DB (v8, 오프라인 전용)
├── flutter_background_service Android 백그라운드 BLE 릴레이
├── mobile_scanner            QR 스캔
└── qr_flutter                QR 생성
```

---

## 프로젝트 구조

```
BlueTooth-Comm/
├── mesh_comm/                    Flutter 앱
│   ├── lib/
│   │   ├── core/
│   │   │   ├── ble/              BLE 서비스 (스캔·연결·GATT·fragment·retry)
│   │   │   ├── crypto/           암호화 서비스 (Ed25519·X25519·AES-GCM)
│   │   │   ├── packet/           패킷 구조 (직렬화·역직렬화·서명)
│   │   │   └── storage/          SQLite DB (v8 마이그레이션)
│   │   ├── features/
│   │   │   ├── identity/         기기 ID·키쌍·역할·암호화 백업·복원
│   │   │   ├── contacts/         연락처·TOFU·즐겨찾기·그룹·역할
│   │   │   ├── messaging/        메시지 송수신·릴레이·정책·토폴로지 스캔
│   │   │   └── settings/         앱 설정 (알림·역할·데모모드)
│   │   └── ui/
│   │       ├── home/             연락처 목록·그룹·필터·SCAN 그래프
│   │       ├── chat/             1:1 채팅 (일반·타임드·공지S·공지L)
│   │       └── qr/               QR 생성·스캔·TOFU 확인
│   ├── android/                  Android 설정·권한
│   └── windows/                  Windows 설정
├── memory-bank/                  설계 문서 (RULES·PATTERNS·CACHE)
├── code-review.md                코드 리뷰 기록
└── CLAUDE.md                     AI 에이전트 진입점
```

---

## 빌드 및 실행

### 요구사항
- Flutter SDK 3.44+
- Android Studio (Android 빌드용)
- Visual Studio 2022 (Windows 빌드용)

### Android 빌드

```bash
cd mesh_comm
flutter pub get
flutter run -d android          # 연결된 기기에 설치
flutter build apk               # APK 빌드
```

**권한 주의 (Android 12+):** BLE 스캔 시 `ACCESS_FINE_LOCATION` 또는 위치 서비스가 켜져 있어야 합니다 (삼성 기기 기준).

### Windows 빌드

```bash
cd mesh_comm
flutter pub get
flutter run -d windows          # 개발 모드 실행
flutter build windows           # 릴리즈 빌드
```

---

## 보안 설계

### 기기 ID (node_id)
```
node_id = SHA-256(Ed25519 공개키) 앞 16 bytes
→ 위조 불가, 사칭 불가
```

### 메시지 암호화
```
sharedSecret = X25519 ECDH(내 개인키, 상대 공개키)
ciphertext   = AES-GCM(plaintext, sharedSecret, random_nonce)
→ 릴레이 노드는 내용 열람 불가
```

### 패킷 신뢰
```
서명   = Ed25519(sender_private_key, packet_bytes)
검증   = Ed25519.verify(sender_public_key, signature)
실패 시 = 즉시 폐기, 릴레이 안 함
```

### 신뢰 모델 (TOFU)
```
최초 연결 → QR 코드로 핑거프린트 대조 → 신뢰 등록
이후 공개키 변경 감지 시 → 경고 + 재확인 요구
```

### 신원 백업
```
백업 = PBKDF2-HMAC-SHA256(password, random_salt) → AES-GCM 암호화
복원 = 동일 비밀번호 입력 → 복호화 → 키쌍 복원
앱은 백업 비밀번호를 저장하지 않음
```

---

## 메시지 패킷 구조

```
┌─────────────────────────────────────────────────┐
│ version    1 byte   프로토콜 버전 (현재 v2)        │
│ msg_id    16 bytes  UUID v4 (중복·루프 방지)        │
│ sender_id 16 bytes  SHA-256(공개키) 앞 16 bytes    │
│ target_id 16 bytes  수신자 ID (FF×16 = 브로드캐스트) │
│ msg_type   1 byte   TEXT/KEY/TOPO/ACK/PING/PONG   │
│ ttl        1 byte   남은 홉 수 (기본 7)             │
│ hop_count  1 byte   경유 홉 수 (255 오버플로 방지)   │
│ timestamp  8 bytes  발신 시각 (ms)                 │
│ signature 64 bytes  Ed25519 발신자 서명             │
│ payload  가변       AES-GCM 암호화 본문             │
└─────────────────────────────────────────────────┘
```

BLE MTU에 맞게 자동 분할 전송 후 수신 측 재조립 (`MC` magic + transfer_id + fragment_index).

---

## 사용자 역할 체계

| 역할 | 설명 | 공지S 쿨다운 | 공지L 쿨다운 | 연락처 한도 |
|------|------|-------------|-------------|------------|
| Creator | 네트워크 창설자 | 무제한 | 무제한 | 무제한 |
| Builder | 핵심 운영자 | 1시간 | 2시간 | 무제한 |
| Admin | 관리자 | 2시간 | 4시간 | 무제한 |
| User | 일반 사용자 | 6시간 | 24시간 | 10 |
| Server | 자동화 릴레이 노드 | 불가 | 불가 | — |

> **역할 할당:** Creator가 최상위. 역할 변경은 자신보다 낮은 레벨의 연락처에만 가능.

---

## SCAN 토폴로지

SCAN 화면은 BLE 이웃 노드를 N-depth까지 탐색하고 그래프로 시각화합니다.

```
[SCAN START] → TOPOLOGY_REQUEST 브로드캐스트 (depth 제한 포함)
             ← TOPOLOGY_RESPONSE (각 노드의 1-hop 이웃 요약)
             → BFS 그래프 빌드 → 동심원 레이아웃으로 렌더링
```

- depth=1: 직접 연결된 이웃만
- depth=3: 3홉 내 모든 노드 (User/Server 기본 최대 depth)
- depth=-1: 무제한 (Admin 이상)
- **데모 모드:** Settings에서 활성화 시 27노드 가상 메시 시나리오 표시

---

## 채팅 모드

| 모드 | 전송 대상 | 특징 |
|------|-----------|------|
| 일반 | 1:1 대화 상대 | 기본 채팅, E2E 암호화 |
| 타임드 | 1:1 | 수신 후 1분 자동 삭제 |
| 공지S | 직접 연결 연락처 | 50자 이내, 레벨별 쿨다운 |
| 공지L | 메시 전체 브로드캐스트 | 50자 이내, 레벨별 쿨다운 |

---

## 개발 로드맵

| 단계 | 상태 | 내용 |
|------|------|------|
| Wave 1 | ✅ 완료 | 아키텍처 설계·보안 모델 확정 |
| Wave 2 | ✅ 완료 | MVP 구현 (BLE·암호화·UI 기반) |
| Wave 3 | ✅ 완료 | 실기기 검증·버그 수정 (2홉 릴레이 확인) |
| Phase 1 | ✅ 완료 | UI 완성 (앱 셸·연락처·채팅·역할·공지) |
| Phase 2 | 🔄 진행 | N-depth 토폴로지 프로토콜 백엔드 완료, UI 렌더링 진행 중 |
| Phase 3 | ⏳ 예정 | 그룹 메시지·관리자 공지 |
| Phase 4 | ⏳ 예정 | 음성 메시지·위성 연동 |

---

## 알려진 제한 사항

- **개인키 저장:** 현재 DB에 평문 저장 — `flutter_secure_storage` 교체 예정
- **3홉 릴레이:** 2홉까지 검증, 3홉 E2E 검증 예정
- **개발용 Manufacturer ID:** `0xFFFF` — 배포 전 Bluetooth SIG 할당 ID로 교체 필요
- **위치 권한:** 삼성 Android 기기에서 BLE 스캔 시 위치 서비스 활성화 필요
- **토폴로지 UI:** 백엔드 완료, SCAN 그래프 렌더링 완료, UI 고도화 진행 예정
- **PC BLE 사전 페어링:** Windows PC와 Android 핸드폰 연결 시 Windows 설정에서 수동 페어링 필요. 재난 즉석 연결에는 적합하지 않으며, PC는 사전 등록된 거점 릴레이 용도로 사용 권장

---

## 라이선스

Private — 모든 권리 보유

---

*MeshComm은 재난 시 사람들이 서로 연결될 수 있어야 한다는 믿음에서 시작했습니다.*
