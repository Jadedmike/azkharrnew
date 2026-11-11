import 'package:adhan/adhan.dart';

import '../models/prayer_settings.dart';
import '../models/prayer_times_result.dart';
import 'country_method_resolver.dart';

/// Categories of errors that can occur during prayer time calculation.
enum PrayerCalculationErrorType {
  /// Latitude or longitude is NaN, infinite, or outside geographic bounds
  /// (`[-90, 90]` for latitude, `[-180, 180]` for longitude).
  invalidCoordinates,

  /// The requested calendar date or [DateComponents] has an out-of-range year,
  /// month, or day.
  invalidDate,

  /// Underlying solar/astronomical calculation could not resolve valid times
  /// (for example, extreme polar coordinates where sunrise/sunset is undefined).
  calculationFailed,
}

/// Typed exception thrown by [PrayerCalculationService] when inputs are invalid
/// or calculation cannot be completed.
class PrayerCalculationException implements Exception {
  /// Classification of the calculation error.
  final PrayerCalculationErrorType type;

  /// Human-readable description of the failure.
  final String message;

  /// Optional underlying exception thrown by the calculation library.
  final Object? cause;

  const PrayerCalculationException(
    this.type,
    this.message, {
    this.cause,
  });

  @override
  String toString() {
    if (cause != null) {
      return 'PrayerCalculationException(${type.name}): $message (cause: $cause)';
    }
    return 'PrayerCalculationException(${type.name}): $message';
  }
}

/// Pure, stateless service that calculates the six daily prayer times using
/// the installed `adhan` package, [PrayerSettings], and
/// [CountryMethodResolver].
///
/// ### Timezone & UTC Offset Semantics
/// - **`utcOffset == null` (default):** `adhan` converts each calculated UTC
///   solar timestamp to the host device's OS local timezone via
///   `DateTime.toLocal()`. Returned [DateTime] values have `isUtc == false`
///   and reflect the OS timezone rules (including host-device DST for that
///   date). This is only accurate for the user's current local timezone.
/// - **`utcOffset != null`:** `adhan` shifts each calculated UTC timestamp by
///   the supplied fixed [Duration] (`utcTimestamp.add(utcOffset)`), returning
///   [DateTime] values with `isUtc == true` whose clock fields (`hour`,
///   `minute`, etc.) represent wall-clock time in that fixed offset.
/// - **Fixed offset vs. IANA timezone:** An explicit [utcOffset] is a fixed
///   offset, not an IANA timezone identifier (such as `Europe/London` or
///   `America/New_York`). A fixed offset alone does not automatically adjust
///   for Daylight Saving Time (DST) transitions across arbitrary dates or
///   remote locations; callers passing an explicit [utcOffset] must supply the
///   offset valid for the target location on the target calendar date.
class PrayerCalculationService {
  /// Minimum supported Gregorian calendar year.
  static const int minSupportedYear = 1900;

  /// Maximum supported Gregorian calendar year.
  static const int maxSupportedYear = 9999;

  const PrayerCalculationService();

  /// Returns `true` if [latitude] is finite and within `[-90.0, 90.0]`.
  static bool isValidLatitude(double latitude) {
    return latitude.isFinite && latitude >= -90.0 && latitude <= 90.0;
  }

  /// Returns `true` if [longitude] is finite and within `[-180.0, 180.0]`.
  static bool isValidLongitude(double longitude) {
    return longitude.isFinite && longitude >= -180.0 && longitude <= 180.0;
  }

  /// Returns `true` if both [latitude] and [longitude] are valid geographic
  /// coordinates.
  static bool areValidCoordinates(double latitude, double longitude) {
    return isValidLatitude(latitude) && isValidLongitude(longitude);
  }

  /// Returns `true` if [year], [month], and [day] form a valid Gregorian
  /// calendar date within `[minSupportedYear, maxSupportedYear]`.
  static bool isValidCalendarDate(int year, int month, int day) {
    if (year < minSupportedYear || year > maxSupportedYear) {
      return false;
    }
    if (month < 1 || month > 12) {
      return false;
    }
    final maxDays = _daysInMonth(year, month);
    return day >= 1 && day <= maxDays;
  }

  static int _daysInMonth(int year, int month) {
    switch (month) {
      case 1:
      case 3:
      case 5:
      case 7:
      case 8:
      case 10:
      case 12:
        return 31;
      case 4:
      case 6:
      case 9:
      case 11:
        return 30;
      case 2:
        final isLeap = (year % 4 == 0) && (year % 100 != 0 || year % 400 == 0);
        return isLeap ? 29 : 28;
      default:
        return 0;
    }
  }

  /// Normalizes an optional ISO 3166-1 alpha-2 [countryCode] to a 2-letter
  /// uppercase string, or returns `null` if null, empty, or not 2 ASCII letters.
  static String? normalizeCountryCode(String? countryCode) {
    if (countryCode == null) {
      return null;
    }
    final trimmed = countryCode.trim().toUpperCase();
    if (trimmed.length != 2) {
      return null;
    }
    final codeUnit0 = trimmed.codeUnitAt(0);
    final codeUnit1 = trimmed.codeUnitAt(1);
    final isAlpha0 = codeUnit0 >= 65 && codeUnit0 <= 90;
    final isAlpha1 = codeUnit1 >= 65 && codeUnit1 <= 90;
    if (!isAlpha0 || !isAlpha1) {
      return null;
    }
    return trimmed;
  }

  /// Returns `true` if the six daily prayer timestamps follow valid
  /// non-decreasing chronological order:
  /// `fajr <= sunrise <= dhuhr <= asr <= maghrib <= isha` with `fajr < isha`.
  static bool isValidChronologicalOrder({
    required DateTime fajr,
    required DateTime sunrise,
    required DateTime dhuhr,
    required DateTime asr,
    required DateTime maghrib,
    required DateTime isha,
  }) {
    return !sunrise.isBefore(fajr) &&
        !dhuhr.isBefore(sunrise) &&
        !asr.isBefore(dhuhr) &&
        !maghrib.isBefore(asr) &&
        !isha.isBefore(maghrib) &&
        fajr.isBefore(isha);
  }

  /// Calculates prayer times for a [DateTime] calendar date.
  ///
  /// Extracts `date.year`, `date.month`, and `date.day` and delegates to
  /// [calculateForDateComponents].
  ///
  /// When [utcOffset] is `null`, returned [DateTime] values use the device OS
  /// local timezone (`isUtc == false`). When [utcOffset] is non-null, it is
  /// applied as a fixed offset from UTC (`isUtc == true`), not an IANA
  /// timezone; a fixed offset alone does not automatically account for DST
  /// transitions at arbitrary locations.
  ///
  /// Throws a [PrayerCalculationException] if coordinates or date are invalid,
  /// or if the underlying `adhan` calculation fails or produces non-chronological
  /// times. Unexpected programming errors (such as [TypeError], [StateError],
  /// or [AssertionError]) are not caught and will propagate.
  PrayerTimesResult calculate({
    required double latitude,
    required double longitude,
    required DateTime date,
    required PrayerSettings settings,
    String? countryCode,
    Duration? utcOffset,
  }) {
    return calculateForDateComponents(
      latitude: latitude,
      longitude: longitude,
      dateComponents: DateComponents(date.year, date.month, date.day),
      settings: settings,
      countryCode: countryCode,
      utcOffset: utcOffset,
    );
  }

  /// Calculates prayer times for explicit `adhan` [DateComponents].
  ///
  /// - Validates [latitude] and [longitude] (`[-90, 90]` and `[-180, 180]`).
  /// - Validates [dateComponents] calendar bounds (`year`, `month`, `day`).
  /// - Resolves the effective [CalculationMethod] and [CalculationParameters]
  ///   via [CountryMethodResolver] according to [settings.calculationMode],
  ///   [settings.manualCalculationMethod], [settings.madhab], and [countryCode].
  /// - Invokes `adhan`'s [PrayerTimes] constructor and verifies that the
  ///   resulting timestamps satisfy `fajr <= sunrise <= dhuhr <= asr <= maghrib <= isha`.
  /// - When [utcOffset] is `null`, returned [DateTime] values are converted to
  ///   the device OS local timezone (`isUtc == false`). When [utcOffset] is
  ///   provided, it is treated as a fixed offset from UTC (`isUtc == true`),
  ///   which does not automatically adjust for DST at arbitrary locations.
  ///
  /// Throws a [PrayerCalculationException] on invalid inputs or documented
  /// calculation failures (`ArgumentError` / `FormatException` from `adhan` or
  /// non-chronological output). Unexpected programming errors (such as
  /// [TypeError], [StateError], or [AssertionError]) propagate untouched.
  PrayerTimesResult calculateForDateComponents({
    required double latitude,
    required double longitude,
    required DateComponents dateComponents,
    required PrayerSettings settings,
    String? countryCode,
    Duration? utcOffset,
  }) {
    if (!isValidLatitude(latitude)) {
      throw PrayerCalculationException(
        PrayerCalculationErrorType.invalidCoordinates,
        'Invalid latitude ($latitude). Must be a finite number between -90.0 and 90.0.',
      );
    }

    if (!isValidLongitude(longitude)) {
      throw PrayerCalculationException(
        PrayerCalculationErrorType.invalidCoordinates,
        'Invalid longitude ($longitude). Must be a finite number between -180.0 and 180.0.',
      );
    }

    if (!isValidCalendarDate(
      dateComponents.year,
      dateComponents.month,
      dateComponents.day,
    )) {
      throw PrayerCalculationException(
        PrayerCalculationErrorType.invalidDate,
        'Invalid calendar date (${dateComponents.year}-${dateComponents.month}-${dateComponents.day}).',
      );
    }

    final normalizedCountry = normalizeCountryCode(countryCode);
    final effectiveMethod = CountryMethodResolver.resolveEffectiveMethod(
      settings,
      countryCode: normalizedCountry,
    );
    final calculationParameters =
        CountryMethodResolver.resolveCalculationParameters(
      settings,
      countryCode: normalizedCountry,
    );

    final PrayerTimes prayerTimes;
    try {
      final coordinates = Coordinates(latitude, longitude, validate: true);
      prayerTimes = PrayerTimes(
        coordinates,
        dateComponents,
        calculationParameters,
        utcOffset: utcOffset,
      );
    } on ArgumentError catch (error) {
      throw PrayerCalculationException(
        PrayerCalculationErrorType.calculationFailed,
        'Failed to calculate prayer times for coordinates ($latitude, $longitude).',
        cause: error,
      );
    } on FormatException catch (error) {
      throw PrayerCalculationException(
        PrayerCalculationErrorType.calculationFailed,
        'Failed to calculate prayer times due to invalid calculation parameters.',
        cause: error,
      );
    }

    if (!isValidChronologicalOrder(
      fajr: prayerTimes.fajr,
      sunrise: prayerTimes.sunrise,
      dhuhr: prayerTimes.dhuhr,
      asr: prayerTimes.asr,
      maghrib: prayerTimes.maghrib,
      isha: prayerTimes.isha,
    )) {
      throw PrayerCalculationException(
        PrayerCalculationErrorType.calculationFailed,
        'Calculated prayer times for ($latitude, $longitude) on '
        '${dateComponents.year}-${dateComponents.month}-${dateComponents.day} '
        'are not in valid chronological order.',
      );
    }

    return PrayerTimesResult(
      fajr: prayerTimes.fajr,
      sunrise: prayerTimes.sunrise,
      dhuhr: prayerTimes.dhuhr,
      asr: prayerTimes.asr,
      maghrib: prayerTimes.maghrib,
      isha: prayerTimes.isha,
      latitude: latitude,
      longitude: longitude,
      year: dateComponents.year,
      month: dateComponents.month,
      day: dateComponents.day,
      calculationMode: settings.calculationMode,
      calculationMethod: effectiveMethod,
      madhab: settings.madhab,
      countryCode: normalizedCountry,
    );
  }

  /// Null-safe wrapper around [calculate] that returns `null` when a
  /// [PrayerCalculationException] occurs (invalid inputs or documented
  /// calculation failure).
  ///
  /// Unexpected programming errors (such as [TypeError], [StateError], or
  /// [AssertionError]) are NOT caught and will propagate to the caller.
  PrayerTimesResult? tryCalculate({
    required double latitude,
    required double longitude,
    required DateTime date,
    required PrayerSettings settings,
    String? countryCode,
    Duration? utcOffset,
  }) {
    try {
      return calculate(
        latitude: latitude,
        longitude: longitude,
        date: date,
        settings: settings,
        countryCode: countryCode,
        utcOffset: utcOffset,
      );
    } on PrayerCalculationException {
      return null;
    }
  }
}

