import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:esc_pos_utils_plus/esc_pos_utils_plus.dart';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;

/// Nội dung 1 tem dán ly (mỗi ly 1 tem).
class CupLabelData {
  final String channelLabel; // GRAB / SHOPEEFOOD
  final String orderCode;    // mã đơn trên app (vd GF-482)
  final int cupIndex;        // ly thứ mấy (1-based) trong cả đơn
  final int cupTotal;        // tổng số ly của đơn
  final String itemName;
  final String? options;     // "Size L · Đường 70%"
  final String? note;
  final String? shopName;
  final String? timeText;    // "14:32 28/10"

  const CupLabelData({
    required this.channelLabel,
    required this.orderCode,
    required this.cupIndex,
    required this.cupTotal,
    required this.itemName,
    this.options,
    this.note,
    this.shopName,
    this.timeText,
  });
}

/// Dựng tem dán ly thành ảnh đen trắng rồi chuyển sang lệnh in.
///
/// Giống [ReceiptImageBuilder]: vẽ chữ thành ảnh nên in đúng tiếng Việt có dấu
/// trên mọi máy, không phụ thuộc bảng mã của máy in.
/// Máy in tem 203dpi → 8 dot / mm (tem 40×30mm = 320×240 dot).
class LabelImageBuilder {
  static const int dotsPerMm = 8;

  /// Vẽ 1 tem → ảnh RGBA (trắng nền, chữ đen).
  static Future<ui.Image> _renderUi(CupLabelData d, int w, int h) async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder, Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()));
    canvas.drawRect(Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()), Paint()..color = Colors.white);

    // Tỉ lệ chữ theo chiều cao tem (thiết kế chuẩn cho tem cao 30mm = 240 dot).
    final k = (h / 240.0).clamp(0.7, 2.0).toDouble();
    // Lề an toàn ~1.25mm: máy in tem thường lệch vài dot khi canh khe giấy.
    final pad = 10.0 * k;
    final cw = w - pad * 2;

    TextPainter tp(String text, double size,
        {bool bold = false, Color color = Colors.black, int maxLines = 1, double? maxW, TextAlign align = TextAlign.left}) {
      return TextPainter(
        text: TextSpan(
          text: text,
          style: TextStyle(
            color: color,
            fontSize: size,
            height: 1.15,
            fontWeight: bold ? FontWeight.w800 : FontWeight.w500,
          ),
        ),
        maxLines: maxLines,
        ellipsis: '…',
        textAlign: align,
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: maxW ?? cw);
    }

    double y = pad;

    // ── Hàng đầu: [GRAB] #mã ............ 1/3 ──
    final cupTp = tp('${d.cupIndex}/${d.cupTotal}', 24 * k, bold: true);
    final chTp = tp(d.channelLabel, 15 * k, bold: true, color: Colors.white);
    final chBoxW = chTp.width + 10 * k;
    final headerH = [cupTp.height, chTp.height + 6 * k].reduce((a, b) => a > b ? a : b);
    final codeMaxW = cw - chBoxW - 8 * k - cupTp.width - 8 * k;
    final codeTp = tp(d.orderCode.isEmpty ? '' : '#${d.orderCode}', 24 * k,
        bold: true, maxW: codeMaxW < 20 ? 20 : codeMaxW);

    final chBoxH = chTp.height + 6 * k;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
          Rect.fromLTWH(pad, y + (headerH - chBoxH) / 2, chBoxW, chBoxH), Radius.circular(4 * k)),
      Paint()..color = Colors.black,
    );
    chTp.paint(canvas, Offset(pad + 5 * k, y + (headerH - chTp.height) / 2));
    codeTp.paint(canvas, Offset(pad + chBoxW + 8 * k, y + (headerH - codeTp.height) / 2));
    cupTp.paint(canvas, Offset(w - pad - cupTp.width, y + (headerH - cupTp.height) / 2));
    y += headerH + 4 * k;

    canvas.drawRect(Rect.fromLTWH(pad, y, cw, 2 * k), Paint()..color = Colors.black);
    y += 2 * k + 5 * k;

    // ── Chân tem: tên quán (trái) + giờ (phải) ──
    final footParts = <TextPainter>[];
    TextPainter? timeTp;
    TextPainter? shopTp;
    if (d.timeText != null && d.timeText!.isNotEmpty) {
      timeTp = tp(d.timeText!, 14 * k);
      footParts.add(timeTp);
    }
    if (d.shopName != null && d.shopName!.isNotEmpty) {
      final maxW = cw - (timeTp?.width ?? 0) - 8 * k;
      shopTp = tp(d.shopName!, 14 * k, bold: true, maxW: maxW < 20 ? 20 : maxW);
      footParts.add(shopTp);
    }
    final footH = footParts.isEmpty ? 0.0 : footParts.map((e) => e.height).reduce((a, b) => a > b ? a : b);
    final footY = h - pad - footH;

    // ── Thân tem: tên món, tuỳ chọn, ghi chú — tự thu nhỏ chữ cho vừa ──
    final bodyAvail = footY - (footH > 0 ? 4 * k : 0) - y;
    List<TextPainter> body = [];
    for (var s = 1.0; s >= 0.6; s -= 0.05) {
      body = [
        tp(d.itemName, 26 * k * s, bold: true, maxLines: 2),
        if (d.options != null && d.options!.isNotEmpty) tp(d.options!, 19 * k * s, bold: true),
        if (d.note != null && d.note!.isNotEmpty) tp('* ${d.note!}', 17 * k * s, maxLines: 2),
      ];
      final total = body.fold<double>(0, (a, e) => a + e.height) + 3 * k * (body.length - 1);
      if (total <= bodyAvail) break;
    }
    for (final t in body) {
      if (y + t.height > footY + 1) break; // hết chỗ → bỏ dòng (đã thu nhỏ hết mức)
      t.paint(canvas, Offset(pad, y));
      y += t.height + 3 * k;
    }

    if (shopTp != null) shopTp.paint(canvas, Offset(pad, footY));
    if (timeTp != null) timeTp.paint(canvas, Offset(w - pad - timeTp.width, footY));

    final picture = recorder.endRecording();
    return picture.toImage(w, h);
  }

  /// Ảnh PNG của tem — dùng để xem trước trong Cài đặt.
  static Future<Uint8List> renderPng(CupLabelData d, {required int widthMm, required int heightMm}) async {
    final ui.Image im = await _renderUi(d, widthMm * dotsPerMm, heightMm * dotsPerMm);
    final bd = await im.toByteData(format: ui.ImageByteFormat.png);
    return bd!.buffer.asUint8List();
  }

  /// Vẽ tem → ảnh đen trắng (package:image), [rotate180] cho máy đẩy giấy ngược.
  static Future<img.Image> renderMono(CupLabelData d,
      {required int widthMm, required int heightMm, bool rotate180 = false}) async {
    final w = widthMm * dotsPerMm;
    final h = heightMm * dotsPerMm;
    final uiImage = await _renderUi(d, w, h);
    final byteData = await uiImage.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (byteData == null) throw Exception('Không thể dựng ảnh tem để in');
    var im = img.Image.fromBytes(
      width: w,
      height: h,
      bytes: byteData.buffer,
      numChannels: 4,
      order: img.ChannelOrder.rgba,
    );
    im = img.grayscale(im);
    if (rotate180) im = img.copyRotate(im, angle: 180);
    return im;
  }

  /// Lệnh TSPL (Xprinter XP-365B / XP-420B / TSC…): mỗi ảnh = 1 tem.
  /// Trong TSPL BITMAP, bit 1 = KHÔNG in (trắng), bit 0 = in (đen).
  static Uint8List encodeTspl(List<img.Image> labels,
      {required int widthMm, required int heightMm, int gapMm = 2}) {
    final out = BytesBuilder();
    void cmd(String s) => out.add(ascii.encode('$s\r\n'));
    cmd('SIZE $widthMm mm,$heightMm mm');
    cmd('GAP $gapMm mm,0 mm');
    cmd('DIRECTION 1,0');
    cmd('REFERENCE 0,0');
    cmd('SET TEAR ON');
    for (final im in labels) {
      final wBytes = (im.width + 7) ~/ 8;
      final data = Uint8List(wBytes * im.height)..fillRange(0, wBytes * im.height, 0xFF);
      for (var yy = 0; yy < im.height; yy++) {
        for (var xx = 0; xx < im.width; xx++) {
          final lum = im.getPixel(xx, yy).r; // đã grayscale → r = g = b
          if (lum < 140) {
            data[yy * wBytes + (xx >> 3)] &= ~(0x80 >> (xx & 7));
          }
        }
      }
      cmd('CLS');
      out.add(ascii.encode('BITMAP 0,0,$wBytes,${im.height},0,'));
      out.add(data);
      out.add(ascii.encode('\r\n'));
      cmd('PRINT 1,1');
    }
    return out.toBytes();
  }

  /// Lệnh ESC/POS — dùng khi in tem bằng máy in bill lắp giấy decal cuộn:
  /// mỗi tem in xong cắt 1 lần.
  static Future<Uint8List> encodeEscPos(List<img.Image> labels) async {
    final profile = await CapabilityProfile.load();
    final width = labels.isEmpty ? 384 : labels.first.width;
    final generator = Generator(width > 400 ? PaperSize.mm80 : PaperSize.mm58, profile);
    final out = <int>[];
    out.addAll(generator.reset());
    for (final im in labels) {
      out.addAll(generator.image(im));
      out.addAll(generator.feed(1));
      out.addAll(generator.cut());
    }
    return Uint8List.fromList(out);
  }
}
