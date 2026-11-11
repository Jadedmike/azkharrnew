import 'package:adhan/adhan.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/prayer_settings.dart';
import 'country_method_resolver.dart';

export 'country_method_resolver.dart';

/// Signature for providing a [SharedPreferences] instance.
typedef SharedPreferencesProvider = Future<SharedPreferences> Function();

/// Exception thrown when persisting or resetting [PrayerSettings] in local
/// storage fails.
class PrayerSettingsStorageException implements Exception {
  /// Human-readable description of the storage failure.
  final String message;

  /// Optional underlying error thrown by the storage provider.
  final Object? cause;

  const PrayerSettingsStorageException(this.message, {this.cause});

  @override
  String toString() {
    if (cause != null) {
      return 'PrayerSettingsStorageException: $message (cause: $cause)';
    }
    return 'PrayerSettingsStorageException: $message';
  }
}

/// Isolated service for loading, updating, and persisting [PrayerSettings].
///
/// Uses [SharedPreferences] with a dedicated namespaced storage key
/// ([storageKey]) so it never collides with the existing `SettingsManager`
/// keys. Holds instance-scoped state rather than global mutable state so it can
/// be instantiated and tested independently.
class PrayerSettingsService {
  /// Namespaced SharedPreferences key for storing serialized prayer settings.
  static const String storageKey = 'prayer_settings_v1_json';

  final SharedPreferencesProvider _preferencesProvider;

  PrayerSettings _currentSettings = const PrayerSettings.defaults();
  bool _isInitialized = false;

  /// Creates a [PrayerSettingsService].
  ///
  /// An optional [preferencesProvider] can be injected for testing; defaults to
  /// [SharedPreferences.getInstance].
  PrayerSettingsService({
    SharedPreferencesProvider? preferencesProvider,
  }) : _preferencesProvider =
            preferencesProvider ?? SharedPreferences.getInstance;

  /// Whether [init] (or [loadSettings]) has completed at least once on this
  /// service instance.
  bool get isInitialized => _isInitialized;

  /// Returns the currently loaded [PrayerSettings] (or
  /// [PrayerSettings.defaults] if [init] has not been called yet).
  PrayerSettings get currentSettings => _currentSettings;

  /// Initializes the service by loading persisted settings from local storage.
  ///
  /// If no settings are stored, or if stored data is missing, corrupted, or has
  /// an invalid type, falls back to [PrayerSettings.defaults] without throwing.
  Future<PrayerSettings> init() => loadSettings();

  /// Loads and validates [PrayerSettings] from local storage, updating
  /// [currentSettings].
  Future<PrayerSettings> loadSettings() async {
    try {
      final prefs = await _preferencesProvider();
      final Object? rawValue = prefs.get(storageKey);

      if (rawValue is String && rawValue.trim().isNotEmpty) {
        _currentSettings = PrayerSettings.fromJsonString(rawValue);
      } else {
        _currentSettings = const PrayerSettings.defaults();
      }
    } catch (_) {
      _currentSettings = const PrayerSettings.defaults();
    }

    _isInitialized = true;
    return _currentSettings;
  }

  /// Persists the provided [settings] locally and updates [currentSettings]
  /// only after the write succeeds.
  ///
  /// Throws a [PrayerSettingsStorageException] if the storage provider fails
  /// or `SharedPreferences.setString` returns `false`, leaving
  /// [currentSettings] unchanged so in-memory state never misleadingly diverges
  /// from persisted storage.
  Future<PrayerSettings> saveSettings(PrayerSettings settings) async {
    final validated = PrayerSettings(
      calculationMode: settings.calculationMode,
      manualCalculationMethod: settings.manualCalculationMethod,
      madhab: settings.madhab,
      schemaVersion: settings.schemaVersion,
    );

    try {
      final prefs = await _preferencesProvider();
      final bool persisted = await prefs.setString(
        storageKey,
        validated.toJsonString(),
      );
      if (!persisted) {
        throw const PrayerSettingsStorageException(
          'SharedPreferences.setString returned false when saving prayer settings.',
        );
      }
    } on PrayerSettingsStorageException {
      rethrow;
    } catch (error) {
      throw PrayerSettingsStorageException(
        'Failed to persist prayer settings to local storage.',
        cause: error,
      );
    }

    _currentSettings = validated;
    _isInitialized = true;
    return _currentSettings;
  }

  /// Updates the calculation mode ([PrayerCalculationMode.auto] or
  /// [PrayerCalculationMode.manual]) and persists the change locally.
  ///
  /// Switching back to [PrayerCalculationMode.auto] preserves the previously
  /// saved [PrayerSettings.manualCalculationMethod] for future manual use.
  ///
  /// Throws a [PrayerSettingsStorageException] if persistence fails.
  Future<PrayerSettings> updateCalculationMode(
    PrayerCalculationMode mode,
  ) async {
    if (!_isInitialized) {
      await loadSettings();
    }
    return saveSettings(
      _currentSettings.copyWith(calculationMode: mode),
    );
  }

  /// Updates the manually selected [CalculationMethod] and persists the change
  /// locally.
  ///
  /// If an unsupported method (such as [CalculationMethod.other]) is passed, it
  /// is sanitized to [PrayerSettings.defaultManualCalculationMethod].
  ///
  /// Throws a [PrayerSettingsStorageException] if persistence fails.
  Future<PrayerSettings> updateManualCalculationMethod(
    CalculationMethod method,
  ) async {
    if (!_isInitialized) {
      await loadSettings();
    }
    final sanitized = PrayerSettings.sanitizeCalculationMethod(method);
    return saveSettings(
      _currentSettings.copyWith(manualCalculationMethod: sanitized),
    );
  }

  /// Updates the selected [Madhab] ([Madhab.shafi] or [Madhab.hanafi]) for Asr
  /// calculation and persists the change locally.
  ///
  /// Throws a [PrayerSettingsStorageException] if persistence fails.
  Future<PrayerSettings> updateMadhab(Madhab madhab) async {
    if (!_isInitialized) {
      await loadSettings();
    }
    return saveSettings(
      _currentSettings.copyWith(madhab: madhab),
    );
  }

  /// Resets prayer settings to [PrayerSettings.defaults] and persists the
  /// default state in local storage.
  ///
  /// Throws a [PrayerSettingsStorageException] if persistence fails, leaving
  /// [currentSettings] unchanged.
  Future<PrayerSettings> resetToDefaults() async {
    const defaults = PrayerSettings.defaults();

    try {
      final prefs = await _preferencesProvider();
      final bool persisted = await prefs.setString(
        storageKey,
        defaults.toJsonString(),
      );
      if (!persisted) {
        throw const PrayerSettingsStorageException(
          'SharedPreferences.setString returned false when resetting prayer settings.',
        );
      }
    } on PrayerSettingsStorageException {
      rethrow;
    } catch (error) {
      throw PrayerSettingsStorageException(
        'Failed to reset prayer settings in local storage.',
        cause: error,
      );
    }

    _currentSettings = defaults;
    _isInitialized = true;
    return _currentSettings;
  }

  /// Resolves the effective [CalculationMethod] for [currentSettings].
  ///
  /// - In [PrayerCalculationMode.manual], always returns
  ///   [PrayerSettings.manualCalculationMethod], never overriding it with
  ///   [countryCode].
  /// - In [PrayerCalculationMode.auto], resolves a method from [countryCode]
  ///   via [CountryMethodResolver.resolveFromCountryCode] (falling back to
  ///   [CountryMethodResolver.fallbackMethod] when [countryCode] is null,
  ///   empty, or unrecognized).
  CalculationMethod resolveEffectiveCalculationMethod({String? countryCode}) {
    return CountryMethodResolver.resolveEffectiveMethod(
      _currentSettings,
      countryCode: countryCode,
    );
  }

  /// Resolves configured `adhan` [CalculationParameters] (both calculation
  /// method and [Madhab]) for [currentSettings] and optional [countryCode].
  CalculationParameters resolveCalculationParameters({String? countryCode}) {
    return CountryMethodResolver.resolveCalculationParameters(
      _currentSettings,
      countryCode: countryCode,
    );
  }
}
