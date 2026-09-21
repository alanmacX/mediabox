/**
 * 跑分历史 — preferences 持久化 + 跨页传递选中项。
 * 性能页写结果；历史列表页读全量；详情页读 selected。
 */
import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BenchReport } from './BenchScoring';

const BENCH_PREF = 'mediabox_bench_history';
const BENCH_KEY = 'history_v1';
const BENCH_HIST_MAX = 20;

export interface BenchHistoryEntry {
  savedAt: number;
  elapsedSec: number;
  report: BenchReport;
}

export class BenchHistoryStore {
  /** 详情页数据源：列表页点选后写入，push 进详情页读取。 */
  static selected?: BenchHistoryEntry;

  static async load(context: common.UIAbilityContext): Promise<BenchHistoryEntry[]> {
    try {
      const store = await preferences.getPreferences(context, BENCH_PREF);
      const raw = store.getSync(BENCH_KEY, '[]') as string;
      return JSON.parse(raw) as BenchHistoryEntry[];
    } catch (e) {
      hilog.warn(0x4D42, 'BenchHistory', 'load %{public}s', (e as Error).message);
      return [];
    }
  }

  static async add(context: common.UIAbilityContext, entry: BenchHistoryEntry): Promise<void> {
    try {
      const store = await preferences.getPreferences(context, BENCH_PREF);
      const list = await BenchHistoryStore.load(context);
      const next = [entry].concat(list).slice(0, BENCH_HIST_MAX);
      store.putSync(BENCH_KEY, JSON.stringify(next));
      await store.flush();
    } catch (e) {
      hilog.warn(0x4D42, 'BenchHistory', 'add %{public}s', (e as Error).message);
    }
  }

  static formatTime(ts: number): string {
    const d = new Date(ts);
    return `${d.getFullYear()}-${d.getMonth() + 1}-${d.getDate()} ${d.getHours()}:${String(d.getMinutes()).padStart(2, '0')}`;
  }

  /** 详情页标题栏副标题（随 selected 生成；无选中时省略）。 */
  static detailSubtitle(): string | undefined {
    const e = BenchHistoryStore.selected;
    return e === undefined ? undefined : `${BenchHistoryStore.formatTime(e.savedAt)} · 用时 ${e.elapsedSec}s`;
  }
}
