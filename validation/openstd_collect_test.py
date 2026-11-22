#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""openstd.samr.gov.cn 采集链路测试

流程：入口页 -> 关键词搜索列表（可翻页）-> 详情页 -> 全文下载（showGb -> viewGb）。
仅使用 Python 标准库，验证 PRD 中 M2/M3/M12 的关键动作能否在真实站点跑通。

用法：
  python3 validation/openstd_collect_test.py --keyword 计算机 --pages 3 --max-download 5
"""

import argparse
import csv
import html
import json
import os
import re
import sys
import time
from http.cookiejar import CookieJar
from urllib.error import HTTPError, URLError
from urllib.parse import quote, unquote_plus, urlsplit
from urllib.request import HTTPCookieProcessor, Request, build_opener

BASE = "https://openstd.samr.gov.cn"
DEFAULT_UA = (
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
    "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
)
ILLEGAL = '\\/:*?"<>|'


def log(msg):
    print(msg, flush=True)


def strip_tags(s):
    s = re.sub(r"<[^>]+>", "", s or "")
    return html.unescape(s).replace("\u00a0", " ").strip()


def norm_space(s):
    return re.sub(r"\s+", " ", s or "").strip()


def sanitize(name):
    for ch in ILLEGAL:
        name = name.replace(ch, "_")
    return norm_space(name)[:180]


class Fetcher:
    """带 Cookie 的抓取器：viewGb 依赖 showGb 建立的会话，必须复用 Cookie。"""

    def __init__(self, ua, timeout, delay):
        self.ua = ua
        self.timeout = timeout
        self.delay = delay
        self.opener = build_opener(HTTPCookieProcessor(CookieJar()))
        self._last = 0.0

    def reset(self):
        """重建会话。站点按会话累计下载量触发验证码，换新会话即可恢复；不涉及破解。"""
        self.opener = build_opener(HTTPCookieProcessor(CookieJar()))

    def get(self, url, referer=None):
        wait = self.delay - (time.time() - self._last)
        if wait > 0:
            time.sleep(wait)
        headers = {"User-Agent": self.ua, "Accept-Language": "zh-CN,zh;q=0.9"}
        if referer:
            headers["Referer"] = referer
        req = Request(url, headers=headers)
        try:
            with self.opener.open(req, timeout=self.timeout) as resp:
                data = resp.read()
                return resp.status, resp.headers, data
        finally:
            self._last = time.time()


def fetch_text(fetcher, url, referer=None):
    status, headers, data = fetcher.get(url, referer)
    charset = headers.get_content_charset() or "utf-8"
    try:
        text = data.decode(charset, "replace")
    except LookupError:
        text = data.decode("utf-8", "replace")
    return status, headers, text


def list_url(keyword, page, page_size):
    return (
        BASE
        + "/bzgk/std/std_list?p.p1=0&p.p90=circulation_date&p.p91=desc"
        + "&p.p2=" + quote(keyword)
        + "&page=%d&pageSize=%d" % (page, page_size)
    )


def parse_list(text):
    """解析结果表格行。列顺序：序号/标准号/代替/采标/名称/类别/状态/发布日期/实施日期/操作。"""
    items = []
    for block in re.findall(r"<tr>(.*?)</tr>", text, re.S):
        m = re.search(r"showInfo\('([0-9A-F]+)'\)", block)
        if not m:
            continue
        hcno = m.group(1)
        if any(it["hcno"] == hcno for it in items):
            continue
        cells = re.findall(r"<td[^>]*>(.*?)</td>", block, re.S)
        if len(cells) < 9:
            continue
        title = ""
        tm = re.search(r'<td class="mytxt"[^>]*>(.*?)</td>', block, re.S)
        if tm:
            title = strip_tags(tm.group(1))
        if not title and len(cells) > 4:
            title = strip_tags(cells[4])
        items.append({
            "hcno": hcno,
            "number": strip_tags(cells[1]),
            "title": title,
            "type": strip_tags(cells[5]),
            "status": strip_tags(cells[6]),
            "publish_date": strip_tags(cells[7])[:10],
            "implement_date": strip_tags(cells[8])[:10],
            "detail_url": BASE + "/bzgk/std/newGbInfo?hcno=" + hcno,
        })
    return items


def parse_detail(text):
    """返回 (中文名称, 是否提供下载, 不可下载原因)。"""
    cn = ""
    m = re.search(r"中文标准名称：</td>\s*<td[^>]*>(.*?)</td>", text, re.S)
    if not m:
        m = re.search(r"中文标准名称[：:]\s*([^<\r\n]+)", text)
    if m:
        cn = strip_tags(m.group(1))
    body = text.split("<body", 1)[-1]
    downloadable = False
    for tag in re.findall(r"<button[^>]*>", body):
        if "xz_btn" in tag and re.search(r'data-value="[0-9A-F]+"', tag):
            downloadable = True
            break
    reason = ""
    if not downloadable:
        rm = re.search(r'<span class="text-danger"\s*>(.*?)</span>', body, re.S)
        reason = norm_space(strip_tags(rm.group(1))) if rm else "详情页未提供下载入口"
        reason = reason or "详情页未提供下载入口"
    return cn, downloadable, reason


def get_filename(headers, fallback):
    cd = headers.get("Content-Disposition") or ""
    m = re.search(r'filename\*?=(?:UTF-8\'\')?"?([^";]+)"?', cd, re.I)
    if m:
        raw = m.group(1)
        try:
            name = unquote_plus(raw)
        except Exception:
            name = raw
        if name:
            return sanitize(name)
    return sanitize(fallback)


def unique_path(out_dir, name):
    base, ext = os.path.splitext(name)
    path = os.path.join(out_dir, name)
    i = 1
    while os.path.exists(path):
        path = os.path.join(out_dir, "%s(%d)%s" % (base, i, ext))
        i += 1
    return path


def existing_file(out_dir, number):
    """按标准号判断是否已下载（等价于 PRD 的增量跳过）。"""
    key = number.replace("/", "").replace(" ", "")
    for name in os.listdir(out_dir):
        if name.lower().endswith(".pdf") and name.replace(" ", "").startswith(key):
            return os.path.join(out_dir, name)
    return None


def probe_pdf(path):
    """借用 macOS 自带 PDFKit 检查页数/文本层，用于验证 M3 的文字提取前提。"""
    try:
        import Foundation
        from Quartz import PDFDocument

        doc = PDFDocument.alloc().initWithURL_(Foundation.NSURL.fileURLWithPath_(path))
        n = doc.pageCount()
        counts = [len(doc.pageAtIndex_(i).string() or "") for i in range(min(n, 5))]
        with_text = sum(1 for i in range(n) if len(doc.pageAtIndex_(i).string() or "") > 10)
        return {"pages": n, "pages_with_text": with_text,
                "first5_text_chars": counts}
    except Exception:
        return {}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--keyword", default="计算机")
    ap.add_argument("--pages", type=int, default=3)
    ap.add_argument("--page-size", type=int, default=10)
    ap.add_argument("--max-download", type=int, default=5)
    ap.add_argument("--out", default=os.path.join(os.path.dirname(__file__), "openstd_downloads"))
    ap.add_argument("--delay", type=float, default=1.2)
    ap.add_argument("--timeout", type=float, default=30)
    ap.add_argument("--ua", default=DEFAULT_UA)
    args = ap.parse_args()

    os.makedirs(args.out, exist_ok=True)
    fetcher = Fetcher(args.ua, args.timeout, args.delay)

    log("[合规] 仅采集已获授权的公开页面资源，遵守站点访问频率。")

    # 1) 入口页可达性
    status, _, home = fetch_text(fetcher, BASE + "/bzgk/std/", referer=BASE + "/")
    log("[入口] %s -> HTTP %s, %d 字符" % (BASE + "/bzgk/std/", status, len(home)))

    # 2) 列表翻页
    all_items, seen = [], set()
    for page in range(1, args.pages + 1):
        url = list_url(args.keyword, page, args.page_size)
        status, _, text = fetch_text(fetcher, url, referer=BASE + "/bzgk/std/")
        items = parse_list(text)
        fresh = [it for it in items if it["hcno"] not in seen]
        for it in fresh:
            seen.add(it["hcno"])
            it["page"] = page
        all_items.extend(fresh)
        log("[列表] 关键词「%s」第 %d 页 -> HTTP %s, 本页 %d 条, 新增 %d 条"
            % (args.keyword, page, status, len(items), len(fresh)))
        if not items:
            break

    if not all_items:
        log("未搜索到结果，测试终止。")
        return 2

    # 3) 详情 + 下载（已存在的按标准号跳过，验证增量语义）
    downloaded, blocked, failed, skipped = [], [], [], []
    for it in all_items:
        if len(downloaded) >= args.max_download:
            break
        old = existing_file(args.out, it["number"])
        if old:
            skipped.append(dict(it, file=os.path.basename(old)))
            log("[已存在] %s %s -> %s" % (it["number"], it["title"], os.path.basename(old)))
            continue
        status, _, detail = fetch_text(fetcher, it["detail_url"], referer=BASE + "/bzgk/std/")
        cn, downloadable, reason = parse_detail(detail)
        if cn:
            it["title"] = cn
        if not downloadable:
            blocked.append(dict(it, reason=reason))
            log("[无全文] %s %s：%s" % (it["number"], it["title"], reason))
            continue
        try:
            show_url = (BASE + "/bzgk/std/showGb?type=download&hcno=" + it["hcno"]
                        + "&request_locale=zh")
            _, _, page = fetch_text(fetcher, show_url, referer=it["detail_url"])
            valid = re.search(r"var isValid = '(true|false)'", page)
            if not valid or valid.group(1) != "true":
                # 站点按会话累计下载量触发验证码；换新会话重试一次，仍失败则如实记录。
                fetcher.reset()
                fetch_text(fetcher, it["detail_url"], referer=BASE + "/bzgk/std/")
                _, _, page = fetch_text(fetcher, show_url, referer=it["detail_url"])
                valid = re.search(r"var isValid = '(true|false)'", page)
                log("[会话] %s：重建会话后重试" % it["number"])
            if not valid or valid.group(1) != "true":
                blocked.append(dict(it, reason="下载前需输入验证码"))
                log("[验证码] %s %s：站点要求人工验证，按 PRD 不破解" % (it["number"], it["title"]))
                continue
            view_url = BASE + "/bzgk/std/viewGb?hcno=" + it["hcno"]
            code, headers, data = fetcher.get(view_url, referer=show_url)
            if code != 200 or not data.startswith(b"%PDF"):
                ctype = headers.get("Content-Type", "")
                failed.append(dict(it, reason="HTTP %s %s %d 字节" % (code, ctype, len(data))))
                log("[失败] %s %s：返回非 PDF（%s, %d 字节）"
                    % (it["number"], it["title"], ctype, len(data)))
                continue
            name = get_filename(headers, (it["number"] or "standard") + ".pdf")
            if not name.lower().endswith(".pdf"):
                name += ".pdf"
            path = unique_path(args.out, name)
            with open(path, "wb") as f:
                f.write(data)
            it.update({
                "file": os.path.relpath(path, os.path.dirname(__file__)),
                "bytes": len(data),
            })
            it.update(probe_pdf(path))
            downloaded.append(it)
            log("[成功] %s %s -> %s（%d 字节，%s 页）"
                % (it["number"], it["title"], name, len(data), it.get("pages", "?")))
        except (HTTPError, URLError, TimeoutError, OSError) as e:
            failed.append(dict(it, reason=str(e)))
            log("[失败] %s %s：%s" % (it["number"], it["title"], e))

    report = {
        "keyword": args.keyword,
        "pages_fetched": args.pages,
        "listed": len(all_items),
        "downloaded": len(downloaded),
        "skipped_existing": len(skipped),
        "blocked_no_fulltext_or_captcha": len(blocked),
        "failed": len(failed),
        "items": all_items,
        "downloaded_items": downloaded,
        "skipped_items": skipped,
        "blocked_items": blocked,
        "failed_items": failed,
    }
    with open(os.path.join(args.out, "report.json"), "w", encoding="utf-8") as f:
        json.dump(report, f, ensure_ascii=False, indent=2)
    with open(os.path.join(args.out, "report.csv"), "w", encoding="utf-8-sig", newline="") as f:
        w = csv.writer(f)
        w.writerow(["标准号", "标准名称", "状态", "发布日期", "页", "结果", "文件/原因"])
        done = {d["hcno"]: d for d in downloaded}
        have = {s["hcno"]: s for s in skipped}
        bad = {b["hcno"]: b for b in blocked + failed}
        for it in all_items:
            if it["hcno"] in done:
                w.writerow([it["number"], it["title"], it["status"], it["publish_date"],
                            it["page"], "已下载", done[it["hcno"]]["file"]])
            elif it["hcno"] in have:
                w.writerow([it["number"], it["title"], it["status"], it["publish_date"],
                            it["page"], "已存在跳过", have[it["hcno"]]["file"]])
            elif it["hcno"] in bad:
                w.writerow([it["number"], it["title"], it["status"], it["publish_date"],
                            it["page"], "未下载", bad[it["hcno"]]["reason"]])
            else:
                w.writerow([it["number"], it["title"], it["status"], it["publish_date"],
                            it["page"], "未处理", ""])

    log("")
    log("== 汇总 ==")
    log("列表命中 %d 条；新下载 %d 个 PDF；已存在跳过 %d 条；无全文/需验证 %d 条；失败 %d 条"
        % (len(all_items), len(downloaded), len(skipped), len(blocked), len(failed)))
    log("输出目录：%s" % args.out)
    return 0 if downloaded else 1


if __name__ == "__main__":
    sys.exit(main())
