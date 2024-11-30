import os
import json
import numpy as np
import matplotlib.pyplot as plt

plt.style.use("dark_background")

RESULTS_DIS = "perf_results"

data = {}
for d in os.listdir(RESULTS_DIS):
    if "fio" not in d:
        continue

    run_data = {
        "read": [],
        "write": [],
        "randread": [],
        "randwrite": [],
    }
    for path in os.listdir(f"{RESULTS_DIS}/{d}"):
        if "fio" not in path:
            continue

        file_path = f"{RESULTS_DIS}/{d}/{path}"
        with open(file_path, "r") as file:
            fio_data = json.load(file)
            job = fio_data["jobs"][0]
            mode = job["job options"]["rw"]
            if "read" in mode:
                run_data[mode].append(job["read"]["bw"] / 1024)
            elif "write" in mode:
                run_data[mode].append(job["write"]["bw"] / 1024)
            else:
                print(f"unknown mode: {mode}")

    read_data = np.array(run_data["read"])
    read_mean = np.mean(read_data)
    read_std = np.std(read_data)

    write_data = np.array(run_data["write"])
    write_mean = np.mean(write_data)
    write_std = np.std(write_data)

    randread_data = np.array(run_data["randread"])
    randread_mean = np.mean(randread_data)
    randread_std = np.std(randread_data)

    randwrite_data = np.array(run_data["randwrite"])
    randwrite_mean = np.mean(randwrite_data)
    randwrite_std = np.std(randwrite_data)

    data[d] = {
        "mean": [read_mean, write_mean, randread_mean, randwrite_mean],
        "std": [read_std, write_std, randread_std, randwrite_std],
    }


width = 0.75 / len(data.keys())
multiplier = 0
label_loc = np.arange(4)
xticks = ["read", "write", "randread", "randwrite"]
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
