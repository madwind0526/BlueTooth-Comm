enum TransportKind {
  lan('LAN'),
  wifi('Wi-Fi'),
  bluetooth('BLE');

  final String label;
  const TransportKind(this.label);

  bool get implementedForMessages =>
      this == TransportKind.bluetooth || this == TransportKind.lan;
}

class TransportStatus {
  final TransportKind kind;
  final bool enabled;
  final bool available;

  const TransportStatus({
    required this.kind,
    required this.enabled,
    required this.available,
  });

  TransportStatus copyWith({bool? enabled, bool? available}) {
    return TransportStatus(
      kind: kind,
      enabled: enabled ?? this.enabled,
      available: available ?? this.available,
    );
  }
}
