import { image } from '@kit.ImageKit';
import { media } from '@kit.MediaKit';
import { fileIo } from '@kit.CoreFileKit';
import { AnalyzedMedia, MediaType, ToolAction } from '../../core/model/MediaTypes';
import { TaskParams } from '../../core/task/MediaTask';
import { native1080pDimensions, nativeMaximumDimensions, estimateTargetBitrateBps } from '../../core/engine/CapabilityRouter';
import { PreviewFrames } from '../../core/media/PreviewFrames';
import { TextOverlay } from '../../core/engine/TextOverlay';
import { Dt } from '../theme/DesignTokens';

export interface TextCornerXY {
  x: number;
  y: number;
}

export function hasAdjustmentPanel(id: string): boolean {
  // gif_crop / gif_resize 归 ActionConfigPanel（含调色板/循环），不在此重复声明
  return ['image_convert', 'image_to_jpeg', 'image_to_png', 'image_to_heif', 'image_compress',
    'image_text', 'video_text', 'image_resize', 'image_crop', 'image_rotate', 'image_flip', 'video_resize', 'video_crop',
    'video_rotate', 'video_flip', 'video_speed', 'video_fps', 'video_loop', 'video_timecode',
    'video_rotation_metadata', 'subtitle_shift_advance', 'subtitle_shift_delay', 'compress_smart',
    'convert_mp4', 'preset_quality', 'preset_balanced', 'preset_small', 'preset_fast', 'hdr_to_sdr'].includes(id);
}

@Component
export struct AdjustmentPanel {
  @StorageProp('windowWidthVp') windowWidthVp: number = 390;
  /** 双栏时右侧已有预览，表单内不再重复画预览。 */
  @Prop showPreview: boolean = true;
  @Prop mediaInfo: AnalyzedMedia;
  @Prop @Watch('resetAction') action: ToolAction;
  onSubmit: (params: TaskParams) => void = () => {};
  onClose: () => void = () => {};
  @State widthText: string = '';
  @State heightText: string = '';
  @State xText: string = '0';
  @State yText: string = '0';
  @State quality: number = 90;
  @State bitrateText: string = '3000';
  @State useVideoBitrate: boolean = false;
  @State audioBitrateText: string = '128';
  @State codec: string = 'AVC';
  @State textValue: string = 'MediaBox媒体工具箱';
  @State fontSizeText: string = '32';
  @State textColor: string = '#FFFFFF';
  /** TL | TR | BL | BR，默认左下 */
  @State textCorner: string = 'BL';
  @State degrees: number = 90;
  @State vertical: boolean = false;
  @State keepRatio: boolean = true;
  @State scalar: string = '1';
  @State format: string = 'image/jpeg';
  @State formats: string[] = ['image/jpeg'];
  @State matteColor: string = '#FFFFFF';
  @State preview?: image.PixelMap = undefined;
  @State previewBusy: boolean = false;
  @State errorText: string = '';
  @State previewStale: boolean = true;
  private alive: boolean = true;
  private previewEpoch: number = 0;

  aboutToAppear(): void { this.resetAction(); }

  private resetAction(): void {
    this.previewEpoch++;
    this.preview?.release();
    this.preview = undefined;
    this.alive = true;
    this.xText = '0'; this.yText = '0'; this.scalar = '1';
    this.textCorner = 'BL';
    this.useVideoBitrate = false; this.codec = 'AVC';
    this.errorText = ''; this.schedulePreview();
    this.format = 'image/jpeg';
    if (this.isImage()) {
      this.formats = image.getImagePackerSupportedFormats().filter((value: string) =>
        ['image/jpeg', 'image/png', 'image/webp', 'image/heif'].includes(value));
      if ((this.crop() || this.resize() || this.flip() || this.isRotation() || this.isText()) &&
        this.mediaInfo.container.toLowerCase().includes('png')) this.format = 'image/png';
    }
    this.widthText = `${this.sourceWidth()}`;
    this.heightText = `${this.sourceHeight()}`;
    if (this.nativeVideo() && this.mediaInfo.video !== undefined) {
      const v = this.mediaInfo.video;
      let dimensions = this.action.id === 'preset_quality' ? nativeMaximumDimensions(v.width, v.height) :
        native1080pDimensions(v.width, v.height);
      if (this.action.id === 'preset_small') {
        const ratio = Math.min(1, 1280 / v.width, 720 / v.height);
        dimensions = { width: Math.max(240, Math.floor(v.width * ratio / 2) * 2),
          height: Math.max(240, Math.floor(v.height * ratio / 2) * 2) };
      }
      this.widthText = `${dimensions.width}`; this.heightText = `${dimensions.height}`;
      this.bitrateText = `${Math.max(80, Math.round(estimateTargetBitrateBps(v.width, v.height,
        v.fps, v.bitrateKbps * 1000, dimensions.width, dimensions.height, v.fps) / 1000))}`;
    }
    if (this.action.id === 'image_convert') this.format = 'image/webp';
    if (this.action.id === 'image_to_png') this.format = 'image/png';
    if (this.action.id === 'image_to_heif') this.format = 'image/heif';
    if (this.action.id === 'image_compress') this.quality = 80;
    if (this.action.id === 'video_fps') this.scalar = `${this.mediaInfo.video?.fps || 30}`;
    if (this.action.id === 'video_loop') this.scalar = '3';
    if (this.action.id === 'video_timecode') this.scalar = '00:00:00:00';
    if (this.action.id.startsWith('subtitle_shift')) this.scalar = '500';
    if (this.visual()) this.updatePreview();
    if (this.isText()) this.applyCorner();
  }

  private nativeVideo(): boolean {
    return this.action.id === 'compress_smart' || this.action.id === 'convert_mp4' ||
      this.action.id.startsWith('preset_') || this.action.id === 'hdr_to_sdr';
  }

  private formatLabel(format: string): string {
    return format.substring(format.indexOf('/') + 1).toUpperCase();
  }

  private sourceWidth(): number { return this.mediaInfo.video?.width ?? this.mediaInfo.imageWidth; }
  private sourceHeight(): number { return this.mediaInfo.video?.height ?? this.mediaInfo.imageHeight; }
  private isImage(): boolean { return this.mediaInfo.mediaType === MediaType.IMAGE; }
  private crop(): boolean { return this.action.id.endsWith('_crop'); }
  private resize(): boolean { return this.action.id.endsWith('_resize') || this.nativeVideo(); }
  private isRotation(): boolean { return this.action.id.endsWith('_rotate'); }
  private flip(): boolean { return this.action.id.endsWith('_flip'); }
  private isText(): boolean { return this.action.id === 'image_text' || this.action.id === 'video_text'; }
  private visual(): boolean { return this.isText() || this.nativeVideo() || this.isImage() || this.crop() || this.resize() || this.isRotation() || this.flip(); }

  /** 按四角计算文字左上角坐标（产品默认左下）。 */
  private cornerXY(): TextCornerXY {
    const fs = Math.max(1, Number(this.fontSizeText) || 32);
    const pad = 24;
    const sw = this.sourceWidth();
    const sh = this.sourceHeight();
    switch (this.textCorner) {
      case 'TR':
        return { x: Math.max(0, sw - fs * this.textValue.length - pad), y: pad };
      case 'BR':
        return { x: Math.max(0, sw - fs * this.textValue.length - pad), y: Math.max(0, sh - fs - pad) };
      case 'TL':
        return { x: pad, y: pad };
      default:
        return { x: pad, y: Math.max(0, sh - fs - pad) };
    }
  }

  private applyCorner(): void {
    if (!this.isText()) {
      return;
    }
    const xy = this.cornerXY();
    this.xText = `${xy.x}`;
    this.yText = `${xy.y}`;
    this.schedulePreview();
  }

  private previewTimer: number = -1;

  private schedulePreview(): void {
    this.previewStale = true;
    this.desiredRevision++;
    if (this.previewTimer >= 0) {
      clearTimeout(this.previewTimer);
    }
    this.previewTimer = setTimeout(() => {
      if (this.alive) {
        this.updatePreview();
      }
    }, 350);
  }

  private desiredRevision: number = 0;
  private renderedRevision: number = 0;

  aboutToDisappear(): void {
    this.alive = false;
    if (this.previewTimer >= 0) {
      clearTimeout(this.previewTimer);
    }
    this.previewEpoch++;
    this.preview?.release();
    this.preview = undefined;
  }

  private params(): TaskParams {
    const w = Number(this.widthText), h = Number(this.heightText);
    let x = Number(this.xText), y = Number(this.yText);
    const scalar = Number(this.scalar);
    if (this.isText()) {
      const xy = this.cornerXY();
      x = xy.x;
      y = xy.y;
    }
    if ((this.crop() || this.resize()) && (![w, h, x, y].every((n: number) => Number.isInteger(n)) ||
      w <= 0 || h <= 0 || x < 0 || y < 0 || w > 16384 || h > 16384)) {
      throw new Error('尺寸必须为 1–16384 的整数，裁剪坐标不能为负数');
    }
    if (this.crop() && (x + w > this.sourceWidth() || y + h > this.sourceHeight())) {
      throw new Error('裁剪区域超出原始画面');
    }
    if (this.mediaInfo.mediaType === MediaType.VIDEO && (this.crop() || this.resize()) && (w % 2 !== 0 || h % 2 !== 0)) {
      throw new Error('视频输出宽高需为偶数');
    }
    if (this.mediaInfo.mediaType === MediaType.VIDEO && this.crop() && (x % 2 !== 0 || y % 2 !== 0)) {
      throw new Error('视频裁剪 X、Y 使用偶数像素，避免色度采样导致位置取整');
    }
    if (this.useVideoBitrate && (!Number.isFinite(Number(this.bitrateText)) || Number(this.bitrateText) < 80)) {
      throw new Error('视频码率至少为 80 kbps');
    }
    if (this.action.id === 'video_speed' && (!Number.isFinite(scalar) || scalar < 0.5 || scalar > 2)) {
      throw new Error('速度倍率范围为 0.5–2');
    }
    if (this.action.id === 'video_fps' && (!Number.isFinite(scalar) || scalar < 1 || scalar > 120)) {
      throw new Error('帧率范围为 1–120 FPS');
    }
    if (this.action.id === 'video_loop' && (!Number.isInteger(scalar) || scalar < 1 || scalar > 100)) {
      throw new Error('播放次数范围为 1–100');
    }
    if (this.action.id === 'video_timecode' && !/^\d{2}:[0-5]\d:[0-5]\d:\d{2}$/.test(this.scalar)) {
      throw new Error('时间码格式为 HH:MM:SS:FF');
    }
    if (this.action.id.startsWith('subtitle_shift') && (!Number.isFinite(scalar) || scalar < 0)) {
      throw new Error('字幕偏移请输入非负毫秒数');
    }
    if (this.isImage() && !/^#[0-9a-fA-F]{6}$/.test(this.matteColor)) {
      throw new Error('背景色格式为 #RRGGBB');
    }
    if (this.isText() && (!this.textValue.trim() || !/^#[0-9a-fA-F]{6}$/.test(this.textColor) ||
      !Number.isFinite(Number(this.fontSizeText)) || Number(this.fontSizeText) < 1 || Number(this.fontSizeText) > 1024 ||
      ![x, y].every((n: number) => Number.isFinite(n) && n >= 0) || x >= this.sourceWidth() || y >= this.sourceHeight())) {
      throw new Error('请检查文字、颜色、字号 1–1024 及画面内坐标');
    }
    if (this.nativeVideo() && (w < 240 || h < 240 || w > 3840 || h > 2160 ||
      !Number.isFinite(Number(this.bitrateText)) || Number(this.bitrateText) < 80 ||
      !Number.isFinite(Number(this.audioBitrateText)) || Number(this.audioBitrateText) < 1 ||
      Number(this.audioBitrateText) > 500)) {
      throw new Error('原生转码宽度 240–3840，高度 240–2160；视频至少 80 kbps，音频 1–500 kbps');
    }
    return {
      textOverlay: this.isText() ? this.textValue : undefined,
      textX: x, textY: y, textCorner: this.isText() ? this.textCorner : undefined,
      textFontSize: Number(this.fontSizeText), textColor: this.textColor,
      textCanvasWidth: this.sourceWidth(), textCanvasHeight: this.sourceHeight(),
      targetVideoKbps: this.nativeVideo() || this.useVideoBitrate ? Number(this.bitrateText) : undefined,
      targetAudioKbps: this.nativeVideo() && this.mediaInfo.audio !== undefined ? Number(this.audioBitrateText) : undefined,
      targetVideoCodec: this.action.id === 'hdr_to_sdr' ? 'AVC' : this.codec,
      targetContainer: this.nativeVideo() ? 'MP4' : undefined,
      targetWidth: this.resize() ? w : undefined, targetHeight: this.resize() ? h : undefined,
      cropX: this.crop() ? x : undefined, cropY: this.crop() ? y : undefined,
      cropWidth: this.crop() ? w : undefined, cropHeight: this.crop() ? h : undefined,
      imageRotateDegrees: this.isRotation() || this.action.id === 'video_rotation_metadata' ? this.degrees : undefined,
      imageFlipHorizontal: this.flip() ? !this.vertical : undefined,
      imageFlipVertical: this.flip() ? this.vertical : undefined,
      imageFormat: this.isImage() ? this.format : undefined,
      imageQuality: this.isImage() ? Math.round(this.quality) : undefined,
      imageBackgroundColor: this.matteColor,
      speed: this.action.id === 'video_speed' ? scalar : undefined,
      targetFps: this.action.id === 'video_fps' ? scalar : undefined,
      loopCount: this.action.id === 'video_loop' ? `${scalar - 1}` : undefined,
      timecode: this.action.id === 'video_timecode' ? this.scalar : undefined,
      subtitleDelaySeconds: this.action.id.startsWith('subtitle_shift') ?
        scalar / 1000 * (this.action.id.endsWith('advance') ? -1 : 1) : undefined,
      streamKind: this.mediaInfo.audio !== undefined ? 'av' : 'video'
    };
  }

  private submit(): void {
    try { this.onSubmit(this.params()); } catch (e) { this.errorText = (e as Error).message; }
  }

  private changeWidth(value: string): void {
    this.widthText = value;
    this.syncPeerDimension('w');
    this.schedulePreview();
  }

  private changeHeight(value: string): void {
    this.heightText = value;
    this.syncPeerDimension('h');
    this.schedulePreview();
  }

  /** 锁定比例时双向换算；视频输出取偶数。 */
  private syncPeerDimension(edited: string): void {
    if (!this.keepRatio || !this.resize()) {
      return;
    }
    const sw = this.sourceWidth();
    const sh = this.sourceHeight();
    if (sw <= 0 || sh <= 0) {
      return;
    }
    const ratio = sw / sh;
    if (edited === 'w') {
      const w = Number(this.widthText);
      if (!Number.isFinite(w) || w <= 0) {
        return;
      }
      let h = w / ratio;
      if (this.mediaInfo.mediaType === MediaType.VIDEO) {
        h = Math.round(h / 2) * 2;
      } else {
        h = Math.round(h);
      }
      this.heightText = `${Math.max(1, h)}`;
    } else {
      const h = Number(this.heightText);
      if (!Number.isFinite(h) || h <= 0) {
        return;
      }
      let w = h * ratio;
      if (this.mediaInfo.mediaType === MediaType.VIDEO) {
        w = Math.round(w / 2) * 2;
      } else {
        w = Math.round(w);
      }
      this.widthText = `${Math.max(1, w)}`;
    }
  }

  private async updatePreview(): Promise<void> {
    if (this.previewBusy) {
      return;
    }
    this.previewBusy = true;
    this.errorText = '';
    const wanted = this.desiredRevision;
    let pixels: image.PixelMap | undefined;
    try {
      const p = this.params();
      const settings = JSON.stringify(p);
      const epoch = this.previewEpoch;
      pixels = await PreviewFrames.load(this.mediaInfo);
      if (epoch !== this.previewEpoch) {
        return;
      }
      const info = await pixels.getImageInfo();
      if (this.crop()) {
        const sx = info.size.width / this.sourceWidth(), sy = info.size.height / this.sourceHeight();
        const px = Math.floor((p.cropX ?? 0) * sx), py = Math.floor((p.cropY ?? 0) * sy);
        await pixels.crop({ x: px, y: py, size: {
          width: Math.max(1, Math.min(info.size.width - px, Math.round((p.cropWidth ?? 1) * sx))),
          height: Math.max(1, Math.min(info.size.height - py, Math.round((p.cropHeight ?? 1) * sy))) } });
      }
      if (this.resize()) {
        const outputRatio = Math.min(1, 960 / Math.max(p.targetWidth ?? 1, p.targetHeight ?? 1));
        await pixels.scale((p.targetWidth ?? 1) * outputRatio / info.size.width,
          (p.targetHeight ?? 1) * outputRatio / info.size.height);
      }
      if (this.isText()) {
        TextOverlay.draw(pixels, p, info.size.width / this.sourceWidth(), info.size.height / this.sourceHeight());
      }
      if (this.isRotation()) {
        await pixels.rotate(p.imageRotateDegrees ?? 0);
      }
      if (this.flip()) {
        await pixels.flip(p.imageFlipHorizontal ?? false, p.imageFlipVertical ?? false);
      }
      // 只在参数未再变化时采纳，避免旧请求覆盖新结果
      if (this.alive && epoch === this.previewEpoch && settings === JSON.stringify(this.params())) {
        const old = this.preview;
        this.preview = pixels;
        pixels = undefined;
        await old?.release();
        this.renderedRevision = wanted;
        this.previewStale = false;
      }
    } catch (e) {
      this.errorText = `预览失败：${(e as Error).message}`;
    } finally {
      await pixels?.release();
      this.previewBusy = false;
      // 渲染期间用户又改了参数：立刻补跑最新
      if (this.alive && this.desiredRevision > this.renderedRevision) {
        this.updatePreview();
      }
    }
  }

  @Builder
  NumberField(label: string, value: string, changed: (text: string) => void) {
    Column({ space: 4 }) {
      Text(label).fontSize(Dt.fontCaption).width('100%')
      TextInput({ text: value }).type(InputType.Number).onChange(changed)
    }.layoutWeight(1)
  }

  build() {
    Column({ space: Dt.spaceMd }) {
      // 标题由 HdsNavDestination 提供，面板内不再重复
      Text('参数').fontSize(Dt.fontCaption).fontColor($r('app.color.text_secondary')).width('100%')
      if (this.showPreview && this.visual()) {
        if (this.preview !== undefined) {
          Image(this.preview).objectFit(ImageFit.Contain).height(this.windowWidthVp < 600 ? 180 : 240).width('100%')
            .backgroundColor('#181818')
        }
        Text(this.previewBusy ? '正在更新预览…' : '预览随参数自动更新')
          .fontSize(Dt.fontCaption).fontColor($r('app.color.text_secondary'))
      }
      if (this.isText()) {
        Text('文字内容').fontSize(Dt.fontCaption)
        TextInput({ text: this.textValue }).onChange((v: string) => { this.textValue = v; this.applyCorner(); })
        Text('位置').fontSize(Dt.fontCaption)
        Select([{ value: '左上' }, { value: '右上' }, { value: '左下' }, { value: '右下' }])
          .selected(['TL', 'TR', 'BL', 'BR'].indexOf(this.textCorner))
          .value(this.textCorner === 'BL' ? '左下' :
            (this.textCorner === 'BR' ? '右下' : (this.textCorner === 'TR' ? '右上' : '左上')))
          .onSelect((i: number) => {
            this.textCorner = ['TL', 'TR', 'BL', 'BR'][i];
            this.applyCorner();
          })
        Row({ space: 8 }) {
          this.NumberField('字号 px', this.fontSizeText, (v: string) => { this.fontSizeText = v; this.applyCorner(); })
        }
        .width('100%')
        Text('颜色').fontSize(Dt.fontCaption)
        Flex({ wrap: FlexWrap.Wrap }) {
          ForEach(['#FFFFFF', '#000000', '#E53935', '#FB8C00', '#FDD835',
            '#43A047', '#00ACC1', '#1E88E5', '#8E24AA', '#D81B60'], (c: string) => {
            Button()
              .width(Dt.touchMin)
              .height(Dt.touchMin)
              .backgroundColor(c)
              .borderRadius(24)
              .border({ width: this.textColor.toUpperCase() === c ? 2 : 0.5,
                color: this.textColor.toUpperCase() === c ? $r('app.color.accent') : $r('app.color.divider') })
              .onClick(() => {
                this.textColor = c;
                this.schedulePreview();
              })
            Row().width(4)
          }, (c: string) => c)
        }
        .width('100%')
        Text(`当前 ${this.textColor}`).fontSize(Dt.fontCaption)
          .fontColor($r('app.color.text_secondary'))
      }
      if (this.crop() || this.resize()) {
        Text(`原始尺寸 ${this.sourceWidth()} × ${this.sourceHeight()}`).fontSize(Dt.fontCaption)
        Row({ space: 8 }) {
          this.NumberField('宽度 px', this.widthText, (v: string) => this.changeWidth(v))
          this.NumberField('高度 px', this.heightText, (v: string) => this.changeHeight(v))
        }
        if (this.resize()) {
          Row({ space: 8 }) {
            Toggle({ type: ToggleType.Checkbox, isOn: this.keepRatio }).onChange((v: boolean) => {
              this.keepRatio = v;
              if (v) {
                this.syncPeerDimension('w');
                this.schedulePreview();
              }
            })
            Text('保持宽高比').fontSize(Dt.fontCaption)
          }
        }
        if (this.crop()) {
          Button('裁剪区域居中').onClick(() => {
            const step = this.mediaInfo.mediaType === MediaType.VIDEO ? 2 : 1;
            this.xText = `${Math.max(0, Math.floor((this.sourceWidth() - Number(this.widthText)) / 2 / step) * step)}`;
            this.yText = `${Math.max(0, Math.floor((this.sourceHeight() - Number(this.heightText)) / 2 / step) * step)}`;
            this.schedulePreview();
          })
          Row({ space: 8 }) {
            this.NumberField('左侧 X', this.xText, (v: string) => { this.xText = v; this.schedulePreview(); })
            this.NumberField('顶部 Y', this.yText, (v: string) => { this.yText = v; this.schedulePreview(); })
          }
        }
      }
      if (this.isRotation() || this.action.id === 'video_rotation_metadata') {
        Select([{ value: '0°' }, { value: '90°' }, { value: '180°' }, { value: '270°' }])
          .selected(this.degrees / 90).value(`${this.degrees}°`)
          .onSelect((i: number) => { this.degrees = i * 90; this.schedulePreview(); })
      }
      if (this.flip()) {
        Select([{ value: '水平镜像' }, { value: '垂直镜像' }]).selected(this.vertical ? 1 : 0)
          .value(this.vertical ? '垂直镜像' : '水平镜像')
          .onSelect((i: number) => { this.vertical = i === 1; this.schedulePreview(); })
      }
      if (this.mediaInfo.mediaType === MediaType.VIDEO && !this.nativeVideo() &&
        !['video_loop', 'video_timecode', 'video_rotation_metadata'].includes(this.action.id)) {
        Row({ space: 8 }) {
          Toggle({ type: ToggleType.Checkbox, isOn: this.useVideoBitrate })
            .onChange((value: boolean) => this.useVideoBitrate = value)
          Text('自定义视频码率').fontSize(Dt.fontCaption)
        }
        if (this.useVideoBitrate) {
          TextInput({ text: this.bitrateText, placeholder: '视频码率 kbps' }).type(InputType.Number)
            .onChange((v: string) => this.bitrateText = v)
        }
      }
      if (this.nativeVideo()) {
        Text('原生视频转码 · MP4').fontSize(Dt.fontCaption)
        Row({ space: 8 }) {
          this.NumberField('视频 kbps', this.bitrateText, (v: string) => this.bitrateText = v)
          if (this.mediaInfo.audio !== undefined) {
            this.NumberField('音频 kbps', this.audioBitrateText, (v: string) => this.audioBitrateText = v)
          }
        }
        if (this.action.id !== 'hdr_to_sdr') {
          Select([{ value: 'H.264 / AVC' }, { value: 'H.265 / HEVC' }])
            .selected(this.codec === 'AVC' ? 0 : 1).value(this.codec)
            .onSelect((i: number) => this.codec = i === 0 ? 'AVC' : 'HEVC')
        }
      }
      if (this.isImage()) {
        if (!['image_convert', 'image_to_jpeg', 'image_to_png', 'image_to_heif'].includes(this.action.id)) {
          Select(this.formats.map((value: string): SelectOption => { return { value: this.formatLabel(value) }; }))
            .value(this.formatLabel(this.format)).selected(this.formats.indexOf(this.format))
            .onSelect((index: number) => this.format = this.formats[index])
        }
        if (this.format !== 'image/png') {
          Text(`编码质量 ${Math.round(this.quality)} / 100`).fontSize(Dt.fontCaption)
          Slider({ value: this.quality, min: 1, max: 100, step: 1 })
            .onChange((v: number) => { this.quality = v; this.schedulePreview(); })
        }
        Text(`输出格式：${this.formatLabel(this.format)}；重新编码将移除源元数据`).fontSize(Dt.fontCaption)
        if (this.format === 'image/jpeg') {
          Text('透明区域背景色').fontSize(Dt.fontCaption)
          TextInput({ text: this.matteColor, placeholder: '#RRGGBB' }).onChange((v: string) => this.matteColor = v)
        }
      }
      if (!this.visual() && this.action.id !== 'video_rotation_metadata') {
        Text(this.action.id === 'video_speed' ? '速度倍率 0.5–2' :
          (this.action.id === 'video_fps' ? '输出帧率 FPS' :
            (this.action.id === 'video_loop' ? '总播放次数（包含原始一遍）' :
              (this.action.id === 'video_timecode' ? '起始时间码 HH:MM:SS:FF' : '偏移毫秒数'))))
          .fontSize(Dt.fontCaption)
        TextInput({ text: this.scalar }).onChange((v: string) => this.scalar = v)
      }
      if (this.errorText.length > 0) Text(this.errorText).fontColor($r('app.color.danger_red'))
      Button('开始导出')
        .width('100%')
        .buttonStyle(ButtonStyleMode.EMPHASIZED)
        .onClick(() => this.submit())
    }.alignItems(HorizontalAlign.Start).width('100%').padding(Dt.spaceLg).borderRadius(Dt.radiusLg)
      .backgroundColor($r('app.color.surface_card'))
  }
}
