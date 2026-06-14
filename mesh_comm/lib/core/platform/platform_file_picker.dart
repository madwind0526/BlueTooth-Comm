import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';

/// Platform-specific file open/save abstraction.
///
/// Android : MethodChannel(com.meshcomm/file_selector)
///   - Open: ACTION_GET_CONTENT  → Samsung My Files (folder tree)
///   - Save: ACTION_CREATE_DOCUMENT → DocumentsUI save
/// Windows : file_selector package (openFile / getSaveLocation)
class PlatformFilePicker {
  static const _ch = MethodChannel('com.meshcomm/file_selector');

  // ─── Open ─────────────────────────────────────────────────────────────────

  /// Opens a file and returns it as a string. Returns null on cancel.
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

  /// Opens a file and returns it as bytes. Returns null on cancel.
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

  // ─── Save ─────────────────────────────────────────────────────────────────

  /// Shows a save file dialog and writes a string. Returns the saved path/URI, or null on cancel.
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

  /// Shows a save file dialog and writes bytes. Returns the saved path/URI, or null on cancel.
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
