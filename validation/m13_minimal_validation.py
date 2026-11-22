#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""M13 智能判定最小化验证。

默认使用确定性 mock，不产生真实 token 消耗；设置 --endpoint / --api-key / --model
后可调用任意兼容 OpenAI Chat Completions 协议的服务做真实验证。
"""

import argparse
import hashlib
import json
import os
import sys
import time
import urllib.request

CATEGORIES = [
    {"id": "bid", "name": "招标公告", "keywords": ["招标", "采购", "中标"]},
    {"id": "policy", "name": "政策文件", "keywords": ["政策", "通知", "办法"]},
    {"id": "internal", "name": "内部通知", "keywords": ["内部", "会议", "人事"]},
]
CAT_BY_ID = {c["id"]: c for c in CATEGORIES}
CAT_ORDER = {c["id"]: i for i, c in enumerate(CATEGORIES)}

PAGES = {
    "p1": {"title": "采购公告", "category_ids": ["bid"]},
    "p2": {"title": "政策发布", "category_ids": ["policy"]},
    "p3": {"title": "综合信息", "category_ids": ["bid", "policy", "internal"]},
    "p4": {"title": "内部通知", "category_ids": ["internal"]},
}

# 前 4 条用于制造歧义，后 6 条用于验证“规则优先、零调用”。
RAW_ATTACHMENTS = [
    {"page": "p1", "filename": "2026年招标公告.pdf"},
    {"page": "p2", "filename": "政策解读.pdf"},
    {"page": "p3", "filename": "关于开展招标采购政策培训的通知.pdf"},
    {"page": "p3", "filename": "附件1.pdf"},
    {"page": "p1", "filename": "中标结果公示.pdf"},
    {"page": "p4", "filename": "会议纪要.pdf"},
    # 与第 3 条完全相同，用于验证缓存 + 增量
    {"page": "p3", "filename": "关于开展招标采购政策培训的通知.pdf"},
    {"page": "p3", "filename": "采购政策问答.pdf"},
    {"page": "p1", "filename": "招标文件.pdf"},
    {"page": "p2", "filename": "政策通知.pdf"},
    {"page": "p4", "filename": "内部会议纪要.pdf"},
    {"page": "p1", "filename": "采购需求.pdf"},
    {"page": "p2", "filename": "办法解读.pdf"},
    {"page": "p4", "filename": "人事通知.pdf"},
]


def rule_candidates(att):
    """按 PRD R-M5-05 前三步返回候选分类与原因。"""
    page = PAGES[att["page"]]
    ids = [cid for cid in page["category_ids"] if cid in CAT_BY_ID]
    if len(ids) <= 1:
        return ids, "页面唯一"
    filename = att["filename"].lower()
    hits = [
        cid for cid in ids
        if any(k.lower() in filename for k in CAT_BY_ID[cid]["keywords"])
    ]
    if hits:
        return hits, "关键词命中"
    return ids, "关键词无命中"


def build_prompt(batch):
    """只发送文件名、页面标题、候选分类名称与关键词。"""
    union = []
    for item in batch:
        for cid in item["candidates"]:
            if cid not in union:
                union.append(cid)

    lines = [
        "你是附件分类器。只输出 JSON，不要解释，也不要思考。",
        '输出格式：{"results":[{"i":1,"category_id":"bid"}]}；无法判断用 null。',
        "只能从每个附件给出的候选分类中选择。",
        "每个附件独立判断，不要参考同批其他附件的分类结果。",
        "如果文件名和页面标题不足以判断，category_id 用 null，不要猜测。",
        "候选分类：",
    ]
    for cid in union:
        cat = CAT_BY_ID[cid]
        lines.append("- %s | %s | 关键词：%s" % (
            cid, cat["name"], ",".join(cat["keywords"][:10])
        ))
    lines.append("附件：")
    for i, item in enumerate(batch, 1):
        title = PAGES[item["page"]]["title"]
        lines.append("%d. 文件名：%s | 页面标题：%s | 候选：%s" % (
            i,
            item["filename"][:200],
            title[:200],
            ",".join(item["candidates"]),
        ))
    return "\n".join(lines)


class MockLLM:
    name = "mock-deterministic"

    def __init__(self, fail=False):
        self.fail = fail

    def complete(self, prompt, batch):
        if self.fail:
            raise TimeoutError("模拟调用超时")
        results = []
        for i, item in enumerate(batch, 1):
            text = (item["filename"] + " " + PAGES[item["page"]]["title"]).lower()
            scored = []
            for cid in item["candidates"]:
                score = sum(
                    1 for k in CAT_BY_ID[cid]["keywords"] if k.lower() in text
                )
                scored.append((score, -CAT_ORDER[cid], cid))
            best = max(scored)
            cid = best[2] if best[0] > 0 else item["candidates"][0]
            results.append({"i": i, "category_id": cid})
        return {"results": results}, {}


class OpenAICompatLLM:
    def __init__(self, endpoint, api_key, model, timeout=10,
                 disable_thinking=False, max_output_tokens=256):
        self.endpoint = endpoint
        self.api_key = api_key
        self.model = model
        self.name = model
        self.timeout = timeout
        self.disable_thinking = disable_thinking
        self.max_output_tokens = max_output_tokens

    def complete(self, prompt, batch):
        payload = {
            "model": self.model,
            "temperature": 0,
            "max_tokens": self.max_output_tokens,
            "messages": [{"role": "user", "content": prompt}],
        }
        if self.disable_thinking:
            payload["enable_thinking"] = False
        request = urllib.request.Request(
            self.endpoint,
            data=json.dumps(payload).encode("utf-8"),
            headers={
                "Content-Type": "application/json",
                "Authorization": "Bearer " + self.api_key,
            },
            method="POST",
        )
        with urllib.request.urlopen(request, timeout=self.timeout) as response:
            data = json.loads(response.read().decode("utf-8"))
        message = data["choices"][0]["message"]
        content = message.get("content") or ""
        if not content:
            raise ValueError("响应无正文（可能仍在思考模式或输出被截断）")
        start, end = content.find("{"), content.rfind("}")
        if start < 0 or end < start:
            raise ValueError("响应中没有 JSON")
        return json.loads(content[start:end + 1]), data.get("usage", {})


class Cache:
    def __init__(self, path=None):
        self.path = path
        self.data = {}
        if path and os.path.exists(path):
            try:
                with open(path, "r", encoding="utf-8") as handle:
                    self.data = json.load(handle)
            except Exception:
                self.data = {}

    @staticmethod
    def make_key(model, version, page_id, filename):
        raw = "%s|%s|%s|%s" % (model, version, page_id, filename.lower())
        return hashlib.sha256(raw.encode("utf-8")).hexdigest()

    def get(self, key, candidates):
        row = self.data.get(key)
        if not row:
            return None
        cid = row.get("category_id")
        return cid if cid in candidates else None

    def put(self, key, cid, source, model, version):
        self.data[key] = {
            "category_id": cid,
            "source": source,
            "model": model,
            "prompt_version": version,
            "time": int(time.time()),
        }
        if self.path:
            with open(self.path, "w", encoding="utf-8") as handle:
                json.dump(self.data, handle, ensure_ascii=False, indent=2)


def split_batches(items, max_chars, max_items):
    batch = []
    for item in items:
        trial = batch + [item]
        if batch and (
            len(trial) > max_items or len(build_prompt(trial)) > max_chars
        ):
            yield batch
            batch = [item]
        else:
            batch = trial
    if batch:
        yield batch


def main():
    parser = argparse.ArgumentParser(description="M13 智能判定最小化验证")
    parser.add_argument("--max-calls", type=int, default=50)
    parser.add_argument("--max-input-chars", type=int, default=8000)
    parser.add_argument("--batch-size", type=int, default=10)
    parser.add_argument("--no-llm", action="store_true")
    parser.add_argument("--simulate-failure", action="store_true")
    parser.add_argument("--endpoint", default="")
    parser.add_argument("--api-key", default=os.environ.get("M13_API_KEY", ""))
    parser.add_argument("--model", default="mock-deterministic")
    parser.add_argument("--timeout", type=int, default=10)
    parser.add_argument("--disable-thinking", action="store_true")
    parser.add_argument("--max-output-tokens", type=int, default=256)
    parser.add_argument("--prompt-version", default="m13-v3")
    parser.add_argument("--cache-file", default="")
    args = parser.parse_args()

    if args.endpoint:
        if not args.api_key:
            parser.error("使用 --endpoint 时必须提供 --api-key 或 M13_API_KEY")
        llm = OpenAICompatLLM(
            args.endpoint, args.api_key, args.model,
            timeout=args.timeout,
            disable_thinking=args.disable_thinking,
            max_output_tokens=args.max_output_tokens,
        )
    else:
        llm = MockLLM(args.simulate_failure)

    cache = Cache(args.cache_file or None)
    metrics = {
        "rule": 0,
        "cache": 0,
        "calls": 0,
        "llm_items": 0,
        "budget_fb": 0,
        "fail_fb": 0,
        "invalid_fb": 0,
        "disabled_fb": 0,
        "dedupe": 0,
        "inc_hits": 0,
        "prompt_chars": 0,
        "usage": {},
        "budget_exhausted": False,
    }
    results = []
    incremental = set()

    def finalize(item, cid, source):
        cat = CAT_BY_ID.get(cid)
        cat_name = cat["name"] if cat else "默认分类"
        key = (cat_name, item["filename"])
        if key in incremental:
            action = "增量跳过"
            metrics["inc_hits"] += 1
        else:
            incremental.add(key)
            action = "写入"
        results.append((
            item["index"], item["filename"], cat_name, source, action
        ))

    def fallback(item, source, write_cache=False):
        cid = item["candidates"][0] if item["candidates"] else None
        if write_cache:
            cache.put(
                Cache.make_key(
                    llm.name, args.prompt_version, item["page"], item["filename"]
                ),
                cid, source, llm.name, args.prompt_version,
            )
        finalize(item, cid, source)

    attachments = []
    for index, raw in enumerate(RAW_ATTACHMENTS, 1):
        item = dict(raw)
        item["index"] = index
        item["candidates"], item["reason"] = rule_candidates(item)
        attachments.append(item)

    pending = []
    for item in attachments:
        candidates = item["candidates"]
        if len(candidates) <= 1:
            metrics["rule"] += 1
            finalize(item, candidates[0] if candidates else None, "规则(唯一)")
            continue
        if args.no_llm:
            metrics["disabled_fb"] += 1
            finalize(item, candidates[0], "规则回退(未启用)")
            continue
        cache_key = Cache.make_key(
            llm.name, args.prompt_version, item["page"], item["filename"]
        )
        cached = cache.get(cache_key, candidates)
        if cached:
            metrics["cache"] += 1
            finalize(item, cached, "缓存")
            continue
        pending.append(item)

    unique_pending = []
    duplicates = {}
    seen_keys = set()
    for item in pending:
        key = Cache.make_key(
            llm.name, args.prompt_version, item["page"], item["filename"]
        )
        if key in seen_keys:
            duplicates.setdefault(key, []).append(item)
        else:
            seen_keys.add(key)
            unique_pending.append(item)

    resolved = {}

    for batch in split_batches(unique_pending, args.max_input_chars, args.batch_size):
        if metrics["calls"] >= args.max_calls:
            metrics["budget_exhausted"] = True
            for item in batch:
                key = Cache.make_key(
                    llm.name, args.prompt_version, item["page"], item["filename"]
                )
                cid = item["candidates"][0] if item["candidates"] else None
                cache.put(key, cid, "规则回退(预算)", llm.name, args.prompt_version)
                resolved[key] = (cid, "规则回退(预算)", True)
                metrics["budget_fb"] += 1
                finalize(item, cid, "规则回退(预算)")
            continue

        prompt = build_prompt(batch)
        metrics["calls"] += 1
        metrics["llm_items"] += len(batch)
        metrics["prompt_chars"] += len(prompt)

        try:
            response, usage = llm.complete(prompt, batch)
        except Exception:
            metrics["fail_fb"] += len(batch)
            for item in batch:
                key = Cache.make_key(
                    llm.name, args.prompt_version, item["page"], item["filename"]
                )
                cid = item["candidates"][0] if item["candidates"] else None
                resolved[key] = (cid, "规则回退(失败)", False)
                fallback(item, "规则回退(失败)", write_cache=False)
            continue

        for name, value in (usage or {}).items():
            if isinstance(value, int):
                metrics["usage"][name] = metrics["usage"].get(name, 0) + value

        parsed = {}
        for row in (response.get("results", []) if isinstance(response, dict) else []):
            if not isinstance(row, dict):
                continue
            index = row.get("i")
            if isinstance(index, int) and 1 <= index <= len(batch):
                parsed[index] = row.get("category_id")

        for index, item in enumerate(batch, 1):
            key = Cache.make_key(
                llm.name, args.prompt_version, item["page"], item["filename"]
            )
            cid = parsed.get(index)
            if cid in item["candidates"]:
                cache.put(key, cid, "AI", llm.name, args.prompt_version)
                resolved[key] = (cid, "AI", True)
                finalize(item, cid, "AI")
            else:
                metrics["invalid_fb"] += 1
                fallback_cid = item["candidates"][0] if item["candidates"] else None
                cache.put(
                    key, fallback_cid, "规则回退(非法)",
                    llm.name, args.prompt_version,
                )
                resolved[key] = (fallback_cid, "规则回退(非法)", True)
                finalize(item, fallback_cid, "规则回退(非法)")

    # 同一轮内键相同的附件：唯一项处理完后，优先按缓存命中复用。
    for key, items in duplicates.items():
        for item in items:
            cached = cache.get(key, item["candidates"])
            if cached:
                metrics["cache"] += 1
                finalize(item, cached, "缓存")
            elif key in resolved:
                metrics["dedupe"] += 1
                cid = resolved[key][0]
                finalize(item, cid, "同批结果")
            else:
                metrics["fail_fb"] += 1
                fallback(item, "规则回退(失败)", write_cache=False)

    total = len(attachments)
    ambiguous = total - metrics["rule"]

    print("=" * 78)
    print("M13 智能判定最小化验证")
    print("模式: %s | 模型: %s | 批量: %d | 最大调用: %d | 最大字符: %d | 超时: %ds | 思考: %s" % (
        "关闭" if args.no_llm else "启用",
        llm.name, args.batch_size, args.max_calls, args.max_input_chars,
        args.timeout, "关闭" if args.disable_thinking else "默认",
    ))
    print("=" * 78)
    for index, filename, cat_name, source, action in sorted(results):
        print("[%02d] %-34s -> %-8s | %-18s | %s" % (
            index, filename, cat_name, source, action
        ))

    print("\n--- 汇总 ---")
    print("附件总数: %d" % total)
    print("规则直接归属: %d (%.1f%%)" % (
        metrics["rule"], metrics["rule"] * 100.0 / total
    ))
    print("进入智能判定: %d" % ambiguous)
    print("  缓存命中: %d | 同批去重: %d" % (
        metrics["cache"], metrics["dedupe"]
    ))
    print("  实际调用: %d 次，覆盖 %d 个附件" % (
        metrics["calls"], metrics["llm_items"]
    ))
    print("  预算回退: %d | 失败回退: %d | 非法回退: %d | 未启用回退: %d" % (
        metrics["budget_fb"], metrics["fail_fb"],
        metrics["invalid_fb"], metrics["disabled_fb"],
    ))
    print("增量命中: %d" % metrics["inc_hits"])
    print("输入字符合计: %d（保守 token 上限，按 1 字符≈1 token）" % (
        metrics["prompt_chars"]
    ))
    if metrics["usage"]:
        print("接口 usage: %s" % json.dumps(metrics["usage"], ensure_ascii=False))
    print("未进入模型: 规则 %d + 缓存 %d + 同批 %d = %d" % (
        metrics["rule"], metrics["cache"], metrics["dedupe"],
        metrics["rule"] + metrics["cache"] + metrics["dedupe"],
    ))
    print("预算耗尽: %s" % ("是" if metrics["budget_exhausted"] else "否"))


if __name__ == "__main__":
    main()
