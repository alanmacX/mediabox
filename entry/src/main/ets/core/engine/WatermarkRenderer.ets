import { image } from '@kit.ImageKit';
import { drawing } from '@kit.ArkGraphics2D';
import { fileIo } from '@kit.CoreFileKit';
import { TaskParams } from '../task/MediaTask';

/** Coordinates/width use original-media pixels. The same renderer supports scaled previews. */
export class WatermarkRenderer {
  static async draw(base: image.PixelMap, uri: string, params: TaskParams,
    scaleX: number = 1, scaleY: number = 1): Promise<void> {
    const file = await fileIo.open(uri, fileIo.OpenMode.READ_ONLY);
    const source = image.createImageSource(file.fd);
    let mark: image.PixelMap | undefined;
    try {
      const info = await source.getImageInfo();
      const width = params.watermarkWidth ?? 240;
      if (!Number.isFinite(width) || width <= 0 || width > 16384) throw new Error('水印宽度超出范围');
      const height = width * info.size.height / Math.max(1, info.size.width);
      let x = (params.watermarkX ?? 24) * scaleX, y = (params.watermarkY ?? 24) * scaleY;
      const baseInfo = await base.getImageInfo();
      const position = params.watermarkPosition ?? 'custom';
      if (position !== 'custom') {
        x = position.includes('right') ? baseInfo.size.width - width * scaleX - 10 * scaleX : 10 * scaleX;
        y = position.includes('bottom') ? baseInfo.size.height - height * scaleY - 10 * scaleY : 10 * scaleY;
        if (position === 'center') { x = (baseInfo.size.width - width * scaleX) / 2; y = (baseInfo.size.height - height * scaleY) / 2; }
      }
      if (x < 0 || y < 0 || x >= baseInfo.size.width || y >= baseInfo.size.height) {
        throw new Error('水印起点必须位于画面内');
      }
      mark = await source.createPixelMap({ desiredSize: {
        width: Math.max(1, Math.round(width * scaleX)), height: Math.max(1, Math.round(height * scaleY)) } });
      const canvas = new drawing.Canvas(base);
      canvas.drawImageRect(mark, { left: x, top: y, right: x + width * scaleX, bottom: y + height * scaleY });
    } finally { await mark?.release(); await source.release(); await fileIo.close(file); }
  }
}
