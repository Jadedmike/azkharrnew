import 'dart:math' as math;

import 'package:flutter/foundation.dart';

/// Typed error classification for Qibla calculation failures.
class QiblaCalculationException implements Exception {
  final String message;

  const QiblaCalculationException(this.message);

  @override
  String toString() => 'QiblaCalculationException: $message';
}

/// Immutable result of calculating the great-circle Qibla bearing and distance
/// from a user coordinate to the Kaaba.
@immutable
class QiblaCalculationResult {
  /// Exact initial great-circle bearing in degrees normalized to `[0.0, 360.0)`.
  final double bearing;

  /// Nearest whole-degree bearing normalized to `0..359`.
  final int bearingDegrees;

  /// Great-circle distance to the Kaaba in kilometers.
  final double distanceKm;

  /// Whether the user's coordinates are effectively at the Kaaba location.
  final bool isAtKaaba;

  const QiblaCalculationResult({
    required this.bearing,
    required this.bearingDegrees,
    required this.distanceKm,
    this.isAtKaaba = false,
  });

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is QiblaCalculationResult &&
        other.bearing == bearing &&
        other.bearingDegrees == bearingDegrees &&
        other.distanceKm == distanceKm &&
        other.isAtKaaba == isAtKaaba;
  }

  @override
  int get hashCode => Object.hash(bearing, bearingDegrees, distanceKm, isAtKaaba);
}

/// Pure, stateless service for calculating the Qibla direction (initial
/// great-circle bearing toward the Kaaba) and compass orientation math.
///
/// Completely independent from UI widgets, GPS plugins, and sensor streams.
class QiblaCalculationService {
  /// Official latitude of the Kaaba in degrees North.
  static const double kaabaLatitude = 21.422487;

  /// Official longitude of the Kaaba in degrees East.
  static const double kaabaLongitude = 39.826206;

  /// Mean Earth radius in kilometers (IUGG mean radius).
  static const double _earthRadiusKm = 6371.0088;

  /// Radius in kilometers inside which the user is considered at the Kaaba
  /// and initial azimuth becomes geometrically degenerate.
  static const double _kaabaProximityThresholdKm = 0.02;

  const QiblaCalculationService();

  /// Returns `true` if [latitude] and [longitude] are non-null, finite, and
  /// within valid WGS84 geographic bounds.
  static bool areValidCoordinates(double? latitude, double? longitude) {
    if (latitude == null || longitude == null) {
      return false;
    }
    return latitude.isFinite &&
        latitude >= -90.0 &&
        latitude <= 90.0 &&
        longitude.isFinite &&
        longitude >= -180.0 &&
        longitude <= 180.0;
  }

  /// Normalizes any finite [angleDegrees] into `[0.0, 360.0)`.
  static double normalizeAngle(double angleDegrees) {
    if (!angleDegrees.isFinite) {
      return 0.0;
    }
    final double wrapped = angleDegrees % 360.0;
    final double positive = wrapped < 0 ? wrapped + 360.0 : wrapped;
    if (positive >= 360.0 || positive == 0.0) {
      return 0.0;
    }
    return positive;
  }

  /// Converts a continuous angle into an integer degree in `0..359`.
  static int toWholeDegrees(double angleDegrees) {
    if (!angleDegrees.isFinite) {
      return 0;
    }
    final int rounded = normalizeAngle(angleDegrees).round() % 360;
    return rounded < 0 ? rounded + 360 : rounded;
  }

  /// Returns the shortest signed angular difference in `[-180.0, 180.0)`
  /// from [fromDegrees] to [toDegrees].
  static double shortestSignedDelta(double fromDegrees, double toDegrees) {
    final double from = normalizeAngle(fromDegrees);
    final double to = normalizeAngle(toDegrees);
    return ((to - from + 540.0) % 360.0) - 180.0;
  }

  /// Applies shortest-arc exponential smoothing to compass headings while
  /// rejecting tiny jitter smaller than [deadbandDegrees] to avoid noisy
  /// UI rebuilds.
  double smoothHeading({
    required double? previousSmoothed,
    required double rawHeading,
    double alpha = 0.25,
    double deadbandDegrees = 0.5,
  }) {
    final double target = normalizeAngle(rawHeading);
    if (previousSmoothed == null || !previousSmoothed.isFinite) {
      return target;
    }

    final double current = normalizeAngle(previousSmoothed);
    final double delta = shortestSignedDelta(current, target);
    if (delta.abs() < deadbandDegrees) {
      return current;
    }

    final double clampedAlpha = alpha.clamp(0.05, 1.0);
    return normalizeAngle(current + clampedAlpha * delta);
  }

  /// Computes the Qibla direction relative to the phone's current heading:
  /// `relativeDirection = (qiblaBearing - deviceHeading + 360) % 360`.
  double calculateRelativeDirection({
    required double qiblaBearing,
    required double deviceHeading,
  }) {
    final double qibla = normalizeAngle(qiblaBearing);
    final double heading = normalizeAngle(deviceHeading);
    return normalizeAngle((qibla - heading + 360.0) % 360.0);
  }

  /// Calculates the initial great-circle Qibla bearing and distance from
  /// ([latitude], [longitude]) to the Kaaba, throwing
  /// [QiblaCalculationException] if coordinates are invalid.
  QiblaCalculationResult calculateBearing({
    required double latitude,
    required double longitude,
  }) {
    if (!areValidCoordinates(latitude, longitude)) {
      throw QiblaCalculationException(
        'Invalid coordinates ($latitude, $longitude).',
      );
    }

    final double distanceKm = _haversineDistanceKm(
      latitude,
      longitude,
      kaabaLatitude,
      kaabaLongitude,
    );

    if (distanceKm < _kaabaProximityThresholdKm) {
      return QiblaCalculationResult(
        bearing: 0.0,
        bearingDegrees: 0,
        distanceKm: distanceKm,
        isAtKaaba: true,
      );
    }

    final double lat1 = _degToRad(latitude);
    final double lat2 = _degToRad(kaabaLatitude);
    final double dLng = _degToRad(kaabaLongitude - longitude);

    final double y = math.sin(dLng) * math.cos(lat2);
    final double x =
        math.cos(lat1) * math.sin(lat2) -
        math.sin(lat1) * math.cos(lat2) * math.cos(dLng);

    final double rawBearingDeg = _radToDeg(math.atan2(y, x));
    final double bearing = normalizeAngle(rawBearingDeg);

    return QiblaCalculationResult(
      bearing: bearing,
      bearingDegrees: toWholeDegrees(bearing),
      distanceKm: distanceKm,
      isAtKaaba: false,
    );
  }

  /// Null-safe wrapper around [calculateBearing] returning `null` if
  /// coordinates are missing, non-finite, or out of geographic bounds.
  QiblaCalculationResult? tryCalculateBearing({
    required double? latitude,
    required double? longitude,
  }) {
    if (!areValidCoordinates(latitude, longitude)) {
      return null;
    }
    try {
      return calculateBearing(
        latitude: latitude!,
        longitude: longitude!,
      );
    } on QiblaCalculationException {
      return null;
    }
  }

  /// Returns a concise Arabic cardinal/intercardinal label for [bearing].
  static String cardinalDirectionAr(double bearing) {
    final int normalized = toWholeDegrees(bearing);
    const labels = <String>[
      'الشمال',
      'الشمال الشرقي',
      'الشرق',
      'الجنوب الشرقي',
      'الجنوب',
      'الجنوب الغربي',
      'الغرب',
      'الشمال الغربي',
    ];
    final int sector = ((normalized + 22.5) ~/ 45) % 8;
    return labels[sector];
  }

  static double _degToRad(double degrees) => degrees * (math.pi / 180.0);

  static double _radToDeg(double radians) => radians * (180.0 / math.pi);

  static double _haversineDistanceKm(
    double lat1Deg,
    double lng1Deg,
    double lat2Deg,
    double lng2Deg,
  ) {
    final double dLat = _degToRad(lat2Deg - lat1Deg);
    final double dLng = _degToRad(lng2Deg - lng1Deg);
    final double lat1 = _degToRad(lat1Deg);
    final double lat2 = _degToRad(lat2Deg);

    final double sinHalfLat = math.sin(dLat / 2.0);
    final double sinHalfLng = math.sin(dLng / 2.0);
    final double a =
        sinHalfLat * sinHalfLat +
        math.cos(lat1) * math.cos(lat2) * sinHalfLng * sinHalfLng;
    final double c = 2.0 * math.atan2(math.sqrt(a), math.sqrt(1.0 - a));
    return _earthRadiusKm * c;
  }
}

