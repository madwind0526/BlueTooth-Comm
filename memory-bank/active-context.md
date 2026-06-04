# Active Context

## Latest 2026-06-04

- Latest build: `v1.0.H / 20260604-214748`
- Identity Backup/Restore verified on S26 after uninstall/reinstall.
- DB v6: message `expires_at`, contact `remote_display_name`, `remote_avatar_key`.
- Chat modes: normal, timed, notice S, notice L.
- Notice policy: 50 chars, level-based cooldowns. Creator unlimited; Builder S/L 1h/2h; Admin 2h/4h; User 6h/24h; Server cannot send.
- DB v8: contact `user_level`; app setting `user_level`; unread message counts and read marking added.
- Message UX: incoming sound, per-contact unread badge, per-contact message delete, Settings delete-all-messages.
- Level policy: Settings only lets regular User/Server choose User or Server for self. Contact `... > Level` is only for Admin/Builder/Creator. Admin can assign User/Admin; Builder can assign User/Admin/Builder; Creator can assign User/Admin/Builder/Creator.
- Level sync: QR and KEY_ANNOUNCE now include `userLevel`; contacts update their stored remote level from the peer. Contact level changes are allowed only when the contact's level is lower than my level.
- Server is self-selected only by regular User/Server in Settings. Admin/Builder/Creator cannot assign or remove Server; Server contacts are displayed distinctly but not externally editable.
- SCAN map now hides stale unsaved discovered nodes unless they were seen within the last 3 minutes, and scan start runs stale-contact cleanup. Settings dialog clamps text scaling to prevent Android large-font wrapping. Contact import opens the file picker without a restrictive extension filter.
- Android back now stays inside the app: Back from SCAN/Search/Home-root returns Home/All, and returning from Chat/QR also resets to Home/All. App exit is intended through the Power button or Android Home/Recents.
- Current local roles: S26 Ultra `madwind` = Creator, Windows PC `메인PC임` = Builder, S21 `홍기` = User.
- Chat filter and chat screen periodically refresh so expired instant messages disappear.
- Safe duplicate cleanup only removes untrusted, non-favorite, no-group, no-message temporary contacts with matching announced metadata.
- SCAN START button is now single-line safe under larger phone font scaling by using a custom fitted button; bottom navigation selection remains icon-color only.
- SCAN topology is still local-contact based. True N-depth topology packet exchange is still pending.
- Attachment transfer is documented but not fully implemented; full files need a multi-chunk protocol.

## Current Focus

- ✅ Phase-1 portrait shell: top transport menu, left filters, bottom navigation
- ✅ Favorites-first alphabetical contact/group sorting and local group management
- ✅ Search screen and SCAN Tree-only entry screen
- ✅ GPS/Map removed from scope; shout policy reduced to 50 chars / 1 day
- ⏳ Phase-2: group messaging model and N-depth topology protocol / Tree renderer

- ✅ S26 Ultra added: PC direct, phone direct, and two-hop relay TEXT verified
- ✅ Samsung phone-to-phone BLE scan needs location permission and system location service enabled
- ✅ Wave 2 완료: Android + Windows MVP 구현
- ✅ Android 실기기 동작 확인 (S21+)
- ✅ QR 등록 → 연락처 → 채팅 UI 흐름 동작
- ✅ 코드 리뷰 Critical 3개 수정 (릴레이 재서명, DoS, R-14)
- ✅ Android Peripheral GATT 서버 구현 (`ble_peripheral`)
- ✅ Windows → S21+ BLE 광고 발견 + GATT 연결 smoke test
- ✅ 중복 BLE 연결 경쟁 조건 수정 (`_connectingDevices`)
- ✅ 연결 직후 `KEY_ANNOUNCE` 재전송 + 홈 화면 수동 키 재전송 버튼
- ✅ Windows ↔ S21+ 실제 암호화 TEXT write/notify 양방향 테스트
- ✅ 릴레이된 자체 패킷 echo 조기 drop
- ✅ DB v2 연락처 로컬 메타데이터 (`is_favorite`, `group_name`)
- ✅ 연락처 `...` 메뉴: 삭제, Group 추가/변경, 즐겨찾기, 로컬 이름 변경
- ✅ 이전 진단 과정에서 저장된 자기 연락처 앱 시작 시 자동 정리
- ✅ Android 연락처 이름/Group 변경 시 다이얼로그 controller use-after-dispose 수정
- ✅ Phase-0 프로토콜 v2 + DB v3 마이그레이션
- ✅ TEXT X25519 ECDH + AES-GCM 종단 간 암호화
- ✅ BLE fragmentation/reassembly, Windows MTU 23 실기기 검증
- ✅ GATT characteristic 캐싱 + Android notify 직렬화
- ✅ heartbeat PING/PONG 활성화, 30초 주기 실기기 검증
- ✅ KEY_ANNOUNCE 상호 응답 + 반복 응답 제한
- 🔲 A ↔ PC ↔ B ↔ C 물리 기기 3홉 릴레이 E2E 검증
- 🔲 두 번째 Android 폰으로 폰↔폰 실제 메시지 전송 테스트

<!-- 규칙: 최근 작업 10개만 유지 -->
