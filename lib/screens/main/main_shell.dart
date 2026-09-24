import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';
import '../../core/theme/app_theme.dart';
import '../../providers/auth_provider.dart';
import '../dashboard/dashboard_screen.dart';
import '../orders/orders_screen.dart';
import '../menu/menu_screen.dart';
import '../tables/tables_screen.dart';
import '../reports/reports_screen.dart';
import '../../models/shift_model.dart';
import '../../services/shift_service.dart';
import '../shifts/shift_screen.dart';
import '../discounts/discounts_screen.dart';
import '../accounts/accounts_screen.dart';

// TẠM: chỉ hiển thị mục "Đơn hàng", ẩn các mục còn lại.
// Đổi về false để bật lại phân quyền đầy đủ (admin thấy hết, staff chỉ Đơn hàng).
const bool _kTempOnlyOrders = true;

class MainShell extends StatefulWidget {
  const MainShell({super.key});

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  int _selectedIndex = 0;
  bool _sidebarCollapsed = true; // mặc định đóng khi mở app

  late final bool _isAdmin;
  late final List<_NavItem> _navItems;
  late final List<Widget> _screens;
  final _shiftService = ShiftService();

  // Cache lại 1 lần duy nhất — KHÔNG được gọi watchOpenShift() ngay trong
  // build(), vì build() chạy lại mỗi khi đổi tab (setState _selectedIndex),
  // nếu tạo stream mới mỗi lần sẽ hủy/mở lại kết nối Firestore liên tục → giật lag.
  late final bool _requiresShift;
  // Toàn bộ ca đang mở của MỌI nhân viên (không chỉ riêng người đăng nhập) — dùng
  // để phát hiện ca cũ bị bỏ dở từ NGƯờI KHÁC, vì ngăn kéo tiền là dùng chung:
  // staff A mở ca rồi thoát app kiểu vượt-tắt → lần sau dù admin hay staff B đăng
  // nhập cũng phải bị chặn bởi ca cũ của staff A cho đến khi nó được đóng.
  Stream<List<ShiftModel>>? _allOpenShiftsStream;

  // true trong lúc đang xử lý đóng ca để đăng xuất (bị ép hoặc chủ động) —
  // build() sẽ tạm bỏ qua hẳn cổng "cần mở ca" phản ứng theo stream trong
  // lúc này. Đây là điểm mấu chốt: KHÔNG dựa vào việc đoán thời gian chờ,
  // mà chặn dứt điểm việc cổng đó có cơ hội render trong suốt quá trình đóng
  // ca cho tới khi thực sự đăng xuất xong.
  bool _loggingOut = false;

  @override
  void initState() {
    super.initState();
    // Phân quyền giống web: admin thấy mọi mục; staff/kitchen chỉ vào "Đơn hàng".
    _isAdmin = context.read<AuthProvider>().isAdmin;

    final currentUser = context.read<AuthProvider>().currentUser;
    // _requiresShift: có BUẸC phải MỜ ca mới được dùng app hay không — vẫn chỉ
    // áp dụng cho tài khoản không phải bếp (bếp không thao tác tiền nên không bắt
    // buộc phải mở ca). Riêng việc PHÁT HIỆN ca cũ bị bỏ dở (do thoát app kiểu
    // vượt-tắt) thì áp dụng cho MọI tài khoản đã từng mở ca (kể cả bếp, nếu họ từ
    // mở ca từ màn Kểm ca) — vì vậy stream luôn được tạo cho mọi tài khoản đăng nhập,
    // không chỉ riêng tài khoản bắt buộc mở ca.
    if (currentUser != null) {
      _requiresShift = currentUser.role != 'kitchen';
      _allOpenShiftsStream = _shiftService.watchAllOpenShifts();
    } else {
      _requiresShift = false;
    }

    final all = <_NavEntry>[
      _NavEntry(Icons.dashboard_rounded,        'Tổng quan',  const DashboardScreen(), adminOnly: true),
      _NavEntry(Icons.receipt_long_rounded,     'Đơn hàng',   OrdersScreen(onToggleSidebar: _toggleSidebar), adminOnly: false, tooltip: 'Quản Lý Đặt Món'),
      _NavEntry(Icons.restaurant_menu_rounded,  'Menu',       const MenuScreen(),      adminOnly: true),
      _NavEntry(Icons.table_restaurant_rounded, 'Bàn',        const TablesScreen(),    adminOnly: true),
      _NavEntry(Icons.bar_chart_rounded,        'Báo cáo',    ReportsScreen(),         adminOnly: true),
      _NavEntry(Icons.savings_rounded,          'Kiểm ca',    ShiftScreen(
        onLoggingOutChanged: (v) { if (mounted) setState(() => _loggingOut = v); },
      ), adminOnly: false, tooltip: 'Kiểm Ca Làm Việc'),
      _NavEntry(Icons.local_offer_rounded,      'Khuyến mãi', const DiscountsScreen(), adminOnly: true),
      _NavEntry(Icons.manage_accounts_rounded,  'Tài khoản',  const AccountsScreen(),  adminOnly: true),
    ];
    final visible = all.where((e) {
      // "Kiểm ca" không bị cờ tạm _kTempOnlyOrders chặn — mọi tài khoản đều thấy.
      if (e.label == 'Kiểm ca') return true;
      if (_kTempOnlyOrders) return e.label == 'Đơn hàng'; // tạm chỉ giữ Đơn hàng
      return !e.adminOnly || _isAdmin;
    }).toList();
    _navItems = visible.map((e) => _NavItem(icon: e.icon, label: e.label, tooltip: e.tooltip ?? e.label)).toList();
    _screens  = visible.map((e) => e.screen).toList();
  }

  // LƯU Ý QUAN TRỌNG: chỉ hàm này (nơi DUY NHẤT gọi CloseShiftDialog từ luồng
  // đăng xuất) mới được quyết định gọi AuthProvider.logout() sau khi dialog
  // đóng — dialog CloseShiftDialog tự nó không còn gọi logout() nữa. Trước
  // đây cả 2 bên (dialog + hàm này) cùng tự ý logout, chạy đua với nhau, có
  // lúc màn hình đăng nhập bật ra khi dialog đóng ca còn chưa xử lý/đóng
  // xong hẳn. Nay chỉ dựa vào kết quả trả về của dialog (true = đã đóng ca
  // thành công), không truy vấn lại Firestore để tránh thêm 1 nguồn race nữa.
  Future<void> _logout() async {
    final auth = context.read<AuthProvider>();
    final user = auth.currentUser;
    // Bếp không thao tác tiền/ca — cho đăng xuất bình thường.
    if (user == null || user.role == 'kitchen') {
      auth.logout();
      return;
    }
    final openShift = await _shiftService.getOpenShift(user.id);
    if (openShift == null) {
      auth.logout();
      return;
    }
    final expectedCash = await _shiftService.computeExpectedCash(openShift);
    if (!mounted) return;

    // Chặn dứt điểm cổng "cần mở ca" TRƯỚC khi mở dialog — xem giải thích ở
    // field _loggingOut phía trên. Đây mới là điểm sửa gốc rễ, không phải
    // đoán thời gian chờ.
    setState(() => _loggingOut = true);

    final closed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => CloseShiftDialog(
        shift: openShift,
        expectedCash: expectedCash,
        shiftService: _shiftService,
        fmt: NumberFormat('#,###', 'vi_VN'),
      ),
    );

    if (closed == true) {
      // showDialog() đã resolve = dialog đã pop khỏi Navigator; đợi chút xíu
      // chỉ để hiệu ứng đóng dialog mượt mà (KHÔNG phải để chờ xử lý xong —
      // việc đóng ca đã xử lý & ghi Firestore xong từ trước khi dialog tự pop).
      await Future.delayed(const Duration(milliseconds: 200));
      auth.logout();
      return; // MainShell sắp bị unmount, không cần setState nữa.
    }

    // Người dùng hủy đóng ca → bỏ cờ chặn, quay lại bình thường.
    if (mounted) {
      setState(() => _loggingOut = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Bạn cần đóng ca trước khi đăng xuất')),
      );
    }
  }

  void _toggleSidebar() => setState(() => _sidebarCollapsed = !_sidebarCollapsed);

  @override
  Widget build(BuildContext context) {
    // Không có stream (không xác định được currentUser ở initState) — trường
    // hợp an toàn dự phòng, không nên xảy ra trên thực tế.
    if (_openShiftStream == null) return _buildShell();

    // Đang trong lúc đóng ca để đăng xuất → CHỦ ĐỘNG không xét stream ca mở
    // nữa, luôn hiện màn hình chờ đơn giản. Đây là điểm sửa gốc rễ: nếu vẫn
    // để StreamBuilder bên dưới quyết định, nó sẽ thấy ca vừa đóng xong (gần
    // như ngay khi closeShift() ghi Firestore) và tự chuyển sang màn "cần mở
    // ca" TRONG LÚC dialog đóng ca vẫn còn đang hiển thị phía trên — khiến
    // người dùng thấy màn "cần mở ca" chớp qua ngay khi dialog vừa đóng, rồi
    // mới tới màn đăng nhập, tạo cảm giác 2-3 màn hình chồng/nối đuôi nhau.
    if (_loggingOut) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    final user = context.read<AuthProvider>().currentUser!;
    return StreamBuilder<ShiftModel?>(
      stream: _openShiftStream,
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Scaffold(body: Center(child: CircularProgressIndicator()));
        }
        final openShift = snap.data;

        // Bước 1 — ÁP DỤNG CHO MỌI TÀI KHOẢN đã từng mở ca (kể cả bếp, nếu
        // có): nếu ca đang mở là từ một ngày trước đó, gần như chắc chắn do app bị
        // thoát (vượt-tắt/force-kill) mà không đăng xuất hay đóng ca. Bắt buộc kiểm
        // ca thủ công (đếm tiền thật) trước khi cho vào app — không tự động đóng
        // ngầm, không cho bỏ qua, không phân biệt vai trò tài khoản.
        if (openShift != null) {
          final now = DateTime.now();
          final opened = openShift.openedAt;
          final isStale = opened.year != now.year ||
              opened.month != now.month ||
              opened.day != now.day;
          if (isStale) {
            return StaleShiftGateScreen(
              shift: openShift,
              shiftService: _shiftService,
            );
          }
        }

        // Bước 2 — chỉ áp dụng cho tài khoản bắt buộc phải mở ca (không phải bếp):
        // chưa mở ca — chặn toàn bộ app, bắt buộc mở ca trước.
        if (_requiresShift && openShift == null) {
          return OpenShiftGateScreen(
            staffId: user.id,
            staffName: user.fullName,
            shiftService: _shiftService,
          );
        }

        return _buildShell();
      },
    );
  }

  Widget _buildShell() {
    final isDesktop = MediaQuery.of(context).size.width >= 720;
    return isDesktop ? _buildDesktop() : _buildMobile();
  }

  // ──────────────────────────────────────────────
  // DESKTOP
  // ──────────────────────────────────────────────
  Widget _buildDesktop() {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: Row(
          children: [
            // Ẩn hẳn ↔ hiện dạng rail hẹp (chỉ icon). Mở lại bằng nút ☰ trên topbar.
            if (!_sidebarCollapsed)
              _Sidebar(
                selectedIndex: _selectedIndex,
                items: _navItems,
                collapsed: true, // luôn hiện dạng rail hẹp khi mở
                onSelect: (i) => setState(() => _selectedIndex = i),
                onLogout: _logout,
                onToggle: _toggleSidebar,
              ),
            Expanded(
              child: IndexedStack(
                index: _selectedIndex,
                children: _screens,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ──────────────────────────────────────────────
  // MOBILE
  // ──────────────────────────────────────────────
  Widget _buildMobile() {
    final showNav = _navItems.length >= 2;
    return Scaffold(
      appBar: AppBar(
        title: Text(_navItems[_selectedIndex].label),
        automaticallyImplyLeading: false,
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            icon: const Icon(Icons.logout_rounded),
            tooltip: 'Đăng xuất',
            onPressed: _logout,
          ),
        ],
      ),
      body: IndexedStack(
        index: _selectedIndex,
        children: _screens,
      ),
      bottomNavigationBar: showNav
          ? NavigationBar(
              selectedIndex: _selectedIndex,
              onDestinationSelected: (i) => setState(() => _selectedIndex = i),
              backgroundColor: AppColors.surface,
              indicatorColor: AppColors.primary.withValues(alpha: 0.12),
              labelBehavior: NavigationDestinationLabelBehavior.onlyShowSelected,
              destinations: _navItems.map((item) => NavigationDestination(
                icon: Icon(item.icon, color: AppColors.textSecondary),
                selectedIcon: Icon(item.icon, color: AppColors.primary),
                label: item.label,
              )).toList(),
            )
          : null,
    );
  }
}

// ──────────────────────────────────────────────
// SIDEBAR
// ──────────────────────────────────────────────
class _Sidebar extends StatelessWidget {
  final int selectedIndex;
  final List<_NavItem> items;
  final bool collapsed;
  final ValueChanged<int> onSelect;
  final VoidCallback onLogout;
  final VoidCallback onToggle;

  const _Sidebar({
    required this.selectedIndex,
    required this.items,
    required this.collapsed,
    required this.onSelect,
    required this.onLogout,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    final user = context.watch<AuthProvider>().currentUser;
    final name = (user?.fullName.isNotEmpty ?? false) ? user!.fullName : 'Người dùng';
    final roleLabel = user?.roleLabel ?? '';
    final isAdmin = user?.role == 'admin';

    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeInOut,
      width: collapsed ? 68 : 230,
      color: AppColors.sidebarBg,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Logo (chỉ ở dạng đầy đủ). Dạng rail hẹp: bỏ header ☰, để icon nav lên đầu.
          if (!collapsed)
            Container(
              height: 64,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              color: Colors.black26,
              child: Row(
                children: [
                  Container(
                    width: 34, height: 34,
                    decoration: BoxDecoration(
                      color: AppColors.accent,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Icon(Icons.coffee_rounded, color: Colors.white, size: 20),
                  ),
                  const SizedBox(width: 10),
                  const Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('CAFÉ',
                          style: TextStyle(color: Colors.white, fontSize: 15,
                            fontWeight: FontWeight.w800, letterSpacing: 1.5)),
                        Text('Admin Panel',
                          style: TextStyle(color: Colors.white54, fontSize: 10, letterSpacing: 0.5)),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.menu_open_rounded, color: Colors.white70, size: 20),
                    onPressed: onToggle,
                  ),
                ],
              ),
            ),

          // Section label
          if (!collapsed)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
              child: Text('QUẢN LÝ',
                style: TextStyle(color: Colors.white.withValues(alpha: 0.35),
                  fontSize: 10, fontWeight: FontWeight.w700, letterSpacing: 1.2)),
            )
          else
            const SizedBox(height: 12),

          // Nav items
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              itemCount: items.length,
              itemBuilder: (_, i) => _SidebarItem(
                item: items[i],
                isSelected: i == selectedIndex,
                collapsed: collapsed,
                onTap: () => onSelect(i),
              ),
            ),
          ),

          // Bottom divider + user + logout
          const Divider(color: Colors.white10, height: 1),
          Padding(
            padding: EdgeInsets.all(collapsed ? 10 : 16),
            child: collapsed
                ? Column(
                    children: [
                      _RailTooltip(
                        message: roleLabel.isNotEmpty ? '$name • $roleLabel' : name,
                        child: CircleAvatar(
                          radius: 16,
                          backgroundColor: isAdmin ? const Color(0xFF8B5CF6) : AppColors.primary,
                          child: Text(name.isNotEmpty ? name[0].toUpperCase() : '?',
                            style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w800)),
                        ),
                      ),
                      const SizedBox(height: 4),
                      _RailTooltip(
                        message: 'Đăng xuất',
                        child: IconButton(
                          icon: const Icon(Icons.logout_rounded, size: 18),
                          color: Colors.white54,
                          onPressed: onLogout,
                        ),
                      ),
                    ],
                  )
                : Row(
                    children: [
                      CircleAvatar(
                        radius: 16,
                        backgroundColor: isAdmin ? const Color(0xFF8B5CF6) : AppColors.primary,
                        child: Text(name.isNotEmpty ? name[0].toUpperCase() : '?',
                          style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w800)),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(name,
                              maxLines: 1, overflow: TextOverflow.ellipsis,
                              style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600)),
                            Text(roleLabel,
                              style: const TextStyle(color: Colors.white38, fontSize: 11)),
                          ],
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.logout_rounded, size: 18),
                        color: Colors.white54,
                        tooltip: 'Đăng xuất',
                        onPressed: onLogout,
                      ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}

class _SidebarItem extends StatelessWidget {
  final _NavItem item;
  final bool isSelected;
  final bool collapsed;
  final VoidCallback onTap;

  const _SidebarItem({
    required this.item,
    required this.isSelected,
    required this.collapsed,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final row = collapsed
        ? Center(
            child: Icon(item.icon, size: 20,
              color: isSelected ? Colors.white : Colors.white.withValues(alpha: 0.55)),
          )
        : Row(
            children: [
              Icon(item.icon, size: 18,
                color: isSelected ? Colors.white : Colors.white.withValues(alpha: 0.55)),
              const SizedBox(width: 10),
              Expanded(
                child: Text(item.label,
                  maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: isSelected ? Colors.white : Colors.white.withValues(alpha: 0.6),
                    fontSize: 13.5,
                    fontWeight: isSelected ? FontWeight.w600 : FontWeight.w400,
                  )),
              ),
              if (isSelected)
                Container(
                  width: 4, height: 4,
                  decoration: const BoxDecoration(color: AppColors.accent, shape: BoxShape.circle),
                ),
            ],
          );

    final content = Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: onTap,
          hoverColor: Colors.white.withValues(alpha: 0.05),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            padding: EdgeInsets.symmetric(horizontal: collapsed ? 8 : 12, vertical: 10),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              color: isSelected ? AppColors.primary.withValues(alpha: 0.85) : Colors.transparent,
            ),
            child: row,
          ),
        ),
      ),
    );

    return collapsed ? _RailTooltip(message: item.tooltip, child: content) : content;
  }
}

// ──────────────────────────────────────────────
// Tooltip tùy biến: hiện bên PHẢI, có mũi tên chỉ vào icon
// ──────────────────────────────────────────────
class _RailTooltip extends StatefulWidget {
  final String message;
  final Widget child;
  const _RailTooltip({required this.message, required this.child});

  @override
  State<_RailTooltip> createState() => _RailTooltipState();
}

class _RailTooltipState extends State<_RailTooltip> {
  OverlayEntry? _entry;

  void _show() {
    if (_entry != null) return;
    final box = context.findRenderObject() as RenderBox?;
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (box == null || overlay == null) return;
    final offset = box.localToGlobal(Offset.zero, ancestor: overlay);
    final size = box.size;
    _entry = OverlayEntry(
      builder: (_) => Positioned(
        left: offset.dx + size.width + 6,
        top: offset.dy + size.height / 2,
        child: FractionalTranslation(
          translation: const Offset(0, -0.5),
          child: Material(
            color: Colors.transparent,
            child: Row(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.center, children: [
              CustomPaint(size: const Size(6, 12), painter: _TooltipArrowPainter()),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: const Color(0xFF1E293B),
                  borderRadius: BorderRadius.circular(6),
                  boxShadow: const [BoxShadow(color: Color(0x33000000), blurRadius: 6, offset: Offset(0, 2))],
                ),
                child: Text(widget.message,
                  style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600)),
              ),
            ]),
          ),
        ),
      ),
    );
    Overlay.of(context).insert(_entry!);
  }

  void _hide() {
    _entry?.remove();
    _entry = null;
  }

  @override
  void dispose() {
    _hide();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => _show(),
      onExit: (_) => _hide(),
      child: widget.child,
    );
  }
}

class _TooltipArrowPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = const Color(0xFF1E293B)..style = PaintingStyle.fill;
    final path = Path()
      ..moveTo(0, size.height / 2)          // đỉnh mũi tên chỉ sang trái (vào icon)
      ..lineTo(size.width, 0)
      ..lineTo(size.width, size.height)
      ..close();
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _NavItem {
  final IconData icon;
  final String label;
  final String tooltip;
  const _NavItem({required this.icon, required this.label, required this.tooltip});
}

class _NavEntry {
  final IconData icon;
  final String label;
  final Widget screen;
  final bool adminOnly;
  final String? tooltip;
  const _NavEntry(this.icon, this.label, this.screen, {required this.adminOnly, this.tooltip});
}
