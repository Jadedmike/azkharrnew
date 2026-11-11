import 'package:shared_preferences/shared_preferences.dart';

import '../models/saved_prayer_location.dart';

/// Signature for providing a [SharedPreferences] instance.
typedef LocationCachePreferencesProvider = Future<SharedPreferences> Function();

/// Exception thrown when persisting or clearing the saved prayer location fails.
class PrayerLocationCacheStorageException implements Exception {
  final String message;
  final Object? cause;

  const PrayerLocationCacheStorageException(this.message, {this.cause});

  @override
  String toString() {
    if (cause != null) {
      return 'PrayerLocationCacheStorageException: $message (cause: $cause)';
    }
    return 'PrayerLocationCacheStorageException: $message';
  }
}

/// Dedicated persistent location cache for the Prayer Times feature.
///
/// Completely independent of prayer notification settings
/// (`prayer_notification_settings_v1_json` and `prayer_last_coordinates_v1_json`)
/// so disabling prayer notifications never deletes the user's saved prayer
/// location.
class PrayerLocationCacheService {
  /// Namespaced SharedPreferences key for the saved prayer location.
  static const String storageKey = 'prayer_saved_location_v1_json';

  final LocationCachePreferencesProvider _preferencesProvider;

  SavedPrayerLocation? _currentLocation;
  bool _isInitialized = false;

  PrayerLocationCacheService({
    LocationCachePreferencesProvider? preferencesProvider,
  }) : _preferencesProvider =
            preferencesProvider ?? SharedPreferences.getInstance;

  bool get isInitialized => _isInitialized;

  SavedPrayerLocation? get currentLocation => _currentLocation;

  /// Loads and validates the persisted [SavedPrayerLocation], returning `null`
  /// if missing, malformed, or carrying invalid coordinates.
  Future<SavedPrayerLocation?> loadLocation() async {
    try {
      final prefs = await _preferencesProvider();
      final Object? rawValue = prefs.get(storageKey);

      if (rawValue is String && rawValue.trim().isNotEmpty) {
        _currentLocation = SavedPrayerLocation.tryFromJsonString(rawValue);
      } else {
        _currentLocation = null;
      }
    } catch (_) {
      _currentLocation = null;
    }

    _isInitialized = true;
    return _currentLocation;
  }

  /// Persists [location] to local storage **before** updating
  /// [currentLocation].
  ///
  /// Throws [ArgumentError] if [location] does not have valid WGS84
  /// coordinates, or [PrayerLocationCacheStorageException] if writing fails,
  /// leaving [currentLocation] and any prior persisted cache intact.
  Future<SavedPrayerLocation> saveLocation(
    SavedPrayerLocation location,
  ) async {
    if (!location.isValid) {
      throw ArgumentError.value(
        location,
        'location',
        'SavedPrayerLocation must contain valid WGS84 coordinates.',
      );
    }

    try {
      final prefs = await _preferencesProvider();
      final bool persisted = await prefs.setString(
        storageKey,
        location.toJsonString(),
      );
      if (!persisted) {
        throw const PrayerLocationCacheStorageException(
          'SharedPreferences.setString returned false when saving prayer location.',
        );
      }
    } on PrayerLocationCacheStorageException {
      rethrow;
    } catch (error) {
      throw PrayerLocationCacheStorageException(
        'Failed to persist saved prayer location to local storage.',
        cause: error,
      );
    }

    _currentLocation = location;
    _isInitialized = true;
    return location;
  }

  /// Clears the persisted prayer location from storage.
  Future<void> clearLocation() async {
    try {
      final prefs = await _preferencesProvider();
      await prefs.remove(storageKey);
    } catch (_) {}
    _currentLocation = null;
    _isInitialized = true;
  }
}

