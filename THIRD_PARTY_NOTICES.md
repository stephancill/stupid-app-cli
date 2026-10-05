# Third-Party Notices

## LZFSE

The `Sources/CLZFSE` target contains source from Apple's LZFSE reference
implementation, pinned at commit
`e634ca58b4821d9f3d560cdc6df5dec02ffc93fd` from
<https://github.com/lzfse/lzfse>. The source is used without modification except
for its Swift Package target layout.

Copyright (c) 2015-2016, Apple Inc. All rights reserved.

Redistribution and use in source and binary forms, with or without modification,
are permitted provided that the following conditions are met:

1. Redistributions of source code must retain the above copyright notice,
   this list of conditions and the following disclaimer.
2. Redistributions in binary form must reproduce the above copyright notice,
   this list of conditions and the following disclaimer in the documentation
   and/or other materials provided with the distribution.
3. Neither the name of the copyright holder(s) nor the names of any contributors
   may be used to endorse or promote products derived from this software without
   specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR
ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
(INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON
ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

## pymobiledevice3

The optional physical-device transport is provisioned from the frozen environment in
`Tools/pymobiledevice3` and requires `pymobiledevice3` 8.2.1. The dependency is not
vendored in this repository. pymobiledevice3 is distributed under GPL-3.0-or-later;
installations and redistributions must comply with its license and the licenses of its
transitive dependencies.

Source: <https://github.com/doronz88/pymobiledevice3>

## OpenSSL

`DeviceKit` dynamically links a host-provided OpenSSL 3.x installation through
`COpenSSL` for the qualified CoreDevice TLS 1.2 PSK connection and lockdown
client-certificate session/service TLS. OpenSSL source is not vendored. OpenSSL is
distributed under the Apache License 2.0.

Source: <https://github.com/openssl/openssl>

## libimobiledevice

The native lockdown pairing certificate shape and request sequence were checked against
`libimobiledevice` as an interoperability reference. libimobiledevice source is not
vendored or linked by this package. libimobiledevice is distributed under
LGPL-2.1-or-later.

Source: <https://github.com/libimobiledevice/libimobiledevice>

## lwIP

The userspace tunnel spike vendors the upstream lwIP core (excluding IPv4) and
headers under `Sources/CUserspaceIP/vendor`. The files are
unmodified and pinned to lwIP 2.2.1, tag `STABLE-2_2_1_RELEASE`, commit
`77dcd25a72509eb83f72b033d219b1d40cd8eb95`. The surrounding C shim, Swift adapters,
and configuration are project-owned. Individual upstream source notices are
retained; the upstream BSD-3-Clause license follows.

Source: <https://github.com/lwip-tcpip/lwip>

Copyright (c) 2001, 2002 Swedish Institute of Computer Science.
All rights reserved.

Redistribution and use in source and binary forms, with or without modification,
are permitted provided that the following conditions are met:

1. Redistributions of source code must retain the above copyright notice,
   this list of conditions and the following disclaimer.
2. Redistributions in binary form must reproduce the above copyright notice,
   this list of conditions and the following disclaimer in the documentation
   and/or other materials provided with the distribution.
3. The name of the author may not be used to endorse or promote products
   derived from this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE AUTHOR ``AS IS'' AND ANY EXPRESS OR IMPLIED
WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF
MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT
SHALL THE AUTHOR BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT
OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING
IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY
OF SUCH DAMAGE.
