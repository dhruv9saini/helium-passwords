#!/usr/bin/env python3
import json
import time
import urllib.parse
import urllib.request


cdp = "http://127.0.0.1:9223"
blank = "about:blank"


def request(path, method="GET"):
    req = urllib.request.Request(f"{cdp}{path}", method=method)
    with urllib.request.urlopen(req, timeout=3) as response:
        return response.read()


def pages():
    return json.loads(request("/json/list").decode("utf-8"))


def unwanted(url):
    return (
        url.startswith("chrome://setup/")
        or url.startswith("https://darkreader.org/help/")
        or url.startswith("chrome://newtab/")
    )


def close(page_id):
    try:
        request(f"/json/close/{page_id}")
    except Exception:
        pass


def activate(page_id):
    try:
        request(f"/json/activate/{page_id}")
    except Exception:
        pass


last_pages = []
for _ in range(10):
    try:
        last_pages = pages()
    except Exception:
        time.sleep(1)
        continue

    for page in last_pages:
        if page.get("type") == "page" and unwanted(page.get("url", "")):
            close(page["id"])
    time.sleep(1)

visible_pages = [page for page in pages() if page.get("type") == "page"]
if not visible_pages:
    request("/json/new?" + urllib.parse.quote(blank, safe=":/?=&"), "PUT")
else:
    blank_pages = [
        page
        for page in visible_pages
        if page.get("url", "") == blank or page.get("url", "").startswith("chrome-extension://")
    ]
    activate((blank_pages or visible_pages)[0]["id"])
