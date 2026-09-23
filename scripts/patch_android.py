#!/usr/bin/env python3
"""
Patches the Android project that `flutter create` scaffolds fresh on every CI run so
ArchiveX has the storage permissions, app label and Gradle reliability settings it needs.

Run after `flutter create --platforms=android .` and before `flutter build apk`.
Safe to run multiple times (idempotent) and safe regardless of the exact
attributes the installed Flutter version's template already puts on
<manifest>/<application> (it overwrites existing attributes in place instead
of appending duplicates, which is what previously produced invalid XML and
broke `processReleaseManifest`).
"""
import re
import sys
import xml.dom.minidom
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ANDROID = ROOT / "android"


def _set_attr(tag_text: str, attr: str, value: str) -> str:
    """Set attr="value" on an XML opening tag, overwriting it if already present
    instead of appending a duplicate (duplicate attributes make the file invalid
    XML and fail manifest parsing outright)."""
    pattern = re.compile(re.escape(attr) + r'\s*=\s*"[^"]*"')
    if pattern.search(tag_text):
        return pattern.sub(f'{attr}="{value}"', tag_text, count=1)
    # Not present yet: insert just before the tag's closing '>'.
    assert tag_text.endswith(">") and not tag_text.endswith("/>")
    return tag_text[:-1].rstrip() + f'\n    {attr}="{value}">'


def _replace_tag(text: str, tag_regex: str, mutate) -> str:
    m = re.search(tag_regex, text, re.DOTALL)
    if not m:
        raise RuntimeError(f"Could not find tag matching {tag_regex!r}")
    original = m.group(0)
    updated = mutate(original)
    return text[: m.start()] + updated + text[m.end() :]


def patch_manifest():
    manifest = ANDROID / "app" / "src" / "main" / "AndroidManifest.xml"
    text = manifest.read_text()

    # Ensure xmlns:tools is declared on <manifest> (needed for tools:ignore below).
    text = _replace_tag(
        text,
        r"<manifest\b[^>]*>",
        lambda tag: _set_attr(tag, "xmlns:tools", "http://schemas.android.com/tools"),
    )

    # Insert the storage permissions once, right after <manifest ...>.
    if "MANAGE_EXTERNAL_STORAGE" not in text:
        permissions = (
            '    <uses-permission android:name="android.permission.READ_EXTERNAL_STORAGE" '
            'android:maxSdkVersion="32" />\n'
            '    <uses-permission android:name="android.permission.WRITE_EXTERNAL_STORAGE" '
            'android:maxSdkVersion="32" />\n'
            '    <uses-permission android:name="android.permission.MANAGE_EXTERNAL_STORAGE" '
            'tools:ignore="ScopedStorage" />\n'
        )
        m = re.search(r"<manifest\b[^>]*>", text, re.DOTALL)
        insert_at = m.end()
        text = text[:insert_at] + "\n" + permissions + text[insert_at:]

    # Set (not append) the app label and legacy-storage flag on <application>.
    text = _replace_tag(
        text,
        r"<application\b[^>]*>",
        lambda tag: _set_attr(_set_attr(tag, "android:label", "ArchiveX"),
                               "android:requestLegacyExternalStorage", "true"),
    )

    # Fail loudly here rather than downstream in Gradle if something is still broken.
    xml.dom.minidom.parseString(text)

    manifest.write_text(text)
    print(f"patched {manifest}")


def patch_gradle_properties():
    props = ANDROID / "gradle.properties"
    text = props.read_text() if props.exists() else ""
    extra = {
        "android.useAndroidX": "true",
        "android.enableJetifier": "true",
        "org.gradle.jvmargs": "-Xmx4G -XX:MaxMetaspaceSize=2G",
        "org.gradle.parallel": "true",
        "org.gradle.caching": "true",
        # Retry/timeout tuning so transient Maven Central / Google Maven hiccups
        # (rate limits, flaky CI network) don't fail the whole build outright.
        "systemProp.org.gradle.internal.repository.max.retries": "10",
        "systemProp.org.gradle.internal.repository.max.tentatives": "10",
        "systemProp.org.gradle.internal.http.connectionTimeout": "180000",
        "systemProp.org.gradle.internal.http.socketTimeout": "180000",
        "systemProp.http.socketTimeout": "180000",
        "systemProp.http.connectionTimeout": "180000",
    }
    lines = [l for l in text.splitlines() if l.strip()]
    keys_present = {l.split("=", 1)[0].strip() for l in lines if "=" in l}
    for k, v in extra.items():
        if k not in keys_present:
            lines.append(f"{k}={v}")
    props.write_text("\n".join(lines) + "\n")
    print(f"patched {props}")


def main():
    if not ANDROID.exists():
        print("android/ not found — run `flutter create --platforms=android .` first", file=sys.stderr)
        sys.exit(1)
    patch_manifest()
    patch_gradle_properties()


if __name__ == "__main__":
    main()
