/**
 * 媒体性能指数 — 固定负载和固定参考吞吐量。
 *
 * - 子项用「吞吐指标」而非绝对耗时：实时倍速 / MB/s / MP/s
 * - 子项指数 = 100 × 吞吐/参考吞吐；100 是参考值，不是满分
 * - 总指数 = 500 × 各子项吞吐比的加权几何平均；无固定上限
 * - 每项先预热，再测多批次，并报告批次间变异系数
 * - 负载过小（纯开销）不计分
 */

export interface BenchItemSpec {
  id: string;
  title: string;
  weight: number;
  /** 指标单位说明 */
  metricLabel: string;
  /** 此版本冻结的参考吞吐量；子项达到此值时指数为 100。 */
  referenceMetric: number;
  note: string;
}

export interface BenchItemResult {
  id: string;
  title: string;
  ok: boolean;
  /** 原始指标 */
  metric: number;
  metricLabel: string;
  /** 参考吞吐量为 100，无固定上限。 */
  score: number;
  weight: number;
  note: string;
  detail: string;
  elapsedMs: number;
  referenceMetric: number;
  /** 三个固定批次的每次操作耗时，单位毫秒。 */
  samplesMs: number[];
  iterations: number;
  /** 每次操作耗时在批次间的变异系数。 */
  variationPct: number;
}

export interface BenchReport {
  version: string;
  score: number;
  items: BenchItemResult[];
  passed: number;
  total: number;
  deviceNote: string;
  maxVariationPct: number;
}

export class BenchSpecs {
  /** 参考吞吐量沿用上一版总分公式的固定基线；调整时须升级跑分版本。 */
  static items(): BenchItemSpec[] {
    // 顺序：原生/不依赖 FFmpeg 的项在前；GIF 最后，避免挂死堵住单线程 FFmpeg 队列
    return [
      {
        id: 'image_resize',
        title: '大图缩放编码',
        weight: 1,
        metricLabel: 'MP/s',
        referenceMetric: 47,
        note: 'Image Kit · 像素/秒'
      },
      {
        id: 'image_stack',
        title: '双图拼接',
        weight: 1,
        metricLabel: 'MP/s',
        referenceMetric: 23.5,
        note: '原生合成输出像素吞吐'
      },
      {
        id: 'video_native_720p',
        title: '视频硬件转码',
        weight: 1,
        metricLabel: '实时倍速 x',
        referenceMetric: 1.8,
        note: 'AVTranscoder · 不放大分辨率'
      },
      {
        id: 'audio_aac',
        title: '音频转 AAC',
        weight: 1,
        metricLabel: '实时倍速 x',
        referenceMetric: 61.5,
        note: '正弦样例 → AAC'
      },
      {
        id: 'audio_mp3',
        title: '音频转 MP3',
        weight: 1,
        metricLabel: '实时倍速 x',
        referenceMetric: 41,
        note: 'libmp3lame（探测通过）'
      },
      {
        id: 'audio_normalize',
        title: '响度标准化',
        weight: 1,
        metricLabel: '实时倍速 x',
        referenceMetric: 12.75,
        note: 'loudnorm（有效音频）'
      },
      {
        id: 'video_remux',
        title: '无损封装 Remux',
        weight: 1,
        metricLabel: 'MB/s',
        referenceMetric: 41,
        note: 'FFmpeg stream copy'
      },
      {
        id: 'gif_optimize',
        title: 'GIF 优化',
        weight: 1,
        metricLabel: '实时倍速 x',
        referenceMetric: 6.2,
        note: 'FFmpeg GIF 重编码'
      }
    ];
  }
}

export class BenchScoring {
  static readonly VERSION: string = 'media-v2';
  static readonly BASELINE_SCORE: number = 500;

  /** 单项指数：100 代表本版本的固定参考吞吐量。 */
  static scoreFromMetric(referenceMetric: number, metric: number): number {
    if (!Number.isFinite(referenceMetric) || !(referenceMetric > 0) ||
      !Number.isFinite(metric) || !(metric > 0)) {
      return 0;
    }
    return Math.round(100 * metric / referenceMetric);
  }

  static median(values: number[]): number {
    const list = values.filter((v: number): boolean => Number.isFinite(v) && v > 0)
      .slice()
      .sort((a: number, b: number): number => a - b);
    if (list.length === 0) {
      return 0;
    }
    const mid = Math.floor(list.length / 2);
    return list.length % 2 === 1 ? list[mid] : (list[mid - 1] + list[mid]) / 2;
  }

  static coefficientOfVariation(values: number[]): number {
    const samples = values.filter((v: number): boolean => Number.isFinite(v) && v > 0);
    if (samples.length < 2) {
      return 0;
    }
    const mean = samples.reduce((sum: number, v: number): number => sum + v, 0) / samples.length;
    const variance = samples.reduce((sum: number, v: number): number => sum + (v - mean) * (v - mean), 0) /
      samples.length;
    return Math.sqrt(variance) / mean * 100;
  }

  /** 吞吐/参考值的加权几何平均；全项达到参考值时为 500。 */
  static overallScore(items: BenchItemResult[]): number {
    let logSum = 0;
    let weightSum = 0;
    for (const item of items) {
      if (!item.ok || !Number.isFinite(item.metric) || !(item.metric > 0) ||
        !Number.isFinite(item.referenceMetric) || !(item.referenceMetric > 0)) {
        continue;
      }
      const weight = item.weight > 0 ? item.weight : 1;
      logSum += Math.log(item.metric / item.referenceMetric) * weight;
      weightSum += weight;
    }
    if (weightSum === 0) {
      return 0;
    }
    const total = BenchScoring.BASELINE_SCORE * Math.exp(logSum / weightSum);
    if (!Number.isFinite(total) || total <= 0) {
      return 0;
    }
    return Math.round(total);
  }

  static buildReport(raw: BenchItemResult[], deviceNote: string): BenchReport {
    const passed = raw.filter((r: BenchItemResult): boolean => r.ok).length;
    const complete = raw.length > 0 && passed === raw.length;
    const score = complete ? BenchScoring.overallScore(raw) : 0;
    const maxVariationPct = raw.reduce((max: number, item: BenchItemResult): number =>
      Math.max(max, item.variationPct), 0);
    return {
      version: BenchScoring.VERSION,
      score: score,
      items: raw,
      passed: passed,
      total: raw.length,
      deviceNote: deviceNote,
      maxVariationPct: maxVariationPct
    };
  }

  /** 实时倍速：媒体时长秒 / 耗时秒。 */
  static realtimeFactor(contentSeconds: number, elapsedMs: number): number {
    if (!(contentSeconds > 0) || !(elapsedMs > 0)) {
      return 0;
    }
    return contentSeconds / (elapsedMs / 1000);
  }

  /** 兆像素每秒。 */
  static megapixelsPerSec(width: number, height: number, elapsedMs: number): number {
    if (!(width > 0) || !(height > 0) || !(elapsedMs > 0)) {
      return 0;
    }
    return (width * height) / 1e6 / (elapsedMs / 1000);
  }

  /** MB/s。 */
  static megabytesPerSec(bytes: number, elapsedMs: number): number {
    if (!(bytes > 0) || !(elapsedMs > 0)) {
      return 0;
    }
    return (bytes / (1024 * 1024)) / (elapsedMs / 1000);
  }
}
