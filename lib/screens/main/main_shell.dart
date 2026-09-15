import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/theme/app_theme.dart';
import '../../providers/auth_provider.dart';
import '../dashboard/dashboard_screen.dart';
import '../orders/orders_screen.dart';
import '../menu/menu_screen.dart';
import '../tables/tables_screen.dart';
import '../reports/reports_screen.dart';
import '../discounts/discounts_screen.dart';
import '../accounts/accounts_screen.dart';

class NavItem {
  final String label;
  final IconData icon;
  final IconData selectedIcon;
  final Widget screen;
  final bool adminOnly;

  const NavItem({
    required this.label,
    required this.icon,
    required this.selectedIcon,
    required this.screen,
    this.adminOnly = false,
  });
}

class MainShell extends StatefulWidget {
  const MainShell({super.key});

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  int _selectedIndex = 0;

  List<NavItem> _getNavItems(bool isAdmin) {
    final all = [
      const NavItem(
        label: 'Dashboard',
        icon: Icons.dashboard_outlined,
        selectedIcon: Icons.dashboard,
        screen: DashboardScreen(),
      ),
      const NavItem(
        label: 'Đơn hàng',
        icon: Icons.receipt_long_outlined,
        selectedIcon: Icons.receipt_long,
        screen: OrdersScreen(),
      ),
      const NavItem(
        label: 'Menu',
        icon: Icons.menu_book_outlined,
        selectedIcon: Icons.menu_book,
        screen: MenuScreen(),
        adminOnly: true,
      ),
      const NavItem(
        label: 'Bàn',
        icon: Icons.table_bar_outlined,
        selectedIcon: Icons.table_bar,
        screen: TablesScreen(),
        adminOnly: true,
      ),
      const NavItem(
        label: 'Báo cáo',
        icon: Icons.bar_chart_outlined,
        selectedIcon: Icons.bar_chart,
        screen: ReportsScreen(),
        adminOnly: true,
      ),
      const NavItem(
        label: 'Khuyến mãi',
        icon: Icons.local_offer_outlined,
        selectedIcon: Icons.local_offer,
        screen: DiscountsScreen(),
        adminOnly: true,
      ),
      const NavItem(
        label: 'Tài khoản',
        icon: Icons.people_outline,
        selectedIcon: Icons.people,
        screen: AccountsScreen(),
        adminOnly: true,
      ),
    ];
    return isAdmin ? all : all.where((n) => !n.adminOnly).toList();
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    final navItems = _getNavItems(auth.isAdmin);
    final isWide = MediaQuery.of(context).size.width >= 720;

    // Clamp index if navItems changed
    if (_selectedIndex >= navItems.length) _selectedIndex = 0;

    final currentScreen = navItems[_selectedIndex].screen;

    if (isWide) {
      // Sidebar layout for tablet/desktop
      return Scaffold(
        body: Row(
          children: [
            _SideNav(
              items: navItems,
              selectedIndex: _selectedIndex,
              onSelected: (i) => setState(() => _selectedIndex = i),
              user: auth.currentUser,
              onLogout: () => auth.logout(),
            ),
            const VerticalDivider(width: 1),
            Expanded(child: currentScreen),
          ],
        ),
      );
    } else {
      // Bottom nav for mobile
      return Scaffold(
        body: currentScreen,
        bottomNavigationBar: NavigationBar(
          selectedIndex: _selectedIndex,
          onDestinationSelected: (i) => setState(() => _selectedIndex = i),
          destinations: navItems
              .map((n) => NavigationDestination(
                    icon: Icon(n.icon),
                    selectedIcon: Icon(n.selectedIcon),
                    label: n.label,
                  ))
              .toList(),
          backgroundColor: Colors.white,
          elevation: 4,
        ),
      );
    }
  }
}

class _SideNav extends StatelessWidget {
  final List<NavItem> items;
  final int selectedIndex;
  final ValueChanged<int> onSelected;
  final dynamic user;
  final VoidCallback onLogout;

  const _SideNav({
    required this.items,
    required this.selectedIndex,
    required this.onSelected,
    required this.user,
    required this.onLogout,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 220,
      color: AppColors.primaryDark,
      child: Column(
        children: [
          // Header
          Container(
            padding: const EdgeInsets.fromLTRB(16, 48, 16, 20),
            child: Row(
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: AppColors.accent,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Icon(Icons.coffee, color: Colors.white, size: 20),
                ),
                const SizedBox(width: 10),
                const Expanded(
                  child: Text(
                    'Cafe Admin',
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const Divider(color: Colors.white24, height: 1),
          const SizedBox(height: 8),

          // Nav items
          Expanded(
            child: ListView.builder(
              itemCount: items.length,
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              itemBuilder: (context, index) {
                final item = items[index];
                final selected = index == selectedIndex;
                return Padding(
                  padding: const EdgeInsets.only(bottom: 2),
                  child: ListTile(
                    leading: Icon(
                      selected ? item.selectedIcon : item.icon,
                      color: selected ? AppColors.accent : Colors.white70,
                      size: 20,
                    ),
                    title: Text(
                      item.label,
                      style: TextStyle(
                        color: selected ? Colors.white : Colors.white70,
                        fontWeight: selected
                            ? FontWeight.w600
                            : FontWeight.normal,
                        fontSize: 14,
                      ),
                    ),
                    selected: selected,
                    selectedTileColor: Colors.white.withOpacity(0.1),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                    dense: true,
                    onTap: () => onSelected(index),
                  ),
                );
              },
            ),
          ),

          // User info & logout
          const Divider(color: Colors.white24, height: 1),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                CircleAvatar(
                  radius: 18,
                  backgroundColor: AppColors.accent,
                  child: Text(
                    (user?.fullName ?? 'A').substring(0, 1).toUpperCase(),
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        user?.fullName ?? '',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        user?.roleLabel ?? '',
                        style: const TextStyle(
                          color: Colors.white60,
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.logout, color: Colors.white60, size: 20),
                  onPressed: onLogout,
                  tooltip: 'Đăng xuất',
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
