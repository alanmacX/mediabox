/**
 * 系统 Symbol 的集中映射。
 * 所有图标均来自 sys.symbol，页面和业务模型不再保存 emoji 或字符图标。
 */
import { ToolSymbol } from '../../core/model/MediaTypes';

@Component
export struct SystemSymbolIcon {
  @Prop name: ToolSymbol = ToolSymbol.FILE;
  @Prop iconSize: number = 22;
  @Prop color: ResourceColor = $r('app.color.text_primary');

  @Builder
  Glyph(symbol: Resource) {
    SymbolGlyph(symbol)
      .fontSize(this.iconSize)
      .fontColor([this.color])
  }

  build() {
    if (this.name === ToolSymbol.HOME) {
      this.Glyph($r('sys.symbol.house'))
    } else if (this.name === ToolSymbol.TASKS) {
      this.Glyph($r('sys.symbol.list_bullet_square'))
    } else if (this.name === ToolSymbol.VIDEO) {
      this.Glyph($r('sys.symbol.video'))
    } else if (this.name === ToolSymbol.AUDIO) {
      this.Glyph($r('sys.symbol.waveform'))
    } else if (this.name === ToolSymbol.GIF) {
      this.Glyph($r('sys.symbol.video_badge_adiowaves'))
    } else if (this.name === ToolSymbol.IMAGE) {
      this.Glyph($r('sys.symbol.picture_on_square'))
    } else if (this.name === ToolSymbol.CONVERT) {
      this.Glyph($r('sys.symbol.arrow_2_circlepath'))
    } else if (this.name === ToolSymbol.COMPRESS) {
      this.Glyph($r('sys.symbol.square_and_arrow_down_1'))
    } else if (this.name === ToolSymbol.TARGET) {
      this.Glyph($r('sys.symbol.slider_horizontal_2'))
    } else if (this.name === ToolSymbol.EDIT) {
      this.Glyph($r('sys.symbol.rectangle_and_cut'))
    } else if (this.name === ToolSymbol.RESIZE) {
      this.Glyph($r('sys.symbol.crop_rotate'))
    } else if (this.name === ToolSymbol.INFO) {
      this.Glyph($r('sys.symbol.info_rectangle_portrait'))
    } else if (this.name === ToolSymbol.NORMALIZE) {
      this.Glyph($r('sys.symbol.waveform_path_circle'))
    } else if (this.name === ToolSymbol.MOVING_PHOTO) {
      this.Glyph($r('sys.symbol.livephoto'))
    } else if (this.name === ToolSymbol.WAITING) {
      this.Glyph($r('sys.symbol.doc_text_badge_clock'))
    } else if (this.name === ToolSymbol.COMPLETED) {
      this.Glyph($r('sys.symbol.checkmark_circle'))
    } else if (this.name === ToolSymbol.FAILED) {
      this.Glyph($r('sys.symbol.xmark_circle'))
    } else if (this.name === ToolSymbol.EMPTY) {
      this.Glyph($r('sys.symbol.folder'))
    } else if (this.name === ToolSymbol.SHARE) {
      this.Glyph($r('sys.symbol.share'))
    } else if (this.name === ToolSymbol.DELETE) {
      this.Glyph($r('sys.symbol.trash'))
    } else if (this.name === ToolSymbol.STOP) {
      this.Glyph($r('sys.symbol.stop_circle'))
    } else if (this.name === ToolSymbol.RETRY) {
      this.Glyph($r('sys.symbol.arrow_2_circlepath'))
    } else if (this.name === ToolSymbol.PAUSE) {
      this.Glyph($r('sys.symbol.pause_circle'))
    } else if (this.name === ToolSymbol.PLAY) {
      this.Glyph($r('sys.symbol.play_circle'))
    } else if (this.name === ToolSymbol.CHEVRON) {
      this.Glyph($r('sys.symbol.arrow_right'))
    } else {
      this.Glyph($r('sys.symbol.doc_plaintext'))
    }
  }
}
