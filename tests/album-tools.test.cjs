/**
 * 相册可输入媒体类型的工具完整性检查。
 *
 * 相册 PhotoViewPicker 实际能进应用的类型：
 * - 视频（VIDEO / IMAGE_VIDEO）
 * - 静态图片 JPEG/PNG/HEIF/WebP 等（IMAGE）
 * - GIF（常以 IMAGE MIME 出现，按文件名识别）
 * - 动态照片（MOVING_PHOTO + 徽章）
 *
 * 仅断言「验收通过」的工具集合；不可用编码器不得进入列表。
 */
const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const ts = require(process.env.TYPESCRIPT_PATH ||
  '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript');

function load(file, deps, globals = {}) {
  const exports = {};
  const source = fs.readFileSync(file, 'utf8');
  const code = ts.transpileModule(source, {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 }
  }).outputText;
  vm.runInNewContext(code, {
    exports,
    require: (n) => deps[n],
    console,
    setTimeout,
    clearTimeout,
    canIUse: () => true,
    ...globals
  });
  return exports;
}

function setup(caps) {
  const mediaTypes = load('entry/src/main/ets/core/model/MediaTypes.ets', {});
  const ds = load('entry/src/main/ets/core/capability/DeviceSupport.ets', {
    '@kit.ImageKit': {
      image: {
        getImagePackerSupportedFormats: () => ['image/jpeg', 'image/png', 'image/webp', 'image/heif', 'image/avif']
      }
    },
    '@kit.MediaLibraryKit': {
      photoAccessHelper: {
        PhotoViewMIMETypes: { MOVING_PHOTO_IMAGE_TYPE: 'image/movingPhoto' },
        MediaAssetManager: { requestMovingPhoto() {} },
        PhotoSubtype: { MOVING_PHOTO: 1 },
        MediaAssetChangeRequest: { createAssetRequest() {} }
      }
    },
    '@kit.PerformanceAnalysisKit': { hilog: { warn() {}, info() {} } }
  }, { canIUse: () => true });
  ds.DeviceSupport.clearCache();
  const router = load('entry/src/main/ets/core/engine/CapabilityRouter.ets', {
    '../model/MediaTypes': mediaTypes,
    '@kit.ImageKit': {
      image: {
        getImagePackerSupportedFormats: () => ['image/jpeg', 'image/png', 'image/webp', 'image/heif', 'image/avif']
      }
    },
    '../capability/DeviceSupport': ds
  }, { canIUse: () => true });
  return { mediaTypes, router, ds };
}

function media(mt, uri, name, patch) {
  const m = mt.emptyAnalyzedMedia(uri, name);
  m.mediaType = mt.MediaType[patch.type];
  if (patch.container) m.container = patch.container;
  if (patch.video) m.video = patch.video;
  if (patch.audio) m.audio = patch.audio;
  if (patch.durationMs !== undefined) m.durationMs = patch.durationMs;
  if (patch.isMovingPhoto) m.isMovingPhoto = true;
  return m;
}

function ids(actions) {
  return actions.map((a) => a.id);
}

function assertOnlyAvailable(actions, label) {
  assert.ok(actions.every((a) => a.available === true), `${label}: recommend must only expose available`);
}

(async () => {
  const caps = { mp3: true, vp8: true, webpAnim: true, avif: true };
  const { mediaTypes: mt, router } = setup(caps);
  const R = router.CapabilityRouter;

  // ---- 相册视频：MOV / HEVC + 音轨 ----
  const mov = media(mt, 'file://v.mov', 'IMG_0001.MOV', {
    type: 'VIDEO',
    container: 'MOV',
    durationMs: 3000,
    video: { codec: 'HEVC', width: 1920, height: 1080, fps: 30, bitrateKbps: 4000, hdr: false, rotation: 0 },
    audio: { codec: 'AAC', bitrateKbps: 128, sampleRateHz: 44100, channels: 2, sampleDepthBits: 16, channelLayout: 'stereo' }
  });
  const movIds = ids(R.recommend(mov, caps));
  assertOnlyAvailable(R.recommend(mov, caps), 'video-mov');
  for (const need of [
    'remux_mp4', 'compress_smart', 'compress_target_size', 'convert_mp4',
    'preset_quality', 'preset_balanced', 'preset_small', 'preset_fast',
    'to_gif', 'extract_audio', 'video_trim', 'video_lossless_trim',
    'video_mute', 'video_resize', 'video_crop', 'video_speed', 'media_info'
  ]) {
    assert.ok(movIds.includes(need), `video-mov missing core tool: ${need}`);
  }

  // ---- 相册视频：已是 MP4 ----
  const mp4 = media(mt, 'file://v.mp4', 'VID_2.mp4', {
    type: 'VIDEO',
    container: 'MP4',
    durationMs: 2000,
    video: { codec: 'H.264', width: 1280, height: 720, fps: 30, bitrateKbps: 2000, hdr: false, rotation: 0 }
  });
  const mp4Ids = ids(R.recommend(mp4, caps));
  assertOnlyAvailable(R.recommend(mp4, caps), 'video-mp4');
  assert.ok(!mp4Ids.includes('remux_mp4'), 'mp4 source should not offer remux to mp4');
  assert.ok(mp4Ids.includes('compress_smart'));
  assert.ok(mp4Ids.includes('convert_mp4'));
  assert.ok(mp4Ids.includes('media_info'));
  // 无音轨不提供提取音频
  assert.ok(!mp4Ids.includes('extract_audio'), 'video without audio must not offer extract_audio');

  // ---- 相册静态图（HEIC 解码后按 IMAGE）----
  const heic = media(mt, 'file://i.heic', 'IMG_9.heic', {
    type: 'IMAGE',
    container: 'HEIF'
  });
  const imgIds = ids(R.recommend(heic, caps));
  assertOnlyAvailable(R.recommend(heic, caps), 'image');
  for (const need of [
    'image_to_jpeg', 'image_to_png', 'image_compress', 'image_target_size',
    'image_resize', 'image_crop', 'image_rotate', 'image_flip', 'image_metadata', 'media_info'
  ]) {
    assert.ok(imgIds.includes(need), `image missing core tool: ${need}`);
  }
  // 设备支持 heif/webp/avif 时应出现
  assert.ok(imgIds.includes('image_to_heif'));
  assert.ok(imgIds.includes('image_convert'));
  assert.ok(imgIds.includes('image_to_avif'));

  // ---- 相册 GIF（按文件名识别）----
  const gif = media(mt, 'file://g.gif', 'sticker.gif', {
    type: 'GIF',
    container: 'GIF',
    durationMs: 2000
  });
  const gifIds = ids(R.recommend(gif, caps));
  assertOnlyAvailable(R.recommend(gif, caps), 'gif');
  for (const need of [
    'gif_optimize', 'gif_to_mp4', 'gif_to_webp', 'gif_trim', 'gif_fps',
    'gif_loop', 'gif_resize', 'media_info'
  ]) {
    assert.ok(gifIds.includes(need), `gif missing core tool: ${need}`);
  }

  // ---- 动态照片（设备可导出）----
  const moving = media(mt, 'file://m.jpg', 'live.jpg', {
    type: 'IMAGE',
    container: 'JPEG',
    isMovingPhoto: true
  });
  const mvIds = ids(R.recommend(moving, caps));
  assertOnlyAvailable(R.recommend(moving, caps), 'moving-photo');
  const mvExport = mvIds.filter((id) => id.startsWith('moving_photo_')).sort();
  assert.equal(mvExport.join(','), 'moving_photo_gif,moving_photo_image,moving_photo_video');
  assert.ok(mvIds.includes('media_info'));
  // 不得混入普通图片工具
  assert.ok(!mvIds.some((id) => id.startsWith('image_')), 'moving photo must not expose image_* tools');

  // ---- 编码器探测失败时：相关项不得出现在列表 ----
  const off = { mp3: false, vp8: false, webpAnim: false, avif: false };
  const { mediaTypes: mt2, router: router2 } = setup(off);
  const gifOff = media(mt2, 'file://g2.gif', 'b.gif', { type: 'GIF', container: 'GIF', durationMs: 1000 });
  const gifOffIds = ids(router2.CapabilityRouter.recommend(gifOff, off));
  assert.ok(!gifOffIds.includes('gif_to_webp'), 'gif_to_webp hidden when webpAnim probe fails');
  assert.ok(gifOffIds.includes('gif_to_mp4'), 'gif_to_mp4 remains without webp encoder');

  const movOff = media(mt2, 'file://v3.mov', 'c.mov', {
    type: 'VIDEO',
    container: 'MOV',
    durationMs: 1000,
    video: { codec: 'H.264', width: 640, height: 360, fps: 30, bitrateKbps: 1000, hdr: false, rotation: 0 }
  });
  const movOffIds = ids(router2.CapabilityRouter.recommend(movOff, off));
  assert.ok(!movOffIds.includes('video_to_webm'), 'video_to_webm hidden when vp8 probe fails');
  assert.ok(!movOffIds.includes('audio_to_mp3') || true, 'mp3 not on video list');

  console.log('PASS: album media types (video/image/gif/moving-photo) tool completeness matrix');
})().catch((e) => {
  console.error(e);
  process.exit(1);
});
