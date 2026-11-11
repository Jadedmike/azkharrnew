import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../../../core/services/notification_service.dart';

/// Data class representing saved reading position state.
class LastReadingPosition {
  final String categoryTitle;
  final String? jsonAssetPath;
  final int index;
  final double scrollOffset;

  const LastReadingPosition({
    required this.categoryTitle,
    this.jsonAssetPath,
    required this.index,
    required this.scrollOffset,
  });
}

/// Global Settings Manager for app preferences including copy settings, font size, theme mode, and reading state.
class SettingsManager {
  static const String _keyCopySource = 'copy_source';
  static const String _keyFontSizeOption = 'font_size_option';
  static const String _keyThemeMode = 'theme_mode_option';
  static const String _keyVibration = 'vibration_option';
  static const String _keyKeepScreenOn = 'keep_screen_on';
  static const String _keyShowSource = 'show_source';
  static const String _keyShowTranslation = 'show_translation';
  static const String _keyMorningReminder = 'morning_reminder';
  static const String _keyEveningReminder = 'evening_reminder';
  static const String _keyDailyReminder = 'daily_reminder';
  static const String _keyMorningTimeHour = 'morning_time_hour';
  static const String _keyMorningTimeMinute = 'morning_time_minute';
  static const String _keyEveningTimeHour = 'evening_time_hour';
  static const String _keyEveningTimeMinute = 'evening_time_minute';
  static const String _keyRememberLastPosition = 'remember_last_position';
  static const String _keyLastCategoryTitle = 'last_category_title';
  static const String _keyLastDhikrIndex = 'last_dhikr_index';
  static const String _keyLastScrollOffset = 'last_scroll_offset';
  static const String _keyLastJsonAssetPath = 'last_json_asset_path';

  /// ValueNotifier for whether to include source when copying text.
  static final ValueNotifier<bool> copySource = ValueNotifier<bool>(false);

  /// ValueNotifier holding current Dhikr font size option ('صغير', 'متوسط', 'كبير', 'كبير جداً')
  static final ValueNotifier<String> fontSizeOption = ValueNotifier<String>(
    'متوسط',
  );

  /// ValueNotifier holding current Theme Mode option ('فاتح', 'داكن', 'تكيّف حسب النظام')
  static final ValueNotifier<String> themeModeOption = ValueNotifier<String>(
    'فاتح',
  );

  /// ValueNotifier for haptic vibration feedback during count.
  static final ValueNotifier<bool> vibrationOption = ValueNotifier<bool>(true);

  /// ValueNotifier for keeping screen on during reading.
  static final ValueNotifier<bool> keepScreenOn = ValueNotifier<bool>(true);

  /// ValueNotifier for displaying source and reference below Dhikr.
  static final ValueNotifier<bool> showSource = ValueNotifier<bool>(true);

  /// ValueNotifier for displaying translation when available.
  static final ValueNotifier<bool> showTranslation = ValueNotifier<bool>(true);

  /// ValueNotifier for Morning Dhikr reminder.
  static final ValueNotifier<bool> morningReminder = ValueNotifier<bool>(true);

  /// ValueNotifier for Evening Dhikr reminder.
  static final ValueNotifier<bool> eveningReminder = ValueNotifier<bool>(true);

  /// ValueNotifier for Morning Dhikr reminder time (default 6:00 AM).
  static final ValueNotifier<TimeOfDay> morningTime = ValueNotifier<TimeOfDay>(
    const TimeOfDay(hour: 6, minute: 0),
  );

  /// ValueNotifier for Evening Dhikr reminder time (default 5:00 PM / 17:00).
  static final ValueNotifier<TimeOfDay> eveningTime = ValueNotifier<TimeOfDay>(
    const TimeOfDay(hour: 17, minute: 0),
  );

  /// ValueNotifier for Daily Duas reminder.
  static final ValueNotifier<bool> dailyReminder = ValueNotifier<bool>(true);

  /// ValueNotifier for remembering last reading position.
  static final ValueNotifier<bool> rememberLastPosition = ValueNotifier<bool>(
    true,
  );

  static String? _cachedLastCategoryTitle;
  static int _cachedLastDhikrIndex = 0;
  static double _cachedLastScrollOffset = 0.0;
  static String? _cachedLastJsonAssetPath;

  /// Helper getter to convert font size option to double pixel size for Dhikr/Dua text.
  static double get dhikrFontSize {
    switch (fontSizeOption.value) {
      case 'صغير':
        return 18.0;
      case 'كبير':
        return 26.0;
      case 'كبير جداً':
        return 30.0;
      case 'متوسط':
      default:
        return 22.0;
    }
  }

  /// Helper getter for Flutter ThemeMode
  static ThemeMode get themeMode {
    switch (themeModeOption.value) {
      case 'داكن':
        return ThemeMode.dark;
      case 'تكيّف حسب النظام':
        return ThemeMode.system;
      case 'فاتح':
      default:
        return ThemeMode.light;
    }
  }

  /// Initialize settings from SharedPreferences
  static Future<void> init() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      copySource.value = prefs.getBool(_keyCopySource) ?? false;
      fontSizeOption.value = prefs.getString(_keyFontSizeOption) ?? 'متوسط';
      themeModeOption.value = prefs.getString(_keyThemeMode) ?? 'فاتح';
      vibrationOption.value = prefs.getBool(_keyVibration) ?? true;
      keepScreenOn.value = prefs.getBool(_keyKeepScreenOn) ?? true;
      showSource.value = prefs.getBool(_keyShowSource) ?? true;
      showTranslation.value = prefs.getBool(_keyShowTranslation) ?? true;
      morningReminder.value = prefs.getBool(_keyMorningReminder) ?? true;
      eveningReminder.value = prefs.getBool(_keyEveningReminder) ?? true;

      final morningHour = prefs.getInt(_keyMorningTimeHour) ?? 6;
      final morningMinute = prefs.getInt(_keyMorningTimeMinute) ?? 0;
      morningTime.value = TimeOfDay(hour: morningHour, minute: morningMinute);

      final eveningHour = prefs.getInt(_keyEveningTimeHour) ?? 17;
      final eveningMinute = prefs.getInt(_keyEveningTimeMinute) ?? 0;
      eveningTime.value = TimeOfDay(hour: eveningHour, minute: eveningMinute);

      dailyReminder.value = prefs.getBool(_keyDailyReminder) ?? true;
      rememberLastPosition.value =
          prefs.getBool(_keyRememberLastPosition) ?? true;

      _cachedLastCategoryTitle = prefs.getString(_keyLastCategoryTitle);
      _cachedLastJsonAssetPath = prefs.getString(_keyLastJsonAssetPath);
      _cachedLastDhikrIndex = prefs.getInt(_keyLastDhikrIndex) ?? 0;
      _cachedLastScrollOffset = prefs.getDouble(_keyLastScrollOffset) ?? 0.0;
    } catch (_) {}
  }

  /// Sync notification setting states with real operating system permission status.
  static Future<void> syncNotificationPermissionsWithOs() async {
    final bool osGranted = await NotificationService.isPermissionGranted();
    if (!osGranted) {
      // Real OS permission is disabled: reflect real state in app
      morningReminder.value = false;
      eveningReminder.value = false;
      dailyReminder.value = false;
      await NotificationService.cancelAdhkarNotifications();
    } else {
      await NotificationService.syncSchedulesWithOsState();
    }
  }

  /// Set and persist vibration option
  static Future<void> setVibrationOption(bool value) async {
    vibrationOption.value = value;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_keyVibration, value);
    } catch (_) {}
  }

  /// Set and persist keep screen on option
  static Future<void> setKeepScreenOn(bool value) async {
    keepScreenOn.value = value;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_keyKeepScreenOn, value);
    } catch (_) {}
  }

  /// Set and persist show source option
  static Future<void> setShowSource(bool value) async {
    showSource.value = value;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_keyShowSource, value);
    } catch (_) {}
  }

  /// Set and persist show translation option
  static Future<void> setShowTranslation(bool value) async {
    showTranslation.value = value;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_keyShowTranslation, value);
    } catch (_) {}
  }

  /// Set and persist morning reminder option after checking OS notification permissions.
  /// Returns `true` if operation succeeded, `false` if OS permission was denied.
  static Future<bool> setMorningReminder(bool value) async {
    if (value) {
      bool granted = await NotificationService.isPermissionGranted();
      if (!granted) {
        granted = await NotificationService.requestPermission();
      }
      if (!granted) {
        morningReminder.value = false;
        try {
          final prefs = await SharedPreferences.getInstance();
          await prefs.setBool(_keyMorningReminder, false);
        } catch (_) {}
        await NotificationService.cancelMorning();
        return false;
      }
      morningReminder.value = true;
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setBool(_keyMorningReminder, true);
      } catch (_) {}
      await NotificationService.scheduleMorningNotification();
      return true;
    } else {
      morningReminder.value = false;
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setBool(_keyMorningReminder, false);
      } catch (_) {}
      await NotificationService.cancelMorning();
      return true;
    }
  }

  /// Set and persist evening reminder option after checking OS notification permissions.
  /// Returns `true` if operation succeeded, `false` if OS permission was denied.
  static Future<bool> setEveningReminder(bool value) async {
    if (value) {
      bool granted = await NotificationService.isPermissionGranted();
      if (!granted) {
        granted = await NotificationService.requestPermission();
      }
      if (!granted) {
        eveningReminder.value = false;
        try {
          final prefs = await SharedPreferences.getInstance();
          await prefs.setBool(_keyEveningReminder, false);
        } catch (_) {}
        await NotificationService.cancelEvening();
        return false;
      }
      eveningReminder.value = true;
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setBool(_keyEveningReminder, true);
      } catch (_) {}
      await NotificationService.scheduleEveningNotification();
      return true;
    } else {
      eveningReminder.value = false;
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setBool(_keyEveningReminder, false);
      } catch (_) {}
      await NotificationService.cancelEvening();
      return true;
    }
  }

  /// Set and persist morning reminder time and reschedule if morning reminder is enabled.
  static Future<void> setMorningTime(TimeOfDay time) async {
    morningTime.value = time;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_keyMorningTimeHour, time.hour);
      await prefs.setInt(_keyMorningTimeMinute, time.minute);
    } catch (_) {}

    if (morningReminder.value) {
      final bool granted = await NotificationService.isPermissionGranted();
      if (granted) {
        await NotificationService.cancelMorning();
        await NotificationService.scheduleMorningNotification(
          hour: time.hour,
          minute: time.minute,
        );
      }
    }
  }

  /// Set and persist evening reminder time and reschedule if evening reminder is enabled.
  static Future<void> setEveningTime(TimeOfDay time) async {
    eveningTime.value = time;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_keyEveningTimeHour, time.hour);
      await prefs.setInt(_keyEveningTimeMinute, time.minute);
    } catch (_) {}

    if (eveningReminder.value) {
      final bool granted = await NotificationService.isPermissionGranted();
      if (granted) {
        await NotificationService.cancelEvening();
        await NotificationService.scheduleEveningNotification(
          hour: time.hour,
          minute: time.minute,
        );
      }
    }
  }


  /// Set and persist daily reminder option after checking OS notification permissions.
  /// Returns `true` if operation succeeded, `false` if OS permission was denied.
  static Future<bool> setDailyReminder(bool value) async {
    if (value) {
      bool granted = await NotificationService.isPermissionGranted();
      if (!granted) {
        granted = await NotificationService.requestPermission();
      }
      if (!granted) {
        dailyReminder.value = false;
        try {
          final prefs = await SharedPreferences.getInstance();
          await prefs.setBool(_keyDailyReminder, false);
        } catch (_) {}
        await NotificationService.cancelDaily();
        return false;
      }
      dailyReminder.value = true;
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setBool(_keyDailyReminder, true);
      } catch (_) {}
      await NotificationService.scheduleRandomDhikrNotifications();
      return true;
    } else {
      dailyReminder.value = false;
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setBool(_keyDailyReminder, false);
      } catch (_) {}
      await NotificationService.cancelDaily();
      return true;
    }
  }

  /// Set and persist remember last position option
  static Future<void> setRememberLastPosition(bool value) async {
    rememberLastPosition.value = value;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_keyRememberLastPosition, value);
      if (!value) {
        await clearLastReadingPosition();
      }
    } catch (_) {}
  }

  /// Save last reading position if feature enabled
  static Future<void> saveLastReadingPosition({
    required String categoryTitle,
    String? jsonAssetPath,
    required int index,
    required double scrollOffset,
  }) async {
    if (!rememberLastPosition.value) return;

    _cachedLastCategoryTitle = categoryTitle;
    _cachedLastJsonAssetPath = jsonAssetPath;
    _cachedLastDhikrIndex = index;
    _cachedLastScrollOffset = scrollOffset;

    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_keyLastCategoryTitle, categoryTitle);
      if (jsonAssetPath != null && jsonAssetPath.isNotEmpty) {
        await prefs.setString(_keyLastJsonAssetPath, jsonAssetPath);
      } else {
        await prefs.remove(_keyLastJsonAssetPath);
      }
      await prefs.setInt(_keyLastDhikrIndex, index);
      await prefs.setDouble(_keyLastScrollOffset, scrollOffset);
    } catch (_) {}
  }

  /// Clear saved reading position
  static Future<void> clearLastReadingPosition() async {
    _cachedLastCategoryTitle = null;
    _cachedLastJsonAssetPath = null;
    _cachedLastDhikrIndex = 0;
    _cachedLastScrollOffset = 0.0;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_keyLastCategoryTitle);
      await prefs.remove(_keyLastJsonAssetPath);
      await prefs.remove(_keyLastDhikrIndex);
      await prefs.remove(_keyLastScrollOffset);
    } catch (_) {}
  }

  /// Helper to get last reading position if enabled and present
  static LastReadingPosition? getLastReadingPosition() {
    if (!rememberLastPosition.value) return null;
    if (_cachedLastCategoryTitle == null || _cachedLastCategoryTitle!.isEmpty) {
      return null;
    }
    return LastReadingPosition(
      categoryTitle: _cachedLastCategoryTitle!,
      jsonAssetPath: _cachedLastJsonAssetPath,
      index: _cachedLastDhikrIndex,
      scrollOffset: _cachedLastScrollOffset,
    );
  }

  /// Toggle or update copy source setting
  static Future<void> setCopySource(bool value) async {
    copySource.value = value;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_keyCopySource, value);
    } catch (_) {}
  }

  /// Set and persist font size option
  static Future<void> setFontSizeOption(String option) async {
    fontSizeOption.value = option;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_keyFontSizeOption, option);
    } catch (_) {}
  }

  /// Set and persist theme mode option
  static Future<void> setThemeModeOption(String option) async {
    themeModeOption.value = option;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_keyThemeMode, option);
    } catch (_) {}
  }
}
