"""Read native WebSocket failure messages during the browser matrix."""
from pathlib import Path
import json
import subprocess


class ConsoleTrace:
    def __init__(self, work, wait):
        self.work = work
        self.processes = []
        self.stopped = False
        script = Path(__file__).with_suffix('.d')
        try:
            for line in subprocess.check_output(['ps', '-axo', 'pid=,comm='], text=True).splitlines():
                pid, executable = line.strip().split(None, 1)
                name = Path(executable).name
                if name not in ['Safari', 'com.apple.WebKit.WebContent']:
                    continue
                path = work / ('console-' + pid + '.log')
                output = path.open('w')
                process = subprocess.Popen(['sudo', '-n', 'dtrace', '-xmangled', '-Z', '-q', '-p', pid, '-s', str(script)], stdout=output, stderr=subprocess.STDOUT, start_new_session=True)
                self.processes.append((process, output, path, name))
                wait(lambda: 'READY ' in path.read_text() or process.poll() is not None, 'DTrace startup')
                assert process.poll() is None, path.read_text()
            assert self.processes, 'No Safari or WebKit process is available for native console tracing'
        except Exception:
            self.stop()
            raise

    def stop(self):
        if self.stopped:
            return
        self.stopped = True
        for process, output, path, name in self.processes:
            if process.poll() is None:
                subprocess.run(['sudo', '-n', '/bin/kill', '-INT', '-' + str(process.pid)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    subprocess.check_call(['sudo', '-n', '/bin/kill', '-TERM', '-' + str(process.pid)])
                    process.wait(timeout=10)
            output.close()

    def report(self):
        self.stop()
        logs = [(name, path.read_text()) for _, _, path, name in self.processes]
        result = {'genericSendFailure': any('Failed to send WebSocket handshake' in text for _, text in logs),
                  'probeErrors': [name for name, text in logs if 'error on enabled probe' in text],
                  'wk1PositiveControl': any(name == 'Safari' and 'Upgrade' in text for name, text in logs),
                  'wk2PositiveControl': any(name == 'com.apple.WebKit.WebContent' and 'Upgrade' in text for name, text in logs)}
        (self.work / 'console-check.json').write_text(json.dumps(result, indent=2))
        return result
