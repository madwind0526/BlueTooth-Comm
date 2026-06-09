// lib/features/identity/identity_service.dart

import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:mesh_comm/core/crypto/crypto_service.dart';
import 'package:mesh_comm/core/storage/database_service.dart';
import 'package:mesh_comm/core/packet/mesh_packet.dart';
import 'package:mesh_comm/core/packet/msg_type.dart';
import 'package:mesh_comm/features/contacts/contact_model.dart';
import 'package:mesh_comm/features/identity/user_level.dart';
import 'package:mesh_comm/features/settings/app_settings_service.dart';

/// 이 기기 자신의 신원(Ed25519 키쌍 + node_id)을 관리하는 싱글톤 서비스.
///
/// 보안 원칙 (RULES.md):
///   - R-06: node_id = SHA-256(공개키) 앞 16 bytes
///   - R-07: KEY_ANNOUNCE 패킷에 Ed25519 서명 포함
///   - R-08: TOFU — 핑거프린트를 통한 신원 확인
///
/// 사용 방법:
/// ```dart
/// await IdentityService().init();
/// print(IdentityService().myFingerprint); // "A1B2-C3D4-E5F6-G7H8"
/// ```
class IdentityService {
  // ── 싱글톤 ──────────────────────────────────────────────────────────────
  static final IdentityService _instance = IdentityService._internal();
  factory IdentityService() => _instance;
  IdentityService._internal();

  // ── 의존성 ──────────────────────────────────────────────────────────────
  final _crypto = CryptoService();
  final _db = DatabaseService();
  static const _secureStorage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );
  static const _keySigningSeed     = 'mesh_comm_signing_key';
  static const _keyEncryptionSeed  = 'mesh_comm_encryption_key';

  // ── 내부 상태 ────────────────────────────────────────────────────────────
  bool _initialized = false;

  Uint8List? _nodeId; // 16 bytes
  Uint8List? _publicKey; // 32 bytes (Ed25519 public key)
  Uint8List? _privateKey; // 32 bytes (Ed25519 seed, 메모리에만 보관)
  Uint8List? _encryptionPublicKey; // 32 bytes (X25519 public key)
  Uint8List? _encryptionPrivateKey; // 32 bytes (X25519 seed)

  // ── 초기화 ───────────────────────────────────────────────────────────────

  /// 신원 정보를 초기화한다.
  ///
  /// 1. DB에서 identity 로드 시도
  /// 2. 없으면 새 키쌍 생성 + node_id 계산 + DB 저장
  /// 3. 있으면 seed로 키쌍 복원
  ///
  /// 앱 시작 시 한 번만 호출한다 (멱등 보장).
  Future<void> init() async {
    if (_initialized) return;

    // ── 1단계: secure storage에서 개인키 seed 로드 시도 ──────────────────────
    final signingHex    = await _secureStorage.read(key: _keySigningSeed);
    final encryptionHex = await _secureStorage.read(key: _keyEncryptionSeed);

    final saved = await _db.getIdentity();

    if (signingHex != null && encryptionHex != null && saved != null) {
      // ── 정상 경로: secure storage + DB 공개키 모두 존재 ────────────────────
      _nodeId              = saved['node_id']              as Uint8List;
      _publicKey           = saved['public_key']           as Uint8List;
      _encryptionPublicKey = saved['encryption_public_key'] as Uint8List?;
      _privateKey          = _fromHex(signingHex);
      _encryptionPrivateKey = _fromHex(encryptionHex);

      // encryption 공개키 누락 시 DB에서 복원 (구형 DB 호환)
      if (_encryptionPublicKey == null) {
        final kp = await _crypto.generateEncryptionKeyPair();
        await _db.updateIdentityEncryptionKeys(kp.publicKey, kp.privateKey);
        _encryptionPublicKey = kp.publicKey;
        // 개인키는 이미 secure storage에 있으므로 덮어쓰지 않음
      }
    } else if (saved != null) {
      // ── 마이그레이션 경로: 기존 DB 평문 저장 → secure storage로 이전 ────────
      final dbPrivate    = saved['private_key']            as Uint8List;
      final dbEncPrivate = saved['encryption_private_key'] as Uint8List?;

      _nodeId              = saved['node_id']              as Uint8List;
      _publicKey           = saved['public_key']           as Uint8List;
      _encryptionPublicKey = saved['encryption_public_key'] as Uint8List?;
      _privateKey          = dbPrivate;

      // X25519 개인키가 DB에 없으면 새로 생성
      if (dbEncPrivate == null || _isZeroBytes(dbEncPrivate)) {
        final kp = await _crypto.generateEncryptionKeyPair();
        _encryptionPublicKey = kp.publicKey;
        _encryptionPrivateKey = kp.privateKey;
        await _db.updateIdentityEncryptionKeys(kp.publicKey, kp.privateKey);
      } else {
        _encryptionPrivateKey = dbEncPrivate;
      }

      // secure storage에 저장 후 DB 개인키 0으로 덮어쓰기
      if (!_isZeroBytes(dbPrivate)) {
        await _secureStorage.write(key: _keySigningSeed,    value: _toHex(_privateKey!));
        await _secureStorage.write(key: _keyEncryptionSeed, value: _toHex(_encryptionPrivateKey!));
        await _db.clearPrivateKeys();
      }
    } else {
      // ── 최초 설치: 새 키쌍 생성 ──────────────────────────────────────────
      final keyPair           = await _crypto.generateKeyPair();
      final encryptionKeyPair = await _crypto.generateEncryptionKeyPair();
      final nodeId            = _crypto.nodeIdFromPublicKey(keyPair.publicKey);

      // 공개키·node_id만 DB에 저장, 개인키는 secure storage에 저장
      final zeros32 = Uint8List(32);
      await _db.saveIdentity(
        nodeId,
        keyPair.publicKey,
        zeros32,                      // DB에는 zeros — 개인키는 secure storage에
        encryptionKeyPair.publicKey,
        zeros32,
      );
      await _secureStorage.write(key: _keySigningSeed,    value: _toHex(keyPair.privateKey));
      await _secureStorage.write(key: _keyEncryptionSeed, value: _toHex(encryptionKeyPair.privateKey));

      _nodeId               = nodeId;
      _publicKey            = keyPair.publicKey;
      _privateKey           = keyPair.privateKey;
      _encryptionPublicKey  = encryptionKeyPair.publicKey;
      _encryptionPrivateKey = encryptionKeyPair.privateKey;
    }

    _initialized = true;
  }

  static bool _isZeroBytes(Uint8List bytes) => bytes.every((b) => b == 0);

  // ── Getters ──────────────────────────────────────────────────────────────

  /// 초기화 완료 여부.
  bool get isInitialized => _initialized;

  /// 이 기기의 node_id (16 bytes).
  ///
  /// [init] 호출 전이면 StateError를 던진다.
  Uint8List get myNodeId {
    _assertInitialized();
    return _nodeId!;
  }

  /// 이 기기의 Ed25519 공개키 (32 bytes).
  ///
  /// [init] 호출 전이면 StateError를 던진다.
  Uint8List get myPublicKey {
    _assertInitialized();
    return _publicKey!;
  }

  /// 이 기기의 Ed25519 개인키 seed (32 bytes, 메모리에만 존재).
  ///
  /// 개인키는 flutter_secure_storage (Android Keystore / Windows DPAPI)에 저장된다.
  /// [init] 호출 전이면 StateError를 던진다.
  Uint8List get myPrivateKeySeed {
    _assertInitialized();
    return _privateKey!;
  }

  /// 이 기기의 X25519 메시지 암호화 공개키.
  Uint8List get myEncryptionPublicKey {
    _assertInitialized();
    return _encryptionPublicKey!;
  }

  /// 이 기기의 X25519 메시지 암호화 개인키 seed.
  Uint8List get myEncryptionPrivateKeySeed {
    _assertInitialized();
    return _encryptionPrivateKey!;
  }

  /// TOFU 확인용 핑거프린트 ("A1B2-C3D4-E5F6-G7H8" 형식).
  ///
  /// 사용자가 구두 또는 QR로 상대방과 대조한다 (R-08).
  /// [init] 호출 전이면 StateError를 던진다.
  String get myFingerprint {
    _assertInitialized();
    return _crypto.fingerprint(_publicKey!);
  }

  // ── QR 코드 ──────────────────────────────────────────────────────────────

  /// QR 코드에 담을 JSON 문자열을 반환한다.
  ///
  /// 형식:
  /// ```json
  /// {
  ///   "nodeId": "<hex 32자>",
  ///   "publicKey": "<hex 64자>",
  ///   "fingerprint": "A1B2-C3D4-E5F6-G7H8"
  /// }
  /// ```
  ///
  /// [init] 호출 전이면 StateError를 던진다.
  String getQrData() {
    _assertInitialized();
    final settings = AppSettingsService().current;
    final map = {
      'nodeId': _toHex(_nodeId!),
      'publicKey': _toHex(_publicKey!),
      'encryptionPublicKey': _toHex(_encryptionPublicKey!),
      'deviceType': myDeviceType.wireName,
      'displayName': settings.displayName,
      'avatarKey': settings.avatarKey,
      'userLevel': settings.userLevel.wireName,
      'protocolVersion': MeshPacket.currentProtocolVersion,
      'fingerprint': myFingerprint,
    };
    return jsonEncode(map);
  }

  /// 상대방 QR 코드 문자열을 파싱하여 [ContactInfo]를 반환한다.
  ///
  /// 파싱 실패 시 (잘못된 JSON, 필드 누락, 길이 불일치 등) null을 반환한다.
  ContactInfo? parseQrData(String qrString) {
    try {
      final map = jsonDecode(qrString) as Map<String, dynamic>;

      final nodeIdHex = map['nodeId'] as String?;
      final publicKeyHex = map['publicKey'] as String?;
      final encryptionPublicKeyHex = map['encryptionPublicKey'] as String?;
      final deviceType = MeshDeviceType.fromWire(map['deviceType'] as String?);
      final displayName = _cleanText(map['displayName'] as String?);
      final avatarKey = _cleanText(map['avatarKey'] as String?);
      final userLevel = UserLevel.fromWire(map['userLevel'] as String?);
      final protocolVersion = map['protocolVersion'] as int?;
      final fingerprint = map['fingerprint'] as String?;

      if (nodeIdHex == null ||
          publicKeyHex == null ||
          encryptionPublicKeyHex == null ||
          protocolVersion != MeshPacket.currentProtocolVersion ||
          fingerprint == null) {
        return null;
      }

      final nodeId = _fromHex(nodeIdHex);
      final publicKey = _fromHex(publicKeyHex);
      final encryptionPublicKey = _fromHex(encryptionPublicKeyHex);

      // 기본 길이 검증
      if (nodeId.length != 16 ||
          publicKey.length != 32 ||
          encryptionPublicKey.length != 32) {
        return null;
      }

      // 공개키로부터 node_id 검증 (위조 방지 — R-06)
      final expectedNodeId = _crypto.nodeIdFromPublicKey(publicKey);
      for (var i = 0; i < 16; i++) {
        if (nodeId[i] != expectedNodeId[i]) return null;
      }

      return ContactInfo(
        nodeId: nodeId,
        publicKey: publicKey,
        encryptionPublicKey: encryptionPublicKey,
        deviceType: deviceType,
        displayName: displayName,
        avatarKey: avatarKey,
        userLevel: userLevel,
        protocolVersion: protocolVersion!,
        fingerprint: fingerprint,
      );
    } catch (_) {
      return null;
    }
  }

  // ── KEY_ANNOUNCE 패킷 ─────────────────────────────────────────────────────

  /// 자신의 공개키를 브로드캐스트하는 KEY_ANNOUNCE 패킷을 생성한다.
  ///
  /// payload JSON: `{"publicKey": "<hex>"}`
  /// 생성된 패킷에 Ed25519 서명이 포함된다 (R-07).
  ///
  /// [init] 호출 전이면 StateError를 던진다.
  Future<MeshPacket> createKeyAnnouncePacket() async {
    _assertInitialized();
    final settings = AppSettingsService().current;

    final payloadJson = jsonEncode({
      'protocolVersion': MeshPacket.currentProtocolVersion,
      'publicKey': _toHex(_publicKey!),
      'encryptionPublicKey': _toHex(_encryptionPublicKey!),
      'deviceType': myDeviceType.wireName,
      'displayName': settings.displayName,
      'avatarKey': settings.avatarKey,
      'userLevel': settings.userLevel.wireName,
    });
    final payloadBytes = Uint8List.fromList(utf8.encode(payloadJson));

    final packet = MeshPacket.create(
      senderId: _nodeId!,
      targetId: MeshPacket.broadcast,
      msgType: MsgType.keyAnnounce,
      payload: payloadBytes,
    );

    // Ed25519 서명 (R-07: 모든 패킷 서명 필수)
    final signableBytes = packet.toSignableBytes();
    final signature = await _crypto.sign(signableBytes, _privateKey!);
    packet.signature = signature;

    return packet;
  }

  /// 수신한 KEY_ANNOUNCE 패킷에서 발신자의 [ContactInfo]를 추출한다.
  ///
  /// 파싱 실패 또는 서명 검증 실패 시 null을 반환한다.
  /// 서명 검증 실패 패킷은 즉시 폐기한다 (R-07).
  ContactInfo? parseKeyAnnouncePacket(MeshPacket packet) {
    try {
      if (packet.msgType != MsgType.keyAnnounce) return null;

      final payloadJson = utf8.decode(packet.payload);
      final map = jsonDecode(payloadJson) as Map<String, dynamic>;

      final publicKeyHex = map['publicKey'] as String?;
      final encryptionPublicKeyHex = map['encryptionPublicKey'] as String?;
      final deviceType = MeshDeviceType.fromWire(map['deviceType'] as String?);
      final displayName = _cleanText(map['displayName'] as String?);
      final avatarKey = _cleanText(map['avatarKey'] as String?);
      final userLevel = UserLevel.fromWire(map['userLevel'] as String?);
      final protocolVersion = map['protocolVersion'] as int?;
      if (publicKeyHex == null ||
          encryptionPublicKeyHex == null ||
          protocolVersion != MeshPacket.currentProtocolVersion) {
        return null;
      }

      final publicKey = _fromHex(publicKeyHex);
      final encryptionPublicKey = _fromHex(encryptionPublicKeyHex);
      if (publicKey.length != 32 || encryptionPublicKey.length != 32) {
        return null;
      }

      // node_id 검증 — 발신자가 공개키 해시로부터 만든 node_id와 일치해야 함 (R-06)
      final expectedNodeId = _crypto.nodeIdFromPublicKey(publicKey);
      for (var i = 0; i < 16; i++) {
        if (packet.senderId[i] != expectedNodeId[i]) return null;
      }

      // 주의: 서명 검증은 async이므로 여기서 직접 수행 불가.
      // 호출자(BLE 수신 레이어)가 verifyPacketSignature()로 선검증 후 이 메서드를 호출해야 한다.
      // 이 메서드는 파싱만 담당하며, 서명이 이미 검증되었다고 가정한다.

      final fingerprint = _crypto.fingerprint(publicKey);

      return ContactInfo(
        nodeId: Uint8List.fromList(packet.senderId),
        publicKey: publicKey,
        encryptionPublicKey: encryptionPublicKey,
        deviceType: deviceType,
        displayName: displayName,
        avatarKey: avatarKey,
        userLevel: userLevel,
        protocolVersion: protocolVersion!,
        fingerprint: fingerprint,
      );
    } catch (_) {
      return null;
    }
  }

  /// KEY_ANNOUNCE 패킷의 Ed25519 서명을 검증한다.
  ///
  /// BLE 수신 레이어에서 [parseKeyAnnouncePacket] 호출 전에 먼저 실행해야 한다.
  /// 검증 실패 시 false — 패킷을 즉시 폐기하고 릴레이하지 않는다 (R-07).
  Future<bool> verifyPacketSignature(
    MeshPacket packet,
    Uint8List senderPublicKey,
  ) async {
    final signableBytes = packet.toSignableBytes();
    return _crypto.verify(signableBytes, packet.signature, senderPublicKey);
  }

  // ── 내부 유틸리티 ─────────────────────────────────────────────────────────

  void _assertInitialized() {
    if (!_initialized) {
      throw StateError('IdentityService.init() 를 먼저 호출하세요.');
    }
  }

  MeshDeviceType get myDeviceType {
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      return MeshDeviceType.pc;
    }
    if (Platform.isAndroid || Platform.isIOS) {
      return MeshDeviceType.phone;
    }
    return MeshDeviceType.unknown;
  }

  /// Uint8List → 소문자 hex 문자열.
  static String _toHex(Uint8List bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  /// 소문자 hex 문자열 → Uint8List.
  ///
  /// 길이가 홀수이거나 유효하지 않은 hex이면 FormatException을 던진다.
  static Uint8List _fromHex(String hex) {
    if (hex.length.isOdd) throw const FormatException('홀수 hex 길이');
    return Uint8List.fromList([
      for (var i = 0; i < hex.length; i += 2)
        int.parse(hex.substring(i, i + 2), radix: 16),
    ]);
  }

  static String? _cleanText(String? value) {
    final trimmed = value?.trim();
    return trimmed == null || trimmed.isEmpty ? null : trimmed;
  }
}

// ── ContactInfo ────────────────────────────────────────────────────────────

/// 상대방의 신원 정보.
///
/// QR 스캔 또는 KEY_ANNOUNCE 수신 시 생성된다.
/// TOFU 확인 후 DatabaseService.upsertContact()를 통해 연락처로 등록된다 (R-08).
class ContactInfo {
  /// 상대방 node_id (16 bytes, SHA-256(공개키) 앞 16 bytes).
  final Uint8List nodeId;

  /// 상대방 Ed25519 공개키 (32 bytes).
  final Uint8List publicKey;

  /// 상대방 X25519 메시지 암호화 공개키 (32 bytes).
  final Uint8List encryptionPublicKey;

  final MeshDeviceType deviceType;
  final String? displayName;
  final String? avatarKey;
  final UserLevel userLevel;

  /// 상대방이 사용하는 패킷 프로토콜 버전.
  final int protocolVersion;

  /// TOFU 확인용 핑거프린트 ("A1B2-C3D4-E5F6-G7H8" 형식).
  final String fingerprint;

  const ContactInfo({
    required this.nodeId,
    required this.publicKey,
    required this.encryptionPublicKey,
    required this.deviceType,
    this.displayName,
    this.avatarKey,
    this.userLevel = UserLevel.user,
    required this.protocolVersion,
    required this.fingerprint,
  });

  @override
  String toString() =>
      'ContactInfo(nodeId=${nodeId.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}, '
      'fingerprint=$fingerprint)';
}
