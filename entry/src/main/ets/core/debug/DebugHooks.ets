/**
 * 模拟器/真机调试 Hook — 跳过系统选择器，直接用 rawfile 样例进工作台。
 *
 * 触发：连点首页标题 5 次（仅本包调试；正式包可去掉入口）。
 * 用途：横屏/桌面验证时不经过慢速图库与文件选择器。
 */
import { common } from '@kit.AbilityKit';
import { fileIo, fileUri } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { MediaType } from '../model/MediaTypes';
import { guessMediaType, PickedFile } from '../analyze/MediaAnalyzer';
import { WorkbenchSession, RouteNames } from '../../ui/components/WorkbenchSession';

const TAG = 'DebugHooks';
const DOMAIN = 0x4D42;

export class DebugHooks {
  private static taps: number = 0;
  private static lastTapMs: number = 0;

  /** 标题连点 5 次返回 true。 */
  static registerTitleTap(): boolean {
    const now = Date.now();
    if (now - DebugHooks.lastTapMs > 800) {
      DebugHooks.taps = 0;
    }
    DebugHooks.lastTapMs = now;
    DebugHooks.taps++;
    if (DebugHooks.taps >= 5) {
      DebugHooks.taps = 0;
      return true;
    }
    return false;
  }

  /**
   * 把 rawfile 样例拷入沙箱并直接进工作台。
   * @param kind video | gif | image | audio
   */
  static async openFixture(context: common.UIAbilityContext, pathStack: NavPathStack,
    kind: string): Promise<void> {
    const nameMap: Map<string, string> = new Map([
      ['video', 'fixtures/sample_video.mp4'],
      ['gif', 'fixtures/sample.gif'],
      ['image', 'fixtures/sample_image.jpg'],
      ['audio', 'fixtures/sample_audio.m4a']
    ]);
    const raw = nameMap.get(kind);
    if (raw === undefined) {
      return;
    }
    try {
      const bytes = await context.resourceManager.getRawFileContent(raw);
      const display = raw.substring(raw.lastIndexOf('/') + 1);
      const dest = `${context.cacheDir}/debug_${display}`;
      const file = fileIo.openSync(dest,
        fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      fileIo.writeSync(file.fd, bytes.buffer);
      fileIo.closeSync(file);
      const uri = fileUri.getUriFromPath(dest);
      const hinted = guessMediaType(display);
      const picked: PickedFile = {
        uri: uri,
        displayName: display,
        mediaTypeHint: hinted === MediaType.UNKNOWN ? undefined : hinted
      };
      WorkbenchSession.clear();
      WorkbenchSession.picked = picked;
      pathStack.pushPathByName(RouteNames.WORKBENCH, 'debug');
      hilog.info(DOMAIN, TAG, 'open fixture %{public}s -> %{public}s', kind, uri);
    } catch (e) {
      const err = e as Error;
      hilog.error(DOMAIN, TAG, 'open fixture failed %{public}s', err.message);
      throw err;
    }
  }
}
