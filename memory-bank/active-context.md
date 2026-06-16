## Latest 2026-06-14 (v1.4.5+94 — LAN race fix + PC→Android routing fix)

- **LAN simultaneous-open fix**: `lan_service.dart` `_setupSocketListener` outgoing path now uses nodeId tie-break. Lower nodeId keeps its outgoing socket (replaces the temp incoming); higher nodeId yields (discards outgoing). Prevents both sockets from being destroyed, which was causing WiFi connections to drop to 0 after SCAN and requiring manual WiFi on/off to recover.
- **PC→Android message routing fix**: `messaging_service.dart` line 1142 — guard on `_deviceToNodeHex` writes: only store when `!_lan.hasPeer(fromDeviceId)`. LAN service passes nodeIdHex as `fromDeviceId`; storing `{nodeIdHex: nodeIdHex}` corrupted `_bleDeviceIdForNode()` which iterates in insertion order and may return nodeIdHex as the BLE device ID → `BleService.sendPacket(packet, nodeIdHex)` fails silently → PC→S21/S26 messages lost.
- **Version**: v1.4.5+94 / 2026-06-14

## Latest 2026-06-14 (v1.4.4+93 — SCAN crash + DB schema + compile errors)

- BLE MTU cap at 515: prevents 514-byte frames from exceeding Android GATT 512-byte hard limit; fixes SCAN crash on connected peer devices.
- DB schema self-heal: `_onCreate` includes `expires_at`; migration order fixed; `_ensureSchema()` added.
- Compile errors: `TransferFailed` optional `meta`/`contactNodeIdHex` fields; `LanService` `tryReconnectCached()`/`tryConnectCached()` methods.
- Version downgrade fix: bumped to +93 (devices had +92).

## Current Focus

- ⏳ v1.4.5 build in progress (Android + Windows) — deploy to S21, S26, Windows PC
- 🔲 Verify SCAN no longer drops WiFi connections
- 🔲 Verify PC→S21 and PC→S26 messaging works
- 🔲 LATER: PC↔Phone file transfer "연결 경로 없음"
- 🔲 LATER: WiFi sender progress bar mismatch
