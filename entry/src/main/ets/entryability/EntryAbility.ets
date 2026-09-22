/**
 * EntryAbility — 沉浸式窗口 + 自适应度量注入。
 *
 * 按官方《开发沉浸式效果》指南:
 *   setWindowLayoutFullScreen(true) 让内容延伸到状态栏/导航区,
 *   getWindowAvoidArea + on('avoidAreaChange') 动态获取避让高度写入 AppStorage,
 *   页面据此做安全区留白;宽度(vp)写入 AppStorage 驱动断点适配,
 *   旋转 / 折叠 / 分屏 / 自由窗口缩放全部实时响应。
 *
 */
import { AbilityConstant, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { display, window } from '@kit.ArkUI';
import { TaskQueue } from '../core/task/TaskQueue';
import { NativeEngineExecutor } from '../core/engine/NativeEngine';
import { systemShare } from '@kit.ShareKit';
import { WorkbenchSession } from '../ui/components/WorkbenchSession';
import { HandPrefs, MotionHandService } from '../core/capability/MotionHandService';

const DOMAIN = 0x4D42;
const TAG = 'EntryAbility';

export default class EntryAbility extends UIAbility {
  private readonly motionHand = new MotionHandService();
  private handPrefsReady: Promise<void> = Promise.resolve();
  private inForeground: boolean = false;

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    this.context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
    TaskQueue.getInstance().init(this.context, new NativeEngineExecutor(this.context));
    HandPrefs.ensureDefaults();
    this.handPrefsReady = HandPrefs.load(this.context);
    this.handleSharedWant(want);
    hilog.info(DOMAIN, TAG, 'Ability onCreate');
  }

  onNewWant(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    this.handleSharedWant(want);
  }

  /** Share Kit 官方接收链路：sendData Want → getSharedData → 本地工作台。 */
  private handleSharedWant(want: Want): void {
    if (want.action !== 'ohos.want.action.sendData') {
      return;
    }
    systemShare.getSharedData(want).then((data: systemShare.SharedData) => {
      const records = data.getRecords();
      for (const record of records) {
        if (record.uri === undefined || record.uri.length === 0) {
          continue;
        }
        const pathName = record.uri.substring(record.uri.lastIndexOf('/') + 1);
        WorkbenchSession.result = undefined;
        WorkbenchSession.picked = {
          uri: record.uri,
          displayName: record.title ?? decodeURIComponent(pathName)
        };
        WorkbenchSession.sharedPending = true;
        const version = AppStorage.get<number>('sharedFileVersion') ?? 0;
        AppStorage.setOrCreate('sharedFileVersion', version + 1);
        return;
      }
      hilog.warn(DOMAIN, TAG, 'shared data has no file URI');
    }).catch((e: Error) => {
      hilog.warn(DOMAIN, TAG, 'getSharedData failed %{public}s', e.message);
    });
  }

  onDestroy(): void {
    this.inForeground = false;
    this.motionHand.stop();
    // 官方建议在应用关闭时主动 stopLiveView；普通退后台不会触发 onDestroy，
    // 因此不会影响获批后的后台媒体处理。
    TaskQueue.getInstance().onAbilityDestroy();
    hilog.info(DOMAIN, TAG, 'Ability onDestroy');
  }

  private pushWindowMetrics(win: window.Window): void {
    const props = win.getWindowProperties();
    const densityPixels = display.getDefaultDisplaySync().densityPixels;
    const density = densityPixels > 0 ? densityPixels : 1;
    const widthVp = props.windowRect.width / density;
    const heightVp = props.windowRect.height / density;
    AppStorage.setOrCreate('windowWidthVp', widthVp);
    AppStorage.setOrCreate('windowHeightVp', heightVp);
    AppStorage.setOrCreate('isLandscape', widthVp > heightVp);
    const sysAvoid = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
    AppStorage.setOrCreate('safeTopVp', sysAvoid.topRect.height / density);
    AppStorage.setOrCreate('safeLeftVp', sysAvoid.leftRect.width / density);
    AppStorage.setOrCreate('safeRightVp', sysAvoid.rightRect.width / density);
    const indicator = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR);
    AppStorage.setOrCreate('safeBottomVp', indicator.bottomRect.height / density);
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, TAG, 'Failed to load the content. Cause: %{public}s', JSON.stringify(err));
        return;
      }
      const win = windowStage.getMainWindowSync();
      win.setWindowLayoutFullScreen(true).then(() => {
        this.pushWindowMetrics(win);
        win.on('windowSizeChange', () => this.pushWindowMetrics(win));
        win.on('avoidAreaChange', () => this.pushWindowMetrics(win));
        hilog.info(DOMAIN, TAG, 'immersive layout enabled');
      }).catch((e: Error) => {
        hilog.warn(DOMAIN, TAG, 'setWindowLayoutFullScreen failed %{public}s', e.message);
      });
    });
  }

  onWindowStageDestroy(): void {
    hilog.info(DOMAIN, TAG, 'Ability onWindowStageDestroy');
  }

  onForeground(): void {
    this.inForeground = true;
    this.handPrefsReady.then((): void => {
      if (!this.inForeground) {
        return;
      }
      const subscribed = this.motionHand.start((hand) => HandPrefs.onDetected(hand));
      HandPrefs.setAvailable(subscribed);
    }).catch((e: Error) => {
      hilog.warn(DOMAIN, TAG, 'hand preferences load failed %{public}s', e.message);
      HandPrefs.setAvailable(false);
    });
    hilog.info(DOMAIN, TAG, 'Ability onForeground');
  }

  onBackground(): void {
    this.inForeground = false;
    this.motionHand.stop();
    HandPrefs.setAvailable(false);
    hilog.info(DOMAIN, TAG, 'Ability onBackground');
  }
}
