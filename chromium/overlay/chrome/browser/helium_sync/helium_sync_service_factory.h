// Copyright 2026 The Helium Authors

#ifndef CHROME_BROWSER_HELIUM_SYNC_HELIUM_SYNC_SERVICE_FACTORY_H_
#define CHROME_BROWSER_HELIUM_SYNC_HELIUM_SYNC_SERVICE_FACTORY_H_

#include <memory>

#include "base/no_destructor.h"
#include "chrome/browser/profiles/profile_keyed_service_factory.h"

class HeliumSyncService;
class Profile;

class HeliumSyncServiceFactory : public ProfileKeyedServiceFactory {
 public:
  static HeliumSyncService* GetForProfile(Profile* profile);
  static HeliumSyncServiceFactory* GetInstance();

  HeliumSyncServiceFactory(const HeliumSyncServiceFactory&) = delete;
  HeliumSyncServiceFactory& operator=(const HeliumSyncServiceFactory&) = delete;

 private:
  friend base::NoDestructor<HeliumSyncServiceFactory>;

  HeliumSyncServiceFactory();
  ~HeliumSyncServiceFactory() override;

  // BrowserContextKeyedServiceFactory:
  std::unique_ptr<KeyedService> BuildServiceInstanceForBrowserContext(
      content::BrowserContext* context) const override;
  bool ServiceIsCreatedWithBrowserContext() const override;
};

#endif  // CHROME_BROWSER_HELIUM_SYNC_HELIUM_SYNC_SERVICE_FACTORY_H_
