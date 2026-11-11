import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:geocoding/geocoding.dart';

/// Structured address fields extracted from native platform reverse geocoding.
@immutable
class PrayerGeocodingAddress {
  /// Normalized 2-letter uppercase ISO 3166-1 alpha-2 country code (e.g. `TR`),
  /// or `null` if unavailable.
  final String? countryIsoCode;

  /// Localized country name, or `null` if unavailable.
  final String? countryName;

  /// City / locality name, or `null` if unavailable.
  final String? city;

  /// District / sublocality name, or `null` if unavailable.
  final String? district;

  /// Whether reverse geocoding resolved at least one usable address component.
  bool get hasAnyComponent =>
      (countryName != null && countryName!.isNotEmpty) ||
      (city != null && city!.isNotEmpty) ||
      (district != null && district!.isNotEmpty);

  const PrayerGeocodingAddress({
    this.countryIsoCode,
    this.countryName,
    this.city,
    this.district,
  });

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is PrayerGeocodingAddress &&
        other.countryIsoCode == countryIsoCode &&
        other.countryName == countryName &&
        other.city == city &&
        other.district == district;
  }

  @override
  int get hashCode => Object.hash(countryIsoCode, countryName, city, district);
}

/// Injectable abstraction over the `geocoding` plugin so
/// [PrayerGeocodingService] is cleanly unit-testable without platform channels.
abstract class GeocodingClient {
  Future<void> setLocaleIdentifier(String localeIdentifier);

  Future<List<Placemark>> placemarkFromCoordinates(
    double latitude,
    double longitude,
  );
}

/// Production [GeocodingClient] delegating to the native `geocoding` package.
class DefaultGeocodingClient implements GeocodingClient {
  const DefaultGeocodingClient();

  @override
  Future<void> setLocaleIdentifier(String localeIdentifier) async {
    if (GeocodingPlatform.instance == null) {
      return;
    }
    await GeocodingPlatform.instance!.setLocaleIdentifier(localeIdentifier);
  }

  @override
  Future<List<Placemark>> placemarkFromCoordinates(
    double latitude,
    double longitude,
  ) async {
    if (GeocodingPlatform.instance == null) {
      return const <Placemark>[];
    }
    return GeocodingPlatform.instance!.placemarkFromCoordinates(
      latitude,
      longitude,
    );
  }
}

/// Pure, bounded reverse-geocoding service using the native OS geocoder
/// (`geocoding` package) with zero external API keys or tracking SDKs.
class PrayerGeocodingService {
  static const Duration defaultTimeout = Duration(seconds: 6);

  final GeocodingClient _client;
  final Duration timeout;
  final String? preferredLocaleIdentifier;

  const PrayerGeocodingService({
    GeocodingClient? client,
    this.timeout = defaultTimeout,
    this.preferredLocaleIdentifier = 'ar',
  }) : _client = client ?? const DefaultGeocodingClient();

  /// Resolves readable address components for valid coordinates.
  ///
  /// Never throws on geocoding errors or timeouts; instead returns an empty
  /// [PrayerGeocodingAddress] so the caller can preserve valid coordinates and
  /// display the fallback location label.
  Future<PrayerGeocodingAddress> reverseGeocode({
    required double latitude,
    required double longitude,
  }) async {
    if (!latitude.isFinite ||
        latitude < -90.0 ||
        latitude > 90.0 ||
        !longitude.isFinite ||
        longitude < -180.0 ||
        longitude > 180.0) {
      return const PrayerGeocodingAddress();
    }

    try {
      if (preferredLocaleIdentifier != null &&
          preferredLocaleIdentifier!.isNotEmpty) {
        try {
          await _client
              .setLocaleIdentifier(preferredLocaleIdentifier!)
              .timeout(timeout);
        } catch (_) {
          // Locale override is best-effort only; proceed with platform default.
        }
      }

      final placemarks = await _client
          .placemarkFromCoordinates(latitude, longitude)
          .timeout(timeout);

      if (placemarks.isEmpty) {
        return const PrayerGeocodingAddress();
      }

      return extractAddressFromPlacemarks(placemarks);
    } catch (_) {
      return const PrayerGeocodingAddress();
    }
  }

  /// Extracts normalized, deduplicated country, city, and district fields from
  /// a list of [Placemark] objects.
  static PrayerGeocodingAddress extractAddressFromPlacemarks(
    List<Placemark> placemarks,
  ) {
    if (placemarks.isEmpty) {
      return const PrayerGeocodingAddress();
    }

    String? isoCode;
    String? countryName;
    String? city;
    String? district;

    for (final placemark in placemarks) {
      isoCode ??= _normalizeIsoCode(placemark.isoCountryCode);
      countryName ??= _clean(placemark.country);
      city ??= _firstNonEmpty(<String?>[
        placemark.locality,
        placemark.administrativeArea,
      ]);
      district ??= _firstDistinct(
        candidates: <String?>[
          placemark.subLocality,
          placemark.subAdministrativeArea,
        ],
        excludeValues: <String?>[countryName, city],
      );
    }

    // Ensure city does not duplicate countryName and district does not duplicate either.
    if (city != null &&
        countryName != null &&
        city.toLowerCase() == countryName.toLowerCase()) {
      city = null;
    }

    return PrayerGeocodingAddress(
      countryIsoCode: isoCode,
      countryName: countryName,
      city: city,
      district: district,
    );
  }

  static String? _clean(String? value) {
    if (value == null) return null;
    final trimmed = value.trim().replaceAll(RegExp(r'\s+'), ' ');
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

  static String? _firstNonEmpty(List<String?> candidates) {
    for (final candidate in candidates) {
      final cleaned = _clean(candidate);
      if (cleaned != null) {
        return cleaned;
      }
    }
    return null;
  }

  static String? _firstDistinct({
    required List<String?> candidates,
    required List<String?> excludeValues,
  }) {
    final excluded = excludeValues
        .map((e) => _clean(e)?.toLowerCase())
        .whereType<String>()
        .toSet();

    for (final candidate in candidates) {
      final cleaned = _clean(candidate);
      if (cleaned != null && !excluded.contains(cleaned.toLowerCase())) {
        return cleaned;
      }
    }
    return null;
  }
}

