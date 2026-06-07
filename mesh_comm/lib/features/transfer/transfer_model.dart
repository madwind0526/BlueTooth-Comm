// lib/features/transfer/transfer_model.dart

import 'dart:typed_data';

/// 전송 종류.
enum TransferKind { file, image }

/// 전송 방향.
enum TransferDirection { outgoing, incoming }

/// 전송 상태.
enum TransferStatus {
  waiting,     // 발신: 헤더 전송 전 / 수신: 헤더 수신 전
  transferring,// 청크 교환 중
  done,        // 완료
  failed,      // 실패 또는 타임아웃
}

/// 청크 크기 설정.
class TransferChunkSize {
  // MeshPacket 오버헤드 102 bytes + TID 8 + idx 4 = 114 bytes.
  // BLE max write = 512 bytes → data = 512 - 114 = 398 → 사용 380 (안전 마진)
  static const int ble = 380;
  static const int lan = 4000;  // LAN TCP (MeshPacket maxPayload 4096에서 여유)
}

/// 전송 고유 ID (8바이트 랜덤 → hex 16자).
typedef TransferId = String;

/// 전송 세션 메타데이터 (발신·수신 공통).
class TransferMeta {
  final TransferId tid;
  final String fileName;
  final int fileSize;
  final int totalChunks;
  final String mimeType;
  final TransferKind kind;

  /// 이미지 묶음 전송 시 이 이미지의 순서 (0-based). 단일 파일은 0.
  final int imageIndex;

  const TransferMeta({
    required this.tid,
    required this.fileName,
    required this.fileSize,
    required this.totalChunks,
    required this.mimeType,
    required this.kind,
    this.imageIndex = 0,
  });

  Map<String, dynamic> toJson() => {
        'tid': tid,
        'name': fileName,
        'size': fileSize,
        'chunks': totalChunks,
        'mime': mimeType,
        'kind': kind.name,
        'imgIdx': imageIndex,
      };

  factory TransferMeta.fromJson(Map<String, dynamic> j) => TransferMeta(
        tid: j['tid'] as String,
        fileName: j['name'] as String,
        fileSize: j['size'] as int,
        totalChunks: j['chunks'] as int,
        mimeType: j['mime'] as String? ?? 'application/octet-stream',
        kind: j['kind'] == 'image' ? TransferKind.image : TransferKind.file,
        imageIndex: j['imgIdx'] as int? ?? 0,
      );
}

/// 발신 세션.
class OutgoingTransfer {
  final TransferMeta meta;
  final Uint8List data;
  final String targetNodeIdHex;

  int sentChunks = 0;
  int ackedChunks = 0;
  TransferStatus status = TransferStatus.waiting;

  OutgoingTransfer({
    required this.meta,
    required this.data,
    required this.targetNodeIdHex,
  });

  bool get isComplete => ackedChunks >= meta.totalChunks;
}

/// 수신 세션.
class IncomingTransfer {
  final TransferMeta meta;
  final String senderNodeIdHex;

  /// 수신된 청크 데이터 (인덱스 → 데이터).
  final Map<int, Uint8List> chunks = {};

  TransferStatus status = TransferStatus.waiting;

  IncomingTransfer({required this.meta, required this.senderNodeIdHex});

  int get receivedCount => chunks.length;
  bool get isComplete => chunks.length >= meta.totalChunks;

  /// 수신 완료 시 청크를 순서대로 합쳐 전체 바이트를 반환한다.
  Uint8List assemble() {
    final result = BytesBuilder();
    for (var i = 0; i < meta.totalChunks; i++) {
      final chunk = chunks[i];
      if (chunk == null) throw StateError('Missing chunk $i');
      result.add(chunk);
    }
    return result.toBytes();
  }
}

/// TransferService가 emit하는 이벤트.
sealed class TransferEvent {
  final TransferId tid;
  const TransferEvent(this.tid);
}

class TransferStarted extends TransferEvent {
  final TransferMeta meta;
  final TransferDirection direction;
  const TransferStarted(super.tid, {required this.meta, required this.direction});
}

class TransferProgress extends TransferEvent {
  /// 0.0 ~ 1.0
  final double progress;
  final TransferDirection direction;
  const TransferProgress(super.tid, {required this.progress, required this.direction});
}

class TransferCompleted extends TransferEvent {
  final Uint8List data;
  final TransferMeta meta;
  final TransferDirection direction;
  /// 수신 시 senderId hex, 발신 시 targetId hex — 저장 경로에 사용.
  final String contactNodeIdHex;
  const TransferCompleted(
    super.tid, {
    required this.data,
    required this.meta,
    required this.direction,
    required this.contactNodeIdHex,
  });
}

/// 로컬에 저장된 파일/이미지 레코드.
class TransferFileRecord {
  final String tid;
  final String filePath;
  final String contactHex;
  final String fileName;
  final String mimeType;
  final TransferDirection direction;
  final int timestamp;
  final int fileSize;

  const TransferFileRecord({
    required this.tid,
    required this.filePath,
    required this.contactHex,
    required this.fileName,
    required this.mimeType,
    required this.direction,
    required this.timestamp,
    required this.fileSize,
  });

  bool get isImage =>
      mimeType.startsWith('image/') ||
      fileName.toLowerCase().endsWith('.jpg') ||
      fileName.toLowerCase().endsWith('.jpeg') ||
      fileName.toLowerCase().endsWith('.png') ||
      fileName.toLowerCase().endsWith('.gif') ||
      fileName.toLowerCase().endsWith('.webp');
}

class TransferFailed extends TransferEvent {
  final String reason;
  final TransferDirection direction;
  const TransferFailed(super.tid, {required this.reason, required this.direction});
}
