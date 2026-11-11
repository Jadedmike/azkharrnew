import 'package:adhan/adhan.dart';

import '../models/prayer_settings.dart';

/// Pure, stateless resolver that maps an ISO 3166-1 alpha-2 country code to a
/// default [CalculationMethod] supported by the `adhan` package.
///
/// ### Important Note on Library Presets & Regional Conventions
/// A library [CalculationMethod] preset is an angular calculation model and is
/// not guaranteed to be identical to an official national or local mosque
/// timetable, which may include local sighting adjustments, municipal offsets,
/// or ministry-specific tables.
///
/// This resolver includes automatic country mappings only where `adhan`
/// provides a corresponding country/institution preset or where a documented
/// multilateral angular convention (MABIMS) applies as a regional
/// approximation. All other countries resolve to [fallbackMethod] until the
/// user selects a preferred method in [PrayerCalculationMode.manual].
class CountryMethodResolver {
  const CountryMethodResolver._();

  /// Fallback method returned when no country code is available, the code is
  /// malformed, or the country does not have a dedicated mapping in
  /// [countryMethodMap].
  ///
  /// Uses [CalculationMethod.muslim_world_league] (18° Fajr / 17° Isha).
  static const CalculationMethod fallbackMethod =
      PrayerSettings.defaultManualCalculationMethod;

  /// Conservative mapping of uppercase ISO 3166-1 alpha-2 country codes to
  /// `adhan` [CalculationMethod] presets.
  ///
  /// Countries without a dedicated `adhan` preset or documented regional
  /// angular accord (such as `BH`, `OM`, `YE`, `SD`, `LY`, `PS`, `SY`, `LB`,
  /// `IQ`, `BD`, `IN`, `AF`, `US`, `CA`) are intentionally omitted so they use
  /// [fallbackMethod] unless overridden manually.
  static const Map<String, CalculationMethod> countryMethodMap =
      <String, CalculationMethod>{
    // -------------------------------------------------------------------------
    // Direct Country / Institution Presets in `adhan`
    // -------------------------------------------------------------------------

    // Saudi Arabia: Maps to the Umm al-Qura University (Makkah) preset in
    // `adhan` (18.5° Fajr, 90-minute Isha interval).
    'SA': CalculationMethod.umm_al_qura,

    // United Arab Emirates: Maps to the Dubai / UAE preset in `adhan`
    // (18.2° Fajr, 18.2° Isha, with preset minute adjustments).
    'AE': CalculationMethod.dubai,

    // Kuwait: Maps to the Kuwait preset in `adhan` (18.0° Fajr, 17.5° Isha).
    'KW': CalculationMethod.kuwait,

    // Qatar: Maps to the Qatar preset in `adhan` (18.0° Fajr, 90-minute Isha
    // interval).
    'QA': CalculationMethod.qatar,

    // Egypt: Maps to the Egyptian General Authority of Survey preset in `adhan`
    // (19.5° Fajr, 17.5° Isha).
    'EG': CalculationMethod.egyptian,

    // Pakistan: Maps to the University of Islamic Sciences, Karachi preset in
    // `adhan` (18.0° Fajr, 18.0° Isha).
    'PK': CalculationMethod.karachi,

    // Turkey: Maps to the Diyanet (`turkey`) preset in `adhan` (18.0° Fajr,
    // 17.0° Isha, with Diyanet minute adjustments).
    'TR': CalculationMethod.turkey,

    // Iran: Maps to the Institute of Geophysics, University of Tehran preset in
    // `adhan` (17.7° Fajr, 14.0° Isha, 4.5° Maghrib).
    'IR': CalculationMethod.tehran,

    // Singapore: Maps to the Singapore (`singapore`) preset in `adhan`
    // (20.0° Fajr, 18.0° Isha).
    'SG': CalculationMethod.singapore,

    // -------------------------------------------------------------------------
    // Documented MABIMS Regional Standard (20° Fajr / 18° Isha Approximation)
    // -------------------------------------------------------------------------
    // The religious ministries of Brunei Darussalam, Indonesia, Malaysia, and
    // Singapore (MABIMS) share a documented regional angular convention of
    // 20° solar depression for Fajr and 18° for Isha. In `adhan`, these angles
    // are represented by `CalculationMethod.singapore`.
    //
    // Note: This mapping is a regional angular approximation and is not an
    // identical national timetable (local ministry ihtiyat / rounding offsets
    // can differ by locality).

    // Malaysia: MABIMS 20° Fajr / 18° Isha regional approximation via
    // `CalculationMethod.singapore`.
    'MY': CalculationMethod.singapore,

    // Indonesia: MABIMS 20° Fajr / 18° Isha regional approximation via
    // `CalculationMethod.singapore`.
    'ID': CalculationMethod.singapore,

    // Brunei Darussalam: MABIMS 20° Fajr / 18° Isha regional approximation via
    // `CalculationMethod.singapore`.
    'BN': CalculationMethod.singapore,
  };

  /// Resolves a [CalculationMethod] purely from an optional ISO 3166-1 alpha-2
  /// [countryCode].
  ///
  /// - Trims whitespace and normalizes [countryCode] to uppercase.
  /// - Does not guess a country if [countryCode] is null, empty, malformed, or
  ///   unrecognized; returns [fallbackMethod] instead.
  static CalculationMethod resolveFromCountryCode(String? countryCode) {
    if (countryCode == null) {
      return fallbackMethod;
    }

    final normalized = countryCode.trim().toUpperCase();
    if (normalized.length != 2) {
      return fallbackMethod;
    }

    return countryMethodMap[normalized] ?? fallbackMethod;
  }

  /// Resolves the effective [CalculationMethod] for the given [settings] and
  /// optional [countryCode].
  ///
  /// - If [settings.calculationMode] is [PrayerCalculationMode.manual], always
  ///   returns [settings.manualCalculationMethod] and never overrides it with
  ///   the country resolver.
  /// - If [settings.calculationMode] is [PrayerCalculationMode.auto], resolves
  ///   the method from [countryCode] (or [fallbackMethod] if unresolved).
  static CalculationMethod resolveEffectiveMethod(
    PrayerSettings settings, {
    String? countryCode,
  }) {
    if (settings.calculationMode == PrayerCalculationMode.manual) {
      return PrayerSettings.sanitizeCalculationMethod(
        settings.manualCalculationMethod,
      );
    }
    return resolveFromCountryCode(countryCode);
  }

  /// Builds `adhan` [CalculationParameters] for the given [settings] and
  /// optional [countryCode], applying both the resolved calculation method and
  /// [settings.madhab].
  static CalculationParameters resolveCalculationParameters(
    PrayerSettings settings, {
    String? countryCode,
  }) {
    final method = resolveEffectiveMethod(settings, countryCode: countryCode);
    final params = method.getParameters();
    params.madhab = settings.madhab;
    return params;
  }
}
