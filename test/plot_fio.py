import os
import json
import numpy as np
import matplotlib.pyplot as plt

plt.style.use('dark_background')

RESULTS_DIS = "perf_results"

data = {}
for d in os.listdir(RESULTS_DIS):
    if "fio" not in d:
        continue

    run_data = {}
    for path in os.listdir(f"{RESULTS_DIS}/{d}"):
        file_path = f"{RESULTS_DIS}/{d}/{path}"
        with open(file_path, "r") as file:
            fio_data = json.load(file)
            job = fio_data["jobs"][0]
            mode = job["job options"]["rw"]
            if "read" in mode:
                run_data[mode] = job["read"]["bw"] / 1024
            elif "write" in mode:
                run_data[mode] = job["write"]["bw"] / 1024
            else:
                print(f"unknown mode: {mode}")
    data[d] = run_data


width = 0.25 / len(data.keys())
multiplier = 0
label_loc = np.arange(4)
xticks = []
fig, ax = plt.subplots()
for run_name, run_data in data.items():
    offset = width * multiplier
    multiplier += 1

    xticks = run_data.keys()

    bar = ax.bar(label_loc + offset, run_data.values(), width, label=run_name)
    labels = [f"{v:.2f}" for v in run_data.values()]

    ax.bar_label(bar, labels=labels)

ax.set_ylabel("bw: MBps")
ax.legend(loc="upper left", ncols=len(data.keys()))
ax.set_xticks(label_loc + (width / 2) * (len(data.keys()) - 1), xticks)
plt.show()


