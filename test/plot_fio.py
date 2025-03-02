import os
import json
import numpy as np
import matplotlib.pyplot as plt

plt.style.use("dark_background")

RESULTS_DIS = "perf_results"
DEVICES = ["/dev/vdb", "/dev/pmem0"]
MODES = ["read", "write", "randread", "randwrite"]
BLOCK_SIZES = ["4K", "8K", "16K"]  # , "1M"]

data = {}
for d in os.listdir(RESULTS_DIS):
    if "fio" not in d:
        continue

    run_data = {}
    for device in DEVICES:
        run_data[device] = {}
        for mode in MODES:
            run_data[device][mode] = {}
            for bs in BLOCK_SIZES:
                run_data[device][mode][bs] = []

    for path in os.listdir(f"{RESULTS_DIS}/{d}"):
        if "fio" not in path:
            continue

        file_path = f"{RESULTS_DIS}/{d}/{path}"
        with open(file_path, "r") as file:
            try:
                fio_data = json.load(file)
            except:
                print(f"{file_path} is not a valid json")
                continue
            job = fio_data["jobs"][0]
            mode = job["job options"]["rw"]
            bs = job["job options"]["bs"]
            device = job["job options"]["filename"]
            if "read" in mode:
                run_data[device][mode][bs].append(job["read"]["bw"] / 1024)
            elif "write" in mode:
                run_data[device][mode][bs].append(job["write"]["bw"] / 1024)
            else:
                print(f"unknown mode: {mode}")

    for device in DEVICES:
        means = []
        stds = []
        for mode in MODES:
            for bs in BLOCK_SIZES:
                r_data = np.array(run_data[device][mode][bs])
                mean = np.mean(r_data)
                std = np.std(r_data)
                means.append(mean)
                stds.append(std)

        data[f"{d}_{device}"] = {
            "mean": means,
            "std": stds,
        }


for device in DEVICES:
    tests = len(data.keys()) / 2
    width = 0.75 / tests
    multiplier = 0
    label_loc = np.arange(len(MODES) * len(BLOCK_SIZES))
    xticks = [f"{m}/{bs}" for m in MODES for bs in BLOCK_SIZES]
    fig, ax = plt.subplots(figsize=(16, 14))
    for run_name, run_data in data.items():
        if device not in run_name:
            continue
        offset = width * multiplier
        multiplier += 1

        mean = run_data["mean"]
        std = run_data["std"]

        print(f"name: {run_name} mean: {mean} std: {std}")
        bar = ax.bar(
            label_loc + offset,
            mean,
            yerr=std,
            width=width,
            label=run_name,
            ecolor="white",
        )
        labels = [f"{m:.2f}/{s:.2f}" for m, s in zip(mean, std)]
        ax.bar_label(bar, labels=labels, rotation=90)

    ax.set_ylabel("mean/std: MBps")
    ax.legend(loc="upper left", ncols=tests)
    ax.set_xticks(label_loc + (width / 2) * (tests - 1), xticks, rotation=90)
    # plt.savefig(f"fio.png")
    plt.show()
