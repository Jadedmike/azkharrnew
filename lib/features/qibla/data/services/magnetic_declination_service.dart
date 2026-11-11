import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import 'qibla_calculation_service.dart';

/// Error categories for [MagneticDeclinationService].
enum MagneticDeclinationErrorType {
  /// Latitude or longitude is missing, non-finite, or outside WGS84 bounds.
  invalidCoordinates,

  /// Altitude is non-finite.
  invalidAltitude,

  /// Target calculation date falls outside the WMM-2025 supported epoch window.
  unsupportedDate,

  /// Underlying geomagnetic computation failed or produced non-finite output.
  calculationFailed,
}

/// Typed exception thrown when magnetic declination cannot be computed safely.
class MagneticDeclinationException implements Exception {
  final MagneticDeclinationErrorType type;
  final String message;

  const MagneticDeclinationException(this.type, this.message);

  @override
  String toString() => 'MagneticDeclinationException(${type.name}): $message';
}

/// Immutable geomagnetic calculation result from WMM-2025.
@immutable
class MagneticDeclinationResult {
  /// Magnetic declination in degrees (`+` East of True North, `-` West of True North).
  final double declinationDegrees;

  /// Decimal year used to propagate secular variation from epoch `2025.0`.
  final double decimalYear;

  /// Model identifier (`WMM-2025`).
  final String modelName;

  const MagneticDeclinationResult({
    required this.declinationDegrees,
    required this.decimalYear,
    this.modelName = MagneticDeclinationService.modelName,
  });

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is MagneticDeclinationResult &&
        other.declinationDegrees == declinationDegrees &&
        other.decimalYear == decimalYear &&
        other.modelName == modelName;
  }

  @override
  int get hashCode => Object.hash(declinationDegrees, decimalYear, modelName);
}

/// Coefficient entry `(n, m, g, h, gDot, hDot)` from NOAA/BGS `WMM.COF`.
class _WmmCoefficient {
  final int n;
  final int m;
  final double g;
  final double h;
  final double gDot;
  final double hDot;

  const _WmmCoefficient(
    this.n,
    this.m,
    this.g,
    this.h,
    this.gDot,
    this.hDot,
  );
}

/// Offline World Magnetic Model (**WMM-2025**) calculator producing local
/// geomagnetic declination from geodetic WGS-84 coordinates and date.
///
/// ### Model Specification
/// - **Model:** `WMM-2025` (NOAA NCEI / BGS release date `11/13/2024`, degree `N = 12`).
/// - **Epoch & Supported Date Range:** Epoch `2025.0`, valid for decimal years
///   `[2025.0, 2030.0)` (`2025-01-01T00:00:00Z` through `2029-12-31T23:59:59Z`).
///   Dates outside this range throw [MagneticDeclinationException] rather than
///   silently assuming zero declination.
/// - **Units & Sign Convention:** Declination is returned in **degrees**, where
///   **positive values denote East declination** (Magnetic North lies East of
///   True North, so `trueHeading = magneticHeading + declination`) and
///   **negative values denote West declination** (Magnetic North lies West of
///   True North).
/// - **Altitude:** Height above WGS-84 ellipsoid (`haeKm`) in kilometers,
///   defaulting to `0.0` km (mean sea/ellipsoid level).
class MagneticDeclinationService {
  static const String modelName = 'WMM-2025';
  static const double epochYear = 2025.0;
  static const double minSupportedDecimalYear = 2025.0;
  static const double maxSupportedDecimalYearExclusive = 2030.0;
  static const int maxDegree = 12;

  // WGS-84 ellipsoid & IGRF/WMM geomagnetic reference sphere constants (km).
  static const double _wgs84SemiMajorKm = 6378.137;
  static const double _wgs84InverseFlattening = 298.257223563;
  static const double _geomagneticReferenceRadiusKm = 6371.2;

  /// Official NOAA/BGS WMM-2025 `WMM.COF` main field (`nT`) and secular
  /// variation (`nT/yr`) Gauss coefficients (`11/13/2024`).
  static const List<_WmmCoefficient> _coefficients = <_WmmCoefficient>[
    _WmmCoefficient(1, 0, -29351.8, 0.0, 12.0, 0.0),
    _WmmCoefficient(1, 1, -1410.8, 4545.4, 9.7, -21.5),
    _WmmCoefficient(2, 0, -2556.6, 0.0, -11.6, 0.0),
    _WmmCoefficient(2, 1, 2951.1, -3133.6, -5.2, -27.7),
    _WmmCoefficient(2, 2, 1649.3, -815.1, -8.0, -12.1),
    _WmmCoefficient(3, 0, 1361.0, 0.0, -1.3, 0.0),
    _WmmCoefficient(3, 1, -2404.1, -56.6, -4.2, 4.0),
    _WmmCoefficient(3, 2, 1243.8, 237.5, 0.4, -0.3),
    _WmmCoefficient(3, 3, 453.6, -549.5, -15.6, -4.1),
    _WmmCoefficient(4, 0, 895.0, 0.0, -1.6, 0.0),
    _WmmCoefficient(4, 1, 799.5, 278.6, -2.4, -1.1),
    _WmmCoefficient(4, 2, 55.7, -133.9, -6.0, 4.1),
    _WmmCoefficient(4, 3, -281.1, 212.0, 5.6, 1.6),
    _WmmCoefficient(4, 4, 12.1, -375.6, -7.0, -4.4),
    _WmmCoefficient(5, 0, -233.2, 0.0, 0.6, 0.0),
    _WmmCoefficient(5, 1, 368.9, 45.4, 1.4, -0.5),
    _WmmCoefficient(5, 2, 187.2, 220.2, 0.0, 2.2),
    _WmmCoefficient(5, 3, -138.7, -122.9, 0.6, 0.4),
    _WmmCoefficient(5, 4, -142.0, 43.0, 2.2, 1.7),
    _WmmCoefficient(5, 5, 20.9, 106.1, 0.9, 1.9),
    _WmmCoefficient(6, 0, 64.4, 0.0, -0.2, 0.0),
    _WmmCoefficient(6, 1, 63.8, -18.4, -0.4, 0.3),
    _WmmCoefficient(6, 2, 76.9, 16.8, 0.9, -1.6),
    _WmmCoefficient(6, 3, -115.7, 48.8, 1.2, -0.4),
    _WmmCoefficient(6, 4, -40.9, -59.8, -0.9, 0.9),
    _WmmCoefficient(6, 5, 14.9, 10.9, 0.3, 0.7),
    _WmmCoefficient(6, 6, -60.7, 72.7, 0.9, 0.9),
    _WmmCoefficient(7, 0, 79.5, 0.0, -0.0, 0.0),
    _WmmCoefficient(7, 1, -77.0, -48.9, -0.1, 0.6),
    _WmmCoefficient(7, 2, -8.8, -14.4, -0.1, 0.5),
    _WmmCoefficient(7, 3, 59.3, -1.0, 0.5, -0.8),
    _WmmCoefficient(7, 4, 15.8, 23.4, -0.1, 0.0),
    _WmmCoefficient(7, 5, 2.5, -7.4, -0.8, -1.0),
    _WmmCoefficient(7, 6, -11.1, -25.1, -0.8, 0.6),
    _WmmCoefficient(7, 7, 14.2, -2.3, 0.8, -0.2),
    _WmmCoefficient(8, 0, 23.2, 0.0, -0.1, 0.0),
    _WmmCoefficient(8, 1, 10.8, 7.1, 0.2, -0.2),
    _WmmCoefficient(8, 2, -17.5, -12.6, 0.0, 0.5),
    _WmmCoefficient(8, 3, 2.0, 11.4, 0.5, -0.4),
    _WmmCoefficient(8, 4, -21.7, -9.7, -0.1, 0.4),
    _WmmCoefficient(8, 5, 16.9, 12.7, 0.3, -0.5),
    _WmmCoefficient(8, 6, 15.0, 0.7, 0.2, -0.6),
    _WmmCoefficient(8, 7, -16.8, -5.2, -0.0, 0.3),
    _WmmCoefficient(8, 8, 0.9, 3.9, 0.2, 0.2),
    _WmmCoefficient(9, 0, 4.6, 0.0, -0.0, 0.0),
    _WmmCoefficient(9, 1, 7.8, -24.8, -0.1, -0.3),
    _WmmCoefficient(9, 2, 3.0, 12.2, 0.1, 0.3),
    _WmmCoefficient(9, 3, -0.2, 8.3, 0.3, -0.3),
    _WmmCoefficient(9, 4, -2.5, -3.3, -0.3, 0.3),
    _WmmCoefficient(9, 5, -13.1, -5.2, 0.0, 0.2),
    _WmmCoefficient(9, 6, 2.4, 7.2, 0.3, -0.1),
    _WmmCoefficient(9, 7, 8.6, -0.6, -0.1, -0.2),
    _WmmCoefficient(9, 8, -8.7, 0.8, 0.1, 0.4),
    _WmmCoefficient(9, 9, -12.9, 10.0, -0.1, 0.1),
    _WmmCoefficient(10, 0, -1.3, 0.0, 0.1, 0.0),
    _WmmCoefficient(10, 1, -6.4, 3.3, 0.0, 0.0),
    _WmmCoefficient(10, 2, 0.2, 0.0, 0.1, -0.0),
    _WmmCoefficient(10, 3, 2.0, 2.4, 0.1, -0.2),
    _WmmCoefficient(10, 4, -1.0, 5.3, -0.0, 0.1),
    _WmmCoefficient(10, 5, -0.6, -9.1, -0.3, -0.1),
    _WmmCoefficient(10, 6, -0.9, 0.4, 0.0, 0.1),
    _WmmCoefficient(10, 7, 1.5, -4.2, -0.1, 0.0),
    _WmmCoefficient(10, 8, 0.9, -3.8, -0.1, -0.1),
    _WmmCoefficient(10, 9, -2.7, 0.9, -0.0, 0.2),
    _WmmCoefficient(10, 10, -3.9, -9.1, -0.0, -0.0),
    _WmmCoefficient(11, 0, 2.9, 0.0, 0.0, 0.0),
    _WmmCoefficient(11, 1, -1.5, 0.0, -0.0, -0.0),
    _WmmCoefficient(11, 2, -2.5, 2.9, 0.0, 0.1),
    _WmmCoefficient(11, 3, 2.4, -0.6, 0.0, -0.0),
    _WmmCoefficient(11, 4, -0.6, 0.2, 0.0, 0.1),
    _WmmCoefficient(11, 5, -0.1, 0.5, -0.1, -0.0),
    _WmmCoefficient(11, 6, -0.6, -0.3, 0.0, -0.0),
    _WmmCoefficient(11, 7, -0.1, -1.2, -0.0, 0.1),
    _WmmCoefficient(11, 8, 1.1, -1.7, -0.1, -0.0),
    _WmmCoefficient(11, 9, -1.0, -2.9, -0.1, 0.0),
    _WmmCoefficient(11, 10, -0.2, -1.8, -0.1, 0.0),
    _WmmCoefficient(11, 11, 2.6, -2.3, -0.1, 0.0),
    _WmmCoefficient(12, 0, -2.0, 0.0, 0.0, 0.0),
    _WmmCoefficient(12, 1, -0.2, -1.3, 0.0, -0.0),
    _WmmCoefficient(12, 2, 0.3, 0.7, -0.0, 0.0),
    _WmmCoefficient(12, 3, 1.2, 1.0, -0.0, -0.1),
    _WmmCoefficient(12, 4, -1.3, -1.4, -0.0, 0.1),
    _WmmCoefficient(12, 5, 0.6, -0.0, -0.0, -0.0),
    _WmmCoefficient(12, 6, 0.6, 0.6, 0.1, -0.0),
    _WmmCoefficient(12, 7, 0.5, -0.1, -0.0, -0.0),
    _WmmCoefficient(12, 8, -0.1, 0.8, 0.0, 0.0),
    _WmmCoefficient(12, 9, -0.4, 0.1, 0.0, -0.0),
    _WmmCoefficient(12, 10, -0.2, -1.0, -0.1, -0.0),
    _WmmCoefficient(12, 11, -1.3, 0.1, -0.0, 0.0),
    _WmmCoefficient(12, 12, -0.7, 0.2, -0.1, -0.1),
  ];

  const MagneticDeclinationService();

  /// Converts a [DateTime] into a UTC decimal year (e.g. `2025-07-02T12:00:00Z` ≈ `2025.5`).
  static double toDecimalYear(DateTime date) {
    final DateTime utc = date.toUtc();
    final int year = utc.year;
    final DateTime startOfYear = DateTime.utc(year, 1, 1);
    final DateTime startOfNextYear = DateTime.utc(year + 1, 1, 1);
    final int elapsedMicros = utc.difference(startOfYear).inMicroseconds;
    final int totalMicros = startOfNextYear.difference(startOfYear).inMicroseconds;
    return year + (elapsedMicros / totalMicros);
  }

  /// Returns `true` if [decimalYear] is within `[2025.0, 2030.0)`.
  static bool isSupportedDecimalYear(double decimalYear) {
    return decimalYear.isFinite &&
        decimalYear >= minSupportedDecimalYear &&
        decimalYear < maxSupportedDecimalYearExclusive;
  }

  /// Calculates magnetic declination for a calendar [date] using [calculateForDecimalYear].
  MagneticDeclinationResult calculate({
    required double latitude,
    required double longitude,
    required DateTime date,
    double altitudeKm = 0.0,
  }) {
    final double decimalYear = toDecimalYear(date);
    return calculateForDecimalYear(
      latitude: latitude,
      longitude: longitude,
      decimalYear: decimalYear,
      altitudeKm: altitudeKm,
    );
  }

  /// Calculates WMM-2025 magnetic declination for geodetic ([latitude], [longitude])
  /// at [decimalYear] and ellipsoid height [altitudeKm] (km above WGS-84).
  ///
  /// Throws [MagneticDeclinationException] if coordinates, altitude, or date
  /// are invalid or outside `[2025.0, 2030.0)`.
  MagneticDeclinationResult calculateForDecimalYear({
    required double latitude,
    required double longitude,
    required double decimalYear,
    double altitudeKm = 0.0,
  }) {
    if (!QiblaCalculationService.areValidCoordinates(latitude, longitude)) {
      throw MagneticDeclinationException(
        MagneticDeclinationErrorType.invalidCoordinates,
        'Invalid coordinates ($latitude, $longitude) for geomagnetic calculation.',
      );
    }
    if (!altitudeKm.isFinite) {
      throw MagneticDeclinationException(
        MagneticDeclinationErrorType.invalidAltitude,
        'Invalid altitude ($altitudeKm km) for geomagnetic calculation.',
      );
    }
    if (!isSupportedDecimalYear(decimalYear)) {
      throw MagneticDeclinationException(
        MagneticDeclinationErrorType.unsupportedDate,
        'Date decimal year $decimalYear is outside WMM-2025 supported range '
        '[$minSupportedDecimalYear, $maxSupportedDecimalYearExclusive).',
      );
    }

    const double f = 1.0 / _wgs84InverseFlattening;
    const double e2 = f * (2.0 - f);

    // Clamp exact poles infinitesimally only to avoid division by zero in Y'/cos(phi').
    final double safeLatDeg = latitude.clamp(-89.999999, 89.999999);
    final double phi = safeLatDeg * (math.pi / 180.0);
    final double lambda = longitude * (math.pi / 180.0);

    final double sinPhi = math.sin(phi);
    final double cosPhi = math.cos(phi);
    final double rc = _wgs84SemiMajorKm / math.sqrt(1.0 - e2 * sinPhi * sinPhi);

    final double p = (rc + altitudeKm) * cosPhi;
    final double z = (rc * (1.0 - e2) + altitudeKm) * sinPhi;
    final double r = math.sqrt(p * p + z * z);

    final double sinPhiPrime = z / r;
    final double cosPhiPrime = p / r;
    final double phiPrime = math.atan2(z, p);

    // Schmidt semi-normalized associated Legendre functions P[n][m] and dP/d(phi').
    final List<List<double>> pnm = List<List<double>>.generate(
      maxDegree + 1,
      (_) => List<double>.filled(maxDegree + 1, 0.0),
    );
    final List<List<double>> dpnm = List<List<double>>.generate(
      maxDegree + 1,
      (_) => List<double>.filled(maxDegree + 1, 0.0),
    );

    pnm[0][0] = 1.0;
    dpnm[0][0] = 0.0;

    for (int n = 1; n <= maxDegree; n++) {
      // Diagonal m == n
      if (n == 1) {
        pnm[1][1] = cosPhiPrime;
        dpnm[1][1] = -sinPhiPrime;
      } else {
        final double kDiag = math.sqrt((2.0 * n - 1.0) / (2.0 * n));
        pnm[n][n] = kDiag * cosPhiPrime * pnm[n - 1][n - 1];
        dpnm[n][n] =
            kDiag *
            (-sinPhiPrime * pnm[n - 1][n - 1] +
                cosPhiPrime * dpnm[n - 1][n - 1]);
      }

      // Sub-diagonal and lower orders m < n
      for (int m = 0; m < n; m++) {
        final double denom = math.sqrt((n * n - m * m).toDouble());
        final double a = (2.0 * n - 1.0) / denom;
        final double pPrev1 = pnm[n - 1][m];
        final double dpPrev1 = dpnm[n - 1][m];

        if (n - 2 >= m) {
          final double b =
              math.sqrt(((n - 1) * (n - 1) - m * m).toDouble()) / denom;
          pnm[n][m] = a * sinPhiPrime * pPrev1 - b * pnm[n - 2][m];
          dpnm[n][m] =
              a * (cosPhiPrime * pPrev1 + sinPhiPrime * dpPrev1) -
              b * dpnm[n - 2][m];
        } else {
          pnm[n][m] = a * sinPhiPrime * pPrev1;
          dpnm[n][m] = a * (cosPhiPrime * pPrev1 + sinPhiPrime * dpPrev1);
        }
      }
    }

    // Precompute cos(m * lambda) and sin(m * lambda).
    final List<double> cosMLambda = List<double>.filled(maxDegree + 1, 0.0);
    final List<double> sinMLambda = List<double>.filled(maxDegree + 1, 0.0);
    cosMLambda[0] = 1.0;
    sinMLambda[0] = 0.0;
    for (int m = 1; m <= maxDegree; m++) {
      final double angle = m * lambda;
      cosMLambda[m] = math.cos(angle);
      sinMLambda[m] = math.sin(angle);
    }

    // Radial attenuation powers (R_e / r)^(n + 2).
    final double ratio = _geomagneticReferenceRadiusKm / r;
    final List<double> radialPower = List<double>.filled(maxDegree + 1, 0.0);
    double currentPower = ratio * ratio; // ratio^2
    for (int n = 1; n <= maxDegree; n++) {
      currentPower *= ratio; // ratio^(n + 2)
      radialPower[n] = currentPower;
    }

    final double dt = decimalYear - epochYear;
    double xPrime = 0.0;
    double yPrimeSum = 0.0;
    double zPrime = 0.0;

    for (final _WmmCoefficient coef in _coefficients) {
      final int n = coef.n;
      final int m = coef.m;
      final double gTime = coef.g + dt * coef.gDot;
      final double hTime = coef.h + dt * coef.hDot;

      final double tempMain =
          gTime * cosMLambda[m] + hTime * sinMLambda[m];
      final double rp = radialPower[n];

      xPrime -= rp * tempMain * dpnm[n][m];
      zPrime -= (n + 1) * rp * tempMain * pnm[n][m];

      if (m > 0) {
        yPrimeSum +=
            rp * m * (gTime * sinMLambda[m] - hTime * cosMLambda[m]) * pnm[n][m];
      }
    }

    final double yPrime = yPrimeSum / cosPhiPrime;

    // Rotate from spherical geocentric (X', Y', Z') back to geodetic (X, Y, Z).
    final double psi = phi - phiPrime;
    final double cosPsi = math.cos(psi);
    final double sinPsi = math.sin(psi);

    final double xGeodetic = xPrime * cosPsi + zPrime * sinPsi;
    final double yGeodetic = yPrime;

    if (!xGeodetic.isFinite || !yGeodetic.isFinite) {
      throw const MagneticDeclinationException(
        MagneticDeclinationErrorType.calculationFailed,
        'Geomagnetic calculation produced non-finite field components.',
      );
    }

    final double declinationRad = math.atan2(yGeodetic, xGeodetic);
    final double declinationDeg = declinationRad * (180.0 / math.pi);

    if (!declinationDeg.isFinite) {
      throw const MagneticDeclinationException(
        MagneticDeclinationErrorType.calculationFailed,
        'Declination computation produced non-finite value.',
      );
    }

    return MagneticDeclinationResult(
      declinationDegrees: declinationDeg,
      decimalYear: decimalYear,
    );
  }
}
