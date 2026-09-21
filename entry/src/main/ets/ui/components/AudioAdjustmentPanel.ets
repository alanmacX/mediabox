import { AnalyzedMedia, ToolAction } from '../../core/model/MediaTypes';
import { TaskParams } from '../../core/task/MediaTask';
import { Dt } from '../theme/DesignTokens';

export function hasAudioAdjustment(id: string): boolean {
  return ['extract_audio', 'extract_audio_mp3', 'audio_convert', 'audio_to_mp3', 'audio_to_wav', 'audio_to_flac', 'audio_to_opus',
    'audio_to_ogg',
    'audio_normalize', 'audio_peak_normalize', 'audio_remove_silence', 'audio_silence_detect',
    'audio_volume', 'audio_fade', 'audio_mono', 'audio_stereo', 'audio_resample'].includes(id);
}

@Component
export struct AudioAdjustmentPanel {
  @Prop mediaInfo: AnalyzedMedia;
  @Prop @Watch('resetAction') action: ToolAction;
  onSubmit: (params: TaskParams) => void = () => {};
  onClose: () => void = () => {};
  @State bitrate: string = '192';
  @State sampleRate: string = '48000';
  @State channels: number = 0;
  @State volume: string = '1';
  @State lufs: string = '-16';
  @State peak: string = '-1.5';
  @State range: string = '11';
  @State fadeIn: string = '2';
  @State fadeOut: string = '2';
  @State noise: string = '-35';
  @State silenceDuration: string = '0.5';
  @State format: string = 'm4a';
  @State errorText: string = '';

  private between(text: string, low: number, high: number): number {
    const number = Number(text);
    if (text.trim().length === 0 || !Number.isFinite(number) || number < low || number > high) {
      throw new Error(`参数范围为 ${low}–${high}`);
    }
    return number;
  }

  private submit(): void {
    try {
      const params: TaskParams = {};
      const id = this.action.id;
      const lossless = id === 'audio_to_wav' || id === 'audio_to_flac';
      if (id !== 'audio_silence_detect') {
        if (!lossless) params.targetAudioKbps = this.between(this.bitrate, 8, 500);
        params.targetSampleRateHz = id === 'audio_to_opus' ? 48000 : this.between(this.sampleRate, 8000, 96000);
        if (![8000, 16000, 22050, 32000, 44100, 48000, 96000].includes(params.targetSampleRateHz)) {
          throw new Error('采样率支持 8000 / 16000 / 22050 / 32000 / 44100 / 48000 / 96000');
        }
        params.targetChannels = id === 'audio_mono' ? 1 : (id === 'audio_stereo' ? 2 :
          (this.channels === 0 ? undefined : this.channels));
      }
      if (id === 'extract_audio') params.targetContainer = this.format;
      if (id === 'audio_volume') params.volumeMultiplier = this.between(this.volume, 0, 10);
      if (id === 'audio_normalize') {
        params.loudnessLufs = this.between(this.lufs, -70, -5);
        params.truePeakDb = this.between(this.peak, -9, 0);
        params.loudnessRange = this.between(this.range, 1, 50);
      }
      if (id === 'audio_peak_normalize') params.peakLevel = this.between(this.volume, 0.01, 0.99);
      if (id === 'audio_fade') {
        const duration = this.mediaInfo.durationMs / 1000;
        if (duration <= 0) throw new Error('无法读取媒体时长，不能定位淡出边界');
        params.fadeInSeconds = this.between(this.fadeIn, 0, duration);
        params.fadeOutSeconds = this.between(this.fadeOut, 0, duration);
        params.durationSeconds = `${duration}`;
      }
      if (id === 'audio_silence_detect' || id === 'audio_remove_silence') {
        params.silenceThresholdDb = this.between(this.noise, -100, 0);
        params.silenceDurationSeconds = this.between(this.silenceDuration, 0.01, 3600);
      }
      this.onSubmit(params);
    } catch (e) { this.errorText = (e as Error).message; }
  }

  aboutToAppear(): void { this.resetAction(); }

  private resetAction(): void {
    this.errorText = '';
    this.volume = '1';
    if (this.mediaInfo.audio?.sampleRateHz) this.sampleRate = `${this.mediaInfo.audio.sampleRateHz}`;
    if (this.action.id === 'audio_peak_normalize') this.volume = '0.95';
  }

  @Builder
  Field(label: string, value: string, change: (text: string) => void) {
    Text(label).fontSize(Dt.fontCaption).width('100%')
    TextInput({ text: value }).onChange(change)
  }

  build() {
    Column({ space: Dt.spaceMd }) {
      // 标题由 HdsNavDestination 提供
      Text('音频参数').fontSize(Dt.fontCaption).fontColor($r('app.color.text_secondary')).width('100%')
      if (this.action.id === 'extract_audio') {
        Text('提取首条音轨并重新编码；保留原编码请使用媒体流提取').fontSize(Dt.fontCaption)
        Select([{ value: 'M4A / AAC' }, { value: 'WAV / PCM' }, { value: 'FLAC' }, { value: 'MP3' }])
          .selected(['m4a', 'wav', 'flac', 'mp3'].indexOf(this.format)).value(this.format)
          .onSelect((index: number) => this.format = ['m4a', 'wav', 'flac', 'mp3'][index])
      }
      if (this.action.id !== 'audio_silence_detect') {
        if (!['audio_to_wav', 'audio_to_flac'].includes(this.action.id) &&
          !(this.action.id === 'extract_audio' && this.format !== 'm4a')) {
          this.Field('音频码率 kbps', this.bitrate, (v: string) => this.bitrate = v)
        }
        if (this.action.id === 'audio_to_opus') {
          Text('Opus 输出采样率：48000 Hz').fontSize(Dt.fontCaption)
        } else {
          this.Field('采样率 Hz', this.sampleRate, (v: string) => this.sampleRate = v)
        }
        if (!['audio_mono', 'audio_stereo'].includes(this.action.id)) {
          Select([{ value: '保留声道' }, { value: '单声道' }, { value: '立体声' }]).selected(this.channels)
            .value(['保留声道', '单声道', '立体声'][this.channels]).onSelect((i: number) => this.channels = i)
        }
      }
      if (this.action.id === 'audio_volume') this.Field('音量倍率 0–10', this.volume, (v: string) => this.volume = v)
      if (this.action.id === 'audio_peak_normalize') {
        this.Field('动态峰值目标 0.01–0.99', this.volume, (v: string) => this.volume = v)
      }
      if (this.action.id === 'audio_normalize') {
        this.Field('目标响度 LUFS', this.lufs, (v: string) => this.lufs = v)
        this.Field('真峰值上限 dBTP', this.peak, (v: string) => this.peak = v)
        this.Field('响度范围 LRA', this.range, (v: string) => this.range = v)
      }
      if (this.action.id === 'audio_fade') {
        this.Field('淡入秒数', this.fadeIn, (v: string) => this.fadeIn = v)
        this.Field('淡出秒数', this.fadeOut, (v: string) => this.fadeOut = v)
        Text('对完整音频处理，不截成固定的 30 秒').fontSize(Dt.fontCaption)
      }
      if (this.action.id === 'audio_silence_detect' || this.action.id === 'audio_remove_silence') {
        this.Field('静音阈值 dB', this.noise, (v: string) => this.noise = v)
        this.Field('最短静音秒数', this.silenceDuration, (v: string) => this.silenceDuration = v)
      }
      if (this.errorText.length > 0) Text(this.errorText).fontColor($r('app.color.danger_red'))
      Button('开始导出')
        .width('100%')
        .buttonStyle(ButtonStyleMode.EMPHASIZED)
        .onClick(() => this.submit())
    }.alignItems(HorizontalAlign.Start).padding(Dt.spaceLg).width('100%').borderRadius(Dt.radiusLg).backgroundColor($r('app.color.surface_card'))
  }
}
