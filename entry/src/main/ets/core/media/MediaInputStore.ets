/**
 * 把 DocumentViewPicker 返回的临时授权文件立即固化到应用沙箱。
 *
 * 文件提供方的 URI/授权不保证能跨越长队列持续打开。任务只保存沙箱路径，
 * 从根上避免“前一项成功、后一项 Operation not permitted”。
 */
import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { PickedFile } from '../analyze/MediaAnalyzer';

function safeName(name: string): string {
  const cleaned = name.replace(/[^0-9A-Za-z._-]/g, '_');
  return cleaned.length > 0 ? cleaned : 'media.bin';
}

export class MediaInputStore {
  private static sequence: number = 0;

  static async materializeDocuments(context: common.UIAbilityContext, files: PickedFile[]): Promise<PickedFile[]> {
    const inputDir = `${context.cacheDir}/picked_inputs`;
    if (!fileIo.accessSync(inputDir)) {
      fileIo.mkdirSync(inputDir);
    }
    const local: PickedFile[] = [];
    for (const picked of files) {
      const suffix = `${Date.now()}_${MediaInputStore.sequence++}`;
      const destination = `${inputDir}/${suffix}_${safeName(picked.displayName)}`;
      let source: fileIo.File | undefined = undefined;
      try {
        // 授权最强的时刻就是 picker 返回后；先打开一次并完整复制，后续分析、
        // 排队、重试都不再依赖外部文件提供方。
        source = fileIo.openSync(picked.uri, fileIo.OpenMode.READ_ONLY);
        await fileIo.copyFile(source.fd, destination);
      } catch (e) {
        if (fileIo.accessSync(destination)) {
          fileIo.unlinkSync(destination);
        }
        throw new Error(`无法读取“${picked.displayName}”：${(e as Error).message}`);
      } finally {
        if (source !== undefined) {
          fileIo.closeSync(source);
        }
      }
      local.push({
        uri: destination,
        displayName: picked.displayName,
        mediaTypeHint: picked.mediaTypeHint,
        isMovingPhoto: picked.isMovingPhoto
      });
    }
    return local;
  }
}
