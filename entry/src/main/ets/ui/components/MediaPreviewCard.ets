/**
 * 预览卡 — 对齐 web preview：媒体画面 + 文件名 + chips。
 */
import { image } from '@kit.ImageKit';
import { AnalyzedMedia, Fmt, MediaType, ToolSymbol } from '../../core/model/MediaTypes';
import { SystemSymbolIcon } from './SystemSymbolIcon';
import { GlassCard } from './GlassCard';
import { Dt } from '../theme/DesignTokens';

@Component
export struct MediaPreviewCard {
  @Prop media: AnalyzedMedia | undefined;
  @Prop thumbnail?: image.PixelMap = undefined;
  @Prop height: number = Dt.previewH;

  private chips(): string[] {
    const m = this.media;
    if (m === undefined) {
      return [];
    }
    const list: string[] = [];
    if (m.video !== undefined) {
      list.push(`${m.video.width}×${m.video.height}`);
      if (m.video.fps > 0) {
        list.push(`${m.video.fps}FPS`);
      }
      list.push(m.video.codec);
      if (m.video.hdr) {
        list.push('HDR');
      }
    }
    if (m.imageWidth > 0) {
      list.push(`${m.imageWidth}×${m.imageHeight}`);
    }
    if (m.audio !== undefined) {
      list.push(m.audio.codec.length > 0 ? m.audio.codec : 'Audio');
    }
    if (m.durationMs > 0) {
      list.push(Fmt.duration(m.durationMs));
    }
    if (m.sizeBytes > 0) {
      list.push(Fmt.bytes(m.sizeBytes));
    }
    return list;
  }

  private typeLabel(): string {
    const m = this.media;
    if (m === undefined) {
      return '';
    }
    if (m.isMovingPhoto) {
      return '动态照片';
    }
    switch (m.mediaType) {
      case MediaType.VIDEO:
        return '视频';
      case MediaType.IMAGE:
        return '图片';
      case MediaType.GIF:
        return 'GIF';
      case MediaType.AUDIO:
        return '音频';
      case MediaType.SUBTITLE:
        return '字幕';
      default:
        return '媒体';
    }
  }

  @Builder
  Body() {
    Column({ space: Dt.spaceSm }) {
      Stack() {
        if (this.media !== undefined && this.media.mediaType === MediaType.GIF &&
          !this.media.isMovingPhoto && this.thumbnail === undefined) {
          Image(this.media.uri)
            .objectFit(ImageFit.Contain)
            .width('100%')
            .height(this.height)
            .borderRadius(Dt.radiusMd)
            .backgroundColor('#1B1D22')
            .autoResize(false)
        } else if (this.thumbnail !== undefined) {
          // 动态照片关键帧 / 图片 / 视频封面
          Image(this.thumbnail)
            .objectFit(ImageFit.Contain)
            .width('100%')
            .height(this.height)
            .borderRadius(Dt.radiusMd)
            .backgroundColor('#1B1D22')
        } else if (this.media !== undefined && !this.media.isMovingPhoto &&
          this.media.mediaType === MediaType.IMAGE) {
          Image(this.media.uri)
            .objectFit(ImageFit.Contain)
            .width('100%')
            .height(this.height)
            .borderRadius(Dt.radiusMd)
            .backgroundColor('#1B1D22')
        } else if (this.media !== undefined && this.media.isMovingPhoto) {
          Column({ space: Dt.spaceSm }) {
            SystemSymbolIcon({ name: ToolSymbol.IMAGE, iconSize: 36, color: $r('app.color.accent') })
            Text('动态照片关键帧加载中…')
              .fontSize(Dt.fontCaption)
              .fontColor($r('app.color.text_secondary'))
          }
          .width('100%')
          .height(this.height)
          .justifyContent(FlexAlign.Center)
          .alignItems(HorizontalAlign.Center)
          .borderRadius(Dt.radiusMd)
          .backgroundColor('#1B1D22')
        } else if (this.media !== undefined && this.media.mediaType === MediaType.AUDIO) {
          Column({ space: Dt.spaceSm }) {
            SystemSymbolIcon({ name: ToolSymbol.AUDIO, iconSize: 36, color: $r('app.color.accent') })
            Text(`${this.media.audio?.codec ?? '音频'} · ${Fmt.duration(this.media.durationMs)}`)
              .fontSize(Dt.fontCaption)
              .fontColor($r('app.color.text_secondary'))
          }
          .width('100%')
          .height(this.height)
          .justifyContent(FlexAlign.Center)
          .alignItems(HorizontalAlign.Center)
          .borderRadius(Dt.radiusMd)
          .backgroundColor('#1B1D22')
        } else {
          Row() {
            SystemSymbolIcon({ name: ToolSymbol.FILE, iconSize: 28,
              color: $r('app.color.text_secondary') })
          }
          .width('100%')
          .height(this.height)
          .justifyContent(FlexAlign.Center)
          .borderRadius(Dt.radiusMd)
          .backgroundColor('#1B1D22')
        }
      }
      .width('100%')

      Text(this.media?.displayName ?? '')
        .fontSize(Dt.fontSub)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')

      Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Start }) {
        ForEach(this.chips(), (c: string) => {
          Text(c)
            .fontSize(Dt.fontCaption)
            .fontColor($r('app.color.text_secondary'))
            .padding({ left: 8, right: 8, top: 4, bottom: 4 })
            .borderRadius(Dt.radiusSm)
            .backgroundColor($r('app.color.accent_soft'))
            .margin({ right: Dt.spaceSm, bottom: Dt.spaceSm })
        }, (c: string) => c)
      }
      .width('100%')
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
  }

  build() {
    GlassCard({ radius: Dt.radiusXl, paddingV: Dt.spaceLg }) {
      this.Body()
    }
  }
}
