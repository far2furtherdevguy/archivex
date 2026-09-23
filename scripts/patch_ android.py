#!/usr/bin/env python3
"""
Patches the Android project that `flutter create` scaffolds fresh on every CI run so
ArchiveX has the storage permissions, app label and Gradle reliability settings it needs.

Run after `flutter create --platforms=android .` and before `flutter build apk`.
Safe to run multiple times (idempotent).
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ANDROID = ROOT / "android"


def patch_manifest():
    manifest = ANDROID / "app" / "src" / "main" / "AndroidManifest.xml"
    text = manifest.read_text()

    if "xmlns:tools" not in text:
        text = text.replace(
            "<manifest xmlns:android=\"http://schemas.android.com/apk/res/android\"",
            "<manifest xmlns:android=\"http://schemas.android.com/apk/res/android\"\n"
            "    xmlns:tools=\"http://schemas.android.com/tools\"",
            1,
        )

    permissions = """    <uses-permission android:name="android.permission.READ_EXTERNAL_STORAGE" android:maxSdkVersion="32" />
    <uses-permission android:name="android.permission.WRITE_EXTERNAL_STORAGE" android:maxSdkVersion="32" />
    <uses-permission android:name="android.permission.MANAGE_EXTERNAL_STORAGE" tools:ignore="ScopedStorage" />
"""
    if "MANAGE_EXTERNAL_STORAGE" not in text:
        text = re.sub(r"(<manifest\b[^>]*>)", r"\1\n" + permissions, text, count=1)

    if 'android:requestLegacyExternalStorage' not in text:
        text = text.replace(
            "<application",
            '<application\n        android:requestLegacyExternalStorage="true"\n        android:label="ArchiveX"',
            1,
        )
    else:
        text = text.replace('android:label="archivex"', 'android:label="ArchiveX"')

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
