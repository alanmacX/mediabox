# MediaBox FFmpeg source and relink kit

This archive accompanies MediaBox 1.0.0 for HarmonyOS arm64. It contains the exact
source revisions and third-party source archives used to build the FFmpeg-based
`libffmpegutils.so` in the app, plus the wrapper source and build recipe. The
OHOS H.264 adapter is built from source; no opaque H.264 object files are used.

To rebuild, install DevEco Studio's HarmonyOS Native SDK and `pkgconf`, obtain
the MediaBox project with `@ohos/aki` 1.2.24 installed (`ohpm install`), then run
from this extracted directory:

```sh
APP_ROOT=/absolute/path/to/mediabox \
SOURCE_KIT_DIR="$PWD" \
WORK="$(mktemp -d)" \
PACKAGE_OUTPUT=/absolute/path/to/rebuilt-ffmpeg-tools.har \
bash rebuild_ffmpeg_encoders.sh
```

The script uses the included source archives. It verifies SHA-256 hashes of
third-party archives, checks that GPL and postproc are disabled, and checks the
linked FFmpeg license string before packaging. It will not need to download
codec source when run with `SOURCE_KIT_DIR`; the packaging step fetches the
original `@prq/ffmpeg-tools` 2.2.6 HAR to retain its ArkTS packaging metadata,
then replaces its native FFmpeg library. That HAR is not included in this source
kit. `@ohos/aki` is an independent dependency of the MediaBox project.

The new `.har` contains a replacement `libffmpegutils.so`. A modified library
can be packaged with the project and signed with your own HarmonyOS development
identity. See `LICENSE_AUDIT.md` for remaining legal review notes. `SHA256SUMS`
identifies the archived inputs; `REFERENCE_BINARY_SHA256.txt` identifies the
published reference library.
