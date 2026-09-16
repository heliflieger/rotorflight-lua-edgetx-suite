#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Build the announcement pack under src/rfsuite/audio/<language>/ from the word lists in json/.

The pack is not hand-recorded: every file is one line of text, synthesised by Google Cloud
Text-to-Speech and post-processed with SoX. This script is what turns json/<language>.json into
the WAV files the packager copies, so a new announcement is a new line in those lists rather
than an audio file somebody has to produce by hand.

Two modes, and only one of them needs a Google Cloud account:

    generate-googleapi.py --check
        Compares the word lists against the files on disk: what is declared and missing, what is
        on disk and declared nowhere, and which entries still have no translation. Needs nothing
        but Python, and is the mode to run when reviewing a change to the lists.

    generate-googleapi.py --lang en --only-missing
        Synthesises. Needs `google-cloud-texttospeech`, `sox` (the binary and the Python
        binding), and Google Cloud credentials in the environment.

The audio chain is fixed, because it is the one the shipped pack went through and the files have
to stay consistent with each other: LINEAR16 at 16 kHz from the API, then SoX to mono 16 kHz
G.711 A-law with the trailing silence trimmed, then SoX again to the 16-bit PCM this radio's
firmware plays. The A-law step is not redundant -- it is what gives the pack its quantisation,
and a file rendered without it sits noticeably cleaner than the ones beside it.
"""

import argparse
import hashlib
import json
import os
import shutil
import sys
import tempfile

# The voice each language is rendered with. Changing one of these re-renders that whole language
# and the result will not match the files already in the tree, so it is a deliberate act.
VOICES = {
    "en": "en-US-Wavenet-F",
    "de": "de-DE-Wavenet-E",
}

HERE = os.path.dirname(os.path.abspath(__file__))
JSON_DIR = os.path.join(HERE, "json")
AUDIO_DIR = os.path.normpath(os.path.join(HERE, "..", "..", "src", "rfsuite", "audio"))


def load_list(lang):
    path = os.path.join(JSON_DIR, lang + ".json")
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


def languages(selected):
    if selected in (None, "all"):
        return sorted(VOICES)
    return [selected]


def files_on_disk(lang):
    base = os.path.join(AUDIO_DIR, lang)
    found = set()
    for dirpath, _dirnames, filenames in os.walk(base):
        for name in filenames:
            if name.endswith(".wav"):
                rel = os.path.relpath(os.path.join(dirpath, name), base)
                found.add(rel.replace(os.sep, "/"))
    return found


def text_for(entry):
    """The line to speak. A missing translation falls back to English rather than to silence."""
    if entry.get("translation") is None:
        return entry.get("english", ""), True
    return entry["translation"], False


# --------------------------------------------------------------------------- check

def check(selected):
    problems = 0
    for lang in languages(selected):
        entries = load_list(lang)
        declared = set(e["file"] for e in entries)
        present = files_on_disk(lang)
        missing = sorted(declared - present)
        orphan = sorted(present - declared)
        untranslated = sorted(e["file"] for e in entries if e.get("translation") is None)

        print("[%s] %d declared, %d on disk" % (lang, len(declared), len(present)))
        for f in missing:
            print("      MISSING     %s  (declared, no file -- run this script to build it)" % f)
        for f in orphan:
            print("      UNDECLARED  %s  (file exists, no entry -- it cannot be rebuilt)" % f)
        for f in untranslated:
            print("      NO TEXT     %s  (spoken in English by the %s voice)" % (f, lang))
        problems += len(missing) + len(orphan)
    return 1 if problems else 0


# --------------------------------------------------------------------------- build

class NullCache:
    def get(self, *args, **kwargs):
        return False

    def push(self, *args, **kwargs):
        pass


class PromptsCache:
    """Keyed on the spoken text and the voice, so an unchanged line is never paid for twice."""

    def __init__(self, directory):
        self.directory = directory
        if not os.path.exists(directory):
            os.makedirs(directory)

    def path(self, text, voice):
        digest = hashlib.md5((voice + "\0" + text).encode("utf-8")).hexdigest()
        return os.path.join(self.directory, digest)

    def get(self, filename, text, voice):
        cached = self.path(text, voice)
        if not os.path.exists(cached):
            return False
        os.makedirs(os.path.dirname(filename), exist_ok=True)
        shutil.copy(cached, filename)
        return True

    def push(self, filename, text, voice):
        shutil.copy(filename, self.path(text, voice))


def post_process(sox, raw_path, dest_path):
    """LINEAR16 from the API -> A-law, trailing silence trimmed -> the 16-bit PCM the radio plays."""
    temp_dir = tempfile.mkdtemp()
    try:
        alaw_path = os.path.join(temp_dir, "alaw.wav")

        to_alaw = sox.Transformer()
        to_alaw.set_output_format(channels=1, rate=16000, encoding="a-law")
        to_alaw.build(raw_path, alaw_path,
                      extra_args=["reverse", "silence", "1", "0.1", "0.1%", "reverse"])

        to_pcm = sox.Transformer()
        to_pcm.set_output_format(channels=1, rate=16000, encoding="signed-integer", bits=16)
        os.makedirs(os.path.dirname(dest_path), exist_ok=True)
        to_pcm.build(alaw_path, dest_path)
    finally:
        shutil.rmtree(temp_dir, ignore_errors=True)


def build(selected, voice_override, speed, only_missing, cache_dir, dry_run):
    if dry_run:
        sox = None
        client = None
    else:
        try:
            import sox
        except ImportError:
            print("SoX is missing: python -m pip install sox (and install the sox binary)", file=sys.stderr)
            return 1
        try:
            from google.cloud import texttospeech
        except ImportError:
            print("The client is missing: python -m pip install google-cloud-texttospeech", file=sys.stderr)
            return 1
        client = texttospeech.TextToSpeechClient()

    for lang in languages(selected):
        voice_name = voice_override or VOICES[lang]
        cache = PromptsCache(os.path.join(cache_dir, voice_name)) if cache_dir else NullCache()
        entries = load_list(lang)
        built = skipped = 0

        for entry in entries:
            dest = os.path.join(AUDIO_DIR, lang, *entry["file"].split("/"))
            if only_missing and os.path.exists(dest):
                skipped += 1
                continue

            text, fell_back = text_for(entry)
            if not text:
                print("  no text at all for %s, skipped" % entry["file"], file=sys.stderr)
                continue
            if fell_back:
                print("  no %s translation for %s, speaking the English line" % (lang, entry["file"]),
                      file=sys.stderr)

            print("  %s <- %r" % (entry["file"], text))
            if dry_run:
                built += 1
                continue

            if cache.get(dest, text, voice_name):
                built += 1
                continue

            from google.cloud import texttospeech
            response = client.synthesize_speech(
                input=texttospeech.SynthesisInput(text=text),
                voice=texttospeech.VoiceSelectionParams(
                    language_code="-".join(voice_name.split("-")[:2]),
                    name=voice_name),
                audio_config=texttospeech.AudioConfig(
                    audio_encoding=texttospeech.AudioEncoding.LINEAR16,
                    sample_rate_hertz=16000,
                    speaking_rate=speed))

            temp_dir = tempfile.mkdtemp()
            try:
                raw_path = os.path.join(temp_dir, "raw.wav")
                with open(raw_path, "wb") as out:
                    out.write(response.audio_content)
                post_process(sox, raw_path, dest)
            finally:
                shutil.rmtree(temp_dir, ignore_errors=True)

            cache.push(dest, text, voice_name)
            built += 1

        print("[%s] voice %s: %d built, %d already present" % (lang, voice_name, built, skipped))

    return 0


def main():
    parser = argparse.ArgumentParser(description="Build the announcement pack from the word lists.")
    parser.add_argument("--check", action="store_true",
                        help="Compare the lists against the files on disk and report; needs no credentials.")
    parser.add_argument("--lang", help="Language to build: %s, or 'all' (the default)."
                                       % ", ".join(sorted(VOICES)))
    parser.add_argument("--voice", help="Override the voice for this run. Re-renders against the shipped pack.")
    parser.add_argument("--speed", type=float, default=1.0, help="Speaking rate multiplier, default 1.0.")
    parser.add_argument("--only-missing", action="store_true", help="Build only the files that are not there yet.")
    parser.add_argument("--cache", help="Directory to keep synthesised audio in, keyed on text and voice.")
    parser.add_argument("--dry-run", action="store_true",
                        help="List what would be built and where, without calling the API.")
    args = parser.parse_args()

    if args.lang and args.lang != "all" and args.lang not in VOICES:
        print("Unknown language %r; known: %s" % (args.lang, ", ".join(sorted(VOICES))), file=sys.stderr)
        return 1

    if args.check:
        return check(args.lang)
    return build(args.lang, args.voice, args.speed, args.only_missing, args.cache, args.dry_run)


if __name__ == "__main__":
    sys.exit(main())
