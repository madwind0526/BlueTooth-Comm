class AppVersion {
  AppVersion._();

  static const version = String.fromEnvironment(
    'MESHCOMM_VERSION',
    defaultValue: '1.2.X',
  );
  static const buildTime = String.fromEnvironment(
    'MESHCOMM_BUILD_TIME',
    defaultValue: 'local',
  );

  static String get shortLabel {
    final baseVersion = version.split('+').first;
    return 'V$baseVersion';
  }

  static String get buildLabel => 'Build: v$version / $buildTime';
}
