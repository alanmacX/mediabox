/**
 * 媒体信息页 — Analyzer 输出的完整技术参数(项目简报 §3)。
 * Container / Video / Audio / Metadata 分组键值对呈现。
 */
import { AnalyzedMedia, Fmt, MediaType } from '../core/model/MediaTypes';
import { WorkbenchSession } from '../ui/components/WorkbenchSession';
import { Adaptive } from '../ui/adaptive/AdaptiveKit';
import { Dt } from '../ui/theme/DesignTokens';

interface InfoRow {
  k: string;
  v: string;
}

interface InfoGroup {
  title: string;
  rows: InfoRow[];
}

@Component
export struct MediaInfoPage {
  @StorageProp('windowWidthVp') windowWidthVp: number = 390;
  @StorageProp('isLandscape') isLandscape: boolean = false;
  @State media: AnalyzedMedia | undefined = WorkbenchSession.result?.media;
  @State showRaw: boolean = false;

  private groups(): InfoGroup[] {
    const m = this.media;
    if (m === undefined) {
      return [];
    }
    const groups: InfoGroup[] = [];
    const general: InfoRow[] = [
      { k: '文件名', v: m.displayName },
      { k: '类型', v: m.mediaType === MediaType.IMAGE ? '图片' : (m.mediaType === MediaType.GIF ? 'GIF 动画' :
        (m.mediaType === MediaType.VIDEO ? '视频' : (m.mediaType === MediaType.AUDIO ? '音频' : '字幕或其他'))) },
      { k: '扩展名封装', v: m.container || '未知' },
      { k: '检测 MIME', v: m.mimeType || 'SDK 未返回' },
      { k: '动态照片', v: m.isMovingPhoto ? '是' : '否' }
    ];
    if (m.sizeBytes > 0) {
      general.push({ k: '大小', v: `${Fmt.bytes(m.sizeBytes)}（${m.sizeBytes} 字节）` });
    }
    if (m.durationMs > 0) {
      general.push({ k: '时长', v: `${Fmt.duration(m.durationMs)}（${m.durationMs} ms）` });
    }
    groups.push({ title: '概览', rows: general });

    if (m.video !== undefined) {
      const rows: InfoRow[] = [
        { k: '编码', v: m.video.codec },
        { k: '分辨率', v: `${m.video.width} × ${m.video.height}` }
      ];
      if (m.video.fps > 0) {
        rows.push({ k: '帧率', v: `${m.video.fps} FPS` });
      }
      if (m.video.bitrateKbps > 0) {
        rows.push({ k: '码率', v: Fmt.kbps(m.video.bitrateKbps) });
      }
      rows.push({ k: 'HDR', v: m.video.hdrKnown === false ? 'SDK 未返回' : (m.video.hdr ? '是' : '否') });
      if (m.video.rotation !== 0) {
        rows.push({ k: '旋转', v: `${m.video.rotation}°` });
      }
      groups.push({ title: '视频轨', rows: rows });
    }
    if (m.imageWidth > 0) {
      const imageRows: InfoRow[] = [
        { k: '尺寸', v: `${m.imageWidth} × ${m.imageHeight}` },
        { k: '像素', v: `${(m.imageWidth * m.imageHeight / 1000000).toFixed(1)} MP` }
      ];
      if (m.imageBitsPerSample.length > 0) imageRows.push({ k: '每通道位数', v: m.imageBitsPerSample });
      if (m.imageOrientation.length > 0) imageRows.push({ k: '方向', v: m.imageOrientation });
      if (m.imageDateTaken.length > 0) imageRows.push({ k: '拍摄时间', v: m.imageDateTaken });
      if (m.imageExposure.length > 0) imageRows.push({ k: '曝光时间', v: m.imageExposure });
      if (m.imageIso.length > 0) imageRows.push({ k: 'ISO', v: m.imageIso });
      if (m.imageFNumber.length > 0) imageRows.push({ k: '光圈', v: m.imageFNumber });
      if (m.imageGps.length > 0) imageRows.push({ k: 'GPS', v: m.imageGps });
      if (m.imageFrameCount > 0) imageRows.push({ k: '帧数', v: `${m.imageFrameCount}` });
      imageRows.push({ k: 'HDR', v: m.imageHdr ? '是' : '否' });

      groups.push({ title: '图像', rows: imageRows });
      if (m.imageDetails) {
        const cameraRows = m.imageDetails.split('\n').map((value: string): InfoRow => {
          const separator = value.indexOf('：');
          return { k: value.substring(0, separator), v: value.substring(separator + 1) };
        });
        groups.push({ title: '相机与色彩', rows: cameraRows });
      }
    }
    if (m.audio !== undefined) {
      const rows: InfoRow[] = [];
      if (m.audio.codec.length > 0) {
        rows.push({ k: '编码', v: m.audio.codec });
      }
      if (m.audio.bitrateKbps > 0) {
        rows.push({ k: '码率', v: Fmt.kbps(m.audio.bitrateKbps) });
      }
      if (m.audio.sampleRateHz > 0) {
        rows.push({ k: '采样率', v: `${m.audio.sampleRateHz} Hz` });
      }
      if (m.audio.channels > 0) {
        rows.push({ k: '声道', v: m.audio.channelLayout.length > 0 ? m.audio.channelLayout : `${m.audio.channels}` });
      }
      if (m.audio.sampleDepthBits > 0) {
        rows.push({ k: '位深', v: `${m.audio.sampleDepthBits} bit` });
      }
      if (rows.length > 0) {
        groups.push({ title: '音频轨', rows: rows });
      }
    }
    if (m.streams.length > 0) {
      const rows: InfoRow[] = m.streams.map((stream): InfoRow => {
        const bitrate = stream.bitrateKbps > 0 ? Fmt.kbps(stream.bitrateKbps) : '';
        const detail = [stream.codec, bitrate, stream.language, stream.name]
          .filter((value: string) => value.length > 0).join(' · ');
        return { k: `${stream.kind} ${stream.index}`, v: detail.length > 0 ? detail : '未知编码' };
      });
      groups.push({ title: `媒体流（${m.streams.length} 条）`, rows: rows });
      for (const stream of m.streams) {
        const rows: InfoRow[] = [{ k: '编码', v: stream.codec || '未知' },
          { k: '语言', v: stream.language || 'SDK 未返回' }, { k: '轨道标题', v: stream.name || 'SDK 未返回' }];
        if ((stream.width ?? 0) > 0) rows.push({ k: '尺寸', v: `${stream.width} × ${stream.height}` });
        if ((stream.fps ?? 0) > 0) rows.push({ k: '帧率', v: `${stream.fps} FPS` });
        if (stream.bitrateKbps > 0) rows.push({ k: '码率', v: Fmt.kbps(stream.bitrateKbps) });
        if ((stream.sampleRateHz ?? 0) > 0) rows.push({ k: '采样率', v: `${stream.sampleRateHz} Hz` });
        if ((stream.channels ?? 0) > 0) rows.push({ k: '声道数', v: `${stream.channels}` });
        if ((stream.sampleDepthBits ?? 0) > 0) rows.push({ k: '位深', v: `${stream.sampleDepthBits} bit` });
        if (this.showRaw && stream.rawDetails) rows.push({ k: '全部字段', v: stream.rawDetails });
        groups.push({ title: `轨道 ${stream.index} · ${stream.kind}`, rows: rows });
      }
    }
    const meta: InfoRow[] = [];
    if (m.title.length > 0) {
      meta.push({ k: '标题', v: m.title });
    }
    if (m.artist.length > 0) {
      meta.push({ k: '艺术家', v: m.artist });
    }
    if (m.albumArtist.length > 0) {
      meta.push({ k: '专辑艺术家', v: m.albumArtist });
    }
    if (m.album.length > 0) {
      meta.push({ k: '专辑', v: m.album });
    }
    if (m.author.length > 0) {
      meta.push({ k: '作者', v: m.author });
    }
    if (m.composer.length > 0) {
      meta.push({ k: '作曲', v: m.composer });
    }
    if (m.genre.length > 0) {
      meta.push({ k: '流派', v: m.genre });
    }
    if (m.creationTime.length > 0) {
      meta.push({ k: '创建时间', v: m.creationTime });
    }
    if (meta.length > 0) {
      groups.push({ title: '元数据', rows: meta });
    }
    return groups;
  }

  @Builder
  Row2(r: InfoRow) {
    Row() {
      Text(r.k)
        .fontSize(Dt.fontBody)
        .fontColor($r('app.color.text_secondary'))
        .width(96)
      Text(r.v)
        .fontSize(Dt.fontBody)
        .fontColor($r('app.color.text_primary'))
        .layoutWeight(1)
        .copyOption(CopyOptions.LocalDevice)
    }
    .width('100%')
    .padding({ top: Dt.spaceSm, bottom: Dt.spaceSm })
  }

  build() {
    // 标题栏由 Index 的 HdsNavDestination 提供。
    Scroll() {
      Column({ space: Dt.spaceLg }) {
        if (this.media?.analysisNote) {
          Text(this.media?.analysisNote ?? '')
            .fontColor($r('app.color.danger_red'))
            .fontSize(Dt.fontCaption)
            .width('100%')
        }
        ForEach(this.groups(), (g: InfoGroup) => {
          this.InfoGroupCard(g)
        }, (g: InfoGroup) => g.title)
        Button(this.showRaw ? '收起原始技术字段' : '查看原始技术字段')
          .buttonStyle(ButtonStyleMode.NORMAL)
          .controlSize(ControlSize.SMALL)
          .onClick(() => this.showRaw = !this.showRaw)
        if (this.showRaw) {
          Text(this.media?.rawMetadata ?? 'SDK 未返回元数据')
            .fontSize(Dt.fontCaption)
            .copyOption(CopyOptions.LocalDevice)
            .width('100%')
        }
        Text('部分字段可能因格式或系统支持情况无法读取。')
          .fontSize(Dt.fontCaption)
          .fontColor($r('app.color.text_secondary'))
      }
      .width('100%')
      .padding({
        left: Dt.navContentInset,
        right: Adaptive.pagePadding(this.windowWidthVp),
        top: 96,
        bottom: Dt.spaceXxl
      })
    }
    .scrollBar(BarState.Off)
    .width('100%')
    .height('100%')
    .backgroundColor(Color.Transparent)
  }

  @Builder
  InfoGroupCard(g: InfoGroup) {
    Column() {
      Text(g.title)
        .fontSize(Dt.fontSub)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
        .width('100%')
        .margin({ bottom: Dt.spaceSm })
      Column() {
        ForEach(g.rows, (r: InfoRow) => {
          this.Row2(r)
        }, (r: InfoRow) => r.k)
      }
      .width('100%')
      .padding(Dt.spaceLg)
      .borderRadius(Dt.radiusLg)
      .backgroundColor($r('app.color.surface_card'))
      .border({ width: 0.5, color: $r('app.color.divider') })
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
  }
}
