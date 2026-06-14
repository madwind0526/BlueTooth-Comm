# MeshComm Code Review - Codex

Date: 2026-06-14

Scope: `mesh_comm` Flutter/Dart app 전체 코드, 핵심 BLE/LAN 메시징, 암호화, 그룹, 전송, UI 경로.

Method:
- Codex 로컬 리뷰
- 독립 sub-agent 4개 병렬 리뷰: 보안/암호화, 로직/동시성, 성능/자원, UI/UX
- `flutter analyze`
- `flutter test`

Verification result:
- `flutter analyze`: PASS, no issues found
- `flutter test`: PASS, 20 tests passed

## 간단 정리

현재 코드는 정적 분석과 테스트를 통과합니다. 큰 방향도 잘 잡혀 있습니다. 특히 최근 LAN/BLE 라우팅, BLE MTU cap, DB schema self-heal, transfer retry 쪽 개선 흔적이 분명합니다.

다만 테스트로 잡히지 않는 실제 운영 리스크가 꽤 있습니다. 가장 먼저 봐야 할 것은 보안/권한 경계입니다. 연락처 import가 nodeId와 publicKey의 관계를 검증하지 않고 trusted 값을 받아들이며, 그룹 메시지/멤버 변경은 sender가 그룹 멤버인지 방장인지 확인하지 않습니다. Server mode가 relay-only라는 규칙도 그룹 제어 패킷과 수신 처리에서는 일부 빠져 있습니다.

두 번째는 파일 전송입니다. 파일 header/chunk가 암호화되지 않고, chunk마다 SQLite seen cache와 서명 검증을 타며, 파일 전체를 메모리에 올립니다. 큰 파일이나 BLE 전송에서 배터리, 속도, 메모리 문제가 날 수 있습니다.

세 번째는 LAN/BLE 상태 일관성입니다. 사용자가 LAN을 꺼도 SCAN 후처리나 connectivity 이벤트가 다시 LAN을 켤 수 있고, 반대로 BLE가 꺼져 있으면 LAN-only SCAN은 막힙니다. UI 표시와 실제 transport 상태가 어긋날 수 있습니다.

## 우선순위 권장

1. 보안/권한: contact import 검증, 그룹 권한 검증, Server relay-only 송수신 강제
2. Identity backup/restore: secure storage 기반으로 실제 key를 백업/복원
3. LAN/BLE 정책: LAN off source of truth, LAN-only SCAN 허용, PING/PONG transport 분리
4. 파일 전송 안정화: 크기 제한, chunk validation, streaming, E2E 암호화, 빠른 dedup 경로
5. DB/성능: messages 인덱스, KEY_ANNOUNCE 처리 비용 감소, BLE scan backoff
6. UI 안정성/접근성: mounted check, touch target, text scaling, QR responsive sizing

## Creator/Admin/Builder 권한 설계 보완

현재 리뷰에서 지적한 "Windows 실행 시 Creator 강제" 문제의 핵심은 Windows 자체가 아닙니다. 목표는 "내 PC에 설치된 내 identity만 Creator"가 되는 것입니다. 따라서 권한은 OS가 아니라 cryptographic identity 기준으로 판단해야 합니다.

### 권장 원칙

| 권한 | 권장 인정 방식 |
|---|---|
| Creator | 앱이 신뢰하는 Creator public key 또는 nodeId allowlist + 해당 private key 서명 가능 여부 |
| Admin / Builder | Creator가 서명한 role grant가 있을 때만 인정 |
| User / Server | 자기 설정 가능. 단, Server는 relay-only 정책을 송신/수신 양쪽에서 강제 |
| Contact 표시 level | KEY_ANNOUNCE의 자기 주장만으로 elevated role을 믿지 않음 |

쉽게 말하면 `User`와 `Server`는 사용자가 직접 고를 수 있어도, `Admin`, `Builder`, `Creator`는 "누가 그렇게 임명했는가"를 서명으로 증명해야 합니다.

### Creator가 Admin/Builder를 임명하는 흐름

Creator가 특정 사용자를 Admin 또는 Builder로 지정하려면 단순히 contact DB의 level만 바꾸면 안 됩니다. Creator private key로 서명한 role grant를 만들어야 합니다.

권장 흐름:

```text
1. Creator가 사용자 A를 선택
2. level = Admin 또는 Builder 지정
3. Creator private key로 role grant 서명
4. role grant를 A에게 전송
5. A는 Creator signature를 검증하고 자기 권한을 갱신
6. 다른 노드도 A의 권한을 볼 때 role grant signature를 확인
```

role grant payload 예시:

| 필드 | 의미 |
|---|---|
| `grantId` | grant 중복 방지 ID |
| `targetNodeId` | 권한을 받을 node |
| `role` | `admin` 또는 `builder` |
| `issuerNodeId` | 권한을 준 Creator |
| `issuedAt` | 발급 시각 |
| `expiresAt` | 만료 시각, 선택 |
| `signature` | Creator private key로 위 payload에 서명 |

개선 방향:
- `MsgType.adminNotice`의 `level_change`를 "요청"이 아니라 signed role grant로 확장합니다.
- 수신자는 issuer가 신뢰된 Creator인지 확인하고, signature와 `targetNodeId == myNodeId`를 검증한 뒤 자기 role을 반영합니다.
- contact의 elevated role 표시도 해당 contact가 가진 유효 role grant를 확인한 뒤 표시합니다.
- 추후에는 revoke grant와 expiresAt 기반 만료 처리를 추가합니다.

### nodeId만 알면 Creator가 되는가?

아닙니다. 정상 설계에서는 nodeId는 공개 이름표일 뿐입니다. Creator 여부는 해당 nodeId에 대응되는 private key로 서명할 수 있어야 증명됩니다.

| 보유한 정보 | Creator 가능 여부 |
|---|---|
| nodeId만 앎 | 불가능 |
| public key만 앎 | 불가능 |
| 앱 DB만 복사했지만 private key 없음 | 불가능 |
| identity backup 파일과 비밀번호를 모두 획득 | 가능 |
| secure storage의 private key까지 탈취 | 가능 |

즉, nodeId가 알려지는 것은 괜찮지만 Creator identity backup과 비밀번호가 함께 유출되면 그 identity를 복제할 수 있습니다. Creator backup은 강한 비밀번호, 제한된 보관, 필요 시 revoke/key rotation 절차가 필요합니다.

### hard-coded nodeId allowlist의 한계

내 PC의 nodeId를 앱에 hard coding하면 "내 identity만 Creator"라는 1차 필터로는 쓸 수 있습니다. 하지만 앱 binary나 소스를 변조할 수 있는 사람은 allowlist를 자기 nodeId로 바꿀 수 있습니다. 따라서 hard coding만으로 권한을 보장하면 안 됩니다.

더 안전한 판단은 다음 조합입니다.

```text
Creator 인정 = trusted Creator public key/nodeId allowlist
             + 해당 private key로 만든 유효 signature
```

정리하면, 내 PC만 Creator로 만들려면 Windows 여부가 아니라 Creator identity의 public key/nodeId를 root of trust로 두고, Admin/Builder 임명은 Creator 서명 grant로 증명하는 방식이 가장 적합합니다.

## Critical

### 1. 연락처 import가 TOFU 신뢰 모델을 우회할 수 있음

Files:
- `mesh_comm/lib/features/contacts/contact_file_service.dart:97`
- `mesh_comm/lib/features/contacts/contact_file_service.dart:104`
- `mesh_comm/lib/features/messaging/messaging_service.dart:2059`

Problem:
- import된 `nodeId`가 `SHA-256(publicKey)[0..16]`인지 검증하지 않습니다.
- import 파일의 `isTrusted` 값을 그대로 DB에 저장합니다.
- 이후 일반 패킷 검증은 DB public key를 조회해 서명을 검증하므로, 잘못 매핑된 contact가 있으면 nodeId-publicKey 불변식이 깨진 상태를 계속 신뢰할 수 있습니다.

Impact:
- 조작된 contact export 파일을 가져오면 공격자가 특정 nodeId에 자기 public key를 연결하고 trusted 상태까지 주입할 수 있습니다.
- R-06 node_id 규칙과 R-08 TOFU 모델이 깨집니다.

Direction:
- 모든 contact write 경로에서 `nodeId == CryptoService.nodeIdFromPublicKey(publicKey)` 검증을 강제합니다.
- import의 `isTrusted=true`는 무시하고, QR/지문 확인 이후에만 trusted로 올립니다.
- `_resolveSenderPublicKey()`에서도 방어적으로 public key-derived nodeId를 재검증합니다.
- import 보안 테스트를 추가합니다.

### 2. 그룹 메시지/멤버 변경 수신 권한 검증이 부족함

Files:
- `mesh_comm/lib/features/groups/group_messaging_service.dart:306`
- `mesh_comm/lib/features/groups/group_messaging_service.dart:343`
- `mesh_comm/lib/features/messaging/messaging_service.dart:1243`

Problem:
- `_handleGroupMessage()`는 group 존재만 확인하고 sender가 멤버인지 확인하지 않습니다.
- `_handleMemberUpdate()`는 senderNodeId를 인자로 받지 않아 방장/권한 검증이 구조적으로 불가능합니다.
- invite response도 실제 pending invite 또는 방장 발신 여부 검증이 약합니다.

Impact:
- groupId를 아는 신뢰 연락처가 임의 메시지를 주입하거나 멤버 추가/삭제/방장 변경을 위조할 수 있습니다.

Direction:
- `GroupMessagingService.handleIncomingPacket()`에서 sender를 모든 handler에 전달합니다.
- group message는 `group.hasMember(sender)`일 때만 저장합니다.
- member update, leader change, remove는 방장 또는 명시된 권한자만 허용합니다.
- invite response는 pending invite가 있는 대상만 처리합니다.
- 그룹 권한 unit test를 추가합니다.

### 3. Identity backup/restore가 secure storage 전환과 맞지 않음

Files:
- `mesh_comm/lib/features/identity/identity_backup_service.dart:34`
- `mesh_comm/lib/features/identity/identity_backup_service.dart:162`
- `mesh_comm/lib/features/identity/identity_service.dart:104`

Problem:
- identity seed는 secure storage로 이동한 뒤 DB의 private key가 zero 처리됩니다.
- 그러나 backup export는 DB의 `private_key`, `encryption_private_key`를 읽습니다.
- restore는 DB에 private key를 쓰지만 secure storage를 갱신하지 않습니다.

Impact:
- 백업 파일에 실제 key가 아니라 zero key가 담길 수 있습니다.
- 복원 후 DB public identity와 secure storage private key가 불일치할 수 있습니다.
- 복원 직후 private key가 DB에 평문으로 남을 수 있습니다.

Direction:
- backup/export는 `IdentityService` 또는 secure storage accessor를 통해 실제 seed를 읽습니다.
- restore는 secure storage에 seed를 쓰고 DB에는 public key 및 zero private key만 남깁니다.
- restore 직후 signature self-test와 X25519 self-test를 수행합니다.

## High

### 4. Server mode relay-only 정책이 그룹 송신/수신에서 누락됨

Files:
- `mesh_comm/lib/features/groups/group_messaging_service.dart:87`
- `mesh_comm/lib/features/groups/group_messaging_service.dart:113`
- `mesh_comm/lib/features/messaging/messaging_service.dart:1857`
- `mesh_comm/lib/features/messaging/messaging_service.dart:1311`

Problem:
- 1:1 text send는 local server mode에서 차단하지만, 그룹 invite/message/member update/leave 제어 패킷에는 `canSendMessages` guard가 없습니다.
- 수신 TEXT와 그룹 메시지도 sender contact가 `UserLevel.server`인지 확인하지 않습니다.

Impact:
- Server node가 사용자 메시지나 그룹 제어 패킷을 만들 수 있어 "server-mode nodes may relay only" 규칙을 우회합니다.

Direction:
- `sendGroupControlPacket()` 또는 `GroupMessagingService._send()`에서 server mode를 차단합니다.
- UI에서도 서버 모드일 때 그룹 생성/초대/송신 버튼을 숨기거나 비활성화합니다.
- 수신 처리 시 sender contact level이 server면 TEXT/groupMessage/group control을 drop합니다.
- sender/receiver 양쪽 정책 테스트를 추가합니다.

### 5. LAN OFF 상태가 실제 transport 상태와 어긋날 수 있음

Files:
- `mesh_comm/lib/ui/home/home_screen.dart:655`
- `mesh_comm/lib/ui/home/home_screen.dart:721`
- `mesh_comm/lib/features/messaging/messaging_service.dart:220`

Problem:
- 사용자가 LAN 버튼을 꺼도 SCAN 후처리가 `stopLan()` 후 `startLan()`을 다시 호출합니다.
- connectivity change handler도 local network가 감지되면 `_lan.start()`를 호출합니다.
- UI의 `_lanEnabled=false`와 `LanService.isRunning=true`가 분리될 수 있습니다.

Impact:
- 사용자에게 LAN OFF로 보이지만 UDP/TCP discovery와 LAN routing이 다시 살아날 수 있습니다.
- 배터리/프라이버시/테스트 조건이 사용자의 의도와 달라집니다.

Direction:
- MessagingService에 `userLanEnabled`를 단일 source of truth로 둡니다.
- `_handleConnectivityChange`, `notifyWakeup`, SCAN 후 LAN restart 모두 이 플래그를 확인합니다.
- LAN OFF 상태에서 SCAN 후처리가 LAN을 재시작하지 않도록 합니다.

### 6. LAN-only SCAN이 막혀 있음

Files:
- `mesh_comm/lib/ui/home/home_screen.dart:681`
- `mesh_comm/lib/ui/home/home_screen.dart:699`

Problem:
- `_runScan()`은 Bluetooth가 꺼져 있으면 즉시 return합니다.
- 메모리뱅크 패턴은 "BLE 꺼져도 LAN 있으면 SCAN 동작"입니다.

Impact:
- LAN peer가 살아 있어도 BLE off 상태에서는 topology scan을 시작할 수 없습니다.

Direction:
- 차단 조건을 `if (!_bluetoothEnabled && !_lanEnabled)`로 바꿉니다.
- `_bleService.startScan()`은 BLE enabled일 때만 실행합니다.
- topology request와 KEY_ANNOUNCE는 LAN만 켜져 있어도 진행합니다.

### 7. 파일 전송 payload가 E2E 암호화되지 않음

Files:
- `mesh_comm/lib/features/transfer/transfer_service.dart:264`
- `mesh_comm/lib/features/transfer/transfer_service.dart:301`
- `mesh_comm/lib/features/messaging/messaging_service.dart:842`

Problem:
- file header와 chunk payload가 서명은 되지만 AES-GCM 암호화는 되지 않습니다.

Impact:
- 파일은 relay 제외라 하더라도 BLE/LAN 링크 관찰자에게 파일명, MIME, 파일 내용 chunk가 노출될 수 있습니다.

Direction:
- 파일 header/chunk도 대상 X25519 shared secret으로 암호화합니다.
- tid, chunk index, totalChunks는 암호문 내부 또는 AEAD AAD로 바인딩합니다.
- 암호화된 파일 전송 round-trip test를 추가합니다.

### 8. 파일 전송 크기/범위 검증과 메모리 사용이 위험함

Files:
- `mesh_comm/lib/features/transfer/transfer_service.dart:395`
- `mesh_comm/lib/features/transfer/transfer_service.dart:411`
- `mesh_comm/lib/ui/chat/chat_screen.dart:350`
- `mesh_comm/lib/ui/chat/chat_screen.dart:379`
- `mesh_comm/lib/features/messaging/message_attachment_policy.dart:4`

Problem:
- 수신 header의 `fileSize`, `totalChunks`, filename length, mime 검증이 부족합니다.
- chunk 수신 시 `chunkIdx < totalChunks`, 누적 byte `<= fileSize` 확인이 없습니다.
- 파일/이미지를 전체 `Uint8List`로 읽고, outgoing transfer와 completed event, image cache에도 바이트를 유지합니다.
- attachment policy의 max size가 실제 send path에서 강제되지 않습니다.

Impact:
- 큰 파일 또는 악의적 chunk로 Android OOM, GC 증가, UI 끊김, transfer timeout까지 메모리 점유가 발생할 수 있습니다.

Direction:
- 파일 선택 직후와 `MessagingService.sendFile()` 양쪽에서 크기 제한을 강제합니다.
- receiver에서 header와 chunk index/size를 검증하고 실패 시 즉시 cancel/nack합니다.
- 전송은 file stream 또는 temp file chunk reader 기반으로 바꿉니다.
- 미리보기는 작은 image preview만 bytes로 보관하고, 나머지는 file path 기반으로 표시합니다.

### 9. 파일 chunk/ack가 일반 packet path를 타서 비용이 큼

Files:
- `mesh_comm/lib/features/messaging/messaging_service.dart:1157`
- `mesh_comm/lib/features/messaging/messaging_service.dart:1192`
- `mesh_comm/lib/features/messaging/messaging_service.dart:1214`

Problem:
- 모든 file chunk와 ack가 SQLite `seen_messages` 조회/insert와 Ed25519 signature verify를 거칩니다.

Impact:
- BLE 25MB 전송은 chunk 수가 매우 많아 SQLite I/O, CPU, 배터리 비용이 급증합니다.

Direction:
- header 검증 이후 file transfer 전용 fast path를 둡니다.
- chunk dedup은 `tid + chunkIdx` 기반 in-memory cache로 처리합니다.
- ack는 transfer session 검증 후 lightweight path로 처리합니다.

#### 파일 전송 전용 빠른 dedup 경로란?

현재 구조는 파일 조각 하나하나를 일반 메시지처럼 처리합니다. 즉, 파일 chunk 하나마다 signature verify, `seen_messages` DB 조회, `seen_messages` DB insert가 반복됩니다. 작은 메시지에는 안전한 방식이지만, 파일 전송에는 비용이 큽니다.

예를 들어 25MB 파일을 BLE로 400 byte 단위로 보내면 chunk가 6만 개 이상 생길 수 있습니다. 이 경우 일반 packet path를 그대로 쓰면 DB 조회/기록과 서명 검증도 chunk 수만큼 반복될 수 있습니다.

개선 아이디어는 파일 전송을 "메시지 6만 개"가 아니라 "하나의 검증된 transfer session 안의 chunk 6만 개"로 다루는 것입니다.

권장 흐름:

```text
fileHeader 수신:
  1. signature 검증
  2. sender/target 확인
  3. tid, fileSize, totalChunks, chunkSize 검증
  4. transfer session 등록

fileChunk 수신:
  1. tid가 등록된 transfer session인지 확인
  2. chunkIdx가 0 <= chunkIdx < totalChunks인지 확인
  3. receivedChunks[chunkIdx]가 이미 있으면 중복으로 drop
  4. 새 chunk면 저장하고 ACK 전송

transfer 완료:
  1. 전체 chunk 수와 fileSize 재확인
  2. 파일 조립/저장
  3. session dedup 상태 삭제
```

기존 방식과 개선 방식 비교:

| 구분 | 현재 방식 | fast path |
|---|---|---|
| 중복 확인 | 모든 chunk를 `seen_messages` DB에 기록 | transfer session의 `tid + chunkIdx` 메모리 set으로 확인 |
| 서명 검증 | chunk마다 Ed25519 검증 | header에서 강하게 검증하고 chunk는 session 범위 검증 중심 |
| DB 부하 | chunk 수만큼 DB 조회/insert | 완료 파일 저장 중심 |
| 메모리 | session 상태와 chunk data 관리 불명확 | session별 received map/set을 명시적으로 관리하고 완료/실패 시 삭제 |
| 보안 보완 | packet 단위 서명 의존 | header 서명 + session 검증 + chunk index/size 검증 + 가능하면 chunk MAC/E2E 암호화 |

주의할 점:
- fast path는 "검증을 없애자"가 아니라 "파일 전송에 맞는 검증으로 바꾸자"는 의미입니다.
- header만 믿고 아무 chunk나 받으면 안 됩니다. `tid`, sender, target, chunk index, total size를 계속 확인해야 합니다.
- 파일 chunk를 E2E 암호화한다면 chunk MAC 검증도 함께 수행하는 편이 좋습니다.

## Medium

### 10. ttl/hopCount가 서명 대상에서 제외되어 전파 범위 변조 가능

Files:
- `mesh_comm/lib/core/packet/mesh_packet.dart:145`
- `mesh_comm/lib/features/messaging/messaging_service.dart:1272`

Problem:
- relay 재서명 문제를 피하려고 `ttl`과 `hopCount`가 signature 대상에서 빠져 있습니다.

Impact:
- 유효 서명 packet을 받은 악의적 node가 TTL을 늘려 전파 범위를 확장할 수 있습니다.

Direction:
- mutable `ttl`과 별개로 signed `originTtl` 또는 `maxHop`을 추가합니다.
- 수신 시 `hopCount <= originTtl`을 검증합니다.
- 장기적으로 original packet signature와 relay envelope를 분리합니다.

### 11. PING/PONG이 transport를 혼용함

Files:
- `mesh_comm/lib/features/messaging/messaging_service.dart:1203`
- `mesh_comm/lib/features/messaging/messaging_service.dart:1773`

Problem:
- PING을 BLE로 받았어도 PONG은 `_sendPacketToNodeId()`를 통해 LAN 우선으로 나갈 수 있습니다.
- PONG 수신은 항상 `_ble.markHeartbeatResponse(fromDeviceId)`만 호출합니다.

Impact:
- LAN+BLE 동시 연결에서 BLE heartbeat가 실제 BLE 왕복을 확인하지 못하거나, LAN PONG이 BLE heartbeat로 잘못 처리될 수 있습니다.

Direction:
- PONG은 들어온 transport 그대로 응답합니다.
- `fromDeviceId`가 LAN nodeId인지 BLE deviceId인지 명확히 구분합니다.
- LAN heartbeat와 BLE heartbeat 상태를 별도로 갱신합니다.

### 12. relay broadcast에서 LAN reverse path filtering이 빠짐

Files:
- `mesh_comm/lib/features/messaging/messaging_service.dart:1290`
- `mesh_comm/lib/core/lan/lan_service.dart:187`

Problem:
- BLE broadcast는 `excludeDeviceId`를 받지만 LAN broadcast는 수신 peer를 제외할 방법이 없습니다.

Impact:
- LAN으로 받은 relay packet을 같은 LAN peer에게 되돌려 보내 불필요한 트래픽과 echo가 생깁니다.

Direction:
- `LanService.broadcastPacket(packet, {String? excludePeerId})`로 확장합니다.
- `_broadcastRelayPacket()`에서 LAN 수신 peer를 제외합니다.

### 13. 복호화 실패 전에 seen 처리되어 정상 메시지 재시도가 막힘

Files:
- `mesh_comm/lib/features/messaging/messaging_service.dart:1191`
- `mesh_comm/lib/features/messaging/messaging_service.dart:1329`

Problem:
- signature 검증 후 바로 `markMessageSeen()`을 수행합니다.
- 이후 내 target 메시지의 encryption key 없음 또는 decrypt 실패가 발생하면 메시지는 처리되지 않았지만 seen cache에 남습니다.

Impact:
- KEY_ANNOUNCE 순서 지연이나 구 DB encryption key 누락 상태에서 먼저 도착한 정상 메시지가 30분 동안 재수신되어도 drop될 수 있습니다.

Direction:
- loop 방지 seen과 local 처리 완료 상태를 분리합니다.
- 내 target TEXT/group packet은 decrypt 성공 후 seen 확정하거나, decrypt 실패를 retry 가능한 상태로 기록합니다.

### 14. 서비스 구독/타이머 cleanup이 불완전함

Files:
- `mesh_comm/lib/features/messaging/messaging_service.dart:282`
- `mesh_comm/lib/features/messaging/messaging_service.dart:330`
- `mesh_comm/lib/features/messaging/messaging_service.dart:1925`
- `mesh_comm/lib/features/transfer/transfer_service.dart:93`
- `mesh_comm/lib/core/lan/lan_service.dart:437`

Problem:
- connectivity subscription과 transfer stream subscription을 저장/취소하지 않습니다.
- TransferService에는 watchdog, ack timer, stream controller cleanup용 dispose가 없습니다.
- LAN reconnect `Future.delayed` 예약 작업을 cancel할 수 없습니다.

Impact:
- dispose 후 재초기화 시 중복 구독, 중복 file save/reset, 살아있는 timer, 불필요한 reconnect가 생길 수 있습니다.

Direction:
- subscription 필드를 추가하고 dispose에서 cancel합니다.
- `TransferService.dispose()`를 만들고 MessagingService.dispose에서 호출합니다.
- LAN reconnect는 `Timer` map으로 관리해 stop/dispose에서 cancel합니다.

### 15. messages 테이블 인덱스가 부족함

Files:
- `mesh_comm/lib/core/storage/database_service.dart:130`
- `mesh_comm/lib/core/storage/database_service.dart:643`
- `mesh_comm/lib/core/storage/database_service.dart:696`
- `mesh_comm/lib/core/storage/database_service.dart:712`

Problem:
- `sender_id`, `target_id`, `timestamp`, unread query용 인덱스가 없습니다.

Impact:
- 메시지가 많아질수록 chat history, unread count, contact-with-messages 조회가 full scan에 가까워집니다.

Direction:
- DB v12 migration으로 다음 인덱스를 추가합니다.
  - `(sender_id, target_id, timestamp)`
  - `(target_id, sender_id, timestamp)`
  - `(target_id, is_read, is_outgoing)`
  - 필요 시 `(sender_id, timestamp)`, `(target_id, timestamp)`

### 16. BLE scan 반복이 배터리 비용을 키울 수 있음

Files:
- `mesh_comm/lib/core/ble/ble_service.dart:237`
- `mesh_comm/lib/core/ble/ble_constants.dart:28`
- `mesh_comm/lib/main.dart:109`

Problem:
- 앱 시작 후 max connection에 도달할 때까지 10초 scan, 15초 대기 패턴이 반복됩니다.

Impact:
- 실제 환경에서 7개 BLE 연결을 채우기 어렵다면 모바일 배터리 소모가 지속됩니다.

Direction:
- 최근 발견 여부, LAN peer 수, 화면 상태, 배터리 상태에 따라 exponential backoff를 적용합니다.
- SCAN 화면 active scan과 background low-frequency scan을 분리합니다.

### 17. UI async mounted guard가 일부 빠짐

Files:
- `mesh_comm/lib/ui/chat/chat_screen.dart:377`
- `mesh_comm/lib/ui/chat/group_chat_screen.dart:319`
- `mesh_comm/lib/ui/chat/group_chat_screen.dart:336`
- `mesh_comm/lib/ui/chat/group_chat_screen.dart:372`
- `mesh_comm/lib/ui/chat/group_chat_screen.dart:389`

Problem:
- file/image read와 send await 이후 `mounted` 확인 없이 setState 또는 추가 전송이 이어질 수 있습니다.

Impact:
- 전송 중 화면을 닫으면 `setState() called after dispose()` 또는 닫힌 화면에서 계속 전송되는 부작용이 생길 수 있습니다.

Direction:
- 모든 `await` 이후 UI 상태 갱신 전 `if (!mounted) return;`을 추가합니다.
- 긴 전송은 화면 생명주기와 분리한 service state로 관리하고 UI는 stream만 구독합니다.

### 18. 접근성/터치 타깃/글자 크기 대응이 약함

Files:
- `mesh_comm/lib/ui/home/home_screen.dart:2402`
- `mesh_comm/lib/ui/home/home_screen.dart:3108`
- `mesh_comm/lib/ui/home/home_screen.dart:5965`
- `mesh_comm/lib/ui/chat/chat_screen.dart:706`
- `mesh_comm/lib/ui/chat/group_chat_screen.dart:676`
- `mesh_comm/lib/ui/qr/qr_screen.dart:111`

Problem:
- 일부 icon/toggle/cancel control이 48x48 터치 타깃보다 작습니다.
- Settings dialog가 `TextScaler.linear(1.0)`로 시스템 글자 크기를 무시합니다.
- QR/fingerprint 영역은 고정 크기라 좁은 화면에서 overflow 가능성이 있습니다.

Impact:
- 작은 화면, 접근성 글자 크기, 스크린리더 환경에서 사용성이 떨어집니다.

Direction:
- `IconButton`, `Semantics`, `Tooltip`을 사용하고 최소 hit target을 보장합니다.
- 전체 text scale disable 대신 필요한 곳에만 layout clamp, Wrap, FittedBox, scroll을 적용합니다.
- QR 영역은 `LayoutBuilder`로 화면 폭에 맞춰 크기를 조정하고 semantic label을 추가합니다.

## Lower Priority / Design Notes

### 19. X25519 raw shared secret을 바로 AES-GCM key로 사용함

Files:
- `mesh_comm/lib/core/crypto/crypto_service.dart:113`
- `mesh_comm/lib/core/crypto/crypto_service.dart:140`

Problem:
- HKDF 없이 raw shared secret을 AES-GCM-256 key로 사용합니다.

Impact:
- 현재 동작 자체는 가능하지만, 프로토콜 분리와 context binding이 약합니다.

Direction:
- HKDF-SHA256을 사용하고 info/context에 app protocol, sender nodeId, target nodeId, msg type을 넣습니다.

### 20. Windows Creator 강제 정책은 운영 모델을 명확히 해야 함

Files:
- `mesh_comm/lib/main.dart:73`

Problem:
- Windows 실행 시 local self level을 Creator로 강제하는 정책이 있습니다.

Impact:
- "특정 관리 PC만 Creator"라는 운영 전제가 아니라면 Windows 설치가 곧 최고 권한이 됩니다.

Direction:
- 개발/테스트 편의 정책이면 build flag로 분리합니다.
- 운영 빌드는 restored identity 또는 명시적 관리자 승인 흐름으로 권한을 부여합니다.

## 추천 테스트 추가

- contact import가 nodeId-publicKey mismatch를 거부하는 테스트
- import된 trusted=true가 자동 신뢰로 저장되지 않는 테스트
- group message sender가 member가 아니면 drop되는 테스트
- group member update는 leader만 가능한 테스트
- local/server sender와 remote/server sender 모두 메시지 송수신 차단 테스트
- LAN OFF 후 connectivity event와 SCAN 후처리로 LAN이 재시작되지 않는 테스트
- BLE OFF + LAN ON 상태에서 topology scan이 동작하는 테스트
- file transfer header/chunk size/index validation 테스트
- identity backup/restore가 secure storage seed를 실제로 복원하는 테스트

## 결론

기능은 많이 올라와 있고 현재 analyze/test도 깨끗합니다. 하지만 mesh messaging 앱 특성상 "누가 누구를 신뢰하는가", "server는 정말 relay만 하는가", "전송 경로가 사용자가 켠 상태와 일치하는가"가 제품의 핵심 안전선입니다. 다음 수정은 UI polish보다 보안/권한/transport 상태 일관성을 먼저 잡는 편이 좋습니다.
