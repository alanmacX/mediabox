/**
 * 预览缩略图统一入口。
 * - 音频/字幕：不生成画面预览
 * - 动态照片：优先系统自带关键帧（PhotoAsset.getThumbnail）
 * - 图片/GIF：Image Kit 解码
 * - 视频：AVMetadataExtractor 抽帧
 */
import { common } from '@kit.AbilityKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { dataSharePredicates } from '@kit.ArkData';
import { image } from '@kit.ImageKit';
import { media } from '@kit.MediaKit';
import { fileIo, fileUri } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { AnalyzedMedia, MediaType } from '../model/MediaTypes';
import { PreviewFrames } from './PreviewFrames';

const TAG = 'MediaThumb';
const DOMAIN = 0x4D42;
const THUMB_LONG_EDGE = 960;

export interface MediaThumbInput {
  uri: string;
  displayName?: string;
  mediaType?: MediaType;
  isMovingPhoto?: boolean;
  imageWidth?: number;
  imageHeight?: number;
}

function extType(name: string): MediaType {
  const idx = name.lastIndexOf('.');
  if (idx < 0) {
    return MediaType.UNKNOWN;
  }
  switch (name.substring(idx + 1).toLowerCase()) {
    case 'jpg':
    case 'jpeg':
    case 'png':
    case 'webp':
    case 'heif':
    case 'heic':
    case 'avif':
    case 'bmp':
    case 'tif':
    case 'tiff':
      return MediaType.IMAGE;
    case 'gif':
      return MediaType.GIF;
    case 'mp4':
    case 'mov':
    case 'mkv':
    case 'webm':
    case 'avi':
    case 'ts':
    case 'flv':
    case 'm4v':
    case '3gp':
      return MediaType.VIDEO;
    case 'mp3':
    case 'aac':
    case 'm4a':
    case 'wav':
    case 'flac':
    case 'ogg':
    case 'opus':
    case 'amr':
      return MediaType.AUDIO;
    case 'srt':
    case 'vtt':
    case 'ass':
    case 'ssa':
      return MediaType.SUBTITLE;
    default:
      return MediaType.UNKNOWN;
  }
}

export class MediaThumb {
  /** 需要画面预览的类型；音频/字幕不需要。 */
  static wantsPreview(type: MediaType, isMovingPhoto: boolean = false): boolean {
    if (isMovingPhoto) {
      return true;
    }
    return type === MediaType.IMAGE || type === MediaType.GIF || type === MediaType.VIDEO;
  }

  static async load(info: MediaThumbInput | AnalyzedMedia,
    context?: common.UIAbilityContext, seconds: number = 0): Promise<image.PixelMap | undefined> {
    const uri = info.uri;
    const displayName = (info as AnalyzedMedia).displayName ?? (info as MediaThumbInput).displayName ?? '';
    const isMoving = info.isMovingPhoto === true;
    const type = info.mediaType ?? extType(displayName);
    if (!MediaThumb.wantsPreview(type, isMoving)) {
      return undefined;
    }
    if (isMoving) {
      return MediaThumb.loadMovingPhotoKeyframe(uri, context);
    }
    if (type === MediaType.IMAGE || type === MediaType.GIF) {
      return MediaThumb.decodeStill(uri, info.imageWidth ?? 0, info.imageHeight ?? 0, seconds,
        type === MediaType.GIF);
    }
    if (type === MediaType.VIDEO) {
      const analyzed = info as AnalyzedMedia;
      if (analyzed.video !== undefined && (analyzed.video.width > 0 || analyzed.imageWidth > 0)) {
        try {
          return await PreviewFrames.load(analyzed, seconds);
        } catch (e) {
          // fall through
        }
      }
      return MediaThumb.loadVideoFrame(uri, seconds);
    }
    return undefined;
  }

  /** 把解码出的 PixelMap 落成沙箱预览图，返回 file:// URI 供 Image 组件加载。 */
  static async cachePreview(pm: image.PixelMap, context: common.UIAbilityContext): Promise<string> {
    const packer = image.createImagePacker();
    const path = `${context.cacheDir}/preview_${Date.now()}.jpg`;
    const file = fileIo.openSync(path, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
    try {
      await packer.packToFile(pm, file.fd, { format: 'image/jpeg', quality: 90 });
      hilog.info(DOMAIN, TAG, 'cachePreview ok %{public}s', path);
    } catch (e) {
      fileIo.closeSync(file);
      await packer.release();
      hilog.error(DOMAIN, TAG, 'cachePreview failed %{public}s', (e as Error).message);
      throw new Error((e as Error).message);
    }
    return fileUri.getUriFromPath(path);
  }

  /**
   * 动态照片关键帧：
   * 1) PhotoAsset.getThumbnail（系统自带关键帧/缩略图）
   * 2) Image Kit 直接解码 URI（部分机型 moving URI 可读静态图）
   * 3) MediaAssetManager 导出 IMAGE_RESOURCE 后再解码
   */
  static async loadMovingPhotoKeyframe(uri: string,
    context?: common.UIAbilityContext): Promise<image.PixelMap | undefined> {
    const fromSystem = await MediaThumb.systemPhotoThumbnail(uri, context);
    if (fromSystem !== undefined) {
      return fromSystem;
    }
    try {
      return await MediaThumb.decodeStill(uri, 0, 0);
    } catch (e) {
      hilog.info(DOMAIN, TAG, 'moving photo uri decode failed %{public}s', (e as Error).message);
    }
    return MediaThumb.exportMovingPhotoStill(uri, context);
  }

  private static async systemPhotoThumbnail(uri: string,
    context?: common.UIAbilityContext): Promise<image.PixelMap | undefined> {
    if (context === undefined) {
      return undefined;
    }
    let result: photoAccessHelper.FetchResult<photoAccessHelper.PhotoAsset> | undefined = undefined;
    try {
      const helper = photoAccessHelper.getPhotoAccessHelper(context);
      const predicates = new dataSharePredicates.DataSharePredicates();
      predicates.equalTo(photoAccessHelper.PhotoKeys.URI, uri);
      result = await helper.getAssets({
        fetchColumns: [photoAccessHelper.PhotoKeys.URI],
        predicates: predicates
      });
      if (result.getCount() === 0) {
        return undefined;
      }
      const asset = await result.getFirstObject();
      return await asset.getThumbnail({ width: THUMB_LONG_EDGE, height: THUMB_LONG_EDGE });
    } catch (e) {
      hilog.info(DOMAIN, TAG, 'system thumbnail failed %{public}s', (e as Error).message);
      return undefined;
    } finally {
      try {
        result?.close();
      } catch (closeErr) {
        // ignore
      }
    }
  }

  /** 从动态照片导出静态资源作为关键帧预览。 */
  private static async exportMovingPhotoStill(uri: string,
    context?: common.UIAbilityContext): Promise<image.PixelMap | undefined> {
    if (context === undefined ||
      photoAccessHelper.MediaAssetManager === undefined ||
      typeof photoAccessHelper.MediaAssetManager.requestMovingPhoto !== 'function') {
      return undefined;
    }
    let result: photoAccessHelper.FetchResult<photoAccessHelper.PhotoAsset> | undefined = undefined;
    const cachePath = `${context.cacheDir}/moving_thumb_${Date.now()}.jpg`;
    let handlerKeepAlive: photoAccessHelper.MediaAssetDataHandler<photoAccessHelper.MovingPhoto> | undefined =
      undefined;
    try {
      const helper = photoAccessHelper.getPhotoAccessHelper(context);
      const predicates = new dataSharePredicates.DataSharePredicates();
      predicates.equalTo(photoAccessHelper.PhotoKeys.URI, uri);
      result = await helper.getAssets({
        fetchColumns: [photoAccessHelper.PhotoKeys.URI],
        predicates: predicates
      });
      if (result.getCount() === 0) {
        return undefined;
      }
      const asset = await result.getFirstObject();
      const movingPhoto = await new Promise<photoAccessHelper.MovingPhoto>((resolve, reject) => {
        const timeoutId = setTimeout(() => reject(new Error('moving photo keyframe timeout')), 15000);
        const handler: photoAccessHelper.MediaAssetDataHandler<photoAccessHelper.MovingPhoto> = {
          onDataPrepared: (data: photoAccessHelper.MovingPhoto): void => {
            clearTimeout(timeoutId);
            if (data === undefined || data === null) {
              reject(new Error('moving photo keyframe empty'));
              return;
            }
            resolve(data);
          }
        };
        handlerKeepAlive = handler;
        photoAccessHelper.MediaAssetManager.requestMovingPhoto(context, asset, {
          deliveryMode: photoAccessHelper.DeliveryMode.FAST_MODE
        }, handler).catch((err: Error) => {
          clearTimeout(timeoutId);
          reject(err);
        });
      });
      const stillUri = fileUri.getUriFromPath(cachePath);
      await movingPhoto.requestContent(photoAccessHelper.ResourceType.IMAGE_RESOURCE, stillUri);
      return await MediaThumb.decodeStill(stillUri, 0, 0);
    } catch (e) {
      hilog.info(DOMAIN, TAG, 'export moving keyframe failed %{public}s', (e as Error).message);
      return undefined;
    } finally {
      handlerKeepAlive = undefined;
      try {
        result?.close();
      } catch (closeErr) {
        // ignore
      }
      try {
        if (fileIo.accessSync(cachePath)) {
          fileIo.unlinkSync(cachePath);
        }
        if (fileIo.accessSync(cachePath.replace(/^file:\/\//, ''))) {
          fileIo.unlinkSync(cachePath.replace(/^file:\/\//, ''));
        }
      } catch (cleanup) {
        // ignore
      }
    }
  }

  private static async decodeStill(uri: string, width: number, height: number, seconds: number = 0,
    isGif: boolean = false): Promise<image.PixelMap> {
    const path = uri.startsWith('file://') ? uri : uri;
    let file: fileIo.File | undefined = undefined;
    let source: image.ImageSource | undefined = undefined;
    try {
      file = await fileIo.open(path, fileIo.OpenMode.READ_ONLY);
      source = image.createImageSource(file.fd);
      let index = 0;
      if (isGif && seconds > 0) {
        const delays = await source.getDelayTimeList();
        let end = 0;
        for (let i = 0; i < delays.length; i++) {
          end += Math.max(1, delays[i]);
          index = i;
          if (seconds * 1000 < end) {
            break;
          }
        }
      }
      const options: image.DecodingOptions = { editable: false, index: index };
      if (width > 0 && height > 0) {
        const ratio = Math.min(1, THUMB_LONG_EDGE / Math.max(width, height));
        options.desiredSize = {
          width: Math.max(1, Math.round(width * ratio)),
          height: Math.max(1, Math.round(height * ratio))
        };
      } else {
        hilog.info(DOMAIN, TAG, 'decodeStill no size hint uri=…%{public}s', path.substring(path.length - 24));
        try {
          const info = await source.getImageInfo();
          const ratio = Math.min(1, THUMB_LONG_EDGE / Math.max(1, info.size.width, info.size.height));
          options.desiredSize = {
            width: Math.max(1, Math.round(info.size.width * ratio)),
            height: Math.max(1, Math.round(info.size.height * ratio))
          };
        } catch (infoErr) {
          // 系统缩略图/导出图通常已足够小
        }
      }
      const pm = await source.createPixelMap(options);
      const info = pm.getImageInfoSync();
      hilog.info(DOMAIN, TAG, 'decodeStill ok %{public}dx%{public}d uri=…%{public}s',
        info.size.width, info.size.height, path.substring(path.length - 24));
      return pm;
    } catch (e) {
      const msg = (e as Error).message;
      hilog.error(DOMAIN, TAG, 'decodeStill failed %{public}s uri=…%{public}s',
        msg, path.substring(path.length - 24));
      throw new Error(msg);
    } finally {
      try {
        await source?.release();
      } catch (releaseErr) {
        // ignore
      }
      try {
        if (file !== undefined) {
          fileIo.close(file);
        }
      } catch (closeErr) {
        // ignore
      }
    }
  }

  /** 未知分辨率时也能抽视频帧，供批量列表等场景使用。 */
  static async loadVideoFrame(uri: string, seconds: number = 0,
    size: image.Size = { width: 480, height: 270 }): Promise<image.PixelMap | undefined> {
    let file: fileIo.File | undefined = undefined;
    let extractor: media.AVMetadataExtractor | undefined = undefined;
    try {
      file = await fileIo.open(uri, fileIo.OpenMode.READ_ONLY);
      extractor = await media.createAVMetadataExtractor();
      extractor.fdSrc = { fd: file.fd, offset: 0, length: fileIo.statSync(file.fd).size };
      return await extractor.fetchFrameByTime(Math.max(0, seconds) * 1_000_000,
        media.AVImageQueryOptions.AV_IMAGE_QUERY_CLOSEST, size);
    } catch (e) {
      hilog.info(DOMAIN, TAG, 'video frame failed %{public}s', (e as Error).message);
      return undefined;
    } finally {
      try {
        await extractor?.release();
      } catch (releaseErr) {
        // ignore
      }
      try {
        if (file !== undefined) {
          fileIo.close(file);
        }
      } catch (closeErr) {
        // ignore
      }
    }
  }
}
