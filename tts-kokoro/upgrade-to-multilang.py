#!/usr/bin/env python3
"""
Nâng cấp bộ model Kokoro TTS từ v1.0 (English-only) lên
kokoro-multi-lang-v1_1 (English + Chinese, 103 voices).

Chạy (từ thư mục scripts/ModelAi/tts-kokoro/):
    python3 upgrade-to-multilang.py

File output sẽ được ghi thẳng vào thư mục hiện tại — không tạo folder con.

Script sẽ:
  1. Tải bundle kokoro-multi-lang-v1_1.tar.bz2 từ sherpa-onnx GitHub release.
  2. Giải nén tạm ra /tmp.
  3. Zip lại thư mục espeak-ng-data/ thành espeak-ng-data.zip.
  4. Ghi 6 file cần thiết vào thư mục hiện tại với đúng tên đang dùng trong repo.
  5. In gợi ý các bước tiếp theo (git add, config app).

File output (khớp với repo tuanhoang95/ModelAi/tts-kokoro/):
    model.onnx           (~330 MB - multi-lang v1.1)
    voices.bin           (~103 MB - 103 speakers, gồm 8 voice Chinese)
    tokens.txt
    lexicon-us-en.txt    (tiếng Anh - Mỹ)
    lexicon-zh.txt       (tiếng Trung)
    espeak-ng-data.zip   (~9 MB - phoneme data đa ngôn ngữ)
"""

from __future__ import annotations

import argparse
import shutil
import sys
import tarfile
import tempfile
import urllib.request
import zipfile
from pathlib import Path

BUNDLE_URL = (
    "https://github.com/k2-fsa/sherpa-onnx/releases/download/"
    "tts-models/kokoro-multi-lang-v1_1.tar.bz2"
)
BUNDLE_NAME = "kokoro-multi-lang-v1_1"

FILES_TO_COPY = [
    "model.onnx",
    "voices.bin",
    "tokens.txt",
    "lexicon-us-en.txt",
    "lexicon-zh.txt",
]


def parse_args() -> argparse.Namespace:

    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--out",
        type=Path,
        default=Path(__file__).resolve().parent,
        help="Thư mục xuất file (mặc định: cùng thư mục với script)",
    )
    parser.add_argument(
        "--keep-work",
        action="store_true",
        help="Giữ thư mục làm việc để debug (mặc định xoá sau khi xong)",
    )
    return parser.parse_args()


def download_bundle(dest: Path) -> None:

    if dest.exists():

        print(f"[skip] Bundle đã có: {dest} ({dest.stat().st_size / 1024 / 1024:.1f} MB)")
        return

    print(f"[1/4] Tải bundle từ {BUNDLE_URL}")
    print("      (~380 MB, có thể mất vài phút…)")
    dest.parent.mkdir(parents=True, exist_ok=True)

    with urllib.request.urlopen(BUNDLE_URL) as response, dest.open("wb") as out:

        total = int(response.headers.get("Content-Length", 0))
        copied = 0
        while chunk := response.read(1024 * 1024):

            out.write(chunk)
            copied += len(chunk)
            if total > 0:

                percent = copied * 100 / total
                print(f"\r      {percent:5.1f}%  ({copied / 1024 / 1024:.1f} / {total / 1024 / 1024:.1f} MB)", end="")

    print("\n      Done.")


def extract_bundle(archive: Path, work_dir: Path) -> Path:

    print(f"[2/4] Giải nén {archive.name}")
    work_dir.mkdir(parents=True, exist_ok=True)
    with tarfile.open(archive, "r:bz2") as tar:

        tar.extractall(work_dir)

    extracted = work_dir / BUNDLE_NAME
    if not extracted.is_dir():

        sys.exit(f"[error] Không tìm thấy thư mục {BUNDLE_NAME}/ sau khi giải nén.")
    return extracted


def zip_espeak_data(bundle_dir: Path, out_dir: Path) -> None:

    espeak_dir = bundle_dir / "espeak-ng-data"
    if not espeak_dir.is_dir():

        sys.exit(f"[error] Không có {espeak_dir} trong bundle.")

    zip_path = out_dir / "espeak-ng-data.zip"
    print(f"[3/4] Nén espeak-ng-data/ → {zip_path.name}")

    with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED) as zf:

        for path in espeak_dir.rglob("*"):

            if path.is_file():

                zf.write(path, path.relative_to(bundle_dir))


def copy_files(bundle_dir: Path, out_dir: Path) -> None:

    print(f"[4/4] Copy {len(FILES_TO_COPY)} file → {out_dir}/")
    missing = []
    for name in FILES_TO_COPY:

        src = bundle_dir / name
        if not src.exists():

            missing.append(name)
            continue
        shutil.copy2(src, out_dir / name)
        print(f"      ✓ {name}  ({src.stat().st_size / 1024 / 1024:.2f} MB)")

    if missing:

        sys.exit(f"[error] Thiếu file trong bundle: {missing}")


def print_summary(out_dir: Path) -> None:

    print()
    print("=" * 60)
    print(f"Xong — 6 file đã được ghi vào: {out_dir}")
    print("=" * 60)
    print()
    print("Bước tiếp theo:")
    print()
    print("1. Commit + push lên repo ModelAi (đã có sẵn git-lfs track):")
    print("     cd /path/to/ModelAi")
    print("     git add tts-kokoro/")
    print("     git commit -m 'Upgrade Kokoro to multi-lang v1.1 (EN + ZH)'")
    print("     git push")
    print()
    print("2. Cập nhật TtsManagerProvider (lexicon giờ là 2 file):")
    print()
    print('     lexicon = FileEntry(')
    print('         url = "$RAW_URL/lexicon-us-en.txt,$RAW_URL/lexicon-zh.txt",')
    print('         weight = 3,')
    print('     )')
    print()
    print("   → sửa KokoroEngine.buildSherpaConfig để tách chuỗi lexicon")
    print("     bằng dấu phẩy, download từng URL, rồi ghép path lại truyền")
    print("     cho sherpa-onnx (nó hỗ trợ 'file1.txt,file2.txt').")
    print()
    print("3. Cập nhật modelId + defaultVoice:")
    print('     modelId      = "kokoro-multi-lang-v1_1"')
    print('     defaultVoice = "af_heart"   (English) hoặc "zf_xiaoxiao" (Chinese)')


def main() -> None:

    args = parse_args()
    args.out.mkdir(parents=True, exist_ok=True)

    work_dir = Path(tempfile.mkdtemp(prefix="kokoro-upgrade-"))
    print(f"[work] Thư mục tạm: {work_dir}")

    try:

        archive = work_dir / "kokoro-multi-lang-v1_1.tar.bz2"
        download_bundle(archive)
        bundle_dir = extract_bundle(archive, work_dir)
        zip_espeak_data(bundle_dir, args.out)
        copy_files(bundle_dir, args.out)
    finally:

        if args.keep_work:

            print(f"\n[keep] Giữ lại: {work_dir}")
        else:

            print(f"\n[cleanup] Xoá {work_dir}")
            shutil.rmtree(work_dir, ignore_errors=True)

    print_summary(args.out)


if __name__ == "__main__":

    main()
