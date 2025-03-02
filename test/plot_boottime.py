import os
import json
import numpy as np
import matplotlib.pyplot as plt

plt.style.use("dark_background")

RESULTS_DIS = "perf_results"

data = {}
for d in os.listdir(RESULTS_DIS):
    if "boottime" not in d:
        continue

    run_data = {"drive": [], "pmem": []}
    for path in os.listdir(f"{RESULTS_DIS}/{d}"):
        if "boottime" not in path:
            continue

        file_path = f"{RESULTS_DIS}/{d}/{path}"
        with open(file_path, "r") as file:
            line = file.readlines()[0]
            total_time = line.split("=")[1]
            if "drive" in file_path:
                run_data["drive"].append(float(total_time.strip()[:-2]))
            if "pmem" in file_path:
                run_data["pmem"].append(float(total_time.strip()[:-2]))

    run_data = {
        "drive": np.array(run_data["drive"]),
        "pmem": np.array(run_data["pmem"]),
    }
    data[f"{d}_drive"] = {"mean": np.mean(run_data["drive"]), "std": np.std(run_data["drive"])}
    data[f"{d}_pmem"] = {"mean": np.mean(run_data["pmem"]), "std": np.std(run_data["pmem"])}

width = 0.25 / len(data.keys())
multiplier = 0
fig, ax = plt.subplots(figsize=(16, 12))
for run_name, run_data in data.items():
    offset = width * multiplier
    multiplier += 1
    mean = run_data["mean"]
    std = run_data["std"]
    print(f"name: {run_name} mean: {mean} std: {std}")
    bar = ax.bar(offset, mean, yerr=std, width=width, label=run_name, ecolor="white")
    ax.bar_label(bar, labels=[f"{mean:.2f}/{std:.2f}"])

ax.set_ylabel("mean time/std: ms")
ax.legend(loc="upper left", ncols=len(data.keys()))
ax.set_xticks([0 + (width / 2) * (len(data.keys()) - 1)], ["boottime"])
plt.savefig("boottime.png")
plt.show()
