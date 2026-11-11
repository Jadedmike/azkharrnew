import 'package:adhan/adhan.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:adhkar/features/prayer/data/models/prayer_settings.dart';
import 'package:adhkar/features/prayer/data/models/prayer_times_result.dart';
import 'package:adhkar/features/prayer/data/services/prayer_calculation_service.dart';

/// Test helper that simulates an unexpected programming defect (e.g.
/// [StateError], [AssertionError], or [TypeError]) when accessed during
/// calculation, verifying that [PrayerCalculationService] does not swallow
/// programming errors.
class _ThrowingPrayerSettings extends PrayerSettings {
  final Object errorToThrow;

  const _ThrowingPrayerSettings(this.errorToThrow) : super.defaults();

  @override
  PrayerCalculationMode get calculationMode => throw errorToThrow;
}

void main() {
  const service = PrayerCalculationService();

  // Makkah coordinates
  const double makkahLat = 21.4225;
  const double makkahLng = 39.8262;
  final DateTime testDate = DateTime(2026, 3, 20);
  const Duration makkahUtcOffset = Duration(hours: 3);

  group('PrayerCalculationService Unit Tests', () {
    test(
      'calculates all six prayer times for valid coordinates and date matching adhan output exactly',
      () {
        const settings = PrayerSettings.defaults();
        final result = service.calculate(
          latitude: makkahLat,
          longitude: makkahLng,
          date: testDate,
          settings: settings,
          countryCode: 'SA',
          utcOffset: makkahUtcOffset,
        );

        // Compute direct reference from adhan package
        final expectedParams = CalculationMethod.umm_al_qura.getParameters()
          ..madhab = Madhab.shafi;
        final expectedAdhan = PrayerTimes(
          Coordinates(makkahLat, makkahLng),
          DateComponents(2026, 3, 20),
          expectedParams,
          utcOffset: makkahUtcOffset,
        );

        expect(result.fajr, equals(expectedAdhan.fajr));
        expect(result.sunrise, equals(expectedAdhan.sunrise));
        expect(result.dhuhr, equals(expectedAdhan.dhuhr));
        expect(result.asr, equals(expectedAdhan.asr));
        expect(result.maghrib, equals(expectedAdhan.maghrib));
        expect(result.isha, equals(expectedAdhan.isha));

        // Chronological order of all six daily prayer times
        expect(result.fajr.isBefore(result.sunrise), isTrue);
        expect(result.sunrise.isBefore(result.dhuhr), isTrue);
        expect(result.dhuhr.isBefore(result.asr), isTrue);
        expect(result.asr.isBefore(result.maghrib), isTrue);
        expect(result.maghrib.isBefore(result.isha), isTrue);

      // Verify helper timeForPrayer
      expect(result.timeForPrayer(Prayer.fajr), equals(result.fajr));
      expect(result.timeForPrayer(Prayer.sunrise), equals(result.sunrise));
      expect(result.timeForPrayer(Prayer.dhuhr), equals(result.dhuhr));
      expect(result.timeForPrayer(Prayer.asr), equals(result.asr));
      expect(result.timeForPrayer(Prayer.maghrib), equals(result.maghrib));
      expect(result.timeForPrayer(Prayer.isha), equals(result.isha));
      expect(result.timeForPrayer(Prayer.none), isNull);

      // Independent verification of Umm al-Qura 90-minute fixed Isha interval
      // and expected Makkah vernal equinox clock windows (UTC+3) without mirroring adhan:
      expect(
        result.isha.difference(result.maghrib),
        equals(const Duration(minutes: 90)),
      );
      expect(result.fajr.hour, equals(5));
      expect(result.sunrise.hour, equals(6));
      expect(result.dhuhr.hour, equals(12));
      expect(result.asr.hour, equals(15));
      expect(result.maghrib.hour, equals(18));
      expect(result.isha.hour, equals(20));
    },
  );

  test(
    'auto mode with supported country codes uses mapped CalculationMethod and changes calculated prayer times',
    () {
      const autoSettings = PrayerSettings.defaults();

      final saResult = service.calculate(
        latitude: makkahLat,
        longitude: makkahLng,
        date: testDate,
        settings: autoSettings,
        countryCode: 'sa',
        utcOffset: makkahUtcOffset,
      );
      expect(saResult.calculationMode, equals(PrayerCalculationMode.auto));
      expect(
        saResult.calculationMethod,
        equals(CalculationMethod.umm_al_qura),
      );
      expect(saResult.countryCode, equals('SA'));
      // Umm al-Qura uses a 90-minute Isha interval after Maghrib
      expect(
        saResult.isha.difference(saResult.maghrib),
        equals(const Duration(minutes: 90)),
      );

      // Same coordinates and date with Egypt ('EG' -> egyptian: Fajr 19.5°, Isha 17.5°)
      final egSameCoordsResult = service.calculate(
        latitude: makkahLat,
        longitude: makkahLng,
        date: testDate,
        settings: autoSettings,
        countryCode: 'EG',
        utcOffset: makkahUtcOffset,
      );
      expect(
        egSameCoordsResult.calculationMethod,
        equals(CalculationMethod.egyptian),
      );
      expect(egSameCoordsResult.countryCode, equals('EG'));

      // Same coordinates and date with Singapore ('SG' -> singapore: Fajr 20.0°, Isha 18.0°)
      final sgSameCoordsResult = service.calculate(
        latitude: makkahLat,
        longitude: makkahLng,
        date: testDate,
        settings: autoSettings,
        countryCode: 'SG',
        utcOffset: makkahUtcOffset,
      );
      expect(
        sgSameCoordsResult.calculationMethod,
        equals(CalculationMethod.singapore),
      );

      // Same coordinates and date with Iran ('IR' -> tehran: Fajr 17.7°, Isha 14.0°, Maghrib 4.5°)
      final irSameCoordsResult = service.calculate(
        latitude: makkahLat,
        longitude: makkahLng,
        date: testDate,
        settings: autoSettings,
        countryCode: 'IR',
        utcOffset: makkahUtcOffset,
      );
      expect(
        irSameCoordsResult.calculationMethod,
        equals(CalculationMethod.tehran),
      );

      // Verify that country mappings produce distinct calculated times:
      // Larger Fajr depression angle means earlier Fajr: SG (20.0°) < EG (19.5°) < SA (18.5°) < IR (17.7°)
      expect(sgSameCoordsResult.fajr.isBefore(egSameCoordsResult.fajr), isTrue);
      expect(egSameCoordsResult.fajr.isBefore(saResult.fajr), isTrue);
      expect(saResult.fajr.isBefore(irSameCoordsResult.fajr), isTrue);

      // SA (90-min fixed interval) Isha is later than angle-based EG (17.5°) and IR (14.0°)
      expect(saResult.isha.isAfter(egSameCoordsResult.isha), isTrue);
      expect(egSameCoordsResult.isha.isAfter(irSameCoordsResult.isha), isTrue);

      // IR (tehran uses 4.5° maghrib angle) has a later Maghrib than horizon-based SA/EG
      expect(irSameCoordsResult.maghrib.isAfter(saResult.maghrib), isTrue);

      final trResult = service.calculate(
        latitude: 41.0082,
        longitude: 28.9784,
        date: testDate,
        settings: autoSettings,
        countryCode: 'TR',
        utcOffset: const Duration(hours: 3),
      );
      expect(trResult.calculationMethod, equals(CalculationMethod.turkey));
      expect(trResult.countryCode, equals('TR'));
    },
  );

    test('auto mode with null, empty, or unknown country falls back to MWL', () {
      const autoSettings = PrayerSettings.defaults();

      final nullCountryResult = service.calculate(
        latitude: makkahLat,
        longitude: makkahLng,
        date: testDate,
        settings: autoSettings,
        countryCode: null,
        utcOffset: makkahUtcOffset,
      );
      expect(
        nullCountryResult.calculationMethod,
        equals(CalculationMethod.muslim_world_league),
      );
      expect(nullCountryResult.countryCode, isNull);

      final unknownCountryResult = service.calculate(
        latitude: makkahLat,
        longitude: makkahLng,
        date: testDate,
        settings: autoSettings,
        countryCode: 'US',
        utcOffset: makkahUtcOffset,
      );
      expect(
        unknownCountryResult.calculationMethod,
        equals(CalculationMethod.muslim_world_league),
      );
      expect(unknownCountryResult.countryCode, equals('US'));
      expect(unknownCountryResult.fajr, equals(nullCountryResult.fajr));
      expect(unknownCountryResult.isha, equals(nullCountryResult.isha));

      final malformedCountryResult = service.calculate(
        latitude: makkahLat,
        longitude: makkahLng,
        date: testDate,
        settings: autoSettings,
        countryCode: '123',
        utcOffset: makkahUtcOffset,
      );
      expect(
        malformedCountryResult.calculationMethod,
        equals(CalculationMethod.muslim_world_league),
      );
      expect(malformedCountryResult.countryCode, isNull);
    });

    test('manual calculation method overrides country resolution', () {
      final manualSettings = PrayerSettings(
        calculationMode: PrayerCalculationMode.manual,
        manualCalculationMethod: CalculationMethod.karachi,
        madhab: Madhab.shafi,
      );

      final withSaCountry = service.calculate(
        latitude: makkahLat,
        longitude: makkahLng,
        date: testDate,
        settings: manualSettings,
        countryCode: 'SA',
        utcOffset: makkahUtcOffset,
      );
      final withEgCountry = service.calculate(
        latitude: makkahLat,
        longitude: makkahLng,
        date: testDate,
        settings: manualSettings,
        countryCode: 'EG',
        utcOffset: makkahUtcOffset,
      );
      final withNullCountry = service.calculate(
        latitude: makkahLat,
        longitude: makkahLng,
        date: testDate,
        settings: manualSettings,
        countryCode: null,
        utcOffset: makkahUtcOffset,
      );

      expect(
        withSaCountry.calculationMethod,
        equals(CalculationMethod.karachi),
      );
      expect(
        withEgCountry.calculationMethod,
        equals(CalculationMethod.karachi),
      );
      expect(
        withNullCountry.calculationMethod,
        equals(CalculationMethod.karachi),
      );

      // Prayer times are identical regardless of supplied countryCode in manual mode
      expect(withSaCountry.fajr, equals(withNullCountry.fajr));
      expect(withSaCountry.isha, equals(withNullCountry.isha));
      expect(withEgCountry.fajr, equals(withNullCountry.fajr));
    });

    test('Shafi and Hanafi madhab settings produce expected Asr times', () {
      final shafiSettings = PrayerSettings(
        calculationMode: PrayerCalculationMode.manual,
        manualCalculationMethod: CalculationMethod.muslim_world_league,
        madhab: Madhab.shafi,
      );
      final hanafiSettings = shafiSettings.copyWith(madhab: Madhab.hanafi);

      final shafiResult = service.calculate(
        latitude: makkahLat,
        longitude: makkahLng,
        date: testDate,
        settings: shafiSettings,
        utcOffset: makkahUtcOffset,
      );
      final hanafiResult = service.calculate(
        latitude: makkahLat,
        longitude: makkahLng,
        date: testDate,
        settings: hanafiSettings,
        utcOffset: makkahUtcOffset,
      );

      expect(shafiResult.madhab, equals(Madhab.shafi));
      expect(hanafiResult.madhab, equals(Madhab.hanafi));

      // Hanafi Asr (double shadow length) occurs later than Shafi Asr (single shadow length)
      expect(hanafiResult.asr.isAfter(shafiResult.asr), isTrue);
      // Independently verify meaningful shadow-length separation (>= 30 minutes at Makkah equinox)
      expect(
        hanafiResult.asr.difference(shafiResult.asr).inMinutes,
        greaterThanOrEqualTo(30),
      );

      // Non-Asr prayers remain identical
      expect(hanafiResult.fajr, equals(shafiResult.fajr));
      expect(hanafiResult.sunrise, equals(shafiResult.sunrise));
      expect(hanafiResult.dhuhr, equals(shafiResult.dhuhr));
      expect(hanafiResult.maghrib, equals(shafiResult.maghrib));
      expect(hanafiResult.isha, equals(shafiResult.isha));
    });

    test(
      'default utcOffset == null path returns local DateTime values matching UTC instants without assuming host timezone',
      () {
        const settings = PrayerSettings.defaults();

        final localResult = service.calculate(
          latitude: makkahLat,
          longitude: makkahLng,
          date: testDate,
          settings: settings,
          countryCode: 'SA',
        );

        final utcZeroResult = service.calculate(
          latitude: makkahLat,
          longitude: makkahLng,
          date: testDate,
          settings: settings,
          countryCode: 'SA',
          utcOffset: Duration.zero,
        );

        // When utcOffset is null, all returned DateTime values must be local (isUtc == false)
        expect(localResult.fajr.isUtc, isFalse);
        expect(localResult.sunrise.isUtc, isFalse);
        expect(localResult.dhuhr.isUtc, isFalse);
        expect(localResult.asr.isUtc, isFalse);
        expect(localResult.maghrib.isUtc, isFalse);
        expect(localResult.isha.isUtc, isFalse);

        // When utcOffset is explicitly provided, returned DateTime values have isUtc == true
        expect(utcZeroResult.fajr.isUtc, isTrue);

        // Converting local DateTime values to UTC yields the exact same astronomical instants
        // regardless of which OS timezone the test machine is running in
        expect(localResult.fajr.toUtc(), equals(utcZeroResult.fajr));
        expect(localResult.sunrise.toUtc(), equals(utcZeroResult.sunrise));
        expect(localResult.dhuhr.toUtc(), equals(utcZeroResult.dhuhr));
        expect(localResult.asr.toUtc(), equals(utcZeroResult.asr));
        expect(localResult.maghrib.toUtc(), equals(utcZeroResult.maghrib));
        expect(localResult.isha.toUtc(), equals(utcZeroResult.isha));

        // Chronological order holds in local time
        expect(
          PrayerCalculationService.isValidChronologicalOrder(
            fajr: localResult.fajr,
            sunrise: localResult.sunrise,
            dhuhr: localResult.dhuhr,
            asr: localResult.asr,
            maghrib: localResult.maghrib,
            isha: localResult.isha,
          ),
          isTrue,
        );
      },
    );

    test(
      'handles valid high-latitude location in summer and enforces chronological order',
      () {
        const settings = PrayerSettings.defaults();

        // Copenhagen, Denmark (55.6761° N, 12.5683° E) on summer solstice (2026-06-21)
        // where twilight persists and adhan applies HighLatitudeRule.middle_of_the_night
        final highLatResult = service.calculate(
          latitude: 55.6761,
          longitude: 12.5683,
          date: DateTime(2026, 6, 21),
          settings: settings,
          utcOffset: const Duration(hours: 2),
        );

        expect(
          PrayerCalculationService.isValidChronologicalOrder(
            fajr: highLatResult.fajr,
            sunrise: highLatResult.sunrise,
            dhuhr: highLatResult.dhuhr,
            asr: highLatResult.asr,
            maghrib: highLatResult.maghrib,
            isha: highLatResult.isha,
          ),
          isTrue,
        );
        expect(highLatResult.fajr.isBefore(highLatResult.sunrise), isTrue);
        expect(highLatResult.sunrise.isBefore(highLatResult.dhuhr), isTrue);
        expect(highLatResult.dhuhr.isBefore(highLatResult.asr), isTrue);
        expect(highLatResult.asr.isBefore(highLatResult.maghrib), isTrue);
        expect(highLatResult.maghrib.isBefore(highLatResult.isha), isTrue);

        // Verify chronological validator rejects inverted or degenerate timestamps
        final base = DateTime.utc(2026, 6, 21, 4, 0);
        expect(
          PrayerCalculationService.isValidChronologicalOrder(
            fajr: base,
            sunrise: base.subtract(const Duration(minutes: 1)), // inverted
            dhuhr: base.add(const Duration(hours: 8)),
            asr: base.add(const Duration(hours: 12)),
            maghrib: base.add(const Duration(hours: 16)),
            isha: base.add(const Duration(hours: 18)),
          ),
          isFalse,
        );
        expect(
          PrayerCalculationService.isValidChronologicalOrder(
            fajr: base,
            sunrise: base.add(const Duration(hours: 1)),
            dhuhr: base.add(const Duration(hours: 8)),
            asr: base.add(const Duration(hours: 12)),
            maghrib: base.add(const Duration(hours: 16)),
            isha: base.add(const Duration(hours: 15)), // isha before maghrib
          ),
          isFalse,
        );
        expect(
          PrayerCalculationService.isValidChronologicalOrder(
            fajr: base,
            sunrise: base,
            dhuhr: base,
            asr: base,
            maghrib: base,
            isha: base, // degenerate zero-length day/night
          ),
          isFalse,
        );
      },
    );

    test(
      'propagates unexpected programming errors while converting expected calculation failures cleanly',
      () {
        const validSettings = PrayerSettings.defaults();

        // 1. Expected invalid calculation failure (polar sunrise/sunset NaN -> ArgumentError in adhan)
        // is converted to PrayerCalculationException in calculate() and returns null in tryCalculate()
        expect(
          () => service.calculate(
            latitude: 89.9,
            longitude: 0.0,
            date: DateTime(2026, 6, 21),
            settings: validSettings,
          ),
          throwsA(
            isA<PrayerCalculationException>().having(
              (e) => e.type,
              'type',
              equals(PrayerCalculationErrorType.calculationFailed),
            ),
          ),
        );
        expect(
          service.tryCalculate(
            latitude: 89.9,
            longitude: 0.0,
            date: DateTime(2026, 6, 21),
            settings: validSettings,
          ),
          isNull,
        );

        // 2. Unexpected programming errors (StateError, AssertionError, TypeError)
        // must propagate out of both calculate() and tryCalculate() without being swallowed
        final stateErrorSettings = _ThrowingPrayerSettings(
          StateError('Unexpected corrupted internal state'),
        );
        expect(
          () => service.calculate(
            latitude: makkahLat,
            longitude: makkahLng,
            date: testDate,
            settings: stateErrorSettings,
          ),
          throwsStateError,
        );
        expect(
          () => service.tryCalculate(
            latitude: makkahLat,
            longitude: makkahLng,
            date: testDate,
            settings: stateErrorSettings,
          ),
          throwsStateError,
        );

        final assertionErrorSettings = _ThrowingPrayerSettings(
          AssertionError('Violated internal invariant'),
        );
        expect(
          () => service.calculate(
            latitude: makkahLat,
            longitude: makkahLng,
            date: testDate,
            settings: assertionErrorSettings,
          ),
          throwsA(isA<AssertionError>()),
        );
        expect(
          () => service.tryCalculate(
            latitude: makkahLat,
            longitude: makkahLng,
            date: testDate,
            settings: assertionErrorSettings,
          ),
          throwsA(isA<AssertionError>()),
        );

        final typeErrorSettings = _ThrowingPrayerSettings(TypeError());
        expect(
          () => service.calculate(
            latitude: makkahLat,
            longitude: makkahLng,
            date: testDate,
            settings: typeErrorSettings,
          ),
          throwsA(isA<TypeError>()),
        );
        expect(
          () => service.tryCalculate(
            latitude: makkahLat,
            longitude: makkahLng,
            date: testDate,
            settings: typeErrorSettings,
          ),
          throwsA(isA<TypeError>()),
        );
      },
    );

    test('rejects invalid latitude and longitude safely', () {
      const settings = PrayerSettings.defaults();

      final invalidCoords = <List<double>>[
        <double>[-90.001, 39.8262],
        <double>[90.5, 39.8262],
        <double>[double.nan, 39.8262],
        <double>[double.infinity, 39.8262],
        <double>[double.negativeInfinity, 39.8262],
        <double>[21.4225, -180.001],
        <double>[21.4225, 180.5],
        <double>[21.4225, double.nan],
        <double>[21.4225, double.infinity],
        <double>[21.4225, double.negativeInfinity],
      ];

      for (final pair in invalidCoords) {
        expect(
          () => service.calculate(
            latitude: pair[0],
            longitude: pair[1],
            date: testDate,
            settings: settings,
          ),
          throwsA(
            isA<PrayerCalculationException>().having(
              (e) => e.type,
              'type',
              equals(PrayerCalculationErrorType.invalidCoordinates),
            ),
          ),
        );

        expect(
          service.tryCalculate(
            latitude: pair[0],
            longitude: pair[1],
            date: testDate,
            settings: settings,
          ),
          isNull,
        );
      }
    });

    test('rejects invalid calendar dates and handles polar calculation failure safely', () {
      const settings = PrayerSettings.defaults();

      final invalidDates = <DateComponents>[
        DateComponents(1899, 12, 31),
        DateComponents(10000, 1, 1),
        DateComponents(2026, 0, 15),
        DateComponents(2026, 13, 15),
        DateComponents(2026, 1, 0),
        DateComponents(2026, 1, 32),
        DateComponents(2025, 2, 29), // 2025 is not a leap year
        DateComponents(2024, 2, 30), // Feb 30 never exists
        DateComponents(2026, 4, 31), // April has 30 days
      ];

      for (final invalidDate in invalidDates) {
        expect(
          () => service.calculateForDateComponents(
            latitude: makkahLat,
            longitude: makkahLng,
            dateComponents: invalidDate,
            settings: settings,
          ),
          throwsA(
            isA<PrayerCalculationException>().having(
              (e) => e.type,
              'type',
              equals(PrayerCalculationErrorType.invalidDate),
            ),
          ),
        );
      }

      // Leap year Feb 29 (2024-02-29) is valid
      final leapDayResult = service.calculateForDateComponents(
        latitude: makkahLat,
        longitude: makkahLng,
        dateComponents: DateComponents(2024, 2, 29),
        settings: settings,
        utcOffset: makkahUtcOffset,
      );
      expect(leapDayResult.year, equals(2024));
      expect(leapDayResult.month, equals(2));
      expect(leapDayResult.day, equals(29));

      // Extreme polar latitude where sunrise/sunset is undefined (NaN in adhan)
      expect(
        () => service.calculate(
          latitude: 89.9,
          longitude: 0.0,
          date: DateTime(2026, 6, 21),
          settings: settings,
        ),
        throwsA(
          isA<PrayerCalculationException>().having(
            (e) => e.type,
            'type',
            equals(PrayerCalculationErrorType.calculationFailed),
          ),
        ),
      );
    });

    test('produces repeatable, equal PrayerTimesResult for identical inputs', () {
      const settings = PrayerSettings.defaults();

      final PrayerTimesResult first = service.calculate(
        latitude: makkahLat,
        longitude: makkahLng,
        date: testDate,
        settings: settings,
        countryCode: 'SA',
        utcOffset: makkahUtcOffset,
      );
      final PrayerTimesResult second = service.calculate(
        latitude: makkahLat,
        longitude: makkahLng,
        date: testDate,
        settings: settings,
        countryCode: 'sa',
        utcOffset: makkahUtcOffset,
      );

      expect(first, equals(second));
      expect(first.hashCode, equals(second.hashCode));
    });
  });
}

