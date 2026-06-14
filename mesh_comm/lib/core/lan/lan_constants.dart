// lib/core/lan/lan_constants.dart

class LanConstants {
  LanConstants._();

  /// UDP beacon receive port (listens for multicast/broadcast)
  static const int udpPort = 7654;

  /// TCP GATT server port
  static const int tcpPort = 7655;

  /// UDP multicast group (link-local scope)
  static const String multicastGroup = '224.0.0.251';

  /// Beacon transmission interval
  static const Duration beaconInterval = Duration(seconds: 5);

  /// Reconnect delay after TCP disconnection
  static const Duration reconnectDelay = Duration(seconds: 3);

  /// Connection timeout when peer does not respond
  static const Duration connectTimeout = Duration(seconds: 5);

  /// TCP packet receive buffer size
  static const int readBufferSize = 65536;

  /// Beacon identifier (first 4 bytes)
  static const String beaconMagic = 'MSHC';
}
