
#import "PilotIDeviceBridge.h"
#import "idevice.h"

#import <Foundation/Foundation.h>
#import <arpa/inet.h>
#import <netinet/in.h>
#import <sys/socket.h>
#import <ifaddrs.h>
#import <netdb.h>
#import <net/if.h>
#import <unistd.h>
#import <errno.h>
#import <fcntl.h>
#import <sys/select.h>
#import <stdio.h>

static BOOL PPBuildNumericSocketAddress(
    const char *host,
    uint16_t port,
    struct sockaddr_storage *storage,
    socklen_t *lengthOut
);


extern int32_t pilot_xctest_metadata(
    struct AdapterHandle *adapter,
    struct RsdHandshakeHandle *handshake,
    char *message,
    size_t message_capacity
);

extern int32_t pilot_xctest_execute_center_tap(
    struct AdapterHandle *adapter,
    struct RsdHandshakeHandle *handshake,
    char *message,
    size_t message_capacity
);

extern int32_t pilot_xctest_execute_activate(
    struct AdapterHandle *adapter,
    struct RsdHandshakeHandle *handshake,
    char *message,
    size_t message_capacity
);

extern int32_t pilot_xctest_execute_tap(
    struct AdapterHandle *adapter,
    struct RsdHandshakeHandle *handshake,
    double normalized_x,
    double normalized_y,
    char *message,
    size_t message_capacity
);

extern int32_t pilot_xctest_execute_swipe(
    struct AdapterHandle *adapter,
    struct RsdHandshakeHandle *handshake,
    double from_x,
    double from_y,
    double to_x,
    double to_y,
    double duration,
    char *message,
    size_t message_capacity
);

extern int32_t pilot_xctest_execute_select12(
    struct AdapterHandle *adapter,
    struct RsdHandshakeHandle *handshake,
    char *message,
    size_t message_capacity
);

extern int32_t pilot_xctest_execute_dispatch_tail(
    struct AdapterHandle *adapter,
    struct RsdHandshakeHandle *handshake,
    double pink_x,
    double pink_y,
    int32_t pink_count,
    int32_t fast_mode,
    char *message,
    size_t message_capacity
);


// Stage 11.3.2 phone-local Personalized DDI mount export.
extern int32_t pilot_ddi_mount_personalized(
    struct AdapterHandle *adapter,
    struct RsdHandshakeHandle *handshake,
    const char *image_path,
    const char *build_manifest_path,
    const char *trustcache_path,
    char *message,
    size_t message_capacity
);

// Stage 9.1 phone-local Runner self-install export injected into idevice-ffi.
extern int32_t pilot_runner_install_ipa(
    struct AdapterHandle *adapter,
    struct RsdHandshakeHandle *handshake,
    const char *local_ipa_path,
    char *message,
    size_t message_capacity
);

// Custom Stage 7.6 runner discovery export injected into idevice-ffi.
extern int32_t pilot_xctest_runner_discovery(
    struct AdapterHandle *adapter,
    struct RsdHandshakeHandle *handshake,
    char *message,
    size_t message_capacity
);

// Custom Stage 7.5 C ABI export injected into idevice-ffi at build time.
extern int32_t pilot_xctest_dtx_bootstrap(
    struct AdapterHandle *adapter,
    struct RsdHandshakeHandle *handshake,
    char *message,
    size_t message_capacity
);


// Custom Stage 7.4 C ABI export injected into idevice-ffi at build time.
extern int32_t pilot_xctest_service_probe(
    struct RsdHandshakeHandle *handshake,
    char *message,
    size_t message_capacity
);


static void PPWriteMessage(char *message, size_t capacity, NSString *text) {
    if (message == NULL || capacity == 0) {
        return;
    }

    const char *utf8 = text.UTF8String ?: "";
    snprintf(message, capacity, "%s", utf8);
    message[capacity - 1] = '\0';
}


static BOOL PPSendAll(int fd, const uint8_t *bytes, size_t length) {
    size_t offset = 0;
    while (offset < length) {
        ssize_t sent = send(fd, bytes + offset, length - offset, 0);
        if (sent <= 0) {
            return NO;
        }
        offset += (size_t)sent;
    }
    return YES;
}

static BOOL PPRecvExact(int fd, uint8_t *bytes, size_t length) {
    size_t offset = 0;
    while (offset < length) {
        ssize_t received = recv(fd, bytes + offset, length - offset, 0);
        if (received <= 0) {
            return NO;
        }
        offset += (size_t)received;
    }
    return YES;
}

static NSString *PPErrnoText(int value) {
    const char *text = strerror(value);
    return text != NULL ? [NSString stringWithUTF8String:text] : @"unknown";
}

static NSString *PPProbeLockdownAddress(NSString *host, BOOL *readyOut) {
    if (readyOut != NULL) {
        *readyOut = NO;
    }

    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) {
        int e = errno;
        return [NSString stringWithFormat:@"TCP=SOCKET-FAIL errno=%d %@", e, PPErrnoText(e)];
    }

    struct timeval timeout;
    timeout.tv_sec = 2;
    timeout.tv_usec = 0;
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));

    struct sockaddr_in address;
    memset(&address, 0, sizeof(address));
#if defined(__APPLE__)
    address.sin_len = sizeof(address);
#endif
    address.sin_family = AF_INET;
    address.sin_port = htons(62078);

    if (inet_pton(AF_INET, host.UTF8String, &address.sin_addr) != 1) {
        close(fd);
        return @"TCP=BAD-ADDRESS";
    }

    if (connect(fd, (const struct sockaddr *)&address, sizeof(address)) != 0) {
        int e = errno;
        close(fd);
        return [NSString stringWithFormat:@"TCP=FAIL errno=%d %@", e, PPErrnoText(e)];
    }

    NSDictionary *request = @{
        @"Label": @"PikminPilot-NoVPN-Probe",
        @"Request": @"QueryType"
    };
    NSError *plistError = nil;
    NSData *payload = [NSPropertyListSerialization dataWithPropertyList:request
                                                                 format:NSPropertyListXMLFormat_v1_0
                                                                options:0
                                                                  error:&plistError];
    if (payload == nil) {
        close(fd);
        return [NSString stringWithFormat:@"TCP=CONNECTED LOCKDOWN=REQUEST-ENCODE-FAIL %@",
                plistError.localizedDescription ?: @"unknown"];
    }

    uint32_t networkLength = htonl((uint32_t)payload.length);
    if (!PPSendAll(fd, (const uint8_t *)&networkLength, sizeof(networkLength)) ||
        !PPSendAll(fd, payload.bytes, payload.length)) {
        int e = errno;
        close(fd);
        return [NSString stringWithFormat:@"TCP=CONNECTED LOCKDOWN=SEND-FAIL errno=%d %@", e, PPErrnoText(e)];
    }

    uint32_t responseNetworkLength = 0;
    if (!PPRecvExact(fd, (uint8_t *)&responseNetworkLength, sizeof(responseNetworkLength))) {
        int e = errno;
        close(fd);
        return [NSString stringWithFormat:@"TCP=CONNECTED LOCKDOWN=NO-HEADER errno=%d %@", e, PPErrnoText(e)];
    }

    uint32_t responseLength = ntohl(responseNetworkLength);
    if (responseLength == 0 || responseLength > 4000000) {
        close(fd);
        return [NSString stringWithFormat:@"TCP=CONNECTED LOCKDOWN=BAD-LENGTH(%u)", responseLength];
    }

    NSMutableData *response = [NSMutableData dataWithLength:responseLength];
    if (!PPRecvExact(fd, response.mutableBytes, responseLength)) {
        int e = errno;
        close(fd);
        return [NSString stringWithFormat:@"TCP=CONNECTED LOCKDOWN=SHORT-REPLY errno=%d %@", e, PPErrnoText(e)];
    }
    close(fd);

    NSPropertyListFormat responseFormat = NSPropertyListXMLFormat_v1_0;
    NSError *decodeError = nil;
    id object = [NSPropertyListSerialization propertyListWithData:response
                                                          options:NSPropertyListImmutable
                                                           format:&responseFormat
                                                            error:&decodeError];
    if (![object isKindOfClass:[NSDictionary class]]) {
        return [NSString stringWithFormat:@"TCP=CONNECTED LOCKDOWN=NON-PLIST(%u)b %@",
                responseLength, decodeError.localizedDescription ?: @""];
    }

    NSDictionary *dictionary = (NSDictionary *)object;
    NSString *type = [dictionary[@"Type"] isKindOfClass:[NSString class]] ? dictionary[@"Type"] : @"?";
    NSString *requestName = [dictionary[@"Request"] isKindOfClass:[NSString class]] ? dictionary[@"Request"] : @"?";
    BOOL ready = [type rangeOfString:@"lockdown" options:NSCaseInsensitiveSearch].location != NSNotFound ||
                 [requestName isEqualToString:@"QueryType"];
    if (ready) {
        if (readyOut != NULL) {
            *readyOut = YES;
        }
        return [NSString stringWithFormat:@"TCP=CONNECTED LOCKDOWN=READY type=%@", type];
    }

    NSArray *keys = [[dictionary allKeys] sortedArrayUsingSelector:@selector(compare:)];
    return [NSString stringWithFormat:@"TCP=CONNECTED LOCKDOWN=REPLY keys=%@", [keys componentsJoinedByString:@","]];
}

int32_t PPProbeCellularLockdownRoute(char *message, size_t messageCapacity) {
    BOOL ready = NO;
    NSString *result = PPProbeLockdownAddress(@"10.7.0.1", &ready);
    NSString *text = [NSString stringWithFormat:
        @"CELLULAR LOCKDOWN ROUTE %@ • 10.7.0.1:62078 • %@",
        ready ? @"READY ✅" : @"FAILED ❌",
        result];
    PPWriteMessage(message, messageCapacity, text);
    return ready ? 0 : 1;
}


// Stage 11.5.4.3: distinguish the fixed RPPairing ingress socket from the
// later createListener/device-socket hop hidden inside tunnel_create_rppairing.
// This probe runs only after the normal tunnel already failed, so it cannot
// mask a successful RSD session. It never sends RPPairing protocol bytes.
static NSString *PPIPv4InterfaceNameForAddress(struct in_addr wanted) {
    struct ifaddrs *interfaces = NULL;
    if (getifaddrs(&interfaces) != 0 || interfaces == NULL) {
        return @"?";
    }

    NSString *match = @"?";
    for (struct ifaddrs *cursor = interfaces; cursor != NULL; cursor = cursor->ifa_next) {
        if (cursor->ifa_addr == NULL || cursor->ifa_addr->sa_family != AF_INET) {
            continue;
        }
        const struct sockaddr_in *sin = (const struct sockaddr_in *)cursor->ifa_addr;
        if (sin->sin_addr.s_addr == wanted.s_addr) {
            match = cursor->ifa_name != NULL
                ? [NSString stringWithUTF8String:cursor->ifa_name]
                : @"?";
            break;
        }
    }
    freeifaddrs(interfaces);
    return match;
}

static NSString *PPCompactIPv4Interfaces(void) {
    struct ifaddrs *interfaces = NULL;
    if (getifaddrs(&interfaces) != 0 || interfaces == NULL) {
        return @"ifs=?";
    }

    NSMutableArray<NSString *> *items = [NSMutableArray array];
    for (struct ifaddrs *cursor = interfaces; cursor != NULL; cursor = cursor->ifa_next) {
        if (cursor->ifa_addr == NULL || cursor->ifa_addr->sa_family != AF_INET) {
            continue;
        }
        NSString *name = cursor->ifa_name != NULL
            ? [NSString stringWithUTF8String:cursor->ifa_name]
            : @"?";
        if (![name isEqualToString:@"en0"] &&
            ![name hasPrefix:@"pdp_ip"] &&
            ![name hasPrefix:@"utun"] &&
            ![name isEqualToString:@"lo0"]) {
            continue;
        }

        char host[INET_ADDRSTRLEN] = {0};
        const struct sockaddr_in *sin = (const struct sockaddr_in *)cursor->ifa_addr;
        if (inet_ntop(AF_INET, &sin->sin_addr, host, sizeof(host)) == NULL) {
            continue;
        }
        [items addObject:[NSString stringWithFormat:@"%@=%s", name, host]];
    }
    freeifaddrs(interfaces);
    [items sortUsingSelector:@selector(compare:)];
    return [NSString stringWithFormat:@"ifs=[%@]", [items componentsJoinedByString:@","]];
}

static NSString *PPProbeTCPIngress(NSString *host, uint16_t port, BOOL *connectedOut) {
    if (connectedOut != NULL) {
        *connectedOut = NO;
    }

    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) {
        int e = errno;
        return [NSString stringWithFormat:@"TCP=SOCKET-FAIL errno=%d %@", e, PPErrnoText(e)];
    }

    int oldFlags = fcntl(fd, F_GETFL, 0);
    if (oldFlags >= 0) {
        (void)fcntl(fd, F_SETFL, oldFlags | O_NONBLOCK);
    }

    struct sockaddr_in address;
    memset(&address, 0, sizeof(address));
#if defined(__APPLE__)
    address.sin_len = sizeof(address);
#endif
    address.sin_family = AF_INET;
    address.sin_port = htons(port);
    if (inet_pton(AF_INET, host.UTF8String, &address.sin_addr) != 1) {
        close(fd);
        return @"TCP=BAD-ADDRESS";
    }

    int rc = connect(fd, (const struct sockaddr *)&address, sizeof(address));
    if (rc != 0 && errno == EINPROGRESS) {
        fd_set writeSet;
        FD_ZERO(&writeSet);
        FD_SET(fd, &writeSet);
        struct timeval tv = { .tv_sec = 2, .tv_usec = 0 };
        rc = select(fd + 1, NULL, &writeSet, NULL, &tv);
        if (rc > 0 && FD_ISSET(fd, &writeSet)) {
            int socketError = 0;
            socklen_t errorLength = (socklen_t)sizeof(socketError);
            if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &socketError, &errorLength) == 0 && socketError == 0) {
                rc = 0;
            } else {
                errno = socketError != 0 ? socketError : errno;
                rc = -1;
            }
        } else if (rc == 0) {
            errno = ETIMEDOUT;
            rc = -1;
        } else {
            rc = -1;
        }
    }

    if (rc != 0) {
        int e = errno;
        close(fd);
        return [NSString stringWithFormat:@"TCP=FAIL errno=%d %@", e, PPErrnoText(e)];
    }

    if (oldFlags >= 0) {
        (void)fcntl(fd, F_SETFL, oldFlags);
    }

    struct sockaddr_in local;
    memset(&local, 0, sizeof(local));
    socklen_t localLength = (socklen_t)sizeof(local);
    NSString *localText = @"?";
    NSString *interfaceName = @"?";
    if (getsockname(fd, (struct sockaddr *)&local, &localLength) == 0) {
        char localHost[INET_ADDRSTRLEN] = {0};
        if (inet_ntop(AF_INET, &local.sin_addr, localHost, sizeof(localHost)) != NULL) {
            localText = [NSString stringWithFormat:@"%s:%u", localHost, ntohs(local.sin_port)];
            interfaceName = PPIPv4InterfaceNameForAddress(local.sin_addr);
        }
    }

    close(fd);
    if (connectedOut != NULL) {
        *connectedOut = YES;
    }
    return [NSString stringWithFormat:@"TCP=CONNECTED local=%@ if=%@", localText, interfaceName];
}

static NSString *PPFormatSockaddr(const struct sockaddr *sa, socklen_t length) {
    if (sa == NULL) return @"?";
    char host[NI_MAXHOST] = {0};
    char service[NI_MAXSERV] = {0};
    int rc = getnameinfo(sa, length, host, sizeof(host), service, sizeof(service),
                         NI_NUMERICHOST | NI_NUMERICSERV);
    if (rc != 0) return @"?";
    if (sa->sa_family == AF_INET6) {
        return [NSString stringWithFormat:@"[%s]:%s", host, service];
    }
    return [NSString stringWithFormat:@"%s:%s", host, service];
}

static NSString *PPProbeTCPNumeric(NSString *host, uint16_t port, BOOL *connectedOut) {
    if (connectedOut != NULL) *connectedOut = NO;
    struct sockaddr_storage address;
    socklen_t addressLength = 0;
    if (!PPBuildNumericSocketAddress(host.UTF8String, port, &address, &addressLength)) {
        return @"TCP=BAD-ADDRESS";
    }

    int fd = socket(address.ss_family, SOCK_STREAM, 0);
    if (fd < 0) {
        int e = errno;
        return [NSString stringWithFormat:@"TCP=SOCKET-FAIL errno=%d %@", e, PPErrnoText(e)];
    }
    int oldFlags = fcntl(fd, F_GETFL, 0);
    if (oldFlags >= 0) (void)fcntl(fd, F_SETFL, oldFlags | O_NONBLOCK);

    int rc = connect(fd, (const struct sockaddr *)&address, addressLength);
    if (rc != 0 && errno == EINPROGRESS) {
        fd_set writeSet;
        FD_ZERO(&writeSet);
        FD_SET(fd, &writeSet);
        struct timeval tv = { .tv_sec = 2, .tv_usec = 0 };
        rc = select(fd + 1, NULL, &writeSet, NULL, &tv);
        if (rc > 0 && FD_ISSET(fd, &writeSet)) {
            int socketError = 0;
            socklen_t errorLength = (socklen_t)sizeof(socketError);
            if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &socketError, &errorLength) == 0 && socketError == 0) {
                rc = 0;
            } else {
                errno = socketError != 0 ? socketError : errno;
                rc = -1;
            }
        } else if (rc == 0) {
            errno = ETIMEDOUT;
            rc = -1;
        } else {
            rc = -1;
        }
    }
    if (rc != 0) {
        int e = errno;
        close(fd);
        return [NSString stringWithFormat:@"TCP=FAIL errno=%d %@", e, PPErrnoText(e)];
    }
    if (oldFlags >= 0) (void)fcntl(fd, F_SETFL, oldFlags);

    struct sockaddr_storage local;
    memset(&local, 0, sizeof(local));
    socklen_t localLength = sizeof(local);
    NSString *localText = @"?";
    if (getsockname(fd, (struct sockaddr *)&local, &localLength) == 0) {
        localText = PPFormatSockaddr((const struct sockaddr *)&local, localLength);
    }
    close(fd);
    if (connectedOut != NULL) *connectedOut = YES;
    return [NSString stringWithFormat:@"TCP=CONNECTED local=%@", localText];
}

int32_t PPProbeCellularRPPairingIngress(char *message, size_t messageCapacity) {
    BOOL peerConnected = NO;
    NSString *peer = PPProbeTCPIngress(@"10.7.0.1", 49152, &peerConnected);

    BOOL loopbackConnected = NO;
    NSString *loopback = PPProbeTCPIngress(@"127.0.0.1", 49152, &loopbackConnected);

    NSString *text = [NSString stringWithFormat:
        @"CELLULAR RP INGRESS %@ • peer 10.7.0.1:49152 %@ • loopback 127.0.0.1:49152 %@ • %@",
        peerConnected ? @"READY ✅" : @"FAILED ❌",
        peer,
        loopback,
        PPCompactIPv4Interfaces()];
    PPWriteMessage(message, messageCapacity, text);
    return peerConnected ? 0 : 1;
}

int32_t PPNoVPNSelfTransportProbe(char *message, size_t messageCapacity) {
    NSMutableArray<NSString *> *lines = [NSMutableArray arrayWithObject:@"NO-VPN SELF PROBE"];
    BOOL anyReady = NO;

    BOOL localhostReady = NO;
    NSString *localhostResult = PPProbeLockdownAddress(@"127.0.0.1", &localhostReady);
    [lines addObject:[NSString stringWithFormat:@"localhost: %@", localhostResult]];
    anyReady = anyReady || localhostReady;

    struct ifaddrs *interfaces = NULL;
    NSMutableArray<NSDictionary<NSString *, NSString *> *> *candidates = [NSMutableArray array];
    if (getifaddrs(&interfaces) == 0 && interfaces != NULL) {
        for (struct ifaddrs *cursor = interfaces; cursor != NULL; cursor = cursor->ifa_next) {
            if (cursor->ifa_addr == NULL || cursor->ifa_addr->sa_family != AF_INET) {
                continue;
            }

            NSString *name = cursor->ifa_name != NULL ? [NSString stringWithUTF8String:cursor->ifa_name] : @"?";
            if ([name isEqualToString:@"lo0"]) {
                continue;
            }

            char host[NI_MAXHOST] = {0};
            socklen_t addressLength = cursor->ifa_addr->sa_len > 0
                ? cursor->ifa_addr->sa_len
                : (socklen_t)sizeof(struct sockaddr_in);
            int rc = getnameinfo(cursor->ifa_addr,
                                 addressLength,
                                 host,
                                 sizeof(host),
                                 NULL,
                                 0,
                                 NI_NUMERICHOST);
            if (rc != 0 || host[0] == '\0') {
                continue;
            }

            NSString *address = [NSString stringWithUTF8String:host];
            if (address.length == 0 || [address isEqualToString:@"0.0.0.0"] || [address isEqualToString:@"127.0.0.1"]) {
                continue;
            }
            [candidates addObject:@{ @"name": name, @"address": address }];
        }
        freeifaddrs(interfaces);
    }

    [candidates sortUsingComparator:^NSComparisonResult(NSDictionary *lhs, NSDictionary *rhs) {
        NSString *ln = lhs[@"name"];
        NSString *rn = rhs[@"name"];
        NSInteger lr = [ln isEqualToString:@"en0"] ? 0 : ([ln hasPrefix:@"pdp_ip"] ? 1 : 2);
        NSInteger rr = [rn isEqualToString:@"en0"] ? 0 : ([rn hasPrefix:@"pdp_ip"] ? 1 : 2);
        if (lr < rr) return NSOrderedAscending;
        if (lr > rr) return NSOrderedDescending;
        return [ln compare:rn];
    }];

    if (candidates.count == 0) {
        [lines addObject:@"self-ip: none"];
    } else {
        BOOL selfIPReady = NO;
        NSUInteger limit = MIN((NSUInteger)6, candidates.count);
        for (NSUInteger i = 0; i < limit; i++) {
            NSDictionary *candidate = candidates[i];
            BOOL ready = NO;
            NSString *result = PPProbeLockdownAddress(candidate[@"address"], &ready);
            [lines addObject:[NSString stringWithFormat:@"%@=%@: %@",
                              candidate[@"name"], candidate[@"address"], result]];
            if (ready) {
                selfIPReady = YES;
                anyReady = YES;
                break;
            }
        }
        if (!selfIPReady) {
            [lines addObject:@"self-ip lockdown: no direct path found"];
        }
    }

    [lines addObject:@"VPN/Tunnel was not used by this probe"];
    PPWriteMessage(message, messageCapacity, [lines componentsJoinedByString:@"\n"]);
    return anyReady ? 0 : 1;
}

static int32_t PPConsumeError(
    struct IdeviceFfiError *error,
    char *message,
    size_t capacity,
    NSString *prefix
) {
    if (error == NULL) {
        return 0;
    }

    int32_t code = error->code;
    int32_t subCode = error->sub_code;
    NSString *detail = error->message != NULL
        ? [NSString stringWithUTF8String:error->message]
        : @"unknown idevice error";

    PPWriteMessage(
        message,
        capacity,
        [NSString stringWithFormat:@"%@: code=%d sub=%d %@",
         prefix, code, subCode, detail]
    );

    idevice_error_free(error);
    return code == 0 ? -1 : code;
}

static int32_t PPLoadPairing(
    const char *path,
    struct RpPairingFileHandle **outPairing,
    char *message,
    size_t capacity
) {
    if (path == NULL || outPairing == NULL) {
        PPWriteMessage(message, capacity, @"Pairing path is missing");
        return -10;
    }

    *outPairing = NULL;

    struct IdeviceFfiError *error =
        rp_pairing_file_read(path, outPairing);

    if (error != NULL) {
        return PPConsumeError(
            error,
            message,
            capacity,
            @"RPPairing read failed"
        );
    }

    if (*outPairing == NULL) {
        PPWriteMessage(message, capacity, @"RPPairing parser returned NULL");
        return -11;
    }

    return 0;
}


static BOOL PPBuildNumericSocketAddress(
    const char *host,
    uint16_t port,
    struct sockaddr_storage *storage,
    socklen_t *lengthOut
) {
    if (host == NULL || storage == NULL || lengthOut == NULL) {
        return NO;
    }
    memset(storage, 0, sizeof(*storage));

    struct sockaddr_in *v4 = (struct sockaddr_in *)storage;
#if defined(__APPLE__)
    v4->sin_len = sizeof(*v4);
#endif
    v4->sin_family = AF_INET;
    v4->sin_port = htons(port);
    if (inet_pton(AF_INET, host, &v4->sin_addr) == 1) {
        *lengthOut = (socklen_t)sizeof(*v4);
        return YES;
    }

    NSString *text = [NSString stringWithUTF8String:host];
    if (text.length == 0) {
        return NO;
    }
    NSString *addressPart = text;
    NSString *scopePart = nil;
    NSRange percent = [text rangeOfString:@"%" options:NSBackwardsSearch];
    if (percent.location != NSNotFound) {
        addressPart = [text substringToIndex:percent.location];
        scopePart = [text substringFromIndex:percent.location + 1];
    }

    struct sockaddr_in6 *v6 = (struct sockaddr_in6 *)storage;
#if defined(__APPLE__)
    v6->sin6_len = sizeof(*v6);
#endif
    v6->sin6_family = AF_INET6;
    v6->sin6_port = htons(port);
    if (inet_pton(AF_INET6, addressPart.UTF8String, &v6->sin6_addr) != 1) {
        return NO;
    }
    if (scopePart.length > 0) {
        char *end = NULL;
        unsigned long numeric = strtoul(scopePart.UTF8String, &end, 10);
        if (end != NULL && *end == '\0' && numeric > 0 && numeric <= UINT32_MAX) {
            v6->sin6_scope_id = (uint32_t)numeric;
        } else {
            unsigned int index = if_nametoindex(scopePart.UTF8String);
            if (index == 0) {
                return NO;
            }
            v6->sin6_scope_id = index;
        }
    }
    *lengthOut = (socklen_t)sizeof(*v6);
    return YES;
}

static int32_t PPCreateRPPairingTunnelOnly(
    const char *pairingPath,
    const char *host,
    uint16_t port,
    struct AdapterHandle **outAdapter,
    struct RsdHandshakeHandle **outHandshake,
    char *message,
    size_t capacity
) {
    if (outAdapter == NULL || outHandshake == NULL) {
        PPWriteMessage(message, capacity, @"Invalid tunnel outputs");
        return -20;
    }

    *outAdapter = NULL;
    *outHandshake = NULL;

    struct RpPairingFileHandle *pairing = NULL;

    int32_t loadResult =
        PPLoadPairing(
            pairingPath,
            &pairing,
            message,
            capacity
        );

    if (loadResult != 0) {
        return loadResult;
    }

    struct sockaddr_storage address;
    socklen_t addressLength = 0;
    if (!PPBuildNumericSocketAddress(host, port, &address, &addressLength)) {
        rp_pairing_file_free(pairing);
        PPWriteMessage(message, capacity, @"Invalid numeric IP address/scope");
        return -21;
    }

    struct IdeviceFfiError *error =
        tunnel_create_rppairing(
            (const idevice_sockaddr *)&address,
            (idevice_socklen_t)addressLength,
            "Pikmin Pilot",
            pairing,
            NULL,
            NULL,
            outAdapter,
            outHandshake
        );

    // The pairing file is borrowed by tunnel_create_rppairing.
    // Persist any pair-verify refresh/update before freeing it.
    if (error == NULL) {
        struct IdeviceFfiError *writeError =
            rp_pairing_file_write(pairing, pairingPath);

        if (writeError != NULL) {
            // Connection succeeded. Do not fail the tunnel solely because
            // persistence failed; free the diagnostic.
            idevice_error_free(writeError);
        }
    }

    rp_pairing_file_free(pairing);

    if (error != NULL) {
        return PPConsumeError(
            error,
            message,
            capacity,
            @"RPPairing tunnel failed"
        );
    }

    if (*outAdapter == NULL || *outHandshake == NULL) {
        PPWriteMessage(message, capacity, @"Tunnel returned empty RSD handles");
        return -22;
    }

    return 0;
}


// Stage 11.5.4.8: preserve the Stage 11.5.3 raw RPPairing transport.
// The only change is that PPCreateRPPairingTunnelOnly now accepts numeric
// IPv4 or IPv6 endpoints (including %interface scope for link-local IPv6).
static int32_t PPCreateTunnel(
    const char *pairingPath,
    const char *host,
    uint16_t port,
    struct AdapterHandle **outAdapter,
    struct RsdHandshakeHandle **outHandshake,
    char *message,
    size_t capacity
) {
    return PPCreateRPPairingTunnelOnly(
        pairingPath, host, port, outAdapter, outHandshake, message, capacity
    );
}

int32_t PPValidateRPPairingFile(
    const char *path,
    char *message,
    size_t messageCapacity
) {
    struct RpPairingFileHandle *pairing = NULL;

    int32_t result =
        PPLoadPairing(
            path,
            &pairing,
            message,
            messageCapacity
        );

    if (result != 0) {
        return result;
    }

    uint8_t *serialized = NULL;
    uintptr_t length = 0;

    struct IdeviceFfiError *error =
        rp_pairing_file_to_bytes(
            pairing,
            &serialized,
            &length
        );

    if (error != NULL) {
        rp_pairing_file_free(pairing);
        return PPConsumeError(
            error,
            message,
            messageCapacity,
            @"RPPairing serialize failed"
        );
    }

    if (serialized != NULL) {
        idevice_data_free(serialized, length);
    }

    rp_pairing_file_free(pairing);

    PPWriteMessage(
        message,
        messageCapacity,
        [NSString stringWithFormat:
         @"IDEVICE LINKED • RPPairing OK • %llu bytes",
         (unsigned long long)length]
    );

    return 0;
}

int32_t PPProbeRSD(
    const char *pairingPath,
    const char *host,
    uint16_t port,
    char *message,
    size_t messageCapacity
) {
    struct AdapterHandle *adapter = NULL;
    struct RsdHandshakeHandle *handshake = NULL;

    int32_t tunnelResult =
        PPCreateTunnel(
            pairingPath,
            host,
            port,
            &adapter,
            &handshake,
            message,
            messageCapacity
        );

    if (tunnelResult != 0) {
        return tunnelResult;
    }

    char *uuid = NULL;
    struct IdeviceFfiError *uuidError =
        rsd_get_uuid(handshake, &uuid);

    NSString *uuidText = @"RSD connected";

    if (uuidError == NULL && uuid != NULL) {
        uuidText =
            [NSString stringWithFormat:
             @"PHONE-LOCAL RSD ONLINE • UUID %s",
             uuid];
        idevice_string_free(uuid);
    } else if (uuidError != NULL) {
        idevice_error_free(uuidError);
    }

    rsd_handshake_free(handshake);
    adapter_free(adapter);

    PPWriteMessage(message, messageCapacity, uuidText);
    return 0;
}


// Stage 11.5.4.5: determine whether Apple's fixed RPPairing ingress (49152)
// is exposed on any real local interface while Wi-Fi is off. 11.5.4.4 proved:
//   10.7.0.1:49152 -> ECONNREFUSED
//   127.0.0.1:49152 -> TCP accepts but full RPPairing is reset by peer
// Do not touch PacketTunnel routes here. Enumerate the kernel's actual IPv4
// interface addresses, TCP-probe 49152, then run the exact same PPProbeRSD on
// every accepting non-loopback candidate. This separates "Wi-Fi-only listener"
// from "listener moved to cellular/utun" on the user's actual phone.
int32_t PPProbeCellularRPPairingInterfaces(
    const char *pairingPath,
    char *selectedHost,
    size_t selectedHostCapacity,
    char *message,
    size_t messageCapacity
) {
    if (selectedHost != NULL && selectedHostCapacity > 0) {
        selectedHost[0] = '\0';
    }
    if (pairingPath == NULL) {
        PPWriteMessage(message, messageCapacity, @"CELLULAR IF RP PROBE FAILED • missing pairing path");
        return -30;
    }

    struct ifaddrs *interfaces = NULL;
    if (getifaddrs(&interfaces) != 0 || interfaces == NULL) {
        int e = errno;
        PPWriteMessage(message, messageCapacity,
            [NSString stringWithFormat:@"CELLULAR IF RP PROBE FAILED • getifaddrs errno=%d %@", e, PPErrnoText(e)]);
        return -31;
    }

    NSMutableArray<NSDictionary<NSString *, NSString *> *> *candidates = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    for (struct ifaddrs *cursor = interfaces; cursor != NULL; cursor = cursor->ifa_next) {
        if (cursor->ifa_addr == NULL || cursor->ifa_addr->sa_family != AF_INET) {
            continue;
        }
        NSString *name = cursor->ifa_name != NULL
            ? [NSString stringWithUTF8String:cursor->ifa_name]
            : @"?";
        if (![name isEqualToString:@"en0"] &&
            ![name hasPrefix:@"pdp_ip"] &&
            ![name hasPrefix:@"utun"]) {
            continue;
        }

        char host[INET_ADDRSTRLEN] = {0};
        const struct sockaddr_in *sin = (const struct sockaddr_in *)cursor->ifa_addr;
        if (inet_ntop(AF_INET, &sin->sin_addr, host, sizeof(host)) == NULL) {
            continue;
        }
        NSString *hostText = [NSString stringWithUTF8String:host];
        if (hostText.length == 0 || [seen containsObject:hostText]) {
            continue;
        }
        [seen addObject:hostText];
        [candidates addObject:@{ @"name": name, @"host": hostText }];
    }
    freeifaddrs(interfaces);

    [candidates sortUsingComparator:^NSComparisonResult(NSDictionary<NSString *, NSString *> *a,
                                                        NSDictionary<NSString *, NSString *> *b) {
        NSString *an = a[@"name"] ?: @"";
        NSString *bn = b[@"name"] ?: @"";
        NSComparisonResult r = [an compare:bn];
        if (r != NSOrderedSame) return r;
        return [(a[@"host"] ?: @"") compare:(b[@"host"] ?: @"")];
    }];

    NSMutableArray<NSString *> *reports = [NSMutableArray array];
    for (NSDictionary<NSString *, NSString *> *candidate in candidates) {
        NSString *name = candidate[@"name"] ?: @"?";
        NSString *host = candidate[@"host"] ?: @"?";
        BOOL connected = NO;
        NSString *tcp = PPProbeTCPIngress(host, 49152, &connected);
        if (!connected) {
            [reports addObject:[NSString stringWithFormat:@"%@=%@ {%@}", name, host, tcp]];
            continue;
        }

        char rsdMessage[2048] = {0};
        int32_t rsdResult = PPProbeRSD(
            pairingPath,
            host.UTF8String,
            49152,
            rsdMessage,
            sizeof(rsdMessage)
        );
        NSString *rsd = rsdMessage[0] != '\0'
            ? [NSString stringWithUTF8String:rsdMessage]
            : [NSString stringWithFormat:@"code=%d", rsdResult];
        [reports addObject:[NSString stringWithFormat:@"%@=%@ {%@; FULL-RP=%@}", name, host, tcp, rsd]];

        if (rsdResult == 0) {
            if (selectedHost != NULL && selectedHostCapacity > 0) {
                snprintf(selectedHost, selectedHostCapacity, "%s", host.UTF8String);
            }
            PPWriteMessage(message, messageCapacity,
                [NSString stringWithFormat:@"CELLULAR IF RP READY ✅ • selected=%@:49152 if=%@ • %@",
                 host, name, [reports componentsJoinedByString:@" | "]]);
            return 0;
        }
    }

    NSString *candidateText = reports.count > 0
        ? [reports componentsJoinedByString:@" | "]
        : @"no en0/pdp_ip*/utun* IPv4 candidates";
    PPWriteMessage(message, messageCapacity,
        [NSString stringWithFormat:@"CELLULAR IF RP FAILED ❌ • %@", candidateText]);
    return 1;
}

int32_t PPProbeCellularRPPairingIPv6Interfaces(
    const char *pairingPath,
    char *selectedHost,
    size_t selectedHostCapacity,
    char *message,
    size_t messageCapacity
) {
    if (selectedHost != NULL && selectedHostCapacity > 0) selectedHost[0] = '\0';
    if (pairingPath == NULL) {
        PPWriteMessage(message, messageCapacity, @"IPV6 RP PROBE FAILED • missing pairing path");
        return -40;
    }

    struct ifaddrs *interfaces = NULL;
    if (getifaddrs(&interfaces) != 0 || interfaces == NULL) {
        int e = errno;
        PPWriteMessage(message, messageCapacity,
            [NSString stringWithFormat:@"IPV6 RP PROBE FAILED • getifaddrs errno=%d %@", e, PPErrnoText(e)]);
        return -41;
    }

    NSMutableArray<NSDictionary<NSString *, NSString *> *> *candidates = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    for (struct ifaddrs *cursor = interfaces; cursor != NULL; cursor = cursor->ifa_next) {
        if (cursor->ifa_addr == NULL || cursor->ifa_addr->sa_family != AF_INET6) continue;
        NSString *name = cursor->ifa_name ? [NSString stringWithUTF8String:cursor->ifa_name] : @"?";
        if (![name isEqualToString:@"lo0"] && ![name isEqualToString:@"en0"] &&
            ![name hasPrefix:@"pdp_ip"] && ![name hasPrefix:@"utun"]) continue;

        const struct sockaddr_in6 *sin6 = (const struct sockaddr_in6 *)cursor->ifa_addr;
        if (IN6_IS_ADDR_UNSPECIFIED(&sin6->sin6_addr) || IN6_IS_ADDR_MULTICAST(&sin6->sin6_addr)) continue;
        char raw[INET6_ADDRSTRLEN] = {0};
        if (inet_ntop(AF_INET6, &sin6->sin6_addr, raw, sizeof(raw)) == NULL) continue;
        NSString *base = [NSString stringWithUTF8String:raw];
        NSString *host = base;
        if (IN6_IS_ADDR_LINKLOCAL(&sin6->sin6_addr)) {
            host = [NSString stringWithFormat:@"%@%%%@", base, name];
        }
        NSString *dedupe = [NSString stringWithFormat:@"%@|%@", name, host];
        if ([seen containsObject:dedupe]) continue;
        [seen addObject:dedupe];
        [candidates addObject:@{ @"name": name, @"host": host }];
    }
    freeifaddrs(interfaces);

    [candidates sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        NSString *an = a[@"name"] ?: @"";
        NSString *bn = b[@"name"] ?: @"";
        NSInteger ar = [an hasPrefix:@"pdp_ip"] ? 0 : ([an hasPrefix:@"utun"] ? 1 : ([an isEqualToString:@"lo0"] ? 2 : 3));
        NSInteger br = [bn hasPrefix:@"pdp_ip"] ? 0 : ([bn hasPrefix:@"utun"] ? 1 : ([bn isEqualToString:@"lo0"] ? 2 : 3));
        if (ar != br) return ar < br ? NSOrderedAscending : NSOrderedDescending;
        NSComparisonResult r = [an compare:bn];
        if (r != NSOrderedSame) return r;
        return [(a[@"host"] ?: @"") compare:(b[@"host"] ?: @"")];
    }];

    NSMutableArray<NSString *> *reports = [NSMutableArray array];
    for (NSDictionary *candidate in candidates) {
        NSString *name = candidate[@"name"] ?: @"?";
        NSString *host = candidate[@"host"] ?: @"?";
        BOOL connected = NO;
        NSString *tcp = PPProbeTCPNumeric(host, 49152, &connected);
        if (!connected) {
            [reports addObject:[NSString stringWithFormat:@"%@=[%@]:49152 {%@}", name, host, tcp]];
            continue;
        }

        char rsdMessage[4096] = {0};
        int32_t rsdResult = PPProbeRSD(pairingPath, host.UTF8String, 49152,
                                       rsdMessage, sizeof(rsdMessage));
        NSString *rsd = rsdMessage[0] != '\0'
            ? [NSString stringWithUTF8String:rsdMessage]
            : [NSString stringWithFormat:@"code=%d", rsdResult];
        [reports addObject:[NSString stringWithFormat:@"%@=[%@]:49152 {%@; FULL-RP=%@}", name, host, tcp, rsd]];
        if (rsdResult == 0) {
            if (selectedHost != NULL && selectedHostCapacity > 0) {
                snprintf(selectedHost, selectedHostCapacity, "%s", host.UTF8String);
            }
            PPWriteMessage(message, messageCapacity,
                [NSString stringWithFormat:@"IPV6 RP ENDPOINT READY ✅ • selected=[%@]:49152 if=%@ • %@",
                 host, name, [reports componentsJoinedByString:@" | "]]);
            return 0;
        }
    }

    NSString *detail = reports.count > 0
        ? [reports componentsJoinedByString:@" | "]
        : @"no lo0/en0/pdp_ip*/utun* IPv6 candidates";
    PPWriteMessage(message, messageCapacity,
        [NSString stringWithFormat:@"IPV6 RP ENDPOINT FAILED ❌ • %@", detail]);
    return 1;
}

int32_t PPMountPhoneLocalPersonalizedDDI(
    const char *pairingPath,
    const char *host,
    uint16_t port,
    const char *imagePath,
    const char *buildManifestPath,
    const char *trustCachePath,
    char *message,
    size_t messageCapacity
) {
    if (imagePath == NULL || buildManifestPath == NULL || trustCachePath == NULL) {
        PPWriteMessage(message, messageCapacity, @"DDI payload path is NULL");
        return -160;
    }

    struct AdapterHandle *adapter = NULL;
    struct RsdHandshakeHandle *handshake = NULL;
    int32_t tunnelResult = PPCreateTunnel(
        pairingPath, host, port, &adapter, &handshake, message, messageCapacity
    );
    if (tunnelResult != 0) {
        return tunnelResult;
    }

    int32_t result = pilot_ddi_mount_personalized(
        adapter, handshake, imagePath, buildManifestPath, trustCachePath,
        message, messageCapacity
    );

    rsd_handshake_free(handshake);
    adapter_free(adapter);
    return result;
}


int32_t PPLaunchPikmin(
    const char *pairingPath,
    const char *host,
    uint16_t port,
    char *message,
    size_t messageCapacity
) {
    struct AdapterHandle *adapter = NULL;
    struct RsdHandshakeHandle *handshake = NULL;

    int32_t tunnelResult =
        PPCreateTunnel(
            pairingPath,
            host,
            port,
            &adapter,
            &handshake,
            message,
            messageCapacity
        );

    if (tunnelResult != 0) {
        return tunnelResult;
    }

    struct AppServiceHandle *appService = NULL;

    struct IdeviceFfiError *connectError =
        app_service_connect_rsd(
            adapter,
            handshake,
            &appService
        );

    if (connectError != NULL) {
        rsd_handshake_free(handshake);
        adapter_free(adapter);

        return PPConsumeError(
            connectError,
            message,
            messageCapacity,
            @"AppService connect failed"
        );
    }

    struct LaunchResponseC *response = NULL;

    struct IdeviceFfiError *launchError =
        app_service_launch_app(
            appService,
            "com.nianticlabs.pikmin",
            NULL,
            0,
            0,
            0,
            NULL,
            &response
        );

    if (launchError != NULL) {
        app_service_free(appService);
        rsd_handshake_free(handshake);
        adapter_free(adapter);

        return PPConsumeError(
            launchError,
            message,
            messageCapacity,
            @"Pikmin launch failed"
        );
    }

    if (response != NULL) {
        app_service_free_launch_response(response);
    }

    app_service_free(appService);
    rsd_handshake_free(handshake);
    adapter_free(adapter);

    PPWriteMessage(
        message,
        messageCapacity,
        @"PHONE-LOCAL AppService → Pikmin launch SENT"
    );

    return 0;
}


int32_t PPTakePhoneScreenshot(
    const char *pairingPath,
    const char *host,
    uint16_t port,
    const char *outputPath,
    char *message,
    size_t messageCapacity
) {
    if (outputPath == NULL || outputPath[0] == '\0') {
        PPWriteMessage(message, messageCapacity, @"Screenshot output path is missing");
        return -30;
    }

    struct AdapterHandle *adapter = NULL;
    struct RsdHandshakeHandle *handshake = NULL;

    int32_t tunnelResult =
        PPCreateTunnel(
            pairingPath,
            host,
            port,
            &adapter,
            &handshake,
            message,
            messageCapacity
        );

    if (tunnelResult != 0) {
        return tunnelResult;
    }

    // iOS 17+ developer screenshot path:
    // RSD -> com.apple.instruments.dtservicehub -> DVT screenshot channel.
    // Do not use classic Screenshotr here; that service may not be advertised
    // on modern RSD transports and produced "service not found" on iOS 26.6.1.
    struct RemoteServerHandle *remoteServer = NULL;
    struct IdeviceFfiError *remoteError =
        remote_server_connect_rsd(adapter, handshake, &remoteServer);

    if (remoteError != NULL) {
        rsd_handshake_free(handshake);
        adapter_free(adapter);
        return PPConsumeError(
            remoteError,
            message,
            messageCapacity,
            @"DVT RemoteServer connect failed"
        );
    }

    if (remoteServer == NULL) {
        rsd_handshake_free(handshake);
        adapter_free(adapter);
        PPWriteMessage(message, messageCapacity, @"DVT RemoteServer returned NULL");
        return -31;
    }

    struct ScreenshotClientHandle *client = NULL;
    struct IdeviceFfiError *clientError =
        screenshot_client_new(remoteServer, &client);

    if (clientError != NULL) {
        remote_server_free(remoteServer);
        rsd_handshake_free(handshake);
        adapter_free(adapter);
        return PPConsumeError(
            clientError,
            message,
            messageCapacity,
            @"DVT Screenshot channel failed"
        );
    }

    if (client == NULL) {
        remote_server_free(remoteServer);
        rsd_handshake_free(handshake);
        adapter_free(adapter);
        PPWriteMessage(message, messageCapacity, @"DVT Screenshot returned NULL client");
        return -32;
    }

    uint8_t *imageBytes = NULL;
    uintptr_t imageLength = 0;
    struct IdeviceFfiError *shotError =
        screenshot_client_take_screenshot(client, &imageBytes, &imageLength);

    if (shotError != NULL) {
        screenshot_client_free(client);
        remote_server_free(remoteServer);
        rsd_handshake_free(handshake);
        adapter_free(adapter);
        return PPConsumeError(
            shotError,
            message,
            messageCapacity,
            @"DVT Screenshot failed"
        );
    }

    if (imageBytes == NULL || imageLength == 0) {
        if (imageBytes != NULL) {
            idevice_data_free(imageBytes, imageLength);
        }
        screenshot_client_free(client);
        remote_server_free(remoteServer);
        rsd_handshake_free(handshake);
        adapter_free(adapter);
        PPWriteMessage(message, messageCapacity, @"DVT Screenshot returned empty data");
        return -33;
    }

    NSData *imageData =
        [NSData dataWithBytes:imageBytes length:(NSUInteger)imageLength];
    NSString *path = [NSString stringWithUTF8String:outputPath];
    NSError *writeError = nil;
    BOOL wrote = [imageData writeToFile:path options:NSDataWritingAtomic error:&writeError];
    uintptr_t byteCount = imageLength;

    idevice_data_free(imageBytes, imageLength);
    screenshot_client_free(client);
    remote_server_free(remoteServer);
    rsd_handshake_free(handshake);
    adapter_free(adapter);

    if (!wrote) {
        NSString *detail = writeError.localizedDescription ?: @"unknown file write error";
        PPWriteMessage(
            message,
            messageCapacity,
            [NSString stringWithFormat:@"DVT Screenshot save failed: %@", detail]
        );
        return -34;
    }

    PPWriteMessage(
        message,
        messageCapacity,
        [NSString stringWithFormat:
         @"PHONE-LOCAL DVT SCREENSHOT OK • %llu bytes",
         (unsigned long long)byteCount]
    );

    return 0;
}


int32_t PPTakePhoneScreenshotBounded(
    const char *pairingPath,
    const char *host,
    uint16_t port,
    const char *outputPath,
    uint64_t timeoutMilliseconds,
    char *message,
    size_t messageCapacity
) {
    if (outputPath == NULL || outputPath[0] == '\0') {
        PPWriteMessage(message, messageCapacity, @"Screenshot output path is missing");
        return -30;
    }

    struct AdapterHandle *adapter = NULL;
    struct RsdHandshakeHandle *handshake = NULL;

    int32_t tunnelResult =
        PPCreateTunnel(
            pairingPath,
            host,
            port,
            &adapter,
            &handshake,
            message,
            messageCapacity
        );

    if (tunnelResult != 0) {
        return tunnelResult;
    }

    // iOS 17+ developer screenshot path:
    // RSD -> com.apple.instruments.dtservicehub -> DVT screenshot channel.
    // Do not use classic Screenshotr here; that service may not be advertised
    // on modern RSD transports and produced "service not found" on iOS 26.6.1.
    struct RemoteServerHandle *remoteServer = NULL;
    struct IdeviceFfiError *remoteError =
        remote_server_connect_rsd(adapter, handshake, &remoteServer);

    if (remoteError != NULL) {
        rsd_handshake_free(handshake);
        adapter_free(adapter);
        return PPConsumeError(
            remoteError,
            message,
            messageCapacity,
            @"DVT RemoteServer connect failed"
        );
    }

    if (remoteServer == NULL) {
        rsd_handshake_free(handshake);
        adapter_free(adapter);
        PPWriteMessage(message, messageCapacity, @"DVT RemoteServer returned NULL");
        return -31;
    }

    struct ScreenshotClientHandle *client = NULL;
    struct IdeviceFfiError *clientError =
        screenshot_client_new(remoteServer, &client);

    if (clientError != NULL) {
        remote_server_free(remoteServer);
        rsd_handshake_free(handshake);
        adapter_free(adapter);
        return PPConsumeError(
            clientError,
            message,
            messageCapacity,
            @"DVT Screenshot channel failed"
        );
    }

    if (client == NULL) {
        remote_server_free(remoteServer);
        rsd_handshake_free(handshake);
        adapter_free(adapter);
        PPWriteMessage(message, messageCapacity, @"DVT Screenshot returned NULL client");
        return -32;
    }

    uint8_t *imageBytes = NULL;
    uintptr_t imageLength = 0;
    struct IdeviceFfiError *shotError =
        screenshot_client_take_screenshot_timeout(client, &imageBytes, &imageLength, timeoutMilliseconds);

    if (shotError != NULL) {
        screenshot_client_free(client);
        remote_server_free(remoteServer);
        rsd_handshake_free(handshake);
        adapter_free(adapter);
        return PPConsumeError(
            shotError,
            message,
            messageCapacity,
            @"DVT Screenshot failed"
        );
    }

    if (imageBytes == NULL || imageLength == 0) {
        if (imageBytes != NULL) {
            idevice_data_free(imageBytes, imageLength);
        }
        screenshot_client_free(client);
        remote_server_free(remoteServer);
        rsd_handshake_free(handshake);
        adapter_free(adapter);
        PPWriteMessage(message, messageCapacity, @"DVT Screenshot returned empty data");
        return -33;
    }

    NSData *imageData =
        [NSData dataWithBytes:imageBytes length:(NSUInteger)imageLength];
    NSString *path = [NSString stringWithUTF8String:outputPath];
    NSError *writeError = nil;
    BOOL wrote = [imageData writeToFile:path options:NSDataWritingAtomic error:&writeError];
    uintptr_t byteCount = imageLength;

    idevice_data_free(imageBytes, imageLength);
    screenshot_client_free(client);
    remote_server_free(remoteServer);
    rsd_handshake_free(handshake);
    adapter_free(adapter);

    if (!wrote) {
        NSString *detail = writeError.localizedDescription ?: @"unknown file write error";
        PPWriteMessage(
            message,
            messageCapacity,
            [NSString stringWithFormat:@"DVT Screenshot save failed: %@", detail]
        );
        return -34;
    }

    PPWriteMessage(
        message,
        messageCapacity,
        [NSString stringWithFormat:
         @"PHONE-LOCAL BOUNDED DVT SCREENSHOT OK • %llu bytes",
         (unsigned long long)byteCount]
    );

    return 0;
}


int32_t PPProbePhoneLocalXCTestServices(
    const char *pairingPath,
    const char *host,
    uint16_t port,
    char *message,
    size_t messageCapacity
) {
    struct AdapterHandle *adapter = NULL;
    struct RsdHandshakeHandle *handshake = NULL;

    int32_t tunnelResult =
        PPCreateTunnel(
            pairingPath,
            host,
            port,
            &adapter,
            &handshake,
            message,
            messageCapacity
        );

    if (tunnelResult != 0) {
        return tunnelResult;
    }

    int32_t result =
        pilot_xctest_service_probe(
            handshake,
            message,
            messageCapacity
        );

    rsd_handshake_free(handshake);
    adapter_free(adapter);
    return result;
}


int32_t PPBootstrapPhoneLocalXCTestDTX(
    const char *pairingPath,
    const char *host,
    uint16_t port,
    char *message,
    size_t messageCapacity
) {
    struct AdapterHandle *adapter = NULL;
    struct RsdHandshakeHandle *handshake = NULL;

    int32_t tunnelResult =
        PPCreateTunnel(
            pairingPath,
            host,
            port,
            &adapter,
            &handshake,
            message,
            messageCapacity
        );

    if (tunnelResult != 0) {
        return tunnelResult;
    }

    int32_t result =
        pilot_xctest_dtx_bootstrap(
            adapter,
            handshake,
            message,
            messageCapacity
        );

    rsd_handshake_free(handshake);
    adapter_free(adapter);
    return result;
}


int32_t PPInstallPhoneLocalXCTestRunnerIPA(
    const char *pairingPath,
    const char *host,
    uint16_t port,
    const char *localIPAPath,
    char *message,
    size_t messageCapacity
) {
    if (localIPAPath == NULL || localIPAPath[0] == '\0') {
        PPWriteMessage(message, messageCapacity, @"Runner IPA path is empty");
        return -120;
    }

    struct AdapterHandle *adapter = NULL;
    struct RsdHandshakeHandle *handshake = NULL;
    int32_t tunnelResult = PPCreateTunnel(
        pairingPath, host, port, &adapter, &handshake, message, messageCapacity
    );
    if (tunnelResult != 0) {
        return tunnelResult;
    }

    int32_t result = pilot_runner_install_ipa(
        adapter, handshake, localIPAPath, message, messageCapacity
    );

    rsd_handshake_free(handshake);
    adapter_free(adapter);
    return result;
}


int32_t PPDiscoverPhoneLocalXCTestRunner(
    const char *pairingPath,
    const char *host,
    uint16_t port,
    char *message,
    size_t messageCapacity
) {
    struct AdapterHandle *adapter = NULL;
    struct RsdHandshakeHandle *handshake = NULL;

    int32_t tunnelResult =
        PPCreateTunnel(
            pairingPath,
            host,
            port,
            &adapter,
            &handshake,
            message,
            messageCapacity
        );

    if (tunnelResult != 0) {
        return tunnelResult;
    }

    int32_t result =
        pilot_xctest_runner_discovery(
            adapter,
            handshake,
            message,
            messageCapacity
        );

    rsd_handshake_free(handshake);
    adapter_free(adapter);
    return result;
}


int32_t PPLaunchBundleID(
    const char *pairingPath,
    const char *host,
    uint16_t port,
    const char *bundleID,
    char *message,
    size_t messageCapacity
) {
    if (bundleID == NULL || bundleID[0] == '\0') {
        PPWriteMessage(
            message,
            messageCapacity,
            @"Bundle ID is empty"
        );
        return -100;
    }

    struct AdapterHandle *adapter = NULL;
    struct RsdHandshakeHandle *handshake = NULL;

    int32_t tunnelResult =
        PPCreateTunnel(
            pairingPath,
            host,
            port,
            &adapter,
            &handshake,
            message,
            messageCapacity
        );

    if (tunnelResult != 0) {
        return tunnelResult;
    }

    struct AppServiceHandle *appService = NULL;

    struct IdeviceFfiError *connectError =
        app_service_connect_rsd(
            adapter,
            handshake,
            &appService
        );

    if (connectError != NULL) {
        rsd_handshake_free(handshake);
        adapter_free(adapter);

        return PPConsumeError(
            connectError,
            message,
            messageCapacity,
            @"AppService connect failed"
        );
    }

    struct LaunchResponseC *response = NULL;

    struct IdeviceFfiError *launchError =
        app_service_launch_app(
            appService,
            bundleID,
            NULL,
            0,
            0,
            0,
            NULL,
            &response
        );

    if (launchError != NULL) {
        app_service_free(appService);
        rsd_handshake_free(handshake);
        adapter_free(adapter);

        return PPConsumeError(
            launchError,
            message,
            messageCapacity,
            @"Bundle launch failed"
        );
    }

    if (response != NULL) {
        app_service_free_launch_response(response);
    }

    NSString *bundleString =
        [NSString stringWithUTF8String:bundleID]
        ?: @"<invalid bundle id>";

    app_service_free(appService);
    rsd_handshake_free(handshake);
    adapter_free(adapter);

    PPWriteMessage(
        message,
        messageCapacity,
        [NSString stringWithFormat:
            @"PHONE-LOCAL XCTEST RUNNER LAUNCH SENT • %@",
            bundleString
        ]
    );

    return 0;
}


int32_t PPPreparePhoneLocalXCTestMetadata(
    const char *pairingPath,
    const char *host,
    uint16_t port,
    char *message,
    size_t messageCapacity
) {
    struct AdapterHandle *adapter = NULL;
    struct RsdHandshakeHandle *handshake = NULL;

    int32_t tunnelResult = PPCreateTunnel(
        pairingPath, host, port,
        &adapter, &handshake,
        message, messageCapacity
    );
    if (tunnelResult != 0) {
        return tunnelResult;
    }

    int32_t result = pilot_xctest_metadata(
        adapter, handshake,
        message, messageCapacity
    );

    rsd_handshake_free(handshake);
    adapter_free(adapter);
    return result;
}

int32_t PPRunPhoneLocalXCTestCenterTap(
    const char *pairingPath,
    const char *host,
    uint16_t port,
    char *message,
    size_t messageCapacity
) {
    struct AdapterHandle *adapter = NULL;
    struct RsdHandshakeHandle *handshake = NULL;

    int32_t tunnelResult = PPCreateTunnel(
        pairingPath, host, port,
        &adapter, &handshake,
        message, messageCapacity
    );
    if (tunnelResult != 0) {
        return tunnelResult;
    }

    int32_t result = pilot_xctest_execute_center_tap(
        adapter, handshake,
        message, messageCapacity
    );

    rsd_handshake_free(handshake);
    adapter_free(adapter);
    return result;
}

int32_t PPRunPhoneLocalXCTestActivate(
    const char *pairingPath,
    const char *host,
    uint16_t port,
    char *message,
    size_t messageCapacity
) {
    struct AdapterHandle *adapter = NULL;
    struct RsdHandshakeHandle *handshake = NULL;

    int32_t tunnelResult = PPCreateTunnel(
        pairingPath, host, port, &adapter, &handshake, message, messageCapacity
    );
    if (tunnelResult != 0) {
        return tunnelResult;
    }

    int32_t result = pilot_xctest_execute_activate(
        adapter, handshake, message, messageCapacity
    );

    rsd_handshake_free(handshake);
    adapter_free(adapter);
    return result;
}

int32_t PPRunPhoneLocalXCTestTap(
    const char *pairingPath,
    const char *host,
    uint16_t port,
    double normalizedX,
    double normalizedY,
    char *message,
    size_t messageCapacity
) {
    struct AdapterHandle *adapter = NULL;
    struct RsdHandshakeHandle *handshake = NULL;

    int32_t tunnelResult = PPCreateTunnel(
        pairingPath, host, port, &adapter, &handshake, message, messageCapacity
    );
    if (tunnelResult != 0) {
        return tunnelResult;
    }

    int32_t result = pilot_xctest_execute_tap(
        adapter,
        handshake,
        normalizedX,
        normalizedY,
        message,
        messageCapacity
    );

    rsd_handshake_free(handshake);
    adapter_free(adapter);
    return result;
}

int32_t PPRunPhoneLocalXCTestTapBounded(
    const char *pairingPath,
    const char *host,
    uint16_t port,
    double normalizedX,
    double normalizedY,
    uint64_t timeoutSeconds,
    char *message,
    size_t messageCapacity
) {
    struct AdapterHandle *adapter = NULL;
    struct RsdHandshakeHandle *handshake = NULL;

    int32_t tunnelResult = PPCreateTunnel(
        pairingPath, host, port, &adapter, &handshake, message, messageCapacity
    );
    if (tunnelResult != 0) {
        return tunnelResult;
    }

    int32_t result = pilot_xctest_execute_tap_bounded(
        adapter,
        handshake,
        normalizedX,
        normalizedY,
        timeoutSeconds,
        message,
        messageCapacity
    );

    rsd_handshake_free(handshake);
    adapter_free(adapter);
    return result;
}

int32_t PPRunPhoneLocalXCTestSwipe(
    const char *pairingPath,
    const char *host,
    uint16_t port,
    double fromX,
    double fromY,
    double toX,
    double toY,
    double duration,
    char *message,
    size_t messageCapacity
) {
    struct AdapterHandle *adapter = NULL;
    struct RsdHandshakeHandle *handshake = NULL;

    int32_t tunnelResult = PPCreateTunnel(
        pairingPath, host, port, &adapter, &handshake, message, messageCapacity
    );
    if (tunnelResult != 0) {
        return tunnelResult;
    }

    int32_t result = pilot_xctest_execute_swipe(
        adapter, handshake, fromX, fromY, toX, toY, duration,
        message, messageCapacity
    );

    rsd_handshake_free(handshake);
    adapter_free(adapter);
    return result;
}

int32_t PPRunPhoneLocalXCTestSelectPink12(
    const char *pairingPath,
    const char *host,
    uint16_t port,
    char *message,
    size_t messageCapacity
) {
    struct AdapterHandle *adapter = NULL;
    struct RsdHandshakeHandle *handshake = NULL;

    int32_t tunnelResult = PPCreateTunnel(
        pairingPath, host, port, &adapter, &handshake, message, messageCapacity
    );
    if (tunnelResult != 0) {
        return tunnelResult;
    }

    int32_t result = pilot_xctest_execute_select12(
        adapter, handshake, message, messageCapacity
    );

    rsd_handshake_free(handshake);
    adapter_free(adapter);
    return result;
}

int32_t PPRunPhoneLocalXCTestDispatchTail(
    const char *pairingPath,
    const char *host,
    uint16_t port,
    double pikminFilterX,
    double pikminFilterY,
    int32_t pikminCount,
    int32_t fastMode,
    char *message,
    size_t messageCapacity
) {
    struct AdapterHandle *adapter = NULL;
    struct RsdHandshakeHandle *handshake = NULL;

    int32_t tunnelResult = PPCreateTunnel(
        pairingPath, host, port, &adapter, &handshake, message, messageCapacity
    );
    if (tunnelResult != 0) {
        return tunnelResult;
    }

    int32_t result = pilot_xctest_execute_dispatch_tail(
        adapter, handshake, pikminFilterX, pikminFilterY, pikminCount, fastMode, message, messageCapacity
    );

    rsd_handshake_free(handshake);
    adapter_free(adapter);
    return result;
}


// -----------------------------------------------------------------------------
// Stage 11.5.4.9 — persistent RSD session for cellular escape
// -----------------------------------------------------------------------------
// Raw RemotePairing :49152 can disappear when cellular is the active physical
// interface. The cellular workflow therefore establishes one RPPairing/RSD
// session while the listener is temporarily available, keeps Adapter/RSD alive,
// restores cellular, then reuses the already-established session for every
// subsequent CoreDevice/DVT/XCTest operation. No new :49152 connection is made
// by the session-backed calls below.

typedef struct PPPhoneLocalSession {
    struct AdapterHandle *adapter;
    struct RsdHandshakeHandle *handshake;
} PPPhoneLocalSession;

static PPPhoneLocalSession *PPSession(uintptr_t raw, char *message, size_t capacity) {
    PPPhoneLocalSession *session = (PPPhoneLocalSession *)raw;
    if (session == NULL || session->adapter == NULL || session->handshake == NULL) {
        PPWriteMessage(message, capacity, @"PERSISTENT RSD SESSION INVALID");
        return NULL;
    }
    return session;
}

uintptr_t PPPhoneLocalSessionCreate(
    const char *pairingPath,
    const char *host,
    uint16_t port,
    char *message,
    size_t messageCapacity
) {
    struct AdapterHandle *adapter = NULL;
    struct RsdHandshakeHandle *handshake = NULL;
    int32_t tunnelResult = PPCreateTunnel(
        pairingPath, host, port, &adapter, &handshake, message, messageCapacity
    );
    if (tunnelResult != 0 || adapter == NULL || handshake == NULL) {
        if (handshake != NULL) rsd_handshake_free(handshake);
        if (adapter != NULL) adapter_free(adapter);
        return (uintptr_t)0;
    }

    PPPhoneLocalSession *session = calloc(1, sizeof(PPPhoneLocalSession));
    if (session == NULL) {
        rsd_handshake_free(handshake);
        adapter_free(adapter);
        PPWriteMessage(message, messageCapacity, @"PERSISTENT RSD SESSION ALLOC FAILED");
        return (uintptr_t)0;
    }
    session->adapter = adapter;
    session->handshake = handshake;

    char *uuid = NULL;
    NSString *detail = @"RSD connected";
    struct IdeviceFfiError *uuidError = rsd_get_uuid(handshake, &uuid);
    if (uuidError == NULL && uuid != NULL) {
        detail = [NSString stringWithFormat:@"UUID %s", uuid];
        idevice_string_free(uuid);
    } else if (uuidError != NULL) {
        idevice_error_free(uuidError);
    }
    PPWriteMessage(message, messageCapacity,
        [NSString stringWithFormat:@"PERSISTENT RSD SESSION READY ✅ • %@ • endpoint=%s:%u",
         detail, host ?: "?", (unsigned)port]);
    return (uintptr_t)session;
}

void PPPhoneLocalSessionFree(uintptr_t raw) {
    PPPhoneLocalSession *session = (PPPhoneLocalSession *)raw;
    if (session == NULL) return;
    if (session->handshake != NULL) rsd_handshake_free(session->handshake);
    if (session->adapter != NULL) adapter_free(session->adapter);
    session->handshake = NULL;
    session->adapter = NULL;
    free(session);
}

int32_t PPPhoneLocalSessionProbeXCTestServices(uintptr_t raw, char *message, size_t messageCapacity) {
    PPPhoneLocalSession *session = PPSession(raw, message, messageCapacity);
    if (session == NULL) return -240;
    return pilot_xctest_service_probe(session->handshake, message, messageCapacity);
}

int32_t PPPhoneLocalSessionBootstrapXCTestDTX(uintptr_t raw, char *message, size_t messageCapacity) {
    PPPhoneLocalSession *session = PPSession(raw, message, messageCapacity);
    if (session == NULL) return -259;
    return pilot_xctest_dtx_bootstrap(
        session->adapter, session->handshake, message, messageCapacity
    );
}

int32_t PPPhoneLocalSessionMountPersonalizedDDI(
    uintptr_t raw,
    const char *imagePath,
    const char *buildManifestPath,
    const char *trustCachePath,
    char *message,
    size_t messageCapacity
) {
    PPPhoneLocalSession *session = PPSession(raw, message, messageCapacity);
    if (session == NULL) return -241;
    if (imagePath == NULL || buildManifestPath == NULL || trustCachePath == NULL) {
        PPWriteMessage(message, messageCapacity, @"DDI payload path is NULL");
        return -242;
    }
    return pilot_ddi_mount_personalized(
        session->adapter, session->handshake,
        imagePath, buildManifestPath, trustCachePath,
        message, messageCapacity
    );
}

int32_t PPPhoneLocalSessionInstallRunnerIPA(
    uintptr_t raw,
    const char *localIPAPath,
    char *message,
    size_t messageCapacity
) {
    PPPhoneLocalSession *session = PPSession(raw, message, messageCapacity);
    if (session == NULL) return -243;
    if (localIPAPath == NULL || localIPAPath[0] == '\0') {
        PPWriteMessage(message, messageCapacity, @"Runner IPA path is empty");
        return -244;
    }
    return pilot_runner_install_ipa(
        session->adapter, session->handshake, localIPAPath, message, messageCapacity
    );
}

int32_t PPPhoneLocalSessionDiscoverRunner(uintptr_t raw, char *message, size_t messageCapacity) {
    PPPhoneLocalSession *session = PPSession(raw, message, messageCapacity);
    if (session == NULL) return -245;
    return pilot_xctest_runner_discovery(
        session->adapter, session->handshake, message, messageCapacity
    );
}

int32_t PPPhoneLocalSessionLaunchBundleID(
    uintptr_t raw,
    const char *bundleID,
    char *message,
    size_t messageCapacity
) {
    PPPhoneLocalSession *session = PPSession(raw, message, messageCapacity);
    if (session == NULL) return -246;
    if (bundleID == NULL || bundleID[0] == '\0') {
        PPWriteMessage(message, messageCapacity, @"Bundle ID is empty");
        return -247;
    }

    struct AppServiceHandle *appService = NULL;
    struct IdeviceFfiError *connectError =
        app_service_connect_rsd(session->adapter, session->handshake, &appService);
    if (connectError != NULL) {
        return PPConsumeError(connectError, message, messageCapacity,
                              @"Persistent AppService connect failed");
    }
    if (appService == NULL) {
        PPWriteMessage(message, messageCapacity, @"Persistent AppService returned NULL");
        return -248;
    }

    struct LaunchResponseC *response = NULL;
    struct IdeviceFfiError *launchError = app_service_launch_app(
        appService, bundleID, NULL, 0, 0, 0, NULL, &response
    );
    if (launchError != NULL) {
        app_service_free(appService);
        return PPConsumeError(launchError, message, messageCapacity,
                              @"Persistent bundle launch failed");
    }
    if (response != NULL) app_service_free_launch_response(response);
    app_service_free(appService);
    PPWriteMessage(message, messageCapacity,
        [NSString stringWithFormat:@"PERSISTENT RSD BUNDLE LAUNCH SENT • %s", bundleID]);
    return 0;
}

int32_t PPPhoneLocalSessionTakeScreenshot(
    uintptr_t raw,
    const char *outputPath,
    char *message,
    size_t messageCapacity
) {
    PPPhoneLocalSession *session = PPSession(raw, message, messageCapacity);
    if (session == NULL) return -249;
    if (outputPath == NULL || outputPath[0] == '\0') {
        PPWriteMessage(message, messageCapacity, @"Screenshot output path is missing");
        return -250;
    }

    struct RemoteServerHandle *remoteServer = NULL;
    struct IdeviceFfiError *remoteError =
        remote_server_connect_rsd(session->adapter, session->handshake, &remoteServer);
    if (remoteError != NULL) {
        return PPConsumeError(remoteError, message, messageCapacity,
                              @"Persistent DVT RemoteServer connect failed");
    }
    if (remoteServer == NULL) {
        PPWriteMessage(message, messageCapacity, @"Persistent DVT RemoteServer returned NULL");
        return -251;
    }

    struct ScreenshotClientHandle *client = NULL;
    struct IdeviceFfiError *clientError = screenshot_client_new(remoteServer, &client);
    if (clientError != NULL) {
        remote_server_free(remoteServer);
        return PPConsumeError(clientError, message, messageCapacity,
                              @"Persistent DVT Screenshot channel failed");
    }
    if (client == NULL) {
        remote_server_free(remoteServer);
        PPWriteMessage(message, messageCapacity, @"Persistent DVT Screenshot returned NULL client");
        return -252;
    }

    uint8_t *imageBytes = NULL;
    uintptr_t imageLength = 0;
    struct IdeviceFfiError *shotError =
        screenshot_client_take_screenshot(client, &imageBytes, &imageLength);
    if (shotError != NULL) {
        screenshot_client_free(client);
        remote_server_free(remoteServer);
        return PPConsumeError(shotError, message, messageCapacity,
                              @"Persistent DVT Screenshot failed");
    }
    if (imageBytes == NULL || imageLength == 0) {
        if (imageBytes != NULL) idevice_data_free(imageBytes, imageLength);
        screenshot_client_free(client);
        remote_server_free(remoteServer);
        PPWriteMessage(message, messageCapacity, @"Persistent DVT Screenshot returned empty data");
        return -253;
    }

    NSData *imageData = [NSData dataWithBytes:imageBytes length:(NSUInteger)imageLength];
    NSString *path = [NSString stringWithUTF8String:outputPath];
    NSError *writeError = nil;
    BOOL wrote = [imageData writeToFile:path options:NSDataWritingAtomic error:&writeError];
    uintptr_t byteCount = imageLength;
    idevice_data_free(imageBytes, imageLength);
    screenshot_client_free(client);
    remote_server_free(remoteServer);
    if (!wrote) {
        PPWriteMessage(message, messageCapacity,
            [NSString stringWithFormat:@"Persistent screenshot save failed: %@",
             writeError.localizedDescription ?: @"unknown file write error"]);
        return -254;
    }
    PPWriteMessage(message, messageCapacity,
        [NSString stringWithFormat:@"PERSISTENT RSD SCREENSHOT OK • %llu bytes",
         (unsigned long long)byteCount]);
    return 0;
}

int32_t PPPhoneLocalSessionTakeScreenshotBounded(
    uintptr_t raw,
    const char *outputPath,
    uint64_t timeoutMilliseconds,
    char *message,
    size_t messageCapacity
) {
    PPPhoneLocalSession *session = PPSession(raw, message, messageCapacity);
    if (session == NULL) return -270;
    if (outputPath == NULL || outputPath[0] == '\0') {
        PPWriteMessage(message, messageCapacity, @"Bounded screenshot output path is missing");
        return -271;
    }

    struct RemoteServerHandle *remoteServer = NULL;
    struct IdeviceFfiError *remoteError =
        remote_server_connect_rsd(session->adapter, session->handshake, &remoteServer);
    if (remoteError != NULL) {
        return PPConsumeError(remoteError, message, messageCapacity,
                              @"Bounded DVT RemoteServer connect failed");
    }
    if (remoteServer == NULL) {
        PPWriteMessage(message, messageCapacity, @"Bounded DVT RemoteServer returned NULL");
        return -272;
    }

    struct ScreenshotClientHandle *client = NULL;
    struct IdeviceFfiError *clientError = screenshot_client_new(remoteServer, &client);
    if (clientError != NULL) {
        remote_server_free(remoteServer);
        return PPConsumeError(clientError, message, messageCapacity,
                              @"Bounded DVT Screenshot channel failed");
    }
    if (client == NULL) {
        remote_server_free(remoteServer);
        PPWriteMessage(message, messageCapacity, @"Bounded DVT Screenshot returned NULL client");
        return -273;
    }

    uint8_t *imageBytes = NULL;
    uintptr_t imageLength = 0;
    struct IdeviceFfiError *shotError = screenshot_client_take_screenshot_timeout(
        client,
        &imageBytes,
        &imageLength,
        timeoutMilliseconds
    );
    if (shotError != NULL) {
        screenshot_client_free(client);
        remote_server_free(remoteServer);
        return PPConsumeError(shotError, message, messageCapacity,
                              @"Bounded DVT Screenshot failed");
    }
    if (imageBytes == NULL || imageLength == 0) {
        if (imageBytes != NULL) idevice_data_free(imageBytes, imageLength);
        screenshot_client_free(client);
        remote_server_free(remoteServer);
        PPWriteMessage(message, messageCapacity, @"Bounded DVT Screenshot returned empty data");
        return -274;
    }

    NSData *imageData = [NSData dataWithBytes:imageBytes length:(NSUInteger)imageLength];
    NSString *path = [NSString stringWithUTF8String:outputPath];
    NSError *writeError = nil;
    BOOL wrote = [imageData writeToFile:path options:NSDataWritingAtomic error:&writeError];
    uintptr_t byteCount = imageLength;
    idevice_data_free(imageBytes, imageLength);
    screenshot_client_free(client);
    remote_server_free(remoteServer);
    if (!wrote) {
        PPWriteMessage(message, messageCapacity,
            [NSString stringWithFormat:@"Bounded screenshot save failed: %@",
             writeError.localizedDescription ?: @"unknown file write error"]);
        return -275;
    }
    PPWriteMessage(message, messageCapacity,
        [NSString stringWithFormat:@"BOUNDED DVT SCREENSHOT OK • %llu bytes • timeout=%llums",
         (unsigned long long)byteCount,
         (unsigned long long)timeoutMilliseconds]);
    return 0;
}

int32_t PPPhoneLocalSessionXCTestActivate(uintptr_t raw, char *message, size_t messageCapacity) {
    PPPhoneLocalSession *session = PPSession(raw, message, messageCapacity);
    if (session == NULL) return -255;
    return pilot_xctest_execute_activate(
        session->adapter, session->handshake, message, messageCapacity
    );
}

int32_t PPPhoneLocalSessionXCTestTap(
    uintptr_t raw,
    double normalizedX,
    double normalizedY,
    char *message,
    size_t messageCapacity
) {
    PPPhoneLocalSession *session = PPSession(raw, message, messageCapacity);
    if (session == NULL) return -256;
    return pilot_xctest_execute_tap(
        session->adapter, session->handshake,
        normalizedX, normalizedY, message, messageCapacity
    );
}

int32_t PPPhoneLocalSessionXCTestTapBounded(
    uintptr_t raw,
    double normalizedX,
    double normalizedY,
    uint64_t timeoutSeconds,
    char *message,
    size_t messageCapacity
) {
    PPPhoneLocalSession *session = PPSession(raw, message, messageCapacity);
    if (session == NULL) return -276;
    return pilot_xctest_execute_tap_bounded(
        session->adapter,
        session->handshake,
        normalizedX,
        normalizedY,
        timeoutSeconds,
        message,
        messageCapacity
    );
}

int32_t PPPhoneLocalSessionXCTestSwipe(
    uintptr_t raw,
    double fromX,
    double fromY,
    double toX,
    double toY,
    double duration,
    char *message,
    size_t messageCapacity
) {
    PPPhoneLocalSession *session = PPSession(raw, message, messageCapacity);
    if (session == NULL) return -257;
    return pilot_xctest_execute_swipe(
        session->adapter, session->handshake,
        fromX, fromY, toX, toY, duration,
        message, messageCapacity
    );
}

int32_t PPPhoneLocalSessionXCTestDispatchTail(
    uintptr_t raw,
    double pikminFilterX,
    double pikminFilterY,
    int32_t pikminCount,
    int32_t fastMode,
    char *message,
    size_t messageCapacity
) {
    PPPhoneLocalSession *session = PPSession(raw, message, messageCapacity);
    if (session == NULL) return -258;
    return pilot_xctest_execute_dispatch_tail(
        session->adapter, session->handshake,
        pikminFilterX, pikminFilterY, pikminCount, fastMode,
        message, messageCapacity
    );
}
