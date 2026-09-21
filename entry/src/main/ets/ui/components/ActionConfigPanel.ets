/**
 * ActionConfigPanel — 单文件"简单参数"配置面板。
 *
 * 从 Workbench 拆出：时间点、时长、帧率、尺寸、音量、元数据等
 * 标量参数的输入、校验与入队全部内聚在此组件；Workbench 只负责
 * 面板的打开/关闭。每个动作打开时重置为合理默认值。
 */
import { image } from '@kit.ImageKit';
import { PreviewFrames } from '../../core/media/PreviewFrames';
import { TaskParams } from '../../core/task/MediaTask';
import { TaskQueue } from '../../core/task/TaskQueue';
import { WorkbenchSession } from './WorkbenchSession';
import { AnalyzedMedia, Fmt, MediaType, ToolAction } from '../../core/model/MediaTypes';
import { Dt } from '../theme/DesignTokens';
import { GlassCard } from './GlassCard';

/** 需要本面板配置的动作集合（与 Workbench 的入口判断保持一致）。 */
export function usesSimpleConfig(id: string): boolean {
  return ['to_gif', 'video_trim', 'video_lossless_trim', 'video_snapshot', 'gif_optimize', 'gif_trim',
    'gif_crop', 'gif_resize', 'gif_fps', 'gif_speed', 'gif_loop', 'gif_quality',
    'video_split', 'video_frames', 'audio_convert', 'audio_trim', 'audio_normalize', 'audio_volume',
    'audio_fade', 'audio_mono', 'audio_stereo', 'audio_resample', 'image_text', 'image_to_jpeg', 'video_text',
    'video_create_chapters', 'metadata_edit', 'image_metadata_edit'].includes(id) || id.startsWith('stream_metadata_');
}

@Component
export struct ActionConfigPanel {
  @Prop @Watch('onActionChange') action: ToolAction;
  @Prop mediaInfo: AnalyzedMedia;
  onSubmit: () => void = () => {};
  onClose: () => void = () => {};
  @State startTimeText: string = '00:00:00';
  @State timePreview?: image.PixelMap = undefined;
  @State timePreviewBusy: boolean = false;
  @State timePreviewLabel: string = '';
  @State durationText: string = '30';
  @State fpsText: string = '12';
  @State widthText: string = '480';
  @State heightText: string = '320';
  @State speedText: string = '1';
  @State loopCountText: string = '0';
  @State paletteColorsText: string = '128';
  @State imageBackgroundText: string = '#FFFFFF';
  @State audioBitrateText: string = '192';
  @State volumeText: string = '1.5';
  @State sampleRateText: string = '44100';
  @State overlayText: string = 'MediaBox媒体工具箱';
  @State metadataTitleText: string = '';
  @State metadataArtistText: string = '';
  @State metadataAlbumArtistText: string = '';
  @State metadataAlbumText: string = '';
  @State metadataAuthorText: string = '';
  @State metadataComposerText: string = '';
  @State metadataGenreText: string = '';
  @State metadataCreationTimeText: string = '';
  @State trackTitleText: string = '';
  @State trackLanguageText: string = '';
  @State subtitlePreviewNote: string = '';
  private previewRequest: number = 0;

  aboutToAppear(): void {
    this.onActionChange();
  }

  aboutToDisappear(): void {
    this.previewRequest++;
    this.timePreview?.release();
    this.timePreview = undefined;
  }

  private onActionChange(): void {
    this.previewRequest++;
    this.timePreview?.release();
    this.timePreview = undefined;
    this.timePreviewLabel = '';
    this.subtitlePreviewNote = '';
    if (this.action.id === 'metadata_edit' || this.action.id === 'image_metadata_edit') {
      this.metadataTitleText = this.mediaInfo.title;
      this.metadataArtistText = this.mediaInfo.artist;
      this.metadataAlbumArtistText = this.mediaInfo.albumArtist;
      this.metadataAlbumText = this.mediaInfo.album;
      this.metadataAuthorText = this.mediaInfo.author;
      this.metadataComposerText = this.mediaInfo.composer;
      this.metadataGenreText = this.mediaInfo.genre;
      this.metadataCreationTimeText = this.mediaInfo.creationTime;
    }
    if (this.action.id.startsWith('stream_metadata_')) {
      const index = Number(this.action.id.substring('stream_metadata_'.length));
      const stream = this.mediaInfo.streams.find((item) => item.index === index);
      this.trackTitleText = stream?.name ?? '';
      this.trackLanguageText = stream?.language ?? '';
    }
    if (this.action.id === 'gif_crop') {
      this.widthText = `${Math.max(1, Math.min(480, this.mediaInfo.imageWidth || 480))}`;
      this.heightText = `${Math.max(1, Math.min(320, this.mediaInfo.imageHeight || 320))}`;
    }
  }

  private isTimeAction(): boolean {
    return this.action.id.includes('trim') || this.action.id === 'to_gif' ||
      this.action.id === 'video_snapshot';
  }

  private isDurationAction(): boolean {
    return this.action.id.includes('trim') || this.action.id === 'to_gif' ||
      this.action.id === 'audio_fade' || this.action.id === 'video_split' ||
      this.action.id === 'video_frames' || this.action.id === 'video_create_chapters';
  }

  private timeSeconds(): number {
    const parts = this.startTimeText.split(':');
    if (parts.length !== 3) return 0;
    return Math.max(0, Number(parts[0]) * 3600 + Number(parts[1]) * 60 + Number(parts[2]));
  }

  private setPreviewTime(seconds: number): void {
    const hours = Math.floor(seconds / 3600);
    const minutes = Math.floor(seconds % 3600 / 60);
    const remaining = (seconds % 60).toFixed(2).padStart(5, '0');
    this.startTimeText = `${hours.toString().padStart(2, '0')}:${minutes.toString().padStart(2, '0')}:${remaining}`;
  }

  private async previewTime(): Promise<void> {
    const m = this.mediaInfo;
    if (this.timePreviewBusy) return;
    const seconds = this.timeSeconds();
    if (!Number.isFinite(seconds) || seconds < 0 || seconds >= m.durationMs / 1000) {
      this.timePreviewLabel = '请选择媒体时长以内的时间点';
      return;
    }
    const request = ++this.previewRequest;
    this.timePreviewBusy = true;
    try {
      const pixels = await PreviewFrames.load(m, seconds);
      if (request !== this.previewRequest) { await pixels.release(); return; }
      const old = this.timePreview;
      this.timePreview = pixels;
      await old?.release();
      this.timePreviewLabel = `${seconds.toFixed(2)} 秒附近的画面；无损裁剪仍以关键帧边界为准`;
    } catch (e) { this.timePreviewLabel = `预览失败：${(e as Error).message}`; }
    finally { this.timePreviewBusy = false; }
  }

  private toast(message: string): void {
    this.getUIContext().getPromptAction().showToast({ message: message });
  }

  private enqueueConfiguredAction(): void {
    const m = this.mediaInfo;
    const action = this.action;
    const duration = Number(this.durationText);
    const fps = Number(this.fpsText);
    const width = Number(this.widthText);
    const height = Number(this.heightText);
    const speed = Number(this.speedText);
    const loopCount = Number(this.loopCountText);
    const paletteColors = Number(this.paletteColorsText);
    const audioKbps = Number(this.audioBitrateText);
    const volume = Number(this.volumeText);
    const sampleRate = Number(this.sampleRateText);
    const validTime = /^\d{2,}:([0-5]\d):([0-5]\d)(\.\d+)?$/.test(this.startTimeText);
    const startSeconds = validTime ? this.timeSeconds() : -1;
    if (this.isTimeAction() && (!validTime || (m.durationMs > 0 && startSeconds >= m.durationMs / 1000))) {
      this.toast('请输入有效开始时间 HH:MM:SS，且不能超出媒体时长');
      return;
    }
    if ((action.id === 'audio_volume' && (!Number.isFinite(volume) || volume < 0 || volume > 10)) ||
      (action.id === 'audio_resample' && ![8000, 16000, 22050, 32000, 44100, 48000, 96000].includes(sampleRate))) {
      this.toast('音量范围为 0–10；请输入支持的采样率');
      return;
    }
    const needsFps = action.id === 'to_gif' || action.id === 'gif_optimize' || action.id === 'gif_fps';
    const needsWidth = action.id === 'to_gif' || action.id === 'gif_optimize' || action.id === 'gif_resize' ||
      action.id === 'gif_crop';
    const needsHeight = action.id === 'gif_crop';
    const needsAudioBitrate = action.id.startsWith('audio_');
    if ((this.isDurationAction() && (!Number.isFinite(duration) || duration <= 0)) ||
      (needsFps && (!Number.isFinite(fps) || fps <= 0)) ||
      (needsWidth && (!Number.isFinite(width) || width <= 0)) ||
      (needsHeight && (!Number.isFinite(height) || height <= 0)) ||
      (needsAudioBitrate && (!Number.isFinite(audioKbps) || audioKbps <= 0)) ||
      (action.id === 'gif_speed' && (!Number.isFinite(speed) || speed < 0.05 || speed > 20)) ||
      (action.id === 'gif_loop' && (!Number.isFinite(loopCount) || loopCount < 0 || !Number.isInteger(loopCount))) ||
      (action.id === 'gif_quality' && (!Number.isFinite(paletteColors) || paletteColors < 2 ||
        paletteColors > 256 || !Number.isInteger(paletteColors)))) {
      this.toast('参数必须是大于 0 的数字');
      return;
    }
    const ids = TaskQueue.getInstance().enqueue([m.uri], [m.displayName], action.id, action.title, {
      startTime: this.startTimeText,
      durationSeconds: `${Math.min(duration, Math.max(0.001, (m.durationMs > 0 ? m.durationMs / 1000 -
        (this.isTimeAction() ? startSeconds : 0) : duration)))}`,
      totalDurationSeconds: action.id === 'audio_fade' || action.id === 'video_create_chapters' ?
        Math.max(1, m.durationMs / 1000) : undefined,
      targetFps: Math.round(fps),
      targetWidth: Math.round(width),
      cropWidth: action.id === 'gif_crop' ? Math.min(Math.round(width), m.imageWidth > 0 ? m.imageWidth :
        Math.round(width)) : undefined,
      cropHeight: action.id === 'gif_crop' ? Math.min(Math.round(height), m.imageHeight > 0 ? m.imageHeight :
        Math.round(height)) : undefined,
      targetAudioKbps: Math.round(audioKbps),
      targetSampleRateHz: action.id === 'audio_resample' ? sampleRate :
        (action.id === 'audio_mono' || action.id === 'audio_stereo' ? 48000 : undefined),
      targetChannels: action.id === 'audio_mono' ? 1 : (action.id === 'audio_stereo' ? 2 : undefined),
      volumeMultiplier: action.id === 'audio_volume' ? volume : undefined,
      loopCount: action.id === 'gif_loop' ? `${Math.round(loopCount)}` : '0',
      speed: action.id === 'gif_speed' ? speed : undefined,
      paletteColors: action.id === 'gif_quality' ? Math.round(paletteColors) : undefined,
      imageFormat: action.id === 'image_to_jpeg' ? 'image/jpeg' : undefined,
      imageQuality: action.id === 'image_to_jpeg' ? 90 : undefined,
      imageBackgroundColor: action.id === 'image_to_jpeg' ? this.imageBackgroundText : undefined,
      textOverlay: action.id === 'image_text' || action.id === 'video_text' ? this.overlayText : undefined,
      metadataTitle: action.id === 'metadata_edit' || action.id === 'image_metadata_edit' ?
        this.metadataTitleText : undefined,
      metadataArtist: action.id === 'metadata_edit' || action.id === 'image_metadata_edit' ?
        this.metadataArtistText : undefined,
      metadataAlbumArtist: action.id === 'metadata_edit' ? this.metadataAlbumArtistText : undefined,
      metadataAlbum: action.id === 'metadata_edit' ? this.metadataAlbumText : undefined,
      metadataAuthor: action.id === 'metadata_edit' ? this.metadataAuthorText : undefined,
      metadataComposer: action.id === 'metadata_edit' ? this.metadataComposerText : undefined,
      metadataGenre: action.id === 'metadata_edit' ? this.metadataGenreText : undefined,
      metadataCreationTime: action.id === 'metadata_edit' || action.id === 'image_metadata_edit' ?
        this.metadataCreationTimeText : undefined,
      trackTitle: action.id.startsWith('stream_metadata_') ? this.trackTitleText : undefined,
      trackLanguage: action.id.startsWith('stream_metadata_') ? this.trackLanguageText : undefined
    });
    WorkbenchSession.lastTaskIds = ids;
    this.onSubmit();
  }

  @Builder
  TimeFields() {
    if (this.isTimeAction()) {
      if (this.mediaInfo.mediaType !== MediaType.AUDIO && (this.mediaInfo.durationMs ?? 0) > 0) {
        Slider({ value: this.timeSeconds(), min: 0,
          max: Math.max(0.01, (this.mediaInfo.durationMs ?? 0) / 1000 - 0.01), step: 0.01 })
          .onChange((value: number) => this.setPreviewTime(value))
        if (this.timePreview !== undefined) {
          Image(this.timePreview).width('100%').height(220).objectFit(ImageFit.Contain)
        }
        Button(this.timePreviewBusy ? '正在读取画面…' : '预览所选时间点')
          .enabled(!this.timePreviewBusy).onClick(() => this.previewTime())
        if (this.timePreviewLabel.length > 0) {
          Text(this.timePreviewLabel).fontSize(Dt.fontCaption)
        }
      }
      Text('开始时间 00:00:00').fontSize(Dt.fontCaption)
        .fontColor($r('app.color.text_secondary')).width('100%')
      TextInput({ text: this.startTimeText, placeholder: '例如 00:00:05' })
        .onChange((value: string) => this.startTimeText = value)
    }
  }

  @Builder
  Field(text: string, placeholder: string, changed: (value: string) => void, numeric: boolean,
    weight: number) {
    Column({ space: 4 }) {
      Text(placeholder).fontSize(Dt.fontCaption)
        .fontColor($r('app.color.text_secondary')).width('100%')
      TextInput({ text: text })
        .type(numeric ? InputType.Number : InputType.USER_NAME)
        .width('100%')
        .onChange(changed)
    }
    .layoutWeight(weight)
  }

  private trimRangeLabel(): string {
    const srcSec = (this.mediaInfo.durationMs ?? 0) / 1000;
    const start = this.timeSeconds();
    const dur = Number(this.durationText);
    const end = Math.min(srcSec, start + (Number.isFinite(dur) && dur > 0 ? dur : 0));
    return `输出区间 ${this.startTimeText} → ${Fmt.duration(end * 1000)}（源 ${Fmt.duration(this.mediaInfo.durationMs)}）`;
  }

  build() {
    Column() {
      GlassCard({ radius: Dt.radiusLg, strongBlur: false }) {
        Column({ space: Dt.spaceMd }) {
          // 标题由 HdsNavDestination 提供
          this.TimeFields()
          if (this.isDurationAction()) {
            Text(this.action.id === 'video_frames' ? '抽帧间隔（秒）' :
              (this.action.id === 'video_create_chapters' ? '章节间隔（秒）' : '时长（秒）'))
              .fontSize(Dt.fontCaption).fontColor($r('app.color.text_secondary')).width('100%')
            TextInput({ text: this.durationText, placeholder: '默认 30' })
              .type(InputType.Number)
              .onChange((value: string) => this.durationText = value)
            if (this.action.id.includes('trim') && (this.mediaInfo.durationMs ?? 0) > 0) {
              Text(this.trimRangeLabel())
                .fontSize(Dt.fontCaption)
                .fontColor($r('app.color.text_secondary'))
                .width('100%')
            }
          }
          // 字段成对：横屏/宽屏两列，竖屏仍单列（父级约束宽度）
          if (this.action.id === 'to_gif' || this.action.id === 'gif_optimize') {
            Row({ space: Dt.spaceSm }) {
              this.Field(this.fpsText, 'FPS', (v: string) => this.fpsText = v, true, 1)
              this.Field(this.widthText, '宽度', (v: string) => this.widthText = v, true, 1)
            }
            .width('100%')
          }
          if (this.action.id === 'gif_crop') {
            Row({ space: Dt.spaceSm }) {
              this.Field(this.widthText, '裁剪宽度', (v: string) => this.widthText = v, true, 1)
              this.Field(this.heightText, '裁剪高度', (v: string) => this.heightText = v, true, 1)
            }
          }
          if (this.action.id === 'gif_resize') {
            this.Field(this.widthText, '输出宽度，自动保持比例', (v: string) => this.widthText = v, true, 0)
          }
          if (this.action.id === 'gif_fps') {
            this.Field(this.fpsText, '输出 FPS', (v: string) => this.fpsText = v, true, 0)
          }
          if (this.action.id === 'gif_speed') {
            this.Field(this.speedText, '速度倍率，例如 0.5 或 2', (v: string) => this.speedText = v, true, 0)
          }
          if (this.action.id === 'gif_loop') {
            this.Field(this.loopCountText, '循环次数，0 表示无限循环', (v: string) => this.loopCountText = v, true, 0)
          }
          if (this.action.id === 'gif_quality') {
            this.Field(this.paletteColorsText, '调色板颜色数，2 到 256', (v: string) => this.paletteColorsText = v, true, 0)
          }
          if (this.action.id === 'image_to_jpeg') {
            this.Field(this.imageBackgroundText, '透明背景色，例如 #FFFFFF 或 #000000',
              (v: string) => this.imageBackgroundText = v, false, 0)
          }
          if (this.action.id === 'audio_volume') {
            Text('音量倍率 · 0 静音 / 1 原音量 / 2 两倍').fontSize(Dt.fontCaption)
            this.Field(this.volumeText, '', (v: string) => this.volumeText = v, true, 0)
          }
          if (this.action.id === 'audio_resample') {
            Text('采样率 Hz · 8000 / 16000 / 22050 / 32000 / 44100 / 48000 / 96000')
              .fontSize(Dt.fontCaption)
            this.Field(this.sampleRateText, '', (v: string) => this.sampleRateText = v, true, 0)
          }
          if (this.action.id.startsWith('audio_')) {
            this.Field(this.audioBitrateText, '音频码率 kbps', (v: string) => this.audioBitrateText = v, true, 0)
          }
          if (this.action.id === 'image_text' || this.action.id === 'video_text') {
            this.Field(this.overlayText, '输入要添加的文字', (v: string) => this.overlayText = v, false, 0)
          }
          if (this.action.id === 'metadata_edit' || this.action.id === 'image_metadata_edit') {
            this.Field(this.metadataTitleText, '标题', (v: string) => this.metadataTitleText = v, false, 0)
            this.Field(this.metadataArtistText, '艺术家', (v: string) => this.metadataArtistText = v, false, 0)
            if (this.action.id === 'metadata_edit') {
              this.Field(this.metadataAlbumArtistText, '专辑艺术家', (v: string) => this.metadataAlbumArtistText = v, false, 0)
              this.Field(this.metadataAlbumText, '专辑', (v: string) => this.metadataAlbumText = v, false, 0)
              this.Field(this.metadataAuthorText, '作者', (v: string) => this.metadataAuthorText = v, false, 0)
              this.Field(this.metadataComposerText, '作曲', (v: string) => this.metadataComposerText = v, false, 0)
              this.Field(this.metadataGenreText, '流派', (v: string) => this.metadataGenreText = v, false, 0)
            }
            this.Field(this.metadataCreationTimeText, '创建时间，例如 2026-09-05T12:00:00Z',
              (v: string) => this.metadataCreationTimeText = v, false, 0)
          }
          if (this.action.id.startsWith('stream_metadata_')) {
            this.Field(this.trackTitleText, '轨道标题', (v: string) => this.trackTitleText = v, false, 0)
            this.Field(this.trackLanguageText, '语言代码，例如 zho、eng', (v: string) => this.trackLanguageText = v, false, 0)
          }
          Row({ space: Dt.spaceSm }) {
            Button('取消').layoutWeight(1).buttonStyle(ButtonStyleMode.NORMAL)
              .onClick(() => this.onClose())
            Button('开始').layoutWeight(1).buttonStyle(ButtonStyleMode.EMPHASIZED)
              .onClick(() => this.enqueueConfiguredAction())
          }
        }
        .alignItems(HorizontalAlign.Start)
        .width('100%')
        .padding(Dt.spaceLg)
      }
    }
    .margin({ bottom: Dt.spaceMd })
  }
}
