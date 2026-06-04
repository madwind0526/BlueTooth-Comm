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
