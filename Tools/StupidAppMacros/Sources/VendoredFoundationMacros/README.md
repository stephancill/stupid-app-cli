# Vendored FoundationMacros

`PredicateMacro.swift` and `BundleMacro.swift` are copied unchanged from
[swift-foundation](https://github.com/swiftlang/swift-foundation) at tag
`swift-6.4.2-RELEASE` (`Sources/FoundationMacros`), under the Apache License v2.0 with
Runtime Library Exception (`LICENSE.md`).

The Linux Swift toolchain ships these macros built for Linux, where `#Predicate` expands to
`FoundationEssentials` names. Apple's iOS SDK has those types in `Foundation`, so this
target builds the same sources with `FOUNDATION_FRAMEWORK` defined, which makes them emit
`Foundation` names as Apple's own build does.
