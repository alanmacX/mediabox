/**
 * MediaDeck — 类型牌堆（圆环）。
 * 竖屏随屏宽、横屏随可用高度等比缩放（手机基准：牌 176×224、环深 358、步长 14°），
 * 恰好占满可用空间。左右滑动单张步进（阻尼限幅）。
 * 性能：卡面只使用静态系统 Symbol，拖拽帧仅更新卡片位姿。
 */
import { curves } from '@kit.ArkUI';
import { ToolSymbol } from '../../core/model/MediaTypes';
import { MediaPickMode } from '../../core/media/MediaPickerService';
import { DeviceSupport } from '../../core/capability/DeviceSupport';
import { Adaptive } from '../adaptive/AdaptiveKit';
import { Dt } from '../theme/DesignTokens';
import { DeckTypeArt } from './DeckTypeArt';

/** 发牌/落位弹簧曲线（轻微 overshoot，Demo 同参）。 */
const DEAL_CURVE: curves.ICurve = curves.cubicBezierCurve(0.34, 1.42, 0.64, 1.0);
const RING_SNAP_MS: number = 420;
const RING_BOUNCE_MS: number = 260;
/** 圆环几何定稿参数（Demo 调优值）。 */
// 侧卡多露出一段轮廓；不靠降低透明度区分前后层。
const RING_STEP_DEG: number = 17;
// 超出一张的拖拽保留更多位移，减轻橡皮筋阻尼但仍限制单次只切一张。
const RING_DAMP_K: number = 0.48;
const RING_DAMP_MAX_STEPS: number = 1.7;

export interface DeckCardItem {
  id: string;
  title: string;
  subtitle: string;
  icon: ToolSymbol;
  pickMode: MediaPickMode;
  fromGallery: boolean;
  fromFiles: boolean;
}

interface DeckPose {
  x: number;
  y: number;
  w: number;
  h: number;
  scale: number;
  rotate: number;
  opacity: number;
  z: number;
  /** 卡面亮度（环上侧卡压暗）。 */
  bright: number;
}

@Component
export struct MediaDeck {
  onPickGallery: (mode: MediaPickMode) => void = () => {
  };
  onPickFiles: (mode: MediaPickMode) => void = () => {
  };

  @StorageProp('windowWidthVp') windowWidthVp: number = 390;
  @StorageProp('isLandscape') isLandscape: boolean = false;
  @StorageProp('windowHeightVp') windowHeightVp: number = 844;
  @StorageProp('safeTopVp') safeTopVp: number = 0;
  @StorageProp('safeBottomVp') safeBottomVp: number = 0;

  @State deckIndex: number = 0;
  @State dragX: number = 0;
  @State deckW: number = 320;
  /** 舞台实际高度（onAreaChange 量得）：横屏据此让圆环恰好占满。 */
  @State stageH: number = 0;
  private isDragging: boolean = false;
  private lastDragX: number = 0;

  private cards: DeckCardItem[] = MediaDeck.buildCards();

  aboutToAppear(): void {
    this.deckW = Math.max(240, this.windowWidthVp - 48);
  }

  static buildCards(): DeckCardItem[] {
    const list: DeckCardItem[] = [
      {
        id: 'video',
        title: '视频',
        subtitle: '转换 · 压缩 · 裁剪',
        icon: ToolSymbol.VIDEO,
        pickMode: MediaPickMode.VIDEO,
        fromGallery: true,
        fromFiles: true
      },
      {
        id: 'image',
        title: '图片',
        subtitle: '格式 · 尺寸 · 压缩',
        icon: ToolSymbol.IMAGE,
        pickMode: MediaPickMode.IMAGE,
        fromGallery: true,
        fromFiles: true
      },
      {
        id: 'gif',
        title: 'GIF',
        subtitle: '优化 · 帧率 · 循环',
        icon: ToolSymbol.GIF,
        pickMode: MediaPickMode.GIF,
        fromGallery: true,
        fromFiles: true
      },
      {
        id: 'audio',
        title: '音频',
        subtitle: '转换 · 裁剪 · 响度',
        icon: ToolSymbol.AUDIO,
        pickMode: MediaPickMode.AUDIO,
        fromGallery: false,
        fromFiles: true
      },
      {
        id: 'subtitle',
        title: '字幕',
        subtitle: '转换 · 偏移',
        icon: ToolSymbol.FILE,
        pickMode: MediaPickMode.SUBTITLE,
        fromGallery: false,
        fromFiles: true
      }
    ];
    const mp = DeviceSupport.movingPhoto();
    if (mp.available && mp.canExportMovingPhoto) {
      list.push({
        id: 'moving',
        title: '动态照片',
        subtitle: '静态图 · 短视频 · GIF',
        icon: ToolSymbol.MOVING_PHOTO,
        pickMode: MediaPickMode.MOVING_PHOTO,
        fromGallery: true,
        fromFiles: false
      });
    }
    return list;
  }

  // ================= 圆环几何（等比缩放，恰好占满可用空间） =================

  /** 宽矮竖屏（典型折叠外屏）需要把牌堆抬高，避免标题落入悬浮 TabBar 后方。 */
  private compactPortrait(): boolean {
    return !this.isLandscape && this.windowWidthVp >= 420 && this.windowHeightVp > 0 &&
      this.windowHeightVp / this.windowWidthVp < 1.62;
  }

  /** 竖屏中首页上半区固定内容与底部悬浮栏之外，可交给卡堆使用的高度。 */
  private portraitDeckHeight(): number {
    // 标题/选择卡约 160vp，卡堆与选择卡留 24vp，底栏安全预留约 84vp。
    return Math.max(190, this.windowHeightVp - this.safeTopVp - this.safeBottomVp - 244);
  }

  /**
   * 缩放系数：横屏随实测舞台高度；竖屏仍随宽度给环半径一个稳定基准，
   * 卡片本身再由 portraitDeckHeight 约束，避免“矮窗太小、高窗空很多”。
   */
  private ringScale(): number {
    if (this.isLandscape) {
      if (this.stageH > 80) {
        return Math.max(0.4, Math.min(1.3, this.stageH / 336));
      }
      const avail = Math.max(220, this.windowHeightVp -
        (this.safeTopVp + 16 + 88 + 16) - (this.safeBottomVp + 72 + 32));
      return Math.max(0.4, Math.min(1.3, avail / 336));
    }
    return Math.max(0.78, Math.min(1.18, this.windowWidthVp / 390));
  }

  /** 环上牌宽：手机端留出下方页签安全区；横屏给足宽度保证底栏一行排下。 */
  private ringCardW(): number {
    if (this.isLandscape) {
      return Math.max(210, Math.min(270, this.windowWidthVp * 0.32));
    }
    // 卡堆舞台 = 卡高(1.27w) + 环顶部留白(约 0.1w) + 弧沉余量。
    // 高度和宽度双向封顶：小窗不压 TabBar，高窗不会因为固定宽比留下大片空白。
    const heightCap = this.portraitDeckHeight() / 1.43;
    return Math.max(132, Math.min(248, this.windowWidthVp * 0.60, heightCap));
  }

  /** 环上牌高：竖屏使用紧凑比例，首屏能完整看见当前卡的操作区。 */
  private ringCardH(): number {
    if (this.isLandscape) {
      const maxH = Math.max(150, (this.stageH > 80 ? this.stageH : 272) -
        this.ringTopPad() - 20);
      return Math.min(this.ringCardW() * 1.45, maxH);
    }
    return this.ringCardW() * 1.27;
  }

  /** 环半径（环心在屏幕下方远处），demo 定稿 358/390 屏宽比。 */
  private ringR(): number {
    return 358 * this.ringScale();
  }

  private ringTopPad(): number {
    return (this.compactPortrait() ? 12 : 36) * this.ringScale();
  }

  /** 跟手阻尼：一个弧步内 1:1，超出按 0.32 橡胶衰减，上限 1.7 步——一次手势只走一张。 */
  private dampedDragAngle(): number {
    const raw = (this.dragX / this.ringR()) * 57.3;
    if (Math.abs(raw) <= RING_STEP_DEG) {
      return raw;
    }
    const d = Math.sign(raw) * (RING_STEP_DEG + (Math.abs(raw) - RING_STEP_DEG) * RING_DAMP_K);
    return Math.sign(raw) * Math.min(Math.abs(d), RING_STEP_DEG * RING_DAMP_MAX_STEPS);
  }

  private stackOffset(i: number): number {
    const n = this.cards.length;
    if (n <= 0) {
      return 0;
    }
    let d = i - this.deckIndex;
    if (d > n / 2) {
      d -= n;
    }
    if (d < -n / 2) {
      d += n;
    }
    return d;
  }

  /** 非环绕序（0..n-1）：单列平铺铺放顺序。 */
  private stackOrder(i: number): number {
    const n = this.cards.length;
    if (n <= 0) {
      return 0;
    }
    return ((i - this.deckIndex) % n + n) % n;
  }

  /** 环上位姿。d = 相对首卡的环绕偏移；首卡居中，左右各露约 1/4 卡宽。
   *  超出屏幕可完整容纳角度的卡平滑淡出（横屏窄容器下不出现硬裁切）。 */
  private ringPose(i: number): DeckPose {
    const d = this.stackOffset(i);
    const R = this.ringR();
    const a = (d * RING_STEP_DEG + this.dampedDragAngle()) * Math.PI / 180;
    const front = Math.max(0, Math.cos(a));
    const w = this.ringCardW();
    const aDeg = Math.abs(a * 57.3);
    const aFit = Math.asin(Math.max(0, Math.min(1, (this.deckW / 2 - w / 2) / R))) * 57.3;
    const vis = Math.max(0, Math.min(1,
      (aFit + RING_STEP_DEG * 1.6 - aDeg) / (RING_STEP_DEG * 0.9)));
    return {
      x: Math.max(2, this.deckW / 2 - w / 2 + Math.sin(a) * R),
      y: this.ringTopPad() + R * (1 - Math.cos(a)) * 0.6,
      w: w,
      h: this.ringCardH(),
      // 卡片统一不透明度；层级只由位置、缩放和旋转表达。
      // 侧卡略收小，和前卡之间留出稳定的弧形负空间，轮廓更容易被看见。
      scale: d === 0 ? 1 : 0.86 + 0.04 * front,
      rotate: a * 57.3 * 0.85,
      opacity: vis,
      z: 100 - Math.abs(d) * 5 - (d <= 0 ? 1 : 0),
      bright: 1
    };
  }

  private poseOf(i: number): DeckPose {
    return this.ringPose(i);
  }

  private deckContainerHeight(): number {
    // 卡堆舞台的自然高度。
    return this.ringCardH() + this.ringTopPad() + 12 * this.ringScale();
  }

  /** 位姿缓存：同一帧内一张卡的十几个属性链只算一次 pose。 */
  private poseCacheKey: string = '';
  private poseCacheI: number = -1;
  private poseCacheVal: DeckPose | undefined = undefined;

  private cachedPose(i: number): DeckPose {
    const key = `${this.deckIndex}|${this.dragX}|${Math.round(this.deckW)}` +
      `|${Math.round(this.windowWidthVp)}|${Math.round(this.windowHeightVp)}` +
      `|${Math.round(this.safeTopVp)}|${Math.round(this.safeBottomVp)}|${this.isLandscape}` +
      `|${Math.round(this.stageH)}`;
    if (key === this.poseCacheKey && this.poseCacheI === i && this.poseCacheVal !== undefined) {
      return this.poseCacheVal;
    }
    const pose = this.poseOf(i);
    this.poseCacheKey = key;
    this.poseCacheI = i;
    this.poseCacheVal = pose;
    return pose;
  }

  private animate(duration: number, body: () => void, curve: curves.ICurve = DEAL_CURVE): void {
    this.getUIContext().animateTo({
      duration: duration,
      curve: curve
    }, body);
  }

  private goIndex(next: number): void {
    const n = this.cards.length;
    if (n <= 0) {
      return;
    }
    const idx = ((next % n) + n) % n;
    if (idx === this.deckIndex && this.dragX === 0) {
      return;
    }
    this.animate(RING_SNAP_MS, (): void => {
      this.deckIndex = idx;
      this.dragX = 0;
    });
  }

  /** 松手：阈值 48px，超阈值单张切换，不足则阻尼回弹（对齐原生手感）。 */
  private onPanEnd(): void {
    const threshold = 48;
    const drag = this.dragX;
    if (drag <= -threshold) {
      this.goIndex(this.deckIndex + 1);
      return;
    }
    if (drag >= threshold) {
      this.goIndex(this.deckIndex - 1);
      return;
    }
    this.animate(RING_BOUNCE_MS, (): void => {
      this.dragX = 0;
    });
  }

  private pick(item: DeckCardItem): void {
    if (item.fromGallery) {
      this.onPickGallery(item.pickMode);
    } else {
      this.onPickFiles(item.pickMode);
    }
  }

  /** 卡面：动效占上半区；下半区只保留类型名称与来源按钮。 */
  @Builder
  CardFace(item: DeckCardItem, i: number) {
    Column() {
      Column() {
        DeckTypeArt({
          kind: item.id,
          // 只有成为前卡的一刻触发系统 Symbol 的一次性入场弹性。
          symbolTrigger: i === this.deckIndex ? this.deckIndex + 1 : -1
        })
          .width('100%')
          .height('100%')
      }
      .width('100%')
      .layoutWeight(1)
      .padding({ top: Dt.spaceSm })

      Row({ space: Dt.spaceSm }) {
        Row({ space: 6 }) {
          if (item.fromGallery) {
            Button('图库')
              .height(30)
              .fontSize(11)
              .constraintSize({ minWidth: 44, maxWidth: 64 })
              .type(ButtonType.Capsule)
              .buttonStyle(ButtonStyleMode.NORMAL)
              .onClick((): void => this.pick(item))
          }
          if (item.fromFiles) {
            Button('文件')
              .height(30)
              .fontSize(11)
              .constraintSize({ minWidth: 44, maxWidth: 64 })
              .type(ButtonType.Capsule)
              .buttonStyle(item.fromGallery ? ButtonStyleMode.NORMAL : ButtonStyleMode.EMPHASIZED)
              .onClick((): void => this.pick(item))
          }
        }
        .flexShrink(0)

        Column() {
          Text(item.title)
            .fontSize(14)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.text_primary'))
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Clip })
            .textAlign(TextAlign.End)
            .width('100%')
        }
        .layoutWeight(1)
        .height(30)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.End)
        .clip(true)
        .constraintSize({ minWidth: 48 })
      }
      .width('100%')
      .height(30)
      .padding({ left: Dt.spaceSm, right: Dt.spaceSm, bottom: Dt.spaceSm })
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  CardsStack() {
    Stack({ alignContent: Alignment.TopStart }) {
      ForEach(this.cards, (item: DeckCardItem, i: number) => {
        Stack({ alignContent: Alignment.TopStart }) {
          Column() {
            this.CardFace(item, i)
          }
          .width('100%')
          .height('100%')

          // 压暗蒙层：替代 brightness 滤镜；不拦截触摸（否则盖住卡面按钮）
          Column()
            .width('100%')
            .height('100%')
            .backgroundColor('#000000')
            .opacity(1 - this.cachedPose(i).bright)
            .hitTestBehavior(HitTestMode.None)
            .clip(true)
        }
        .width(this.cachedPose(i).w)
        .height(this.cachedPose(i).h)
        // translate 走渲染合成（不触发 relayout）：拖拽帧只合成不布局
        .translate({
          x: this.cachedPose(i).x,
          y: this.cachedPose(i).y
        })
        .scale({
          x: this.cachedPose(i).scale,
          y: this.cachedPose(i).scale,
          centerX: '50%',
          centerY: '50%'
        })
        .rotate({
          x: 0,
          y: 0,
          z: 1,
          angle: this.cachedPose(i).rotate,
          centerX: '50%',
          centerY: '50%'
        })
        .opacity(this.cachedPose(i).opacity)
        .zIndex(this.cachedPose(i).z)
        .borderRadius(Dt.radiusXl)
        // 卡面无描边：类型动效和下半区自然融合。
        .linearGradient({
          angle: 160,
          colors: [[$r('app.color.deck_card_start'), 0], [$r('app.color.deck_card_end'), 1]]
        })
        // 所有卡用完全一致的静态投影；层级只来自几何位姿，不再用阴影差异表达。
        .shadow({
          radius: 12,
          color: '#4A071222',
          offsetX: 0,
          offsetY: 4
        })
        .clip(true)
        .onClick((): void => {
          if (i !== this.deckIndex) {
            this.goIndex(i);
          }
        })
      }, (item: DeckCardItem) => item.id)
    }
    .width('100%')
    // 横屏：容器高由父级 layoutWeight 给定（stageH 实测后定环缩放）；竖屏按内容自适应
    .height(this.isLandscape ? '100%' : this.deckContainerHeight())
    .clip(false)
    .onAreaChange((_old: Area, area: Area): void => {
      const w = Number(area.width);
      const h = Number(area.height);
      if (w > 40) {
        this.deckW = w;
      }
      if (h > 40) {
        this.stageH = h;
      }
    })
  }

  /**
   * 单一挂载的牌区 + 手势：
   * - 单一牌区承载整个手势，避免节点重建造成位姿跳变。
   * - 横竖屏统一左右 pan（圆环切卡是左右），竖向滚动全部交给页面。
   */
  build() {
    Column() {
      this.CardsStack()
    }
    .width('100%')
    .gesture(
      GestureGroup(GestureMode.Parallel,
        PanGesture({
          fingers: 1,
          direction: PanDirection.Horizontal
        })
          .onActionStart((_e: GestureEvent): void => {
            this.isDragging = true;
          })
          .onActionUpdate((e: GestureEvent): void => {
            // 节流：位移变化 <2vp 不触发状态更新，避免 120Hz 输入全树重排
            const v = e.offsetX;
            if (Math.abs(v - this.lastDragX) < 2) {
              return;
            }
            this.lastDragX = v;
            // 手势更新必须直达状态；逐帧 animateTo 会积压 80ms 动画，造成跟手滞后。
            // 仅在松手后为落位和回弹启用显式动画。
            this.dragX = v;
          })
          .onActionEnd((): void => {
            this.isDragging = false;
            this.lastDragX = 0;
            this.onPanEnd();
          })
      )
    )
  }
}
