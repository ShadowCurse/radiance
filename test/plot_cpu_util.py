import os
import argparse
import numpy as np
import matplotlib.pyplot as plt

plt.style.use("dark_background")


class CpuLoad:
    def __init__(self, line: str):
        split = line.split(" ")
        self.user = int(split[1])
        self.nice = int(split[2])
        self.system = int(split[3])
        self.idle = int(split[4])
        self.iowait = int(split[5])
        self.irq = int(split[6])
        self.softirq = int(split[7])
        self.steal = int(split[8])
        self.guest = int(split[9])
        self.guest_nice = int(split[10])

    def work_time(self) -> int:
        return (
            self.user
            + self.nice
            + self.system
            + self.irq
            + self.softirq
            - self.guest
            - self.guest_nice
        )

    def total_time(self) -> int:
        return (
            self.work_time()
            + self.idle
            + self.iowait
            + self.guest
            + self.guest_nice
            + self.steal
        )

    # self is new, other is old
    def usage(self, other) -> float:
        def diff(a: int, b: int, default: int) -> int:
            if b < a:
                return a - b
            else:
                return default

        return (
            float(diff(self.work_time(), other.work_time(), 0))
            / float(diff(self.total_time(), other.total_time(), 1))
            * 100.0
        )


parser = argparse.ArgumentParser(description="Plot cpu utilization")
parser.add_argument("-p", "--path", type=str, help="Path to the `cpu_usage.txt` file")
parser.add_argument("-s", "--start", type=int, help="Start time to plot from")
parser.add_argument("-e", "--end", type=int, help="End time to plot up to")
args = parser.parse_args()

util = {}
with open(args.path, "r") as file:
    for line in file.readlines():
        line = line.replace("  ", " ")
        cpu = line.split(" ")[0]
        if cpu not in util:
            util[cpu] = []
        util[cpu].append(CpuLoad(line))


for cpu, u in util.items():
    util[cpu] = [b.usage(a) for (a, b) in zip(u, u[1:])]

fig, ax = plt.subplots(figsize=(21, 9))
x = np.arange(0.0, len(util["cpu"]), 1.0)

if args.start:
    start = args.start
else:
    start = 0

if args.end:
    end = args.end
else:
    end = len(util["cpu"])

for cpu, u in util.items():
    if cpu == "cpu":
        linewidth = 3
    else:
        linewidth = 1
    ax.plot(x[start:end], u[start:end], label=cpu, linewidth=linewidth)

ax.set_xlabel("seconds")
ax.set_ylabel("cpu util %")
ax.legend(loc="upper left", ncols=len(util.keys()))
plt.show()
