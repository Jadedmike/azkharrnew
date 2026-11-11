import 'package:flutter_test/flutter_test.dart';

import 'package:adhkar/features/qibla/data/services/magnetic_declination_service.dart';

void main() {
  const service = MagneticDeclinationService();

  group('MagneticDeclinationService (NOAA WMM-2025 Reference Validation)', () {
    /// Reference dataset: Official NOAA/NCEI WMM-2025 `WMM2025_TestValues.txt`
    /// distributed inside `WMM2025COF.zip` (model release 11/13/2024, valid 2025.0–2030.0).
    /// Tolerance: within 0.02 degrees of published NOAA test values (values below rounded to 2 d.p.).
    final wmm2025ReferenceCases = <({
      double decimalYear,
      double altitudeKm,
      double latitude,
      double longitude,
      double expectedDeclinationDeg,
      String label,
    })>[
      // Positive East declination cases
      (
        decimalYear: 2025.0,
        altitudeKm: 0.0,
        latitude: 80.0,
        longitude: 0.0,
        expectedDeclinationDeg: 1.28,
        label: '2025.0 surface 80N 0E (positive east)',
      ),
      (
        decimalYear: 2027.5,
        altitudeKm: 0.0,
        latitude: 80.0,
        longitude: 0.0,
        expectedDeclinationDeg: 2.59,
        label: '2027.5 surface 80N 0E (secular variation positive east)',
      ),
      (
        decimalYear: 2025.0,
        altitudeKm: 3.0,
        latitude: -50.0,
        longitude: -103.0,
        expectedDeclinationDeg: 27.96,
        label: '2025.0 HAE=3km 50S 103W (South Pacific strong east)',
      ),
      (
        decimalYear: 2025.5,
        altitudeKm: 44.0,
        latitude: 33.0,
        longitude: -118.0,
        expectedDeclinationDeg: 11.10,
        label: '2025.5 HAE=44km 33N 118W (California east)',
      ),
      (
        decimalYear: 2028.5,
        altitudeKm: 95.0,
        latitude: 30.0,
        longitude: 28.0,
        expectedDeclinationDeg: 4.56,
        label: '2028.5 HAE=95km 30N 28E (Eastern Mediterranean)',
      ),
      // Negative West declination cases
      (
        decimalYear: 2025.0,
        altitudeKm: 0.0,
        latitude: 0.0,
        longitude: 120.0,
        expectedDeclinationDeg: -0.16,
        label: '2025.0 surface 0N 120E (negative west near zero)',
      ),
      (
        decimalYear: 2027.5,
        altitudeKm: 0.0,
        latitude: 0.0,
        longitude: 120.0,
        expectedDeclinationDeg: -0.24,
        label: '2027.5 surface 0N 120E (negative west)',
      ),
      (
        decimalYear: 2026.0,
        altitudeKm: 34.0,
        latitude: -19.0,
        longitude: 43.0,
        expectedDeclinationDeg: -14.98,
        label: '2026.0 HAE=34km 19S 43E (Mozambique Channel west)',
      ),
      (
        decimalYear: 2027.5,
        altitudeKm: 0.0,
        latitude: -13.0,
        longitude: -59.0,
        expectedDeclinationDeg: -17.49,
        label: '2027.5 surface 13S 59W (South America west)',
      ),
      (
        decimalYear: 2029.0,
        altitudeKm: 41.0,
        latitude: 42.0,
        longitude: -19.0,
        expectedDeclinationDeg: -4.13,
        label: '2029.0 HAE=41km 42N 19W (North Atlantic west)',
      ),
      // High-latitude large magnitude & southern ocean cases
      (
        decimalYear: 2025.0,
        altitudeKm: 0.0,
        latitude: -80.0,
        longitude: -120.0, // 240 E
        expectedDeclinationDeg: 68.78,
        label: '2025.0 surface 80S 240E',
      ),
      (
        decimalYear: 2027.5,
        altitudeKm: 0.0,
        latitude: -80.0,
        longitude: -120.0, // 240 E
        expectedDeclinationDeg: 68.49,
        label: '2027.5 surface 80S 240E',
      ),
      (
        decimalYear: 2029.5,
        altitudeKm: 33.0,
        latitude: 17.0,
        longitude: 5.0,
        expectedDeclinationDeg: 0.89,
        label: '2029.5 HAE=33km 17N 5E (West Africa small east)',
      ),
    ];

    for (final testCase in wmm2025ReferenceCases) {
      test('matches NOAA WMM-2025 official value for ${testCase.label}', () {
        final result = service.calculateForDecimalYear(
          latitude: testCase.latitude,
          longitude: testCase.longitude,
          decimalYear: testCase.decimalYear,
          altitudeKm: testCase.altitudeKm,
        );

        expect(result.modelName, 'WMM-2025');
        expect(
          result.declinationDegrees,
          closeTo(testCase.expectedDeclinationDeg, 0.02),
        );
      });
    }

    test('calculates positive East declination for Istanbul in 2026 via DateTime API', () {
      final result = service.calculate(
        latitude: 41.0082,
        longitude: 28.9784,
        date: DateTime.utc(2026, 11, 10),
      );

      // Eastern Mediterranean / Istanbul geomagnetic declination in late 2026 is ~ +6° E
      expect(result.declinationDegrees, inInclusiveRange(5.0, 8.0));
    });

    test('accepts supported boundary dates across 2025–2029 and rejects out-of-range dates', () {
      expect(
        service
            .calculate(
              latitude: 41.0,
              longitude: 29.0,
              date: DateTime.utc(2025, 1, 1, 0, 0),
            )
            .declinationDegrees
            .isFinite,
        isTrue,
      );
      expect(
        service
            .calculate(
              latitude: 41.0,
              longitude: 29.0,
              date: DateTime.utc(2029, 12, 31, 23, 59, 59),
            )
            .declinationDegrees
            .isFinite,
        isTrue,
      );

      expect(
        () => service.calculate(
          latitude: 41.0,
          longitude: 29.0,
          date: DateTime.utc(2024, 12, 31, 23, 59),
        ),
        throwsA(
          predicate<MagneticDeclinationException>(
            (e) => e.type == MagneticDeclinationErrorType.unsupportedDate,
          ),
        ),
      );

      expect(
        () => service.calculate(
          latitude: 41.0,
          longitude: 29.0,
          date: DateTime.utc(2030, 1, 1, 0, 0),
        ),
        throwsA(
          predicate<MagneticDeclinationException>(
            (e) => e.type == MagneticDeclinationErrorType.unsupportedDate,
          ),
        ),
      );
    });

    test('rejects invalid coordinates and non-finite altitudes explicitly', () {
      expect(
        () => service.calculate(
          latitude: 95.0,
          longitude: 29.0,
          date: DateTime.utc(2026, 6, 1),
        ),
        throwsA(
          predicate<MagneticDeclinationException>(
            (e) => e.type == MagneticDeclinationErrorType.invalidCoordinates,
          ),
        ),
      );

      expect(
        () => service.calculate(
          latitude: double.nan,
          longitude: 29.0,
          date: DateTime.utc(2026, 6, 1),
        ),
        throwsA(
          predicate<MagneticDeclinationException>(
            (e) => e.type == MagneticDeclinationErrorType.invalidCoordinates,
          ),
        ),
      );

      expect(
        () => service.calculate(
          latitude: 41.0,
          longitude: 29.0,
          date: DateTime.utc(2026, 6, 1),
          altitudeKm: double.infinity,
        ),
        throwsA(
          predicate<MagneticDeclinationException>(
            (e) => e.type == MagneticDeclinationErrorType.invalidAltitude,
          ),
        ),
      );
    });
  });
}

