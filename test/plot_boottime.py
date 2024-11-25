import os
import json
import numpy as np
import matplotlib.pyplot as plt

plt.style.use('dark_background')

RESULTS_DIS = "perf_results"

data = {}
for d in os.listdir(RESULTS_DIS):
    if "boottime" not in d:
        continue

    run_data = {}
    for path in os.listdir(f"{RESULTS_DIS}/{d}"):
        file_path = f"{RESULTS_DIS}/{d}/{path}"
        with open(file_path, "r") as file:
            line = file.readlines()[0]
            total_time = line.split("=")[1]
            data[d] = float(total_time.strip()[:-2])

width = 0.25 / len(data.keys())
multiplier = 0
fig, ax = plt.subplots()
for run_name, run_data in data.items():
    offset = width * multiplier
    multiplier += 1
    bar = ax.bar(offset, run_data, width, label=run_name)
    ax.bar_label(bar, labels=[f"{run_data:.2f}"])

ax.set_ylabel("time: ms")
ax.legend(loc="upper left", ncols=len(data.keys()))
ax.set_xticks([0 + (width / 2) * (len(data.keys()) - 1)], ["boottime"])
plt.show()
