/* -*- Mode: C++; tab-width: 8; indent-tabs-mode: nil; c-basic-offset: 2 -*- */
/* vim: set ts=8 sts=2 et sw=2 tw=80: */
/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

#include "mozilla/dom/SVGScriptElement.h"

#include "mozilla/dom/Document.h"
#include "mozilla/dom/FetchPriority.h"
#include "nsGkAtoms.h"
#include "nsNetUtil.h"
#include "nsContentUtils.h"
#include "mozilla/dom/SVGScriptElementBinding.h"
#include "nsIScriptError.h"

NS_IMPL_NS_NEW_SVG_ELEMENT_CHECK_PARSER(Script)

using JS::loader::ScriptKind;

namespace mozilla::dom {

JSObject* SVGScriptElement::WrapNode(JSContext* aCx,
                                     JS::Handle<JSObject*> aGivenProto) {
  return SVGScriptElement_Binding::Wrap(aCx, this, aGivenProto);
}

SVGElement::StringInfo SVGScriptElement::sStringInfo[2] = {
    {nsGkAtoms::href, kNameSpaceID_None, false},
    {nsGkAtoms::href, kNameSpaceID_XLink, false}};

//----------------------------------------------------------------------
// nsISupports methods

NS_IMPL_ISUPPORTS_INHERITED(SVGScriptElement, SVGScriptElementBase,
                            nsIScriptLoaderObserver, nsIScriptElement,
                            nsIMutationObserver)

//----------------------------------------------------------------------
// Implementation

SVGScriptElement::SVGScriptElement(
    already_AddRefed<mozilla::dom::NodeInfo>&& aNodeInfo,
    FromParser aFromParser)
    : SVGScriptElementBase(std::move(aNodeInfo)), ScriptElement(aFromParser) {
  AddMutationObserver(this);
}

//----------------------------------------------------------------------
// nsINode methods

nsresult SVGScriptElement::Clone(dom::NodeInfo* aNodeInfo,
                                 nsINode** aResult) const {
  *aResult = nullptr;

  SVGScriptElement* it = new (aNodeInfo->NodeInfoManager())
      SVGScriptElement(do_AddRef(aNodeInfo), NOT_FROM_PARSER);

  nsCOMPtr<nsINode> kungFuDeathGrip = it;
  nsresult rv1 = it->Init();
  nsresult rv2 = const_cast<SVGScriptElement*>(this)->CopyInnerTo(it);
  NS_ENSURE_SUCCESS(rv1, rv1);
  NS_ENSURE_SUCCESS(rv2, rv2);

  // The clone should be marked evaluated if we are.
  it->mAlreadyStarted = mAlreadyStarted;
  it->mLineNumber = mLineNumber;
  it->mMalformed = mMalformed;

  kungFuDeathGrip.swap(*aResult);

  return NS_OK;
}

//----------------------------------------------------------------------
void SVGScriptElement::GetType(nsAString& aType) {
  GetAttr(nsGkAtoms::type, aType);
}

void SVGScriptElement::SetType(const nsAString& aType, ErrorResult& rv) {
  rv = SetAttr(kNameSpaceID_None, nsGkAtoms::type, aType, true);
}

void SVGScriptElement::GetCrossOrigin(nsAString& aCrossOrigin) {
  // Null for both missing and invalid defaults is ok, since we
  // always parse to an enum value, so we don't need an invalid
  // default, and we _want_ the missing default to be null.
  GetEnumAttr(nsGkAtoms::crossorigin, nullptr, aCrossOrigin);
}

void SVGScriptElement::SetCrossOrigin(const nsAString& aCrossOrigin,
                                      ErrorResult& aError) {
  SetOrRemoveNullableStringAttr(nsGkAtoms::crossorigin, aCrossOrigin, aError);
}

already_AddRefed<DOMSVGAnimatedString> SVGScriptElement::Href() {
  return mStringAttributes[HREF].IsExplicitlySet()
             ? mStringAttributes[HREF].ToDOMAnimatedString(this)
             : mStringAttributes[XLINK_HREF].ToDOMAnimatedString(this);
}

//----------------------------------------------------------------------
// nsIScriptElement methods

void SVGScriptElement::GetScriptText(nsAString& text) const {
  nsContentUtils::GetNodeTextContent(this, false, text);
}

void SVGScriptElement::GetScriptCharset(nsAString& charset) {
  charset.Truncate();
}

void SVGScriptElement::FreezeExecutionAttrs(const Document* aOwnerDoc) {
  if (mFrozen) {
    return;
  }

  // Determine whether this is a(n) classic/module/importmap script.
  DetermineKindFromType(aOwnerDoc);

  if (mStringAttributes[HREF].IsExplicitlySet() ||
      mStringAttributes[XLINK_HREF].IsExplicitlySet()) {
    // variation of this code in nsHTMLScriptElement - check if changes
    // need to be transferred when modifying
    bool isHref = false;
    nsAutoString src;
    if (mStringAttributes[HREF].IsExplicitlySet()) {
      mStringAttributes[HREF].GetAnimValue(src, this);
      isHref = true;
    } else {
      mStringAttributes[XLINK_HREF].GetAnimValue(src, this);
    }

    SourceLocation loc{OwnerDoc()->GetDocumentURI(), GetScriptLineNumber(),
                       GetScriptColumnNumber().oneOriginValue()};
    // Empty src should be treated as invalid URL.
    if (!src.IsEmpty()) {
      NS_NewURI(getter_AddRefs(mUri), src, nullptr, GetBaseURI());

      if (!mUri) {
        AutoTArray<nsString, 2> params = {
            isHref ? u"href"_ns : u"xlink:href"_ns, src};

        nsContentUtils::ReportToConsole(nsIScriptError::warningFlag, "SVG"_ns,
                                        OwnerDoc(),
                                        nsContentUtils::eDOM_PROPERTIES,
                                        "ScriptSourceInvalidUri", params, loc);
      }
    } else {
      AutoTArray<nsString, 1> params = {isHref ? u"href"_ns : u"xlink:href"_ns};

      nsContentUtils::ReportToConsole(
          nsIScriptError::warningFlag, "SVG"_ns, OwnerDoc(),
          nsContentUtils::eDOM_PROPERTIES, "ScriptSourceEmpty", params, loc);
    }

    // At this point mUri will be null for invalid URLs.
    mExternal = true;
  }

  bool async = (mExternal || mKind == ScriptKind::eModule) && Async();
  bool defer = mExternal && Defer();

  mDefer = !async && defer;
  mAsync = async;

  mFrozen = true;
}

//----------------------------------------------------------------------
// ScriptElement methods
bool SVGScriptElement::HasExternalScriptContent() {
  return mFrozen ? mExternal
                 : (mStringAttributes[HREF].IsExplicitlySet() ||
                    mStringAttributes[XLINK_HREF].IsExplicitlySet());
}

//----------------------------------------------------------------------
// SVGElement methods

SVGElement::StringAttributesInfo SVGScriptElement::GetStringInfo() {
  return StringAttributesInfo(mStringAttributes, sStringInfo,
                              std::size(sStringInfo));
}

//----------------------------------------------------------------------
// nsIContent methods

nsresult SVGScriptElement::BindToTree(BindContext& aContext, nsINode& aParent) {
  nsresult rv = SVGScriptElementBase::BindToTree(aContext, aParent);
  NS_ENSURE_SUCCESS(rv, rv);

  if (IsInComposedDoc()) {
    MaybeProcessScript();
  }

  return NS_OK;
}

bool SVGScriptElement::ParseAttribute(int32_t aNamespaceID, nsAtom* aAttribute,
                                      const nsAString& aValue,
                                      nsIPrincipal* aMaybeScriptedPrincipal,
                                      nsAttrValue& aResult) {
  if (aNamespaceID == kNameSpaceID_None) {
    if (aAttribute == nsGkAtoms::crossorigin) {
      ParseCORSValue(aValue, aResult);
      return true;
    }
    if (aAttribute == nsGkAtoms::fetchpriority) {
      ParseFetchPriority(aValue, aResult);
      return true;
    }
  }

  return SVGScriptElementBase::ParseAttribute(aNamespaceID, aAttribute, aValue,
                                              aMaybeScriptedPrincipal, aResult);
}

CORSMode SVGScriptElement::GetCORSMode() const {
  return AttrValueToCORSMode(GetParsedAttr(nsGkAtoms::crossorigin));
}

void SVGScriptElement::GetFetchPriority(nsAString& aFetchPriority) const {
  GetEnumAttr(nsGkAtoms::fetchpriority, kFetchPriorityAttributeValueAuto,
              aFetchPriority);
}

FetchPriority SVGScriptElement::GetFetchPriority() const {
  return Element::GetFetchPriority();
}

}  // namespace mozilla::dom
