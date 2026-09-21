/** Native Image Kit implementation of the upstream imageHStack/imageVStack operations. */
import { drawing } from '@kit.ArkGraphics2D';
import { image } from '@kit.ImageKit';
import { fileIo } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { MediaTask } from '../task/MediaTask';

export class ImageComposition {
  static async stack(context: common.UIAbilityContext, task: MediaTask,
    progress: (value: number) => void): Promise<string> {
    const uris = [task.sourceUri].concat(task.params.additionalSourceUris ?? []);
    const vertical = task.actionId === 'image_stack_vertical';
    const sizes: image.Size[] = [];
    for (const uri of uris) {
      const file = await fileIo.open(uri, fileIo.OpenMode.READ_ONLY);
      const source = image.createImageSource(file.fd);
      try { sizes.push((await source.getImageInfo()).size); }
      finally { await source.release(); await fileIo.close(file); }
    }
    if (sizes.length < 2) throw new Error('拼接至少需要两张图片');
    const cross = Math.min(task.params.targetWidth ?? 1920,
      ...sizes.map((size: image.Size) => vertical ? size.width : size.height));
    const targets: image.Size[] = sizes.map((size: image.Size): image.Size => {
      const ratio = cross / (vertical ? size.width : size.height);
      return { width: Math.max(1, Math.round(size.width * ratio)),
        height: Math.max(1, Math.round(size.height * ratio)) };
    });
    const width = vertical ? cross : targets.reduce((sum: number, size: image.Size) => sum + size.width, 0);
    const height = vertical ? targets.reduce((sum: number, size: image.Size) => sum + size.height, 0) : cross;
    if (width * height > 24_000_000 || width > 32768 || height > 32768) {
      throw new Error('拼接结果过大，请减少图片或降低拼接边长');
    }
    const pixels = await image.createPixelMap(new ArrayBuffer(width * height * 4), {
      size: { width: width, height: height }, pixelFormat: image.PixelMapFormat.RGBA_8888,
      alphaType: image.AlphaType.PREMUL, editable: true });
    try {
      const canvas = new drawing.Canvas(pixels);
      let offsetX = 0, offsetY = 0;
      for (let i = 0; i < uris.length; i++) {
        const input = await fileIo.open(uris[i], fileIo.OpenMode.READ_ONLY);
        const source = image.createImageSource(input.fd);
        let part: image.PixelMap | undefined;
        try {
          part = await source.createPixelMap({ desiredSize: targets[i] });
          canvas.drawImage(part, offsetX, offsetY);
          if (vertical) offsetY += targets[i].height; else offsetX += targets[i].width;
          progress(Math.round((i + 1) / uris.length * 85));
        } finally { await part?.release(); await source.release(); await fileIo.close(input); }
      }
    } catch (e) {
      await pixels.release();
      throw e as Error;
    }
    const packer = image.createImagePacker();
    let file: fileIo.File | undefined;
    try {
      const directory = `${context.filesDir}/outputs`;
      if (!fileIo.accessSync(directory)) fileIo.mkdirSync(directory);
      const path = `${directory}/stack_${task.id}.png`;
      file = await fileIo.open(path, fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.TRUNC);
      await packer.packToFile(pixels, file.fd, { format: 'image/png', quality: 100 });
      return path;
    } finally { await pixels.release(); await packer.release(); if (file) await fileIo.close(file); }
  }
}
