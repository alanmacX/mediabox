/**
 * QueueObserver — TaskQueue 监听的统一封装。
 * 页面只需要提供一个刷新回调；订阅/退订生命周期由使用方管理。
 */
import { TaskQueueListener } from '../../core/task/MediaTask';

export class QueueObserver implements TaskQueueListener {
  private callback: () => void;

  constructor(callback: () => void) {
    this.callback = callback;
  }

  onQueueChanged(): void {
    this.callback();
  }
}
