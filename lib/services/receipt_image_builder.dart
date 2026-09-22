import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:esc_pos_utils_plus/esc_pos_utils_plus.dart';
import 'package:image/image.dart' as img;

/// Canh lề của 1 dòng trên hóa đơn (chỉ áp dụng khi [ReceiptLine.right] rỗng).
enum ReceiptAlign { left, center, right }

/// 1 dòng nội dung trên hóa đơn. Nếu có [right] thì dòng được in 2 cột
/// (ví dụ: "2 x Cà phê sữa" bên trái, "50.000đ" bên phải).
class ReceiptLine {
  final String left;
  final String right;
  final double fontSize;
  final bool bold;
  final ReceiptAlign align;

  const ReceiptLine(
    this.left, {
    this.right = '',
    this.fontSize = 22,
    this.bold = false,
    this.align = ReceiptAlign.left,
  });
}

/// Dựng hóa đơn thành 1 tấm ảnh (bitmap) rồi convert sang lệnh ESC/POS dạng
/// ảnh (raster). Cách này in đúng tiếng Việt có dấu trên MỌI máy in nhiệt
/// ESC/POS, không phụ thuộc bảng mã (codepage TCVN3/Windows-1258...) mà từng
/// hãng máy in hỗ trợ khác nhau — chỉ cần máy in hỗ trợ lệnh in ảnh chuẩn
/// (hầu hết máy in nhiệt 58mm/80mm đời mới đều hỗ trợ).
class ReceiptImageBuilder {
  /// [paperDots]: độ rộng giấy tính theo dot ảnh. Khổ 80mm ~ 576 dot,
  /// khổ 58mm ~ 384 dot (theo chuẩn 203dpi phổ biến của máy in nhiệt).
  static Future<Uint8List> buildEscPosBytes({
    required List<ReceiptLine> lines,
    int paperDots = 576,
  }) async {
    const padding = 16.0;
    final contentWidth = paperDots - padding * 2;

    final leftPainters = <TextPainter>[];
    final rightPainters = <TextPainter?>[];
    double totalHeight = padding;

    for (final line in lines) {
      final style = TextStyle(
        color: Colors.black,
        fontSize: line.fontSize,
        fontWeight: line.bold ? FontWeight.bold : FontWeight.normal,
      );

      TextPainter? rightTp;
      double leftMaxWidth = contentWidth;
      if (line.right.isNotEmpty) {
        rightTp = TextPainter(
          text: TextSpan(text: line.right, style: style),
          textAlign: TextAlign.right,
          textDirection: TextDirection.ltr,
        )..layout(maxWidth: contentWidth);
        leftMaxWidth = contentWidth - rightTp.width - 8;
        if (leftMaxWidth < 20) leftMaxWidth = 20;
      }

      final leftAlign = line.right.isNotEmpty
          ? TextAlign.left
          : (line.align == ReceiptAlign.center
              ? TextAlign.center
              : line.align == ReceiptAlign.right
                  ? TextAlign.right
                  : TextAlign.left);

      final leftTp = TextPainter(
        text: TextSpan(text: line.left, style: style),
        textAlign: leftAlign,
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: line.right.isNotEmpty ? leftMaxWidth : contentWidth);

      leftPainters.add(leftTp);
      rightPainters.add(rightTp);

      final lineHeight = rightTp != null
          ? (leftTp.height > rightTp.height ? leftTp.height : rightTp.height)
          : leftTp.height;
      totalHeight += lineHeight + 8;
    }
    totalHeight += padding;
    final h = totalHeight.ceil() < 1 ? 1 : totalHeight.ceil();

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(
        recorder, Rect.fromLTWH(0, 0, paperDots.toDouble(), h.toDouble()));
    canvas.drawRect(Rect.fromLTWH(0, 0, paperDots.toDouble(), h.toDouble()),
        Paint()..color = Colors.white);

    double y = padding;
    for (var i = 0; i < lines.length; i++) {
      final leftTp = leftPainters[i];
      final rightTp = rightPainters[i];
      final line = lines[i];
      double leftX = padding;
      if (line.right.isEmpty && line.align == ReceiptAlign.center) {
        // TextPainter với textAlign.center đã tự canh giữa trong contentWidth
        // vì layout dùng maxWidth = contentWidth, nên vẫn vẽ ở x = padding.
      }
      leftTp.paint(canvas, Offset(leftX, y));
      double lineHeight = leftTp.height;
      if (rightTp != null) {
        rightTp.paint(canvas, Offset(paperDots - padding - rightTp.width, y));
        if (rightTp.height > lineHeight) lineHeight = rightTp.height;
      }
      y += lineHeight + 8;
    }

    final picture = recorder.endRecording();
    final uiImage = await picture.toImage(paperDots, h);
    final byteData = await uiImage.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (byteData == null) {
      throw Exception('Không thể dựng ảnh hóa đơn để in');
    }

    var rasterImage = img.Image.fromBytes(
      width: paperDots,
      height: h,
      bytes: byteData.buffer,
      numChannels: 4,
      order: img.ChannelOrder.rgba,
    );
    rasterImage = img.grayscale(rasterImage);

    final profile = await CapabilityProfile.load();
    final generator = Generator(
        paperDots >= 500 ? PaperSize.mm80 : PaperSize.mm58, profile);
    final out = <int>[];
    out.addAll(generator.reset());
    out.addAll(generator.image(rasterImage));
    out.addAll(generator.feed(2));
    out.addAll(generator.cut());
    return Uint8List.fromList(out);
  }
}
