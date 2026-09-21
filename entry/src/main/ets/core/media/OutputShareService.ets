/**
 * Share Kit 输出分享。
 * 应用沙箱路径先通过 fileUri 转为可授权 URI，再交由系统分享面板分发。
 */
import { common } from '@kit.AbilityKit';
import { fileUri } from '@kit.CoreFileKit';
import { picker } from '@kit.CoreFileKit';
import { fileIo } from '@kit.CoreFileKit';
import { uniformTypeDescriptor as utd } from '@kit.ArkData';
import { systemShare } from '@kit.ShareKit';

function sharedType(path: string): string {
  const ext = path.substring(path.lastIndexOf('.') + 1).toLowerCase();
  if (['jpg', 'jpeg', 'png', 'webp', 'heif', 'heic', 'avif', 'gif', 'bmp', 'tif', 'tiff'].includes(ext)) {
    return utd.UniformDataType.IMAGE;
  }
  if (['mp4', 'mov', 'mkv', 'webm', 'avi', 'ts', 'flv', 'm4v', '3gp'].includes(ext)) {
    return utd.UniformDataType.VIDEO;
  }
  if (['mp3', 'aac', 'm4a', 'wav', 'flac', 'ogg', 'opus', 'amr'].includes(ext)) {
    return utd.UniformDataType.AUDIO;
  }
  return utd.UniformDataType.FILE;
}

export class OutputShareService {
  static async save(context: common.UIAbilityContext, outputPath: string): Promise<boolean> {
    if (fileIo.statSync(outputPath).isDirectory()) {
      throw new Error('多文件结果请通过“分享结果”批量导出');
    }
    const name = outputPath.substring(outputPath.lastIndexOf('/') + 1);
    const destinations = await new picker.DocumentViewPicker(context).save({ newFileNames: [name] });
    if (destinations.length === 0) {
      return false;
    }
    const source = await fileIo.open(outputPath, fileIo.OpenMode.READ_ONLY);
    try {
      // Some document providers may return an existing destination. Truncate it before copying so
      // overwriting a larger file with a smaller result cannot leave stale trailing bytes.
      const target = await fileIo.open(destinations[0], fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.TRUNC);
      try {
        await fileIo.copyFile(source.fd, target.fd);
      } finally {
        await fileIo.close(target);
      }
    } finally {
      await fileIo.close(source);
    }
    return true;
  }

  static async show(context: common.UIAbilityContext, outputPath: string, title: string): Promise<void> {
    if (!canIUse('SystemCapability.Collaboration.SystemShare')) {
      throw new Error('当前设备不支持系统分享');
    }
    const stat = fileIo.statSync(outputPath);
    let data: systemShare.SharedData;
    let selectionMode = systemShare.SelectionMode.SINGLE;
    if (stat.isDirectory()) {
      const names = fileIo.listFileSync(outputPath);
      if (names.length === 0) {
        throw new Error('输出目录为空');
      }
      const firstPath = `${outputPath}/${names[0]}`;
      data = new systemShare.SharedData({ utd: sharedType(firstPath), uri: fileUri.getUriFromPath(firstPath),
        title: names[0], description: '由MediaBox媒体工具箱在本机处理生成' });
      for (let i = 1; i < names.length; i++) {
        const path = `${outputPath}/${names[i]}`;
        data.addRecord({ utd: sharedType(path), uri: fileUri.getUriFromPath(path), title: names[i] });
      }
      selectionMode = systemShare.SelectionMode.BATCH;
    } else {
      data = new systemShare.SharedData({
        utd: sharedType(outputPath),
        uri: fileUri.getUriFromPath(outputPath),
        title: title,
        description: '由MediaBox媒体工具箱在本机处理生成'
      });
    }
    const controller = new systemShare.ShareController(data);
    await controller.show(context, {
      selectionMode: selectionMode,
      previewMode: systemShare.SharePreviewMode.DETAIL
    });
  }
}
