# MeshComm Code Review Log

> 날짜별 리뷰 결과를 누적 기록합니다.

---

## 2026-06-07 — Export/Import + File Transfer Direct-Only

### 리뷰 범위

| 파일 | 변경 내용 |
|------|-----------|
| `lib/core/lan/lan_service.dart` | `hasPeer()` 추가 |
| `lib/features/messaging/messaging_service.dart` | 직접 연결 추적, `isDirectlyConnected()`, 파일 relay 차단, `sendFile` 직접 연결 검사 |
| `lib/ui/chat/chat_screen.dart` | 페이퍼클립 제거, 드롭다운에 파일/이미지 항목 추가 |
| `lib/core/storage/database_service.dart` | `exportAllMessagesRaw()`, `importMessagesRaw()`, `deleteAllSavedContacts()` |
| `lib/features/contacts/contact_file_service.dart` | `exportBackupToJson()`, `importContactsFromBackupJson()`, `importConversationsFromJson()`, 메시지 직렬화 헬퍼 |
| `lib/ui/home/home_screen.dart` | Export/Import 다이얼로그, `_deleteAllContacts()`, Settings "연락처 전부 지우기" |

### Critical Issues (수정 완료)

**C-1. `ContactService().refresh()` await 누락 → 수정됨**
- **위치**: `_deleteAllContacts()` (home_screen.dart)
- **문제**: `await` 없이 호출 → `_loadContacts()` 실행 시 리프레시 미완료 상태로 race condition
- **수정**: `await` + `if (!mounted) return` 가드 추가

**C-2. Export 다이얼로그 "전체 선택" 부분 선택 상태 미표현 → 수정됨**
- **위치**: `_ExportDialogState` (home_screen.dart)
- **문제**: `tristate: false` 사용으로 부분 선택 상태 시각화 불가
- **수정**: `tristate: true` + `bool? _allSelectedState` 계산 프로퍼티 (null=부분, true=전체, false=없음)

### Warnings (확인 필요)

**W-1. `hopCount == 0` 직접 연결 추적의 이론적 spoofing 위험**
- 악의적 노드가 hopCount=0 위조 가능. 단, 서명 검증(R-07)이 패킷 진위 보장하므로 실용적 위험 낮음
- 향후 BLE 레이어에서 deviceId→nodeId 직접 매핑으로 개선 권고

**W-2. 대규모 메시지 export/import 메모리 사용**
- 전체 메시지 일괄 메모리 로드. 개인 P2P 앱 특성상 즉각적 위험 없음
- 향후 필요 시 배치 크기 제한(500건/배치) 추가 권고

**W-3. `encryptionPublicKey` 길이 미검증 (import)**
- `nodeId`/`publicKey` 검증하지만 `encryptionPublicKey` 길이 검증 없음
- 향후 `encryptionPublicKey.length != 32` 조건 추가 권고

### Minor

- Import 시 `is_read = 0`으로 초기화 (읽었던 메시지도 안읽음으로 보임) → 의도된 동작
- 구버전(`mesh_comm_contacts`) + 신버전(`mesh_comm_backup`) 모두 `contacts` 키 최상위 → 하위 호환됨
- Export 파일명을 `mesh_comm_backup_<timestamp>.json`으로 통일

### 전체 평가: 8.5/10

강점: 레이어 분리 명확, relay 차단으로 0% 버그 근본 해결, tristate 체크박스 UX, import 타입 선택 후 파일 picker 순서 직관적
개선된 항목: C-1/C-2 수정 완료
향후 과제: hopCount 기반 추적 → transport 레이어 직접 노출로 개선, 메시지 export 페이지네이션
> 각 리뷰는 `## [날짜]` 섹션으로 구분되어 이전 결과와 겹치지 않습니다.

---

<!-- ================================================================ -->
## 2026-06-03 — Wave 3 실기기 검증 후 리뷰

> **리뷰 시점:** S21+, S26 Ultra, Windows PC 3대로 1홉·2홉 릴레이 검증 완료 후
> **리뷰 방법:** 소스 파일 14개 직접 읽기 + CACHE.md + RULES.md 교차 검증
> **전체 평가:** 🟢 양호 (88/100) — 배포 직전 수준의 완성도

### ✅ 이번 리뷰에서 확인된 것

| 항목 | 결과 |
|------|------|
| Wave 2 릴레이 재서명 버그 | ✅ 수정 확인 (ttl/hopCount 서명 제외) |
| Wave 2 markMessageSeen 순서 역전 | ✅ 수정 확인 (서명 검증 후 등록) |
| Wave 2 SHA-256 공개 sharedSecret | ✅ 수정 확인 (X25519 ECDH로 교체) |
| X25519 ECDH 대칭성 | ✅ 수학적으로 올바름 |
| AES-GCM nonce 재사용 | ✅ 없음 (cryptography 패키지 자동 random) |
| Fragment 메모리 누수 | ✅ 없음 (30초 타임아웃 정리 확인) |
| R-04 BLE 단일화 | ✅ WiFi/TCP 코드 없음 |
| R-03 오프라인 우선 | ✅ 외부 서버 호출 없음 |
| DB v1→v2→v3 마이그레이션 | ✅ 안전 (각 버전 독립 체크) |

---

### 🔴 즉시 수정 필요 (2건)

#### R-1. 개인키 평문 DB 저장 — 기기 탈취 시 모든 암호화 뚫림

- **파일:** `lib/features/identity/identity_service.dart`
- **문제:** Ed25519 + X25519 개인키 seed가 SQLite에 암호화 없이 저장됨
- **위험:** 폰을 빼앗기면 공격자가 ADB/루팅으로 DB 꺼내 과거 메시지 전부 복호화 가능
- **해결:** `flutter_secure_storage` 패키지로 OS 키체인에 저장

#### R-2. seen_messages 개수 제한 없음 — 장기 실행 시 DB 무한 증가

- **파일:** `lib/core/storage/database_service.dart` → `cleanOldSeenMessages()`
- **문제:** 30분 TTL은 있으나 RULES.md R-09의 10,000개 FIFO 상한 미구현
- **위험:** 수일 연속 실행 시 DB 용량 급증 + 조회 속도 저하
- **해결:** TTL 삭제 후 아래 SQL 추가
  ```sql
  DELETE FROM seen_messages
  WHERE msg_id NOT IN (
    SELECT msg_id FROM seen_messages ORDER BY seen_at DESC LIMIT 10000
  );
  ```

---

### 🟡 개선 권장 (6건)

| # | 파일 | 문제 | 해결 |
|---|------|------|------|
| W-1 | `ble_service.dart` | 스캔 모드 `lowLatency` → R-12 위반 (배터리 최대 소모) | `lowPower`로 변경 |
| W-2 | `ble_service.dart` | `broadcastPacket()` 순차 전송 → 이웃 많을수록 느림 | `Future.wait()`으로 병렬화 |
| W-3 | `messaging_service.dart` | `_keyAnnounceRespondedNodeIds` Set 무한 증가 | 주기적 `.clear()` |
| W-4 | `messaging_service.dart` | `_bytesEqual()` 2곳 중복 구현 | 공통 유틸로 추출 |
| W-5 | `ble_service.dart` | char 캐시 미스 시 `discoverServices()` 재실행 | 캐시 미스 = 버그로 처리 후 false 반환 |
| W-6 | `chat_screen.dart` | 바이트 비교 로직 인라인 복잡 코드 | `_bytesEqual()` 유틸 사용 |

---

### 🔵 참고 사항 (배포 전 체크리스트)

- [ ] `BleConstants.developmentManufacturerId = 0xFFFF` → Bluetooth SIG 할당 ID 교체 필요
- [ ] 3홉 릴레이 (A↔PC↔B↔C) 실기기 E2E 검증 미완료
- [ ] `parseKeyAnnouncePacket()` — 서명 검증 선행 가정이 코드 주석에만 존재 (추후 타입으로 강제 권장)

---

### 📋 다음 단계 (우선순위 순)

1. **[보안]** `flutter_secure_storage`로 개인키 seed 암호화 저장
2. **[R-09]** seen_messages 10,000개 FIFO 제한 추가
3. **[R-12]** 스캔 모드 `lowPower`로 변경
4. **[성능]** `broadcastPacket()` 병렬화
5. **[코드정리]** `_bytesEqual` 공통 유틸 추출
6. **[검증]** 실기기 3홉 릴레이 E2E 테스트
7. **[배포전]** Manufacturer ID 0xFFFF 교체
8. **[Phase 2]** ACK 수신 확인 구현
9. **[Phase 2]** 공개키 변경 감지 UI 경고

---
<!-- ================================================================ -->

<!-- ================================================================ -->
## 2026-06-04 — Wave 3 심층 독립 에이전트 3-way 리뷰

> **리뷰 시점:** v1.0.H (20260604-214748) — 레벨 정책, 공지 채팅, DB v8, UI 개선 완료 후  
> **리뷰 방법:** 3개 독립 에이전트 병렬 실행 (보안/프로토콜/UI 각 독립 검토)  
> **전체 평가:** 🟡 주의 (핵심 암호화 설계 정확, 프로덕션 배포 전 수정 필요 항목 다수)

### 결과 요약

| 영역 | CRITICAL | HIGH | MEDIUM | LOW |
|------|----------|------|--------|-----|
| 보안 & 암호화 | 2 | 4 | 4 | 5 |
| 프로토콜 & 아키텍처 | 5 | 6 | 8 | 6 |
| UI & 비즈니스 로직 | 5 | 6 | 8 | 7 |
| **합계** | **12** | **16** | **20** | **18** |

---

### 🔴 CRITICAL — 즉시 수정 필요

#### [보안] C-1. 개인키 SQLite 평문 저장 (이전 R-1과 동일, 미수정)
- **파일:** `identity_service.dart:66`, `identity_backup_service.dart:15-43`
- **문제:** Ed25519 + X25519 개인키가 DB에 암호화 없이 저장. 백업 JSON에도 평문 포함.
- **해결:** `flutter_secure_storage`로 개인키 seed 이동, 백업 파일 AES-GCM 암호화.

#### [프로토콜] C-2. hopCount 255 오버플로 → 무한 릴레이 루프
- **파일:** `messaging_service.dart:542-563`
- **문제:** `hopCount`가 255에 도달하면 0으로 순환, TTL과 무관하게 무한 릴레이.
- **해결:** `if (packet.hopCount >= 255) return;` 조건 추가.

#### [프로토콜] C-3. 단편 재조립 데이터 손상
- **파일:** `ble_fragment_codec.dart:104-107`
- **문제:** 동일 transferId로 새 전송 도착 시 이전 조립 버퍼 무조건 덮어씀. 지연 도착 단편이 새 데이터 오염.
- **해결:** transferId에 시퀀스 번호 또는 타임스탬프 추가 후 불일치 시 이전 버퍼 폐기.

#### [프로토콜] C-4. 송신 큐 메모리 누수
- **파일:** `ble_service.dart:269-277`
- **문제:** `identical()` 비교 실패 시 이전 Future 참조가 `_sendQueues` 맵에 영구 잔존.
- **해결:** `_sendQueues[deviceId] = null`로 명시적 해제 또는 WeakReference 사용.

#### [UI] C-5. 서명 검증 순서 역전 (이전 Wave 2 리뷰 재발)
- **파일:** `messaging_service.dart:501-518`
- **문제:** `isMessageSeen()` 호출이 서명 검증보다 먼저. 잘못된 서명 패킷이 동일 msg_id로 정상 패킷 차단 가능.
- **해결:** `isMessageSeen()` 호출을 서명 검증 이후로 이동.

#### [UI] C-6. async 콜백 mounted 체크 누락 다수
- **파일:** `home_screen.dart:178-181, 215-217`, `chat_screen.dart:143-144`
- **문제:** BLE 토글 및 10초 Future 콜백 완료 시점에 위젯 해제 여부 미확인. setState 예외 발생.
- **해결:** 모든 async 콜백에 `if (!mounted) return;` 추가.

---

### 🟠 HIGH — Wave 4 목표

| # | 파일 | 문제 |
|---|------|------|
| H-1 | `identity_backup_service.dart:82-89` | 백업 무결성 HMAC 없음. 공개키+개인키 동시 교체 공격 가능. |
| H-2 | `messaging_service.dart:580-601` | 브로드캐스트(공지L) 평문 전송. 네트워크 도청 가능. |
| H-3 | `ble_service.dart:677` | 하트비트 타이머 async 콜백 미완료 상태로 다음 틱 실행 → 다중 동시 해제. |
| H-4 | `database_service.dart:408-415` | 메시지 만료 삭제 트랜잭션 없음 → 동시 접근 시 null 참조. |
| H-5 | `home_screen.dart:99-100` | `mounted` 체크 후에도 조건 없이 `setState()` 호출. |
| H-6 | `user_level.dart:65-77` | `UserLevel.server` 쿨다운 `null` 반환 → 호출 측 런타임 오류 가능. |
| H-7 | `home_screen.dart:336-354` | 연락처 액션 핸들러 예외 처리 없음 → 실패 시 UI 불일치. |
| H-8 | `qr_screen.dart:269-290` | `confirmTrust()` 실패 여부 무관하게 성공 메시지 표시. |
| H-9 | `messaging_service.dart:167-170` | `init()` 중복 호출 시 이전 StreamSubscription 미취소. |
| H-10 | `ble_service.dart:214-218` | 스캔 재시작 시 이전 리스너 미해제. 이벤트 리스너 누적. |

---

### 🟡 MEDIUM — 개선 권장

| # | 파일 | 문제 |
|---|------|------|
| M-1 | `home_screen.dart:101-104` | 연속 메시지 수신 시 디바운스 없이 DB 쿼리 반복 (100ms 디바운스 권장). |
| M-2 | `database_service.dart:299-302` | `getAllContacts()` 페이지네이션 없음 → 대량 연락처 메모리 급증. |
| M-3 | `chat_screen.dart:187` | 공지 메시지 텍스트에 `[공지S]` 접두어 영구 저장 → 원본 텍스트 유실. |
| M-4 | `contact_service.dart:104-147` | `addOrUpdateContact()` 마다 전체 연락처 O(n) 순회. |
| M-5 | `home_screen.dart:365-366` | 그룹 즐겨찾기 토글이 멤버별 개별 실행 → 중간 실패 시 불일치. |
| M-6 | `messaging_service.dart:853-873` | 문자 수 제한만 확인, UTF-8 멀티바이트(이모지) 바이트 초과 미체크. |
| M-7 | `identity_service.dart:199-252` | QR 파싱 시 필드 유효성 검사 미흡. |
| M-8 | `messaging_service.dart:445-452` | 브로드캐스트 재시도 350ms 고정 → 지수 백오프 없음. |

---

### 🔵 LOW — 참고 / 배포 전 체크리스트

- [ ] `ble_constants.dart:24` — `manufacturer ID 0xFFFF` (개발 예약값) → Bluetooth SIG 값으로 교체 필요
- [ ] `ble_constants.dart:54` — MTU 512 하드코딩 → 플랫폼별 제한 처리 없음
- [ ] `home_screen.dart:1127` — 툴팁에 깨진 한글 "吏???덉젙" → 인코딩 오류 수정 필요
- [ ] `chat_screen.dart:170-171` — `unawaited()` 사용으로 실패 묵살
- [ ] `qr_screen.dart:308,315,322` — SnackBar 색상 하드코딩, Theme 미사용
- [ ] `identity_backup_service.dart:101-130` — 바이트 비교 비상수 시간 (타이밍 공격 위험 낮음)

---

### 📋 수정 우선순위

**즉시 (이번 Wave)**
1. `hopCount >= 255` 가드 추가 (C-2)
2. 모든 async 콜백 `mounted` 체크 (C-6)
3. `isMessageSeen()` / 서명 검증 순서 수정 (C-5)
4. `user_level.dart` `null` Duration 해결 (H-6)
5. 깨진 툴팁 텍스트 수정 (LOW)

**Wave 4 목표**
6. 개인키 암호화 저장 — `flutter_secure_storage` (C-1, 이미 알고 있음)
7. 브로드캐스트 메시지 E2E 암호화 (H-2)
8. DB 트랜잭션 적용 — 메시지 만료, 연락처 upsert (H-4)
9. 메시지 스트림 디바운스 100ms (M-1)
10. 연락처 액션 에러 핸들링 + 사용자 피드백 (H-7)

<!-- ================================================================ -->

<!-- ================================================================ -->
## 2026-06-05 — Working Tree Diff 리뷰 (/code-review, 7-angle × 병렬 에이전트)

> **리뷰 시점:** `git diff HEAD -- lib/` 기준 (v1.0.H → v1.0.K 작업 중 변경분)  
> **리뷰 방법:** Phase 1 — Finder 3개 병렬 (Angles A+B / C+Reuse / Simplification+Efficiency+Altitude), Phase 2 — Verifier 3개 병렬  
> **전체 평가:** 🟡 주의 — 설계 방향 올바름, 즉시 수정 필요 항목 5건 확인

### 주요 변경 범위 (이번 diff)

| 파일 | 주요 변경 |
|------|-----------|
| `ble_fragment_codec.dart` | 단편 충돌 감지 + reset 로직 추가 |
| `ble_service.dart` | 송신 retry 래퍼, `_heartbeatInProgress` 플래그, `broadcastPacket` 병렬화 |
| `database_service.dart` | `seen_messages` 10,000행 FIFO 상한 추가 |
| `contact_service.dart` | `ensureSelfContact()` 추가, `setSaved` 자기 노드 제외 |
| `messaging_service.dart` | hopCount 255 가드, 릴레이에 retry 적용, KEY_ANNOUNCE 타이머 responded-set clear |
| `app_settings.dart` | `MessageAlertMode` enum 추가 |
| `main.dart` | 시작 시 `deleteContact` → `ensureSelfContact` 교체 |
| `chat_screen.dart` | 서버 모드 early return + scroll mounted 체크 |

---

### 🔴 CONFIRMED — 즉시 수정

#### CR-1. KEY_ANNOUNCE 5분 주기 `.clear()` → O(N²) 패킷 폭풍
- **파일:** `messaging_service.dart:177`
- **문제:** `_keyAnnounceRespondedNodeIds.clear()`를 타이머마다 실행해 이미 응답한 노드를 전부 잊음. 다음 주기에 모든 노드의 KEY_ANNOUNCE에 다시 응답 → N노드 메시에서 N×(N-1) 패킷.
- **해결:** `clear()` 제거. 새 기기 감지 시 또는 앱 재시작 시만 제거 (`_keyAnnounceRespondedNodeIds.remove(nodeId)` on disconnect).

#### CR-2. `_lastSendFailureAt` 쿨다운이 새 패킷 첫 시도(attempt=0)에도 적용
- **파일:** `ble_service.dart:285`
- **문제:** 이전 패킷 실패로 저장된 타임스탬프가 다음 패킷의 첫 시도도 120ms 지연. 정상 전송이 불필요하게 throttle됨.
- **해결:** 쿨다운 체크를 `attempt > 0` 조건 안으로 이동, 또는 `_lastSendFailureAt` 체크를 재시도 간격 용도로만 사용.

#### CR-3. SCAN 맵 채팅 버튼 `myLevel.canSendMessages` 체크 누락
- **파일:** `home_screen.dart:2017`
- **문제:** scan 패널의 Chat 버튼이 `contact.userLevel.canSendMessages`만 확인. self가 서버 모드이면 버튼이 활성화되지만 누르면 SnackBar만 뜨는 불일치 UX.
- **해결:** `canOpenChatWithContact(_settings.userLevel, selectedNode.contact!)` 로 교체.

#### CR-4. `chat_screen.dart` 서버 모드 early return — `maybePop()` no-op 시 빈 화면 잔존
- **파일:** `chat_screen.dart:99`
- **문제:** `ChatScreen`이 루트 라우트이면 `maybePop()`이 아무것도 하지 않음. 위젯이 history/stream 없이 마운트 상태 유지. send 버튼은 활성 상태이나 잘못된 오류 메시지 표시.
- **해결:** `maybePop()` 후 반환값 체크, false이면 별도 fallback UI 또는 `Navigator.pushReplacement` 사용.

---

### 🟠 PLAUSIBLE — 높은 우선순위 수정 권장

#### CP-1. 자기 연락처 `is_saved=true` 저장 → Chats 탭 노출
- **파일:** `contact_service.dart:192`, `home_screen.dart`
- **문제:** `ensureSelfContact`가 `savedContact: true`로 DB 저장. 자기 메시지 전송 후 `getContactNodeIdsWithMessages`가 myNodeId 반환 → Chats 필터에 자기 노드 표시. 서버 모드 자기 노드는 클릭 불가 뱃지만 표시.
- **해결:** `ensureSelfContact`에서 `savedContact: false` (또는 `is_saved` 별도 컬럼 없이 별개 테이블 관리), 또는 모든 contactsStream 구독에서 `myNodeId` 필터링 추가.

#### CP-2. 릴레이에 `_broadcastPacketWithRetry` 적용 → dedup 창 내 중복 전달 가능
- **파일:** `messaging_service.dart:587`
- **문제:** 시도 0 실패 후 250ms 내 시도 1 성공 시, 이웃이 두 복사본을 `markMessageSeen` 완료 전에 수신하면 두 번 릴레이됨.
- **해결:** 릴레이는 fire-and-forget(`_ble.broadcastPacket` 직접 호출)으로 복구. retry는 발신 노드 책임.

#### CP-3. `_heartbeatInProgress` 틱 스킵으로 dead device 퇴출 지연
- **파일:** `ble_service.dart:706`
- **문제:** BLE 쓰기 지연이 `heartbeatInterval`보다 길면 후속 틱이 skip → `_heartbeatMissed` 미증가 → 죽은 기기 영구 미퇴출 가능.
- **해결:** 틱 스킵 시 `_heartbeatMissed` 증가는 유지하고, 실제 ping 전송만 스킵. 또는 `_heartbeatInProgress`를 per-device 플래그로 변경.

---

### 🟡 개선 권장

| # | 파일 | 문제 |
|---|------|------|
| I-1 | `ble_fragment_codec.dart:143` | `_bytesEqual` 4곳(ble_fragment_codec, contact_service, messaging_service, home_screen) 중복. 공용 유틸로 추출. |
| I-2 | `database_service.dart:584` | `NOT IN (SELECT msg_id ...)` — BLOB 키 anti-join은 full scan. `NOT IN (SELECT rowid ... LIMIT 10000)`로 교체하면 O(N log N). |
| I-3 | `contact_service.dart:311` | `cleanupStaleContacts`에서 `myNodeId` 명시적 제외 가드 없음. 현재는 `is_trusted=true`로 보호되나, 방어적 가드 추가 권장. |

---

### ✅ 이번 diff에서 올바르게 수정된 것

| 항목 | 결과 |
|------|------|
| `hopCount >= 255` 가드 추가 | ✅ 올바름 (무한 릴레이 루프 방지) |
| `broadcastPacket` `Future.wait` 병렬화 | ✅ 올바름 (`_sendPacketAttempt` 내부 예외 묵살로 안전) |
| `seen_messages` 10,000행 FIFO 상한 | ✅ 올바름 (R-09 충족) |
| 단편 충돌 감지 reset 로직 | ✅ REFUTED — 실제로는 올바르게 구현됨 (reset 후 triggering fragment 정상 저장) |
| `_heartbeatInProgress` 재진입 방지 | ✅ 재진입 방지 목적은 달성 (단, 틱 스킵 부작용 주의 — CP-3) |

---

### 📋 수정 우선순위

**즉시 (이번 빌드)**
1. `messaging_service.dart:177` — `_keyAnnounceRespondedNodeIds.clear()` 제거 (CR-1)
2. `ble_service.dart:285` — 쿨다운 체크를 재시도 전용으로 이동 (CR-2)
3. `home_screen.dart:2017` — scan chat 버튼 `canOpenChatWithContact` 전체 체크 (CR-3)
4. `chat_screen.dart:99` — `maybePop()` 반환값 처리 (CR-4)

**다음 Wave**
5. `contact_service.dart:192` — 자기 연락처 Chats 탭 노출 수정 (CP-1)
6. `messaging_service.dart:587` — 릴레이 retry 제거, fire-and-forget 복귀 (CP-2)
7. `ble_service.dart:706` — heartbeat 틱 스킵 시 missed 카운트 유지 (CP-3)
8. `_bytesEqual` 공용 유틸 추출 (I-1)
9. `database_service.dart:584` — rowid NOT IN 교체 (I-2)

<!-- ================================================================ -->

<!-- ================================================================ -->
## 2026-06-06 — Working Tree Diff 리뷰 (7-angle, medium effort)

> **리뷰 시점:** `git diff HEAD` 기준 — v1.0.L 현재 미커밋 변경분 (토폴로지 백엔드, 암호화 백업, 자기 연락처, 알림 채널, 릴레이 재시도 등)
> **리뷰 방법:** 7-angle finder 2개 병렬 + verifier 직접 파일 확인
> **전체 평가:** 🔴 주의 — 데이터 손상 버그 2건 + 프로토콜 폭풍 1건 포함

---

### 주요 변경 범위

| 파일 | 주요 변경 |
|------|-----------|
| `messaging_service.dart` | KEY_ANNOUNCE 5분 타이머에 `.clear()` 추가; 릴레이에 retry 적용; 토폴로지 request/response 핸들러 추가; 자기 텍스트 메시지 경로 |
| `ble_service.dart` | `_sendPacketNow` retry 루프 + `_lastSendFailureAt` 쿨다운; `startHeartbeat` 재진입 방지 플래그 |
| `contact_service.dart` | `ensureSelfContact` 추가; `cleanupStaleContacts` — `Uint8List(16)` + 미범위 삭제 |
| `identity_backup_service.dart` | PBKDF2+AES-GCM 암호화 백업 (신규) |
| `chat_screen.dart` | Server 모드 early return + `maybePop()` |
| `database_service.dart` | `getMessages`/`deleteMessagesForContact` 에 `myNodeId` 범위 추가 |
| `topology_message.dart` | 신규 — TopologyRequest/Response 직렬화 |

---

### 🔴 CONFIRMED — 즉시 수정 필요

#### WD-1. `contact_service.dart:291` — `deleteContact`에서 미범위 메시지 삭제
- **코드:** `await _db.deleteMessagesForContact(nodeId);` (myNodeId 미전달)
- **문제:** `deleteMessagesForContact`의 `myNodeId=null` 경로는 `WHERE sender_id = ? OR target_id = ?` — 해당 nodeId가 sender/target으로 등장하는 **모든** 메시지를 삭제. 나와 다른 상대 간에 릴레이된 메시지도 함께 삭제됨.
- **재현:** 연락처 A를 삭제 → A가 relayed-sender로 저장된 다른 대화의 메시지도 함께 사라짐.
- **수정:** `await _db.deleteMessagesForContact(nodeId, myNodeId: IdentityService().myNodeId);`

#### WD-2. `contact_service.dart:301,319` — `cleanupStaleContacts`에서 2개 버그
**버그 A — `Uint8List(16)` 제로 ID:**
- **코드:** `_db.getContactNodeIdsWithMessages(Uint8List(16))`
- **문제:** myNodeId로 16바이트 0을 전달 → 실제 내 노드 ID가 제외되지 않아 자기 자신이 "메시지 있음" 목록에 포함될 수 있음. stale cleanup이 잘못된 연락처를 보호하거나 삭제함.
- **수정:** `Uint8List(16)` → `IdentityService().myNodeId`

**버그 B — 미범위 삭제:**
- **코드:** `await _db.deleteMessagesForContact(contact.nodeId);` (myNodeId 미전달)
- **문제:** WD-1과 동일한 미범위 삭제가 자동 cleanup 시에도 발생.
- **수정:** myNodeId 전달 추가.

#### WD-3. `messaging_service.dart:185` — KEY_ANNOUNCE 5분 타이머에 `.clear()` 추가 → 패킷 폭풍
- **코드:** `_keyAnnounceRespondedNodeIds.clear(); await broadcastKeyAnnounce();`
- **문제:** 매 5분마다 응답한 노드 목록을 초기화 → 이미 KEY_ANNOUNCE에 응답한 N개 이웃이 전부 다시 응답 → N×(N-1) 패킷 발생. 이전 리뷰(2026-06-05 CR-1)에서 경고했으나 이번 diff에서 새로 추가됨.
- **수정:** `.clear()` 제거. 연결 해제 시 `_keyAnnounceRespondedNodeIds.remove(nodeId)` 로만 관리.

#### WD-4. `messaging_service.dart:794` — `TopologyRequest.fromPayload` 예외 미처리 → 릴레이 영구 차단
- **코드:** `final request = TopologyRequest.fromPayload(packet.payload);` — try/catch 없음
- **문제:** 잘못된 페이로드(버전 불일치, JSON 파싱 오류)로 `FormatException` throw → `_handleIncomingPacket` 상위에도 try/catch 없음 → 예외 전파. 해당 packet의 `markMessageSeen`은 이미 완료됐으므로(line 591) 이 패킷은 향후 수신되어도 중복으로 판정되어 릴레이 영구 차단.
- **수정:** `_handleTopologyRequestPacket` 내부에 try/catch 추가.

---

### 🟠 PLAUSIBLE — 높은 우선순위 수정 권장

#### WP-1. `ble_service.dart:483` — `_lastSendFailureAt` 쿨다운이 attempt=0에도 적용
- **코드:** 루프 최상단에서 쿨다운 체크 → attempt=0일 때도 120ms 지연
- **문제:** 이전 패킷 실패로 기록된 타임스탬프가 다음 패킷의 첫 시도도 throttle. 이전 리뷰(2026-06-05 CR-2) 지적과 동일하나 현재 코드에도 잔존.
- **수정:** 쿨다운 체크를 `if (attempt > 0)` 안으로 이동.

#### WP-2. `messaging_service.dart:631` — 릴레이에 `_broadcastPacketWithRetry` (최대 1.5초 차단)
- **코드:** relay 경로에서 3회 retry × 250ms/500ms/750ms 지연
- **문제:** BLE 이웃이 없을 때 수신 콜백이 최대 1.5초 차단 → 해당 기기로부터 도착하는 후속 패킷들이 GATT 버퍼 오버플로 또는 타임아웃으로 손실될 수 있음. 릴레이는 fire-and-forget이 적합.
- **수정:** 릴레이는 `_ble.broadcastPacket(packet, excludeDeviceId: fromDeviceId)` 직접 호출로 복귀. retry는 발신 노드 책임.

#### WP-3. `chat_screen.dart:99` — `maybePop()` 반환값 미확인 → 빈 화면 잔존
- **코드:** `Navigator.of(context).maybePop();` — 반환값 무시
- **문제:** ChatScreen이 루트 라우트이면 `maybePop()`이 false 반환 (아무것도 안 함). 위젯이 SnackBar만 보여주고 마운트 상태 유지. `_loadHistory`/`_subscribeToStream` 미호출이라 빈 화면.
- **수정:** 반환값 체크 또는 `Navigator.pushReplacement(HomeScreen)` 사용.

---

### 🟡 개선 권장

| # | 파일 | 문제 |
|---|------|------|
| I-1 | 6개 파일 | `_bytesEqual` 6곳 중복 (`ble_fragment_codec`, `database_service`, `contact_service`, `identity_backup_service`, `messaging_service`, `home_screen`) — 공용 유틸로 추출 |
| I-2 | `messaging_service.dart:793` | `_handleTopologyRequestPacket`에 자기 요청 응답 방지 가드 없음 (`if (_bytesEqual(packet.senderId, _identity.myNodeId)) return;`) |

---

### ✅ 이번 diff에서 올바르게 구현된 것

| 항목 | 결과 |
|------|------|
| 암호화 백업 (PBKDF2-HMAC-SHA256 + AES-GCM, 210,000 iterations) | ✅ 올바름 |
| `_handleTopologyResponsePacket` targetId 필터 | ✅ 올바름 |
| `_heartbeatInProgress` 재진입 방지 | ✅ 목적 달성 (단, CP-3 틱 스킵 부작용 주의) |
| `hopCount >= 255` 가드 | ✅ 올바름 (이전 리뷰 C-2 수정 확인) |
| `seen_messages` 10,000행 FIFO 상한 | ✅ 올바름 |
| `isMessageSeen` 후 서명 검증 순서 | ✅ 올바름 (C-5 수정 확인) |
| `canOpenChatWithContact` 헬퍼 도입 | ✅ 올바름 |
| 메시지 쌍 범위 지정 (`myNodeId`) — `getMessages` 호출 측 | ✅ 올바름 |

---

### 📋 수정 우선순위

**즉시 (이번 빌드)**
1. `contact_service.dart:291` — `deleteContact`에 `myNodeId` 전달 (WD-1)
2. `contact_service.dart:301` — `Uint8List(16)` → `IdentityService().myNodeId` (WD-2A)
3. `contact_service.dart:319` — `cleanupStaleContacts`에 `myNodeId` 전달 (WD-2B)
4. `messaging_service.dart:185` — `_keyAnnounceRespondedNodeIds.clear()` 제거 (WD-3)
5. `messaging_service.dart:794` — `_handleTopologyRequestPacket` try/catch 추가 (WD-4)

**다음 빌드**
6. `ble_service.dart:483` — 쿨다운 체크를 `attempt > 0`으로 이동 (WP-1)
7. `messaging_service.dart:631` — 릴레이를 fire-and-forget으로 복귀 (WP-2)
8. `chat_screen.dart:99` — `maybePop()` 반환값 처리 (WP-3)
9. `_bytesEqual` 공용 유틸 추출 (I-1)

<!-- ================================================================ -->

<!-- ================================================================ -->
## 2026-06-06 — 신규 토폴로지/시뮬레이터 코드 추가 리뷰

> **리뷰 시점:** 직전 리뷰(2026-06-06 Working Tree) 이후 추가된 미커밋 파일 3개 신규 분석
> **신규 파일:** `topology_graph.dart`, `topology_demo.dart`, `virtual_mesh_simulator.dart`
> **기존 WD-1~WD-4 버그:** 여전히 미수정 — 수정 우선순위 유지
> **전체 평가:** 🟢 신규 코드 양호 (14개 테스트 통과, 알고리즘 정확)

---

### 신규 추가 파일 요약

| 파일 | 역할 |
|------|------|
| `topology_graph.dart` | BFS로 토폴로지 응답을 그래프(노드/엣지)로 변환. depth 제한, maxNodes 상한, 엣지 중복 제거 포함 |
| `topology_demo.dart` | 27노드 시나리오 하드코딩 — BLE/Wi-Fi/LAN 혼합 메시 데모용 |
| `virtual_mesh_simulator.dart` | 가상 메시에서 메시지 라우팅 시뮬레이션 — BFS, 홉 제한, 공지 쿨다운 정책 반영 |
| `topology_message.dart` (수정) | `TopologyNodeSummary`에 `transportKind` 필드 추가 (기본값 bluetooth) |
| `app_settings.dart` (수정) | `demoMode` bool 설정 추가 — 기본값 false, `demo_mode` 키로 persist |

---

### ✅ 신규 코드에서 올바르게 구현된 것

| 항목 | 확인 결과 |
|------|-----------|
| BFS depth 제한 (`depth == -1` → 무제한) | ✅ 올바름 |
| 엣지 키 정규화 (알파벳 순 정렬 `A:B`) — 양방향 중복 제거 | ✅ 올바름 |
| `summariesById[id]!` null 안전성 (BFS에서 adj에 있는 노드는 모두 addNode됨) | ✅ 올바름 |
| `VirtualMeshSendResult.sent()` — 수신자 없으면 `accepted: false` | ✅ 의도된 동작 |
| Server 노드 메시지 차단 (`canShowMessages: false`) | ✅ 시뮬레이터와 실제 코드 일관 |
| 공지 쿨다운 (`Builder` 1시간, 시뮬레이터 반영) | ✅ 올바름 |
| `mathMax` — 테스트 헬퍼 함수로 정의됨 (line 369) | ✅ 컴파일 가능 |

---

### 🟡 신규 코드 — 낮은 우선순위 개선 사항

#### NG-1. `topology_demo.dart:118` — `depth3()` 팩토리가 `large()`와 동일
- `DemoTopologyScenario.depth3()` → `DemoTopologyScenario.large()` 그대로 위임
- 이름이 다른 시나리오임을 암시하지만 동일한 데이터 반환. 혼동 유발 가능.
- **수정:** `depth3()` 제거 후 호출 측에서 `large()` 직접 사용, 또는 별개 시나리오로 구현.

#### NG-2. `home_screen.dart` — 데모 모드 스캔이 `scanDepthController.text = '5'` 강제 설정
- 데모 실행 시 depth 컨트롤러를 '5'로 변경하지만 `AppSettings`는 업데이트하지 않음.
- 데모 해제 후 실제 스캔 시 컨트롤러에 '5'가 남아있어 의도치 않게 깊은 스캔 실행 가능.
- **수정:** 데모 종료 시 `_scanDepthController.text`를 `_settings.scanDefaultDepth.toString()`으로 복원.

---

### ⚠️ 직전 리뷰 미수정 항목 (우선 수정 필요)

아래 5건은 이전 리뷰(2026-06-06 Working Tree)에서 발견된 버그로 **현재도 미수정** 상태:

| 항목 | 파일 | 심각도 |
|------|------|--------|
| WD-1: `deleteContact` 미범위 메시지 삭제 | `contact_service.dart:291` | 🔴 데이터 손상 |
| WD-2A: `Uint8List(16)` 제로 ID | `contact_service.dart:301` | 🔴 데이터 손상 |
| WD-2B: `cleanupStaleContacts` 미범위 삭제 | `contact_service.dart:319` | 🔴 데이터 손상 |
| WD-3: KEY_ANNOUNCE `.clear()` 패킷 폭풍 | `messaging_service.dart:185` | 🔴 네트워크 폭풍 |
| WD-4: `TopologyRequest.fromPayload` 예외 미처리 | `messaging_service.dart:794` | 🟠 릴레이 차단 |

<!-- ================================================================ -->

<!-- ================================================================ -->
## 2026-06-06 — 4-에이전트 전체 코드베이스 병렬 리뷰

> **리뷰 시점:** v1.0.L / 20260606-034232 — 19개 테스트 통과, 실기기 검증 완료 후  
> **리뷰 방법:** 4개 독립 에이전트 병렬 분석 (보안/암호화 · BLE/메시징 · 데이터/정책 · UI/구조)  
> **전체 평가:** 🟠 주의 — Critical 12건 포함, 프로덕션 배포 전 수정 필수

### 결과 요약

| 에이전트 | Critical | High | Medium | Low |
|---------|----------|------|--------|-----|
| 보안/암호화 | 3 | 5 | 5 | 3 |
| BLE/메시징 | 3 | 5 | 6 | 4 |
| 데이터/정책 | 2 | 3 | 3 | 2 |
| UI/구조 | 4 | 6 | 7 | 3 |
| **합계** | **12** | **19** | **21** | **12** |

---

### 🔴 CRITICAL — 즉시 수정 필요

#### [보안] SC-1. 개인키 평문 SQLite 저장 (반복 지적)
- **파일:** `identity_service.dart:66-73`
- **문제:** Ed25519/X25519 개인키 seed가 DB에 암호화 없이 저장. "Phase 2 개선" TODO 존재하나 프로덕션 전 필수.
- **위험:** 기기 탈취 → ADB/루팅으로 DB 추출 → 모든 통신 복호화 및 노드 위장
- **해결:** Android Keystore / iOS Keychain 연동 (`flutter_secure_storage`)

#### [보안] SC-2. PBKDF2 반복 횟수 부족
- **파일:** `identity_backup_service.dart:21` (`_kdfIterations = 210000`)
- **문제:** NIST 2024 기준 최소 600,000회 권장. 현재 210,000회는 GPU 브루트포스에 취약.
- **해결:** `_kdfIterations = 600000` 이상으로 변경

#### [보안] SC-3. AES-GCM 논스 재사용 위험 (장기 운영 시)
- **파일:** `crypto_service.dart:140-158`
- **문제:** 동일 X25519 공유 비밀에 12바이트 랜덤 논스 → 생일 역설으로 2^48 메시지 후 충돌 가능
- **해결:** HKDF로 메시지마다 고유 키 파생 또는 X25519 임시 키쌍 주기적 교체

#### [보안] SC-4. ECDH 공유 비밀에 KDF 미적용
- **파일:** `crypto_service.dart:113-132`
- **문제:** X25519 Raw 출력을 직접 AES-GCM 키로 사용. RFC 7748 및 NIST 지침 위반.
- **해결:** HKDF-SHA256 적용 후 파생 키 사용

#### [데이터] SC-5. `setUserLevel()` 인증 체크 없음 (권한 탈취)
- **파일:** `contact_service.dart:390-392`
- **문제:** 호출자 레벨 검증 없음. `UserLevel.canChangeContactLevel()`이 정의됐으나 미호출.
- **위험:** 일반 User가 코드 직접 호출 시 Creator 레벨 부여 가능
- **해결:** 진입부에 `AppSettingsService().current.userLevel.canChangeContactLevel(level)` 추가

#### [데이터] SC-6. JSON 임포트로 권한 탈취
- **파일:** `contact_file_service.dart:70-72`
- **문제:** 임포트 JSON의 `userLevel` 필드를 검증 없이 DB 저장. 조작된 파일로 임의 연락처에 Creator 부여.
- **해결:** 임포트 시 `user`/`server`만 허용; 그 외는 `user`로 강제 지정

#### [BLE] SC-7. 프래그먼트 재조립 결함 (데이터 손상)
- **파일:** `ble_fragment_codec.dart:116`
- **문제:** 완성 여부를 `map.length == count`로만 판별. 인덱스 {0,2,3}처럼 중간 조각 누락해도 통과 → 손상 패킷 반환
- **해결:** 인덱스 0~count-1 모두 존재하는지 명시적 검증

#### [BLE] SC-8. 무제한 텍스트 페이로드 DoS
- **파일:** `messaging_service.dart:1123-1162`
- **문제:** `_decodeTextPayload()`에 길이 제한 없음. 악성 노드가 수 MB 페이로드 전송 시 메모리/CPU 소진
- **해결:** 디코딩 전 최대 크기(예: 64KB) 검증 후 드롭

#### [BLE] SC-9. Timer async 패턴 오류 (하트비트)
- **파일:** `ble_service.dart:706-707`
- **문제:** `Timer.periodic` 콜백에서 async 함수를 await 없이 호출 → 완료 안 된 Future 누적, 하트비트 실패 및 메모리 릭
- **해결:** `while` + `await` 패턴으로 재설계

#### [UI] SC-10. dispose 후 setState (스캔 타이머)
- **파일:** `home_screen.dart:335-337`
- **문제:** `Future.delayed` 콜백이 10초 후 실행 시 위젯이 이미 dispose됐을 수 있음
- **해결:** dispose 시 타이머 취소 또는 `_isScanning` 플래그로 콜백 무효화

#### [UI] SC-11. PostFrame 콜백 취소 불가 (크래시 위험)
- **파일:** `chat_screen.dart:88-104`
- **문제:** `addPostFrameCallback`은 취소 불가. 위젯 dispose 후 콜백 실행 시 크래시
- **해결:** 콜백 내 `if (!mounted) return` 가드 강화

#### [UI] SC-12. QR 스캔 — 검증 전 `_scanned = true` 설정
- **파일:** `qr_screen.dart:243-266`
- **문제:** 검증 실패해도 `_scanned = true`가 유지되어 스캐너 잠김
- **해결:** 검증 성공 후에 `_scanned = true` 설정

---

### 🟠 HIGH — 빠른 수정 권장 (19건)

#### [보안] SH-1. ECDH 공유 비밀 KDF 미적용
- **파일:** `crypto_service.dart:113-132`
- **문제:** X25519 Raw 출력을 직접 AES-GCM 키로 사용. RFC 7748 및 NIST 지침 위반.
- **해결:** `Hkdf(macAlgorithm: Hmac.sha256())`로 파생 키 생성 후 사용

#### [보안] SH-2. 솔트 길이 16바이트 — 32바이트 권장
- **파일:** `identity_backup_service.dart:230-235`
- **문제:** PBKDF2 솔트가 16바이트(128비트). 키 크기(256비트)와 불일치, 현대 위협 모델에 부족.
- **해결:** `_randomBytes(32)`로 변경

#### [보안] SH-3. 릴레이 노드의 unsigned 필드 변조 가능 (문서화 부족)
- **파일:** `mesh_packet.dart:285-289` 및 `messaging_service.dart:667-670`
- **문제:** `toSignableBytes()`가 TTL/hopCount를 제외하는 설계는 올바르나, 이 외 필드(timestamp 등)가 서명 범위임을 문서화하지 않음. 릴레이 노드가 timestamp를 조작해도 검출 어려움.
- **해결:** `toSignableBytes()` 주석에 "mutable: ttl, hopCount only" 명시; 향후 릴레이 서명 체인 고려

#### [보안] SH-4. 서명 검증 선행 의존 — 컴파일 타임 강제 불가
- **파일:** `identity_service.dart:328-330`
- **문제:** `parseKeyAnnouncePacket()` 주석에 "호출자가 먼저 검증해야 함"이라고 명시했으나 런타임 체크 없음. 호출자 누락 시 미검증 패킷 처리.
- **해결:** 메서드를 `parseAndVerifyKeyAnnouncePacket()`으로 통합하거나 진입부에 assertion 추가

#### [보안] SH-5. 고정 probe 문자열로 키쌍 검증
- **파일:** `identity_backup_service.dart:147-160`
- **문제:** 복원 시 `'mesh_comm_identity_probe'` 고정 문자열로 서명 검증. 관찰된 (probe, signature) 쌍 재사용 가능.
- **해결:** `final nonce = Random.secure().nextInt(0xffffffff); final probe = utf8.encode('probe|$nonce');`

#### [BLE] SH-6. 스캔 타이머 무한 재귀 등록
- **파일:** `ble_service.dart:235-239`
- **문제:** 스캔 타임아웃 후 `startScan()`이 내부에서 다시 `startScan()`을 예약 → 타이머가 해제되지 않고 누적
- **해결:** `Timer.periodic` 단일 인스턴스로 교체 또는 재귀 호출 전 기존 타이머 명시 취소

#### [BLE] SH-7. 송신 큐 정리 레이스 조건
- **파일:** `ble_service.dart:268-279`
- **문제:** `sendPacket()`에서 `identical()` 비교 실패 시 이전 Future 참조가 `_sendQueues`에 영구 잔존 → 큐 메모리 릭
- **해결:** 고유 ID 기반 큐 관리 또는 `_sendQueues[deviceId] = null` 명시적 해제

#### [BLE] SH-8. notify 스트림 재연결 시 중복 구독
- **파일:** `ble_service.dart:513-519`
- **문제:** `messageChar.lastValueStream.listen()`의 `onError` 콜백은 있으나, 재연결 레이스 시 이전 구독이 `_notificationSubscriptions`에 남아 중복 리스너 등록 가능
- **해결:** `_onDeviceDisconnected()`에서 구독 취소 순서 보장; 재연결 전 기존 구독 완전 정리

#### [BLE] SH-9. `_cleanExpired()` 동시성 보호 없음
- **파일:** `ble_fragment_codec.dart:134-141`
- **문제:** `add()` 호출마다 `_cleanExpired()`가 실행되는데 동기화 없음. 복수 스레드에서 동시 호출 시 `removeWhere()` 중 이터레이터 오염 또는 조각 손실 가능.
- **해결:** 단일 스레드 가정을 주석으로 문서화하거나 Mutex 추가

#### [BLE] SH-10. hopCount 255 초과 패킷이 드롭 전 핸들러 실행
- **파일:** `messaging_service.dart:596-683`
- **문제:** TTL/hop 초과 체크가 타입별 핸들러 실행 후에 위치. hopCount=255 패킷도 TEXT/TOPOLOGY 핸들러를 거친 뒤 드롭됨 → 불필요한 DB 쓰기 등 사이드 이펙트 발생.
- **해결:** hop 검증을 파이프라인 최상단(서명 검증 이전 또는 직후)으로 이동

#### [BLE] SH-11. 중복 검사가 서명 검증보다 선행
- **파일:** `messaging_service.dart:606-609`
- **문제:** `isMessageSeen()` 호출 후 서명 검증. 위조 패킷이 동일 msg_id로 전송되면 정상 패킷이 "이미 처리됨"으로 차단 가능 (DoS 벡터)
- **해결:** 서명 검증 성공 후에 `markMessageSeen()` 호출

#### [데이터] SH-12. 공지 쿨다운 AppSettings 타임스탬프 의존 — 우회 가능
- **파일:** `message_policy.dart`, `messaging_service.dart:348-360`
- **문제:** 쿨다운 시행이 `AppSettings.lastShortNoticeAt` 타임스탬프에만 의존. DB 직접 조작으로 타임스탬프를 0으로 설정 시 모든 쿨다운 우회 가능.
- **해결:** 서버 측 검증(릴레이 노드가 타임스탬프 검증) 또는 쿨다운 정책 버전 함께 저장

#### [데이터] SH-13. Settings 로드 시 userLevel 검증 없음
- **파일:** `app_settings_service.dart:19-24`
- **문제:** `AppSettings.fromMap()`에서 로드된 `userLevel` 검증 없음. SQLite 직접 조작으로 `user_level = 'creator'` 설정 시 앱 시작부터 Creator 권한 획득.
- **해결:** 로드 후 초기 레벨 이하인지 검증; Windows는 Creator 강제이므로 Android에만 적용

#### [데이터] SH-14. 공개키 변경 시 신뢰 플래그 재평가 불완전
- **파일:** `contact_service.dart:249-287`
- **문제:** `checkPublicKeyChange()`에서 `trusted: false`로 재설정하지만, 이후 `addOrUpdateContact()` 호출 시 기존 `is_trusted` 값을 재사용. 키 변경 후 재연결 시 신뢰 플래그가 복원될 수 있음.
- **해결:** `addOrUpdateContact()` 내부에서 공개키 불일치 시 `trusted = false` 강제

#### [UI] SH-15. 연락처 스트림 급속 갱신 시 `setState` 레이스
- **파일:** `home_screen.dart:147-149`
- **문제:** `initState()`의 연락처 구독에서 `if (mounted) setState(...)` 가드가 있으나, dispose 진행 중 스트림이 빠르게 여러 이벤트를 방출하면 가드 통과 후 dispose 완료될 수 있음
- **해결:** `addPostFrameCallback` 사용 또는 dispose 시 구독 즉시 취소 순서 보장

#### [UI] SH-16. 노드ID 바이트 비교 인라인 구현 — 비효율 및 버그 유발
- **파일:** `chat_screen.dart:150-176`
- **문제:** `.where()` 안에서 `List.generate(...).every(...)` 패턴으로 바이트 비교. 가독성 저하, 실수 유발 가능, `listEquals` 대비 비효율.
- **해결:** `_bytesEqual(a, b)` 공용 유틸 사용; nodeId 비교는 hex 문자열 비교로 통일 권장

#### [UI] SH-17. BLE 토글 실패 시 UI 상태 불일치
- **파일:** `home_screen.dart:277-288`
- **문제:** `_toggleBluetooth()`에서 `startScan()`/`stopScan()` 예외 미처리. 실패해도 `_bluetoothEnabled` 상태가 변경되어 UI와 실제 BLE 상태 불일치.
- **해결:** try-catch로 감싸고 실패 시 `_bluetoothEnabled` 원복

#### [UI] SH-18. async 연산 후 `Navigator.push` 전 mounted 체크 누락
- **파일:** `home_screen.dart:386-406`
- **문제:** `markMessagesReadForContact()` → `_loadUnreadCounts()` → `Navigator.push()` 체인에서 마지막 push 직전 mounted 체크 없음. 중간 await 중 dispose 시 크래시.
- **해결:** `Navigator.push()` 직전 `if (!mounted) return;` 추가

#### [UI] SH-19. 이미지 로드 에러 묵살
- **파일:** `avatar_registry.dart:129-145`
- **문제:** `errorBuilder`가 폴백 CircleAvatar를 반환하지만 에러를 로깅하지 않음. 아바타 에셋 누락 시 사용자/개발자 모두 인지 불가.
- **해결:** 디버그 빌드에서 `debugPrint('[Avatar] load error: $error')` 추가

---

### 🟡 MEDIUM — 계획적 개선 (21건)

#### [보안] SM-1. `catch (_) { rethrow }` 에러 로깅 없음
- **파일:** `crypto_service.dart:78-85` (및 42-44, 129-131)
- **문제:** 여러 함수에서 `catch (_) { rethrow }` 패턴 사용. 예외 종류·원인 추적 불가, 디버깅 어려움.
- **해결:** `debugPrint('[CryptoService] error: $e'); rethrow;`로 교체

#### [보안] SM-2. 백업 버전·반복횟수 정확 일치 요구 — 하위 호환 불가
- **파일:** `identity_backup_service.dart:81-90`
- **문제:** 버전·KDF·반복횟수가 정확히 일치해야만 복원 가능. 보안 기준 업그레이드 후 생성된 새 백업을 이전 앱이 복원 불가.
- **해결:** 버전은 `>=` 허용, 반복횟수는 `>=` 허용 (더 강한 설정 수용)

#### [보안] SM-3. 암호화 키 크기 검증 없음
- **파일:** `messaging_service.dart:264-267`, `389-392`, `725-728`
- **문제:** `computeSharedSecret()` 반환값을 크기 검증 없이 `encrypt()`에 전달. X25519 구현이 32바이트를 보장하지만 방어적 코딩 부재.
- **해결:** `encrypt()`/`decrypt()` 진입부에 `assert(sharedSecret.length == 32)` 추가

#### [보안] SM-4. 패킷 파싱 시 타임스탬프 합리성 검증 없음
- **파일:** `mesh_packet.dart:214-254`
- **문제:** `fromBytes()`에서 타임스탬프 범위 검증 없음. 미래 or 매우 과거 타임스탬프를 가진 패킷도 수락.
- **해결:** 메시징 레이어에서 `|now - packet.timestamp| > 300s` 이면 드롭

#### [보안] SM-5. PBKDF2 API의 `nonce:` 파라미터에 솔트 전달 — 의미 혼동
- **파일:** `identity_backup_service.dart:178-181`
- **문제:** `pbkdf2.deriveKey(nonce: salt)` — 파라미터명이 `nonce`이지만 실제로는 솔트. 코드 가독성 저하, 향후 API 변경 시 혼동 위험.
- **해결:** 주석 `// cryptography 패키지에서 PBKDF2 솔트를 nonce로 표기함` 추가

#### [BLE] SM-6. 스캔 타이머 재할당 전 이전 타이머 취소 누락
- **파일:** `ble_service.dart:230-239`
- **문제:** `_scanTimer = Timer(...)` 재할당 전 `_scanTimer?.cancel()` 없음. `startScan()` 빠르게 연속 호출 시 고아 타이머 누적.
- **해결:** 할당 직전 `_scanTimer?.cancel();` 추가

#### [BLE] SM-7. `License.nonprofit` 하드코딩
- **파일:** `ble_service.dart:472`
- **문제:** `device.connect(license: License.nonprofit)` 상용 배포 시 부적절. 설정 파일이나 빌드 플래그로 분리 필요.
- **해결:** `BleConstants`에 라이선스 상수 추가 또는 빌드 플래버별 설정

#### [BLE] SM-8. 빈 페이로드 프래그먼트 허용
- **파일:** `ble_fragment_codec.dart:59-76`
- **문제:** `parse()`가 빈 payload를 가진 프래그먼트를 수락. 재조립 시 빈 청크 연결로 패킷 손상.
- **해결:** `payload.isEmpty && totalCount > 1` 이면 파싱 거부

#### [BLE] SM-9. TTL 등록을 읽기 전용 함수 내에서 수행
- **파일:** `messaging_service.dart:1058-1062`
- **문제:** `getMessageHistory()`(읽기 의도) 내부에서 `setMessageExpiresAtIfNull()` 쓰기 수행. 다중 소비자 동시 호출 시 레이스 가능.
- **해결:** TTL 등록을 메시지 수신 핸들러로 이동; 읽기 함수는 순수 읽기로 유지

#### [BLE] SM-10. BFS 사이클 처리 문서화 부족
- **파일:** `topology_graph.dart:99`
- **문제:** visited 집합으로 사이클을 방지하고 있으나 코드 주석 없음. maxNodes=80 도달 시 그래프가 절단됨도 명시 안 됨.
- **해결:** `// 사이클 방지: visited 집합; maxNodes 초과 시 BFS 중단` 주석 추가

#### [BLE] SM-11. BFS TTL 체크 시작 시점 최적화
- **파일:** `virtual_mesh_simulator.dart:345-354`
- **문제:** `_shortestRoute()`에서 ttl=0이면 BFS가 이웃 탐색 후 조건 실패로 종료. 시작 시점에 `if (ttl < 1) return null;` 조기 탈출이 없음.
- **해결:** BFS 루프 진입 전 `if (ttl < 1) return null;` 추가

#### [데이터] SM-12. `upsertContact` GET→INSERT 레이스 조건
- **파일:** `database_service.dart:245-270`
- **문제:** `getContact(nodeId)` 후 `INSERT` 사이 다른 코드가 동일 연락처를 수정하면 `first_seen` 손실 등 데이터 불일치 발생.
- **해결:** `first_seen`만 별도 서브쿼리로 인라인 조회: `COALESCE((SELECT first_seen FROM contacts WHERE node_id=?), ?)`

#### [데이터] SM-13. 키 변경 시 `userLevel` 명시 보존 누락
- **파일:** `contact_service.dart:249-287`
- **문제:** `checkPublicKeyChange()` 내 `upsertContact()` 호출에서 `userLevel` 파라미터 미전달. 기본값 `'user'`로 리셋될 수 있음.
- **해결:** `userLevel: row['user_level'] as String? ?? 'user'` 명시 전달

#### [데이터] SM-14. `scanDefaultDepth` 상한선 없음
- **파일:** `app_settings.dart:83`
- **문제:** 음수만 체크하고 상한 없음. `depth=999999` 입력 시 토폴로지 BFS가 maxNodes 한계까지 폭주.
- **해결:** `depth < 0 || depth > 20 ? 3 : depth` 또는 `BleConstants.maxScanDepth` 상수로 관리

#### [UI] SM-15. 툴팁 한글 인코딩 깨짐
- **파일:** `home_screen.dart:1906`
- **문제:** `'$label 吏???덉젙'` — 한글 소스 파일 인코딩 오류. 툴팁이 의미 없는 문자 표시.
- **해결:** 해당 문자열을 올바른 한글로 수정

#### [UI] SM-16. 이름·그룹 입력 빈 문자열 검증 없음
- **파일:** `home_screen.dart:461-466`
- **문제:** `_askForText()`가 빈 문자열을 반환해도 DB에 저장. 연락처 이름이 빈 문자열이 되면 목록에서 구분 불가.
- **해결:** `if (result.trim().isEmpty) return;` 가드 추가

#### [UI] SM-17. QR 스캔에서 `_scanned = true` 설정 순서 오류
- **파일:** `qr_screen.dart:243-266`
- **문제:** 검증 전에 `_scanned = true` 설정. 검증 실패 후 `_resetScanner()`를 호출해도 race 조건에서 스캐너 잠금 상태 유지 가능.
- **해결:** 검증 성공 확인 후 `_scanned = true` 설정

#### [UI] SM-18. 빠른 메시지 수신 시 `_loadHistory` 중복 호출로 목록 불일치
- **파일:** `chat_screen.dart:127-148`
- **문제:** `replace=true`로 전체 재로드 방식. 여러 메시지가 빠르게 수신되면 목록이 깜빡이거나 순서 불일치 가능.
- **해결:** 신규 메시지만 append하는 방식으로 변경 또는 디바운스(100ms) 적용

#### [UI] SM-19. 설정 다이얼로그 토글 즉시 저장 — 디바운스 없음
- **파일:** `home_screen.dart:545-567`
- **문제:** 다크모드·데모모드 토글 시 즉시 저장. 사용자가 빠르게 토글하면 불필요한 DB 쓰기 다수 발생.
- **해결:** "저장" 버튼 도입 또는 300ms 디바운스

#### [UI] SM-20. QR 초기화 실패 시 무한 로딩
- **파일:** `qr_screen.dart:87-91`
- **문제:** `identity.isInitialized` 체크 후 false이면 `CircularProgressIndicator` 표시. 초기화가 영구 실패해도 에러 UI 없이 로딩 지속.
- **해결:** 타임아웃(예: 10초) 후 에러 상태 표시

#### [데이터] SM-21. 중복 DELETE 쿼리 — `NOT IN` 비효율
- **파일:** `database_service.dart:640-648`
- **문제:** TTL 삭제 후 상위 10,000건 유지를 위한 두 번째 `NOT IN (SELECT ... LIMIT 10000)`가 BLOB 키 anti-join으로 full scan. 테이블이 크면 성능 저하.
- **해결:** `NOT IN (SELECT rowid FROM seen_messages ORDER BY seen_at DESC LIMIT 10000)` — rowid 기반으로 교체

---

### 🟢 LOW — 참고 (12건)

| # | 영역 | 파일 | 설명 | 해결 |
|---|------|------|------|------|
| SL-1 | 보안 | `crypto_service.dart:42-44` | `catch (_) { rethrow }` 3곳 — 에러 로깅 없어 디버깅 어려움 | `debugPrint` 추가 |
| SL-2 | 보안 | `identity_service.dart:387-393` | `_fromHex()` 유효 hex 문자 사전 검증 없음 — 비hex 문자 입력 시 불명확한 예외 | `RegExp(r'^[0-9a-fA-F]*$')` 검증 추가 |
| SL-3 | 보안 | `mesh_packet.dart:277-283` | `isBroadcast` O(16) 루프 — 반복 호출 시 비효율 | `targetId.every((b) => b == 0xFF)` 또는 생성자에서 캐시 |
| SL-4 | BLE | `ble_service.dart:793-796` | `_log()`가 `print()` 사용 — 프로덕션 로거 미연동 | 로깅 프레임워크 연동 또는 `kDebugMode` 가드 |
| SL-5 | BLE | `messaging_service.dart:1217-1223` | `_bytesEqual()` 비상수 시간 비교 — 보안 중요 경로에서는 constant-time 권장 | `listEquals()` 사용 또는 보안 경로 분리 |
| SL-6 | BLE | `topology_message.dart:161-170` | `_hexToBytes()` 대소문자 정규화 없음 — 노드ID 불일치 엣지 케이스 가능 | 입력을 `toLowerCase()` 정규화 |
| SL-7 | BLE | `messaging_service.dart:1170-1177` | 토폴로지 깊이 제한 3이 하드코딩 | `BleConstants.userMaxScanDepth` 상수로 이동 |
| SL-8 | 데이터 | `contact_file_service.dart:42-48` | 임포트 시 `nodeId == SHA-256(publicKey)[0:16]` 검증 없음 — 불일치 쌍 저장 가능 | `CryptoService().nodeIdFromPublicKey(publicKey)` 비교 추가 |
| SL-9 | 데이터 | `database_service.dart:656` | `Map.of(row)` 불필요한 복사 — 주석에 "이미 Uint8List" 명시돼 있으나 실제 목적 불분명 | 제거 또는 목적 주석 명시 |
| SL-10 | UI | `home_screen.dart:534-540` | `_bytesEqual()` 로컬 정의 중복 — 6개 파일에 같은 구현 | 공용 `utils.dart`로 추출 |
| SL-11 | UI | `home_screen.dart:2295-2300` | PC/Phone 아이콘 색상 `Colors.lightBlueAccent` 하드코딩 — 다크/라이트 테마 무시 | `Theme.of(context).colorScheme` 사용 |
| SL-12 | UI | `diagnostic_config.dart:28-44` | `targetNodeId` 미설정 여부를 빈 문자열로 판별 — `isEmpty` 체크가 fragile | `const bool.hasEnvironment()` 또는 nullable 타입으로 변경 |

---

### ✅ 잘 된 점

| 영역 | 내용 |
|------|------|
| 암호화 | SHA-256 순수 Dart 구현 FIPS 180-4 준수 |
| 암호화 | `verify()` 예외 대신 bool 반환 — 타이밍 공격 방지 |
| 암호화 | nodeId = SHA-256(publicKey) QR 검증 |
| 암호화 | 수신 파이프라인에서 서명 검증 선행 (DoS 방지) |
| BLE | `dispose()`가 타이머·구독·연결 모두 정리 |
| BLE | hopCount 증가 + TTL 감소 시 원본 서명 유지 |
| BLE | 토폴로지 BFS maxNodes=80 제한으로 폭주 방지 |
| UI | `PopScope`로 Android 뒤로가기 처리 |
| UI | 미신뢰 연락처 경고 배너 명확 표시 |
| 데이터 | 모든 WHERE 절 파라미터 바인딩 — SQL 인젝션 없음 |
| 데이터 | `UserLevel.canChangeContactLevel()` 설계 자체는 올바름 |
| 데이터 | `Contact.fromMap()` null-coalescing 안전 역직렬화 |

---

### 📋 수정 우선순위

**Phase A — 이번 Wave (즉시)**
1. **SC-5, SC-6** — 권한 탈취 벡터 차단 (`setUserLevel` 인증 + JSON 임포트 레벨 제한)
2. **SC-7** — 프래그먼트 인덱스 완전성 검증
3. **SC-8** — 페이로드 길이 제한
4. **SM-5** — 툴팁 한글 인코딩 수정
5. **SM-6** — 이름 입력 빈 문자열 방어

**Phase B — 다음 Wave**
1. **SC-2** — PBKDF2 반복 횟수 600,000으로 증가
2. **SC-3, SC-4** — HKDF 키 파생 적용
3. **SH-4** — 스캔 타이머 재귀 제거
4. **SH-5, SH-6** — 패킷 수신 파이프라인 순서 수정

**Phase C — 프로덕션 전 필수**
1. **SC-1** — 개인키 플랫폼 키스토어 이전
2. **SH-2** — Settings 로드 시 userLevel 검증

<!-- ================================================================ -->

<!-- 다음 리뷰는 아래 형식으로 추가하세요:

## YYYY-MM-DD — [리뷰 이유/시점]

> **리뷰 시점:** ...
> **전체 평가:** ...

### ✅ 이번에 새로 확인된 것
### 🔴 즉시 수정 필요
### 🟡 개선 권장
### 🔵 참고 사항
### 📋 다음 단계

-->

---

<!-- ================================================================ -->
## 2026-06-07 — 3-에이전트 전체 코드베이스 리뷰 (v1.0.Q)

> 보안/암호화, BLE/메시징/DB, UI/정책 3개 독립 에이전트 병렬 리뷰
> Critical + High 항목만 기록. 수정은 별도 Wave에서 진행.

### 요약

| 구분 | Critical | High |
|------|---------|------|
| 보안/암호화 | 3 | 4 |
| BLE/메시징/DB | 4 | 5 |
| UI/정책 | 2 | 4 |
| **합계** | **9** | **13** |

---

### [보안/암호화] Critical

| ID | 파일:라인 | 설명 | 영향 | 수정 방향 |
|---|---|---|---|---|
| SC-1 | `identity_service.dart:67–73`<br>`database_service.dart:192–199` | **개인키 평문 저장**: Ed25519 seed와 X25519 private key가 암호화 없이 SQLite BLOB으로 저장됨. 코드에 `TODO: seed 저장 전 암호화 적용 (Phase 2)` 주석이 있으나 미구현 | 기기 루팅·로컬 DB 접근 시 모든 메시지를 복호화하고 발신자로 위장(서명 위조) 가능 | `identity_backup_service.dart`의 PBKDF2+AES-GCM 패턴을 재사용하여 Android Keystore(또는 Flutter Secure Storage)로 파생한 키로 DB 저장 전 seed 암호화 |
| SC-2 | `contact_file_service.dart:42–72` | **연락처 JSON 가져오기 — nodeId 무결성 미검증**: `importFromJson`이 `nodeId`와 `publicKey`를 독립 hex로 수용하고 `SHA-256(publicKey)[0:16] == nodeId` 검증 없음. QR 파싱은 동일 검증을 수행하나 파일 import는 생략 | 공격자가 조작된 `.json` 파일을 배포하여 임의 nodeId에 신뢰 상태(`isTrusted:true`) + 높은 `userLevel` 설정 가능 → LEVEL_CHANGE 수신 시 권한 상승 | `_fromHex(item['nodeId'])` 직후 `crypto.nodeIdFromPublicKey(publicKey)`와 바이트 비교 추가; `trusted` 필드는 파일에서 읽지 않고 항상 `false`로 고정 |
| SC-3 | `contact_file_service.dart:55, 64`<br>`database_service.dart:247–269` | **JSON 가져오기가 `isTrusted:true`를 그대로 주입**: `trusted: trusted` (line 64)로 JSON 값을 신뢰 플래그에 직접 사용. 조작된 파일로 TOFU 우회 가능 | TOFU 핑거프린트 직접 확인 없이 신뢰 상태 설정 → 암호화 키 교환 없이 메시지 수신 신뢰 표시 | `importFromJson`에서 `trusted` 필드 무시, 항상 `trusted: false` 전달; 신뢰는 QR 스캔 또는 `confirmTrust()` 경로로만 가능하도록 강제 |

### [보안/암호화] High

| ID | 파일:라인 | 설명 | 영향 | 수정 방향 |
|---|---|---|---|---|
| SH-1 | `crypto_service.dart:140–158`<br>`messaging_service.dart:288–294` | **X25519 raw output → AES-256 직접 사용 (KDF 누락)**: `computeSharedSecret`이 반환한 32 byte DH 출력을 KDF 없이 곧바로 `SecretKey`로 사용. NIST SP 800-56A / RFC 7748은 반드시 KDF(HKDF-SHA256 등) 적용을 요구 | 약한 키 재료 사용 → AES-GCM 키가 균일 랜덤이 아닐 경우 키 구분 공격(key distinguishing) 위험 | `computeSharedSecret` 결과에 `HKDF-SHA256(salt=senderNodeId‖recipientNodeId, ikm=sharedSecret, info="mesh_comm_e2e")` 적용 후 AES 키로 사용 |
| SH-2 | `messaging_service.dart:540–572, 819–821` | **브로드캐스트 notice TEXT 평문 전송**: `_sendLongNoticeBroadcast`가 평문 UTF-8/JSON payload를 직접 사용. 수신측은 `packet.isBroadcast`이면 payload를 그대로 plaintext로 처리 | 네트워크 경로의 모든 릴레이 노드(R-14 위반)가 long-notice 메시지 내용을 평문으로 열람 가능 | 브로드캐스트 텍스트에도 그룹 키 또는 정책 명시; 최소한 UI에 경고 추가 |
| SH-3 | `database_service.dart:27, 633–649` | **30분 seen_messages TTL — 재전송 공격 창**: msg_id 중복 차단이 30분 후 만료되므로 동일 msg_id 패킷을 30분 이상 후 재전송하면 재처리됨 | 오래된 서명된 패킷을 재전송하여 메시지 중복 수신·릴레이 루프 유발 가능 | 패킷 헤더의 `timestamp`를 수신 시각과 비교하여 허용 창(예: ±5분) 초과 시 폐기; TEXT·KEY_ANNOUNCE에 미적용된 timestamp 검사 추가 |
| SH-4 | `messaging_service.dart:1059–1079` | **LEVEL_CHANGE 권한 검사가 발신자의 로컬 DB 등록 레벨 기준**: SC-2/SC-3 취약점이 결합되면 import된 신뢰 연락처가 `creator` 레벨로 등록될 수 있어 자신의 레벨을 강제 변경당할 수 있음 | 네트워크 공격자 또는 조작된 백업 파일로 `userLevel`을 `creator`로 상향 → notice 쿨다운 우회, 연락처 레벨 변경 권한 획득 | SH-3의 timestamp 검사 + SC-2/SC-3 수정으로 연동 방어; LEVEL_CHANGE 처리 전 발신자 레벨의 출처(QR 인증 vs. KEY_ANNOUNCE) 구분 플래그 도입 권장 |

---

### [BLE/메시징/DB] Critical

| ID | 파일:라인 | 설명 | 영향 | 수정 방향 |
|---|---|---|---|---|
| BC-1 | `ble_service.dart:542–554` | **GATT 연결 실패 시 disconnect 미호출**: `discoverServices` 등 예외 발생 시 `_connectToDevice`가 `_connectedDevices`에 등록하지 않은 채 리턴하지만 OS-level BLE 연결은 유지됨. `connectionState` 리스너도 없으므로 GATT 슬롯이 영구 leak | BLE GATT 슬롯 고갈 → 신규 연결 전부 실패. Android 재부팅 전까지 복구 불가 | `catch` 블록에서 `await device.disconnect()` 호출 추가; `finally`에서 `_connectedDevices`에 없으면 disconnect |
| BC-2 | `ble_service.dart:721–744` | **Heartbeat timeout 후 disconnect가 비동기로 처리되어 다음 틱에 중복 호출**: `disconnect()` 직후에도 `connectedDeviceIds`에 기기가 잔류하여 다음 heartbeat 틱에서 동일 기기에 disconnect 반복 호출 | disconnect 다중 호출 → BLE 스택 혼란, 재연결 로직과 충돌 가능 | `disconnect()` 호출 직전에 `_heartbeatMissed.remove(deviceId)` 및 `_connectedDevices.remove(deviceId)` 선제 정리 |
| BC-3 | `messaging_service.dart:757–781` | **TTL 체크가 패킷 처리 이후에 실행됨**: TTL=0 패킷도 핸들러가 모두 실행됨. 특히 PONG(TTL=0 설계)에 `ttl -= 1` 후 `-1`이 되어 relay 조건을 통과하여 **PONG flooding** 발생 가능 | PONG 패킷이 예상치 못하게 relay됨 → 메시 네트워크 내 flooding | TTL 체크를 `ttl -= 1` 이전에 수행; PONG은 msg_type 기반으로 relay 자체를 막음 |
| BC-4 | `ble_fragment_codec.dart:106–116` | **fragment reassembly 30초 만료 시 상위 레이어에 실패 통지 없음**: 느린 연결에서 불완전 어셈블리가 30초 후 소리 없이 drop되며 `null` 반환 외 아무 경고 없음 | 긴 메시지 무음 유실. 상위 레이어가 재전송 불가 → 중요 메시지 손실 | reassembly timeout 시 상위 레이어에 실패 콜백 제공; 경고 로그 추가 |

### [BLE/메시징/DB] High

| ID | 파일:라인 | 설명 | 영향 | 수정 방향 |
|---|---|---|---|---|
| BH-1 | `ble_service.dart:189–247` | **재스캔 익명 Timer 누수**: `startScan()` 예외 중단 시 15초 딜레이 익명 Timer가 `_scanTimer`에 저장되지 않아 `stopScan()` 후에도 취소되지 않음 | dispose 후 스캔 재시작 → 닫힌 StreamController에 접근 → `Bad state: Cannot add event after close` 크래시 | 15초 딜레이 타이머를 `_scanTimer`에 저장; 또는 dispose 완료 플래그 검사 |
| BH-2 | `ble_service.dart:528` | **`lastValueStream` 사용으로 stale notify 재처리**: `lastValueStream`은 이전 세션의 캐시값을 즉시 replay함. 연결 시 오래된 데이터가 `_handleIncomingBytes`로 전달될 수 있음 | 이전 세션의 stale 패킷이 재처리 → 중복 메시지 표시 또는 seen_messages 캐시 오염 | `lastValueStream` → `onValueReceived`로 변경 |
| BH-3 | `database_service.dart:124–178` | **DB 업그레이드 경로에 `seen_messages` 테이블 생성 누락**: `_onUpgrade`에서 `seen_messages` 테이블 생성 구문이 없어 v1에서 직접 업그레이드 시 테이블 미생성 | 구버전 앱 사용자 업그레이드 시 `no such table: seen_messages` 예외 → 앱 크래시 또는 중복 방지 기능 완전 비활성화 | `_onUpgrade`의 적절한 버전 구간에 `CREATE TABLE IF NOT EXISTS seen_messages (...)` 추가 |
| BH-4 | `messaging_service.dart:699–732` | **`isMessageSeen()` async 조회 사이 동일 패킷 중복 처리**: 거의 동시 도착한 동일 msg_id 패킷 두 개가 모두 `isMessageSeen() = false`를 받아 `_messageStreamController.add()` 두 번 emit | 사용자에게 동일 메시지가 두 번 표시될 수 있음 | `markMessageSeen()`을 가능한 일찍 호출하거나 Dart 레벨 in-memory Set으로 선제 dedup |
| BH-5 | `ble_service.dart:309–317` | **disconnect 직후 pending 전송들이 불필요한 실패-disconnect 루프**: `sendPacket()` 큐에 pending된 Future들이 disconnect 이후에도 `_sendPacketNow`를 실행하여 `_recordSendFailure` → 이미 없는 기기에 `disconnect()` 재호출 | disconnect 직후 로그 오염 및 타이밍에 따라 재연결 로직과 충돌 가능 | `disconnect()` 시 deviceId를 "disconnecting" Set에 추가하여 후속 `_recordSendFailure` 무시 |

---

### [UI/정책] Critical

| ID | 파일:라인 | 설명 | 영향 | 수정 방향 |
|---|---|---|---|---|
| UC-1 | `chat_screen.dart:127–148` | **채팅 히스토리 중복 표시 버그**: 초기 `_loadHistory(replace:false)` 후 스트림으로 수신된 메시지가 1분 후 `_loadHistory(replace:true)` 호출 시 DB에서 다시 addAll되어 중복 표시 | 수신 메시지가 채팅창에 2개씩 표시됨. 재현: 채팅 화면 열어둔 상태에서 메시지 수신 후 1분 경과 | `_loadHistory` 내부에서 msgId 기준 dedup(Map) 처리; 또는 타이머 제거하고 스트림만 사용 |
| UC-2 | `home_screen.dart:4354–4374` | **설정 저장 race condition**: Dark/Demo 스위치 `onChanged`에서 `unawaited`로 `save()` 호출 시 이전 save가 완료되기 전에 `_settingsFromFields()`가 이전 값을 읽어 덮어쓸 수 있음 | 설정 값 유실 가능성. Dark/Demo 중 하나가 저장되지 않을 수 있음 | Save 버튼 클릭 시에만 `_settingsFromFields()`로 한 번에 저장; 중간 상태는 dialog local state로만 관리 |

### [UI/정책] High

| ID | 파일:라인 | 설명 | 영향 | 수정 방향 |
|---|---|---|---|---|
| UH-1 | `qr_screen.dart:252–260` | **QR 스캔 시 상대방이 자신을 `server`로 위장 가능**: QR에 `"userLevel":"server"`를 넣으면 스캔한 상대방 DB에 server 레벨로 등록되어 채팅이 `canOpenChatWithContact` 정책에 의해 차단됨 | 공격자가 server로 위장한 QR을 찍히게 함으로써 피해자와의 채팅을 DoS로 차단 가능 | QR 경유 add 시에는 항상 `UserLevel.user`로 고정; 레벨은 관리자가 수동으로만 변경 |
| UH-2 | `chat_screen.dart:86–104` | **Server mode 차단 경로에서 `await maybePop()` 후 `mounted` 재확인 없음**: dispose된 위젯에서 `setState` 호출 가능성 | `setState after dispose` 예외 발생 위험 | `maybePop()` await 이후 `if (!mounted) return;` 추가 |
| UH-3 | `virtual_mesh_simulator.dart:248–279` | **데모 화면 재진입 시 notice cooldown 리셋**: `VirtualMeshNode` 재생성으로 `lastShortNoticeAt=0` 초기화 → cooldown 우회 가능 | 데모 모드의 notice cooldown 정책이 화면 재진입으로 우회됨. 사용자에게 실제 cooldown 동작을 잘못 학습시킬 수 있음 | `VirtualMeshSimulator`를 HomeScreen 레벨에서 유지하여 화면 이동에도 인스턴스가 유지되도록 함 |
| UH-4 | `app_settings_service.dart:19–23`<br>`main.dart:59–62` | **Windows Creator 레벨 적용 전 `_emit()` 발화**: `load()` 이후 Windows 조건으로 레벨을 creator로 수정 전에 settingsStream 구독자가 이전 값을 받아 `_MeshCommAppState._settings`에 old level이 남음 | Windows에서 UI에 creator 레벨이 표시되지 않을 수 있음; 설정 dialog에서 잘못된 level 초기값 표시 | `save(notify:false)` → `save(notify:true)`로 변경; 또는 구독자 등록을 Windows 레벨 수정 이후로 순서 조정 |

---

### 잘 된 점

| 항목 | 근거 |
|---|---|
| KEY_ANNOUNCE 서명 검증 파이프라인 | `_resolveSenderPublicKey` → `verifyPacketSignature` → 처리 순서가 일관되게 지켜지며, 서명 검증 성공 후에만 `markMessageSeen`을 기록하여 위조 패킷을 통한 DoS를 방지 |
| 백업 암호화 품질 | PBKDF2-HMAC-SHA256 210,000회 반복, 16 byte 랜덤 salt, AES-GCM-256 — 현대적 백업 암호화 기준 충족 |
| nodeId 결정적 바인딩(R-06) | QR 파싱·KEY_ANNOUNCE 파싱 모두 `SHA-256(publicKey)[0:16] == senderId` 검증으로 node_id 위조를 원천 차단(파일 import 경로 제외 — SC-2) |
| fragment reassembler 자동 만료 | `_cleanExpired()`가 `add()` 호출마다 실행되어 불완전 어셈블리 30초 후 자동 정리; `removeDevice()`로 연결 끊김 시 버퍼 즉시 해제 |
| dispose() 일관성 | `HomeScreen`과 `ChatScreen` 모두 StreamSubscription, Timer, Controller를 dispose()에서 빠짐없이 취소/해제; `mounted` 가드도 광범위하게 적용 |
| Server mode 채팅 차단 이중화 | `HomeScreen._openChat`과 `ChatScreen.initState` 양쪽에서 독립적으로 `canSendMessages` 체크 수행 |
| QR TOFU 플로우 | QR 스캔 → `addOrUpdateContact`(미확인) → `_showFingerprintDialog` → `confirmTrust` 순서로 올바르게 구현됨 |

---

### 우선순위 액션 플랜

| 우선순위 | ID | 작업 |
|---|---|---|
| P1 (즉시) | BC-3 | TTL 체크를 처리 전으로 이동; PONG relay 차단 |
| P1 (즉시) | BH-2 | `lastValueStream` → `onValueReceived` 교체 |
| P1 (즉시) | UC-1 | 채팅 히스토리 중복 표시 버그 수정 |
| P1 (즉시) | SC-2, SC-3 | JSON import에서 nodeId 검증 + trusted 강제 false |
| P2 (단기) | BC-1 | GATT 연결 실패 시 disconnect 추가 |
| P2 (단기) | BC-2 | Heartbeat disconnect 선제 정리 |
| P2 (단기) | UH-1 | QR 경유 userLevel 고정 |
| P2 (단기) | UH-4 | Windows Creator 레벨 적용 순서 수정 |
| P3 (중기) | SC-1 | 개인키 암호화 저장 (큰 작업) |
| P3 (중기) | SH-1 | HKDF 적용 |
| P3 (중기) | BH-3 | DB 업그레이드 seen_messages 테이블 추가 |
