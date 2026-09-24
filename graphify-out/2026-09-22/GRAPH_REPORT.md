# Graph Report - cafe-order-flutter  (2026-09-22)

## Corpus Check
- cluster-only mode — file stats not available

## Summary
- 1047 nodes · 1320 edges · 42 communities (35 shown, 7 thin omitted)
- Extraction: 100% EXTRACTED · 0% INFERRED · 0% AMBIGUOUS · INFERRED: 1 edges (avg confidence: 0.85)
- Token cost: 0 input · 0 output

## Graph Freshness
- Built from commit: `b9f187f6`
- Run `git rev-parse HEAD` and compare to check if the graph is stale.
- Run `graphify update .` after code changes (no API cost).

## Community Hubs (Navigation)
- orders/orders_screen.dart
- Claude outputs/orders_screen.dart
- main_shell.dart
- app_theme.dart
- board_tab.dart
- menu_screen.dart
- State
- order_model.dart
- printer_service.dart
- printer_settings_screen.dart
- reports_screen.dart
- order_service.dart
- StatelessWidget
- dashboard_screen.dart
- StatefulWidget
- discount_model.dart
- AuthProvider
- table_model.dart
- package:flutter/material.dart
- table_service.dart
- menu_item_model.dart
- auth_provider.dart
- GeneratedPluginRegistrant.swift
- auth_service.dart
- account_model.dart
- main.dart
- tables_screen.dart
- discount_service.dart
- package:cloud_firestore/cloud_firestore.dart
- .application
- ios/RunnerTests/RunnerTests.swift
- GeneratedPluginRegistrant.java
- FlutterMacOS
- AppDelegate
- .awakeFromNib
- RunnerTests
- _TooltipArrowPainter
- Runner-Bridging-Header.h
- _MainShellState
- _RailTooltip
- _buildTopBar

## God Nodes (most connected - your core abstractions)
1. `AuthProvider` - 17 edges
2. `AppDelegate` - 5 edges
3. `OrderModel` - 5 edges
4. `AppDelegate` - 4 edges
5. `_LoginScreenState` - 4 edges
6. `MenuItemModel` - 4 edges
7. `FlutterMacOS` - 4 edges
8. `_MainShellState` - 4 edges
9. `_TableBoardTabState` - 4 edges
10. `_OrdersScreenState` - 4 edges

## Surprising Connections (you probably didn't know these)
- `_TableBoardTabState` --references--> `AuthProvider`  [EXTRACTED]
  Claude outputs/board_tab.dart → lib/providers/auth_provider.dart
- `build` --references--> `AuthProvider`  [EXTRACTED]
  lib/screens/login/login_screen.dart → lib/providers/auth_provider.dart
- `_handleLogin` --references--> `AuthProvider`  [EXTRACTED]
  lib/screens/login/login_screen.dart → lib/providers/auth_provider.dart
- `build` --references--> `AuthProvider`  [EXTRACTED]
  lib/screens/main/main_shell.dart → lib/providers/auth_provider.dart
- `initState` --references--> `AuthProvider`  [EXTRACTED]
  lib/screens/main/main_shell.dart → lib/providers/auth_provider.dart

## Import Cycles
- None detected.

## Communities (42 total, 7 thin omitted)

### Community 0 - "orders/orders_screen.dart"
Cohesion: 0.01
Nodes (200): activeDiscount, activeDiscountId, _activeOrders, _AddCartItem, _addItem, amount, _applyDiscountLocally, _applyingId (+192 more)

### Community 1 - "Claude outputs/orders_screen.dart"
Cohesion: 0.01
Nodes (174): AudioPlayer, _CartEntry, activeDiscount, activeDiscountId, _activeOrders, _AddCartItem, _addItem, amount (+166 more)

### Community 2 - "main_shell.dart"
Cohesion: 0.05
Nodes (43): ../accounts/accounts_screen.dart, ../dashboard/dashboard_screen.dart, ../discounts/discounts_screen.dart, adminOnly, _buildDesktop, _buildMobile, child, collapsed (+35 more)

### Community 3 - "app_theme.dart"
Cohesion: 0.04
Nodes (42): dart:typed_data, dart:ui, accent, accentDark, AppColors, AppTheme, background, divider (+34 more)

### Community 4 - "board_tab.dart"
Cohesion: 0.05
Nodes (41): _activeOrders, _applyDiscountLocally, _billedTableIds, _boardChip, _boardDetail, _boardFilterBar, _boardListCard, build (+33 more)

### Community 5 - "menu_screen.dart"
Cohesion: 0.05
Nodes (40): IconData, build, _categoryCtrl, color, _confirmDelete, createState, _descCtrl, dispose (+32 more)

### Community 6 - "State"
Cohesion: 0.08
Nodes (35): _AddProductDialog, _TableBoardTabState, _AddProductDialogState, _DiscountPickerDialogState, _EditOrderDialogState, _HoanThanhBtnState, _InvoiceDialogState, _KDSTabState (+27 more)

### Community 7 - "order_model.dart"
Cohesion: 0.06
Nodes (30): double get, createdAt, discountAmount, discountCode, fromDoc, fromMap, id, image (+22 more)

### Community 8 - "printer_service.dart"
Cohesion: 0.07
Nodes (28): dart:async, dart:io, btAddress, btName, clear, connType, instance, ip (+20 more)

### Community 9 - "printer_settings_screen.dart"
Cohesion: 0.07
Nodes (28): _btDevices, build, _busy, _connType, createState, dispose, initState, _ipCtrl (+20 more)

### Community 10 - "reports_screen.dart"
Cohesion: 0.08
Nodes (25): Color, build, _buildContent, color, createState, _DailyBarChart, dailyRevenue, fmt (+17 more)

### Community 11 - "order_service.dart"
Cohesion: 0.08
Nodes (24): android, DefaultFirebaseOptions, ios, macos, web, OrderModel, completeAllOrdersAndFreeTable, createOrder (+16 more)

### Community 12 - "StatelessWidget"
Cohesion: 0.08
Nodes (25): _Badge, _CartRow, _HeaderActionBtn, _IconSqBtn, _MenuCard, _OrderBlock, _OrderDetailDialog, _QtyBtn (+17 more)

### Community 13 - "dashboard_screen.dart"
Cohesion: 0.08
Nodes (24): Color color,, int paidCount, activeCount,, _Badge, bg, build, color, count, currency (+16 more)

### Community 14 - "StatefulWidget"
Cohesion: 0.09
Nodes (23): _TableBoardTab, _AddProductDialog, _DiscountPickerDialog, _EditOrderDialog, _HoanThanhBtn, _InvoiceDialog, _KDSTab, _OptionPicker (+15 more)

### Community 15 - "discount_model.dart"
Cohesion: 0.11
Nodes (18): active, code, createdAt, description, DiscountModel, expiresAt, fromDoc, id (+10 more)

### Community 16 - "AuthProvider"
Cohesion: 0.14
Nodes (17): ChangeNotifier, FormState, AuthProvider, build, createState, dispose, _formKey, _handleLogin (+9 more)

### Community 17 - "table_model.dart"
Cohesion: 0.11
Nodes (17): activeDiscount, capacity, clearedAt, copyWith, currentOrderId, fromDoc, id, _int (+9 more)

### Community 18 - "package:flutter/material.dart"
Cohesion: 0.13
Nodes (13): core/theme/app_theme.dart, AccountsScreen, build, _roleColor, build, DiscountsScreen, package:cafe_admin/main.dart, package:flutter/material.dart (+5 more)

### Community 19 - "table_service.dart"
Cohesion: 0.12
Nodes (15): clearServiceRequest, clearTable, clearTableDiscount, _db, deleteTable, getAllTables, saveTable, setTableDiscount (+7 more)

### Community 20 - "menu_item_model.dart"
Cohesion: 0.13
Nodes (14): available, category, copyWith, description, fromDoc, id, imageUrl, MenuItemModel (+6 more)

### Community 21 - "auth_provider.dart"
Cohesion: 0.14
Nodes (13): AccountModel? get, bool get, _authService, clearError, _currentUser, _error, isAdmin, _isLoading (+5 more)

### Community 22 - "GeneratedPluginRegistrant.swift"
Cohesion: 0.15
Nodes (12): audioplayers_darwin, cloud_firestore, file_selector_macos, firebase_core, firebase_storage, flutter_tts, Foundation, network_info_plus (+4 more)

### Community 23 - "auth_service.dart"
Cohesion: 0.15
Nodes (12): dart:convert, AuthService, createAccount, _db, hashPassword, login, _salt, streamAccounts (+4 more)

### Community 24 - "account_model.dart"
Cohesion: 0.17
Nodes (11): DateTime, AccountModel, active, createdAt, fromDoc, fullName, id, passwordHash (+3 more)

### Community 25 - "main.dart"
Cohesion: 0.17
Nodes (11): firebase_options.dart, AuthGate, build, CafeAdminApp, initializeDateFormatting, main, null, package:intl/date_symbol_data_local.dart (+3 more)

### Community 26 - "tables_screen.dart"
Cohesion: 0.18
Nodes (10): TableModel, build, onDelete, onEdit, onToggleStatus, table, _TableCard, TablesScreen (+2 more)

### Community 27 - "discount_service.dart"
Cohesion: 0.22
Nodes (8): _db, delete, DiscountService, incrementUsage, save, streamDiscounts, toggle, ../models/discount_model.dart

### Community 28 - "package:cloud_firestore/cloud_firestore.dart"
Cohesion: 0.22
Nodes (8): _db, getLatestActiveForOrder, getLatestActiveForTable, InvoiceService, saveInvoice, setPaymentMethod, supersede, package:cloud_firestore/cloud_firestore.dart

### Community 29 - ".application"
Cohesion: 0.25
Nodes (6): Any, FlutterImplicitEngineBridge, FlutterImplicitEngineDelegate, AppDelegate, Bool, UIApplication

### Community 30 - "ios/RunnerTests/RunnerTests.swift"
Cohesion: 0.32
Nodes (5): Flutter, FlutterSceneDelegate, SceneDelegate, UIKit, XCTest

### Community 31 - "GeneratedPluginRegistrant.java"
Cohesion: 0.38
Nodes (5): GeneratedPluginRegistrant, androidx.annotation.Keep, io.flutter.embedding.engine.FlutterEngine, log, nonnull

### Community 32 - "FlutterMacOS"
Cohesion: 0.38
Nodes (3): Cocoa, FlutterMacOS, RunnerTests

### Community 33 - "AppDelegate"
Cohesion: 0.47
Nodes (4): FlutterAppDelegate, AppDelegate, Bool, NSApplication

### Community 34 - ".awakeFromNib"
Cohesion: 0.40
Nodes (4): FlutterPluginRegistry, RegisterGeneratedPlugins(), MainFlutterWindow, NSWindow

## Knowledge Gaps
- **752 isolated node(s):** `activeDiscount`, `activeDiscountId`, `_activeOrders`, `_AddCartItem`, `_addItem` (+747 more)
  These have ≤1 connection - possible missing edges or undocumented components. (Counts symbols only; 805 node(s) total have ≤1 connection when file, concept and rationale nodes are included.)
- **7 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `AuthProvider` connect `AuthProvider` to `orders/orders_screen.dart`, `main_shell.dart`, `board_tab.dart`, `State`, `_MainShellState`, `auth_provider.dart`, `main.dart`?**
  _High betweenness centrality (0.034) - this node is a cross-community bridge._
- **Why does `OrderModel` connect `order_service.dart` to `orders/orders_screen.dart`, `Claude outputs/orders_screen.dart`, `dashboard_screen.dart`, `order_model.dart`?**
  _High betweenness centrality (0.021) - this node is a cross-community bridge._
- **Why does `MenuItemModel` connect `menu_item_model.dart` to `orders/orders_screen.dart`, `Claude outputs/orders_screen.dart`, `menu_screen.dart`?**
  _High betweenness centrality (0.008) - this node is a cross-community bridge._
- **What connects `activeDiscount`, `activeDiscountId`, `_activeOrders` to the rest of the system?**
  _752 weakly-connected nodes found - possible documentation gaps or missing edges._
- **Should `orders/orders_screen.dart` be split into smaller, more focused modules?**
  _Cohesion score 0.009950248756218905 - nodes in this community are weakly interconnected._
- **Should `Claude outputs/orders_screen.dart` be split into smaller, more focused modules?**
  _Cohesion score 0.011428571428571429 - nodes in this community are weakly interconnected._
- **Should `main_shell.dart` be split into smaller, more focused modules?**
  _Cohesion score 0.045454545454545456 - nodes in this community are weakly interconnected._