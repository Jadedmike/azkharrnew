import 'package:adhan/adhan.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/prayer_notification_settings.dart';

/// Signature for providing a [SharedPreferences] instance.
typedef NotificationPreferencesProvider = Future<SharedPreferences> Function();

/// Exception thrown when persisting or clearing prayer notification settings
/// or the notification coordinate cache fails.
class PrayerNotificationSettingsStorageException implements Exception {
  final String message;
  final Object? cause;

  const PrayerNotificationSettingsStorageException(
    this.message, {
    this.cause,
  });

  @override
  String toString() {
    if (cause != null) {
      return 'PrayerNotificationSettingsStorageException: $message (cause: $cause)';
    }
    return 'PrayerNotificationSettingsStorageException: $message';
  }
}

/// Isolated service for persisting [PrayerNotificationSettings] and the
/// minimal coordinate cache used exclusively for prayer notification
/// rescheduling.
///
/// ### Privacy & Coordinate Cache Policy
/// - [storageKey] (`prayer_notification_settings_v1_json`) is completely
///   isolated from both `SettingsManager` and Phase 2 `PrayerSettingsService`.
/// - [coordinatesCacheKey] (`prayer_last_coordinates_v1_json`) stores
///   **latitude and longitude only** solely to keep scheduled prayer
///   notifications accurate across date, timezone, and calculation-settings
///   changes.
/// - Coordinates are stored **only** after the user has enabled prayer
///   notifications and valid coordinates have been acquired. When prayer
///   notifications are disabled, coordinates are never stored (and any cached
///   coordinates are cleared).
class PrayerNotificationSettingsService {
  /// Namespaced SharedPreferences key for prayer notification preferences.
  static const String storageKey = 'prayer_notification_settings_v1_json';

  /// Namespaced SharedPreferences key for cached coordinates (`lat`/`lng` only)
  /// used solely to maintain local prayer notification scheduling.
  static const String coordinatesCacheKey = 'prayer_last_coordinates_v1_json';

  final NotificationPreferencesProvider _preferencesProvider;

  PrayerNotificationSettings _currentSettings =
      const PrayerNotificationSettings.defaults();
  bool _isInitialized = false;

  PrayerNotificationSettingsService({
    NotificationPreferencesProvider? preferencesProvider,
  }) : _preferencesProvider =
            preferencesProvider ?? SharedPreferences.getInstance;

  bool get isInitialized => _isInitialized;

  PrayerNotificationSettings get currentSettings => _currentSettings;

  Future<PrayerNotificationSettings> init() => loadSettings();

  /// Loads and validates [PrayerNotificationSettings] from local storage.
  Future<PrayerNotificationSettings> loadSettings() async {
    try {
      final prefs = await _preferencesProvider();
      final Object? rawValue = prefs.get(storageKey);

      if (rawValue is String && rawValue.trim().isNotEmpty) {
        _currentSettings = PrayerNotificationSettings.fromJsonString(rawValue);
      } else {
        _currentSettings = const PrayerNotificationSettings.defaults();
      }
    } catch (_) {
      _currentSettings = const PrayerNotificationSettings.defaults();
    }

    _isInitialized = true;
    return _currentSettings;
  }

  /// Persists [settings] before updating [currentSettings].
  ///
  /// If persistence fails or returns `false`, throws
  /// [PrayerNotificationSettingsStorageException] and leaves [currentSettings]
  /// unchanged.
  Future<PrayerNotificationSettings> saveSettings(
    PrayerNotificationSettings settings,
  ) async {
    final validated = PrayerNotificationSettings(
      enabled: settings.enabled,
      fajr: settings.fajr,
      dhuhr: settings.dhuhr,
      asr: settings.asr,
      maghrib: settings.maghrib,
      isha: settings.isha,
      soundMode: settings.soundMode,
      schemaVersion: settings.schemaVersion,
    );

    try {
      final prefs = await _preferencesProvider();
      final bool persisted = await prefs.setString(
        storageKey,
        validated.toJsonString(),
      );
      if (!persisted) {
        throw const PrayerNotificationSettingsStorageException(
          'SharedPreferences.setString returned false when saving prayer notification settings.',
        );
      }
      if (!validated.enabled) {
        await prefs.remove(coordinatesCacheKey);
      }
    } on PrayerNotificationSettingsStorageException {
      rethrow;
    } catch (error) {
      throw PrayerNotificationSettingsStorageException(
        'Failed to persist prayer notification settings to local storage.',
        cause: error,
      );
    }

    _currentSettings = validated;
    _isInitialized = true;
    return _currentSettings;
  }

  /// Updates the master [enabled] switch and persists it.
  Future<PrayerNotificationSettings> updateEnabled(bool enabled) async {
    if (!_isInitialized) {
      await loadSettings();
    }
    return saveSettings(_currentSettings.copyWith(enabled: enabled));
  }

  /// Updates an individual obligatory prayer notification toggle.
  ///
  /// Passing [Prayer.sunrise] or [Prayer.none] returns [currentSettings]
  /// unchanged without scheduling or storing a Sunrise option.
  Future<PrayerNotificationSettings> updatePrayerEnabled(
    Prayer prayer,
    bool enabled,
  ) async {
    if (!_isInitialized) {
      await loadSettings();
    }
    if (PrayerNotificationSettings.prayerIndexFor(prayer) == null) {
      return _currentSettings;
    }
    return saveSettings(_currentSettings.copyWithPrayer(prayer, enabled));
  }

  /// Updates [soundMode] (`short` or `silent`) and persists it.
  Future<PrayerNotificationSettings> updateSoundMode(
    PrayerNotificationSound soundMode,
  ) async {
    if (!_isInitialized) {
      await loadSettings();
    }
    return saveSettings(_currentSettings.copyWith(soundMode: soundMode));
  }

  /// Resets notification settings to defaults and clears any cached coordinates.
  Future<PrayerNotificationSettings> resetToDefaults() async {
    const defaults = PrayerNotificationSettings.defaults();

    try {
      final prefs = await _preferencesProvider();
      final bool persisted = await prefs.setString(
        storageKey,
        defaults.toJsonString(),
      );
      if (!persisted) {
        throw const PrayerNotificationSettingsStorageException(
          'SharedPreferences.setString returned false when resetting prayer notification settings.',
        );
      }
      await prefs.remove(coordinatesCacheKey);
    } on PrayerNotificationSettingsStorageException {
      rethrow;
    } catch (error) {
      throw PrayerNotificationSettingsStorageException(
        'Failed to reset prayer notification settings in local storage.',
        cause: error,
      );
    }

    _currentSettings = defaults;
    _isInitialized = true;
    return _currentSettings;
  }

  /// Loads locally cached coordinates (`latitude` and `longitude` only) when
  /// present and valid, or returns `null`.
  Future<PrayerCachedCoordinates?> loadLastCoordinates() async {
    try {
      final prefs = await _preferencesProvider();
      final Object? rawValue = prefs.get(coordinatesCacheKey);
      if (rawValue is String) {
        return PrayerCachedCoordinates.tryFromJsonString(rawValue);
      }
    } catch (_) {}
    return null;
  }

  /// Stores `latitude` and `longitude` locally to maintain prayer notification
  /// scheduling, **only** when prayer notifications are currently enabled and
  /// coordinates are valid.
  ///
  /// Returns `true` if coordinates were stored, or `false` if skipped because
  /// prayer notifications are disabled or coordinates are invalid.
  Future<bool> saveLastCoordinates({
    required double latitude,
    required double longitude,
  }) async {
    if (!_isInitialized) {
      await loadSettings();
    }
    if (!_currentSettings.enabled) {
      return false;
    }

    final coords = PrayerCachedCoordinates(
      latitude: latitude,
      longitude: longitude,
    );
    if (!coords.isValid) {
      return false;
    }

    try {
      final prefs = await _preferencesProvider();
      final bool persisted = await prefs.setString(
        coordinatesCacheKey,
        coords.toJsonString(),
      );
      if (!persisted) {
        throw const PrayerNotificationSettingsStorageException(
          'SharedPreferences.setString returned false when saving cached coordinates.',
        );
      }
      return true;
    } on PrayerNotificationSettingsStorageException {
      rethrow;
    } catch (error) {
      throw PrayerNotificationSettingsStorageException(
        'Failed to persist cached prayer coordinates to local storage.',
        cause: error,
      );
    }
  }

  /// Clears locally cached coordinates.
  Future<void> clearLastCoordinates() async {
    try {
      final prefs = await _preferencesProvider();
      await prefs.remove(coordinatesCacheKey);
    } catch (_) {}
  }
}

