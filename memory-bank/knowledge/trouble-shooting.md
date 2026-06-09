# Trouble Shooting

> 발생했던 버그와 해결 방법. 같은 문제를 두 번 겪지 않기 위한 기록.

---

## PC BLE — Windows는 핸드폰과 사전 페어링 필요

### 증상
Windows PC에서 `flutter_blue_plus_winrt`로 BLE 스캔을 해도 Android 핸드폰이 발견되지 않거나,
발견되더라도 GATT 연결이 불안정함.

### 원인
코드 문제가 아닌 **PC 하드웨어(Bluetooth 어댑터) 수준 제약**.
Windows Bluetooth 스택은 광고를 수신하는 것과 별개로, GATT 연결 전에 OS 수준에서
기기 페어링(pairing)이 되어 있어야 안정적으로 연결되는 경우가 있음.
실험 결과 핸드폰 2대를 Windows 블루투스 설정에서 수동 페어링 후 발견 및 연결 가능 확인.

### 실무적 함의
- PC를 메시 릴레이로 쓰려면 연결할 핸드폰마다 **Windows 설정 > Bluetooth에서 수동 페어링** 선행 필요
- 재난 시나리오(낯선 사람끼리 즉시 연결)에서 PC 노드는 **진입 장벽이 높음**
- 폰↔폰 BLE는 페어링 없이 동작(Android BLE GATT는 OS 페어링 불필요) → 재난 시 폰 중심 메시가 더 현실적

### 해결 방향
- PC 노드는 "사전 등록된 거점 릴레이" 역할로 한정 (집, 사무소 등 고정 환경)
- 재난 시 즉석 메시의 핵심 노드는 Android 폰
- Windows Central-only 구조는 유지하되, PC 노드의 역할을 문서에 명확히 표시

### 검증
2026-06-07 Windows PC — Galaxy S21+, Galaxy S26 Ultra 각각 수동 페어링 후:
- PC BLE 스캔에서 핸드폰 2대 모두 발견 확인
- GATT 연결 및 메시지 교환 정상 동작

---

## Samsung phone-to-phone BLE scan returns no MeshComm devices

### Symptom
- PC can discover Android advertisements, but S21+ and S26 Ultra do not discover each other.
- `BLUETOOTH_SCAN`, `BLUETOOTH_CONNECT`, and `BLUETOOTH_ADVERTISE` are already granted.

### Cause
On the tested Samsung devices, peer BLE scan results were suppressed while location permission
or the system location service was off. Android 12+ Bluetooth permissions alone were not
sufficient in this environment.

### Fix
- Request `ACCESS_FINE_LOCATION` and `ACCESS_COARSE_LOCATION` together with Android 12+
  Bluetooth runtime permissions.
- Ensure the phone's system location service is on while testing peer discovery.

### Verification
2026-06-03 Galaxy S21+ and Galaxy S26 Ultra:
- After granting location permissions and enabling the location service, S26 discovered S21+
  and connected immediately.
- Direct phone-to-phone heartbeat and TEXT delivery succeeded.

---

## Three-node physical BLE relay verification

2026-06-03 Galaxy S21+, Galaxy S26 Ultra, and Windows PC:

| Topology | Sender -> receiver | Result |
|----------|--------------------|--------|
| S21+ <-> PC <-> S26 | S21+ -> S26 | PASS, PC relay hop=1 |
| S21+ <-> S26 | S21+ -> S26 | PASS, direct hop=0 |
| PC <-> S26 | PC -> S26 | PASS, direct hop=0 |
| S21+ <-> S26 <-> PC | S21+ -> PC | PASS, S26 relay hop=1 |
| PC <-> S21+ <-> S26 | PC -> S26 | PASS, S21+ relay hop=1 |

Relay nodes forwarded encrypted TEXT packets without saving them as local chat messages.

---

## Phase-0 저 MTU 전송과 종단 간 암호화

### 증상
- Windows Central은 `mtuNow=23`으로 동작해 큰 `MeshPacket`을 한 번에 write할 수 없음.
- Android peripheral notify를 연속 호출하면 앞선 값이 전달되기 전에 다음 값으로 교체될 수 있음.
- 공개 node ID 기반 임시 키는 릴레이 노드도 계산할 수 있어 본문 열람 차단이 되지 않음.

### 해결
- 프로토콜 v2, DB v3 마이그레이션 추가
- identity와 contact에 X25519 메시지 암호화 키 저장
- TEXT는 X25519 ECDH shared secret + AES-GCM으로 암복호화
- BLE ATT MTU에 맞춰 `MC` 조각 프레임으로 분할하고 수신 후 재조립
- Android peripheral notify는 device별 큐와 15ms 간격으로 직렬화
- 연결 시 GATT characteristic을 캐싱하여 매 전송마다 service discovery를 반복하지 않음
- `MessagingService.init()`에서 서명된 PING/PONG heartbeat 시작
- KEY 공지를 받은 이웃에게 내 KEY를 응답하되, 같은 실행 동안 node별 1회로 제한

### 검증
2026-06-02 Galaxy S21+와 Windows PC에서 확인:
- Windows MTU 23: KEY_ANNOUNCE 313 bytes를 40조각으로 전송
- Windows MTU 23: TEXT 183 bytes를 23조각으로 전송
- Windows → S21+, S21+ → Windows TEXT 양방향 복호화 성공
- 일반 빌드에서 긴 한국어 메시지 수신 성공
- 30초 간격 PING/PONG 양방향 응답 확인

물리 기기 4대를 사용하는 `A ↔ PC ↔ B ↔ C` 3홉 E2E 검증은 별도 수행한다.

---

## Windows BLE 연결 불가 — Android GATT 서버 미등록

### 증상
Windows PC와 Android 폰 사이 BLE 메시지 연결이 성립하지 않음.
Android 폰은 BLE 광고 중이지만 Windows에서 서비스 연결을 완료할 수 없음.

### 원인
기존 `flutter_ble_peripheral` 구현은 Android 광고만 송출하고,
Windows Central이 탐색하는 GATT service와 characteristic을 등록하지 않았음.

### 해결
- 광고 전용 `flutter_ble_peripheral` 제거
- `ble_peripheral: ^2.4.0` 추가
- Android에서 아래 GATT 서버 등록

```text
Service:        4a580001-b5a3-f393-e0a9-e50e24dcca9e
Characteristic: 4a580002-b5a3-f393-e0a9-e50e24dcca9e
Properties:     write + writeWithoutResponse + notify
```

- Central → Android: write request callback을 `MeshPacket` 파서로 전달
- Android → Central: `updateCharacteristic()` notify 사용
- 광고 manufacturer data에 node_id 16 bytes 포함

### 검증
2026-06-02 Galaxy S21+와 Windows PC에서 확인:
- Windows `flutter_blue_plus_winrt 0.0.20` 경로로 `MeshComm` 광고 발견
- Windows Central → S21+ GATT 연결 성공
- MTU 517 협상
- CCCD notify 구독 성공

별도 PC에서 WinRT scan 문제가 재현되면 `win_ble` 교체를 재검토한다.

---

## 반복 scan result 중복 연결

### 증상
Windows가 같은 Android 광고를 짧은 시간에 여러 번 수신하면서
동일 device ID에 `connect()`를 반복 호출함.

### 원인
연결 완료 후에만 `_connectedDevices`에 추가했기 때문에
연결 협상 중 들어온 scan result를 차단하지 못함.

### 해결
`_connectingDevices` Set을 추가하고 연결 시작부터 `finally`까지 device ID를 보관.
notify 구독 직후 발생하는 빈 `lastValueStream` 값도 무시.

---

## 연결 직후 KEY_ANNOUNCE 유실과 TEXT 실기기 검증

### 증상
앱 시작 시 `KEY_ANNOUNCE`를 보냈지만 아직 BLE 이웃이 없어 `0개 이웃`으로 끝남.
새 연결 이후 다음 5분 주기 공지 전까지 상대 공개키가 없어 TEXT 서명 검증이 불가능할 수 있음.

### 해결
- `MessagingService`가 `connectedDevicesStream`을 구독
- 새 연결 발견 시 CCCD notify 구독 완료를 고려해 3초 뒤 `KEY_ANNOUNCE` 재전송
- 홈 화면 키 아이콘으로 수동 재전송 지원
- `BleService.broadcastPacket()`이 성공한 이웃 수를 반환
- 연결된 이웃이 없으면 채팅 UI에서 전송 실패 표시

릴레이로 되돌아온 자체 패킷이 자기 연락처를 만들지 않도록
`sender_id == myNodeId` 패킷은 수신 파이프라인 초기에 drop한다.

### 재현용 진단 빌드
일반 빌드에서는 동작하지 않는다. `--dart-define`을 준 경우에만
첫 연락처 발견 1초 후 TEXT를 한 번 자동 전송한다.

```powershell
flutter build apk --debug --dart-define=MESHCOMM_DIAGNOSTIC_MESSAGE=S21_TO_WINDOWS
flutter build windows --debug --dart-define=MESHCOMM_DIAGNOSTIC_MESSAGE=WINDOWS_TO_S21
```

### 검증 결과
2026-06-02 Galaxy S21+와 Windows PC에서 확인:
- Windows → S21+: central write, AES-GCM TEXT 복호화 수신 성공
- S21+ → Windows: peripheral notify, AES-GCM TEXT 복호화 수신 성공
- 릴레이된 자체 패킷은 `DROP(자체 패킷 echo)`로 제거

---

## 이전 진단 실행 후 자기 연락처가 목록에 남음

### 증상
Windows 연락처 목록에 PC 자신과 S21+가 함께 표시됨.
PC 자신의 연락처를 열면 양방향 메시지 기록이 한 화면에 섞여 보임.

### 원인
자체 패킷 echo 차단을 추가하기 전 진단 실행에서 PC의 `KEY_ANNOUNCE`가
릴레이되어 돌아왔고, 자신의 node ID가 연락처 DB에 저장됨.

### 해결
- 수신 파이프라인에서 `sender_id == myNodeId` 패킷을 조기 drop
- 앱 시작 시 내 node ID와 동일한 오래된 연락처 레코드를 자동 삭제
- DB v2 연락처 `...` 메뉴에서 수동 삭제도 지원

2026-06-02 Windows DB 마이그레이션 후 `SELF_CONTACT_COUNT=0` 확인.

---

## Android 연락처 이름 변경 후 빨간 오류 화면

### 증상
S21+에서 연락처 이름을 변경하면 DB 저장은 성공하지만,
저장 직후 Flutter 빨간 오류 화면이 표시됨. Back으로 돌아가면 변경 이름은 반영되어 있음.

### 원인
`showDialog()` 결과를 받은 직후 `TextEditingController.dispose()`를 호출함.
Android에서는 dialog pop reverse animation 동안 `TextField`가 controller를 한 프레임 더 참조할 수 있음.

### 해결
- 이름 변경 및 Group 변경 dialog에서 외부 `TextEditingController` 제거
- `TextFormField(initialValue: ...)`와 `onChanged` closure 값 사용

### 검증
2026-06-02 S21+에서 이름을 `S21RenameFixed`로 변경:
- 홈 화면 복귀 성공
- 변경 이름 즉시 반영
- `flutter:E` 로그 0건

---

## ADB로 Android SQLite 파일을 복사할 때 PowerShell 리다이렉션 금지

### 주의
PowerShell에서 아래처럼 네이티브 stdout을 `>`로 저장하면 SQLite 바이너리가
텍스트로 변환되어 손상될 수 있다.

```powershell
adb exec-out run-as com.meshcomm.mesh_comm cat app_flutter/mesh_comm.db > mesh_comm.db
```

### 안전한 방법
앱을 중지하고 `run-as cp`로 외부 임시 위치에 복사한 뒤 `adb pull`을 사용한다.
복원은 `/data/local/tmp`에 `adb push` 후 앱 UID로 복사한다.

```powershell
adb shell am force-stop com.meshcomm.mesh_comm
adb shell run-as com.meshcomm.mesh_comm cp app_flutter/mesh_comm.db /sdcard/Download/mesh_comm.db
adb pull /sdcard/Download/mesh_comm.db
```

일반 UI 테스트에서는 DB 파일을 직접 수정하지 않는다.

---

## sqflite Windows 초기화 오류

### 증상
```
Bad state: databaseFactory not initialized
databaseFactory is only initialized when using sqflite.
```

### 원인
Windows/Linux에서 sqflite는 네이티브 SQLite 대신 FFI 초기화 필요.

### 해결
```dart
// main.dart 초기화 시
if (Platform.isWindows || Platform.isLinux) {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
}
```
패키지: `sqflite_common_ffi` 추가 필요.

---

## AndroidManifest 서비스 exported 충돌

### 증상
```
Manifest merger failed: Attribute service#BackgroundService@exported value=(false)
is also present at flutter_background_service_android value=(true)
```

### 원인
`flutter_background_service` 플러그인의 Android 매니페스트와 앱 매니페스트의 `exported` 속성 충돌.

### 해결
`AndroidManifest.xml`의 service 태그에 `tools:replace="android:exported"` 추가:
```xml
<manifest xmlns:android="..." xmlns:tools="...">
  <service
      android:name="id.flutter.flutter_background_service.BackgroundService"
      android:exported="false"
      tools:replace="android:exported"/>
```

---

## flutter_ble_peripheral Windows 빌드 오류 (C4819)

### 증상
```
error C2220: 다음 경고는 오류로 처리됩니다
warning C4819: 현재 코드 페이지(949)에서 표시할 수 없는 문자
```

### 원인
`flutter_ble_peripheral` Windows 플러그인 소스에 한글/특수문자가 포함되어
Korean Windows(코드 페이지 949)에서 MSVC 컴파일러가 경고를 오류로 처리.

### 해결
`windows/CMakeLists.txt`에 경고 억제 추가:
```cmake
if(MSVC)
  add_compile_options(/wd4819)
endif()
```

---

## 릴레이 재서명 버그 (2홉 이상 메시지 전달 불가)

### 증상
직접 연결된 1홉은 메시지 전달되나, 릴레이를 거친 2홉 이상 메시지가 서명 검증 실패로 drop됨.

### 원인
릴레이 노드가 ttl/hopCount 변경 후 자신의 개인키로 재서명.
수신 노드는 원래 발신자의 공개키로 검증 → 서명 불일치.

### 해결
`toSignableBytes()`에서 ttl/hopCount를 서명 대상에서 제외.
릴레이 시 원본 서명 유지, ttl/hopCount만 변경.
