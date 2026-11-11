import 'package:flutter_test/flutter_test.dart';
import 'package:geocoding/geocoding.dart';

import 'package:adhkar/features/prayer/data/models/saved_prayer_location.dart';
import 'package:adhkar/features/prayer/data/services/prayer_geocoding_service.dart';

class _FakeGeocodingClient implements GeocodingClient {
  List<Placemark> placemarks;
  Object? localeError;
  Object? placemarkError;
  Duration delay;
  final List<String> localeCalls = <String>[];
  int placemarkCalls = 0;

  _FakeGeocodingClient({
    this.placemarks = const <Placemark>[],
    this.localeError,
    this.placemarkError,
    this.delay = Duration.zero,
  });

  @override
  Future<void> setLocaleIdentifier(String localeIdentifier) async {
    localeCalls.add(localeIdentifier);
    if (localeError != null) {
      throw localeError!;
    }
  }

  @override
  Future<List<Placemark>> placemarkFromCoordinates(
    double latitude,
    double longitude,
  ) async {
    placemarkCalls++;
    if (delay > Duration.zero) {
      await Future<void>.delayed(delay);
    }
    if (placemarkError != null) {
      throw placemarkError!;
    }
    return placemarks;
  }
}

void main() {
  group('PrayerGeocodingService', () {
    test(
      'extracts country, city, district, and normalized ISO code from Placemark',
      () async {
        final client = _FakeGeocodingClient(
          placemarks: const <Placemark>[
            Placemark(
              isoCountryCode: 'tr',
              country: 'تركيا',
              administrativeArea: 'إسطنبول',
              locality: 'إسطنبول',
              subLocality: 'إسنيورت',
            ),
          ],
        );
        final service = PrayerGeocodingService(client: client);

        final address = await service.reverseGeocode(
          latitude: 41.0332,
          longitude: 28.6801,
        );

        expect(client.localeCalls, <String>['ar']);
        expect(address.countryIsoCode, 'TR');
        expect(address.countryName, 'تركيا');
        expect(address.city, 'إسطنبول');
        expect(address.district, 'إسنيورت');
        expect(address.hasAnyComponent, isTrue);

        final location = SavedPrayerLocation(
          latitude: 41.0332,
          longitude: 28.6801,
          timestamp: DateTime.utc(2026, 4, 15, 8, 0),
          countryIsoCode: address.countryIsoCode,
          countryName: address.countryName,
          city: address.city,
          district: address.district,
        );
        expect(location.displayName, 'تركيا، إسطنبول، إسنيورت');
      },
    );

    test('handles missing district and falls back city to administrativeArea', () async {
      final client = _FakeGeocodingClient(
        placemarks: const <Placemark>[
          Placemark(
            isoCountryCode: 'SA',
            country: 'المملكة العربية السعودية',
            administrativeArea: 'مكة المكرمة',
            locality: '',
            subLocality: null,
            subAdministrativeArea: '',
          ),
        ],
      );
      final service = PrayerGeocodingService(client: client);

      final address = await service.reverseGeocode(
        latitude: 21.4225,
        longitude: 39.8262,
      );

      expect(address.countryIsoCode, 'SA');
      expect(address.countryName, 'المملكة العربية السعودية');
      expect(address.city, 'مكة المكرمة');
      expect(address.district, isNull);
    });

    test('handles missing city while keeping country and distinct district', () async {
      final client = _FakeGeocodingClient(
        placemarks: const <Placemark>[
          Placemark(
            isoCountryCode: 'TR',
            country: 'تركيا',
            administrativeArea: 'تركيا',
            locality: '',
            subAdministrativeArea: 'باشاك شهير',
          ),
        ],
      );
      final service = PrayerGeocodingService(client: client);

      final address = await service.reverseGeocode(
        latitude: 41.09,
        longitude: 28.80,
      );

      expect(address.countryIsoCode, 'TR');
      expect(address.countryName, 'تركيا');
      expect(address.city, isNull);
      expect(address.district, 'باشاك شهير');
    });

    test('deduplicates repeated administrative hierarchy values', () async {
      final client = _FakeGeocodingClient(
        placemarks: const <Placemark>[
          Placemark(
            isoCountryCode: 'kw',
            country: 'الكويت',
            administrativeArea: 'الكويت',
            locality: 'مدينة الكويت',
            subLocality: 'مدينة الكويت',
            subAdministrativeArea: 'مدينة الكويت',
          ),
        ],
      );
      final service = PrayerGeocodingService(client: client);

      final address = await service.reverseGeocode(
        latitude: 29.3759,
        longitude: 47.9774,
      );

      expect(address.countryIsoCode, 'KW');
      expect(address.countryName, 'الكويت');
      expect(address.city, 'مدينة الكويت');
      expect(address.district, isNull);
    });

    test(
      'returns empty address without throwing on geocoding exception or timeout',
      () async {
        final errorClient = _FakeGeocodingClient(
          placemarkError: StateError('Platform geocoder unavailable'),
        );
        final errorService = PrayerGeocodingService(client: errorClient);

        final errorResult = await errorService.reverseGeocode(
          latitude: 41.0332,
          longitude: 28.6801,
        );
        expect(errorResult.hasAnyComponent, isFalse);
        expect(errorResult.countryIsoCode, isNull);

        final timeoutClient = _FakeGeocodingClient(
          delay: const Duration(milliseconds: 250),
          placemarks: const <Placemark>[
            Placemark(country: 'تركيا', locality: 'إسطنبول'),
          ],
        );
        final timeoutService = PrayerGeocodingService(
          client: timeoutClient,
          timeout: const Duration(milliseconds: 20),
        );

        final timeoutResult = await timeoutService.reverseGeocode(
          latitude: 41.0332,
          longitude: 28.6801,
        );
        expect(timeoutResult.hasAnyComponent, isFalse);

        // Callers can still preserve coordinates and use generic fallback label.
        final fallbackSaved = SavedPrayerLocation(
          latitude: 41.0332,
          longitude: 28.6801,
          timestamp: DateTime.utc(2026, 4, 15, 8, 0),
          countryIsoCode: timeoutResult.countryIsoCode,
          countryName: timeoutResult.countryName,
          city: timeoutResult.city,
          district: timeoutResult.district,
        );
        expect(fallbackSaved.isValid, isTrue);
        expect(fallbackSaved.displayName, 'الموقع المحفوظ');
      },
    );

    test('ignores setLocaleIdentifier failure and still extracts placemark', () async {
      final client = _FakeGeocodingClient(
        localeError: UnsupportedError('Locale switch unsupported'),
        placemarks: const <Placemark>[
          Placemark(
            isoCountryCode: 'EG',
            country: 'مصر',
            locality: 'القاهرة',
            subLocality: 'المعادي',
          ),
        ],
      );
      final service = PrayerGeocodingService(client: client);

      final address = await service.reverseGeocode(
        latitude: 29.9602,
        longitude: 31.2569,
      );

      expect(address.countryIsoCode, 'EG');
      expect(address.countryName, 'مصر');
      expect(address.city, 'القاهرة');
      expect(address.district, 'المعادي');
    });

    test('returns empty address immediately for invalid coordinates', () async {
      final client = _FakeGeocodingClient(
        placemarks: const <Placemark>[Placemark(country: 'تركيا')],
      );
      final service = PrayerGeocodingService(client: client);

      final result = await service.reverseGeocode(
        latitude: 95.0,
        longitude: 28.0,
      );

      expect(result.hasAnyComponent, isFalse);
      expect(client.placemarkCalls, 0);
    });
  });
}

