import 'dart:convert';

import 'package:flutter/foundation.dart';

/// Origin of the coordinates stored in [SavedPrayerLocation].
enum PrayerLocationSource {
  /// Acquired from a fresh foreground GPS/network location update.
  fresh,

  /// Acquired from a recent OS last-known cached location fallback.
  cached;

  /// Safely parses a stored string into a [PrayerLocationSource].
  static PrayerLocationSource fromStorageString(Object? raw) {
    if (raw is! String || raw.trim().isEmpty) {
      return PrayerLocationSource.fresh;
    }
    final normalized = raw.trim().toLowerCase();
    for (final value in PrayerLocationSource.values) {
      if (value.name.toLowerCase() == normalized) {
        return value;
      }
    }
    return PrayerLocationSource.fresh;
  }
}

/// Immutable model representing the user's persisted prayer location and its
/// resolved human-readable address components.
///
/// Coordinates are stored internally for prayer time calculation and debug
/// diagnostics, while [displayName] presents only readable place names (or
/// [fallbackDisplayName] if geocoding components are unavailable).
@immutable
class SavedPrayerLocation {
  /// Current persistence schema version.
  static const int currentSchemaVersion = 1;

  /// Friendly Arabic fallback label shown when no readable address component
  /// could be resolved from reverse geocoding.
  static const String fallbackDisplayName = 'الموقع المحفوظ';

  static const String keySchemaVersion = 'schemaVersion';
  static const String keyLatitude = 'latitude';
  static const String keyLongitude = 'longitude';
  static const String keyCountryIsoCode = 'countryIsoCode';
  static const String keyCountryName = 'countryName';
  static const String keyCity = 'city';
  static const String keyDistrict = 'district';
  static const String keyTimestamp = 'timestamp';
  static const String keySource = 'source';

  /// Latitude in degrees (`-90.0` to `90.0`).
  final double latitude;

  /// Longitude in degrees (`-180.0` to `180.0`).
  final double longitude;

  /// Normalized 2-letter uppercase ISO 3166-1 alpha-2 country code (e.g., `TR`),
  /// or `null` if unavailable.
  final String? countryIsoCode;

  /// Localized country name from reverse geocoding, or `null` if unavailable.
  final String? countryName;

  /// City / locality name from reverse geocoding, or `null` if unavailable.
  final String? city;

  /// District / sublocality name from reverse geocoding, or `null` if
  /// unavailable.
  final String? district;

  /// Timestamp when the underlying coordinates were obtained.
  final DateTime timestamp;

  /// Whether the underlying coordinates came from a fresh fix or OS cache.
  final PrayerLocationSource source;

  /// Schema version (`1`).
  final int schemaVersion;

  SavedPrayerLocation({
    required this.latitude,
    required this.longitude,
    required this.timestamp,
    String? countryIsoCode,
    String? countryName,
    String? city,
    String? district,
    this.source = PrayerLocationSource.fresh,
    this.schemaVersion = currentSchemaVersion,
  }) : countryIsoCode = _normalizeIsoCode(countryIsoCode),
       countryName = _normalizeText(countryName),
       city = _normalizeText(city),
       district = _normalizeText(district);

  /// Returns `true` if [latitude] and [longitude] are finite and within valid
  /// WGS84 bounds.
  bool get hasValidCoordinates =>
      latitude.isFinite &&
      latitude >= -90.0 &&
      latitude <= 90.0 &&
      longitude.isFinite &&
      longitude >= -180.0 &&
      longitude <= 180.0;

  /// Whether this saved location is usable for prayer time calculation.
  bool get isValid => hasValidCoordinates;

  /// Builds a clean, deduplicated Arabic-comma-separated location label such as
  /// `تركيا، إسطنبول، إسنيورت`, or [fallbackDisplayName] (`الموقع المحفوظ`)
  /// when no readable address components exist.
  ///
  /// Never exposes raw latitude/longitude coordinates.
  String get displayName {
    final parts = <String>[];
    final seenNormalized = <String>{};

    for (final candidate in <String?>[countryName, city, district]) {
      final trimmed = candidate?.trim();
      if (trimmed == null || trimmed.isEmpty) {
        continue;
      }
      final canonical = trimmed.replaceAll(RegExp(r'\s+'), ' ').toLowerCase();
      if (seenNormalized.add(canonical)) {
        parts.add(trimmed);
      }
    }

    if (parts.isEmpty) {
      return fallbackDisplayName;
    }
    return parts.join('، ');
  }

  /// Creates a copy with replaced fields.
  SavedPrayerLocation copyWith({
    double? latitude,
    double? longitude,
    String? countryIsoCode,
    String? countryName,
    String? city,
    String? district,
    DateTime? timestamp,
    PrayerLocationSource? source,
    int? schemaVersion,
  }) {
    return SavedPrayerLocation(
      latitude: latitude ?? this.latitude,
      longitude: longitude ?? this.longitude,
      countryIsoCode: countryIsoCode ?? this.countryIsoCode,
      countryName: countryName ?? this.countryName,
      city: city ?? this.city,
      district: district ?? this.district,
      timestamp: timestamp ?? this.timestamp,
      source: source ?? this.source,
      schemaVersion: schemaVersion ?? this.schemaVersion,
    );
  }

  Map<String, dynamic> toMap() {
    return <String, dynamic>{
      keySchemaVersion: schemaVersion,
      keyLatitude: latitude,
      keyLongitude: longitude,
      keyCountryIsoCode: countryIsoCode,
      keyCountryName: countryName,
      keyCity: city,
      keyDistrict: district,
      keyTimestamp: timestamp.toUtc().toIso8601String(),
      keySource: source.name,
    };
  }

  String toJsonString() => jsonEncode(toMap());

  /// Safely deserializes a [SavedPrayerLocation] from [map], returning `null`
  /// if schema version, coordinates, or timestamp are invalid.
  static SavedPrayerLocation? tryFromMap(Map<String, dynamic>? map) {
    if (map == null || map.isEmpty) {
      return null;
    }

    final Object? rawSchema = map[keySchemaVersion];
    if (rawSchema != null && rawSchema != currentSchemaVersion) {
      return null;
    }

    final Object? rawLat = map[keyLatitude];
    final Object? rawLng = map[keyLongitude];
    if (rawLat is! num || rawLng is! num) {
      return null;
    }

    final double lat = rawLat.toDouble();
    final double lng = rawLng.toDouble();

    final Object? rawTimestamp = map[keyTimestamp];
    DateTime? parsedTimestamp;
    if (rawTimestamp is String && rawTimestamp.trim().isNotEmpty) {
      parsedTimestamp = DateTime.tryParse(rawTimestamp.trim());
    }
    if (parsedTimestamp == null) {
      return null;
    }

    final location = SavedPrayerLocation(
      latitude: lat,
      longitude: lng,
      countryIsoCode: map[keyCountryIsoCode] as String?,
      countryName: map[keyCountryName] as String?,
      city: map[keyCity] as String?,
      district: map[keyDistrict] as String?,
      timestamp: parsedTimestamp,
      source: PrayerLocationSource.fromStorageString(map[keySource]),
      schemaVersion: currentSchemaVersion,
    );

    return location.isValid ? location : null;
  }

  /// Safely deserializes a [SavedPrayerLocation] from raw JSON, returning `null`
  /// if missing, malformed, or invalid.
  static SavedPrayerLocation? tryFromJsonString(String? jsonString) {
    if (jsonString == null || jsonString.trim().isEmpty) {
      return null;
    }
    try {
      final Object? decoded = jsonDecode(jsonString);
      if (decoded is Map<String, dynamic>) {
        return tryFromMap(decoded);
      }
      if (decoded is Map) {
        return tryFromMap(
          decoded.map((key, value) => MapEntry(key.toString(), value)),
        );
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  static String? _normalizeText(String? value) {
    if (value == null) return null;
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  static String? _normalizeIsoCode(String? code) {
    if (code == null) return null;
    final trimmed = code.trim().toUpperCase();
    if (trimmed.length != 2) return null;
    final c0 = trimmed.codeUnitAt(0);
    final c1 = trimmed.codeUnitAt(1);
    if (c0 < 65 || c0 > 90 || c1 < 65 || c1 > 90) {
      return null;
    }
    return trimmed;
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is SavedPrayerLocation &&
        other.latitude == latitude &&
        other.longitude == longitude &&
        other.countryIsoCode == countryIsoCode &&
        other.countryName == countryName &&
        other.city == city &&
        other.district == district &&
        other.timestamp.toUtc() == timestamp.toUtc() &&
        other.source == source &&
        other.schemaVersion == schemaVersion;
  }

  @override
  int get hashCode => Object.hash(
        latitude,
        longitude,
        countryIsoCode,
        countryName,
        city,
        district,
        timestamp.toUtc(),
        source,
        schemaVersion,
      );
}

