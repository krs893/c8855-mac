"""Build native macOS app, with a replaceable bundled libusb library."""
import pathlib
import plistlib
import shutil
import subprocess
import sys
import tempfile

root = pathlib.Path(__file__).resolve().parent
bundle = root / "C8855カウンター.app"
macos = bundle / "Contents" / "MacOS"
resources = bundle / "Contents" / "Resources"
macos.mkdir(parents=True, exist_ok=True)
resources.mkdir(parents=True, exist_ok=True)
library = root / "vendor" / "libusb-1.0.dylib"
if not library.exists():
    import libusb_package
    library = pathlib.Path(libusb_package.get_library_path())
shutil.copy2(library, resources / "libusb-1.0.dylib")
license_path = root / "vendor" / "COPYING"
if license_path.exists():
    shutil.copy2(license_path, resources / "LIBUSB_COPYING.txt")
sdk = subprocess.check_output(["xcrun", "--show-sdk-path"], text=True).strip()
with tempfile.TemporaryDirectory(prefix="c8855-build-") as directory:
    temp = pathlib.Path(directory)
    executables = []
    for arch in ["arm64", "x86_64"]:
        obj = temp / (arch + ".o")
        executable = temp / arch
        subprocess.run(["xcrun", "clang", "-arch", arch, "-mmacosx-version-min=13.0", "-isysroot", sdk,
                        "-Wall", "-Wextra", "-Werror", "-O2", "-c", str(root / "USBBridge.c"), "-o", str(obj)], check=True)
        subprocess.run(["xcrun", "swiftc", "-target", arch + "-apple-macosx13.0", "-sdk", sdk,
                        "-swift-version", "5", "-O", "-module-cache-path", str(temp / "swift-cache"),
                        "-import-objc-header", str(root / "USBBridge.h"), str(root / "NativeApp.swift"),
                        str(root / "PlotData.swift"), str(obj), "-o", str(executable),
                        "-framework", "Cocoa", "-framework", "SwiftUI"], check=True)
        executables.append(str(executable))
    subprocess.run(["lipo", "-create", *executables, "-output", str(macos / "C8855Counter")], check=True)
with (bundle / "Contents" / "Info.plist").open("wb") as f:
    plistlib.dump(dict(CFBundleExecutable="C8855Counter", CFBundleIdentifier="local.lab.c8855",
                      CFBundleName="C8855カウンター", CFBundleDisplayName="C8855カウンター",
                      CFBundlePackageType="APPL", CFBundleVersion="3", CFBundleShortVersionString="0.3.0",
                      LSMinimumSystemVersion="13.0", NSHighResolutionCapable=True), f)
subprocess.run(["codesign", "--force", "--sign", "-", str(resources / "libusb-1.0.dylib")], check=True)
subprocess.run(["codesign", "--force", "--sign", "-", str(bundle)], check=True)
print(bundle)
