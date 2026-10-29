import 'package:shared_preferences/shared_preferences.dart';

import '../models/order_model.dart' show OrderChannel;

/// Giá bán trên app giao hàng: Grab / ShopeeFood thường bán cao hơn giá tại quán
/// (bù chiết khấu của app). Cài đặt % cộng thêm cho từng app — POS tự tính giá
/// khi tạo đơn app, làm tròn lên 1.000đ. 0% = bán đúng giá menu.
/// Lưu trên từng máy (SharedPreferences), giống cài đặt máy in.
class DeliveryPricingService {
  DeliveryPricingService._();
  static final DeliveryPricingService instance = DeliveryPricingService._();

  static const _kGrab = 'delivery_markup_grab';
  static const _kShopee = 'delivery_markup_shopee';
  static const _kGrabFee = 'delivery_commission_grab';
  static const _kShopeeFee = 'delivery_commission_shopee';

  double grabPercent = 0;
  double shopeePercent = 0;
  /// % chiết khấu app thu của quán trên mỗi đơn — lưu kèm hóa đơn lúc giao
  /// tài xế để báo cáo tính tiền quán THỰC NHẬN.
  double grabCommission = 0;
  double shopeeCommission = 0;
  bool _loaded = false;

  Future<void> load() async {
    if (_loaded) return;
    final sp = await SharedPreferences.getInstance();
    grabPercent = sp.getDouble(_kGrab) ?? 0;
    shopeePercent = sp.getDouble(_kShopee) ?? 0;
    grabCommission = sp.getDouble(_kGrabFee) ?? 0;
    shopeeCommission = sp.getDouble(_kShopeeFee) ?? 0;
    _loaded = true;
  }

  Future<void> save({
    required double grab,
    required double shopee,
    required double grabFee,
    required double shopeeFee,
  }) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setDouble(_kGrab, grab);
    await sp.setDouble(_kShopee, shopee);
    await sp.setDouble(_kGrabFee, grabFee);
    await sp.setDouble(_kShopeeFee, shopeeFee);
    grabPercent = grab;
    shopeePercent = shopee;
    grabCommission = grabFee;
    shopeeCommission = shopeeFee;
    _loaded = true;
  }

  double commissionFor(String? channel) => channel == OrderChannel.grab
      ? grabCommission
      : channel == OrderChannel.shopee
          ? shopeeCommission
          : 0;

  double percentFor(String? channel) => channel == OrderChannel.grab
      ? grabPercent
      : channel == OrderChannel.shopee
          ? shopeePercent
          : 0;

  /// Giá 1 món theo kênh: giá menu + %, làm tròn LÊN 1.000đ.
  double priceFor(double basePrice, String? channel) {
    final pct = percentFor(channel);
    if (pct <= 0 || basePrice <= 0) return basePrice;
    final raw = basePrice * (1 + pct / 100);
    return (raw / 1000).ceil() * 1000.0;
  }
}
