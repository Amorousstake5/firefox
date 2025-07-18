/* -*- Mode: C++; tab-width: 8; indent-tabs-mode: nil; c-basic-offset: 2 -*- */
/* vim: set ts=8 sts=2 et sw=2 tw=80: */
/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

#ifndef nsOpenWindowInfo_h
#define nsOpenWindowInfo_h

#include "nsIOpenWindowInfo.h"
#include "nsISupportsImpl.h"
#include "mozilla/OriginAttributes.h"
#include "mozilla/RefPtr.h"
#include "mozilla/dom/ClientOpenWindowUtils.h"

// f4fecc26-02fe-46dc-935c-4d6f9acb18a6
#define NS_OPENWINDOWINFO_CID \
  {0xf4fecc26, 0x02fe, 0x46dc, {0x93, 0x5c, 0x4d, 0x6f, 0x9a, 0xcb, 0x18, 0xa6}}

class nsOpenWindowInfo : public nsIOpenWindowInfo {
 public:
  NS_DECL_ISUPPORTS
  NS_DECL_NSIOPENWINDOWINFO

  nsOpenWindowInfo();

  bool mForceNoOpener = false;
  bool mIsRemote = false;
  bool mIsForPrinting = false;
  bool mIsForWindowDotPrint = false;
  bool mIsTopLevelCreatedByWebContent = false;
  bool mHasValidUserGestureActivation = false;
  bool mTextDirectiveUserActivation = false;
  RefPtr<mozilla::dom::BrowserParent> mNextRemoteBrowser;
  mozilla::OriginAttributes mOriginAttributes;
  RefPtr<mozilla::dom::BrowsingContext> mParent;
  RefPtr<nsIBrowsingContextReadyCallback> mBrowsingContextReadyCallback;

 private:
  virtual ~nsOpenWindowInfo();
};

class nsBrowsingContextReadyCallback : public nsIBrowsingContextReadyCallback {
 public:
  NS_DECL_ISUPPORTS
  NS_DECL_NSIBROWSINGCONTEXTREADYCALLBACK

  explicit nsBrowsingContextReadyCallback(
      RefPtr<mozilla::dom::BrowsingContextCallbackReceivedPromise::Private>
          aPromise);

 private:
  virtual ~nsBrowsingContextReadyCallback();

  RefPtr<mozilla::dom::BrowsingContextCallbackReceivedPromise::Private>
      mPromise;
};

#endif  // nsOpenWindowInfo_h
