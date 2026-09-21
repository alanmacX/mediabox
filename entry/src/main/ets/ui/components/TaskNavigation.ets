/** 将处理任务统一带到根“任务”Tab，避免二级 NavDestination 保留过期任务卡快照。 */
export class TaskNavigation {
  static showRootQueue(): void {
    const version = AppStorage.get<number>('openRootTasksVersion') ?? 0;
    AppStorage.setOrCreate<number>('openRootTasksVersion', version + 1);
  }
}
