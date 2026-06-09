// lib/features/transfer/transfer_storage_service.dart
//
// 파일/이미지를 공개 폴더에 자동 저장하는 서비스.
// Android: Documents/Mesh-comm/sent|received/ (쓰기 불가 시 Downloads로 폴백)
// Windows: Documents\Mesh-comm\sent|received\
// 메타데이터: appSupportDir/mesh_meta/<contactHex>/<tid>.json

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'transfer_model.dart';

class TransferStorageService {
  static final _instance = TransferStorageService._();
  factory TransferStorageService() => _instance;
  TransferStorageService._();

  /// 공개 Mesh-comm 디렉토리를 반환한다.
  /// Android: Documents → Downloads → app docs 순으로 폴백
  /// Windows: Documents\Mesh-comm\
  static Future<Directory> meshCommPublicDir({String sub = ''}) async {
    if (Platform.isAndroid) {
      final extDir = await getExternalStorageDirectory();
      if (extDir != null) {
        // extDir = /storage/emulated/0/Android/data/<pkg>/files
        // 4단계 위 = /storage/emulated/0
        final storageRoot = extDir.parent.parent.parent.parent.path;
        for (final folder in ['Documents', 'Downloads']) {
          try {
            final target = sub.isEmpty
                ? Directory(p.join(storageRoot, folder, 'Mesh-comm'))
                : Directory(p.join(storageRoot, folder, 'Mesh-comm', sub));
            await target.create(recursive: true);
            final probe = File(p.join(target.path, '.probe'));
            await probe.writeAsString('x');
            await probe.delete();
            return target;
          } catch (_) {
            continue;
          }
        }
      }
    } else {
      // Windows: C:\Users\<user>\Documents\Mesh-comm\
      final docs = await getApplicationDocumentsDirectory();
      final target = sub.isEmpty
          ? Directory(p.join(docs.path, 'Mesh-comm'))
          : Directory(p.join(docs.path, 'Mesh-comm', sub));
      if (!await target.exists()) await target.create(recursive: true);
      return target;
    }
    // 최후 폴백: 앱 내부 documents
    final appDocs = await getApplicationDocumentsDirectory();
    final target = sub.isEmpty
        ? Directory(p.join(appDocs.path, 'Mesh-comm'))
        : Directory(p.join(appDocs.path, 'Mesh-comm', sub));
    if (!await target.exists()) await target.create(recursive: true);
    return target;
  }

  Future<Directory> _fileDir(TransferDirection direction) async {
    final sub = direction == TransferDirection.outgoing ? 'sent' : 'received';
    return meshCommPublicDir(sub: sub);
  }

  Future<Directory> _metaDir(String contactHex) async {
    final base = await getApplicationSupportDirectory();
    final dir = Directory(p.join(base.path, 'mesh_meta', contactHex));
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  /// 동일 이름 파일이 있으면 name(1).ext, name(2).ext … 형식으로 회피
  Future<String> _resolveFileName(Directory dir, String fileName) async {
    final name = p.basenameWithoutExtension(fileName);
    final ext = p.extension(fileName);
    var candidate = fileName;
    var counter = 1;
    while (await File(p.join(dir.path, candidate)).exists()) {
      candidate = '$name($counter)$ext';
      counter++;
    }
    return candidate;
  }

  Future<void> save({
    required Uint8List data,
    required String tid,
    required String contactHex,
    required String fileName,
    required String mimeType,
    required TransferDirection direction,
    required int fileSize,
  }) async {
    try {
      final fileDir = await _fileDir(direction);
      final resolvedName = await _resolveFileName(fileDir, fileName);
      final destFile = File(p.join(fileDir.path, resolvedName));
      await destFile.writeAsBytes(data);

      final metaDir = await _metaDir(contactHex);
      await File(p.join(metaDir.path, '$tid.json')).writeAsString(
        jsonEncode({
          'tid': tid,
          'fileName': resolvedName,
          'filePath': destFile.path,
          'mimeType': mimeType,
          'direction': direction.name,
          'timestamp': DateTime.now().millisecondsSinceEpoch,
          'fileSize': fileSize,
          'contactHex': contactHex,
        }),
      );
    } catch (e) {
      debugPrint('[TransferStorageService] save error: $e');
    }
  }

  Future<List<TransferFileRecord>> loadAll(String contactHex) async {
    try {
      final metaDir = await _metaDir(contactHex);
      if (!await metaDir.exists()) return [];
      final records = <TransferFileRecord>[];
      await for (final entity in metaDir.list()) {
        if (entity is! File || !entity.path.endsWith('.json')) continue;
        try {
          final json =
              jsonDecode(await entity.readAsString()) as Map<String, dynamic>;
          final tid = json['tid'] as String;
          final filePath = json['filePath'] as String;
          if (!await File(filePath).exists()) continue;
          records.add(
            TransferFileRecord(
              tid: tid,
              filePath: filePath,
              contactHex: contactHex,
              fileName: json['fileName'] as String,
              mimeType: json['mimeType'] as String,
              direction: json['direction'] == 'outgoing'
                  ? TransferDirection.outgoing
                  : TransferDirection.incoming,
              timestamp: json['timestamp'] as int,
              fileSize: json['fileSize'] as int,
            ),
          );
        } catch (_) {}
      }
      records.sort((a, b) => a.timestamp.compareTo(b.timestamp));
      return records;
    } catch (_) {
      return [];
    }
  }

  Future<void> delete(String tid, String contactHex) async {
    try {
      final metaDir = await _metaDir(contactHex);
      final metaFile = File(p.join(metaDir.path, '$tid.json'));
      if (await metaFile.exists()) {
        final json =
            jsonDecode(await metaFile.readAsString()) as Map<String, dynamic>;
        final actualFile = File(json['filePath'] as String);
        if (await actualFile.exists()) await actualFile.delete();
        await metaFile.delete();
      }
    } catch (e) {
      debugPrint('[TransferStorageService] delete error: $e');
    }
  }

  /// 다운로드 폴더 경로 (UI에 표시용)
  static Future<String> downloadsRoot() async {
    final base =
        await getDownloadsDirectory() ??
        await getApplicationDocumentsDirectory();
    return p.join(base.path, 'Mesh-comm');
  }
}
