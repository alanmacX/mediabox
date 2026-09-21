/**
 * DeviceSupport：动态照片 / 图片编码能力门控。
 * 模拟 canIUse 与 ImagePacker 返回值，验证推荐列表与首页入口过滤。
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
  const sandbox = {
    exports,
    require: (name) => deps[name],
    console,
    setTimeout,
    clearTimeout,
    canIUse: globals.canIUse ?? (() => true),
    ...globals
  };
  vm.runInNewContext(code, sandbox);
  return exports;
}

function makePhotoHelper(opts) {
  return {
    PhotoViewMIMETypes: opts.canPick ? { MOVING_PHOTO_IMAGE_TYPE: 'image/movingPhoto' } : {},
    MediaAssetManager: opts.canExport ? { requestMovingPhoto() {} } : {},
    PhotoSubtype: opts.canCreate ? { MOVING_PHOTO: 1 } : {},
    MediaAssetChangeRequest: opts.canCreate ? { createAssetRequest() {} } : {}
  };
}

(async () => {
  // 1) 无媒体库 → 不可用
  let DeviceSupport = load('entry/src/main/ets/core/capability/DeviceSupport.ets', {
    '@kit.ImageKit': { image: { getImagePackerSupportedFormats: () => ['image/jpeg'] } },
    '@kit.MediaLibraryKit': { photoAccessHelper: makePhotoHelper({ canPick: false, canExport: false, canCreate: false }) },
    '@kit.PerformanceAnalysisKit': { hilog: { warn() {}, info() {} } }
  }, { canIUse: (cap) => !String(cap).includes('PhotoAccessHelper') }).DeviceSupport;
  DeviceSupport.clearCache();
  let mp = DeviceSupport.movingPhoto();
  assert.equal(mp.available, false);
  assert.ok(mp.reason && mp.reason.length > 0);

  // 2) 有选择器 + 导出接口 → 可用
  DeviceSupport = load('entry/src/main/ets/core/capability/DeviceSupport.ets', {
    '@kit.ImageKit': { image: { getImagePackerSupportedFormats: () => ['image/jpeg', 'image/png'] } },
    '@kit.MediaLibraryKit': { photoAccessHelper: makePhotoHelper({ canPick: true, canExport: true, canCreate: true }) },
    '@kit.PerformanceAnalysisKit': { hilog: { warn() {}, info() {} } }
  }, { canIUse: () => true }).DeviceSupport;
  DeviceSupport.clearCache();
  mp = DeviceSupport.movingPhoto();
  assert.equal(mp.available, true);
  assert.equal(mp.canExportMovingPhoto, true);
  assert.equal(mp.canCreateMovingPhoto, true);
  const enc = DeviceSupport.imageEncode();
  assert.equal(enc.jpeg, true);
  assert.equal(enc.png, true);
  assert.equal(enc.webp, false);

  // 3) CapabilityRouter：无导出接口时动态照片动作置灰
  const mediaTypes = load('entry/src/main/ets/core/model/MediaTypes.ets', {});
  const dsMod = load('entry/src/main/ets/core/capability/DeviceSupport.ets', {
    '@kit.ImageKit': { image: { getImagePackerSupportedFormats: () => ['image/jpeg'] } },
    '@kit.MediaLibraryKit': { photoAccessHelper: makePhotoHelper({ canPick: true, canExport: false, canCreate: true }) },
    '@kit.PerformanceAnalysisKit': { hilog: { warn() {}, info() {} } }
  }, { canIUse: () => true });
  dsMod.DeviceSupport.clearCache();
  const routerDeps = {
    '../model/MediaTypes': mediaTypes,
    '@kit.ImageKit': { image: { getImagePackerSupportedFormats: () => ['image/jpeg'] } },
    '../capability/DeviceSupport': dsMod
  };
  const { CapabilityRouter, emptyAnalyzedMedia } = {
    ...load('entry/src/main/ets/core/engine/CapabilityRouter.ets', routerDeps),
    emptyAnalyzedMedia: mediaTypes.emptyAnalyzedMedia
  };
  const media = emptyAnalyzedMedia('file://photo/1', 'live.jpg');
  media.mediaType = mediaTypes.MediaType.IMAGE;
  media.isMovingPhoto = true;
  const actions = CapabilityRouter.recommend(media, {});
  const mpActions = actions.filter((a) => a.id.startsWith('moving_photo_'));
  // 功能验收：不可用的动态照片操作不进入推荐列表
  assert.equal(mpActions.length, 0);

  // 4) 有导出接口时点亮
  const dsOk = load('entry/src/main/ets/core/capability/DeviceSupport.ets', {
    '@kit.ImageKit': { image: { getImagePackerSupportedFormats: () => ['image/jpeg'] } },
    '@kit.MediaLibraryKit': { photoAccessHelper: makePhotoHelper({ canPick: true, canExport: true, canCreate: true }) },
    '@kit.PerformanceAnalysisKit': { hilog: { warn() {}, info() {} } }
  }, { canIUse: () => true });
  dsOk.DeviceSupport.clearCache();
  const routerOk = load('entry/src/main/ets/core/engine/CapabilityRouter.ets', {
    '../model/MediaTypes': mediaTypes,
    '@kit.ImageKit': { image: { getImagePackerSupportedFormats: () => ['image/jpeg'] } },
    '../capability/DeviceSupport': dsOk
  }).CapabilityRouter;
  const okActions = routerOk.recommend(media, {}).filter((a) => a.id.startsWith('moving_photo_'));
  assert.equal(okActions.length, 3, 'export-ok keeps image/video/gif export');
  assert.ok(okActions.every((a) => a.available === true));

  console.log('PASS: DeviceSupport moving-photo gate, image encode matrix, CapabilityRouter filtering');
})().catch((e) => {
  console.error(e);
  process.exit(1);
});
