/**
 * Media Analyzer — 所有功能的入口。
 *
 * 任何媒体文件先经过这里:
 *   Media File → Media Analyzer → AnalyzedMedia → CapabilityRouter → 推荐
 *
 * 实现:
 *  - 图片:Image Kit 的 image.createImageSource().getImageInfo()
 *  - 音视频:Media Kit 的 media.createAVMetadataExtractor()(fdSrc + fetchMetadata),
 *    编解码/码率/声道等轨道信息来自 meta.tracks(MediaDescription 键值对)
 *  - 视频缩略图:AVMetadataExtractor.fetchThumbnail()
 *
 * 依据官方指南核对过的约束:
 *  - 同一 fd 不要传给多个 AVMetadataExtractor / AVTranscoder 实例,每次分析单独 open。
 *  - fdSrc 模式分析结束后需关闭 fd。
 */
import { media } from '@kit.MediaKit';
import { image } from '@kit.ImageKit';
import { fileIo } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { util } from '@kit.ArkTS';
import { AnalyzedMedia, MediaType, VideoInfo, AudioInfo, MediaStreamInfo, MediaStreamKind,
  emptyAnalyzedMedia } from '../model/MediaTypes';
import { MediaThumb } from '../media/MediaThumb';

const TAG = 'MediaAnalyzer';
const DOMAIN = 0x4D42; // 'MB'

export interface PickedFile {
  uri: string;
  displayName: string;
  isMovingPhoto?: boolean;
  /** 分类入口或系统分享已知类型；仅在文件名无法可靠推断时使用。 */
  mediaTypeHint?: MediaType;
}

export interface AnalysisResult {
  media: AnalyzedMedia;
  thumbnail?: image.PixelMap;
}

function extOf(name: string): string {
  const idx = name.lastIndexOf('.');
  return idx >= 0 ? name.substring(idx + 1).toLowerCase() : '';
}

export function guessMediaType(name: string): MediaType {
  switch (extOf(name)) {
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

function containerOf(name: string): string {
  const ext = extOf(name);
  return ext.length > 0 ? ext.toUpperCase() : '';
}

function toNum(v?: string | number): number {
  if (v === undefined) {
    return 0;
  }
  const n = Number(v);
  return Number.isFinite(n) ? n : 0;
}

/**
 * MD_KEY_FRAME_RATE 偶发返回 ×100/×1000 的整数。
 * 只在值明显超出合理帧率时归一化，避免把真实高帧率误缩小。
 */
export function normalizeFps(raw: number): number {
  if (!Number.isFinite(raw) || raw <= 0) {
    return 0;
  }
  if (raw <= 240) {
    return raw;
  }
  const by100 = raw / 100;
  if (by100 >= 1 && by100 <= 240) {
    return by100;
  }
  const by1000 = raw / 1000;
  if (by1000 >= 1 && by1000 <= 240) {
    return by1000;
  }
  return 0;
}

/** MediaDescription 键值对值的安全提取(Uint8Array | string | number 联合类型)。 */
function descStr(track: media.MediaDescription, key: string): string {
  const v = track[key];
  if (typeof v === 'string') {
    return v;
  }
  if (typeof v === 'number') {
    return String(v);
  }
  return '';
}

function descNum(track: media.MediaDescription, key: string): number {
  const v = track[key];
  return typeof v === 'number' ? v : toNum(typeof v === 'string' ? v : undefined);
}

async function imageProperty(source: image.ImageSource, key: image.PropertyKey): Promise<string> {
  try {
    return await source.getImageProperty(key);
  } catch (e) {
    return '';
  }
}

/** mime → 展示名,如 video/hevc → HEVC(H.265) */
export function codecDisplayName(mime: string): string {
  const m = mime.toLowerCase();
  if (m.includes('avc') || m.includes('h264')) {
    return 'H.264 / AVC';
  }
  if (m.includes('hevc') || m.includes('h265') || m.includes('hvc1')) {
    return 'HEVC / H.265';
  }
  if (m.includes('av1')) {
    return 'AV1';
  }
  if (m.includes('vp9')) {
    return 'VP9';
  }
  if (m.includes('mp4a') || m.includes('aac')) {
    return 'AAC';
  }
  if (m.includes('mpeg') && m.includes('audio')) {
    return 'MP3';
  }
  if (m.includes('flac')) {
    return 'FLAC';
  }
  if (m.includes('opus')) {
    return 'Opus';
  }
  if (m.includes('vorbis')) {
    return 'Vorbis';
  }
  if (m.includes('amr')) {
    return 'AMR';
  }
  return mime;
}

export class MediaAnalyzer {
  /**
   * 文件名无法判断时读取实际内容。Image Kit 会识别图片 MIME，Media Kit 会给出音视频轨道；
   * 最后只对具有明确时间轴标记的 UTF-8 文本判为字幕，避免把任意文本当作媒体。
   */
  static async detectMediaType(picked: PickedFile): Promise<MediaType> {
    const hinted = picked.mediaTypeHint ?? guessMediaType(picked.displayName);
    if (hinted !== MediaType.UNKNOWN) {
      return hinted;
    }

    let source: image.ImageSource | undefined = undefined;
    try {
      source = image.createImageSource(picked.uri);
      const imageInfo = await source.getImageInfo();
      return imageInfo.mimeType.toLowerCase().includes('gif') ? MediaType.GIF : MediaType.IMAGE;
    } catch (e) {
      hilog.info(DOMAIN, TAG, 'not an image: %{public}s', picked.displayName);
    } finally {
      if (source !== undefined) {
        try {
          await source.release();
        } catch (e) {
          hilog.warn(DOMAIN, TAG, 'image source release failed');
        }
      }
    }

    let file: fileIo.File | undefined = undefined;
    let extractor: media.AVMetadataExtractor | undefined = undefined;
    try {
      file = fileIo.openSync(picked.uri, fileIo.OpenMode.READ_ONLY);
      extractor = await media.createAVMetadataExtractor();
      const fileSize = fileIo.statSync(file.fd).size;
      extractor.fdSrc = { fd: file.fd, offset: 0, length: fileSize };
      const metadata = await extractor.fetchMetadata();
      let hasAudio = false;
      for (const track of metadata.tracks ?? []) {
        const trackType = descNum(track, media.MediaDescriptionKey.MD_KEY_TRACK_TYPE);
        if (trackType === media.MediaType.MEDIA_TYPE_VID) {
          return MediaType.VIDEO;
        }
        if (trackType === media.MediaType.MEDIA_TYPE_AUD) {
          hasAudio = true;
        }
      }
      if (hasAudio) {
        return MediaType.AUDIO;
      }
    } catch (e) {
      hilog.info(DOMAIN, TAG, 'not an AV container: %{public}s', picked.displayName);
    } finally {
      try {
        if (extractor !== undefined) {
          try {
            await extractor.release();
          } catch (e) {
            hilog.warn(DOMAIN, TAG, 'metadata extractor release failed');
          }
        }
      } finally {
        if (file !== undefined) {
          try {
            fileIo.closeSync(file);
          } catch (e) {
            hilog.warn(DOMAIN, TAG, 'media file close failed');
          }
        }
      }
    }

    file = undefined;
    try {
      file = fileIo.openSync(picked.uri, fileIo.OpenMode.READ_ONLY);
      const length = Math.min(8192, fileIo.statSync(file.fd).size);
      const buffer = new ArrayBuffer(length);
      const bytesRead = fileIo.readSync(file.fd, buffer, { length: length });
      const text = util.TextDecoder.create('utf-8', { fatal: true, ignoreBOM: true })
        .decodeToString(new Uint8Array(buffer, 0, bytesRead));
      if (text.includes('-->') || text.includes('[Script Info]') || text.includes('[Events]')) {
        return MediaType.SUBTITLE;
      }
    } catch (e) {
      hilog.info(DOMAIN, TAG, 'not a supported subtitle: %{public}s', picked.displayName);
    } finally {
      if (file !== undefined) {
        try {
          fileIo.closeSync(file);
        } catch (e) {
          hilog.warn(DOMAIN, TAG, 'subtitle file close failed');
        }
      }
    }
    return MediaType.UNKNOWN;
  }

  /**
   * 分析一个已选中的媒体文件。
   * uri 需为应用可读的 URI(PhotoViewPicker 返回的 photoUris 具有永久授权,可直接 fileIo 打开)。
   */
  static async analyze(picked: PickedFile, wantThumbnail: boolean = true): Promise<AnalysisResult> {
    const type = await MediaAnalyzer.detectMediaType(picked);
    let info = emptyAnalyzedMedia(picked.uri, picked.displayName);
    info.mediaType = type;
    info.isMovingPhoto = picked.isMovingPhoto ?? false;
    info.container = containerOf(picked.displayName);
    info.sizeBytes = await MediaAnalyzer.statSize(picked.uri);

    let thumbnail: image.PixelMap | undefined = undefined;
    try {
      if (type === MediaType.IMAGE || type === MediaType.GIF) {
        info = await MediaAnalyzer.analyzeImage(info);
        if (wantThumbnail) {
          thumbnail = await MediaThumb.load(info);
        }
      } else if (type === MediaType.VIDEO || type === MediaType.AUDIO) {
        // 音频不请求画面缩略图
        const r = await MediaAnalyzer.analyzeAV(info, wantThumbnail && type === MediaType.VIDEO);
        info = r.media;
        thumbnail = r.thumbnail;
      }
    } catch (e) {
      info.analysisNote = `部分信息读取失败：${(e as Error).message}`;
      hilog.error(DOMAIN, TAG, 'analyze failed: %{public}s', JSON.stringify(e));
    }
    // 动态照片：无论 MIME 判成图片还是视频，预览一律用系统关键帧
    if (thumbnail === undefined && info.isMovingPhoto && wantThumbnail) {
      try {
        thumbnail = await MediaThumb.loadMovingPhotoKeyframe(info.uri);
      } catch (mpErr) {
        hilog.warn(DOMAIN, TAG, 'moving photo keyframe failed: %{public}s', (mpErr as Error).message);
      }
    }
    info.hasThumbnail = thumbnail !== undefined;
    return { media: info, thumbnail: thumbnail };
  }

  private static async statSize(uri: string): Promise<number> {
    try {
      const stat = fileIo.statSync(uri);
      return stat.size;
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'stat failed %{public}s', JSON.stringify(e));
      return 0;
    }
  }

  private static async analyzeImage(info: AnalyzedMedia): Promise<AnalyzedMedia> {
    const file = await fileIo.open(info.uri, fileIo.OpenMode.READ_ONLY);
    const source = image.createImageSource(file.fd);
    try {
      const imgInfo = await source.getImageInfo();
      info.mimeType = imgInfo.mimeType;
      info.imageWidth = imgInfo.size.width;
      info.imageHeight = imgInfo.size.height;
      info.imageHdr = imgInfo.isHdr;
      info.rawMetadata = JSON.stringify(imgInfo, null, 2);
      const details: string[] = [];
      const keys: image.PropertyKey[] = [image.PropertyKey.MAKE, image.PropertyKey.MODEL,
        image.PropertyKey.LENS_MAKE, image.PropertyKey.LENS_MODEL, image.PropertyKey.FOCAL_LENGTH,
        image.PropertyKey.WHITE_BALANCE, image.PropertyKey.COLOR_SPACE];
      const labels = ['设备厂商', '相机型号', '镜头厂商', '镜头型号', '焦距', '白平衡', '色彩空间'];
      for (let i = 0; i < keys.length; i++) {
        const value = await imageProperty(source, keys[i]);
        if (value.length > 0) details.push(`${labels[i]}：${value}`);
      }
      info.imageDetails = details.join('\n');
      if (info.mediaType === MediaType.GIF) {
        try {
          info.imageFrameCount = await source.getFrameCount();
          const delays = await source.getDelayTimeList();
          info.durationMs = delays.reduce((sum: number, delay: number) => sum + Math.max(0, delay), 0);
        } catch (e) {
          info.imageFrameCount = 0;
        }
      }
      info.imageBitsPerSample = await imageProperty(source, image.PropertyKey.BITS_PER_SAMPLE);
      info.imageOrientation = await imageProperty(source, image.PropertyKey.ORIENTATION);
      info.imageDateTaken = await imageProperty(source, image.PropertyKey.DATE_TIME_ORIGINAL);
      info.imageExposure = await imageProperty(source, image.PropertyKey.EXPOSURE_TIME);
      info.imageIso = await imageProperty(source, image.PropertyKey.ISO_SPEED_RATINGS);
      info.imageFNumber = await imageProperty(source, image.PropertyKey.F_NUMBER);
      const latitude = await imageProperty(source, image.PropertyKey.GPS_LATITUDE);
      const longitude = await imageProperty(source, image.PropertyKey.GPS_LONGITUDE);
      const latRef = await imageProperty(source, image.PropertyKey.GPS_LATITUDE_REF);
      const lonRef = await imageProperty(source, image.PropertyKey.GPS_LONGITUDE_REF);
      info.imageGps = latitude.length > 0 && longitude.length > 0 ? `${latitude} ${latRef}, ${longitude} ${lonRef}` : '';
      return info;
    } finally {
      await source.release();
      await fileIo.close(file);
    }
  }

  private static async analyzeAV(info: AnalyzedMedia, wantThumbnail: boolean): Promise<AnalysisResult> {
    let file: fileIo.File | undefined = undefined;
    let extractor: media.AVMetadataExtractor | undefined = undefined;
    try {
      file = fileIo.openSync(info.uri, fileIo.OpenMode.READ_ONLY);
      extractor = await media.createAVMetadataExtractor();
      const fileSize = fileIo.statSync(file.fd).size;
      extractor.fdSrc = { fd: file.fd, offset: 0, length: fileSize };
      const meta = await extractor.fetchMetadata();
      info.rawMetadata = JSON.stringify(meta, null, 2);
      info.mimeType = meta.mimeType;

      info.durationMs = toNum(meta.duration);
      info.title = meta.title ?? '';
      info.artist = meta.artist ?? '';
      info.albumArtist = meta.albumArtist ?? '';
      info.album = meta.album ?? '';
      info.author = meta.author ?? '';
      info.composer = meta.composer ?? '';
      info.genre = meta.genre ?? '';
      info.creationTime = meta.dateTimeFormat ?? meta.dateTime ?? '';

      const tracks = meta.tracks ?? [];
      for (const track of tracks) {
        const trackType = descNum(track, media.MediaDescriptionKey.MD_KEY_TRACK_TYPE);
        const mime = descStr(track, media.MediaDescriptionKey.MD_KEY_CODEC_MIME);
        let kind = MediaStreamKind.UNKNOWN;
        if (trackType === media.MediaType.MEDIA_TYPE_VID) {
          kind = MediaStreamKind.VIDEO;
        } else if (trackType === media.MediaType.MEDIA_TYPE_AUD) {
          kind = MediaStreamKind.AUDIO;
        } else if (trackType === media.MediaType.MEDIA_TYPE_SUBTITLE) {
          kind = MediaStreamKind.SUBTITLE;
        } else if (trackType === media.MediaType.MEDIA_TYPE_ATTACHMENT) {
          kind = MediaStreamKind.ATTACHMENT;
        }
        const stream: MediaStreamInfo = {
          rawDetails: JSON.stringify(track, null, 2),
          width: descNum(track, media.MediaDescriptionKey.MD_KEY_WIDTH),
          height: descNum(track, media.MediaDescriptionKey.MD_KEY_HEIGHT),
          fps: normalizeFps(descNum(track, media.MediaDescriptionKey.MD_KEY_FRAME_RATE)),
          sampleRateHz: descNum(track, media.MediaDescriptionKey.MD_KEY_AUD_SAMPLE_RATE),
          channels: descNum(track, media.MediaDescriptionKey.MD_KEY_AUD_CHANNEL_COUNT),
          sampleDepthBits: descNum(track, media.MediaDescriptionKey.MD_KEY_AUD_SAMPLE_DEPTH),
          index: descNum(track, media.MediaDescriptionKey.MD_KEY_TRACK_INDEX),
          kind: kind,
          codec: codecDisplayName(mime.length > 0 ? mime : descStr(track, media.MediaDescriptionKey.MD_KEY_MIME_TYPE)),
          language: descStr(track, media.MediaDescriptionKey.MD_KEY_LANGUAGE),
          name: descStr(track, media.MediaDescriptionKey.MD_KEY_TRACK_NAME),
          bitrateKbps: Math.round(descNum(track, media.MediaDescriptionKey.MD_KEY_BITRATE) / 1000)
        };
        info.streams.push(stream);
        if (trackType === media.MediaType.MEDIA_TYPE_VID && info.video === undefined) {
          const video: VideoInfo = {
            codec: codecDisplayName(mime),
            width: descNum(track, media.MediaDescriptionKey.MD_KEY_WIDTH),
            height: descNum(track, media.MediaDescriptionKey.MD_KEY_HEIGHT),
            fps: normalizeFps(descNum(track, media.MediaDescriptionKey.MD_KEY_FRAME_RATE)),
            bitrateKbps: Math.round(descNum(track, media.MediaDescriptionKey.MD_KEY_BITRATE) / 1000),
            hdrKnown: meta.hdrType !== undefined,
            hdr: toNum(meta.hdrType) !== media.HdrType.AV_HDR_TYPE_NONE,
            rotation: toNum(meta.videoOrientation)
          };
          info.video = video;
        } else if (trackType === media.MediaType.MEDIA_TYPE_AUD && info.audio === undefined) {
          const audio: AudioInfo = {
            codec: codecDisplayName(mime),
            bitrateKbps: Math.round(descNum(track, media.MediaDescriptionKey.MD_KEY_BITRATE) / 1000),
            sampleRateHz: descNum(track, media.MediaDescriptionKey.MD_KEY_AUD_SAMPLE_RATE),
            channels: descNum(track, media.MediaDescriptionKey.MD_KEY_AUD_CHANNEL_COUNT),
            sampleDepthBits: descNum(track, media.MediaDescriptionKey.MD_KEY_AUD_SAMPLE_DEPTH),
            channelLayout: descNum(track, media.MediaDescriptionKey.MD_KEY_AUD_CHANNEL_COUNT) === 1 ? '单声道' :
              (descNum(track, media.MediaDescriptionKey.MD_KEY_AUD_CHANNEL_COUNT) === 2 ? '立体声' : '')
          };
          info.audio = audio;
        }
      }

      let thumbnail: image.PixelMap | undefined = undefined;
      if (wantThumbnail) {
        try {
          thumbnail = await extractor.fetchFrameByTime(Math.max(info.durationMs / 2, 500) * 1000,
            media.AVImageQueryOptions.AV_IMAGE_QUERY_NEXT_SYNC,
            { width: 640, height: 360 });
        } catch (e) {
          hilog.warn(DOMAIN, TAG, 'thumbnail failed %{public}s', JSON.stringify(e));
        }
      }
      return { media: info, thumbnail: thumbnail };
    } finally {
      try {
        if (extractor !== undefined) {
          await extractor.release();
        }
      } finally {
        if (file !== undefined) {
          fileIo.closeSync(file);
        }
      }
    }
  }
}
