import os
import json
import numpy as np
import matplotlib.pyplot as plt

plt.style.use('dark_background')

RESULTS_DIS = "perf_results"

data = {}
for d in os.listdir(RESULTS_DIS):
    if "iperf" not in d:
        continue

    run_data = {}
    for path in os.listdir(f"{RESULTS_DIS}/{d}"):
        file_path = f"{RESULTS_DIS}/{d}/{path}"
        with open(file_path, "r") as file:
            iperf_data = json.load(file)
            if iperf_data["start"]["test_start"]["reverse"] == 0:
                mode = "h2g"
            else:
                mode = "g2h"

            run_data[mode] = []
            for interval in iperf_data["intervals"]:
                bps = interval["sum"]["bits_per_second"] / 8 / 1024 / 1024
                run_data[mode].append(bps)

    data[d] = run_data


width = 0.25 / len(data.keys())
multiplier = 0
label_loc = np.arange(2)
xticks = []
fig, ax = plt.subplots()
for run_name, run_data in data.items():
    offset = width * multiplier
    multiplier += 1

    xticks = run_data.keys()

    y = [np.mean(np.array(m)) for m in run_data.values()]
    bar = ax.bar(label_loc + offset, y, width, label=run_name)

    labels = [f"{v:.2f}" for v in y]
    ax.bar_label(bar, labels=labels)

ax.set_ylabel("MBs")
ax.legend(loc="upper left", ncols=len(data.keys()))
ax.set_xticks(label_loc + (width / 2) * (len(data.keys()) - 1), xticks)
plt.show()


