#!/usr/bin/env bash
#
# prepare-models.sh
# ─────────────────────────────────────────────────────────────────────────────
# Tải model Kokoro int8 từ k2-fsa/sherpa-onnx releases, chuẩn hoá thành 5 file
# đúng cấu trúc mà module :tts-kokoro mong đợi, in size + SHA256 để bạn khai
# báo vào TtsConfig.
#
# Cách dùng:
#   ./prepare-models.sh                 # dùng bản mặc định (multi-lang int8 v1_1)
#   ./prepare-models.sh en              # bản English-only v0_19 (fp32, không int8)
#
# Yêu cầu: bash, curl, tar, bzip2, zip, shasum (có sẵn trên macOS).
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

VARIANT="${1:-multi}"

case "$VARIANT" in
    multi)
        ARCHIVE="kokoro-int8-multi-lang-v1_1"
        MODEL_ID="kokoro-int8-multi-lang-v1_1"
        LEXICON_NAME="lexicon-us-en.txt"
        ;;
    en)
        ARCHIVE="kokoro-en-v0_19"
        MODEL_ID="kokoro-en-v0_19"
        LEXICON_NAME=""   # bản này không có file lexicon riêng
        ;;
    *)
        echo "Usage: $0 [multi|en]" >&2
        exit 1
        ;;
esac

URL="https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/${ARCHIVE}.tar.bz2"
WORK_DIR="$(cd "$(dirname "$0")" && pwd)/build"
# OUT_DIR phải KHÁC tên với $ARCHIVE (folder tar extract ra) để tránh dẫm chân
OUT_DIR="$WORK_DIR/upload/$MODEL_ID"

echo "▶ Tải $ARCHIVE.tar.bz2 …"
mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

# Nếu cache < 10 MB thì chắc chắn hỏng (real archive ~100 MB)
if [[ -f "$ARCHIVE.tar.bz2" ]]; then
    SIZE=$(wc -c < "$ARCHIVE.tar.bz2")
    if (( SIZE < 10000000 )); then
        echo "  ⚠ File cache chỉ $SIZE bytes — chắc chắn hỏng, xoá và tải lại."
        rm -f "$ARCHIVE.tar.bz2"
    fi
fi

if [[ ! -f "$ARCHIVE.tar.bz2" ]]; then
    # -L để follow redirect GitHub → S3
    # -f để fail hard trên HTTP 4xx/5xx (không lưu HTML error page)
    curl -L --fail --progress-bar -o "$ARCHIVE.tar.bz2" "$URL" \
        || { echo "✗ Tải thất bại từ $URL" >&2; rm -f "$ARCHIVE.tar.bz2"; exit 1; }
fi

SIZE=$(wc -c < "$ARCHIVE.tar.bz2")
echo "  Kích thước: $(du -h "$ARCHIVE.tar.bz2" | awk '{print $1}') ($SIZE bytes)"
if (( SIZE < 10000000 )); then
    echo "✗ File nhỏ bất thường, có thể là HTML error page. Head 20 dòng:" >&2
    head -c 500 "$ARCHIVE.tar.bz2" >&2
    exit 1
fi

echo "▶ Liệt kê 15 entry đầu của archive để verify:"
tar tjf "$ARCHIVE.tar.bz2" 2>&1 | head -15 | sed 's/^/    /' || {
    echo "✗ Không đọc được nội dung archive — file có thể corrupt" >&2
    exit 1
}
echo

TOP_FOLDER=$(tar tjf "$ARCHIVE.tar.bz2" 2>/dev/null | head -1 | cut -d/ -f1)
echo "  Top-level folder trong archive: '$TOP_FOLDER'"

echo "▶ Giải nén (verbose) …"
rm -rf "$ARCHIVE" "$TOP_FOLDER"
# -v để in từng file, không nuốt stderr — thấy ngay nếu tar lỗi
if ! tar xjvf "$ARCHIVE.tar.bz2" 2>&1 | tail -20 | sed 's/^/    /'; then
    echo "✗ tar xjf trả exit code khác 0" >&2
    exit 1
fi

# Nếu tar dùng top-level folder khác với $ARCHIVE, đổi tên biến
if [[ -n "$TOP_FOLDER" && -d "$TOP_FOLDER" ]]; then
    ARCHIVE="$TOP_FOLDER"
fi

if [[ ! -d "$ARCHIVE" ]] || [[ -z "$(ls -A "$ARCHIVE" 2>/dev/null)" ]]; then
    echo "✗ Thư mục $ARCHIVE không tồn tại hoặc rỗng sau extract" >&2
    echo "  Debug — mọi thư mục trong $(pwd):" >&2
    ls -la >&2
    exit 1
fi

# ─── Sắp xếp file theo cấu trúc module mong đợi ─────────────────────────────
rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"

echo "▶ Nội dung archive giải nén được:"
ls -lh "$ARCHIVE" | sed 's/^/    /'
echo

# Tìm file model — bản int8 tên "model.int8.onnx", bản fp32 tên "model.onnx"
MODEL_SRC=""
for candidate in "model.int8.onnx" "model.onnx"; do
    if [[ -f "$ARCHIVE/$candidate" ]]; then
        MODEL_SRC="$ARCHIVE/$candidate"
        break
    fi
done

if [[ -z "$MODEL_SRC" ]]; then
    echo "✗ Không tìm thấy file model.onnx hoặc model.int8.onnx trong $ARCHIVE/" >&2
    echo "  Kiểm tra output 'ls' bên trên xem archive chứa gì." >&2
    exit 1
fi

echo "▶ Chuẩn hoá filename …"
echo "    $MODEL_SRC → model.onnx"
cp "$MODEL_SRC"           "$OUT_DIR/model.onnx"
cp "$ARCHIVE/voices.bin"  "$OUT_DIR/voices.bin"
cp "$ARCHIVE/tokens.txt"  "$OUT_DIR/tokens.txt"

# Auto-detect lexicon — có thể là lexicon-us-en.txt, lexicon.txt, hoặc không có
for candidate in "$LEXICON_NAME" "lexicon-us-en.txt" "lexicon.txt"; do
    [[ -z "$candidate" ]] && continue
    if [[ -f "$ARCHIVE/$candidate" ]]; then
        echo "    $ARCHIVE/$candidate → lexicon.txt"
        cp "$ARCHIVE/$candidate" "$OUT_DIR/lexicon.txt"
        break
    fi
done

if [[ -d "$ARCHIVE/espeak-ng-data" ]]; then
    echo "▶ Nén espeak-ng-data → espeak-ng-data.zip …"
    # Zip từ trong thư mục để tránh nested "espeak-ng-data/espeak-ng-data/…"
    (cd "$ARCHIVE/espeak-ng-data" && zip -qr "$OUT_DIR/espeak-ng-data.zip" .)
fi

# ─── In manifest ────────────────────────────────────────────────────────────
echo
echo "════════════════════════════════════════════════════════════════════"
echo "  ✅ Xong. File chuẩn bị tại: $OUT_DIR"
echo "════════════════════════════════════════════════════════════════════"
echo

printf "%-25s %12s   %s\n" "File" "Size" "SHA256"
printf "%-25s %12s   %s\n" "----" "----" "------"
for f in "$OUT_DIR"/*; do
    name=$(basename "$f")
    size=$(du -h "$f" | awk '{print $1}')
    sha=$(shasum -a 256 "$f" | awk '{print substr($1,1,16) "…"}')
    printf "%-25s %12s   %s\n" "$name" "$size" "$sha"
done

echo
echo "────────────────────────────────────────────────────────────────────"
echo "  BƯỚC TIẾP: upload 5 file trên lên CDN / Firebase / S3, ví dụ"
echo "  https://cdn.example.com/$MODEL_ID/model.onnx  …"
echo
echo "  Sau đó cập nhật TtsConfig trong app:"
echo "────────────────────────────────────────────────────────────────────"
cat <<EOF

val config = TtsConfig(
    modelId = "$MODEL_ID",
    files = ModelFiles(
        modelUrl       = "https://cdn.example.com/$MODEL_ID/model.onnx",
        voicesUrl      = "https://cdn.example.com/$MODEL_ID/voices.bin",
        tokensUrl      = "https://cdn.example.com/$MODEL_ID/tokens.txt",
        lexiconUrl     = "https://cdn.example.com/$MODEL_ID/lexicon.txt",
        espeakDataUrl  = "https://cdn.example.com/$MODEL_ID/espeak-ng-data.zip",
        modelSizeBytes = $(wc -c < "$OUT_DIR/model.onnx"),
        voicesSizeBytes = $(wc -c < "$OUT_DIR/voices.bin"),
    ),
)

EOF
