#!/usr/bin/env python3
"""Build the local App, with optional stable identity and fixed installation path."""
from pathlib import Path
import argparse
import json
import plistlib
import shutil
import subprocess
import tempfile

parser = argparse.ArgumentParser()
parser.add_argument("--output", type=Path, help="Optional candidate path; keeps the existing running App unchanged")
parser.add_argument("--signed", action="store_true", help="Use the separately tested local identity; may need one-time macOS confirmation")
parser.add_argument("--install", action="store_true", help="Install signed App into ~/Applications/Agent Workbench Dev.app")
args = parser.parse_args()
if args.install and not args.signed:
    parser.error("--install requires --signed")
identity = "-"
if args.signed:
    config = json.loads((Path.home() / "Library/Application Support/Hushlight/Development/signing.json").read_text())
    if config.get("probe") != "signature_identity_pass":
        parser.error("Run setup_local_signing.py successfully first")
    identity = config["identity_sha1"]
project = Path(__file__).resolve().parents[1]
subprocess.run(["swift", "build", "--package-path", str(project), "--product", "HushlightMac"], check=True)
subprocess.run(["swift", "build", "--package-path", str(project), "--product", "agent-workbench-mcp"], check=True)
product = Path(subprocess.check_output(
    ["swift", "build", "--package-path", str(project), "--show-bin-path"], text=True
).strip())
output_app = args.output.expanduser().resolve() if args.output else project / ".build/HushlightMac-Dev.app"
output_app.parent.mkdir(parents=True, exist_ok=True)
staging_directory = tempfile.TemporaryDirectory(prefix="workbench-app-", dir=project / ".build")
app = Path(staging_directory.name) / "HushlightMac-Dev.app"
(app / "Contents/MacOS").mkdir(parents=True, exist_ok=True)
(app / "Contents/Resources").mkdir(exist_ok=True)
shutil.copy2(product / "HushlightMac", app / "Contents/MacOS/HushlightMac")
shutil.copy2(product / "agent-workbench-mcp", app / "Contents/MacOS/agent-workbench-mcp")
for resource in product.glob("HushlightMac_*.bundle"):
    shutil.copytree(resource, app / "Contents/Resources" / resource.name, dirs_exist_ok=True)
# Convert the user-provided artwork during the next ordinary App build.
# Preserve the supplied original; use the reviewed tight-canvas Orbit master.
icon_source = project / "Assets/OrbitIcon.png"
iconset = Path(staging_directory.name) / "AgentWorkbench.iconset"
iconset.mkdir()
for points in (16, 32, 128, 256, 512):
    for scale in (1, 2):
        pixels = points * scale
        suffix = "@2x" if scale == 2 else ""
        subprocess.run(["sips", "-z", str(pixels), str(pixels), str(icon_source),
                        "--out", str(iconset / f"icon_{points}x{points}{suffix}.png")],
                       check=True, stdout=subprocess.DEVNULL)
subprocess.run(["iconutil", "-c", "icns", str(iconset), "-o",
                str(app / "Contents/Resources/AgentWorkbench.icns")], check=True)
info = {
    "CFBundleIdentifier": "com.hushlight.bridge.mac",
    "CFBundleExecutable": "HushlightMac",
    "CFBundleName": "Orbit 智轨 Dev",
    "CFBundleDisplayName": "Orbit 智轨 Dev",
    "CFBundlePackageType": "APPL",
    "CFBundleIconFile": "AgentWorkbench.icns",
    "CFBundleVersion": "1",
    "CFBundleShortVersionString": "0.0.1",
    "NSHighResolutionCapable": True,
    "NSMicrophoneUsageDescription": "仅在你点击开始录音后使用麦克风，将语音转为可审阅文本；不保存录音，不自动执行识别内容。",
    "NSSpeechRecognitionUsageDescription": "使用支持的设备端语音识别，将你主动录制的语音转为文本；不支持设备端识别时停止，不回退云端。",
    "NSLocationWhenInUseUsageDescription": "仅在你点击后获取一次大致位置，显示时间和精度，不持续追踪，不自动共享给天气服务。",
    "NSLocationUsageDescription": "仅按需获取一次大致位置，不持续追踪或自动共享。",
    "NSAppleEventsUsageDescription": "按你选择的范围连接 Apple Notes 或 Apple Mail。Notes 仅访问专用文件夹；Mail 先核对账户和邮箱范围，再读取所选邮箱。",
    "NSCalendarsFullAccessUsageDescription": "仅管理工作台专用日历与工作台创建的日程，联动前由你明确授权。",
    "NSCalendarsUsageDescription": "管理工作台专用日历中创建的日程。",
    "NSRemindersFullAccessUsageDescription": "管理已连接的专用列表中由 Bridge 创建的提醒事项。系统需要完整提醒事项授权，本工具仅访问专用列表。",
    "NSRemindersUsageDescription": "管理已连接的专用列表中由 Bridge 创建的提醒事项。",
    "LSMinimumSystemVersion": "13.0",
}
(app / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
subprocess.run(["codesign", "--force", "--timestamp=none", "--sign", identity, str(app / "Contents/MacOS/agent-workbench-mcp")], check=True)
subprocess.run(["codesign", "--force", "--timestamp=none", "--sign", identity, str(app)], check=True)
subprocess.run(["codesign", "--verify", "--strict", str(app)], check=True)
# Keep existing .build paths valid for configured MCP clients.
backup_build = output_app.with_name(output_app.stem + ".previous.app")
if backup_build.exists():
    shutil.rmtree(backup_build)
if output_app.exists():
    output_app.rename(backup_build)
app.rename(output_app)
staging_directory.cleanup()
app = output_app
if args.install:
    destination = Path.home() / "Applications/Agent Workbench Dev.app"
    destination.parent.mkdir(exist_ok=True)
    staging = destination.with_name(".Agent Workbench Dev.installing.app")
    if staging.exists():
        shutil.rmtree(staging)
    shutil.copytree(app, staging)
    subprocess.run(["codesign", "--verify", "--strict", str(staging)], check=True)
    backup = destination.with_name(".Agent Workbench Dev.previous.app")
    if backup.exists():
        shutil.rmtree(backup)
    if destination.exists():
        destination.rename(backup)
    staging.rename(destination)
    app = destination
print(app)
