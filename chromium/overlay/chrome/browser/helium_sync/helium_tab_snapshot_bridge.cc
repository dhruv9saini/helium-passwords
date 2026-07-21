// Copyright 2026 The Helium Authors

#include "chrome/browser/helium_sync/helium_tab_snapshot_bridge.h"

#include <algorithm>
#include <optional>
#include <string>
#include <utility>

#include "base/files/file_util.h"
#include "base/files/important_file_writer.h"
#include "base/functional/bind.h"
#include "base/json/json_writer.h"
#include "base/location.h"
#include "base/logging.h"
#include "base/strings/string_number_conversions.h"
#include "base/strings/utf_string_conversions.h"
#include "base/task/sequenced_task_runner.h"
#include "base/time/time.h"
#include "base/values.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/tab_list/tab_list_interface.h"
#include "chrome/browser/ui/browser_window/public/browser_window_interface.h"
#include "chrome/browser/ui/browser_window/public/browser_window_interface_iterator.h"
#include "components/sessions/core/session_id.h"
#include "components/tabs/public/tab_interface.h"
#include "content/public/browser/navigation_controller.h"
#include "content/public/browser/navigation_entry.h"
#include "content/public/browser/web_contents.h"
#include "crypto/sha2.h"

namespace helium_sync {
namespace {

constexpr int kSchemaVersion = 1;
constexpr int kMaxWindows = 100;
constexpr int kMaxTabs = 5000;
constexpr int kMaxNavigations = 100;
constexpr base::TimeDelta kStartupCaptureDelay = base::Seconds(30);
constexpr base::TimeDelta kCaptureInterval = base::Minutes(5);

bool AllowedSnapshotUrl(const GURL& url) {
  return url.SchemeIsHTTPOrHTTPS() || url.SchemeIs("chrome") ||
         url.SchemeIs("about");
}

std::optional<base::DictValue> BuildSnapshot(Profile* profile) {
  base::ListValue windows;
  int tab_count = 0;
  bool valid = true;

  ForEachCurrentBrowserWindowInterfaceOrderedByActivation(
      [&](BrowserWindowInterface* browser) {
        if (browser->GetProfile() != profile ||
            browser->GetType() != BrowserWindowInterface::TYPE_NORMAL) {
          return true;
        }
        if (windows.size() >= kMaxWindows) {
          valid = false;
          return false;
        }
        TabListInterface* tab_list = TabListInterface::From(browser);
        if (!tab_list || tab_list->GetTabCount() <= 0 ||
            tab_list->GetActiveIndex() < 0 ||
            tab_list->GetActiveIndex() >= tab_list->GetTabCount()) {
          valid = false;
          return false;
        }

        base::DictValue window;
        window.Set("id", base::NumberToString(browser->GetSessionID().id()));
        window.Set("active_index", tab_list->GetActiveIndex());
        base::ListValue tabs;
        for (tabs::TabInterface* tab : tab_list->GetAllTabs()) {
          if (!tab || ++tab_count > kMaxTabs) {
            valid = false;
            return false;
          }
          content::WebContents* contents = tab->GetContents();
          if (!contents) {
            // Android may leave background tabs unloaded. Publishing a partial
            // generation is worse than retaining the previous complete one.
            valid = false;
            return false;
          }
          content::NavigationController& controller = contents->GetController();
          const int entry_count = controller.GetEntryCount();
          const int current_index = controller.GetCurrentEntryIndex();
          if (entry_count <= 0 || current_index < 0 ||
              current_index >= entry_count) {
            valid = false;
            return false;
          }

          int first_entry = std::max(0, current_index - kMaxNavigations / 2);
          int last_entry = std::min(entry_count, first_entry + kMaxNavigations);
          first_entry = std::max(0, last_entry - kMaxNavigations);
          base::ListValue navigations;
          for (int i = first_entry; i < last_entry; ++i) {
            content::NavigationEntry* entry = controller.GetEntryAtIndex(i);
            if (!entry || !entry->GetVirtualURL().is_valid() ||
                !AllowedSnapshotUrl(entry->GetVirtualURL())) {
              valid = false;
              return false;
            }
            base::DictValue navigation;
            navigation.Set("url", entry->GetVirtualURL().spec());
            if (!entry->GetTitle().empty()) {
              navigation.Set("title", base::UTF16ToUTF8(entry->GetTitle()));
            }
            navigations.Append(std::move(navigation));
          }

          base::DictValue item;
          item.Set("id", base::NumberToString(tab->GetHandle().raw_value()));
          if (tab->IsPinned()) {
            item.Set("pinned", true);
          }
          if (std::optional<tab_groups::TabGroupId> group = tab->GetGroup()) {
            item.Set("group", group->ToString());
          }
          item.Set("current_index", current_index - first_entry);
          item.Set("navigations", std::move(navigations));
          tabs.Append(std::move(item));
        }
        window.Set("tabs", std::move(tabs));
        windows.Append(std::move(window));
        return true;
      });

  if (!valid || windows.empty()) {
    return std::nullopt;
  }
  base::DictValue root;
  root.Set("schema_version", kSchemaVersion);
  root.Set("windows", std::move(windows));
  return root;
}

}  // namespace

HeliumTabSnapshotBridge::HeliumTabSnapshotBridge(Profile* profile,
                                                 base::FilePath export_path)
    : profile_(profile), export_path_(std::move(export_path)) {}

HeliumTabSnapshotBridge::~HeliumTabSnapshotBridge() {
  Stop();
}

void HeliumTabSnapshotBridge::Start() {
  if (!profile_ || export_path_.empty() || !export_path_.IsAbsolute() ||
      export_path_ == profile_->GetPath() ||
      profile_->GetPath().IsParent(export_path_)) {
    LOG(WARNING) << "Helium tab export inactive: export path must be absolute "
                    "and outside the browser profile";
    return;
  }
  base::SequencedTaskRunner::GetCurrentDefault()->PostDelayedTask(
      FROM_HERE,
      base::BindOnce(&HeliumTabSnapshotBridge::Capture,
                     weak_factory_.GetWeakPtr()),
      kStartupCaptureDelay);
  capture_timer_.Start(FROM_HERE, kCaptureInterval,
                       base::BindRepeating(&HeliumTabSnapshotBridge::Capture,
                                           weak_factory_.GetWeakPtr()));
}

void HeliumTabSnapshotBridge::Stop() {
  capture_timer_.Stop();
  weak_factory_.InvalidateWeakPtrs();
}

bool HeliumTabSnapshotBridge::CaptureNowForTesting() {
  std::optional<base::DictValue> snapshot = BuildSnapshot(profile_);
  if (!snapshot) {
    return false;
  }
  std::string raw;
  if (!base::JSONWriter::WriteWithOptions(
          *snapshot, base::JSONWriter::OPTIONS_PRETTY_PRINT, &raw)) {
    return false;
  }
  raw.push_back('\n');
  std::string fingerprint = base::HexEncodeLower(crypto::SHA256HashString(raw));
  if (fingerprint == last_fingerprint_) {
    return true;
  }
  if (!base::CreateDirectory(export_path_.DirName()) ||
      !base::ImportantFileWriter::WriteFileAtomically(export_path_, raw,
                                                      "HeliumSync")) {
    return false;
  }
  last_fingerprint_ = std::move(fingerprint);
  return true;
}

void HeliumTabSnapshotBridge::Capture() {
  if (!CaptureNowForTesting()) {
    LOG(WARNING) << "Helium tab export retained the previous complete capture";
  }
}

}  // namespace helium_sync
