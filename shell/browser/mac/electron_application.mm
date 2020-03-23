// Copyright (c) 2013 GitHub, Inc.
// Use of this source code is governed by the MIT license that can be
// found in the LICENSE file.

#import "shell/browser/mac/electron_application.h"

#include <memory>
#include <string>
#include <utility>

#include "base/auto_reset.h"
#include "base/observer_list.h"
#include "base/strings/sys_string_conversions.h"
#include "content/public/browser/browser_accessibility_state.h"
#include "content/public/browser/native_event_processor_mac.h"
#include "content/public/browser/native_event_processor_observer_mac.h"
#include "shell/browser/browser.h"
#include "shell/browser/mac/dict_util.h"
#import "shell/browser/mac/electron_application_delegate.h"

namespace {

inline void dispatch_sync_main(dispatch_block_t block) {
  if ([NSThread isMainThread])
    block();
  else
    dispatch_sync(dispatch_get_main_queue(), block);
}

}  // namespace

@interface AtomApplication () <NativeEventProcessor> {
  base::ObserverList<content::NativeEventProcessorObserver>::Unchecked
      observers_;
}
@end

@implementation AtomApplication

+ (AtomApplication*)sharedApplication {
  return (AtomApplication*)[super sharedApplication];
}

- (void)terminate:(id)sender {
  if (shouldShutdown_ && !shouldShutdown_.Run())
    return;  // User will call Quit later.

  // We simply try to close the browser, which in turn will try to close the
  // windows. Termination can proceed if all windows are closed or window close
  // can be cancelled which will abort termination.
  electron::Browser::Get()->Quit();
}

- (void)setShutdownHandler:(base::Callback<bool()>)handler {
  shouldShutdown_ = std::move(handler);
}

- (BOOL)isHandlingSendEvent {
  return handlingSendEvent_;
}

- (void)sendEvent:(NSEvent*)event {
  base::AutoReset<BOOL> scoper(&handlingSendEvent_, YES);
  if (event.type == NSEventTypeKeyDown && event.keyCode == 49) {
    // Skipping space bar handling
    NSWindow* nextWindow = event.window;
    [nextWindow sendEvent:event];
  } else 
    content::ScopedNotifyNativeEventProcessorObserver scopedObserverNotifier(
      &observers_, event);
    [super sendEvent:event];
  }
}

- (void)setHandlingSendEvent:(BOOL)handlingSendEvent {
  handlingSendEvent_ = handlingSendEvent;
}

- (void)setCurrentActivity:(NSString*)type
              withUserInfo:(NSDictionary*)userInfo
            withWebpageURL:(NSURL*)webpageURL {
  currentActivity_ = base::scoped_nsobject<NSUserActivity>(
      [[NSUserActivity alloc] initWithActivityType:type]);
  [currentActivity_ setUserInfo:userInfo];
  [currentActivity_ setWebpageURL:webpageURL];
  [currentActivity_ setDelegate:self];
  [currentActivity_ becomeCurrent];
  [currentActivity_ setNeedsSave:YES];
}

- (NSUserActivity*)getCurrentActivity {
  return currentActivity_.get();
}

- (void)invalidateCurrentActivity {
  if (currentActivity_) {
    [currentActivity_ invalidate];
    currentActivity_.reset();
  }
}

- (void)resignCurrentActivity {
  if (@available(macOS 10.11, *)) {
    if (currentActivity_)
      [currentActivity_ resignCurrent];
  }
}

- (void)updateCurrentActivity:(NSString*)type
                 withUserInfo:(NSDictionary*)userInfo {
  if (currentActivity_) {
    [currentActivity_ addUserInfoEntriesFromDictionary:userInfo];
  }

  [handoffLock_ lock];
  updateReceived_ = YES;
  [handoffLock_ signal];
  [handoffLock_ unlock];
}

- (void)userActivityWillSave:(NSUserActivity*)userActivity {
  __block BOOL shouldWait = NO;
  dispatch_sync_main(^{
    std::string activity_type(
        base::SysNSStringToUTF8(userActivity.activityType));
    std::unique_ptr<base::DictionaryValue> user_info =
        electron::NSDictionaryToDictionaryValue(userActivity.userInfo);

    electron::Browser* browser = electron::Browser::Get();
    shouldWait =
        browser->UpdateUserActivityState(activity_type, *user_info) ? YES : NO;
  });

  if (shouldWait) {
    [handoffLock_ lock];
    updateReceived_ = NO;
    while (!updateReceived_) {
      BOOL isSignaled =
          [handoffLock_ waitUntilDate:[NSDate dateWithTimeIntervalSinceNow:1]];
      if (!isSignaled)
        break;
    }
    [handoffLock_ unlock];
  }

  [userActivity setNeedsSave:YES];
}

- (void)userActivityWasContinued:(NSUserActivity*)userActivity {
  dispatch_async(dispatch_get_main_queue(), ^{
    std::string activity_type(
        base::SysNSStringToUTF8(userActivity.activityType));
    std::unique_ptr<base::DictionaryValue> user_info =
        electron::NSDictionaryToDictionaryValue(userActivity.userInfo);

    electron::Browser* browser = electron::Browser::Get();
    browser->UserActivityWasContinued(activity_type, *user_info);
  });
  [userActivity setNeedsSave:YES];
}

- (void)registerURLHandler {
  [[NSAppleEventManager sharedAppleEventManager]
      setEventHandler:self
          andSelector:@selector(handleURLEvent:withReplyEvent:)
        forEventClass:kInternetEventClass
           andEventID:kAEGetURL];

  handoffLock_ = [NSCondition new];
}

- (void)handleURLEvent:(NSAppleEventDescriptor*)event
        withReplyEvent:(NSAppleEventDescriptor*)replyEvent {
  NSString* url =
      [[event paramDescriptorForKeyword:keyDirectObject] stringValue];
  electron::Browser::Get()->OpenURL(base::SysNSStringToUTF8(url));
}

- (bool)voiceOverEnabled {
  NSUserDefaults* defaults = [NSUserDefaults standardUserDefaults];
  [defaults addSuiteNamed:@"com.apple.universalaccess"];
  [defaults synchronize];

  return [defaults boolForKey:@"voiceOverOnOffKey"];
}

- (void)accessibilitySetValue:(id)value forAttribute:(NSString*)attribute {
  // Undocumented attribute that VoiceOver happens to set while running.
  // Chromium uses this too, even though it's not exactly right.
  if ([attribute isEqualToString:@"AXEnhancedUserInterface"]) {
    bool enableAccessibility = ([self voiceOverEnabled] && [value boolValue]);
    [self updateAccessibilityEnabled:enableAccessibility];
  } else if ([attribute isEqualToString:@"AXManualAccessibility"]) {
    [self updateAccessibilityEnabled:[value boolValue]];
  }
  return [super accessibilitySetValue:value forAttribute:attribute];
}

- (void)updateAccessibilityEnabled:(BOOL)enabled {
  auto* ax_state = content::BrowserAccessibilityState::GetInstance();

  if (enabled) {
    ax_state->OnScreenReaderDetected();
  } else {
    ax_state->DisableAccessibility();
  }

  electron::Browser::Get()->OnAccessibilitySupportChanged();
}

- (void)orderFrontStandardAboutPanel:(id)sender {
  electron::Browser::Get()->ShowAboutPanel();
}

- (void)addNativeEventProcessorObserver:
    (content::NativeEventProcessorObserver*)observer {
  observers_.AddObserver(observer);
}

- (void)removeNativeEventProcessorObserver:
    (content::NativeEventProcessorObserver*)observer {
  observers_.RemoveObserver(observer);
}

@end
