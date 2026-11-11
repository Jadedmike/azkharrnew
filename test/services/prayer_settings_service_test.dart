import 'package:adhan/adhan.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:adhkar/features/prayer/data/models/prayer_settings.dart';
import 'package:adhkar/features/prayer/data/services/prayer_settings_service.dart';

/// Fake [SharedPreferences] wrapper that simulates a write failure by returning
/// `false` (or throwing) from [setString] while delegating reads to an
/// underlying [SharedPreferences] instance.
class _FailingWriteSharedPreferences implements SharedPreferences {
  final SharedPreferences _delegate;
  final bool throwOnWrite;

  _FailingWriteSharedPreferences(this._delegate, {this.throwOnWrite = false});

  @override
  Object? get(String key) => _delegate.get(key);

  @override
  Future<bool> setString(String key, String value) async {
    if (throwOnWrite) {
      throw StateError('Simulated disk write exception');
    }
    return false;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('PrayerSettings Model & Schema Version Tests', () {
    test('default settings use auto mode, Muslim World League, Shafi, v1', () {
      const defaults = PrayerSettings.defaults();
      expect(defaults.calculationMode, equals(PrayerCalculationMode.auto));
      expect(
        defaults.manualCalculationMethod,
        equals(CalculationMethod.muslim_world_league),
      );
      expect(defaults.madhab, equals(Madhab.shafi));
      expect(defaults.schemaVersion, equals(1));

      final constructed = PrayerSettings();
      expect(constructed, equals(defaults));
      expect(constructed.hashCode, equals(defaults.hashCode));
    });

    test('serialization and deserialization round-trip (Map and JSON)', () {
      final original = PrayerSettings(
        calculationMode: PrayerCalculationMode.manual,
        manualCalculationMethod: CalculationMethod.umm_al_qura,
        madhab: Madhab.hanafi,
        schemaVersion: 1,
      );

      final map = original.toMap();
      expect(map[PrayerSettings.keyCalculationMode], equals('manual'));
      expect(
        map[PrayerSettings.keyManualCalculationMethod],
        equals('umm_al_qura'),
      );
      expect(map[PrayerSettings.keyMadhab], equals('hanafi'));
      expect(map[PrayerSettings.keySchemaVersion], equals(1));

      final fromMap = PrayerSettings.fromMap(map);
      expect(fromMap, equals(original));

      final jsonString = original.toJsonString();
      final fromJson = PrayerSettings.fromJsonString(jsonString);
      expect(fromJson, equals(original));
    });

    test('schema version handling: v1, 0, negative, malformed, and future v99', () {
      // Version 1 (int and numeric string) is supported
      expect(PrayerSettings.isSupportedSchemaVersion(1), isTrue);
      expect(PrayerSettings.isSupportedSchemaVersion('1'), isTrue);
      expect(PrayerSettings.isSupportedSchemaVersion(' 1 '), isTrue);

      final validV1 = PrayerSettings.fromMap(<String, dynamic>{
        PrayerSettings.keySchemaVersion: 1,
        PrayerSettings.keyCalculationMode: 'manual',
        PrayerSettings.keyManualCalculationMethod: 'turkey',
        PrayerSettings.keyMadhab: 'hanafi',
      });
      expect(validV1.calculationMode, equals(PrayerCalculationMode.manual));
      expect(
        validV1.manualCalculationMethod,
        equals(CalculationMethod.turkey),
      );
      expect(validV1.madhab, equals(Madhab.hanafi));
      expect(validV1.schemaVersion, equals(1));

      // Version 0 is unsupported -> falls back to defaults
      expect(PrayerSettings.isSupportedSchemaVersion(0), isFalse);
      expect(PrayerSettings.isSupportedSchemaVersion('0'), isFalse);
      final versionZero = PrayerSettings.fromMap(<String, dynamic>{
        PrayerSettings.keySchemaVersion: 0,
        PrayerSettings.keyCalculationMode: 'manual',
        PrayerSettings.keyManualCalculationMethod: 'turkey',
        PrayerSettings.keyMadhab: 'hanafi',
      });
      expect(versionZero, equals(const PrayerSettings.defaults()));

      // Negative versions are unsupported -> fall back to defaults
      expect(PrayerSettings.isSupportedSchemaVersion(-1), isFalse);
      expect(PrayerSettings.isSupportedSchemaVersion(-5), isFalse);
      expect(PrayerSettings.isSupportedSchemaVersion('-5'), isFalse);
      final negativeVersion = PrayerSettings.fromMap(<String, dynamic>{
        PrayerSettings.keySchemaVersion: -5,
        PrayerSettings.keyCalculationMode: 'manual',
        PrayerSettings.keyManualCalculationMethod: 'turkey',
        PrayerSettings.keyMadhab: 'hanafi',
      });
      expect(negativeVersion, equals(const PrayerSettings.defaults()));

      // Malformed versions are unsupported -> fall back to defaults
      expect(PrayerSettings.isSupportedSchemaVersion('abc'), isFalse);
      expect(PrayerSettings.isSupportedSchemaVersion('1.5'), isFalse);
      expect(PrayerSettings.isSupportedSchemaVersion(true), isFalse);
      expect(PrayerSettings.isSupportedSchemaVersion(null), isFalse);
      final malformedVersion = PrayerSettings.fromMap(<String, dynamic>{
        PrayerSettings.keySchemaVersion: 'malformed_v1',
        PrayerSettings.keyCalculationMode: 'manual',
        PrayerSettings.keyManualCalculationMethod: 'turkey',
        PrayerSettings.keyMadhab: 'hanafi',
      });
      expect(malformedVersion, equals(const PrayerSettings.defaults()));

      // Unknown future schema versions (e.g., 2, 99, '99') are NOT silently
      // treated as supported -> rejected and fall back safely to defaults (v1)
      expect(PrayerSettings.isSupportedSchemaVersion(2), isFalse);
      expect(PrayerSettings.isSupportedSchemaVersion(99), isFalse);
      expect(PrayerSettings.isSupportedSchemaVersion('99'), isFalse);

      final futureV99Int = PrayerSettings.fromMap(<String, dynamic>{
        PrayerSettings.keySchemaVersion: 99,
        PrayerSettings.keyCalculationMode: 'manual',
        PrayerSettings.keyManualCalculationMethod: 'turkey',
        PrayerSettings.keyMadhab: 'hanafi',
      });
      expect(futureV99Int, equals(const PrayerSettings.defaults()));
      expect(futureV99Int.schemaVersion, equals(1));

      final futureV99String = PrayerSettings.fromMap(<String, dynamic>{
        PrayerSettings.keySchemaVersion: '99',
        PrayerSettings.keyCalculationMode: 'manual',
        PrayerSettings.keyManualCalculationMethod: 'turkey',
        PrayerSettings.keyMadhab: 'hanafi',
      });
      expect(futureV99String, equals(const PrayerSettings.defaults()));

      // Direct constructor also normalizes unsupported schema versions to 1
      expect(PrayerSettings(schemaVersion: 0).schemaVersion, equals(1));
      expect(PrayerSettings(schemaVersion: -10).schemaVersion, equals(1));
      expect(PrayerSettings(schemaVersion: 99).schemaVersion, equals(1));
    });

    test('invalid or missing stored values fall back safely without throwing', () {
      expect(
        PrayerSettings.fromMap(null),
        equals(const PrayerSettings.defaults()),
      );
      expect(
        PrayerSettings.fromMap(const <String, dynamic>{}),
        equals(const PrayerSettings.defaults()),
      );
      expect(
        PrayerSettings.fromJsonString(null),
        equals(const PrayerSettings.defaults()),
      );
      expect(
        PrayerSettings.fromJsonString(''),
        equals(const PrayerSettings.defaults()),
      );
      expect(
        PrayerSettings.fromJsonString('   '),
        equals(const PrayerSettings.defaults()),
      );
      expect(
        PrayerSettings.fromJsonString('{corrupted json'),
        equals(const PrayerSettings.defaults()),
      );
      expect(
        PrayerSettings.fromJsonString('[1, 2, 3]'),
        equals(const PrayerSettings.defaults()),
      );

      final partiallyInvalid = PrayerSettings.fromMap(<String, dynamic>{
        PrayerSettings.keyCalculationMode: 'invalid_mode',
        PrayerSettings.keyManualCalculationMethod: 'non_existent_method',
        PrayerSettings.keyMadhab: 12345,
        PrayerSettings.keySchemaVersion: 1,
      });
      expect(partiallyInvalid, equals(const PrayerSettings.defaults()));

      // CalculationMethod.other must be rejected and sanitized to default
      final withOtherMethod = PrayerSettings.fromMap(<String, dynamic>{
        PrayerSettings.keyCalculationMode: 'manual',
        PrayerSettings.keyManualCalculationMethod: 'other',
        PrayerSettings.keyMadhab: 'hanafi',
        PrayerSettings.keySchemaVersion: 1,
      });
      expect(
        withOtherMethod.calculationMode,
        equals(PrayerCalculationMode.manual),
      );
      expect(
        withOtherMethod.manualCalculationMethod,
        equals(CalculationMethod.muslim_world_league),
      );
      expect(withOtherMethod.madhab, equals(Madhab.hanafi));
      expect(withOtherMethod.schemaVersion, equals(1));

      final constructedWithOther = PrayerSettings(
        manualCalculationMethod: CalculationMethod.other,
      );
      expect(
        constructedWithOther.manualCalculationMethod,
        equals(CalculationMethod.muslim_world_league),
      );
    });
  });

  group('PrayerSettingsService Persistence, Reset & Error Handling Tests', () {
    setUp(() {
      SharedPreferences.setMockInitialValues(<String, Object>{});
    });

    test('initializes with default settings when storage is empty', () async {
      final service = PrayerSettingsService();
      expect(service.isInitialized, isFalse);
      expect(service.currentSettings, equals(const PrayerSettings.defaults()));

      final loaded = await service.init();
      expect(service.isInitialized, isTrue);
      expect(loaded, equals(const PrayerSettings.defaults()));
    });

    test('handles corrupted, wrong-typed, or future-version SharedPreferences values gracefully', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        PrayerSettingsService.storageKey: 42, // non-string value
      });

      final service = PrayerSettingsService();
      final loaded = await service.init();
      expect(loaded, equals(const PrayerSettings.defaults()));

      SharedPreferences.setMockInitialValues(<String, Object>{
        PrayerSettingsService.storageKey: '{not valid json',
      });
      final reloadedCorrupted = await service.loadSettings();
      expect(reloadedCorrupted, equals(const PrayerSettings.defaults()));

      SharedPreferences.setMockInitialValues(<String, Object>{
        PrayerSettingsService.storageKey:
            '{"schemaVersion":99,"calculationMode":"manual","manualCalculationMethod":"turkey","madhab":"hanafi"}',
      });
      final reloadedFuture = await service.loadSettings();
      expect(reloadedFuture, equals(const PrayerSettings.defaults()));
    });

    test('updates calculation mode, persists, and reloads across instances', () async {
      final service = PrayerSettingsService();
      await service.init();

      final updated = await service.updateCalculationMode(
        PrayerCalculationMode.manual,
      );
      expect(updated.calculationMode, equals(PrayerCalculationMode.manual));
      expect(
        service.currentSettings.calculationMode,
        equals(PrayerCalculationMode.manual),
      );

      final secondService = PrayerSettingsService();
      final reloaded = await secondService.init();
      expect(reloaded.calculationMode, equals(PrayerCalculationMode.manual));
    });

    test('updates manual calculation method, validates, and persists', () async {
      final service = PrayerSettingsService();
      await service.init();

      for (final method in PrayerSettings.supportedCalculationMethods) {
        final updated = await service.updateManualCalculationMethod(method);
        expect(updated.manualCalculationMethod, equals(method));
      }

      // Verify reload from disk
      await service.updateManualCalculationMethod(CalculationMethod.egyptian);
      final secondService = PrayerSettingsService();
      final reloaded = await secondService.init();
      expect(
        reloaded.manualCalculationMethod,
        equals(CalculationMethod.egyptian),
      );

      // Verify CalculationMethod.other is sanitized
      final sanitized = await service.updateManualCalculationMethod(
        CalculationMethod.other,
      );
      expect(
        sanitized.manualCalculationMethod,
        equals(CalculationMethod.muslim_world_league),
      );
    });

    test('updates madhab, persists, and reloads', () async {
      final service = PrayerSettingsService();
      await service.init();

      final updatedHanafi = await service.updateMadhab(Madhab.hanafi);
      expect(updatedHanafi.madhab, equals(Madhab.hanafi));

      final secondService = PrayerSettingsService();
      final reloaded = await secondService.init();
      expect(reloaded.madhab, equals(Madhab.hanafi));

      final updatedShafi = await secondService.updateMadhab(Madhab.shafi);
      expect(updatedShafi.madhab, equals(Madhab.shafi));
    });

    test('resets to defaults and overwrites persisted preferences', () async {
      final service = PrayerSettingsService();
      await service.init();

      await service.updateCalculationMode(PrayerCalculationMode.manual);
      await service.updateManualCalculationMethod(CalculationMethod.karachi);
      await service.updateMadhab(Madhab.hanafi);

      final reset = await service.resetToDefaults();
      expect(reset, equals(const PrayerSettings.defaults()));
      expect(service.currentSettings, equals(const PrayerSettings.defaults()));

      final secondService = PrayerSettingsService();
      final reloaded = await secondService.init();
      expect(reloaded, equals(const PrayerSettings.defaults()));
    });

    test('failed SharedPreferences writes throw PrayerSettingsStorageException and do not mutate in-memory settings', () async {
      // Seed valid initial persisted settings
      final initialSettings = PrayerSettings(
        calculationMode: PrayerCalculationMode.manual,
        manualCalculationMethod: CalculationMethod.umm_al_qura,
        madhab: Madhab.hanafi,
      );
      SharedPreferences.setMockInitialValues(<String, Object>{
        PrayerSettingsService.storageKey: initialSettings.toJsonString(),
      });
      final realPrefs = await SharedPreferences.getInstance();

      // Case 1: setString returns false
      final falseWriteService = PrayerSettingsService(
        preferencesProvider: () async =>
            _FailingWriteSharedPreferences(realPrefs, throwOnWrite: false),
      );
      await falseWriteService.init();
      expect(falseWriteService.currentSettings, equals(initialSettings));

      await expectLater(
        () => falseWriteService.updateCalculationMode(
          PrayerCalculationMode.auto,
        ),
        throwsA(isA<PrayerSettingsStorageException>()),
      );
      // In-memory state must remain unchanged
      expect(falseWriteService.currentSettings, equals(initialSettings));

      await expectLater(
        () => falseWriteService.updateManualCalculationMethod(
          CalculationMethod.egyptian,
        ),
        throwsA(isA<PrayerSettingsStorageException>()),
      );
      expect(falseWriteService.currentSettings, equals(initialSettings));

      await expectLater(
        () => falseWriteService.updateMadhab(Madhab.shafi),
        throwsA(isA<PrayerSettingsStorageException>()),
      );
      expect(falseWriteService.currentSettings, equals(initialSettings));

      await expectLater(
        () => falseWriteService.resetToDefaults(),
        throwsA(isA<PrayerSettingsStorageException>()),
      );
      expect(falseWriteService.currentSettings, equals(initialSettings));

      // Case 2: setString throws an exception
      final throwingWriteService = PrayerSettingsService(
        preferencesProvider: () async =>
            _FailingWriteSharedPreferences(realPrefs, throwOnWrite: true),
      );
      await throwingWriteService.init();
      expect(throwingWriteService.currentSettings, equals(initialSettings));

      await expectLater(
        () => throwingWriteService.saveSettings(const PrayerSettings.defaults()),
        throwsA(isA<PrayerSettingsStorageException>()),
      );
      expect(throwingWriteService.currentSettings, equals(initialSettings));

      await expectLater(
        () => throwingWriteService.resetToDefaults(),
        throwsA(isA<PrayerSettingsStorageException>()),
      );
      expect(throwingWriteService.currentSettings, equals(initialSettings));
    });

    test('does not interfere with existing app preferences in SharedPreferences', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'font_size_option': 'كبير',
        'theme_mode_option': 'داكن',
      });

      final service = PrayerSettingsService();
      await service.init();
      await service.updateCalculationMode(PrayerCalculationMode.manual);
      await service.updateManualCalculationMethod(CalculationMethod.dubai);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('font_size_option'), equals('كبير'));
      expect(prefs.getString('theme_mode_option'), equals('داكن'));
    });
  });

  group('CountryMethodResolver & Manual Override Tests', () {
    test('resolves only the approved conservative country mappings', () {
      // Exact approved 12 country mappings (9 direct + 3 MABIMS)
      expect(CountryMethodResolver.countryMethodMap.length, equals(12));
      expect(
        CountryMethodResolver.countryMethodMap.keys.toSet(),
        equals(<String>{
          'TR',
          'SA',
          'AE',
          'KW',
          'QA',
          'EG',
          'PK',
          'SG',
          'IR',
          'MY',
          'ID',
          'BN',
        }),
      );

      expect(
        CountryMethodResolver.resolveFromCountryCode('TR'),
        equals(CalculationMethod.turkey),
      );
      expect(
        CountryMethodResolver.resolveFromCountryCode('SA'),
        equals(CalculationMethod.umm_al_qura),
      );
      expect(
        CountryMethodResolver.resolveFromCountryCode('sa'),
        equals(CalculationMethod.umm_al_qura),
      );
      expect(
        CountryMethodResolver.resolveFromCountryCode('  ae '),
        equals(CalculationMethod.dubai),
      );
      expect(
        CountryMethodResolver.resolveFromCountryCode('KW'),
        equals(CalculationMethod.kuwait),
      );
      expect(
        CountryMethodResolver.resolveFromCountryCode('QA'),
        equals(CalculationMethod.qatar),
      );
      expect(
        CountryMethodResolver.resolveFromCountryCode('EG'),
        equals(CalculationMethod.egyptian),
      );
      expect(
        CountryMethodResolver.resolveFromCountryCode('PK'),
        equals(CalculationMethod.karachi),
      );
      expect(
        CountryMethodResolver.resolveFromCountryCode('SG'),
        equals(CalculationMethod.singapore),
      );
      expect(
        CountryMethodResolver.resolveFromCountryCode('IR'),
        equals(CalculationMethod.tehran),
      );
      expect(
        CountryMethodResolver.resolveFromCountryCode('MY'),
        equals(CalculationMethod.singapore),
      );
      expect(
        CountryMethodResolver.resolveFromCountryCode('ID'),
        equals(CalculationMethod.singapore),
      );
      expect(
        CountryMethodResolver.resolveFromCountryCode('BN'),
        equals(CalculationMethod.singapore),
      );
    });

    test('removed regional assumptions and unknown/invalid codes fall back to MWL', () {
      // Removed countries must NOT be in countryMethodMap and must use fallback
      const removedCountries = <String>[
        'BH',
        'OM',
        'YE',
        'SD',
        'LY',
        'PS',
        'SY',
        'LB',
        'IQ',
        'BD',
        'IN',
        'AF',
        'US',
        'CA',
      ];
      for (final code in removedCountries) {
        expect(
          CountryMethodResolver.countryMethodMap.containsKey(code),
          isFalse,
          reason: '$code must not be mapped automatically',
        );
        expect(
          CountryMethodResolver.resolveFromCountryCode(code),
          equals(CalculationMethod.muslim_world_league),
          reason: '$code must resolve to fallback method',
        );
      }

      // Null, empty, malformed, and other unmapped countries
      expect(
        CountryMethodResolver.resolveFromCountryCode(null),
        equals(CalculationMethod.muslim_world_league),
      );
      expect(
        CountryMethodResolver.resolveFromCountryCode(''),
        equals(CalculationMethod.muslim_world_league),
      );
      expect(
        CountryMethodResolver.resolveFromCountryCode('   '),
        equals(CalculationMethod.muslim_world_league),
      );
      expect(
        CountryMethodResolver.resolveFromCountryCode('S'),
        equals(CalculationMethod.muslim_world_league),
      );
      expect(
        CountryMethodResolver.resolveFromCountryCode('SAU'),
        equals(CalculationMethod.muslim_world_league),
      );
      expect(
        CountryMethodResolver.resolveFromCountryCode('FR'),
        equals(CalculationMethod.muslim_world_league),
      );
      expect(
        CountryMethodResolver.resolveFromCountryCode('DE'),
        equals(CalculationMethod.muslim_world_league),
      );
      expect(
        CountryMethodResolver.resolveFromCountryCode('ZZ'),
        equals(CalculationMethod.muslim_world_league),
      );
    });

    test('manual mode overrides automatic country resolution until switched back to auto', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final service = PrayerSettingsService();
      await service.init();

      // Initially in auto mode: country code resolves dynamically
      expect(
        service.resolveEffectiveCalculationMethod(countryCode: 'SA'),
        equals(CalculationMethod.umm_al_qura),
      );
      expect(
        service.resolveEffectiveCalculationMethod(countryCode: 'EG'),
        equals(CalculationMethod.egyptian),
      );
      expect(
        service.resolveEffectiveCalculationMethod(countryCode: null),
        equals(CalculationMethod.muslim_world_league),
      );

      // Select manual method and switch to manual mode
      await service.updateManualCalculationMethod(CalculationMethod.turkey);
      await service.updateCalculationMode(PrayerCalculationMode.manual);
      await service.updateMadhab(Madhab.hanafi);

      // Manual selection must NEVER be overridden by country codes
      expect(
        service.resolveEffectiveCalculationMethod(countryCode: 'SA'),
        equals(CalculationMethod.turkey),
      );
      expect(
        service.resolveEffectiveCalculationMethod(countryCode: 'EG'),
        equals(CalculationMethod.turkey),
      );
      expect(
        service.resolveEffectiveCalculationMethod(countryCode: null),
        equals(CalculationMethod.turkey),
      );

      final params = service.resolveCalculationParameters(countryCode: 'SA');
      expect(params.method, equals(CalculationMethod.turkey));
      expect(params.madhab, equals(Madhab.hanafi));

      // Switch back to auto mode: automatic resolution resumes, while manual
      // preference stays preserved in settings
      await service.updateCalculationMode(PrayerCalculationMode.auto);
      expect(
        service.currentSettings.manualCalculationMethod,
        equals(CalculationMethod.turkey),
      );
      expect(
        service.resolveEffectiveCalculationMethod(countryCode: 'SA'),
        equals(CalculationMethod.umm_al_qura),
      );
    });
  });
}
