#!/usr/bin/env python3
import json
import os
import sqlite3
import sys


profile = sys.argv[1] if len(sys.argv) > 1 else "/root/.config/helium-passwords"
google_guid = "485bf7d3-0215-45af-87dc-538868000001"
google_url = "https://www.google.com/search?q={searchTerms}"
google_suggest = "https://www.google.com/complete/search?client=chrome&q={searchTerms}"


def update_json(path, update):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    if os.path.exists(path):
        with open(path, "r", encoding="utf-8") as handle:
            data = json.load(handle)
    else:
        data = {}
    update(data)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as handle:
        json.dump(data, handle, separators=(",", ":"))
    os.replace(tmp, path)


def google_template_url_data():
    return {
        "alternate_urls": [],
        "contextual_search_url": "",
        "created_from_play_api": False,
        "date_created": "0",
        "doodle_url": "",
        "enforced_by_policy": False,
        "favicon_url": "",
        "featured_by_policy": False,
        "id": "2",
        "image_search_branding_label": "",
        "image_translate_source_language_param_key": "",
        "image_translate_target_language_param_key": "",
        "image_translate_url": "",
        "image_url": "",
        "image_url_post_params": "",
        "input_encodings": ["UTF-8"],
        "is_active": 1,
        "keyword": "google.com",
        "last_modified": "0",
        "last_visited": "0",
        "logo_url": "",
        "new_tab_url": "",
        "originating_url": "",
        "policy_origin": 0,
        "preconnect_to_search_url": False,
        "prefetch_likely_navigations": False,
        "prepopulate_id": 1,
        "safe_for_autoreplace": True,
        "search_intent_params": [],
        "search_url_post_params": "",
        "short_name": "Google",
        "starter_pack_id": 0,
        "suggestions_url": google_suggest,
        "suggestions_url_post_params": "",
        "synced_guid": google_guid,
        "url": google_url,
        "usage_count": 0,
    }


def update_preferences(data):
    profile_prefs = data.setdefault("profile", {})
    profile_prefs["exited_cleanly"] = True
    profile_prefs["exit_type"] = "Normal"
    data.setdefault("browser", {})["has_seen_welcome_page"] = True

    session = data.setdefault("session", {})
    session["restore_on_startup"] = 1
    session.pop("startup_urls", None)

    data["vertical_tabs"] = {
        "collapsed_state": False,
        "enabled": True,
        "enabled_first_time": True,
        "expand_on_hover": False,
        "uncollapsed_width": 240,
    }
    helium_browser = data.setdefault("helium", {}).setdefault("browser", {})
    helium_browser["layout"] = 2
    helium_browser["vertical_right_aligned"] = False

    data.setdefault("search", {})["suggest_enabled"] = True
    default_search = data.setdefault("default_search_provider", {})
    default_search["guid"] = google_guid
    default_search["reset_occurred"] = False
    data["default_search_provider_data"] = {
        "template_url_data": google_template_url_data(),
        "mirrored_template_url_data": google_template_url_data(),
    }


def update_local_state(data):
    profile_state = data.setdefault("profile", {})
    profile_state["exited_cleanly"] = True
    profile_state["exit_type"] = "Normal"


def patch_web_data(path):
    if not os.path.exists(path):
        return
    con = sqlite3.connect(path)
    try:
        cur = con.cursor()
        cur.execute(
            """
            update keywords
               set short_name = ?,
                   keyword = ?,
                   url = ?,
                   suggest_url = ?,
                   prepopulate_id = 1,
                   safe_for_autoreplace = 1,
                   is_active = 1
             where sync_guid = ?
            """,
            ("Google", "google.com", google_url, google_suggest, google_guid),
        )
        if cur.rowcount == 0:
            cur.execute("select coalesce(max(id), 0) + 1 from keywords")
            new_id = cur.fetchone()[0]
            cur.execute(
                """
                insert into keywords
                  (id, short_name, keyword, favicon_url, url,
                   safe_for_autoreplace, originating_url, date_created,
                   usage_count, input_encodings, suggest_url, prepopulate_id,
                   created_by_policy, last_modified, sync_guid, alternate_urls,
                   image_url, search_url_post_params, suggest_url_post_params,
                   image_url_post_params, new_tab_url, last_visited,
                   created_from_play_api, is_active, starter_pack_id,
                   enforced_by_policy, featured_by_policy)
                values
                  (?, ?, ?, '', ?, 1, '', 0, 0, 'UTF-8', ?, 1, 0, 0, ?, '',
                   '', '', '', '', '', 0, 0, 1, 0, 0, 0)
                """,
                (new_id, "Google", "google.com", google_url, google_suggest, google_guid),
            )

        cur.execute(
            """
            update keywords
               set is_active = 0
             where lower(keyword) in ('@gemini', '@aimode')
                or lower(short_name) in ('gemini', 'google ai mode')
            """
        )
        con.commit()
    finally:
        con.close()


update_json(os.path.join(profile, "Default", "Preferences"), update_preferences)
update_json(os.path.join(profile, "Local State"), update_local_state)
patch_web_data(os.path.join(profile, "Default", "Web Data"))
