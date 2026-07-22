// Copyright 2026 The Helium Authors

#ifndef CHROME_BROWSER_HELIUM_SYNC_HELIUM_TAB_SNAPSHOT_BRIDGE_H_
#define CHROME_BROWSER_HELIUM_SYNC_HELIUM_TAB_SNAPSHOT_BRIDGE_H_

#include "base/files/file_path.h"
#include "base/memory/raw_ptr.h"
#include "base/memory/weak_ptr.h"
#include "base/timer/timer.h"

class Profile;

namespace helium_sync {

// Exports Chromium's live tab model to the validated JSON boundary consumed by
// helium-tabs. The independent generation store remains owned by helium-tabs;
// this class never reads or copies Chromium's Session_* or Tabs_* files.
class HeliumTabSnapshotBridge {
 public:
  HeliumTabSnapshotBridge(Profile* profile, base::FilePath export_path);
  HeliumTabSnapshotBridge(const HeliumTabSnapshotBridge&) = delete;
  HeliumTabSnapshotBridge& operator=(const HeliumTabSnapshotBridge&) = delete;
  ~HeliumTabSnapshotBridge();

  void Start();
  void Stop();

  // Public for a disposable-profile browser test. Production uses the timer.
  bool CaptureNowForTesting();

 private:
  void Capture();

  raw_ptr<Profile> profile_;
  const base::FilePath export_path_;
  base::RepeatingTimer capture_timer_;
  base::WeakPtrFactory<HeliumTabSnapshotBridge> weak_factory_{this};
};

}  // namespace helium_sync

#endif  // CHROME_BROWSER_HELIUM_SYNC_HELIUM_TAB_SNAPSHOT_BRIDGE_H_
