/**
 * 智感握姿 / 惯用手 — 对齐 alanmacX/safeshare MotionHandService。
 *
 * 产品语义（SafeShare CHANGELOG）：主操作按钮贴向拇指一侧。
 * 不是把表单/预览整栏左右对调。
 *
 * operatingHandChanged — API 15+（谁在点屏）
 * holdingHandChanged  — API 20+（握持 / 智感握姿）
 * 权限：ohos.permission.DETECT_GESTURE（system_grant，声明后由系统授予）。
 * 本机 SDK：holding/operating 在 phone 声明；tablet 上可能 801/无回调。
 * 无感知能力时保持手动 left/right，界面文案说明。
 */
import { motion } from '@kit.MultimodalAwarenessKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';

export type HandSide = 'left' | 'right';
/** auto=跟系统；left/right=手动固定 */
export type HandMode = 'auto' | 'left' | 'right';

const TAG = 'MediaBoxHand';
const DOMAIN = 0x4D42;
const PREFS_NAME = 'handedness';
const KEY_MODE = 'hand_mode';
const KEY_SIDE = 'hand_side';

export class MotionHandService {
  private holdingCallback?: (status: motion.HoldingHandStatus) => void;
  private operatingCallback?: (status: motion.OperatingHandStatus) => void;
  private started: boolean = false;
  private holdingSubscribed: boolean = false;
  private operatingSubscribed: boolean = false;
  private holdingResolved: boolean = false;
  private generation: number = 0;

  /** 订阅成功至少一条则 true。仅在真正 LEFT/RIGHT 时回调。 */
  start(onHand: (hand: HandSide) => void): boolean {
    if (this.started) {
      return true;
    }
    // 真机上该 syscap 的 canIUse 可能返回 false，但 motion.on 仍可用。
    // 以官方 API 的同步异常（201/801/31500002）作为能力判断，不预先拦截订阅。
    const generation = ++this.generation;
    this.holdingResolved = false;
    this.operatingCallback = (status: motion.OperatingHandStatus): void => {
      if (generation !== this.generation) {
        return;
      }
      const hand = MotionHandService.operatingToSide(status);
      hilog.info(DOMAIN, TAG, 'operating=%{public}d hand=%{public}s', status, hand ?? '-');
      // 物理握持手一旦明确，以握持手为准；触屏手只在此前充当兜底。
      if (hand !== undefined && !this.holdingResolved) {
        onHand(hand);
      }
    };
    this.holdingCallback = (status: motion.HoldingHandStatus): void => {
      if (generation !== this.generation) {
        return;
      }
      const hand = MotionHandService.holdingToSide(status);
      hilog.info(DOMAIN, TAG, 'holding=%{public}d hand=%{public}s', status, hand ?? '-');
      if (hand !== undefined) {
        this.holdingResolved = true;
        onHand(hand);
      } else {
        this.holdingResolved = false;
      }
    };

    let operatingOk = false;
    let holdingOk = false;
    try {
      motion.on('operatingHandChanged', this.operatingCallback);
      operatingOk = true;
    } catch (err) {
      const code = (err as BusinessError).code ?? -1;
      hilog.warn(DOMAIN, TAG, 'on_operating_failed code=%{public}d', code);
    }
    try {
      motion.on('holdingHandChanged', this.holdingCallback);
      holdingOk = true;
    } catch (err) {
      const code = (err as BusinessError).code ?? -1;
      hilog.warn(DOMAIN, TAG, 'on_holding_failed code=%{public}d', code);
    }
    this.operatingSubscribed = operatingOk;
    this.holdingSubscribed = holdingOk;
    this.started = operatingOk || holdingOk;
    if (!this.started) {
      this.operatingCallback = undefined;
      this.holdingCallback = undefined;
    } else {
      hilog.info(DOMAIN, TAG, 'subscribed operating=%{public}d holding=%{public}d', operatingOk, holdingOk);
      if (operatingOk && !this.holdingResolved) {
        try {
          const hand = MotionHandService.operatingToSide(motion.getRecentOperatingHandStatus());
          if (hand !== undefined && !this.holdingResolved) {
            onHand(hand);
          }
        } catch (err) {
          const code = (err as BusinessError).code ?? -1;
          hilog.warn(DOMAIN, TAG, 'recent_operating_failed code=%{public}d', code);
        }
      }
    }
    return this.started;
  }

  stop(): void {
    ++this.generation;
    this.started = false;
    try {
      if (this.operatingSubscribed && this.operatingCallback !== undefined) {
        motion.off('operatingHandChanged', this.operatingCallback);
      }
    } catch (_) {
    }
    try {
      if (this.holdingSubscribed && this.holdingCallback !== undefined) {
        motion.off('holdingHandChanged', this.holdingCallback);
      }
    } catch (_) {
    }
    this.operatingCallback = undefined;
    this.holdingCallback = undefined;
    this.operatingSubscribed = false;
    this.holdingSubscribed = false;
    this.holdingResolved = false;
  }

  static holdingToSide(status: motion.HoldingHandStatus): HandSide | undefined {
    if (status === motion.HoldingHandStatus.LEFT_HAND_HELD) {
      return 'left';
    }
    if (status === motion.HoldingHandStatus.RIGHT_HAND_HELD) {
      return 'right';
    }
    return undefined;
  }

  static operatingToSide(status: motion.OperatingHandStatus): HandSide | undefined {
    if (status === motion.OperatingHandStatus.LEFT_HAND_OPERATED) {
      return 'left';
    }
    if (status === motion.OperatingHandStatus.RIGHT_HAND_OPERATED) {
      return 'right';
    }
    return undefined;
  }
}

/**
 * UI 状态存储：preferredHand 仅驱动 ToolConfig 预览/操作 card 左右对调。
 * 主页等其他页面不读取。
 */
export class HandPrefs {
  static ensureDefaults(): void {
    if (AppStorage.get<string>('preferredHand') === undefined) {
      AppStorage.setOrCreate<string>('preferredHand', 'right');
    }
    if (AppStorage.get<HandMode>('handMode') === undefined) {
      AppStorage.setOrCreate<HandMode>('handMode', 'auto');
    }
    if (AppStorage.get<string>('detectedHand') === undefined) {
      AppStorage.setOrCreate<string>('detectedHand', '');
    }
    if (AppStorage.get<boolean>('motionHandAvailable') === undefined) {
      AppStorage.setOrCreate<boolean>('motionHandAvailable', false);
    }
  }

  static async load(context: common.UIAbilityContext): Promise<void> {
    HandPrefs.ensureDefaults();
    try {
      const store = await preferences.getPreferences(context, PREFS_NAME);
      const mode = await store.get(KEY_MODE, 'auto') as string;
      const side = await store.get(KEY_SIDE, 'right') as string;
      const handMode: HandMode = (mode === 'left' || mode === 'right') ? mode as HandMode : 'auto';
      AppStorage.setOrCreate<HandMode>('handMode', handMode);
      if (handMode === 'auto') {
        const detected = AppStorage.get<string>('detectedHand');
        AppStorage.setOrCreate<string>('preferredHand',
          detected === 'left' ? 'left' : 'right');
      } else {
        AppStorage.setOrCreate<string>('preferredHand', handMode);
      }
    } catch (e) {
      AppStorage.setOrCreate<HandMode>('handMode', 'auto');
      AppStorage.setOrCreate<string>('preferredHand', 'right');
    }
  }

  static async setMode(context: common.UIAbilityContext, mode: HandMode): Promise<void> {
    HandPrefs.ensureDefaults();
    AppStorage.setOrCreate<HandMode>('handMode', mode);
    if (mode === 'left' || mode === 'right') {
      AppStorage.setOrCreate<string>('preferredHand', mode);
    } else {
      const detected = AppStorage.get<string>('detectedHand') ?? '';
      AppStorage.setOrCreate<string>('preferredHand', detected === 'left' ? 'left' : 'right');
    }
    try {
      const store = await preferences.getPreferences(context, PREFS_NAME);
      await store.put(KEY_MODE, mode);
      await store.put(KEY_SIDE, AppStorage.get<string>('preferredHand') ?? 'right');
      await store.flush();
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'persist hand mode failed %{public}s', (e as Error).message);
    }
  }

  /** 系统回调：仅 auto 模式更新界面。 */
  static onDetected(hand: HandSide): void {
    HandPrefs.ensureDefaults();
    AppStorage.setOrCreate<string>('detectedHand', hand);
    AppStorage.setOrCreate<boolean>('motionHandAvailable', true);
    const mode = AppStorage.get<HandMode>('handMode') ?? 'auto';
    if (mode !== 'auto') {
      return;
    }
    AppStorage.setOrCreate<string>('preferredHand', hand);
    hilog.info(DOMAIN, TAG, 'auto preferredHand=%{public}s', hand);
  }

  static setAvailable(ok: boolean): void {
    HandPrefs.ensureDefaults();
    AppStorage.setOrCreate<boolean>('motionHandAvailable', ok);
    if (!ok && (AppStorage.get<HandMode>('handMode') ?? 'auto') === 'auto') {
      // 设备无法报手（801 / 平板 / 未授权）：本会话按右手，偏好仍保留 auto。
      const cur = AppStorage.get<string>('preferredHand');
      if (cur === undefined || cur === '') {
        AppStorage.setOrCreate<string>('preferredHand', 'right');
      }
    }
  }

  static mode(): HandMode {
    return AppStorage.get<HandMode>('handMode') ?? 'auto';
  }

  static detected(): string {
    return AppStorage.get<string>('detectedHand') ?? '';
  }

  static available(): boolean {
    return AppStorage.get<boolean>('motionHandAvailable') === true;
  }

  /** 主操作按钮是否贴左侧。 */
  static primaryOnLeft(): boolean {
    return (AppStorage.get<string>('preferredHand') ?? 'right') === 'left';
  }

  static effectiveHand(): HandSide {
    return HandPrefs.primaryOnLeft() ? 'left' : 'right';
  }
}
