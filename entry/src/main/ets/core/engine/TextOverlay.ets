import { image } from '@kit.ImageKit';
import { drawing } from '@kit.ArkGraphics2D';
import { TaskParams } from '../task/MediaTask';

/**
 * Shared by export bitmap / video layer / downscaled preview.
 * Use Pen+Brush for broader OHOS Drawing compatibility; color must be #RRGGBB.
 */
export class TextOverlay {
  static draw(pixels: image.PixelMap, params: TaskParams, scaleX: number = 1, scaleY: number = 1): void {
    const value = (params.textOverlay ?? '').trim();
    if (value.length === 0) {
      return;
    }
    const color = params.textColor ?? '#FFFFFF';
    if (!/^#[0-9a-fA-F]{6}$/.test(color)) {
      throw new Error('文字颜色格式为 #RRGGBB');
    }
    const r = parseInt(color.substring(1, 3), 16);
    const g = parseInt(color.substring(3, 5), 16);
    const b = parseInt(color.substring(5, 7), 16);
    const size = Math.max(8, Math.min(512, Math.round((params.textFontSize ?? 32) * Math.min(scaleX, scaleY))));
    const x = Math.max(0, Math.round((params.textX ?? 24) * scaleX));
    const y = Math.max(size, Math.round(((params.textY ?? 24) + (params.textFontSize ?? 32)) * scaleY));

    const canvas = new drawing.Canvas(pixels);
    const brush = new drawing.Brush();
    brush.setColor(255, r, g, b);
    const pen = new drawing.Pen();
    pen.setColor(255, r, g, b);
    pen.setStrokeWidth(Math.max(1, Math.round(size / 16)));

    const font = new drawing.Font();
    font.setSize(size);

    try {
      const blob = drawing.TextBlob.makeFromString(value, font);
      if (blob === undefined || blob === null) {
        return;
      }
      canvas.attachBrush(brush);
      canvas.drawTextBlob(blob, x, y);
      canvas.detachBrush();
      // 轻描边，浅色底上也可读
      canvas.attachPen(pen);
      canvas.drawTextBlob(blob, x, y);
      canvas.detachPen();
    } catch (e) {
      const err = e as Error;
      throw new Error(`绘制文字失败：${err.message}`);
    }
  }
}
