import Foundation
import Security

struct SSHClient: Sendable {
    static var applicationDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("GPUCheck", isDirectory: true)
    }

    static func validate(_ server: Server) throws {
        guard !server.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw GPUCheckError("请填写服务器名称。") }
        let host = server.host
        guard !host.isEmpty, !host.hasPrefix("-"), host.range(of: "^[A-Za-z0-9_][A-Za-z0-9._:-]*$", options: .regularExpression) != nil else {
            throw GPUCheckError("主机地址格式不正确。请填写 IP、域名或 SSH 配置中的主机别名。")
        }
        guard server.port > 0 && server.port <= 65535 else { throw GPUCheckError("端口必须在 1 到 65535 之间。") }
        guard server.user.range(of: "^[A-Za-z0-9_][A-Za-z0-9_.-]*[$]?$", options: .regularExpression) != nil else { throw GPUCheckError("SSH 用户名格式不正确。") }
        if !server.identityPath.isEmpty {
            let path = (server.identityPath as NSString).expandingTildeInPath
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue else {
                throw GPUCheckError("找不到指定的 SSH 私钥文件。")
            }
        }
    }

    func fetch(_ server: Server) async throws -> Snapshot {
        let data = try await run(server, script: Self.metricsScript)
        do {
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .secondsSince1970
            var result = try decoder.decode(Snapshot.self, from: data)
            // A local receipt timestamp keeps history chronological even when remote clocks differ.
            result.timestamp = Date()
            guard !result.gpus.isEmpty else { throw GPUCheckError("SSH 已连接，但服务器没有可读取的 NVIDIA GPU。") }
            return result
        } catch let error as GPUCheckError { throw error }
        catch { throw GPUCheckError("服务器返回的 GPU 数据无法解析。请确认远端 nvidia-smi 和 Python 3 工作正常。") }
    }

    func inspect(_ process: GPUProcess, server: Server) async throws -> ProcessDetails {
        guard process.pid > 0 else { throw GPUCheckError("进程 PID 无效。") }
        guard !process.type.hasPrefix("宿主机 /") else {
            throw GPUCheckError("该 NVIDIA PID 属于宿主机，当前 SSH 容器无法验证它与本地 PID 的对应关系。为避免显示同号的无关进程，请查看“设备句柄（容器）”候选进程，或通过宿主机 SSH 登录。")
        }
        let script = Self.processScript.replacingOccurrences(of: "__GPUCHECK_PID__", with: String(process.pid))
        let data = try await run(server, script: script)
        do { return try JSONDecoder().decode(ProcessDetails.self, from: data) }
        catch { throw GPUCheckError("无法解析进程详情。该进程可能已经退出，或当前用户没有读取权限。") }
    }

    func run(_ server: Server, script: String, timeout: TimeInterval = 18) async throws -> Data {
        try Self.validate(server)
        return try await Task.detached(priority: .utility) {
            try Self.runBlocking(server, script: script, timeout: timeout)
        }.value
    }

    private static func runBlocking(_ server: Server, script: String, timeout: TimeInterval) throws -> Data {
            let fm = FileManager.default
            let support = Self.applicationDirectory
            try fm.createDirectory(at: support, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            let knownHostsPath = support.appendingPathComponent("known_hosts").path
            let quotedKnownHosts = "\"" + knownHostsPath.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
            var arguments = [
                "-T", "-o", "ClearAllForwardings=yes", "-o", "ControlMaster=no", "-o", "ControlPath=none",
                "-o", "ConnectTimeout=10", "-o", "ConnectionAttempts=1", "-o", "ServerAliveInterval=5",
                "-o", "ServerAliveCountMax=2", "-o", "StrictHostKeyChecking=accept-new",
                "-o", "UserKnownHostsFile=\(quotedKnownHosts)",
                "-o", "LogLevel=ERROR", "-o", "NumberOfPasswordPrompts=1", "-o", "PermitLocalCommand=no",
                "-p", String(server.port)
            ]
            if !server.identityPath.isEmpty { arguments += ["-i", (server.identityPath as NSString).expandingTildeInPath] }
            var environment = ProcessInfo.processInfo.environment
            // Give launchd-started GUI apps the standard ssh-agent socket when available.
            let hasPassword = (try? SSHKeychain.read(account: server.id.uuidString)) != nil
            let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/GPUCheckAskPass").path
            if hasPassword && fm.isExecutableFile(atPath: helper) {
                arguments += ["-o", "BatchMode=no"]
                environment["SSH_ASKPASS"] = helper
                environment["SSH_ASKPASS_REQUIRE"] = "force"
                environment["DISPLAY"] = ":0"
                environment["GPUCHECK_KEYCHAIN_ACCOUNT"] = server.id.uuidString
            } else {
                arguments += ["-o", "BatchMode=yes"]
            }
            arguments += ["--", "\(server.user)@\(server.host)", "python3 -"]
            process.arguments = arguments
            process.environment = environment
            let input = Pipe(), output = Pipe(), errors = Pipe()
            process.standardInput = input; process.standardOutput = output; process.standardError = errors
            let collector = SSHOutputCollector()
            let readers = DispatchGroup()
            let timeoutState = SSHTimeoutState()
            try process.run()
            readers.enter()
            DispatchQueue.global(qos: .utility).async {
                collector.setOutput(output.fileHandleForReading.readDataToEndOfFile()); readers.leave()
            }
            readers.enter()
            DispatchQueue.global(qos: .utility).async {
                collector.setError(errors.fileHandleForReading.readDataToEndOfFile()); readers.leave()
            }
            let timer = DispatchWorkItem {
                if process.isRunning {
                    timeoutState.markTimedOut()
                    process.terminate()
                    DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                    }
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
            do { try input.fileHandleForWriting.write(contentsOf: Data(script.utf8)) }
            catch { /* A connection failure may close stdin before the script can be written. */ }
            try? input.fileHandleForWriting.close()
            process.waitUntilExit(); timer.cancel(); readers.wait()
            let (stdout, stderr) = collector.value()
            if timeoutState.timedOut { throw GPUCheckError("连接超时。请检查服务器地址、端口、网络或 SSH 登录配置。") }
            guard process.terminationStatus == 0 else {
                throw GPUCheckError(Self.friendlyError(String(data: stderr, encoding: .utf8) ?? "SSH 连接失败。"))
            }
            // Ignore banners produced by remote shell startup files; only accept a complete JSON record.
            if let text = String(data: stdout, encoding: .utf8), let line = text.split(separator: "\n").last(where: { $0.hasPrefix("{") }) {
                return Data(line.utf8)
            }
            throw GPUCheckError("SSH 已连接，但没有收到有效 GPU 数据。远端需要 Python 3 和 nvidia-smi。")
    }

    static func friendlyError(_ raw: String) -> String {
        if raw.contains("REMOTE HOST IDENTIFICATION HAS CHANGED") || raw.contains("Host key verification failed") {
            return "服务器主机密钥验证失败。为保护 SSH 连接，GPUCheck 已停止连接。请核对服务器是否重装或更换了主机密钥，再检查 ~/Library/Application Support/GPUCheck/known_hosts。"
        }
        if raw.contains("Permission denied") || raw.contains("Authentication failed") {
            return "SSH 身份验证失败。请检查用户名、密码或私钥；也可先在终端中确认此服务器能够登录。"
        }
        if raw.contains("Connection refused") { return "服务器拒绝连接。请确认 SSH 端口正确，且 SSH 服务正在运行。" }
        if raw.contains("Could not resolve hostname") { return "无法解析主机地址。请检查 IP、域名或 SSH 配置别名。" }
        if raw.contains("timed out") || raw.contains("No route to host") { return "连接超时或网络不可达。请检查网络和服务器地址。" }
        if raw.contains("nvidia-smi") { return "SSH 已连接，但 nvidia-smi 不可用。请确认远端已安装 NVIDIA 驱动，且当前用户能运行 nvidia-smi。" }
        if raw.contains("python3") { return "SSH 已连接，但远端找不到 Python 3。GPUCheck 需要 Python 3 读取 GPU 和进程信息。" }
        let clean = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? "SSH 连接失败，请检查连接配置。" : String(clean.prefix(900))
    }

    static let metricsScript = #"""
import os,sys,json,socket,subprocess,time,re,pwd,xml.etree.ElementTree as ET
try:
    result = subprocess.run(['nvidia-smi','-q','-x'], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=10)
    if result.returncode != 0:
        sys.stderr.write('nvidia-smi: '+result.stderr); sys.exit(3)
    root = ET.fromstring(result.stdout)
except Exception as e:
    sys.stderr.write('nvidia-smi: '+str(e)); sys.exit(3)
def text(node,path,default='N/A'):
    value=node.findtext(path)
    return value.strip() if value and value.strip() else default
def num(value):
    if value is None: return None
    m=re.match(r'^\s*(-?\d+(?:\.\d+)?)',value)
    return float(m.group(1)) if m else None
def metric(node,*paths):
    for path in paths:
        value=num(text(node,path))
        if value is not None:return value
    return None
def context(pid):
    base='/proc/'+str(pid)
    info={'user':'—','command':'','cwd':'—'}
    try:info['user']=pwd.getpwuid(os.stat(base).st_uid).pw_name
    except Exception:pass
    try:
        with open(base+'/cmdline','rb') as f:info['command']=f.read(32768).replace(b'\x00',b' ').decode('utf-8','replace').strip()
    except Exception:pass
    try:info['cwd']=os.readlink(base+'/cwd')
    except Exception:pass
    return info
# NVIDIA reports host PIDs. Container SSH sessions may only expose namespace-local PIDs.
# In that case list local processes with open device handles as explicitly labeled candidates.
host_pids=[int(num(text(item,'pid')) or 0) for gpu in root.findall('gpu') for item in gpu.findall('processes/process_info')]
namespace_limited=any(pid>0 and not os.path.isdir('/proc/'+str(pid)) for pid in host_pids)
local_devices={}
if namespace_limited:
    for local_pid in [p for p in os.listdir('/proc') if p.isdigit()][:8192]:
        try:
            devices=set()
            for fd in os.listdir('/proc/'+local_pid+'/fd')[:1024]:
                try:
                    target=os.readlink('/proc/'+local_pid+'/fd/'+fd)
                    if re.match(r'^/dev/nvidia[0-9]+$',target):devices.add(target)
                except OSError:pass
            if devices:local_devices[int(local_pid)]=devices
        except OSError:pass
out=[]
for index,gpu in enumerate(root.findall('gpu')):
    uuid=text(gpu,'uuid',str(index))
    details={}
    labels={
        '架构':'product_architecture','品牌':'product_brand','序列号':'serial','VBIOS':'vbios_version',
        'PCI 总线':'pci/pci_bus_id','PCIe 当前代数':'pci/pci_gpu_link_info/pcie_gen/current_link_gen',
        'PCIe 最大代数':'pci/pci_gpu_link_info/pcie_gen/max_link_gen',
        'PCIe 当前宽度':'pci/pci_gpu_link_info/link_widths/current_link_width',
        'PCIe 最大宽度':'pci/pci_gpu_link_info/link_widths/max_link_width',
        'PCIe 发送':'pci/tx_util','PCIe 接收':'pci/rx_util',
        '显存空闲':'fb_memory_usage/free','显存保留':'fb_memory_usage/reserved',
        'BAR1 显存总量':'bar1_memory_usage/total','BAR1 显存已用':'bar1_memory_usage/used',
        '显存控制器利用率':'utilization/memory_util','编码器利用率':'utilization/encoder_util',
        '解码器利用率':'utilization/decoder_util','JPEG 利用率':'utilization/jpeg_util',
        'OFA 利用率':'utilization/ofa_util','SM 时钟':'clocks/sm_clock',
        '视频时钟':'clocks/video_clock','最大图形时钟':'max_clocks/graphics_clock',
        '最大显存时钟':'max_clocks/mem_clock','ECC 当前状态':'ecc_mode/current_ecc',
        'ECC 待定状态':'ecc_mode/pending_ecc','MIG 模式':'mig_mode/current_mig',
        '计算模式':'compute_mode','持久模式':'persistence_mode','显示状态':'display_active',
        'GPU 关机温度':'temperature/gpu_temp_max_threshold','GPU 降频温度':'temperature/gpu_temp_slow_threshold',
        '显存温度':'temperature/memory_temp','板卡型号':'board_part_number',
        '固件版本':'gsp_firmware_version','GPU 电压':'voltage/graphics_volt',
        'ECC 已纠正总计':'ecc_errors/aggregate/correctable/total',
        'ECC 未纠正总计':'ecc_errors/aggregate/uncorrectable/total',
        '重映射已纠正行':'row_remapper/correctable_error','重映射未纠正行':'row_remapper/uncorrectable_error',
        '重映射失败':'row_remapper/remapping_failure_occurred',
        '功率默认上限':'gpu_power_readings/default_power_limit','功率最大上限':'gpu_power_readings/max_power_limit'
    }
    for label,path in labels.items():details[label]=text(gpu,path)
    # Preserve every reported leaf as a searchable raw field for detailed hardware inspection.
    def leaves(node,prefix=''):
        for child in node:
            path=prefix+'/'+child.tag if prefix else child.tag
            if len(child):leaves(child,path)
            elif child.text and child.text.strip():details['原始 / '+path]=child.text.strip()
    leaves(gpu)
    processes=[]
    for item in gpu.findall('processes/process_info'):
        pid=int(num(text(item,'pid')) or 0)
        if pid<=0:continue
        ctx=context(pid)
        visible=(not namespace_limited) and os.path.isdir('/proc/'+str(pid))
        if not visible:ctx={'user':'—','command':'','cwd':'—'}
        pname=text(item,'process_name')
        if not visible and pname in ('[Not Found]','N/A'):pname='宿主机进程（容器外）'
        processes.append(dict(id=uuid+':'+str(pid),pid=pid,name=pname,memoryUsed=metric(item,'used_memory'),gpuUUID=uuid,type=text(item,'type') if visible else '宿主机 / '+text(item,'type'),**ctx))
    if namespace_limited:
        details['进程可见性']='当前 SSH 位于容器内。设备句柄列表只表明进程打开了 GPU 设备，无法与宿主机显存记录精确对应。'
        device='/dev/nvidia'+text(gpu,'minor_number',str(index))
        for pid,devices in local_devices.items():
            if device in devices:
                ctx=context(pid)
                pname=ctx['command'].split(' ')[0] if ctx['command'] else '设备使用进程'
                processes.append(dict(id=uuid+':local:'+str(pid),pid=pid,name=pname,memoryUsed=None,gpuUUID=uuid,type='设备句柄（容器）',**ctx))
    out.append(dict(id=uuid,index=index,name=text(gpu,'product_name'),utilization=metric(gpu,'utilization/gpu_util'),
        memoryUsed=metric(gpu,'fb_memory_usage/used'),memoryTotal=metric(gpu,'fb_memory_usage/total'),
        temperature=metric(gpu,'temperature/gpu_temp'),powerDraw=metric(gpu,'gpu_power_readings/power_draw','power_readings/power_draw','gpu_power_readings/instant_power_draw','power_readings/instant_power_draw'),
        powerLimit=metric(gpu,'gpu_power_readings/power_limit','gpu_power_readings/current_power_limit','gpu_power_readings/enforced_power_limit','power_readings/power_limit','power_readings/current_power_limit','power_readings/enforced_power_limit'),fan=metric(gpu,'fan_speed'),
        clockGraphics=metric(gpu,'clocks/graphics_clock'),clockMemory=metric(gpu,'clocks/mem_clock'),
        pstate=text(gpu,'performance_state'),details=details,processes=processes))
print(json.dumps(dict(timestamp=time.time(),gpus=out,hostname=socket.gethostname(),driverVersion=text(root,'driver_version'),cudaVersion=text(root,'cuda_version')),ensure_ascii=False))
"""#

    static let processScript = #"""
import os,sys,json,pwd,shlex
pid=__GPUCHECK_PID__
base='/proc/'+str(pid)
notes=[]
def link(path):
    try:return os.readlink(path)
    except Exception as e:notes.append(str(e));return '—'
user='—';command='—';files=[]
try:user=pwd.getpwuid(os.stat(base).st_uid).pw_name
except Exception as e:notes.append(str(e))
try:
    with open(base+'/cmdline','rb') as f:args=f.read(65536).split(b'\x00')
    command=' '.join(shlex.quote(v.decode('utf-8','replace')) for v in args if v)
except Exception as e:notes.append(str(e))
cwd=link(base+'/cwd');executable=link(base+'/exe')
try:
    entries=os.listdir(base+'/fd')
    if len(entries)>512:notes.append('文件描述符超过 512 个，仅展示前 512 个。')
    for fd in entries[:512]:
        try:
            value=os.readlink(base+'/fd/'+fd)
            if value.startswith('/') and value not in files:files.append(value)
        except Exception:pass
except Exception as e:notes.append(str(e))
# Memory-mapped model/data files may remain mapped after their descriptors were closed.
try:
    with open(base+'/maps','r',errors='replace') as f:
        for line in f:
            parts=line.rstrip().split(None,5)
            if len(parts)==6 and parts[5].startswith('/') and parts[5] not in files:files.append(parts[5])
            if len(files)>=768:notes.append('文件清单已截断为 768 项。');break
except Exception as e:notes.append(str(e))
notes.insert(0,'当前打开的文件与内存映射文件；无法完整追溯已经关闭的模型或数据文件。')
if not os.path.isdir(base):notes.append('该 PID 在当前 SSH 进程命名空间中不可见：可能是容器外的宿主机 PID，或进程已经退出。若列表有“设备句柄（容器）”候选进程，可查看其本地 PID；无法精确对应宿主机显存。')
print(json.dumps(dict(pid=pid,user=user,command=command,cwd=cwd,executable=executable,files=sorted(files),note=' '.join(dict.fromkeys(notes))),ensure_ascii=False))
"""#
}

private final class SSHOutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var output = Data(), error = Data()
    func setOutput(_ value: Data) { lock.lock(); output = value; lock.unlock() }
    func setError(_ value: Data) { lock.lock(); error = value; lock.unlock() }
    func value() -> (Data, Data) { lock.lock(); defer { lock.unlock() }; return (output, error) }
}
private final class SSHTimeoutState: @unchecked Sendable {
    private let lock = NSLock(); private var value = false
    var timedOut: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func markTimedOut() { lock.lock(); value = true; lock.unlock() }
}

enum SSHKeychain {
    static let service = "GPUCheck.SSH"
    static func read(account: String) throws -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw GPUCheckError("无法从 macOS 钥匙串读取 SSH 密码。") }
        return String(data: data, encoding: .utf8)
    }
    static func save(_ password: String, account: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: Data(password.utf8)] as CFDictionary)
        if status == errSecItemNotFound {
            var entry = query; entry[kSecValueData as String] = Data(password.utf8)
            entry[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            guard SecItemAdd(entry as CFDictionary, nil) == errSecSuccess else { throw GPUCheckError("无法将 SSH 密码保存到 macOS 钥匙串。") }
        } else if status != errSecSuccess { throw GPUCheckError("无法更新 macOS 钥匙串中的 SSH 密码。") }
    }
    static func delete(account: String) {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account] as CFDictionary)
    }
}
