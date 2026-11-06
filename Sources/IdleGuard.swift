import Foundation
import Combine

struct IdleGuardState {
    var enabled = false
    var status = "未启用"
    var detail = "可选功能：连续观察全部 GPU 空闲 5 小时后，运行最多 5 分钟的显存与计算负载。"
    var idleSeconds: TimeInterval = 0
    var idleSince: Date?
    var runningUntil: Date?
    var busy = false
    var isRunning = false
}

private struct IdleGuardRun: Codable {
    var token: String
    var server: Server
    var deadline: Date
}
private struct IdleGuardSetting: Codable {
    var enabled = false
    var idleSeconds: TimeInterval?
    var retryAfter: Date?
    var active: IdleGuardRun?
}
private struct IdleGuardRemoteReply: Decodable {
    var ok: Bool
    var status: String?
    var detail: String?
    var remaining: Double?
}

@MainActor
final class IdleGuardManager: ObservableObject {
    static let idleDuration: TimeInterval = 5 * 3600
    @Published var states: [UUID: IdleGuardState] = [:]
    private weak var store: MonitorStore?
    private let client = SSHClient()
    private let settingsURL: URL
    private var settings: [UUID: IdleGuardSetting] = [:]
    private var pollTask: Task<Void, Never>?
    private let requiredIdleDuration: TimeInterval
    private var lastProgressSave = Date.distantPast
    private var previousTick: Date?
    private var busySince: [UUID: Date] = [:]
    private var lastSample: [UUID: Date] = [:]

    init(store: MonitorStore, settingsURL: URL? = nil, idleDuration: TimeInterval = 5 * 3600) {
        self.store = store
        self.settingsURL = settingsURL ?? SSHClient.applicationDirectory.appendingPathComponent("idle-guard.json")
        requiredIdleDuration = idleDuration
        if let data = try? Data(contentsOf: self.settingsURL), let saved = try? JSONDecoder().decode([UUID: IdleGuardSetting].self, from: data) { settings = saved }
        for server in store.servers {
            let setting = settings[server.id] ?? IdleGuardSetting()
            var state = IdleGuardState(); state.enabled = setting.enabled; state.idleSeconds = max(0, setting.idleSeconds ?? 0)
            if let active = setting.active {
                state.isRunning = true; state.runningUntil = active.deadline; state.status = "正在核对远端任务"
                state.detail = "上次任务由远端独立看门狗限制为最多 5 分钟。"
            } else if setting.enabled {
                state.status = "等待新采样"; state.detail = "继续累计已保存的在线空闲时间。"
            }
            states[server.id] = state
        }
    }
    deinit { pollTask?.cancel() }

    func start() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard self != nil else { return }
                await self?.tick()
                do { try await Task.sleep(nanoseconds: 5_000_000_000) } catch { return }
            }
        }
    }

    func setEnabled(_ enabled: Bool, for server: Server) async throws {
        guard !(states[server.id]?.busy ?? false) else { throw GPUCheckError("正在处理此服务器的空闲保活设置，请稍候。") }
        if !enabled {
            var setting = settings[server.id] ?? IdleGuardSetting(); setting.enabled = false; settings[server.id] = setting
            change(server.id) { $0.enabled = false; $0.idleSince = nil; $0.status = "已关闭"; $0.detail = "不会再启动新的负载。" }
            try saveSettings()
            if setting.active != nil { try await stop(for: server) }
            return
        }
        let previousSetting = settings[server.id]
        let previouslyEnabled = states[server.id]?.enabled ?? false
        change(server.id) { $0.busy = true; $0.status = "正在检查运行环境" }
        defer { change(server.id) { $0.busy = false } }
        do {
            let reply = try await request(server, script: Self.preflightScript, timeout: 30)
            guard reply.ok else { throw GPUCheckError(reply.detail ?? "远端环境检查失败。") }
            var setting = settings[server.id] ?? IdleGuardSetting(); setting.enabled = true; settings[server.id] = setting
            try saveSettings()
            change(server.id) {
                $0.enabled = true; $0.idleSince = nil; $0.status = "等待连续空闲"
                $0.detail = "环境检查通过；全部 GPU 连续空闲 5 小时才会触发。断连或休眠暂停累计，检测到 GPU 忙碌时重新计时。"
            }
            lastSample[server.id] = nil
        } catch {
            settings[server.id] = previousSetting
            try? saveSettings()
            change(server.id) { $0.enabled = previouslyEnabled; $0.status = "启用失败"; $0.detail = error.localizedDescription }
            throw error
        }
    }

    func stop(for server: Server) async throws {
        guard !(states[server.id]?.busy ?? false) else { throw GPUCheckError("正在处理此服务器的任务，请稍候。") }
        guard let run = settings[server.id]?.active else {
            change(server.id) { $0.isRunning = false; $0.runningUntil = nil; $0.idleSince = nil }
            return
        }
        change(server.id) { $0.busy = true; $0.status = "正在停止远端负载" }
        defer { change(server.id) { $0.busy = false } }
        do {
            let reply = try await request(run.server, script: Self.controlScript(token: run.token, stop: true), timeout: 18)
            guard reply.ok else { throw GPUCheckError(reply.detail ?? "无法确认远端任务已停止。") }
            finish(server.id, detail: reply.detail ?? "已停止 GPUCheck 自己启动的负载。")
        } catch {
            change(server.id) { $0.status = "停止尚未确认"; $0.detail = "\(error.localizedDescription) 远端独立看门狗仍会在原定 5 分钟期限内结束任务。" }
            throw error
        }
    }

    static func isIdle(_ snapshot: Snapshot) -> Bool {
        guard !snapshot.gpus.isEmpty else { return false }
        return snapshot.gpus.allSatisfy { gpu in
            guard let load = gpu.utilization else { return false }
            return load.isFinite && load >= 0 && load <= 2
        }
    }

    static func thresholdReached(idleSince: Date?, now: Date) -> Bool {
        guard let idleSince, now >= idleSince else { return false }
        return now.timeIntervalSince(idleSince) >= idleDuration
    }

    private func tick() async {
        guard let store else { return }
        let now = Date()
        let interrupted = previousTick.map { now.timeIntervalSince($0) > 20 || now.timeIntervalSince($0) < 0 } ?? false
        previousTick = now
        let servers = store.servers
        // Recover/stop owned tasks even if their server entry was removed or edited.
        let activeIDs = settings.keys.filter { settings[$0]?.active != nil }
        for id in activeIDs where !(states[id]?.busy ?? false) {
            guard let run = settings[id]?.active else { continue }
            do {
                let shouldStop = !(settings[id]?.enabled ?? false) || !servers.contains { $0.id == id && $0 == run.server }
                let reply = try await request(run.server, script: Self.controlScript(token: run.token, stop: shouldStop), timeout: 18)
                guard settings[id]?.active?.token == run.token else { continue }
                guard reply.ok else { throw GPUCheckError(reply.detail ?? "无法确认远端任务状态。") }
                if reply.status == "running" || reply.status == "starting" {
                    change(id) { $0.isRunning = true; $0.idleSince = nil; $0.runningUntil = Date().addingTimeInterval(max(0, reply.remaining ?? 0)); $0.status = reply.status == "starting" ? "正在准备负载" : "正在运行 5 分钟负载"; $0.detail = reply.detail ?? "远端看门狗独立计时；发现外部计算进程会提前结束。" }
                } else { finish(id, detail: reply.detail ?? "本轮任务已结束。", retry: reply.status == "cancelled") }
            } catch {
                guard settings[id]?.active?.token == run.token else { continue }
                change(id) { $0.idleSince = nil; $0.status = "远端任务状态待确认"; $0.detail = "\(error.localizedDescription) 任务有独立 5 分钟期限。" }
            }
        }
        for server in servers where !activeIDs.contains(server.id) {
            let id = server.id
            if states[id] == nil { states[id] = IdleGuardState() }
            guard settings[id]?.enabled == true, settings[id]?.active == nil, !(states[id]?.busy ?? false) else { continue }
            guard !interrupted, store.errors[id] == nil, let snapshot = store.snapshots[id], now.timeIntervalSince(snapshot.timestamp) >= 0, now.timeIntervalSince(snapshot.timestamp) <= 20 else {
                change(id) { $0.idleSince = nil; $0.status = "计时已暂停，等待连接"; $0.detail = "已累计的在线空闲时间会保留，恢复有效采样后继续。" }
                lastSample[id] = nil
                busySince[id] = nil
                continue
            }
            let previous = lastSample[id]
            lastSample[id] = snapshot.timestamp
            guard Self.isIdle(snapshot) else {
                lastSample[id] = nil
                let validLoads = snapshot.gpus.compactMap(\.utilization).filter { $0.isFinite && $0 >= 0 }
                guard validLoads.count == snapshot.gpus.count else {
                    busySince[id] = nil
                    change(id) { $0.idleSince = nil; $0.status = "利用率读数不可用，暂停计时" }
                    continue
                }
                let firstBusy = busySince[id] ?? snapshot.timestamp
                busySince[id] = firstBusy
                let sustained = snapshot.timestamp.timeIntervalSince(firstBusy)
                if Self.shouldResetIdle(peakUtilization: validLoads.max() ?? 0, busySeconds: sustained) {
                    settings[id]?.idleSeconds = 0
                    settings[id]?.retryAfter = nil
                    change(id) { $0.idleSince = nil; $0.idleSeconds = 0; $0.status = "GPU 使用中"; $0.detail = "利用率达到 10%，或连续高于 2% 达 15 秒，重新累计空闲时间。" }
                } else {
                    change(id) { $0.idleSince = nil; $0.status = "检测到瞬时负载，暂停计时"; $0.detail = "短暂的小幅波动保留已累计时间，恢复 ≤2% 后继续。" }
                }
                continue
            }
            busySince[id] = nil
            if let retryAfter = settings[id]?.retryAfter, retryAfter > now {
                change(id) { $0.idleSince = nil; $0.status = "等待可用资源后重试" }
                continue
            }
            let credited = Self.creditedInterval(previous: previous, current: snapshot.timestamp)
            let elapsed = max(0, settings[id]?.idleSeconds ?? 0) + credited
            settings[id]?.idleSeconds = elapsed
            change(id) { $0.idleSeconds = elapsed; $0.idleSince = now.addingTimeInterval(-elapsed); $0.status = "正在累计在线空闲时间"; $0.detail = "累计满 5 小时触发；断连或休眠暂停计时，持续高于 2% 达 15 秒或达到 10% 时清零。" }
            if elapsed >= requiredIdleDuration { await launch(for: server) }
        }
        if now.timeIntervalSince(lastProgressSave) >= 15 {
            do { try saveSettings(); lastProgressSave = now }
            catch { for server in servers { change(server.id) { $0.detail = "计时保存失败：\(error.localizedDescription)" } } }
        }
    }

    static func shouldResetIdle(peakUtilization: Double, busySeconds: TimeInterval) -> Bool {
        peakUtilization >= 10 || busySeconds >= 15
    }

    static func creditedInterval(previous: Date?, current: Date) -> TimeInterval {
        guard let previous else { return 0 }
        let seconds = current.timeIntervalSince(previous)
        return seconds >= 0 && seconds <= 20 ? seconds : 0
    }

    private func launch(for server: Server) async {
        let token = UUID().uuidString
        let pendingDeadline = Date().addingTimeInterval(300)
        change(server.id) { $0.busy = true; $0.idleSince = nil; $0.status = "正在复核 GPU 空闲状态" }
        defer { change(server.id) { $0.busy = false } }
        var remoteAttempted = false
        do {
            var pending = settings[server.id] ?? IdleGuardSetting()
            pending.idleSeconds = 0
            pending.active = IdleGuardRun(token: token, server: server, deadline: pendingDeadline)
            settings[server.id] = pending
            try saveSettings()
            remoteAttempted = true
            let reply = try await request(server, script: Self.launchScript(token: token), timeout: 35)
            guard reply.ok else { throw GPUCheckError(reply.detail ?? "启动前复核失败。") }
            let deadline = Date().addingTimeInterval(max(0, reply.remaining ?? 300))
            settings[server.id]?.active?.deadline = deadline
            try saveSettings()
            change(server.id) { $0.isRunning = true; $0.runningUntil = deadline; $0.status = "正在准备负载"; $0.detail = "全部 GPU 同时运行；远端独立看门狗将在 5 分钟期限内清理 GPUCheck 进程。" }
        } catch {
            let stopped = remoteAttempted ? try? await request(server, script: Self.controlScript(token: token, stop: true), timeout: 18) : nil
            if !remoteAttempted || stopped?.ok == true {
                finish(server.id, detail: error.localizedDescription, retry: remoteAttempted)
            } else {
                change(server.id) { $0.isRunning = true; $0.runningUntil = pendingDeadline; $0.status = "启动状态待确认"; $0.detail = "\(error.localizedDescription) 已保留任务令牌，将继续核对；远端任务最多运行 5 分钟。" }
            }
        }
    }

    private func finish(_ id: UUID, detail: String, retry: Bool = false) {
        let shouldRetry = retry && settings[id]?.enabled == true
        settings[id]?.active = nil
        settings[id]?.idleSeconds = shouldRetry ? requiredIdleDuration : 0
        settings[id]?.retryAfter = shouldRetry ? Date().addingTimeInterval(60) : nil
        change(id) {
            $0.isRunning = false; $0.runningUntil = nil; $0.idleSince = nil
            $0.idleSeconds = settings[id]?.idleSeconds ?? 0
            $0.enabled = settings[id]?.enabled ?? false
            $0.status = shouldRetry ? "等待 60 秒后重试" : ($0.enabled ? "等待重新累计空闲" : "已关闭")
            $0.detail = detail
        }
        lastSample[id] = nil
        try? saveSettings()
    }
    private func change(_ id: UUID, _ body: (inout IdleGuardState) -> Void) {
        var state = states[id] ?? IdleGuardState(); body(&state); states[id] = state
    }
    private func saveSettings() throws {
        try FileManager.default.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(settings).write(to: settingsURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: settingsURL.path)
    }
    private func request(_ server: Server, script: String, timeout: TimeInterval) async throws -> IdleGuardRemoteReply {
        let data = try await client.run(server, script: script, timeout: timeout)
        do { return try JSONDecoder().decode(IdleGuardRemoteReply.self, from: data) }
        catch { throw GPUCheckError("无法解析空闲保活任务返回的信息。") }
    }

    static let preflightScript = #"""
import sys,json,subprocess,xml.etree.ElementTree as ET
sys.dont_write_bytecode=True
try:
    import torch
    root=ET.fromstring(subprocess.check_output(['nvidia-smi','-q','-x'],timeout=10))
    gpus=root.findall('gpu')
    if not torch.cuda.is_available():raise RuntimeError('PyTorch CUDA 不可用。')
    if not gpus or torch.cuda.device_count()!=len(gpus):raise RuntimeError('PyTorch 可访问 GPU 数量与 NVIDIA 报告不一致，不能启用全卡负载。')
    for i in range(len(gpus)):
        prop=torch.cuda.get_device_properties(i)
        if prop.total_memory<2*1024**3:raise RuntimeError('GPU 显存小于 2 GiB，无法保留安全余量。')
    print(json.dumps({'ok':True,'status':'ready','detail':'PyTorch CUDA 与全部 GPU 可访问性检查通过。'},ensure_ascii=False))
except Exception as e:print(json.dumps({'ok':False,'status':'unavailable','detail':'无法启用：远端 python3 需要可用的 PyTorch CUDA；'+str(e)},ensure_ascii=False))
"""#

    static func launchScript(token: String) -> String {
        guard UUID(uuidString: token) != nil else { return "import json; print(json.dumps({'ok':False,'status':'invalid','detail':'Invalid task token'}))" }
        let encoded = Data(remoteRunner.utf8).base64EncodedString()
        return #"""
import os,sys,json,time,base64,subprocess,xml.etree.ElementTree as ET,re
sys.dont_write_bytecode=True
token='TOKEN_VALUE'
source=base64.b64decode('SOURCE_VALUE')
def num(s):
    m=re.match(r'\s*([0-9.]+)',s or '')
    return float(m.group(1)) if m else None
def idle_now():
    root=ET.fromstring(subprocess.check_output(['nvidia-smi','-q','-x'],timeout=10))
    gpus=root.findall('gpu')
    if not gpus:raise RuntimeError('没有 GPU。')
    for g in gpus:
        load=num(g.findtext('utilization/gpu_util'))
        if load is None or not 0<=load<=2:raise RuntimeError('GPU 利用率已超过空闲阈值或无法读取，本轮取消。')
    return [g.findtext('uuid') for g in gpus]
def start_ticks(pid):
    data=open('/proc/'+str(pid)+'/stat').read()
    return data[data.rfind(')')+2:].split()[19]
try:
    devices=idle_now()
    import torch
    if not torch.cuda.is_available() or torch.cuda.device_count()!=len(devices):raise RuntimeError('PyTorch 无法访问全部 GPU。')
    devices=idle_now()
    folder=os.path.expanduser('~/.cache/GPUCheck/idle-guard');os.makedirs(folder,mode=0o700,exist_ok=True);os.chmod(folder,0o700)
    script=os.path.join(folder,token+'.py');statepath=os.path.join(folder,token+'.json');cancelpath=os.path.join(folder,token+'.cancel')
    if os.path.exists(cancelpath):raise RuntimeError('本轮启动已取消。')
    with open(script,'xb') as f:f.write(source)
    os.chmod(script,0o700)
    deadline=time.monotonic()+300
    args=[sys.executable,script,'--runner',token,statepath,str(deadline)]
    env=dict(os.environ);env['PYTHONDONTWRITEBYTECODE']='1'
    if os.path.exists(cancelpath):raise RuntimeError('本轮启动已取消。')
    runner=subprocess.Popen(args,stdin=subprocess.DEVNULL,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,start_new_session=True,env=env)
    ticks=start_ticks(runner.pid)
    watchdog=subprocess.Popen([sys.executable,script,'--watchdog',token,statepath,str(deadline),str(runner.pid),ticks],stdin=subprocess.DEVNULL,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,start_new_session=True,env=env)
    state={'token':token,'pid':runner.pid,'start':ticks,'watchdog':{'pid':watchdog.pid,'start':start_ticks(watchdog.pid)},'workers':[],'status':'starting','detail':'正在复核空闲状态并准备负载。','deadline':deadline,'devices':devices}
    temp=statepath+'.launch'
    with open(temp,'x') as f:json.dump(state,f,ensure_ascii=False)
    os.chmod(temp,0o600);os.replace(temp,statepath)
    print(json.dumps({'ok':True,'status':'starting','remaining':max(0,deadline-time.monotonic())},ensure_ascii=False))
except Exception as e:
    # If launch failed after spawning the session, only its verified child process is stopped.
    if 'runner' in locals():
        try:
            if runner.poll() is None and os.getpgid(runner.pid)==runner.pid:os.killpg(runner.pid,9)
        except OSError:pass
    if 'watchdog' in locals():
        try:watchdog.terminate()
        except OSError:pass
    print(json.dumps({'ok':False,'status':'cancelled','detail':str(e)},ensure_ascii=False))
"""#.replacingOccurrences(of: "TOKEN_VALUE", with: token).replacingOccurrences(of: "SOURCE_VALUE", with: encoded)
    }

    static func controlScript(token: String, stop: Bool) -> String {
        guard UUID(uuidString: token) != nil else { return "import json; print(json.dumps({'ok':False,'status':'invalid','detail':'Invalid task token'}))" }
        return #"""
import os,sys,json,time,signal
sys.dont_write_bytecode=True
token='TOKEN_VALUE';stop=STOP_VALUE
path=os.path.expanduser('~/.cache/GPUCheck/idle-guard/'+token+'.json')
# A durable token-specific cancellation marker also cancels an SSH launch still in preflight.
if stop:
    folder=os.path.dirname(path);os.makedirs(folder,mode=0o700,exist_ok=True);os.chmod(folder,0o700)
    cancelpath=os.path.join(folder,token+'.cancel')
    fd=os.open(cancelpath,os.O_WRONLY|os.O_CREAT,0o600);os.close(fd)
def ident(pid,ticks,mode):
    try:
        raw=open('/proc/'+str(pid)+'/stat').read();current=raw[raw.rfind(')')+2:].split()[19]
        cmd=open('/proc/'+str(pid)+'/cmdline','rb').read().split(b'\0')
        return current==str(ticks) and token.encode() in cmd and mode.encode() in cmd
    except OSError:return False
def discover_workers(group):
    found=[]
    for entry in os.listdir('/proc'):
        if not entry.isdigit():continue
        try:
            pid=int(entry);raw=open('/proc/'+entry+'/stat').read();start=raw[raw.rfind(')')+2:].split()[19]
            if ident(pid,start,'--worker') and os.getpgid(pid)==group:found.append({'pid':pid,'start':start})
        except OSError:pass
    return found
try:
    with open(path) as f:state=json.load(f)
    if state.get('token')!=token:raise RuntimeError('任务令牌不匹配，拒绝操作。')
    pid=state.get('pid',0);ticks=state.get('start','')
    alive=ident(pid,ticks,'--runner')
    workers=state.get('workers',[])+discover_workers(pid)
    if stop or (not alive and any(ident(w['pid'],w['start'],'--worker') for w in workers)):
        if alive and os.getpgid(pid)==pid:os.killpg(pid,signal.SIGTERM)
        for worker in workers:
            if ident(worker['pid'],worker['start'],'--worker'):
                try:os.kill(worker['pid'],signal.SIGTERM)
                except ProcessLookupError:pass
        end=time.monotonic()+2
        while time.monotonic()<end and ident(pid,ticks,'--runner'):time.sleep(.1)
        if ident(pid,ticks,'--runner') and os.getpgid(pid)==pid:os.killpg(pid,signal.SIGKILL)
        for worker in workers:
            if ident(worker['pid'],worker['start'],'--worker'):
                try:os.kill(worker['pid'],signal.SIGKILL)
                except ProcessLookupError:pass
        print(json.dumps({'ok':True,'status':'stopped','detail':'已停止令牌与进程启动时间均匹配的 GPUCheck 负载。'},ensure_ascii=False))
    elif not alive:
        print(json.dumps({'ok':True,'status':state.get('status','finished') if state.get('status') not in ('starting','running') else 'finished','detail':state.get('detail','本轮任务已结束。'),'remaining':0},ensure_ascii=False))
    else:print(json.dumps({'ok':True,'status':state.get('status','starting'),'detail':state.get('detail',''),'remaining':max(0,state['deadline']-time.monotonic())},ensure_ascii=False))
except FileNotFoundError:print(json.dumps({'ok':True,'status':'finished','detail':'没有仍在运行的 GPUCheck 任务。'}))
except Exception as e:print(json.dumps({'ok':False,'status':'unknown','detail':str(e)},ensure_ascii=False))
"""#.replacingOccurrences(of: "TOKEN_VALUE", with: token).replacingOccurrences(of: "STOP_VALUE", with: stop ? "True" : "False")
    }

    static let remoteRunner = #"""
import os,sys,json,time,signal,subprocess,re,xml.etree.ElementTree as ET
sys.dont_write_bytecode=True
mode,token,statepath=sys.argv[1:4]
deadline=float(sys.argv[4])
cancelpath=statepath[:-5]+'.cancel'
def cancelled():return os.path.exists(cancelpath)
def ticks(pid):
    raw=open('/proc/'+str(pid)+'/stat').read()
    return raw[raw.rfind(')')+2:].split()[19]
def ident(pid,start,kind):
    try:
        args=open('/proc/'+str(pid)+'/cmdline','rb').read().split(b'\0')
        return ticks(pid)==str(start) and token.encode() in args and kind.encode() in args
    except OSError:return False
def write(path,value):
    temp=path+'.tmp.'+str(os.getpid())
    with open(temp,'w') as f:json.dump(value,f,ensure_ascii=False)
    os.chmod(temp,0o600);os.replace(temp,path)
def read_state():
    with open(statepath) as f:s=json.load(f)
    if s.get('token')!=token:raise RuntimeError('Task token mismatch')
    return s
def gpu_state():
    root=ET.fromstring(subprocess.check_output(['nvidia-smi','-q','-x'],stderr=subprocess.DEVNULL,timeout=3))
    rows=[]
    def number(value):
        m=re.match(r'\s*([0-9.]+)',value or '')
        return float(m.group(1)) if m else None
    for gpu in root.findall('gpu'):
        pids={int(p.findtext('pid')) for p in gpu.findall('processes/process_info')}
        rows.append((gpu.findtext('uuid'),number(gpu.findtext('utilization/gpu_util')),number(gpu.findtext('fb_memory_usage/used')),pids))
    return rows
def initially_idle(rows):
    return bool(rows) and all(load is not None and 0<=load<=2 for _,load,_,_ in rows)
def added_gpu_pids(rows,existing):
    current={uuid:pids for uuid,_,_,pids in rows}
    if current.keys()!=existing.keys():raise RuntimeError('GPU 设备列表发生变化，本轮取消。')
    return {uuid:pids-existing[uuid] for uuid,pids in current.items()}
def owned_workers_present(rows,existing,owned):
    current={uuid:pids for uuid,_,_,pids in rows}
    return current.keys()==existing.keys()==owned.keys() and all(owned[uuid]<=pids and pids<=existing[uuid]|owned[uuid] for uuid,pids in current.items())
def is_memory_error(error):
    message=str(error).lower()
    return 'out of memory' in message or 'cublas_status_alloc_failed' in message

def memory_plan(free_bytes):
    mib=1024**2
    reserve=min(512*mib,max(16*mib,int(free_bytes*.05)))
    workspace=min(128*mib,max(8*mib,int(free_bytes*.10)))
    matrix_budget=max(0,free_bytes-reserve-workspace)
    sizes=(8192,6144,4096,3072,2048,1536,1024,768,512,256,128)
    side=next((size for size in sizes if 6*size*size<=matrix_budget),None)
    return side,reserve
def terminate_owned(state):
    workers=state.get('workers',[])
    for w in workers:
        if ident(w['pid'],w['start'],'--worker'):
            try:os.kill(w['pid'],signal.SIGTERM)
            except ProcessLookupError:pass
    until=min(deadline,time.monotonic()+1)
    while time.monotonic()<until and any(ident(w['pid'],w['start'],'--worker') for w in workers):time.sleep(.05)
    for w in workers:
        if ident(w['pid'],w['start'],'--worker'):
            try:os.kill(w['pid'],signal.SIGKILL)
            except ProcessLookupError:pass
def discover_workers():
    found=[]
    try:entries=os.listdir('/proc')
    except OSError:return found
    for candidate in entries:
        if not candidate.isdigit():continue
        try:
            pid=int(candidate);start=ticks(pid)
            if ident(pid,start,'--worker') and os.getpgid(pid)==int(sys.argv[5]):found.append({'pid':pid,'start':start})
        except OSError:pass
    return found
if mode=='--watchdog':
    runner_pid=int(sys.argv[5]);runner_start=sys.argv[6]
    # This independent process never imports torch and survives app/SSH/runner termination.
    while time.monotonic()<deadline:time.sleep(min(.25,max(0,deadline-time.monotonic())))
    try:state=read_state()
    except Exception:state={}
    try:
        if ident(runner_pid,runner_start,'--runner') and os.getpgid(runner_pid)==runner_pid:os.killpg(runner_pid,signal.SIGKILL)
    except OSError:pass
    for w in state.get('workers',[])+discover_workers():
        if ident(w['pid'],w['start'],'--worker'):
            try:os.kill(w['pid'],signal.SIGKILL)
            except ProcessLookupError:pass
    if state.get('token')==token and state.get('status') in ('starting','running'):
        state['status']='finished';state['detail']='远端 5 分钟看门狗期限已到，已清理 GPUCheck 负载。'
        try:write(statepath,state)
        except Exception:pass
    sys.exit(0)
if mode=='--worker':
    device_index=int(sys.argv[5]);ready=sys.argv[6]
    device=0 if os.environ.get('GPUCHECK_SINGLE_DEVICE')=='1' else device_index
    try:
        if cancelled():raise RuntimeError('Task was cancelled before allocation')
        os.environ['CUDA_MODULE_LOADING']='LAZY'
        import torch
        torch.set_num_threads(1);torch.cuda.set_device(device)
        # Load the small GEMM/runtime modules before measuring the allocatable budget.
        warm_a=torch.ones((128,128),device='cuda',dtype=torch.float16)
        warm_b=torch.ones_like(warm_a)
        warm_c=torch.mm(warm_a,warm_b);torch.cuda.synchronize()
        del warm_a,warm_b,warm_c
        torch.cuda.empty_cache()
        free_before,total=torch.cuda.mem_get_info(device)
        side,reserve=memory_plan(free_before)
        if side is None:raise RuntimeError('当前可用显存不足，稍后将自动重试。')
        a=b=c=None
        for n in (size for size in (8192,6144,4096,3072,2048,1536,1024,768,512,256,128) if size<=side):
            if cancelled() or time.monotonic()>=deadline:raise RuntimeError('Cancelled or deadline reached before allocation')
            try:
                a=torch.randn((n,n),device='cuda',dtype=torch.float16)
                b=torch.randn((n,n),device='cuda',dtype=torch.float16)
                c=torch.empty((n,n),device='cuda',dtype=torch.float16)
                torch.mm(a,b,out=c);torch.cuda.synchronize()
                break
            except RuntimeError as error:
                if not is_memory_error(error):raise
                a=b=c=None
                torch.cuda.empty_cache()
        if a is None:raise RuntimeError('当前可用显存无法容纳最小计算矩阵，稍后将自动重试。')
        padding=[]
        extra_headroom=min(64*1024**2,max(4*1024**2,int(free_before*.02)))
        headroom=reserve+extra_headroom
        while time.monotonic()<deadline and not cancelled():
            free,total=torch.cuda.mem_get_info(device)
            block_size=min(128*1024**2,max(0,free-headroom))
            if block_size<4*1024**2:break
            try:
                block=torch.empty((block_size,),device='cuda',dtype=torch.uint8)
                block.fill_(1);torch.cuda.synchronize()
                padding.append(block);del block
            except RuntimeError as error:
                if not is_memory_error(error):raise
                block=None
                torch.cuda.empty_cache();break
        free_after,total=torch.cuda.mem_get_info(device)
        while free_after<reserve and padding:
            padding.pop();torch.cuda.empty_cache()
            free_after,total=torch.cuda.mem_get_info(device)
        if free_after<reserve:
            a=b=c=None
            padding.clear();torch.cuda.empty_cache()
            raise RuntimeError('可用显存发生变化，已释放本轮分配，稍后将自动重试。')
        write(ready,{'ok':True,'pid':os.getpid(),'start':ticks(os.getpid()),'device':device_index,'matrixSide':n,'freeBeforeMiB':free_before//1024**2,'freeAfterMiB':free_after//1024**2,'paddingMiB':sum(block.numel() for block in padding)//1024**2})
        batch_count=max(8,min(256,8192//n*8))
        last_pressure_check=time.monotonic()
        while time.monotonic()<deadline and not cancelled():
            for _ in range(batch_count):torch.mm(a,b,out=c)
            torch.cuda.synchronize()
            if time.monotonic()-last_pressure_check>=2:
                free,total=torch.cuda.mem_get_info(device)
                while free<reserve and padding:
                    padding.pop();torch.cuda.empty_cache()
                    free,total=torch.cuda.mem_get_info(device)
                last_pressure_check=time.monotonic()
    except Exception as e:
        write(ready,{'ok':False,'detail':str(e)})
        sys.exit(2)
    finally:
        # Process exit releases its CUDA allocations; no other process is touched.
        pass
    sys.exit(0)
if mode!='--runner':sys.exit(2)
state={};children=[];interrupted=False
# SIGTERM causes orderly cleanup, then the independent watchdog remains as a final bound.
def stop_handler(signum,frame):
    global interrupted
    interrupted=True
signal.signal(signal.SIGTERM,stop_handler);signal.signal(signal.SIGINT,stop_handler)
try:
    limit=min(deadline,time.monotonic()+5)
    while not os.path.exists(statepath) and time.monotonic()<limit:time.sleep(.05)
    state=read_state()
    if cancelled():raise RuntimeError('本轮启动已被取消。')
    rows=gpu_state()
    if not initially_idle(rows) or [r[0] for r in rows]!=state['devices']:raise RuntimeError('启动前 GPU 已变忙或设备列表发生变化，本轮取消。')
    import torch
    if not torch.cuda.is_available() or torch.cuda.device_count()!=len(rows):raise RuntimeError('PyTorch 无法访问全部 GPU。')
    # Recheck after torch import, immediately before allocating any GPU workload.
    rows=gpu_state()
    if cancelled() or not initially_idle(rows):raise RuntimeError('分配显存前 GPU 利用率已超过空闲阈值，本轮取消。')
    # Existing idle processes and their VRAM are allowed; only new arrivals count as collisions.
    existing={uuid:pids for uuid,_,_,pids in rows}
    for index in range(len(rows)):
        if interrupted or cancelled() or time.monotonic()>=deadline:raise RuntimeError('任务已停止或期限已到。')
        ready=statepath+'.ready.'+str(index)
        worker_env=dict(os.environ,CUDA_VISIBLE_DEVICES=rows[index][0],GPUCHECK_SINGLE_DEVICE='1',CUDA_MODULE_LOADING='LAZY')
        proc=subprocess.Popen([sys.executable,__file__,'--worker',token,statepath,str(deadline),str(index),ready],stdin=subprocess.DEVNULL,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,env=worker_env)
        children.append((proc,ready))
        state['workers'].append({'pid':proc.pid,'start':ticks(proc.pid)})
        write(statepath,state)
    prepare_until=min(deadline,time.monotonic()+45)
    while True:
        if interrupted or cancelled() or time.monotonic()>=prepare_until:raise RuntimeError('负载准备超时或已被停止。')
        ready_values=[]
        for proc,path in children:
            if os.path.exists(path):
                with open(path) as f:ready_values.append(json.load(f))
        failed=[r.get('detail','Unknown worker error') for r in ready_values if not r.get('ok')]
        if failed:raise RuntimeError('GPU 负载启动失败：'+'; '.join(failed))
        if any(proc.poll() is not None for proc,_ in children):raise RuntimeError('GPU worker 提前退出，本轮取消。')
        current=gpu_state()
        added=added_gpu_pids(current,existing)
        if any(len(pids)>1 for pids in added.values()):raise RuntimeError('发现新加入的外部 NVIDIA 进程，已停止本轮负载。')
        if len(ready_values)==len(children):
            if any(len(pids)!=1 for pids in added.values()):raise RuntimeError('无法可靠确认全卡 GPUCheck 进程归属，本轮取消。')
            if len(set().union(*added.values()))!=len(children):raise RuntimeError('GPU 进程归属存在歧义，本轮取消。')
            owned=added;break
        time.sleep(.2)
    state['status']='running';state['workerMetrics']=ready_values;state['detail']='已按各卡可用显存调整矩阵和填充，全卡计算负载运行中。';write(statepath,state)
    while time.monotonic()<deadline and not interrupted and not cancelled():
        if any(proc.poll() is not None for proc,_ in children):raise RuntimeError('GPU worker 已退出，结束本轮。')
        current=gpu_state()
        if not owned_workers_present(current,existing,owned):raise RuntimeError('检测到新加入的外部 GPU 进程或维护进程退出，提前停止。')
        time.sleep(min(1,max(0,deadline-time.monotonic())))
    state['status']='finished';state['detail']='已完成本轮 5 分钟上限的负载。' if not interrupted else '已按请求停止 GPUCheck 负载。'
except Exception as e:
    state['status']='cancelled';state['detail']=str(e)
finally:
    terminate_owned(state)
    for proc,_ in children:
        try:proc.wait(timeout=.2)
        except Exception:pass
    if state.get('token')==token:
        try:write(statepath,state)
        except Exception:pass
"""#
}
