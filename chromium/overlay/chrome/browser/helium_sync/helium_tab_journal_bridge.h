// Copyright 2026 The Helium Authors

#ifndef CHROME_BROWSER_HELIUM_SYNC_HELIUM_TAB_JOURNAL_BRIDGE_H_
#define CHROME_BROWSER_HELIUM_SYNC_HELIUM_TAB_JOURNAL_BRIDGE_H_

#include <memory>

#include "base/files/file_path.h"

class Profile;

namespace helium_sync {

// An independent event-driven recovery journal. It does not call the neutral
// snapshot exporter and it never reads Chromium's on-disk Sessions files.
class HeliumTabJournalBridge {
 public:
  HeliumTabJournalBridge(Profile* profile, base::FilePath journal_root);
  HeliumTabJournalBridge(const HeliumTabJournalBridge&) = delete;
  HeliumTabJournalBridge& operator=(const HeliumTabJournalBridge&) = delete;
  ~HeliumTabJournalBridge();

  void Start();
  void Stop();

 private:
  struct Impl;
  std::unique_ptr<Impl> impl_;
};

}  // namespace helium_sync

#endif  // CHROME_BROWSER_HELIUM_SYNC_HELIUM_TAB_JOURNAL_BRIDGE_H_
