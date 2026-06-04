import 'dart:convert';
import 'dart:typed_data';

import 'package:mesh_comm/core/crypto/crypto_service.dart';
import 'package:mesh_comm/core/storage/database_service.dart';

class IdentityBackupService {
  IdentityBackupService({DatabaseService? database, CryptoService? crypto})
    : _db = database ?? DatabaseService(),
      _crypto = crypto ?? CryptoService();

  final DatabaseService _db;
  final CryptoService _crypto;

  Future<String> exportToJson() async {
    final identity = await _db.getIdentity();
    if (identity == null) {
      throw StateError('No identity is stored yet.');
    }

    final nodeId = identity['node_id'] as Uint8List;
    final publicKey = identity['public_key'] as Uint8List;
    final privateKey = identity['private_key'] as Uint8List;
    final encryptionPublicKey = identity['encryption_public_key'] as Uint8List?;
    final encryptionPrivateKey =
        identity['encryption_private_key'] as Uint8List?;

    if (encryptionPublicKey == null || encryptionPrivateKey == null) {
      throw StateError('Identity encryption keys are not ready yet.');
    }

    final payload = {
      'format': 'mesh_comm_identity_backup',
      'version': 1,
      'exportedAt': DateTime.now().toIso8601String(),
      'nodeId': _bytesToHex(nodeId),
      'publicKey': _bytesToHex(publicKey),
      'privateKey': _bytesToHex(privateKey),
      'encryptionPublicKey': _bytesToHex(encryptionPublicKey),
      'encryptionPrivateKey': _bytesToHex(encryptionPrivateKey),
    };
    return const JsonEncoder.withIndent('  ').convert(payload);
  }

  Future<String> restoreFromJson(String rawJson) async {
    final decoded = jsonDecode(rawJson);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Invalid identity backup file.');
    }
    if (decoded['format'] != 'mesh_comm_identity_backup' ||
        decoded['version'] != 1) {
      throw const FormatException('Unsupported identity backup file.');
    }

    final nodeId = _requireHexBytes(decoded['nodeId'] as String?, 16, 'nodeId');
    final publicKey = _requireHexBytes(
      decoded['publicKey'] as String?,
      32,
      'publicKey',
    );
    final privateKey = _requireHexBytes(
      decoded['privateKey'] as String?,
      32,
      'privateKey',
    );
    final encryptionPublicKey = _requireHexBytes(
      decoded['encryptionPublicKey'] as String?,
      32,
      'encryptionPublicKey',
    );
    final encryptionPrivateKey = _requireHexBytes(
      decoded['encryptionPrivateKey'] as String?,
      32,
      'encryptionPrivateKey',
    );

    final expectedNodeId = _crypto.nodeIdFromPublicKey(publicKey);
    if (!_bytesEqual(nodeId, expectedNodeId)) {
      throw const FormatException('Backup nodeId does not match publicKey.');
    }

    final probe = Uint8List.fromList(utf8.encode('mesh_comm_identity_probe'));
    final signature = await _crypto.sign(probe, privateKey);
    final keyPairMatches = await _crypto.verify(probe, signature, publicKey);
    if (!keyPairMatches) {
      throw const FormatException(
        'Backup privateKey does not match publicKey.',
      );
    }

    await _db.saveIdentity(
      nodeId,
      publicKey,
      privateKey,
      encryptionPublicKey,
      encryptionPrivateKey,
    );
    return _bytesToHex(nodeId);
  }

  Uint8List _requireHexBytes(String? hex, int length, String label) {
    final bytes = _hexToBytes(hex);
    if (bytes == null || bytes.length != length) {
      throw FormatException('Invalid $label.');
    }
    return bytes;
  }

  Uint8List? _hexToBytes(String? hex) {
    if (hex == null || hex.length.isOdd) return null;
    try {
      return Uint8List.fromList([
        for (var i = 0; i < hex.length; i += 2)
          int.parse(hex.substring(i, i + 2), radix: 16),
      ]);
    } catch (_) {
      return null;
    }
  }

  String _bytesToHex(Uint8List bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  bool _bytesEqual(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
