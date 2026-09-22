#!/usr/bin/env python3
"""Build a portable Windows ZIP or Debian .deb using the locally supplied SDK."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys
import tarfile
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parents[1]
VERSION = "1.3.0"


def run(args, **kwargs):
    print("+", " ".join(map(str, args)), flush=True)
    subprocess.run(list(map(str, args)), check=True, **kwargs)


def extract(archive, target):
    target.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(archive) as zipped:
        # Reject archive traversal even for user-supplied SDK archives.
        for item in zipped.infolist():
            if not (target / item.filename).resolve().is_relative_to(target.resolve()):
                raise ValueError(f"Unsafe archive member: {item.filename}")
        zipped.extractall(target)


def sdk_root(argument, key, archive_suffix):
    if argument:
        source = Path(argument).resolve()
    else:
        source = ROOT / "sdk" / key
        if not (source / "app/CRSDK/CameraRemote_SDK.h").exists():
            archives = sorted(ROOT.glob(f"CrSDK*_{archive_suffix}.zip"))
            if not archives:
                raise SystemExit(f"Put CrSDK*_{archive_suffix}.zip in the repository, or pass --sdk PATH")
            source = archives[-1]
    if source.is_file():
        destination = ROOT / "sdk" / key
        extract(source, destination)
        source = destination
    if not (source / "app/CRSDK/CameraRemote_SDK.h").exists() and (source / "SimpleCli.zip").exists():
        extract(source / "SimpleCli.zip", source)
    if not (source / "app/CRSDK/CameraRemote_SDK.h").exists():
        raise SystemExit(f"SDK headers missing: {source}")
    return source


def windows_environment():
    env = os.environ.copy()
    env["PATH"] = str(Path(sys.executable).parent) + os.pathsep + env.get("PATH", "")
    if shutil.which("cl", path=env["PATH"]):
        return env, None
    vswhere = Path(os.environ.get("ProgramFiles(x86)", "C:/Program Files (x86)")) / "Microsoft Visual Studio/Installer/vswhere.exe"
    installation = subprocess.check_output([str(vswhere), "-latest", "-products", "*", "-requires", "Microsoft.VisualStudio.Component.VC.Tools.x86.x64", "-property", "installationPath"], text=True).strip()
    if not installation:
        raise SystemExit("Install Visual Studio Build Tools with the C++ desktop workload.")
    vcvars = Path(installation) / "VC/Auxiliary/Build/vcvars64.bat"
    # These are trusted tool paths; no user-supplied SDK path is passed to cmd.
    output = subprocess.check_output(f'cmd.exe /d /s /c ""{vcvars}" >nul && set"', env=env, text=True, errors="replace")
    for line in output.splitlines():
        if "=" in line:
            name, value = line.split("=", 1)
            env[name] = value
    return env, Path(installation)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sdk", help="SDK ZIP, SDK root, or extracted SimpleCli directory")
    parser.add_argument("--native-only", action="store_true")
    parser.add_argument("--output-dir", type=Path, help="Directory for the unpacked application (use a separate directory if an older build is running)")
    args = parser.parse_args()
    windows = sys.platform == "win32"
    if sys.platform not in ("win32", "linux"):
        raise SystemExit("Use Scripts/build.sh for the native macOS application.")
    machine = platform.machine().lower()
    arm = machine in ("aarch64", "arm64")
    if windows and machine not in ("amd64", "x86_64"):
        raise SystemExit("Windows build requires an x64 Python interpreter and Win64 SDK.")
    if not windows and machine not in ("x86_64", "amd64", "aarch64", "arm64"):
        raise SystemExit(f"Unsupported Linux architecture: {machine}")
    libc_version = platform.libc_ver()[1] if not windows else ""
    if not windows and arm and not args.native_only and tuple(map(int, libc_version.split("."))) < (2, 39):
        raise SystemExit("PySide6 6.8.3 ARM64 requires glibc >= 2.39. Build the ARM64 desktop on Debian 13 or newer; Debian 12 supports the native bridge only.")
    key = "windows" if windows else ("linux-arm64" if arm else "linux-x64")
    suffix = "Win64" if windows else ("Linux64ARMv8" if arm else "Linux64PC")
    sdk = sdk_root(args.sdk, key, suffix)
    env, vs = windows_environment() if windows else (os.environ.copy(), None)
    env["PATH"] = str(Path(sys.executable).parent) + os.pathsep + env.get("PATH", "")
    build = ROOT / "build" / ("native-win" if windows else f"native-{key}")
    stage = ROOT / "build" / f"stage-{key}"
    dist = args.output_dir.resolve() if args.output_dir else ROOT / "dist" / key
    cmake = shutil.which("cmake", path=env["PATH"])
    if not cmake:
        raise SystemExit("CMake is required.")
    run([cmake, "-S", ROOT, "-B", build, "-G", "Ninja", "-DCMAKE_BUILD_TYPE=Release", f"-DSONY_SDK_ROOT={sdk.as_posix()}"], env=env)
    run([cmake, "--build", build, "--parallel"], env=env)
    run([str(Path(cmake).with_name("ctest.exe" if windows else "ctest")), "--test-dir", build, "--output-on-failure"], env=env)
    run([cmake, "--install", build, "--prefix", stage], env=env)
    if args.native_only:
        print(f"Native SDK bridge: {stage / 'native'}")
        return
    payload_temp = tempfile.TemporaryDirectory(prefix="sony-native-payload-")
    payload = Path(payload_temp.name) / "native"
    shutil.copytree(sdk / "external/crsdk", payload, ignore=shutil.ignore_patterns("*.lib", "*.a", "*.exe", "*.pdb", "*.log"))
    shutil.copy2(stage / "native" / ("camera_bridge.dll" if windows else "libcamera_bridge.so"), payload)
    run([sys.executable, "-m", "PyInstaller", "--noconfirm", "--clean", "--onedir", "--windowed",
         "--name", "SonyCameraControl", "--distpath", dist, "--workpath", ROOT / "build" / f"pyinstaller-{key}",
         "--specpath", ROOT / "build" / f"spec-{key}", "--add-data", f"{payload}{os.pathsep}native",
         "--exclude-module", "numpy", "--exclude-module", "cv2", ROOT / "Sources/Desktop/main.py"], env=env)
    app = dist / "SonyCameraControl"
    # Sony discovers adapters relative to the host executable, even when Core is
    # loaded from _internal/native by ctypes. Keep this vendor directory intact.
    shutil.copytree(payload / "CrAdapter", app / "CrAdapter", dirs_exist_ok=True)
    payload_temp.cleanup()
    shutil.copy2(ROOT / "Scripts/install-camera-driver.ps1", app / "install-camera-driver.ps1")
    licenses = app / "licenses"
    licenses.mkdir(exist_ok=True)
    shutil.copytree(ROOT / "ThirdPartyLicenses", licenses / "Sony", dirs_exist_ok=True)
    shutil.copy2(sdk / "README.md", licenses / "Sony-SDK-platform-notices.md")
    shutil.copy2(ROOT / "ThirdParty/nlohmann/LICENSE.MIT", licenses / "nlohmann-json-MIT.txt")
    for name in ("README.md", "使用说明.md", "THIRD_PARTY_NOTICES.md", "DESKTOP.md", "DESKTOP_VALIDATION.md"):
        if (ROOT / name).exists():
            shutil.copy2(ROOT / name, app / name)
    import PySide6
    pyside = Path(PySide6.__file__).parent
    for candidate in (pyside / "doc/licenses", pyside / "Qt/licenses"):
        if candidate.exists():
            shutil.copytree(candidate, licenses / "Qt", dirs_exist_ok=True)
    own_licenses = ROOT / "ThirdPartyLicenses/Desktop"
    if own_licenses.exists():
        shutil.copytree(own_licenses, licenses / "Desktop", dirs_exist_ok=True)
    if not windows:
        python_copyright = Path(f"/usr/share/doc/python{sys.version_info.major}.{sys.version_info.minor}/copyright")
        if python_copyright.exists():
            shutil.copy2(python_copyright, licenses / "Desktop/Python-LICENSE.txt")
    artifacts = []
    if windows:
        if (sdk / "Driver.zip").exists():
            extract(sdk / "Driver.zip", app / "drivers")
        if vs:
            crt = sorted((vs / "VC/Redist/MSVC").glob("14.*/x64/Microsoft.VC*.CRT"))
            if crt:
                for dll in crt[-1].glob("*.dll"):
                    shutil.copy2(dll, app / "_internal/native" / dll.name)
        archive_base = ROOT / "dist" / f"SonyCameraControl-{VERSION}-windows-x64"
        artifacts.append(Path(shutil.make_archive(str(archive_base), "zip", dist, "SonyCameraControl")))
    else:
        arch = "arm64" if arm else "amd64"
        # WSL /mnt/c and /mnt/d may not preserve Unix permissions. Stage the
        # Debian filesystem on the native temporary filesystem instead.
        debtemp = tempfile.TemporaryDirectory(prefix="sony-camera-deb-")
        deb = Path(debtemp.name)
        opt = deb / "opt/sony-camera-control"
        shutil.copytree(app, opt, dirs_exist_ok=True)
        (deb / "DEBIAN").mkdir(parents=True, exist_ok=True)
        depends = f"libc6 (>= {libc_version}), libstdc++6, libgcc-s1, libudev1, libxml2, libglib2.0-0, libgl1, libegl1, libopengl0, libxcb-cursor0, libxcb-shape0, libxcb-icccm4, libxcb-keysyms1, libxkbcommon-x11-0, libxrender1, libxi6, libxrandr2, libxcursor1, libxcomposite1, libxdamage1, libxtst6, libnss3, libasound2, libdbus-1-3, libfontconfig1, libgtk-3-0"
        (deb / "DEBIAN/control").write_text(f"Package: sony-camera-control\nVersion: {VERSION}\nSection: graphics\nPriority: optional\nArchitecture: {arch}\nMaintainer: Sony Camera Control contributors\nDepends: {depends}\nRecommends: fonts-noto-cjk\nDescription: Desktop remote control for Sony SDK-compatible cameras\n Live view, direct photo transfer, burst capture and manual focus.\n", encoding="utf-8")
        for source, destination in (("sony-camera-control.desktop", "usr/share/applications/sony-camera-control.desktop"), ("sony-camera-control.svg", "usr/share/icons/hicolor/scalable/apps/sony-camera-control.svg"), ("70-sony-camera-control.rules", "usr/lib/udev/rules.d/70-sony-camera-control.rules")):
            target = deb / destination
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(ROOT / "Packaging" / source, target)
        launcher = deb / "usr/bin/sony-camera-control"
        launcher.parent.mkdir(parents=True, exist_ok=True)
        launcher.write_text('#!/bin/sh\nexec /opt/sony-camera-control/SonyCameraControl "$@"\n', encoding="utf-8")
        launcher.chmod(0o755)
        for script in ("postinst", "postrm"):
            path = deb / "DEBIAN" / script
            path.write_text('#!/bin/sh\nset -e\nif command -v udevadm >/dev/null 2>&1; then udevadm control --reload-rules || true; fi\nexit 0\n', encoding="utf-8")
            path.chmod(0o755)
        for path in deb.rglob("*"):
            if not path.is_symlink():
                path.chmod(0o755 if path.is_dir() or path.name in ("SonyCameraControl", "sony-camera-control", "postinst", "postrm") or ".so" in path.name else 0o644)
        artifact = ROOT / "dist" / f"sony-camera-control_{VERSION}_{arch}.deb"
        run(["dpkg-deb", "--root-owner-group", "--build", deb, artifact])
        debtemp.cleanup()
        artifacts.append(artifact)
        archive = ROOT / "dist" / f"SonyCameraControl-{VERSION}-{key}.tar.gz"
        with tarfile.open(archive, "w:gz") as tar:
            def safe_mode(info):
                info.mode &= 0o755
                info.uid = info.gid = 0
                info.uname = info.gname = "root"
                return info
            tar.add(app, arcname="SonyCameraControl", filter=safe_mode)
        artifacts.append(archive)
    for artifact in artifacts:
        digest = hashlib.sha256(artifact.read_bytes()).hexdigest()
        artifact.with_name(artifact.name + ".sha256").write_text(f"{digest}  {artifact.name}\n", encoding="ascii")
        print(f"Built: {artifact} ({artifact.stat().st_size:,} bytes)")


if __name__ == "__main__":
    main()
