/// Compile-time diagnostic configuration.
///
/// All values default in normal builds, so they do not affect app behavior.
class DiagnosticConfig {
  DiagnosticConfig._();

  static const String label = String.fromEnvironment(
    'MESHCOMM_DIAGNOSTIC_LABEL',
  );

  static const bool disableScan = bool.fromEnvironment(
    'MESHCOMM_DIAGNOSTIC_DISABLE_SCAN',
  );

  static const bool disableAdvertising = bool.fromEnvironment(
    'MESHCOMM_DIAGNOSTIC_DISABLE_ADVERTISE',
  );

  static const bool stopAdvertisingAfterPeripheralConnect =
      bool.fromEnvironment(
        'MESHCOMM_DIAGNOSTIC_STOP_ADVERTISE_AFTER_PERIPHERAL_CONNECT',
      );

  static const String targetNodeId = String.fromEnvironment(
    'MESHCOMM_DIAGNOSTIC_TARGET_NODE_ID',
  );

  static void logConfiguration() {
    if (label.isEmpty &&
        !disableScan &&
        !disableAdvertising &&
        !stopAdvertisingAfterPeripheralConnect &&
        targetNodeId.isEmpty) {
      return;
    }

    // ignore: avoid_print
    print(
      '[DiagnosticConfig] label=$label disableScan=$disableScan '
      'disableAdvertising=$disableAdvertising '
      'stopAdvertisingAfterPeripheralConnect=$stopAdvertisingAfterPeripheralConnect '
      'targetNodeId=$targetNodeId',
    );
  }
}
