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
