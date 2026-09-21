import { MediaTask } from './MediaTask';

/** Pure projection used by the task UI. Queue state remains owned by TaskQueue. */
export interface TaskDayGroup {
  key: string;
  label: string;
  isToday: boolean;
  tasks: MediaTask[];
}

export function taskDayKey(ts: number): string {
  const d = new Date(ts);
  return `${d.getFullYear()}-${d.getMonth() + 1}-${d.getDate()}`;
}

export function taskDayLabel(ts: number, now: number = Date.now()): string {
  const d = new Date(ts);
  const today = new Date(now);
  const todayKey = taskDayKey(now);
  const yesterdayKey = taskDayKey(new Date(today.getTime() - 86400000).getTime());
  const key = taskDayKey(ts);
  if (key === todayKey) {
    return '今天';
  }
  if (key === yesterdayKey) {
    return '昨天';
  }
  return `${d.getMonth() + 1}月${d.getDate()}日`;
}

export function groupTasksByDay(tasks: MediaTask[], now: number = Date.now()): TaskDayGroup[] {
  const out: TaskDayGroup[] = [];
  const groups = new Map<string, TaskDayGroup>();
  const todayKey = taskDayKey(now);
  for (const task of tasks) {
    const key = taskDayKey(task.createdAt);
    let group = groups.get(key);
    if (group === undefined) {
      group = {
        key: key,
        label: taskDayLabel(task.createdAt, now),
        isToday: key === todayKey,
        tasks: []
      };
      groups.set(key, group);
      out.push(group);
    }
    group.tasks.push(task);
  }
  return out;
}

/**
 * The day component owns a nested ForEach. Its key must change when membership
 * changes, otherwise ArkUI reuses the entire day subtree and never diffs the
 * nested list. Task field changes intentionally do not affect this key: those
 * flow through the stable @Observed/@ObjectLink objects.
 */
export function taskDayRenderKey(group: TaskDayGroup): string {
  let key = group.key;
  for (const task of group.tasks) {
    key += `|${task.id}`;
  }
  return key;
}
