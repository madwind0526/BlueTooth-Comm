import 'dart:math';
import 'dart:typed_data';

import 'ble_constants.dart';

/// BLE ATT payload 크기에 맞춰 MeshPacket bytes를 나누는 전송 프레임.
class BleFragmentCodec {
  BleFragmentCodec._();

  static const int _magic0 = 0x4d; // M
  static const int _magic1 = 0x43; // C
  static const int frameVersion = 1;
  static const int headerSize = 12;
  static final Random _random = Random.secure();

  static bool isFragment(Uint8List bytes) =>
      bytes.length >= 2 && bytes[0] == _magic0 && bytes[1] == _magic1;

  static List<Uint8List> fragment(
    Uint8List bytes, {
    required int mtu,
    int? transferId,
  }) {
    final chunkSize = mtu - BleConstants.attOverhead - headerSize;
    if (chunkSize < 1) {
      throw ArgumentError.value(
        mtu,
        'mtu',
        'MTU is too small for frame header',
      );
    }

    final count = bytes.isEmpty
        ? 1
        : (bytes.length + chunkSize - 1) ~/ chunkSize;
    if (count > BleConstants.maxFragmentCount) {
      throw ArgumentError('packet requires too many BLE fragments: $count');
    }

    final id = transferId ?? _random.nextInt(0x100000000);
    return List.generate(count, (index) {
      final start = index * chunkSize;
      final end = min(start + chunkSize, bytes.length);
      final payload = bytes.sublist(start, end);
      final frame = Uint8List(headerSize + payload.length);
      final data = ByteData.sublistView(frame);
      data.setUint8(0, _magic0);
      data.setUint8(1, _magic1);
      data.setUint8(2, frameVersion);
      data.setUint8(3, 0); // reserved flags
      data.setUint32(4, id, Endian.big);
      data.setUint16(8, index, Endian.big);
      data.setUint16(10, count, Endian.big);
      frame.setRange(headerSize, frame.length, payload);
      return frame;
    });
  }

  static BleFragmentFrame? parse(Uint8List bytes) {
    if (!isFragment(bytes) || bytes.length < headerSize) return null;
    final data = ByteData.sublistView(bytes);
    if (data.getUint8(2) != frameVersion) return null;

    final index = data.getUint16(8, Endian.big);
    final count = data.getUint16(10, Endian.big);
    if (count < 1 || count > BleConstants.maxFragmentCount || index >= count) {
      return null;
    }
    final payload = Uint8List.fromList(bytes.sublist(headerSize));
    if (count > 1 && payload.isEmpty) return null;

    return BleFragmentFrame(
      transferId: data.getUint32(4, Endian.big),
      index: index,
      count: count,
      payload: payload,
    );
  }
}

class BleFragmentFrame {
  final int transferId;
  final int index;
  final int count;
  final Uint8List payload;

  const BleFragmentFrame({
    required this.transferId,
    required this.index,
    required this.count,
    required this.payload,
  });
}

/// device별로 도착한 BLE 조각을 모아 원래 MeshPacket bytes로 복원한다.
class BleFragmentReassembler {
  final Map<String, _FragmentAssembly> _assemblies = {};

  Uint8List? add(String deviceId, Uint8List bytes) {
    _cleanExpired();
    final frame = BleFragmentCodec.parse(bytes);
    if (frame == null) return null;

    final key = '$deviceId:${frame.transferId}';
    var assembly = _assemblies[key];
    if (assembly == null || assembly.count != frame.count) {
      assembly = _FragmentAssembly(frame.count);
      _assemblies[key] = assembly;
    }
    final existingFragment = assembly.fragments[frame.index];
    if (existingFragment != null &&
        !_bytesEqual(existingFragment, frame.payload)) {
      assembly = _FragmentAssembly(frame.count);
      _assemblies[key] = assembly;
    }
    assembly.fragments[frame.index] = frame.payload;

    if (assembly.fragments.length != assembly.count) return null;

    final builder = BytesBuilder(copy: false);
    for (var index = 0; index < assembly.count; index++) {
      final fragment = assembly.fragments[index];
      if (fragment == null) return null;
      builder.add(fragment);
    }
    _assemblies.remove(key);
    return builder.takeBytes();
  }

  void removeDevice(String deviceId) {
    _assemblies.removeWhere((key, _) => key.startsWith('$deviceId:'));
  }

  void clear() => _assemblies.clear();

  void _cleanExpired() {
    final cutoff = DateTime.now().subtract(
      BleConstants.fragmentAssemblyTimeout,
    );
    _assemblies.removeWhere(
      (_, assembly) => assembly.createdAt.isBefore(cutoff),
    );
  }

  bool _bytesEqual(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

class _FragmentAssembly {
  final int count;
  final DateTime createdAt = DateTime.now();
  final Map<int, Uint8List> fragments = {};

  _FragmentAssembly(this.count);
}
