/**
 * 自适应工具 — 手机 / 折叠屏 / 平板 / 横屏 / 2in1。
 *
 * 断点(与 HarmonyOS 设计规范一致):
 *   sm:  [0, 600)    单手手机
 *   md:  [600, 840)  折叠屏展开态 / 竖屏平板
 *   lg:  [840, +∞)   平板横屏 / 2in1 / 自由窗口
 *
 * 横屏额外放宽内容宽度与列数，避免把宽屏压成一条窄柱。
 */

export enum Breakpoint {
  SM = 'sm',
  MD = 'md',
  LG = 'lg'
}

export interface GridCols {
  sm: number;
  md: number;
  lg: number;
}

export class Adaptive {
  static readonly SM_MAX: number = 600;
  static readonly MD_MAX: number = 840;

  static breakpoint(widthVp: number): Breakpoint {
    if (widthVp < Adaptive.SM_MAX) {
      return Breakpoint.SM;
    }
    if (widthVp < Adaptive.MD_MAX) {
      return Breakpoint.MD;
    }
    return Breakpoint.LG;
  }

  /** 页面水平留白:宽屏加大呼吸感。 */
  static pagePadding(widthVp: number): number {
    const bp = Adaptive.breakpoint(widthVp);
    if (bp === Breakpoint.SM) {
      return 16;
    }
    if (bp === Breakpoint.MD) {
      return 24;
    }
    return 32;
  }

  /** 类型宫格列数：横屏 3，与 preview 一致。 */
  static typeGridColumns(widthVp: number, isLandscape: boolean): GridCols {
    if (isLandscape && widthVp >= 600) {
      return { sm: 2, md: 3, lg: 3 };
    }
    return { sm: 2, md: 2, lg: 2 };
  }

  /** 任务卡片列数：横屏双列铺开。 */
  static taskGridColumns(widthVp: number, isLandscape: boolean): GridCols {
    if (isLandscape && Adaptive.breakpoint(widthVp) !== Breakpoint.SM) {
      return { sm: 1, md: 2, lg: 2 };
    }
    return { sm: 1, md: 1, lg: 1 };
  }

  /**
   * 内容最大宽度：左对齐铺满可用宽度，不居中、不收成窄柱。
   * 竖屏 lg 略收，避免一行过长。
   */
  static contentMaxWidth(widthVp: number, isLandscape: boolean = false): Length {
    if (isLandscape || Adaptive.breakpoint(widthVp) === Breakpoint.LG) {
      return '100%';
    }
    return Adaptive.breakpoint(widthVp) === Breakpoint.MD ? 720 : '100%';
  }

  /** 左对齐；宽屏用多列吃满宽度。 */
  static shouldCenterContent(_widthVp: number, _isLandscape: boolean): boolean {
    return false;
  }

  /**
   * 是否使用侧边页签（官方一多）。
   * - 手机宽（&lt;600vp）：始终底部悬浮条
   * - 有高度时按 HDS 宽档：宽/高 ≥ 0.8 且宽 ≥ 600 → 侧栏（横屏 Pad / 2in1 / 宽自由窗）
   * - 无高度时回退：横屏且宽 ≥ 600
   */
  static useSideTabs(widthVp: number, isLandscape: boolean, heightVp?: number): boolean {
    if (widthVp < Adaptive.SM_MAX) {
      return false;
    }
    if (heightVp !== undefined && heightVp > 0) {
      return widthVp / heightVp >= 0.8;
    }
    return isLandscape;
  }

  /** 覆盖式根侧栏占用的根 Tab 内容左侧安全空间。二级页不调用此方法。 */
  static sideTabInset(widthVp: number, isLandscape: boolean, heightVp?: number): number {
    return Adaptive.useSideTabs(widthVp, isLandscape, heightVp) ? 165 : 0;
  }

  /** 根 Tab 底部 inset：仅底部悬浮页签时使用。 */
  static bottomTabInset(safeBottomVp: number, widthVp: number, isLandscape: boolean,
    heightVp?: number): number {
    if (Adaptive.useSideTabs(widthVp, isLandscape, heightVp)) {
      return safeBottomVp + 16;
    }
    // 与 HdsKit 的 16vp 悬浮边距保持一致：底距 + TabBar + 内容间隔。
    return safeBottomVp + 16 + 56 + 12;
  }

  /** 视觉配置页是否双栏：横屏/宽窗。 */
  static useVisualDualPane(widthVp: number, isLandscape: boolean): boolean {
    return isLandscape || widthVp >= 600;
  }

  /** 视觉配置参数栏宽度。 */
  static formPaneWidth(): number {
    return 400;
  }
}
