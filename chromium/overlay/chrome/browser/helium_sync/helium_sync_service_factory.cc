// Copyright 2026 The Helium Authors

#include "chrome/browser/helium_sync/helium_sync_service_factory.h"

#include <memory>

#include "base/no_destructor.h"
#include "build/build_config.h"
#include "chrome/browser/helium_sync/helium_sync_service.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/profiles/profile_selections.h"

#if __has_include( \
    "chrome/browser/password_manager/factories/profile_password_store_factory.h")
#include "chrome/browser/password_manager/factories/profile_password_store_factory.h"
#else
#include "chrome/browser/password_manager/profile_password_store_factory.h"
#endif

// static
HeliumSyncService* HeliumSyncServiceFactory::GetForProfile(Profile* profile) {
  return static_cast<HeliumSyncService*>(
      GetInstance()->GetServiceForBrowserContext(profile, true));
}

// static
HeliumSyncServiceFactory* HeliumSyncServiceFactory::GetInstance() {
  static base::NoDestructor<HeliumSyncServiceFactory> instance;
  return instance.get();
}

HeliumSyncServiceFactory::HeliumSyncServiceFactory()
    : ProfileKeyedServiceFactory(
          "HeliumSyncService",
          ProfileSelections::Builder()
              .WithRegular(ProfileSelection::kOriginalOnly)
              .Build()) {
  DependsOn(ProfilePasswordStoreFactory::GetInstance());
}

HeliumSyncServiceFactory::~HeliumSyncServiceFactory() = default;

std::unique_ptr<KeyedService>
HeliumSyncServiceFactory::BuildServiceInstanceForBrowserContext(
    content::BrowserContext* context) const {
  return std::make_unique<HeliumSyncService>(
      Profile::FromBrowserContext(context));
}

bool HeliumSyncServiceFactory::ServiceIsCreatedWithBrowserContext() const {
  return true;
}
