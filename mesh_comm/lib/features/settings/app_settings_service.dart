import 'dart:async';

import 'package:mesh_comm/core/storage/database_service.dart';
import 'package:mesh_comm/features/settings/app_settings.dart';

class AppSettingsService {
  static final AppSettingsService _instance = AppSettingsService._internal();
  factory AppSettingsService() => _instance;
  AppSettingsService._internal();

  final _db = DatabaseService();
  final _controller = StreamController<AppSettings>.broadcast();

  AppSettings _current = const AppSettings();

  AppSettings get current => _current;
  Stream<AppSettings> get settingsStream => _controller.stream;

  Future<AppSettings> load() async {
    final values = await _db.getSettings();
    _current = AppSettings.fromMap(values);
    _emit();
    return _current;
  }

  Future<void> save(AppSettings settings, {bool notify = true}) async {
    _current = settings;
    await _db.setSettings(settings.toMap());
    if (notify) {
      _emit();
    }
  }

  void _emit() {
    if (!_controller.isClosed) {
      _controller.add(_current);
    }
  }

  Future<void> dispose() async {
    await _controller.close();
  }
}
