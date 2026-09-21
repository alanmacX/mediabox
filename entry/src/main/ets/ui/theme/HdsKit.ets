/**
 * HDS 辅助 — 只封装确认过的 UIDesignKit 构造参数。
 */
import {
  BlurStrategy,
  HdsBarStyle,
  HdsBarWidthRangeOptions,
  HdsNavigationTitleBarOptions,
  HdsTabsFloatingStyle,
  HdsTabsMiniBar,
  hdsMaterial,
  ScrollEffectType
} from '@kit.UIDesignKit';
import { uiMaterial } from '@kit.ArkUI';
import { ToolSymbol } from '../../core/model/MediaTypes';
import { Dt } from './DesignTokens';

/** 悬浮 TabBar 相对安全区的稳定 vp 边距；不混入像素负偏移。 */
export const TAB_FLOAT_BOTTOM: number = 16;

/**
 * 组件级沉浸光感统一入口（鸿蒙7 / API 26 uiMaterial）。
 * - API 26+ 且设备支持：返回 ImmersiveMaterial，底色/描边/阴影/光效由系统材质层绘制
 * - 6.1(24) 及以下：模块命名空间存在但成员缺失（6.1 模拟器实测 isImmersiveMaterialSupported
 *   不可调用、ImmersiveStyle 为 undefined），所有 uiMaterial 成员访问必须放在
 *   available() 通过之后，否则渲染期 TypeError。
 */
export class Immersive {
  private static checked: boolean = false;
  private static usable: boolean = false;

  static available(): boolean {
    if (!Immersive.checked) {
      Immersive.checked = true;
      try {
        Immersive.usable = typeof uiMaterial.isImmersiveMaterialSupported === 'function' &&
          uiMaterial.isImmersiveMaterialSupported() === true;
      } catch (e) {
        Immersive.usable = false;
      }
    }
    return Immersive.usable;
  }

  /** 系统沉浸材质；不可用时返回 undefined（systemMaterial(undefined) 为无材质）。 */
  static regular(): uiMaterial.ImmersiveMaterial | undefined {
    if (!Immersive.available()) {
      return undefined;
    }
    try {
      return new uiMaterial.ImmersiveMaterial({
        style: uiMaterial.ImmersiveStyle.REGULAR,
        applyShadow: true,
        interactive: true
      });
    } catch (e) {
      return undefined;
    }
  }
}

export function toolSymbolResource(name: ToolSymbol): Resource {
  switch (name) {
    case ToolSymbol.HOME:
      return $r('sys.symbol.house');
    case ToolSymbol.TASKS:
      return $r('sys.symbol.list_bullet_square');
    case ToolSymbol.VIDEO:
      return $r('sys.symbol.video');
    case ToolSymbol.AUDIO:
      return $r('sys.symbol.waveform');
    case ToolSymbol.GIF:
      return $r('sys.symbol.video_badge_adiowaves');
    case ToolSymbol.IMAGE:
      return $r('sys.symbol.picture_on_square');
    case ToolSymbol.CONVERT:
    case ToolSymbol.RETRY:
      return $r('sys.symbol.arrow_2_circlepath');
    case ToolSymbol.COMPRESS:
      return $r('sys.symbol.square_and_arrow_down_1');
    case ToolSymbol.TARGET:
      return $r('sys.symbol.slider_horizontal_2');
    case ToolSymbol.EDIT:
      return $r('sys.symbol.rectangle_and_cut');
    case ToolSymbol.RESIZE:
      return $r('sys.symbol.crop_rotate');
    case ToolSymbol.INFO:
      return $r('sys.symbol.info_rectangle_portrait');
    case ToolSymbol.NORMALIZE:
      return $r('sys.symbol.waveform_path_circle');
    case ToolSymbol.MOVING_PHOTO:
      return $r('sys.symbol.livephoto');
    case ToolSymbol.WAITING:
      return $r('sys.symbol.doc_text_badge_clock');
    case ToolSymbol.COMPLETED:
      return $r('sys.symbol.checkmark_circle');
    case ToolSymbol.FAILED:
      return $r('sys.symbol.xmark_circle');
    case ToolSymbol.EMPTY:
      return $r('sys.symbol.folder');
    case ToolSymbol.SHARE:
      return $r('sys.symbol.share');
    case ToolSymbol.DELETE:
      return $r('sys.symbol.trash');
    case ToolSymbol.STOP:
      return $r('sys.symbol.stop_circle');
    case ToolSymbol.PAUSE:
      return $r('sys.symbol.pause_circle');
    case ToolSymbol.PLAY:
      return $r('sys.symbol.play_circle');
    case ToolSymbol.CHEVRON:
      return $r('sys.symbol.arrow_right');
    default:
      return $r('sys.symbol.doc_plaintext');
  }
}

/** 侧栏 miniBar 宽度；ROM 对嵌套对象 ParseProp 不稳时，用 vp 字符串。 */
export function sideMiniBarWidth(): HdsBarWidthRangeOptions {
  return { smallWidth: '52vp', mediumWidth: '56vp', largeWidth: '64vp' };
}

/** HdsTabs.barWidth 使用的侧栏/底部宽度（数值 vp）：侧栏收窄（用户反馈横屏侧栏过大）。 */
export function tabBarWidthValue(vertical: boolean, windowWidthVp: number = 0): number {
  if (vertical) {
    // 固定侧边导航需要容纳“图标 + 文字”的横向导航项，不能沿用手机 miniBar 宽度。
    return 200;
  }
  // 小窗中跟随可用宽度收缩，避免固定 280vp 横向溢出或视觉偏心。
  return windowWidthVp > 0 ? Math.min(280, Math.max(160, windowWidthVp - 24)) : 280;
}

/**
 * 侧栏展开/收起时把内容左 inset 写入 AppStorage。
 */
export function publishSideTabsInset(miniBarWidth: number, tabBarWidth: number,
  tabBarStyle: HdsBarStyle): void {
  const expanded: boolean = tabBarStyle === HdsBarStyle.EXPAND;
  const fallback: number = expanded ? 88 : 56;
  const barW: number = expanded ?
    (tabBarWidth > 0 ? tabBarWidth : fallback) :
    (miniBarWidth > 0 ? miniBarWidth : fallback);
  AppStorage.setOrCreate<number>('tabBarSideInsetVp', Math.ceil(barW) + 28);
}

/**
 * 底部/侧边悬浮 HDS TabBar 材质样式。
 * 不在此塞 barWidth 嵌套对象：部分 ROM 会 ParseProp 失败；宽度交给 HdsTabs.barWidth。
 */
export function tabBarFloatingStyle(safeBottomVp: number, accent: ResourceColor,
  vertical: boolean = false, miniBar?: HdsTabsMiniBar): HdsTabsFloatingStyle {
  if (vertical) {
    return {
      // 宽屏侧栏固定贴边，去掉手机悬浮 Tab 的边距、渐隐蒙版和单手模式。
      barSideMargin: 0,
      barBottomMargin: 0,
      adaptToHandedness: false,
      lightColor: accent,
      thermoCtrl: false,
      systemMaterialEffect: {
        materialType: hdsMaterial.MaterialType.IMMERSIVE,
        materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE
      }
    };
  }
  return {
    barBottomMargin: safeBottomVp + TAB_FLOAT_BOTTOM,
    adaptToHandedness: true,
    lightColor: accent,
    thermoCtrl: true,
    systemMaterialEffect: {
      materialType: hdsMaterial.MaterialType.IMMERSIVE,
      materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE
    }
  };
}

/** 状态栏图标颜色：浅色背景用深色图标（官方 SystemBarStyle）。 */
export interface StatusBarColorStyle {
  statusBarContentColor: string;
}

export function lightStatusBarStyle(): StatusBarColorStyle {
  return { statusBarContentColor: '#182431' };
}

/** Tab 根页面底部 inset：悬浮条高度 + 底距 + 导航指示条。 */
export function tabBarBottomInset(safeBottomVp: number): number {
  return safeBottomVp + TAB_FLOAT_BOTTOM + Dt.tabBarHeight + Dt.spaceMd;
}

/** 横屏/大屏左侧竖条 inset 默认值（回调前）。 */
export function tabBarSideInsetDefault(): number {
  return AppStorage.get<number>('tabBarSideInsetVp') ?? 128;
}

/**
 * 二级页标题栏：
 * - originalStyle：未滚动时也显示深色标题与返回键（避免发白/看不见）
 * - scrollEffectStyle：滚动后渐变模糊，颜色保持可读
 */
export function destinationTitleBar(mainTitle: string, subTitle?: string): HdsNavigationTitleBarOptions {
  return {
    avoidLayoutSafeArea: true,
    content: subTitle === undefined ?
      { title: { mainTitle: mainTitle } } :
      { title: { mainTitle: mainTitle, subTitle: subTitle } },
    style: {
      originalStyle: {
        backgroundStyle: {
          backgroundColor: Color.Transparent,
          maskExtraHeight: 24
        },
        contentStyle: {
          titleStyle: {
            mainTitleColor: $r('app.color.text_primary')
          },
          backIconStyle: {
            iconColor: $r('app.color.text_primary'),
            textColor: $r('app.color.text_primary'),
            backgroundColor: Color.Transparent
          }
        }
      },
      scrollEffectStyle: {
        backgroundStyle: {
          backgroundColor: $r('app.color.app_background'),
          maskExtraHeight: 32,
          blurRadius: 40
        },
        contentStyle: {
          titleStyle: {
            mainTitleColor: $r('app.color.text_primary')
          },
          backIconStyle: {
            iconColor: $r('app.color.text_primary'),
            textColor: $r('app.color.text_primary')
          }
        }
      },
      scrollEffectOpts: {
        enableScrollEffect: true,
        scrollEffectType: ScrollEffectType.IMMERSIVE_GRADIENT_BLUR
      },
      blurStrategy: BlurStrategy.ADAPTIVE,
      // HDS 沉浸光感（6.1/23+）：标题栏按钮系统级光影；旧 ROM 由 HdsNavigation 内部降级
      systemMaterialEffect: {
        materialType: hdsMaterial.MaterialType.IMMERSIVE,
        materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE
      },
      thermoCtrl: true
    }
  };
}
