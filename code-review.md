# MeshComm Code Review Log

> 날짜별 리뷰 결과를 누적 기록합니다.
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
