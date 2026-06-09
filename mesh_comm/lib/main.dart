import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:mesh_comm/core/ble/ble_service.dart';
import 'package:mesh_comm/core/diagnostics/diagnostic_config.dart';
import 'package:mesh_comm/core/storage/database_service.dart';
import 'package:mesh_comm/features/contacts/contact_service.dart';
import 'package:mesh_comm/features/identity/identity_service.dart';
import 'package:mesh_comm/features/identity/user_level.dart';
import 'package:mesh_comm/features/messaging/messaging_service.dart';
import 'package:mesh_comm/features/settings/app_settings.dart';
import 'package:mesh_comm/features/settings/app_settings_service.dart';
import 'package:mesh_comm/ui/home/home_screen.dart';

void main() {
  runZonedGuarded(
    () async {
      WidgetsFlutterBinding.ensureInitialized();

      FlutterError.onError = (details) {
        debugPrint(
          '[Flutter] onError: ${details.exception}\n${details.stack}',
        );
      };

      if (Platform.isWindows || Platform.isLinux) {
        sqfliteFfiInit();
        databaseFactory = databaseFactoryFfi;
      }

      runApp(const MeshCommApp());
    },
    (e, st) {
      debugPrint('[Zone] Uncaught error: $e\n$st');
    },
  );
}

class MeshCommApp extends StatefulWidget {
  const MeshCommApp({super.key});

  @override
  State<MeshCommApp> createState() => _MeshCommAppState();
}

class _MeshCommAppState extends State<MeshCommApp> {
  bool _initialized = false;
  String? _errorMessage;
  AppSettings _settings = const AppSettings();
  StreamSubscription<AppSettings>? _settingsSubscription;

  @override
  void initState() {
    super.initState();
    _initializeServices();
  }

  @override
  void dispose() {
    _settingsSubscription?.cancel();
    super.dispose();
  }

  Future<void> _initializeServices() async {
    try {
      DiagnosticConfig.logConfiguration();

      await DatabaseService().init();
      _settings = await AppSettingsService().load();
      if (Platform.isWindows && _settings.userLevel != UserLevel.creator) {
        _settings = _settings.copyWith(userLevel: UserLevel.creator);
        await AppSettingsService().save(_settings, notify: false);
      }
      _settingsSubscription = AppSettingsService().settingsStream.listen((
        settings,
      ) {
        if (mounted) setState(() => _settings = settings);
      });

      await IdentityService().init();
      debugPrint('[main] nodeId=${_hex(IdentityService().myNodeId)}');

      await ContactService().ensureSelfContact(
        nodeId: IdentityService().myNodeId,
        publicKey: IdentityService().myPublicKey,
        encryptionPublicKey: IdentityService().myEncryptionPublicKey,
        displayName: _settings.displayName,
        avatarKey: _settings.avatarKey,
        userLevel: _settings.userLevel,
        deviceType: IdentityService().myDeviceType,
      );

      await BleService().init(
        myNodeId: IdentityService().myNodeId,
        onPacketReceived: (packet, deviceId) {
          MessagingService()
              .handleIncomingPacket(packet, deviceId)
              .catchError((Object e, StackTrace st) {
            debugPrint('[BLE] handleIncomingPacket error: $e\n$st');
          });
        },
      );

      await MessagingService().init();

      if (!DiagnosticConfig.disableScan) {
        await BleService().startScan();
      }

      if (Platform.isAndroid && !DiagnosticConfig.disableAdvertising) {
        await BleService().startAdvertising();
      }

      if (mounted) {
        setState(() => _initialized = true);
      }
    } catch (e, stack) {
      debugPrint('[main] init error: $e\n$stack');
      if (mounted) {
        setState(() => _errorMessage = 'Init failed: $e');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'MeshComm',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF7C6AF7),
          brightness: _settings.darkMode ? Brightness.dark : Brightness.light,
        ),
        useMaterial3: true,
      ),
      home: _buildHome(),
    );
  }

  Widget _buildHome() {
    if (_errorMessage != null) {
      return Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.error_outline,
                  color: Color(0xFFF87171),
                  size: 48,
                ),
                const SizedBox(height: 16),
                Text(
                  _errorMessage!,
                  style: const TextStyle(
                    color: Color(0xFFF87171),
                    fontSize: 14,
                  ),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ),
      );
    }

    if (_initialized) {
      return const HomeScreen();
    }

    return const Scaffold(
      backgroundColor: Colors.black,
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'MeshComm',
              style: TextStyle(
                color: Color(0xFF7C6AF7),
                fontSize: 28,
                fontWeight: FontWeight.bold,
                letterSpacing: 2,
              ),
            ),
            SizedBox(height: 32),
            CircularProgressIndicator(color: Color(0xFF7C6AF7)),
          ],
        ),
      ),
    );
  }

  String _hex(List<int> bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}
