import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:adhkar/features/prayer/data/models/prayer_notification_settings.dart';
import 'package:adhkar/features/prayer/data/models/saved_prayer_location.dart';
import 'package:adhkar/features/prayer/data/services/prayer_location_cache_service.dart';
import 'package:adhkar/features/prayer/data/services/prayer_notification_settings_service.dart';

class _FailingWriteSharedPreferences implements SharedPreferences {
  final SharedPreferences _delegate;
  bool failNextSetString = false;
  bool throwOnSetString = false;

  _FailingWriteSharedPreferences(this._delegate);

  @override
  Future<bool> setString(String key, String value) async {
    if (throwOnSetString) {
      throw StateError('Disk write error');
    }
    if (failNextSetString) {
      return false;
    }
    return _delegate.setString(key, value);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      Function.apply(_delegateDelegate(invocation), invocation.positionalArguments, invocation.namedArguments);

  Function _delegateDelegate(Invocation invocation) {
    // Forward standard SharedPreferences methods used by PrayerLocationCacheService.
    if (invocation.memberName == #get) {
      return (String key) => _delegate.get(key);
    }
    if (invocation.memberName == #getString) {
      return (String key) => _delegate.getString(key);
    }
    if (invocation.memberName == #remove) {
      return (String key) => _delegate.remove(key);
    }
    throw UnimplementedError('Unhandled SharedPreferences member: ${invocation.memberName}');
  }
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  group('SavedPrayerLocation & PrayerLocationCacheService', () {
    test(
      'persists full location including countryIsoCode and district across instances',
      () async {
        final service1 = PrayerLocationCacheService();
        final timestamp = DateTime.utc(2026, 4, 15, 8, 30);
        final saved = SavedPrayerLocation(
          latitude: 41.0332,
          longitude: 28.6801,
          countryIsoCode: 'tr',
          countryName: 'تركيا',
          city: 'إسطنبول',
          district: 'إسنيورت',
          timestamp: timestamp,
          source: PrayerLocationSource.fresh,
        );

        await service1.saveLocation(saved);
        expect(service1.currentLocation, isNotNull);
        expect(service1.currentLocation!.countryIsoCode, 'TR');

        // Reload via a brand new service instance simulating an app restart.
        final service2 = PrayerLocationCacheService();
        final reloaded = await service2.loadLocation();

        expect(reloaded, isNotNull);
        expect(reloaded!.latitude, closeTo(41.0332, 0.0001));
        expect(reloaded.longitude, closeTo(28.6801, 0.0001));
        expect(reloaded.countryIsoCode, 'TR');
        expect(reloaded.countryName, 'تركيا');
        expect(reloaded.city, 'إسطنبول');
        expect(reloaded.district, 'إسنيورت');
        expect(reloaded.timestamp.toUtc(), timestamp);
        expect(reloaded.source, PrayerLocationSource.fresh);
        expect(reloaded.displayName, 'تركيا، إسطنبول، إسنيورت');
      },
    );

    test('displayName deduplicates components and falls back safely', () {
      final duplicated = SavedPrayerLocation(
        latitude: 24.7136,
        longitude: 46.6753,
        countryIsoCode: 'SA',
        countryName: 'السعودية',
        city: 'الرياض',
        district: 'الرياض',
        timestamp: DateTime.utc(2026, 4, 15),
      );
      expect(duplicated.displayName, 'السعودية، الرياض');

      final missingPlace = SavedPrayerLocation(
        latitude: 21.4225,
        longitude: 39.8262,
        timestamp: DateTime.utc(2026, 4, 15),
      );
      expect(missingPlace.displayName, SavedPrayerLocation.fallbackDisplayName);
      expect(missingPlace.displayName, 'الموقع المحفوظ');
      expect(missingPlace.displayName.contains('21.42'), isFalse);
      expect(missingPlace.displayName.contains('39.82'), isFalse);
    });

    test(
      'disabling prayer notifications does NOT delete saved PrayerLocationCacheService data',
      () async {
        final locationCache = PrayerLocationCacheService();
        final notificationSettings = PrayerNotificationSettingsService();

        final saved = SavedPrayerLocation(
          latitude: 41.0332,
          longitude: 28.6801,
          countryIsoCode: 'TR',
          countryName: 'تركيا',
          city: 'إسطنبول',
          district: 'إسنيورت',
          timestamp: DateTime.utc(2026, 4, 15, 9, 0),
        );
        await locationCache.saveLocation(saved);

        // Enable notifications, persist notification coordinates, then disable notifications.
        await notificationSettings.saveSettings(
          PrayerNotificationSettings(enabled: true),
        );
        await notificationSettings.saveLastCoordinates(
          latitude: 41.0332,
          longitude: 28.6801,
        );
        await notificationSettings.updateEnabled(false);

        // Notification coordinates are cleared on disable, while prayer page location remains intact.
        expect(await notificationSettings.loadLastCoordinates(), isNull);
        final reloaded = await PrayerLocationCacheService().loadLocation();
        expect(reloaded, isNotNull);
        expect(reloaded!.displayName, 'تركيا، إسطنبول، إسنيورت');
        expect(reloaded.countryIsoCode, 'TR');
      },
    );

    test(
      'preserves previous valid cached location when a subsequent save fails',
      () async {
        final prefs = await SharedPreferences.getInstance();
        final failingPrefs = _FailingWriteSharedPreferences(prefs);
        final service = PrayerLocationCacheService(
          preferencesProvider: () async => failingPrefs,
        );

        final initialLocation = SavedPrayerLocation(
          latitude: 41.0332,
          longitude: 28.6801,
          countryIsoCode: 'TR',
          countryName: 'تركيا',
          city: 'إسطنبول',
          district: 'إسنيورت',
          timestamp: DateTime.utc(2026, 4, 15, 8, 0),
        );
        await service.saveLocation(initialLocation);

        final replacement = SavedPrayerLocation(
          latitude: 21.4225,
          longitude: 39.8262,
          countryIsoCode: 'SA',
          countryName: 'السعودية',
          city: 'مكة المكرمة',
          timestamp: DateTime.utc(2026, 4, 15, 10, 0),
        );

        failingPrefs.failNextSetString = true;
        await expectLater(
          () => service.saveLocation(replacement),
          throwsA(isA<PrayerLocationCacheStorageException>()),
        );
        expect(service.currentLocation!.city, 'إسطنبول');

        failingPrefs.failNextSetString = false;
        failingPrefs.throwOnSetString = true;
        await expectLater(
          () => service.saveLocation(replacement),
          throwsA(isA<PrayerLocationCacheStorageException>()),
        );

        final reloaded = await service.loadLocation();
        expect(reloaded, isNotNull);
        expect(reloaded!.countryIsoCode, 'TR');
        expect(reloaded.displayName, 'تركيا، إسطنبول، إسنيورت');
      },
    );

    test('returns null cleanly for corrupted or out-of-range cached data', () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(PrayerLocationCacheService.storageKey, '{bad-json');
      final service = PrayerLocationCacheService();
      expect(await service.loadLocation(), isNull);

      await prefs.setString(
        PrayerLocationCacheService.storageKey,
        '{"schemaVersion":1,"latitude":120.0,"longitude":28.0,"timestamp":"2026-04-15T08:00:00Z"}',
      );
      expect(await service.loadLocation(), isNull);

      await prefs.setString(
        PrayerLocationCacheService.storageKey,
        '{"schemaVersion":99,"latitude":41.0,"longitude":28.6,"timestamp":"2026-04-15T08:00:00Z"}',
      );
      expect(await service.loadLocation(), isNull);
    });
  });
}

