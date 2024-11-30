import os
import argparse
import numpy as np
import matplotlib.pyplot as plt

plt.style.use("dark_background")


parser = argparse.ArgumentParser(description="Plot resource utilization")
parser.add_argument(
    "-p", "--path", type=str, help="Path to the `resource_usage.txt` file"
)
parser.add_argument("-s", "--start", type=int, help="Start time to plot from")
parser.add_argument("-e", "--end", type=int, help="End time to plot up to")
parser.add_argument("-v", "--values", type=str, help="Values to plot")
args = parser.parse_args()

util = {}
with open(args.path, "r") as file:
    for line in file.readlines():
        split = line.split(" ")
        if split[0] not in util:
            util[split[0]] = []

        if len(split) == 2:
            util[split[0]].append(int(split[1]))
        elif len(split) == 3:
            util[split[0]].append(int(split[1]) * 1000 + int(split[2]))


fig, ax = plt.subplots(figsize=(21, 9))
x = np.arange(0.0, len(util["utime"]), 1.0)

if args.start:
    start = args.start
else:
    start = 0

if args.end:
    end = args.end
else:
    end = len(util["utime"])

for name, values in util.items():
    if args.values and name not in args.values:
        continue

    linewidth = 2
    ax.plot(x[start:end], values[start:end], label=name, linewidth=linewidth)

ax.set_xlabel("iteration")
ax.set_ylabel("resource")
ax.legend(loc="upper left", ncols=len(util.keys()) % 10)
plt.show()
