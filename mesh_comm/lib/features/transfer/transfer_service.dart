// lib/features/transfer/transfer_service.dart
//
// 파일·이미지 전송 서비스 (싱글톤).
//
// ## 송신 흐름
//   1. sendFile() 호출 → TransferMeta 생성 → fileHeader 패킷 전송
//   2. 상대방 fileAck(chunk=-1) 수신 → 청크 순차 전송 시작
//   3. 각 청크 ack 수신 후 다음 청크 전송
//   4. 마지막 ack → TransferCompleted emit
//
// ## 수신 흐름
//   1. fileHeader 패킷 수신 → IncomingTransfer 등록 → fileAck(chunk=-1) 송신
//   2. fileChunk 패킷 수신 → 청크 저장 → fileAck 송신
//   3. 마지막 청크 도착 → assemble() → TransferCompleted emit

import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint;

import '../../core/crypto/crypto_service.dart';
import '../../core/packet/mesh_packet.dart';
import '../../core/packet/msg_type.dart';
import '../../features/identity/identity_service.dart';
import 'transfer_model.dart';

/// 패킷 전송 콜백 타입 (MessagingService가 주입한다).
typedef SendPacketFn = Future<void> Function(MeshPacket packet, String targetNodeIdHex);

class TransferService {
  static final TransferService _instance = TransferService._internal();
  factory TransferService() => _instance;
  TransferService._internal();

  SendPacketFn? _sendPacket;
  final _crypto = CryptoService();
  final _identity = IdentityService();

  // 진행 중인 발신/수신 세션
  final Map<TransferId, OutgoingTransfer> _outgoing = {};
  final Map<TransferId, IncomingTransfer> _incoming = {};

  final StreamController<TransferEvent> _eventController =
      StreamController<TransferEvent>.broadcast();

  Stream<TransferEvent> get transferStream => _eventController.stream;

  /// 현재 진행 중인 발신/수신 전송 스냅샷 (UI 복원용).
  List<({TransferId tid, TransferMeta meta, double progress, TransferDirection direction})>
      get activeTransferSnapshots {
    final result = <({TransferId tid, TransferMeta meta, double progress, TransferDirection direction})>[];
    for (final t in _outgoing.values) {
      result.add((
        tid: t.meta.tid,
        meta: t.meta,
        progress: t.meta.totalChunks > 0 ? t.ackedChunks / t.meta.totalChunks : 0.0,
        direction: TransferDirection.outgoing,
      ));
    }
    for (final t in _incoming.values) {
      result.add((
        tid: t.meta.tid,
        meta: t.meta,
        progress: t.meta.totalChunks > 0 ? t.receivedCount / t.meta.totalChunks : 0.0,
        direction: TransferDirection.incoming,
      ));
    }
    return result;
  }

  void init({required SendPacketFn sendPacket}) {
    _sendPacket = sendPacket;
  }

  // ── 발신 ─────────────────────────────────────────────────────────────────────

  /// 파일 또는 이미지를 대상 노드에 전송한다.
  ///
  /// [chunkSize] 기본값은 BLE 청크 크기. LAN 경유 시 [TransferChunkSize.lan]을 전달.
  Future<TransferId> sendFile({
    required Uint8List data,
    required String fileName,
    required String mimeType,
    required String targetNodeIdHex,
    TransferKind kind = TransferKind.file,
    int imageIndex = 0,
    int chunkSize = TransferChunkSize.ble,
  }) async {
    final tid = _randomTid();
    final totalChunks = (data.length / chunkSize).ceil().clamp(1, 999999);
    final meta = TransferMeta(
      tid: tid,
      fileName: fileName,
      fileSize: data.length,
      totalChunks: totalChunks,
      mimeType: mimeType,
      kind: kind,
      imageIndex: imageIndex,
    );

    final transfer = OutgoingTransfer(
      meta: meta,
      data: data,
      targetNodeIdHex: targetNodeIdHex,
    );
    _outgoing[tid] = transfer;
    _emit(TransferStarted(tid, meta: meta, direction: TransferDirection.outgoing));

    await _sendHeader(transfer);
    return tid;
  }

  Future<void> _sendHeader(OutgoingTransfer transfer) async {
    final payload = utf8.encode(jsonEncode(transfer.meta.toJson()));
    final packet = await _buildPacket(
      msgType: MsgType.fileHeader,
      targetNodeIdHex: transfer.targetNodeIdHex,
      payload: Uint8List.fromList(payload),
    );
    transfer.status = TransferStatus.transferring;
    await _sendPacket?.call(packet, transfer.targetNodeIdHex);
  }

  Future<void> _sendNextChunk(OutgoingTransfer transfer) async {
    if (transfer.sentChunks >= transfer.meta.totalChunks) return;
    final idx = transfer.sentChunks;
    final chunkSize = TransferChunkSize.ble;
    final start = idx * chunkSize;
    final end = (start + chunkSize).clamp(0, transfer.data.length);
    final chunk = transfer.data.sublist(start, end);

    final tidBytes = _tidToBytes(transfer.meta.tid);
    final payload = Uint8List(tidBytes.length + 4 + chunk.length);
    payload.setRange(0, tidBytes.length, tidBytes);
    final bd = ByteData.sublistView(payload);
    bd.setUint32(tidBytes.length, idx, Endian.big);
    payload.setRange(tidBytes.length + 4, payload.length, chunk);

    final packet = await _buildPacket(
      msgType: MsgType.fileChunk,
      targetNodeIdHex: transfer.targetNodeIdHex,
      payload: payload,
    );
    transfer.sentChunks++;
    await _sendPacket?.call(packet, transfer.targetNodeIdHex);
    _emit(TransferProgress(
      transfer.meta.tid,
      progress: transfer.sentChunks / transfer.meta.totalChunks,
      direction: TransferDirection.outgoing,
    ));
  }

  // ── 수신 패킷 처리 ────────────────────────────────────────────────────────────

  void handleFileHeader(MeshPacket packet, String senderNodeIdHex) {
    try {
      final meta = TransferMeta.fromJson(
        jsonDecode(utf8.decode(packet.payload)) as Map<String, dynamic>,
      );
      final transfer = IncomingTransfer(meta: meta, senderNodeIdHex: senderNodeIdHex);
      _incoming[meta.tid] = transfer;
      _emit(TransferStarted(meta.tid, meta: meta, direction: TransferDirection.incoming));
      _sendAck(meta.tid, senderNodeIdHex, chunk: -1);
    } catch (e) {
      _log('handleFileHeader error: $e');
    }
  }

  void handleFileChunk(MeshPacket packet, String senderNodeIdHex) {
    try {
      final payload = packet.payload;
      if (payload.length < 12) return;

      final tidBytes = payload.sublist(0, 8);
      final tid = _bytesToTid(tidBytes);
      final bd = ByteData.sublistView(payload);
      final chunkIdx = bd.getUint32(8, Endian.big);
      final data = payload.sublist(12);

      final transfer = _incoming[tid];
      if (transfer == null) return;

      transfer.chunks[chunkIdx] = data;
      _sendAck(tid, senderNodeIdHex, chunk: chunkIdx);

      _emit(TransferProgress(
        tid,
        progress: transfer.receivedCount / transfer.meta.totalChunks,
        direction: TransferDirection.incoming,
      ));

      if (transfer.isComplete) {
        final assembled = transfer.assemble();
        _incoming.remove(tid);
        _emit(TransferCompleted(
          tid,
          data: assembled,
          meta: transfer.meta,
          direction: TransferDirection.incoming,
          contactNodeIdHex: transfer.senderNodeIdHex,
        ));
      }
    } catch (e) {
      _log('handleFileChunk error: $e');
    }
  }

  void handleFileAck(MeshPacket packet, String senderNodeIdHex) {
    try {
      final ack = jsonDecode(utf8.decode(packet.payload)) as Map<String, dynamic>;
      final tid = ack['tid'] as String;
      final chunk = ack['chunk'] as int;
      final ok = ack['ok'] as bool? ?? true;

      final transfer = _outgoing[tid];
      if (transfer == null) return;

      if (!ok) {
        transfer.status = TransferStatus.failed;
        _outgoing.remove(tid);
        _emit(TransferFailed(tid, reason: 'ack not ok', direction: TransferDirection.outgoing));
        return;
      }

      if (chunk == -1) {
        // 헤더 ack → 첫 청크 전송 시작
        _sendNextChunk(transfer);
        return;
      }

      transfer.ackedChunks++;
      if (transfer.isComplete) {
        transfer.status = TransferStatus.done;
        _outgoing.remove(tid);
        _emit(TransferCompleted(
          tid,
          data: transfer.data,
          meta: transfer.meta,
          direction: TransferDirection.outgoing,
          contactNodeIdHex: transfer.targetNodeIdHex,
        ));
        return;
      }
      _sendNextChunk(transfer);
    } catch (e) {
      _log('handleFileAck error: $e');
    }
  }

  // ── 내부 유틸 ─────────────────────────────────────────────────────────────────

  Future<void> _sendAck(TransferId tid, String targetNodeIdHex, {required int chunk}) async {
    final payload = utf8.encode(jsonEncode({'tid': tid, 'chunk': chunk, 'ok': true}));
    final packet = await _buildPacket(
      msgType: MsgType.fileAck,
      targetNodeIdHex: targetNodeIdHex,
      payload: Uint8List.fromList(payload),
    );
    await _sendPacket?.call(packet, targetNodeIdHex);
  }

  Future<MeshPacket> _buildPacket({
    required MsgType msgType,
    required String targetNodeIdHex,
    required Uint8List payload,
  }) async {
    final myNodeId = _identity.myNodeId;
    final targetId = _fromHex(targetNodeIdHex);
    final msgId = _randomBytes(16);
    final now = DateTime.now().millisecondsSinceEpoch;

    final unsigned = MeshPacket(
      protocolVersion: MeshPacket.currentProtocolVersion,
      msgId: msgId,
      senderId: myNodeId,
      targetId: targetId,
      msgType: msgType,
      ttl: MeshPacket.defaultTtl,
      hopCount: 0,
      timestamp: now,
      signature: Uint8List(64),
      payload: payload,
    );
    final sig = await _crypto.sign(unsigned.toSignableBytes(), _identity.myPrivateKeySeed);
    unsigned.signature = sig;
    return unsigned;
  }

  static String _randomTid() {
    final rng = Random.secure();
    final bytes = Uint8List.fromList(List.generate(8, (_) => rng.nextInt(256)));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  static Uint8List _tidToBytes(String hex) {
    final result = Uint8List(8);
    for (var i = 0; i < 8; i++) {
      result[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return result;
  }

  static String _bytesToTid(Uint8List bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  static Uint8List _fromHex(String hex) {
    final result = Uint8List(hex.length ~/ 2);
    for (var i = 0; i < result.length; i++) {
      result[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return result;
  }

  static Uint8List _randomBytes(int n) {
    final rng = Random.secure();
    return Uint8List.fromList(List.generate(n, (_) => rng.nextInt(256)));
  }

  void _emit(TransferEvent event) {
    if (!_eventController.isClosed) _eventController.add(event);
  }

  void _log(String msg) => debugPrint('[TransferService] $msg');
}
