/**
 * 媒体预览块 — 固定高度、深色底、视频使用静态封面。
 *
 * 不能在工作流页面常驻 Video：它会持有同一视频的解码器，和 AVTranscoder 的
 * 硬件编解码资源竞争；表现为前台任务卡住、关闭页面/应用后才继续。
 * 动态照片：优先展示系统关键帧缩略图，不直接解码 moving URI。
 */
import { AnalyzedMedia, MediaType, ToolSymbol, Fmt } from '../../core/model/MediaTypes';
import { SystemSymbolIcon } from './SystemSymbolIcon';
import { Dt } from '../theme/DesignTokens';
import { image } from '@kit.ImageKit';

@Component
export struct MediaPreview {
  @Prop media?: AnalyzedMedia = undefined;
  @Prop thumbnail?: image.PixelMap = undefined;
  /** 沙箱预览图 URI（PixelMap 经 @Prop 深拷贝会渲染异常，预览统一走文件 URI）。 */
  @Prop previewUri: string = '';
  @Prop subtitlePreview: string = '';
  @Prop heightVp: number = Dt.previewH;

  build() {
    Stack() {
      if (this.media !== undefined && this.media.mediaType === MediaType.GIF &&
        !this.media.isMovingPhoto && this.thumbnail === undefined) {
        Image(this.media.uri)
          .objectFit(ImageFit.Contain)
          .width('100%')
          .height(this.heightVp)
          .borderRadius(Dt.radiusSm)
          .backgroundColor('#181818')
          .autoResize(false)
      } else if (this.previewUri.length > 0) {
        // 普通图片 / 动态照片关键帧 / 视频封面：统一走沙箱预览图
        Image(this.previewUri)
          .objectFit(ImageFit.Contain)
          .width('100%')
          .height(this.heightVp)
          .borderRadius(Dt.radiusSm)
          .backgroundColor('#181818')
          .autoResize(false)
      } else if (this.thumbnail !== undefined) {
        // 兜底：直接渲染 PixelMap（部分设备上 @Prop 拷贝会黑图）
        Image(this.thumbnail)
          .objectFit(ImageFit.Contain)
          .width('100%')
          .height(this.heightVp)
          .borderRadius(Dt.radiusSm)
          .backgroundColor('#181818')
      } else if (this.media !== undefined && !this.media.isMovingPhoto &&
        this.media.mediaType === MediaType.IMAGE) {
        Image(this.media.uri)
          .objectFit(ImageFit.Contain)
          .width('100%')
          .height(this.heightVp)
          .borderRadius(Dt.radiusSm)
          .backgroundColor('#181818')
      } else if (this.media !== undefined && this.media.isMovingPhoto) {
        // 关键帧尚未就绪：占位，避免用不可靠的 moving URI 直接 Image()
        Column({ space: Dt.spaceSm }) {
          SystemSymbolIcon({ name: ToolSymbol.IMAGE, iconSize: 40, color: $r('app.color.accent') })
          Text('动态照片关键帧加载中…')
            .fontSize(Dt.fontCaption)
            .fontColor($r('app.color.text_secondary'))
        }
        .width('100%')
        .height(this.heightVp)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .borderRadius(Dt.radiusSm)
        .backgroundColor('#181818')
      } else if (this.media !== undefined && this.media.mediaType === MediaType.AUDIO) {
        Column({ space: Dt.spaceSm }) {
          SystemSymbolIcon({ name: ToolSymbol.AUDIO, iconSize: 40, color: $r('app.color.accent') })
          Text('音频文件').fontSize(Dt.fontCaption).fontColor($r('app.color.text_secondary'))
          if (this.media.audio !== undefined) {
            Text(`${this.media.audio.codec} · ${Fmt.duration(this.media.durationMs)}`)
              .fontSize(Dt.fontCaption).fontColor($r('app.color.text_secondary'))
          }
        }
        .width('100%')
        .height(this.heightVp)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .borderRadius(Dt.radiusSm)
        .backgroundColor('#181818')
      } else if (this.media !== undefined && this.media.mediaType === MediaType.SUBTITLE) {
        Text(this.subtitlePreview.length > 0 ? this.subtitlePreview : '正在读取字幕')
          .fontSize(Dt.fontCaption)
          .fontColor($r('app.color.text_secondary'))
          .fontFamily('monospace')
          .maxLines(12)
          .width('100%')
          .height(this.heightVp)
          .padding(Dt.spaceLg)
          .borderRadius(Dt.radiusSm)
          .backgroundColor('#181818')
      } else {
        Row() {
          SystemSymbolIcon({ name: ToolSymbol.VIDEO, iconSize: 32, color: $r('app.color.text_secondary') })
        }
        .width('100%')
        .height(this.heightVp)
        .justifyContent(FlexAlign.Center)
        .borderRadius(Dt.radiusSm)
        .backgroundColor('#181818')
      }

      if (this.media !== undefined && this.media.isMovingPhoto) {
        Text('动态照片')
          .fontSize(Dt.fontCaption)
          .fontColor(Color.White)
          .padding({ left: 8, right: 8, top: 2, bottom: 2 })
          .borderRadius(6)
          .backgroundColor('#B3000000')
          .position({ x: 8, y: 8 })
      }
    }
    .width('100%')
    .clip(true)
  }
}
