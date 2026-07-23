// Copyright 2026 The Helium Authors

#ifndef CHROME_BROWSER_HELIUM_SYNC_HELIUM_TAB_RESTORE_BRIDGE_H_
#define CHROME_BROWSER_HELIUM_SYNC_HELIUM_TAB_RESTORE_BRIDGE_H_

#include <memory>

class Profile;

namespace helium_sync {

// Applies one prepared local tab snapshot only when the dedicated command-line
// switch is present and the current user-data directory is a marked disposable
// drill profile. Normal launches never construct this bridge.
class HeliumTabRestoreBridge {
 public:
  static bool IsRequested();

  explicit HeliumTabRestoreBridge(Profile* profile);
  HeliumTabRestoreBridge(const HeliumTabRestoreBridge&) = delete;
  HeliumTabRestoreBridge& operator=(const HeliumTabRestoreBridge&) = delete;
  ~HeliumTabRestoreBridge();

  void Start();
  void Stop();

 private:
  struct Impl;

  std::unique_ptr<Impl> impl_;
};

}  // namespace helium_sync

#endif  // CHROME_BROWSER_HELIUM_SYNC_HELIUM_TAB_RESTORE_BRIDGE_H_
