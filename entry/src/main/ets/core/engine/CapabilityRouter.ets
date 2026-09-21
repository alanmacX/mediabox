/**
 * Capability Router — 把"这个文件能做什么"变成结构化的推荐列表。
 *
 * 功能验收原则（2026-09）：
 * - 仅保留单测/命令审计覆盖、且引擎有执行路径的操作。
 * - 编码器依赖运行时探测（mp3 / webpAnim / vp8 / avif）或 DeviceSupport。
 * - 未验证的冷门转封装、HDR 管线、黑帧/章节/流级操作等不再进入推荐列表。
 */
import { AnalyzedMedia, MediaType, ToolAction, EngineKind, ToolSymbol } from '../model/MediaTypes';
import { image } from '@kit.ImageKit';
import { DeviceSupport } from '../capability/DeviceSupport';

const LOSSLESS_TARGET = 'MP4';

export interface FfmpegEncoderCaps {
  mp3?: boolean;
  vp8?: boolean;
  webpAnim?: boolean;
  avif?: boolean;
}

export interface BitrateBudget {
  videoKbps: number;
  audioKbps: number;
}

export interface VideoDimensions {
  width: number;
  height: number;
}

const AV_TRANSCODER_SYSCAP = 'SystemCapability.Multimedia.Media.AVTranscoder';
const IMAGE_PACKER_SYSCAP = 'SystemCapability.Multimedia.Image.ImagePacker';
const IMAGE_SOURCE_SYSCAP = 'SystemCapability.Multimedia.Image.ImageSource';

export function nativeTranscodeAvailable(media: AnalyzedMedia): boolean {
  return media.video !== undefined && media.video.width >= 240 && media.video.height >= 240 &&
    canIUse(AV_TRANSCODER_SYSCAP);
}

export function nativeImageAvailable(): boolean {
  return canIUse(IMAGE_SOURCE_SYSCAP) && canIUse(IMAGE_PACKER_SYSCAP);
}

function nativeImageFormatAvailable(format: string): boolean {
  if (!nativeImageAvailable()) {
    return false;
  }
  try {
    return image.getImagePackerSupportedFormats().includes(format);
  } catch (e) {
    return false;
  }
}

export function native1080pDimensions(srcW: number, srcH: number): VideoDimensions {
  let scale = Math.min(1, 1920 / Math.max(srcW, 1), 1080 / Math.max(srcH, 1));
  if (srcW * scale < 240) {
    scale = Math.min(1, 240 / Math.max(srcW, 1));
  }
  if (srcH * scale < 240) {
    scale = Math.min(1, 240 / Math.max(srcH, 1));
  }
  const width = Math.max(240, Math.floor(srcW * scale / 2) * 2);
  const height = Math.max(240, Math.floor(srcH * scale / 2) * 2);
  return { width: width, height: height };
}

export function nativeMaximumDimensions(srcW: number, srcH: number): VideoDimensions {
  let scale = Math.min(1, 3840 / Math.max(srcW, 1), 2160 / Math.max(srcH, 1));
  if (srcW * scale < 240) {
    scale = Math.min(1, 240 / Math.max(srcW, 1));
  }
  if (srcH * scale < 240) {
    scale = Math.min(1, 240 / Math.max(srcH, 1));
  }
  return {
    width: Math.min(3840, Math.max(240, Math.floor(srcW * scale / 2) * 2)),
    height: Math.min(2160, Math.max(240, Math.floor(srcH * scale / 2) * 2))
  };
}

function remuxFeasible(media: AnalyzedMedia): boolean {
  if (media.mediaType !== MediaType.VIDEO || media.container === LOSSLESS_TARGET) {
    return false;
  }
  if (media.video === undefined) {
    return false;
  }
  const c = media.video.codec.toUpperCase();
  const audio = media.audio?.codec.toUpperCase() ?? '';
  const audioCompatible = audio.length === 0 || audio.includes('AAC') || audio.includes('MP3');
  return audioCompatible && (c.startsWith('H.264') || c.startsWith('HEVC') || c.startsWith('H.265'));
}

export function estimateTargetBitrateBps(srcW: number, srcH: number, srcFps: number, srcBitrateBps: number,
  dstW: number, dstH: number, dstFps: number): number {
  const baseline = 3_000_000;
  const resFactor = Math.pow((dstW * dstH) / (1280 * 720), 1.57);
  const fpsFactor = Math.min(2, Math.max(0.5, dstFps / 30));
  const r1 = baseline * resFactor * fpsFactor;
  const srcResFactor = Math.pow((srcW * srcH) / (1280 * 720), 1.57);
  const srcFpsFactor = Math.min(2, Math.max(0.5, (srcFps > 0 ? srcFps : 30) / 30));
  const r2 = (srcBitrateBps > 0 ? srcBitrateBps : r1) * (resFactor * fpsFactor) / (srcResFactor * srcFpsFactor);
  return Math.floor(Math.min(r1, r2));
}

export function targetSizeBudget(media: AnalyzedMedia, targetBytes: number): BitrateBudget {
  const durSec = Math.max(media.durationMs / 1000, 1);
  const totalKbps = (targetBytes * 8 * 0.95) / durSec / 1000;
  const audioKbps = media.audio !== undefined ? Math.min(128, Math.max(32, Math.floor(totalKbps * 0.2))) : 0;
  const videoKbps = Math.max(80, Math.floor(totalKbps - audioKbps));
  return { videoKbps: videoKbps, audioKbps: audioKbps };
}

function compressSavingPct(media: AnalyzedMedia): number {
  const srcKbps = (media.video?.bitrateKbps ?? 0) + (media.audio?.bitrateKbps ?? 0);
  if (srcKbps <= 0 || media.durationMs <= 0 || media.video === undefined) {
    return 0;
  }
  const targetBps = estimateTargetBitrateBps(
    media.video.width, media.video.height, media.video.fps, media.video.bitrateKbps * 1000,
    media.video.width, media.video.height, Math.max(media.video.fps, 30)) * 0.9;
  const saving = 1 - targetBps / (srcKbps * 1000);
  return Math.round(Math.min(85, Math.max(10, saving * 100)));
}

export class CapabilityRouter {
  /** 仅返回 available===true 的动作；不完美/不可用项不进 UI。 */
  static recommend(media: AnalyzedMedia, caps?: FfmpegEncoderCaps): ToolAction[] {
    const actions: ToolAction[] = [];
    if (media.isMovingPhoto) {
      const mp = DeviceSupport.movingPhoto();
      const exportOk = mp.available && mp.canExportMovingPhoto;
      if (exportOk) {
        actions.push({
          id: 'moving_photo_image', title: '导出静态照片', subtitle: '从动态照片读取原始图片资源',
          lossless: true, engine: EngineKind.NATIVE, available: true, icon: ToolSymbol.IMAGE
        });
        actions.push({
          id: 'moving_photo_video', title: '导出短视频', subtitle: '从动态照片读取原始视频资源',
          lossless: true, engine: EngineKind.NATIVE, available: true, icon: ToolSymbol.VIDEO
        });
        actions.push({
          id: 'moving_photo_gif', title: '动态照片转 GIF', subtitle: '读取视频资源并转换为循环 GIF',
          lossless: false, engine: EngineKind.NATIVE, available: true, icon: ToolSymbol.GIF
        });
      }
      // 动态照片不走普通图片工具：Image Kit 对 moving URI 不可靠
      actions.push({
        id: 'media_info', title: '媒体信息', subtitle: '查看完整技术参数',
        lossless: true, engine: EngineKind.NATIVE, available: true, icon: ToolSymbol.INFO
      });
      return actions.filter((a: ToolAction) => a.available === true);
    }
    switch (media.mediaType) {
      case MediaType.VIDEO:
        actions.push(...CapabilityRouter.videoActions(media, caps));
        break;
      case MediaType.GIF:
        actions.push(...CapabilityRouter.gifActions(media, caps));
        break;
      case MediaType.IMAGE:
        actions.push(...CapabilityRouter.imageActions(media, caps));
        break;
      case MediaType.AUDIO:
        actions.push(...CapabilityRouter.audioActions(media, caps));
        break;
      case MediaType.SUBTITLE:
        if (media.container !== 'SRT') {
          actions.push({
            id: 'subtitle_to_srt', title: '转换为 SRT', subtitle: '转换为兼容性更高的 SubRip 字幕',
            lossless: true, engine: EngineKind.FFMPEG, available: true, icon: ToolSymbol.CONVERT
          });
        }
        actions.push({
          id: 'subtitle_shift_delay', title: '调整字幕延迟', subtitle: '整体向后移动字幕时间轴',
          lossless: true, engine: EngineKind.FFMPEG, available: true, icon: ToolSymbol.EDIT
        });
        actions.push({
          id: 'subtitle_shift_advance', title: '调整字幕提前', subtitle: '整体向前移动字幕时间轴',
          lossless: true, engine: EngineKind.FFMPEG, available: true, icon: ToolSymbol.EDIT
        });
        break;
      default:
        break;
    }
    actions.push({
      id: 'media_info',
      title: '媒体信息',
      subtitle: '查看完整技术参数',
      lossless: true,
      engine: EngineKind.NATIVE,
      available: true,
      icon: ToolSymbol.INFO
    });
    return actions.filter((a: ToolAction) => a.available === true);
  }

  /** 验收通过：无损 remux、原生压缩/预设/转 MP4、GIF、提取音频、已测裁剪与编辑。 */
  private static videoActions(media: AnalyzedMedia, caps?: FfmpegEncoderCaps): ToolAction[] {
    const out: ToolAction[] = [];
    const nativeReady = nativeTranscodeAvailable(media);
    const nativeStatus = media.video === undefined ? '未识别视频轨' :
      (media.video.width < 240 || media.video.height < 240 ? '分辨率不支持' : '设备不支持');

    if (remuxFeasible(media)) {
      out.push({
        id: 'remux_mp4',
        title: `无损转 ${LOSSLESS_TARGET}`,
        subtitle: `容器从 ${media.container} 转为 MP4,无需重新编码`,
        lossless: true,
        engine: EngineKind.FFMPEG,
        available: true,
        icon: ToolSymbol.CONVERT
      });
    }

    const saving = compressSavingPct(media);
    out.push({
      id: 'compress_smart',
      title: '智能压缩',
      subtitle: saving > 0 ? `自动选择参数,预计可节省 ${saving}%` : '自动选择编码、分辨率与码率',
      lossless: false,
      engine: EngineKind.NATIVE,
      available: nativeReady,
      statusLabel: nativeReady ? undefined : nativeStatus,
      estimatedSavingPct: saving,
      icon: ToolSymbol.COMPRESS
    });
    out.push({
      id: 'compress_target_size',
      title: '压到指定大小',
      subtitle: '输入目标体积,自动计算码率与分辨率',
      lossless: false,
      engine: EngineKind.NATIVE,
      available: nativeReady,
      statusLabel: nativeReady ? undefined : nativeStatus,
      icon: ToolSymbol.TARGET
    });
    out.push({
      id: 'preset_quality', title: '最高质量', subtitle: '保留原分辨率，使用较高目标码率',
      lossless: false, engine: EngineKind.NATIVE, available: nativeReady,
      statusLabel: nativeReady ? undefined : nativeStatus, icon: ToolSymbol.VIDEO
    });
    out.push({
      id: 'preset_balanced', title: '平衡', subtitle: '兼顾画质、体积与处理速度',
      lossless: false, engine: EngineKind.NATIVE, available: nativeReady,
      statusLabel: nativeReady ? undefined : nativeStatus, icon: ToolSymbol.COMPRESS
    });
    out.push({
      id: 'preset_small', title: '更小文件', subtitle: '限制到 720p 并降低码率',
      lossless: false, engine: EngineKind.NATIVE, available: nativeReady,
      statusLabel: nativeReady ? undefined : nativeStatus, icon: ToolSymbol.TARGET
    });
    out.push({
      id: 'preset_fast', title: '最快', subtitle: '使用硬件 H.264 与适中码率',
      lossless: false, engine: EngineKind.NATIVE, available: nativeReady,
      statusLabel: nativeReady ? undefined : nativeStatus, icon: ToolSymbol.CONVERT
    });
    out.push({
      id: 'convert_mp4',
      title: '转 MP4(H.264)',
      subtitle: '最大兼容性,硬件转码',
      lossless: false,
      engine: EngineKind.NATIVE,
      available: nativeReady,
      statusLabel: nativeReady ? undefined : nativeStatus,
      icon: ToolSymbol.CONVERT
    });
    out.push({
      id: 'video_to_mkv', title: '转 MKV', subtitle: '尽量直接复制全部媒体流', lossless: true,
      engine: EngineKind.FFMPEG, available: true, icon: ToolSymbol.CONVERT
    });
    const vp8Ready = caps?.vp8 === true;
    out.push({
      id: 'video_to_webm', title: '转 WebM', subtitle: 'VP8 与 Vorbis 输出', lossless: false,
      engine: EngineKind.FFMPEG, available: vp8Ready,
      statusLabel: vp8Ready ? undefined : '当前 FFmpeg 构建缺少 VP8 编码器',
      icon: ToolSymbol.CONVERT
    });
    out.push({
      id: 'to_gif',
      title: '转 GIF',
      subtitle: '选取片段与帧率,导出 GIF',
      lossless: false,
      engine: EngineKind.FFMPEG,
      available: true,
      icon: ToolSymbol.GIF
    });
    if (media.audio !== undefined) {
      out.push({
        id: 'extract_audio',
        title: '提取音频',
        subtitle: '选择 M4A、WAV、FLAC 或 MP3 及音频参数',
        lossless: false,
        engine: EngineKind.FFMPEG,
        available: true,
        icon: ToolSymbol.AUDIO
      });
    }
    out.push({
      id: 'video_trim',
      title: '精确裁剪',
      subtitle: '指定起点与时长，重新编码保证边界',
      lossless: false,
      engine: EngineKind.FFMPEG,
      available: true,
      icon: ToolSymbol.EDIT
    });
    out.push({
      id: 'video_lossless_trim', title: '无损裁剪',
      subtitle: '指定起点与时长，按关键帧复制', lossless: true,
      engine: EngineKind.FFMPEG, available: true, icon: ToolSymbol.EDIT
    });
    out.push({
      id: 'video_split', title: '无损分段', subtitle: '按设定秒数切分，复制所有媒体流', lossless: true,
      engine: EngineKind.FFMPEG, available: true, icon: ToolSymbol.EDIT
    });
    out.push({
      id: 'video_mute', title: '移除声音', subtitle: '复制视频流并删除所有音轨', lossless: true,
      engine: EngineKind.FFMPEG, available: true, icon: ToolSymbol.AUDIO
    });
    out.push({
      id: 'video_loop', title: '循环播放', subtitle: '复制媒体流并连续重复播放', lossless: true,
      engine: EngineKind.FFMPEG, available: true, icon: ToolSymbol.EDIT
    });
    out.push({
      id: 'video_timecode', title: '写入起始时间码', subtitle: '自定义起始容器时间码', lossless: true,
      engine: EngineKind.FFMPEG, available: true, icon: ToolSymbol.INFO
    });
    out.push({
      id: 'video_resize', title: '调整视频尺寸', subtitle: '自定义输出尺寸与比例', lossless: false,
      engine: EngineKind.FFMPEG, available: true, icon: ToolSymbol.RESIZE
    });
    out.push({
      id: 'video_rotate', title: '旋转画面', subtitle: '选择旋转角度并预览', lossless: false,
      engine: EngineKind.FFMPEG, available: true, icon: ToolSymbol.EDIT
    });
    out.push({
      id: 'video_flip', title: '镜像翻转', subtitle: '选择水平或垂直镜像', lossless: false,
      engine: EngineKind.FFMPEG, available: true, icon: ToolSymbol.EDIT
    });
    out.push({
      id: 'video_crop', title: '画面裁剪', subtitle: '自定义裁剪区域与预览', lossless: false,
      engine: EngineKind.FFMPEG, available: true, icon: ToolSymbol.RESIZE
    });
    out.push({
      id: 'video_speed', title: '调整播放速度', subtitle: '音视频同步变速', lossless: false,
      engine: EngineKind.FFMPEG, available: true, icon: ToolSymbol.EDIT
    });
    out.push({
      id: 'video_fps', title: '转换帧率', subtitle: '自定义输出帧率', lossless: false,
      engine: EngineKind.FFMPEG, available: true, icon: ToolSymbol.CONVERT
    });
    out.push({
      id: 'video_snapshot', title: '视频截图', subtitle: '指定时间点导出 JPEG', lossless: true,
      engine: EngineKind.FFMPEG, available: true, icon: ToolSymbol.IMAGE
    });
    return out;
  }

  private static gifActions(media: AnalyzedMedia, caps?: FfmpegEncoderCaps): ToolAction[] {
    return [
      {
        id: 'gif_target_size', title: '压到指定大小', subtitle: '联合调整尺寸、帧率与调色板',
        lossless: false, engine: EngineKind.FFMPEG, available: true, icon: ToolSymbol.TARGET
      },
      {
        id: 'gif_optimize', title: 'GIF 优化', subtitle: '帧率与尺寸重编码，稳定可完成',
        lossless: false, engine: EngineKind.FFMPEG, available: true, icon: ToolSymbol.TARGET
      },
      {
        id: 'gif_to_mp4', title: 'GIF 转 MP4', subtitle: '体积更小,画质更稳',
        lossless: false, engine: EngineKind.FFMPEG, available: true, icon: ToolSymbol.CONVERT
      },
      {
        id: 'gif_to_webp', title: 'GIF 转动态 WebP', subtitle: '保留动画并减小常见场景体积',
        lossless: false, engine: EngineKind.FFMPEG, available: caps?.webpAnim === true,
        statusLabel: caps?.webpAnim === true ? undefined : '当前 FFmpeg 构建缺少 WebP 动画编码器',
        icon: ToolSymbol.CONVERT
      },
      {
        id: 'gif_trim', title: 'GIF 裁剪时段', subtitle: '按开始时间与时长保留动画片段',
        lossless: false, engine: EngineKind.FFMPEG, available: true, icon: ToolSymbol.EDIT
      },
      {
        id: 'gif_crop', title: 'GIF 裁剪画面', subtitle: '裁剪到指定宽度与高度',
        lossless: false, engine: EngineKind.FFMPEG, available: true, icon: ToolSymbol.EDIT
      },
      {
        id: 'gif_resize', title: 'GIF 调整尺寸', subtitle: '指定输出宽度并保持比例',
        lossless: false, engine: EngineKind.FFMPEG, available: true, icon: ToolSymbol.RESIZE
      },
      {
        id: 'gif_fps', title: 'GIF 调整帧率', subtitle: '调整动画每秒帧数',
        lossless: false, engine: EngineKind.FFMPEG, available: true, icon: ToolSymbol.EDIT
      },
      {
        id: 'gif_speed', title: 'GIF 调整速度', subtitle: '按倍率加速或减速动画',
        lossless: false, engine: EngineKind.FFMPEG, available: true, icon: ToolSymbol.EDIT
      },
      {
        id: 'gif_loop', title: 'GIF 循环次数', subtitle: '设置无限循环或有限循环',
        lossless: false, engine: EngineKind.FFMPEG, available: true, icon: ToolSymbol.EDIT
      },
      {
        id: 'gif_quality', title: 'GIF 调色板质量', subtitle: '2–256 色控制画质与体积',
        lossless: false, engine: EngineKind.FFMPEG, available: true, icon: ToolSymbol.EDIT
      }
    ];
  }

  private static imageActions(media: AnalyzedMedia, caps?: FfmpegEncoderCaps): ToolAction[] {
    const ready = nativeImageAvailable();
    const status = ready ? undefined : '设备不支持 Image Kit 编解码';
    const encode = DeviceSupport.imageEncode();
    const out: ToolAction[] = [];
    out.push({
      id: 'image_convert', title: '格式转换', subtitle: '转换为 WebP；不保留源元数据',
      lossless: false, engine: EngineKind.NATIVE, available: encode.webp,
      statusLabel: encode.webp ? undefined : '当前设备不支持 WebP 编码', icon: ToolSymbol.CONVERT
    });
    out.push({
      id: 'image_to_jpeg', title: '转 JPEG', subtitle: '可指定透明区域的合成背景色', lossless: false,
      engine: EngineKind.NATIVE, available: ready && encode.jpeg,
      statusLabel: encode.jpeg ? status : '当前设备不支持 JPEG 编码', icon: ToolSymbol.CONVERT
    });
    out.push({
      id: 'image_to_png', title: '转 PNG', subtitle: '支持透明通道的无损像素编码', lossless: false,
      engine: EngineKind.NATIVE, available: encode.png,
      statusLabel: encode.png ? undefined : '当前设备不支持 PNG 编码', icon: ToolSymbol.CONVERT
    });
    out.push({
      id: 'image_to_heif', title: '转 HEIF', subtitle: '设备 Image Kit 高效编码', lossless: false,
      engine: EngineKind.NATIVE, available: encode.heif,
      statusLabel: encode.heif ? undefined : '当前设备不支持 HEIF 编码', icon: ToolSymbol.CONVERT
    });
    const avifOk = encode.avif === true || caps?.avif === true;
    out.push({
      id: 'image_to_avif', title: '转 AVIF', subtitle: encode.avif ? '设备 Image Kit AVIF' : 'FFmpeg libaom AV1',
      lossless: false, engine: encode.avif ? EngineKind.NATIVE : EngineKind.FFMPEG, available: avifOk,
      statusLabel: avifOk ? undefined : '当前设备无 AVIF 编码', icon: ToolSymbol.CONVERT
    });
    out.push({
      id: 'image_compress', title: '图片压缩', subtitle: '调整 JPEG 编码质量',
      lossless: false, engine: EngineKind.NATIVE, available: ready && encode.jpeg,
      statusLabel: encode.jpeg ? status : '当前设备不支持 JPEG 编码', icon: ToolSymbol.COMPRESS
    });
    out.push({
      id: 'image_target_size', title: '压到指定大小', subtitle: '搜索不超过目标体积的最高 JPEG 质量',
      lossless: false, engine: EngineKind.NATIVE, available: ready && encode.jpeg,
      statusLabel: encode.jpeg ? status : '当前设备不支持 JPEG 编码', icon: ToolSymbol.TARGET
    });
    out.push({
      id: 'image_resize', title: '尺寸调整', subtitle: '自定义输出宽高与比例',
      lossless: false, engine: EngineKind.NATIVE, available: ready, statusLabel: status,
      icon: ToolSymbol.RESIZE
    });
    out.push({
      id: 'image_crop', title: '裁剪图片', subtitle: '设置裁剪区域并重新编码',
      lossless: false, engine: EngineKind.NATIVE, available: ready, statusLabel: status,
      icon: ToolSymbol.EDIT
    });
    out.push({
      id: 'image_rotate', title: '旋转画面', subtitle: '选择旋转角度并重新编码',
      lossless: false, engine: EngineKind.NATIVE, available: ready, statusLabel: status,
      icon: ToolSymbol.EDIT
    });
    out.push({
      id: 'image_flip', title: '镜像翻转', subtitle: '选择水平或垂直镜像',
      lossless: false, engine: EngineKind.NATIVE, available: ready, statusLabel: status,
      icon: ToolSymbol.EDIT
    });
    out.push({
      id: 'image_text', title: '添加文字', subtitle: '系统字体在图片上绘制文字', lossless: false,
      engine: EngineKind.NATIVE,
      available: nativeImageFormatAvailable('image/jpeg') && canIUse('SystemCapability.Graphics.Drawing'),
      statusLabel: canIUse('SystemCapability.Graphics.Drawing') ? status : '设备不支持原生绘图',
      icon: ToolSymbol.EDIT
    });
    out.push({
      id: 'image_metadata', title: '清除元数据', subtitle: '重新编码并移除 EXIF 等源属性',
      lossless: false, engine: EngineKind.NATIVE, available: ready, statusLabel: status,
      icon: ToolSymbol.INFO
    });
    return out;
  }

  private static audioActions(media: AnalyzedMedia, caps?: FfmpegEncoderCaps): ToolAction[] {
    return [
      {
        id: 'audio_convert', title: '转 AAC', subtitle: '设置码率、采样率与声道，输出 M4A',
        lossless: false, engine: EngineKind.FFMPEG, available: true, icon: ToolSymbol.CONVERT
      },
      {
        id: 'audio_to_mp3', title: '转 MP3', subtitle: '设置码率、采样率与声道', lossless: false,
        engine: EngineKind.FFMPEG, available: caps?.mp3 === true,
        statusLabel: caps?.mp3 === true ? undefined : '当前 FFmpeg 构建缺少 MP3 编码器',
        icon: ToolSymbol.CONVERT
      },
      {
        id: 'audio_to_wav', title: '转 WAV', subtitle: '16-bit PCM', lossless: false,
        engine: EngineKind.FFMPEG, available: true, icon: ToolSymbol.CONVERT
      },
      {
        id: 'audio_to_flac', title: '转 FLAC', subtitle: '无损音频编码', lossless: false,
        engine: EngineKind.FFMPEG, available: true, icon: ToolSymbol.CONVERT
      },
      {
        id: 'audio_trim', title: '裁剪音频', subtitle: '设置开始时间与时长',
        lossless: false, engine: EngineKind.FFMPEG, available: true, icon: ToolSymbol.EDIT
      },
      {
        id: 'audio_normalize', title: '响度标准化', subtitle: 'LUFS / 真峰值 / 响度范围',
        lossless: false, engine: EngineKind.FFMPEG, available: true, icon: ToolSymbol.NORMALIZE
      },
      {
        id: 'audio_silence_detect', title: '静音区间检测', subtitle: '阈值与最短持续时间',
        lossless: true, engine: EngineKind.FFMPEG, available: true, icon: ToolSymbol.INFO
      },
      {
        id: 'audio_volume', title: '调整音量', subtitle: '设置音量倍率', lossless: false,
        engine: EngineKind.FFMPEG, available: true, icon: ToolSymbol.AUDIO
      },
      {
        id: 'audio_fade', title: '淡入淡出', subtitle: '设置淡入与淡出时长', lossless: false,
        engine: EngineKind.FFMPEG, available: true, icon: ToolSymbol.EDIT
      },
      {
        id: 'audio_mono', title: '转换为单声道', subtitle: 'AAC 单声道输出', lossless: false,
        engine: EngineKind.FFMPEG, available: true, icon: ToolSymbol.CONVERT
      },
      {
        id: 'audio_stereo', title: '转换为立体声', subtitle: 'AAC 双声道输出', lossless: false,
        engine: EngineKind.FFMPEG, available: true, icon: ToolSymbol.CONVERT
      },
      {
        id: 'audio_resample', title: '调整采样率', subtitle: '保持声道并转换采样率', lossless: false,
        engine: EngineKind.FFMPEG, available: true, icon: ToolSymbol.CONVERT
      }
    ];
  }
}
