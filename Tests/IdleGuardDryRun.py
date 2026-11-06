"""Parse generated guard scripts and test PID/deadline logic without CUDA or real signals.
Usage: python3 IdleGuardDryRun.py /path/to/exported-python-scripts
"""
import ast
import io
import pathlib
import signal
import sys
import types
import re
import xml.etree.ElementTree as ET

folder = pathlib.Path(sys.argv[1])
for filename in ('runner.py', 'control.py', 'launch.py', 'preflight.py'):
    ast.parse((folder / filename).read_text(), filename=filename)
print('ALL_GENERATED_PYTHON_AST_OK')
source = (folder / 'runner.py').read_text()
tree = ast.parse(source)
functions = [n for n in tree.body if isinstance(n, ast.FunctionDef)]
namespace = {'__builtins__': __builtins__}
exec(compile(ast.fix_missing_locations(ast.Module(body=functions, type_ignores=[])), 'guard-functions', 'exec'), namespace)

token = '00C0C5DE-CFE7-4A88-A13B-D7692575447B'
runner_pid = 700
processes = {
    runner_pid: {'start': '10', 'group': runner_pid, 'kind': '--runner', 'token': token},
    701: {'start': '11', 'group': runner_pid, 'kind': '--worker', 'token': token},
    702: {'start': '12', 'group': runner_pid, 'kind': '--worker', 'token': 'foreign-token'},
    703: {'start': '13', 'group': 999, 'kind': '--worker', 'token': token},
}
kills = []

def fake_open(path, mode='r', *args, **kwargs):
    parts = str(path).split('/')
    if len(parts) >= 4 and parts[1] == 'proc':
        pid = int(parts[2])
        if pid not in processes:
            raise FileNotFoundError(path)
        proc = processes[pid]
        if parts[3] == 'stat':
            return io.StringIO(f'{pid} (python test) ' + ' '.join(['S'] + ['0'] * 18 + [proc['start']] + ['0'] * 20))
        if parts[3] == 'cmdline':
            argv = ['python3', f'/owned/{token}.py', proc['kind'], proc['token']]
            return io.BytesIO(('\0'.join(argv) + '\0').encode())
    raise FileNotFoundError(path)

fake_os = types.SimpleNamespace(
    listdir=lambda path: [str(pid) for pid in processes],
    getpgid=lambda pid: processes[pid]['group'],
    kill=lambda pid, sig: kills.append(('pid', pid, sig)),
    killpg=lambda group, sig: kills.append(('group', group, sig)),
)
namespace.update(os=fake_os, open=fake_open, token=token, sys=types.SimpleNamespace(argv=['runner.py', '--watchdog', token, 'missing.json', '100', str(runner_pid), '10'], exit=lambda code: (_ for _ in ()).throw(SystemExit(code))), signal=signal)
assert namespace['ident'](701, '11', '--worker')
assert not namespace['ident'](701, 'old-start-time', '--worker')
assert not namespace['ident'](702, '12', '--worker')
assert not namespace['ident'](701, '11', '--runner')
assert namespace['discover_workers']() == [{'pid': 701, 'start': '11'}]
print('TOKEN_PID_STARTTIME_NAMESPACE_GROUP_VALIDATION_OK')

# Busy memory and already-running idle programs do not block eligibility.
rows = [('GPU-a', 0, 79000, {900, 901}), ('GPU-b', 2, None, {900})]
assert namespace['initially_idle'](rows)
for bad in [[], [('GPU-a', None, 100, set())], [('GPU-a', 2.1, 79000, {900})], [('GPU-a', -1, None, set())], [('GPU-a', float('nan'), None, set())]]:
    assert not namespace['initially_idle'](bad)
print('REMOTE_UTILIZATION_ONLY_IGNORES_VRAM_AND_EXISTING_PROCESSES_OK')

existing = {'GPU-a': {900, 901}, 'GPU-b': {900}}
current = [('GPU-a', 100, 81000, {900, 901, 800}), ('GPU-b', 100, 81000, {900, 801})]
owned = namespace['added_gpu_pids'](current, existing)
assert owned == {'GPU-a': {800}, 'GPU-b': {801}}
assert namespace['owned_workers_present'](current, existing, owned)
# Existing idle processes may leave; new arrivals or missing owned workers stop our load.
assert namespace['owned_workers_present']([('GPU-a', 100, 81000, {800}), ('GPU-b', 100, 81000, {801})], existing, owned)
for bad in [
    [('GPU-a', 100, 81000, {900, 800, 999}), current[1]],
    [('GPU-a', 100, 81000, {900, 901}), current[1]],
    [current[0]],
]:
    assert not namespace['owned_workers_present'](bad, existing, owned)
try:
    namespace['added_gpu_pids']([current[0]], existing)
    raise AssertionError('Changed GPU list must fail')
except RuntimeError:
    pass
print('PREEXISTING_IDLE_PROCESSES_ALLOWED_NEW_PROCESS_AND_WORKER_EXIT_GUARDS_OK')

# Exercise the actual launcher XML parser with high/unknown VRAM and preexisting PIDs.
launch_source = (folder / 'launch.py').read_text()
launch_tree = ast.parse(launch_source)
launch_namespace = {'__builtins__': __builtins__, 're': re, 'ET': ET}
launch_functions = [n for n in launch_tree.body if isinstance(n, ast.FunctionDef)]
exec(compile(ast.fix_missing_locations(ast.Module(body=launch_functions, type_ignores=[])), 'launcher-functions', 'exec'), launch_namespace)
def xml_data(load_a='0 %', load_b='2 %', memory='79000 MiB'):
    return f'<nvidia_smi_log><gpu><uuid>GPU-a</uuid><utilization><gpu_util>{load_a}</gpu_util></utilization><fb_memory_usage><used>{memory}</used></fb_memory_usage><processes><process_info><pid>900</pid><type>C</type></process_info></processes></gpu><gpu><uuid>GPU-b</uuid><utilization><gpu_util>{load_b}</gpu_util></utilization><processes><process_info><pid>900</pid></process_info><process_info><pid>901</pid></process_info></processes></gpu></nvidia_smi_log>'.encode()
for payload in [xml_data(), xml_data(memory='N/A')]:
    launch_namespace['subprocess'] = types.SimpleNamespace(check_output=lambda *a, _data=payload, **k: _data)
    assert launch_namespace['idle_now']() == ['GPU-a', 'GPU-b']
for payload in [xml_data(load_a='3 %'), xml_data(load_b='N/A')]:
    launch_namespace['subprocess'] = types.SimpleNamespace(check_output=lambda *a, _data=payload, **k: _data)
    try:
        launch_namespace['idle_now']()
        raise AssertionError('Busy or unknown utilization must reject')
    except RuntimeError:
        pass
print('LAUNCHER_XML_HIGH_VRAM_EXISTING_PID_AND_UNKNOWN_VRAM_REGRESSION_OK')

# Run only the watchdog AST branch with mocked time/process files/signals.
# No subprocesses, CUDA, filesystem writes, sleeps, or real os.kill calls occur.
watchdog = next(n for n in tree.body if isinstance(n, ast.If) and ast.unparse(n.test) == "mode == '--watchdog'")
namespace.update(mode='--watchdog', deadline=100, time=types.SimpleNamespace(monotonic=lambda: 100, sleep=lambda seconds: None))
namespace['read_state'] = lambda: (_ for _ in ()).throw(FileNotFoundError('mock missing state'))
for runner_alive in (True, False):
    kills.clear()
    if not runner_alive:
        processes.pop(runner_pid, None)
    try:
        exec(compile(ast.fix_missing_locations(ast.Module(body=watchdog.body, type_ignores=[])), 'watchdog-branch', 'exec'), namespace)
    except SystemExit:
        pass
    assert ('pid', 701, signal.SIGKILL) in kills
    assert all(entry[1] not in (702, 703) for entry in kills)
    if runner_alive:
        assert ('group', runner_pid, signal.SIGKILL) in kills
    else:
        assert all(entry[0] != 'group' for entry in kills)
print('WATCHDOG_KILLS_UNRECORDED_OWN_WORKER_WITH_MISSING_STATE_AND_DEAD_RUNNER_OK')

launch = (folder / 'launch.py').read_text()
control = (folder / 'control.py').read_text()
assert 'deadline=time.monotonic()+300' in launch
assert launch.count('if os.path.exists(cancelpath)') >= 2
assert "if stop:" in control and 'os.open(cancelpath' in control
assert "if cancelled():raise RuntimeError('本轮启动已被取消。')" in source
assert 'while time.monotonic()<deadline and not cancelled()' in source
assert "if ident(pid,ticks,'--runner')" in control
print('LAUNCH_300_SECOND_BOUND_DURABLE_CANCEL_AND_SCOPED_STOP_GUARDS_OK')

# An 80 GiB card may have very little free memory. Plan against free bytes.
last_side=0
for free_mib in (32, 64, 128, 256, 320, 768, 4096, 32768):
    free=free_mib*1024**2
    side,reserve=namespace['memory_plan'](free)
    assert side is not None and 6*side*side+reserve<=free
    assert reserve<=512*1024**2
    assert side>=last_side
    last_side=side
assert namespace['memory_plan'](8*1024**2)[0] is None
assert namespace['memory_plan'](320*1024**2)[0]<8192
print('ADAPTIVE_MATRICES_AND_RESERVE_FOR_32MIB_TO_32GIB_FREE_VRAM_OK')

assert namespace['is_memory_error'](RuntimeError('CUDA error: out of memory'))
assert namespace['is_memory_error'](RuntimeError('CUBLAS_STATUS_ALLOC_FAILED'))
assert not namespace['is_memory_error'](RuntimeError('CUDA illegal memory access'))
print('CUDA_RUNTIME_MEMORY_ERRORS_CLASSIFIED_WITHOUT_SWALLOWING_OTHER_FAILURES_OK')
