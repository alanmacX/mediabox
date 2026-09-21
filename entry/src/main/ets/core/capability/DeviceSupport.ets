/**
 * 设备能力门控 — 过滤当前设备/系统实际不支持的类型与操作。
 *
 * 原则：
 * 1. 不猜：只用 canIUse + 运行时 SDK 返回值。
 * 2. 不可用就不展示，或明确置灰并给出原因。
 * 3. 动态照片依赖 Media Library Kit 的 MediaAssetManager 与 PhotoViewPicker 徽章能力。
 */
import { image } from '@kit.ImageKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG = 'DeviceSupport';
const DOMAIN = 0x4D42;

const PHOTO_CORE = 'SystemCapability.FileManagement.PhotoAccessHelper.Core';
const IMAGE_SOURCE = 'SystemCapability.Multimedia.Image.ImageSource';
const IMAGE_PACKER = 'SystemCapability.Multimedia.Image.ImagePacker';
const AV_TRANSCODER = 'SystemCapability.Multimedia.Media.AVTranscoder';
const DRAWING = 'SystemCapability.Graphics.Drawing';

export interface MovingPhotoSupport {
  /** 系统是否具备 Media Library Kit 基础能力。 */
  available: boolean;
  /** PhotoViewPicker 是否能请求动态照片 MIME（API 12+）。 */
  canPickMovingPhoto: boolean;
  /** 是否能通过 MediaAssetManager 导出动态照片资源（API 18+）。 */
  canExportMovingPhoto: boolean;
  /** 是否能通过 SaveButton 创建动态照片（API 12+ PhotoSubtype）。 */
  canCreateMovingPhoto: boolean;
  /** 不可用时的短原因。 */
  reason?: string;
}

export interface ImageEncodeSupport {
  jpeg: boolean;
  png: boolean;
  webp: boolean;
  heif: boolean;
  avif: boolean;
  /** 设备返回的完整 MIME 集合，便于诊断。 */
  formats: string[];
}

let movingPhotoCache: MovingPhotoSupport | undefined = undefined;
let imageEncodeCache: ImageEncodeSupport | undefined = undefined;

function safeCanIUse(cap: string): boolean {
  try {
    return canIUse(cap);
  } catch (e) {
    hilog.warn(DOMAIN, TAG, 'canIUse failed for %{public}s', cap);
    return false;
  }
}

export class DeviceSupport {
  static photoLibraryAvailable(): boolean {
    return safeCanIUse(PHOTO_CORE);
  }

  static avTranscoderAvailable(): boolean {
    return safeCanIUse(AV_TRANSCODER);
  }

  static imageCodecAvailable(): boolean {
    return safeCanIUse(IMAGE_SOURCE) && safeCanIUse(IMAGE_PACKER);
  }

  static drawingAvailable(): boolean {
    return safeCanIUse(DRAWING);
  }

  /**
   * 动态照片能力探测。
   * - 无 PhotoAccessHelper：整体不可用。
   * - 枚举/类型存在但设备固件过旧时，API 调用会失败；此处先做静态能力判断，
   *   运行时再由 MovingPhotoEngine 抛出明确错误。
   */
  static movingPhoto(): MovingPhotoSupport {
    if (movingPhotoCache !== undefined) {
      return movingPhotoCache;
    }
    if (!DeviceSupport.photoLibraryAvailable()) {
      movingPhotoCache = {
        available: false,
        canPickMovingPhoto: false,
        canExportMovingPhoto: false,
        canCreateMovingPhoto: false,
        reason: '当前设备不支持媒体库动态照片'
      };
      return movingPhotoCache;
    }
    let canPick = false;
    let canExport = false;
    let canCreate = false;
    try {
      // MOVING_PHOTO_IMAGE_TYPE 自 API 12 提供。
      const mime = photoAccessHelper.PhotoViewMIMETypes.MOVING_PHOTO_IMAGE_TYPE;
      canPick = mime !== undefined && `${mime}`.length > 0;
    } catch (e) {
      canPick = false;
    }
    try {
      // MediaAssetManager.requestMovingPhoto 自 API 18 提供。
      const manager = photoAccessHelper.MediaAssetManager;
      canExport = manager !== undefined && typeof manager.requestMovingPhoto === 'function';
    } catch (e) {
      canExport = false;
    }
    try {
      const subtype = photoAccessHelper.PhotoSubtype.MOVING_PHOTO;
      const creator = photoAccessHelper.MediaAssetChangeRequest;
      canCreate = subtype !== undefined && creator !== undefined &&
        typeof creator.createAssetRequest === 'function';
    } catch (e) {
      canCreate = false;
    }
    const available = canPick && (canExport || canCreate);
    movingPhotoCache = {
      available: available,
      canPickMovingPhoto: canPick,
      canExportMovingPhoto: canExport,
      canCreateMovingPhoto: canCreate,
      reason: available ? undefined :
        (!canPick ? '系统选择器不支持动态照片' : '系统缺少动态照片读写接口')
    };
    return movingPhotoCache;
  }

  static imageEncode(): ImageEncodeSupport {
    if (imageEncodeCache !== undefined) {
      return imageEncodeCache;
    }
    if (!DeviceSupport.imageCodecAvailable()) {
      imageEncodeCache = { jpeg: false, png: false, webp: false, heif: false, avif: false, formats: [] };
      return imageEncodeCache;
    }
    let formats: string[] = [];
    try {
      formats = image.getImagePackerSupportedFormats();
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'getImagePackerSupportedFormats failed');
      formats = [];
    }
    const has = (mime: string): boolean => formats.includes(mime);
    imageEncodeCache = {
      jpeg: has('image/jpeg') || has('image/jpg'),
      png: has('image/png'),
      webp: has('image/webp'),
      heif: has('image/heif') || has('image/heic'),
      avif: has('image/avif') || has('image/avif-sequence'),
      formats: formats
    };
    hilog.info(DOMAIN, TAG, 'image encode formats %{public}s', JSON.stringify(formats));
    return imageEncodeCache;
  }

  static clearCache(): void {
    movingPhotoCache = undefined;
    imageEncodeCache = undefined;
  }
}
