import Foundation

#if canImport(dnssd)
  import dnssd

  /// A DNS-SD browser for `_remotepairing._tcp` advertisements that uses the system
  /// mDNSResponder through `DNSServiceBrowse`/`DNSServiceResolve`/`DNSServiceGetAddrInfo`.
  ///
  /// Raw multicast UDP is not usable from an ordinary process on current macOS: a
  /// `sendto` to `224.0.0.251` fails with `EHOSTUNREACH` because there is no unscoped
  /// multicast route and the Local Network privacy policy does not grant raw multicast to
  /// every process. The system resolver daemon does have the needed access, so browsing
  /// through `dnssd` is both correct and portable.
  final class DNSSDDiscoveryBrowser {
    private var browseRef: DNSServiceRef?
    private var childRefs: [DNSServiceRef] = []

    private struct Instance {
      var name: String
      var regtype: String
      var domain: String
      var interfaceIndex: UInt32
    }

    private var instances: [String: Instance] = [:]
    private var resolved: [String: RemotepairingDiscovery.Advertisement] = [:]
    private var addresses: [String: [RemotepairingDiscovery.Address]] = [:]

    /// Browses for up to `timeout` seconds and returns assembled advertisements.
    func browse(timeout: Double) throws -> [RemotepairingDiscovery.Advertisement] {
      var browseRef: DNSServiceRef?
      let context = Unmanaged.passUnretained(self).toOpaque()
      let serviceType = "_remotepairing._tcp"
      let domain = "local."
      let error = DNSServiceBrowse(
        &browseRef, 0, 0, serviceType, domain, browseCallback, context)
      guard error == kDNSServiceErr_NoError, let browseRef else {
        throw DiscoveryError.transport("could not start DNS-SD browsing (\(error))")
      }
      self.browseRef = browseRef
      defer {
        for ref in childRefs { DNSServiceRefDeallocate(ref) }
        DNSServiceRefDeallocate(browseRef)
        self.browseRef = nil
        childRefs.removeAll()
      }

      let deadline = Date().addingTimeInterval(timeout)
      while Date() < deadline {
        var refs: [DNSServiceRef] = []
        if let browseRef = self.browseRef { refs.append(browseRef) }
        refs.append(contentsOf: childRefs)
        guard !refs.isEmpty else { break }

        var descriptors: [pollfd] = refs.map {
          pollfd(fd: DNSServiceRefSockFD($0), events: Int16(POLLIN), revents: 0)
        }
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0 else { break }
        let timeoutMilliseconds = Int32(min(200, max(1, remaining * 1000)))
        let ready = poll(&descriptors, nfds_t(descriptors.count), timeoutMilliseconds)
        guard ready > 0 else { continue }
        for (index, descriptor) in descriptors.enumerated() where descriptor.revents != 0 {
          DNSServiceProcessResult(refs[index])
        }
      }

      return assemble()
    }

    // MARK: - Assembly

    private func assemble() -> [RemotepairingDiscovery.Advertisement] {
      resolved.values.map { advertisement in
        var advertisement = advertisement
        advertisement.addresses = (addresses[advertisement.host ?? ""] ?? []).sorted()
        return advertisement
      }
      .sorted { $0.instance < $1.instance }
    }

    // MARK: - Callback state

    fileprivate func handleBrowse(
      flags: DNSServiceFlags, interfaceIndex: UInt32, errorCode: DNSServiceErrorType,
      serviceName: String, regtype: String, replyDomain: String
    ) {
      guard errorCode == kDNSServiceErr_NoError else { return }
      let fullName =
        serviceName.hasSuffix(".")
        ? "\(serviceName)\(regtype)\(replyDomain)" : "\(serviceName).\(regtype)\(replyDomain)"
      if flags & DNSServiceFlags(kDNSServiceFlagsAdd) != 0 {
        instances[fullName] = Instance(
          name: serviceName, regtype: regtype, domain: replyDomain,
          interfaceIndex: interfaceIndex)
        startResolve(fullName)
      }
    }

    private func startResolve(_ fullName: String) {
      guard let instance = instances[fullName] else { return }
      var resolveRef: DNSServiceRef?
      let context = Unmanaged.passUnretained(self).toOpaque()
      let error = DNSServiceResolve(
        &resolveRef, 0, instance.interfaceIndex, instance.name, instance.regtype, instance.domain,
        resolveCallback, context)
      guard error == kDNSServiceErr_NoError, let resolveRef else { return }
      childRefs.append(resolveRef)
      pendingResolve[resolveRef] = fullName
    }

    fileprivate var pendingResolve: [DNSServiceRef: String] = [:]

    fileprivate func handleResolve(
      ref: DNSServiceRef, flags: DNSServiceFlags, interfaceIndex: UInt32,
      errorCode: DNSServiceErrorType, hostTarget: String, port: UInt16,
      txtRecord: UnsafePointer<UInt8>?, txtLen: UInt16
    ) {
      guard let fullName = pendingResolve[ref] else { return }
      pendingResolve.removeValue(forKey: ref)
      guard errorCode == kDNSServiceErr_NoError else { return }

      let host = hostTarget
      let data = txtRecord.map { Data(bytes: $0, count: Int(txtLen)) } ?? Data()
      let properties = RemotepairingDiscovery.parseTXT(data)
      resolved[fullName] = RemotepairingDiscovery.Advertisement(
        instance: fullName, host: host, port: Int(UInt16(bigEndian: port)), addresses: [],
        properties: properties)

      var addressRef: DNSServiceRef?
      let context = Unmanaged.passUnretained(self).toOpaque()
      let error = DNSServiceGetAddrInfo(
        &addressRef, 0, interfaceIndex,
        DNSServiceProtocol(kDNSServiceProtocol_IPv4 | kDNSServiceProtocol_IPv6),
        host, addrInfoCallback, context)
      guard error == kDNSServiceErr_NoError, let addressRef else { return }
      childRefs.append(addressRef)
      pendingAddress[addressRef] = host
    }

    fileprivate var pendingAddress: [DNSServiceRef: String] = [:]

    fileprivate func handleAddrInfo(
      ref: DNSServiceRef, interfaceIndex: UInt32, errorCode: DNSServiceErrorType,
      hostname: String, address: UnsafePointer<sockaddr>?
    ) {
      guard let host = pendingAddress[ref], errorCode == kDNSServiceErr_NoError, let address else {
        return
      }
      guard let ip = RemotepairingDiscovery.formatSockaddr(address) else { return }
      let interface = RemotepairingDiscovery.interfaceName(interfaceIndex)
      let existing = addresses[host] ?? []
      guard !existing.contains(where: { $0.ip == ip }) else { return }
      addresses[host] = existing + [RemotepairingDiscovery.Address(ip: ip, interface: interface)]
    }
  }

  // MARK: - C callbacks

  private func browseCallback(
    _: DNSServiceRef?, _ flags: DNSServiceFlags, _ interfaceIndex: UInt32,
    _ errorCode: DNSServiceErrorType, _ serviceName: UnsafePointer<CChar>?,
    _ regtype: UnsafePointer<CChar>?, _ replyDomain: UnsafePointer<CChar>?,
    _ context: UnsafeMutableRawPointer?
  ) {
    guard let context else { return }
    let browser = Unmanaged<DNSSDDiscoveryBrowser>.fromOpaque(context).takeUnretainedValue()
    browser.handleBrowse(
      flags: flags, interfaceIndex: interfaceIndex, errorCode: errorCode,
      serviceName: serviceName.map(String.init(cString:)) ?? "",
      regtype: regtype.map(String.init(cString:)) ?? "",
      replyDomain: replyDomain.map(String.init(cString:)) ?? "")
  }

  private func resolveCallback(
    _ ref: DNSServiceRef?, _ flags: DNSServiceFlags, _ interfaceIndex: UInt32,
    _ errorCode: DNSServiceErrorType, _ fullname: UnsafePointer<CChar>?,
    _ hosttarget: UnsafePointer<CChar>?, _ port: UInt16, _ txtLen: UInt16,
    _ txtRecord: UnsafePointer<UInt8>?, _ context: UnsafeMutableRawPointer?
  ) {
    guard let ref, let context else { return }
    let browser = Unmanaged<DNSSDDiscoveryBrowser>.fromOpaque(context).takeUnretainedValue()
    browser.handleResolve(
      ref: ref, flags: flags, interfaceIndex: interfaceIndex, errorCode: errorCode,
      hostTarget: hosttarget.map(String.init(cString:)) ?? "", port: port,
      txtRecord: txtRecord, txtLen: txtLen)
    _ = fullname
  }

  private func addrInfoCallback(
    _ ref: DNSServiceRef?, _ flags: DNSServiceFlags, _ interfaceIndex: UInt32,
    _ errorCode: DNSServiceErrorType, _ hostname: UnsafePointer<CChar>?,
    _ address: UnsafePointer<sockaddr>?, _ ttl: UInt32, _ context: UnsafeMutableRawPointer?
  ) {
    guard let ref, let context else { return }
    let browser = Unmanaged<DNSSDDiscoveryBrowser>.fromOpaque(context).takeUnretainedValue()
    browser.handleAddrInfo(
      ref: ref, interfaceIndex: interfaceIndex, errorCode: errorCode,
      hostname: hostname.map(String.init(cString:)) ?? "", address: address)
    _ = flags
    _ = ttl
  }
#endif
