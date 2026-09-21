/**
 * 媒体选择服务。
 *
 * - 照片/视频:photoAccessHelper.PhotoViewPicker 安全组件,零权限,
 *   返回的 photoUris 具有永久授权,可直接 fileIo 打开。
 * - 任意文件(含 MKV / FLV / FLAC 等):picker.DocumentViewPicker,同样零权限。
 */
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { picker } from '@kit.CoreFileKit';
import { guessMediaType, PickedFile } from '../analyze/MediaAnalyzer';
import { MediaType } from '../model/MediaTypes';

export enum MediaPickMode {
  AUTO = 'AUTO',
  VIDEO = 'VIDEO',
  IMAGE = 'IMAGE',
  GIF = 'GIF',
  AUDIO = 'AUDIO',
  SUBTITLE = 'SUBTITLE',
  MOVING_PHOTO = 'MOVING_PHOTO'
}

export class MediaPickerService {
  /** 从图库选择图片/视频(可选动态照片)。 */
  static async pickPhotos(maxCount: number, mode: MediaPickMode = MediaPickMode.AUTO): Promise<PickedFile[]> {
    const options = new photoAccessHelper.PhotoSelectOptions();
    options.MIMEType = mode === MediaPickMode.MOVING_PHOTO ?
      photoAccessHelper.PhotoViewMIMETypes.MOVING_PHOTO_IMAGE_TYPE :
      (mode === MediaPickMode.VIDEO ? photoAccessHelper.PhotoViewMIMETypes.VIDEO_TYPE :
        (mode === MediaPickMode.IMAGE || mode === MediaPickMode.GIF ?
          photoAccessHelper.PhotoViewMIMETypes.IMAGE_TYPE : photoAccessHelper.PhotoViewMIMETypes.IMAGE_VIDEO_TYPE));
    options.maxSelectNumber = maxCount;
    options.isMovingPhotoBadgeShown = true;
    const result = await new photoAccessHelper.PhotoViewPicker().select(options);
    return result.photoUris.map((uri: string, index: number): PickedFile => {
      const path = uri.substring(uri.lastIndexOf('/') + 1);
      // 徽章优先；动态照片入口且徽章数组缺失时，不把全部选中项误标为动态照片
      const state = index < result.movingPhotoBadgeStates.length ? result.movingPhotoBadgeStates[index] :
        photoAccessHelper.MovingPhotoBadgeStateType.NOT_MOVING_PHOTO;
      const inferred = guessMediaType(decodeURIComponent(path));
      const selectedType = mode === MediaPickMode.VIDEO ? MediaType.VIDEO :
        (mode === MediaPickMode.GIF ? MediaType.GIF :
          (mode === MediaPickMode.IMAGE || mode === MediaPickMode.MOVING_PHOTO ? MediaType.IMAGE : undefined));
      const hint = inferred === MediaType.UNKNOWN ? selectedType : inferred;
      const badgeMoving = state !== photoAccessHelper.MovingPhotoBadgeStateType.NOT_MOVING_PHOTO &&
        state !== undefined;
      // 仅当 MIME 过滤为动态照片且徽章明确「是」时才标 moving
      const isMoving = badgeMoving;
      return { uri: uri, displayName: decodeURIComponent(path), mediaTypeHint: hint, isMovingPhoto: isMoving };
    });
  }

  private static suffixFilters(mode: MediaPickMode): string[] | undefined {
    switch (mode) {
      case MediaPickMode.VIDEO:
        return ['视频|.mp4,.mov,.mkv,.webm,.avi,.ts,.flv,.m4v,.3gp'];
      case MediaPickMode.IMAGE:
        return ['图片|.jpg,.jpeg,.png,.webp,.heif,.heic,.avif,.bmp,.tif,.tiff'];
      case MediaPickMode.GIF:
        // 相册入口：IMAGE_TYPE 可含 GIF；文件入口仍限定 .gif
        return ['GIF|.gif,.gifv'];
      case MediaPickMode.AUDIO:
        return ['音频|.mp3,.aac,.m4a,.wav,.flac,.ogg,.opus,.amr'];
      case MediaPickMode.SUBTITLE:
        return ['字幕|.srt,.vtt,.ass,.ssa'];
      default:
        return undefined;
    }
  }

  /** 从文件系统选择媒体；分类入口使用系统后缀过滤器。 */
  static async pickDocuments(maxCount: number, mode: MediaPickMode = MediaPickMode.AUTO): Promise<PickedFile[]> {
    const docOptions = new picker.DocumentSelectOptions();
    docOptions.maxSelectNumber = maxCount;
    const filters = MediaPickerService.suffixFilters(mode);
    if (filters !== undefined) {
      docOptions.fileSuffixFilters = filters;
    }
    const fileUris = await new picker.DocumentViewPicker().select(docOptions);
    return fileUris.map((uri: string): PickedFile => {
      const path = uri.substring(uri.lastIndexOf('/') + 1);
      const name = decodeURIComponent(path);
      const inferred = guessMediaType(name);
      return { uri: uri, displayName: name,
        mediaTypeHint: inferred === MediaType.UNKNOWN ? undefined : inferred };
    });
  }
}
