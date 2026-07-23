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
#include "build/build_config.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/tab_list/tab_list_interface.h"
#include "chrome/browser/ui/browser_window/public/browser_window_interface.h"
#include "chrome/browser/ui/browser_window/public/browser_window_interface_iterator.h"
#include "components/sessions/core/session_id.h"
#include "components/tab_groups/tab_group_color.h"
#include "components/tab_groups/tab_group_visual_data.h"
#include "components/tabs/public/tab_interface.h"
#include "content/public/browser/navigation_controller.h"
#include "content/public/browser/navigation_entry.h"
#include "content/public/browser/web_contents.h"

namespace helium_sync {
namespace {

constexpr int kSchemaVersion = 2;
constexpr int kMaxWindows = 100;
constexpr int kMaxTabs = 5000;
constexpr int kMaxNavigations = 100;
constexpr char kGroupMetadataComplete[] = "complete";
constexpr char kHistoryBounded[] = "bounded";
constexpr char kHistoryCurrentOnlyUnloaded[] = "current-only-unloaded";
constexpr base::TimeDelta kStartupCaptureDelay = base::Seconds(30);
constexpr base::TimeDelta kCaptureInterval = base::Minutes(5);

bool AllowedSnapshotUrl(const GURL& url) {
  return url.SchemeIsHTTPOrHTTPS() || url.SchemeIs("chrome") ||
         url.SchemeIs("about");
}

std::optional<std::string> GroupColorName(tab_groups::TabGroupColorId color) {
  switch (color) {
    case tab_groups::TabGroupColorId::kGrey:
      return "grey";
    case tab_groups::TabGroupColorId::kBlue:
      return "blue";
    case tab_groups::TabGroupColorId::kRed:
      return "red";
    case tab_groups::TabGroupColorId::kYellow:
      return "yellow";
    case tab_groups::TabGroupColorId::kGreen:
      return "green";
    case tab_groups::TabGroupColorId::kPink:
      return "pink";
    case tab_groups::TabGroupColorId::kPurple:
      return "purple";
    case tab_groups::TabGroupColorId::kCyan:
      return "cyan";
    case tab_groups::TabGroupColorId::kOrange:
      return "orange";
    case tab_groups::TabGroupColorId::kNumEntries:
      return std::nullopt;
  }
  return std::nullopt;
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
        base::ListValue groups;
        for (const tab_groups::TabGroupId& group_id :
             tab_list->ListTabGroups()) {
          std::optional<tab_groups::TabGroupVisualData> visual_data =
              tab_list->GetTabGroupVisualData(group_id);
          if (!visual_data) {
            valid = false;
            return false;
          }
          std::optional<std::string> color =
              GroupColorName(visual_data->color());
          if (!color) {
            valid = false;
            return false;
          }
          base::DictValue group;
          group.Set("id", group_id.ToString());
          group.Set("title", base::UTF16ToUTF8(visual_data->title()));
          group.Set("color", *color);
          group.Set("collapsed", visual_data->is_collapsed());
          group.Set("metadata_state", kGroupMetadataComplete);
          groups.Append(std::move(group));
        }
        window.Set("groups", std::move(groups));

        base::ListValue tabs;
        for (tabs::TabInterface* tab : tab_list->GetAllTabs()) {
          if (!tab || ++tab_count > kMaxTabs) {
            valid = false;
            return false;
          }
          content::WebContents* contents = tab->GetContents();
          base::ListValue navigations;
          int snapshot_current_index = 0;
          std::string history_state;
          if (!contents) {
            // Android may unload a background tab. TabInterface deliberately
            // exposes its current URL/title without loading it; preserve that
            // safe current entry and make the history limitation explicit.
            const GURL url = tab->GetURL();
            if (!url.is_valid() || !AllowedSnapshotUrl(url)) {
              valid = false;
              return false;
            }
            base::DictValue navigation;
            navigation.Set("url", url.spec());
            navigation.Set("title", base::UTF16ToUTF8(tab->GetTitle()));
            navigations.Append(std::move(navigation));
            history_state = kHistoryCurrentOnlyUnloaded;
          } else {
            content::NavigationController& controller =
                contents->GetController();
            const int entry_count = controller.GetEntryCount();
            const int current_index = controller.GetCurrentEntryIndex();
            if (entry_count <= 0 || current_index < 0 ||
                current_index >= entry_count) {
              valid = false;
              return false;
            }

            int first_entry = std::max(0, current_index - kMaxNavigations / 2);
            int last_entry =
                std::min(entry_count, first_entry + kMaxNavigations);
            first_entry = std::max(0, last_entry - kMaxNavigations);
            for (int i = first_entry; i < last_entry; ++i) {
              content::NavigationEntry* entry = controller.GetEntryAtIndex(i);
              if (!entry || !entry->GetVirtualURL().is_valid() ||
                  !AllowedSnapshotUrl(entry->GetVirtualURL())) {
                valid = false;
                return false;
              }
              base::DictValue navigation;
              navigation.Set("url", entry->GetVirtualURL().spec());
              navigation.Set("title", base::UTF16ToUTF8(entry->GetTitle()));
              navigations.Append(std::move(navigation));
            }
            snapshot_current_index = current_index - first_entry;
            history_state = kHistoryBounded;
          }

          base::DictValue item;
          item.Set("id", base::NumberToString(tab->GetHandle().raw_value()));
          item.Set("pinned", tab->IsPinned());
          std::string group_id;
          if (std::optional<tab_groups::TabGroupId> group = tab->GetGroup()) {
            group_id = group->ToString();
          }
          item.Set("group", group_id);
          item.Set("history_state", history_state);
          item.Set("current_index", snapshot_current_index);
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
  if (!base::CreateDirectory(export_path_.DirName())) {
    return false;
  }
#if BUILDFLAG(IS_POSIX)
  if (!base::SetPosixFilePermissions(export_path_.DirName(), 0700)) {
    return false;
  }
#endif
  if (!base::ImportantFileWriter::WriteFileAtomically(export_path_, raw,
                                                      "HeliumSync")) {
    return false;
  }
#if BUILDFLAG(IS_POSIX)
  if (!base::SetPosixFilePermissions(export_path_, 0600)) {
    base::DeleteFile(export_path_);
    return false;
  }
#endif
  return true;
}

void HeliumTabSnapshotBridge::Capture() {
  if (!CaptureNowForTesting()) {
    LOG(WARNING) << "Helium tab export retained the previous complete capture";
  }
}

}  // namespace helium_sync
