#!/usr/bin/env python3
import json
import time
import urllib.parse
import urllib.request


cdp = "http://127.0.0.1:9223"
blank = "about:blank"
startup_only_seconds = 60


def request(path, method="GET"):
    req = urllib.request.Request(f"{cdp}{path}", method=method)
    with urllib.request.urlopen(req, timeout=3) as response:
        return response.read()


def pages():
    return json.loads(request("/json/list").decode("utf-8"))


def unwanted(url):
    lower_url = url.lower()
    return (
        lower_url.startswith("chrome://setup/")
        or lower_url.startswith("chrome://welcome")
        or lower_url.startswith("chrome://whats-new")
        or lower_url.startswith("chrome://newtab")
        or lower_url.startswith("chrome://new-tab-page")
        or lower_url.startswith("chrome://extensions")
        or lower_url.startswith("chrome://management")
        or lower_url.startswith("chrome-extension://")
        or lower_url.startswith("https://darkreader.org/help/")
        or lower_url.startswith("https://www.google.com/chrome/")
    )


def unwanted_page(page):
    if page.get("type") != "page":
        return False
    url = page.get("url", "")
    if unwanted(url):
        return True
    title = page.get("title", "").lower()
    return (
        "installed" in title
        or "welcome" in title
        or "thanks for installing" in title
        or "thank you for installing" in title
        or "getting started" in title
        or "what's new" in title
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
deadline = time.time() + startup_only_seconds
while time.time() < deadline:
    try:
        last_pages = pages()
    except Exception:
        time.sleep(1)
        continue

    for page in last_pages:
        if unwanted_page(page):
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
