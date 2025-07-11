/* -*- Mode: IDL; tab-width: 2; indent-tabs-mode: nil; c-basic-offset: 2 -*- */
/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this file,
 * You can obtain one at http://mozilla.org/MPL/2.0/.
 *
 * The origin of this IDL file is
 * http://www.whatwg.org/specs/web-apps/current-work/#the-button-element
 * © Copyright 2004-2011 Apple Computer, Inc., Mozilla Foundation, and
 * Opera Software ASA. You are granted a license to use, reproduce
 * and create derivative works of this document.
 */

// http://www.whatwg.org/specs/web-apps/current-work/#the-button-element
[Exposed=Window]
interface HTMLButtonElement : HTMLElement {
  [HTMLConstructor] constructor();

  [CEReactions, SetterThrows, Pure]
           attribute boolean disabled;
  [Pure]
  readonly attribute HTMLFormElement? form;
  [CEReactions, SetterThrows, Pure]
           attribute DOMString formAction;
  [CEReactions, SetterThrows, Pure]
           attribute DOMString formEnctype;
  [CEReactions, SetterThrows, Pure]
           attribute DOMString formMethod;
  [CEReactions, SetterThrows, Pure]
           attribute boolean formNoValidate;
  [CEReactions, SetterThrows, Pure]
           attribute DOMString formTarget;
  [CEReactions, SetterThrows, Pure]
           attribute DOMString name;
  [CEReactions, SetterThrows, Pure]
           attribute DOMString type;
  [CEReactions, SetterThrows, Pure]
           attribute DOMString value;

  readonly attribute boolean willValidate;
  readonly attribute ValidityState validity;
  [Throws]
  readonly attribute DOMString validationMessage;
  boolean checkValidity();
  boolean reportValidity();
  undefined setCustomValidity(DOMString error);

  readonly attribute NodeList labels;

  [Pref="dom.element.commandfor.enabled", CEReactions] attribute Element? commandForElement;
  [Pref="dom.element.commandfor.enabled", CEReactions] attribute DOMString command;
};

HTMLButtonElement includes PopoverInvokerElement;
