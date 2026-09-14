
#import "PilotIDeviceBridge.h"
#import "idevice.h"

#import <Foundation/Foundation.h>
#import <arpa/inet.h>
#import <netinet/in.h>
#import <sys/socket.h>
#import <ifaddrs.h>
#import <netdb.h>
#import <unistd.h>
#import <errno.h>



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

static int32_t PPCreateTunnel(
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

    struct sockaddr_in address;
    memset(&address, 0, sizeof(address));

#if defined(__APPLE__)
    address.sin_len = sizeof(address);
#endif

    address.sin_family = AF_INET;
    address.sin_port = htons(port);

    if (host == NULL ||
        inet_pton(AF_INET, host, &address.sin_addr) != 1) {
        rp_pairing_file_free(pairing);
        PPWriteMessage(message, capacity, @"Invalid IPv4 address");
        return -21;
    }

    struct IdeviceFfiError *error =
        tunnel_create_rppairing(
            (const idevice_sockaddr *)&address,
            (idevice_socklen_t)sizeof(address),
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

