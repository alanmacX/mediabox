import { liveViewManager } from '@kit.LiveViewKit';
import { wantAgent, WantAgent } from '@kit.AbilityKit';

interface LiveViewTexts {
  pct: number;
  capMain: string;
  capSub: string;
  sub: string;
}

const STAGES: Record<string, LiveViewTexts> = {
  '0': { pct: 0, capMain: '处理中', capSub: '转码', sub: '正在准备 · HEVC 1080p' },
  '45': { pct: 45, capMain: '45%', capSub: '转码中', sub: '已处理 45% · 预计剩余 3 分钟' },
  '100': { pct: 100, capMain: '完成', capSub: '已保存', sub: '已完成 · 已保存到导出目录' },
};

@Entry
@Component
struct Index {
  @State status: string = '就绪 · 实况窗 id=1001';
  private agent: WantAgent | undefined = undefined;

  aboutToAppear(): void {
    const info: wantAgent.WantAgentInfo = {
      wants: [{ bundleName: 'com.mediabox.app', abilityName: 'EntryAbility' }],
      operationType: wantAgent.OperationType.START_ABILITY,
      requestCode: 0,
      wantAgentFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG],
    };
    wantAgent.getWantAgent(info).then((agent) => {
      this.agent = agent;
    });
  }

  private mk(t: LiveViewTexts): liveViewManager.LiveView {
    return {
      id: 1001,
      event: 'PROGRESS',
      isMute: true,
      liveViewData: {
        primary: {
          title: '正在转码 summer_trip.mp4',
          content: [{ text: t.sub }],
          clickAction: this.agent,
          layoutData: {
            layoutType: liveViewManager.LayoutType.LAYOUT_TYPE_PROGRESS,
            progress: t.pct,
            nodeIcons: ['node1.png', 'node2.png', 'node3.png'],
          },
        },
        capsule: {
          type: liveViewManager.CapsuleType.CAPSULE_TYPE_TEXT,
          status: 1,
          icon: 'node1.png',
          title: t.capMain,
          content: t.capSub,
          backgroundColor: '#FF0A0A0A',
        },
      },
    };
  }

  private async toStage(key: string): Promise<void> {
    const t = STAGES[key];
    try {
      const r = await liveViewManager.startLiveView(this.mk(t));
      this.status = `startLiveView(${key}%) = ${r.resultCode}`;
    } catch (e1) {
      const err1 = e1 as BusinessError;
      try {
        await liveViewManager.updateLiveView(this.mk(t));
        this.status = `updateLiveView(${key}%) = ok`;
      } catch (e2) {
        const err2 = e2 as BusinessError;
        this.status = `失败: start=${err1.code} update=${err2.code}`;
      }
    }
    console.info('LiveViewDemo: ' + this.status);
  }

  private async stop(): Promise<void> {
    try {
      await liveViewManager.stopLiveView(this.mk(STAGES['100']));
      this.status = 'stopLiveView = ok（实况窗已结束）';
    } catch (e) {
      const err = e as BusinessError;
      this.status = `stop 失败: code=${err.code}`;
    }
    console.info('LiveViewDemo: ' + this.status);
  }

  build() {
    Column({ space: 18 }) {
      Text('MediaBox 实况窗录制台')
        .fontSize(22).fontWeight(FontWeight.Bold).fontColor('#EAEFF5')
      Text('按顺序点按钮触发 stage，在状态栏/通知中心/锁屏录制素材')
        .fontSize(12).fontColor('#9AA6B5')

      Button('① 开始任务 · 0%')
        .width('86%').height(52).fontSize(17)
        .backgroundColor('#E8FFB84D').fontColor('#FFB84D')
        .onClick(() => this.toStage('0'))
      Button('② 处理中 · 45%')
        .width('86%').height(52).fontSize(17)
        .backgroundColor('#E8317AF7').fontColor('#7FB0FA')
        .onClick(() => this.toStage('45'))
      Button('③ 已完成 · 100%')
        .width('86%').height(52).fontSize(17)
        .backgroundColor('#E83BC96E').fontColor('#7BE3A8')
        .onClick(() => this.toStage('100'))
      Button('④ 结束实况窗 stopLiveView')
        .width('86%').height(52).fontSize(17)
        .backgroundColor('#E8FF7A8A').fontColor('#FF9AA8')
        .onClick(() => this.stop())

      Text(this.status)
        .fontSize(12).fontColor('#9AA6B5')
        .maxLines(2)
    }
    .width('100%').height('100%')
    .justifyContent(FlexAlign.Center)
    .backgroundColor('#10141B')
  }
}
