// Copyright 2026 The Helium Authors

#include "chrome/browser/helium_sync/helium_tab_journal_bridge.h"

#include <algorithm>
#include <cstdint>
#include <map>
#include <memory>
#include <optional>
#include <set>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

#include "base/files/file.h"
#include "base/files/file_util.h"
#include "base/functional/bind.h"
#include "base/json/json_writer.h"
#include "base/location.h"
#include "base/logging.h"
#include "base/memory/raw_ptr.h"
#include "base/memory/weak_ptr.h"
#include "base/strings/string_number_conversions.h"
#include "base/strings/utf_string_conversions.h"
#include "base/time/time.h"
#include "base/timer/timer.h"
#include "base/uuid.h"
#include "base/values.h"
#include "build/build_config.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/tab_list/tab_list_interface.h"
#include "chrome/browser/tab_list/tab_list_interface_observer.h"
#include "chrome/browser/tab_list/tab_removed_reason.h"
#include "chrome/browser/ui/browser_window/public/browser_window_interface.h"
#include "chrome/browser/ui/browser_window/public/browser_window_interface_iterator.h"
#include "components/tab_groups/tab_group_color.h"
#include "components/tab_groups/tab_group_visual_data.h"
#include "components/tabs/public/tab_interface.h"
#include "content/public/browser/navigation_entry.h"
#include "content/public/browser/page.h"
#include "content/public/browser/web_contents.h"
#include "content/public/browser/web_contents_observer.h"
#include "crypto/sha2.h"
#include "sql/database.h"
#include "sql/statement.h"
#include "sql/transaction.h"
#include "url/gurl.h"

namespace helium_sync {
namespace {

constexpr int kSchemaVersion = 1;
constexpr int kMaxWindows = 100;
constexpr int kMaxTabs = 5000;
constexpr size_t kMaxPayloadBytes = 8 * 1024 * 1024;
constexpr int64_t kMaxEventsPerEpoch = 100000;
constexpr base::TimeDelta kWindowDiscoveryInterval = base::Seconds(2);
constexpr base::TimeDelta kMutationDebounce = base::Milliseconds(500);
constexpr base::TimeDelta kHeartbeatInterval = base::Minutes(5);
constexpr base::TimeDelta kInitialCheckpointTimeout = base::Seconds(30);
constexpr base::TimeDelta kInitialCheckpointPoll = base::Milliseconds(250);
constexpr char kActiveDatabase[] = "active.sqlite";
constexpr char kClosedDirectory[] = "closed";
constexpr char kJournalRootMarker[] = ".helium-tab-journal-root-v1";
constexpr char kJournalRootMarkerContent[] = "helium-tab-journal-root-v1\n";

bool AllowedJournalUrl(const GURL& url) {
  return url.is_valid() && !url.scheme().empty();
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

bool SecureDirectory(const base::FilePath& path) {
  if (path.empty() || !path.IsAbsolute() || base::IsLink(path) ||
      !base::DirectoryExists(path)) {
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

bool SecureMarker(const base::FilePath& path, std::string_view expected) {
  if (path.empty() || !path.IsAbsolute() || base::IsLink(path)) {
    return false;
  }
  base::File::Info info;
  std::string value;
  if (!base::GetFileInfo(path, &info) || info.is_directory || info.size < 0 ||
      info.size > 256 ||
      !base::ReadFileToStringWithMaxSize(path, &value, 256)) {
    return false;
  }
#if BUILDFLAG(IS_POSIX)
  int mode = 0;
  if (!base::GetPosixFilePermissions(path, &mode) || (mode & 0077) != 0) {
    return false;
  }
#endif
  return value == expected;
}

bool SyncDirectory(const base::FilePath& path) {
#if BUILDFLAG(IS_POSIX)
  base::File directory(path, base::File::FLAG_OPEN | base::File::FLAG_READ);
  return directory.IsValid() && directory.Flush();
#else
  return true;
#endif
}

std::string HashEvent(std::string_view previous,
                      std::string_view epoch,
                      int64_t sequence,
                      std::string_view occurred_at,
                      std::string_view kind,
                      std::string_view payload) {
  std::string value;
  value.reserve(previous.size() + epoch.size() + occurred_at.size() +
                kind.size() + payload.size() + 64);
  value.append(previous);
  value.push_back('\n');
  value.append(epoch);
  value.push_back('\n');
  value.append(base::NumberToString(sequence));
  value.push_back('\n');
  value.append(occurred_at);
  value.push_back('\n');
  value.append(kind);
  value.push_back('\n');
  value.append(payload);
  return base::HexEncodeLower(crypto::SHA256HashString(value));
}

std::optional<std::string> BuildCheckpoint(Profile* profile) {
  base::ListValue windows;
  int tab_count = 0;
  bool valid = true;
  int window_index = 0;
  ForEachCurrentBrowserWindowInterfaceOrderedByActivation(
      [&](BrowserWindowInterface* browser) {
        if (browser->GetProfile() != profile ||
            browser->GetType() != BrowserWindowInterface::TYPE_NORMAL ||
            browser->IsDeleteScheduled()) {
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
        base::ListValue groups;
        for (const tab_groups::TabGroupId& group_id :
             tab_list->ListTabGroups()) {
          std::optional<tab_groups::TabGroupVisualData> visual =
              tab_list->GetTabGroupVisualData(group_id);
          std::optional<std::string> color =
              visual ? GroupColorName(visual->color()) : std::nullopt;
          if (!visual || !color) {
            valid = false;
            return false;
          }
          base::DictValue group;
          group.Set("id", group_id.ToString());
          group.Set("title", base::UTF16ToUTF8(visual->title()));
          group.Set("color", *color);
          group.Set("collapsed", visual->is_collapsed());
          groups.Append(std::move(group));
        }
        base::ListValue tabs;
        int tab_index = 0;
        for (tabs::TabInterface* tab : tab_list->GetAllTabs()) {
          if (!tab || ++tab_count > kMaxTabs ||
              !AllowedJournalUrl(tab->GetURL())) {
            valid = false;
            return false;
          }
          base::DictValue item;
          item.Set("index", tab_index);
          item.Set("active", tab_index == tab_list->GetActiveIndex());
          item.Set("pinned", tab->IsPinned());
          std::string group;
          if (std::optional<tab_groups::TabGroupId> group_id =
                  tab->GetGroup()) {
            group = group_id->ToString();
          }
          item.Set("group", group);
          item.Set("url", tab->GetURL().spec());
          item.Set("title", base::UTF16ToUTF8(tab->GetTitle()));
          tabs.Append(std::move(item));
          ++tab_index;
        }
        base::DictValue window;
        window.Set("index", window_index++);
        window.Set("groups", std::move(groups));
        window.Set("tabs", std::move(tabs));
        windows.Append(std::move(window));
        return true;
      });
  if (!valid || windows.empty()) {
    return std::nullopt;
  }
  base::DictValue checkpoint;
  checkpoint.Set("schema_version", kSchemaVersion);
  checkpoint.Set("windows", std::move(windows));
  std::string raw;
  if (!base::JSONWriter::Write(checkpoint, &raw) ||
      raw.size() > kMaxPayloadBytes) {
    return std::nullopt;
  }
  return raw;
}

}  // namespace

struct HeliumTabJournalBridge::Impl : public TabListInterfaceObserver {
  class ContentsObserver : public content::WebContentsObserver {
   public:
    ContentsObserver(Impl* owner, content::WebContents* contents)
        : content::WebContentsObserver(contents), owner_(owner) {}

    void PrimaryPageChanged(content::Page& page) override {
      owner_->ScheduleCheckpoint();
    }

    void TitleWasSet(content::NavigationEntry* entry) override {
      owner_->ScheduleCheckpoint();
    }

    void WebContentsDestroyed() override {
      if (owner_) {
        owner_->ScheduleRefresh();
      }
      owner_ = nullptr;
    }

   private:
    raw_ptr<Impl> owner_;
  };

  Impl(Profile* profile, base::FilePath journal_root)
      : profile_(profile), journal_root_(std::move(journal_root)) {}

  ~Impl() override { Stop(); }

  void Start() {
    const base::FilePath closed = journal_root_.AppendASCII(kClosedDirectory);
    if (started_ || !profile_ || journal_root_.empty() ||
        !journal_root_.IsAbsolute() || journal_root_ == profile_->GetPath() ||
        profile_->GetPath().IsParent(journal_root_) ||
        journal_root_.IsParent(profile_->GetPath()) ||
        !SecureDirectory(journal_root_) ||
        !SecureMarker(journal_root_.AppendASCII(kJournalRootMarker),
                      kJournalRootMarkerContent) ||
        (base::PathExists(closed) && base::IsLink(closed)) ||
        !base::CreateDirectory(closed)) {
      LOG(ERROR) << "Helium tab journal inactive: invalid independent root";
      return;
    }
#if BUILDFLAG(IS_POSIX)
    if (!base::SetPosixFilePermissions(closed, 0700)) {
      LOG(ERROR) << "Helium tab journal inactive: root permissions";
      return;
    }
#endif
    if (!SecureDirectory(closed) || !OpenDatabase() ||
        (sequence_ >= kMaxEventsPerEpoch && !RotateEpoch())) {
      LOG(ERROR) << "Helium tab journal inactive: database admission failed";
      return;
    }
    started_ = true;
    RefreshObservers();
    initial_deadline_ = base::TimeTicks::Now() + kInitialCheckpointTimeout;
    discovery_timer_.Start(
        FROM_HERE, kWindowDiscoveryInterval,
        base::BindRepeating(&Impl::PollTopology, weak_factory_.GetWeakPtr()));
    if (sequence_ > 0) {
      heartbeat_timer_.Start(FROM_HERE, kHeartbeatInterval,
                             base::BindRepeating(&Impl::AppendHeartbeat,
                                                 weak_factory_.GetWeakPtr()));
    } else {
      TryInitialCheckpoint();
    }
  }

  void Stop() {
    initial_timer_.Stop();
    mutation_timer_.Stop();
    refresh_timer_.Stop();
    discovery_timer_.Stop();
    heartbeat_timer_.Stop();
    weak_factory_.InvalidateWeakPtrs();
    if (!started_) {
      return;
    }
    if (sequence_ > 0) {
      AppendCheckpoint("final-checkpoint");
    }
    DetachObservers();
    database_.Close();
    const base::FilePath active = journal_root_.AppendASCII(kActiveDatabase);
    const base::FilePath closed = journal_root_.AppendASCII(kClosedDirectory)
                                      .AppendASCII(epoch_ + ".sqlite");
    if (sequence_ > 0 && base::PathExists(active) &&
        !base::PathExists(closed) && base::Move(active, closed)) {
#if BUILDFLAG(IS_POSIX)
      base::SetPosixFilePermissions(closed, 0600);
#endif
    }
    started_ = false;
  }

  bool OpenDatabase() {
    const base::FilePath active = journal_root_.AppendASCII(kActiveDatabase);
    if (base::PathExists(active) && base::IsLink(active)) {
      return false;
    }
    new_epoch_ = !base::PathExists(active);
    if (!database_.Open(active)) {
      return false;
    }
    if (!database_.Execute("PRAGMA journal_mode=WAL") ||
        !database_.Execute("PRAGMA synchronous=FULL") ||
        !database_.Execute("PRAGMA secure_delete=ON")) {
      return false;
    }
    if (new_epoch_) {
      epoch_ = base::NumberToString(
                   base::Time::Now().InMillisecondsSinceUnixEpoch()) +
               "-" + base::Uuid::GenerateRandomV4().AsLowercaseString();
      sql::Transaction transaction(&database_);
      if (!transaction.Begin() ||
          !database_.Execute("CREATE TABLE meta("
                             "key TEXT PRIMARY KEY NOT NULL,"
                             "value TEXT NOT NULL"
                             ") STRICT") ||
          !database_.Execute("CREATE TABLE events("
                             "epoch TEXT NOT NULL,"
                             "sequence INTEGER NOT NULL,"
                             "occurred_at_unix_millis TEXT NOT NULL,"
                             "kind TEXT NOT NULL,"
                             "payload_json TEXT NOT NULL,"
                             "previous_sha256 TEXT NOT NULL,"
                             "sha256 TEXT NOT NULL,"
                             "PRIMARY KEY(epoch, sequence)"
                             ") STRICT")) {
        return false;
      }
      sql::Statement meta(database_.GetUniqueStatement(
          "INSERT INTO meta(key, value) VALUES(?, ?)"));
      meta.BindString(0, "schema_version");
      meta.BindString(1, base::NumberToString(kSchemaVersion));
      if (!meta.Run()) {
        return false;
      }
      meta.Reset(true);
      meta.BindString(0, "epoch");
      meta.BindString(1, epoch_);
      if (!meta.Run() || !transaction.Commit()) {
        return false;
      }
      sequence_ = 0;
      previous_hash_.clear();
    } else {
      sql::Statement integrity(
          database_.GetUniqueStatement("PRAGMA quick_check"));
      if (!integrity.Step() || integrity.ColumnString(0) != "ok") {
        return false;
      }
      sql::Statement meta(database_.GetUniqueStatement(
          "SELECT key, value FROM meta ORDER BY key"));
      std::map<std::string, std::string> values;
      while (meta.Step()) {
        values.emplace(meta.ColumnString(0), meta.ColumnString(1));
      }
      if (!meta.Succeeded() || values.size() != 2 ||
          values["schema_version"] != base::NumberToString(kSchemaVersion) ||
          values["epoch"].empty()) {
        return false;
      }
      epoch_ = values["epoch"];
      sql::Statement last(database_.GetUniqueStatement(
          "SELECT sequence, sha256, payload_json FROM events "
          "WHERE epoch=? ORDER BY sequence DESC LIMIT 1"));
      last.BindString(0, epoch_);
      if (!last.Step()) {
        if (!last.Succeeded()) {
          return false;
        }
        sequence_ = 0;
        previous_hash_.clear();
        new_epoch_ = true;
      } else {
        sequence_ = last.ColumnInt64(0);
        previous_hash_ = last.ColumnString(1);
        last_payload_ = last.ColumnString(2);
        if (sequence_ <= 0 || sequence_ > kMaxEventsPerEpoch ||
            previous_hash_.size() != crypto::kSHA256Length * 2) {
          return false;
        }
      }
    }
#if BUILDFLAG(IS_POSIX)
    if (!base::SetPosixFilePermissions(active, 0600)) {
      return false;
    }
#endif
    return true;
  }

  bool AppendCheckpoint(std::string_view kind) {
    if (!started_) {
      return false;
    }
    std::optional<std::string> payload = BuildCheckpoint(profile_);
    if (!payload) {
      LOG(WARNING) << "Helium tab journal deferred incomplete topology";
      return true;
    }
    if (kind == "checkpoint" && *payload == last_payload_) {
      return true;
    }
    if (sequence_ >= kMaxEventsPerEpoch && !RotateEpoch()) {
      return false;
    }
    const std::string_view effective_kind =
        sequence_ == 0 ? std::string_view("initial-checkpoint") : kind;
    const int64_t sequence = sequence_ + 1;
    const std::string occurred_at =
        base::NumberToString(base::Time::Now().InMillisecondsSinceUnixEpoch());
    const std::string hash = HashEvent(previous_hash_, epoch_, sequence,
                                       occurred_at, effective_kind, *payload);
    sql::Statement insert(database_.GetUniqueStatement(
        "INSERT INTO events("
        "epoch,sequence,occurred_at_unix_millis,kind,payload_json,"
        "previous_sha256,sha256) VALUES(?,?,?,?,?,?,?)"));
    insert.BindString(0, epoch_);
    insert.BindInt64(1, sequence);
    insert.BindString(2, occurred_at);
    insert.BindString(3, effective_kind);
    insert.BindString(4, *payload);
    insert.BindString(5, previous_hash_);
    insert.BindString(6, hash);
    if (!insert.Run()) {
      return false;
    }
    sequence_ = sequence;
    previous_hash_ = hash;
    last_payload_ = *payload;
    return true;
  }

  bool RotateEpoch() {
    database_.Close();
    const base::FilePath active = journal_root_.AppendASCII(kActiveDatabase);
    const base::FilePath closed = journal_root_.AppendASCII(kClosedDirectory)
                                      .AppendASCII(epoch_ + ".sqlite");
    if (!base::PathExists(active) || base::PathExists(closed) ||
        !base::Move(active, closed)) {
      return false;
    }
#if BUILDFLAG(IS_POSIX)
    if (!base::SetPosixFilePermissions(closed, 0600)) {
      return false;
    }
#endif
    if (!SyncDirectory(journal_root_.AppendASCII(kClosedDirectory)) ||
        !SyncDirectory(journal_root_)) {
      return false;
    }
    sequence_ = 0;
    previous_hash_.clear();
    last_payload_.clear();
    return OpenDatabase();
  }

  void AppendHeartbeat() {
    if (!AppendCheckpoint("heartbeat")) {
      FailClosed("heartbeat");
    }
  }

  void TryInitialCheckpoint() {
    if (!started_ || sequence_ > 0) {
      return;
    }
    if (!AppendCheckpoint(new_epoch_ ? "initial-checkpoint" : "checkpoint")) {
      FailClosed("initial-checkpoint");
      return;
    }
    if (sequence_ > 0) {
      heartbeat_timer_.Start(FROM_HERE, kHeartbeatInterval,
                             base::BindRepeating(&Impl::AppendHeartbeat,
                                                 weak_factory_.GetWeakPtr()));
      return;
    }
    if (base::TimeTicks::Now() >= initial_deadline_) {
      FailClosed("initial-checkpoint-timeout");
      return;
    }
    initial_timer_.Start(FROM_HERE, kInitialCheckpointPoll,
                         base::BindOnce(&Impl::TryInitialCheckpoint,
                                        weak_factory_.GetWeakPtr()));
  }

  void ScheduleCheckpoint() {
    if (!started_) {
      return;
    }
    if (sequence_ == 0) {
      TryInitialCheckpoint();
      return;
    }
    if (mutation_timer_.IsRunning()) {
      return;
    }
    mutation_timer_.Start(
        FROM_HERE, kMutationDebounce,
        base::BindOnce(&Impl::AppendMutation, weak_factory_.GetWeakPtr()));
  }

  void AppendMutation() {
    if (!AppendCheckpoint("checkpoint")) {
      FailClosed("mutation");
    }
  }

  void ScheduleRefresh() {
    ScheduleCheckpoint();
    if (!started_ || refresh_timer_.IsRunning()) {
      return;
    }
    refresh_timer_.Start(
        FROM_HERE, kMutationDebounce,
        base::BindOnce(&Impl::RefreshObservers, weak_factory_.GetWeakPtr()));
  }

  void PollTopology() {
    RefreshObservers();
    ScheduleCheckpoint();
  }

  void RefreshObservers() {
    if (!started_) {
      return;
    }
    std::set<TabListInterface*> current_lists;
    std::set<content::WebContents*> current_contents;
    for (BrowserWindowInterface* browser : GetAllBrowserWindowInterfaces()) {
      if (!browser || browser->GetProfile() != profile_ ||
          browser->GetType() != BrowserWindowInterface::TYPE_NORMAL ||
          browser->IsDeleteScheduled()) {
        continue;
      }
      TabListInterface* tab_list = TabListInterface::From(browser);
      if (!tab_list) {
        continue;
      }
      current_lists.insert(tab_list);
      if (!observed_lists_.contains(tab_list)) {
        tab_list->AddTabListInterfaceObserver(this);
        observed_lists_.insert(tab_list);
      }
      for (tabs::TabInterface* tab : tab_list->GetAllTabs()) {
        if (tab && tab->GetContents()) {
          current_contents.insert(tab->GetContents());
          if (!contents_observers_.contains(tab->GetContents())) {
            contents_observers_.emplace(
                tab->GetContents(),
                std::make_unique<ContentsObserver>(this, tab->GetContents()));
          }
        }
      }
    }
    for (auto iterator = contents_observers_.begin();
         iterator != contents_observers_.end();) {
      if (!current_contents.contains(iterator->first)) {
        iterator = contents_observers_.erase(iterator);
      } else {
        ++iterator;
      }
    }
    // OnTabListDestroyed removes dead lists synchronously. A list missing from
    // the current window set but not destroyed may be in a reparent operation;
    // keep observing it until that lifecycle callback.
  }

  void DetachObservers() {
    contents_observers_.clear();
    for (TabListInterface* tab_list : observed_lists_) {
      tab_list->RemoveTabListInterfaceObserver(this);
    }
    observed_lists_.clear();
  }

  void FailClosed(std::string_view reason) {
    LOG(ERROR) << "Helium tab journal stopped after durable append failure: "
               << reason;
    initial_timer_.Stop();
    mutation_timer_.Stop();
    refresh_timer_.Stop();
    discovery_timer_.Stop();
    heartbeat_timer_.Stop();
    DetachObservers();
    database_.Close();
    started_ = false;
  }

  void OnTabAdded(TabListInterface& tab_list,
                  tabs::TabInterface* tab,
                  int index) override {
    ScheduleRefresh();
  }

  void OnActiveTabChanged(TabListInterface& tab_list,
                          tabs::TabInterface* tab) override {
    ScheduleCheckpoint();
  }

  void OnTabRemoved(TabListInterface& tab_list,
                    tabs::TabInterface* tab,
                    TabRemovedReason removed_reason) override {
    ScheduleRefresh();
  }

  void OnTabMoved(TabListInterface& tab_list,
                  tabs::TabInterface* tab,
                  int from_index,
                  int to_index) override {
    ScheduleCheckpoint();
  }

  void OnWebContentsReplaced(TabListInterface& tab_list,
                             tabs::TabInterface* tab,
                             content::WebContents* old_contents,
                             content::WebContents* new_contents) override {
    ScheduleRefresh();
  }

  void OnTabListDestroyed(TabListInterface& tab_list) override {
    observed_lists_.erase(&tab_list);
    ScheduleRefresh();
  }

  void OnAllTabsAreClosing(TabListInterface& tab_list) override {
    ScheduleCheckpoint();
  }

  raw_ptr<Profile> profile_;
  base::FilePath journal_root_;
  sql::Database database_;
  std::string epoch_;
  std::string previous_hash_;
  std::string last_payload_;
  int64_t sequence_ = 0;
  bool new_epoch_ = false;
  bool started_ = false;
  std::set<TabListInterface*> observed_lists_;
  std::map<content::WebContents*, std::unique_ptr<ContentsObserver>>
      contents_observers_;
  base::OneShotTimer mutation_timer_;
  base::OneShotTimer initial_timer_;
  base::OneShotTimer refresh_timer_;
  base::RepeatingTimer discovery_timer_;
  base::RepeatingTimer heartbeat_timer_;
  base::TimeTicks initial_deadline_;
  base::WeakPtrFactory<Impl> weak_factory_{this};
};

HeliumTabJournalBridge::HeliumTabJournalBridge(Profile* profile,
                                               base::FilePath journal_root)
    : impl_(std::make_unique<Impl>(profile, std::move(journal_root))) {}

HeliumTabJournalBridge::~HeliumTabJournalBridge() {
  Stop();
}

void HeliumTabJournalBridge::Start() {
  impl_->Start();
}

void HeliumTabJournalBridge::Stop() {
  impl_->Stop();
}

}  // namespace helium_sync
