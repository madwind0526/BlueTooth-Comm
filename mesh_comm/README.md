# MeshComm Flutter App

This folder contains the Flutter application for MeshComm.

For the full project overview, first-run guide, app usage, menu descriptions, security notes, and troubleshooting, see the root README:

```text
../README.md
```

## Common Commands

Run these commands from this `mesh_comm` directory.

```powershell
flutter pub get
flutter analyze
flutter test
flutter run -d windows
flutter run -d android
flutter build apk
flutter build windows
```

## Notes

- Android devices can act as BLE peripheral and central nodes.
- Windows currently acts as a central/client node and may require manual Bluetooth pairing with Android devices.
- Identity backup/restore, contact setup, SCAN usage, and role/security guidance are documented in the root README.
