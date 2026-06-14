// core/crypto/crypto_service.dart

import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';

/// CryptoService
///
/// Cryptographic service for offline P2P mesh networking.
/// Handles Ed25519 signing, X25519 key exchange, and AES-GCM encryption.
///
/// Security principles (RULES.md R-06, R-07, R-14):
///   - node_id = first 16 bytes of SHA-256(public key) (R-06)
///   - All packets must be Ed25519-signed (R-07)
///   - Payload is encrypted with X25519+AES-GCM; relay nodes cannot read it (R-14)
class CryptoService {
  static final CryptoService _instance = CryptoService._internal();
  factory CryptoService() => _instance;
  CryptoService._internal();

  final Ed25519 _ed25519 = Ed25519();
  final X25519 _x25519 = X25519();
  final AesGcm _aesGcm = AesGcm.with256bits();

  // ── 1. Ed25519 key pair generation ────────────────────────────────────────

  /// Generates an Ed25519 key pair.
  ///
  /// Returns: `({Uint8List publicKey, Uint8List privateKey})`
  ///   - publicKey  32 bytes
  ///   - privateKey 32 bytes (seed)
  Future<({Uint8List publicKey, Uint8List privateKey})>
  generateKeyPair() async {
    try {
      final keyPair = await _ed25519.newKeyPair();
      final privateKeyBytes = await (keyPair as SimpleKeyPairData)
          .extractPrivateKeyBytes();
      final publicKey = await keyPair.extractPublicKey();
      return (
        publicKey: Uint8List.fromList(publicKey.bytes),
        privateKey: Uint8List.fromList(privateKeyBytes),
      );
    } catch (_) {
      rethrow;
    }
  }

  /// Generates an X25519 message encryption key pair.
  Future<({Uint8List publicKey, Uint8List privateKey})>
  generateEncryptionKeyPair() async {
    final keyPair = await _x25519.newKeyPair();
    final privateKeyBytes = await (keyPair as SimpleKeyPairData)
        .extractPrivateKeyBytes();
    final publicKey = await keyPair.extractPublicKey();
    return (
      publicKey: Uint8List.fromList(publicKey.bytes),
      privateKey: Uint8List.fromList(privateKeyBytes),
    );
  }

  // ── 2. node_id generation ──────────────────────────────────────────────────

  /// node_id = first 16 bytes of SHA-256(publicKey).
  ///
  /// Deterministic generation → not forgeable (R-06).
  Uint8List nodeIdFromPublicKey(Uint8List publicKey) {
    // cryptography package's Sha256.hash() is async, so
    // this synchronous method uses the internal pure-Dart SHA-256 implementation.
    final hash = _syncSha256(publicKey);
    return Uint8List.fromList(hash.sublist(0, 16));
  }

  // ── 3. Packet signing ──────────────────────────────────────────────────────

  /// Signs data with an Ed25519 private key.
  ///
  /// Returns: 64-byte signature
  Future<Uint8List> sign(Uint8List data, Uint8List privateKey) async {
    try {
      final keyPair = await _ed25519.newKeyPairFromSeed(privateKey);
      final signature = await _ed25519.sign(data, keyPair: keyPair);
      return Uint8List.fromList(signature.bytes);
    } catch (_) {
      rethrow;
    }
  }

  // ── 4. Signature verification ──────────────────────────────────────────────

  /// Verifies an Ed25519 signature.
  ///
  /// Returns false on verification failure (must not throw — R-07 discard packets with invalid signatures).
  Future<bool> verify(
    Uint8List data,
    Uint8List signature,
    Uint8List publicKey,
  ) async {
    try {
      if (signature.length != 64) return false;
      final pubKey = SimplePublicKey(publicKey, type: KeyPairType.ed25519);
      final sig = Signature(signature, publicKey: pubKey);
      return await _ed25519.verify(data, signature: sig);
    } catch (_) {
      return false;
    }
  }

  // ── 5. X25519 shared secret generation ────────────────────────────────────

  /// Computes a shared secret via X25519 ECDH.
  ///
  /// Used as E2E encryption key material (R-14).
  /// Returns: 32-byte raw shared secret
  Future<Uint8List> computeSharedSecret(
    Uint8List myPrivateKey,
    Uint8List theirPublicKey,
  ) async {
    try {
      final myKeyPair = await _x25519.newKeyPairFromSeed(myPrivateKey);
      final theirPubKey = SimplePublicKey(
        theirPublicKey,
        type: KeyPairType.x25519,
      );
      final sharedSecret = await _x25519.sharedSecretKey(
        keyPair: myKeyPair,
        remotePublicKey: theirPubKey,
      );
      final bytes = await sharedSecret.extractBytes();
      return Uint8List.fromList(bytes);
    } catch (_) {
      rethrow;
    }
  }

  // ── 6. AES-GCM encryption ─────────────────────────────────────────────────

  /// Encrypts plaintext with AES-GCM (256-bit).
  ///
  /// Return format: nonce(12 bytes) || ciphertext+tag
  /// sharedSecret must be 32 bytes.
  Future<Uint8List> encrypt(Uint8List plaintext, Uint8List sharedSecret) async {
    try {
      final secretKey = SecretKey(sharedSecret);
      final box = await _aesGcm.encrypt(plaintext, secretKey: secretKey);
      // nonce(12) + ciphertext + mac(16)
      final result = Uint8List(
        box.nonce.length + box.cipherText.length + box.mac.bytes.length,
      );
      var offset = 0;
      result.setRange(offset, offset + box.nonce.length, box.nonce);
      offset += box.nonce.length;
      result.setRange(offset, offset + box.cipherText.length, box.cipherText);
      offset += box.cipherText.length;
      result.setRange(offset, offset + box.mac.bytes.length, box.mac.bytes);
      return result;
    } catch (_) {
      rethrow;
    }
  }

  // ── 7. AES-GCM decryption ─────────────────────────────────────────────────

  /// Decrypts bytes in nonce(12 bytes) || ciphertext+tag format.
  ///
  /// Returns null on decryption failure (MAC mismatch, wrong key, etc.).
  Future<Uint8List?> decrypt(
    Uint8List ciphertext,
    Uint8List sharedSecret,
  ) async {
    try {
      const nonceLength = 12;
      const macLength = 16;
      if (ciphertext.length < nonceLength + macLength) return null;

      final nonce = ciphertext.sublist(0, nonceLength);
      final body = ciphertext.sublist(nonceLength);
      final cipherBody = body.sublist(0, body.length - macLength);
      final mac = Mac(body.sublist(body.length - macLength));

      final secretKey = SecretKey(sharedSecret);
      final box = SecretBox(cipherBody, nonce: nonce, mac: mac);
      final plaintext = await _aesGcm.decrypt(box, secretKey: secretKey);
      return Uint8List.fromList(plaintext);
    } catch (_) {
      return null;
    }
  }

  // ── 8. Public key fingerprint ─────────────────────────────────────────────

  /// Public key fingerprint for TOFU verification.
  ///
  /// Format: "A1B2-C3D4-E5F6-G7H8" (first 8 bytes of SHA-256, 4-group uppercase hex)
  /// Users compare verbally or via QR (R-08).
  String fingerprint(Uint8List publicKey) {
    final hash = _syncSha256(publicKey);
    final hex = hash
        .sublist(0, 8)
        .map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase())
        .join();
    // Concatenate 2 chars at a time and split into 4 groups (4 bytes = 8 hex chars per group)
    return '${hex.substring(0, 4)}-'
        '${hex.substring(4, 8)}-'
        '${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}';
  }

  // ── Internal: synchronous SHA-256 ────────────────────────────────────────

  /// Pure-Dart SHA-256 implementation.
  ///
  /// Because cryptography package's Sha256.hash() is async,
  /// this internal synchronous implementation is provided for use in
  /// nodeIdFromPublicKey (sync method) and fingerprint (sync method).
  ///
  /// Standard FIPS 180-4 SHA-256 implementation.
  static Uint8List _syncSha256(Uint8List data) {
    // SHA-256 initial hash values (fractional parts of square roots of first 8 primes)
    final h = [
      0x6a09e667,
      0xbb67ae85,
      0x3c6ef372,
      0xa54ff53a,
      0x510e527f,
      0x9b05688c,
      0x1f83d9ab,
      0x5be0cd19,
    ];

    // SHA-256 round constants (fractional parts of cube roots of first 64 primes)
    const k = [
      0x428a2f98,
      0x71374491,
      0xb5c0fbcf,
      0xe9b5dba5,
      0x3956c25b,
      0x59f111f1,
      0x923f82a4,
      0xab1c5ed5,
      0xd807aa98,
      0x12835b01,
      0x243185be,
      0x550c7dc3,
      0x72be5d74,
      0x80deb1fe,
      0x9bdc06a7,
      0xc19bf174,
      0xe49b69c1,
      0xefbe4786,
      0x0fc19dc6,
      0x240ca1cc,
      0x2de92c6f,
      0x4a7484aa,
      0x5cb0a9dc,
      0x76f988da,
      0x983e5152,
      0xa831c66d,
      0xb00327c8,
      0xbf597fc7,
      0xc6e00bf3,
      0xd5a79147,
      0x06ca6351,
      0x14292967,
      0x27b70a85,
      0x2e1b2138,
      0x4d2c6dfc,
      0x53380d13,
      0x650a7354,
      0x766a0abb,
      0x81c2c92e,
      0x92722c85,
      0xa2bfe8a1,
      0xa81a664b,
      0xc24b8b70,
      0xc76c51a3,
      0xd192e819,
      0xd6990624,
      0xf40e3585,
      0x106aa070,
      0x19a4c116,
      0x1e376c08,
      0x2748774c,
      0x34b0bcb5,
      0x391c0cb3,
      0x4ed8aa4a,
      0x5b9cca4f,
      0x682e6ff3,
      0x748f82ee,
      0x78a5636f,
      0x84c87814,
      0x8cc70208,
      0x90befffa,
      0xa4506ceb,
      0xbef9a3f7,
      0xc67178f2,
    ];

    // Padding
    final bitLen = data.length * 8;
    final padLen = (data.length + 9 + 63) & ~63;
    final padded = Uint8List(padLen);
    padded.setRange(0, data.length, data);
    padded[data.length] = 0x80;
    // big-endian 64-bit length
    for (var i = 0; i < 8; i++) {
      padded[padLen - 8 + i] = (bitLen >> (56 - i * 8)) & 0xff;
    }

    // Block processing
    final hh = List<int>.from(h);
    for (var offset = 0; offset < padLen; offset += 64) {
      final w = List<int>.filled(64, 0);
      for (var i = 0; i < 16; i++) {
        w[i] =
            ((padded[offset + i * 4] & 0xff) << 24) |
            ((padded[offset + i * 4 + 1] & 0xff) << 16) |
            ((padded[offset + i * 4 + 2] & 0xff) << 8) |
            (padded[offset + i * 4 + 3] & 0xff);
      }
      for (var i = 16; i < 64; i++) {
        final s0 =
            _rotr32(w[i - 15], 7) ^ _rotr32(w[i - 15], 18) ^ (w[i - 15] >>> 3);
        final s1 =
            _rotr32(w[i - 2], 17) ^ _rotr32(w[i - 2], 19) ^ (w[i - 2] >>> 10);
        w[i] = (w[i - 16] + s0 + w[i - 7] + s1) & 0xffffffff;
      }

      var a = hh[0],
          b = hh[1],
          c = hh[2],
          d = hh[3],
          e = hh[4],
          f = hh[5],
          g = hh[6],
          hv = hh[7];

      for (var i = 0; i < 64; i++) {
        final bigSigma1 = _rotr32(e, 6) ^ _rotr32(e, 11) ^ _rotr32(e, 25);
        final ch = (e & f) ^ ((~e & 0xffffffff) & g);
        final temp1 = (hv + bigSigma1 + ch + k[i] + w[i]) & 0xffffffff;
        final bigSigma0 = _rotr32(a, 2) ^ _rotr32(a, 13) ^ _rotr32(a, 22);
        final maj = (a & b) ^ (a & c) ^ (b & c);
        final temp2 = (bigSigma0 + maj) & 0xffffffff;

        hv = g;
        g = f;
        f = e;
        e = (d + temp1) & 0xffffffff;
        d = c;
        c = b;
        b = a;
        a = (temp1 + temp2) & 0xffffffff;
      }

      hh[0] = (hh[0] + a) & 0xffffffff;
      hh[1] = (hh[1] + b) & 0xffffffff;
      hh[2] = (hh[2] + c) & 0xffffffff;
      hh[3] = (hh[3] + d) & 0xffffffff;
      hh[4] = (hh[4] + e) & 0xffffffff;
      hh[5] = (hh[5] + f) & 0xffffffff;
      hh[6] = (hh[6] + g) & 0xffffffff;
      hh[7] = (hh[7] + hv) & 0xffffffff;
    }

    final digest = Uint8List(32);
    for (var i = 0; i < 8; i++) {
      digest[i * 4] = (hh[i] >> 24) & 0xff;
      digest[i * 4 + 1] = (hh[i] >> 16) & 0xff;
      digest[i * 4 + 2] = (hh[i] >> 8) & 0xff;
      digest[i * 4 + 3] = hh[i] & 0xff;
    }
    return digest;
  }

  static int _rotr32(int x, int n) {
    x &= 0xffffffff;
    return ((x >>> n) | (x << (32 - n))) & 0xffffffff;
  }
}
