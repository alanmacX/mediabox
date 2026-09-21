import { image } from '@kit.ImageKit';
import { media } from '@kit.MediaKit';
import { fileIo } from '@kit.CoreFileKit';
import { AnalyzedMedia, MediaType } from '../model/MediaTypes';

export class PreviewFrames {
  static async load(info: AnalyzedMedia, seconds: number = 0): Promise<image.PixelMap> {
    const file = await fileIo.open(info.uri, fileIo.OpenMode.READ_ONLY);
    let source: image.ImageSource | undefined;
    let extractor: media.AVMetadataExtractor | undefined;
    try {
      const width = info.video?.width ?? info.imageWidth;
      const height = info.video?.height ?? info.imageHeight;
      if (width <= 0 || height <= 0) throw new Error('未读取到画面尺寸，无法生成预览');
      const ratio = Math.min(1, 960 / Math.max(width, height));
      const size: image.Size = { width: Math.max(1, Math.round(width * ratio)),
        height: Math.max(1, Math.round(height * ratio)) };
      if (info.mediaType === MediaType.IMAGE || info.mediaType === MediaType.GIF) {
        source = image.createImageSource(file.fd);
        let index = 0;
        if (info.mediaType === MediaType.GIF && seconds > 0) {
          const delays = await source.getDelayTimeList();
          let end = 0;
          for (let i = 0; i < delays.length; i++) {
            end += Math.max(1, delays[i]);
            index = i;
            if (seconds * 1000 < end) break;
          }
        }
        return await source.createPixelMap({ desiredSize: size, editable: true, index: index });
      }
      extractor = await media.createAVMetadataExtractor();
      extractor.fdSrc = { fd: file.fd, offset: 0, length: fileIo.statSync(file.fd).size };
      const frame = await extractor.fetchFrameByTime(seconds * 1_000_000,
        media.AVImageQueryOptions.AV_IMAGE_QUERY_CLOSEST, size);
      try {
        const packer = image.createImagePacker();
        try {
          const data = await packer.packToData(frame, { format: 'image/png', quality: 100 });
          source = image.createImageSource(data);
          return await source.createPixelMap({ editable: true });
        } finally { await packer.release(); }
      } finally { await frame.release(); }
    } finally { await source?.release(); await extractor?.release(); await fileIo.close(file); }
  }
}
