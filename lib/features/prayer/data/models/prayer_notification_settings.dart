import 'dart:convert';

import 'package:adhan/adhan.dart';
import 'package:flutter/foundation.dart';

/// Sound mode for local prayer notifications.
///
/// Full Adhan audio is intentionally never supported; notifications play either
/// the operating system's short default notification sound ([short]) or remain
/// silent ([silent]).
enum PrayerNotificationSound {
  /// Plays the operating system's default short notification sound.
  short,

  /// Displays the notification silently without sound.
  silent;

  /// Safely parses a stored string into a [PrayerNotificationSound].
  ///
  /// Defaults to [PrayerNotificationSound.short] when [raw] is null, empty,
  /// or unrecognized.
  static PrayerNotificationSound fromStorageString(Object? raw) {
    if (raw is! String || raw.trim().isEmpty) {
      return PrayerNotificationSound.short;
    }
    final normalized = raw.trim().toLowerCase();
    for (final mode in PrayerNotificationSound.values) {
      if (mode.name.toLowerCase() == normalized) {
        return mode;
      }
    }
    return PrayerNotificationSound.short;
  }
}

/// Immutable, schema-versioned model representing local prayer notification
/// preferences.
///
/// Supports the five obligatory daily prayers only (`Fajr`, `Dhuhr`, `Asr`,
/// `Maghrib`, `Isha`). Sunrise (`Shuruq`) is intentionally absent and can never
/// be enabled for notifications.
@immutable
class PrayerNotificationSettings {
  /// Current persistence schema version.
  static const int currentSchemaVersion = 1;

  /// Default master switch value (`false`) so notifications are opt-in only.
  static const bool defaultEnabled = false;

  /// Default per-prayer toggle value (`true`) once master notifications are
  /// enabled.
  static const bool defaultPrayerEnabled = true;

  /// Default notification sound mode (`short`).
  static const PrayerNotificationSound defaultSoundMode =
      PrayerNotificationSound.short;

  /// JSON/Map field keys used for local persistence.
  static const String keySchemaVersion = 'schemaVersion';
  static const String keyEnabled = 'enabled';
  static const String keyFajr = 'fajr';
  static const String keyDhuhr = 'dhuhr';
  static const String keyAsr = 'asr';
  static const String keyMaghrib = 'maghrib';
  static const String keyIsha = 'isha';
  static const String keySoundMode = 'soundMode';

  /// Ordered list of the five obligatory prayers eligible for notifications.
  ///
  /// [Prayer.sunrise] and [Prayer.none] are intentionally excluded.
  static const List<Prayer> eligiblePrayers = <Prayer>[
    Prayer.fajr,
    Prayer.dhuhr,
    Prayer.asr,
    Prayer.maghrib,
    Prayer.isha,
  ];

  /// Returns the deterministic prayer index (`0..4`) used for notification ID
  /// calculation, or `null` for non-obligatory entries such as [Prayer.sunrise]
  /// or [Prayer.none].
  static int? prayerIndexFor(Prayer prayer) {
    switch (prayer) {
      case Prayer.fajr:
        return 0;
      case Prayer.dhuhr:
        return 1;
      case Prayer.asr:
        return 2;
      case Prayer.maghrib:
        return 3;
      case Prayer.isha:
        return 4;
      case Prayer.sunrise:
      case Prayer.none:
        return null;
    }
  }

  /// Master switch controlling whether prayer notifications are enabled.
  final bool enabled;

  /// Whether Fajr notification is enabled when [enabled] is `true`.
  final bool fajr;

  /// Whether Dhuhr notification is enabled when [enabled] is `true`.
  final bool dhuhr;

  /// Whether Asr notification is enabled when [enabled] is `true`.
  final bool asr;

  /// Whether Maghrib notification is enabled when [enabled] is `true`.
  final bool maghrib;

  /// Whether Isha notification is enabled when [enabled] is `true`.
  final bool isha;

  /// Sound mode (`short` or `silent`).
  final PrayerNotificationSound soundMode;

  /// Schema version (normalized to [currentSchemaVersion]).
  final int schemaVersion;

  /// Creates a validated [PrayerNotificationSettings] instance.
  PrayerNotificationSettings({
    this.enabled = defaultEnabled,
    this.fajr = defaultPrayerEnabled,
    this.dhuhr = defaultPrayerEnabled,
    this.asr = defaultPrayerEnabled,
    this.maghrib = defaultPrayerEnabled,
    this.isha = defaultPrayerEnabled,
    this.soundMode = defaultSoundMode,
    int schemaVersion = currentSchemaVersion,
  }) : schemaVersion = isSupportedSchemaVersion(schemaVersion)
            ? schemaVersion
            : currentSchemaVersion;

  /// Compile-time constant constructor returning safe defaults (`enabled: false`,
  /// `soundMode: PrayerNotificationSound.short`).
  const PrayerNotificationSettings.defaults()
      : enabled = defaultEnabled,
        fajr = defaultPrayerEnabled,
        dhuhr = defaultPrayerEnabled,
        asr = defaultPrayerEnabled,
        maghrib = defaultPrayerEnabled,
        isha = defaultPrayerEnabled,
        soundMode = defaultSoundMode,
        schemaVersion = currentSchemaVersion;

  /// Returns `true` only when [raw] equals [currentSchemaVersion] (`1`).
  static bool isSupportedSchemaVersion(Object? raw) {
    if (raw is int) {
      return raw == currentSchemaVersion;
    }
    if (raw is String) {
      return int.tryParse(raw.trim()) == currentSchemaVersion;
    }
    return false;
  }

  /// Returns whether notifications are enabled for [prayer].
  ///
  /// Always returns `false` for [Prayer.sunrise] and [Prayer.none].
  bool isPrayerEnabled(Prayer prayer) {
    switch (prayer) {
      case Prayer.fajr:
        return fajr;
      case Prayer.dhuhr:
        return dhuhr;
      case Prayer.asr:
        return asr;
      case Prayer.maghrib:
        return maghrib;
      case Prayer.isha:
        return isha;
      case Prayer.sunrise:
      case Prayer.none:
        return false;
    }
  }

  /// Returns `true` if at least one obligatory prayer toggle is enabled.
  bool get hasAnyPrayerEnabled => fajr || dhuhr || asr || maghrib || isha;

  /// Returns a copy with the specified obligatory [prayer] toggle updated.
  ///
  /// Calling this with [Prayer.sunrise] or [Prayer.none] returns `this`
  /// unchanged because Sunrise is never eligible for prayer notifications.
  PrayerNotificationSettings copyWithPrayer(Prayer prayer, bool value) {
    switch (prayer) {
      case Prayer.fajr:
        return copyWith(fajr: value);
      case Prayer.dhuhr:
        return copyWith(dhuhr: value);
      case Prayer.asr:
        return copyWith(asr: value);
      case Prayer.maghrib:
        return copyWith(maghrib: value);
      case Prayer.isha:
        return copyWith(isha: value);
      case Prayer.sunrise:
      case Prayer.none:
        return this;
    }
  }

  /// Creates a copy with the specified fields replaced.
  PrayerNotificationSettings copyWith({
    bool? enabled,
    bool? fajr,
    bool? dhuhr,
    bool? asr,
    bool? maghrib,
    bool? isha,
    PrayerNotificationSound? soundMode,
    int? schemaVersion,
  }) {
    return PrayerNotificationSettings(
      enabled: enabled ?? this.enabled,
      fajr: fajr ?? this.fajr,
      dhuhr: dhuhr ?? this.dhuhr,
      asr: asr ?? this.asr,
      maghrib: maghrib ?? this.maghrib,
      isha: isha ?? this.isha,
      soundMode: soundMode ?? this.soundMode,
      schemaVersion: schemaVersion ?? this.schemaVersion,
    );
  }

  /// Serializes this [PrayerNotificationSettings] to a JSON-compatible map.
  Map<String, dynamic> toMap() {
    return <String, dynamic>{
      keySchemaVersion: schemaVersion,
      keyEnabled: enabled,
      keyFajr: fajr,
      keyDhuhr: dhuhr,
      keyAsr: asr,
      keyMaghrib: maghrib,
      keyIsha: isha,
      keySoundMode: soundMode.name,
    };
  }

  /// Serializes this [PrayerNotificationSettings] to a JSON string.
  String toJsonString() => jsonEncode(toMap());

  static bool _parseBool(Object? raw, bool fallback) {
    return raw is bool ? raw : fallback;
  }

  /// Deserializes a [PrayerNotificationSettings] instance from a map.
  ///
  /// Rejects unsupported/invalid/future schema versions by safely returning
  /// [PrayerNotificationSettings.defaults].
  factory PrayerNotificationSettings.fromMap(Map<String, dynamic>? map) {
    if (map == null || map.isEmpty) {
      return const PrayerNotificationSettings.defaults();
    }

    if (map.containsKey(keySchemaVersion) &&
        map[keySchemaVersion] != null &&
        !isSupportedSchemaVersion(map[keySchemaVersion])) {
      return const PrayerNotificationSettings.defaults();
    }

    return PrayerNotificationSettings(
      enabled: _parseBool(map[keyEnabled], defaultEnabled),
      fajr: _parseBool(map[keyFajr], defaultPrayerEnabled),
      dhuhr: _parseBool(map[keyDhuhr], defaultPrayerEnabled),
      asr: _parseBool(map[keyAsr], defaultPrayerEnabled),
      maghrib: _parseBool(map[keyMaghrib], defaultPrayerEnabled),
      isha: _parseBool(map[keyIsha], defaultPrayerEnabled),
      soundMode:
          PrayerNotificationSound.fromStorageString(map[keySoundMode]),
      schemaVersion: currentSchemaVersion,
    );
  }

  /// Deserializes a [PrayerNotificationSettings] instance from raw JSON.
  factory PrayerNotificationSettings.fromJsonString(String? jsonString) {
    if (jsonString == null || jsonString.trim().isEmpty) {
      return const PrayerNotificationSettings.defaults();
    }

    try {
      final Object? decoded = jsonDecode(jsonString);
      if (decoded is Map<String, dynamic>) {
        return PrayerNotificationSettings.fromMap(decoded);
      }
      if (decoded is Map) {
        return PrayerNotificationSettings.fromMap(
          decoded.map((key, value) => MapEntry(key.toString(), value)),
        );
      }
      return const PrayerNotificationSettings.defaults();
    } catch (_) {
      return const PrayerNotificationSettings.defaults();
    }
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is PrayerNotificationSettings &&
        other.enabled == enabled &&
        other.fajr == fajr &&
        other.dhuhr == dhuhr &&
        other.asr == asr &&
        other.maghrib == maghrib &&
        other.isha == isha &&
        other.soundMode == soundMode &&
        other.schemaVersion == schemaVersion;
  }

  @override
  int get hashCode => Object.hash(
        enabled,
        fajr,
        dhuhr,
        asr,
        maghrib,
        isha,
        soundMode,
        schemaVersion,
      );

  @override
  String toString() {
    return 'PrayerNotificationSettings('
        'enabled: $enabled, '
        'fajr: $fajr, '
        'dhuhr: $dhuhr, '
        'asr: $asr, '
        'maghrib: $maghrib, '
        'isha: $isha, '
        'soundMode: ${soundMode.name}, '
        'schemaVersion: $schemaVersion'
        ')';
  }
}

/// Minimal cached geographic coordinates (`latitude` and `longitude` only).
///
/// Stored locally solely to maintain local prayer notification rescheduling
/// across settings, date, or timezone changes without inventing a city or
/// issuing reverse-geocoding network requests.
@immutable
class PrayerCachedCoordinates {
  static const String keyLatitude = 'latitude';
  static const String keyLongitude = 'longitude';

  final double latitude;
  final double longitude;

  const PrayerCachedCoordinates({
    required this.latitude,
    required this.longitude,
  });

  /// Returns `true` if [latitude] and [longitude] are finite and within valid
  /// WGS84 geographic bounds.
  bool get isValid =>
      latitude.isFinite &&
      latitude >= -90.0 &&
      latitude <= 90.0 &&
      longitude.isFinite &&
      longitude >= -180.0 &&
      longitude <= 180.0;

  Map<String, dynamic> toMap() => <String, dynamic>{
        keyLatitude: latitude,
        keyLongitude: longitude,
      };

  String toJsonString() => jsonEncode(toMap());

  static PrayerCachedCoordinates? tryFromJsonString(String? jsonString) {
    if (jsonString == null || jsonString.trim().isEmpty) {
      return null;
    }
    try {
      final Object? decoded = jsonDecode(jsonString);
      if (decoded is! Map) {
        return null;
      }
      final Object? rawLat = decoded[keyLatitude];
      final Object? rawLng = decoded[keyLongitude];
      if (rawLat is! num || rawLng is! num) {
        return null;
      }
      final coords = PrayerCachedCoordinates(
        latitude: rawLat.toDouble(),
        longitude: rawLng.toDouble(),
      );
      return coords.isValid ? coords : null;
    } catch (_) {
      return null;
    }
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is PrayerCachedCoordinates &&
        other.latitude == latitude &&
        other.longitude == longitude;
  }

  @override
  int get hashCode => Object.hash(latitude, longitude);
}

