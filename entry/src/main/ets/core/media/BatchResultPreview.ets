/**
 * 批量图片操作的轻量成品预览。
 *
 * 预览走与正式任务相同的缩放、拼接与编码规则，但把画布限制在 960px 内，
 * 避免用户每改一次参数就先执行一遍完整导出。
 */
import { drawing } from '@kit.ArkGraphics2D';
import { image } from '@kit.ImageKit';
import { fileIo } from '@kit.CoreFileKit';
import { PickedFile } from '../analyze/MediaAnalyzer';

const PREVIEW_LONG_EDGE = 960;

export class BatchResultPreview {
  static supports(title: string): boolean {
    return title.includes('拼接图片') || title === '批量转 WebP' ||
      title === '批量压缩图片' || title === '批量缩放' ||
      title === '图片生成视频' || title === '图片生成 GIF';
  }

  static async render(files: PickedFile[], title: string, quality: number,
    dimension: number, frameIndex: number = 0): Promise<image.PixelMap | undefined> {
    if (files.length === 0 || !BatchResultPreview.supports(title)) {
      return undefined;
    }
    if (title.includes('拼接图片')) {
      return BatchResultPreview.stack(files, title.startsWith('纵向'), dimension);
    }
    const file = files[Math.min(Math.max(0, frameIndex), files.length - 1)];
    if (title === '批量缩放') {
      return BatchResultPreview.decode(file.uri, dimension);
    }
    const pixels = await BatchResultPreview.decode(file.uri, PREVIEW_LONG_EDGE);
    if (title === '批量转 WebP' || title === '批量压缩图片') {
      return BatchResultPreview.encodeRoundTrip(pixels,
        title === '批量转 WebP' ? 'image/webp' : 'image/jpeg', quality);
    }
    // 图片转视频/GIF 的实际画面就是按顺序停留的源帧；页面负责按停留时间轮播。
    return pixels;
  }

  private static async decode(uri: string, requestedLongEdge: number): Promise<image.PixelMap> {
    const file = fileIo.openSync(uri, fileIo.OpenMode.READ_ONLY);
    const source = image.createImageSource(file.fd);
    try {
      const info = await source.getImageInfo();
      const longEdge = Math.max(1, Math.min(PREVIEW_LONG_EDGE, requestedLongEdge));
      const ratio = Math.min(1, longEdge / Math.max(1, info.size.width, info.size.height));
      return await source.createPixelMap({
        editable: true,
        desiredPixelFormat: image.PixelMapFormat.RGBA_8888,
        desiredSize: {
          width: Math.max(1, Math.round(info.size.width * ratio)),
          height: Math.max(1, Math.round(info.size.height * ratio))
        }
      });
    } finally {
      await source.release();
      fileIo.closeSync(file);
    }
  }

  private static async encodeRoundTrip(pixels: image.PixelMap, format: string,
    quality: number): Promise<image.PixelMap> {
    const packer = image.createImagePacker();
    let source: image.ImageSource | undefined = undefined;
    try {
      const encoded = await packer.packToData(pixels, {
        format: format,
        quality: Math.min(100, Math.max(1, Math.round(quality)))
      });
      source = image.createImageSource(encoded);
      return await source.createPixelMap({ editable: false });
    } finally {
      await pixels.release();
      await source?.release();
      await packer.release();
    }
  }

  private static async sourceSize(uri: string): Promise<image.Size> {
    const file = fileIo.openSync(uri, fileIo.OpenMode.READ_ONLY);
    const source = image.createImageSource(file.fd);
    try {
      return (await source.getImageInfo()).size;
    } finally {
      await source.release();
      fileIo.closeSync(file);
    }
  }

  private static async decodeSize(uri: string, size: image.Size): Promise<image.PixelMap> {
    const file = fileIo.openSync(uri, fileIo.OpenMode.READ_ONLY);
    const source = image.createImageSource(file.fd);
    try {
      return await source.createPixelMap({
        editable: false,
        desiredSize: size
      });
    } finally {
      await source.release();
      fileIo.closeSync(file);
    }
  }

  private static async stack(files: PickedFile[], vertical: boolean,
    requestedCross: number): Promise<image.PixelMap> {
    const sizes: image.Size[] = [];
    for (const file of files) {
      sizes.push(await BatchResultPreview.sourceSize(file.uri));
    }
    const cross = Math.max(16, Math.min(requestedCross,
      ...sizes.map((size: image.Size) => vertical ? size.width : size.height)));
    const fullTargets = sizes.map((size: image.Size): image.Size => {
      const ratio = cross / (vertical ? size.width : size.height);
      return {
        width: Math.max(1, Math.round(size.width * ratio)),
        height: Math.max(1, Math.round(size.height * ratio))
      };
    });
    const fullWidth = vertical ? cross : fullTargets.reduce((sum: number, size: image.Size) => sum + size.width, 0);
    const fullHeight = vertical ? fullTargets.reduce((sum: number, size: image.Size) => sum + size.height, 0) : cross;
    const previewScale = Math.min(1, PREVIEW_LONG_EDGE / Math.max(fullWidth, fullHeight));
    const targets = fullTargets.map((size: image.Size): image.Size => ({
      width: Math.max(1, Math.round(size.width * previewScale)),
      height: Math.max(1, Math.round(size.height * previewScale))
    }));
    const width = vertical ? Math.max(1, Math.round(fullWidth * previewScale)) :
      targets.reduce((sum: number, size: image.Size) => sum + size.width, 0);
    const height = vertical ? targets.reduce((sum: number, size: image.Size) => sum + size.height, 0) :
      Math.max(1, Math.round(fullHeight * previewScale));
    const result = await image.createPixelMap(new ArrayBuffer(width * height * 4), {
      size: { width: width, height: height },
      pixelFormat: image.PixelMapFormat.RGBA_8888,
      alphaType: image.AlphaType.PREMUL,
      editable: true
    });
    try {
      const canvas = new drawing.Canvas(result);
      let offsetX = 0;
      let offsetY = 0;
      for (let i = 0; i < files.length; i++) {
        const part = await BatchResultPreview.decodeSize(files[i].uri, targets[i]);
        try {
          canvas.drawImage(part, offsetX, offsetY);
          if (vertical) {
            offsetY += targets[i].height;
          } else {
            offsetX += targets[i].width;
          }
        } finally {
          await part.release();
        }
      }
      return result;
    } catch (e) {
      await result.release();
      throw e as Error;
    }
  }
}
