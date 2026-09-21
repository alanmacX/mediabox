/**
 * AppBackground — 轻量全局底色与柔光，不冒充系统材质。
 */
@Component
export struct AppBackground {
  build() {
    Stack() {
      Column()
        .radialGradient({
          center: ['15%', '0%'],
          radius: 280,
          colors: [[$r('app.color.glow_primary'), 0], ['#00000000', 1]]
        })
      Column()
        .radialGradient({
          center: ['95%', '100%'],
          radius: 300,
          colors: [[$r('app.color.glow_secondary'), 0], ['#00000000', 1]]
        })
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.app_background'))
  }
}

/**
 * GlassCard — 统一内容卡片。只做层次，不嵌套模糊。
 * 保留原名以兼容现有调用：GlassCard({ radius, padding }) { ... }
 */
@Component
export struct GlassCard {
  @BuilderParam content: () => void = emptyBuilder;
  @Prop radius: number = 16;
  @Prop paddingV: number = 16;
  @Prop strongBlur: boolean = false;

  build() {
    Column() {
      this.content()
    }
    .width('100%')
    .padding(this.paddingV)
    .borderRadius(this.radius)
    .backgroundColor($r('app.color.surface_card'))
    .shadow({
      radius: 24,
      color: '#0F101814',
      offsetX: 0,
      offsetY: 8
    })
    .clip(true)
  }
}

@Builder
function emptyBuilder() {
}
