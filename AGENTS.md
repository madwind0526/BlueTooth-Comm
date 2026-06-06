# BlueTooth-Comm Agent Guide

## Workspace

- Root: `C:\Claude\BlueTooth-Comm`
- Flutter app: `mesh_comm`
- Memory bank: `memory-bank`

## Project Summary

MeshComm is a Flutter app for Android and Windows that explores P2P mesh messaging. The current transport is BLE, with planned LAN and Wi-Fi support. Android devices can act as BLE peripheral and central nodes; Windows currently acts as a central/client node.

Core goals:

- Direct and relayed 1:1 messaging between nodes.
- Relay-only server mode.
- Contact trust, local aliases, avatars, favorites, groups, and role levels.
- SCAN topology view with real and demo network modes.
- End-to-end message confidentiality for relay paths.

## Tech Stack

- Flutter / Dart
- Android + Windows targets
- BLE: `flutter_blue_plus`
- Local storage: SQLite via `sqflite`
- Crypto: Ed25519 signatures, X25519 ECDH, AES-GCM

## Common Commands

Run from `mesh_comm` unless noted.

```powershell
flutter pub get
flutter analyze
flutter test
flutter run -d windows
flutter run -d android
flutter build apk
flutter build windows
```

## Important Project Files

- `mesh_comm/lib/core/ble/ble_service.dart`: BLE scan/connect/send layer.
- `mesh_comm/lib/features/messaging/messaging_service.dart`: packet handling, encryption, relay, notices, topology.
- `mesh_comm/lib/features/messaging/topology_*`: SCAN request/response, graph building, demo topology.
- `mesh_comm/lib/features/contacts/*`: contacts, groups, import/export, cleanup.
- `mesh_comm/lib/features/settings/*`: app settings and persistence.
- `mesh_comm/lib/ui/home/home_screen.dart`: main UI, contacts, SCAN, settings dialog.
- `mesh_comm/lib/ui/chat/chat_screen.dart`: real chat UI.

## Working Rules

- Prefer small, focused changes that match the existing Flutter style.
- Keep demo mode in memory unless the user explicitly wants demo data written to the real DB.
- Do not make server-mode nodes send user messages; they may relay only.
- Contact level changes must be checked on both sender UI and receiver packet handling.
- Do not use destructive git commands unless the user explicitly requests them.
- After code changes, run `flutter analyze` and the relevant tests.

## Memory Bank

Start by reading these when re-orienting:

- `memory-bank/active-context.md`
- `memory-bank/STATE.md`
- `memory-bank/CACHE.md`
- `memory-bank/knowledge/design-document.md`
- `memory-bank/knowledge/RULES.md`
- `memory-bank/knowledge/PATTERNS.md`
- `memory-bank/knowledge/trouble-shooting.md`
