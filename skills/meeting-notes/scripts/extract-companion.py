#!/usr/bin/env python3
"""Extract text and embedded images from a companion source into a directory.

A companion source is material captured alongside a transcript: a note app entry, an exported
HTML note, a saved page. It commonly carries screenshots whose content is not in the audio.

Emits <out>/<label>.md (text, with an [[image N: path]] marker where each image was) and
<out>/images/<label>-NN.<ext>. Where a downscaler is available, also writes a .view copy small
enough to read. Prints a manifest; never prints the source, which can be tens of megabytes.

Stdlib only. The Apple Notes adapter requires macOS.
"""

import argparse
import base64
import html
import os
import re
import shutil
import subprocess
import sys

DATA_URI = re.compile(r"data:image/([A-Za-z0-9.+-]+);base64,([A-Za-z0-9+/=\s]+)")
IMG_TAG = re.compile(r"<img\b[^>]*\bsrc\s*=\s*[\"']([^\"']+)[\"'][^>]*>", re.I)
EXT = {"png": "png", "jpeg": "jpg", "jpg": "jpg", "gif": "gif", "webp": "webp",
       "tiff": "tiff", "bmp": "bmp", "heic": "heic", "svg+xml": "svg"}


def die(message, code=1):
    sys.stderr.write("extract-companion: %s\n" % message)
    raise SystemExit(code)


def read_apple_note(title):
    """Return the HTML body of the first Notes entry whose name contains `title`."""
    if sys.platform != "darwin":
        die("--apple-note requires macOS; use --html with an exported file", 2)
    if not shutil.which("osascript"):
        die("--apple-note requires osascript", 2)
    quoted = title.replace("\\", "\\\\").replace('"', '\\"')
    script = ('tell application "Notes" to get body of first note '
              'whose name contains "%s"' % quoted)
    try:
        done = subprocess.run(["osascript", "-e", script], capture_output=True, text=True)
    except OSError as exc:
        die("osascript failed: %s" % exc)
    if done.returncode != 0:
        detail = done.stderr.strip().splitlines()
        hint = detail[-1] if detail else "no such note, or Notes access was denied"
        die("could not read a note matching %r: %s" % (title, hint))
    if not done.stdout.strip():
        die("note matching %r is empty" % title)
    return done.stdout


def downscale(path, max_px):
    """Write a reduced-size sibling for reading. Returns its path, or None."""
    stem, ext = os.path.splitext(path)
    out = "%s.view%s" % (stem, ext)
    if shutil.which("sips"):
        cmd = ["sips", "-Z", str(max_px), path, "--out", out]
    elif shutil.which("magick"):
        cmd = ["magick", path, "-resize", "%dx%d>" % (max_px, max_px), out]
    else:
        return None
    done = subprocess.run(cmd, capture_output=True)
    return out if done.returncode == 0 and os.path.exists(out) else None


def html_to_text(markup):
    text = re.sub(r"(?is)<(script|style)\b.*?</\1>", "", markup)
    text = re.sub(r"(?i)<br\s*/?>", "\n", text)
    text = re.sub(r"(?i)<li\b[^>]*>", "\n- ", text)
    for level in range(1, 7):
        text = re.sub(r"(?i)<h%d\b[^>]*>" % level, "\n%s " % ("#" * level), text)
    text = re.sub(r"(?i)</(div|p|tr|ul|ol|h[1-6]|blockquote)>", "\n", text)
    text = re.sub(r"<[^>]+>", "", text)
    text = html.unescape(text)
    text = "\n".join(line.rstrip() for line in text.splitlines())
    return re.sub(r"\n{3,}", "\n\n", text).strip() + "\n"


def extract(markup, out_dir, label, max_px, base_dir):
    images_dir = os.path.join(out_dir, "images")
    os.makedirs(images_dir, exist_ok=True)
    found = []

    def save(data, extension):
        name = "%s-%02d.%s" % (label, len(found) + 1, extension)
        path = os.path.join(images_dir, name)
        with open(path, "wb") as handle:
            handle.write(data)
        view = downscale(path, max_px) if max_px else None
        found.append((path, view))
        return "\n[[image %d: %s]]\n" % (len(found), view or path)

    def from_data_uri(match):
        try:
            return save(base64.b64decode(match.group(2)), EXT.get(match.group(1).lower(), "bin"))
        except (ValueError, TypeError):
            return "\n[[image: undecodable data URI]]\n"

    def from_img_tag(match):
        src = html.unescape(match.group(1))
        embedded = DATA_URI.match(src)
        if embedded:
            return from_data_uri(embedded)
        if src.startswith("file://"):
            src = src[7:]
        if re.match(r"^[a-z][a-z0-9+.-]*://", src, re.I):
            return "\n[[image: remote, not fetched: %s]]\n" % src
        path = src if os.path.isabs(src) else os.path.join(base_dir, src)
        if not os.path.isfile(path):
            return "\n[[image: missing local file: %s]]\n" % src
        with open(path, "rb") as handle:
            return save(handle.read(), (os.path.splitext(path)[1].lstrip(".") or "bin").lower())

    markup = IMG_TAG.sub(from_img_tag, markup)
    markup = DATA_URI.sub(from_data_uri, markup)
    if not found:
        os.rmdir(images_dir)
    text_path = os.path.join(out_dir, "%s.md" % label)
    with open(text_path, "w", encoding="utf-8") as handle:
        handle.write(html_to_text(markup))
    return text_path, found


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--apple-note", metavar="TITLE",
                        help="read the first macOS Notes entry whose name contains TITLE")
    source.add_argument("--html", metavar="FILE", help="read an HTML file")
    source.add_argument("--stdin", action="store_true", help="read HTML from stdin")
    parser.add_argument("--out", required=True, metavar="DIR", help="output directory")
    parser.add_argument("--label", help="artifact name stem (default: derived from the source)")
    parser.add_argument("--max-px", type=int, default=1600, metavar="N",
                        help="longest edge of the readable copy; 0 disables (default: 1600)")
    args = parser.parse_args()

    base_dir = os.getcwd()
    if args.apple_note:
        markup = read_apple_note(args.apple_note)
        default_label = args.apple_note
    elif args.html:
        if not os.path.isfile(args.html):
            die("no such file: %s" % args.html, 2)
        with open(args.html, encoding="utf-8", errors="replace") as handle:
            markup = handle.read()
        base_dir = os.path.dirname(os.path.abspath(args.html))
        default_label = os.path.splitext(os.path.basename(args.html))[0]
    else:
        markup = sys.stdin.read()
        default_label = "companion"

    label = re.sub(r"[^a-z0-9]+", "-", (args.label or default_label).lower()).strip("-")
    if not label:
        label = "companion"
    if args.max_px < 0:
        die("--max-px must not be negative", 2)

    os.makedirs(args.out, exist_ok=True)
    text_path, found = extract(markup, args.out, label, args.max_px, base_dir)

    print("text: %s" % text_path)
    for index, (path, view) in enumerate(found, 1):
        print("image %d: %s%s" % (index, path, "" if not view else "  read: %s" % view))
    print("images: %d" % len(found))
    if not found:
        print("note: no embedded images found", file=sys.stderr)
    if found and not any(view for _, view in found) and args.max_px:
        print("note: no downscaler (sips or magick) on PATH; originals may be too large to read",
              file=sys.stderr)


if __name__ == "__main__":
    main()
