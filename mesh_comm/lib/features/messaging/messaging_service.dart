// lib/features/messaging/messaging_service.dart

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:mesh_comm/core/ble/ble_service.dart';
import 'package:mesh_comm/core/crypto/crypto_service.dart';
import 'package:mesh_comm/core/diagnostics/diagnostic_config.dart';
import 'package:mesh_comm/core/lan/lan_service.dart';
import 'package:mesh_comm/core/packet/mesh_packet.dart';
import 'package:mesh_comm/core/packet/msg_type.dart';
import 'package:mesh_comm/core/storage/database_service.dart';
import 'package:mesh_comm/features/contacts/contact_model.dart';
import 'package:mesh_comm/features/contacts/contact_service.dart';
import 'package:mesh_comm/features/identity/identity_service.dart';
import 'package:mesh_comm/features/identity/user_level.dart';
import 'package:mesh_comm/features/settings/app_settings_service.dart';
import 'package:mesh_comm/features/transfer/transfer_model.dart';
import 'package:mesh_comm/features/transfer/transfer_service.dart';
import 'package:mesh_comm/features/transfer/transfer_storage_service.dart';

import 'package:mesh_comm/features/groups/group_messaging_service.dart';

import 'message_policy.dart';
import 'topology_message.dart';

// ── ReceivedMessage ────────────────────────────────────────────────────────────

/// 수신된 1:1 텍스트 메시지 (복호화 완료 상태).
class ReceivedMessage {
  /// 패킷의 고유 ID (16 bytes).
  final Uint8List msgId;

  /// 발신자 node_id (16 bytes, SHA-256(publicKey) 앞 16 bytes).
  final Uint8List senderNodeId;

  /// 복호화된 텍스트 본문.
  final String text;

  /// 발신 Unix timestamp (밀리초).
  final int timestamp;

  /// 발신자가 신뢰 연락처(TOFU 확인 완료)인지 여부 (R-08).
  final bool isTrusted;

  /// 자신이 보낸 메시지 여부 (true = 발신, false = 수신).
  final bool isOutgoing;

  /// 채팅 화면에 표시된 뒤 이 시간 후 삭제된다. null이면 자동 삭제 없음.
  final int? readTtlMs;

  /// 공지 메시지 여부 (shortNotice 또는 longNotice).
  final bool isNotice;

  const ReceivedMessage({
    required this.msgId,
    required this.senderNodeId,
    required this.text,
    required this.timestamp,
    required this.isTrusted,
    this.isOutgoing = false,
    this.readTtlMs,
    this.isNotice = false,
  });

  @override
  String toString() {
    final senderHex = senderNodeId
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    return 'ReceivedMessage(sender=$senderHex, ts=$timestamp, '
        'trusted=$isTrusted, outgoing=$isOutgoing, text="$text")';
  }
}

// ── MessagingService ───────────────────────────────────────────────────────────

/// 1:1 텍스트 메시지 송수신 + 메시 릴레이 서비스 (싱글톤).
///
/// ## 책임
/// - 수신 패킷 처리 파이프라인 (중복 제거 → 서명 검증 → 유형별 처리 → 릴레이)
/// - TEXT 패킷 암호화 전송
/// - KEY_ANNOUNCE 주기 브로드캐스트 (R-10)
/// - seen_messages 캐시 주기 정리 (R-09)
/// - 수신 메시지 Stream 제공
///
/// ## 초기화 순서
/// ```dart
/// await DatabaseService().init();
/// await IdentityService().init();
/// await BleService().init(myNodeId: ..., onPacketReceived: ...);
/// await MessagingService().init();
/// ```
class GroupSendResult {
  final int attempted;
  final int sent;
  final int skipped;
  final String? blockedReason;

  const GroupSendResult({
    required this.attempted,
    required this.sent,
    required this.skipped,
    this.blockedReason,
  });

  const GroupSendResult.blocked(String reason)
    : attempted = 0,
      sent = 0,
      skipped = 0,
      blockedReason = reason;

  bool get sentAny => sent > 0;
}

class _DecodedTextPayload {
  final String text;
  final int? ttlMs;
  final bool isNotice;

  const _DecodedTextPayload({required this.text, this.ttlMs, this.isNotice = false});
}

class MessagingService {
  // ── 싱글톤 ──────────────────────────────────────────────────────────────────
  static final MessagingService _instance = MessagingService._internal();
  factory MessagingService() => _instance;
  MessagingService._internal();

  // ── 의존성 ──────────────────────────────────────────────────────────────────
  final _ble = BleService();
  final _lan = LanService();
  final _transfer = TransferService();
  final _crypto = CryptoService();
  final _db = DatabaseService();
  final _identity = IdentityService();
  final _contacts = ContactService();

  // ── 내부 상태 ────────────────────────────────────────────────────────────────
  bool _initialized = false;

  // KEY_ANNOUNCE 재전송 타이머 (R-10: 5분 주기)
  Timer? _keyAnnounceTimer;
  Timer? _connectionAnnounceTimer;
  Timer? _lanKeepaliveTimer;
  DateTime? _lastKeyAnnounceAt;
  Future<void>? _keyAnnounceInFlight;
  final Set<String> _keyAnnounceRespondedNodeIds = {};
  final Map<String, int> _topologyRequestsHandledAt = {};
  StreamSubscription<List<String>>? _connectionSubscription;
  StreamSubscription<List<String>>? _lanConnectionSubscription;
  Set<String> _knownBleDeviceIds = {};
  Set<String> _knownLanPeerIds = {};

  // BLE deviceId → nodeId hex (직접 연결된 이웃 추적)
  final Map<String, String> _deviceToNodeHex = {};
  final Map<String, int> _lanRetryAfterMs = {};
  final Set<String> _processingMessageIds = {};

  // seen_messages 정리 타이머 (R-09: 30분 주기)
  Timer? _cleanSeenTimer;

  // 컴파일 타임 진단 메시지. 일반 빌드에서는 빈 문자열이므로 동작하지 않는다.
  static const _diagnosticMessage = String.fromEnvironment(
    'MESHCOMM_DIAGNOSTIC_MESSAGE',
  );
  Timer? _diagnosticMessageTimer;
  bool _diagnosticMessageSent = false;

  // 수신 메시지 Stream 컨트롤러
  final StreamController<ReceivedMessage> _messageStreamController =
      StreamController<ReceivedMessage>.broadcast();
  final StreamController<TopologyResponse> _topologyStreamController =
      StreamController<TopologyResponse>.broadcast();

  // ── 공개 Stream ─────────────────────────────────────────────────────────────

  /// 새 수신 TEXT 메시지가 도착할 때마다 emit된다 (복호화 완료 상태).
  Stream<ReceivedMessage> get messageStream => _messageStreamController.stream;

  /// SCAN topology responses from reachable nodes.
  Stream<TopologyResponse> get topologyStream =>
      _topologyStreamController.stream;

  /// 현재 연결된 LAN 피어 수.
  int get lanConnectedCount => _lan.connectedCount;

  /// LAN 피어 목록 변경 스트림 (UI 업데이트용).
  Stream<List<String>> get lanPeersStream => _lan.connectedPeersStream;

  Future<void> startLan() => _lan.start();
  Future<void> stopLan() => _lan.stop();

  /// [nodeIdHex]가 직접 BLE 또는 LAN으로 연결된 이웃인지 확인한다.
  bool isDirectlyConnected(String nodeIdHex) =>
      _deviceToNodeHex.values.contains(nodeIdHex) || _lan.hasPeer(nodeIdHex);

  /// 파일/이미지 전송 이벤트 스트림.
  Stream<TransferEvent> get transferStream => _transfer.transferStream;

  // ── 초기화 ───────────────────────────────────────────────────────────────────

  /// MessagingService를 초기화한다.
  ///
  /// - [BleService.init]의 onPacketReceived 콜백을 [_handleIncomingPacket]으로 설정한다.
  /// - KEY_ANNOUNCE 즉시 브로드캐스트 후 5분 주기 타이머 시작 (R-10).
  /// - seen_messages 정리 타이머 시작 (R-09, 30분 주기).
  ///
  /// 멱등(idempotent): 이미 초기화된 경우 즉시 반환.
  Future<void> init() async {
    if (_initialized) return;

    // BleService onPacketReceived 콜백 재등록
    // BleService.init()에서 이미 myNodeId를 설정했으므로,
    // 콜백만 교체하기 위해 내부 필드를 직접 접근하지 않고
    // init()을 다시 호출한다 (멱등 보장 — BleService.init이 이미 초기화된 경우 return).
    // 대신 BleService는 _onPacketReceived 필드를 노출하지 않으므로,
    // 패킷 수신은 BleService.init()의 onPacketReceived 매개변수로 최초에 등록해야 한다.
    //
    // MessagingService는 앱 시작 시 BleService.init()의 onPacketReceived에
    // _handleIncomingPacket을 전달하는 방식으로 연결된다.
    // 호출 순서 예시:
    //   await BleService().init(
    //     myNodeId: identity.myNodeId,
    //     onPacketReceived: MessagingService()._handleIncomingPacket,
    //   );
    //   await MessagingService().init();
    //
    // 단, 편의를 위해 init() 내부에서 BleService.init()을 재호출할 수도 있다.
    // BleService.init()은 이미 초기화된 경우 즉시 반환(멱등)하지만,
    // _onPacketReceived는 다시 설정해야 하는 문제가 있다.
    // 따라서 이 서비스의 init()은 BleService가 이미 초기화된 상태에서 호출됨을 전제한다.
    // 콜백 주입은 앱 부트스트랩 레이어의 책임이다.

    _initialized = true;

    _connectionSubscription = _ble.connectedDevicesStream.listen(
      _handleConnectedDevices,
    );
    _ble.startHeartbeat(_createPingPacket);

    // LAN 서비스 초기화 및 피어 변경 구독
    await _lan.init(
      myNodeId: _identity.myNodeId,
      onPacketReceived: (packet, peerId) {
        handleIncomingPacket(packet, peerId).catchError(
          (Object e, StackTrace st) {
            debugPrint('[LAN] handleIncomingPacket error: $e\n$st');
          },
        );
      },
    );
    _lanConnectionSubscription = _lan.connectedPeersStream.listen((peerIds) {
      final current = peerIds.toSet();
      final hasNew = current.difference(_knownLanPeerIds).isNotEmpty;
      for (final peerId in current) {
        _lanRetryAfterMs.remove(peerId);
      }
      _knownLanPeerIds = current;
      if (hasNew) {
        // 새 LAN 피어가 연결되면 즉시 키를 알린다.
        // 수신 측에서 아직 등록하지 않은 소켓을 첫 패킷으로 깨운다.
        unawaited(broadcastKeyAnnounce());
      }
    });

    // LAN TCP 연결 keepalive (30초마다 keyAnnounce 전송)
    _lanKeepaliveTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (_lan.connectedCount > 0) {
        unawaited(broadcastKeyAnnounce());
      }
    });

    // TransferService 초기화
    _transfer.init(sendPacket: _sendPacketToNodeId);

    // 전송 완료 시 자동으로 로컬에 파일 저장 (채팅창 열려있지 않아도 보존)
    // 그룹 전송(groupId != null)은 1:1 채팅 저장소를 오염시키지 않도록 제외.
    _transfer.transferStream.listen((event) {
      if (event is TransferCompleted && event.meta.groupId == null) {
        unawaited(_saveTransferFile(event));
      }
    });

    // GroupMessagingService에 전송 함수 주입
    GroupMessagingService().setSendFunction(sendGroupControlPacket);

    // KEY_ANNOUNCE 즉시 브로드캐스트 (R-10)
    await broadcastKeyAnnounce(force: true);

    // KEY_ANNOUNCE 5분 주기 재전송 (R-10)
    _keyAnnounceTimer = Timer.periodic(const Duration(minutes: 5), (_) async {
      await broadcastKeyAnnounce(force: true);
    });

    await _db.deleteExpiredMessages();
    await _db.deleteExpiredGroupMessages();

    // seen_messages 30분 주기 정리 (R-09)
    _cleanSeenTimer = Timer.periodic(const Duration(minutes: 30), (_) async {
      try {
        await _db.deleteExpiredMessages();
        await _db.deleteExpiredGroupMessages();
        await _db.cleanOldSeenMessages();
        _log('seen_messages 정리 완료');
      } catch (e) {
        _log('cleanOldSeenMessages 오류: $e');
      }
    });

    _log('MessagingService 초기화 완료');
  }

  void _handleConnectedDevices(List<String> deviceIds) {
    final currentDeviceIds = deviceIds.toSet();
    final hasNewDevice = currentDeviceIds.difference(_knownBleDeviceIds).isNotEmpty;
    final disconnected = _knownBleDeviceIds.difference(currentDeviceIds);
    _knownBleDeviceIds = currentDeviceIds;

    for (final deviceId in disconnected) {
      _deviceToNodeHex.remove(deviceId);
    }

    if (!hasNewDevice) return;

    // Android peripheral 연결 콜백은 central의 CCCD 구독 완료보다 먼저 올 수 있다.
    // notify 경로가 준비된 뒤 키를 다시 알려 새 이웃을 바로 연락처로 등록한다.
    _connectionAnnounceTimer?.cancel();
    _connectionAnnounceTimer = Timer(const Duration(seconds: 3), () async {
      await broadcastKeyAnnounce();
    });
  }

  // ── 1:1 텍스트 메시지 전송 ───────────────────────────────────────────────────

  /// 상대방에게 암호화된 1:1 텍스트 메시지를 전송한다.
  ///
  /// ## 처리 흐름
  /// 1. sharedSecret으로 payload AES-GCM 암호화
  /// 2. [MeshPacket.create]로 패킷 생성
  /// 3. Ed25519 서명 (R-07)
  /// 4. DB에 발신 메시지 저장 (복호화된 text 보존)
  /// 5. [BleService.broadcastPacket]으로 전송
  ///
  /// 반환값: 전송 성공 여부.
  Future<bool> sendTextMessage({
    required Uint8List targetNodeId,
    required String text,
    MessageSendMode mode = MessageSendMode.normal,
  }) async {
    try {
      final settings = AppSettingsService().current;
      if (!settings.userLevel.canSendMessages) {
        _log('TEXT send blocked: server level only relays messages.');
        return false;
      }
      final trimmedText = text.trim();
      if (trimmedText.isEmpty || trimmedText.length > mode.maxLength) {
        return false;
      }
      if (mode.isNotice) {
        return _sendNoticeMessage(text: trimmedText, mode: mode);
      }
      if (_bytesEqual(targetNodeId, _identity.myNodeId)) {
        return _sendSelfTextMessage(text: trimmedText, mode: mode);
      }

      // 1. 최종 수신자와만 공유하는 X25519 비밀키로 payload 암호화.
      // 릴레이 노드는 패킷을 전달하지만 본문을 복호화할 수 없다.
      final targetEncryptionPublicKey = await _contacts.getEncryptionPublicKey(
        targetNodeId,
      );
      if (targetEncryptionPublicKey == null) {
        _log('TEXT 전송 실패: 상대방 메시지 암호화 키가 없습니다.');
        return false;
      }
      final sharedSecret = await _crypto.computeSharedSecret(
        _identity.myEncryptionPrivateKeySeed,
        targetEncryptionPublicKey,
      );

      final plaintext = _encodeTextPayload(trimmedText, mode);
      final encryptedPayload = await _crypto.encrypt(plaintext, sharedSecret);

      // 2. 패킷 생성
      final packet = MeshPacket.create(
        senderId: _identity.myNodeId,
        targetId: targetNodeId,
        msgType: MsgType.text,
        payload: encryptedPayload,
      );

      // 3. Ed25519 서명 (R-07)
      final signableBytes = packet.toSignableBytes();
      final signature = await _crypto.sign(
        signableBytes,
        _identity.myPrivateKeySeed,
      );
      packet.signature = signature;

      // 4. 브로드캐스트 전송
      final recipientCount = await _sendPacketToNodeIdCount(
        packet,
        _hex(targetNodeId),
      );
      if (recipientCount == 0) {
        _log('TEXT 전송 실패: 연결된 BLE 이웃이 없습니다.');
        return false;
      }

      // 5. DB에 발신 메시지 저장 (복호화된 UTF-8 bytes 보존)
      await _db.saveMessage(
        msgId: packet.msgId,
        senderId: _identity.myNodeId,
        targetId: targetNodeId,
        msgType: MsgType.text.value,
        timestamp: packet.timestamp,
        payload: plaintext, // 평문 저장 (자신이 보낸 메시지는 복호화 불필요)
        isOutgoing: true,
        expiresAt: _expiresAtForLocalDisplay(mode),
      );

      _log(
        'TEXT 전송: ${_hexShort(targetNodeId)} '
        'mode=$mode "${_truncate(trimmedText, 30)}"',
      );
      return true;
    } catch (e) {
      _log('sendTextMessage 오류: $e');
      return false;
    }
  }

  // ── KEY_ANNOUNCE 브로드캐스트 ────────────────────────────────────────────────

  /// 자신의 공개키를 담은 KEY_ANNOUNCE 패킷을 브로드캐스트한다 (R-10).
  ///
  /// [IdentityService.createKeyAnnouncePacket]으로 생성 후 서명 포함.
  Future<GroupSendResult> sendGroupTextMessage({
    required Iterable<Contact> recipients,
    required String text,
    MessageSendMode mode = MessageSendMode.normal,
  }) async {
    try {
      final settings = AppSettingsService().current;
      if (!settings.userLevel.canSendMessages) {
        return const GroupSendResult.blocked(
          'Server mode only relays messages.',
        );
      }
      final trimmedText = text.trim();
      if (trimmedText.isEmpty) {
        return const GroupSendResult.blocked('Message is empty.');
      }
      if (trimmedText.length > mode.maxLength) {
        return const GroupSendResult.blocked('Message is too long.');
      }

      if (mode.isNotice) {
        final sent = await _sendNoticeMessage(text: trimmedText, mode: mode);
        return GroupSendResult(
          attempted: sent ? 1 : 0,
          sent: sent ? 1 : 0,
          skipped: 0,
          blockedReason: sent ? null : 'Notice could not be sent.',
        );
      }

      final seenNodeIds = <String>{};
      var attempted = 0;
      var sent = 0;
      var skipped = 0;

      for (final contact in recipients) {
        if (!seenNodeIds.add(_hex(contact.nodeId))) {
          continue;
        }
        if (_bytesEqual(contact.nodeId, _identity.myNodeId) ||
            !contact.userLevel.canSendMessages ||
            contact.encryptionPublicKey == null) {
          skipped++;
          continue;
        }

        attempted++;
        final ok = await _sendEncryptedTextPacket(
          targetNodeId: contact.nodeId,
          text: trimmedText,
          mode: mode,
        );
        if (ok) {
          sent++;
        }
      }

      return GroupSendResult(
        attempted: attempted,
        sent: sent,
        skipped: skipped,
        blockedReason: sent == 0
            ? 'No group recipients could be reached.'
            : null,
      );
    } catch (e) {
      _log('sendGroupTextMessage error: $e');
      return GroupSendResult.blocked('Group send failed: $e');
    }
  }

  Future<bool> _sendSelfTextMessage({
    required String text,
    required MessageSendMode mode,
  }) async {
    final msgId = MeshPacket.generateMsgId();
    await _db.saveMessage(
      msgId: msgId,
      senderId: _identity.myNodeId,
      targetId: _identity.myNodeId,
      msgType: MsgType.text.value,
      timestamp: DateTime.now().millisecondsSinceEpoch,
      payload: _encodeTextPayload(text, mode),
      isOutgoing: true,
      expiresAt: _expiresAtForLocalDisplay(mode),
    );
    _log('SELF TEXT 저장: mode=$mode "${_truncate(text, 30)}"');
    return true;
  }

  Future<bool> _sendNoticeMessage({
    required String text,
    required MessageSendMode mode,
  }) async {
    final settingsService = AppSettingsService();
    final settings = settingsService.current;
    final cooldown = settings.userLevel.noticeCooldown(mode);
    if (cooldown == null) {
      _log('NOTICE send blocked: server level only relays messages.');
      return false;
    }
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final lastUsedMs = mode == MessageSendMode.shortNotice
        ? settings.lastShortNoticeAt
        : settings.lastLongNoticeAt;

    if (cooldown > Duration.zero &&
        lastUsedMs > 0 &&
        nowMs - lastUsedMs < cooldown.inMilliseconds) {
      _log('NOTICE 전송 실패: 하루 1회 제한 mode=$mode');
      return false;
    }

    final sent = mode == MessageSendMode.shortNotice
        ? await _sendShortNoticeToContacts(text)
        : await _sendLongNoticeBroadcast(text, mode);

    if (!sent) return false;

    if (cooldown > Duration.zero) {
      final nextSettings = mode == MessageSendMode.shortNotice
          ? settings.copyWith(lastShortNoticeAt: nowMs)
          : settings.copyWith(lastLongNoticeAt: nowMs);
      await settingsService.save(nextSettings, notify: false);
    }

    _log('NOTICE 전송: mode=$mode "$text"');
    return true;
  }

  Future<bool> _sendEncryptedTextPacket({
    required Uint8List targetNodeId,
    required String text,
    required MessageSendMode mode,
    int ttl = MeshPacket.defaultTtl,
  }) async {
    final targetEncryptionPublicKey = await _contacts.getEncryptionPublicKey(
      targetNodeId,
    );
    if (targetEncryptionPublicKey == null) return false;

    final sharedSecret = await _crypto.computeSharedSecret(
      _identity.myEncryptionPrivateKeySeed,
      targetEncryptionPublicKey,
    );
    final plaintext = _encodeTextPayload(text, mode);
    final encryptedPayload = await _crypto.encrypt(plaintext, sharedSecret);
    final packet = MeshPacket.create(
      senderId: _identity.myNodeId,
      targetId: targetNodeId,
      msgType: MsgType.text,
      payload: encryptedPayload,
      ttl: ttl,
    );
    packet.signature = await _crypto.sign(
      packet.toSignableBytes(),
      _identity.myPrivateKeySeed,
    );

    final targetNodeIdHex = _hex(targetNodeId);
    final recipientCount = mode.isNotice
        ? await _sendTargetedMeshPacketCount(packet, targetNodeIdHex)
        : await _sendPacketToNodeIdCount(packet, targetNodeIdHex);
    if (recipientCount == 0) return false;

    await _db.saveMessage(
      msgId: packet.msgId,
      senderId: _identity.myNodeId,
      targetId: targetNodeId,
      msgType: MsgType.text.value,
      timestamp: packet.timestamp,
      payload: plaintext,
      isOutgoing: true,
      expiresAt: _expiresAtForLocalDisplay(mode),
    );
    return true;
  }

  Future<bool> _sendShortNoticeToContacts(String text) async {
    final contacts = await _contacts.getAllContacts();
    var sentAny = false;

    for (final contact in contacts) {
      if (_bytesEqual(contact.nodeId, _identity.myNodeId) ||
          !contact.userLevel.canSendMessages ||
          contact.encryptionPublicKey == null) {
        continue;
      }
      final sent = await _sendEncryptedTextPacket(
        targetNodeId: contact.nodeId,
        text: text,
        mode: MessageSendMode.shortNotice,
        ttl: MessagePolicy.shortNoticeTtl,
      );
      sentAny = sentAny || sent;
    }

    return sentAny;
  }

  Future<bool> _sendLongNoticeBroadcast(
    String text,
    MessageSendMode mode,
  ) async {
    final packet = MeshPacket.create(
      senderId: _identity.myNodeId,
      targetId: MeshPacket.broadcast,
      msgType: MsgType.text,
      payload: _encodeTextPayload(text, mode),
      ttl: MessagePolicy.longNoticeTtl,
    );
    packet.signature = await _crypto.sign(
      packet.toSignableBytes(),
      _identity.myPrivateKeySeed,
    );

    final recipientCount = await _broadcastPacketWithRetry(packet);
    if (recipientCount == 0) {
      _log('NOTICE 전송 실패: 연결된 BLE 이웃이 없습니다.');
      return false;
    }

    await _db.saveMessage(
      msgId: packet.msgId,
      senderId: _identity.myNodeId,
      targetId: MeshPacket.broadcast,
      msgType: MsgType.text.value,
      timestamp: packet.timestamp,
      payload: packet.payload,
      isOutgoing: true,
    );
    return true;
  }

  Future<bool> sendLevelChangeRequest({
    required Uint8List targetNodeId,
    required UserLevel level,
  }) async {
    try {
      final senderLevel = AppSettingsService().current.userLevel;
      if (!senderLevel.canAssignContactLevels ||
          !senderLevel.contactAssignableLevels.contains(level)) {
        _log('LEVEL_CHANGE send blocked: unauthorized sender level.');
        return false;
      }
      final payload = Uint8List.fromList(
        utf8.encode(
          jsonEncode({
            'protocolVersion': MeshPacket.currentProtocolVersion,
            'kind': 'level_change',
            'level': level.wireName,
          }),
        ),
      );
      final packet = MeshPacket.create(
        senderId: _identity.myNodeId,
        targetId: targetNodeId,
        msgType: MsgType.adminNotice,
        payload: payload,
        ttl: MeshPacket.defaultTtl,
      );
      packet.signature = await _crypto.sign(
        packet.toSignableBytes(),
        _identity.myPrivateKeySeed,
      );
      final recipientCount = await _sendPacketToNodeIdCount(
        packet,
        _hex(targetNodeId),
      );
      _log(
        'LEVEL_CHANGE request target=${_hexShort(targetNodeId)} '
        'level=${level.label} recipients=$recipientCount',
      );
      return recipientCount > 0;
    } catch (e) {
      _log('sendLevelChangeRequest error: $e');
      return false;
    }
  }

  Future<int> _broadcastPacketWithRetry(
    MeshPacket packet, {
    String? excludeDeviceId,
  }) async {
    // LAN 브로드캐스트 (dedup은 seen_messages에서 처리됨)
    final lanFuture = _lan.broadcastPacket(packet);

    var bleRecipientCount = 0;
    for (var attempt = 0; attempt < 3; attempt++) {
      bleRecipientCount = await _ble.broadcastPacket(
        packet,
        excludeDeviceId: excludeDeviceId,
      );
      if (bleRecipientCount > 0) break;
      await Future<void>.delayed(Duration(milliseconds: 250 * (attempt + 1)));
    }
    final lanRecipientCount = await lanFuture;
    return lanRecipientCount + bleRecipientCount;
  }

  Future<void> broadcastKeyAnnounce({bool force = false}) async {
    final inFlight = _keyAnnounceInFlight;
    if (inFlight != null) {
      await inFlight;
      if (!force) return;
    }

    final now = DateTime.now();
    final last = _lastKeyAnnounceAt;
    if (!force &&
        last != null &&
        now.difference(last) < const Duration(seconds: 5)) {
      return;
    }

    final task = _broadcastKeyAnnounceNow();
    _keyAnnounceInFlight = task;
    try {
      await task;
      _lastKeyAnnounceAt = DateTime.now();
    } finally {
      if (identical(_keyAnnounceInFlight, task)) {
        _keyAnnounceInFlight = null;
      }
    }
  }

  Future<void> _broadcastKeyAnnounceNow() async {
    try {
      final packet = await _identity.createKeyAnnouncePacket();
      final lanFuture = _lan.broadcastPacket(packet);
      final bleRecipientCount = await _ble.broadcastPacket(packet);
      final recipientCount = await lanFuture + bleRecipientCount;
      _log('KEY_ANNOUNCE 브로드캐스트 완료: $recipientCount개 이웃 (LAN 포함)');
    } catch (e) {
      _log('broadcastKeyAnnounce 오류: $e');
    }
  }

  /// 특정 nodeIdHex에게 직접 패킷을 전송한다. LAN 우선, 없으면 BLE.
  Future<void> _sendPacketToNodeId(MeshPacket packet, String targetNodeIdHex) async {
    await _sendPacketToNodeIdCount(packet, targetNodeIdHex);
  }

  Future<int> _sendPacketToNodeIdCount(
    MeshPacket packet,
    String targetNodeIdHex,
  ) async {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final lanRetryAfter = _lanRetryAfterMs[targetNodeIdHex] ?? 0;
    if (_lan.hasPeer(targetNodeIdHex) && nowMs >= lanRetryAfter) {
      final lanSent = await _lan.sendPacket(packet, targetNodeIdHex);
      if (lanSent) {
        _lanRetryAfterMs.remove(targetNodeIdHex);
        return 1;
      }
      _lanRetryAfterMs[targetNodeIdHex] =
          nowMs + const Duration(seconds: 5).inMilliseconds;
    }

    final bleDeviceId = _bleDeviceIdForNode(targetNodeIdHex);
    if (bleDeviceId != null) {
      final bleSent = await _ble.sendPacket(packet, bleDeviceId);
      return bleSent ? 1 : 0;
    }

    return _broadcastPacketWithRetry(packet);
  }

  Future<int> _sendTargetedMeshPacketCount(
    MeshPacket packet,
    String targetNodeIdHex,
  ) async {
    var count = 0;
    count += await _sendDirectPacketToNodeIdCount(packet, targetNodeIdHex);
    count += await _broadcastPacketWithRetry(packet);
    return count;
  }

  Future<int> _sendDirectPacketToNodeIdCount(
    MeshPacket packet,
    String targetNodeIdHex,
  ) async {
    var count = 0;
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final lanRetryAfter = _lanRetryAfterMs[targetNodeIdHex] ?? 0;
    if (_lan.hasPeer(targetNodeIdHex) && nowMs >= lanRetryAfter) {
      final lanSent = await _lan.sendPacket(packet, targetNodeIdHex);
      if (lanSent) {
        _lanRetryAfterMs.remove(targetNodeIdHex);
        count++;
      } else {
        _lanRetryAfterMs[targetNodeIdHex] =
            nowMs + const Duration(seconds: 5).inMilliseconds;
      }
    }

    final bleDeviceId = _bleDeviceIdForNode(targetNodeIdHex);
    if (bleDeviceId != null) {
      final bleSent = await _ble.sendPacket(packet, bleDeviceId);
      if (bleSent) count++;
    }
    return count;
  }

  String? _bleDeviceIdForNode(String nodeIdHex) {
    for (final entry in _deviceToNodeHex.entries) {
      if (entry.value == nodeIdHex) return entry.key;
    }
    return null;
  }

  /// 파일 또는 이미지를 지정한 연락처에게 전송한다. 직접 연결 시에만 허용한다.
  Future<TransferId?> sendFile({
    required Uint8List data,
    required String fileName,
    required String mimeType,
    required String targetNodeIdHex,
    TransferKind kind = TransferKind.file,
    int imageIndex = 0,
    String? groupId,
  }) async {
    final isLan = _lan.hasPeer(targetNodeIdHex);
    final isBle = _deviceToNodeHex.values.contains(targetNodeIdHex);
    _log('[DIAG-TX] sendFile 요청: target=${targetNodeIdHex.substring(0, 8)} isLAN=$isLan isBLE=$isBle isDirect=${isDirectlyConnected(targetNodeIdHex)}');
    if (!isDirectlyConnected(targetNodeIdHex)) {
      _log('[DIAG-TX] sendFile 차단: 직접 연결 없음 (LAN peers: ${_lan.connectedPeerIds}, BLE map: ${_deviceToNodeHex.values.take(3)})');
      return null;
    }
    try {
      final transport = isLan && isBle
          ? TransferTransport.wifiBle
          : isLan
              ? TransferTransport.wifi
              : isBle
                  ? TransferTransport.ble
                  : TransferTransport.unknown;
      final chunkSize = transport == TransferTransport.wifi
          ? TransferChunkSize.lan
          : TransferChunkSize.ble;
      _log(
        '[DIAG-TX] sendFile chunkSize=$chunkSize transport=${transport.label}',
      );
      return await _transfer.sendFile(
        data: data,
        fileName: fileName,
        mimeType: mimeType,
        targetNodeIdHex: targetNodeIdHex,
        kind: kind,
        transport: transport,
        imageIndex: imageIndex,
        chunkSize: chunkSize,
        groupId: groupId,
      );
    } catch (e) {
      _log('sendFile 오류: $e');
      return null;
    }
  }

  /// 진행 중인 전송을 취소한다 (UI에서 X 버튼 클릭 시 호출).
  void cancelTransfer(String tid) {
    _transfer.cancelTransfer(tid);
  }

  /// 전송 완료된 1:1 파일을 Personal/Chat/{contactName}/ 에 저장한다.
  Future<void> _saveTransferFile(TransferCompleted event) async {
    try {
      String contactName;
      try {
        final nodeId = _fromHex(event.contactNodeIdHex);
        final contact = await _contacts.getContact(nodeId);
        final name = contact?.displayName ?? '';
        contactName = name.isNotEmpty ? name : event.contactNodeIdHex.substring(0, 8);
      } catch (_) {
        contactName = event.contactNodeIdHex.substring(0, 8);
      }
      await TransferStorageService().save(
        data: event.data,
        tid: event.meta.tid,
        contactHex: event.contactNodeIdHex,
        fileName: event.meta.fileName,
        mimeType: event.meta.mimeType,
        direction: event.direction,
        fileSize: event.meta.fileSize,
        contactName: contactName,
      );
    } catch (e) {
      _log('_saveTransferFile error: $e');
    }
  }

  // ── 수신 패킷 처리 ───────────────────────────────────────────────────────────

  /// BleService에서 패킷을 수신했을 때 호출되는 콜백.
  ///
  /// ## 처리 파이프라인
  /// 1. msg_id 중복 확인 → 이미 봤으면 drop (R-09)
  /// 2. markMessageSeen() — seen_messages에 기록
  /// 3. 서명 검증 (발신자 공개키 필요)
  ///    - TEXT/PING/PONG: ContactService.getPublicKey() 로 조회
  ///    - KEY_ANNOUNCE: 패킷 payload에서 publicKey 추출하여 검증
  ///    - 공개키를 알 수 없으면 서명 검증 불가 → drop
  ///    - 검증 실패 → drop (R-07)
  /// 4. msg_type 별 처리
  /// 5. TTL 체크 후 릴레이 (R-09 RPF)

  /// BleService.onPacketReceived 콜백에서 호출하는 public 진입점.
  Future<String?> requestTopologyScan({required int depth}) async {
    try {
      final effectiveDepth = _limitTopologyDepth(depth);
      if (effectiveDepth == 0) return null;

      final requestId = _hex(MeshPacket.generateMsgId());
      final request = TopologyRequest(
        requestId: requestId,
        requestedDepth: effectiveDepth,
      );
      final packet = MeshPacket.create(
        senderId: _identity.myNodeId,
        targetId: MeshPacket.broadcast,
        msgType: MsgType.topologyRequest,
        payload: request.toPayload(),
        ttl: effectiveDepth < 0 ? MeshPacket.defaultTtl : effectiveDepth,
      );
      packet.signature = await _crypto.sign(
        packet.toSignableBytes(),
        _identity.myPrivateKeySeed,
      );

      final recipientCount = await _broadcastPacketWithRetry(packet);
      _log(
        'TOPOLOGY_REQUEST sent depth=$effectiveDepth neighbors=$recipientCount',
      );
      return requestId;
    } catch (e) {
      _log('requestTopologyScan error: $e');
      return null;
    }
  }

  Future<void> handleIncomingPacket(MeshPacket packet, String fromDeviceId) =>
      _handleIncomingPacket(packet, fromDeviceId);

  Future<void> _handleIncomingPacket(
    MeshPacket packet,
    String fromDeviceId,
  ) async {
    if (_bytesEqual(packet.senderId, _identity.myNodeId)) {
      _log('DROP(자체 패킷 echo): ${_hexShort(packet.msgId)}');
      return;
    }

    // hopCount == 0: 발신자가 직접 보낸 패킷 → 직접 연결 이웃으로 기록
    if (packet.hopCount == 0) {
      _deviceToNodeHex[fromDeviceId] = _hex(packet.senderId);
    }

    // ── Step 1: msg_id 중복 확인 ─────────────────────────────────────────────
    final alreadySeen = await _db.isMessageSeen(packet.msgId);
    final msgIdHex = _hex(packet.msgId);
    if (alreadySeen) {
      _log('DROP(중복): ${_hexShort(packet.msgId)}');
      return;
    }

    // ── Step 2: 서명 검증 (markMessageSeen은 검증 후에 수행) ─────────────────
    // C-2 수정: DoS 방지 — 위조 패킷으로 정상 패킷을 차단하는 것을 막기 위해
    // 서명 검증 성공 후에만 seen 캐시에 등록한다.
    if (!_processingMessageIds.add(msgIdHex)) {
      _log('DROP(in-flight duplicate): ${_hexShort(packet.msgId)}');
      return;
    }

    final senderPublicKey = await _resolveSenderPublicKey(packet, fromDeviceId);
    if (senderPublicKey == null) {
      _processingMessageIds.remove(msgIdHex);
      _log('DROP(공개키 없음): ${_hexShort(packet.msgId)} type=${packet.msgType}');
      return;
    }

    final signatureValid = await _identity.verifyPacketSignature(
      packet,
      senderPublicKey,
    );
    if (!signatureValid) {
      _processingMessageIds.remove(msgIdHex);
      _log(
        'DROP(서명 불일치): ${_hexShort(packet.msgId)} sender=${_hexShort(packet.senderId)}',
      );
      return;
    }

    // ── Step 3: markMessageSeen (서명 검증 성공 후) ───────────────────────────
    await _db.markMessageSeen(packet.msgId);
    _processingMessageIds.remove(msgIdHex);

    // ── Step 4: msg_type 별 처리 ──────────────────────────────────────────────
    switch (packet.msgType) {
      case MsgType.text:
        await _handleTextPacket(packet);
      case MsgType.keyAnnounce:
        await _handleKeyAnnouncePacket(packet, senderPublicKey);
      case MsgType.ping:
        await _handlePingPacket(packet, fromDeviceId);
      case MsgType.pong:
        _ble.markHeartbeatResponse(fromDeviceId);
        _log('PONG 수신: sender=${_hexShort(packet.senderId)}');
      case MsgType.topologyRequest:
        await _handleTopologyRequestPacket(packet);
      case MsgType.topologyResponse:
        await _handleTopologyResponsePacket(packet);
      case MsgType.adminNotice:
        await _handleAdminNoticePacket(packet);
      case MsgType.ack:
        // Phase 2 구현 예정
        _log('ACK 수신 (Phase 2 미구현): ${_hexShort(packet.msgId)}');
      case MsgType.fileHeader:
        final fhForMe = _bytesEqual(packet.targetId, _identity.myNodeId);
        _log('[DIAG-RX] fileHeader 도착: forMe=$fhForMe sender=${_hexShort(packet.senderId)}');
        if (fhForMe) {
          _transfer.handleFileHeader(packet, _hex(packet.senderId));
        }
      case MsgType.fileChunk:
        if (_bytesEqual(packet.targetId, _identity.myNodeId)) {
          _transfer.handleFileChunk(packet, _hex(packet.senderId));
        }
      case MsgType.fileAck:
        final faForMe = _bytesEqual(packet.targetId, _identity.myNodeId);
        _log('[DIAG-RX] fileAck 도착: forMe=$faForMe sender=${_hexShort(packet.senderId)}');
        if (faForMe) {
          _transfer.handleFileAck(packet, _hex(packet.senderId));
        }
      case MsgType.fileCancel:
        if (_bytesEqual(packet.targetId, _identity.myNodeId)) {
          _transfer.handleFileCancel(packet);
        }
      case MsgType.groupInvite:
      case MsgType.groupInviteResp:
      case MsgType.groupMessage:
      case MsgType.groupMemberUpdate:
      case MsgType.groupLeave:
        if (_bytesEqual(packet.targetId, _identity.myNodeId)) {
          final decrypted = await _decryptGroupPayload(packet);
          if (decrypted != null) {
            await GroupMessagingService().handleIncomingPacket(
              packet,
              packet.senderId,
              decrypted,
            );
          }
        }
    }

    // ── Step 5: TTL 체크 및 릴레이 ───────────────────────────────────────────
    // 파일 패킷만 relay 제외 (직접 연결 전용 — 청크 크기 문제).
    // 그룹 패킷(초대/응답/메시지/멤버업데이트/탈퇴) 모두 relay 허용:
    //   PC↔Phone 직접 연결 불안정 시 중간 노드가 초대/수락 응답을 중계해야 한다.
    if (packet.msgType == MsgType.fileHeader ||
        packet.msgType == MsgType.fileChunk ||
        packet.msgType == MsgType.fileAck ||
        packet.msgType == MsgType.fileCancel) {
      return;
    }

    if (packet.ttl <= 0) {
      _log('DROP(TTL=0): ${_hexShort(packet.msgId)}');
      return;
    }
    if (packet.hopCount >= 255) {
      _log('DROP(hop overflow): ${_hexShort(packet.msgId)}');
      return;
    }

    // C-1 수정: ttl/hopCount는 toSignableBytes()에서 제외됨 → 재서명 불필요
    // 원래 발신자 서명을 그대로 유지한 채 ttl/hopCount만 변경하여 릴레이
    packet.ttl -= 1;
    packet.hopCount += 1;

    final relayed = await _broadcastRelayPacket(
      packet,
      excludeDeviceId: fromDeviceId,
    );
    if (relayed > 0) {
      _log(
        'RELAY: type=${packet.msgType} sender=${_hexShort(packet.senderId)} '
        'target=${_hexShort(packet.targetId)} hop=${packet.hopCount} '
        'ttl=${packet.ttl} neighbors=$relayed',
      );
    }
  }

  Future<int> _broadcastRelayPacket(
    MeshPacket packet, {
    String? excludeDeviceId,
  }) async {
    final lanFuture = _lan.broadcastPacket(packet);
    var bleRecipientCount = 0;
    for (var attempt = 0; attempt < 3; attempt++) {
      bleRecipientCount = await _ble.broadcastPacket(
        packet,
        excludeDeviceId: excludeDeviceId,
      );
      if (bleRecipientCount > 0) break;
      await Future<void>.delayed(Duration(milliseconds: 120 * (attempt + 1)));
    }
    final lanRecipientCount = await lanFuture;
    return lanRecipientCount + bleRecipientCount;
  }

  // ── TEXT 패킷 처리 ────────────────────────────────────────────────────────────

  /// TEXT 패킷을 복호화하여 Stream에 emit하고 DB에 저장한다.
  Future<void> _handleTextPacket(MeshPacket packet) async {
    // 자신에게 온 메시지인지 확인 (targetId = myNodeId 또는 broadcast)
    final myNodeId = _identity.myNodeId;
    final isForMe =
        packet.isBroadcast || _bytesEqual(packet.targetId, myNodeId);
    if (!isForMe) {
      // 릴레이 전용 (복호화 불필요)
      return;
    }

    if (!AppSettingsService().current.userLevel.canSendMessages) {
      _log('TEXT display skipped: server level only relays messages.');
      return;
    }

    final Uint8List plaintext;
    if (packet.isBroadcast) {
      plaintext = packet.payload;
    } else {
      final senderEncryptionPublicKey = await _contacts.getEncryptionPublicKey(
        packet.senderId,
      );
      if (senderEncryptionPublicKey == null) {
        _log('TEXT 복호화 실패: 발신자 메시지 암호화 키가 없습니다.');
        return;
      }
      final sharedSecret = await _crypto.computeSharedSecret(
        _identity.myEncryptionPrivateKeySeed,
        senderEncryptionPublicKey,
      );

      final decrypted = await _crypto.decrypt(packet.payload, sharedSecret);
      if (decrypted == null) {
        _log('TEXT 복호화 실패: ${_hexShort(packet.msgId)}');
        return;
      }
      plaintext = decrypted;
    }

    final _DecodedTextPayload decodedPayload;
    try {
      decodedPayload = _decodeTextPayload(plaintext);
    } catch (e) {
      _log('TEXT UTF-8 디코딩 실패: ${_hexShort(packet.msgId)} — $e');
      return;
    }
    // DB에 수신 메시지 저장 (복호화된 본문 보존)
    await _db.saveMessage(
      msgId: packet.msgId,
      senderId: packet.senderId,
      targetId: packet.targetId,
      msgType: MsgType.text.value,
      timestamp: packet.timestamp,
      payload: plaintext,
      isOutgoing: false,
    );

    // 신뢰 상태 확인 (R-08)
    final contact = await _contacts.getContact(packet.senderId);
    final isTrusted = contact?.isTrusted ?? false;

    final received = ReceivedMessage(
      msgId: packet.msgId,
      senderNodeId: Uint8List.fromList(packet.senderId),
      text: decodedPayload.text,
      timestamp: packet.timestamp,
      isTrusted: isTrusted,
      readTtlMs: decodedPayload.ttlMs,
      isNotice: decodedPayload.isNotice,
    );

    if (!_messageStreamController.isClosed) {
      _messageStreamController.add(received);
    }

    _log(
      'TEXT 수신: sender=${_hexShort(packet.senderId)} '
      'trusted=$isTrusted hop=${packet.hopCount} '
      '"${_truncate(decodedPayload.text, 30)}"',
    );
  }

  // ── KEY_ANNOUNCE 패킷 처리 ────────────────────────────────────────────────────

  /// KEY_ANNOUNCE 패킷을 처리하여 연락처를 추가/업데이트한다.
  Future<void> _handleKeyAnnouncePacket(
    MeshPacket packet,
    Uint8List senderPublicKey,
  ) async {
    // 서명은 Step 3에서 이미 검증 완료
    // parseKeyAnnouncePacket은 서명이 이미 검증되었다고 가정한다 (IdentityService 주석 참고)
    final contactInfo = _identity.parseKeyAnnouncePacket(packet);
    if (contactInfo == null) {
      _log('KEY_ANNOUNCE 파싱 실패: ${_hexShort(packet.msgId)}');
      return;
    }

    // 공개키 변경 감지 (R-08 TOFU)
    final changeResult = await _contacts.checkPublicKeyChange(
      contactInfo.nodeId,
      contactInfo.publicKey,
      contactInfo.encryptionPublicKey,
    );

    if (changeResult == TrustChangeResult.changed) {
      _log(
        '경고: ${_hexShort(contactInfo.nodeId)} 공개키 변경 감지 '
        '— 신뢰 상태 리셋, 재확인 필요 (R-08)',
      );
      // TODO: UI 레이어에서 경고 표시 이벤트 발행 (Phase 2)
    }

    await _contacts.addOrUpdateContact(
      contactInfo.nodeId,
      contactInfo.publicKey,
      encryptionPublicKey: contactInfo.encryptionPublicKey,
      displayName: contactInfo.displayName,
      avatarKey: contactInfo.avatarKey,
      userLevel: contactInfo.userLevel,
      deviceType: contactInfo.deviceType,
    );

    _log(
      'KEY_ANNOUNCE 처리: sender=${_hexShort(packet.senderId)} '
      'result=$changeResult',
    );

    if (_keyAnnounceRespondedNodeIds.add(_hex(contactInfo.nodeId))) {
      // 새 이웃이 자신의 키를 알려오면 내 키도 응답하여 양쪽 ECDH 준비를 끝낸다.
      await broadcastKeyAnnounce();
    }
    _scheduleDiagnosticMessage(contactInfo.nodeId);
  }

  void _scheduleDiagnosticMessage(Uint8List nodeId) {
    if (_diagnosticMessage.isEmpty || _diagnosticMessageSent) return;
    final targetNodeId = DiagnosticConfig.targetNodeId.toLowerCase();
    if (targetNodeId.isNotEmpty && _hex(nodeId) != targetNodeId) return;

    _diagnosticMessageSent = true;
    _diagnosticMessageTimer = Timer(const Duration(seconds: 1), () async {
      final sent = await sendTextMessage(
        targetNodeId: nodeId,
        text: _diagnosticMessage,
      );
      _log('진단 TEXT 자동 전송: ${sent ? '성공' : '실패'}');
    });
  }

  // ── PING 패킷 처리 ────────────────────────────────────────────────────────────

  /// PING 패킷에 PONG으로 응답한다.
  Future<void> _handleTopologyRequestPacket(MeshPacket packet) async {
    if (_bytesEqual(packet.senderId, _identity.myNodeId)) return;
    final TopologyRequest request;
    try {
      request = TopologyRequest.fromPayload(packet.payload);
    } catch (e) {
      _log('TOPOLOGY_REQUEST parse failed: $e');
      return;
    }
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    _topologyRequestsHandledAt.removeWhere(
      (_, handledAt) =>
          nowMs - handledAt > const Duration(minutes: 5).inMilliseconds,
    );
    if (_topologyRequestsHandledAt.containsKey(request.requestId)) {
      _log('TOPOLOGY_REQUEST duplicate ignored: ${request.requestId}');
      return;
    }
    _topologyRequestsHandledAt[request.requestId] = nowMs;

    final contacts = await _topologyNeighborSummaries();
    final settings = AppSettingsService().current;
    final response = TopologyResponse(
      requestId: request.requestId,
      responder: TopologyNodeSummary(
        nodeId: _identity.myNodeId,
        displayName: settings.displayName,
        deviceType: _identity.myDeviceType,
        userLevel: settings.userLevel,
        isSaved: true,
        lastSeen: DateTime.now().millisecondsSinceEpoch,
      ),
      neighbors: contacts,
      timestamp: nowMs,
    );
    final responsePacket = MeshPacket.create(
      senderId: _identity.myNodeId,
      targetId: Uint8List.fromList(packet.senderId),
      msgType: MsgType.topologyResponse,
      payload: response.toPayload(),
      ttl: MeshPacket.defaultTtl,
    );
    responsePacket.signature = await _crypto.sign(
      responsePacket.toSignableBytes(),
      _identity.myPrivateKeySeed,
    );
    final recipientCount = await _sendPacketToNodeIdCount(
      responsePacket,
      _hex(packet.senderId),
    );
    _log(
      'TOPOLOGY_RESPONSE sent request=${request.requestId.substring(0, 8)} '
      'neighbors=${contacts.length} recipients=$recipientCount',
    );
  }

  Future<void> _handleTopologyResponsePacket(MeshPacket packet) async {
    if (!_bytesEqual(packet.targetId, _identity.myNodeId)) return;
    final TopologyResponse response;
    try {
      response = TopologyResponse.fromPayload(packet.payload);
    } catch (e) {
      _log('TOPOLOGY_RESPONSE parse failed: $e');
      return;
    }
    final ageMs = DateTime.now().millisecondsSinceEpoch - response.timestamp;
    if (ageMs.abs() > const Duration(minutes: 2).inMilliseconds) {
      _log('TOPOLOGY_RESPONSE ignored: stale response.');
      return;
    }
    if (!_topologyStreamController.isClosed) {
      _topologyStreamController.add(response);
    }
    _log(
      'TOPOLOGY_RESPONSE received responder=${_hexShort(response.responder.nodeId)} '
      'neighbors=${response.neighbors.length}',
    );
  }

  Future<void> _handleAdminNoticePacket(MeshPacket packet) async {
    if (!_bytesEqual(packet.targetId, _identity.myNodeId)) {
      _log('ADMIN_NOTICE relay-only: ${_hexShort(packet.msgId)}');
      return;
    }
    final ageMs = DateTime.now().millisecondsSinceEpoch - packet.timestamp;
    if (ageMs.abs() > const Duration(minutes: 10).inMilliseconds) {
      _log('ADMIN_NOTICE ignored: stale timestamp.');
      return;
    }

    final Map<String, dynamic> decoded;
    try {
      final raw = jsonDecode(utf8.decode(packet.payload));
      if (raw is! Map<String, dynamic>) {
        throw const FormatException('Invalid admin notice payload.');
      }
      decoded = raw;
    } catch (e) {
      _log('ADMIN_NOTICE parse failed: $e');
      return;
    }

    if (decoded['protocolVersion'] != MeshPacket.currentProtocolVersion ||
        decoded['kind'] != 'level_change') {
      _log('ADMIN_NOTICE ignored: unsupported payload.');
      return;
    }

    final requestedLevel = UserLevel.fromWire(decoded['level'] as String?);
    if (requestedLevel == UserLevel.server) {
      _log('LEVEL_CHANGE ignored: user/server mode is self-selected.');
      return;
    }

    final sender = await _contacts.getContact(packet.senderId);
    if (sender == null ||
        !sender.isTrusted ||
        !sender.userLevel.canChangeContactLevel(
          AppSettingsService().current.userLevel,
        ) ||
        !sender.userLevel.contactAssignableLevels.contains(requestedLevel)) {
      _log('LEVEL_CHANGE ignored: unauthorized sender.');
      return;
    }

    final settingsService = AppSettingsService();
    final current = settingsService.current;
    if (current.userLevel == requestedLevel) return;
    await settingsService.save(current.copyWith(userLevel: requestedLevel));
    await broadcastKeyAnnounce();
    _log('LEVEL_CHANGE applied: ${requestedLevel.label}');
  }

  Future<List<TopologyNodeSummary>> _topologyNeighborSummaries() async {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final recentCutoff = nowMs - const Duration(minutes: 3).inMilliseconds;
    final contacts = await _contacts.getAllContacts();
    final summaries = <TopologyNodeSummary>[];
    for (final contact in contacts) {
      if (_bytesEqual(contact.nodeId, _identity.myNodeId)) continue;
      if (!contact.isSaved && contact.lastSeen < recentCutoff) continue;
      summaries.add(TopologyNodeSummary.fromContact(contact));
      if (summaries.length >= 15) break;
    }
    return summaries;
  }

  Future<void> _handlePingPacket(MeshPacket packet, String fromDeviceId) async {
    _log('PING 수신: sender=${_hexShort(packet.senderId)}');

    try {
      // PONG 패킷 생성 — target을 발신자로 설정
      final pong = MeshPacket.create(
        senderId: _identity.myNodeId,
        targetId: Uint8List.fromList(packet.senderId),
        msgType: MsgType.pong,
        payload: Uint8List(0), // PONG은 payload 없음
        ttl: 0, // 직접 연결된 이웃에게만 응답
      );

      // Ed25519 서명 (R-07)
      final signableBytes = pong.toSignableBytes();
      final signature = await _crypto.sign(
        signableBytes,
        _identity.myPrivateKeySeed,
      );
      pong.signature = signature;

      // LAN 우선, 없으면 BLE로 직접 전송
      await _sendPacketToNodeId(pong, _hex(packet.senderId));

      _log('PONG 전송: target=${_hexShort(packet.senderId)}');
    } catch (e) {
      _log('PONG 전송 오류: $e');
    }
  }

  /// 직접 연결된 이웃의 생존 여부를 확인하는 서명된 PING 패킷을 만든다.
  Future<MeshPacket> _createPingPacket() async {
    final ping = MeshPacket.create(
      senderId: _identity.myNodeId,
      targetId: MeshPacket.broadcast,
      msgType: MsgType.ping,
      payload: Uint8List(0),
      ttl: 0,
    );
    ping.signature = await _crypto.sign(
      ping.toSignableBytes(),
      _identity.myPrivateKeySeed,
    );
    return ping;
  }

  // ── 메시지 히스토리 조회 ─────────────────────────────────────────────────────

  /// 특정 연락처와의 메시지 목록을 반환한다 (timestamp 오름차순).
  ///
  /// DB에서 복호화된 payload를 읽어 [ReceivedMessage] 목록으로 변환한다.
  Future<List<ReceivedMessage>> getMessageHistory(
    Uint8List contactNodeId, {
    int limit = 50,
  }) async {
    final rows = await _db.getMessages(
      contactNodeId,
      myNodeId: _identity.myNodeId,
      limit: limit,
    );
    final contact = await _contacts.getContact(contactNodeId);
    final isTrusted = contact?.isTrusted ?? false;

    final result = <ReceivedMessage>[];
    for (final row in rows) {
      final payload = row['payload'] as Uint8List?;
      if (payload == null) continue;

      _DecodedTextPayload decodedPayload;
      try {
        decodedPayload = _decodeTextPayload(payload);
      } catch (_) {
        continue; // 디코딩 불가 항목 건너뜀
      }

      final isOutgoing = (row['is_outgoing'] as int? ?? 0) == 1;
      if (decodedPayload.ttlMs != null && row['expires_at'] == null) {
        await _db.setMessageExpiresAtIfNull(
          row['msg_id'] as Uint8List,
          DateTime.now().millisecondsSinceEpoch + decodedPayload.ttlMs!,
        );
      }
      result.add(
        ReceivedMessage(
          msgId: row['msg_id'] as Uint8List,
          senderNodeId: row['sender_id'] as Uint8List,
          text: decodedPayload.text,
          timestamp: row['timestamp'] as int,
          isTrusted: isTrusted,
          isOutgoing: isOutgoing,
          readTtlMs: decodedPayload.ttlMs,
        ),
      );
    }

    return result;
  }

  // ── 리소스 해제 ─────────────────────────────────────────────────────────────

  /// 타이머와 Stream 컨트롤러를 해제한다. 앱 종료 시 호출.
  // ── Group control packets ────────────────────────────────────────────────

  /// 그룹 제어 패킷을 E2E 암호화하여 전송한다.
  /// GroupMessagingService.setSendFunction()에 주입되는 함수.
  Future<bool> sendGroupControlPacket(
    Uint8List targetNodeId,
    MsgType type,
    String jsonPayload,
  ) async {
    try {
      final targetEncKey = await _contacts.getEncryptionPublicKey(targetNodeId);
      if (targetEncKey == null) return false;

      final sharedSecret = await _crypto.computeSharedSecret(
        _identity.myEncryptionPrivateKeySeed,
        targetEncKey,
      );
      final plain = Uint8List.fromList(utf8.encode(jsonPayload));
      final encrypted = await _crypto.encrypt(plain, sharedSecret);
      final packet = MeshPacket.create(
        senderId: _identity.myNodeId,
        targetId: targetNodeId,
        msgType: type,
        payload: encrypted,
      );
      packet.signature = await _crypto.sign(
        packet.toSignableBytes(),
        _identity.myPrivateKeySeed,
      );
      final recipientCount = await _sendPacketToNodeIdCount(
        packet,
        _hex(targetNodeId),
      );
      return recipientCount > 0;
    } catch (e) {
      _log('sendGroupControlPacket error: $e');
      return false;
    }
  }

  Future<String?> _decryptGroupPayload(MeshPacket packet) async {
    try {
      final senderEncKey = await _contacts.getEncryptionPublicKey(packet.senderId);
      if (senderEncKey == null) return null;
      final sharedSecret = await _crypto.computeSharedSecret(
        _identity.myEncryptionPrivateKeySeed,
        senderEncKey,
      );
      final payload = packet.payload;
      final plain = await _crypto.decrypt(payload, sharedSecret);
      if (plain == null) return null;
      return utf8.decode(plain);
    } catch (e) {
      _log('_decryptGroupPayload error: $e');
      return null;
    }
  }

  Future<void> markMessageDisplayed(ReceivedMessage message) async {
    final ttlMs = message.readTtlMs;
    if (ttlMs == null) return;
    await _db.setMessageExpiresAtIfNull(
      message.msgId,
      DateTime.now().millisecondsSinceEpoch + ttlMs,
    );
  }

  Future<void> dispose() async {
    _keyAnnounceTimer?.cancel();
    _keyAnnounceTimer = null;
    _connectionAnnounceTimer?.cancel();
    _connectionAnnounceTimer = null;
    _lanKeepaliveTimer?.cancel();
    _lanKeepaliveTimer = null;
    _lastKeyAnnounceAt = null;
    _keyAnnounceInFlight = null;
    _lanRetryAfterMs.clear();
    await _connectionSubscription?.cancel();
    _connectionSubscription = null;
    await _lanConnectionSubscription?.cancel();
    _lanConnectionSubscription = null;
    _cleanSeenTimer?.cancel();
    _cleanSeenTimer = null;
    _diagnosticMessageTimer?.cancel();
    _diagnosticMessageTimer = null;
    _topologyRequestsHandledAt.clear();
    _ble.stopHeartbeat();
    await _lan.dispose();

    if (!_messageStreamController.isClosed) {
      await _messageStreamController.close();
    }
    if (!_topologyStreamController.isClosed) {
      await _topologyStreamController.close();
    }

    _initialized = false;
    _log('MessagingService 해제 완료');
  }

  // ── 내부 유틸리티 ────────────────────────────────────────────────────────────

  /// 발신자의 공개키를 결정한다.
  ///
  /// - TEXT/PING/PONG/ADMIN_NOTICE/ACK: ContactService.getPublicKey() 조회
  /// - KEY_ANNOUNCE: payload에서 publicKey를 추출하여 반환
  ///   (아직 연락처에 없는 기기의 첫 공개 키 공지를 처리하기 위해)
  Uint8List _encodeTextPayload(String text, MessageSendMode mode) {
    if (mode == MessageSendMode.normal) {
      return Uint8List.fromList(utf8.encode(text));
    }

    final kind = switch (mode) {
      MessageSendMode.normal => 'normal',
      MessageSendMode.timed => 'time',
      MessageSendMode.shortNotice => 'notice_s',
      MessageSendMode.longNotice => 'notice_l',
    };

    final payload = <String, dynamic>{
      'meshTextVersion': 1,
      'kind': kind,
      'text': text,
    };
    if (mode == MessageSendMode.timed) {
      payload['readTtlMs'] = MessagePolicy.timedMessageReadTtl.inMilliseconds;
    }
    return Uint8List.fromList(utf8.encode(jsonEncode(payload)));
  }

  _DecodedTextPayload _decodeTextPayload(Uint8List payload) {
    if (payload.length > MessagePolicy.maxTextPayloadBytes) {
      throw FormatException('Text payload too large: ${payload.length}');
    }
    final raw = utf8.decode(payload);
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic> || decoded['meshTextVersion'] != 1) {
        return _DecodedTextPayload(text: raw);
      }
      final text = decoded['text'];
      final ttlMs = decoded['readTtlMs'] ?? decoded['ttlMs'];
      final kind = decoded['kind'] as String?;
      return _DecodedTextPayload(
        text: text is String ? text : raw,
        ttlMs: ttlMs is int ? ttlMs : null,
        isNotice: kind == 'notice_s' || kind == 'notice_l',
      );
    } catch (_) {
      return _DecodedTextPayload(text: raw);
    }
  }

  int? _expiresAtForLocalDisplay(MessageSendMode mode) {
    if (mode != MessageSendMode.timed) return null;
    return DateTime.now().millisecondsSinceEpoch +
        MessagePolicy.timedMessageReadTtl.inMilliseconds;
  }

  int _limitTopologyDepth(int depth) {
    final normalized = depth < -1 ? 1 : depth;
    final level = AppSettingsService().current.userLevel;
    final isLimited = level == UserLevel.user || level == UserLevel.server;
    if (!isLimited) return normalized;
    if (normalized == -1) return 3;
    return normalized > 3 ? 3 : normalized;
  }

  Future<Uint8List?> _resolveSenderPublicKey(
    MeshPacket packet,
    String fromDeviceId,
  ) async {
    if (packet.msgType == MsgType.keyAnnounce) {
      // KEY_ANNOUNCE: payload에서 직접 publicKey 추출
      try {
        final payloadJson = utf8.decode(packet.payload);
        final map = jsonDecode(payloadJson) as Map<String, dynamic>;
        if (map['protocolVersion'] != MeshPacket.currentProtocolVersion) {
          return null;
        }
        final publicKeyHex = map['publicKey'] as String?;
        if (publicKeyHex == null) return null;

        final publicKey = _fromHex(publicKeyHex);
        if (publicKey.length != 32) return null;

        // node_id 검증 — 위조 방지 (R-06)
        final expectedNodeId = CryptoService().nodeIdFromPublicKey(publicKey);
        if (!_bytesEqual(Uint8List.fromList(packet.senderId), expectedNodeId)) {
          _log(
            'KEY_ANNOUNCE node_id 위조 감지: sender=${_hexShort(packet.senderId)}',
          );
          return null;
        }

        return publicKey;
      } catch (_) {
        return null;
      }
    }

    // 그 외 유형: ContactService에서 조회
    return _contacts.getPublicKey(packet.senderId);
  }

  /// 두 Uint8List의 내용이 동일한지 비교한다.
  bool _bytesEqual(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// 소문자 hex 문자열 → Uint8List.
  static Uint8List _fromHex(String hex) {
    if (hex.length.isOdd) throw const FormatException('홀수 hex 길이');
    return Uint8List.fromList([
      for (var i = 0; i < hex.length; i += 2)
        int.parse(hex.substring(i, i + 2), radix: 16),
    ]);
  }

  /// 디버그용 — Uint8List를 짧은 hex 형식으로 변환 (첫 4 bytes).
  String _hexShort(Uint8List bytes) {
    final end = bytes.length < 4 ? bytes.length : 4;
    return bytes
        .sublist(0, end)
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
  }

  String _hex(Uint8List bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  /// 디버그용 — 문자열을 최대 [maxLen]자로 잘라낸다.
  String _truncate(String s, int maxLen) {
    if (s.length <= maxLen) return s;
    return '${s.substring(0, maxLen)}...';
  }

  void _log(String message) {
    // ignore: avoid_print
    print('[MessagingService] $message');
  }
}
