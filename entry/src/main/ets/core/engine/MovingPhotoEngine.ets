/** API 24 Media Library Kit 动态照片资源导出。 */
import { common } from '@kit.AbilityKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { dataSharePredicates } from '@kit.ArkData';
import { fileIo, fileUri } from '@kit.CoreFileKit';
import { image } from '@kit.ImageKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { DeviceSupport } from '../capability/DeviceSupport';

const TAG = 'MovingPhoto';
const DOMAIN = 0x4D42;

export interface MovingPhotoParts {
  imagePath: string;
  videoPath: string;
}

/**
 * Media Library NAPI 回调会以「裸函数」方式调用 onDataPrepared，
 * 实例方法里的 this 可能为 undefined（真机 crash：resolveValue of undefined）。
 * 因此在构造器里把回调赋成闭包，不依赖 this；空数据立刻 onError，避免 Promise 悬挂。
 */
class MovingPhotoHandler implements photoAccessHelper.MediaAssetDataHandler<photoAccessHelper.MovingPhoto> {
  onDataPrepared: (data: photoAccessHelper.MovingPhoto) => void;

  constructor(onData: (data: photoAccessHelper.MovingPhoto) => void, onError: (message: string) => void) {
    this.onDataPrepared = (data: photoAccessHelper.MovingPhoto): void => {
      if (data === undefined || data === null) {
        hilog.warn(DOMAIN, TAG, 'onDataPrepared got empty MovingPhoto');
        onError('动态照片数据为空，请从图库重新选择');
        return;
      }
      onData(data);
    };
  }
}

export class MovingPhotoEngine {
  /**
   * 将任意 Image Kit 可解码图片标准化为 JPEG，并与 MP4 一起保存为系统动态照片。
   * 调用方必须位于 SaveButton 成功回调内，使用安全控件授予的临时写入权限。
   */
  static async createInMediaLibrary(context: common.UIAbilityContext, imageUri: string, videoUri: string,
    title: string): Promise<string> {
    if (!DeviceSupport.movingPhoto().canCreateMovingPhoto) {
      throw new Error(DeviceSupport.movingPhoto().reason ?? '当前设备不支持创建动态照片');
    }
    const token = `${Date.now()}`;
    const imagePath = `${context.cacheDir}/moving_photo_create_${token}.jpg`;
    const videoPath = `${context.cacheDir}/moving_photo_create_${token}.mp4`;
    let sourceFile: fileIo.File | undefined = undefined;
    let targetFile: fileIo.File | undefined = undefined;
    let videoFile: fileIo.File | undefined = undefined;
    let source: image.ImageSource | undefined = undefined;
    let pixelMap: image.PixelMap | undefined = undefined;
    let packer: image.ImagePacker | undefined = undefined;
    try {
      sourceFile = fileIo.openSync(imageUri, fileIo.OpenMode.READ_ONLY);
      source = image.createImageSource(sourceFile.fd);
      pixelMap = await source.createPixelMap();
      packer = image.createImagePacker();
      targetFile = fileIo.openSync(imagePath,
        fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      await packer.packToFile(pixelMap, targetFile.fd, { format: 'image/jpeg', quality: 95 });
      fileIo.closeSync(targetFile);
      targetFile = undefined;

      videoFile = fileIo.openSync(videoUri, fileIo.OpenMode.READ_ONLY);
      try {
        const srcPath = videoUri.startsWith('file://') ? videoUri.substring(7) : videoUri;
        fileIo.copyFileSync(srcPath, videoPath);
      } catch (copyErr) {
        const buf = new ArrayBuffer(1024 * 256);
        const outFile = fileIo.openSync(videoPath, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE |
          fileIo.OpenMode.TRUNC);
        try {
          for (;;) {
            const n = fileIo.readSync(videoFile.fd, buf);
            if (n <= 0) {
              break;
            }
            fileIo.writeSync(outFile.fd, buf, { length: n });
          }
        } finally {
          fileIo.closeSync(outFile);
        }
      }
      fileIo.closeSync(videoFile);
      videoFile = undefined;

      const helper = photoAccessHelper.getPhotoAccessHelper(context);
      const request = photoAccessHelper.MediaAssetChangeRequest.createAssetRequest(context,
        photoAccessHelper.PhotoType.IMAGE, 'jpg', {
          title: title,
          subtype: photoAccessHelper.PhotoSubtype.MOVING_PHOTO
        });
      request.addResource(photoAccessHelper.ResourceType.IMAGE_RESOURCE, fileUri.getUriFromPath(imagePath));
      request.addResource(photoAccessHelper.ResourceType.VIDEO_RESOURCE, fileUri.getUriFromPath(videoPath));
      await helper.applyChanges(request);
      return request.getAsset().uri;
    } finally {
      try {
        if (sourceFile !== undefined) {
          fileIo.closeSync(sourceFile);
        }
        if (targetFile !== undefined) {
          fileIo.closeSync(targetFile);
        }
        if (videoFile !== undefined) {
          fileIo.closeSync(videoFile);
        }
      } catch (closeErr) {
        hilog.warn(DOMAIN, TAG, 'close fd failed %{public}s', (closeErr as Error).message);
      }
      try {
        if (pixelMap !== undefined) {
          await pixelMap.release();
        }
        if (source !== undefined) {
          await source.release();
        }
        if (packer !== undefined) {
          await packer.release();
        }
      } catch (releaseErr) {
        hilog.warn(DOMAIN, TAG, 'release image resources failed %{public}s', (releaseErr as Error).message);
      }
      try {
        if (fileIo.accessSync(imagePath)) {
          fileIo.unlinkSync(imagePath);
        }
        if (fileIo.accessSync(videoPath)) {
          fileIo.unlinkSync(videoPath);
        }
      } catch (cleanupErr) {
        hilog.warn(DOMAIN, TAG, 'cleanup temp failed %{public}s', (cleanupErr as Error).message);
      }
    }
  }

  static async exportParts(context: common.UIAbilityContext, sourceUri: string, taskId: string): Promise<MovingPhotoParts> {
    if (!DeviceSupport.movingPhoto().canExportMovingPhoto) {
      throw new Error(DeviceSupport.movingPhoto().reason ?? '当前设备无法导出动态照片资源');
    }
    const predicates = new dataSharePredicates.DataSharePredicates();
    predicates.equalTo(photoAccessHelper.PhotoKeys.URI, sourceUri);
    const helper = photoAccessHelper.getPhotoAccessHelper(context);
    let result: photoAccessHelper.FetchResult<photoAccessHelper.PhotoAsset>;
    try {
      result = await helper.getAssets({
        fetchColumns: [photoAccessHelper.PhotoKeys.URI],
        predicates: predicates
      });
    } catch (error) {
      const err = error as Error;
      throw new Error(`无法读取图库中的动态照片（${err.message}）。请从图库重新选择后重试`);
    }
    try {
      if (result.getCount() === 0) {
        throw new Error('所选资源不是可读取的动态照片，或未下载到本机');
      }
      const asset = await result.getFirstObject();
      // handler 必须持有到回调完成，避免被回收
      let handlerKeepAlive: MovingPhotoHandler | undefined = undefined;
      const movingPhoto = await new Promise<photoAccessHelper.MovingPhoto>((resolve, reject) => {
        const timeoutId = setTimeout(() => reject(new Error('读取动态照片超时，请确认资源已下载到本机')), 20000);
        const handler = new MovingPhotoHandler(
          (value: photoAccessHelper.MovingPhoto): void => {
            clearTimeout(timeoutId);
            resolve(value);
          },
          (message: string): void => {
            clearTimeout(timeoutId);
            reject(new Error(message));
          }
        );
        handlerKeepAlive = handler;
        // SDK：requestMovingPhoto 返回 Promise<string>（请求 ID），数据经 DataHandler 回调
        photoAccessHelper.MediaAssetManager.requestMovingPhoto(context, asset, {
          deliveryMode: photoAccessHelper.DeliveryMode.FAST_MODE
        }, handler).then(() => {
          // 数据以 handler.onDataPrepared 为准
        }).catch((error: Error) => {
          clearTimeout(timeoutId);
          reject(new Error(`读取动态照片失败：${error.message}`));
        });
      });
      // 置空仅表示不再主动引用；movingPhoto 已持有数据
      handlerKeepAlive = undefined;
      const outputDir = `${context.filesDir}/outputs`;
      if (!fileIo.accessSync(outputDir)) {
        fileIo.mkdirSync(outputDir);
      }
      const imagePath = `${outputDir}/moving_photo_${taskId}.jpg`;
      const videoPath = `${outputDir}/moving_photo_${taskId}.mp4`;
      const createMode = fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC;
      const imageFile = fileIo.openSync(imagePath, createMode);
      fileIo.closeSync(imageFile);
      const videoFile = fileIo.openSync(videoPath, createMode);
      fileIo.closeSync(videoFile);
      try {
        await movingPhoto.requestContent(fileUri.getUriFromPath(imagePath), fileUri.getUriFromPath(videoPath));
      } catch (contentErr) {
        const err = contentErr as Error;
        throw new Error(`动态照片资源写出失败：${err.message}`);
      }
      const imageOk = fileIo.accessSync(imagePath) && fileIo.statSync(imagePath).size > 0;
      const videoOk = fileIo.accessSync(videoPath) && fileIo.statSync(videoPath).size > 0;
      if (!imageOk) {
        throw new Error('动态照片图片资源导出失败');
      }
      if (!videoOk) {
        throw new Error('动态照片视频资源导出失败');
      }
      return { imagePath: imagePath, videoPath: videoPath };
    } finally {
      try {
        result.close();
      } catch (e) {
        // close 失败不掩盖主错误
      }
    }
  }
}
