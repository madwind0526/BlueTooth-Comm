// lib/features/transfer/transfer_storage_service.dart
//
// 파일/이미지를 앱 지원 디렉터리에 저장하고 불러오는 서비스.
// 경로: <appSupportDir>/mesh_files/<contactHex>/<tid>.bin + <tid>.json

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

  Future<Directory> _dir(String contactHex) async {
    final base = await getApplicationSupportDirectory();
    final dir = Directory(p.join(base.path, 'mesh_files', contactHex));
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
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
      final dir = await _dir(contactHex);
      await File(p.join(dir.path, '$tid.bin')).writeAsBytes(data);
      await File(p.join(dir.path, '$tid.json')).writeAsString(
        jsonEncode({
          'tid': tid,
          'fileName': fileName,
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
      final dir = await _dir(contactHex);
      if (!await dir.exists()) return [];
      final records = <TransferFileRecord>[];
      await for (final entity in dir.list()) {
        if (entity is! File || !entity.path.endsWith('.json')) continue;
        try {
          final json = jsonDecode(await entity.readAsString()) as Map<String, dynamic>;
          final tid = json['tid'] as String;
          final binPath = p.join(dir.path, '$tid.bin');
          if (!await File(binPath).exists()) continue;
          records.add(TransferFileRecord(
            tid: tid,
            filePath: binPath,
            contactHex: contactHex,
            fileName: json['fileName'] as String,
            mimeType: json['mimeType'] as String,
            direction: json['direction'] == 'outgoing'
                ? TransferDirection.outgoing
                : TransferDirection.incoming,
            timestamp: json['timestamp'] as int,
            fileSize: json['fileSize'] as int,
          ));
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
      final dir = await _dir(contactHex);
      final bin = File(p.join(dir.path, '$tid.bin'));
      final meta = File(p.join(dir.path, '$tid.json'));
      if (await bin.exists()) await bin.delete();
      if (await meta.exists()) await meta.delete();
    } catch (e) {
      debugPrint('[TransferStorageService] delete error: $e');
    }
  }
}
