// Copyright 2026 The Helium Authors

#include "chrome/browser/helium_sync/helium_tab_restore_bridge.h"

#include <algorithm>
#include <cstdint>
#include <initializer_list>
#include <map>
#include <optional>
#include <set>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

#include "build/build_config.h"
#if BUILDFLAG(IS_POSIX)
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

#include "base/posix/eintr_wrapper.h"
#endif

#include "base/command_line.h"
#include "base/containers/span.h"
#include "base/files/file.h"
#include "base/files/file_enumerator.h"
#include "base/files/file_path.h"
#include "base/files/file_util.h"
#include "base/functional/bind.h"
#include "base/json/json_reader.h"
#include "base/json/json_writer.h"
#include "base/location.h"
#include "base/logging.h"
#include "base/memory/raw_ptr.h"
#include "base/memory/weak_ptr.h"
#include "base/strings/string_number_conversions.h"
#include "base/strings/string_util.h"
#include "base/strings/utf_string_conversions.h"
#include "base/time/time.h"
#include "base/timer/timer.h"
#include "base/values.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/tab_list/tab_list_interface.h"
#include "chrome/browser/ui/browser_window/public/browser_window_interface.h"
#include "chrome/browser/ui/browser_window/public/browser_window_interface_iterator.h"
#include "chrome/browser/ui/browser_window/public/create_browser_window.h"
#include "components/sessions/content/content_serialized_navigation_builder.h"
#include "components/sessions/core/serialized_navigation_entry.h"
#include "components/tab_groups/tab_group_color.h"
#include "components/tab_groups/tab_group_visual_data.h"
#include "components/tabs/public/tab_interface.h"
#include "content/public/browser/navigation_controller.h"
#include "content/public/browser/navigation_entry.h"
#include "content/public/browser/restore_type.h"
#include "content/public/browser/web_contents.h"
#include "crypto/sha2.h"
#include "ui/base/base_window.h"
#include "url/gurl.h"

namespace helium_sync {
namespace {

constexpr char kRestoreSwitch[] = "helium-restore-disposable-tabs";
constexpr char kDisposableRootMarker[] = ".helium-tabs-disposable-root-v1";
constexpr char kDisposableRootMarkerContent[] =
    "helium-tabs-disposable-root-v1\n";
constexpr char kProfileMarker[] = ".helium-tabs-disposable-browser-profile-v2";
constexpr char kProfileMarkerContent[] =
    "helium-tabs-disposable-browser-profile-v2\n";
constexpr char kPreparedMarker[] = ".helium-tabs-restore-prepared-v2";
constexpr char kInProgressMarker[] = ".helium-tabs-restore-in-progress-v2";
constexpr char kConsumedMarker[] = ".helium-tabs-restore-consumed-v2";
constexpr char kFailedMarker[] = ".helium-tabs-restore-failed-v2";
constexpr char kStateMarkerContent[] = "helium-tabs-restore-state-v2\n";
constexpr char kBrowserManifest[] = "browser-restore-manifest.json";
constexpr char kReceipt[] = ".helium-tabs-restore-receipt-v2.json";
constexpr char kRestoreSource[] = "restore-source";
constexpr char kRestoreManifest[] = "restore-manifest.json";
constexpr char kSession[] = "session.json";
constexpr int kSessionSchema = 2;
constexpr int kBrowserManifestSchema = 2;
constexpr int kRestoreManifestSchema = 1;
constexpr int kReceiptSchema = 2;
constexpr int kMaxWindows = BUILDFLAG(IS_ANDROID) ? 16 : 64;
constexpr int kMaxTabs = BUILDFLAG(IS_ANDROID) ? 750 : 2000;
constexpr int kMaxNavigations = 100;
constexpr int kMaxTotalNavigations = BUILDFLAG(IS_ANDROID) ? 5000 : 20000;
constexpr size_t kMaxSessionBytes = 16 * 1024 * 1024;
constexpr size_t kMaxManifestBytes = 64 * 1024;
constexpr size_t kMaxIdentifierBytes = 128;
constexpr size_t kMaxUrlBytes = 8192;
constexpr size_t kMaxTitleBytes = 4096;
constexpr base::TimeDelta kInitialWindowTimeout = base::Seconds(30);
constexpr base::TimeDelta kInitialWindowPoll = base::Milliseconds(250);

struct RestoreNavigation {
  GURL url;
  std::u16string title;
};

struct RestoreTab {
  std::string id;
  bool pinned = false;
  std::string group;
  std::string history_state;
  int current_index = 0;
  std::vector<RestoreNavigation> navigations;
};

struct RestoreGroup {
  std::string id;
  std::u16string title;
  tab_groups::TabGroupColorId color = tab_groups::TabGroupColorId::kGrey;
  bool collapsed = false;
};

struct RestoreWindow {
  std::string id;
  int active_index = 0;
  std::vector<RestoreGroup> groups;
  std::vector<RestoreTab> tabs;
};

struct RestorePlan {
  std::string source_generation;
  std::string source_device;
  std::string source_profile;
  std::string source_session_sha256;
  int window_count = 0;
  int tab_count = 0;
  int group_count = 0;
  int navigation_count = 0;
  std::vector<RestoreWindow> windows;
};

struct RuntimeWindow {
  base::WeakPtr<BrowserWindowInterface> browser;
  bool is_initial = false;
  std::optional<tabs::TabHandle> anchor;
  std::vector<tabs::TabHandle> restored_tabs;
  std::map<std::string, tab_groups::TabGroupId> groups;
};

bool HasExactKeys(const base::DictValue& dict,
                  std::initializer_list<std::string_view> keys) {
  if (dict.size() != keys.size()) {
    return false;
  }
  return std::all_of(keys.begin(), keys.end(),
                     [&](std::string_view key) { return dict.contains(key); });
}

bool ValidIdentifier(std::string_view value) {
  if (value.empty() || value.size() > kMaxIdentifierBytes ||
      !base::IsStringUTF8(value)) {
    return false;
  }
  return std::none_of(value.begin(), value.end(), [](char character) {
    const unsigned char byte = static_cast<unsigned char>(character);
    return byte < 0x20 || byte == 0x7f;
  });
}

bool ValidSlug(std::string_view value) {
  if (value.empty() || value.size() > 64) {
    return false;
  }
  for (size_t index = 0; index < value.size(); ++index) {
    const char character = value[index];
    if ((character >= 'a' && character <= 'z') ||
        (character >= '0' && character <= '9') ||
        (index > 0 &&
         (character == '.' || character == '_' || character == '-'))) {
      continue;
    }
    return false;
  }
  return true;
}

bool ValidSourceDevice(std::string_view value) {
  return value == "d" || value == "da" || value == "oneplus";
}

bool ValidSha256(std::string_view value) {
  if (value.size() != crypto::kSHA256Length * 2) {
    return false;
  }
  return std::all_of(value.begin(), value.end(), [](char character) {
    return (character >= '0' && character <= '9') ||
           (character >= 'a' && character <= 'f');
  });
}

std::string Sha256(std::string_view value) {
  return base::HexEncodeLower(crypto::SHA256HashString(value));
}

bool AllowedSnapshotUrl(const GURL& url) {
  return url.is_valid() && !url.scheme().empty();
}

bool SafeAnchorUrl(const GURL& url) {
  return url.is_empty() || url == GURL("about:blank") ||
         url == GURL("chrome://newtab/") ||
         url == GURL("chrome-native://newtab/");
}

std::optional<tab_groups::TabGroupColorId> ParseGroupColor(
    std::string_view value) {
  if (value == "grey") {
    return tab_groups::TabGroupColorId::kGrey;
  }
  if (value == "blue") {
    return tab_groups::TabGroupColorId::kBlue;
  }
  if (value == "red") {
    return tab_groups::TabGroupColorId::kRed;
  }
  if (value == "yellow") {
    return tab_groups::TabGroupColorId::kYellow;
  }
  if (value == "green") {
    return tab_groups::TabGroupColorId::kGreen;
  }
  if (value == "pink") {
    return tab_groups::TabGroupColorId::kPink;
  }
  if (value == "purple") {
    return tab_groups::TabGroupColorId::kPurple;
  }
  if (value == "cyan") {
    return tab_groups::TabGroupColorId::kCyan;
  }
  if (value == "orange") {
    return tab_groups::TabGroupColorId::kOrange;
  }
  return std::nullopt;
}

bool PrivateDirectory(const base::FilePath& path) {
  if (path.empty() || !path.IsAbsolute() || base::IsLink(path)) {
    return false;
  }
  base::File::Info info;
  if (!base::GetFileInfo(path, &info) || !info.is_directory) {
    return false;
  }
#if BUILDFLAG(IS_POSIX)
  int mode = 0;
  if (!base::GetPosixFilePermissions(path, &mode) || (mode & 0077) != 0) {
    return false;
  }
#endif
  return true;
}

bool ReadPrivateFile(const base::FilePath& path,
                     size_t max_size,
                     std::string* value) {
  if (!value || path.empty() || !path.IsAbsolute() || base::IsLink(path)) {
    return false;
  }
#if BUILDFLAG(IS_POSIX)
  const int descriptor = HANDLE_EINTR(
      open(path.value().c_str(), O_RDONLY | O_CLOEXEC | O_NOFOLLOW));
  if (descriptor < 0) {
    return false;
  }
  struct stat before = {};
  if (fstat(descriptor, &before) != 0 || !S_ISREG(before.st_mode) ||
      (before.st_mode & 0077) != 0 || before.st_size < 0 ||
      static_cast<uint64_t>(before.st_size) > max_size) {
    close(descriptor);
    return false;
  }
  base::File file{base::ScopedPlatformFile(descriptor)};
  std::string result(static_cast<size_t>(before.st_size), '\0');
  if (!file.ReadAtCurrentPosAndCheck(base::as_writable_byte_span(result))) {
    return false;
  }
  struct stat after = {};
  if (fstat(file.GetPlatformFile(), &after) != 0 ||
      before.st_dev != after.st_dev || before.st_ino != after.st_ino ||
      before.st_size != after.st_size) {
    return false;
  }
#if BUILDFLAG(IS_ANDROID)
  if (before.st_mtime != after.st_mtime ||
      before.st_mtime_nsec != after.st_mtime_nsec) {
    return false;
  }
#elif BUILDFLAG(IS_APPLE)
  if (before.st_mtimespec.tv_sec != after.st_mtimespec.tv_sec ||
      before.st_mtimespec.tv_nsec != after.st_mtimespec.tv_nsec) {
    return false;
  }
#else
  if (before.st_mtim.tv_sec != after.st_mtim.tv_sec ||
      before.st_mtim.tv_nsec != after.st_mtim.tv_nsec) {
    return false;
  }
#endif
  *value = std::move(result);
  return true;
#else
  base::File::Info info;
  if (!base::GetFileInfo(path, &info) || info.is_directory || info.size < 0 ||
      static_cast<uint64_t>(info.size) > max_size) {
    return false;
  }
#if BUILDFLAG(IS_POSIX)
  int mode = 0;
  if (!base::GetPosixFilePermissions(path, &mode) || (mode & 0077) != 0) {
    return false;
  }
#endif
  return base::ReadFileToStringWithMaxSize(path, value, max_size);
#endif
}

bool ExactMarker(const base::FilePath& path, std::string_view expected) {
  std::string value;
  return ReadPrivateFile(path, 256, &value) && value == expected;
}

bool SyncDirectory(const base::FilePath& path) {
#if BUILDFLAG(IS_POSIX)
  base::File directory(path, base::File::FLAG_OPEN | base::File::FLAG_READ);
  return directory.IsValid() && directory.Flush();
#else
  return true;
#endif
}

bool TransitionMarker(const base::FilePath& root,
                      std::string_view from,
                      std::string_view to) {
  const base::FilePath source = root.AppendASCII(from);
  const base::FilePath destination = root.AppendASCII(to);
  if (!ExactMarker(source, kStateMarkerContent) ||
      base::PathExists(destination) || !base::Move(source, destination)) {
    return false;
  }
  return SyncDirectory(root);
}

std::vector<BrowserWindowInterface*> ProfileWindows(Profile* profile) {
  std::vector<BrowserWindowInterface*> windows;
  for (BrowserWindowInterface* browser : GetAllBrowserWindowInterfaces()) {
    if (browser && browser->GetProfile() == profile &&
        browser->GetType() == BrowserWindowInterface::TYPE_NORMAL &&
        !browser->IsDeleteScheduled()) {
      windows.push_back(browser);
    }
  }
  return windows;
}

bool IsSafeAnchor(TabListInterface* tab_list, tabs::TabInterface* tab) {
  return tab_list && tab && tab_list->GetTabCount() == 1 && !tab->IsPinned() &&
         !tab->GetGroup() && SafeAnchorUrl(tab->GetURL());
}

bool ParseFileRecord(const base::DictValue& record,
                     std::string* sha256,
                     int* size) {
  if (!HasExactKeys(record, {"sha256", "size"})) {
    return false;
  }
  const std::string* parsed_hash = record.FindString("sha256");
  std::optional<int> parsed_size = record.FindInt("size");
  if (!parsed_hash || !ValidSha256(*parsed_hash) || !parsed_size ||
      *parsed_size <= 0) {
    return false;
  }
  *sha256 = *parsed_hash;
  *size = *parsed_size;
  return true;
}

bool ParseSession(std::string_view raw, RestorePlan* plan, std::string* error) {
  std::optional<base::DictValue> root =
      base::JSONReader::ReadDict(raw, base::JSON_PARSE_RFC, 20);
  if (!root || !HasExactKeys(*root, {"schema_version", "windows"}) ||
      root->FindInt("schema_version") != kSessionSchema) {
    *error = "session-schema";
    return false;
  }
  const base::ListValue* windows = root->FindList("windows");
  if (!windows || windows->empty() ||
      windows->size() > static_cast<size_t>(kMaxWindows)) {
    *error = "session-window-count";
    return false;
  }

  std::set<std::string> window_ids;
  std::set<std::string> tab_ids;
  std::set<std::string> global_group_ids;
  int tab_count = 0;
  int group_count = 0;
  int navigation_count = 0;
  for (const base::Value& window_value : *windows) {
    const base::DictValue* window_dict = window_value.GetIfDict();
    if (!window_dict ||
        !HasExactKeys(*window_dict, {"id", "active_index", "groups", "tabs"})) {
      *error = "session-window-shape";
      return false;
    }
    const std::string* window_id = window_dict->FindString("id");
    std::optional<int> active_index = window_dict->FindInt("active_index");
    const base::ListValue* groups = window_dict->FindList("groups");
    const base::ListValue* tabs = window_dict->FindList("tabs");
    if (!window_id || !ValidIdentifier(*window_id) ||
        !window_ids.insert(*window_id).second || !active_index || !groups ||
        !tabs || tabs->empty()) {
      *error = "session-window-fields";
      return false;
    }
    if (*active_index < 0 || *active_index >= static_cast<int>(tabs->size())) {
      *error = "session-active-index";
      return false;
    }

    RestoreWindow window;
    window.id = *window_id;
    window.active_index = *active_index;
    std::map<std::string, int> group_first;
    std::map<std::string, int> group_last;
    std::map<std::string, int> group_use_count;
    for (const base::Value& group_value : *groups) {
      const base::DictValue* group_dict = group_value.GetIfDict();
      if (!group_dict ||
          !HasExactKeys(*group_dict, {"id", "title", "color", "collapsed",
                                      "metadata_state"})) {
        *error = "session-group-shape";
        return false;
      }
      const std::string* id = group_dict->FindString("id");
      const std::string* title = group_dict->FindString("title");
      const std::string* color = group_dict->FindString("color");
      std::optional<bool> collapsed = group_dict->FindBool("collapsed");
      const std::string* metadata = group_dict->FindString("metadata_state");
      std::optional<tab_groups::TabGroupColorId> color_id =
          color ? ParseGroupColor(*color) : std::nullopt;
      if (!id || !ValidIdentifier(*id) ||
          !global_group_ids.insert(*id).second || !title ||
          title->size() > kMaxTitleBytes || !base::IsStringUTF8(*title) ||
          !color_id || !collapsed || !metadata || *metadata != "complete") {
        *error = "session-group-fields";
        return false;
      }
      window.groups.push_back(RestoreGroup{
          .id = *id,
          .title = base::UTF8ToUTF16(*title),
          .color = *color_id,
          .collapsed = *collapsed,
      });
      ++group_count;
    }

    bool seen_unpinned = false;
    for (size_t tab_index = 0; tab_index < tabs->size(); ++tab_index) {
      const base::DictValue* tab_dict = (*tabs)[tab_index].GetIfDict();
      if (!tab_dict ||
          !HasExactKeys(*tab_dict, {"id", "pinned", "group", "history_state",
                                    "current_index", "navigations"})) {
        *error = "session-tab-shape";
        return false;
      }
      const std::string* id = tab_dict->FindString("id");
      std::optional<bool> pinned = tab_dict->FindBool("pinned");
      const std::string* group = tab_dict->FindString("group");
      const std::string* history = tab_dict->FindString("history_state");
      std::optional<int> current = tab_dict->FindInt("current_index");
      const base::ListValue* navigations = tab_dict->FindList("navigations");
      if (!id || !ValidIdentifier(*id) || !tab_ids.insert(*id).second ||
          !pinned || !group || !history ||
          (*history != "bounded" && *history != "current-only-unloaded" &&
           *history != "legacy-bounded") ||
          !current || !navigations || navigations->empty() ||
          navigations->size() > static_cast<size_t>(kMaxNavigations) ||
          *current < 0 || *current >= static_cast<int>(navigations->size())) {
        *error = "session-tab-fields";
        return false;
      }
      if (*pinned && seen_unpinned) {
        *error = "session-pinned-order";
        return false;
      }
      if (!*pinned) {
        seen_unpinned = true;
      }
      if (*pinned && !group->empty()) {
        *error = "session-pinned-group";
        return false;
      }

      RestoreTab tab;
      tab.id = *id;
      tab.pinned = *pinned;
      tab.group = *group;
      tab.history_state = *history;
      tab.current_index = *current;
      for (const base::Value& navigation_value : *navigations) {
        const base::DictValue* navigation_dict = navigation_value.GetIfDict();
        if (!navigation_dict ||
            !HasExactKeys(*navigation_dict, {"url", "title"})) {
          *error = "session-navigation-shape";
          return false;
        }
        const std::string* url = navigation_dict->FindString("url");
        const std::string* title = navigation_dict->FindString("title");
        if (!url || url->size() > kMaxUrlBytes || !title ||
            title->size() > kMaxTitleBytes || !base::IsStringUTF8(*title) ||
            !AllowedSnapshotUrl(GURL(*url))) {
          *error = "session-navigation-fields";
          return false;
        }
        tab.navigations.push_back(
            RestoreNavigation{GURL(*url), base::UTF8ToUTF16(*title)});
        if (++navigation_count > kMaxTotalNavigations) {
          *error = "session-total-navigation-count";
          return false;
        }
      }
      if (!tab.group.empty()) {
        const auto group_it =
            std::find_if(window.groups.begin(), window.groups.end(),
                         [&](const RestoreGroup& candidate) {
                           return candidate.id == tab.group;
                         });
        if (group_it == window.groups.end()) {
          *error = "session-unknown-group";
          return false;
        }
        if (group_use_count[tab.group] == 0) {
          group_first[tab.group] = static_cast<int>(tab_index);
        }
        group_last[tab.group] = static_cast<int>(tab_index);
        ++group_use_count[tab.group];
      }
      window.tabs.push_back(std::move(tab));
      if (++tab_count > kMaxTabs) {
        *error = "session-tab-count";
        return false;
      }
    }
    for (const RestoreGroup& group : window.groups) {
      if (group_use_count[group.id] == 0 ||
          group_last[group.id] - group_first[group.id] + 1 !=
              group_use_count[group.id]) {
        *error = "session-group-contiguity";
        return false;
      }
    }
    plan->windows.push_back(std::move(window));
  }
  plan->window_count = static_cast<int>(plan->windows.size());
  plan->tab_count = tab_count;
  plan->group_count = group_count;
  plan->navigation_count = navigation_count;
  return true;
}

bool ParsePreparedPlan(const base::FilePath& root,
                       std::string_view requested_device,
                       RestorePlan* plan,
                       std::string* error) {
  std::string browser_manifest_raw;
  std::string restore_manifest_raw;
  std::string session_raw;
  const base::FilePath source = root.AppendASCII(kRestoreSource);
  base::FileEnumerator source_files(source, false,
                                    base::FileEnumerator::FILES |
                                        base::FileEnumerator::DIRECTORIES |
                                        base::FileEnumerator::SHOW_SYM_LINKS);
  std::set<std::string> source_inventory;
  for (base::FilePath item = source_files.Next(); !item.empty();
       item = source_files.Next()) {
    source_inventory.insert(item.BaseName().AsUTF8Unsafe());
  }
  if (!PrivateDirectory(source) ||
      source_inventory != std::set<std::string>{kRestoreManifest, kSession} ||
      !ReadPrivateFile(root.AppendASCII(kBrowserManifest), kMaxManifestBytes,
                       &browser_manifest_raw) ||
      !ReadPrivateFile(source.AppendASCII(kRestoreManifest), kMaxManifestBytes,
                       &restore_manifest_raw) ||
      !ReadPrivateFile(source.AppendASCII(kSession), kMaxSessionBytes,
                       &session_raw)) {
    *error = "prepared-file-boundary";
    return false;
  }

  std::optional<base::DictValue> browser_manifest = base::JSONReader::ReadDict(
      browser_manifest_raw, base::JSON_PARSE_RFC, 10);
  if (!browser_manifest ||
      !HasExactKeys(
          *browser_manifest,
          {"schema_version", "source_generation", "source_device",
           "source_profile", "source_session", "preferences", "window_count",
           "tab_count", "group_count", "invocation", "prepared_at", "state"}) ||
      browser_manifest->FindInt("schema_version") != kBrowserManifestSchema) {
    *error = "browser-manifest-schema";
    return false;
  }

  const std::string* generation =
      browser_manifest->FindString("source_generation");
  const std::string* device = browser_manifest->FindString("source_device");
  const std::string* profile = browser_manifest->FindString("source_profile");
  const base::DictValue* source_session =
      browser_manifest->FindDict("source_session");
  const base::DictValue* preferences =
      browser_manifest->FindDict("preferences");
  std::optional<int> window_count = browser_manifest->FindInt("window_count");
  std::optional<int> tab_count = browser_manifest->FindInt("tab_count");
  std::optional<int> group_count = browser_manifest->FindInt("group_count");
  const std::string* invocation = browser_manifest->FindString("invocation");
  const std::string* prepared_at = browser_manifest->FindString("prepared_at");
  const std::string* state = browser_manifest->FindString("state");
  std::string session_hash;
  int session_size = 0;
  std::string preferences_hash;
  int preferences_size = 0;
  if (!generation || !ValidIdentifier(*generation) || !device ||
      *device != requested_device || !ValidSourceDevice(*device) || !profile ||
      !ValidIdentifier(*profile) || !source_session ||
      !ParseFileRecord(*source_session, &session_hash, &session_size) ||
      !preferences ||
      !ParseFileRecord(*preferences, &preferences_hash, &preferences_size) ||
      preferences_size != 3 || preferences_hash != Sha256("{}\n") ||
      !window_count || *window_count <= 0 || *window_count > kMaxWindows ||
      !tab_count || *tab_count <= 0 || *tab_count > kMaxTabs || !group_count ||
      *group_count < 0 || *group_count > kMaxTabs || !invocation ||
      *invocation != "explicit-command-line-only" || !prepared_at ||
      prepared_at->empty() || !state || *state != "prepared-not-opened" ||
      session_size != static_cast<int>(session_raw.size()) ||
      session_hash != Sha256(session_raw)) {
    *error = "browser-manifest-fields";
    return false;
  }

  std::optional<base::DictValue> restore_manifest = base::JSONReader::ReadDict(
      restore_manifest_raw, base::JSON_PARSE_RFC, 10);
  if (!restore_manifest ||
      !HasExactKeys(
          *restore_manifest,
          {"schema_version", "source_generation", "source_device",
           "source_profile", "restored_at", "validation", "session"}) ||
      restore_manifest->FindInt("schema_version") != kRestoreManifestSchema ||
      restore_manifest->FindString("source_generation") == nullptr ||
      *restore_manifest->FindString("source_generation") != *generation ||
      restore_manifest->FindString("source_device") == nullptr ||
      *restore_manifest->FindString("source_device") != *device ||
      restore_manifest->FindString("source_profile") == nullptr ||
      *restore_manifest->FindString("source_profile") != *profile ||
      restore_manifest->FindString("restored_at") == nullptr ||
      restore_manifest->FindString("restored_at")->empty() ||
      restore_manifest->FindString("validation") == nullptr ||
      *restore_manifest->FindString("validation") != "valid") {
    *error = "restore-manifest-fields";
    return false;
  }
  const base::DictValue* restore_session =
      restore_manifest->FindDict("session");
  std::string restore_hash;
  int restore_size = 0;
  if (!restore_session ||
      !ParseFileRecord(*restore_session, &restore_hash, &restore_size) ||
      restore_hash != session_hash || restore_size != session_size) {
    *error = "restore-manifest-session";
    return false;
  }

  plan->source_generation = *generation;
  plan->source_device = *device;
  plan->source_profile = *profile;
  plan->source_session_sha256 = session_hash;
  if (!ParseSession(session_raw, plan, error)) {
    return false;
  }
  if (plan->window_count != *window_count || plan->tab_count != *tab_count ||
      plan->group_count != *group_count) {
    *error = "browser-manifest-counts";
    return false;
  }
  return true;
}

}  // namespace

struct HeliumTabRestoreBridge::Impl {
  explicit Impl(Profile* profile) : profile_(profile) {}

  void Start() {
    if (!profile_) {
      return;
    }
    const base::CommandLine* command_line =
        base::CommandLine::ForCurrentProcess();
    requested_device_ = command_line->GetSwitchValueASCII(kRestoreSwitch);
    if (!ValidSourceDevice(requested_device_)) {
      LOG(ERROR) << "Helium tab restore refused: invalid source device";
      return;
    }
    if (!EstablishDisposableRoot()) {
      LOG(ERROR) << "Helium tab restore refused: profile is not a marked drill";
      return;
    }
    if (!AdmitPreparedState()) {
      return;
    }
    deadline_ = base::TimeTicks::Now() + kInitialWindowTimeout;
    WaitForInitialWindow();
  }

  void Stop() {
    retry_timer_.Stop();
    weak_factory_.InvalidateWeakPtrs();
  }

  bool EstablishDisposableRoot() {
    const base::FilePath profile_path = profile_->GetPath();
    if (!profile_path.IsAbsolute() ||
        profile_path.BaseName() !=
            base::FilePath(FILE_PATH_LITERAL("Default"))) {
      return false;
    }
    root_ = profile_path.DirName();
    const std::string root_name = root_.BaseName().AsUTF8Unsafe();
    if (!base::StartsWith(root_name, "drill-") || !ValidSlug(root_name) ||
        !PrivateDirectory(root_) || !PrivateDirectory(profile_path) ||
        !PrivateDirectory(root_.DirName()) ||
        !ExactMarker(root_.DirName().AppendASCII(kDisposableRootMarker),
                     kDisposableRootMarkerContent) ||
        !ExactMarker(root_.AppendASCII(kProfileMarker),
                     kProfileMarkerContent)) {
      return false;
    }
    return true;
  }

  bool AdmitPreparedState() {
    int state_count = 0;
    std::string state;
    for (std::string_view candidate :
         {kPreparedMarker, kInProgressMarker, kConsumedMarker, kFailedMarker}) {
      if (base::PathExists(root_.AppendASCII(candidate))) {
        ++state_count;
        state = candidate;
      }
    }
    if (state_count != 1 ||
        !ExactMarker(root_.AppendASCII(state), kStateMarkerContent)) {
      LOG(ERROR) << "Helium tab restore refused: invalid restore state";
      return false;
    }
    if (state != kPreparedMarker) {
      std::string parse_error;
      RestorePlan terminal_plan;
      if (!ParsePreparedPlan(root_, requested_device_, &terminal_plan,
                             &parse_error)) {
        LOG(ERROR) << "Helium tab restore refused: terminal source changed: "
                   << parse_error;
        return false;
      }
      plan_ = std::move(terminal_plan);
    }
    if (state == kConsumedMarker) {
      if (!ValidReceipt("applied")) {
        LOG(ERROR) << "Helium tab restore refused: consumed receipt invalid";
      }
      return false;
    }
    if (state == kFailedMarker) {
      if (!ValidReceipt("failed")) {
        LOG(ERROR) << "Helium tab restore refused: failed receipt invalid";
      }
      return false;
    }
    if (state == kInProgressMarker) {
      if (ValidReceipt("applied")) {
        if (!TransitionMarker(root_, kInProgressMarker, kConsumedMarker)) {
          LOG(ERROR) << "Helium tab restore could not finalize applied state";
        }
      } else if (ValidReceipt("failed")) {
        if (!TransitionMarker(root_, kInProgressMarker, kFailedMarker)) {
          LOG(ERROR) << "Helium tab restore could not finalize failed state";
        }
      } else {
        LOG(ERROR) << "Helium tab restore refused: interrupted state requires "
                      "discarding this disposable profile";
      }
      return false;
    }
    if (base::PathExists(root_.AppendASCII(kReceipt))) {
      LOG(ERROR) << "Helium tab restore refused: unexpected prepared receipt";
      return false;
    }
    std::string error;
    RestorePlan prepared_plan;
    if (!ParsePreparedPlan(root_, requested_device_, &prepared_plan, &error)) {
      LOG(ERROR) << "Helium tab restore refused: " << error;
      return false;
    }
    if (!TransitionMarker(root_, kPreparedMarker, kInProgressMarker)) {
      LOG(ERROR) << "Helium tab restore refused: state transition failed";
      return false;
    }
    plan_ = std::move(prepared_plan);
    state_started_ = true;
    return true;
  }

  void WaitForInitialWindow() {
    std::vector<BrowserWindowInterface*> windows = ProfileWindows(profile_);
    if (windows.empty() && base::TimeTicks::Now() < deadline_) {
      retry_timer_.Start(FROM_HERE, kInitialWindowPoll,
                         base::BindOnce(&Impl::WaitForInitialWindow,
                                        weak_factory_.GetWeakPtr()));
      return;
    }
    if (windows.size() != 1) {
      Fail(windows.empty() ? "initial-window-timeout" : "initial-window-count",
           false);
      return;
    }
    TabListInterface* tab_list = TabListInterface::From(windows[0]);
    if (!tab_list || !TabListInterface::CanEditTabList(*profile_) ||
        !IsSafeAnchor(tab_list, tab_list->GetTab(0))) {
      Fail("initial-window-not-empty", false);
      return;
    }
    if (!RestoreWindowAt(0, windows[0], true)) {
      return;
    }
    ContinueWithWindow(1);
  }

  void ContinueWithWindow(size_t index) {
    if (index >= plan_.windows.size()) {
      Finalize();
      return;
    }
    if (GetBrowserWindowCreationStatusForProfile(*profile_) !=
        BrowserWindowInterface::CreationStatus::kOk) {
      Fail("window-creation-not-allowed", true);
      return;
    }
    CreateBrowserWindow(
        BrowserWindowCreateParams(*profile_, /*from_user_gesture=*/false),
        base::BindOnce(&Impl::OnWindowCreated, weak_factory_.GetWeakPtr(),
                       index));
  }

  void OnWindowCreated(size_t index, BrowserWindowInterface* browser) {
    if (!browser || browser->GetProfile() != profile_ ||
        browser->GetType() != BrowserWindowInterface::TYPE_NORMAL ||
        ProfileWindows(profile_).size() != index + 1) {
      if (browser && browser->GetProfile() == profile_ &&
          browser->GetType() == BrowserWindowInterface::TYPE_NORMAL) {
        browser->GetWindow()->Close();
      }
      Fail("window-creation-result", true);
      return;
    }
    if (!RestoreWindowAt(index, browser, false)) {
      return;
    }
    ContinueWithWindow(index + 1);
  }

  bool RestoreWindowAt(size_t index,
                       BrowserWindowInterface* browser,
                       bool is_initial) {
    if (index >= plan_.windows.size() || !browser) {
      Fail("window-index", true);
      return false;
    }
    TabListInterface* tab_list = TabListInterface::From(browser);
    if (!tab_list || !TabListInterface::CanEditTabList(*profile_) ||
        tab_list->GetTabCount() > 1 ||
        (tab_list->GetTabCount() == 1 &&
         !IsSafeAnchor(tab_list, tab_list->GetTab(0))) ||
        (is_initial && tab_list->GetTabCount() != 1)) {
      Fail("window-anchor", true);
      return false;
    }

    RuntimeWindow runtime{
        .browser = browser->GetWeakPtr(),
        .is_initial = is_initial,
    };
    if (tab_list->GetTabCount() == 1) {
      runtime.anchor = tab_list->GetTab(0)->GetHandle();
    }
    runtime_windows_.push_back(std::move(runtime));
    RuntimeWindow& inserted = runtime_windows_.back();
    const RestoreWindow& source = plan_.windows[index];

    for (const RestoreTab& tab : source.tabs) {
      content::WebContents::CreateParams create_params(profile_);
      create_params.desired_renderer_state =
          content::WebContents::CreateParams::kNoRendererProcess;
      std::unique_ptr<content::WebContents> contents =
          content::WebContents::Create(create_params);
      if (!contents) {
        Fail("web-contents-create", true);
        return false;
      }
      std::vector<sessions::SerializedNavigationEntry> serialized;
      serialized.reserve(tab.navigations.size());
      for (size_t navigation_index = 0;
           navigation_index < tab.navigations.size(); ++navigation_index) {
        const RestoreNavigation& navigation = tab.navigations[navigation_index];
        sessions::SerializedNavigationEntry entry;
        entry.set_index(static_cast<int>(navigation_index));
        entry.set_virtual_url(navigation.url);
        entry.set_original_request_url(navigation.url);
        entry.set_title(navigation.title);
        entry.set_is_restored(true);
        serialized.push_back(std::move(entry));
      }
      std::vector<std::unique_ptr<content::NavigationEntry>> entries =
          sessions::ContentSerializedNavigationBuilder::ToNavigationEntries(
              serialized, profile_);
      if (entries.size() != serialized.size()) {
        Fail("navigation-conversion", true);
        return false;
      }
      contents->GetController().Restore(
          tab.current_index, content::RestoreType::kRestored, &entries);
      tabs::TabInterface* inserted_tab = tab_list->InsertWebContentsAt(
          tab_list->GetTabCount(), std::move(contents), tab.pinned,
          std::nullopt);
      if (!inserted_tab) {
        Fail("tab-insertion", true);
        return false;
      }
      inserted.restored_tabs.push_back(inserted_tab->GetHandle());
    }

    for (const RestoreGroup& group : source.groups) {
      std::vector<tabs::TabHandle> handles;
      for (size_t tab_index = 0; tab_index < source.tabs.size(); ++tab_index) {
        if (source.tabs[tab_index].group == group.id) {
          handles.push_back(inserted.restored_tabs[tab_index]);
        }
      }
      std::optional<tab_groups::TabGroupId> created =
          tab_list->CreateTabGroup(handles);
      if (!created) {
        Fail("group-creation", true);
        return false;
      }
      tab_list->SetTabGroupVisualData(
          *created, tab_groups::TabGroupVisualData(group.title, group.color,
                                                   group.collapsed));
      inserted.groups.emplace(group.id, *created);
    }
    tab_list->ActivateTab(
        inserted.restored_tabs[static_cast<size_t>(source.active_index)]);
    if (!ValidateRuntimeWindow(index, inserted, true)) {
      Fail("window-readback-before-commit", true);
      return false;
    }
    if (!is_initial) {
      browser->GetWindow()->ShowInactive();
    }
    return true;
  }

  bool ValidateRuntimeWindow(size_t index,
                             const RuntimeWindow& runtime,
                             bool allow_anchor) {
    if (index >= plan_.windows.size() || !runtime.browser) {
      return false;
    }
    TabListInterface* tab_list = TabListInterface::From(runtime.browser.get());
    if (!tab_list) {
      return false;
    }
    const RestoreWindow& source = plan_.windows[index];
    std::vector<tabs::TabInterface*> actual;
    for (tabs::TabInterface* tab : tab_list->GetAllTabs()) {
      if (allow_anchor && runtime.anchor &&
          tab->GetHandle() == *runtime.anchor) {
        continue;
      }
      actual.push_back(tab);
    }
    if (actual.size() != source.tabs.size() ||
        runtime.restored_tabs.size() != source.tabs.size() ||
        tab_list->ListTabGroups().size() != source.groups.size()) {
      return false;
    }
    for (size_t tab_index = 0; tab_index < source.tabs.size(); ++tab_index) {
      const RestoreTab& expected = source.tabs[tab_index];
      tabs::TabInterface* tab = actual[tab_index];
      if (!tab || tab->GetHandle() != runtime.restored_tabs[tab_index] ||
          tab->IsPinned() != expected.pinned || !tab->GetContents()) {
        return false;
      }
      if (expected.group.empty()) {
        if (tab->GetGroup()) {
          return false;
        }
      } else {
        auto group = runtime.groups.find(expected.group);
        if (group == runtime.groups.end() || !tab->GetGroup() ||
            *tab->GetGroup() != group->second) {
          return false;
        }
      }
      content::NavigationController& controller =
          tab->GetContents()->GetController();
      if (controller.GetEntryCount() !=
              static_cast<int>(expected.navigations.size()) ||
          controller.GetCurrentEntryIndex() != expected.current_index) {
        return false;
      }
      for (size_t navigation_index = 0;
           navigation_index < expected.navigations.size(); ++navigation_index) {
        content::NavigationEntry* entry =
            controller.GetEntryAtIndex(static_cast<int>(navigation_index));
        if (!entry ||
            entry->GetVirtualURL() !=
                expected.navigations[navigation_index].url ||
            entry->GetTitle() != expected.navigations[navigation_index].title) {
          return false;
        }
      }
    }
    for (const RestoreGroup& expected : source.groups) {
      auto actual_group = runtime.groups.find(expected.id);
      if (actual_group == runtime.groups.end() ||
          !tab_list->ContainsTabGroup(actual_group->second)) {
        return false;
      }
      std::optional<tab_groups::TabGroupVisualData> visual =
          tab_list->GetTabGroupVisualData(actual_group->second);
      if (!visual || visual->title() != expected.title ||
          visual->color() != expected.color ||
          visual->is_collapsed() != expected.collapsed) {
        return false;
      }
    }
    tabs::TabInterface* active = tab_list->GetActiveTab();
    return active &&
           active->GetHandle() ==
               runtime.restored_tabs[static_cast<size_t>(source.active_index)];
  }

  void Finalize() {
    if (runtime_windows_.size() != plan_.windows.size() ||
        ProfileWindows(profile_).size() != plan_.windows.size()) {
      Fail("final-window-count", true);
      return;
    }
    for (RuntimeWindow& runtime : runtime_windows_) {
      if (!runtime.browser) {
        Fail("final-anchor-state", true);
        return;
      }
      TabListInterface* tab_list =
          TabListInterface::From(runtime.browser.get());
      if (!tab_list) {
        Fail("final-anchor-missing", true);
        return;
      }
      if (runtime.anchor) {
        if (tab_list->GetIndexOfTab(*runtime.anchor) < 0) {
          Fail("final-anchor-missing", true);
          return;
        }
        tab_list->CloseTab(*runtime.anchor);
        runtime.anchor.reset();
      }
    }
    for (size_t index = 0; index < runtime_windows_.size(); ++index) {
      if (!ValidateRuntimeWindow(index, runtime_windows_[index], false)) {
        Fail("final-topology-readback", true);
        return;
      }
    }
    if (!WriteReceipt("applied", "") ||
        !TransitionMarker(root_, kInProgressMarker, kConsumedMarker)) {
      LOG(ERROR) << "Helium tab restore applied but receipt finalization "
                    "requires restart recovery";
      return;
    }
    state_started_ = false;
    LOG(INFO) << "Helium tab restore applied to marked disposable profile";
  }

  bool Rollback() {
    bool asynchronous_window_close = false;
    for (auto iterator = runtime_windows_.rbegin();
         iterator != runtime_windows_.rend(); ++iterator) {
      RuntimeWindow& runtime = *iterator;
      if (!runtime.browser) {
        continue;
      }
      if (!runtime.is_initial) {
        runtime.browser->GetWindow()->Close();
        asynchronous_window_close = true;
        continue;
      }
      TabListInterface* tab_list =
          TabListInterface::From(runtime.browser.get());
      if (!tab_list) {
        continue;
      }
      tabs::TabInterface* anchor = nullptr;
      if (runtime.anchor && tab_list->GetIndexOfTab(*runtime.anchor) >= 0) {
        anchor = tab_list->GetTab(tab_list->GetIndexOfTab(*runtime.anchor));
      }
      if (!anchor) {
        anchor = tab_list->OpenTab(GURL("about:blank"), 0, true);
      }
      for (tabs::TabHandle handle : runtime.restored_tabs) {
        if (tab_list->GetIndexOfTab(handle) >= 0) {
          tab_list->CloseTab(handle);
        }
      }
      if (anchor && tab_list->GetIndexOfTab(anchor->GetHandle()) >= 0) {
        tab_list->ActivateTab(anchor->GetHandle());
      }
    }
    if (asynchronous_window_close) {
      // BaseWindow::Close is asynchronous. Never assert a terminal rollback
      // result until a later process can prove the disposable state.
      return false;
    }
    std::vector<BrowserWindowInterface*> windows = ProfileWindows(profile_);
    if (windows.size() != 1) {
      return false;
    }
    TabListInterface* tab_list = TabListInterface::From(windows[0]);
    if (!tab_list || !IsSafeAnchor(tab_list, tab_list->GetTab(0))) {
      return false;
    }
    for (const RuntimeWindow& runtime : runtime_windows_) {
      for (tabs::TabHandle handle : runtime.restored_tabs) {
        if (tab_list->GetIndexOfTab(handle) >= 0) {
          return false;
        }
      }
    }
    runtime_windows_.clear();
    return true;
  }

  bool WriteReceipt(std::string_view state, std::string_view error) {
    base::DictValue receipt;
    receipt.Set("schema_version", kReceiptSchema);
    receipt.Set("state", state);
    receipt.Set("source_generation", plan_.source_generation);
    receipt.Set("source_device", requested_device_);
    receipt.Set("source_profile", plan_.source_profile);
    receipt.Set("source_session_sha256", plan_.source_session_sha256);
    receipt.Set("window_count", plan_.window_count);
    receipt.Set("tab_count", plan_.tab_count);
    receipt.Set("group_count", plan_.group_count);
    receipt.Set("readback_validation", state == "applied"
                                           ? "exact-supported-live-topology"
                                           : "verified-rollback");
    receipt.Set(
        "completed_at_unix_millis",
        base::NumberToString(base::Time::Now().InMillisecondsSinceUnixEpoch()));
    receipt.Set("error", error);
    std::string raw;
    if (!base::JSONWriter::WriteWithOptions(
            receipt, base::JSONWriter::OPTIONS_PRETTY_PRINT, &raw)) {
      return false;
    }
    raw.push_back('\n');
    const base::FilePath path = root_.AppendASCII(kReceipt);
    if (base::PathExists(path)) {
      return false;
    }
    base::FilePath temporary;
    if (!base::CreateTemporaryFileInDir(root_, &temporary)) {
      return false;
    }
    bool written = false;
    {
      base::File file(temporary,
                      base::File::FLAG_OPEN | base::File::FLAG_WRITE);
      written = file.IsValid() &&
                file.WriteAtCurrentPosAndCheck(base::as_byte_span(raw)) &&
                file.Flush();
    }
#if BUILDFLAG(IS_POSIX)
    written = written && base::SetPosixFilePermissions(temporary, 0600);
#endif
    if (!written || !base::Move(temporary, path) || !SyncDirectory(root_)) {
      base::DeleteFile(temporary);
      return false;
    }
    std::string readback;
    return ReadPrivateFile(path, kMaxManifestBytes, &readback) &&
           readback == raw;
  }

  bool ValidReceipt(std::string_view expected_state) {
    std::string raw;
    if (!ReadPrivateFile(root_.AppendASCII(kReceipt), kMaxManifestBytes,
                         &raw)) {
      return false;
    }
    std::optional<base::DictValue> receipt =
        base::JSONReader::ReadDict(raw, base::JSON_PARSE_RFC, 10);
    if (!receipt ||
        !HasExactKeys(
            *receipt,
            {"schema_version", "state", "source_generation", "source_device",
             "source_profile", "source_session_sha256", "window_count",
             "tab_count", "group_count", "readback_validation",
             "completed_at_unix_millis", "error"}) ||
        receipt->FindInt("schema_version") != kReceiptSchema ||
        receipt->FindString("state") == nullptr ||
        *receipt->FindString("state") != expected_state ||
        receipt->FindString("source_device") == nullptr ||
        *receipt->FindString("source_device") != requested_device_ ||
        receipt->FindString("completed_at_unix_millis") == nullptr ||
        receipt->FindString("completed_at_unix_millis")->empty() ||
        receipt->FindString("error") == nullptr) {
      return false;
    }
    const std::string* generation = receipt->FindString("source_generation");
    const std::string* profile = receipt->FindString("source_profile");
    const std::string* sha = receipt->FindString("source_session_sha256");
    const std::string* validation = receipt->FindString("readback_validation");
    std::optional<int> windows = receipt->FindInt("window_count");
    std::optional<int> tabs = receipt->FindInt("tab_count");
    std::optional<int> groups = receipt->FindInt("group_count");
    if (!generation || *generation != plan_.source_generation || !profile ||
        *profile != plan_.source_profile || !sha ||
        *sha != plan_.source_session_sha256 || !validation || !windows ||
        *windows != plan_.window_count || !tabs || *tabs != plan_.tab_count ||
        !groups || *groups != plan_.group_count) {
      return false;
    }
    if (expected_state == "applied") {
      return *validation == "exact-supported-live-topology" &&
             receipt->FindString("error")->empty();
    }
    return *validation == "verified-rollback" &&
           !receipt->FindString("error")->empty();
  }

  void Fail(std::string_view error, bool rollback) {
    if (!state_started_) {
      return;
    }
    retry_timer_.Stop();
    if (rollback && !Rollback()) {
      LOG(ERROR) << "Helium tab restore rollback incomplete; the marked "
                    "disposable profile remains in-progress and must be "
                    "discarded: "
                 << error;
      return;
    }
    if (!WriteReceipt("failed", error) ||
        !TransitionMarker(root_, kInProgressMarker, kFailedMarker)) {
      LOG(ERROR) << "Helium tab restore failed and remains fail-closed "
                    "in progress";
    } else {
      state_started_ = false;
      LOG(ERROR) << "Helium tab restore failed: " << error;
    }
  }

  raw_ptr<Profile> profile_;
  std::string requested_device_;
  base::FilePath root_;
  RestorePlan plan_;
  std::vector<RuntimeWindow> runtime_windows_;
  base::TimeTicks deadline_;
  bool state_started_ = false;
  base::OneShotTimer retry_timer_;
  base::WeakPtrFactory<Impl> weak_factory_{this};
};

bool HeliumTabRestoreBridge::IsRequested() {
  return base::CommandLine::ForCurrentProcess()->HasSwitch(kRestoreSwitch);
}

HeliumTabRestoreBridge::HeliumTabRestoreBridge(Profile* profile)
    : impl_(std::make_unique<Impl>(profile)) {}

HeliumTabRestoreBridge::~HeliumTabRestoreBridge() {
  Stop();
}

void HeliumTabRestoreBridge::Start() {
  impl_->Start();
}

void HeliumTabRestoreBridge::Stop() {
  impl_->Stop();
}

}  // namespace helium_sync
