/**
 * UI 调试 Hook — 便于在模拟器上高效验收，不依赖点 UI。
 *
 * 用法（hdc）：
 *   hdc shell "hilog | grep MediaBoxUI"
 *   启动后会打印 windowWidth/Height、isLandscape、safe 区。
 *   也可通过 AppStorage.get('uiDebugDump') 触发一次摘要。
 */
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG = 'MediaBoxUI';
const DOMAIN = 0x4D42;

export class UiDebugHooks {
  /** 启动时注入一次窗口度量，便于模拟器脚本 grep。 */
  static logWindowMetrics(): void {
    const w = AppStorage.get<number>('windowWidthVp') ?? 0;
    const h = AppStorage.get<number>('windowHeightVp') ?? 0;
    const land = AppStorage.get<boolean>('isLandscape') ?? false;
    const top = AppStorage.get<number>('safeTopVp') ?? 0;
    const bottom = AppStorage.get<number>('safeBottomVp') ?? 0;
    hilog.info(DOMAIN, TAG,
      'metrics w=%{public}s h=%{public}s land=%{public}s safeTop=%{public}s safeBottom=%{public}s',
      `${w}`, `${h}`, `${land}`, `${top}`, `${bottom}`);
  }

  /** 供测试脚本用的固定分隔行，方便 grep。 */
  static mark(page: string): void {
    hilog.info(DOMAIN, TAG, 'PAGE %{public}s', page);
  }
}
