import 'package:flutter/material.dart';
import '../../../../config/theme/app_assets.dart';
import '../../../../config/theme/app_colors.dart';
import '../../../../config/theme/app_page_transitions.dart';
import '../../../../core/utils/daily_content_helper.dart';
import '../../../../core/utils/dhikr_copy_helper.dart';
import '../../../../core/utils/dhikr_share_helper.dart';
import '../../../../shared/widgets/animated_card_tap.dart';
import '../../../../shared/widgets/app_background.dart';
import '../../../../shared/widgets/floating_bottom_nav_bar.dart';
import '../managers/favorites_manager.dart';
import '../managers/settings_manager.dart';
import 'package:intl/intl.dart' hide TextDirection;
import 'package:hijri/hijri_calendar.dart';
import 'favorites_page.dart';
import 'global_search_page.dart';
import 'tasbeeh_page.dart';
import '../../../prayer/presentation/pages/prayer_times_page.dart';
import '../../../qibla/presentation/pages/qibla_page.dart';

/// The Home Screen of the Adhkar ("ذكر") application.
/// Preserving top header, greeting, daily quote cards, background, and bottom navigation.
/// Only category grid replaced with a single centered 75% width Tasbeeh card.
class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final String greetingText = _getGreetingText();
    final isDark = Theme.of(context).brightness == Brightness.dark;

    final bgColor = isDark ? const Color(0xFF161A15) : const Color(0xFFF7F2E8);

    final dhikrItem = DailyContentHelper.getDhikrOfTheDay();
    final duaItem = DailyContentHelper.getDuaOfTheDay();
    final ayahItem = DailyContentHelper.getAyahOfTheDay();
    final quoteItem = DailyContentHelper.getQuoteOfTheDay();

    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        backgroundColor: bgColor,
        body: Stack(
          children: [
            // Fullscreen Fixed Viewport Background & Ornaments
            const AppBackground(),

            // 3. Main Content Scrollable Canvas
            SafeArea(
              bottom: false,
              child: LayoutBuilder(
                builder: (context, constraints) {
                  return SingleChildScrollView(
                    physics: const BouncingScrollPhysics(),
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        minHeight: constraints.maxHeight,
                      ),
                      child: Padding(
                        padding: const EdgeInsets.only(
                          left: 18,
                          right: 18,
                          top: 8,
                          bottom: 100, // Space for floating bottom nav
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            // Header Bar with Top Icons and Centered Logo
                            const _HeaderLogoRow(),

                            const SizedBox(height: 12),

                            // Greeting Title & Date Pill Container Row
                            _buildGreetingAndDateRow(context, greetingText),

                            const SizedBox(height: 16),

                            // Card 1: ذكر اليوم
                            ValueListenableBuilder<List<Map<String, dynamic>>>(
                              valueListenable: FavoritesManager.favoriteDhikrs,
                              builder: (context, favorites, child) {
                                final itemData = dhikrItem.toFavoriteItem();
                                final isFav = FavoritesManager.isFavorite(
                                  itemData,
                                );
                                return _buildDailyContentCard(
                                  context,
                                  tagText: 'ذكر اليوم',
                                  tagIcon: Icons.eco_outlined,
                                  content: dhikrItem.text,
                                  source: dhikrItem.source,
                                  hasDivider: true,
                                  leftAction: _buildActionButton(
                                    context,
                                    isFav
                                        ? Icons.favorite_rounded
                                        : Icons.favorite_border_rounded,
                                    () => FavoritesManager.toggleFavorite(
                                      context,
                                      itemData,
                                    ),
                                    iconColor: isFav
                                        ? const Color(0xFFC5A059)
                                        : null,
                                  ),
                                  rightActions: [
                                    _buildActionButton(
                                      context,
                                      Icons.copy_rounded,
                                      () => DhikrCopyHelper.copyToClipboard(
                                        context,
                                        itemData,
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    _buildActionButton(
                                      context,
                                      Icons.share_outlined,
                                      () => DhikrShareHelper.shareDhikr(
                                        itemData,
                                      ),
                                    ),
                                  ],
                                );
                              },
                            ),

                            const SizedBox(height: 16),

                            // Card 2: دعاء اليوم
                            ValueListenableBuilder<List<Map<String, dynamic>>>(
                              valueListenable: FavoritesManager.favoriteDhikrs,
                              builder: (context, favorites, child) {
                                final itemData = duaItem.toFavoriteItem();
                                final isFav = FavoritesManager.isFavorite(
                                  itemData,
                                );
                                return _buildDailyContentCard(
                                  context,
                                  tagText: 'دعاء اليوم',
                                  tagIcon: Icons.back_hand_outlined,
                                  content: duaItem.text,
                                  source: duaItem.source,
                                  hasDivider: false,
                                  leftAction: _buildActionButton(
                                    context,
                                    isFav
                                        ? Icons.favorite_rounded
                                        : Icons.favorite_border_rounded,
                                    () => FavoritesManager.toggleFavorite(
                                      context,
                                      itemData,
                                    ),
                                    iconColor: isFav
                                        ? const Color(0xFFC5A059)
                                        : null,
                                  ),
                                  rightActions: [
                                    _buildActionButton(
                                      context,
                                      Icons.copy_rounded,
                                      () => DhikrCopyHelper.copyToClipboard(
                                        context,
                                        itemData,
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    _buildActionButton(
                                      context,
                                      Icons.share_outlined,
                                      () => DhikrShareHelper.shareDhikr(
                                        itemData,
                                      ),
                                    ),
                                  ],
                                );
                              },
                            ),

                            const SizedBox(height: 16),

                            // Card 3: آية عشوائية
                            ValueListenableBuilder<List<Map<String, dynamic>>>(
                              valueListenable: FavoritesManager.favoriteDhikrs,
                              builder: (context, favs, child) {
                                final itemData = ayahItem.toFavoriteItem();
                                final isFav = FavoritesManager.isFavorite(
                                  itemData,
                                );
                                return _buildDailyContentCard(
                                  context,
                                  tagText: 'آية عشوائية',
                                  tagIcon: Icons.menu_book_rounded,
                                  content: ayahItem.text,
                                  source: ayahItem.source,
                                  hasDivider: false,
                                  leftAction: _buildActionButton(
                                    context,
                                    isFav
                                        ? Icons.bookmark_rounded
                                        : Icons.bookmark_border_rounded,
                                    () => FavoritesManager.toggleFavorite(
                                      context,
                                      itemData,
                                    ),
                                    iconColor: isFav
                                        ? const Color(0xFFC5A059)
                                        : null,
                                  ),
                                  rightActions: [
                                    _buildActionButton(
                                      context,
                                      Icons.copy_rounded,
                                      () => DhikrCopyHelper.copyToClipboard(
                                        context,
                                        itemData,
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    _buildActionButton(
                                      context,
                                      Icons.share_outlined,
                                      () => DhikrShareHelper.shareDhikr(
                                        itemData,
                                      ),
                                    ),
                                  ],
                                );
                              },
                            ),

                            const SizedBox(height: 16),

                            // Card 4: اقتباس إسلامي
                            _buildDailyContentCard(
                              context,
                              tagText: 'اقتباس إسلامي',
                              tagIcon: Icons.format_quote_rounded,
                              content: quoteItem.text,
                              source: quoteItem.source,
                              hasDivider: false,
                              leftAction: null,
                              rightActions: [
                                _buildActionButton(
                                  context,
                                  Icons.copy_rounded,
                                  () => DhikrCopyHelper.copyToClipboard(
                                    context,
                                    quoteItem.toFavoriteItem(),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                _buildActionButton(
                                  context,
                                  Icons.share_outlined,
                                  () => DhikrShareHelper.shareDhikr(
                                    quoteItem.toFavoriteItem(),
                                  ),
                                ),
                              ],
                            ),

                            const SizedBox(height: 16),

                            // Single Centered Tasbeeh Card (75% Screen Width)
                            _buildTasbeehCard(context),

                            const SizedBox(height: 16),

                            // Prayer Times Entry
                            _buildPrayerTimesCard(context),

                            const SizedBox(height: 16),

                            // Qibla Compass Entry
                            _buildQiblaCard(context),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),

            // 4. Floating Rounded Bottom Navigation Bar (SelectedIndex: 2 = الرئيسية)
            Positioned(
              left: 16,
              right: 16,
              bottom: 16 + MediaQuery.of(context).padding.bottom,
              child: const FloatingBottomNavBar(selectedIndex: 2),
            ),
          ],
        ),
      ),
    );
  }

  /// Dynamic Time-based Greeting based on local device time.
  String _getGreetingText() {
    final hour = DateTime.now().hour;
    if (hour >= 5 && hour < 12) {
      return 'صباح الخير';
    } else if (hour >= 12 && hour < 18) {
      return 'نهارك سعيد';
    } else {
      return 'مساء الخير';
    }
  }

  /// Formats current date to dynamic Hijri string (e.g. "الجمعة 28 صفر 1448 هـ")
  String _getHijriDateString() {
    try {
      HijriCalendar.setLocal('ar');
      final now = DateTime.now();
      final hDate = HijriCalendar.fromDate(now);
      String weekdayName;
      try {
        weekdayName = DateFormat('EEEE', 'ar').format(now);
      } catch (_) {
        const weekdaysAr = [
          'الإثنين',
          'الثلاثاء',
          'الأربعاء',
          'الخميس',
          'الجمعة',
          'السبت',
          'الأحد',
        ];
        weekdayName = weekdaysAr[now.weekday - 1];
      }
      return '$weekdayName ${hDate.hDay} ${hDate.longMonthName} ${hDate.hYear} هـ';
    } catch (_) {
      return '';
    }
  }

  /// Formats current date to dynamic Gregorian string (e.g. "14 أغسطس 2026 م")
  String _getGregorianDateString() {
    try {
      final now = DateTime.now();
      String formatted;
      try {
        formatted = DateFormat('d MMMM yyyy', 'ar').format(now);
      } catch (_) {
        const monthsAr = [
          'يناير',
          'فبراير',
          'مارس',
          'أبريل',
          'مايو',
          'يونيو',
          'يوليو',
          'أغسطس',
          'سبتمبر',
          'أكتوبر',
          'نوفمبر',
          'ديسمبر',
        ];
        formatted = '${now.day} ${monthsAr[now.month - 1]} ${now.year}';
      }
      return '$formatted م';
    } catch (_) {
      final now = DateTime.now();
      return '${now.day}/${now.month}/${now.year} م';
    }
  }

  /// Greeting & Date Header Row
  Widget _buildGreetingAndDateRow(BuildContext context, String greetingText) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        // Greeting & Subtitle
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                greetingText,
                style: TextStyle(
                  fontFamily: 'Fustat',
                  fontSize: 26,
                  fontWeight: FontWeight.bold,
                  color: isDark
                      ? const Color(0xFFF6F1E7)
                      : AppColors.primaryLight,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'نسأل الله لك سكينة القلب وراحة النفس',
                style: TextStyle(
                  fontFamily: 'Fustat',
                  fontSize: 12.5,
                  fontWeight: FontWeight.w500,
                  color: isDark
                      ? const Color(0xFFD8CEBE)
                      : const Color(0xFF707973),
                ),
              ),
            ],
          ),
        ),

        const SizedBox(width: 8),

        // Hijri & Gregorian Date Card
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFF262D24) : const Color(0xFFFFFDF9),
            borderRadius: BorderRadius.circular(22),
            border: Border.all(
              color: isDark ? const Color(0xFF353E32) : const Color(0xFFEADFCF),
              width: 1.2,
            ),
            boxShadow: [
              BoxShadow(
                color: isDark
                    ? const Color(0x20000000)
                    : const Color(0x0D000000),
                blurRadius: 12,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    _getHijriDateString(),
                    style: TextStyle(
                      fontFamily: 'Fustat',
                      fontSize: 11.5,
                      fontWeight: FontWeight.bold,
                      color: isDark
                          ? const Color(0xFFF6F1E7)
                          : AppColors.primaryLight,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    _getGregorianDateString(),
                    style: TextStyle(
                      fontFamily: 'Fustat',
                      fontSize: 10.5,
                      fontWeight: FontWeight.w500,
                      color: isDark
                          ? const Color(0xFFD8CEBE)
                          : const Color(0xFF707973),
                    ),
                  ),
                ],
              ),
              const SizedBox(width: 8),
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: isDark
                      ? const Color(0xFF1F241D)
                      : const Color(0xFFF7F2E8),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  Icons.calendar_month_outlined,
                  color: isDark
                      ? const Color(0xFFC9A15B)
                      : const Color(0xFFC5A059),
                  size: 19,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// Reusable Premium Card for Daily Content
  Widget _buildDailyContentCard(
    BuildContext context, {
    required String tagText,
    required IconData tagIcon,
    required String content,
    required String source,
    required bool hasDivider,
    required Widget? leftAction,
    required List<Widget> rightActions,
  }) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF262D24) : const Color(0xFFFFFDF9),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(
          color: isDark ? const Color(0xFF353E32) : const Color(0xFFF3ECE0),
          width: 1.2,
        ),
        boxShadow: [
          BoxShadow(
            color: isDark ? const Color(0x20000000) : const Color(0x0E000000),
            blurRadius: 16,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Stack(
        children: [
          // Corner Olive Leaf Watermark Graphic
          Positioned(
            right: 0,
            top: 0,
            child: ClipRRect(
              borderRadius: const BorderRadius.only(
                topRight: Radius.circular(24),
              ),
              child: Opacity(
                opacity: 0.18,
                child: Image.asset(
                  AppAssets.oliveBranches,
                  width: 90,
                  height: 90,
                  fit: BoxFit.cover,
                ),
              ),
            ),
          ),

          Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Tag Header Row
                Row(
                  mainAxisAlignment: MainAxisAlignment.start,
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color: isDark
                            ? const Color(0xFF1F241D)
                            : const Color(0xFFF7F2E8),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            tagIcon,
                            size: 16,
                            color: isDark
                                ? const Color(0xFFC9A15B)
                                : const Color(0xFF4E5B4E),
                          ),
                          const SizedBox(width: 6),
                          Text(
                            tagText,
                            style: TextStyle(
                              fontFamily: 'Fustat',
                              fontSize: 13,
                              fontWeight: FontWeight.bold,
                              color: isDark
                                  ? const Color(0xFFC9A15B)
                                  : const Color(0xFF4E5B4E),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),

                const SizedBox(height: 16),

                // Main Text Content
                Text(
                  content,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontFamily: 'Fustat',
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                    color: isDark
                        ? const Color(0xFFF6F1E7)
                        : const Color(0xFF1E281F),
                    height: 1.8,
                  ),
                ),

                if (hasDivider) ...[
                  const SizedBox(height: 14),
                  // Thin Golden Center Rosette Divider
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Container(
                        width: 70,
                        height: 1.2,
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            colors: [
                              isDark
                                  ? const Color(0x00C9A15B)
                                  : const Color(0x00C5A059),
                              isDark
                                  ? const Color(0xFFC9A15B)
                                  : const Color(0xFFC5A059),
                            ],
                          ),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        child: Icon(
                          Icons.auto_awesome,
                          size: 14,
                          color: isDark
                              ? const Color(0xFFC9A15B)
                              : const Color(0xFFC5A059),
                        ),
                      ),
                      Container(
                        width: 70,
                        height: 1.2,
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            colors: [
                              isDark
                                  ? const Color(0xFFC9A15B)
                                  : const Color(0xFFC5A059),
                              isDark
                                  ? const Color(0x00C9A15B)
                                  : const Color(0x00C5A059),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ],

                const SizedBox(height: 12),

                // Source Subtext
                Text(
                  source,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontFamily: 'Fustat',
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    color: isDark
                        ? const Color(0xFFD8CEBE)
                        : const Color(0xFF707973),
                  ),
                ),

                if (leftAction != null || rightActions.isNotEmpty) ...[
                  const SizedBox(height: 16),

                  // Action Buttons Row
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      // Left Action (Favorite / Bookmark)
                      if (leftAction != null)
                        leftAction
                      else
                        const SizedBox.shrink(),

                      // Right Actions (Copy, Share)
                      Row(children: rightActions),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Helper Action Button Icon Container
  Widget _buildActionButton(
    BuildContext context,
    IconData icon,
    VoidCallback onTap, {
    Color? iconColor,
  }) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        width: 42,
        height: 42,
        decoration: BoxDecoration(
          color: isDark ? const Color(0xFF1F241D) : const Color(0xFFF7F2E8),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: isDark ? const Color(0xFF353E32) : const Color(0xFFEADFCF),
            width: 1,
          ),
        ),
        child: Icon(
          icon,
          size: 20,
          color:
              iconColor ??
              (isDark ? const Color(0xFFD8CEBE) : const Color(0xFF4E5B4E)),
        ),
      ),
    );
  }

  /// Single Centered Premium Circular Tasbeeh Button
  Widget _buildTasbeehCard(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Center(
      child: AnimatedCardTap(
        onTap: () {
          Navigator.of(context).push(AppPageRoute.create(const TasbeehPage()));
        },
        child: Container(
          width: 120,
          height: 120,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: isDark ? const Color(0xFF262D24) : const Color(0xFFFFFDF9),
            border: Border.all(
              color: isDark
                  ? const Color(0xFFC9A15B).withValues(alpha: 0.6)
                  : const Color(0xFFC5A059).withValues(alpha: 0.6),
              width: 2.0,
            ),
            boxShadow: [
              BoxShadow(
                color: isDark
                    ? const Color(0x30000000)
                    : const Color(0x12000000),
                blurRadius: 16,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.grain_outlined,
                size: 34,
                color: isDark
                    ? const Color(0xFFC9A15B)
                    : const Color(0xFF4E5B4E),
              ),
              const SizedBox(height: 6),
              Text(
                'المسبحة',
                style: TextStyle(
                  fontFamily: 'Fustat',
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                  color: isDark
                      ? const Color(0xFFF6F1E7)
                      : const Color(0xFF1E281F),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Centered Circular Prayer Times Button
  Widget _buildPrayerTimesCard(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Center(
      child: AnimatedCardTap(
        onTap: () {
          Navigator.of(
            context,
          ).push(AppPageRoute.create(const PrayerTimesPage()));
        },
        child: Container(
          width: 120,
          height: 120,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: isDark ? const Color(0xFF262D24) : const Color(0xFFFFFDF9),
            border: Border.all(
              color: isDark
                  ? const Color(0xFFC9A15B).withValues(alpha: 0.6)
                  : const Color(0xFFC5A059).withValues(alpha: 0.6),
              width: 2.0,
            ),
            boxShadow: [
              BoxShadow(
                color: isDark
                    ? const Color(0x30000000)
                    : const Color(0x12000000),
                blurRadius: 16,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.mosque_outlined,
                size: 34,
                color: isDark
                    ? const Color(0xFFC9A15B)
                    : const Color(0xFF4E5B4E),
              ),
              const SizedBox(height: 6),
              Text(
                'مواقيت الصلاة',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontFamily: 'Fustat',
                  fontSize: 13.5,
                  fontWeight: FontWeight.bold,
                  color: isDark
                      ? const Color(0xFFF6F1E7)
                      : const Color(0xFF1E281F),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Centered Circular Qibla Compass Button
  Widget _buildQiblaCard(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Center(
      child: AnimatedCardTap(
        key: const Key('home_qibla_button'),
        onTap: () {
          Navigator.of(context).push(AppPageRoute.create(const QiblaPage()));
        },
        child: Container(
          width: 120,
          height: 120,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: isDark ? const Color(0xFF262D24) : const Color(0xFFFFFDF9),
            border: Border.all(
              color: isDark
                  ? const Color(0xFFC9A15B).withValues(alpha: 0.6)
                  : const Color(0xFFC5A059).withValues(alpha: 0.6),
              width: 2.0,
            ),
            boxShadow: [
              BoxShadow(
                color: isDark
                    ? const Color(0x30000000)
                    : const Color(0x12000000),
                blurRadius: 16,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.explore_outlined,
                size: 34,
                color: isDark
                    ? const Color(0xFFC9A15B)
                    : const Color(0xFF4E5B4E),
              ),
              const SizedBox(height: 6),
              Text(
                'اتجاه القبلة',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontFamily: 'Fustat',
                  fontSize: 13.5,
                  fontWeight: FontWeight.bold,
                  color: isDark
                      ? const Color(0xFFF6F1E7)
                      : const Color(0xFF1E281F),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Header Logo Row with Action Buttons
class _HeaderLogoRow extends StatelessWidget {
  const _HeaderLogoRow();

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Stack(
      alignment: Alignment.center,
      children: [
        // Centered Logo & App Title
        Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Image.asset(
              AppAssets.logo2,
              width: 58,
              height: 58,
              fit: BoxFit.contain,
            ),
            const SizedBox(height: 2),
            Text(
              'ذِكْر',
              style: TextStyle(
                fontFamily: 'Fustat',
                fontSize: 17,
                fontWeight: FontWeight.w800,
                color: isDark
                    ? const Color(0xFFF6F1E7)
                    : const Color(0xFF4E5B4E),
              ),
            ),
          ],
        ),

        // Action Buttons Row (Search & Bookmark on Right in RTL, Notification Bell on Left in RTL)
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            // Search & Bookmark Navigation Buttons (Physical Right side)
            Row(
              children: [
                _buildTopIconButton(context, Icons.search_rounded, () {
                  Navigator.of(
                    context,
                  ).push(AppPageRoute.create(const GlobalSearchPage()));
                }),
                const SizedBox(width: 8),
                _buildTopIconButton(
                  context,
                  Icons.bookmark_border_rounded,
                  () {
                    Navigator.of(
                      context,
                    ).push(AppPageRoute.create(const FavoritesPage()));
                  },
                ),
              ],
            ),

            // Notification Bell (Physical Left side)
            ValueListenableBuilder<bool>(
              valueListenable: SettingsManager.dailyReminder,
              builder: (context, dailyActive, child) {
                return _buildTopIconButton(
                  context,
                  dailyActive
                      ? Icons.notifications_active_rounded
                      : Icons.notifications_none_rounded,
                  () {
                    final newVal = !dailyActive;
                    SettingsManager.setDailyReminder(newVal);
                    ScaffoldMessenger.of(context).hideCurrentSnackBar();
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(
                          newVal
                              ? 'تم تفعيل التنبيهات اليومية'
                              : 'تم تعطيل التنبيهات اليومية',
                          style: const TextStyle(
                            fontFamily: 'Fustat',
                            fontSize: 14,
                            fontWeight: FontWeight.bold,
                            color: Color(0xFFFFFDF9),
                          ),
                        ),
                        backgroundColor: const Color(0xFF4E5B4E),
                        behavior: SnackBarBehavior.floating,
                        duration: const Duration(seconds: 2),
                      ),
                    );
                  },
                  iconColor: dailyActive ? const Color(0xFFC5A059) : null,
                );
              },
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildTopIconButton(
    BuildContext context,
    IconData icon,
    VoidCallback onTap, {
    Color? iconColor,
  }) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        width: 42,
        height: 42,
        decoration: BoxDecoration(
          color: isDark ? const Color(0xFF262D24) : const Color(0xFFFFFDF9),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: isDark ? const Color(0xFF353E32) : const Color(0xFFEADFCF),
            width: 1.2,
          ),
          boxShadow: [
            BoxShadow(
              color: isDark ? const Color(0x20000000) : const Color(0x0A000000),
              blurRadius: 10,
              offset: const Offset(0, 3),
            ),
          ],
        ),
        child: Icon(
          icon,
          size: 20,
          color: iconColor ??
              (isDark ? const Color(0xFFD8CEBE) : const Color(0xFF4E5B4E)),
        ),
      ),
    );
  }
}
