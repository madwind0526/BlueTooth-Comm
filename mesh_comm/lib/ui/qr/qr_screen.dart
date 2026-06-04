// lib/ui/qr/qr_screen.dart
//
// QR 코드 공유 화면.
// 탭 1: 내 QR 표시 (상대방이 스캔)
// 탭 2: 상대방 QR 스캔
//
// 의존성:
//   - IdentityService : getQrData(), myFingerprint, parseQrData()
//   - ContactService  : addOrUpdateContact(), confirmTrust()
//   - mobile_scanner  : ^7.2.0  (pubspec에 포함)
//   - qr_flutter      : ^4.1.0  (pubspec에 포함)

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'package:mesh_comm/features/identity/identity_service.dart';
import 'package:mesh_comm/features/contacts/contact_service.dart';

/// QR 코드 공유 화면.
///
/// 앱이 [IdentityService.init()] 완료 후 이 화면을 표시해야 한다.
class QrScreen extends StatefulWidget {
  const QrScreen({super.key});

  @override
  State<QrScreen> createState() => _QrScreenState();
}

class _QrScreenState extends State<QrScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF121212),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1E1E1E),
        foregroundColor: Colors.white,
        title: const Text('QR 코드'),
        bottom: TabBar(
          controller: _tabController,
          indicatorColor: const Color(0xFF7C6AF7),
          labelColor: const Color(0xFF7C6AF7),
          unselectedLabelColor: Colors.white54,
          tabs: const [
            Tab(text: '내 QR'),
            Tab(text: 'QR 스캔'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: const [_MyQrTab(), _ScanQrTab()],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 탭 1 — 내 QR 표시
// ─────────────────────────────────────────────────────────────────────────────

class _MyQrTab extends StatelessWidget {
  const _MyQrTab();

  @override
  Widget build(BuildContext context) {
    final identity = IdentityService();

    // IdentityService가 초기화되지 않은 경우 방어
    if (!identity.isInitialized) {
      return const Center(
        child: Text('신원 초기화 중...', style: TextStyle(color: Colors.white54)),
      );
    }

    final qrData = identity.getQrData();
    final fingerprint = identity.myFingerprint;

    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // QR 이미지
          Center(
            child: Container(
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16),
                boxShadow: [
                  BoxShadow(
                    color: const Color(0xFF7C6AF7).withValues(alpha: 0.3),
                    blurRadius: 24,
                    spreadRadius: 2,
                  ),
                ],
              ),
              padding: const EdgeInsets.all(16),
              child: QrImageView(
                data: qrData,
                version: QrVersions.auto,
                size: 220,
                eyeStyle: const QrEyeStyle(
                  eyeShape: QrEyeShape.square,
                  color: Color(0xFF121212),
                ),
                dataModuleStyle: const QrDataModuleStyle(
                  dataModuleShape: QrDataModuleShape.square,
                  color: Color(0xFF121212),
                ),
              ),
            ),
          ),

          const SizedBox(height: 28),

          // 핑거프린트
          Text(
            '내 핑거프린트',
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.5),
              fontSize: 12,
              letterSpacing: 1.2,
            ),
          ),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
            decoration: BoxDecoration(
              color: const Color(0xFF2A2A2A),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: const Color(0xFF7C6AF7).withValues(alpha: 0.4),
              ),
            ),
            child: Text(
              fingerprint,
              style: const TextStyle(
                color: Color(0xFF7C6AF7),
                fontSize: 18,
                fontWeight: FontWeight.w600,
                letterSpacing: 2,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
          ),

          const SizedBox(height: 20),

          // 안내 문구
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: const Color(0xFF1E1E1E),
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Row(
              children: [
                Icon(Icons.info_outline, color: Colors.white38, size: 18),
                SizedBox(width: 10),
                Expanded(
                  child: Text(
                    '상대방이 이 QR을 스캔하면 연락처에 추가됩니다',
                    style: TextStyle(color: Colors.white54, fontSize: 13),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 탭 2 — QR 스캔
// ─────────────────────────────────────────────────────────────────────────────

class _ScanQrTab extends StatefulWidget {
  const _ScanQrTab();

  @override
  State<_ScanQrTab> createState() => _ScanQrTabState();
}

class _ScanQrTabState extends State<_ScanQrTab> with WidgetsBindingObserver {
  final MobileScannerController _scannerController = MobileScannerController();

  /// 중복 처리 방지 플래그.
  bool _scanned = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _scannerController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 앱이 포그라운드로 복귀할 때 카메라 재시작
    if (state == AppLifecycleState.resumed) {
      _scannerController.start();
    } else if (state == AppLifecycleState.paused) {
      _scannerController.stop();
    }
  }

  // ── QR 스캔 처리 ───────────────────────────────────────────────────────────

  Future<void> _handleScannedQr(String rawValue) async {
    // 중복 처리 방지
    if (_scanned) return;
    setState(() => _scanned = true);

    await _scannerController.stop();

    final identity = IdentityService();
    final contactInfo = identity.parseQrData(rawValue);

    if (contactInfo == null) {
      _showError('올바른 MeshComm QR이 아닙니다');
      _resetScanner();
      return;
    }

    // 연락처 추가 (미확인 상태로)
    await ContactService().addOrUpdateContact(
      contactInfo.nodeId,
      contactInfo.publicKey,
      encryptionPublicKey: contactInfo.encryptionPublicKey,
      displayName: contactInfo.displayName,
      avatarKey: contactInfo.avatarKey,
      userLevel: contactInfo.userLevel,
      deviceType: contactInfo.deviceType,
      savedContact: true,
    );

    // 핑거프린트 확인 다이얼로그
    if (mounted) {
      await _showFingerprintDialog(contactInfo.nodeId, contactInfo.fingerprint);
    }
  }

  Future<void> _showFingerprintDialog(
    Uint8List nodeId,
    String fingerprint,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => _FingerprintDialog(fingerprint: fingerprint),
    );

    if (!mounted) return;

    if (confirmed == true) {
      // 신뢰 확인
      await ContactService().confirmTrust(nodeId, fingerprint);
      _showSuccess('신뢰 연락처로 등록됨');
    } else {
      _showInfo('미확인 연락처로 추가됨');
    }

    // 스캔 탭을 리셋하여 다시 스캔 가능하도록
    _resetScanner();
  }

  void _resetScanner() {
    if (!mounted) return;
    setState(() => _scanned = false);
    _scannerController.start();
  }

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: const Color(0xFFF87171),
      ),
    );
  }

  void _showSuccess(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: const Color(0xFF4ADE80),
      ),
    );
  }

  void _showInfo(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: const Color(0xFF1E1E1E),
      ),
    );
  }

  // ── 빌드 ───────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        // 카메라 뷰
        MobileScanner(
          controller: _scannerController,
          onDetect: (capture) {
            final barcode = capture.barcodes.firstOrNull;
            if (barcode != null && barcode.rawValue != null) {
              _handleScannedQr(barcode.rawValue!);
            }
          },
        ),

        // 스캔 가이드 오버레이
        _ScanOverlay(scanned: _scanned),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 스캔 가이드 오버레이
// ─────────────────────────────────────────────────────────────────────────────

class _ScanOverlay extends StatelessWidget {
  final bool scanned;

  const _ScanOverlay({required this.scanned});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // 상단 안내
        Container(
          width: double.infinity,
          color: Colors.black54,
          padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 20),
          child: Text(
            scanned ? '처리 중...' : '상대방 화면의 QR 코드를 스캔하세요',
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white, fontSize: 14),
          ),
        ),

        // 중앙 투명 영역 (카메라 뷰 노출)
        Expanded(
          child: Row(
            children: [
              Expanded(child: Container(color: Colors.black45)),
              // 가이드 박스
              Container(
                width: 240,
                height: 240,
                decoration: BoxDecoration(
                  border: Border.all(
                    color: scanned
                        ? const Color(0xFF4ADE80)
                        : const Color(0xFF7C6AF7),
                    width: 2.5,
                  ),
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              Expanded(child: Container(color: Colors.black45)),
            ],
          ),
        ),

        // 하단 안내
        Container(
          width: double.infinity,
          color: Colors.black54,
          padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 20),
          child: const Text(
            'QR 코드를 네모 안에 맞추면 자동으로 스캔됩니다',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white54, fontSize: 12),
          ),
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 핑거프린트 확인 다이얼로그
// ─────────────────────────────────────────────────────────────────────────────

class _FingerprintDialog extends StatelessWidget {
  final String fingerprint;

  const _FingerprintDialog({required this.fingerprint});

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: const Color(0xFF1E1E1E),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: const Text(
        '핑거프린트 확인',
        style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '상대방 화면의 코드와 일치하나요?',
            style: TextStyle(color: Colors.white70, fontSize: 14),
          ),
          const SizedBox(height: 16),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: const Color(0xFF2A2A2A),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: const Color(0xFF7C6AF7).withValues(alpha: 0.4),
              ),
            ),
            child: Text(
              fingerprint,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Color(0xFF7C6AF7),
                fontSize: 18,
                fontWeight: FontWeight.w600,
                letterSpacing: 2,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
          ),
          const SizedBox(height: 12),
          const Text(
            '일치하면 신뢰 연락처로, 건너뛰면 미확인으로 저장됩니다.',
            style: TextStyle(color: Colors.white38, fontSize: 12),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('건너뜀', style: TextStyle(color: Colors.white54)),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: const Color(0xFF7C6AF7),
            foregroundColor: Colors.white,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
          ),
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('확인'),
        ),
      ],
    );
  }
}
