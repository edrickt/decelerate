// TCCProbe/main.c proves the acceleration write needs no TCC permission.
//
// Built and run by ../tcc-test.sh as an ad-hoc signed .app bundle. The bundle has
// never been granted Accessibility / Input Monitoring. It must still be able to read
// and write HIDTrackpadAcceleration through the IOHIDSystem parameter connection,
// and the live WindowServer filter log must show the disable/restore transitions.

#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <ApplicationServices/ApplicationServices.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/hidsystem/IOHIDLib.h>
#include <IOKit/hidsystem/IOHIDShared.h>
#include <mach/mach.h>

static io_connect_t openParam(void) {
    io_service_t service =
        IORegistryEntryFromPath(kIOMainPortDefault, "IOService:/IOResources/IOHIDSystem");
    if (!service) return MACH_PORT_NULL;
    io_connect_t handle = MACH_PORT_NULL;
    kern_return_t kr = IOServiceOpen(service, mach_task_self_, kIOHIDParamConnectType, &handle);
    IOObjectRelease(service);
    return kr == KERN_SUCCESS ? handle : MACH_PORT_NULL;
}

static CFTypeRef copyParam(io_connect_t h, CFStringRef key) {
    CFTypeRef out = NULL;
    return IOHIDCopyCFTypeParameter(h, key, &out) == KERN_SUCCESS ? out : NULL;
}

static int32_t rawValue(io_connect_t h, CFStringRef key, int32_t fallback) {
    CFTypeRef ref = copyParam(h, key);
    if (!ref) return fallback;
    int32_t v = fallback;
    if (CFGetTypeID(ref) == CFNumberGetTypeID()) CFNumberGetValue(ref, kCFNumberSInt32Type, &v);
    CFRelease(ref);
    return v;
}

int main(int argc, char **argv) {
    const char *outPath = argc > 1 ? argv[1] : "/tmp/decelerate-tcc-probe.txt";
    FILE *f = fopen(outPath, "w");
    if (!f) return 1;

    fprintf(f, "AXIsProcessTrusted=%d\n", AXIsProcessTrusted());
    fprintf(f, "CGPreflightListenEventAccess=%d\n", CGPreflightListenEventAccess());
    fprintf(f, "CGPreflightPostEventAccess=%d\n", CGPreflightPostEventAccess());
    fprintf(f, "IOHIDCheckAccess(ListenEvent)=%d (0=granted,1=denied,2=unknown)\n",
            (int)IOHIDCheckAccess(kIOHIDRequestTypeListenEvent));

    io_connect_t h = openParam();
    fprintf(f, "IOServiceOpen(IOHIDSystem, kIOHIDParamConnectType)=%s\n", h ? "OK" : "FAILED");
    if (!h) { fclose(f); return 1; }

    int32_t original = rawValue(h, CFSTR("HIDTrackpadAcceleration"), 131072);
    fprintf(f, "HIDTrackpadAcceleration before=%d\n", original);

    int32_t disabled = -65536;
    CFNumberRef n = CFNumberCreate(NULL, kCFNumberSInt32Type, &disabled);
    kern_return_t kr = IOHIDSetCFTypeParameter(h, CFSTR("HIDTrackpadAcceleration"), n);
    fprintf(f, "IOHIDSetCFTypeParameter(-65536) kr=0x%x\n", kr);
    CFRelease(n);
    usleep(600000);

    CFNumberRef n2 = CFNumberCreate(NULL, kCFNumberSInt32Type, &original);
    kr = IOHIDSetCFTypeParameter(h, CFSTR("HIDTrackpadAcceleration"), n2);
    fprintf(f, "restore(%d) kr=0x%x\n", original, kr);
    CFRelease(n2);
    IOServiceClose(h);
    fclose(f);
    return 0;
}
