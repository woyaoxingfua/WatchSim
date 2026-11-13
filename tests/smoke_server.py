import subprocess, os, sys
from PIL import Image
import numpy as np

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LUA = os.environ.get("WATCHSIM_FACE", "")
FRAME = 336 * 480 * 4

if not LUA:
    sys.exit("Set WATCHSIM_FACE to a watch face directory first, "
             "e.g.:  export WATCHSIM_FACE=/path/to/face_dir")
os.makedirs(os.path.join(ROOT, "build"), exist_ok=True)

p = subprocess.Popen(
    [f"{ROOT}/build/cmake/sim_server", LUA, f"{LUA}/", "0"],
    stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)

def send(line):
    p.stdin.write((line + "\n").encode()); p.stdin.flush()

def readline():
    return p.stdout.readline().decode().strip()

print(readline())  # READY

# inject a full snapshot
for k, v in [("timeHour",18),("timeMinute",23),("timeSecond",37),
             ("dateMonth",11),("dateDay",11),("dateWeek",3),
             ("systemStatusBattery",71),("healthStepCount",7401)]:
    send(f"INJECT_INT {k} {v}")
    print(readline())

# request a frame
send("FRAME")
head = readline()
print(head)
n = int(head.split()[1])
raw = p.stdout.read(n)
assert len(raw) == n, f"short frame {len(raw)}"
a = np.frombuffer(raw, dtype=np.uint8).reshape(480, 336, 4)
Image.fromarray(a, "RGBA").save(f"{ROOT}/build/server_frame.png")
print("frame saved, dark px:", int((a[:,:,0] < 240).sum()))

# switch to AOD and request another frame
send("MODE 1"); print(readline())
send("FRAME"); head = readline(); print(head)
raw = p.stdout.read(int(head.split()[1]))
a = np.frombuffer(raw, dtype=np.uint8).reshape(480, 336, 4)
Image.fromarray(a, "RGBA").save(f"{ROOT}/build/server_aod.png")
print("aod frame saved")

send("QUIT"); print(readline())
p.wait(timeout=5)
print("exit code:", p.returncode)
err = p.stderr.read().decode()
if err: print("STDERR:", err[:500])
