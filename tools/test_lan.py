"""Run actual ENet host/client processes, for both possible host roles."""
import subprocess, pathlib, time, tempfile, socket, threading, heapq
class ImpairedLink:
    """Real UDP proxy: 60 ms each way and deterministic 1-in-7 packet loss."""
    def __init__(self, listen, target):
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.sock.bind(('127.0.0.1', listen))
        self.sock.settimeout(0.005)
        self.target = ('127.0.0.1', target)
        self.stopped = threading.Event()
        self.thread = threading.Thread(target=self.run, daemon=True)
        self.thread.start()

    def run(self):
        client = None
        queue = []
        serial = 0
        while not self.stopped.is_set():
            try:
                data, source = self.sock.recvfrom(65536)
                if source == self.target:
                    destination = client
                else:
                    client = source
                    destination = self.target
                serial += 1
                if destination and serial % 7:
                    heapq.heappush(queue, (time.monotonic()+0.06, serial, data, destination))
            except socket.timeout:
                pass
            while queue and queue[0][0] <= time.monotonic():
                _, _, data, destination = heapq.heappop(queue)
                self.sock.sendto(data, destination)

    def close(self):
        self.stopped.set()
        self.thread.join(timeout=1)
        self.sock.close()

root = pathlib.Path(__file__).resolve().parents[1]
for index, role in enumerate(['kate', 'sarah', 'kate', 'sarah', 'kate', 'sarah']):
    port = 24670 + index
    proxy = ImpairedLink(port+20, port) if index >= 4 else None
    join_port = port+20 if proxy else port
    with tempfile.TemporaryDirectory(prefix='mihoyo-lan-') as tmp:
        logs = [open(pathlib.Path(tmp)/name, 'w+') for name in ['host.log','client.log']]
        common = ['godot','--headless','--path',str(root),'--','--auto-ready','--lan-test',f'--port={port}']
        host = subprocess.Popen(common+['--host',f'--role={role}'],stdout=logs[0],stderr=subprocess.STDOUT)
        client = None
        try:
            time.sleep(0.8)
            client_args = [f'--port={join_port}' if item.startswith('--port=') else item for item in common]
            client = subprocess.Popen((['godot','--max-fps','15']+client_args[1:] if index >= 2 else client_args)+['--join=127.0.0.1'],stdout=logs[1],stderr=subprocess.STDOUT)
            client_code = client.wait(timeout=30)
            host_code = host.wait(timeout=5)
        finally:
            if proxy: proxy.close()
            for process in [host,client]:
                if process and process.poll() is None:
                    process.kill(); process.wait()
            for log in logs:
                log.flush(); log.seek(0)
                output=log.read()
                print(output)
                log.close()
        if client_code or host_code:
            raise SystemExit(f'LAN test failed for host role {role}: host={host_code}, client={client_code}')
        print(f'LAN TWO-PROCESS TEST PASSED (host plays {role}, guest FPS={15 if index >= 2 else "default"}, impaired link={bool(proxy)})')

# Matching code/assets are required before starting a shared world.
with tempfile.TemporaryDirectory(prefix='mihoyo-lan-mismatch-') as tmp:
    logs = [open(pathlib.Path(tmp)/name, 'w+') for name in ['host.log','client.log']]
    common = ['godot','--headless','--path',str(root),'--','--auto-ready','--lan-test','--lan-test-mismatch','--port=24674']
    host = subprocess.Popen(common+['--host'],stdout=logs[0],stderr=subprocess.STDOUT)
    client = None
    try:
        time.sleep(0.8)
        client = subprocess.Popen(common+['--join=127.0.0.1'],stdout=logs[1],stderr=subprocess.STDOUT)
        client_code = client.wait(timeout=15)
        host_code = host.wait(timeout=5)
    finally:
        for process in [host,client]:
            if process and process.poll() is None: process.kill(); process.wait()
        for log in logs:
            log.flush(); log.seek(0); print(log.read()); log.close()
    if client_code or host_code: raise SystemExit('Version mismatch test failed')
result = subprocess.run(['godot','--headless','--path',str(root),'--','--auto-ready','--lan-test','--lan-test-failure','--port=24675','--join=127.0.0.1'],capture_output=True,text=True,timeout=15)
print(result.stdout+result.stderr)
if result.returncode: raise SystemExit('Connection failure test failed')
print('ALL LAN TESTS PASSED')
