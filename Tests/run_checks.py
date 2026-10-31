#!/usr/bin/env python3
"""编译独立验证程序，任何编译或运行失败都会立即退出。"""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SOURCES = ROOT / "Sources" / "KimoMonitor"
CORE = [SOURCES / name for name in ("Models.swift", "Formatting.swift", "ProcessSampler.swift", "SystemSampler.swift")]


# 使用与生产相同的源文件编译检查，保持测试不会引入测试版实现。
def run_check(name, sources):
    with tempfile.TemporaryDirectory(prefix="kimo-check-") as directory:
        executable = Path(directory) / name
        command = ["swiftc", "-swift-version", "6", "-O", *map(str, sources), str(ROOT / "Tests" / f"{name}.swift"), "-o", str(executable)]
        subprocess.run(command, check=True, cwd=ROOT)
        return subprocess.run([str(executable)], check=True, text=True, capture_output=True, cwd=ROOT).stdout


# 分别覆盖算法、后台队列、最终位图以及真正的系统菜单栏。
def main():
    outputs = [run_check("SamplerChecks", CORE)]
    outputs.append(run_check("StoreSmoke", [*CORE, SOURCES / "MonitorStore.swift", SOURCES / "PreferencesStore.swift", SOURCES / "AlertController.swift"]))
    views = sorted(path for path in SOURCES.glob("*.swift") if path.name != "KimoMonitorApp.swift")
    outputs.append(run_check("SettingsChecks", views))
    outputs.append(run_check("MenuBarLayoutChecks", views))
    outputs.append(run_check("MenuBarSystemChecks", views))
    outputs.append(run_check("PanelLayoutChecks", views))
    report = "".join(outputs)
    destination = ROOT / "artifacts" / "validation.txt"
    destination.parent.mkdir(exist_ok=True)
    destination.write_text(report)
    print(report, end="")


if __name__ == "__main__":
    main()
