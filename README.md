# MeshComm

MeshComm은 인터넷, 기지국, 중앙 서버 없이 주변 기기끼리 직접 연결해 메시지를 주고받는 Flutter 기반 오프라인 메신저입니다. Android 기기는 BLE peripheral/central 역할을 모두 수행하고, Windows PC는 주로 central/client 및 안정적인 릴레이 노드로 동작합니다. 같은 Wi-Fi/LAN 안에 있는 기기끼리는 LAN 경로도 사용해 더 빠르게 통신할 수 있습니다.

```text
[Phone A] -- BLE/LAN -- [Phone B] -- BLE/LAN -- [Windows PC] -- BLE/LAN -- [Phone C]
                         relay                     relay
```

직접 닿지 않는 두 사용자는 중간 노드의 릴레이를 통해 메시지를 전달할 수 있습니다. 릴레이 노드는 사용자 메시지 본문을 읽지 못하도록 1:1 메시지는 X25519 + AES-GCM으로 암호화됩니다.

## 지원 플랫폼

| 플랫폼 | 역할 |
|---|---|
| Android | BLE 광고, BLE 스캔/연결, 메시지 송수신, 릴레이 |
| Windows | BLE central/client, LAN 통신, 관리/릴레이용 UI |

주의:
- Windows는 BLE peripheral 역할을 하지 않습니다.
- Windows PC에서 Android 기기를 BLE로 안정적으로 연결하려면 Windows 설정의 Bluetooth 화면에서 해당 Android 기기를 미리 수동 페어링해야 할 수 있습니다.
- Android 기기끼리는 보통 OS 페어링 없이 앱 안에서 BLE 검색/연결합니다.

## 개발 환경 준비

필요한 도구:
- Flutter SDK
- Dart SDK, Flutter에 포함
- Android Studio 또는 Android SDK
- Windows 빌드용 Visual Studio C++ build tools
- Android 실기기 또는 Windows 실행 환경

프로젝트 구조:

| 경로 | 설명 |
|---|---|
| `mesh_comm` | Flutter 앱 |
| `memory-bank` | 설계/작업 기록 |
| `README.md` | 사용자/개발자 실행 안내 |

기본 명령어는 `mesh_comm` 폴더에서 실행합니다.

```powershell
cd mesh_comm
flutter pub get
flutter analyze
flutter test
flutter run -d windows
flutter run -d android
```

빌드:

```powershell
flutter build apk
flutter build windows
```

버전명을 명시해서 빌드하려면:

```powershell
flutter build apk --debug --dart-define=MESHCOMM_VERSION=1.5.1
flutter build windows --debug --dart-define=MESHCOMM_VERSION=1.5.1
```

### 빌드, 처음 설치, 업데이트 설치의 차이

`flutter build ...` 명령은 설치 파일을 만드는 작업입니다. 이 명령만으로 Android/Windows 앱의 DB, 연락처, identity가 지워지지는 않습니다. 실제 데이터 초기화는 보통 "설치 방식"에서 발생합니다.

| 상황 | DB/연락처/identity 유지 여부 | 설명 |
|---|---|---|
| 같은 앱을 업데이트 설치 | 유지 | 같은 package/app id와 같은 서명으로 덮어 설치하면 기존 앱 데이터가 유지됩니다. |
| Android 앱 삭제 후 재설치 | 초기화 | uninstall하면 앱 내부 DB와 secure storage가 삭제됩니다. Identity Restore가 필요합니다. |
| Android 설정에서 앱 데이터 삭제 | 초기화 | DB, 연락처, identity가 모두 사라집니다. |
| debug APK와 release APK를 섞어 설치 | 위험 | 서명이 달라 업데이트 설치가 실패하거나 삭제 후 재설치가 필요할 수 있습니다. |
| Windows 빌드 파일만 새로 실행 | 보통 유지 | 앱 데이터 경로가 같으면 DB가 유지됩니다. 단, 앱 데이터 폴더를 삭제하면 초기화됩니다. |
| package name/app id 변경 | 새 앱처럼 동작 | 기존 앱과 다른 앱으로 인식되어 기존 DB를 쓰지 못할 수 있습니다. |

Android에서 기존 앱을 먼저 지우고 새 APK를 설치하면 앱 내부 저장소에 있던 SQLite DB, 설정, identity/secure storage, 일부 권한 상태가 같이 삭제됩니다. 그래서 앱이 "처음 설치한 앱"처럼 시작합니다. Windows는 실행 파일만 새로 빌드해서 실행하는 경우가 많고 앱 데이터 폴더는 그대로 남아 있으므로 보통 리셋처럼 보이지 않습니다.

처음 설치할 때:

```text
1. 앱 설치/실행
2. Settings에서 이름과 아바타 설정
3. Identity Backup 생성
4. 연락처 Import 또는 SCAN의 + 버튼으로 연락처 등록
5. 필요하면 연락처 이름을 로컬로 변경
```

기존 사용자가 업데이트할 때:

```text
1. 업데이트 전 Identity Backup을 한 번 더 저장
2. 앱을 uninstall하지 않음
3. Android라면 같은 서명/debug-release 종류의 APK로 덮어쓰기 설치
4. Windows라면 기존 앱 데이터 폴더를 삭제하지 않음
5. 실행 후 연락처/채팅/SCAN이 유지되는지 확인
```

Android debug APK를 기존 데이터 유지 상태로 업데이트하려면 가능하면 아래처럼 `adb install -r`로 먼저 덮어쓰기 설치합니다.

```powershell
adb install -r build\app\outputs\flutter-apk\app-debug.apk
```

`flutter install`이나 IDE 설치 과정에서 Android가 덮어쓰기 설치를 거부하면 uninstall/install 흐름으로 이어질 수 있습니다. 특히 debug APK와 release APK를 섞거나, 서명이 달라졌거나, package/app id가 바뀌었거나, 설치 상태가 꼬인 경우에 이런 문제가 생길 수 있습니다. 이때 삭제 후 재설치를 선택하면 기존 DB와 연락처는 초기화됩니다.

업데이트 중 문제가 생겨 앱이 새 사용자처럼 보이면, 먼저 Settings의 Identity Restore로 백업 파일을 복원합니다. 그 다음 연락처 파일을 Import하거나 SCAN에서 다시 연락처를 등록합니다.

## 처음 실행 후 반드시 할 일

앱을 처음 실행하면 각 기기에 고유 identity가 자동 생성됩니다. 이 identity가 메시지 서명, 암호화, node ID의 기준입니다. 재설치하거나 기기를 바꾸면 identity가 달라질 수 있으므로 처음 실행 직후 백업하는 것이 중요합니다.

### 1. Settings에서 내 정보 설정

우측 상단 Settings 버튼을 열고 다음을 먼저 설정합니다.

| 항목 | 해야 할 일 |
|---|---|
| 내 이름 | 상대방에게 보일 이름 입력 |
| 아바타 | 연락처/SCAN/채팅에서 보일 아바타 선택 |
| Identity Backup | 비밀번호를 입력해 내 identity 백업 파일 저장 |

Identity Backup은 가장 중요합니다. 백업 파일과 비밀번호가 있으면 앱 재설치 후에도 같은 node ID로 복원할 수 있습니다. 백업 파일과 비밀번호를 함께 잃어버리면 기존 identity로 돌아갈 수 없습니다.

### 2. 연락처에 상대 이름 등록

메시지를 보내려면 먼저 상대를 연락처로 등록하는 것이 좋습니다. 연락처 등록 방법은 두 가지입니다.

| 방법 | 설명 |
|---|---|
| 연락처 파일 Import | 누군가에게 받은 연락처 JSON 파일을 Home의 Import에서 가져옵니다. |
| SCAN에서 등록 | 하단 SCAN 화면에서 주변 사용자를 찾고, 노드 정보의 `+` 표시로 연락처에 추가합니다. |

권장 흐름:

```text
1. 내 이름/아바타 설정
2. Identity Backup 저장
3. 상대방을 Import 또는 SCAN으로 연락처 등록
4. 연락처 이름을 알아보기 쉽게 변경
5. 채팅 시작
```

### 3. Android 권한 허용

Android에서는 BLE 검색/광고를 위해 다음 권한이 필요합니다.

| 권한/설정 | 이유 |
|---|---|
| Bluetooth 권한 | BLE 스캔, 연결, 광고 |
| 위치 권한 | 일부 Android/Samsung 환경에서 BLE 검색 결과 표시 필요 |
| 위치 서비스 ON | 기기 간 BLE discovery 안정화 |
| 알림/진동 권한 | 메시지 알림, 진동 설정 사용 |

## 주요 개념

| 개념 | 설명 |
|---|---|
| node ID | 각 기기의 공개 identity. Ed25519 public key에서 파생됩니다. |
| Identity Backup | 내 node ID와 암호화 키를 복원하기 위한 백업입니다. |
| Contact | 내가 저장한 상대 노드입니다. 이름, 아바타, 즐겨찾기, 역할 등을 로컬로 관리합니다. |
| Trust | QR/지문 확인 등으로 상대 public key를 신뢰한다고 표시하는 상태입니다. |
| Relay | 직접 연결되지 않은 대상에게 중간 노드가 패킷을 전달하는 기능입니다. |
| Server mode | 사용자가 메시지를 보내지 않고 relay만 수행하는 모드입니다. |
| SCAN | 현재 주변/릴레이 가능한 메시 네트워크를 시각화하는 화면입니다. |

## 화면과 메뉴

### 상단 시스템 메뉴

홈 화면 상단에는 transport 상태 버튼과 앱 설정/종료 버튼이 있습니다.

| 메뉴 | 할 수 있는 일 |
|---|---|
| WiFi | Wi-Fi/LAN transport 켜기/끄기 및 상태 확인 |
| BLE | BLE 스캔/광고/연결 켜기/끄기 |
| Settings | 이름, 아바타, 역할, backup/restore, demo mode 설정 |
| On/Off | 앱 종료 |

### Home

하단 Home 탭은 연락처와 그룹을 관리하는 기본 화면입니다.

왼쪽 필터/메뉴:

| 메뉴 | 설명 |
|---|---|
| 공지 | 수신한 공지 메시지 확인 |
| All | 전체 연락처 보기 |
| Group | 그룹 채팅 목록 보기 |
| 즐겨찾기 | 즐겨찾기한 연락처만 보기 |
| 채팅 | 대화 기록이 있는 연락처만 보기 |
| Import | 연락처 파일 또는 대화 파일 가져오기 |
| Export | 연락처 파일 또는 대화 파일 내보내기 |

연락처에서 할 수 있는 일:

| 동작 | 설명 |
|---|---|
| 연락처 탭 | 1:1 채팅 열기 |
| 이름 변경 | 내 기기에서 보이는 상대 이름 변경 |
| 아바타 변경 | 내 기기에서 보이는 상대 아바타 변경 |
| 즐겨찾기 | 즐겨찾기 목록에 고정 |
| 그룹 초대 | 기존 그룹 채팅에 상대 초대 |
| Level 설정 | 권한 정책에 따라 상대 level 지정 |
| 메시지 삭제 | 해당 상대와의 로컬 메시지 기록 삭제 |
| 연락처 삭제 | 연락처 목록에서 제거. 메시지 기록은 별도 정책에 따라 유지/삭제 가능 |

### 1:1 Chat

연락처를 누르면 1:1 채팅 화면이 열립니다.

전송 모드:

| 모드 | 설명 |
|---|---|
| 일반 | 기본 1:1 메시지 |
| 타임 | 수신 후 일정 시간 뒤 사라지는 메시지 |
| 파일 | 파일 선택 후 전송 |
| 이미지 | 이미지 선택 후 전송 |

주의:
- Server mode인 내 기기 또는 Server mode 연락처와는 사용자 채팅을 열지 않습니다.
- 파일/이미지는 직접 연결된 상대에게만 전송하는 것을 기본으로 합니다.
- 파일 전송은 BLE보다 LAN 경로가 있을 때 더 빠릅니다.

### Group

Home의 Group 메뉴에서 그룹 채팅을 관리합니다.

할 수 있는 일:

| 메뉴/동작 | 설명 |
|---|---|
| 그룹 만들기 | 그룹 이름을 입력하고 연락처를 초대합니다. |
| 초대 수락/거절 | 받은 그룹 초대를 처리합니다. |
| 그룹 채팅 | 그룹 멤버에게 메시지, 파일, 이미지 전송 |
| 멤버 추방 | 방장이 멤버를 그룹에서 제거 |
| 그룹 이름 변경 | 그룹 표시 이름 변경 |
| 그룹 나가기 | 그룹에서 나가기. 방장이 나가면 방장 이전 처리 |
| Backup | 그룹 목록 백업 |
| Restore | 그룹 백업 파일 복원 |

권한 주의:
- Server mode는 relay-only가 원칙이므로 그룹 메시지/초대/제어 패킷도 보내지 않는 방향이 맞습니다.
- Admin/Builder/Creator 같은 상위 권한은 단순 자기 선언이 아니라 Creator 서명 grant로 검증하는 설계가 권장됩니다.

### Search

하단 Search 탭에서는 저장된 연락처와 그룹을 빠르게 찾을 수 있습니다.

| 기능 | 설명 |
|---|---|
| 연락처 검색 | 이름 또는 node ID 일부로 연락처 찾기 |
| 그룹 검색 | 그룹 이름으로 그룹 찾기 |
| 결과 선택 | 채팅 또는 그룹 화면으로 이동 |

### SCAN

하단 SCAN 탭은 메시 네트워크를 시각화하고 주변 사용자를 연락처로 등록하는 화면입니다.

할 수 있는 일:

| 메뉴/동작 | 설명 |
|---|---|
| SCAN START | 주변 노드와 릴레이 가능한 노드를 탐색 |
| Depth | 몇 홉까지 탐색할지 설정 |
| 노드 선택 | 해당 노드의 이름, 역할, 연결 정보 확인 |
| `+` 추가 | 주변에서 찾은 사용자를 연락처에 등록 |
| Chat | 저장된 연락처와 채팅 시작 |

연락처 등록 흐름:

```text
SCAN START
-> 주변 노드 선택
-> + 버튼
-> 연락처 등록
-> 필요하면 이름/아바타 변경
```

### QR

하단 QR 탭은 public key를 직접 교환하거나 지문을 확인하는 화면입니다.

| 기능 | 설명 |
|---|---|
| 내 QR 표시 | 상대가 내 public key/contact 정보를 스캔할 수 있게 표시 |
| QR 스캔 | 상대 QR을 스캔해 연락처로 추가 |
| 지문 확인 | 상대 public key가 맞는지 직접 확인 |

QR 교환은 가까이 있는 상대를 신뢰 연락처로 등록할 때 가장 안전한 방법입니다.

### Settings

우측 상단 Settings에서 내 앱 설정을 관리합니다.

| 항목 | 설명 |
|---|---|
| 내 이름 | 상대에게 표시될 이름 |
| 아바타 | 내 프로필 이미지 |
| 역할 | User, Server 등 내 동작 level |
| 메시지 알림 | 소리, 진동, 무음 |
| 기본 SCAN depth | SCAN 시작 시 기본 탐색 깊이 |
| Demo mode | 가상 네트워크로 UI와 메시 흐름 확인 |
| Identity Backup | 내 identity를 비밀번호로 암호화해 저장 |
| Identity Restore | 백업 파일로 identity 복원 |
| 연락처 전부 지우기 | 저장된 연락처를 한 번에 삭제 |
| Delete all messages | 로컬에 저장된 모든 메시지 기록 삭제 |
| Clean stale contacts | 오래되었거나 현재 유효하지 않은 연락처 정리 |

Identity Restore 주의:
- 다른 기기에 같은 identity를 복원하면 같은 node ID를 가진 복제 기기가 됩니다.
- Creator identity를 복원하면 그 기기도 Creator가 될 수 있으므로 Creator backup 파일과 비밀번호는 특히 조심해야 합니다.

## 권한과 역할

| 역할 | 설명 |
|---|---|
| User | 일반 사용자 |
| Server | 메시지를 직접 보내지 않고 relay만 수행 |
| Admin | Creator가 부여할 수 있는 상위 역할 |
| Builder | Creator가 부여할 수 있는 상위 역할 |
| Creator | root 권한. 특정 Creator identity로만 인정하는 설계가 권장됨 |

권장 권한 설계:
- 내 PC의 Creator identity public key/node ID를 root of trust로 봅니다.
- Admin/Builder 임명은 Creator가 서명한 role grant로 증명합니다.
- node ID만 알아서는 Creator가 될 수 없습니다.
- identity backup 파일과 비밀번호가 함께 유출되면 해당 identity를 복제할 수 있으므로 주의해야 합니다.

## 보안

| 항목 | 방식 |
|---|---|
| node ID | Ed25519 public key 기반 |
| 패킷 서명 | Ed25519 |
| 1:1 메시지 암호화 | X25519 ECDH + AES-GCM |
| relay 보안 | relay 노드는 암호화된 1:1 메시지 본문을 읽지 못함 |
| Trust | QR/지문 확인 기반 TOFU |
| Identity Backup | PBKDF2-HMAC-SHA256 + AES-GCM |

long notice는 전체 사용자에게 보내는 공개 공지 성격이므로 평문 broadcast로 유지할 수 있습니다. 비밀 공지가 필요하다면 별도 암호화 설계가 필요합니다.

## 알아두면 좋은 점

- BLE 범위는 환경에 따라 크게 달라집니다.
- 같은 Wi-Fi/LAN에 있으면 LAN 경로가 BLE보다 빠를 수 있습니다.
- Android에서는 위치 서비스가 꺼져 있으면 BLE discovery가 불안정할 수 있습니다.
- Windows PC는 Android 기기와 수동 페어링이 필요할 수 있습니다.
- demo mode는 실제 DB에 demo 연락처를 쓰지 않고 UI/네트워크 형태를 확인하는 용도입니다.
- identity backup은 재설치 전 반드시 저장해두는 것이 좋습니다.

## 문제 해결

| 증상 | 확인할 것 |
|---|---|
| Android끼리 서로 안 보임 | Bluetooth 권한, 위치 권한, 위치 서비스 ON 확인 |
| Windows에서 Android가 안 보임 | Windows Bluetooth 설정에서 수동 페어링 후 재시도 |
| 메시지가 안 감 | 상대가 연락처에 등록되어 있는지, BLE/LAN 연결 상태 확인 |
| SCAN 결과가 없음 | BLE 또는 LAN이 켜져 있는지, depth 값 확인 |
| 파일 전송이 느림 | 가능하면 같은 Wi-Fi/LAN에 연결 |
| 재설치 후 다른 사람으로 보임 | Identity Restore를 하지 않았는지 확인 |

## 개발 참고 명령

```powershell
cd mesh_comm
flutter pub get
flutter analyze
flutter test
flutter run -d windows
flutter run -d android
flutter build apk
flutter build windows
```

## 프로젝트의 목표

MeshComm은 통신 인프라가 불안정하거나 완전히 끊긴 상황에서도 사람들이 가까운 기기끼리 연결되어 메시지를 전달할 수 있도록 만드는 실험적 P2P mesh communication 앱입니다. 핵심 목표는 직접 통신, 릴레이 통신, 로컬 신뢰 관리, 오프라인 identity, 그리고 중앙 서버 없는 메시 전달입니다.
