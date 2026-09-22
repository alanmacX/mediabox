const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { execFileSync } = require('node:child_process');

const root = path.resolve(__dirname, '..');
const archive = path.join(root, 'vendor/ffmpeg-tools-lgpl3-2.2.6.har');

test('the pinned FFmpeg package uses a non-GPL build with required encoders', () => {
  const dependency = fs.readFileSync(path.join(root, 'entry/oh-package.json5'), 'utf8');
  assert.match(dependency, /file:\.\.\/vendor\/ffmpeg-tools-lgpl3-2\.2\.6\.har/);
  assert.ok(fs.existsSync(archive), 'the local package must be present');

  const native = execFileSync('tar', [
    '-xOzf', archive, 'package/libs/arm64-v8a/libffmpegutils.so'
  ], { maxBuffer: 64 * 1024 * 1024 });
  const binary = native.toString('latin1');
  assert.match(binary, /libavcodec license: LGPL version 3 or later/);
  assert.doesNotMatch(binary, /--enable-gpl/);
  for (const encoder of ['--enable-libmp3lame', '--enable-libvpx', '--enable-libwebp', '--enable-libaom']) {
    assert.ok(binary.includes(encoder), `${encoder} missing from packaged binary`);
  }
  assert.match(binary, /ff_h264_ohosavcodec_encoder/);
  assert.match(binary, /ff_h264_ohosavcodec_decoder/);
});
