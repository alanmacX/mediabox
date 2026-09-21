/** 首页媒体类型图标：只用系统 Symbol，不叠加呼吸光晕或背景循环动画。 */
@Component
export struct DeckTypeArt {
  @Prop kind: string = 'video';
  /** 前卡切换时变化；-1 表示不播放。由 SymbolGlyph 原生驱动，不保留循环定时器。 */
  @Prop symbolTrigger: number = -1;
  @State boxW: number = 108;
  @State boxH: number = 82;

  private symbol(): Resource {
    if (this.kind === 'video') return $r('sys.symbol.video');
    if (this.kind === 'image') return $r('sys.symbol.picture_on_square');
    if (this.kind === 'audio') return $r('sys.symbol.waveform');
    if (this.kind === 'subtitle') return $r('sys.symbol.doc_plaintext');
    // HarmonyOS 系统 Symbol 中的实况／动态照片专用图标。
    if (this.kind === 'moving') return $r('sys.symbol.livephoto');
    return $r('sys.symbol.arrow_2_circlepath');
  }

  /** 图标铺满上半区，但为窄卡和横屏卡保留呼吸空间。 */
  private glyphSize(): number {
    const width = this.boxW > 20 ? this.boxW : 108;
    const height = this.boxH > 20 ? this.boxH : 82;
    return Math.max(50, Math.min(96, width * 0.56, height * 0.76));
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      SymbolGlyph(this.symbol())
        .fontSize(this.glyphSize())
        .fontColor([$r('app.color.deck_art')])
        // 单次轻弹：仅在滑动切换到当前卡时播放，不是背景呼吸。
        .symbolEffect(new BounceSymbolEffect(EffectScope.WHOLE, EffectDirection.UP), this.symbolTrigger)
    }
    .width('100%')
    .height('100%')
    .onAreaChange((_old: Area, area: Area): void => {
      const width = Number(area.width);
      const height = Number(area.height);
      if (width > 20) this.boxW = width;
      if (height > 20) this.boxH = height;
    })
  }
}
