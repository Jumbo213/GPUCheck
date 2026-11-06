# GPUCheck

GPUCheck 是一个通过 SSH 监控远端 Linux 服务器 NVIDIA GPU 的原生 macOS 应用。

- 监控利用率、显存、温度、功耗和设备参数，并在 Mac 上保留近 30 天的历史记录。
- 添加、命名和切换多台服务器，查看可读取的 GPU 进程、命令、工作目录及文件。
- 可按服务器启用空闲维护。全卡利用率 ≤2% 的在线时间累计满 5 小时，触发最多 5 分钟的负载。断连和休眠暂停并保存计时，重连后继续累计。瞬时小负载暂停计时，高于 2% 持续 15 秒或达到 10% 时清零。显存占用和已有进程不参与空闲计时。应用需持续运行，远端需支持 PyTorch CUDA。

矩阵大小、填充显存和运行余量按各卡当前可用显存选择。矩阵分配失败时逐级缩小，运行中检测显存压力并释放填充。启动失败会保留空闲进度，60 秒后重试。

历史图表可读取更换 GPU UUID 前的记录，服务器离线时以最后采样时间为终点显示已保存的曲线。

## 安装

从 GitHub Releases 下载通用 DMG，打开后将 GPUCheck 拖入 Applications。支持 macOS 14 及以上的 Apple Silicon 和 Intel Mac。本版本尚未做 Apple 公证，首次打开如被拦截，可参照 [Apple 的打开说明](https://support.apple.com/zh-cn/102445)。

启动后点击“添加服务器”，填写地址、端口和 SSH 用户。支持 SSH 密钥、SSH Agent 和密码，密码存入 macOS 钥匙串。远端监控需要 NVIDIA 驱动、`nvidia-smi` 和 Python 3。

## 构建和测试

在安装了 Xcode Command Line Tools 的 Mac 上运行 `./build.sh`，应用生成在 `build/`，通用 DMG 生成在 `outputs/`。`./Tests/run-tests.sh` 运行本地空闲策略和远端脚本模拟测试。
