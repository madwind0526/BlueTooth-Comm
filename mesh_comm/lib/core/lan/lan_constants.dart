// lib/core/lan/lan_constants.dart

class LanConstants {
  LanConstants._();

  /// UDP 비콘 수신 포트 (멀티캐스트/브로드캐스트 대기)
  static const int udpPort = 7654;

  /// TCP GATT 서버 포트
  static const int tcpPort = 7655;

  /// UDP 멀티캐스트 그룹 (링크-로컬 범위)
  static const String multicastGroup = '224.0.0.251';

  /// 비콘 전송 주기
  static const Duration beaconInterval = Duration(seconds: 30);

  /// 피어 응답 없을 시 연결 타임아웃
  static const Duration connectTimeout = Duration(seconds: 5);

  /// TCP 패킷 수신 버퍼 크기
  static const int readBufferSize = 65536;

  /// 비콘 식별자 (첫 4바이트)
  static const String beaconMagic = 'MSHC';
}
