/**
 * HarmonyOS 原生引擎 — Hardware First。
 *
 * 常见 H.264/H.265 转码 / 智能压缩 / 指定大小压缩走 AVTranscoder,
 * 由系统按设备 Codec capability 执行:更低功耗、更快速度、更好的整机集成。
 * FFmpeg 接入后仅承担冷门格式与高级操作(见 docs/ARCHITECTURE.md)。
 *
 * 实现严格对照官方 AVTranscoder 指南:
 *   createAVTranscoder → fdSrc/fdDst → prepare → start,
 *   'complete'/'error'/'progressUpdate' 回调,结束前 release。
 */
import { media } from '@kit.MediaKit';
import { image } from '@kit.ImageKit';
import { fileIo } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { drawing } from '@kit.ArkGraphics2D';
import { MediaTask, TaskExecutor } from '../task/MediaTask';
import { FfmpegEngine } from './FfmpegEngine';
import { WatermarkRenderer } from './WatermarkRenderer';
import { TextOverlay } from './TextOverlay';
import { ImageComposition } from './ImageComposition';
import { MovingPhotoEngine } from './MovingPhotoEngine';

const TAG = 'NativeEngine';
const DOMAIN = 0x4D42;
const SUCCESS_RELEASE_WAIT_MS = 1200;

function safeDirName(name: string): string {
  const stem = name.lastIndexOf('.') > 0 ? name.substring(0, name.lastIndexOf('.')) : name;
  const cleaned = stem.replace(/[^0-9A-Za-z_-]/g, '_');
  return cleaned.length > 0 ? cleaned : 'output';
}

export class NativeEngineExecutor implements TaskExecutor {
  private nativeRejects: Map<string, (error: Error) => void> = new Map();
  private context: common.UIAbilityContext;
  private ffmpeg: FfmpegEngine;
  private nativeTasks: Map<string, media.AVTranscoder> = new Map();
  /** release 超时后仍在系统侧收尾的实例；系统最多允许同时存在两个 AVTranscoder。 */
  private pendingNativeReleases: Promise<void>[] = [];

  constructor(context: common.UIAbilityContext) {
    this.context = context;
    this.ffmpeg = new FfmpegEngine(context);
  }

  async execute(task: MediaTask, onProgress: (pct: number) => void): Promise<string> {
    if (task.actionId === 'image_stack_horizontal' || task.actionId === 'image_stack_vertical') {
      return ImageComposition.stack(this.context, task, onProgress);
    }
    if (task.actionId === 'ff_image_watermark') return this.processImage(task, onProgress);
    if (task.actionId === 'video_text') {
      return this.addVideoText(task, onProgress);
    }
    if (task.actionId === 'image_copy_metadata') {
      return this.copyImageMetadata(task, onProgress);
    }
    if (task.actionId === 'image_metadata_edit') {
      return this.editImageMetadata(task, onProgress);
    }
    if (task.actionId.startsWith('moving_photo_')) {
      try {
        onProgress(5);
        const parts = await MovingPhotoEngine.exportParts(this.context, task.sourceUri, task.id);
        onProgress(70);
        if (task.actionId === 'moving_photo_image') {
          onProgress(100);
          return parts.imagePath;
        }
        if (task.actionId === 'moving_photo_video') {
          onProgress(100);
          return parts.videoPath;
        }
        const gifTask = new MediaTask(task.id, parts.videoPath, task.displayName, 'to_gif', task.actionTitle, {
          startTime: '00:00:00', durationSeconds: '10', targetFps: 12, targetWidth: 480, loopCount: '0'
        }, task.createdAt);
        return await this.ffmpeg.execute(gifTask, onProgress);
      } catch (e) {
        const msg = (e as Error).message;
        hilog.error(DOMAIN, TAG, 'moving photo failed %{public}s', msg);
        throw new Error(msg.length > 0 ? msg : '动态照片导出失败，请从图库重新选择');
      }
    }
    if (task.actionId === 'image_to_avif') {
      // 设备 Image Kit 原生 AVIF；否则走 FFmpeg libaom
      try {
        return await this.processImage(task, onProgress);
      } catch (e) {
        return await this.ffmpeg.execute(task, onProgress);
      }
    }
    if (task.actionId.startsWith('image_')) {
      return this.processImage(task, onProgress);
    }
    if (task.actionId === 'remux_mp4' || task.actionId === 'to_gif' || task.actionId === 'extract_audio' ||
      task.actionId === 'extract_audio_mp3' || task.actionId === 'video_merge' || task.actionId === 'audio_merge' || task.actionId === 'images_to_video' ||
      task.actionId === 'replace_audio' ||
      task.actionId === 'images_to_gif' || task.actionId.startsWith('ff_image_') ||
      task.actionId === 'metadata_export' || task.actionId === 'metadata_edit' || task.actionId === 'metadata_cover' ||
      task.actionId === 'video_watermark' ||
      task.actionId.startsWith('video_') || task.actionId.startsWith('gif_') ||
      task.actionId.startsWith('audio_') || task.actionId.startsWith('subtitle_') ||
      task.actionId.startsWith('stream_') || task.actionId === 'image_audio_video') {
      return this.ffmpeg.execute(task, onProgress);
    }
    if (!canIUse('SystemCapability.Multimedia.Media.AVTranscoder')) {
      throw new Error('当前设备不支持 AVTranscoder');
    }
    const isVideo = task.params.targetVideoKbps !== undefined || task.params.targetWidth !== undefined;
    if (!isVideo) {
      throw new Error(`NativeEngine 不支持该操作: ${task.actionId}`);
    }
    return this.transcode(task, onProgress);
  }

  /**
   * 当前 FFmpeg 构建没有 drawtext/freetype。这里用 API 24 Image Kit 与
   * ArkGraphics2D 生成透明 PNG，再复用视频水印管线完成文字叠加。
   */
  private async addVideoText(task: MediaTask, onProgress: (pct: number) => void): Promise<string> {
    const value = (task.params.textOverlay ?? '').trim();
    if (value.length === 0) {
      throw new Error('请输入要添加到视频的文字');
    }
    const width = task.params.textCanvasWidth ?? 1280;
    const height = task.params.textCanvasHeight ?? 720;
    if (width * height > 16_000_000) throw new Error('文字图层尺寸过大，请先缩小视频');
    const pixels = new ArrayBuffer(width * height * 4);
    const pixelMap = await image.createPixelMap(pixels, {
      size: { width: width, height: height },
      pixelFormat: image.PixelMapFormat.RGBA_8888,
      editable: true,
      alphaType: image.AlphaType.PREMUL
    });
    const packer = image.createImagePacker();
    const layerPath = `${this.context.cacheDir}/video_text_${task.id}.png`;
    let layerFile: fileIo.File | undefined = undefined;
    try {
      TextOverlay.draw(pixelMap, task.params);
      onProgress(15);

      layerFile = fileIo.openSync(layerPath,
        fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      await packer.packToFile(pixelMap, layerFile.fd, { format: 'image/png', quality: 100 });
      fileIo.closeSync(layerFile);
      layerFile = undefined;
      onProgress(25);

      const overlayTask = new MediaTask(task.id, task.sourceUri, task.displayName, 'video_watermark',
        task.actionTitle, {
          additionalSourceUris: [layerPath],
          additionalDisplayNames: ['text_overlay.png'],
          watermarkWidth: width, watermarkX: 0, watermarkY: 0, targetVideoKbps: task.params.targetVideoKbps
        }, task.createdAt);
      return await this.ffmpeg.execute(overlayTask, (pct: number): void => {
        onProgress(25 + Math.round(pct * 0.75));
      });
    } finally {
      if (layerFile !== undefined) {
        fileIo.closeSync(layerFile);
      }
      await pixelMap.release();
      await packer.release();
      if (fileIo.accessSync(layerPath)) {
        fileIo.unlinkSync(layerPath);
      }
    }
  }

  private async copyImageMetadata(task: MediaTask, onProgress: (pct: number) => void): Promise<string> {
    const targetUri = task.params.additionalSourceUris?.[0];
    const targetName = task.params.additionalDisplayNames?.[0] ?? 'target.jpg';
    if (targetUri === undefined) {
      throw new Error('缺少要写入元数据的目标图片');
    }
    const dot = targetName.lastIndexOf('.');
    const extension = dot >= 0 ? targetName.substring(dot + 1).replace(/[^0-9A-Za-z]/g, '') : 'jpg';
    const outputDir = `${this.context.filesDir}/outputs`;
    if (!fileIo.accessSync(outputDir)) {
      fileIo.mkdirSync(outputDir);
    }
    const outPath = `${outputDir}/${safeDirName(targetName)}_${task.id}.${extension}`;
    const targetFile = fileIo.openSync(targetUri, fileIo.OpenMode.READ_ONLY);
    try {
      fileIo.copyFileSync(targetFile.fd, outPath);
    } finally {
      fileIo.closeSync(targetFile);
    }
    onProgress(25);
    const sourceFile = fileIo.openSync(task.sourceUri, fileIo.OpenMode.READ_ONLY);
    const outputFile = fileIo.openSync(outPath, fileIo.OpenMode.READ_WRITE);
    const source = image.createImageSource(sourceFile.fd);
    const output = image.createImageSource(outputFile.fd);
    const keys: image.PropertyKey[] = [image.PropertyKey.DATE_TIME_ORIGINAL, image.PropertyKey.ORIENTATION,
      image.PropertyKey.GPS_LATITUDE, image.PropertyKey.GPS_LONGITUDE, image.PropertyKey.GPS_LATITUDE_REF,
      image.PropertyKey.GPS_LONGITUDE_REF, image.PropertyKey.EXPOSURE_TIME, image.PropertyKey.ISO_SPEED_RATINGS,
      image.PropertyKey.F_NUMBER];
    try {
      for (let i = 0; i < keys.length; i++) {
        try {
          const value = await source.getImageProperty(keys[i]);
          if (value.length > 0) {
            await output.modifyImageProperty(keys[i], value);
          }
        } catch (e) {
          // 源或目标格式不支持该字段时跳过单个属性，继续复制其余 EXIF。
        }
        onProgress(25 + Math.round((i + 1) / keys.length * 75));
      }
      return outPath;
    } finally {
      await source.release();
      await output.release();
      fileIo.closeSync(sourceFile);
      fileIo.closeSync(outputFile);
    }
  }

  private async editImageMetadata(task: MediaTask, onProgress: (pct: number) => void): Promise<string> {
    const dot = task.displayName.lastIndexOf('.');
    const extension = dot >= 0 ? task.displayName.substring(dot + 1).replace(/[^0-9A-Za-z]/g, '') : 'jpg';
    const outputDir = `${this.context.filesDir}/outputs`;
    if (!fileIo.accessSync(outputDir)) {
      fileIo.mkdirSync(outputDir);
    }
    const outPath = `${outputDir}/${safeDirName(task.displayName)}_${task.id}.${extension}`;
    const sourceFile = fileIo.openSync(task.sourceUri, fileIo.OpenMode.READ_ONLY);
    try {
      fileIo.copyFileSync(sourceFile.fd, outPath);
    } finally {
      fileIo.closeSync(sourceFile);
    }
    onProgress(25);
    const outputFile = fileIo.openSync(outPath, fileIo.OpenMode.READ_WRITE);
    const output = image.createImageSource(outputFile.fd);
    const keys: image.PropertyKey[] = [image.PropertyKey.IMAGE_DESCRIPTION, image.PropertyKey.ARTIST,
      image.PropertyKey.DATE_TIME_ORIGINAL];
    const values: string[] = [task.params.metadataTitle ?? '', task.params.metadataArtist ?? '',
      task.params.metadataCreationTime ?? ''];
    try {
      for (let i = 0; i < keys.length; i++) {
        await output.modifyImageProperty(keys[i], values[i]);
        onProgress(25 + Math.round((i + 1) / keys.length * 75));
      }
      return outPath;
    } finally {
      await output.release();
      fileIo.closeSync(outputFile);
    }
  }

  cancel(taskId: string): boolean {
    if (this.ffmpeg.cancel(taskId)) {
      return true;
    }
    const transcoder = this.nativeTasks.get(taskId);
    if (transcoder === undefined) {
      return false;
    }
    transcoder.cancel().then(() => {
      this.nativeRejects.get(taskId)?.(new Error('任务已取消'));
    }).catch((e: Error) => {
      this.nativeRejects.get(taskId)?.(e);
    });
    return true;
  }

  /**
   * Image Kit 原生图片管线：ImageSource 解码，PixelMap 按需缩放，ImagePacker 重新编码落盘。
   * packToFile、desiredSize、quality 的签名均按 API 24 SDK 声明使用。
   */
  private async processImage(task: MediaTask, onProgress: (pct: number) => void): Promise<string> {
    if (!canIUse('SystemCapability.Multimedia.Image.ImageSource') ||
      !canIUse('SystemCapability.Multimedia.Image.ImagePacker')) {
      throw new Error('当前设备不支持 Image Kit 编解码');
    }
    const srcFile = fileIo.openSync(task.sourceUri, fileIo.OpenMode.READ_ONLY);
    const source = image.createImageSource(srcFile.fd);
    const packer = image.createImagePacker();
    let pixelMap: image.PixelMap | undefined = undefined;
    let dstFile: fileIo.File | undefined = undefined;
    try {
      onProgress(10);
      const needsAlphaFlatten = (task.params.imageFormat ?? 'image/jpeg') === 'image/jpeg';
      const needsTransform = task.params.imageRotateDegrees !== undefined ||
        task.params.imageFlipHorizontal !== undefined || task.params.imageFlipVertical !== undefined ||
        task.params.cropWidth !== undefined || task.params.textOverlay !== undefined || needsAlphaFlatten ||
        task.actionId === 'ff_image_watermark';
      const options: image.DecodingOptions = { editable: needsTransform };
      if (needsAlphaFlatten) {
        options.desiredPixelFormat = image.PixelMapFormat.RGBA_8888;
      }
      if (task.params.targetWidth !== undefined && task.params.targetHeight !== undefined) {
        if (task.actionId === 'image_resize') {
          // “长边上限”必须等比缩放且不放大小图，不能把所有图片强制拉伸成正方形。
          const sourceInfo = await source.getImageInfo();
          const scale = Math.min(1, task.params.targetWidth / sourceInfo.size.width,
            task.params.targetHeight / sourceInfo.size.height);
          options.desiredSize = {
            width: Math.max(1, Math.round(sourceInfo.size.width * scale)),
            height: Math.max(1, Math.round(sourceInfo.size.height * scale))
          };
        } else {
          options.desiredSize = {
            width: task.params.targetWidth,
            height: task.params.targetHeight
          };
        }
      }
      hilog.info(DOMAIN, TAG, 'img-pipeline decode start editable=%{public}d fmt=%{public}d',
        needsTransform ? 1 : 0, options.desiredPixelFormat ?? -1);
      pixelMap = await source.createPixelMap(options);
      hilog.info(DOMAIN, TAG, 'img-pipeline decode done');
      onProgress(45);

      if (task.params.cropWidth !== undefined && task.params.cropHeight !== undefined) {
        await pixelMap.crop({
          x: task.params.cropX ?? 0,
          y: task.params.cropY ?? 0,
          size: { width: task.params.cropWidth, height: task.params.cropHeight }
        });
      }
      if (task.params.imageRotateDegrees !== undefined) {
        await pixelMap.rotate(task.params.imageRotateDegrees);
      }
      if (task.params.imageFlipHorizontal !== undefined || task.params.imageFlipVertical !== undefined) {
        await pixelMap.flip(task.params.imageFlipHorizontal ?? false, task.params.imageFlipVertical ?? false);
      }
      if (task.params.textOverlay !== undefined && task.params.textOverlay.length > 0) {
        TextOverlay.draw(pixelMap, task.params);
      }
      if (task.actionId === 'ff_image_watermark') {
        const uri = task.params.additionalSourceUris?.[0];
        if (!uri) throw new Error('请选择水印图片');
        await WatermarkRenderer.draw(pixelMap, uri, task.params);
      }
      if (needsAlphaFlatten) {
        await this.flattenAlpha(pixelMap, task.params.imageBackgroundColor ?? '#FFFFFF');
      }
      onProgress(70);

      const format = task.params.imageFormat ?? 'image/jpeg';
      const extension = format === 'image/png' ? 'png' : (format === 'image/webp' ? 'webp' :
        (format === 'image/heif' ? 'heif' : (format === 'image/avif' ? 'avif' : 'jpg')));
      const outputDir = `${this.context.filesDir}/outputs`;
      if (!fileIo.accessSync(outputDir)) {
        fileIo.mkdirSync(outputDir);
      }
      const outPath = `${outputDir}/${safeDirName(task.displayName)}_${task.id}.${extension}`;
      dstFile = fileIo.openSync(outPath, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      let quality = Math.min(100, Math.max(0, task.params.imageQuality ?? 90));
      if (task.params.targetBytes !== undefined && task.params.targetBytes > 0 && format !== 'image/png') {
        let low = 5;
        let high = 95;
        let best = low;
        while (low <= high) {
          const probe = Math.floor((low + high) / 2);
          const encoded = await packer.packToData(pixelMap, { format: format, quality: probe });
          if (encoded.byteLength <= task.params.targetBytes) {
            best = probe;
            low = probe + 1;
          } else {
            high = probe - 1;
          }
          onProgress(Math.min(92, 70 + Math.round((95 - Math.max(0, high - low)) / 90 * 20)));
        }
        quality = best;
      }
      const packOptions: image.PackingOption = {
        format: format,
        quality: quality
      };
      await packer.packToFile(pixelMap, dstFile.fd, packOptions);
      if (task.params.targetBytes !== undefined && fileIo.statSync(dstFile.fd).size > task.params.targetBytes) {
        fileIo.unlinkSync(outPath);
        throw new Error('最低图片质量仍超过目标体积，请先缩小分辨率或提高目标大小');
      }
      onProgress(100);
      return outPath;
    } finally {
      if (pixelMap !== undefined) {
        await pixelMap.release();
      }
      await source.release();
      await packer.release();
      fileIo.closeSync(srcFile);
      if (dstFile !== undefined) {
        fileIo.closeSync(dstFile);
      }
    }
  }

  private async flattenAlpha(pixelMap: image.PixelMap, colorText: string): Promise<void> {
    const info = await pixelMap.getImageInfo();
    if (info.pixelFormat !== image.PixelMapFormat.RGBA_8888 || info.alphaType === image.AlphaType.OPAQUE) {
      return;
    }
    const match = /^#?([0-9A-Fa-f]{6})$/.exec(colorText.trim());
    const value = match === null ? 0xFFFFFF : Number.parseInt(match[1], 16);
    const backgroundR = (value >> 16) & 0xFF;
    const backgroundG = (value >> 8) & 0xFF;
    const backgroundB = value & 0xFF;
    const bytes = new ArrayBuffer(info.stride * info.size.height);
    await pixelMap.readPixelsToBuffer(bytes);
    const pixels = new Uint8Array(bytes);
    for (let y = 0; y < info.size.height; y++) {
      const row = y * info.stride;
      for (let x = 0; x < info.size.width; x++) {
        const offset = row + x * 4;
        const alpha = pixels[offset + 3];
        if (alpha < 255) {
          const inverse = 255 - alpha;
          if (info.alphaType === image.AlphaType.PREMUL) {
            pixels[offset] = Math.min(255, pixels[offset] + Math.round(backgroundR * inverse / 255));
            pixels[offset + 1] = Math.min(255, pixels[offset + 1] + Math.round(backgroundG * inverse / 255));
            pixels[offset + 2] = Math.min(255, pixels[offset + 2] + Math.round(backgroundB * inverse / 255));
          } else {
            pixels[offset] = Math.round((pixels[offset] * alpha + backgroundR * inverse) / 255);
            pixels[offset + 1] = Math.round((pixels[offset + 1] * alpha + backgroundG * inverse) / 255);
            pixels[offset + 2] = Math.round((pixels[offset + 2] * alpha + backgroundB * inverse) / 255);
          }
          pixels[offset + 3] = 255;
        }
      }
    }
    await pixelMap.writeBufferToPixels(bytes);
  }

  private async transcode(task: MediaTask, onProgress: (pct: number) => void): Promise<string> {
    // prepare/start 需要申请系统编解码资源；先反馈实际启动阶段，不能静止在 0%。
    onProgress(1);
    // 最多允许两个实例：若已有两个实例仍在 release，必须等至少一个真正退出，
    // 否则批量队列第三项会偶发 createAVTranscoder 失败。
    if (this.pendingNativeReleases.length >= 2) {
      await Promise.race(this.pendingNativeReleases);
    }
    const startedAt = Date.now();
    const transcoder = await media.createAVTranscoder();
    this.nativeTasks.set(task.id, transcoder);
    let dstFile: fileIo.File | undefined = undefined;
    let srcFile: fileIo.File | undefined = undefined;
    let outPath = '';
    let completedSuccessfully = false;
    const progressCallback = (progress: number): void => {
      const pct = Math.min(100, Math.max(0, Math.round(progress)));
      onProgress(pct);
    };
    try {
      const srcFd = fileIo.openSync(task.sourceUri, fileIo.OpenMode.READ_ONLY);
      srcFile = srcFd;
      try {
        const srcSize = fileIo.statSync(srcFd.fd).size;
        transcoder.fdSrc = { fd: srcFd.fd, offset: 0, length: srcSize };

        const outputDir = `${this.context.filesDir}/outputs`;
        if (!fileIo.accessSync(outputDir)) {
          fileIo.mkdirSync(outputDir);
        }
        outPath = `${outputDir}/${safeDirName(task.displayName)}_${task.id}.mp4`;
        dstFile = fileIo.openSync(outPath,
          fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);

        transcoder.fdDst = dstFile.fd;

        const config: media.AVTranscoderConfig = {
          fileFormat: media.ContainerFormatType.CFT_MPEG_4,
          videoCodec: task.params.targetVideoCodec === 'HEVC' ? media.CodecMimeType.VIDEO_HEVC :
            media.CodecMimeType.VIDEO_AVC,
          videoBitrate: (task.params.targetVideoKbps ?? 3000) * 1000
        };
        // AVTranscoder 的宽高可选；缺省时沿用源视频。批量压缩本来没有逐个分析宽高，
        // 旧代码却强塞 1920×1080，竖屏/小视频会在 prepare 阶段报 Output resolution is invalid。
        if (task.params.targetWidth !== undefined && task.params.targetHeight !== undefined) {
          config.videoFrameWidth = Math.min(3840, Math.max(240, Math.floor(task.params.targetWidth / 2) * 2));
          config.videoFrameHeight = Math.min(2160, Math.max(240, Math.floor(task.params.targetHeight / 2) * 2));
        }
        hilog.info(DOMAIN, TAG,
          'native prepare id=%{public}s size=%{public}s bitrate=%{public}d', task.id,
          config.videoFrameWidth !== undefined ? `${config.videoFrameWidth}x${config.videoFrameHeight}` : 'source',
          config.videoBitrate ?? 0);
        if (task.actionId === 'preset_balanced' || task.actionId === 'preset_small') {
          config.enableBFrame = true;
        }
        if (task.params.targetAudioKbps !== undefined) {
          config.audioCodec = media.CodecMimeType.AUDIO_AAC;
          config.audioBitrate = task.params.targetAudioKbps * 1000;
        }

        transcoder.on('progressUpdate', progressCallback);
        const complete = new Promise<void>((resolve, reject) => {
          this.nativeRejects.set(task.id, reject);
          transcoder.on('complete', () => {
            hilog.info(DOMAIN, TAG, 'native complete id=%{public}s encodeMs=%{public}d',
              task.id, Date.now() - startedAt);
            resolve();
          });
          transcoder.on('error', (err: BusinessError) => {
            hilog.error(DOMAIN, TAG, 'transcode error %{public}d %{public}s', err.code, err.message);
            reject(err);
          });
        });
        // Observe early errors while prepare/start are still pending.
        complete.catch(() => {});
        await transcoder.prepare(config);
        await transcoder.start();
        onProgress(2);
        await complete;
        if (task.params.targetBytes !== undefined && fileIo.statSync(dstFile.fd).size > task.params.targetBytes) {
          fileIo.unlinkSync(outPath);
          throw new Error('设备编码结果超过目标体积，请降低码率或提高目标大小');
        }
        onProgress(100);
        completedSuccessfully = true;
        return outPath;
      } finally {
        // Input descriptor remains valid until release completes.
      }
    } catch (e) {
      // prepare/start/encode 失败时不把残缺文件留在输出目录。
      if (outPath.length > 0) {
        try {
          if (fileIo.accessSync(outPath)) {
            fileIo.unlinkSync(outPath);
          }
        } catch (cleanupError) {
          hilog.warn(DOMAIN, TAG, 'cleanup failed %{public}s', (cleanupError as Error).message);
        }
      }
      throw e as Error;
    } finally {
      this.nativeTasks.delete(task.id);
      this.nativeRejects.delete(task.id);
      // 高频 progress 回调不应继续占用 ArkTS 队列并拖慢 release。
      try { transcoder.off('progressUpdate', progressCallback); } catch (e) {}
      try { transcoder.off('complete'); } catch (e) {}
      try { transcoder.off('error'); } catch (e) {}
      const releaseStartedAt = Date.now();
      const cleanup = transcoder.release().catch((e: Error): void => {
        hilog.warn(DOMAIN, TAG, 'release failed %{public}s', e.message);
      }).then((): void => {
        if (dstFile !== undefined) {
          fileIo.closeSync(dstFile);
          dstFile = undefined;
        }
        if (srcFile !== undefined) {
          fileIo.closeSync(srcFile);
          srcFile = undefined;
        }
        hilog.info(DOMAIN, TAG, 'native released id=%{public}s releaseMs=%{public}d',
          task.id, Date.now() - releaseStartedAt);
      });
      let tracked: Promise<void> = Promise.resolve();
      tracked = cleanup.then((): void => {
        this.pendingNativeReleases = this.pendingNativeReleases.filter((item: Promise<void>) => item !== tracked);
      });
      this.pendingNativeReleases.push(tracked);
      if (completedSuccessfully) {
        // complete 已表示输出完成。最多阻塞队列一个很短的资源回收窗口；某些设备
        // release 极慢时让它在后台安全收尾，fd 仍由 cleanup 在真正释放后关闭。
        await Promise.race([
          tracked,
          new Promise<void>((resolve: () => void) => setTimeout(resolve, SUCCESS_RELEASE_WAIT_MS))
        ]);
        if (this.pendingNativeReleases.indexOf(tracked) >= 0) {
          hilog.info(DOMAIN, TAG, 'native release deferred id=%{public}s afterMs=%{public}d',
            task.id, SUCCESS_RELEASE_WAIT_MS);
        }
      } else {
        // 失败/取消路径必须完整释放，避免残缺任务继续占用编解码器。
        await tracked;
      }
    }
  }

}
