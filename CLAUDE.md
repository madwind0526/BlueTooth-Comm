# BlueTooth-Comm

> **Working directory: `C:\Claude\BlueTooth-Comm`**

## Project Vision

천재지변(홍수, 지진 등)으로 통신 인프라가 마비됐을 때, 사람들이 스마트폰만으로 서로 연결될 수 있는 **P2P BLE 메시 네트워크**.

핵심 아이디어: 각 기기가 서버 역할을 하며, BLE로 주변 기기와 직접 연결 → 릴레이 방식으로 범위 확장.

## Tech Stack

- **플랫폼**: Flutter (Dart) — Android + Windows
- **통신**: BLE 단일 계층 (`flutter_blue_plus`)
- **백그라운드**: `flutter_background_service` (Android)
- **저장소**: SQLite — `sqflite`
- **암호화**: `cryptography` (Ed25519 서명 + X25519 키교환 + AES-GCM)

## 노드 역할

| 노드 | 플랫폼 | BLE 역할 | 특징 |
|------|--------|----------|------|
| 모바일 노드 | Android | Peripheral + Central | 메시지 송수신 + 릴레이 |
| PC 노드 | Windows | Central 전용 | 항상 켜진 안정적 릴레이, 관리자 UI |

**PC 간 연결**: 직접 연결 없음. 폰 메시 네트워크를 통해서만 PC↔PC 통신.

## 빌드 & 커밋 규칙 (MANDATORY)

> **이 규칙은 반드시 지켜야 한다. 예외 없음.**

### 빌드 규칙

- **항상 Android + Windows 동시 빌드**한다. 어느 하나만 빌드하지 않는다.
- 빌드 후 **양쪽 모두 실행**한다 (Android: adb install + launch, Windows: Stop-Process + Start-Process).

### 버전 올리기 + git commit 기준

| 상황 | 버전 올리기 | git commit |
|------|-----------|-----------|
| 간단한 UI 수정 (1~2개 위젯 변경) | ❌ | ❌ |
| 버그 1~2개 수정 (로직 변경 없음) | ❌ | ❌ |
| **로직 변경** (서비스, 스트림, DB 등) | ✅ | ✅ |
| **버그 3개 이상 수정** | ✅ | ✅ |
| **새로운 기능 추가** | ✅ | ✅ |
| **여러 파일 동시 수정** | ✅ | ✅ |
| **배포 (기기에 설치)** | ✅ | ✅ |

### 버전 올리는 방법

```dart
// mesh_comm/lib/core/app_version.dart
defaultValue: '1.2.D'  →  '1.2.E'
```

```yaml
# mesh_comm/pubspec.yaml
version: 1.2.1+53  →  1.2.1+54
```

### git commit 방법

```bash
git add <변경된 파일들>   # -A 또는 . 사용 금지 — 파일명 명시
git commit -m "fix/feat: v버전 — 변경 요약"
```

### 빌드 + 배포 명령 (전체 순서)

```bash
# 1. Android 빌드
flutter build apk --dart-define=MESHCOMM_VERSION=X.X.X --dart-define=MESHCOMM_BUILD_TIME=YYYY-MM-DD

# 2. Windows 빌드
flutter build windows --dart-define=MESHCOMM_VERSION=X.X.X --dart-define=MESHCOMM_BUILD_TIME=YYYY-MM-DD

# 3. Android 배포 (S21 + S26 동시)
adb -s R3CR10WTM7P shell am force-stop com.meshcomm.mesh_comm && adb -s R3CR10WTM7P install -r build/app/outputs/flutter-apk/app-release.apk
adb -s R5KL200M0AE shell am force-stop com.meshcomm.mesh_comm && adb -s R5KL200M0AE install -r build/app/outputs/flutter-apk/app-release.apk
adb -s R3CR10WTM7P shell monkey -p com.meshcomm.mesh_comm 1
adb -s R5KL200M0AE shell monkey -p com.meshcomm.mesh_comm 1

# 4. Windows 배포
# PowerShell:
Get-Process mesh_comm -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Process "build\windows\x64\runner\Release\mesh_comm.exe"
```

## Commands

```bash
# Android 실행
flutter run -d android

# Windows 실행
flutter run -d windows

# Android APK 빌드
flutter build apk

# Windows 빌드
flutter build windows

# 패키지 설치
flutter pub get
```

## Memory Bank

| 파일 | 용도 |
|------|------|
| `memory-bank/active-context.md` | 현재 작업 포커스 |
| `memory-bank/STATE.md` | Wave 진행 상태 |
| `memory-bank/CACHE.md` | 세션 중 임시 발견사항 |
| `memory-bank/knowledge/design-document.md` | 전체 설계 명세 (Wave 1 확정) |
| `memory-bank/knowledge/RULES.md` | 설계 규칙 R-01~R-14 |
| `memory-bank/knowledge/PATTERNS.md` | 재사용 코드 패턴 |
| `memory-bank/knowledge/trouble-shooting.md` | 버그 해결 기록 |

**세션 시작 시**: `active-context.md` → `STATE.md` 순으로 읽고 현재 상태를 파악할 것.
