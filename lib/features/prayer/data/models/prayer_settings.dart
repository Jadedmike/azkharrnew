import 'dart:convert';

import 'package:adhan/adhan.dart';
import 'package:flutter/foundation.dart';

/// Mode used to determine the active prayer time calculation method.
enum PrayerCalculationMode {
  /// Automatically resolves a calculation method from a provided ISO country
  /// code (falling back to [PrayerSettings.defaultManualCalculationMethod] when
  /// no country code is available or recognized).
  auto,

  /// Uses the user's explicitly chosen [PrayerSettings.manualCalculationMethod]
  /// regardless of country code.
  manual;

  /// Safely parses a stored string into a [PrayerCalculationMode].
  ///
  /// Returns [PrayerSettings.defaultCalculationMode] (`auto`) if [raw] is null,
  /// empty, or does not match a known mode.
  static PrayerCalculationMode fromStorageString(Object? raw) {
    if (raw is! String || raw.trim().isEmpty) {
      return PrayerSettings.defaultCalculationMode;
    }
    final normalized = raw.trim().toLowerCase();
    for (final mode in PrayerCalculationMode.values) {
      if (mode.name.toLowerCase() == normalized) {
        return mode;
      }
    }
    return PrayerSettings.defaultCalculationMode;
  }
}

/// Strongly typed, immutable model representing user prayer calculation
/// preferences.
///
/// Contains no UI display strings so persistence remains locale-independent.
@immutable
class PrayerSettings {
  /// Current persistence schema version.
  ///
  /// Only version `1` is supported. Payloads carrying invalid (`<= 0`,
  /// malformed) or unknown future (`> currentSchemaVersion`) schema versions
  /// are not treated as supported and safely fall back to
  /// [PrayerSettings.defaults].
  static const int currentSchemaVersion = 1;

  /// Default calculation mode: [PrayerCalculationMode.auto].
  ///
  /// Does not assume the device country is known at initialization time.
  static const PrayerCalculationMode defaultCalculationMode =
      PrayerCalculationMode.auto;

  /// Default calculation method used for manual mode initialization and as a
  /// safe fallback when automatic resolution cannot determine a country.
  static const CalculationMethod defaultManualCalculationMethod =
      CalculationMethod.muslim_world_league;

  /// Default juristic method (Madhab) for Asr shadow length calculation.
  static const Madhab defaultMadhab = Madhab.shafi;

  /// JSON/Map field keys used for local persistence.
  static const String keySchemaVersion = 'schemaVersion';
  static const String keyCalculationMode = 'calculationMode';
  static const String keyManualCalculationMethod = 'manualCalculationMethod';
  static const String keyMadhab = 'madhab';

  /// Concrete calculation methods supported by the `adhan` package for preset
  /// selection.
  ///
  /// Excludes [CalculationMethod.other] because `other` initializes Fajr and
  /// Isha angles to `0.0` and requires custom angle parameters not represented
  /// by a standard preset.
  static const List<CalculationMethod> supportedCalculationMethods =
      <CalculationMethod>[
    CalculationMethod.muslim_world_league,
    CalculationMethod.egyptian,
    CalculationMethod.karachi,
    CalculationMethod.umm_al_qura,
    CalculationMethod.dubai,
    CalculationMethod.moon_sighting_committee,
    CalculationMethod.north_america,
    CalculationMethod.kuwait,
    CalculationMethod.qatar,
    CalculationMethod.singapore,
    CalculationMethod.turkey,
    CalculationMethod.tehran,
  ];

  /// Whether the calculation method is resolved automatically or chosen
  /// manually.
  final PrayerCalculationMode calculationMode;

  /// The user's explicitly selected calculation method.
  ///
  /// Retained in storage even when [calculationMode] is
  /// [PrayerCalculationMode.auto] so the user's manual preference is preserved
  /// if they switch modes.
  final CalculationMethod manualCalculationMethod;

  /// Selected Madhab for Asr calculation ([Madhab.shafi] or [Madhab.hanafi]).
  final Madhab madhab;

  /// Schema version of the stored settings payload (always normalized to
  /// [currentSchemaVersion]).
  final int schemaVersion;

  /// Creates a validated [PrayerSettings] instance.
  ///
  /// If [manualCalculationMethod] is unsupported (such as
  /// [CalculationMethod.other]) or [schemaVersion] is not a supported version
  /// (`!= currentSchemaVersion`), safe defaults are substituted automatically.
  PrayerSettings({
    this.calculationMode = defaultCalculationMode,
    CalculationMethod manualCalculationMethod = defaultManualCalculationMethod,
    this.madhab = defaultMadhab,
    int schemaVersion = currentSchemaVersion,
  })  : manualCalculationMethod =
            sanitizeCalculationMethod(manualCalculationMethod),
        schemaVersion = isSupportedSchemaVersion(schemaVersion)
            ? schemaVersion
            : currentSchemaVersion;

  /// Compile-time constant constructor returning safe default settings.
  const PrayerSettings.defaults()
      : calculationMode = defaultCalculationMode,
        manualCalculationMethod = defaultManualCalculationMethod,
        madhab = defaultMadhab,
        schemaVersion = currentSchemaVersion;

  /// Returns `true` if [method] is a valid preset method supported by the app.
  static bool isSupportedCalculationMethod(CalculationMethod? method) {
    if (method == null || method == CalculationMethod.other) {
      return false;
    }
    return supportedCalculationMethods.contains(method);
  }

  /// Validates [method], returning [defaultManualCalculationMethod] if null or
  /// unsupported.
  static CalculationMethod sanitizeCalculationMethod(
    CalculationMethod? method,
  ) {
    if (isSupportedCalculationMethod(method)) {
      return method!;
    }
    return defaultManualCalculationMethod;
  }

  /// Safely parses a stored calculation method identifier.
  static CalculationMethod parseCalculationMethod(Object? raw) {
    if (raw is! String || raw.trim().isEmpty) {
      return defaultManualCalculationMethod;
    }
    final normalized = raw.trim().toLowerCase();
    for (final method in supportedCalculationMethods) {
      if (method.name.toLowerCase() == normalized) {
        return method;
      }
    }
    return defaultManualCalculationMethod;
  }

  /// Safely parses a stored [Madhab] identifier.
  static Madhab parseMadhab(Object? raw) {
    if (raw is! String || raw.trim().isEmpty) {
      return defaultMadhab;
    }
    final normalized = raw.trim().toLowerCase();
    for (final value in Madhab.values) {
      if (value.name.toLowerCase() == normalized) {
        return value;
      }
    }
    return defaultMadhab;
  }

  /// Returns `true` only if [raw] represents a supported schema version
  /// (currently only version [currentSchemaVersion] = `1`).
  ///
  /// Version `0`, negative numbers, malformed values, and unknown future
  /// versions (`> currentSchemaVersion`, e.g., `99`) return `false`.
  static bool isSupportedSchemaVersion(Object? raw) {
    if (raw is int) {
      return raw == currentSchemaVersion;
    }
    if (raw is String) {
      final parsed = int.tryParse(raw.trim());
      return parsed == currentSchemaVersion;
    }
    return false;
  }

  /// Safely parses a stored schema version, normalizing any unsupported,
  /// invalid (`<= 0`, malformed), or unknown future (`> currentSchemaVersion`)
  /// value to [currentSchemaVersion].
  static int parseSchemaVersion(Object? raw) {
    if (isSupportedSchemaVersion(raw)) {
      return currentSchemaVersion;
    }
    return currentSchemaVersion;
  }

  /// Creates a copy of this [PrayerSettings] with the given fields replaced.
  PrayerSettings copyWith({
    PrayerCalculationMode? calculationMode,
    CalculationMethod? manualCalculationMethod,
    Madhab? madhab,
    int? schemaVersion,
  }) {
    return PrayerSettings(
      calculationMode: calculationMode ?? this.calculationMode,
      manualCalculationMethod:
          manualCalculationMethod ?? this.manualCalculationMethod,
      madhab: madhab ?? this.madhab,
      schemaVersion: schemaVersion ?? this.schemaVersion,
    );
  }

  /// Serializes this [PrayerSettings] to a JSON-compatible map.
  Map<String, dynamic> toMap() {
    return <String, dynamic>{
      keySchemaVersion: schemaVersion,
      keyCalculationMode: calculationMode.name,
      keyManualCalculationMethod: manualCalculationMethod.name,
      keyMadhab: madhab.name,
    };
  }

  /// Serializes this [PrayerSettings] to a JSON string.
  String toJsonString() => jsonEncode(toMap());

  /// Deserializes a [PrayerSettings] instance from a map.
  ///
  /// ### Schema Version Behavior
  /// - If [keySchemaVersion] is omitted (`null`), the map is treated as a
  ///   version `1` payload and its fields are parsed with per-field fallbacks.
  /// - If [keySchemaVersion] is present and equals [currentSchemaVersion]
  ///   (`1`), its fields are parsed with per-field fallbacks.
  /// - If [keySchemaVersion] is present and is invalid (`0`, negative,
  ///   malformed) or an unsupported future version (`> currentSchemaVersion`,
  ///   such as `99`), the entire payload is rejected and
  ///   [PrayerSettings.defaults] is returned safely without throwing.
  factory PrayerSettings.fromMap(Map<String, dynamic>? map) {
    if (map == null || map.isEmpty) {
      return const PrayerSettings.defaults();
    }

    if (map.containsKey(keySchemaVersion) &&
        map[keySchemaVersion] != null &&
        !isSupportedSchemaVersion(map[keySchemaVersion])) {
      return const PrayerSettings.defaults();
    }

    return PrayerSettings(
      calculationMode:
          PrayerCalculationMode.fromStorageString(map[keyCalculationMode]),
      manualCalculationMethod:
          parseCalculationMethod(map[keyManualCalculationMethod]),
      madhab: parseMadhab(map[keyMadhab]),
      schemaVersion: currentSchemaVersion,
    );
  }

  /// Deserializes a [PrayerSettings] instance from a raw JSON string.
  ///
  /// Gracefully returns [PrayerSettings.defaults] if [jsonString] is null,
  /// empty, malformed, carries an unsupported schema version, or does not
  /// decode to a JSON object.
  factory PrayerSettings.fromJsonString(String? jsonString) {
    if (jsonString == null || jsonString.trim().isEmpty) {
      return const PrayerSettings.defaults();
    }

    try {
      final Object? decoded = jsonDecode(jsonString);
      if (decoded is Map<String, dynamic>) {
        return PrayerSettings.fromMap(decoded);
      }
      if (decoded is Map) {
        return PrayerSettings.fromMap(
          decoded.map((key, value) => MapEntry(key.toString(), value)),
        );
      }
      return const PrayerSettings.defaults();
    } catch (_) {
      return const PrayerSettings.defaults();
    }
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is PrayerSettings &&
        other.calculationMode == calculationMode &&
        other.manualCalculationMethod == manualCalculationMethod &&
        other.madhab == madhab &&
        other.schemaVersion == schemaVersion;
  }

  @override
  int get hashCode => Object.hash(
        calculationMode,
        manualCalculationMethod,
        madhab,
        schemaVersion,
      );

  @override
  String toString() {
    return 'PrayerSettings('
        'calculationMode: ${calculationMode.name}, '
        'manualCalculationMethod: ${manualCalculationMethod.name}, '
        'madhab: ${madhab.name}, '
        'schemaVersion: $schemaVersion'
        ')';
  }
}
