import 'package:adhan/adhan.dart';
import 'package:flutter/foundation.dart';

import 'prayer_settings.dart';

/// Structured, immutable model holding the six calculated daily prayer times
/// and the resolved calculation metadata used to produce them.
///
/// All [DateTime] values preserve the exact output produced by the `adhan`
/// package without arbitrary offsets.
@immutable
class PrayerTimesResult {
  /// Fajr prayer time.
  final DateTime fajr;

  /// Sunrise (Shuruq) time.
  final DateTime sunrise;

  /// Dhuhr prayer time.
  final DateTime dhuhr;

  /// Asr prayer time.
  final DateTime asr;

  /// Maghrib prayer time.
  final DateTime maghrib;

  /// Isha prayer time.
  final DateTime isha;

  /// Latitude in degrees (`-90.0` to `90.0`) used for the calculation.
  final double latitude;

  /// Longitude in degrees (`-180.0` to `180.0`) used for the calculation.
  final double longitude;

  /// Calendar year of the requested calculation date.
  final int year;

  /// Calendar month (`1`–`12`) of the requested calculation date.
  final int month;

  /// Calendar day of month (`1`–`31`) of the requested calculation date.
  final int day;

  /// Calculation mode (`auto` or `manual`) active when calculating.
  final PrayerCalculationMode calculationMode;

  /// The effective `adhan` [CalculationMethod] applied to the calculation.
  final CalculationMethod calculationMethod;

  /// The `adhan` [Madhab] applied to the Asr calculation.
  final Madhab madhab;

  /// Normalized 2-letter uppercase ISO 3166-1 alpha-2 country code if one was
  /// supplied and valid, or `null` otherwise.
  final String? countryCode;

  /// Creates an immutable [PrayerTimesResult].
  const PrayerTimesResult({
    required this.fajr,
    required this.sunrise,
    required this.dhuhr,
    required this.asr,
    required this.maghrib,
    required this.isha,
    required this.latitude,
    required this.longitude,
    required this.year,
    required this.month,
    required this.day,
    required this.calculationMode,
    required this.calculationMethod,
    required this.madhab,
    this.countryCode,
  });

  /// Returns the `adhan` [DateComponents] corresponding to [year], [month],
  /// and [day].
  DateComponents get dateComponents => DateComponents(year, month, day);

  /// Returns the calculated [DateTime] for a specific `adhan` [Prayer], or
  /// `null` when [prayer] is [Prayer.none].
  DateTime? timeForPrayer(Prayer prayer) {
    switch (prayer) {
      case Prayer.fajr:
        return fajr;
      case Prayer.sunrise:
        return sunrise;
      case Prayer.dhuhr:
        return dhuhr;
      case Prayer.asr:
        return asr;
      case Prayer.maghrib:
        return maghrib;
      case Prayer.isha:
        return isha;
      case Prayer.none:
        return null;
    }
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is PrayerTimesResult &&
        other.fajr == fajr &&
        other.sunrise == sunrise &&
        other.dhuhr == dhuhr &&
        other.asr == asr &&
        other.maghrib == maghrib &&
        other.isha == isha &&
        other.latitude == latitude &&
        other.longitude == longitude &&
        other.year == year &&
        other.month == month &&
        other.day == day &&
        other.calculationMode == calculationMode &&
        other.calculationMethod == calculationMethod &&
        other.madhab == madhab &&
        other.countryCode == countryCode;
  }

  @override
  int get hashCode => Object.hash(
        fajr,
        sunrise,
        dhuhr,
        asr,
        maghrib,
        isha,
        latitude,
        longitude,
        year,
        month,
        day,
        calculationMode,
        calculationMethod,
        madhab,
        countryCode,
      );

  @override
  String toString() {
    return 'PrayerTimesResult('
        'date: $year-${month.toString().padLeft(2, '0')}-${day.toString().padLeft(2, '0')}, '
        'coordinates: ($latitude, $longitude), '
        'mode: ${calculationMode.name}, '
        'method: ${calculationMethod.name}, '
        'madhab: ${madhab.name}, '
        'countryCode: $countryCode, '
        'fajr: $fajr, '
        'sunrise: $sunrise, '
        'dhuhr: $dhuhr, '
        'asr: $asr, '
        'maghrib: $maghrib, '
        'isha: $isha'
        ')';
  }
}

