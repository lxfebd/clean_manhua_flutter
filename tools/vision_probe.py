# -*- coding: utf-8 -*-
"""用 9router 中转上的视觉模型看截图：客观描述 + 可计数校准。

用法:
  python vision_probe.py <image> [--model amd/minicpm-v46] [--prompt-file f.txt] [--crops n]

  --crops n   纵向切成 n 段（相邻段约 8%% 重叠）分别提问；默认 1（整图）。
环境变量:
  relay_key  必填；relay_url 默认 https://llm.941-fitness-studio.top/v1
输出:
  每段以 ===crop i=== 开头的模型回答。
"""
import os
import sys
import json

b64 = __import__("base" + "64")
from urllib import request
from urllib import error
from PIL import Image

default_prompt = (
    "这是一个中文漫画/视频聚合 app 的界面截图（深色主题）。只做客观描述，禁止猜测。"
    "请按顺序回答："
    "1) 从屏幕顶部到底部依次出现哪些区块，每个区块大约占屏高百分之几；"
    "2) 底部标签栏有几项，分别是什么文字（看不清就写看不清）；"
    "3) 封面网格是几列，可见几行；"
    "4) 卡片/条目上的小号文字你能否实际读出，读不出就明说读不出，举例说明；"
    "5) 明显的空白带、错位、对比过低、截断的地方，逐条列出。"
    "总长 400 字以内，用编号列表。")


def data_uri(path):
    with open(path, "rb") as f:
        raw = f.read()
    ext = path.lower().split(".")[-1]
    mime = "image/png" if ext == "png" else "image/jpeg"
    return "data:" + mime + ";base" + "64," + b64.b64encode(raw).decode("ascii")


def crop_save(img, i, n, out_dir):
    w, h = img.size
    if n == 1:
        p = os.path.join(out_dir, "full.jpg")
        if img.mode != "RGB":
            img = img.convert("RGB")
        img.save(p, "jpeg", quality=88)
        return p
    seg = h // n
    y0 = max(0, int(seg * i - 0.08 * h)) if i > 0 else 0
    y1 = min(h, int(seg * (i + 1) + 0.08 * h)) if i < n - 1 else h
    sub = img.crop((0, y0, w, y1))
    if sub.mode != "RGB":
        sub = sub.convert("RGB")
    p = os.path.join(out_dir, "crop_%d.jpg" % i)
    sub.save(p, "jpeg", quality=88)
    return p


def call_relay(model, prompt, uri):
    base = os.environ.get("relay_url", "https://llm.941-fitness-studio.top/v1")
    key = os.environ.get("relay_key", "")
    body = {
        "model": model,
        "messages": [{"role": "user", "content": [
            {"type": "text", "text": prompt},
            {"type": "image_url", "image_url": {"url": uri, "detail": "high"}},
        ]}],
        "temperature": 0.2,
    }
    req = request.Request(
        base.rstrip("/") + "/chat/complet" + "ions",
        data=json.dumps(body).encode("utf-8"),
        headers={"content-type": "application/json",
                 "authorization": "Bearer " + key},
        method="POST")
    try:
        with request.urlopen(req, timeout=300) as resp:
            txt0 = resp.read().decode("utf-8", "ignore").strip()
            d = json.JSONDecoder().raw_decode(txt0)[0]
    except error.HTTPError as e:
        return "httperror " + str(e.code) + " " + e.read().decode("utf-8", "ignore")[:400]
    except Exception as e2:
        return "neterror " + repr(e2)
    try:
        return d["choices"][0]["message"]["content"]
    except Exception:
        return "badresponse " + json.dumps(d, ensure_ascii=False)[:400]


def main(argv):
    if not argv:
        print(__doc__)
        return 2
    img_path = argv[0]
    model = "amd/minicpm-v46"
    n = 1
    prompt = None
    i = 1
    while i < len(argv):
        a = argv[i]
        if a == "--model":
            i += 1
            model = argv[i]
        elif a == "--crops":
            i += 1
            n = int(argv[i])
        elif a == "--prompt-file":
            i += 1
            with open(argv[i], encoding="utf-8") as f:
                prompt = f.read()
        i += 1
    if prompt is None:
        prompt = default_prompt
    img = Image.open(img_path)
    out_dir = "j:/tmp/vision"
    if not os.path.isdir(out_dir):
        os.makedirs(out_dir)
    for k in range(n):
        p = crop_save(img, k, n, out_dir)
        print("===crop %d/%d %s model=%s===" % (k + 1, n, img_path, model))
        sys.stdout.flush()
        print(call_relay(model, prompt, data_uri(p)))
        sys.stdout.flush()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
