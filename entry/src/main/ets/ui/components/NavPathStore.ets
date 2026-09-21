/**
 * 模块级 NavPathStack，避免 @Provide 字段在 render 周期被重建/赋值。
 */
export class NavPathStore {
  private static _stack: NavPathStack | undefined = undefined;

  static stack(): NavPathStack {
    if (NavPathStore._stack === undefined) {
      NavPathStore._stack = new NavPathStack();
    }
    return NavPathStore._stack;
  }
}
