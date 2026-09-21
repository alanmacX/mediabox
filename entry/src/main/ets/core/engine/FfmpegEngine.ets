/**
 * FFmpeg 兼容引擎。
 * 仅处理本地文件；选择器 URI 会先复制到应用沙箱，绝不开放网络输入。
 */
import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import {
  FFmpegCommandBuilder,
  FFmpegFactory,
  FFmpegManager,
  ContainerFormat,
  TaskCallback,
  FFMpegUtils
} from '@prq/ffmpeg-tools';
import { MediaTask } from '../task/MediaTask';

function safeStem(name: string): string {
  const dot = name.lastIndexOf('.');
  const stem = dot > 0 ? name.substring(0, dot) : name;
  const cleaned = stem.replace(/[^0-9A-Za-z_-]/g, '_');
  return cleaned.length > 0 ? cleaned : 'media';
}

function sourceExtension(name: string): string {
  const dot = name.lastIndexOf('.');
  if (dot < 0 || dot >= name.length - 1) {
    return 'bin';
  }
  return name.substring(dot + 1).replace(/[^0-9A-Za-z]/g, '').toLowerCase();
}

class PromiseTaskCallback implements TaskCallback {
  private resolveTask: () => void;
  private rejectTask: (error: Error) => void;
  private progressTask: (pct: number) => void;
  private startedTask: () => void;
  private settled = false;
  private lastProgressDispatchMs = 0;

  constructor(resolveTask: () => void, rejectTask: (error: Error) => void,
    progressTask: (pct: number) => void, startedTask: () => void) {
    this.resolveTask = resolveTask;
    this.rejectTask = rejectTask;
    this.progressTask = progressTask;
    this.startedTask = startedTask;
  }

  onStart(): void {
    this.startedTask();
    this.progressTask(1);
  }

  onProgress(progress: number): void {
    const pct = Math.min(99, Math.max(1, Math.round(progress * 100)));
    const now = Date.now();
    // Native 日志/进度可在一帧内回调多次。限频只影响展示，不影响底层编码。
    if (pct >= 99 || now - this.lastProgressDispatchMs >= 200) {
      this.lastProgressDispatchMs = now;
      this.progressTask(pct);
    }
  }

  onSuccess(): void {
    if (!this.settled) {
      this.settled = true;
      this.resolveTask();
    }
  }

  onFailure(): void {
    // 管理器随后可能再调 onError；这里立刻 reject，避免 native 只报 failure 时 Promise 永挂。
    if (!this.settled) {
      this.settled = true;
      this.rejectTask(new Error('FFmpeg 任务失败'));
    }
  }

  onCancelled(): void {
    if (!this.settled) {
      this.settled = true;
      this.rejectTask(new Error('任务已取消'));
    }
  }

  onTimeout(): void {
    if (!this.settled) {
      this.settled = true;
      this.rejectTask(new Error('FFmpeg 任务超时'));
    }
  }

  onError(error: Error): void {
    if (!this.settled) {
      this.settled = true;
      this.rejectTask(error);
    }
  }
}

export class FfmpegEngine {
  private context: common.UIAbilityContext;
  private taskIds: Map<string, string> = new Map();
  // 文件暂存阶段没有 native task id，单独记录取消意图。
  private cancelledTaskIds: Set<string> = new Set();

  constructor(context: common.UIAbilityContext) {
    this.context = context;
    // 上游管理器默认打开逐行 native 日志；产品构建关闭，错误仍由回调返回。
    FFmpegManager.getInstance();
    FFMpegUtils.showLog(false);
  }

  async execute(task: MediaTask, onProgress: (pct: number) => void): Promise<string> {
    const inputs: string[] = [];
    try {
      // 复制 Document/Photo Picker 的内容到沙箱可能需要数秒；先给出真实的启动反馈。
      onProgress(1);
      await this.stageInputs(task, inputs, onProgress);
      this.throwIfCancelled(task.id);
      const output = this.outputPath(task);
      if (task.actionId === 'gif_target_size') {
        await this.executeGifTargetSize(task, inputs, output, onProgress);
      } else if (task.actionId === 'video_black_trim') {
        await this.executeBlackTrim(task, inputs[0], output, onProgress);
      } else {
        await this.executeCommand(task, this.commandFor(task, inputs[0], output, inputs), onProgress);
      }
      onProgress(100);
      if (task.actionId === 'video_frames' || task.actionId === 'video_scene_frames' ||
        task.actionId === 'video_split') {
        return output.substring(0, output.lastIndexOf('/'));
      }
      return output;
    } finally {
      this.taskIds.delete(task.id);
      this.cancelledTaskIds.delete(task.id);
      if (task.actionId === 'video_create_chapters') {
        const chapterPath = `${this.context.cacheDir}/chapters_${task.id}.ffmeta`;
        if (fileIo.accessSync(chapterPath)) {
          fileIo.unlinkSync(chapterPath);
        }
      }
      if (task.actionId === 'video_merge_lossless') {
        const concatPath = `${this.context.cacheDir}/concat_${task.id}.txt`;
        if (fileIo.accessSync(concatPath)) {
          fileIo.unlinkSync(concatPath);
        }
      }
      const sourceUris: string[] = [task.sourceUri];
      if (task.params.additionalSourceUris !== undefined) {
        sourceUris.push(...task.params.additionalSourceUris);
      }
      for (let i = 0; i < inputs.length; i++) {
        if (inputs[i] !== sourceUris[i] && fileIo.accessSync(inputs[i])) {
          fileIo.unlinkSync(inputs[i]);
        }
      }
    }
  }

  private async executeCommand(task: MediaTask, command: string[], onProgress: (pct: number) => void): Promise<void> {
    this.throwIfCancelled(task.id);
    if ((task.actionId.startsWith('audio_') || task.actionId === 'extract_audio' ||
      task.actionId === 'extract_audio_mp3') &&
      task.actionId !== 'audio_silence_detect' && task.actionId !== 'audio_loudness_report') {
      const args: string[] = [];
      if (task.params.targetSampleRateHz !== undefined) args.push('-ar', `${task.params.targetSampleRateHz}`);
      if (task.params.targetChannels !== undefined) args.push('-ac', `${task.params.targetChannels}`);
      if (task.params.targetAudioKbps !== undefined && !['audio_to_wav', 'audio_to_flac'].includes(task.actionId) &&
        !(task.actionId === 'extract_audio' && ['wav', 'flac'].includes(task.params.targetContainer ?? '')) &&
        !command.includes('-b:a')) {
        args.push('-b:a', `${task.params.targetAudioKbps}k`);
      }
      command.splice(command.length - 1, 0, ...args);
    }
    if (task.params.targetVideoKbps !== undefined && task.actionId.startsWith('video_') &&
      !command.includes('-b:v')) {
      command.splice(command.length - 1, 0, '-b:v', `${task.params.targetVideoKbps}k`);
    }
    await new Promise<void>((resolve, reject) => {
      let settled = false;
      let nativeTaskId = '';
      const finish = (error?: Error): void => {
        if (settled) {
          return;
        }
        settled = true;
        if (error === undefined) {
          resolve();
        } else {
          reject(error);
        }
      };
      const callback = new PromiseTaskCallback(
        (): void => finish(),
        (error: Error): void => finish(error),
        onProgress,
        (): void => {}
      );
      try {
        nativeTaskId = FFmpegManager.getInstance().execute(command, 0, callback);
        this.taskIds.set(task.id, nativeTaskId);
      } catch (e) {
        finish(e as Error);
      }
    });
  }

  private async executeGifTargetSize(task: MediaTask, inputs: string[], output: string,
    onProgress: (pct: number) => void): Promise<void> {
    const targetBytes = Math.max(1, task.params.targetBytes ?? 5 * 1024 * 1024);
    let width = Math.max(160, task.params.targetWidth ?? 640);
    let fps = Math.max(4, task.params.targetFps ?? 15);
    let colors = 256;
    // 迭代会调整尺寸、帧率和调色板；结束后还原用户在历史记录中的原始参数。
    const originalWidth = task.params.targetWidth;
    const originalFps = task.params.targetFps;
    const originalColors = task.params.paletteColors;
    try {
      for (let attempt = 0; attempt < 5; attempt++) {
        task.params.targetWidth = width;
        task.params.targetFps = fps;
        task.params.paletteColors = colors;
        await this.executeCommand(task, this.commandFor(task, inputs[0], output, inputs), (pct: number) => {
          onProgress(Math.min(99, Math.round((attempt * 100 + pct) / 5)));
        });
        const size = fileIo.statSync(output).size;
        if (size <= targetBytes) {
          return;
        }
        const ratio = Math.max(0.55, Math.min(0.88, Math.sqrt(targetBytes / Math.max(size, 1)) * 0.96));
        width = Math.max(160, Math.floor(width * ratio / 2) * 2);
        fps = Math.max(4, Math.floor(fps * Math.max(0.72, ratio)));
        colors = colors > 128 ? 128 : (colors > 64 ? 64 : 48);
      }
      throw new Error('当前 GIF 参数无法达到目标体积，请提高目标大小或缩短时长');
    } finally {
      task.params.targetWidth = originalWidth;
      task.params.targetFps = originalFps;
      task.params.paletteColors = originalColors;
    }
  }

  private async executeBlackTrim(task: MediaTask, input: string, output: string,
    onProgress: (pct: number) => void): Promise<void> {
    const report = `${this.context.cacheDir}/black_${task.id}.txt`;
    try {
      await this.executeCommand(task, ['ffmpeg', '-i', input, '-vf',
        `blackdetect=d=0.5:pic_th=0.98,metadata=mode=print:file=${report}`, '-an', '-f', 'null', '-'],
      (pct: number) => onProgress(Math.min(45, Math.round(pct * 0.45))));
      const text = fileIo.accessSync(report) ? fileIo.readTextSync(report) : '';
      const starts: number[] = [];
      const ends: number[] = [];
      const startPattern = /lavfi\.black_start=([0-9.]+)/g;
      const endPattern = /lavfi\.black_end=([0-9.]+)/g;
      let match = startPattern.exec(text);
      while (match !== null) {
        starts.push(Number(match[1]));
        match = startPattern.exec(text);
      }
      match = endPattern.exec(text);
      while (match !== null) {
        ends.push(Number(match[1]));
        match = endPattern.exec(text);
      }
      const total = Math.max(0, task.params.totalDurationSeconds ?? 0);
      let start = 0;
      let end = total;
      if (starts.length > 0 && ends.length > 0 && starts[0] <= 0.1) {
        start = ends[0];
      }
      if (total > 0 && starts.length > 0 && ends.length > 0 && ends[ends.length - 1] >= total - 0.25) {
        end = starts[starts.length - 1];
      }
      if (end <= start || (start <= 0.01 && (total <= 0 || end >= total - 0.01))) {
        throw new Error('没有检测到可裁剪的头尾黑屏');
      }
      const command = ['ffmpeg', '-ss', `${start}`, '-i', input];
      if (end > start) {
        command.push('-t', `${end - start}`);
      }
      command.push('-c:v', 'h264_ohosavcodec');
      if (task.params.streamKind === 'av') {
        command.push('-c:a', 'aac');
      } else {
        command.push('-an');
      }
      command.push('-y', output);
      await this.executeCommand(task, command, (pct: number) => onProgress(45 + Math.round(pct * 0.54)));
    } finally {
      if (fileIo.accessSync(report)) {
        fileIo.unlinkSync(report);
      }
    }
  }

  cancel(taskId: string): boolean {
    this.cancelledTaskIds.add(taskId);
    const nativeTaskId = this.taskIds.get(taskId);
    if (nativeTaskId === undefined) {
      return true;
    }
    return FFmpegManager.getInstance().cancel(nativeTaskId);
  }

  private throwIfCancelled(taskId: string): void {
    if (this.cancelledTaskIds.has(taskId)) {
      throw new Error('任务已取消');
    }
  }

  private async stageOne(uri: string, name: string, taskId: string, index: number): Promise<string> {
    // 应用私有目录已经是 FFmpeg 可直接读取的本地文件。重复复制短基准样例
    // 会把文件系统缓存与调度抖动混进编码耗时；普通任务也无需这次复制。
    if (uri.startsWith(`${this.context.filesDir}/`) || uri.startsWith(`${this.context.cacheDir}/`)) {
      return uri;
    }
    const inputDir = `${this.context.cacheDir}/ffmpeg_inputs`;
    if (!fileIo.accessSync(inputDir)) {
      fileIo.mkdirSync(inputDir);
    }
    const staged = `${inputDir}/${safeStem(name)}_${taskId}_${index}.${sourceExtension(name)}`;
    const src = fileIo.openSync(uri, fileIo.OpenMode.READ_ONLY);
    try {
      await fileIo.copyFile(src.fd, staged);
    } finally {
      fileIo.closeSync(src);
    }
    return staged;
  }

  private async stageInputs(task: MediaTask, inputs: string[], onProgress: (pct: number) => void): Promise<void> {
    const total = 1 + (task.params.additionalSourceUris?.length ?? 0);
    inputs.push(await this.stageOne(task.sourceUri, task.displayName, task.id, 0));
    onProgress(Math.round(12 / total));
    this.throwIfCancelled(task.id);
    const uris = task.params.additionalSourceUris ?? [];
    const names = task.params.additionalDisplayNames ?? [];
    for (let i = 0; i < uris.length; i++) {
      inputs.push(await this.stageOne(uris[i], i < names.length ? names[i] : `input_${i + 1}`, task.id, i + 1));
      onProgress(Math.round((i + 2) * 12 / total));
      this.throwIfCancelled(task.id);
    }
  }

  private createChapterMetadata(task: MediaTask): string {
    const path = `${this.context.cacheDir}/chapters_${task.id}.ffmeta`;
    const interval = Math.max(1, Number(task.params.durationSeconds ?? '300'));
    const total = Math.max(interval, task.params.totalDurationSeconds ?? interval);
    let content = ';FFMETADATA1\n';
    let chapter = 1;
    for (let start = 0; start < total; start += interval) {
      const end = Math.min(total, start + interval);
      content += `[CHAPTER]\nTIMEBASE=1/1000\nSTART=${Math.round(start * 1000)}\n` +
        `END=${Math.round(end * 1000)}\ntitle=章节 ${chapter}\n`;
      chapter++;
    }
    const file = fileIo.openSync(path,
      fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
    try {
      fileIo.writeSync(file.fd, content);
    } finally {
      fileIo.closeSync(file);
    }
    return path;
  }

  private createConcatList(task: MediaTask, inputs: string[]): string {
    const path = `${this.context.cacheDir}/concat_${task.id}.txt`;
    let content = '';
    for (const input of inputs) {
      const escaped = input.replace(/'/g, "'\\''");
      content += `file '${escaped}'\n`;
    }
    const file = fileIo.openSync(path,
      fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
    try {
      fileIo.writeSync(file.fd, content);
    } finally {
      fileIo.closeSync(file);
    }
    return path;
  }

  private outputPath(task: MediaTask): string {
    const outputDir = `${this.context.filesDir}/outputs`;
    if (!fileIo.accessSync(outputDir)) {
      fileIo.mkdirSync(outputDir);
    }
    if (task.actionId === 'video_frames' || task.actionId === 'video_scene_frames' ||
      task.actionId === 'video_split') {
      const sequenceDir = `${outputDir}/${safeStem(task.displayName)}_${task.id}`;
      if (!fileIo.accessSync(sequenceDir)) {
        fileIo.mkdirSync(sequenceDir);
      }
      return task.actionId === 'video_split' ? `${sequenceDir}/part_%03d.${sourceExtension(task.displayName)}` :
        `${sequenceDir}/frame_%06d.jpg`;
    }
    let extension = 'mp4';
    if (task.actionId === 'to_gif' || (task.actionId.startsWith('gif_') &&
      task.actionId !== 'gif_to_mp4' && task.actionId !== 'gif_to_webp')) {
      extension = 'gif';
    } else if (task.actionId === 'images_to_gif') {
      extension = 'gif';
    } else if (task.actionId === 'gif_to_webp') {
      extension = 'webp';
    } else if (task.actionId === 'ff_image_watermark') {
      extension = 'jpg';
    } else if (task.actionId === 'ff_image_to_bmp') {
      extension = 'bmp';
    } else if (task.actionId === 'ff_image_to_tiff') {
      extension = 'tiff';
    } else if (task.actionId === 'image_to_avif') {
      extension = 'avif';
    } else if (task.actionId === 'video_black_detect' || task.actionId === 'audio_silence_detect' ||
      task.actionId === 'audio_loudness_report' || task.actionId === 'metadata_export') {
      extension = 'txt';
    } else if (task.actionId === 'audio_to_mp3' || task.actionId === 'extract_audio_mp3') {
      extension = 'mp3';
    } else if (task.actionId === 'audio_to_wav') {
      extension = 'wav';
    } else if (task.actionId === 'audio_to_flac') {
      extension = 'flac';
    } else if (task.actionId === 'audio_to_opus') {
      extension = 'opus';
    } else if (task.actionId === 'audio_to_ogg') {
      extension = 'ogg';
    } else if (task.actionId === 'video_to_mkv') {
      extension = 'mkv';
    } else if (task.actionId === 'video_to_mov') {
      extension = 'mov';
    } else if (task.actionId === 'video_to_webm') {
      extension = 'webm';
    } else if (task.actionId === 'video_to_avi') {
      extension = 'avi';
    } else if (task.actionId === 'video_to_ts') {
      extension = 'ts';
    } else if (task.actionId === 'video_to_flv') {
      extension = 'flv';
    } else if (task.actionId === 'video_to_m4v') {
      extension = 'm4v';
    } else if (task.actionId === 'extract_audio' || task.actionId === 'extract_audio_mp3' ||
      task.actionId.startsWith('audio_')) {
      const container = task.params.targetContainer ?? (task.actionId === 'extract_audio_mp3' ? 'mp3' : 'm4a');
      extension = ['m4a', 'wav', 'flac', 'mp3'].includes(container) ? container : 'm4a';
    } else if (task.actionId === 'video_snapshot') {
      extension = 'jpg';
    } else if (task.actionId === 'subtitle_extract') {
      extension = 'srt';
    } else if (task.actionId === 'subtitle_to_srt') {
      extension = 'srt';
    } else if (task.actionId === 'subtitle_to_vtt') {
      extension = 'vtt';
    } else if (task.actionId === 'subtitle_to_ass') {
      extension = 'ass';
    } else if (task.actionId.startsWith('stream_extract_')) {
      extension = 'mkv';
    } else if (task.actionId.startsWith('subtitle_shift_')) {
      extension = sourceExtension(task.displayName);
    } else if (task.actionId === 'video_lossless_trim' || task.actionId === 'video_mute' ||
      task.actionId === 'video_metadata_remove' || task.actionId === 'video_remove_subtitles' ||
      task.actionId === 'video_rotation_metadata' || task.actionId === 'video_remove_chapters' ||
      task.actionId === 'video_create_chapters' || task.actionId === 'video_loop' ||
      task.actionId === 'video_timecode' || task.actionId === 'metadata_edit' ||
      task.actionId === 'metadata_cover' ||
      task.actionId === 'video_merge_lossless' ||
      task.actionId.startsWith('stream_remove_') || task.actionId.startsWith('stream_metadata_')) {
      extension = sourceExtension(task.displayName);
    }
    return `${outputDir}/${safeStem(task.displayName)}_${task.id}.${extension}`;
  }

  private multiInputCommand(inputs: string[], filter: string, maps: string[], output: string,
    video: boolean, audio: boolean): string[] {
    const command: string[] = ['ffmpeg'];
    for (const input of inputs) {
      command.push('-i', input);
    }
    command.push('-filter_complex', filter);
    for (const map of maps) {
      command.push('-map', map);
    }
    if (video) {
      command.push('-c:v', 'h264_ohosavcodec', '-pix_fmt', 'yuv420p');
    }
    if (audio) {
      command.push('-c:a', 'aac', '-b:a', '192k');
    } else {
      command.push('-an');
    }
    command.push('-y', output);
    return command;
  }

  private gifPaletteFilter(sourceFilter: string, colors: number): string {
    const colorCount = Math.max(2, Math.min(256, Math.round(colors)));
    const prefix = sourceFilter.length > 0 && sourceFilter !== 'null' ? `${sourceFilter},` : '';
    return `${prefix}split[s0][s1];[s0]palettegen=max_colors=${colorCount}[p];` +
      '[s1][p]paletteuse=dither=bayer[v]';
  }

  /** 复杂滤镜（split/palettegen）必须走 -filter_complex，不能塞进 -vf。 */
  private gifComplexCommand(input: string, filter: string, output: string, loop: string | number): string[] {
    return ['ffmpeg', '-i', input, '-filter_complex', filter, '-map', '[v]',
      '-loop', `${loop}`, '-y', output];
  }

  private watermarkPosition(task: MediaTask): string {
    switch (task.params.watermarkPosition) {
      case 'top-left': return '10:10';
      case 'top-right': return 'W-w-10:10';
      case 'bottom-left': return '10:H-h-10';
      case 'bottom-right': return 'W-w-10:H-h-10';
      case 'center': return '(W-w)/2:(H-h)/2';
      default: return `${task.params.watermarkX ?? 24}:${task.params.watermarkY ?? 24}`;
    }
  }

  private commandFor(task: MediaTask, input: string, output: string, inputs: string[]): string[] {
    switch (task.actionId) {
      case 'video_merge_lossless': {
        const concatList = this.createConcatList(task, inputs);
        return ['ffmpeg', '-f', 'concat', '-safe', '0', '-i', concatList, '-map', '0', '-c', 'copy', '-y', output];
      }
      case 'video_merge': {
        const width = task.params.targetWidth ?? 1280;
        const height = task.params.targetHeight ?? 720;
        const allHaveAudio = task.params.inputHasAudio?.length === inputs.length &&
          task.params.inputHasAudio.every((hasAudio: boolean) => hasAudio);
        let normalize = '';
        let pads = '';
        for (let i = 0; i < inputs.length; i++) {
          normalize += `[${i}:v:0]scale=${width}:${height}:force_original_aspect_ratio=decrease,` +
            `pad=${width}:${height}:(ow-iw)/2:(oh-ih)/2,fps=30,setsar=1,format=yuv420p,` +
            `setpts=PTS-STARTPTS[v${i}];`;
          if (allHaveAudio) {
            normalize += `[${i}:a:0]aresample=48000,aformat=sample_fmts=fltp:` +
              `channel_layouts=stereo,asetpts=PTS-STARTPTS[a${i}];`;
            pads += `[v${i}][a${i}]`;
          } else {
            pads += `[v${i}]`;
          }
        }
        const concat = `${pads}concat=n=${inputs.length}:v=1:a=${allHaveAudio ? 1 : 0}` +
          (allHaveAudio ? '[v][a]' : '[v]');
        return this.multiInputCommand(inputs, `${normalize}${concat}`,
          allHaveAudio ? ['[v]', '[a]'] : ['[v]'], output, true, allHaveAudio);
      }
      case 'audio_merge': {
        let normalize = '';
        let pads = '';
        for (let i = 0; i < inputs.length; i++) {
          normalize += `[${i}:a:0]aresample=48000,aformat=sample_fmts=fltp:` +
            `channel_layouts=stereo,asetpts=PTS-STARTPTS[a${i}];`;
          pads += `[a${i}]`;
        }
        return this.multiInputCommand(inputs, `${normalize}${pads}concat=n=${inputs.length}:v=0:a=1[a]`,
          ['[a]'], output, false, true);
      }
      case 'images_to_video': {
        const command: string[] = ['ffmpeg'];
        let pads = '';
        for (let i = 0; i < inputs.length; i++) {
          command.push('-loop', '1', '-framerate', `${task.params.targetFps ?? 30}`,
            '-t', task.params.durationSeconds ?? '2', '-i', inputs[i]);
          pads += `[${i}:v]scale=1280:720:force_original_aspect_ratio=decrease,` +
            `pad=1280:720:(ow-iw)/2:(oh-ih)/2,setsar=1[v${i}];`;
        }
        let concatPads = '';
        for (let i = 0; i < inputs.length; i++) {
          concatPads += `[v${i}]`;
        }
        command.push('-filter_complex', `${pads}${concatPads}concat=n=${inputs.length}:v=1:a=0[v]`,
          '-map', '[v]', '-c:v', 'h264_ohosavcodec', '-pix_fmt', 'yuv420p', '-r', `${task.params.targetFps ?? 30}`, '-an', '-y', output);
        return command;
      }
      case 'images_to_gif': {
        const command: string[] = ['ffmpeg'];
        let pads = '';
        for (let i = 0; i < inputs.length; i++) {
          command.push('-loop', '1', '-framerate', `${task.params.targetFps ?? 30}`,
            '-t', task.params.durationSeconds ?? '2', '-i', inputs[i]);
          pads += `[${i}:v]scale=640:640:force_original_aspect_ratio=decrease,` +
            `pad=640:640:(ow-iw)/2:(oh-ih)/2,setsar=1[v${i}];`;
        }
        let concatPads = '';
        for (let i = 0; i < inputs.length; i++) {
          concatPads += `[v${i}]`;
        }
        command.push('-filter_complex', `${pads}${concatPads}concat=n=${inputs.length}:v=1:a=0,` +
          `fps=${task.params.targetFps ?? 12},split[s0][s1];[s0]palettegen=max_colors=128[p];[s1][p]paletteuse[out]`,
          '-map', '[out]', '-loop', '0', '-y', output);
        return command;
      }
      case 'ff_image_watermark':
        return ['ffmpeg', '-i', inputs[0], '-i', inputs[1], '-filter_complex',
          `[1:v]scale=${task.params.watermarkWidth ?? 240}:-1[wm];[0:v][wm]overlay=${this.watermarkPosition(task)}`, '-frames:v', '1', '-y', output];
      case 'ff_image_to_bmp':
        return ['ffmpeg', '-i', input, '-frames:v', '1', '-c:v', 'bmp', '-y', output];
      case 'ff_image_to_tiff':
        return ['ffmpeg', '-i', input, '-frames:v', '1', '-c:v', 'tiff', '-compression_algo', 'deflate',
          '-y', output];
      case 'image_to_avif':
        // libaom-av1；探测通过后入队
        return ['ffmpeg', '-i', input, '-frames:v', '1', '-c:v', 'libaom-av1',
          '-crf', `${Math.round(100 - (task.params.imageQuality ?? 80))}`, '-y', output];
      case 'replace_audio':
        return ['ffmpeg', '-i', inputs[0], '-i', inputs[1], '-map', '0:v:0', '-map', '1:a:0',
          '-c:v', 'copy', '-c:a', 'aac', '-b:a', '192k', '-shortest', '-y', output];
      case 'video_watermark':
        return ['ffmpeg', '-i', inputs[0], '-i', inputs[1], '-filter_complex',
          `[1:v]scale=${task.params.watermarkWidth ?? 240}:-1[wm];[0:v][wm]overlay=${this.watermarkPosition(task)}[v]`, '-map', '[v]', '-map', '0:a?',
          '-c:v', 'h264_ohosavcodec', '-c:a', 'copy', '-y', output];
      case 'image_audio_video':
        return ['ffmpeg', '-loop', '1', '-i', inputs[0], '-i', inputs[1], '-vf',
          'scale=1280:720:force_original_aspect_ratio=decrease,pad=1280:720:(ow-iw)/2:(oh-ih)/2,format=yuv420p',
          '-map', '0:v:0', '-map', '1:a:0', '-c:v', 'h264_ohosavcodec', '-c:a', 'aac', '-shortest', '-y', output];
      case 'remux_mp4':
        return FFmpegFactory.remux(input, output, ContainerFormat.MP4);
      case 'to_gif': {
        const filter = `fps=${task.params.targetFps ?? 10},scale=${task.params.targetWidth ?? 480}:-2:flags=lanczos,` +
          `split[s0][s1];[s0]palettegen=max_colors=${task.params.paletteColors ?? 128}[p];` +
          '[s1][p]paletteuse=dither=bayer[v]';
        return ['ffmpeg', '-ss', task.params.startTime ?? '00:00:00',
          '-t', task.params.durationSeconds ?? '30', '-i', input,
          '-filter_complex', filter, '-map', '[v]',
          '-loop', task.params.loopCount ?? '0', '-y', output];
      }
      case 'extract_audio': {
        const container = task.params.targetContainer ?? 'm4a';
        const codec = container === 'wav' ? 'pcm_s16le' :
          (container === 'flac' ? 'flac' : (container === 'mp3' ? 'libmp3lame' : 'aac'));
        const cmd = ['ffmpeg', '-i', input, '-map', '0:a:0', '-vn', '-c:a', codec];
        if (container === 'mp3' || container === 'm4a') {
          cmd.push('-b:a', `${task.params.targetAudioKbps ?? 192}k`);
        }
        if (task.params.targetSampleRateHz !== undefined) {
          cmd.push('-ar', `${task.params.targetSampleRateHz}`);
        }
        cmd.push('-y', output);
        return cmd;
      }
      case 'extract_audio_mp3':
        // 与 audio_to_mp3 同编码器；视频/多轨媒体抽 MP3。
        return ['ffmpeg', '-i', input, '-map', '0:a:0', '-vn', '-c:a', 'libmp3lame',
          '-b:a', `${task.params.targetAudioKbps ?? 192}k`, '-y', output];
      case 'video_trim':
        return new FFmpegCommandBuilder().input(input).startTime(task.params.startTime ?? '00:00:00')
          .duration(task.params.durationSeconds ?? '30').hwEncode().audioCodec('aac').audioBitrate('128k')
          .output(output).build();
      case 'video_to_mkv':
        return ['ffmpeg', '-i', input, '-map', '0', '-c', 'copy', '-y', output];
      case 'video_to_mov':
        // 容器转换与 MKV 同理：h264/aac 流复制即可，避免无谓的硬件重编码
        return ['ffmpeg', '-i', input, '-map', '0', '-c', 'copy', '-y', output];
      case 'video_to_webm':
        // 仅在 FFmpegCapability 探测通过后才会入队；libvpx 与原生 Vorbis 编码。
        // 原生 Vorbis 编码器只支持双声道，单声道输入必须强制 -ac 2，否则编码器初始化失败。
        return ['ffmpeg', '-i', input, '-c:v', 'libvpx', '-b:v', '1M', '-c:a', 'vorbis', '-ac', '2',
          '-strict', 'experimental', '-y', output];
      case 'video_to_avi':
        return ['ffmpeg', '-i', input, '-c:v', 'mpeg4', '-q:v', '5', '-c:a', 'pcm_s16le', '-y', output];
      case 'video_to_ts':
        return ['ffmpeg', '-i', input, '-c:v', 'h264_ohosavcodec', '-c:a', 'aac', '-f', 'mpegts', '-y', output];
      case 'video_to_flv':
        return ['ffmpeg', '-i', input, '-c:v', 'flv', '-c:a', 'aac', '-y', output];
      case 'video_to_m4v':
        return ['ffmpeg', '-i', input, '-c:v', 'h264_ohosavcodec', '-c:a', 'aac', '-f', 'mp4', '-y', output];
      case 'video_lossless_trim':
        return new FFmpegCommandBuilder().input(input).startTime(task.params.startTime ?? '00:00:00')
          .duration(task.params.durationSeconds ?? '30').videoCodec('copy').audioCodec('copy').output(output).build();
      case 'video_split':
        return ['ffmpeg', '-i', input, '-map', '0', '-c', 'copy', '-f', 'segment',
          '-segment_time', task.params.durationSeconds ?? '30', '-reset_timestamps', '1', '-y', output];
      case 'video_mute':
        return new FFmpegCommandBuilder().input(input).videoCodec('copy').arg('-an').output(output).build();
      case 'video_loop':
        return ['ffmpeg', '-stream_loop', task.params.loopCount ?? '2', '-i', input, '-map', '0', '-c', 'copy', '-y', output];
      case 'video_timecode':
        return ['ffmpeg', '-i', input, '-map', '0', '-c', 'copy', '-timecode', task.params.timecode ?? '00:00:00:00', '-y', output];
      case 'video_resize':
        return new FFmpegCommandBuilder().input(input).filter(`scale=${task.params.targetWidth ?? 1280}:${task.params.targetHeight ?? -2}:flags=lanczos`)
          .hwEncode().audioCodec('copy').output(output).build();
      case 'video_rotate':
        return new FFmpegCommandBuilder().input(input).filter(task.params.imageRotateDegrees === 180 ? 'hflip,vflip' :
          (task.params.imageRotateDegrees === 270 ? 'transpose=2' :
            (task.params.imageRotateDegrees === 0 ? 'null' : 'transpose=1')))
          .hwEncode().audioCodec('copy').output(output).build();
      case 'video_flip':
        return new FFmpegCommandBuilder().input(input).filter(task.params.imageFlipVertical ? 'vflip' : 'hflip')
          .hwEncode().audioCodec('copy').output(output).build();
      case 'video_crop':
        return new FFmpegCommandBuilder().input(input).filter(`crop=${task.params.cropWidth ?? 640}:${task.params.cropHeight ?? 360}:` +
          `${task.params.cropX ?? 0}:${task.params.cropY ?? 0}`)
          .hwEncode().audioCodec('copy').output(output).build();
      case 'video_speed':
        if (task.params.streamKind === 'av') {
          return ['ffmpeg', '-i', input, '-filter_complex',
            `[0:v]setpts=(PTS-STARTPTS)/${task.params.speed ?? 2}[v];[0:a]atempo=${task.params.speed ?? 2}[a]`, '-map', '[v]', '-map', '[a]',
            '-c:v', 'h264_ohosavcodec', '-c:a', 'aac', '-y', output];
        }
        return ['ffmpeg', '-i', input, '-vf', `setpts=(PTS-STARTPTS)/${task.params.speed ?? 2}`, '-c:v', 'h264_ohosavcodec', '-an', '-y', output];
      case 'video_rotation_metadata':
        return ['ffmpeg', '-i', input, '-map', '0', '-c', 'copy', '-metadata:s:v:0', `rotate=${task.params.imageRotateDegrees ?? 0}`, '-y', output];
      case 'video_fps':
        return new FFmpegCommandBuilder().input(input).fps(task.params.targetFps ?? 30)
          .hwEncode().audioCodec('copy').output(output).build();
      case 'video_snapshot':
        return FFmpegFactory.videoSnapshot(input, output, task.params.startTime ?? '00:00:01');
      case 'video_frames':
        return ['ffmpeg', '-i', input, '-vf', `fps=1/${task.params.durationSeconds ?? '5'}`, '-q:v', '2', '-y', output];
      case 'video_scene_frames':
        return ['ffmpeg', '-i', input, '-vf', "select='gt(scene,0.35)'", '-vsync', 'vfr', '-q:v', '2', '-y', output];
      case 'video_black_detect':
        return ['ffmpeg', '-i', input, '-vf',
          `blackdetect=d=0.5:pic_th=0.98,metadata=mode=print:file=${output}`, '-an', '-f', 'null', '-'];
      case 'video_metadata_remove':
        return new FFmpegCommandBuilder().input(input).videoCodec('copy').audioCodec('copy')
          .arg('-map_metadata', '-1').output(output).build();
      case 'metadata_export':
        return ['ffmpeg', '-i', input, '-f', 'ffmetadata', '-y', output];
      case 'video_remove_chapters':
        return ['ffmpeg', '-i', input, '-map', '0', '-map_chapters', '-1', '-c', 'copy', '-y', output];
      case 'video_create_chapters': {
        const chapters = this.createChapterMetadata(task);
        return ['ffmpeg', '-i', input, '-f', 'ffmetadata', '-i', chapters, '-map', '0',
          '-map_metadata', '0', '-map_chapters', '1', '-c', 'copy', '-y', output];
      }
      case 'subtitle_extract':
        return ['ffmpeg', '-i', input, '-map', `0:s:${task.params.trackIndex ?? 0}`, '-c:s', 'srt', '-y', output];
      case 'video_remove_subtitles':
        return ['ffmpeg', '-i', input, '-map', '0', '-map', '-0:s', '-c', 'copy', '-y', output];
      case 'subtitle_mux':
        return ['ffmpeg', '-i', inputs[0], '-i', inputs[1], '-map', '0', '-map', '1:0',
          '-c:v', 'copy', '-c:a', 'copy', '-c:s', 'mov_text', '-y', output];
      case 'subtitle_burn':
        return ['ffmpeg', '-i', inputs[0], '-vf', `subtitles=${inputs[1]}`,
          '-c:v', 'h264_ohosavcodec', '-c:a', 'copy', '-y', output];
      case 'subtitle_shift_delay':
        return ['ffmpeg', '-itsoffset', `${task.params.subtitleDelaySeconds ?? 0.5}`, '-i', input,
          '-map', '0', '-c', 'copy', '-y', output];
      case 'subtitle_shift_advance':
        return ['ffmpeg', '-itsoffset', `${task.params.subtitleDelaySeconds ?? -0.5}`, '-i', input,
          '-map', '0', '-c', 'copy', '-y', output];
      case 'subtitle_to_srt':
        return ['ffmpeg', '-i', input, '-map', '0:s:0', '-c:s', 'srt', '-y', output];
      case 'subtitle_to_vtt':
        return ['ffmpeg', '-i', input, '-map', '0:s:0', '-c:s', 'webvtt', '-y', output];
      case 'subtitle_to_ass':
        return ['ffmpeg', '-i', input, '-map', '0:s:0', '-c:s', 'ass', '-y', output];
      case 'gif_to_mp4':
        return new FFmpegCommandBuilder().input(input).filter('scale=trunc(iw/2)*2:trunc(ih/2)*2')
          .hwEncode().arg('-pix_fmt', 'yuv420p').arg('-an').output(output).build();
      case 'gif_to_webp':
        // 仅在 FFmpegCapability 探测到 libwebp_anim 后才会入队。
        return ['ffmpeg', '-i', input, '-loop', '0', '-c:v', 'libwebp_anim', '-lossless', '0',
          '-q:v', `${task.params.imageQuality ?? 75}`, '-y', output];
      case 'gif_optimize':
        // 设备上 palettegen/paletteuse 可能挂死；产品路径用稳定的 fps+scale GIF 重编码
        return ['ffmpeg', '-i', input, '-vf',
          `fps=${task.params.targetFps ?? 12},scale=${task.params.targetWidth ?? 640}:-2:flags=lanczos`,
          '-c:v', 'gif', '-loop', task.params.loopCount ?? '0', '-y', output];
      case 'gif_target_size': {
        const filter = `fps=${task.params.targetFps ?? 15},scale=${task.params.targetWidth ?? 640}:-2:flags=lanczos,` +
          `split[s0][s1];[s0]palettegen=max_colors=${task.params.paletteColors ?? 256}[p];` +
          '[s1][p]paletteuse=dither=bayer[v]';
        return this.gifComplexCommand(input, filter, output, '0');
      }
      case 'gif_trim': {
        return ['ffmpeg', '-ss', task.params.startTime ?? '00:00:00', '-t', task.params.durationSeconds ?? '30',
          '-i', input,
          '-filter_complex', this.gifPaletteFilter('', task.params.paletteColors ?? 256),
          '-map', '[v]', '-loop', task.params.loopCount ?? '0', '-y', output];
      }
      case 'gif_crop': {
        const cropWidth = Math.max(1, task.params.cropWidth ?? 320);
        const cropHeight = Math.max(1, task.params.cropHeight ?? 320);
        const filter = this.gifPaletteFilter(
          `crop=${cropWidth}:${cropHeight}:${task.params.cropX ?? 0}:${task.params.cropY ?? 0}`,
          task.params.paletteColors ?? 256);
        return this.gifComplexCommand(input, filter, output, task.params.loopCount ?? '0');
      }
      case 'gif_resize':
        return this.gifComplexCommand(input,
          this.gifPaletteFilter(
            `scale=${Math.max(1, task.params.targetWidth ?? 480)}:${task.params.targetHeight ?? -2}:flags=lanczos`,
            task.params.paletteColors ?? 256),
          output, task.params.loopCount ?? '0');
      case 'gif_fps':
        return this.gifComplexCommand(input,
          this.gifPaletteFilter(`fps=${Math.max(1, task.params.targetFps ?? 12)}`, task.params.paletteColors ?? 256),
          output, task.params.loopCount ?? '0');
      case 'gif_speed':
        return this.gifComplexCommand(input,
          this.gifPaletteFilter(`setpts=${1 / Math.max(0.05, task.params.speed ?? 1)}*PTS`,
            task.params.paletteColors ?? 256),
          output, task.params.loopCount ?? '0');
      case 'gif_loop':
        return ['ffmpeg', '-i', input, '-c', 'copy', '-loop', task.params.loopCount ?? '0', '-y', output];
      case 'gif_quality':
        return this.gifComplexCommand(input,
          this.gifPaletteFilter('', task.params.paletteColors ?? 128),
          output, task.params.loopCount ?? '0');
      case 'audio_convert':
        return new FFmpegCommandBuilder().input(input).arg('-vn').audioCodec('aac')
          .audioBitrate(`${task.params.targetAudioKbps ?? 192}k`).output(output).build();
      case 'audio_to_mp3':
        // 仅在 FFmpegCapability 探测到 libmp3lame 后才会入队；码率/采样率由执行器统一注入。
        return ['ffmpeg', '-i', input, '-vn', '-c:a', 'libmp3lame', '-y', output];
      case 'audio_to_wav':
        return ['ffmpeg', '-i', input, '-vn', '-c:a', 'pcm_s16le', '-ar',
          `${task.params.targetSampleRateHz ?? 48000}`, '-y', output];
      case 'audio_to_flac':
        return ['ffmpeg', '-i', input, '-vn', '-c:a', 'flac', '-y', output];
      case 'audio_to_opus':
        return ['ffmpeg', '-i', input, '-vn', '-c:a', 'opus', '-strict', 'experimental', '-b:a',
          `${task.params.targetAudioKbps ?? 128}k`, '-y', output];
      case 'audio_to_ogg':
        return ['ffmpeg', '-i', input, '-vn', '-c:a', 'vorbis', '-strict', 'experimental', '-b:a',
          `${task.params.targetAudioKbps ?? 192}k`, '-y', output];
      case 'audio_trim':
        return new FFmpegCommandBuilder().input(input).startTime(task.params.startTime ?? '00:00:00')
          .duration(task.params.durationSeconds ?? '30').audioCodec('aac')
          .audioBitrate(`${task.params.targetAudioKbps ?? 192}k`).output(output).build();
      case 'audio_normalize':
        return new FFmpegCommandBuilder().input(input).arg('-vn')
          .arg('-af', `loudnorm=I=${task.params.loudnessLufs ?? -16}:TP=${task.params.truePeakDb ?? -1.5}:LRA=${task.params.loudnessRange ?? 11}`).audioCodec('aac')
          .audioBitrate(`${task.params.targetAudioKbps ?? 192}k`).output(output).build();
      case 'audio_peak_normalize':
        return ['ffmpeg', '-i', input, '-vn', '-af', `dynaudnorm=p=${task.params.peakLevel ?? 0.95}:m=100`,
          '-c:a', 'aac', '-b:a', `${task.params.targetAudioKbps ?? 192}k`, '-y', output];
      case 'audio_remove_silence':
        return ['ffmpeg', '-i', input, '-vn', '-af',
          `silenceremove=start_periods=1:start_duration=${task.params.silenceDurationSeconds ?? 0.5}:` +
          `start_threshold=${task.params.silenceThresholdDb ?? -35}dB:stop_periods=-1:` +
          `stop_duration=${task.params.silenceDurationSeconds ?? 0.5}:stop_threshold=${task.params.silenceThresholdDb ?? -35}dB`,
          '-c:a', 'aac', '-b:a', `${task.params.targetAudioKbps ?? 192}k`, '-y', output];
      case 'audio_silence_detect':
        return ['ffmpeg', '-i', input, '-af',
          `silencedetect=noise=${task.params.silenceThresholdDb ?? -35}dB:d=${task.params.silenceDurationSeconds ?? 0.5},ametadata=mode=print:file=${output}`, '-vn', '-f', 'null', '-'];
      case 'audio_loudness_report':
        return ['ffmpeg', '-i', input, '-af',
          `ebur128=metadata=1,ametadata=mode=print:file=${output}`, '-vn', '-f', 'null', '-'];
      case 'audio_volume':
        return new FFmpegCommandBuilder().input(input).arg('-vn')
          .arg('-af', `volume=${task.params.volumeMultiplier ?? 1.5}`).audioCodec('aac')
          .audioBitrate(`${task.params.targetAudioKbps ?? 192}k`).output(output).build();
      case 'audio_fade': {
        // 淡出锚点基于完整输入时长；旧任务参数里只有裁剪时长时才退回该值。
        const total = task.params.totalDurationSeconds ??
          Math.max(0, Number(task.params.durationSeconds ?? '30'));
        return new FFmpegCommandBuilder().input(input).arg('-vn')
          .arg('-af', `afade=t=in:st=0:d=${task.params.fadeInSeconds ?? 2},afade=t=out:st=${Math.max(0, total - (task.params.fadeOutSeconds ?? 2))}:d=${task.params.fadeOutSeconds ?? 2}`)
          .audioCodec('aac')
          .audioBitrate(`${task.params.targetAudioKbps ?? 192}k`).output(output).build();
      }
      case 'audio_mono':
        return new FFmpegCommandBuilder().input(input).arg('-vn')
          .arg('-ar', `${task.params.targetSampleRateHz ?? 48000}`).arg('-ac', `${task.params.targetChannels ?? 1}`)
          .audioCodec('aac').audioBitrate(`${task.params.targetAudioKbps ?? 192}k`).output(output).build();
      case 'audio_stereo':
        return ['ffmpeg', '-i', input, '-vn', '-ar', `${task.params.targetSampleRateHz ?? 48000}`,
          '-ac', '2', '-c:a', 'aac', '-b:a', `${task.params.targetAudioKbps ?? 192}k`, '-y', output];
      case 'audio_resample':
        return ['ffmpeg', '-i', input, '-vn', '-ar', `${task.params.targetSampleRateHz ?? 44100}`,
          '-c:a', 'aac', '-b:a', `${task.params.targetAudioKbps ?? 192}k`, '-y', output];
      case 'metadata_edit': {
        const command = ['ffmpeg', '-i', input, '-map', '0', '-c', 'copy'];
        command.push('-metadata', `title=${task.params.metadataTitle ?? ''}`,
          '-metadata', `artist=${task.params.metadataArtist ?? ''}`,
          '-metadata', `album_artist=${task.params.metadataAlbumArtist ?? ''}`,
          '-metadata', `album=${task.params.metadataAlbum ?? ''}`,
          '-metadata', `author=${task.params.metadataAuthor ?? ''}`,
          '-metadata', `composer=${task.params.metadataComposer ?? ''}`,
          '-metadata', `genre=${task.params.metadataGenre ?? ''}`,
          '-metadata', `creation_time=${task.params.metadataCreationTime ?? ''}`, '-y', output);
        return command;
      }
      case 'metadata_cover':
        return ['ffmpeg', '-i', inputs[0], '-i', inputs[1], '-map', '0:a:0', '-map', '1:v:0',
          '-c:a', 'copy', '-c:v', 'mjpeg', '-disposition:v:0', 'attached_pic', '-y', output];
      default:
        if (task.actionId.startsWith('stream_extract_')) {
          const index = task.actionId.substring('stream_extract_'.length);
          return ['ffmpeg', '-i', input, '-map', `0:${index}`, '-c', 'copy', '-y', output];
        }
        if (task.actionId.startsWith('stream_remove_')) {
          const index = task.actionId.substring('stream_remove_'.length);
          return ['ffmpeg', '-i', input, '-map', '0', '-map', `-0:${index}`, '-c', 'copy', '-y', output];
        }
        if (task.actionId.startsWith('stream_metadata_')) {
          const index = task.actionId.substring('stream_metadata_'.length);
          return ['ffmpeg', '-i', input, '-map', '0', '-c', 'copy',
            `-metadata:s:${index}`, `title=${task.params.trackTitle ?? ''}`,
            `-metadata:s:${index}`, `language=${task.params.trackLanguage ?? ''}`, '-y', output];
        }
        throw new Error(`FFmpeg 不支持该操作: ${task.actionId}`);
    }
  }
}
