import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:esc_pos_utils_plus/esc_pos_utils_plus.dart';
import 'package:image/image.dart' as img;

/// Canh lề của 1 dòng trên hóa đơn (chỉ áp dụng khi [ReceiptLine.right] rỗng).
enum ReceiptAlign { left, center, right }

/// 1 dòng nội dung trên hóa đơn.
/// - Có [right] (không [mid]) → in 2 cột: trái + phải (vd: "2 x Cà phê sữa" | "50.000đ").
/// - Có cả [mid] và [right] → in 3 cột dạng bảng, cố định độ rộng cột giữa/phải
///   để các dòng thẳng hàng với nhau (vd: Tên món | Đơn giá | Thành tiền).
class ReceiptLine {
  final String left;
  final String mid;
  final String right;
  final double fontSize;
  final bool bold;
  final ReceiptAlign align;

  const ReceiptLine(
    this.left, {
    this.mid = '',
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
    Uint8List? qrImageBytes,
    double qrDisplayWidth = 260,
  }) async {
    const padding = 16.0;
    final contentWidth = paperDots - padding * 2;
    // Cột giữa (Đơn giá) + cột phải (Thành tiền) khi dòng có bảng 3 cột —
    // độ rộng CỐ ĐỊNH để tiêu đề và các dòng dữ liệu thẳng hàng nhau.
    final tableRightColWidth = contentWidth * 0.26;
    final tableMidColWidth = contentWidth * 0.24;
    const colGap = 8.0;

    final leftPainters = <TextPainter>[];
    final midPainters = <TextPainter?>[];
    final rightPainters = <TextPainter?>[];
    double totalHeight = padding;

    for (final line in lines) {
      final style = TextStyle(
        color: Colors.black,
        fontSize: line.fontSize,
        fontWeight: line.bold ? FontWeight.bold : FontWeight.normal,
      );
      final isTable = line.mid.isNotEmpty;

      TextPainter? rightTp;
      TextPainter? midTp;
      double leftMaxWidth = contentWidth;

      if (isTable) {
        // Bảng 3 cột: cột giữa/phải cố định độ rộng để thẳng hàng qua các dòng.
        rightTp = TextPainter(
          text: TextSpan(text: line.right, style: style),
          textAlign: TextAlign.right,
          textDirection: TextDirection.ltr,
        )..layout(maxWidth: tableRightColWidth);
        midTp = TextPainter(
          text: TextSpan(text: line.mid, style: style),
          textAlign: TextAlign.right,
          textDirection: TextDirection.ltr,
        )..layout(maxWidth: tableMidColWidth);
        leftMaxWidth = contentWidth - tableRightColWidth - tableMidColWidth - colGap * 2;
        if (leftMaxWidth < 20) leftMaxWidth = 20;
      } else if (line.right.isNotEmpty) {
        // 2 cột: phải tự co theo nội dung, luôn thẳng mép phải trang.
        rightTp = TextPainter(
          text: TextSpan(text: line.right, style: style),
          textAlign: TextAlign.right,
          textDirection: TextDirection.ltr,
        )..layout(maxWidth: contentWidth);
        leftMaxWidth = contentWidth - rightTp.width - colGap;
        if (leftMaxWidth < 20) leftMaxWidth = 20;
      }

      final leftAlign = (line.right.isNotEmpty || isTable)
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
      )..layout(maxWidth: (line.right.isNotEmpty || isTable) ? leftMaxWidth : contentWidth);

      leftPainters.add(leftTp);
      midPainters.add(midTp);
      rightPainters.add(rightTp);

      var lineHeight = leftTp.height;
      if (rightTp != null && rightTp.height > lineHeight) lineHeight = rightTp.height;
      if (midTp != null && midTp.height > lineHeight) lineHeight = midTp.height;
      totalHeight += lineHeight + 8;
    }
    ui.Image? qrImg;
    double qrPaintH = 0;
    if (qrImageBytes != null) {
      final codec = await ui.instantiateImageCodec(qrImageBytes);
      final frame = await codec.getNextFrame();
      qrImg = frame.image;
      final scale = qrDisplayWidth / qrImg.width;
      qrPaintH = qrImg.height * scale;
      totalHeight += 16 + qrPaintH; // khoảng cách trước QR + chiều cao QR
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
      final midTp = midPainters[i];
      final rightTp = rightPainters[i];
      final line = lines[i];
      final isTable = line.mid.isNotEmpty;

      leftTp.paint(canvas, Offset(padding, y));
      double lineHeight = leftTp.height;

      if (isTable) {
        // Cột giữa: kết thúc ở 1 vị trí x CỐ ĐỊNH (không phụ thuộc độ rộng
        // cột phải thực tế của dòng đó) để mọi dòng có cột giữa thẳng hàng.
        final midBoxEndX = paperDots - padding - tableRightColWidth - colGap;
        if (midTp != null) {
          midTp.paint(canvas, Offset(midBoxEndX - midTp.width, y));
          if (midTp.height > lineHeight) lineHeight = midTp.height;
        }
        if (rightTp != null) {
          rightTp.paint(canvas, Offset(paperDots - padding - rightTp.width, y));
          if (rightTp.height > lineHeight) lineHeight = rightTp.height;
        }
      } else if (rightTp != null) {
        rightTp.paint(canvas, Offset(paperDots - padding - rightTp.width, y));
        if (rightTp.height > lineHeight) lineHeight = rightTp.height;
      }
      y += lineHeight + 8;
    }

    if (qrImg != null) {
      y += 8;
      final qrX = (paperDots - qrDisplayWidth) / 2;
      canvas.drawImageRect(
        qrImg,
        Rect.fromLTWH(0, 0, qrImg.width.toDouble(), qrImg.height.toDouble()),
        Rect.fromLTWH(qrX, y, qrDisplayWidth, qrPaintH),
        Paint(),
      );
      y += qrPaintH;
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
