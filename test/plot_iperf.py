import os
import json
import numpy as np
import matplotlib.pyplot as plt

plt.style.use("dark_background")

RESULTS_DIS = "perf_results"

data = {}
for d in os.listdir(RESULTS_DIS):
    if "iperf" not in d:
        continue

    run_data = {"h2g": [], "g2h": []}
    for path in os.listdir(f"{RESULTS_DIS}/{d}"):
        if "iperf" not in path:
            continue

        file_path = f"{RESULTS_DIS}/{d}/{path}"
        with open(file_path, "r") as file:
            iperf_data = json.load(file)
            if iperf_data["start"]["test_start"]["reverse"] == 0:
                mode = "h2g"
            else:
                mode = "g2h"

            for interval in iperf_data["intervals"]:
                bps = interval["sum"]["bits_per_second"] / 8 / 1024 / 1024
                run_data[mode].append(bps)

    h2g_data = np.array(run_data["h2g"])
    h2g_mean = np.mean(h2g_data)
    h2g_std = np.std(h2g_data)

    g2h_data = np.array(run_data["g2h"])
    g2h_mean = np.mean(g2h_data)
    g2h_std = np.std(g2h_data)

    data[d] = {"mean": [h2g_mean, g2h_mean], "std": [h2g_std, g2h_std]}


width = 0.25 / len(data.keys())
multiplier = 0
label_loc = np.arange(2)
xticks = ["h2g", "g2h"]
fig, ax = plt.subplots()
for run_name, run_data in data.items():
    offset = width * multiplier
    multiplier += 1

    mean = run_data["mean"]
    std = run_data["std"]

    bar = ax.bar(
        label_loc + offset, mean, yerr=std, width=width, label=run_name, ecolor="white"
    )
    labels = [f"{m:.2f}/{s:.2f}" for m, s in zip(mean, std)]
    ax.bar_label(bar, labels=labels)

ax.set_ylabel("mean/std: MBps")
ax.legend(loc="upper left", ncols=len(data.keys()))
ax.set_xticks(label_loc + (width / 2) * (len(data.keys()) - 1), xticks)
plt.show()
