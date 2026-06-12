import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';

/// 플랫폼별 파일 선택/저장 추상화.
///
/// Android : MethodChannel(com.meshcomm/file_selector)
///   - 불러오기: ACTION_GET_CONTENT  → Samsung My Files (폴더 트리)
///   - 저장하기: ACTION_CREATE_DOCUMENT → DocumentsUI 저장
/// Windows : file_selector 패키지 (openFile / getSaveLocation)
class PlatformFilePicker {
  static const _ch = MethodChannel('com.meshcomm/file_selector');

  // ─── 불러오기 ────────────────────────────────────────────────────────────────

  /// 파일을 선택해 문자열로 반환. 취소 시 null.
  static Future<String?> openFileAsString({
    required String initialDirectory,
    List<XTypeGroup> acceptedTypeGroups = const [],
    String mimeType = '*/*',
  }) async {
    if (Platform.isAndroid) {
      final uriStr = await _ch.invokeMethod<String>('openFilePicker', {
        'initialDirectory': initialDirectory,
        'mimeType': mimeType,
      });
      if (uriStr == null) return null;
      final bytes =
          await _ch.invokeMethod<Uint8List>('readFileFromUri', {'uri': uriStr});
      if (bytes == null) return null;
      return utf8.decode(bytes);
    } else {
      final xfile = await openFile(
        initialDirectory: initialDirectory,
        acceptedTypeGroups: acceptedTypeGroups,
      );
      if (xfile == null) return null;
      return xfile.readAsString();
    }
  }

  /// 파일을 선택해 바이트로 반환. 취소 시 null.
  static Future<Uint8List?> openFileAsBytes({
    required String initialDirectory,
    String mimeType = '*/*',
  }) async {
    if (Platform.isAndroid) {
      final uriStr = await _ch.invokeMethod<String>('openFilePicker', {
        'initialDirectory': initialDirectory,
        'mimeType': mimeType,
      });
      if (uriStr == null) return null;
      return _ch.invokeMethod<Uint8List>('readFileFromUri', {'uri': uriStr});
    } else {
      final xfile = await openFile(initialDirectory: initialDirectory);
      if (xfile == null) return null;
      return xfile.readAsBytes();
    }
  }

  // ─── 저장하기 ────────────────────────────────────────────────────────────────

  /// 파일 저장 다이얼로그 → 문자열 저장. 저장 경로/URI 반환. 취소 시 null.
  static Future<String?> saveFileAsString({
    required String content,
    required String suggestedName,
    required String initialDirectory,
    List<XTypeGroup> acceptedTypeGroups = const [],
  }) async {
    if (Platform.isAndroid) {
      final uriStr = await _ch.invokeMethod<String>('saveFilePicker', {
        'suggestedName': suggestedName,
        'initialDirectory': initialDirectory,
      });
      if (uriStr == null) return null;
      await _ch.invokeMethod('writeFileToUri', {
        'uri': uriStr,
        'bytes': Uint8List.fromList(utf8.encode(content)),
      });
      return uriStr;
    } else {
      final location = await getSaveLocation(
        suggestedName: suggestedName,
        initialDirectory: initialDirectory,
        acceptedTypeGroups: acceptedTypeGroups,
      );
      if (location == null) return null;
      await File(location.path).writeAsString(content);
      return location.path;
    }
  }

  /// 파일 저장 다이얼로그 → 바이트 저장. 저장 경로/URI 반환. 취소 시 null.
  static Future<String?> saveFileAsBytes({
    required Uint8List bytes,
    required String suggestedName,
    required String initialDirectory,
  }) async {
    if (Platform.isAndroid) {
      final uriStr = await _ch.invokeMethod<String>('saveFilePicker', {
        'suggestedName': suggestedName,
        'initialDirectory': initialDirectory,
      });
      if (uriStr == null) return null;
      await _ch.invokeMethod('writeFileToUri', {
        'uri': uriStr,
        'bytes': bytes,
      });
      return uriStr;
    } else {
      final location = await getSaveLocation(
        suggestedName: suggestedName,
        initialDirectory: initialDirectory,
      );
      if (location == null) return null;
      await File(location.path).writeAsBytes(bytes);
      return location.path;
    }
  }
}
