import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:mesh_comm/core/crypto/crypto_service.dart';
import 'package:mesh_comm/core/storage/database_service.dart';

class IdentityBackupService {
  IdentityBackupService({DatabaseService? database, CryptoService? crypto})
    : _db = database ?? DatabaseService(),
      _crypto = crypto ?? CryptoService();

  final DatabaseService _db;
  final CryptoService _crypto;
  final AesGcm _aesGcm = AesGcm.with256bits();

  static const _format = 'mesh_comm_identity_backup_encrypted';
  static const _version = 2;
  static const _kdf = 'pbkdf2_hmac_sha256';
  static const _kdfIterations = 210000;
  static const _saltLength = 16;
  static const _nonceLength = 12;

  Future<String> exportToJson({required String password}) async {
    _validatePassword(password);
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

    final payload = jsonEncode({
      'format': 'mesh_comm_identity_payload',
      'version': 1,
      'exportedAt': DateTime.now().toIso8601String(),
      'nodeId': _bytesToHex(nodeId),
      'publicKey': _bytesToHex(publicKey),
      'privateKey': _bytesToHex(privateKey),
      'encryptionPublicKey': _bytesToHex(encryptionPublicKey),
      'encryptionPrivateKey': _bytesToHex(encryptionPrivateKey),
    });

    final salt = _randomBytes(_saltLength);
    final nonce = _randomBytes(_nonceLength);
    final key = await _deriveBackupKey(password, salt);
    final box = await _aesGcm.encrypt(
      utf8.encode(payload),
      secretKey: key,
      nonce: nonce,
    );

    final encryptedBackup = {
      'format': _format,
      'version': _version,
      'kdf': _kdf,
      'iterations': _kdfIterations,
      'salt': _bytesToHex(salt),
      'nonce': _bytesToHex(Uint8List.fromList(box.nonce)),
      'cipherText': _bytesToHex(Uint8List.fromList(box.cipherText)),
      'mac': _bytesToHex(Uint8List.fromList(box.mac.bytes)),
    };
    return const JsonEncoder.withIndent('  ').convert(encryptedBackup);
  }

  Future<String> restoreFromJson(
    String rawJson, {
    required String password,
  }) async {
    _validatePassword(password);
    final decoded = jsonDecode(rawJson);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Invalid identity backup file.');
    }
    if (decoded['format'] != _format ||
        decoded['version'] != _version ||
        decoded['kdf'] != _kdf ||
        decoded['iterations'] != _kdfIterations) {
      throw const FormatException('Unsupported encrypted identity backup.');
    }

    final salt = _requireHexBytes(
      decoded['salt'] as String?,
      _saltLength,
      'salt',
    );
    final nonce = _requireHexBytes(
      decoded['nonce'] as String?,
      _nonceLength,
      'nonce',
    );
    final cipherText = _hexToBytes(decoded['cipherText'] as String?);
    final macBytes = _requireHexBytes(decoded['mac'] as String?, 16, 'mac');
    if (cipherText == null || cipherText.isEmpty) {
      throw const FormatException('Invalid cipherText.');
    }

    final key = await _deriveBackupKey(password, salt);
    final plaintext = await _decryptBackupPayload(
      key: key,
      nonce: nonce,
      cipherText: cipherText,
      macBytes: macBytes,
    );
    final payload = jsonDecode(utf8.decode(plaintext));
    if (payload is! Map<String, dynamic> ||
        payload['format'] != 'mesh_comm_identity_payload' ||
        payload['version'] != 1) {
      throw const FormatException('Invalid encrypted identity payload.');
    }

    return _restorePayload(payload);
  }

  Future<String> _restorePayload(Map<String, dynamic> decoded) async {
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

  Future<SecretKey> _deriveBackupKey(String password, Uint8List salt) async {
    final pbkdf2 = Pbkdf2(
      macAlgorithm: Hmac.sha256(),
      iterations: _kdfIterations,
      bits: 256,
    );
    return pbkdf2.deriveKey(
      secretKey: SecretKey(utf8.encode(password)),
      nonce: salt,
    );
  }

  Future<Uint8List> _decryptBackupPayload({
    required SecretKey key,
    required Uint8List nonce,
    required Uint8List cipherText,
    required Uint8List macBytes,
  }) async {
    try {
      final bytes = await _aesGcm.decrypt(
        SecretBox(cipherText, nonce: nonce, mac: Mac(macBytes)),
        secretKey: key,
      );
      return Uint8List.fromList(bytes);
    } catch (_) {
      throw const FormatException('Invalid password or corrupted backup.');
    }
  }

  void _validatePassword(String password) {
    if (password.length < 8) {
      throw const FormatException('Backup password must be at least 8 chars.');
    }
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

  Uint8List _randomBytes(int length) {
    final random = Random.secure();
    return Uint8List.fromList([
      for (var i = 0; i < length; i++) random.nextInt(256),
    ]);
  }

  bool _bytesEqual(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
