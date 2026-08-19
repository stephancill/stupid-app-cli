# App Extensions And App Groups Scope

Status: **implemented and qualified through App Store Connect + simulator** at this
commit. The design shipped as `stupid-app` multi-bundle support: config/planner/packer build
`PlugIns/*.appex` extensions, a leaf-first `DeepSigningPipeline` signs each extension then
the app with per-file nested sealing, `EntitlementDeriver` supports App Groups with a loud
profile-authorization gate, `signing setup` enables the `APP_GROUPS` capability and
provisions all project bundles, and the release manifest records the extension bundle IDs.
A deep build (`stupid-widgets`, app + WidgetKit extension + App Group) uploaded to App Store
Connect, processed to `VALID` and internal `IN_BETA_TESTING`, and installed/launched on the
simulator with the widget extension loaded, and a physical-device wireless `run --network`
installed and launched the deep app (with the widget extension) on the iPhone. This
document remains the working basis.

## Motivation And Goal

`stupid-widgets` is the first real dogfood of a multi-bundle app:

- a main application `net.stupidtech.stupidwidgets` (`StupidWidgets` -> `StupidWidgetsApp`);
- a WidgetKit app extension `net.stupidtech.stupidwidgets.widget`
  (`StupidWidgetsWidgetExtension` -> `PlugIns/StupidWidgetsWidgetExtension.appex` with
  `NSExtensionPointIdentifier = com.apple.widgetkit-extension`);
- both bundles request `com.apple.security.application-groups` =
  `group.net.stupidtech.stupidwidgets`, through which the app mirrors its script library into
  the extension's container;
- the extension packages generated App Intents metadata
  (`WidgetMetadata/Metadata.appintents`, produced off-line by `appintentsmetadataprocessor`
  and checked in).

Goal: `stupid-app new`/`build`/`run`/`release archive`/`release upload` handle a project with
one app plus any number of bundled app extensions (`PlugIns/*.appex`) and shared App Groups,
with one Apple identity and one IPA.

## Current State (Verified)

- `AppConfig`/`Planner` model exactly one library product as one app with no extensions
  (`Sources/ProjectCore/AppConfig.swift`, `Sources/BuildCore/Planner.swift`).
- `NativeAppClassifier` rejects any nested signable directory or bundle
  (`Sources/SigningKit/NativeAppClassifier.swift:49-79`); `NativeSigner` is
  `native-shallow-v1` and signs exactly one bundle (`.swift:4, 56`).
- `NativeCodeResources.collectSeals` recursively hashes every in-bundle file
  (`Sources/SigningKit/NativeCodeResources.swift:113-161`); the modern `rules2` carry
  `nested: true` for `PlugIns/` etc. (lines 224-229) but no nested-code sealing is emitted.
- `EntitlementDeriver.supportedKeys` is the bare three-key set and rejects everything else
  (`Sources/SigningKit/EntitlementDeriver.swift:43-47`).
- `SigningSetupCommand` provisions one bundle ID per kind; `release archive` and `run` locate
  `profiles/<bundleID> AppStore|Development.mobileprovision`.
- `ASCOperations` has no `bundleIdCapabilities` operation.
- App Store Connect (`specs/latest.json`): `APP_GROUPS` is a `CapabilityType` under
  `bundleIdCapabilities`, but there is **no** `/v1/appGroups` resource and `CapabilitySetting`
  keys are only `ICLOUD_VERSION`, `DATA_PROTECTION_PERMISSION_LEVEL`,
  `APPLE_ID_AUTH_APP_CONSENT`. So the API enables the capability but cannot create the group
  or associate the concrete group identifier with the bundle ID.

## Scope

In scope:

- Bundled app extensions under `PlugIns/*.appex` (WidgetKit here; the mechanism generalizes
  to other app extensions).
- Per-bundle (app + each extension) configuration, provisioning, entitlement derivation,
  signing, and resource packaging.
- Deep / nested signing with leaf-first signing order and nested-code sealing.
- App Group support end to end: capability enablement via API, driven by one source
  application-group declaration, with loud failure when the returned profile does not
  authorize the requested group (the concrete association remains a one-time Developer
  Portal step — see "App Groups provisioning").
- Packaging a bundled App Intents metadata directory into each extension that declares one.

Explicitly out of current scope (fail loudly where they would otherwise be copied silently):

- Other Apple build-tool outputs we do not yet have a writer for (e.g. if a resource type is
  neither a raw resource, the supported icon asset catalog, nor a declared App Intents metadata
  directory).
- Shared `Frameworks/*.framework` embedding in the v1 build (the WidgetKit extension links its
  shared `StupidWidgetsCore` statically via SwiftPM, so no dynamic framework is required yet).
  The nested-seal and leaf-first signing machinery is designed so frameworks are an easy later
  addition.
- Non-iOS extension kinds, watch/today/notification-content in the first cut.
- Assocating new App Group identifiers through the CLI (unreachable via the public API).

## Design Decisions

1. **One flat `extensions:` list** in `stupid-app.yml`. Each entry is an app model almost
   identical to the root: `product`, `bundleID`, `infoPath`, `entitlementsPath`, optional
   `deploymentTarget`, optional `resources`, optional `appIntentsMetadata`.
2. **Exact bundle IDs preserved** (project invariant) — never a rewrite prefix.
3. **One identity per kind**, shared by the app and its extensions (real Apple Development /
   Distribution identity, never pseudo-signed).
4. **Leaf-first signing order** enforced by a single `SigningPipeline` entry: frameworks (none
   yet) -> extensions -> app. Each bundle receives its own profile and its own derived
   entitlements; the app is signed last so its `CodeResources` can seal the nested bundles.
5. **App Groups are single-source.** The group identifiers are read from the source
   entitlements (and thus from `stupid-app.yml` configuration, not re-derivable hidden state).
   The pipeline enables the `APP_GROUPS` capability on each bundle ID via the API (idempotent,
   best-effort) and then **fails loudly** if the downloaded profile does not carry the requested
   `com.apple.security.application-groups` entitlement. The one-time portal step — creating
   `group.net.stupidtech.stupidwidgets` and associating it with both bundle IDs — is documented,
   checked by the CLI, and required before signing can succeed.
6. **App Intents metadata is a declared, sealed directory.** Accept it only for extension
   config as an explicit `appIntentsMetadata` path; pack it at the appex bundle root
   (`WidgetMetadata/Metadata.appintents`) and let normal resource sealing cover it. Anything
   else that looks like a generated Apple build-tool output is rejected loudly.

## Command And Config Surface

New `stupid-app.yml` shape (super-set; existing single-app projects remain valid):

```yaml
version: 1
product: StupidWidgets
bundleID: net.stupidtech.stupidwidgets
deploymentTarget: "17.0"
infoPath: Info.plist
entitlementsPath: StupidWidgets.entitlements
iconPath: Resources/AppIcon.appiconset/Icon-1024.png
resources:
  - Resources/scriptable-api.json
  - "Resources/Hello Widget.scriptable"
  - "Resources/Read MacStories.scriptable"
extensions:
  - product: StupidWidgetsWidgetExtension
    bundleID: net.stupidtech.stupidwidgets.widget
    infoPath: WidgetExtension-Info.plist
    entitlementsPath: StupidWidgetsWidgetExtension.entitlements
    appIntentsMetadata: WidgetMetadata/Metadata.appintents
    resources:
      - WidgetMetadata/Metadata.appintents
```

Notes:

- `deploymentTarget` defaults to the root value when omitted on an extension.
- `appIntentsMetadata` is a convenience that both packs the directory and adds it to the
  extension's seal; listing it under `resources` is redundant and tolerated/ignored.
- `--bundle-id` on `signing setup` is already repeatable, so provisioning the app + extension
  in one call is a natural fit (optionally read from `stupid-app.yml` instead of just the root
  bundle ID).

## Build Architecture

### Planner (`Sources/BuildCore/Planner.swift`)

- Add `extensionPlans: [ExtensionPlan]` to `BuildPlan`, where `ExtensionPlan` carries the same
  fields the root plan carries (product, bundleID, deploymentTarget, infoPlist, resources,
  iconPath?, entitlementsPath, appIntentsMetadata?).
- `makePlan()` independently selects each configured library product by name and synthesizes
  its `Info.plist` from its own `infoPath` with extension-appropriate baseline keys
  (`CFBundlePackageType = "XPC!"`, `NSExtension` preserved from source, `CFBundleExecutable` /
  `CFBundleIdentifier` from the product/bundle ID, `CFBundleSupportedPlatforms`), reusing the
  build-system provenance injection.
- Validate: product exists and is a library; bundle IDs valid and exact; `appIntentsMetadata`
  exists and is a directory; resources relative and non-escaping. Fail loudly on any
  unknown/generated resource type.

### Packer (`Sources/BuildCore/Packer.swift`)

- Generalize the "build one synthetic executable depending on the configured product" step
  into building the app product and each extension product (same scaffold, disabled automatic
  resolution, separate `.appex` assembly).
- `assembleApp` additionally builds each extension into `PlugIns/<Product>.appex`:
  copy the extension executable, merge the extension `Info.plist`, copy the extension's
  declared resources (including `WidgetMetadata/Metadata.appintents` at the appex root), and
  (if configured) generate the extension icon set + `Assets.car` via the existing
  `IconGenerator`/`AssetCatalogWriter`.
- Ship everything to the `.app` unsigned; the individual bundles are signed by `SigningPipeline`
  afterward.

## Signing Architecture

### NativeAppClassifier (`Sources/SigningKit/NativeAppClassifier.swift`)

- Introduce a `deep` classification that permits `PlugIns/` (and, later, `Frameworks/`) with
  nested signable bundles while still rejecting executable leakage and escaping symlinks.
- Keep `shallow` behavior for the current single-app path; the engine version becomes
  `native-shallow-v1` (unchanged) and `native-deep-v1` (new).

### NativeCodeResources (`Sources/SigningKit/NativeCodeResources.swift`)

- Implement nested-code sealing: when a nested directory (under `PlugIns/` etc.) is present,
  `collectSeals` must skip descending into it and instead record the nested bundle's
  `CodeDirectory` digest under its relative path, matching how `codesign` seals embedded
  code. The existing `rules2` already mark these paths `nested: true`; only the seal
  collection must change (and the sealer must be called after each nested bundle is signed).
- `verify` must reproduce the same nested-seal semantics.

### NativeSigner + SigningPipeline (`Sources/SigningKit/NativeSigner.swift`, `.swift:SigningPipeline`)

- Add a `DeepSigningPipeline` (or extend `SigningPipeline`) that, given the assembled `.app`
  plus the per-bundle profile/entitlements identity inputs, signs in leaf-first order:
  1. For each extension: derive entitlements (with its own bundle ID + team), embed its
     profile, sign `PlugIns/<Ext>.appex` with the native engine (`deep` classification);
  2. Embed the app profile, derive the app entitlements, sign the `.app` last so it seals the
     now-signed nested extension.
- The `NativeSigner` signature stays single-bundle (leaf) and the orchestration owns the
  order; this keeps each signing pass independently testable.
- `NativeAppClassifier.deep` is used for app-level classification; the appex is classified with
  the (now shallow-equivalent) leaf path.

## App Groups Provisioning

### Enablement (`Sources/ASCKit/ASCOperations.swift`)

- Add `bundleIdCapabilities` operations: `createBundleIdCapability(bundleId:capabilityType:)`
  (POST `/v1/bundleIdCapabilities` with `capabilityType: APP_GROUPS`) and a list/read of
  existing capabilities for idempotency (GET `/v1/bundleIds/{id}/bundleIdCapabilities`).
- Best-effort: a failed enable step is reported, not fatal by itself; the authoritative check
  is whether the downloaded profile carries the entitlement.

### Authorization check (`Sources/SigningKit/EntitlementDeriver.swift`)

- Add `com.apple.security.application-groups` to `supportedKeys`.
- Reconcile it against the profile with the existing array-subset logic (it already handles
  `[Any]`/`[String]` subset semantics at EntitlementDeriver.swift:101-107).
- The final Check that the profile actually authorizes the requested group becomes the strong
  gate: if the operator has not completed the manual portal association, the profile will not
  contain the identifier and `derive` raises `notAuthorizedByProfile`, so `signing setup` /
  `release archive` / `run` fail loudly with an actionable message pointing at the portal step.

### One-time manual step (documented, enforced)

Creating `group.net.stupidtech.stupidwidgets` and associating it with both bundle IDs under
Developer portal (Certificates, Identifiers & Profiles -> Identifiers -> App Groups) is not
reachable through the public API. `stupid-app doctor` should surface the pending step as a
warning when the configured app-group entitlement is not yet authorized, and `signing setup`
should print the exact URL/form guidance.

## Distribution

- `release archive`: locate and embed each bundle's App Store profile; deep-sign; package the
  IPA with `Payload/<App>.app/PlugIns/<Ext>.appex` present and nested-sealed.
- `release upload`: unchanged transport; the manifest
  (`Sources/ASCKit/ReleaseManifest.swift`) records the app bundle ID/version/build plus the
  list of bundled extensions (bundle ID, product, resource seal) — still credential-safe.
- `run`/`release`: `locateProfile` already keys by bundle ID, so add the extension bundle IDs
  to the per-bundle profile lookup.
- `doctor`: add checks for extension config validity, per-bundle profile presence, and the
  app-group authorization pending state.

## Security And Style

- Same rules as today: credentials `0700`/`0600`, atomic writes, no pseudo/ad-hoc signing,
  secrets never in logs/manifests/notes. Per-bundle profiles and identities remain in the
  hardened store; private key material never enters the IPA.
- Nested sealing inputs and the leaf-first order are enforced by the pipeline, not by
  operator scripts (no external `codesign`/`pkill` dependence).
- One function per boundary; each per-bundle step (derivation, seal, sign, verify) stays
  independently testable with sanitized fixtures.

## Verification Gates

Completed during qualification:

1. `doctor` passes for a deep project (app + extension + App Group). ✅
2. `stupid-app build` produces a `.app` with a `PlugIns/<Ext>.appex`, its App Intents
   metadata, and (once signed) a valid deep seal. ✅
3. `codesign --verify --strict` passes on the extension alone and `--verify --deep --strict`
   passes on the whole app; embedded profiles present in both bundles. ✅
4. `release archive` produces a distribution IPA whose extension and app are each
   Distribution-signed with their own App Store profile and timestamps disabled. ✅
5. `release upload --wait` — App Store Connect processed a live deep build to `VALID` and
   internal `IN_BETA_TESTING`; the extension bundle ID is recorded in the release manifest. ✅
   (Gallery appearance from App Intents metadata was not separately asserted on this run.)
6. App Group behavior: `run` and `release` fail loudly when the profile does not authorize
   the group; both produced distribution profiles authorized
   `group.net.stupidtech.stupidwidgets`. Physical-device read/write through the shared
   container remains open. ⏳ (partially)
7. Regression: the single-app path and existing suite pass (224 tests). ✅

Remaining: manually confirm on the device that the widget appears in the Home Screen
gallery and that an App-Group-backed script selection refreshes the extension's timeline
(read/write through the shared container on a real device). These are visual/behavioral
checks rather than pipeline requirements; the iOS runtime install/launch and the App Store
processing are the pipeline authority and have passed.

## Risks / Open Decisions

- **Nested-seal exactness**: resolved. The App Store rejected `90034` until the shallow
  `^[^/]+$/nested:true` rule was removed so the containing app seals appex files per-file,
  matching `codesign`'s output; a deep build then passed `codesign` and App Store
  processing. (Resolved.)
- **App Group portal dependency**: the concrete group association cannot be automated; it is
  an accepted, loudly-guarded manual prerequisite. Verified the generated profiles already
  carried the requested group. (Still true.)
- **App Intents metadata provenance**: the checked-in `Metadata.appintents` is packaged and
  sealed; not regenerated by `stupid-app`. (Still true.)
- **Extension entry point / linking**: extensions link with `-e _NSExtensionMain` and
  `libextension` (ASC `90898` otherwise); extensions also require
  `UIRequiredDeviceCapabilities=[arm64]` (ASC `90502`). (Resolved.)
- Whether the deep path also handles `Frameworks/` is deferred (statically linked core keeps
  it out of the first cut).
