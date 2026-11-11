import 'package:flutter_test/flutter_test.dart';

import 'package:adhkar/features/qibla/data/services/qibla_calculation_service.dart';

void main() {
  const service = QiblaCalculationService();

  group('QiblaCalculationService', () {
    test('calculates expected bearing from Istanbul to the Kaaba', () {
      // Istanbul (41.0082, 28.9784) -> Kaaba (21.422487, 39.826206): ~151.7 deg (SSE)
      final result = service.calculateBearing(
        latitude: 41.0082,
        longitude: 28.9784,
      );

      expect(result.bearing, inInclusiveRange(150.0, 153.5));
      expect(result.bearingDegrees, inInclusiveRange(150, 154));
      expect(result.distanceKm, inInclusiveRange(2350.0, 2450.0));
      expect(result.isAtKaaba, isFalse);
      expect(
        QiblaCalculationService.cardinalDirectionAr(result.bearing),
        'الجنوب الشرقي',
      );
    });

    test('calculates accurate bearings across multiple global locations', () {
      // Cairo (30.0444, 31.2357) -> SSE (~136 deg)
      final cairo = service.calculateBearing(
        latitude: 30.0444,
        longitude: 31.2357,
      );
      expect(cairo.bearing, inInclusiveRange(134.0, 138.0));

      // Riyadh (24.7136, 46.6753) -> WSW (~244 deg)
      final riyadh = service.calculateBearing(
        latitude: 24.7136,
        longitude: 46.6753,
      );
      expect(riyadh.bearing, inInclusiveRange(242.0, 246.0));

      // Jakarta (-6.2088, 106.8456) -> WNW (~295 deg)
      final jakarta = service.calculateBearing(
        latitude: -6.2088,
        longitude: 106.8456,
      );
      expect(jakarta.bearing, inInclusiveRange(293.0, 297.0));

      // London (51.5074, -0.1278) -> ESE (~119 deg)
      final london = service.calculateBearing(
        latitude: 51.5074,
        longitude: -0.1278,
      );
      expect(london.bearing, inInclusiveRange(117.0, 121.0));

      // New York (40.7128, -74.0060) -> ENE (~58 deg)
      final newYork = service.calculateBearing(
        latitude: 40.7128,
        longitude: -74.0060,
      );
      expect(newYork.bearing, inInclusiveRange(56.0, 60.0));

      // Sydney (-33.8688, 151.2093) -> WNW (~277 deg)
      final sydney = service.calculateBearing(
        latitude: -33.8688,
        longitude: 151.2093,
      );
      expect(sydney.bearing, inInclusiveRange(275.0, 280.0));
    });

    test('handles north-crossing and antimeridian angle normalization cleanly', () {
      // Directly South of Kaaba on same meridian -> due North (~0 deg)
      final dueSouth = service.calculateBearing(
        latitude: 10.0,
        longitude: QiblaCalculationService.kaabaLongitude,
      );
      expect(
        QiblaCalculationService.shortestSignedDelta(0.0, dueSouth.bearing).abs(),
        lessThan(0.01),
      );
      expect(dueSouth.bearingDegrees, 0);

      // Slightly East of Kaaba and South -> ~359.x deg -> whole degree normalizes to 0..359
      final nearlyNorthWest = service.calculateBearing(
        latitude: 20.0,
        longitude: QiblaCalculationService.kaabaLongitude + 0.002,
      );
      expect(nearlyNorthWest.bearing, greaterThanOrEqualTo(0.0));
      expect(nearlyNorthWest.bearing, lessThan(360.0));
      expect(nearlyNorthWest.bearingDegrees, inInclusiveRange(0, 359));

      // Antimeridian crossing (Fiji: -18.1416, 178.4419)
      final fiji = service.calculateBearing(
        latitude: -18.1416,
        longitude: 178.4419,
      );
      expect(fiji.bearing, greaterThanOrEqualTo(0.0));
      expect(fiji.bearing, lessThan(360.0));
      expect(fiji.bearingDegrees, inInclusiveRange(0, 359));
    });

    test('handles locations at or near the Kaaba safely without NaN', () {
      final exact = service.calculateBearing(
        latitude: QiblaCalculationService.kaabaLatitude,
        longitude: QiblaCalculationService.kaabaLongitude,
      );
      expect(exact.isAtKaaba, isTrue);
      expect(exact.bearing, 0.0);
      expect(exact.bearingDegrees, 0);
      expect(exact.distanceKm, closeTo(0.0, 0.001));

      // ~1 km north of Kaaba -> due South (~180 deg)
      final nearbyNorth = service.calculateBearing(
        latitude: QiblaCalculationService.kaabaLatitude + 0.01,
        longitude: QiblaCalculationService.kaabaLongitude,
      );
      expect(nearbyNorth.isAtKaaba, isFalse);
      expect(nearbyNorth.bearing, closeTo(180.0, 0.5));
    });

    test('rejects invalid, missing, NaN, and out-of-range coordinates safely', () {
      expect(QiblaCalculationService.areValidCoordinates(null, 39.8), isFalse);
      expect(QiblaCalculationService.areValidCoordinates(21.4, null), isFalse);
      expect(QiblaCalculationService.areValidCoordinates(double.nan, 39.8), isFalse);
      expect(
        QiblaCalculationService.areValidCoordinates(21.4, double.infinity),
        isFalse,
      );
      expect(QiblaCalculationService.areValidCoordinates(90.1, 39.8), isFalse);
      expect(QiblaCalculationService.areValidCoordinates(-90.1, 39.8), isFalse);
      expect(QiblaCalculationService.areValidCoordinates(21.4, 180.1), isFalse);
      expect(QiblaCalculationService.areValidCoordinates(21.4, -180.1), isFalse);

      expect(
        service.tryCalculateBearing(latitude: 95.0, longitude: 28.0),
        isNull,
      );
      expect(
        () => service.calculateBearing(latitude: 95.0, longitude: 28.0),
        throwsA(isA<QiblaCalculationException>()),
      );
    });

    test('normalizes angles, computes relative direction, and smooths across 359/0 wraparound', () {
      expect(QiblaCalculationService.normalizeAngle(-90.0), 270.0);
      expect(QiblaCalculationService.normalizeAngle(360.0), 0.0);
      expect(QiblaCalculationService.normalizeAngle(725.5), 5.5);
      expect(QiblaCalculationService.toWholeDegrees(359.9), 0);
      expect(QiblaCalculationService.toWholeDegrees(359.4), 359);

      // relativeDirection = (qiblaBearing - deviceHeading + 360) % 360
      expect(
        service.calculateRelativeDirection(
          qiblaBearing: 150.0,
          deviceHeading: 90.0,
        ),
        60.0,
      );
      expect(
        service.calculateRelativeDirection(
          qiblaBearing: 20.0,
          deviceHeading: 300.0,
        ),
        80.0,
      );
      expect(
        service.calculateRelativeDirection(
          qiblaBearing: 150.0,
          deviceHeading: -30.0,
        ),
        180.0,
      );

      // Circular smoothing across 358 -> 2 moves clockwise through 359/0 rather than 180
      final double smoothed = service.smoothHeading(
        previousSmoothed: 358.0,
        rawHeading: 2.0,
        alpha: 0.5,
      );
      expect(smoothed, closeTo(0.0, 0.01));

      // Deadband prevents rebuild jitter under 0.5 degrees
      final double unchanged = service.smoothHeading(
        previousSmoothed: 120.0,
        rawHeading: 120.2,
      );
      expect(unchanged, 120.0);
    });

    test('handles extreme pole latitude numerical edge cases without NaN', () {
      final northPolePrime = service.calculateBearing(latitude: 90.0, longitude: 0.0);
      expect(northPolePrime.bearing.isFinite, isTrue);
      expect(
        northPolePrime.bearing,
        closeTo(180.0 - QiblaCalculationService.kaabaLongitude, 0.01),
      );

      final northPoleKaabaMeridian = service.calculateBearing(
        latitude: 90.0,
        longitude: QiblaCalculationService.kaabaLongitude,
      );
      expect(northPoleKaabaMeridian.bearing, closeTo(180.0, 0.01));

      final southPole = service.calculateBearing(latitude: -90.0, longitude: 0.0);
      expect(southPole.bearing.isFinite, isTrue);
      expect(southPole.bearingDegrees, inInclusiveRange(0, 359));
    });
  });
}

